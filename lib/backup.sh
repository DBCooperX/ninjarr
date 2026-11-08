# shellcheck shell=bash
# ninjarr — backup and restore. A backup is one .tar.gz with ninjarr.env and the apps' own data,
# without logs, caches and anything the apps rebuild by themselves. Restoring it on a fresh VM
# gives the same stack with the same library, history and settings.

# Left out of a backup: rebuilt on their own, or only noise
BACKUP_EXCLUDES=(
  './*/logs' './*/log' './*/cache' './*/Backups' './*/logs.db*' './*/MediaCover'
  './emby/transcoding-temp' './emby/metadata' './dispatcharr/backups' './dispatcharr/recordings'
  './dojo/art' '*.pid' './*.before-import-*'
)

backup_dir() { printf '%s' "${BACKUP_DIR:-$NINJARR_DATA/backups}"; }

# backup_prune DIR N — keeps the newest N of ninjarr's backups in DIR, deletes the rest
backup_prune() {
  local dir=$1 n=$2 old
  (( n >= 1 )) || n=1
  # names are ninjarr-<date>-<time>.tar.gz (nothing ls could mangle), newest first
  # shellcheck disable=SC2012
  while IFS= read -r old; do rm -f "$old"; done < <(ls -1t "$dir"/ninjarr-*.tar.gz 2>/dev/null | tail -n +"$((n + 1))")
}

# copy_tree SRC DST [tar options] — copies a folder the apps are still writing into. GNU tar
# exits 1 when a file changed while it was read (AIOStreams' db.sqlite-wal does, all the time);
# that is no failure here: the SQLite databases are copied again through SQLite afterwards.
# Only a real error (2) or a failing unpack counts.
copy_tree() {
  local src=$1 dst=$2 s; shift 2
  tar -C "$src" "$@" --warning=no-file-changed -cf - . 2>>"$LOG" | tar -C "$dst" -xf - 2>>"$LOG" && return 0 \
    || s=("${PIPESTATUS[@]}")
  (( s[0] <= 1 && s[1] == 0 ))
}

