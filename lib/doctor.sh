# shellcheck shell=bash
# ninjarr — doctor: checks the whole chain end to end and prints a report that is safe to paste
# into a bug report (no keys, no passwords).

D_FAIL=0; D_WARN=0
d_ok()   { ok "$1"; }
d_warn() { printf '   %s!%s %s\n' "$Y" "$X" "$1"; D_WARN=$((D_WARN+1)); }
d_fail() { printf '   %s%s%s %s\n' "$R" "$CROSS" "$X" "$1"; D_FAIL=$((D_FAIL+1)); }

doctor() {
  D_FAIL=0; D_WARN=0
  local c out n
  local -A down=()
  step "Doctor"

  heading "Containers"
  local -a want=(aiostreams prowlarr sonarr radarr bazarr emby seerr dojo)
  [[ "${IPTV:-no}" == yes ]] && want+=(dispatcharr)
  [[ -n "${DOMAIN:-}" ]] && want+=(caddy)
  for c in "${want[@]}"; do
    out=$(docker inspect -f '{{.State.Running}} {{.RestartCount}} {{.Config.Image}}' "$c" 2>/dev/null) || { d_fail "$c: not created — run ./bootstrap.sh"; down[$c]=1; continue; }
    read -r running restarts image <<<"$out"
    if [[ "$running" != true ]]; then d_fail "$c: not running ($image) — docker logs $c"; down[$c]=1
    elif (( restarts > 3 )); then d_warn "$c: running, but restarted $restarts times ($image) — docker logs $c"
    else d_ok "$c ${image##*:}"; fi
  done

  heading "Library mount"
  for c in sonarr radarr emby bazarr; do
    [[ -n "${down[$c]:-}" ]] && continue
    if docker exec "$c" test -d /mnt/aiostreams/usenet/completed 2>/dev/null; then d_ok "$c sees /mnt/aiostreams"
    else d_fail "$c can't see /mnt/aiostreams — every import and playback fails; check docker logs aiostreams"; fi
  done
  if http GET "http://localhost:3000/api/v1/sabnzbd/api?mode=version&output=json&apikey=arr:$ARR_CLIENT_PASSWORD" >/dev/null; then
    d_ok "AIOStreams download client API answers"
  else d_fail "AIOStreams download client API doesn't answer"; fi

  local app body
  for app in sonarr radarr; do
    heading "${app^}"
    [[ -n "${down[$app]:-}" ]] && { info "skipped — not running"; continue; }
    arr_use "$app"
    body=$(api GET "$BASE/downloadclient" | jq -c '[.[] | select(.name == "AIOStreams")][0] // empty') || body=""
    if [[ -z "$body" ]]; then d_fail "$APP_NAME: no AIOStreams download client — run ./bootstrap.sh wire"
    elif api POST "$BASE/downloadclient/test" "$body" >/dev/null; then d_ok "$APP_NAME → AIOStreams: test passed"
    else d_fail "$APP_NAME → AIOStreams: test failed — see $LOG"; fi
    out=$(api GET "$BASE/rootfolder") || out='[]'
    if jq -e 'length > 0 and all(.[]; .accessible)' <<<"$out" >/dev/null; then d_ok "$APP_NAME: root folder $(jq -r '[.[].path] | join(", ")' <<<"$out")"
    else d_fail "$APP_NAME: root folder missing or not accessible"; fi
    out=$(api GET "$BASE/health") || out='[]'
    while IFS= read -r line; do [[ -n "$line" ]] && d_warn "$APP_NAME says: $line"; done < <(jq -r '.[] | .message' <<<"$out")
  done

  heading "Prowlarr"
  arr_use prowlarr
  if [[ -n "${down[prowlarr]:-}" ]]; then info "skipped — not running"; else
  n=$(api GET "$BASE/indexer" | jq 'length' 2>/dev/null || echo 0)
  if (( n > 0 )); then d_ok "Prowlarr: $n indexer(s)"; else d_warn "Prowlarr: no indexers yet — Indexers → Add"; fi
  out=$(api GET "$BASE/indexerstatus") || out='[]'
  while IFS= read -r line; do [[ -n "$line" ]] && d_warn "Prowlarr: indexer $line is disabled after errors"; done \
    < <(jq -r '.[] | select(.disabledTill != null) | .indexerId' <<<"$out")
  fi

  heading "Emby, Seerr, Bazarr"
  out=$(http GET "$EMBY/System/Info" "" -H "X-Emby-Token: ${EMBY_API_KEY:-}") \
    && d_ok "Emby $(jq -r .Version <<<"$out")" || d_fail "Emby: no answer with ninjarr's API key"
  n=$(http GET "$EMBY/Library/VirtualFolders" "" -H "X-Emby-Token: ${EMBY_API_KEY:-}" | jq 'length' 2>/dev/null || echo 0)
  (( n >= 2 )) && d_ok "Emby: $n libraries" || d_fail "Emby: libraries missing — run ./bootstrap.sh wire"
  out=$(http GET "$SEERR/settings/public") || out='{}'
  if [[ "$(jq -r '.initialized' <<<"$out")" == true && "$(jq -r '.mediaServerType' <<<"$out")" == 3 ]]; then d_ok "Seerr: set up, signed in through Emby"
  else d_fail "Seerr: not set up — run ./bootstrap.sh wire"; fi
  BAZARR_API_KEY=${BAZARR_API_KEY:-$(bazarr_key)}
  out=$(bazarr_api GET /api/system/settings | jq -r '.general.enabled_providers // [] | join(", ")' 2>/dev/null) || out=""
  [[ -n "$out" ]] && d_ok "Bazarr: subtitle providers $out" || d_warn "Bazarr: no subtitle providers"

  if [[ "${IPTV:-no}" == yes ]]; then
    heading "Live TV"
    n=$(curl -fsS --max-time 20 http://localhost:9191/output/m3u 2>/dev/null | grep -c '^#EXTINF' || true)
    if (( n > 0 )); then d_ok "Dispatcharr: $n channel(s) for Emby"
    else d_warn "Dispatcharr: no channels yet — add them under Channels"; fi
    if http GET "$EMBY/System/Configuration/livetv" "" -H "X-Emby-Token: ${EMBY_API_KEY:-}" | jq -e 'any(.TunerHosts[]?; .Url | test("dispatcharr"))' >/dev/null; then
      d_ok "Emby: Dispatcharr tuner set up"
    else d_fail "Emby: no Dispatcharr tuner — run ./bootstrap.sh wire"; fi
  fi

  heading "Host"
  local pct
  pct=$(df -P "$NINJARR_DATA" | awk 'NR==2 {gsub("%",""); print $5}')
  (( pct < 90 )) && d_ok "disk $pct% used" || d_warn "disk $pct% used — Emby and the apps need room for their databases"
  local last age
  last=$(ls -1t "$(backup_dir)"/ninjarr-*.tar.gz 2>/dev/null | head -n 1 || true)
  if [[ -z "$last" ]]; then d_warn "no backup yet — ./bootstrap.sh backup"
  else
    age=$(( ($(date +%s) - $(stat -c %Y "$last")) / 86400 ))
    (( age <= 2 )) && d_ok "last backup $(basename "$last") ($age day(s) old)" || d_warn "last backup is $age days old"
  fi
  # What matters is that the library folder is a shared mount, and stays one after a reboot: either
  # systemd shares the whole disk (its default on Debian/Ubuntu) or ninjarr's own unit does it at boot.
  local prop rootprop
  prop=$(findmnt -no PROPAGATION --target "$NINJARR_DATA/stream" 2>/dev/null || echo unknown)
  rootprop=$(findmnt -no PROPAGATION / 2>/dev/null || echo unknown)
  if [[ "$prop" != shared* ]]; then
    d_fail "the library folder isn't a shared mount ($prop) — AIOStreams' files won't reach the other apps; run ./bootstrap.sh"
  elif [[ "$rootprop" == shared* ]] || systemctl is-enabled -q ninjarr-stream-shared.service 2>/dev/null; then
    d_ok "library mount is shared, and stays so after a reboot"
  elif [[ -d /run/systemd/system ]]; then
    d_warn "library mount is shared now, but nothing makes it so after a reboot — run ./bootstrap.sh"
  else
    d_ok "library mount is shared"
  fi
  if command -v systemctl >/dev/null && [[ -d /run/systemd/system ]]; then
    systemctl is-active -q ninjarr-backup.timer && d_ok "nightly backup timer active" || d_warn "nightly backup timer not active"
  fi

  printf '\n   ninjarr %s · %s · %s\n' "$NINJARR_VERSION" "$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown OS}")" \
    "docker $(docker version --format '{{.Server.Version}}' 2>/dev/null)"
  if (( D_FAIL )); then printf '\n   %s%s%s %d problem(s), %d warning(s)\n\n' "$R" "$CROSS" "$X" "$D_FAIL" "$D_WARN"; return 1
  elif (( D_WARN )); then printf '\n   %s!%s all working, %d warning(s)\n\n' "$Y" "$X" "$D_WARN"
  else printf '\n   %s%s%s all good\n\n' "$G" "$TICK" "$X"; fi
}
