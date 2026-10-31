# shellcheck shell=bash
# ninjarr — the VM's own Debian: security updates install by themselves every night (Debian's
# unattended-upgrades). Docker is left out: updating it restarts every container, mid-stream;
# it moves with ninjarr's own update. A restart a kernel update needs is shown in Dojo, or done
# at ~04:45 when AUTO_REBOOT=yes. A status file tells Dojo how it stands.

HOST_STATUS="$ROOT/.state/host.json"

install_os_updates() {
  command -v apt-get >/dev/null || return 0
  if ! dpkg -s unattended-upgrades >/dev/null 2>&1; then
    spin "installing automatic security updates" env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq unattended-upgrades \
      || { warn "could not install unattended-upgrades — security updates stay manual (apt upgrade)"; return 0; }
  fi
  cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
  local reboot=false; [[ "${AUTO_REBOOT:-no}" == yes ]] && reboot=true
  cat >/etc/apt/apt.conf.d/52ninjarr <<EOF
// Written by ninjarr: security updates only (Debian's default origins). Docker updates with
// ninjarr itself — an update here would restart every container while something plays.
Unattended-Upgrade::Package-Blacklist { "docker-ce"; "docker-ce-cli"; "containerd.io"; "docker-buildx-plugin"; "docker-compose-plugin"; "docker-ce-rootless-extras"; };
Unattended-Upgrade::Automatic-Reboot "$reboot";
Unattended-Upgrade::Automatic-Reboot-Time "04:45";
EOF
  install_host_status_timer
  if [[ $reboot == true ]]; then ok "security updates install automatically; a restart they need happens at ~04:45"
  else ok "security updates install automatically; Dojo says when one needs a restart"; fi
  host_status
}

# A status file for Dojo (it can't look at the host itself): updated every 15 minutes and after jobs
host_status() {
  mkdir -p "$ROOT/.state"
  local os kernel reboot=false pkgs="[]" stamp="" last_upd="" last_pkgs="" auto=false
  os=$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-Linux}")
  kernel=$(uname -r)
  if [[ -f /run/reboot-required ]]; then
    reboot=true
    [[ -f /run/reboot-required.pkgs ]] && pkgs=$(sort -u /run/reboot-required.pkgs | jq -R . | jq -sc .)
  fi
  [[ -f /var/lib/apt/periodic/unattended-upgrades-stamp ]] && stamp=$(stat -c %Y /var/lib/apt/periodic/unattended-upgrades-stamp)
  if [[ -f /var/log/unattended-upgrades/unattended-upgrades.log ]]; then
    # the last run that installed something: "2026-10-23 06:12:01,123 INFO Packages that will be upgraded: a b c"
    local line; line=$(grep "Packages that will be upgraded:" /var/log/unattended-upgrades/unattended-upgrades.log | tail -n 1 || true)
    if [[ -n "$line" ]]; then
      last_upd=$(date -d "${line:0:19}" +%s 2>/dev/null || true)
      last_pkgs=${line#*upgraded: }
    fi
  fi
  grep -qs 'Unattended-Upgrade "1"' /etc/apt/apt.conf.d/20auto-upgrades && dpkg -s unattended-upgrades >/dev/null 2>&1 && auto=true
  local gpu gready=false gemby=false mem
  gpu=$(gpu_vendor || true); gpu_ready && gready=true; emby_has_gpu && gemby=true
  mem=$(memory_status 2>>"$LOG") || mem=null
  jq -n --arg os "$os" --arg kernel "$kernel" --argjson reboot "$reboot" --argjson pkgs "$pkgs" \
        --arg stamp "$stamp" --arg lu "$last_upd" --arg lp "$last_pkgs" --argjson auto "$auto" \
        --arg gpu "$gpu" --argjson gready "$gready" --argjson gemby "$gemby" --argjson mem "${mem:-null}" \
        --arg ar "${AUTO_REBOOT:-no}" --arg up "$(cut -d. -f1 /proc/uptime)" '{
      os: $os, kernel: $kernel, auto: $auto, auto_reboot: ($ar == "yes"),
      gpu: (if $gpu == "" then null else $gpu end), gpu_ready: $gready, emby_gpu: $gemby,
      reboot_required: $reboot, reboot_packages: $pkgs,
      last_check: (if $stamp == "" then null else ($stamp | tonumber) end),
      last_update: (if $lu == "" then null else ($lu | tonumber) end),
      last_update_packages: ($lp | split(" ") | map(select(. != ""))),
      memory: $mem, uptime_s: ($up | tonumber), written: now | floor }' >"$HOST_STATUS.new" 2>>"$LOG" && mv "$HOST_STATUS.new" "$HOST_STATUS"
  return 0
}