# backup [quiet] — writes <backup dir>/ninjarr-<date>.tar.gz and prints its path
backup() {
  local quiet=${1:-} dir stage out db rel dispatcharr_was_up=0 n x keep=${BACKUP_KEEP:-7}
  [[ -d "$NINJARR_DATA/appdata" ]] || die "nothing to back up: $NINJARR_DATA/appdata doesn't exist"
  command -v sqlite3 >/dev/null || die "sqlite3 is missing — run ./bootstrap.sh once, it installs it"
  dir=$(backup_dir); mkdir -p "$dir"; chmod 700 "$dir"
  rm -rf "$dir"/.staging.* "$dir"/ninjarr-*.tar.gz.part "$dir"/.ninjarr-restore-*   # leftovers of an interrupted run
  # Make room first: the oldest go before the new one is written, not after. Deleting only
  # afterwards needs space for one backup more than BACKUP_KEEP (plus the staging copy), so on
  # a disk sized for BACKUP_KEEP the next backup failed for lack of space — and as it stopped
  # there, the old ones were never deleted and every night failed the same way.
  backup_prune "$dir" "$((keep - 1))"
  stage=$(mktemp -d "$dir/.staging.XXXX")
  mkdir -p "$stage/appdata" "$stage/library"

  # Dispatcharr keeps a PostgreSQL database, which can only be copied while it's stopped.
  # That interrupts live TV for the few seconds the copy takes; everything else keeps running.
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx dispatcharr; then
    docker stop dispatcharr >/dev/null && dispatcharr_was_up=1
  fi
  local -a ex=(); for x in "${BACKUP_EXCLUDES[@]}"; do ex+=(--exclude="$x"); done
  if ! copy_tree "$NINJARR_DATA/appdata" "$stage/appdata" "${ex[@]}"; then
    (( dispatcharr_was_up )) && docker start dispatcharr >/dev/null
    die "copying the app data failed — see $LOG"
  fi
  (( dispatcharr_was_up )) && docker start dispatcharr >/dev/null
  # the library is only symlinks into AIOStreams — tiny, but the arrs need every one of them
  if [[ -d "$NINJARR_DATA/library" ]] && ! copy_tree "$NINJARR_DATA/library" "$stage/library"; then
    rm -rf "$stage"; die "copying the library failed — see $LOG"
  fi

  # SQLite databases are copied again through SQLite itself, so a database that was being written
  # during the copy above still ends up consistent
  n=0
  while IFS= read -r -d '' db; do
    rel=${db#"$NINJARR_DATA/appdata/"}
    [[ -f "$stage/appdata/$rel" ]] || continue
    if sqlite3 "$db" ".timeout 10000" ".backup '$stage/appdata/$rel.tmp'" 2>>"$LOG"; then
      chown --reference="$db" "$stage/appdata/$rel.tmp"; chmod --reference="$db" "$stage/appdata/$rel.tmp"
      mv "$stage/appdata/$rel.tmp" "$stage/appdata/$rel"
      rm -f "$stage/appdata/$rel-wal" "$stage/appdata/$rel-shm"
      n=$((n+1))
    else
      warn "could not copy the database $rel cleanly — it's in the backup as it was on disk"
    fi
  done < <(find "$NINJARR_DATA/appdata" -type f \( -name '*.db' -o -name '*.sqlite' -o -name '*.sqlite3' \) \
             -not -name 'logs.db' -not -path '*/dispatcharr/*' -print0)

  cp -p "$ENV_FILE" "$stage/ninjarr.env"
  docker compose version >/dev/null 2>&1 && compose config --images 2>/dev/null | sort >"$stage/images.txt" || true
  printf '%s\n' "$NINJARR_VERSION" >"$stage/ninjarr-version"

  out="$dir/ninjarr-$(date +%Y%m%d-%H%M%S).tar.gz"
  if ! { tar -C "$stage" -czf "$out.part" . && mv "$out.part" "$out"; }; then
    rm -rf "$out.part" "$stage"; die "writing the backup failed — disk full?"
  fi
  rm -rf "$stage"
  chmod 600 "$out"

  backup_prune "$dir" "$keep"   # keep the newest BACKUP_KEEP

  [[ "$quiet" == quiet ]] || ok "backup $(basename "$out") ($(du -h "$out" | cut -f1), $n databases) in $dir"
  mkdir -p "$ROOT/.state"; printf '%s' "$out" >"$ROOT/.state/last-backup"
}

# restore FILE — puts a backup's ninjarr.env and app data in place; the caller then builds as usual
restore() {
  local file=$1 tmp ts orig=$1 dec=""
  step "Restoring the backup"
  [[ -f "$file" ]] || die "no such backup: $file"
  # one from Google Drive (lib/drive.sh) is encrypted: unpacked from a decrypted copy next to it
  if [[ "$file" == *.gpg ]]; then
    dec=$(mktemp "$(dirname "$file")/.ninjarr-restore-XXXX")
    drive_decrypt "$file" "$dec"; file=$dec
  fi
  tar -tzf "$file" ./ninjarr.env >/dev/null 2>&1 || { rm -f "$dec"; die "$orig isn't a ninjarr backup (no ninjarr.env inside)"; }
  ts=$(date +%Y%m%d-%H%M%S)
  tmp=$(mktemp -d)
  tar -C "$tmp" -xzf "$file" ./ninjarr.env ./ninjarr-version 2>/dev/null || tar -C "$tmp" -xzf "$file" ./ninjarr.env

  if [[ -f "$ENV_FILE" ]] && ! cmp -s <(grep -v '^#' "$ENV_FILE") <(grep -v '^#' "$tmp/ninjarr.env"); then
    cp -p "$ENV_FILE" "$ENV_FILE.before-restore-$ts"
    info "your current ninjarr.env is kept as $(basename "$ENV_FILE").before-restore-$ts"
  fi
  cp "$tmp/ninjarr.env" "$ENV_FILE"; chmod 600 "$ENV_FILE"
  env_load
  ok "ninjarr.env from the backup (data folder $NINJARR_DATA)"
  [[ -f "$tmp/ninjarr-version" && "$(cat "$tmp/ninjarr-version")" != "$NINJARR_VERSION" ]] && \
    info "backup made with ninjarr $(cat "$tmp/ninjarr-version"), this is $NINJARR_VERSION — fine as long as this one isn't older"
  rm -rf "$tmp"

  # a running stack must not write into the data while it's replaced
  if command -v docker >/dev/null && docker ps -a --format '{{.Names}}' | grep -qxE 'sonarr|radarr|emby|aiostreams|dispatcharr'; then
    spin "stopping the running stack" compose --profile iptv --profile proxy down
  fi
  local d kept=0
  for d in appdata library; do
    if [[ -d "$NINJARR_DATA/$d" ]] && [[ -n "$(ls -A "$NINJARR_DATA/$d" 2>/dev/null)" ]]; then
      mv "$NINJARR_DATA/$d" "$NINJARR_DATA/$d.before-restore-$ts"; kept=1
    fi
  done
  (( kept )) && info "the current data is kept as appdata/library.before-restore-$ts — delete it once all is well"
  mkdir -p "$NINJARR_DATA"
  tar -C "$NINJARR_DATA" -xzf "$file" ./appdata ./library 2>>"$LOG" || tar -C "$NINJARR_DATA" -xzf "$file" ./appdata \
    || { rm -f "$dec"; die "unpacking the backup failed — see $LOG"; }
  rm -f "$dec"
  ok "app data restored from $(basename "$orig")"
}

# Nightly backup at about 04:30, as a systemd timer (BACKUP_SCHEDULE='off' to skip)
install_backup_timer() {
  command -v systemctl >/dev/null && [[ -d /run/systemd/system ]] || return 0
  if [[ "${BACKUP_SCHEDULE:-daily}" == off ]]; then
    systemctl disable --now ninjarr-backup.timer >/dev/null 2>&1 || true
    return 0
  fi
  cat >/etc/systemd/system/ninjarr-backup.service <<EOF
[Unit]
Description=ninjarr nightly backup
After=docker.service

[Service]
Type=oneshot
ExecStart=$ROOT/bootstrap.sh backup
EOF
  cat >/etc/systemd/system/ninjarr-backup.timer <<EOF
[Unit]
Description=ninjarr nightly backup

[Timer]
OnCalendar=*-*-* 04:30
RandomizedDelaySec=20m
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload && systemctl enable --now ninjarr-backup.timer >/dev/null 2>&1 \
    && ok "nightly backup at ~04:30 into $(backup_dir), keeping ${BACKUP_KEEP:-7}" \
    || warn "could not set up the nightly backup timer"
}
