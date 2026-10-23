# shellcheck shell=bash
# ninjarr — Emby, Seerr and Bazarr, wired over their own APIs.

# ISO 639-1 code for a language name, for Emby metadata and Bazarr subtitles
lang_code() {
  case "${1,,}" in
    german) echo de;; english) echo en;; french) echo fr;; spanish) echo es;; italian) echo it;;
    dutch) echo nl;; portuguese) echo pt;; polish) echo pl;; swedish) echo sv;; danish) echo da;;
    norwegian) echo no;; finnish) echo 'fi';; czech) echo cs;; hungarian) echo hu;; turkish) echo tr;;
    russian) echo ru;; japanese) echo ja;; korean) echo ko;; chinese) echo zh;; greek) echo el;;
    *) echo en;;
  esac
}
lang_country() {
  case "$1" in en) echo US;; da) echo DK;; sv) echo SE;; ja) echo JP;; ko) echo KR;; zh) echo CN;; cs) echo CZ;; el) echo GR;;
    *) echo "${1^^}";; esac
}

# ═══════════════════════════════════════════════ Emby
EMBY=http://localhost:8096/emby
EMBY_AUTH='MediaBrowser Client="ninjarr", Device="bootstrap", DeviceId="ninjarr-bootstrap", Version="2.0"'

emby_token() { # signs in as the admin, prints an access token
  http POST "$EMBY/Users/AuthenticateByName" \
    "$(jq -nc --arg u "$ADMIN_USER" --arg p "$ADMIN_PASSWORD" '{Username: $u, Pw: $p}')" \
    -H "X-Emby-Authorization: $EMBY_AUTH" | jq -r '.AccessToken // empty'
}

wire_emby() {
  local code lc country tok libs
  lc=$(lang_code "${PREFERRED_LANGUAGE:-English}"); [[ "${PREFERRED_LANGUAGE,,}" == none ]] && lc=en
  country=$(lang_country "$lc")

  # first-run wizard: the startup endpoints only answer before it has been completed
  code=$(curl -s -o /dev/null -w '%{http_code}' "$EMBY/Startup/User")
  if [[ "$code" == 200 ]]; then
    http POST "$EMBY/Startup/Configuration" "$(jq -nc --arg l "$lc" --arg c "$country" \
      '{UICulture: "en-us", MetadataCountryCode: $c, PreferredMetadataLanguage: $l}')" >/dev/null
    http POST "$EMBY/Startup/User" "$(jq -nc --arg u "$ADMIN_USER" --arg p "$ADMIN_PASSWORD" '{Name: $u, Password: $p}')" >/dev/null
    http POST "$EMBY/Startup/RemoteAccess" '{"EnableRemoteAccess":true,"EnableAutomaticPortMapping":false}' >/dev/null
    if http POST "$EMBY/Startup/Complete" "" >/dev/null; then ok "Emby: setup done, admin $ADMIN_USER"
    else warn "Emby: first-run setup failed — see log"; return 1; fi
  fi

  tok=$(emby_token)
  [[ -n "$tok" ]] || { warn "Emby: could not sign in as $ADMIN_USER — was Emby set up with another password?"; return 1; }

  # an API key for Sonarr/Radarr's "update library" connection and for Seerr
  local key
  key=$(http GET "$EMBY/Auth/Keys" "" -H "X-Emby-Token: $tok" | jq -r '[.Items[] | select(.AppName == "ninjarr") | .AccessToken][0] // empty')
  if [[ -z "$key" ]]; then
    http POST "$EMBY/Auth/Keys?App=ninjarr" "" -H "X-Emby-Token: $tok" >/dev/null
    key=$(http GET "$EMBY/Auth/Keys" "" -H "X-Emby-Token: $tok" | jq -r '[.Items[] | select(.AppName == "ninjarr") | .AccessToken][0] // empty')
  fi
  if [[ -n "$key" ]]; then
    [[ "$key" != "${EMBY_API_KEY:-}" ]] && { env_set EMBY_API_KEY "$key"; env_save; }
    ok "Emby: API key for ninjarr"
  else
    warn "Emby: could not create an API key — see log"
  fi

  # Libraries over the symlink library. Options that would read whole files through usenet in the
  # background (chapter images, preview thumbnails, intro detection) stay off; /library is
  # read-only for Emby, so nothing is saved next to the media either.
  libs=$(http GET "$EMBY/Library/VirtualFolders" "" -H "X-Emby-Token: $tok")
  local entry name type path opts
  for entry in "Movies|movies|/library/movies" "TV Shows|tvshows|/library/tv"; do
    IFS='|' read -r name type path <<<"$entry"
    if jq -e --arg p "$path" 'any(.[]; .Locations | index($p))' <<<"$libs" >/dev/null 2>&1; then
      info "Emby: library $name"; continue
    fi
    opts=$(jq -nc --arg p "$path" --arg l "$lc" --arg c "$country" '{LibraryOptions: {
      PathInfos: [{Path: $p}], PreferredMetadataLanguage: $l, MetadataCountryCode: $c,
      EnableRealtimeMonitor: false, EnableChapterImageExtraction: false, ExtractChapterImagesDuringLibraryScan: false,
      ThumbnailImagesIntervalSeconds: -1, EnableMarkerDetection: false, EnableMarkerDetectionDuringLibraryScan: false,
      SaveLocalMetadata: false, SaveLocalThumbnailSets: false, MetadataSavers: [],
      SaveSubtitlesWithMedia: false, SaveLyricsWithMedia: false}}')
    if http POST "$EMBY/Library/VirtualFolders?name=$(jq -rn --arg n "$name" '$n|@uri')&collectionType=$type&refreshLibrary=false" "$opts" -H "X-Emby-Token: $tok" >/dev/null; then
      ok "Emby: library $name → $path"
    else
      warn "Emby: library $name failed — see log"
    fi
  done
  # a scheduled scan as a safety net; imports already trigger one through Sonarr/Radarr
  return 0
}

