# shellcheck shell=bash
# ninjarr — first-run questions. Everything ends up in ninjarr.env; later runs read that file
# and ask nothing, which is what makes a rebuild fire-and-forget.

wizard() {
  step "A few questions (once)"
  info "answers are saved to ${B}ninjarr.env${X}; press Enter to accept a default"

  # ── basics
  heading "Basics"
  local tz; tz=$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo UTC)
  ask TZ_IN "timezone" "${TZ:-$tz}"
  env_set TZ "$TZ_IN"
  ask DATA_IN "where should ninjarr keep app data and the library?" "${NINJARR_DATA:-/opt/ninjarr}"
  env_set NINJARR_DATA "${DATA_IN%/}"

  # ── admin login
  heading "Your login"
  note "one username and password for Emby, Seerr, Sonarr, Radarr, Prowlarr, Bazarr, AIOStreams (and Dispatcharr)"
  while :; do
    ask ADMIN_USER_IN "username" "${ADMIN_USER:-admin}"
    [[ "$ADMIN_USER_IN" =~ ^[A-Za-z0-9._-]+$ ]] && break
    warn "letters, digits, dot, dash and underscore only"
  done
  env_set ADMIN_USER "$ADMIN_USER_IN"
  local pw="${ADMIN_PASSWORD:-}" pw2=""
  while :; do
    ask_secret pw "password (leave empty to generate one)"
    if [[ -z "$pw" ]]; then pw=$(gen_pass); info "generated a password — it's shown at the end and saved in ninjarr.env"; break; fi
    if [[ "$pw" == *"'"* || "$pw" == *","* || "$pw" =~ ^[[:space:]] || "$pw" =~ [[:space:]]$ ]]; then
      warn "the password can't contain ' or , or start/end with a space"; pw=""; continue
    fi
    if (( ${#pw} < 8 )); then warn "use at least 8 characters"; pw=""; continue; fi
    [[ -n "${ADMIN_PASSWORD:-}" && "$pw" == "$ADMIN_PASSWORD" ]] && break
    ask_secret pw2 "same password again"
    [[ "$pw" == "$pw2" ]] && break
    warn "the two didn't match — once more"; pw=""; pw2=""
  done
  env_set ADMIN_PASSWORD "$pw"

  # ── usenet provider(s)
  heading "Usenet provider"
  note "the server that actually holds the files (e.g. Easynews, Eweka, Newshosting)"
  local providers='[]' n=0 host port tls user pass conns backup
  if [[ -n "${USENET_PROVIDERS:-}" && "${USENET_PROVIDERS}" != "[]" ]]; then
    info "already configured: $(jq -r '[.[].host] | join(", ")' <<<"$USENET_PROVIDERS")"
    if ! confirm "replace them?" n; then providers=$USENET_PROVIDERS; n=-1; fi
  fi
  while (( n >= 0 )); do
    n=$((n+1))
    if (( n == 1 )); then ask_required host "provider host (e.g. news.easynews.com)"; else ask_required host "host"; fi
    ask port "port" "563"
    confirm "use SSL/TLS?" y && tls=true || tls=false
    ask user "username"
    pass=""; ask_secret pass "password"
    [[ "$user$pass" == *"'"* ]] && { warn "single quotes aren't allowed — enter this provider again"; n=$((n-1)); continue; }
    ask conns "max connections (your plan's limit)" "20"
    backup=false
    if (( n > 1 )) && confirm "backup only (used just for articles the others are missing, e.g. a block account)?" y; then
      backup=true
    fi
    providers=$(jq -c --arg id "p$n" --arg host "$host" --argjson port "${port:-563}" --argjson tls "$tls" \
      --arg user "$user" --arg pass "$pass" --argjson conns "${conns:-20}" --argjson prio "$((n-1))" --argjson backup "$backup" \
      '. + [{id: $id, name: $host, host: $host, port: $port, tls: $tls, username: $user, password: $pass,
             maxConnections: $conns, priority: $prio, isBackup: $backup, enabled: true}]' <<<"$providers")
    ok "provider $host added"
    confirm "add another provider (best on a different backbone)?" n || break
  done
  # two or more main providers: together (one priority, AIOStreams spreads the load) or in order
  if (( $(jq '[.[] | select(.isBackup | not)] | length' <<<"$providers") > 1 )) \
     && confirm "use the main providers together, load-balanced? (no = strictly in order)" y; then
    providers=$(jq -c 'map(if .isBackup then . else .priority = 0 end)' <<<"$providers")
  fi
  env_set USENET_PROVIDERS "$providers"

  # ── indexers
  heading "Indexers"
  note "Newznab indexers go into Prowlarr. Sonarr and Radarr search through it and grab the NZB"
  note "themselves, then hand it to AIOStreams — AIOStreams never talks to your indexers."
  local indexers='[]' iname iurl ikey
  if [[ -n "${INDEXERS:-}" && "${INDEXERS}" != "[]" ]]; then
    info "already configured: $(jq -r '[.[].name] | join(", ")' <<<"$INDEXERS")"
    confirm "replace them?" n || indexers=$INDEXERS
  fi
  if [[ "$indexers" == "[]" ]]; then
    while confirm "add a Newznab indexer now?" y; do
      ask_required iname "name (e.g. My Indexer)"
      ask_required iurl "URL (e.g. https://indexer.example.com)"
      ask_required ikey "API key"
      [[ "$iname$iurl$ikey" == *"'"* ]] && { warn "single quotes aren't allowed — skipped"; continue; }
      indexers=$(jq -c --arg n "$iname" --arg u "${iurl%/}" --arg k "$ikey" '. + [{name: $n, url: $u, apikey: $k}]' <<<"$indexers")
      ok "$iname added"
    done
    [[ "$indexers" == "[]" ]] && info "none — add them later in Prowlarr (Indexers → Add)"
  fi
  env_set INDEXERS "$indexers"

  # ── language
  heading "Audio language"
  note "Sonarr and Radarr will prefer this language over picture quality: a 1080p release in your"
  note "language beats a 2160p one without it, and 2160p wins between two in your language."
  note "Type 'none' to rank by picture quality only."
  ask LANG_IN "preferred audio language (English name, e.g. German, French, Spanish)" "${PREFERRED_LANGUAGE:-German}"
  LANG_IN=${LANG_IN,,}; env_set PREFERRED_LANGUAGE "${LANG_IN^}"     # "GERMAN", "german" → German, as Dojo lists it
  if [[ "${PREFERRED_LANGUAGE,,}" != "none" ]]; then
    if confirm "grab other languages meanwhile, and upgrade once a ${PREFERRED_LANGUAGE} release appears?" y; then
      env_set REQUIRE_LANGUAGE no
      ask WAIT_IN "minutes to wait for a ${PREFERRED_LANGUAGE} release before taking another (0 = don't wait)" "${LANGUAGE_WAIT_MINUTES:-0}"
      env_set LANGUAGE_WAIT_MINUTES "${WAIT_IN:-0}"
    else
      env_set REQUIRE_LANGUAGE yes
      env_set LANGUAGE_WAIT_MINUTES 0
    fi
  else
    env_set REQUIRE_LANGUAGE no
    env_set LANGUAGE_WAIT_MINUTES 0
  fi

  # ── live TV (optional)
  heading "Live TV (optional)"
  note "Dispatcharr turns an IPTV subscription into TV channels with a programme guide in Emby."
  note "You pick the channels in Dispatcharr afterwards. Watching Live TV in Emby needs Emby Premiere."
  local iptv_def=n kind=1
  case "${IPTV_TYPE:-}" in
    xtream) kind=1 ;;
    m3u)    kind=2 ;;
    *)      [[ "${IPTV:-no}" == yes ]] && kind=3 ;;
  esac
  [[ "${IPTV:-no}" == yes ]] && iptv_def=y
  if confirm "add IPTV through Dispatcharr?" "$iptv_def"; then
    env_set IPTV yes
    note "1 = Xtream Codes login (server, username, password)   2 = M3U playlist link   3 = later, in Dispatcharr"
    while :; do
      ask kind "how does your provider give you the channels?" "$kind"
      [[ "$kind" =~ ^[123]$ ]] && break
      warn "1, 2 or 3"
    done
    local iurl="" iuser="" ipass="" iepg=""
    case $kind in
      1)
        local xurl=""; [[ "${IPTV_TYPE:-}" == xtream ]] && xurl=${IPTV_URL:-}
        ask_required iurl "server URL (e.g. http://provider.example:8080)" "$xurl"
        ask_required iuser "username" "${IPTV_USER:-}"
        ipass="${IPTV_PASS:-}"; ask_secret ipass "password${IPTV_PASS:+ (Enter keeps the saved one)}"
        note "the programme guide comes from the same login, nothing more to enter"
        env_set IPTV_TYPE xtream ;;
      2)
        local murl=""; [[ "${IPTV_TYPE:-}" == m3u ]] && murl=${IPTV_URL:-}
        ask_required iurl "M3U playlist URL" "$murl"
        ask iepg "programme guide (XMLTV) URL, if your provider has one" "${IPTV_EPG_URL:-}"
        env_set IPTV_TYPE m3u ;;
      3)
        info "Dispatcharr will be installed empty — add your provider under M3U & EPG Manager"
        env_set IPTV_TYPE "" ;;
    esac
    if [[ "$iurl$iuser$ipass$iepg" == *"'"* ]]; then
      warn "single quotes aren't allowed — IPTV left empty, add it in Dispatcharr instead"
      iurl=""; iuser=""; ipass=""; iepg=""; env_set IPTV_TYPE ""
    fi
    env_set IPTV_URL "${iurl%/}"; env_set IPTV_USER "$iuser"; env_set IPTV_PASS "$ipass"; env_set IPTV_EPG_URL "$iepg"
    ask MAXS_IN "how many channels may play at once (your plan's connection limit)" "${IPTV_MAX_STREAMS:-1}"
    [[ "$MAXS_IN" =~ ^[0-9]+$ ]] || MAXS_IN=1
    env_set IPTV_MAX_STREAMS "$MAXS_IN"
  else
    env_set IPTV no
  fi

  # ── domain
  heading "Remote access (optional)"
  note "With a domain, Caddy serves Emby, Seerr and AIOStreams over HTTPS with automatic"
  note "certificates. You need DNS records for emby./request./stream.<domain> pointing at this"
  note "machine and ports 80 and 443 forwarded to it. Leave empty for home-network only."
  ask DOMAIN_IN "domain" "${DOMAIN:-}"
  env_set DOMAIN "${DOMAIN_IN#*://}"
  if [[ -n "$DOMAIN" ]]; then
    ask_required MAIL_IN "e-mail for Let's Encrypt notices" "${ACME_EMAIL:-}"
    env_set ACME_EMAIL "$MAIL_IN"
  else
    env_set ACME_EMAIL ""
  fi
  printf '\n'
}

