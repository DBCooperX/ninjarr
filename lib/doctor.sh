# shellcheck shell=bash
# ninjarr — doctor: checks the whole chain end to end and prints a report that is safe to paste
# into a bug report (no keys, no passwords).
#
# Two halves: what only the host can see (containers, the library mount inside them, mount
# propagation, timers) is checked here; everything about the apps comes from Dojo — the same checks
# Dojo's Home shows — so the terminal and Dojo can never disagree.

D_FAIL=0; D_WARN=0
d_ok()   { ok "$1"; }
d_warn() { printf '   %s!%s %s\n' "$Y" "$X" "$1"; D_WARN=$((D_WARN+1)); }
d_fail() { printf '   %s%s%s %s\n' "$R" "$CROSS" "$X" "$1"; D_FAIL=$((D_FAIL+1)); }

# Dojo's checks, one line each: status <TAB> group <TAB> label <TAB> detail <TAB> what to do
dojo_checks() {
  docker exec dojo python3 /app/app.py checks 2>>"$LOG" | jq -r '.[] |
    (.fix // {}) as $f |
    [.status, .group, .label, (.detail // ""),
     (if $f.job == "wire" then "./bootstrap.sh wire" elif $f.job == "apply" then "./bootstrap.sh"
      elif $f.job == "update" then "./bootstrap.sh update" elif $f.job == "backup" then "./bootstrap.sh backup"
      elif $f.job == "reboot" then "sudo reboot" elif ($f.job // "" | startswith("restart ")) then "docker restart " + ($f.job | ltrimstr("restart "))
      elif $f.go then "Dojo → " + ($f.go | split("/") | map(ascii_upcase[0:1] + .[1:]) | join(" → "))
      elif $f.open then "open " + ($f.label | ltrimstr("Open ")) else "" end)] | @tsv' 2>>"$LOG"
}

doctor() {
  D_FAIL=0; D_WARN=0
  local c out
  local -A down=()
  step "Doctor"
  host_status   # Dojo's checks read the host's status file: make it current first

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
    heading "Timers"
    systemctl is-active -q ninjarr-backup.timer && d_ok "nightly backup" || d_warn "nightly backup timer not active — run ./bootstrap.sh"
    systemctl is-active -q ninjarr-jobs.path && d_ok "Dojo's buttons (job runner)" || d_warn "Dojo's job runner not active — run ./bootstrap.sh"
  fi

  local st group label detail fix last=""
  if [[ -n "${down[dojo]:-}" ]]; then
    heading "Apps"; d_fail "Dojo isn't running, so the app checks can't run — docker logs dojo"
  elif ! out=$(dojo_checks) || [[ -z "$out" ]]; then
    heading "Apps"; d_fail "Dojo didn't answer with its checks — see $LOG"
  else
    while IFS=$'\t' read -r st group label detail fix; do
      [[ "$group" != "$last" ]] && { heading "$group"; last=$group; }
      local line="$label${detail:+: $detail}"
      case "$st" in
        ok)   d_ok "$line" ;;
        warn) d_warn "$line${fix:+ — $fix}" ;;
        *)    d_fail "$line${fix:+ — $fix}" ;;
      esac
    done <<<"$out"
  fi

  printf '\n   ninjarr %s · %s · %s\n' "$NINJARR_VERSION" "$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown OS}")" \
    "docker $(docker version --format '{{.Server.Version}}' 2>/dev/null)"
  if (( D_FAIL )); then printf '\n   %s%s%s %d problem(s), %d warning(s)\n\n' "$R" "$CROSS" "$X" "$D_FAIL" "$D_WARN"; return 1
  elif (( D_WARN )); then printf '\n   %s!%s all working, %d warning(s)\n\n' "$Y" "$X" "$D_WARN"
  else printf '\n   %s%s%s all good\n\n' "$G" "$TICK" "$X"; fi
}