# ═══════════════════════════════════════════════ Seerr
SEERR=http://localhost:5055/api/v1
SEERR_JAR=""

# First sign-in also tells Seerr where Emby is; once it knows, sending the server again is an error
seerr_login() { # seerr_login true|false (server already configured)
  local body
  SEERR_JAR=$(mktemp); chmod 600 "$SEERR_JAR"
  if [[ "$1" == true ]]; then
    body=$(jq -nc --arg u "$ADMIN_USER" --arg p "$ADMIN_PASSWORD" '{username: $u, password: $p}')
  else
    body=$(jq -nc --arg u "$ADMIN_USER" --arg p "$ADMIN_PASSWORD" --arg e "${ACME_EMAIL:-$ADMIN_USER@ninjarr.local}" \
      '{username: $u, password: $p, hostname: "emby", port: 8096, useSsl: false, urlBase: "", email: $e, serverType: 3}')
  fi
  http POST "$SEERR/auth/jellyfin" "$body" -c "$SEERR_JAR" -b "$SEERR_JAR" >/dev/null
}
seerr() { http "$1" "$SEERR$2" "${3:-}" -b "$SEERR_JAR" -c "$SEERR_JAR"; }

seerr_arr() { # seerr_arr sonarr|radarr PORT KEY PROFILE_ID DIR
  local app=$1 port=$2 key=$3 pid=$4 dir=$5 existing body
  [[ -n "$pid" ]] || pid=$(API_KEY=$key api GET "http://localhost:$port/api/v3/qualityprofile" | jq -r --arg n "$QUALITY_PROFILE_NAME" '[.[] | select(.name == $n) | .id][0] // 1')
  existing=$(seerr GET "/settings/$app" | jq -c '.[0] // empty')
  body=$(jq -nc --arg app "$app" --argjson port "$port" --arg key "$key" --argjson pid "$pid" --arg pn "$QUALITY_PROFILE_NAME" \
    --arg dir "$dir" --arg ext "http://$(host_ip):$port" '{
      name: ($app | (.[:1] | ascii_upcase) + .[1:]), hostname: $app, port: $port, apiKey: $key, useSsl: false, baseUrl: "",
      activeProfileId: $pid, activeProfileName: $pn, activeDirectory: $dir, is4k: false, isDefault: true,
      externalUrl: $ext, syncEnabled: true, preventSearch: false}
    + (if $app == "sonarr" then {enableSeasonFolders: true, seriesType: "standard", animeSeriesType: "anime",
         activeAnimeProfileId: $pid, activeAnimeProfileName: $pn, activeAnimeDirectory: $dir}
       else {minimumAvailability: "released"} end)')
  if [[ -n "$existing" ]]; then
    seerr PUT "/settings/$app/$(jq -r .id <<<"$existing")" "$body" >/dev/null \
      && info "Seerr → ${app^}" || warn "Seerr → ${app^} update failed — see log"
  else
    seerr POST "/settings/$app" "$body" >/dev/null \
      && ok "Seerr → ${app^} (profile $QUALITY_PROFILE_NAME, $dir)" || warn "Seerr → ${app^} failed — see log"
  fi
}

