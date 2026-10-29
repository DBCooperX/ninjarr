# shellcheck shell=bash
# shellcheck disable=SC2034  # BASE/API_KEY/APP_NAME are read by api() and friends
# ninjarr — Sonarr, Radarr and Prowlarr, wired over their own APIs.
# Every function checks the current state first, so a rerun changes nothing that's already right.

# arr_use sonarr|radarr|prowlarr — points BASE/API_KEY/V at an app
arr_use() {
  case $1 in
    sonarr)   BASE=http://localhost:8989/api/v3; API_KEY=$SONARR_API_KEY ;;
    radarr)   BASE=http://localhost:7878/api/v3; API_KEY=$RADARR_API_KEY ;;
    prowlarr) BASE=http://localhost:9696/api/v1; API_KEY=$PROWLARR_API_KEY ;;
  esac
  APP=$1
  APP_NAME=${1^}
}

# ─────────────────────────────────────────────── login
# Forms login with the ninjarr admin, always required. ("Not required on the home network"
# makes Sonarr/Radarr demand an Allowed Hosts list, and any name missing from it — a container
# name, a hostname you browse to — silently breaks access. The API key is unaffected either way.)
arr_auth() {
  local cur id payload
  cur=$(api GET "$BASE/config/host") || { warn "$APP_NAME: could not read host settings"; return 1; }
  id=$(jq -r .id <<<"$cur")
  payload=$(jq -c --arg u "$ADMIN_USER" --arg p "$ADMIN_PASSWORD" '
    .authenticationMethod = "forms" | .authenticationRequired = "enabled"
    | .username = $u | .password = $p | .passwordConfirmation = $p' <<<"$cur")
  if api PUT "$BASE/config/host/$id" "$payload" >/dev/null; then ok "$APP_NAME: login $ADMIN_USER"
  else warn "$APP_NAME: could not set the login — see log"; fi
}

# ─────────────────────────────────────────────── library
arr_root_folder() { # arr_root_folder PATH
  local p=$1
  if api GET "$BASE/rootfolder" | jq -e --arg p "$p" 'any(.[]; .path == $p)' >/dev/null 2>&1; then
    info "$APP_NAME: root folder $p"; return 0
  fi
  if api POST "$BASE/rootfolder" "$(jq -nc --arg p "$p" '{path: $p}')" >/dev/null; then ok "$APP_NAME: root folder $p"
  else warn "$APP_NAME: root folder $p failed — see log"; fi
}

# AIOStreams' SABnzbd-compatible API is the download client. Built from the app's own schema
# so a renamed field in a new Sonarr/Radarr version doesn't silently break the payload.
arr_download_client() { # arr_download_client CATEGORY
  local cat=$1 existing schema payload id
  existing=$(api GET "$BASE/downloadclient" | jq -c '[.[] | select(.name == "AIOStreams")][0] // empty')
  schema=$(api GET "$BASE/downloadclient/schema" | jq -c '[.[] | select(.implementation == "Sabnzbd")][0] // empty')
  [[ -n "$schema" ]] || { warn "$APP_NAME: no SABnzbd client type found"; return 1; }
  payload=$(jq -c --arg pw "arr:$ARR_CLIENT_PASSWORD" --arg cat "$cat" '
    .name = "AIOStreams" | .enable = true | .priority = 1
    | .removeCompletedDownloads = true | .removeFailedDownloads = true
    | .fields |= map(
        if   .name == "host"     then .value = "aiostreams"
        elif .name == "port"     then .value = 3000
        elif .name == "useSsl"   then .value = false
        elif .name == "urlBase"  then .value = "/api/v1/sabnzbd"
        elif .name == "apiKey"   then .value = $pw
        elif .name == "username" or .name == "password" then .value = ""
        elif .name == "tvCategory" or .name == "movieCategory" or .name == "category" then .value = $cat
        else . end)' <<<"${existing:-$schema}")
  if [[ -n "$existing" ]]; then
    id=$(jq -r .id <<<"$existing")
    if api PUT "$BASE/downloadclient/$id?forceSave=true" "$payload" >/dev/null; then info "$APP_NAME: download client AIOStreams ($cat)"
    else warn "$APP_NAME: updating the AIOStreams download client failed — see log"; fi
  elif api POST "$BASE/downloadclient?forceSave=true" "$payload" >/dev/null; then
    ok "$APP_NAME: download client AIOStreams ($cat)"
  else
    warn "$APP_NAME: adding the AIOStreams download client failed — see log"
  fi
  # any other download client (e.g. a leftover SABnzbd) is switched off, not deleted
  local other
  for other in $(api GET "$BASE/downloadclient" | jq -r '.[] | select(.name != "AIOStreams" and .enable) | .id'); do
    api PUT "$BASE/downloadclient/$other?forceSave=true" "$(api GET "$BASE/downloadclient/$other" | jq -c '.enable = false')" >/dev/null \
      && info "$APP_NAME: switched off another download client (id $other)"
  done
  return 0
}

# Failed releases get blocklisted and searched again — this is what makes AIOStreams'
# automatic repair of dead releases work.
arr_download_handling() {
  local cur payload
  cur=$(api GET "$BASE/config/downloadclient") || return 1
  payload=$(jq -c '.enableCompletedDownloadHandling = true | .autoRedownloadFailed = true' <<<"$cur")
  if [[ "$(jq -c . <<<"$cur")" == "$payload" ]]; then info "$APP_NAME: redownload failed is on"; return 0; fi
  api PUT "$BASE/config/downloadclient/$(jq -r .id <<<"$cur")" "$payload" >/dev/null \
    && ok "$APP_NAME: completed-download handling and redownload failed on" \
    || warn "$APP_NAME: download handling settings failed — see log"
}

# Propers/repacks must not outrank the language score: an English PROPER would otherwise beat
# a release in the preferred language. Renaming on, so files get clean names.
arr_media_management() { # arr_media_management RENAME_FIELD
  local cur payload
  cur=$(api GET "$BASE/config/mediamanagement") || return 1
  payload=$(jq -c '.downloadPropersAndRepacks = "doNotPrefer"' <<<"$cur")
  if [[ "$(jq -c . <<<"$cur")" != "$payload" ]]; then
    api PUT "$BASE/config/mediamanagement/$(jq -r .id <<<"$cur")" "$payload" >/dev/null \
      && ok "$APP_NAME: propers/repacks don't outrank the score" || warn "$APP_NAME: media management failed — see log"
  fi
  cur=$(api GET "$BASE/config/naming") || return 1
  payload=$(jq -c --arg f "$1" '.[$f] = true' <<<"$cur")
  if [[ "$(jq -c . <<<"$cur")" != "$payload" ]]; then
    api PUT "$BASE/config/naming/$(jq -r .id <<<"$cur")" "$payload" >/dev/null \
      && ok "$APP_NAME: renaming on" || warn "$APP_NAME: naming failed — see log"
  fi
  return 0
}

# Tell Emby about every import, so new titles appear (and Seerr marks them available) in about
# a minute instead of at the next scheduled scan.
arr_emby_connect() {
  [[ -n "${EMBY_API_KEY:-}" ]] || { warn "$APP_NAME: no Emby API key yet — skipped the Emby connection"; return 0; }
  local existing schema payload
  existing=$(api GET "$BASE/notification" | jq -c '[.[] | select(.name == "Emby")][0] // empty')
  schema=$(api GET "$BASE/notification/schema" | jq -c '[.[] | select(.implementation == "MediaBrowser")][0] // empty')
  [[ -n "$schema" ]] || { warn "$APP_NAME: no Emby connection type found"; return 1; }
  payload=$(jq -c --arg k "$EMBY_API_KEY" '
    .name = "Emby"
    | . as $o
    | reduce (keys[] | select(startswith("supportsOn"))) as $s (.;
        ($s | sub("^supports"; "") | (.[:1] | ascii_downcase) + .[1:]) as $on
        | if $o[$s] and ($on | test("^on(Download|Upgrade|Rename|SeriesDelete|EpisodeFileDelete|MovieDelete|MovieFileDelete|ImportComplete)"))
          then .[$on] = true else . end)
    | .fields |= map(
        if   .name == "host"    then .value = "emby"
        elif .name == "port"    then .value = 8096
        elif .name == "useSsl"  then .value = false
        elif .name == "apiKey"  then .value = $k
        elif .name == "notify"  then .value = false
        elif .name == "updateLibrary" then .value = true
        else . end)' <<<"${existing:-$schema}")
  if [[ -n "$existing" ]]; then
    api PUT "$BASE/notification/$(jq -r .id <<<"$existing")?forceSave=true" "$payload" >/dev/null \
      && info "$APP_NAME: Emby library updates on import" || warn "$APP_NAME: Emby connection update failed — see log"
  else
    api POST "$BASE/notification?forceSave=true" "$payload" >/dev/null \
      && ok "$APP_NAME: Emby library updates on import" || warn "$APP_NAME: Emby connection failed — see log"
  fi
}

# Optional: wait a while for a release in the preferred language before taking another.
# A release that already scores as preferred language is grabbed immediately.
arr_delay_profile() {
  local cur wait=${LANGUAGE_WAIT_MINUTES:-0} payload
  [[ "${PREFERRED_LANGUAGE,,}" == none ]] && wait=0
  cur=$(api GET "$BASE/delayprofile" | jq -c '[.[] | select(.id == 1)][0] // empty')
  [[ -n "$cur" ]] || return 0
  payload=$(jq -c --argjson w "$wait" '
    .enableUsenet = true | .preferredProtocol = "usenet" | .usenetDelay = $w
    | .bypassIfAboveCustomFormatScore = ($w > 0) | .minimumCustomFormatScore = (if $w > 0 then 1000 else 0 end)' <<<"$cur")
  [[ "$(jq -c . <<<"$cur")" == "$payload" ]] && return 0
  api PUT "$BASE/delayprofile/1" "$payload" >/dev/null || { warn "$APP_NAME: delay profile failed — see log"; return 1; }
  if (( wait > 0 )); then ok "$APP_NAME: waits ${wait} min for ${PREFERRED_LANGUAGE}, grabs ${PREFERRED_LANGUAGE} at once"
  else info "$APP_NAME: no waiting for a language"; fi
}

# ─────────────────────────────────────────────── quality engine
# The rules worked out on the original stack:
#   * every 1080p/2160p quality in ONE group, so quality never outranks the custom format score
#   * "<Language> Audio" +1000 — by detected audio language, which survives renaming
#   * "2160p" +200 — among equal languages, the better picture wins
#   * Dolby Vision without an HDR fallback -10000 — plays with wrong colours on non-DV screens
#   * AV1 -300 — many players can't decode it, so Emby transcodes and HDR comes out washed out
#   * junk -10000 — mic/line-dubbed audio (MD/LD), upscales, disc images (unplayable as a stream), 3D
# Result: German 2160p 1200 > German 1080p 1000 > German 2160p AV1 900 > English 2160p 200 >
# English 1080p 0. Minimum score -300 keeps an AV1-only release as a last resort.

QUALITY_PROFILE_NAME="ninjarr"
GROUP_QUALITIES='["WEBDL-2160p","WEBRip-2160p","HDTV-2160p","Bluray-1080p","WEBDL-1080p","WEBRip-1080p","HDTV-1080p"]'
FALLBACK_QUALITIES='["HDTV-720p","WEBRip-720p","WEBDL-720p","Bluray-720p"]'

cf_language() { # cf_language NAME ID
  jq -nc --arg n "$1 Audio" --arg l "$1" --argjson id "$2" '{name: $n, includeCustomFormatWhenRenaming: false,
    specifications: [{name: $l, implementation: "LanguageSpecification", negate: false, required: false,
      fields: [{name: "value", value: $id}, {name: "exceptLanguage", value: false}]}]}'
}
cf_2160p() {
  jq -nc '{name: "2160p", includeCustomFormatWhenRenaming: false, specifications: [{name: "2160p",
    implementation: "ResolutionSpecification", negate: false, required: true, fields: [{name: "value", value: 2160}]}]}'
}
cf_dv() { # Sonarr and Radarr number release sources differently
  local webdl=3 webrip=4
  [[ "$APP" == radarr ]] && { webdl=7; webrip=8; }
  jq -nc --argjson wd "$webdl" --argjson wr "$webrip" '{name: "DV (w/o HDR fallback)", includeCustomFormatWhenRenaming: false, specifications: [
    {name: "Dolby Vision", implementation: "ReleaseTitleSpecification", negate: false, required: true, fields: [{name: "value", value: "\\b(dv|dovi|dolby[ .]?v(ision)?)\\b"}]},
    {name: "WEBDL",  implementation: "SourceSpecification", negate: false, required: false, fields: [{name: "value", value: $wd}]},
    {name: "WEBRIP", implementation: "SourceSpecification", negate: false, required: false, fields: [{name: "value", value: $wr}]},
    {name: "Not HDR", implementation: "ReleaseTitleSpecification", negate: true, required: true, fields: [{name: "value", value: "\\bHDR(\\b|\\d)"}]}]}'
}

