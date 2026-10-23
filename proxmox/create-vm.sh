#!/usr/bin/env bash
# ninjarr — create a ready-to-go Debian 13 VM on a Proxmox VE host.
#
# Run this ON THE PROXMOX HOST (as root). It downloads Debian's official cloud image, creates a
# VM with cloud-init, and on first boot the VM clones ninjarr. With --env, the VM also runs
# bootstrap.sh unattended with that ninjarr.env — a complete rebuild in one command.
#
#   ./create-vm.sh                          VM with ninjarr cloned; SSH in and run ./bootstrap.sh
#   ./create-vm.sh --env ninjarr.env        VM that builds the whole stack by itself
#
# Options (all optional):
#   --id N            VM id (default: next free)          --name NAME     (default: ninjarr)
#   --storage NAME    disk storage (default: local-lvm)   --bridge NAME   (default: vmbr0)
#   --cores N         (default: 4)                        --memory MB     (default: 6144)
#   --disk SIZE       (default: 40G)                      --ssh-key FILE  (default: /root/.ssh/authorized_keys)
#   --env FILE        a ninjarr.env to build from         --branch NAME   (default: main)
#   --ip CIDR,GW      static address, e.g. 192.168.1.20/24,192.168.1.1 (default: DHCP)
set -Eeuo pipefail

REPO="https://github.com/DBCooperX/ninjarr.git"
IMG_URL="https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2"
IMG="/var/lib/vz/template/cache/debian-13-genericcloud-amd64.qcow2"

ID=""; NAME=ninjarr; STORAGE=local-lvm; BRIDGE=vmbr0; CORES=4; MEMORY=6144; DISK=40G
SSH_KEY=/root/.ssh/authorized_keys; ENV_FILE=""; BRANCH=main; IPCFG="ip=dhcp"

die()  { printf '\n  \033[31m✖ %s\033[0m\n\n' "$1"; exit 1; }
ok()   { printf '  \033[32m✔\033[0m %s\n' "$1"; }
info() { printf '  ▸ %s\n' "$1"; }

while (( $# )); do
  case $1 in
    --id) ID=$2; shift ;;            --name) NAME=$2; shift ;;
    --storage) STORAGE=$2; shift ;;  --bridge) BRIDGE=$2; shift ;;
    --cores) CORES=$2; shift ;;      --memory) MEMORY=$2; shift ;;
    --disk) DISK=$2; shift ;;        --ssh-key) SSH_KEY=$2; shift ;;
    --env) ENV_FILE=$2; shift ;;     --branch) BRANCH=$2; shift ;;
    --ip) IPCFG="ip=${2%%,*},gw=${2#*,}"; shift ;;
    -h|--help) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option $1 (see --help)" ;;
  esac
  shift
done

command -v qm >/dev/null || die "run this on a Proxmox VE host (qm not found)"
[[ $EUID -eq 0 ]] || die "run as root"
[[ -f "$SSH_KEY" ]] || die "no SSH public key at $SSH_KEY — pass --ssh-key with your public key file"
[[ -z "$ENV_FILE" || -f "$ENV_FILE" ]] || die "no such file: $ENV_FILE"
[[ -n "$ID" ]] || ID=$(pvesh get /cluster/nextid)
qm status "$ID" >/dev/null 2>&1 && die "VM $ID already exists"

# cloud image
if [[ ! -f "$IMG" ]]; then
  info "downloading Debian 13 cloud image"
  curl -fL --progress-bar -o "$IMG.part" "$IMG_URL" && mv "$IMG.part" "$IMG"
fi
ok "Debian 13 cloud image"

# The first-boot script travels as cloud-init vendor data, which needs a storage that holds
# snippets. Proxmox's own "local" storage does once snippets are allowed on it.
SNIPPET_STORE=$(pvesm status --content snippets 2>/dev/null | awk 'NR>1 {print $1; exit}')
if [[ -z "$SNIPPET_STORE" ]]; then
  current=$(pvesh get /storage/local --output-format json | sed -n 's/.*"content":"\([^"]*\)".*/\1/p')
  pvesm set local --content "${current:+$current,}snippets"
  SNIPPET_STORE=local
  info "allowed snippets on storage 'local'"