wire_seerr() {
  local initialized id
  [[ -n "${EMBY_API_KEY:-}" ]] || { warn "Seerr: Emby isn't ready — skipped"; return 1; }
  local pub; pub=$(curl -s "$SEERR/settings/public")
  initialized=$(jq -r .initialized <<<"$pub")
  # mediaServerType 4 = not configured yet; anything else means Seerr already knows its server
  if ! seerr_login "$(jq -r 'if .mediaServerType == 4 then "false" else "true" end' <<<"$pub")"; then warn "Seerr: could not sign in with the Emby admin — see log"; return 1; fi
  if [[ "$initialized" != true ]]; then
    seerr POST /settings/jellyfin/library/sync "" >/dev/null || true
    for id in $(seerr GET /settings/jellyfin/library | jq -r '.[] | select(.type == "movie" or .type == "show") | .id'); do
      seerr PUT "/settings/jellyfin/library/$id" '{"enabled":true}' >/dev/null || true
    done
    ok "Seerr: signed in through Emby, libraries enabled"
  else
    info "Seerr: already set up"
  fi
  seerr_arr sonarr 8989 "$SONARR_API_KEY" "${SONARR_PROFILE_ID:-}" /library/tv
  seerr_arr radarr 7878 "$RADARR_API_KEY" "${RADARR_PROFILE_ID:-}" /library/movies
  if [[ -n "${DOMAIN:-}" ]]; then
    local main; main=$(seerr GET /settings/main)
    seerr POST /settings/main "$(jq -c --arg u "https://request.$DOMAIN" '.applicationUrl = $u | .trustProxy = true' <<<"$main")" >/dev/null \
      && info "Seerr: public URL https://request.$DOMAIN" || true
  fi
  if [[ "$initialized" != true ]]; then
    seerr POST /settings/initialize "" >/dev/null && ok "Seerr: setup complete" || warn "Seerr: could not finish setup — see log"
  fi
  rm -f "$SEERR_JAR"
  return 0
}

# ═══════════════════════════════════════════════ Bazarr
# Bazarr has no per-resource API for settings: everything goes through one form POST to
# /api/system/settings with "settings-<section>-<field>" keys; only submitted keys change.
BAZARR=http://localhost:6767