cf_av1() {
  jq -nc '{name: "AV1", includeCustomFormatWhenRenaming: false, specifications: [{name: "AV1",
    implementation: "ReleaseTitleSpecification", negate: false, required: true, fields: [{name: "value", value: "\\bAV1\\b"}]}]}'
}

cf_title() { # cf_title NAME REGEX — a format that matches the release name (case-insensitive)
  jq -nc --arg n "$1" --arg r "$2" '{name: $n, includeCustomFormatWhenRenaming: false, specifications: [{name: $n,
    implementation: "ReleaseTitleSpecification", negate: false, required: true, fields: [{name: "value", value: $r}]}]}'
}
# name|regex — every one scored -10000, i.e. never grabbed
JUNK_FORMATS=(
  'Dubbed audio (MD/LD)|\b(MD|LD|AC3MD|AC3LD|DTSD|DTSMD|MIC[ ._-]?DUB(BED)?|LINE[ ._-]?DUB(BED)?)\b'
  'Upscaled|\b(AI[ ._-]?)?upscaled?\b'
  'Disc image|\b(BR[ ._-]?DISK|BDMV|ISO|(UHD|BD)[ ._-]?(25|50|66|100)|COMPLETE[ ._-]+(UHD[ ._-]+)?BLU[ ._-]?RAY)\b'
  '3D|\b(3D|H?SBS|H[ ._-]?OU|HALF[ ._-]?(SBS|OU))\b'
)