fi
SNIPPET_DIR=$(pvesh get "/storage/$SNIPPET_STORE" --output-format json | sed -n 's/.*"path":"\([^"]*\)".*/\1/p')/snippets
mkdir -p "$SNIPPET_DIR"
SNIPPET="ninjarr-$ID.yaml"

# Everything after boot happens in proxmox/firstboot.sh, which retries until the network is up.
# cloud-init only drops it (and your ninjarr.env) on the disk and starts it.
HERE=$(cd "$(dirname "$0")" && pwd)
FIRSTBOOT="$HERE/firstboot.sh"
if [[ ! -f "$FIRSTBOOT" ]]; then   # create-vm.sh was downloaded on its own
  curl -fsSL "https://raw.githubusercontent.com/DBCooperX/ninjarr/$BRANCH/proxmox/firstboot.sh" -o /tmp/ninjarr-firstboot.sh \
    || curl -fsSL "https://raw.githubusercontent.com/DBCooperX/ninjarr/main/proxmox/firstboot.sh" -o /tmp/ninjarr-firstboot.sh \
    || die "could not fetch firstboot.sh — download the whole repo instead"
  FIRSTBOOT=/tmp/ninjarr-firstboot.sh
fi
AUTO=no; [[ -n "$ENV_FILE" ]] && AUTO=yes
{
  cat <<EOF
#cloud-config
write_files:
  - path: /usr/local/sbin/ninjarr-firstboot
    permissions: '0755'
    encoding: b64
    content: $(base64 -w0 "$FIRSTBOOT")
  - path: /etc/ninjarr-firstboot.conf
    permissions: '0644'
    content: |
      REPO=$REPO
      BRANCH=$BRANCH
      AUTO=$AUTO
EOF
  if [[ -n "$ENV_FILE" ]]; then
    cat <<EOF
  - path: /root/ninjarr.env
    permissions: '0600'
    encoding: b64
    content: $(base64 -w0 "$ENV_FILE")
EOF
  fi
  cat <<'EOF'
runcmd:
  - [/usr/local/sbin/ninjarr-firstboot]
EOF
} >"$SNIPPET_DIR/$SNIPPET"
chmod 600 "$SNIPPET_DIR/$SNIPPET"
ok "first-boot script ($SNIPPET_STORE:snippets/$SNIPPET)"

qm create "$ID" --name "$NAME" --ostype l26 --cpu host --cores "$CORES" --memory "$MEMORY" \
  --net0 "virtio,bridge=$BRIDGE" --scsihw virtio-scsi-single --agent enabled=1 \
  --serial0 socket --vga serial0 >/dev/null
qm set "$ID" --scsi0 "$STORAGE:0,import-from=$IMG,discard=on,ssd=1" >/dev/null
qm resize "$ID" scsi0 "$DISK" >/dev/null
qm set "$ID" --ide2 "$STORAGE:cloudinit" --boot order=scsi0 \
  --ciuser ninjarr --sshkeys "$SSH_KEY" --ipconfig0 "$IPCFG" \
  --cicustom "vendor=$SNIPPET_STORE:snippets/$SNIPPET" >/dev/null
ok "VM $ID ($NAME): $CORES cores, $((MEMORY / 1024)) GB RAM, $DISK disk"

qm start "$ID"
ok "started"

cat <<EOF

  Log in:   ssh ninjarr@<vm address>     (the address shows in Proxmox under VM $ID → Summary
                                          once the guest agent is up, after a minute or two)
EOF
if [[ -n "$ENV_FILE" ]]; then
  cat <<EOF
  The VM now installs Docker and builds the whole stack by itself (5–15 minutes).
  Follow it:   ssh ninjarr@<vm address> sudo tail -f /var/log/ninjarr-firstboot.log /var/log/ninjarr-install.log

EOF
else
  cat <<EOF
  Then:     sudo -i
            cd /opt/ninjarr-src && ./bootstrap.sh

EOF
fi