wizard_review() {
  heading "Your setup"
  rule
  printf '   %-20s %s\n' "data folder" "$NINJARR_DATA"
  printf '   %-20s %s\n' "login" "$ADMIN_USER / ********"
  printf '   %-20s %s\n' "usenet providers" "$(jq -r '[.[] | .host + (if .isBackup then " (backup)" else "" end)] | join(", ")' <<<"$USENET_PROVIDERS")"
  printf '   %-20s %s\n' "indexers" "$(jq -r 'if length == 0 then "none yet" else [.[].name] | join(", ") end' <<<"$INDEXERS")"
  local lang="$PREFERRED_LANGUAGE"
  [[ "${lang,,}" != none ]] && { [[ "$REQUIRE_LANGUAGE" == yes ]] && lang+=" only" || lang+=" preferred, wait ${LANGUAGE_WAIT_MINUTES} min"; }
  printf '   %-20s %s\n' "language" "$lang"
  local tv="off"
  if [[ "${IPTV:-no}" == yes ]]; then
    case "${IPTV_TYPE:-}" in
      xtream) tv="Dispatcharr — Xtream login at ${IPTV_URL#*://}" ;;
      m3u)    tv="Dispatcharr — M3U playlist" ;;
      *)      tv="Dispatcharr — provider added later" ;;
    esac
  fi
  printf '   %-20s %s\n' "live TV" "$tv"
  printf '   %-20s %s\n' "remote access" "${DOMAIN:-home network only}"
  rule
}
