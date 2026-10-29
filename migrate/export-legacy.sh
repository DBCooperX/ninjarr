#!/usr/bin/env bash
# ninjarr — export an existing (pre-ninjarr) stack into one file that `./bootstrap.sh import` loads.
#
# Run it as root on the machine that can reach your old apps — on Proxmox, the host itself:
#
#   bash export-legacy.sh
#
# Copying Emby takes a while: run it inside tmux (or screen), so a dropped SSH session doesn't
# stop it halfway. If it is cut off anyway, every app it stopped is started again.
#
# It asks where each part lives. A location is one of
#   local          this machine
#   ct:110         a Proxmox container (through pct exec)
#   ssh:root@host  another machine over SSH (root, or a user with passwordless sudo)
#   skip           leave this part out
# and for the library a folder on top: local:/srv/library, ct:110:/library, ...
# The same answers can be given up front as AIO=… LIBRARY=… ARRS=… EMBY=… DISPATCHARR=…
# Containers are found by name or image (aiostreams, sonarr, …); if yours are called something
# else, name them: AIO_CONTAINER=… SONARR_CONTAINER=… RADARR_CONTAINER=… EMBY_CONTAINER=…
# DISPATCHARR_CONTAINER=…
#
# What it collects, each app stopped for the few seconds its data is copied (then started again):
#   AIOStreams   its database — your usenet library (the NZBs, not the video data; there is none)
#   library      the symlink library folder Sonarr/Radarr import into
#   Sonarr/Radarr the series and movie lists (read over their API; nothing stopped)
#   Emby         its whole data folder: users, passwords, watch state, settings, plugins, artwork
#   Dispatcharr  its whole data folder: accounts, channels, profiles, guide
# Nothing is changed on the old stack. The file contains logins (Emby, Dispatcharr, the IPTV
# account) — keep it private and delete it once the import is done.
set -Eeuo pipefail

OUT_DIR=${OUT_DIR:-/var/tmp}
STAMP=$(date +%Y%m%d-%H%M%S)
WORK="$OUT_DIR/ninjarr-migrate-$STAMP"
OUT="$WORK.tar"

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; D=$'\e[2m'; B=$'\e[1m'; X=$'\e[0m'; else G='' Y='' R='' D='' B='' X=''; fi
ok()   { printf '   %s✓%s %s\n' "$G" "$X" "$1"; }
info() { printf '   %s→%s %s\n' "$D" "$X" "$1"; }
warn() { printf '   %s!%s %s\n' "$Y" "$X" "$1"; }
die()  { printf '\n   %s✗ %s%s\n\n' "$R" "$1" "$X"; exit 1; }
ask()  { local v=$1 p=$2 d=${3:-} in; [[ -n "${!v:-}" ]] && return 0
         printf '   %s→%s %s %s[%s]%s ' "$D" "$X" "$p" "$D" "$d" "$X"; read -r in </dev/tty || true; printf -v "$v" '%s' "${in:-$d}"; }

[[ $EUID -eq 0 ]] || die "run this as root (pct and docker need it)"