bazarr_api() { # bazarr_api METHOD PATH [field=value ...]
  local m=$1 path=$2; shift 2
  local -a args=(-sS --max-time 60 -w $'\n%{http_code}' -X "$m" "$BAZARR$path" -H "X-API-KEY: $BAZARR_API_KEY")
  local kv; for kv in "$@"; do args+=(--data-urlencode "$kv"); done
  local out code resp
  out=$(curl "${args[@]}" 2>>"$LOG") || return 1
  code=${out##*$'\n'}; resp=${out%$'\n'*}
  [[ "$code" =~ ^2 ]] && { printf '%s' "$resp"; return 0; }
  printf 'Bazarr %s %s -> HTTP %s\n%s\n\n' "$m" "$path" "$code" "${resp:0:1000}" >>"$LOG"
  return 1
}

bazarr_key() {
  local f="$NINJARR_DATA/appdata/bazarr/config/config.yaml" k=""
  [[ -f "$f" ]] && k=$(awk '/^auth:/{f=1;next} /^[^ ]/{f=0} f && /^[[:space:]]*apikey:/{print $2; exit}' "$f" | tr -d "\"'")
  printf '%s' "$k"
}

wire_bazarr() {
  local key t=0
  while [[ -z "$(bazarr_key)" ]] && (( t < 60 )); do sleep 2; t=$((t+2)); done
  key=$(bazarr_key)
  [[ -n "$key" ]] || { warn "Bazarr: no API key found yet — rerun later"; return 1; }
  [[ "$key" != "${BAZARR_API_KEY:-}" ]] && { env_set BAZARR_API_KEY "$key"; env_save; }

  # languages profile: preferred language first, English as fallback
  local lc profile name
  lc=$(lang_code "${PREFERRED_LANGUAGE:-English}"); [[ "${PREFERRED_LANGUAGE,,}" == none ]] && lc=en
  if [[ "$lc" == en ]]; then
    name="EN"
    profile=$(jq -nc '{profileId: 1, name: "EN", cutoff: 1, items: [{id: 1, language: "en", audio_exclude: "False", audio_only_include: "False", hi: "False", forced: "False"}],
      mustContain: [], mustNotContain: [], originalFormat: 0, tag: null}')
  else
    name="${lc^^}+EN"
    profile=$(jq -nc --arg l "$lc" --arg n "$name" '{profileId: 1, name: $n, cutoff: 1, items: [
      {id: 1, language: $l, audio_exclude: "False", audio_only_include: "False", hi: "False", forced: "False"},
      {id: 2, language: "en", audio_exclude: "False", audio_only_include: "False", hi: "False", forced: "False"}],
      mustContain: [], mustNotContain: [], originalFormat: 0, tag: null}')
  fi
  local -a args=("languages-profiles=[$profile]")
  local l; for l in $(jq -r '[.items[].language] | unique | .[]' <<<"$profile"); do args+=("languages-enabled=$l"); done
  if bazarr_api GET /api/system/languages/profiles | jq -e --arg n "$name" 'any(.[]?; .name == $n)' >/dev/null 2>&1; then
    info "Bazarr: languages profile $name"
  elif bazarr_api POST /api/system/settings "${args[@]}" >/dev/null; then
    ok "Bazarr: languages profile $name"
  else
    warn "Bazarr: languages profile failed — see log"
  fi

  # connections to Sonarr/Radarr, default profile on, only monitored titles, and the login
  if bazarr_api POST /api/system/settings \
      "settings-general-use_sonarr=true" "settings-sonarr-ip=sonarr" "settings-sonarr-port=8989" \
      "settings-sonarr-base_url=/" "settings-sonarr-ssl=false" "settings-sonarr-apikey=$SONARR_API_KEY" \
      "settings-sonarr-only_monitored=true" \
      "settings-general-use_radarr=true" "settings-radarr-ip=radarr" "settings-radarr-port=7878" \
      "settings-radarr-base_url=/" "settings-radarr-ssl=false" "settings-radarr-apikey=$RADARR_API_KEY" \
      "settings-radarr-only_monitored=true" \
      "settings-general-serie_default_enabled=true" "settings-general-serie_default_profile=1" \
      "settings-general-movie_default_enabled=true" "settings-general-movie_default_profile=1" \
      "settings-auth-type=form" "settings-auth-username=$ADMIN_USER" "settings-auth-password=$ADMIN_PASSWORD" \
      >/dev/null; then
    ok "Bazarr: connected to Sonarr and Radarr, login $ADMIN_USER"
  else
    warn "Bazarr: connecting to Sonarr/Radarr failed — see log"
  fi
  bazarr_providers
}

