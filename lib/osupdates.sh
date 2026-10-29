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
  local gpu gready=false gemby=false
  gpu=$(gpu_vendor || true); gpu_ready && gready=true; emby_has_gpu && gemby=true
  jq -n --arg os "$os" --arg kernel "$kernel" --argjson reboot "$reboot" --argjson pkgs "$pkgs" \
        --arg stamp "$stamp" --arg lu "$last_upd" --arg lp "$last_pkgs" --argjson auto "$auto" \
        --arg gpu "$gpu" --argjson gready "$gready" --argjson gemby "$gemby" \
        --arg ar "${AUTO_REBOOT:-no}" --arg up "$(cut -d. -f1 /proc/uptime)" '{
      os: $os, kernel: $kernel, auto: $auto, auto_reboot: ($ar == "yes"),
      gpu: (if $gpu == "" then null else $gpu end), gpu_ready: $gready, emby_gpu: $gemby,
      reboot_required: $reboot, reboot_packages: $pkgs,
      last_check: (if $stamp == "" then null else ($stamp | tonumber) end),
      last_update: (if $lu == "" then null else ($lu | tonumber) end),
      last_update_packages: ($lp | split(" ") | map(select(. != ""))),
      uptime_s: ($up | tonumber), written: now | floor }' >"$HOST_STATUS.new" 2>>"$LOG" && mv "$HOST_STATUS.new" "$HOST_STATUS"
  return 0
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
