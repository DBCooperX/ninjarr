# shellcheck shell=bash
# ninjarr — jobs: how Dojo (a container, no Docker access) gets the host to do things.
#
# Dojo drops a one-line request into .state/jobs/queue/<id>; a systemd path unit notices and runs
# `bootstrap.sh run-jobs`, which executes it and writes .state/jobs/<id>/{cmd,status,log}.
# Only the commands below are ever run, with checked arguments — the queue is never executed as
# a shell line.

JOBS_DIR="$ROOT/.state/jobs"
JOB_SERVICES="aiostreams prowlarr sonarr radarr bazarr emby seerr dojo dispatcharr caddy"

job_command() { # job_command LINE — prints the bootstrap.sh arguments for an allowed request
  local cmd arg extra
  read -r cmd arg extra <<<"$1"
  [[ -z "${extra:-}" ]] || return 1
  case "$cmd" in
    apply)  [[ -z "${arg:-}" ]] && echo install ;;
    wire|update|backup|doctor|reboot) [[ -z "${arg:-}" ]] && echo "$cmd" ;;
    restart) [[ " $JOB_SERVICES " == *" ${arg:-x} "* ]] && echo "restart $arg" ;;
    delete-backup)
      [[ "${arg:-}" =~ ^ninjarr-[0-9]{8}-[0-9]{6}\.tar\.gz$ ]] && [[ -f "$(backup_dir)/$arg" ]] && echo "delete-backup $arg" ;;
    restore)
      # only a backup file ninjarr wrote, by name, from the backup folder
      [[ "${arg:-}" =~ ^ninjarr-[0-9]{8}-[0-9]{6}\.tar\.gz$ ]] && [[ -f "$(backup_dir)/$arg" ]] && echo "restore $(backup_dir)/$arg" ;;
    *) return 1 ;;
  esac
}

# run-jobs: works through the queue, one job at a time, until it's empty
run_jobs() {
  local tee_to=${1:-} q id line args rc
  mkdir -p "$JOBS_DIR/queue"
  exec 9>"$JOBS_DIR/.lock"
  flock -n 9 || return 0            # another runner is at it; it picks up new jobs too
  while :; do
    q=$(find "$JOBS_DIR/queue" -maxdepth 1 -type f -not -name '.*' -printf '%T@ %p\n' 2>/dev/null | sort -n | head -n 1 | cut -d' ' -f2-)
    [[ -n "$q" ]] || break
    id=$(basename "$q")
    [[ "$id" =~ ^[A-Za-z0-9_-]{1,64}$ ]] || { rm -f "$q"; continue; }
    line=$(head -c 300 "$q" | head -n 1); rm -f "$q"
    mkdir -p "$JOBS_DIR/$id"
    printf '%s\n' "$line" >"$JOBS_DIR/$id/cmd"
    date -Is >"$JOBS_DIR/$id/started"
    if ! args=$(job_command "$line"); then
      echo "refused: '$line' is not something ninjarr runs" >"$JOBS_DIR/$id/log"
      echo "failed" >"$JOBS_DIR/$id/status"; continue
    fi
    echo running >"$JOBS_DIR/$id/status"
    rc=0
    # shellcheck disable=SC2086  # args is a checked, space-separated command from job_command
    if [[ -n "$tee_to" ]]; then
      NO_COLOR=1 NINJARR_UNATTENDED=1 "$ROOT/bootstrap.sh" $args 2>&1 | tee "$JOBS_DIR/$id/log" || rc=$?   # pipefail: rc is bootstrap's
    else
      NO_COLOR=1 NINJARR_UNATTENDED=1 "$ROOT/bootstrap.sh" $args >"$JOBS_DIR/$id/log" 2>&1 || rc=$?
    fi
    date -Is >"$JOBS_DIR/$id/finished"
    host_status 2>/dev/null || true
    if (( rc == 0 )); then echo ok >"$JOBS_DIR/$id/status"; else echo "failed" >"$JOBS_DIR/$id/status"; fi
  done
  # keep the last 50 jobs
  find "$JOBS_DIR" -mindepth 1 -maxdepth 1 -type d -not -name queue -printf '%T@ %p\n' | sort -rn | tail -n +51 | cut -d' ' -f2- | xargs -r rm -rf
}

# The systemd units that run the queue whenever Dojo adds something
install_jobs_runner() {
  mkdir -p "$JOBS_DIR/queue"; chmod 700 "$ROOT/.state" "$JOBS_DIR"
  command -v systemctl >/dev/null && [[ -d /run/systemd/system ]] || { info "no systemd — Dojo's buttons work only while bootstrap.sh runs"; return 0; }
  cat >/etc/systemd/system/ninjarr-jobs.service <<EOF
[Unit]
Description=ninjarr: run what Dojo asked for
After=docker.service

[Service]
Type=oneshot
ExecStart=$ROOT/bootstrap.sh run-jobs
EOF
  cat >/etc/systemd/system/ninjarr-jobs.path <<EOF
[Unit]
Description=ninjarr: watch for Dojo's requests

[Path]
PathExistsGlob=$JOBS_DIR/queue/*
Unit=ninjarr-jobs.service

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload && systemctl enable --now ninjarr-jobs.path >/dev/null 2>&1 \
    || warn "could not start the Dojo job runner (ninjarr-jobs.path)"
}
