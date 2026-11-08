# shellcheck shell=bash
# ninjarr — an off-site copy of every backup on Google Drive (optional).
#
# Set up once with `sudo ./bootstrap.sh drive-setup`. After that each backup the `backup` command
# makes (nightly, and Dojo's "Back up now") is encrypted with DRIVE_PASSPHRASE (gpg, AES-256) and
# streamed into the folder DRIVE_FOLDER on Drive with rclone; the newest DRIVE_KEEP stay there.
# rclone only gets Google's "drive.file" access: the files it made itself, nothing else on the Drive.
# Its sign-in lives in .state/drive/rclone.conf, never in the repo. The upload never fails the
# backup itself: the local file is there either way, and .state/drive.json says how it went (Dojo).

DRIVE_REMOTE=ninjarr-drive
DRIVE_NAME_RE='^ninjarr-[0-9]{8}-[0-9]{6}\.tar\.gz(\.gpg)?$'
DRIVE_SCOPE_B64=eyJzY29wZSI6ImRyaXZlLmZpbGUifQ     # {"scope":"drive.file"}, for rclone authorize

drive_conf()   { printf '%s' "$ROOT/.state/drive/rclone.conf"; }
drive_folder() { printf '%s' "${DRIVE_FOLDER:-ninjarr-backups}"; }
drive_on()     { [[ "${DRIVE_BACKUP:-no}" == yes ]]; }
drive_keep()   { local k=${DRIVE_KEEP:-${BACKUP_KEEP:-7}}; [[ "$k" =~ ^[0-9]{1,3}$ ]] && (( k >= 1 )) || k=7; printf '%s' "$k"; }
drive_rclone() { rclone --config "$(drive_conf)" --log-file "${LOG:-/dev/null}" --log-level NOTICE "$@"; }

# need_tool COMMAND PACKAGE — installs PACKAGE with apt when COMMAND is missing
need_tool() {
  command -v "$1" >/dev/null && return 0
  command -v apt-get >/dev/null || die "$1 is missing — install $2 and run again"
  spin "installing $2" bash -c "apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $2"
}

# drive_gpg ARGS… — gpg with the passphrase from $GPG_PASS, in a throwaway keyring folder
drive_gpg() {
  local home rc=0
  home=$(mktemp -d); chmod 700 "$home"
  GNUPGHOME=$home gpg --batch --yes --quiet --no-symkey-cache --pinentry-mode loopback \
    --passphrase-fd 3 "$@" 3<<<"$GPG_PASS" || rc=$?
  GNUPGHOME=$home gpgconf --kill gpg-agent >/dev/null 2>&1 || true
  rm -rf "$home"
  return "$rc"
}

