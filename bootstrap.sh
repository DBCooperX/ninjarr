#!/usr/bin/env bash
# ninjarr — one script, a whole streaming-first media stack, no clicking.
# https://github.com/DBCooperX/ninjarr
#
#   ./bootstrap.sh              first run: starts Dojo and shows a link — the setup continues in
#                               your browser. Later runs: reads ninjarr.env, asks nothing, fixes drift
#   ./bootstrap.sh --terminal   first run with the questions here in the terminal instead
#   ./bootstrap.sh reconfigure  answer the questions again in the terminal (or use Dojo → Settings)
#   ./bootstrap.sh wire         re-apply all settings to the running apps, no pulls/restarts
#   ./bootstrap.sh update       back up, get the latest ninjarr (git pull), move to its tested versions
#   ./bootstrap.sh doctor       check the whole chain; the report is safe to paste into a bug report
#   ./bootstrap.sh backup       ninjarr.env + app data + library into one file (also runs nightly)
#   ./bootstrap.sh restore F    rebuild from backup file F — on a fresh VM or over this install
#   ./bootstrap.sh import F     one-off import of an older stack (file from migrate/export-legacy.sh)
#   ./bootstrap.sh reboot       restart the VM, e.g. after a security update that needs it
#   ./bootstrap.sh status       show what's running and where
#   ./bootstrap.sh down         stop the stack (data stays)
set -Eeuo pipefail

NINJARR_VERSION="1.0.0"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${NINJARR_ENV:-$ROOT/ninjarr.env}"
LOG="$ROOT/.ninjarr.log"
STEP_TOTAL=6

# shellcheck source=lib/ui.sh
. "$ROOT/lib/ui.sh"
# shellcheck source=lib/core.sh
. "$ROOT/lib/core.sh"
# shellcheck source=lib/wizard.sh
. "$ROOT/lib/wizard.sh"
# shellcheck source=lib/host.sh
. "$ROOT/lib/host.sh"
# shellcheck source=lib/arr.sh
. "$ROOT/lib/arr.sh"
# shellcheck source=lib/apps.sh
. "$ROOT/lib/apps.sh"
# shellcheck source=lib/backup.sh
. "$ROOT/lib/backup.sh"
# shellcheck source=lib/doctor.sh
. "$ROOT/lib/doctor.sh"
# shellcheck source=lib/jobs.sh
. "$ROOT/lib/jobs.sh"
# shellcheck source=lib/setup.sh
. "$ROOT/lib/setup.sh"
# shellcheck source=lib/migrate.sh
. "$ROOT/lib/migrate.sh"
# shellcheck source=lib/osupdates.sh
. "$ROOT/lib/osupdates.sh"

# only the main shell reports — a failing command inside $( ) is handled where it's called
trap 'rc=$?; (( BASH_SUBSHELL == 0 )) && printf "\n   %s%s%s stopped at line %s (exit %s) — details in %s\n\n" "$R" "$CROSS" "$X" "$LINENO" "$rc" "$LOG"' ERR

# ═══════════════════════════════════════════════ config
load_or_ask() { # load_or_ask [force]
  local had=0
  env_load && had=1
  if (( had )) && [[ "${1:-}" != force ]] && [[ -n "${USENET_PROVIDERS:-}" ]]; then
    step "Reading ninjarr.env"
    ok "found — nothing to ask"
    return 0
  fi
  if [[ "${NINJARR_UNATTENDED:-0}" == 1 ]]; then
    die "ninjarr.env is missing or incomplete and NINJARR_UNATTENDED=1 — copy ninjarr.env.example and fill it in"
  fi
  wizard
  wizard_review
  confirm "build the stack with these settings?" y || { env_save; die "stopped — your answers are saved in ninjarr.env"; }
  env_save
  ok "saved ninjarr.env"
}

