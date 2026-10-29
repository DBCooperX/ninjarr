#!/usr/bin/env bash
# ninjarr — first boot of a VM made by create-vm.sh (runs once, from cloud-init).
# Waits for the network, installs what's needed, downloads ninjarr to /opt/ninjarr-src and, when
# create-vm.sh was given a ninjarr.env, builds the whole stack. Every step retries, because a
# fresh VM's network (DHCP, VLAN) is often not ready on the first try.
# Log: /var/log/ninjarr-firstboot.log
set -uo pipefail
exec >>/var/log/ninjarr-firstboot.log 2>&1
echo "=== $(date -Is) ninjarr first boot"

# shellcheck disable=SC1091
. /etc/ninjarr-firstboot.conf   # REPO, BRANCH, AUTO
DEST=/opt/ninjarr-src

fail() {
  echo "FAILED: $1"
  cat >/etc/motd <<EOF

  ninjarr: the first-boot setup failed — $1
  Details: sudo cat /var/log/ninjarr-firstboot.log
  By hand: sudo -i; apt-get update && apt-get install -y git
           git clone $REPO $DEST && cd $DEST && ./bootstrap.sh

EOF
  exit 1
}

retry() { # retry TRIES DELAY cmd... — until it works
  local n=$1 d=$2 i; shift 2
  for ((i = 1; i <= n; i++)); do
    "$@" && return 0
    echo "  attempt $i/$n failed: $*"; sleep "$d"
  done
  return 1
}

retry 60 5 getent hosts github.com >/dev/null || fail "no network — this VM can't resolve github.com (check its VLAN and DHCP)"
echo "network ok: $(hostname -I)"

export DEBIAN_FRONTEND=noninteractive
retry 10 15 sh -c 'apt-get update -q && apt-get install -y -q git curl jq qemu-guest-agent' || fail "installing git/curl/jq failed"
systemctl enable --now qemu-guest-agent || true

if ! git ls-remote --exit-code --heads "$REPO" "$BRANCH" >/dev/null 2>&1; then
  echo "branch '$BRANCH' not found in $REPO — using main"; BRANCH=main
fi
rm -rf "$DEST"
retry 10 15 git clone --branch "$BRANCH" "$REPO" "$DEST" || fail "downloading ninjarr from $REPO failed"
echo "ninjarr is in $DEST ($(git -C "$DEST" log --oneline -1))"

if [[ "$AUTO" == yes && -f /root/ninjarr.env ]]; then
  mv /root/ninjarr.env "$DEST/ninjarr.env"
  echo "building the stack — full output in /var/log/ninjarr-install.log"
  if (cd "$DEST" && NINJARR_UNATTENDED=1 NO_COLOR=1 ./bootstrap.sh >/var/log/ninjarr-install.log 2>&1); then
    printf '\n  ninjarr: the stack is built. Check it: sudo -i; cd %s && ./bootstrap.sh doctor\n\n' "$DEST" >/etc/motd
  else
    fail "the stack build stopped — see /var/log/ninjarr-install.log"
  fi
else
  printf '\n  ninjarr is ready: sudo -i; cd %s && ./bootstrap.sh\n\n' "$DEST" >/etc/motd
fi
echo "=== done"