# drive_status ok|fail NAME MESSAGE — .state/drive.json for Dojo; keeps when the last good copy was
drive_status() {
  local f="$ROOT/.state/drive.json" prev='{}' files='[]'
  [[ -s "$f" ]] && prev=$(cat "$f" 2>/dev/null) && jq -e . >/dev/null 2>&1 <<<"$prev" || prev='{}'
  [[ "$1" == ok ]] && files=$(drive_list | jq -Rsc 'split("\n") | map(select(length > 0))')
  mkdir -p "$ROOT/.state"
  jq -n --argjson prev "$prev" --arg st "$1" --arg name "$2" --arg msg "$3" --argjson files "$files" \
        --argjson at "$(date +%s)" --arg folder "$(drive_folder)" --argjson keep "$(drive_keep)" '
    {ok: ($st == "ok"), at: $at, name: $name, message: $msg, folder: $folder, keep: $keep,
     last_ok: (if $st == "ok" then $at else $prev.last_ok end),
     last_ok_name: (if $st == "ok" then $name else $prev.last_ok_name end),
     files: (if $st == "ok" then $files else ($prev.files // []) end)}' >"$f.tmp" && mv "$f.tmp" "$f"
}

# drive_list — ninjarr's backups in the Drive folder, newest first (names carry the time)
drive_list() {
  drive_rclone lsf --files-only "$DRIVE_REMOTE:$(drive_folder)" 2>/dev/null | grep -E "$DRIVE_NAME_RE" | sort -r
}

# drive_prune N — keeps the newest N there. Deleted for good, not into Drive's bin, where they
# would go on counting against the storage for 30 days.
drive_prune() {
  local n=$1 old
  (( n >= 1 )) || n=1
  while IFS= read -r old; do
    [[ "$old" =~ $DRIVE_NAME_RE ]] || continue
    drive_rclone deletefile --drive-use-trash=false "$DRIVE_REMOTE:$(drive_folder)/$old" || true
  done < <(drive_list | tail -n +"$((n + 1))")
}

drive_fail() { drive_status fail "$1" "$2"; warn "Google Drive: $2"; }

# drive_upload FILE — the copy of one backup on Drive; 1 when it didn't work (the reason is noted)
drive_upload() {
  local file=$1 name keep remote rc=0
  drive_on || return 0
  name=$(basename "$file")
  command -v rclone >/dev/null || { drive_fail "$name" "rclone is missing — run sudo ./bootstrap.sh drive-setup"; return 1; }
  [[ -s "$(drive_conf)" ]] || { drive_fail "$name" "not connected — run sudo ./bootstrap.sh drive-setup"; return 1; }
  keep=$(drive_keep); remote="$DRIVE_REMOTE:$(drive_folder)"
  drive_prune "$((keep - 1))"          # room first, as on this disk
  if [[ "${DRIVE_ENCRYPT:-yes}" != no ]]; then
    command -v gpg >/dev/null || { drive_fail "$name" "gpg is missing — run sudo ./bootstrap.sh drive-setup"; return 1; }
    [[ -n "${DRIVE_PASSPHRASE:-}" ]] || { drive_fail "$name" "DRIVE_PASSPHRASE is empty in ninjarr.env — run sudo ./bootstrap.sh drive-setup"; return 1; }
    name+=.gpg
    # streamed: encrypted on the way out, no second copy on this disk
    GPG_PASS=$DRIVE_PASSPHRASE drive_gpg --symmetric --cipher-algo AES256 --compress-algo none -o - "$file" 2>>"${LOG:-/dev/null}" \
      | drive_rclone rcat "$remote/$name" || rc=1
  else
    drive_rclone copyto "$file" "$remote/$name" || rc=1
  fi
  (( rc == 0 )) && drive_list | grep -qx "$name" \
    || { drive_fail "$name" "uploading $name failed — the backup itself is fine, on this machine. Details: ${LOG:-the log}"; return 1; }
  drive_prune "$keep"
  drive_status ok "$name" ""
  ok "copied to Google Drive as $(drive_folder)/$name ($(drive_list | wc -l) there)"
}

# drive_decrypt FILE.gpg OUT — a backup from Drive back into a .tar.gz. Tries the passphrase in
# ninjarr.env, then asks (a fresh VM has none).
drive_decrypt() {  # drive_decrypt IN OUT [NAME to show]
  local in=$1 out=$2 pass=${DRIVE_PASSPHRASE:-} label=${3:-$(basename "$1")}
  need_tool gpg gnupg
  [[ -z "$pass" && -f "$ENV_FILE" ]] && pass=$(env_parse "$ENV_FILE" 2>/dev/null | awk -F'\t' '$1 == "DRIVE_PASSPHRASE" {print $2}')
  # typed into Dojo's first-run setup (restore from Google Drive): used once, then gone
  local typed="$ROOT/.state/dojo/drive-pass"
  if [[ -f "$typed" && ! -L "$typed" ]]; then pass=$(head -c 300 "$typed" | head -n 1); rm -f "$typed"
    ( umask 077; GPG_PASS=$pass drive_gpg --decrypt -o "$out" "$in" 2>>"$LOG" ) && { ok "decrypted $label"; return 0; }
    rm -f "$out"; die "that passphrase doesn't open $label — try again"
  fi
  if [[ -n "$pass" ]] && ( umask 077; GPG_PASS=$pass drive_gpg --decrypt -o "$out" "$in" 2>>"$LOG" ); then return 0; fi
  { : </dev/tty; } 2>/dev/null || { rm -f "$out"; die "couldn't decrypt $label: run the restore in a terminal, it asks for the passphrase"; }
  read -rsp "   Passphrase for the Google Drive backups: " pass </dev/tty; printf '\n'
  ( umask 077; GPG_PASS=$pass drive_gpg --decrypt -o "$out" "$in" 2>>"$LOG" ) \
    || { rm -f "$out"; die "couldn't decrypt $label — wrong passphrase?"; }
  ok "decrypted $label"
}

# drive-setup [TOKEN] — connects Google Drive, once. Without TOKEN, rclone shows a sign-in link
# that opens in the browser of the PC this SSH session comes from, through the tunnel below.
# TOKEN is the JSON `rclone authorize "drive" "eyJzY29wZSI6ImRyaXZlLmZpbGUifQ"` prints on a PC.
drive_setup() {
  local token=${1:-} conf tmp newest
  conf=$(drive_conf)
  step "Google Drive for the backups"
  need_tool rclone rclone
  need_tool gpg gnupg
  mkdir -p "$(dirname "$conf")"; chmod 700 "$(dirname "$conf")"
  tmp=$(mktemp "$conf.XXXX")
  if [[ -n "$token" ]]; then
    jq -e '.access_token and .refresh_token' >/dev/null 2>&1 <<<"$token" \
      || die "that's not the token rclone authorize prints (JSON with access_token and refresh_token)"
    printf '[%s]\ntype = drive\nscope = drive.file\ntoken = %s\n' "$DRIVE_REMOTE" "$(jq -c . <<<"$token")" >"$tmp"
  else
    printf '\n   Sign-in goes through your PC'"'"'s browser. Connect to this VM like this first:\n\n'
    printf '     %sssh -L 53682:127.0.0.1:53682 %s@%s%s\n\n' "$B" "${SUDO_USER:-you}" "$(host_ip)" "$X"
    printf '   then run %ssudo ./bootstrap.sh drive-setup%s in that session and open the link below.\n' "$B" "$X"
    printf '   (No SSH? Run %srclone authorize "drive" "%s"%s on a PC with\n' "$B" "$DRIVE_SCOPE_B64" "$X"
    printf '   rclone and pass what it prints: sudo ./bootstrap.sh drive-setup '"'"'<that>'"'"')\n\n'
    rm -f "$tmp"
    rclone --config "$tmp" config create "$DRIVE_REMOTE" drive scope=drive.file >/dev/null || true
    grep -q '^token = ' "$tmp" 2>/dev/null || { rm -f "$tmp"; die "the sign-in didn't finish — nothing changed"; }
  fi
  chmod 600 "$tmp"; mv "$tmp" "$conf"
  drive_rclone mkdir "$DRIVE_REMOTE:$(drive_folder)" && drive_rclone lsf "$DRIVE_REMOTE:$(drive_folder)" >/dev/null \
    || die "connected, but Google Drive doesn't answer — see $LOG"
  ok "connected to Google Drive"
  # a fresh VM in Dojo's first-run setup connects only to restore from Drive: the backup brings
  # its own settings, passphrase included
  if needs_setup; then
    drive_status ok "" ""
    ok "$(drive_list | wc -l) ninjarr backups in the folder $(drive_folder) — pick one in Dojo"
    return 0
  fi
  info "backups go into the folder $(drive_folder) there"

  env_load
  env_set DRIVE_BACKUP yes
  env_default DRIVE_ENCRYPT yes
  local fresh=0
  if [[ "$DRIVE_ENCRYPT" != no && -z "${DRIVE_PASSPHRASE:-}" ]]; then
    env_set DRIVE_PASSPHRASE "$(openssl rand -base64 30 | tr -d '/+=' | cut -c1-32)"; fresh=1
  fi
  env_save
  if (( fresh )); then
    printf '\n   %sThe passphrase for the backups on Drive — save it in your password manager now:%s\n\n' "$Y" "$X"
    printf '     %s%s%s\n\n' "$B" "$DRIVE_PASSPHRASE" "$X"
    printf '   Without it the copies on Drive can'"'"'t be opened. It'"'"'s in ninjarr.env too, but that\n'
    printf '   file is gone with this VM. Restore with: ./bootstrap.sh restore ninjarr-<date>.tar.gz.gpg\n\n'
  fi

  # the newest backup there is goes up right away, so you see it work
  # shellcheck disable=SC2012  # ninjarr's own names, nothing ls could mangle
  newest=$(ls -1t "$(backup_dir)"/ninjarr-*.tar.gz 2>/dev/null | head -n 1) || true
  if [[ -n "$newest" ]]; then drive_upload "$newest" || true
  else info "no backup yet — the next one (tonight, or Dojo → System → Back up now) goes to Drive too"; fi
}

# ─────────────────────────────────────────────── the same from Dojo
# Dojo can't open a browser on this VM, and Google only sends the sign-in back to 127.0.0.1. So
# drive-connect starts `rclone authorize` here (its own systemd unit, so it outlives the job) and
# notes Google's sign-in link in .state/drive/auth.json. After signing in, the browser lands on
# http://127.0.0.1:53682/?state=…&code=…, which doesn't load on the PC; you paste that address into
# Dojo, Dojo leaves the code in .state/dojo/drive-code, and drive-finish hands it to the waiting
# rclone here, which turns it into the sign-in rclone keeps.

drive_auth_running() { pgrep -f "rclone authorize drive $DRIVE_SCOPE_B64" >/dev/null 2>&1; }
drive_auth_stop() {
  systemctl stop ninjarr-drive-auth >/dev/null 2>&1 || true
  pkill -f "rclone authorize drive $DRIVE_SCOPE_B64" >/dev/null 2>&1 || true
  rm -f "$ROOT/.state/drive/auth.json"
}

drive_connect() {
  local d="$ROOT/.state/drive" out url google
  need_tool rclone rclone
  need_tool gpg gnupg
  mkdir -p "$d"; chmod 700 "$d"
  drive_auth_stop
  out="$d/authorize.out"; : >"$out"; chmod 600 "$out"
  # 15 minutes to sign in, then it's given up
  local cmd="exec timeout 900 rclone authorize drive $DRIVE_SCOPE_B64 --auth-no-open-browser >'$out' 2>&1"
  if command -v systemd-run >/dev/null && [[ -d /run/systemd/system ]]; then
    systemd-run --quiet --collect --unit=ninjarr-drive-auth bash -c "$cmd" || die "couldn't start rclone's sign-in"
  else
    setsid nohup bash -c "$cmd" >/dev/null 2>&1 &
  fi
  for _ in {1..30}; do
    url=$(grep -o 'http://127\.0\.0\.1:53682/auth?state=[A-Za-z0-9_-]*' "$out" 2>/dev/null | head -n 1) || true
    [[ -n "$url" ]] && break; sleep 0.5
  done
  [[ -n "$url" ]] || { cat "$out" >>"$LOG"; drive_auth_stop; die "rclone didn't start its sign-in — see $LOG"; }
  # rclone's own link only forwards to Google; Dojo shows Google's, which opens from any PC
  google=$(curl -s -o /dev/null --max-time 10 -w '%{redirect_url}' "$url") || true
  [[ "$google" == https://accounts.google.com/* ]] || { drive_auth_stop; die "rclone's sign-in didn't point to Google"; }
  jq -n --arg url "$google" --arg state "${url##*state=}" --argjson at "$(date +%s)" \
    '{url: $url, state: $state, at: $at}' >"$d/auth.json.tmp" && mv "$d/auth.json.tmp" "$d/auth.json"
  ok "Google's sign-in is ready: Dojo → System shows the link"
}

drive_finish() {
  local d="$ROOT/.state/drive" f="$ROOT/.state/dojo/drive-code" code state token
  [[ -f "$f" && ! -L "$f" ]] || die "Dojo didn't pass on a sign-in"
  code=$(head -c 600 "$f" | head -n 1); rm -f "$f"
  [[ "$code" =~ ^[A-Za-z0-9/_.-]{10,512}$ ]] || die "that isn't the code Google gives"
  state=$(jq -r '.state // empty' "$d/auth.json" 2>/dev/null) || true
  [[ "$state" =~ ^[A-Za-z0-9_-]{8,64}$ ]] && drive_auth_running \
    || { drive_auth_stop; die "the sign-in had run out (15 minutes) — press Connect again"; }
  curl -s -o /dev/null --max-time 30 -G "http://127.0.0.1:53682/" --data-urlencode "state=$state" --data-urlencode "code=$code" \
    || { drive_auth_stop; die "couldn't hand the sign-in to rclone — press Connect again"; }
  for _ in {1..60}; do drive_auth_running || break; sleep 0.5; done
  token=$(grep -m 1 '^{.*"access_token"' "$d/authorize.out" 2>/dev/null) || true
  if [[ -z "$token" ]]; then
    grep -i 'error' "$d/authorize.out" 2>/dev/null | tail -n 2 | tee -a "$LOG" || true
    drive_auth_stop; : >"$d/authorize.out"
    die "Google didn't accept the sign-in — press Connect and try again"
  fi
  drive_auth_stop; : >"$d/authorize.out"
  drive_setup "$token"
}

# drive-off — no more copies; what's on Drive stays there, the passphrase stays in ninjarr.env
drive_off() {
  drive_auth_stop
  rm -f "$(drive_conf)" "$ROOT/.state/drive.json"
  env_set DRIVE_BACKUP no; env_save
  ok "Google Drive disconnected — the copies already there stay, and so does the passphrase in ninjarr.env"
}

# drive_fetch NAME — one of the copies on Drive back into the backup folder, decrypted, as the
# backup it was (DRIVE_FETCHED is its path); restore takes it from there
drive_fetch() {
  local name=$1 dir out dl
  [[ "$name" =~ $DRIVE_NAME_RE ]] || die "not a ninjarr backup name: $name"
  [[ -s "$(drive_conf)" ]] || die "Google Drive isn't connected"
  dir=$(backup_dir); mkdir -p "$dir"; chmod 700 "$dir"
  out="$dir/${name%.gpg}"
  # shellcheck disable=SC2034  # read by bootstrap.sh
  DRIVE_FETCHED=$out
  [[ -f "$out" ]] && { ok "$(basename "$out") is still on this machine — using that"; return 0; }
  dl=$(mktemp "$dir/.ninjarr-restore-XXXX")
  spin "downloading $name from Google Drive" drive_rclone copyto "$DRIVE_REMOTE:$(drive_folder)/$name" "$dl" \
    || { rm -f "$dl"; die "downloading $name from Google Drive failed — see $LOG"; }
  if [[ "$name" == *.gpg ]]; then
    ( drive_decrypt "$dl" "$out.part" "$name" ) || { rm -f "$dl" "$out.part"; exit 1; }   # it said why
    rm -f "$dl"
  else mv "$dl" "$out.part"; fi
  chmod 600 "$out.part"; mv "$out.part" "$out"
}
