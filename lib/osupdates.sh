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

# A status file for Dojo (it can't look at the host itself): updated every 5 minutes and after jobs
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
  local gpu gready=false gemby=false mem sys
  gpu=$(gpu_vendor || true); gpu_ready && gready=true; emby_has_gpu && gemby=true
  mem=$(memory_status 2>>"$LOG") || mem=null
  sys=$(system_status 2>>"$LOG") || sys=null
  jq -n --arg os "$os" --arg kernel "$kernel" --argjson reboot "$reboot" --argjson pkgs "$pkgs" \
        --arg stamp "$stamp" --arg lu "$last_upd" --arg lp "$last_pkgs" --argjson auto "$auto" \
        --arg gpu "$gpu" --argjson gready "$gready" --argjson gemby "$gemby" --argjson mem "${mem:-null}" --argjson sys "${sys:-null}" \
        --arg ar "${AUTO_REBOOT:-no}" --arg up "$(cut -d. -f1 /proc/uptime)" '{
      os: $os, kernel: $kernel, auto: $auto, auto_reboot: ($ar == "yes"),
      gpu: (if $gpu == "" then null else $gpu end), gpu_ready: $gready, emby_gpu: $gemby,
      reboot_required: $reboot, reboot_packages: $pkgs,
      last_check: (if $stamp == "" then null else ($stamp | tonumber) end),
      last_update: (if $lu == "" then null else ($lu | tonumber) end),
      last_update_packages: ($lp | split(" ") | map(select(. != ""))),
      memory: $mem, system: $sys, uptime_s: ($up | tonumber), written: now | floor }' >"$HOST_STATUS.new" 2>>"$LOG" && mv "$HOST_STATUS.new" "$HOST_STATUS"
  return 0
}