# ═══════════════════════════════════════════════ wiring
wire_all() {
  step "Tying it all together"
  wait_http AIOStreams http://localhost:3000/ 240 || true
  wait_http Sonarr     http://localhost:8989/ping 240 || true
  wait_http Radarr     http://localhost:7878/ping 240 || true
  wait_http Prowlarr   http://localhost:9696/ping 240 || true
  wait_http Emby       http://localhost:8096/emby/System/Info/Public 300 || true
  wait_http Seerr      http://localhost:5055/api/v1/status 300 || true
  wait_http Bazarr     http://localhost:6767/ 300 || true
  wait_http Dojo       http://localhost:1337/ 60 || true
  [[ "${IPTV:-no}" == yes ]] && { wait_http Dispatcharr http://localhost:9191/api/accounts/initialize-superuser/ 300 || true; }
  check_library_mount

  heading "Emby"
  wire_emby || true
  heading "Sonarr"
  wire_arr sonarr || true
  arr_emby_connect || true
  heading "Radarr"
  wire_arr radarr || true
  arr_emby_connect || true
  heading "Prowlarr"
  wire_prowlarr || true
  heading "Seerr"
  wire_seerr || true
  heading "Bazarr"
  wire_bazarr || true
  if [[ "${IPTV:-no}" == yes ]]; then
    heading "Live TV"
    wire_dispatcharr || true
    emby_livetv || true
  else
    emby_livetv_off
  fi
  arr_discord || true
  dojo_live_hooks || true
}

# The library mount has to be visible inside Sonarr/Radarr/Emby, or every import fails
check_library_mount() {
  local t=0
  while (( t < 60 )); do
    if docker exec sonarr test -d /mnt/aiostreams/usenet/completed 2>/dev/null; then
      ok "library mount visible in Sonarr at /mnt/aiostreams"; return 0
    fi
    sleep 2; t=$((t+2))
  done
  warn "the AIOStreams library mount isn't visible inside Sonarr — check 'docker logs aiostreams' for fuse errors"
}

# ═══════════════════════════════════════════════ summary
summary() {
  step "Mission report"
  local ip; ip=$(host_ip)
  rule
  printf '   %s%-12s %-34s %s%s\n' "$D" "APP" "ON YOUR NETWORK" "HTTPS" "$X"
  rule
  local line name port sub
  # in the order a request travels: request → search → grab → stream → play
  local dojo_sub=-; [[ "${DOJO_HTTPS:-no}" == yes ]] && dojo_sub=dojo
  local -a apps=("Dojo 1337 $dojo_sub" "Seerr 5055 request" "Prowlarr 9696 -" "Sonarr 8989 -" "Radarr 7878 -" "AIOStreams 3000 stream")
  [[ "${IPTV:-no}" == yes ]] && apps+=("Dispatcharr 9191 -")
  apps+=("Emby 8096 emby" "Bazarr 6767 -")
  for line in "${apps[@]}"; do
    read -r name port sub <<<"$line"
    local remote=""
    [[ -n "${DOMAIN:-}" && "$sub" != - ]] && remote="https://$sub.$DOMAIN"
    [[ -n "$remote" && "$sub" == dojo ]] && remote+=" $DD(home network only)"
    printf '   %s%-12s%s %-34s %s%s%s\n' "$W" "$name" "$X" "http://$ip:$port" "$D" "$remote" "$X"
  done
  rule
  printf '   %-12s %s / %s\n' "login" "$ADMIN_USER" "$ADMIN_PASSWORD"
  printf '   %s(also in ninjarr.env — keep that file safe, it rebuilds everything)%s\n' "$DD" "$X"

  heading "Next"
  if [[ "$(jq length <<<"${INDEXERS:-[]}")" == 0 ]]; then
    printf '   %s•%s Dojo → Settings → Indexers: add your Newznab indexer(s)\n' "$DR" "$X"
  fi
  printf '   %s•%s Dojo (port 1337) is your control panel: health, settings, activity, backups\n' "$DR" "$X"
  printf '   %s•%s Request something in Seerr — it lands in Emby within a minute or two\n' "$DR" "$X"
  if [[ -z "${OPENSUBTITLES_USER:-}" ]]; then
    printf '   %s•%s More subtitles: an OpenSubtitles.com login under Dojo → Settings\n' "$DR" "$X"
  fi
  if [[ "${IPTV:-no}" == yes ]]; then
    printf '   %s•%s Dispatcharr → Channels: add the channels you want; Emby lists them under Live TV\n' "$DR" "$X"
    printf '     %s(watching Live TV in Emby needs Emby Premiere)%s\n' "$DD" "$X"
  fi
  if [[ -n "${DOMAIN:-}" ]]; then
    local names="emby / request / stream"; [[ "${DOJO_HTTPS:-no}" == yes ]] && names+=" / dojo"
    printf '   %s•%s DNS: %s .%s → your public IP, ports 80+443 forwarded here;\n' "$DR" "$X" "$names" "$DOMAIN"
    printf '     %sat home, rewrite the same names to %s%s\n' "$DD" "$(host_ip)" "$X"
  fi

  # width counted on the plain text: under a C locale ${#s} counts ✦ as 3 bytes, not 1 column
  local plain="MISSION COMPLETE" border
  (( ${WARNINGS:-0} > 0 )) && plain="DONE, ${WARNINGS} WARNING(S), SEE ABOVE"
  local title=" ✦ $plain ✦ "
  printf -v border '%*s' $(( ${#plain} + 6 )) ''; border=${border// /═}
  printf '\n   %s╔%s╗%s\n' "$DR" "$border" "$X"
  printf   '   %s║%s%s%s%s%s║%s\n' "$DR" "$X" "$W$B" "$title" "$X" "$DR" "$X"
  printf   '   %s╚%s╝%s\n' "$DR" "$border" "$X"
  printf '\n   %s%s%s log: %s\n\n' "$DR" "$STAR" "$X" "$LOG"
}

status() {
  env_load || die "no ninjarr.env here — run ./bootstrap.sh first"
  compose ps --format 'table {{.Name}}\t{{.Status}}\t{{.Ports}}'
}

# update: a backup first (the way back if a new version misbehaves), then the newest ninjarr
# release — which brings its tested image versions — and a restart into it
update_prepare() {
  step "Backup, then the latest ninjarr"
  backup
  if [[ -d "$ROOT/.git" ]] && command -v git >/dev/null; then
    if [[ -n "$(git -C "$ROOT" status --porcelain --untracked-files=no)" ]]; then
      warn "local changes in $ROOT — not pulling a new ninjarr; updating to the versions in this copy"
    else
      local before after
      before=$(git -C "$ROOT" rev-parse HEAD)
      if git -C "$ROOT" pull --ff-only -q >>"$LOG" 2>&1; then
        after=$(git -C "$ROOT" rev-parse HEAD)
        if [[ "$before" != "$after" ]]; then
          ok "ninjarr updated ($(git -C "$ROOT" log --oneline "$before..$after" | wc -l) change(s)) — continuing with the new version"
          exec "$ROOT/bootstrap.sh" update-pulled
        fi
        ok "ninjarr is already the latest"
      elif git -C "$ROOT" fetch -q origin >>"$LOG" 2>&1 \
           && ! git -C "$ROOT" merge-base --is-ancestor HEAD "@{upstream}" 2>/dev/null \
           && ! git -C "$ROOT" merge-base HEAD "@{upstream}" >/dev/null 2>&1; then
        # no shared history at all: ninjarr's history was started over (as at 1.0). This copy has
        # no local changes (checked above), so moving to the new history loses nothing.
        git -C "$ROOT" reset -q --hard "@{upstream}" >>"$LOG" 2>&1 \
          && { ok "ninjarr's history was restarted upstream — moved to it"; exec "$ROOT/bootstrap.sh" update-pulled; } \
          || warn "could not move to the new ninjarr history — updating to the versions in this copy (see $LOG)"
      else
        warn "git pull failed — updating to the versions in this copy (see $LOG)"
      fi
    fi
  fi
}

# ═══════════════════════════════════════════════ main
needs_setup() { ! env_load || [[ -z "${USENET_PROVIDERS:-}" || "$USENET_PROVIDERS" == "[]" ]]; }

main() {
  local cmd=${1:-install} terminal=0
  if [[ "$cmd" == --terminal ]]; then terminal=1; cmd=install; fi
  case "$cmd" in
    -h|--help|help) sed -n '2,/^set -E/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'; return 0 ;;
    status) status; return 0 ;;
    down)   env_load || die "no ninjarr.env"; compose down; return 0 ;;
    backup) # also run by the nightly timer, so it keeps its own log and no banner
      LOG="$ROOT/.ninjarr-backup.log"; : >"$LOG"; chmod 600 "$LOG"
      env_load || die "no ninjarr.env here — nothing to back up"
      mkdir -p "$ROOT/.state"; backup; return 0 ;;
    delete-backup) # delete-backup ninjarr-<date>.tar.gz — one of ninjarr's own backups, by name
      env_load || die "no ninjarr.env"
      [[ "${2:-}" =~ ^ninjarr-[0-9]{8}-[0-9]{6}\.tar\.gz$ ]] || die "not a ninjarr backup name: ${2:-}"
      [[ -f "$(backup_dir)/$2" ]] || die "no such backup: $2"
      rm -f "$(backup_dir)/$2"; ok "deleted $2"; return 0 ;;
    host-status) # the VM's update status for Dojo (timer, every 15 minutes)
      LOG=/dev/null; env_load || true; host_status; return 0 ;;
    reboot) # restart the VM (Dojo's "Restart now")
      env_load || true; reboot_host; return 0 ;;
    run-jobs) # started by ninjarr-jobs.path when Dojo queues something
      LOG="$ROOT/.ninjarr-jobs.log"; : >"$LOG"; chmod 600 "$LOG"
      env_load || true; run_jobs; return 0 ;;
    restart)
      env_load || die "no ninjarr.env"
      [[ " $JOB_SERVICES " == *" ${2:-x} "* ]] || die "restart what? one of: $JOB_SERVICES"
      compose restart "$2"; return 0 ;;
    doctor)
      LOG="$ROOT/.ninjarr-doctor.log"; : >"$LOG"; chmod 600 "$LOG"
      env_load || die "no ninjarr.env here — run ./bootstrap.sh first"
      STEP_TOTAL=1; doctor || exit 1; return 0 ;;
  esac
  : >"$LOG"; chmod 600 "$LOG"   # failed API calls are logged with their request body
  banner
  case "$cmd" in
    install|"")
      preflight
      if (( ! terminal )) && [[ "${NINJARR_UNATTENDED:-0}" != 1 ]] && needs_setup; then
        web_setup; return 0             # the build itself ran as the page's job
      fi
      load_or_ask
      ensure_secrets
      prepare_host
      compose_up
      wire_all
      summary ;;
    reconfigure)
      preflight
      load_or_ask force
      ensure_secrets
      prepare_host
      compose_up
      wire_all
      summary ;;
    wire)
      STEP_TOTAL=2
      env_load || die "no ninjarr.env — run ./bootstrap.sh first"
      wire_all
      summary ;;
    update|update-pulled)
      STEP_TOTAL=7; [[ "$cmd" == update-pulled ]] && STEP_TOTAL=6   # the backup step ran before the restart
      preflight
      env_load || die "no ninjarr.env — run ./bootstrap.sh first"
      [[ "$cmd" == update ]] && update_prepare "$@"
      ensure_secrets
      prepare_host
      compose_up
      wire_all
      summary
      doctor || true ;;
    restore)
      [[ -n "${2:-}" ]] || die "which backup? ./bootstrap.sh restore /path/to/ninjarr-<date>.tar.gz"
      preflight
      restore "$2"
      ensure_secrets
      prepare_host
      compose_up
      wire_all
      summary ;;
    import)
      [[ -n "${2:-}" ]] || die "which file? ./bootstrap.sh import /path/to/ninjarr-migrate-<date>.tar"
      STEP_TOTAL=8
      preflight
      env_load || die "no ninjarr.env — set up ninjarr first, then import"
      import_legacy "$2"
      ensure_secrets
      prepare_host
      compose_up
      wire_all
      import_after_wire
      summary ;;
    *) die "unknown command '$cmd' — try ./bootstrap.sh help" ;;
  esac
}
main "$@"