# Subtitle providers that work without an account, plus OpenSubtitles.com when its login is in
# ninjarr.env. Providers you enabled yourself are kept.
bazarr_providers() {
  local cur want p
  cur=$(bazarr_api GET /api/system/settings | jq -c '.general.enabled_providers // []') || { warn "Bazarr: could not read providers"; return 1; }
  want=$(jq -c '. + ["podnapisi", "gestdown"] | unique' <<<"$cur")
  local -a args=()
  if [[ -n "${OPENSUBTITLES_USER:-}" && -n "${OPENSUBTITLES_PASS:-}" ]]; then
    want=$(jq -c '. + ["opensubtitlescom"] | unique' <<<"$want")
    args+=("settings-opensubtitlescom-username=$OPENSUBTITLES_USER" "settings-opensubtitlescom-password=$OPENSUBTITLES_PASS")
  fi
  for p in $(jq -r '.[]' <<<"$want"); do args+=("settings-general-enabled_providers=$p"); done
  if bazarr_api POST /api/system/settings "${args[@]}" >/dev/null; then
    ok "Bazarr: subtitle providers $(jq -r 'join(", ")' <<<"$want")"
  else
    warn "Bazarr: setting subtitle providers failed — see log"
  fi
}

# ═══════════════════════════════════════════════ Dispatcharr (optional IPTV) + Emby Live TV
DISPATCHARR=http://localhost:9191/api
DISPATCHARR_IN=http://dispatcharr:9191   # how Emby reaches it on the ninjarr network
dtok=""

dapi() { # dapi METHOD PATH [JSON] — Dispatcharr API with the admin's token
  http "$1" "$DISPATCHARR$2" "${3:-}" -H "Authorization: Bearer $dtok"
}

dispatcharr_epg_url() { # the guide URL: given, or derived from an Xtream login
  if [[ -n "${IPTV_EPG_URL:-}" ]]; then printf '%s' "$IPTV_EPG_URL"
  elif [[ "${IPTV_TYPE:-}" == xtream ]]; then
    jq -rn --arg s "$IPTV_URL" --arg u "$IPTV_USER" --arg p "$IPTV_PASS" '"\($s)/xmltv.php?username=\($u|@uri)&password=\($p|@uri)"'
  fi
}

# dispatcharr_load ID — refresh the provider and wait for its channel list. A new account first
# loads only its groups ("pending_setup"); a second refresh then imports the streams.
dispatcharr_load() {
  local id=$1 t=0 st msg kicked=0
  dapi POST "/m3u/refresh/$id/" "" >/dev/null || true
  while (( t < 300 )); do
    sleep 3; t=$((t+3))
    st=$(dapi GET "/m3u/accounts/$id/") || continue
    msg=$(jq -r '.last_message // ""' <<<"$st")
    case "$(jq -r .status <<<"$st")" in
      pending_setup) (( kicked++ < 3 )) && dapi POST "/m3u/refresh/$id/" "" >/dev/null ;;
      success) [[ "$msg" == *"Total processed: 0."* && $kicked -lt 3 ]] && { dapi POST "/m3u/refresh/$id/" "" >/dev/null; kicked=$((kicked+1)); continue; }
               return 0 ;;
      error) warn "Dispatcharr: the provider answered with an error — ${msg:0:120}"; return 1 ;;
    esac
  done
  info "Dispatcharr: the channel list is still loading — it shows up in Dispatcharr when done"
}

# An API key for Dojo, which shows Dispatcharr's live streams on its Activity page. The user's
# existing key is reused (a new one would break whatever else uses it); one is made only if none.
dispatcharr_api_key() {
  local dkey
  dkey=$(dapi GET /accounts/api-keys/ | jq -r '.key // empty') || dkey=""
  [[ -n "$dkey" ]] || dkey=$(dapi POST /accounts/api-keys/generate/ '{}' | jq -r '.key // empty') || dkey=""
  [[ -n "$dkey" ]] && { env_set DISPATCHARR_API_KEY "$dkey"; env_save; info "Dispatcharr: API key for Dojo"; }
  return 0
}