upsert_cf() { # upsert_cf JSON — prints the id
  local def=$1 name id
  name=$(jq -r .name <<<"$def")
  id=$(api GET "$BASE/customformat" | jq -r --arg n "$name" '[.[] | select(.name == $n) | .id][0] // empty')
  if [[ -n "$id" ]]; then
    api PUT "$BASE/customformat/$id" "$(jq -c --argjson id "$id" '. + {id: $id}' <<<"$def")" >/dev/null || return 1
  else
    id=$(api POST "$BASE/customformat" "$def" | jq -r .id) || return 1
  fi
  printf '%s' "$id"
}

arr_quality() {
  local lang=${PREFERRED_LANGUAGE:-none} lang_id="" scores id_lang="" id_2160 id_dv id_av1 min cutoff
  if [[ "${lang,,}" != none ]]; then
    lang_id=$(api GET "$BASE/language" | jq -r --arg l "${lang,,}" '[.[] | select(.name | ascii_downcase == $l) | .id][0] // empty')
    [[ -n "$lang_id" ]] || { warn "$APP_NAME: doesn't know the language '$lang' — ranking by picture quality only"; lang=none; }
  fi
  id_2160=$(upsert_cf "$(cf_2160p)") || { warn "$APP_NAME: custom format 2160p failed — see log"; return 1; }
  id_dv=$(upsert_cf "$(cf_dv)")      || { warn "$APP_NAME: custom format DV failed — see log"; return 1; }
  id_av1=$(upsert_cf "$(cf_av1)")    || { warn "$APP_NAME: custom format AV1 failed — see log"; return 1; }
  scores=$(jq -nc --argjson a "$id_2160" --argjson b "$id_dv" --argjson c "$id_av1" \
    '{($a|tostring): 200, ($b|tostring): -10000, ($c|tostring): -300}')
  local junk jid
  for junk in "${JUNK_FORMATS[@]}"; do
    jid=$(upsert_cf "$(cf_title "${junk%%|*}" "${junk#*|}")") || { warn "$APP_NAME: custom format ${junk%%|*} failed — see log"; return 1; }
    scores=$(jq -c --arg c "$jid" '. + {($c): -10000}' <<<"$scores")
  done
  min=-300; cutoff=200
  if [[ "${lang,,}" != none ]]; then
    id_lang=$(upsert_cf "$(cf_language "$lang" "$lang_id")") || { warn "$APP_NAME: custom format $lang Audio failed"; return 1; }
    scores=$(jq -c --arg c "$id_lang" '. + {($c): 1000}' <<<"$scores")
    cutoff=1200
    [[ "${REQUIRE_LANGUAGE:-no}" == yes ]] && min=700   # a release in the language, even AV1
  fi

  local base existing new pid
  existing=$(api GET "$BASE/qualityprofile" | jq -c --arg n "$QUALITY_PROFILE_NAME" '[.[] | select(.name == $n)][0] // empty')
  base=${existing:-$(api GET "$BASE/qualityprofile/schema")}
  new=$(jq -c --arg n "$QUALITY_PROFILE_NAME" --argjson gq "$GROUP_QUALITIES" --argjson fq "$FALLBACK_QUALITIES" \
        --argjson scores "$scores" --argjson min "$min" --argjson cut "$cutoff" --arg app "$APP" '
    [ .items[] | if (.items | length) > 0 then .items[] else . end | .quality ] as $all
    | ($gq + $fq) as $wanted
    | .name = $n
    | .items = (
          [ $all[] | select(.name as $q | ($wanted | any(. == $q)) | not) | {quality: ., items: [], allowed: false} ]
        + [ $fq[] as $q | $all[] | select(.name == $q) | {quality: ., items: [], allowed: true} ]
        + [ {id: 1000, name: "HD + UHD", allowed: true,
             items: [ $gq[] as $q | $all[] | select(.name == $q) | {quality: ., items: [], allowed: true} ]} ] )
    | .cutoff = 1000 | .upgradeAllowed = true
    | .minFormatScore = $min | .cutoffFormatScore = $cut | .minUpgradeFormatScore = 1
    | .formatItems = [ .formatItems[] | .score = ($scores[.format | tostring] // 0) ]
    | if $app == "radarr" then .language = {id: -1, name: "Any"} else . end' <<<"$base")

  # a brand-new custom format may not be in the profile schema yet — add any that are missing
  new=$(jq -c --argjson scores "$scores" '
    reduce ($scores | to_entries[]) as $e (.;
      if any(.formatItems[]; (.format | tostring) == $e.key) then .
      else .formatItems += [{format: ($e.key | tonumber), score: $e.value}] end)' <<<"$new")

  if [[ -n "$existing" ]]; then
    pid=$(jq -r .id <<<"$existing")
    api PUT "$BASE/qualityprofile/$pid" "$new" >/dev/null || { warn "$APP_NAME: quality profile update failed — see log"; return 1; }
  else
    pid=$(api POST "$BASE/qualityprofile" "$(jq -c 'del(.id)' <<<"$new")" | jq -r .id) || { warn "$APP_NAME: quality profile failed — see log"; return 1; }
  fi
  printf -v "${APP^^}_PROFILE_ID" '%s' "$pid"

  local summary="HD+UHD group, 2160p +200, AV1 -300, DV-without-HDR and junk blocked"
  [[ "${lang,,}" != none ]] && summary="${lang} first (+1000), $summary"
  [[ "$min" == 700 ]] && summary+=", ${lang} only"
  ok "$APP_NAME: quality profile '$QUALITY_PROFILE_NAME' — $summary"

  # Stock profiles (Any, HD-1080p, …) only invite picking the wrong one. Remove the unused ones,
  # and move anything that still uses one over to ours first.
  arr_prune_profiles "$pid"
}

arr_prune_profiles() { # arr_prune_profiles KEEP_ID
  local keep=$1 pid items=movie field=qualityProfileId
  [[ "$APP" == sonarr ]] && items=series
  # titles on another profile move to ours
  local moved=0
  for pid in $(api GET "$BASE/$items" | jq -r --argjson k "$keep" '.[] | select(.qualityProfileId != $k) | .id'); do
    api PUT "$BASE/$items/$pid" "$(api GET "$BASE/$items/$pid" | jq -c --argjson k "$keep" --arg f "$field" '.[$f] = $k')" >/dev/null && moved=$((moved+1))
  done
  (( moved )) && info "$APP_NAME: $moved title(s) moved to the '$QUALITY_PROFILE_NAME' profile"
  for pid in $(api GET "$BASE/qualityprofile" | jq -r --argjson k "$keep" '.[] | select(.id != $k) | .id'); do
    api DELETE "$BASE/qualityprofile/$pid" >/dev/null || true
  done
  return 0
}

wire_arr() { # wire_arr sonarr|radarr
  arr_use "$1"
  local root=/library/tv cat=tv rename=renameEpisodes
  [[ "$1" == radarr ]] && { root=/library/movies; cat=movies; rename=renameMovies; }
  arr_auth
  arr_root_folder "$root"
  arr_download_client "$cat"
  arr_download_handling
  arr_media_management "$rename"
  arr_quality
  arr_delay_profile
}

# ─────────────────────────────────────────────── prowlarr
prowlarr_link() { # prowlarr_link Sonarr|Radarr URL KEY
  local name=$1 url=$2 key=$3 existing schema payload
  existing=$(api GET "$BASE/applications" | jq -c --arg n "$name" '[.[] | select(.name == $n)][0] // empty')
  schema=$(api GET "$BASE/applications/schema" | jq -c --arg i "$name" '[.[] | select(.implementation == $i)][0] // empty')
  [[ -n "$schema" ]] || { warn "Prowlarr: no $name application type"; return 1; }
  payload=$(jq -c --arg n "$name" --arg u "$url" --arg k "$key" '
    .name = $n | .syncLevel = "fullSync"
    | .fields |= map(
        if   .name == "prowlarrUrl" then .value = "http://prowlarr:9696"
        elif .name == "baseUrl"     then .value = $u
        elif .name == "apiKey"      then .value = $k
        else . end)' <<<"${existing:-$schema}")
  if [[ -n "$existing" ]]; then
    api PUT "$BASE/applications/$(jq -r .id <<<"$existing")?forceSave=true" "$payload" >/dev/null \
      && info "Prowlarr → $name (full sync)" || warn "Prowlarr → $name update failed — see log"
  else
    api POST "$BASE/applications?forceSave=true" "$payload" >/dev/null \
      && ok "Prowlarr → $name (full sync)" || warn "Prowlarr → $name failed — see log"
  fi
}

# Generic Newznab indexers from the wizard. Redirect is on: Prowlarr hands Sonarr/Radarr the
# indexer's own NZB link and the arr fetches it, so the indexer sees a normal arr grab — never
# Prowlarr, and never AIOStreams.
prowlarr_indexers() {
  local n i name url key preset apipath existing schema schemas payload
  n=$(jq length <<<"${INDEXERS:-[]}")
  (( n )) || { info "Prowlarr: no indexers in ninjarr.env — add them in Prowlarr"; return 0; }
  schemas=$(api GET "$BASE/indexer/schema" | jq -c '[.[] | select(.implementation == "Newznab")]')
  [[ "$(jq length <<<"${schemas:-[]}")" -gt 0 ]] || { warn "Prowlarr: no Newznab indexer type"; return 1; }
  for ((i = 0; i < n; i++)); do
    name=$(jq -r ".[$i].name" <<<"$INDEXERS"); url=$(jq -r ".[$i].url" <<<"$INDEXERS"); key=$(jq -r ".[$i].apikey" <<<"$INDEXERS")
    preset=$(jq -r ".[$i].preset // empty" <<<"$INDEXERS"); apipath=$(jq -r ".[$i].apiPath // \"/api\"" <<<"$INDEXERS")
    # Prowlarr's own definition when the indexer is one it knows (right categories and limits)
    schema=$(jq -c --arg p "$preset" '([.[] | select($p != "" and .name == $p)] + [.[] | select(.name == "Generic Newznab")] + .)[0]' <<<"$schemas")
    existing=$(api GET "$BASE/indexer" | jq -c --arg n "$name" '[.[] | select(.name == $n)][0] // empty')
    payload=$(jq -c --arg n "$name" --arg u "$url" --arg k "$key" --arg a "$apipath" '
      .name = $n | .enable = true | .redirect = true | .appProfileId = (.appProfileId // 1)
      | .fields |= map(
          if   .name == "baseUrl" then .value = $u
          elif .name == "apiPath" then .value = $a
          elif .name == "apiKey"  then .value = $k
          else . end)' <<<"${existing:-$schema}")
    [[ "$(jq '.appProfileId' <<<"$payload")" == 0 ]] && payload=$(jq -c '.appProfileId = 1' <<<"$payload")
    if [[ -n "$existing" ]]; then
      api PUT "$BASE/indexer/$(jq -r .id <<<"$existing")?forceSave=true" "$payload" >/dev/null \
        && info "Prowlarr: indexer $name (redirect on)" || warn "Prowlarr: updating $name failed — see log"
    elif api POST "$BASE/indexer?forceSave=true" "$payload" >/dev/null; then
      ok "Prowlarr: indexer $name (redirect on)"
    else
      warn "Prowlarr: adding $name failed — check its URL and API key (see log)"
    fi
  done
  api POST "$BASE/command" '{"name":"ApplicationIndexerSync"}' >/dev/null || true
}

wire_prowlarr() {
  arr_use prowlarr
  arr_auth
  prowlarr_link Sonarr http://sonarr:8989 "$SONARR_API_KEY"
  prowlarr_link Radarr http://radarr:7878 "$RADARR_API_KEY"
  prowlarr_indexers
}

# Discord notifications (grabs, imports, health) in Sonarr and Radarr when DISCORD_WEBHOOK is set;
# removed again when it's emptied
arr_discord() {
  local app schema existing id body
  for app in sonarr radarr; do
    arr_use "$app"
    existing=$(api GET "$BASE/notification" | jq -r '[.[] | select(.name == "ninjarr-discord") | .id][0] // empty') || continue
    if [[ -z "${DISCORD_WEBHOOK:-}" ]]; then
      [[ -n "$existing" ]] && api DELETE "$BASE/notification/$existing" >/dev/null && info "$APP_NAME: Discord notifications removed"
      continue
    fi
    schema=$(api GET "$BASE/notification/schema" | jq -c '[.[] | select(.implementation == "Discord")][0] // empty')
    [[ -n "$schema" ]] || { warn "$APP_NAME: no Discord notification type"; continue; }
    body=$(jq -c --arg u "$DISCORD_WEBHOOK" '.name = "ninjarr-discord" | .onGrab = true | .onDownload = true | .onUpgrade = true
      | .onHealthIssue = true | .includeHealthWarnings = false
      | .fields |= map(if .name == "webHookUrl" then .value = $u else . end)' <<<"$schema")
    if [[ -n "$existing" ]]; then
      id=$existing; body=$(jq -c --argjson id "$id" '.id = $id' <<<"$body")
      api PUT "$BASE/notification/$id" "$body" >/dev/null && info "$APP_NAME: Discord notifications" || warn "$APP_NAME: Discord update failed — see log"
    else
      api POST "$BASE/notification" "$body" >/dev/null && ok "$APP_NAME: Discord notifications" || warn "$APP_NAME: Discord rejected — check the webhook URL (see log)"
    fi
  done
}

# Live pages: Sonarr, Radarr and Seerr tell Dojo about every event (grab, import, request…), so
# an open Dojo page updates at once instead of on its next timer. The token keeps others out.
dojo_hook_token() {
  local f="$ROOT/.state/hook-token"
  [[ -s "$f" ]] || { mkdir -p "$ROOT/.state"; (umask 077; openssl rand -hex 24 >"$f"); }
  tr -d '[:space:]' <"$f"
}

dojo_live_hooks() {
  local token app schema existing body url
  token=$(dojo_hook_token)
  for app in sonarr radarr; do
    arr_use "$app"
    url="http://dojo:5000/hook/$app?t=$token"
    existing=$(api GET "$BASE/notification" | jq -c '[.[] | select(.name == "Dojo")][0] // empty') || continue
    schema=$(api GET "$BASE/notification/schema" | jq -c '[.[] | select(.implementation == "Webhook")][0] // empty')
    [[ -n "$schema" ]] || { warn "$APP_NAME: no webhook notification type"; continue; }
    body=$(jq -c --arg u "$url" '.name = "Dojo"
      | with_entries(if (.key | test("^on[A-Z]")) and (.value | type == "boolean") then .value = true else . end)
      | .includeHealthWarnings = false
      | .fields |= map(if .name == "url" then .value = $u elif .name == "method" then .value = 1 else . end)' <<<"$schema")
    if [[ -n "$existing" ]]; then
      [[ "$(jq -r '.fields[] | select(.name == "url") | .value' <<<"$existing")" == "$url" ]] && continue
      body=$(jq -c --argjson id "$(jq .id <<<"$existing")" '.id = $id' <<<"$body")
      api PUT "$BASE/notification/$(jq -r .id <<<"$existing")?forceSave=true" "$body" >/dev/null \
        && info "$APP_NAME: tells Dojo about events" || warn "$APP_NAME: Dojo webhook update failed — see log"
    else
      api POST "$BASE/notification?forceSave=true" "$body" >/dev/null \
        && ok "$APP_NAME: tells Dojo about events" || warn "$APP_NAME: Dojo webhook rejected — see log"
    fi
  done
  seerr_live_hook "$token" || true
}

# Seerr's webhook agent: requests, approvals, failures. Its API key sits in its settings file.
seerr_live_hook() {
  local key cur payload types=4318   # pending, approved, available, failed, declined, auto-approved, auto-requested
  key=$(jq -r '.main.apiKey // empty' "$NINJARR_DATA/appdata/seerr/settings.json" 2>/dev/null) || true
  [[ -n "$key" ]] || return 0
  payload='{"type":"{{notification_type}}","subject":"{{subject}}","requestedBy":"{{requestedBy_username}}"}'
  cur=$(http GET http://localhost:5055/api/v1/settings/notifications/webhook "" -H "X-Api-Key: $key") || return 1
  [[ "$(jq -r '.options.webhookUrl // ""' <<<"$cur")" == "http://dojo:5000/hook/seerr?t=$1" && "$(jq -r .enabled <<<"$cur")" == true \
     && "$(jq -r '.options.jsonPayload // ""' <<<"$cur")" == *requestedBy* ]] && return 0
  http POST http://localhost:5055/api/v1/settings/notifications/webhook \
    "$(jq -nc --arg u "http://dojo:5000/hook/seerr?t=$1" --arg p "$payload" --argjson t "$types" \
       '{enabled: true, types: $t, options: {webhookUrl: $u, jsonPayload: $p}}')" -H "X-Api-Key: $key" >/dev/null \
    && ok "Seerr: tells Dojo about requests" || { warn "Seerr: Dojo webhook rejected — see log"; return 1; }
}