# on LOCATION — runs the bash script on stdin there; its stdout comes back here
on() {
  case "$1" in
    local)  bash -s ;;
    ct:*)   command -v pct >/dev/null || die "ct:… needs Proxmox's pct — run this on the Proxmox host"
            pct exec "${1#ct:}" -- bash -s ;;
    ssh:*)  ssh -o ConnectTimeout=10 "${1#ssh:}" 'bash -s' ;;
    *)      die "unknown location '$1' — use local, ct:ID or ssh:user@host" ;;
  esac
}
# Prepended to every remote script: docker through sudo when not root, and container lookups
# shellcheck disable=SC2016  # runs on the other machine: it expands there, not here
REMOTE_LIB='
set -eo pipefail
S=""; [ "$(id -u)" = 0 ] || S="sudo -n"
dk() { $S docker "$@"; }
find_container() { # find_container PATTERN — the named one, else the first whose name or image matches
  local named; named=$(printf %s "$1" | tr a-z A-Z)_CONTAINER; named=${named/AIOSTREAMS/AIO}
  if [ -n "${!named:-}" ]; then echo "${!named}"; return; fi
  dk ps -a --format "{{.Names}} {{.Image}}" | awk -v p="$1" "tolower(\$0) ~ p {print \$1; exit}"
}
mount_of() { # mount_of CONTAINER DEST — the host folder bound to DEST
  dk inspect -f "{{range .Mounts}}{{if eq .Destination \"$2\"}}{{.Source}}{{end}}{{end}}" "$1"
}
'
remote() {
  { local v; for v in AIO_CONTAINER SONARR_CONTAINER RADARR_CONTAINER EMBY_CONTAINER DISPATCHARR_CONTAINER; do
      [ -n "${!v:-}" ] && printf "%s='%s'\n" "$v" "${!v}"; done
    printf '%s\n' "$REMOTE_LIB"; cat; } | on "$1"
}

printf '\n   %sninjarr — export your old stack%s\n\n' "$B" "$X"
info "where does each part live? local, ct:ID, ssh:user@host, or skip"
ask AIO          "AIOStreams (Docker)"            skip
ask LIBRARY      "symlink library folder (e.g. local:/srv/library)" skip
ask ARRS         "Sonarr and Radarr (Docker)"     skip
ask EMBY         "Emby (Docker or native)"        skip
ask DISPATCHARR  "Dispatcharr (Docker)"           skip
printf '\n'

mkdir -p "$WORK"; chmod 700 "$WORK"
trap 'rm -rf "$WORK"' EXIT; trap 'exit 1' HUP INT TERM
MANIFEST="$WORK/manifest.env"
{ echo "NINJARR_MIGRATE=1"; echo "CREATED='$(date -Is)'"; } >"$MANIFEST"
man() { printf "%s='%s'\n" "$1" "$2" >>"$MANIFEST"; }

# ─────────────────────────────────────── AIOStreams: the database holds the usenet library
if [[ "$AIO" != skip ]]; then
  info "AIOStreams: copying its database and NZBs (stopped for a few seconds)"
  remote "$AIO" >"$WORK/aiostreams.tar" <<'EOF'
c=$(find_container aiostreams); [ -n "$c" ] || { echo "no AIOStreams container found" >&2; exit 1; }
src=$(mount_of "$c" /app/data); [ -n "$src" ] || { echo "AIOStreams has no /app/data folder" >&2; exit 1; }
running=$(dk inspect -f '{{.State.Running}}' "$c")
[ "$running" = true ] && dk stop -t 30 "$c" >/dev/null
trap '[ "$running" = true ] && dk start "$c" >/dev/null' EXIT; trap 'exit 1' HUP INT TERM
# the database, plus the NZBs themselves: it keeps only their links in the database and the
# downloaded NZBs in its grab cache (uploaded ones in usenet-nzbs) — without them every file
# would have to be fetched again through the old Prowlarr
files=""; for f in db.sqlite db.sqlite-wal db.sqlite-shm cache/grab-nzb cache/grab-nzb.index.json usenet-nzbs; do $S test -e "$src/$f" && files="$files $f"; done
$S tar -C "$src" -cf - $files
EOF
  [[ -s "$WORK/aiostreams.tar" ]] || die "AIOStreams: nothing copied"
  # shellcheck disable=SC2016  # a command for the other machine
  man AIO_IMAGE "$(remote "$AIO" <<<'dk inspect -f "{{.Config.Image}}" "$(find_container aiostreams)"')"
  n=$(tar -tf "$WORK/aiostreams.tar" | grep -c '^\(\./\)\{0,1\}cache/grab-nzb/.\|^\(\./\)\{0,1\}usenet-nzbs/.' || true)
  ok "AIOStreams: database and $n cached NZB file(s) ($(du -h "$WORK/aiostreams.tar" | cut -f1))"
fi