# Memory for Dojo: the VM's, each app's (against its ceiling), and every app the kernel stopped for
# running out of memory in the last 7 days. Each run also adds a line per app to
# .state/memory.tsv (7 days), so an app that grows slowly can be found afterwards.
memory_status() {
  local total avail swt swf apps oom ids now
  read -r total avail swt swf < <(awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} /^SwapTotal:/{st=$2} /^SwapFree:/{sf=$2}
    END {print int(t/1024), int(a/1024), int(st/1024), int(sf/1024)}' /proc/meminfo)
  # "372.1MiB / 6GiB" → MB
  apps=$(docker stats --no-stream --format '{{.Name}}\t{{.MemUsage}}' 2>/dev/null | jq -Rsc '
    def mb: capture("(?<n>[0-9.]+)\\s*(?<u>[KkMGT]?i?B)") as $m | ($m.n | tonumber) *
      ({"B": (1 / 1048576), "KiB": (1 / 1024), "kB": (1 / 1024), "MiB": 1, "MB": 1, "GiB": 1024, "GB": 1024, "TiB": 1048576}[$m.u] // 1);
    split("\n") | map(select(length > 0) | split("\t") | {name: .[0], mb: (.[1] | split(" / ")[0] | mb | floor),
      limit_mb: (.[1] | split(" / ")[1] | mb | floor)}) | sort_by(-.mb)') || apps='[]'
  # the kernel names the stopped process and its container (cgroup docker-<id>.scope)
  ids=$(docker ps -a --no-trunc --format '{{.ID}} {{.Names}}' 2>/dev/null | jq -Rsc 'split("\n") | map(select(length > 0) | split(" ") | {(.[0]): .[1]}) | add // {}')
  oom=$(journalctl -k --since "-7 days" -o short-unix --no-pager 2>/dev/null | grep 'oom-kill:' | jq -Rsc --argjson ids "$ids" '
    split("\n") | map(select(length > 0) | {at: (split(" ")[0] | tonumber | floor),
      ceiling: test("CONSTRAINT_MEMCG"), task: ((capture("task=(?<t>[^,]+)") // {t: "?"}).t),
      id: ((capture("task_memcg=[^,]*docker-(?<i>[0-9a-f]{64})") // {i: ""}).i)}
      | .app = ($ids[.id] // (if .id == "" then null else "a removed container" end)) | del(.id))') || oom='[]'
  # Docker's own record of the same (kept until Docker restarts; covers machines without a kernel journal)
  oom=$(docker events --since 168h --until "$(date +%s)" --filter event=oom --format '{{.Time}} {{.Actor.Attributes.name}}' 2>/dev/null \
    | jq -Rsc --argjson k "${oom:-[]}" 'split("\n") | map(select(length > 0) | split(" ") | {at: (.[0] | tonumber), app: .[1], ceiling: true, task: null})
      | ($k + .) | group_by(.app, (.at / 60 | floor)) | map(.[0]) | sort_by(.at)') || oom='[]'
  now=$(date +%s)
  if [[ -d "$ROOT/.state" ]]; then
    jq -r --arg t "$now" '.[] | "\($t)\t\(.name)\t\(.mb)"' <<<"$apps" >>"$ROOT/.state/memory.tsv" 2>/dev/null || true
    awk -F'\t' -v cut=$((now - 7 * 86400)) '$1 >= cut' "$ROOT/.state/memory.tsv" >"$ROOT/.state/memory.tsv.new" 2>/dev/null \
      && mv "$ROOT/.state/memory.tsv.new" "$ROOT/.state/memory.tsv"
  fi
  jq -nc --argjson total "$total" --argjson avail "$avail" --argjson swt "$swt" --argjson swf "$swf" \
        --argjson apps "${apps:-[]}" --argjson oom "${oom:-[]}" \
    '{total_mb: $total, available_mb: $avail, swap_mb: $swt, swap_used_mb: ($swt - $swf), apps: $apps, oom: $oom}'
}

install_host_status_timer() {
  command -v systemctl >/dev/null && [[ -d /run/systemd/system ]] || return 0
  cat >/etc/systemd/system/ninjarr-host-status.service <<EOF
[Unit]
Description=ninjarr: the VM's update status for Dojo

[Service]
Type=oneshot
ExecStart=$ROOT/bootstrap.sh host-status
EOF
  cat >/etc/systemd/system/ninjarr-host-status.timer <<'EOF'
[Unit]
Description=ninjarr: the VM's update status for Dojo

[Timer]
OnBootSec=1min
OnUnitActiveSec=15min

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload && systemctl enable --now ninjarr-host-status.timer >/dev/null 2>&1 || true
}

# Restart the VM a few seconds from now, so the job that asked for it can still report back
reboot_host() {
  command -v systemd-run >/dev/null || die "no systemd here — restart the machine yourself"
  systemd-run --on-active=8s --unit="ninjarr-reboot-$(date +%s)" /bin/systemctl reboot >/dev/null \
    && ok "restarting in a few seconds — Dojo is back in about a minute" || die "could not schedule the restart"
}