# Memory for Dojo: the VM's, each app's (against its ceiling), and every app the kernel stopped for
# running out of memory in the last 7 days. Each run also adds a line per app to
# .state/memory.tsv (7 days: time, app, MB, CPU %, network in and out in MB since the app started),
# so an app that grows slowly can be found afterwards.
memory_status() {
  local total avail swt swf apps oom ids now
  read -r total avail swt swf < <(awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} /^SwapTotal:/{st=$2} /^SwapFree:/{sf=$2}
    END {print int(t/1024), int(a/1024), int(st/1024), int(sf/1024)}' /proc/meminfo)
  # "372.1MiB / 6GiB" → MB; CPU "12.5%" (100% is one core); network "1.2MB / 3.4GB" since the app started
  apps=$(docker stats --no-stream --format '{{.Name}}\t{{.MemUsage}}\t{{.CPUPerc}}\t{{.NetIO}}' 2>/dev/null | jq -Rsc '
    def mb: capture("(?<n>[0-9.]+)\\s*(?<u>[KkMGT]?i?B)") as $m | ($m.n | tonumber) *
      ({"B": (1 / 1048576), "KiB": (1 / 1024), "kB": (1000 / 1048576), "MiB": 1, "MB": (1000000 / 1048576),
        "GiB": 1024, "GB": (1000000000 / 1048576), "TiB": 1048576, "TB": (1000000000000 / 1048576)}[$m.u] // 1);
    split("\n") | map(select(length > 0) | split("\t") | {name: .[0], mb: (.[1] | split(" / ")[0] | mb | floor),
      limit_mb: (.[1] | split(" / ")[1] | mb | floor), cpu: ((.[2] // "0") | rtrimstr("%") | tonumber? // 0),
      rx_mb: ((.[3] // "0B / 0B") | split(" / ")[0] | mb * 10 | floor / 10),
      tx_mb: ((.[3] // "0B / 0B") | split(" / ")[1] | mb * 10 | floor / 10)}) | sort_by(-.mb)') || apps='[]'
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
    jq -r --arg t "$now" '.[] | "\($t)\t\(.name)\t\(.mb)\t\(.cpu)\t\(.rx_mb)\t\(.tx_mb)"' <<<"$apps" >>"$ROOT/.state/memory.tsv" 2>/dev/null || true
    awk -F'\t' -v cut=$((now - 7 * 86400)) '$1 >= cut' "$ROOT/.state/memory.tsv" >"$ROOT/.state/memory.tsv.new" 2>/dev/null \
      && mv "$ROOT/.state/memory.tsv.new" "$ROOT/.state/memory.tsv"
  fi
  jq -nc --argjson total "$total" --argjson avail "$avail" --argjson swt "$swt" --argjson swf "$swf" \
        --argjson apps "${apps:-[]}" --argjson oom "${oom:-[]}" \
    '{total_mb: $total, available_mb: $avail, swap_mb: $swt, swap_used_mb: ($swt - $swf), apps: $apps, oom: $oom}'
}

# The VM itself, since the last run, for Dojo's Stats → System: CPU, how much of the time apps
# were stuck waiting for memory (the kernel's pressure figures; they rise before a VM freezes,
# while "memory in use" can still look fine), the data disk, and how often Docker's DNS had more
# lookups waiting than it can hold. A line per run goes to .state/system.tsv (7 days: time, CPU %,
# memory available MB, swap used MB, % of time waiting for memory (some apps / all apps), data disk
# used and size MB, DNS pile-ups, network bytes in and out since boot); the names
# being looked up during such a pile-up go to .state/dns.tsv, so Dojo can say who was asking.
system_status() {
  local now prev pts=0 pcpu=0 pidle=0 psome=0 pfull=0 cpu idle some full dt cpu_pct some_pct full_pct
  local dused dsize piles=0 since
  now=$(date +%s)
  read -r cpu idle < <(awk '/^cpu /{t=0; for (i=2; i<=NF; i++) t+=$i; print t, $5 + $6; exit}' /proc/stat)
  some=$(awk '/^some/{sub("total=", "", $5); print $5}' /proc/pressure/memory 2>/dev/null || echo 0)
  full=$(awk '/^full/{sub("total=", "", $5); print $5}' /proc/pressure/memory 2>/dev/null || echo 0)
  prev="$ROOT/.state/system.prev"
  [[ -f "$prev" ]] && read -r pts pcpu pidle psome pfull <"$prev"
  echo "$now $cpu $idle ${some:-0} ${full:-0}" >"$prev"
  dt=$((now - pts))
  if (( pts == 0 || dt <= 0 || dt > 3600 || cpu <= pcpu )); then
    # nothing to compare with (first run, or after a restart): the last 5 minutes' average instead
    some_pct=$(awk '/^some/{sub("avg300=", "", $4); print $4}' /proc/pressure/memory 2>/dev/null || echo 0)
    full_pct=$(awk '/^full/{sub("avg300=", "", $4); print $4}' /proc/pressure/memory 2>/dev/null || echo 0)
    cpu_pct=$(awk -v l="$(cut -d' ' -f2 /proc/loadavg)" -v n="$(nproc)" 'BEGIN{v=100*l/n; if (v > 100) v=100; printf "%.1f", v}')
  else
    cpu_pct=$(awk -v a="$((cpu - pcpu))" -v i="$((idle - pidle))" 'BEGIN{printf "%.1f", 100 * (a - i) / a}')
    some_pct=$(awk -v d="$(( ${some:-0} - psome ))" -v t="$dt" 'BEGIN{v=d / (t * 10000); if (v < 0) v=0; printf "%.2f", v}')
    full_pct=$(awk -v d="$(( ${full:-0} - pfull ))" -v t="$dt" 'BEGIN{v=d / (t * 10000); if (v < 0) v=0; printf "%.2f", v}')
  fi
  read -r dused dsize < <(df -B1M --output=used,size "${NINJARR_DATA:-/}" 2>/dev/null | awk 'NR==2{print $1, $2}')
  # the VM's network card (the one the default route uses): bytes in and out since it started
  local nic rxb=0 txb=0
  nic=$(awk '$2 == "00000000" {print $1; exit}' /proc/net/route 2>/dev/null)
  [[ -n "$nic" && -r /sys/class/net/$nic/statistics/rx_bytes ]] \
    && rxb=$(</sys/class/net/"$nic"/statistics/rx_bytes) && txb=$(</sys/class/net/"$nic"/statistics/tx_bytes)
  # Docker's DNS pile-ups since the last run, and what was being looked up while they lasted
  if command -v journalctl >/dev/null && [[ -d /run/systemd/system ]]; then
    since=$(( pts > 0 && dt <= 3600 ? pts : now - 300 ))
    local lines; lines=$(journalctl -u docker.service --since "@$since" --until "@$now" -o cat --no-pager 2>/dev/null \
      | grep -E 'more than [0-9]+ concurrent queries|failed to query external DNS server' || true)
    piles=$(grep -c 'concurrent queries' <<<"$lines" || true)
    if (( piles > 0 )); then
      grep -o 'question=";[^\\]*' <<<"$lines" | sed 's/question=";//; s/\.$//' | sort | uniq -c \
        | awk -v t="$now" '{print t "\t" $2 "\t" $1}' >>"$ROOT/.state/dns.tsv" 2>/dev/null || true
    fi
  fi
  if [[ -d "$ROOT/.state" ]]; then
    local mavail swused
    read -r mavail swused < <(awk '/^MemAvailable:/{a=$2} /^SwapTotal:/{st=$2} /^SwapFree:/{sf=$2} END {print int(a/1024), int((st-sf)/1024)}' /proc/meminfo)
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$now" "$cpu_pct" "$mavail" "$swused" "$some_pct" "$full_pct" \
      "${dused:-0}" "${dsize:-0}" "${piles:-0}" "$rxb" "$txb" >>"$ROOT/.state/system.tsv"
    local f; for f in system dns; do
      [[ -f "$ROOT/.state/$f.tsv" ]] || continue
      awk -F'\t' -v cut=$((now - 7 * 86400)) '$1 >= cut' "$ROOT/.state/$f.tsv" >"$ROOT/.state/$f.tsv.new" && mv "$ROOT/.state/$f.tsv.new" "$ROOT/.state/$f.tsv"
    done
  fi
  jq -nc --argjson cpu "$cpu_pct" --argjson some "$some_pct" --argjson full "$full_pct" --argjson cores "$(nproc)" \
        --argjson du "${dused:-0}" --argjson ds "${dsize:-0}" --argjson piles "${piles:-0}" --argjson dt "$dt" \
    '{cpu_pct: $cpu, cores: $cores, pressure: {some: $some, full: $full}, disk: {used_mb: $du, size_mb: $ds}, dns_piles: $piles,
      interval_s: (if $dt > 0 and $dt <= 3600 then $dt else null end)}'
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
OnUnitActiveSec=5min

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
