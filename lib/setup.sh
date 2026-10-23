# shellcheck shell=bash
# ninjarr — first install in the browser. The terminal gets Docker going and starts only Dojo;
# you answer the questions in Dojo's setup page, where every login and key is tested before it's
# saved; then the build runs here, its output on both the page and this terminal.

latest_job() { find "$ROOT/.state/jobs" -mindepth 1 -maxdepth 1 -type d -not -name queue -printf '%T@ %f\n' 2>/dev/null | sort -rn | head -n 1 | cut -d' ' -f2; }

web_setup() {
  step "Setup in your browser"
  local tz code ip url
  tz=$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo UTC)
  env_default TZ "${tz:-UTC}"
  env_default NINJARR_DATA /opt/ninjarr
  ensure_secrets >/dev/null                 # keys and generated passwords; the page never handles them
  mkdir -p "$NINJARR_DATA/appdata/dojo" "$ROOT/.state/jobs/queue"
  chmod 700 "$ROOT/.state"
  : >>"$ROOT/.state/aiostreams.env"         # compose wants every env_file to exist
  write_compose_override >/dev/null

  code=$(printf '%06d' $(( $(od -An -N4 -tu4 /dev/urandom) % 1000000 )))
  printf '%s' "$code" >"$ROOT/.state/setup-code"; chmod 600 "$ROOT/.state/setup-code"

  if ! spin "building Dojo" compose build dojo; then
    die "Dojo could not be built (see $LOG) — or answer the questions here: ./bootstrap.sh --terminal"
  fi
  spin "starting Dojo" compose up -d --no-deps dojo || die "Dojo could not start — see $LOG"
  wait_http Dojo http://localhost:1337/ 90 || die "Dojo doesn't answer on port 1337 — docker logs dojo"

  ip=$(host_ip); url="http://$ip:1337"
  printf '\n   %s┌──────────────────────────────────────────────┐%s\n' "$DR" "$X"
  printf   '   %s│%s  open   %s%-37s%s%s│%s\n' "$DR" "$X" "$W$B" "$url" "$X" "$DR" "$X"
  printf   '   %s│%s  code   %s%-37s%s%s│%s\n' "$DR" "$X" "$W$B" "$code" "$X" "$DR" "$X"
  printf   '   %s└──────────────────────────────────────────────┘%s\n' "$DR" "$X"
  note "keep this terminal open — the build runs here once you press Build on the page"
  note "rather answer in the terminal? Ctrl-C, then ./bootstrap.sh --terminal"
  printf '\n'

  # Work through what the page asks for until a build has gone through. If the systemd runner
  # (left from an earlier install) takes a job first, just watch its result.
  local start_job j st reported=""
  start_job=$(latest_job)
  while :; do
    if [[ -n "$(find "$ROOT/.state/jobs/queue" -maxdepth 1 -type f -not -name '.*' 2>/dev/null)" ]]; then
      printf '\n'; run_jobs tee
    fi
    j=$(latest_job)
    if [[ -n "$j" && "$j" != "$start_job" ]] && grep -qx apply "$ROOT/.state/jobs/$j/cmd" 2>/dev/null; then
      st=$(cat "$ROOT/.state/jobs/$j/status" 2>/dev/null || true)
      if [[ "$st" == ok ]]; then rm -f "$ROOT/.state/setup-code"; return 0; fi
      if [[ "$st" == failed && "$reported" != "$j" ]]; then
        warn "the build stopped — fix it on the page and press Build again (this terminal keeps waiting)"
        reported=$j
      fi
    fi
    sleep 2
  done
}