# ─────────────────────────────────────── the symlink library
if [[ "$LIBRARY" != skip ]]; then
  loc=${LIBRARY%:*}; dir=${LIBRARY##*:}
  [[ "$LIBRARY" == local:* || "$LIBRARY" == ct:*:* || "$LIBRARY" == ssh:*:* ]] || die "library: give location and folder, e.g. local:/srv/library"
  info "library: copying $dir (symlinks only, it's small)"
  remote "$loc" >"$WORK/library.tar" <<EOF
\$S test -d "$dir" || { echo "no folder $dir" >&2; exit 1; }
\$S tar -C "$dir" -cf - .
EOF
  n=$(tar -tf "$WORK/library.tar" | grep -vc '/$' || true)
  ok "library: $n entries"
fi

# ─────────────────────────────────────── Sonarr / Radarr: their lists, over their own API
if [[ "$ARRS" != skip ]]; then
  for app in sonarr radarr; do
    what=series; [[ $app == radarr ]] && what=movie
    info "${app^}: reading the $what list"
    remote "$ARRS" >"$WORK/$app.json" <<EOF
c=\$(find_container $app); [ -n "\$c" ] || { echo "no ${app^} container found" >&2; exit 1; }
cfg=\$(dk exec "\$c" cat /config/config.xml)
key=\$(printf '%s' "\$cfg" | sed -n 's:.*<ApiKey>\(.*\)</ApiKey>.*:\1:p')
port=\$(printf '%s' "\$cfg" | sed -n 's:.*<Port>\(.*\)</Port>.*:\1:p')
base=\$(printf '%s' "\$cfg" | sed -n 's:.*<UrlBase>\(.*\)</UrlBase>.*:\1:p')
get() { dk exec "\$c" curl -fsS -H "X-Api-Key: \$key" "http://localhost:\$port\$base/api/v3/\$1"; }
printf '{"items":'; get $what; printf ',"roots":'; get rootfolder; printf ',"status":'; get system/status
# Sonarr: every series' episode files too — their original release name and languages, which a
# renamed file doesn't show (Radarr's movie list carries its files already)
if [ $app = sonarr ]; then
  printf ',"files":'
  dk exec -e K="\$key" -e U="http://localhost:\$port\$base/api/v3" "\$c" sh -c '
    command -v jq >/dev/null || { printf "[]"; exit 0; }
    printf "["; first=1
    for i in \$(curl -fsS -H "X-Api-Key: \$K" "\$U/series" | jq -r ".[].id"); do
      [ \$first = 1 ] || printf ","; first=0
      curl -fsS -H "X-Api-Key: \$K" "\$U/episodefile?seriesId=\$i" | jq -c "[.[] | {seriesId, relativePath, sceneName, releaseGroup, languages, quality}]"
    done; printf "]"'
fi
printf '}'
EOF
    [[ -s "$WORK/$app.json" ]] && ok "${app^}: list exported, with each file's release name and languages" || warn "${app^}: nothing exported"
  done
fi

# ─────────────────────────────────────── Emby: the whole data folder
if [[ "$EMBY" != skip ]]; then
  info "Emby: copying its data folder (stopped while copying — big libraries take a few minutes)"
  remote "$EMBY" >"$WORK/emby.tar" 2>"$WORK/emby.err" <<'EOF'
excl="--exclude=./cache --exclude=./logs --exclude=./transcoding-temp --exclude=./transcodingtemp"
if [ -d /var/lib/emby/data ] && command -v systemctl >/dev/null && systemctl cat emby-server >/dev/null 2>&1; then
  ver=$(dpkg-query -W -f '${Version}' emby-server 2>/dev/null || cat /var/lib/emby/data/lastversion.txt 2>/dev/null || echo unknown)
  echo "EMBY_KIND=native EMBY_ROOT=/var/lib/emby EMBY_VERSION=$ver" >&2
  $S systemctl stop emby-server
  trap '$S systemctl start emby-server' EXIT; trap 'exit 1' HUP INT TERM
  $S tar -C /var/lib/emby $excl -cf - .
else
  c=$(find_container emby); [ -n "$c" ] || { echo "no Emby found (neither the emby-server service nor a container)" >&2; exit 1; }
  src=$(mount_of "$c" /config)
  ver=$($S cat "$src/data/lastversion.txt" 2>/dev/null || dk inspect -f '{{.Config.Image}}' "$c")
  echo "EMBY_KIND=docker EMBY_ROOT=/config EMBY_VERSION=$ver" >&2
  running=$(dk inspect -f '{{.State.Running}}' "$c")
  [ "$running" = true ] && dk stop -t 30 "$c" >/dev/null
  trap '[ "$running" = true ] && dk start "$c" >/dev/null' EXIT; trap 'exit 1' HUP INT TERM
  $S tar -C "$src" $excl -cf - .
fi
EOF
  meta=$(grep -o 'EMBY_KIND=.*' "$WORK/emby.err" | tail -n 1 || true)
  [[ -n "$meta" ]] || { cat "$WORK/emby.err" >&2; die "Emby: export failed"; }
  for kv in $meta; do man "${kv%%=*}" "${kv#*=}"; done
  ok "Emby: data folder ($(du -h "$WORK/emby.tar" | cut -f1), ${meta##*EMBY_VERSION=})"
  rm -f "$WORK/emby.err"
fi

# ─────────────────────────────────────── Dispatcharr: the whole data folder
if [[ "$DISPATCHARR" != skip ]]; then
  info "Dispatcharr: copying its data folder (stopped for a moment)"
  remote "$DISPATCHARR" >"$WORK/dispatcharr.tar" 2>"$WORK/disp.err" <<'EOF'
c=$(find_container dispatcharr); [ -n "$c" ] || { echo "no Dispatcharr container found" >&2; exit 1; }
src=$(mount_of "$c" /data); [ -n "$src" ] || { echo "Dispatcharr has no /data folder" >&2; exit 1; }
echo "DISPATCHARR_IMAGE=$(dk inspect -f '{{.Config.Image}}' "$c") DISPATCHARR_PG=$($S cat "$src/db/PG_VERSION" 2>/dev/null || echo unknown)" >&2
running=$(dk inspect -f '{{.State.Running}}' "$c")
[ "$running" = true ] && dk stop -t 60 "$c" >/dev/null
trap '[ "$running" = true ] && dk start "$c" >/dev/null' EXIT; trap 'exit 1' HUP INT TERM
$S tar -C "$src" --exclude=./logs --exclude=./recordings --numeric-owner -cf - .
EOF
  meta=$(grep -o 'DISPATCHARR_IMAGE=.*' "$WORK/disp.err" | tail -n 1 || true)
  [[ -n "$meta" ]] || { cat "$WORK/disp.err" >&2; die "Dispatcharr: export failed"; }
  for kv in $meta; do man "${kv%%=*}" "${kv#*=}"; done
  ok "Dispatcharr: data folder ($(du -h "$WORK/dispatcharr.tar" | cut -f1))"
  rm -f "$WORK/disp.err"
fi

[[ -n "$(find "$WORK" -maxdepth 1 \( -name "*.tar" -o -name "*.json" \) -print -quit)" ]] || die "nothing to export — every part was skipped"
tar -C "$WORK" -cf "$OUT" .
chmod 600 "$OUT"
printf '\n'; ok "export ready: $OUT ($(du -h "$OUT" | cut -f1))"
printf '\n   Next, copy it to the ninjarr VM and import it there:\n'
printf '     scp %s ninjarr@<ninjarr-vm>:\n' "$OUT"
printf '     ssh ninjarr@<ninjarr-vm>\n'
printf '     cd /opt/ninjarr-src && sudo ./bootstrap.sh import ~/%s\n\n' "$(basename "$OUT")"
printf '   %sIt contains logins — delete it on both machines once the import is done.%s\n\n' "$D" "$X"
