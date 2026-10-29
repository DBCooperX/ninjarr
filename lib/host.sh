# shellcheck shell=bash
# ninjarr — everything that happens on the host before the containers start.

# ═══════════════════════════════════════════════ preflight
preflight() {
  step "Checking the dojo"

  [[ $EUID -eq 0 ]] || die "run as root (or with sudo): it installs Docker and creates mounts"

  local id="" like=""
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    id=$(. /etc/os-release; echo "${ID:-}"); like=$(. /etc/os-release; echo "${ID_LIKE:-}")
    ok "$(. /etc/os-release; echo "${PRETTY_NAME:-$id}")"
  fi
  local apt=0
  [[ "$id" == debian || "$id" == ubuntu || "$like" == *debian* ]] && apt=1

  # Inside an LXC container FUSE and shared mounts need extra Proxmox features; a VM just works.
  local virt; virt=$(systemd-detect-virt 2>/dev/null || true)
  case "$virt" in
    lxc|lxc-libvirt) warn "running in an LXC container — needs features nesting=1,fuse=1 (a VM is simpler)";;
    none|"") ;;
    *) ok "virtualisation: $virt" ;;
  esac

  # basic tools
  local need=()
  for c in curl jq openssl sqlite3; do command -v "$c" >/dev/null || need+=("$c"); done
  if (( ${#need[@]} )); then
    (( apt )) || die "missing: ${need[*]} — install them and run again"
    spin "installing ${need[*]}" bash -c "apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ${need[*]} ca-certificates"
  fi
  ok "curl, jq, openssl, sqlite3"

  # docker
  if ! command -v docker >/dev/null; then
    (( apt )) || die "Docker is not installed — install Docker Engine with the Compose plugin, then run again"
    info "Docker isn't installed yet — using Docker's official install script"
    spin "installing Docker (a few minutes)" bash -c "curl -fsSL https://get.docker.com | sh"
    systemctl enable --now docker >>"$LOG" 2>&1 || true
  fi
  docker compose version >/dev/null 2>&1 || die "the Docker Compose plugin is missing (docker compose version fails)"
  docker info >/dev/null 2>&1 || die "cannot talk to the Docker daemon"
  ok "docker $(docker version --format '{{.Server.Version}}'), compose $(docker compose version --short)"

  # FUSE for AIOStreams' library mount
  [[ -e /dev/fuse ]] || modprobe fuse >>"$LOG" 2>&1 || true
  [[ -e /dev/fuse ]] || die "/dev/fuse is missing — AIOStreams needs FUSE to mount its library (on Proxmox LXC: enable features fuse=1)"
  ok "FUSE available"

  # sizing — only advice, never a hard stop
  local mem_gb disk_gb
  mem_gb=$(awk '/MemTotal/ {printf "%d", $2/1024/1024 + 0.5}' /proc/meminfo)
  (( mem_gb >= 4 )) && ok "${mem_gb} GB RAM" || warn "${mem_gb} GB RAM — 4 GB or more is recommended"
  local probe=${NINJARR_DATA:-/opt}; while [[ ! -d "$probe" ]]; do probe=$(dirname "$probe"); done
  disk_gb=$(df -BG --output=avail "$probe" | tail -1 | tr -dc '0-9')
  (( disk_gb >= 20 )) && ok "${disk_gb} GB free disk" || warn "${disk_gb} GB free disk — 20 GB or more is recommended (images ~5 GB; media itself takes none)"
}

# ═══════════════════════════════════════════════ secrets & defaults
# Generated once and kept in ninjarr.env. The *arr API keys are written into each app's
# config.xml before its first start, so every key is known up front — AIOStreams can be told
# about Sonarr/Radarr at launch, and a rebuild from the same ninjarr.env gets the same keys.
ensure_secrets() {
  env_default PUID 1000
  env_default PGID 1000
  env_default SONARR_API_KEY   "$(adopt_arr_key sonarr || gen_hex)"
  env_default RADARR_API_KEY   "$(adopt_arr_key radarr || gen_hex)"
  env_default PROWLARR_API_KEY "$(adopt_arr_key prowlarr || gen_hex)"
  env_default ARR_CLIENT_PASSWORD "$(gen_pass)"   # what Sonarr/Radarr use to log in to AIOStreams' SABnzbd API
  env_default AIOSTREAMS_SECRET_KEY "$(gen_hex 32)"
  env_default EMBY_API_KEY ""
  env_default IPTV no
  env_default BAZARR_API_KEY ""
  env_save
}

# If an app already has a config.xml (e.g. ninjarr.env was lost but the data wasn't), keep its key
adopt_arr_key() {
  local f="${NINJARR_DATA}/appdata/$1/config.xml" k
  [[ -f "$f" ]] || return 1
  k=$(sed -n 's:.*<ApiKey>\(.*\)</ApiKey>.*:\1:p' "$f")
  [[ -n "$k" ]] && printf '%s' "$k"
}

# ═══════════════════════════════════════════════ folders
prepare_host() {
  step "Laying out the dojo"
  local d="$NINJARR_DATA"
  mkdir -p "$d"/appdata/{aiostreams,prowlarr,sonarr,radarr,bazarr,emby,seerr,caddy,dojo,dispatcharr} \
           "$d"/library/{movies,tv} "$d/stream" "$ROOT/.state/caddy" "$ROOT/.state/jobs/queue" "$ROOT/.state/dojo"
  chown "$PUID:$PGID" "$d"/appdata/{prowlarr,sonarr,radarr,bazarr,emby} "$d/library" "$d"/library/{movies,tv}
  chown -R 1000:1000 "$d/appdata/seerr"      # Seerr always runs as uid 1000
  ok "data in $d (library, app configs, stream mount point)"

  ensure_shared_mount "$d/stream"
  seed_arr_config sonarr   8989 "$SONARR_API_KEY"
  seed_arr_config radarr   7878 "$RADARR_API_KEY"
  seed_arr_config prowlarr 9696 "$PROWLARR_API_KEY"
  install_backup_timer
  install_jobs_runner
  install_os_updates
  write_aiostreams_env
  write_caddyfile
  ensure_gpu_driver
  write_compose_override
}

# The library mount only reaches the other containers if the host folder sits on a mount with
# shared propagation. systemd makes / shared by default, so this is usually already true; if it
# isn't, the folder becomes its own shared bind mount, made persistent with a tiny systemd unit.
ensure_shared_mount() {
  local p=$1 prop
  prop=$(findmnt -no PROPAGATION --target "$p" 2>/dev/null || echo unknown)
  if [[ "$prop" == shared* ]]; then ok "mount propagation shared at $p"; return 0; fi
  info "making $p a shared mount (was: $prop)"
  if ! findmnt -no TARGET "$p" >/dev/null 2>&1 || [[ "$(findmnt -no TARGET --target "$p")" != "$p" ]]; then
    mount --bind "$p" "$p"
  fi
  mount --make-rshared "$p"
  if command -v systemctl >/dev/null; then
    cat >/etc/systemd/system/ninjarr-stream-shared.service <<EOF
[Unit]
Description=ninjarr: shared mount for the AIOStreams library
Before=docker.service
DefaultDependencies=no
After=local-fs.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'mountpoint -q $p || mount --bind $p $p; mount --make-rshared $p'

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload >>"$LOG" 2>&1 && systemctl enable --now ninjarr-stream-shared.service >>"$LOG" 2>&1 || true
  fi
  ok "mount propagation shared at $p"
}

# Writes a minimal config.xml with our API key before the app's first start. Leaves an existing
# file alone apart from making sure the key matches ninjarr.env.
seed_arr_config() { # seed_arr_config APP PORT KEY
  local app=$1 port=$2 key=$3 f="${NINJARR_DATA}/appdata/$1/config.xml"
  if [[ -f "$f" ]]; then
    if ! grep -q "<ApiKey>$key</ApiKey>" "$f"; then
      sed -i "s:<ApiKey>.*</ApiKey>:<ApiKey>$key</ApiKey>:" "$f"
      info "$app: API key updated to the one in ninjarr.env"
    fi
    return 0
  fi
  cat >"$f" <<EOF
<Config>
  <ApiKey>$key</ApiKey>
  <AuthenticationMethod>Forms</AuthenticationMethod>
  <AuthenticationRequired>Enabled</AuthenticationRequired>
  <Port>$port</Port>
  <UrlBase></UrlBase>
  <LaunchBrowser>False</LaunchBrowser>
</Config>
EOF
  chown "$PUID:$PGID" "$f"
  ok "$app: API key pre-set"
}

aiostreams_base_url() {
  if [[ -n "${DOMAIN:-}" ]]; then printf 'https://stream.%s' "$DOMAIN"; else printf 'http://%s:3000' "$(host_ip)"; fi
}

# AIOStreams reads all of this at start-up. A setting given here is locked (read-only) in its
# dashboard — the point: ninjarr.env stays the single source of truth, and a rerun restores it.
write_aiostreams_env() {
  local f="$ROOT/.state/aiostreams.env" instances
  instances=$(jq -nc --arg sk "$SONARR_API_KEY" --arg rk "$RADARR_API_KEY" '[
    {id: "sonarr", name: "Sonarr", type: "sonarr", url: "http://sonarr:8989", apiKey: $sk, enabled: true, categories: ["tv"]},
    {id: "radarr", name: "Radarr", type: "radarr", url: "http://radarr:7878", apiKey: $rk, enabled: true, categories: ["movies"]}]')
  {
    printf "SECRET_KEY='%s'\n" "$AIOSTREAMS_SECRET_KEY"
    printf "BASE_URL='%s'\n" "$(aiostreams_base_url)"
    printf "AIOSTREAMS_AUTH='%s:%s,arr:%s'\n" "$ADMIN_USER" "$ADMIN_PASSWORD" "$ARR_CLIENT_PASSWORD"
    printf "AIOSTREAMS_AUTH_PERMISSIONS='%s=admin,arr=sabnzbd'\n" "$ADMIN_USER"
    printf "AIOSTREAMS_AUTH_REQUIRED='true'\n"
    # the library: mounted here, imported by the arrs as symlinks
    printf "SHARES_FUSE_ENABLED='true'\n"
    printf "SHARES_FUSE_MOUNT_PATH='/mnt/aiostreams'\n"
    printf "SHARES_FUSE_ALLOW_OTHER='true'\n"
    printf "ARR_MOUNT_DIR='/mnt/aiostreams'\n"
    printf "ARR_IMPORT_MODE='symlink'\n"
    printf "ARR_INSTANCES='%s'\n" "$instances"
    printf "ARR_AUTO_REPAIR='true'\n"
    printf "ARR_QUEUE_CLEANUP_ENABLED='true'\n"
    # usenet engine
    printf "USENET_PROVIDERS='%s'\n" "$USENET_PROVIDERS"
    printf "USENET_RECHECK_SCOPE='sabnzbd'\n"
    printf "USENET_RECHECK_WINDOW='02:00-08:00'\n"
    printf "USENET_VERIFY_CONTENT='true'\n"
    # the downloaded NZBs are what the library streams from: keep plenty (default is 1 GB)
    printf "BUILTIN_NZB_GRAB_DISK_CACHE_BYTES='20GB'\n"
    # AIOStreams is a download client here, never an indexer in front of the arrs
    printf "ENABLE_NAB_API='false'\n"
  } >"$f.tmp"
  chmod 600 "$f.tmp"; mv "$f.tmp" "$f"
  ok "AIOStreams configured ($(jq length <<<"$USENET_PROVIDERS") usenet provider(s), library mount, Sonarr/Radarr links)"
}

write_caddyfile() {
  local f="$ROOT/.state/caddy/Caddyfile"
  if [[ -z "${DOMAIN:-}" ]]; then
    printf '# no domain configured — Caddy is not started\n' >"$f"
    return 0
  fi
  cat >"$f" <<EOF
{
	email $ACME_EMAIL
}

emby.$DOMAIN {
	reverse_proxy emby:8096
}

request.$DOMAIN {
	reverse_proxy seerr:5055
}

stream.$DOMAIN {
	reverse_proxy aiostreams:3000
}
EOF
  if [[ "${DOJO_HTTPS:-no}" == yes ]]; then
    # Dojo can rebuild the stack: over HTTPS for the installed phone app, but only for devices on
    # the home network. A request from the internet arrives with its public address and is refused.
    cat >>"$f" <<EOF

dojo.$DOMAIN {
	@outside not remote_ip private_ranges
	respond @outside "Dojo only answers on the home network." 403
	reverse_proxy dojo:5000
}
EOF
    ok "Caddy: emby.$DOMAIN, request.$DOMAIN, stream.$DOMAIN, dojo.$DOMAIN (home network only)"
  else
    ok "Caddy: emby.$DOMAIN, request.$DOMAIN, stream.$DOMAIN"
  fi
}

# ═══════════════════════════════════════════════ GPU (hardware transcoding in Emby)
# A GPU passed through to the VM (Proxmox: Hardware → PCI Device) needs Debian's normal kernel: the
# cloud kernel the VM image starts with has no graphics drivers, so /dev/dri never appears.

gpu_vendor() { # intel, amd or nothing — the first display device on the PCI bus
  local d c v
  for d in /sys/bus/pci/devices/*; do
    c=$(<"$d/class") 2>/dev/null || continue; v=$(<"$d/vendor") 2>/dev/null || continue
    [[ "$c" == 0x03* ]] || continue
    case "$v" in 0x8086) echo intel; return 0 ;; 0x1002) echo amd; return 0 ;; esac
  done
  return 1
}
gpu_ready() { [[ -e /dev/dri/renderD128 ]]; }
emby_has_gpu() { grep -qs '/dev/dri' "$ROOT/.state/compose.override.yml"; }

# Installs what the GPU needs, if anything is missing, and marks a restart as due (Dojo then shows
# "Restart now"). After the restart, host_status hands the GPU to Emby by itself.
ensure_gpu_driver() {
  local v fw cloud
  v=$(gpu_vendor) || return 0
  gpu_ready && return 0
  fw=firmware-misc-nonfree; [[ "$v" == amd ]] && fw=firmware-amd-graphics
  mapfile -t cloud < <(dpkg-query -W -f '${Package}\n' 'linux-image-*cloud*' 2>/dev/null || true)
  if (( ${#cloud[@]} == 0 )) && dpkg -s "$fw" >/dev/null 2>&1; then
    warn "${v^} GPU found, but no driver for it is loaded — restart the VM once; if that doesn't help, see $LOG"
    return 0
  fi
  # the firmware lives in Debian's non-free-firmware section, which cloud images leave out
  local src=/etc/apt/sources.list.d/debian.sources
  [[ -f "$src" ]] && grep -q '^Components: main$' "$src" && sed -i 's/^Components: main$/Components: main non-free-firmware/' "$src"
  spin "${v^} GPU found: installing Debian's normal kernel and the GPU firmware" \
    env DEBIAN_FRONTEND=noninteractive sh -c "apt-get update -q && apt-get install -y -q linux-image-amd64 $fw" \
    || { warn "installing the GPU driver failed — Emby transcodes on the CPU for now (see $LOG)"; return 0; }
  # the cloud kernel has to go, or the VM keeps booting it (same version, sorted first). Without
  # prompts, Debian allows removing the running kernel; the new one is in place by now.
  if (( ${#cloud[@]} )); then
    spin "removing the cloud kernel (it has no graphics drivers)" \
      env DEBIAN_FRONTEND=noninteractive apt-get purge -y -q "${cloud[@]}" || warn "removing the cloud kernel failed — see $LOG"
  fi
  touch /run/reboot-required; echo "GPU driver" >>/run/reboot-required.pkgs
  ok "GPU driver installed. Restart the VM once (Dojo → Home → Restart now, or sudo reboot); then Emby gets the GPU by itself."
}

# After a restart: the GPU is there now, but Emby was started without it (run by host_status)
gpu_followup() {
  gpu_ready && ! emby_has_gpu || return 0
  [[ "$(docker inspect -f '{{.State.Running}}' emby 2>/dev/null)" == true ]] || return 0   # stopped on purpose: leave it
  write_compose_override >/dev/null
  compose up -d --no-deps emby >>"$LOG" 2>&1 || true
}

# Hardware transcoding for Emby when the VM has a GPU passed through
write_compose_override() {
  local f="$ROOT/.state/compose.override.yml"
  if gpu_ready; then
    cat >"$f" <<'EOF'
services:
  emby:
    devices: ["/dev/dri:/dev/dri"]
EOF
    ok "GPU found — Emby gets /dev/dri for hardware transcoding"
  else
    printf 'services: {}\n' >"$f"
  fi
}

# ═══════════════════════════════════════════════ compose
compose() {
  local -a files=(-f "$ROOT/compose/stack.yml" -f "$ROOT/.state/compose.override.yml")
  local -a prof=()
  [[ -n "${DOMAIN:-}" ]] && prof+=(--profile proxy)
  [[ "${IPTV:-no}" == yes ]] && prof+=(--profile iptv)
  # versions.env first: a *_TAG set in ninjarr.env overrides the tested version
  docker compose --project-directory "$ROOT/compose" --env-file "$ROOT/versions.env" --env-file "$ENV_FILE" \
    "${files[@]}" "${prof[@]}" "$@"
}

compose_up() {
  step "Summoning the clan"
  if ! SOFT=1 spin "pulling images (the slow bit, ~5 GB the first time)" compose pull --ignore-buildable; then
    # A registry (GitHub's, LinuxServer's, AWS's) hiccuped. Every version is pinned in versions.env,
    # so an image that is already here is exactly the right one; only a missing image is a problem.
    # Try each image once more on its own, so the message can name the ones that really failed.
    local img missing=() stale=()
    for img in $(compose config --images); do
      [[ "$img" == ninjarr-dojo:local ]] && continue
      docker pull -q "$img" >>"$LOG" 2>&1 && continue
      if docker image inspect "$img" >/dev/null 2>&1; then stale+=("${img##*/}"); else missing+=("$img"); fi
    done
    (( ${#missing[@]} )) && die "could not download ${missing[*]} — its registry didn't answer (see $LOG); try again in a few minutes"
    if (( ${#stale[@]} == 1 )); then info "${stale[0]}: its registry didn't answer — already here in the right version, nothing missing"
    elif (( ${#stale[@]} )); then info "the registries didn't answer for ${#stale[@]} images — all already here in the right version, nothing missing"
    else ok "images (second try)"; fi
  fi
  if ! spin "building Dojo" compose build dojo; then
    if docker image inspect ninjarr-dojo:local >/dev/null 2>&1; then warn "Dojo rebuild failed — keeping the existing image"
    else warn "Dojo could not be built (see log) — the rest of the stack runs without it"; fi
  fi
  spin "starting containers" compose up -d --remove-orphans
  # a profile service switched off later isn't an orphan to compose, so remove it by hand
  if [[ "${IPTV:-no}" != yes ]] && docker inspect dispatcharr >/dev/null 2>&1; then
    docker rm -f dispatcharr >/dev/null && info "Dispatcharr removed (IPTV is off; its data stays in appdata/dispatcharr)"
  fi
  # Caddy reads its config once: a new domain or Dojo address takes effect with a reload (no downtime)
  if [[ -n "${DOMAIN:-}" ]] && [[ "$(docker inspect -f '{{.State.Running}}' caddy 2>/dev/null)" == true ]]; then
    docker exec caddy caddy reload --config /etc/caddy/Caddyfile >>"$LOG" 2>&1 || warn "Caddy didn't take the new config — see log"
  fi
  local n; n=$(compose ps --format '{{.Name}}' | wc -l)
  ok "$n containers running"
}