wire_dispatcharr() {
  local st body id epg
  st=$(http GET "$DISPATCHARR/accounts/initialize-superuser/") || { warn "Dispatcharr: not answering — see log"; return 1; }
  if [[ "$(jq -r .superuser_exists <<<"$st")" != true ]]; then
    http POST "$DISPATCHARR/accounts/initialize-superuser/" \
      "$(jq -nc --arg u "$ADMIN_USER" --arg p "$ADMIN_PASSWORD" '{username: $u, password: $p}')" >/dev/null \
      && ok "Dispatcharr: admin $ADMIN_USER" || { warn "Dispatcharr: could not create the admin — see log"; return 1; }
  fi
  # Nothing for ninjarr to set up (an imported Dispatcharr, or the provider added there by hand):
  # leave its accounts alone and don't sign in at all
  if [[ ( -z "${IPTV_TYPE:-}" || -z "${IPTV_URL:-}" ) && -z "$(dispatcharr_epg_url)" && "$(jq -r .superuser_exists <<<"$st")" == true ]]; then
    info "Dispatcharr: channels and accounts are managed in Dispatcharr"
    # Dojo's API key: with ninjarr's login if Dispatcharr knows it (one attempt, no retries)
    if [[ -z "${DISPATCHARR_API_KEY:-}" ]]; then
      dtok=$(http POST "$DISPATCHARR/accounts/token/" \
        "$(jq -nc --arg u "$ADMIN_USER" --arg p "$ADMIN_PASSWORD" '{username: $u, password: $p}')" | jq -r '.access // empty') || dtok=""
      if [[ -n "$dtok" ]]; then dispatcharr_api_key
      else info "Dispatcharr: it has its own login — connect Dojo once under Settings → Live TV"; fi
    fi
    return 0
  fi
  local _
  for _ in 1 2 3 4 5; do   # the sign-in is rate-limited; several runs in a row can hit it
    dtok=$(http POST "$DISPATCHARR/accounts/token/" \
      "$(jq -nc --arg u "$ADMIN_USER" --arg p "$ADMIN_PASSWORD" '{username: $u, password: $p}')" | jq -r '.access // empty') || true
    [[ -n "$dtok" ]] && break
    grep -q 'throttled' <(tail -n 3 "$LOG") || break
    sleep 15
  done
  [[ -n "$dtok" ]] || { warn "Dispatcharr: could not sign in as $ADMIN_USER — was its password changed?"; return 1; }
  ok "Dispatcharr: login $ADMIN_USER"
  [[ -n "${DISPATCHARR_API_KEY:-}" ]] || dispatcharr_api_key

  if [[ -z "${IPTV_TYPE:-}" || -z "${IPTV_URL:-}" ]]; then
    info "Dispatcharr: no provider in ninjarr.env — add it under M3U & EPG Manager"
  else
    body=$(jq -nc --arg t "$IPTV_TYPE" --arg url "$IPTV_URL" --arg u "${IPTV_USER:-}" --arg p "${IPTV_PASS:-}" \
                 --argjson max "${IPTV_MAX_STREAMS:-1}" '
      {name: "ninjarr IPTV", server_url: $url, is_active: true, max_streams: $max, refresh_interval: 24,
       account_type: (if $t == "xtream" then "XC" else "STD" end)}
      + (if $t == "xtream" then {username: $u, password: $p} else {} end)')
    id=$(dapi GET /m3u/accounts/ | jq -r '[.[] | select(.name == "ninjarr IPTV") | .id][0] // empty')
    if [[ -n "$id" ]]; then
      dapi PATCH "/m3u/accounts/$id/" "$body" >/dev/null || { warn "Dispatcharr: updating the IPTV provider failed — see log"; return 1; }
    else
      id=$(dapi POST /m3u/accounts/ "$body" | jq -r '.id // empty')
      [[ -n "$id" ]] || { warn "Dispatcharr: adding the IPTV provider failed — check the URL and login (see log)"; return 1; }
    fi
    dispatcharr_load "$id" || return 1
    ok "Dispatcharr: provider ${IPTV_URL#*://} ($([[ $IPTV_TYPE == xtream ]] && echo "Xtream login" || echo "M3U playlist"), ${IPTV_MAX_STREAMS:-1} stream(s) at once)"
  fi

  epg=$(dispatcharr_epg_url)
  if [[ -n "$epg" ]]; then
    body=$(jq -nc --arg url "$epg" '{name: "ninjarr guide", source_type: "xmltv", url: $url, is_active: true, refresh_interval: 24}')
    id=$(dapi GET /epg/sources/ | jq -r '[.[] | select(.name == "ninjarr guide") | .id][0] // empty')
    if [[ -n "$id" ]]; then
      dapi PATCH "/epg/sources/$id/" "$body" >/dev/null && dapi POST /epg/import/ "{\"id\": $id}" >/dev/null || true
    else
      dapi POST /epg/sources/ "$body" >/dev/null || warn "Dispatcharr: adding the programme guide failed — see log"
    fi
    ok "Dispatcharr: programme guide"
  fi
}

# Emby reads Dispatcharr's channel list and guide. Watching needs Emby Premiere; without it the
# settings are still saved and start working once Premiere is active.
emby_livetv() {
  local cfg
  [[ -n "${EMBY_API_KEY:-}" ]] || { warn "Emby: no API key yet — skipped Live TV"; return 0; }
  cfg=$(http GET "$EMBY/System/Configuration/livetv" "" -H "X-Emby-Token: $EMBY_API_KEY") || { warn "Emby: could not read Live TV settings"; return 1; }
  if jq -e --arg u "$DISPATCHARR_IN/" 'any(.TunerHosts[]?; (.Url // "") | startswith($u))' <<<"$cfg" >/dev/null; then
    info "Emby: Live TV tuner Dispatcharr"
  else
    http POST "$EMBY/LiveTv/TunerHosts" "$(jq -nc --arg u "$DISPATCHARR_IN/output/m3u" --argjson n "${IPTV_MAX_STREAMS:-1}" \
        '{Type: "m3u", Url: $u, FriendlyName: "Dispatcharr", ImportGuideData: false, TunerCount: $n,
          AllowHWTranscoding: true, AllowMappingByNumber: true}')" -H "X-Emby-Token: $EMBY_API_KEY" >/dev/null \
      && ok "Emby: Live TV tuner Dispatcharr" || { warn "Emby: adding the Dispatcharr tuner failed — see log"; return 1; }
  fi
  if jq -e --arg p "$DISPATCHARR_IN/" 'any(.ListingProviders[]?; (.Path // "") | startswith($p))' <<<"$cfg" >/dev/null; then
    info "Emby: TV guide from Dispatcharr"
  else
    http POST "$EMBY/LiveTv/ListingProviders" "$(jq -nc --arg p "$DISPATCHARR_IN/output/epg" '{Type: "xmltv", Path: $p, EnableAllTuners: true}')" \
      -H "X-Emby-Token: $EMBY_API_KEY" >/dev/null \
      && ok "Emby: TV guide from Dispatcharr" || warn "Emby: adding the TV guide failed — see log"
  fi
}

# IPTV switched off: take Dispatcharr out of Emby too, so Emby doesn't keep polling a dead tuner
emby_livetv_off() {
  local cfg id removed=0
  [[ -n "${EMBY_API_KEY:-}" ]] || return 0
  cfg=$(http GET "$EMBY/System/Configuration/livetv" "" -H "X-Emby-Token: $EMBY_API_KEY") || return 0
  for id in $(jq -r --arg u "$DISPATCHARR_IN/output/m3u" '.TunerHosts[]? | select(.Url == $u) | .Id' <<<"$cfg"); do
    http DELETE "$EMBY/LiveTv/TunerHosts?Id=$id" "" -H "X-Emby-Token: $EMBY_API_KEY" >/dev/null && removed=1
  done
  for id in $(jq -r --arg p "$DISPATCHARR_IN/output/epg" '.ListingProviders[]? | select(.Path == $p) | .Id' <<<"$cfg"); do
    http DELETE "$EMBY/LiveTv/ListingProviders?Id=$id" "" -H "X-Emby-Token: $EMBY_API_KEY" >/dev/null && removed=1
  done
  (( removed )) && info "Emby: Dispatcharr tuner and guide removed (IPTV is off)"
  return 0
}
