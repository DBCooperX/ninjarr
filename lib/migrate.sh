# shellcheck shell=bash
# ninjarr — one-off import of an older stack, from the file migrate/export-legacy.sh makes.
#
#   AIOStreams   its usenet library rows join ninjarr's database. A file's path comes from the row
#                (category + name), so it shows up exactly where the old symlinks point.
#   library      the symlink folders of every imported series/movie, under /library/tv and /movies
#   Sonarr/Radarr every series/movie the old ones had, with its monitoring, on ninjarr's profile;
#                adding one makes Sonarr/Radarr scan its folder and find the files already there
#   Emby         the whole data folder replaces ninjarr's fresh one: users, passwords, watch state,
#                settings and plugins come along; ninjarr's login is set on the matching user
#   Dispatcharr  the whole data folder replaces ninjarr's; Emby's tuner is pointed at it
#
# Before anything changes, a backup is made, and each replaced folder is kept next to the new
# one as <name>.before-import-<date>.

IMPORT_TS=""
IMPORT_DIR=""

import_legacy() {
  local file=$1
  [[ -f "$file" ]] || die "no such file: $file"
  tar -tf "$file" ./manifest.env >/dev/null 2>&1 || die "$file isn't a ninjarr export (no manifest inside) — make one with migrate/export-legacy.sh"
  docker ps --format '{{.Names}}' | grep -qx aiostreams || die "the stack isn't running — run ./bootstrap.sh first, then import"

  step "Reading the export"
  IMPORT_TS=$(date +%Y%m%d-%H%M%S)
  IMPORT_DIR="$NINJARR_DATA/.import-$IMPORT_TS"
  mkdir -p "$IMPORT_DIR"; chmod 700 "$IMPORT_DIR"
  trap 'rm -rf "$IMPORT_DIR"' EXIT
  tar -C "$IMPORT_DIR" -xf "$file" || die "unpacking $file failed (disk full?)"
  # read, not sourced: the manifest is data
  local k; for k in CREATED EMBY_VERSION EMBY_ROOT EMBY_KIND DISPATCHARR_IMAGE DISPATCHARR_PG AIO_IMAGE; do
    printf -v "$k" '%s' "$(sed -n "s/^$k='\(.*\)'\$/\1/p" "$IMPORT_DIR/manifest.env" | tail -n 1)"
  done
  local -a parts=()
  [[ -f "$IMPORT_DIR/aiostreams.tar" ]] && parts+=("AIOStreams library")
  [[ -f "$IMPORT_DIR/library.tar" ]] && parts+=("symlink library")
  [[ -f "$IMPORT_DIR/sonarr.json" ]] && parts+=("Sonarr series")
  [[ -f "$IMPORT_DIR/radarr.json" ]] && parts+=("Radarr movies")
  [[ -f "$IMPORT_DIR/emby.tar" ]] && parts+=("Emby (${EMBY_VERSION:-?})")
  [[ -f "$IMPORT_DIR/dispatcharr.tar" ]] && parts+=("Dispatcharr")
  ok "export from ${CREATED:-?}: $(IFS=,; echo "${parts[*]}" | sed 's/,/, /g')"
  [[ -f "$IMPORT_DIR/emby.tar" ]] && note "Emby and Dispatcharr data replace ninjarr's (kept next to it as *.before-import-$IMPORT_TS)"
  if [[ -f "$IMPORT_DIR/emby.tar" ]]; then import_emby_check || exit 1; fi
  if [[ -f "$IMPORT_DIR/dispatcharr.tar" ]]; then import_dispatcharr_check || exit 1; fi
  [[ "${NINJARR_UNATTENDED:-0}" == 1 ]] || confirm "import this into ninjarr?" y || die "stopped — nothing changed"

  step "Backing up first"
  backup quiet >/dev/null && ok "backup made — ./bootstrap.sh restore takes you back if needed" || die "the backup failed — nothing changed"

  step "Importing"
  [[ -f "$IMPORT_DIR/aiostreams.tar" ]] && import_aiostreams
  [[ -f "$IMPORT_DIR/library.tar" ]] && import_library
  [[ -f "$IMPORT_DIR/emby.tar" ]] && import_emby
  [[ -f "$IMPORT_DIR/dispatcharr.tar" ]] && import_dispatcharr
  return 0
}

# Sonarr/Radarr lists go in after the wiring, when ninjarr's profile and root folders exist
import_after_wire() {
  [[ -n "$IMPORT_DIR" ]] || return 0
  heading "Library"
  [[ -f "$IMPORT_DIR/sonarr.json" ]] && import_arr sonarr
  [[ -f "$IMPORT_DIR/radarr.json" ]] && import_arr radarr
  [[ -f "$IMPORT_DIR/sonarr.json" ]] && import_arr_files sonarr
  [[ -f "$IMPORT_DIR/radarr.json" ]] && import_arr_files radarr
  if [[ -f "$IMPORT_DIR/emby.tar" && -n "${EMBY_API_KEY:-}" ]]; then
    http POST "$EMBY/Library/Refresh" "" -H "X-Emby-Token: $EMBY_API_KEY" >/dev/null && info "Emby: library scan started"
  fi
  return 0
}

# ─────────────────────────────────────── AIOStreams
import_aiostreams() {
  local src="$IMPORT_DIR/aio" db="$NINJARR_DATA/appdata/aiostreams/db.sqlite" cols before after
  mkdir -p "$src"; tar -C "$src" -xf "$IMPORT_DIR/aiostreams.tar"
  [[ -f "$src/db.sqlite" ]] || { warn "AIOStreams: no database in the export — skipped"; return 0; }
  sqlite3 "$src/db.sqlite" 'PRAGMA wal_checkpoint(TRUNCATE);' >/dev/null 2>>"$LOG" || true
  sqlite3 "$src/db.sqlite" "SELECT 1 FROM usenet_library LIMIT 1" >/dev/null 2>&1 || { warn "AIOStreams: the old database has no usenet library — skipped"; return 0; }
  # the columns both versions know; ownership goes to ninjarr's own download client login ("arr")
  cols=$(comm -12 <(sqlite3 "$src/db.sqlite" "SELECT name FROM pragma_table_info('usenet_library')" | sort) \
                  <(sqlite3 "$db" "SELECT name FROM pragma_table_info('usenet_library')" | sort) | grep -vx owner | paste -sd, -)
  docker stop aiostreams >/dev/null
  before=$(sqlite3 "$db" "SELECT count(*) FROM usenet_library")
  if sqlite3 "$db" >>"$LOG" 2>&1 <<SQL
PRAGMA busy_timeout = 10000;
ATTACH '$src/db.sqlite' AS old;
BEGIN;
INSERT OR IGNORE INTO main.usenet_library ($cols, owner) SELECT $cols, 'arr' FROM old.usenet_library;
INSERT OR IGNORE INTO main.usenet_library_aliases (alias_hash, nzb_hash, nzb_url, created_at)
  SELECT alias_hash, nzb_hash, nzb_url, created_at FROM old.usenet_library_aliases;
COMMIT;
PRAGMA main.wal_checkpoint(TRUNCATE);
SQL
  then
    after=$(sqlite3 "$db" "SELECT count(*) FROM usenet_library")
    ok "AIOStreams: $((after - before)) library entries added ($after in all)"
  else
    warn "AIOStreams: importing the library failed — see $LOG"
  fi
  local f; for f in "$db"-wal "$db"-shm; do [[ -e "$f" ]] && chown --reference="$db" "$f"; done
  # the NZBs themselves (the database only links to them): without these, playing an imported
  # file means fetching its NZB again through the old Prowlarr
  local n=0 d
  for d in cache/grab-nzb usenet-nzbs; do
    [[ -d "$src/$d" ]] || continue
    mkdir -p "$NINJARR_DATA/appdata/aiostreams/$d"
    cp -an "$src/$d/." "$NINJARR_DATA/appdata/aiostreams/$d/" 2>>"$LOG"
    n=$((n + $(find "$src/$d" -type f | wc -l)))
  done
  # AIOStreams drops cached files its index doesn't list, so the two indexes are merged
  local idx="$NINJARR_DATA/appdata/aiostreams/cache/grab-nzb.index.json"
  if [[ -f "$src/cache/grab-nzb.index.json" ]]; then
    if [[ -f "$idx" ]]; then
      jq -s '.[1] + .[0]' "$idx" "$src/cache/grab-nzb.index.json" >"$idx.new" 2>>"$LOG" && mv "$idx.new" "$idx" || rm -f "$idx.new"
    else
      cp "$src/cache/grab-nzb.index.json" "$idx"
    fi
  fi
  chown -R --reference="$NINJARR_DATA/appdata/aiostreams" "$NINJARR_DATA/appdata/aiostreams/cache" 2>/dev/null || true
  (( n )) && ok "AIOStreams: $n cached NZB file(s)" || warn "AIOStreams: no NZBs in the export — imported files are fetched again through their old links (made with an older export script?)"
  docker start aiostreams >/dev/null
  wait_http AIOStreams http://localhost:3000/ 120 >/dev/null || true
}

# ─────────────────────────────────────── the symlink library
# Each imported series/movie keeps its folder name, under ninjarr's /library/tv or /library/movies.
# Old symlinks that point at another mount path are rewritten to /mnt/aiostreams/usenet/…
import_library() {
  local tmp="$IMPORT_DIR/lib" app kind rel base p n=0 fixed=0 t l
  mkdir -p "$tmp"; tar -C "$tmp" -xf "$IMPORT_DIR/library.tar"
  for app in sonarr radarr; do
    [[ -f "$IMPORT_DIR/$app.json" ]] || continue
    kind=tv; [[ $app == radarr ]] && kind=movies
    while IFS= read -r p; do
      [[ -n "$p" ]] || continue
      base=${p##*/}; rel=${p#/}
      # the old path as seen inside the old app; find its folder in the copy by dropping leading parts
      while [[ -n "$rel" && ! -d "$tmp/$rel" ]]; do [[ "$rel" == */* ]] && rel=${rel#*/} || rel=""; done
      [[ -n "$rel" ]] || continue
      mkdir -p "$NINJARR_DATA/library/$kind/$base"
      cp -an "$tmp/$rel/." "$NINJARR_DATA/library/$kind/$base/" 2>>"$LOG"
      n=$((n+1))
    done < <(jq -r '.items[].path // empty' "$IMPORT_DIR/$app.json")
  done
  while IFS= read -r -d '' l; do
    t=$(readlink "$l")
    if [[ "$t" != /mnt/aiostreams/* && "$t" == */usenet/* ]]; then
      ln -sfn "/mnt/aiostreams/usenet/${t#*/usenet/}" "$l"; fixed=$((fixed+1))
    fi
  done < <(find "$NINJARR_DATA/library" -type l -print0)
  chown -hR "$PUID:$PGID" "$NINJARR_DATA/library"
  ok "library: $n folders copied"
  (( fixed )) && info "library: $fixed links now point at /mnt/aiostreams"
  return 0
}

# ─────────────────────────────────────── Sonarr / Radarr
import_arr() { # import_arr sonarr|radarr
  local app=$1 kind=tv idf=tvdbId what=series noun=series pid have total added=0 failed=0 body item
  [[ $app == radarr ]] && { kind=movies; idf=tmdbId; what=movie; noun=movies; }
  arr_use "$app"
  pid=$(api GET "$BASE/qualityprofile" | jq -r --arg n "$QUALITY_PROFILE_NAME" '[.[] | select(.name == $n) | .id][0] // empty') || pid=""
  [[ -n "$pid" ]] || { warn "$APP_NAME: no '$QUALITY_PROFILE_NAME' profile — run ./bootstrap.sh wire, then import again"; return 1; }
  have=$(api GET "$BASE/$what" | jq -c --arg f "$idf" '[.[][$f]]') || have='[]'
  total=$(jq '.items | length' "$IMPORT_DIR/$app.json")
  while IFS= read -r item; do
    body=$(jq -c --argjson pid "$pid" --arg root "/library/$kind" --arg app "$app" '
      del(.id, .statistics, .movieFile, .movieFileId, .added, .lastInfoSync, .languageProfileId, .collection)
      | .tags = [] | .qualityProfileId = $pid
      | .rootFolderPath = $root | .path = ($root + "/" + (.path | split("/") | last))
      | .addOptions = (if $app == "sonarr"
          then {searchForMissingEpisodes: false, searchForCutoffUnmetEpisodes: false}
          else {searchForMovie: false} end)' <<<"$item")
    if api POST "$BASE/$what" "$body" >/dev/null; then added=$((added+1)); else failed=$((failed+1)); fi
  done < <(jq -c --argjson have "$have" --arg f "$idf" '.items[] | select((.[$f] // 0) as $i | $have | index($i) | not)' "$IMPORT_DIR/$app.json")
  (( added == 1 )) && noun=${noun%s}; [[ $what == series ]] && noun=series
  ok "$APP_NAME: $added $noun added ($total in the export, $((total - added - failed)) already here)"
  (( failed )) && warn "$APP_NAME: $failed could not be added — see $LOG"
  info "$APP_NAME scans each folder now and finds the files already there; that takes a while for a big library"
}

# A renamed file ("Show - S01E07 - Title WEBDL-2160p.mkv") no longer shows its release name or
# languages, and Sonarr/Radarr don't read files (that would pull them through usenet). Scanned
# from disk they'd count as English and below the cutoff, so the language rule would want to
# replace everything. The old apps knew better: their release name, group, languages and quality
# go back onto each matching file.
arr_busy() { # arr_busy — Sonarr/Radarr still adding or scanning?
  api GET "$BASE/command" | jq -e 'any(.[]; (.status == "queued" or .status == "started")
    and (.name | test("Refresh|Rescan|DiskScan")))' >/dev/null 2>&1
}
import_arr_files() { # import_arr_files sonarr|radarr
  # big libraries: everything goes through files, never through jq/curl arguments
  local app=$1 legacy="$IMPORT_DIR/$1.legacy.json" cur="$IMPORT_DIR/$1.current.ndjson" body="$IMPORT_DIR/$1.body.json"
  local t=0 n total sid tvdb
  arr_use "$app"
  if [[ $app == sonarr ]]; then
    jq -e '(.files // []) | length > 0' "$IMPORT_DIR/$app.json" >/dev/null || { info "$APP_NAME: no file details in the export (made with an older export script)"; return 0; }
    # legacy files keyed by tvdbId + relative path
    jq -c '(.items | map({key: (.id | tostring), value: .tvdbId}) | from_entries) as $tv
      | [.files[][] | select(.sceneName != null or (.languages // []) != []) | . + {tvdbId: $tv[(.seriesId | tostring)]}]' "$IMPORT_DIR/$app.json" >"$legacy"
  else
    jq -c '[.items[] | select(.movieFile != null) | .movieFile + {tmdbId}]' "$IMPORT_DIR/$app.json" >"$legacy"
  fi
  total=$(jq length "$legacy")
  (( total )) || return 0
  while arr_busy && (( t < 1800 )); do
    (( t == 0 )) && info "$APP_NAME: waiting for the scan of the imported folders to finish"
    sleep 15; t=$((t+15))
  done
  : >"$cur"
  if [[ $app == sonarr ]]; then
    while read -r sid tvdb; do
      { api GET "$BASE/episodefile?seriesId=$sid" || echo '[]'; } \
        | jq -c --argjson t "$tvdb" '.[] | {id, key: "\($t)/\(.relativePath)"}' >>"$cur"
    done < <(api GET "$BASE/series" | jq -r '.[] | "\(.id) \(.tvdbId)"')
    jq -c -s --slurpfile old "$legacy" '
      ($old[0] | map({key: "\(.tvdbId)/\(.relativePath)", value: .}) | from_entries) as $o
      | [.[] | ($o[.key]) as $f | select($f != null)
         | {id, sceneName: $f.sceneName, releaseGroup: $f.releaseGroup, languages: $f.languages, quality: $f.quality}]' "$cur" >"$body"
  else
    api GET "$BASE/movie" | jq -c '.[] | select(.movieFile != null) | {id: .movieFile.id, key: (.tmdbId | tostring)}' >"$cur"
    jq -c -s --slurpfile old "$legacy" '
      ($old[0] | map({key: (.tmdbId | tostring), value: .}) | from_entries) as $o
      | [.[] | ($o[.key]) as $f | select($f != null)
         | {id, sceneName: $f.sceneName, releaseGroup: $f.releaseGroup, languages: $f.languages, quality: $f.quality}]' "$cur" >"$body"
  fi
  n=$(jq length "$body")
  if (( n == 0 )); then
    info "$APP_NAME: no imported files found yet — if the scan is still running, import the same file again later"
    return 0
  fi
  local ep=episodefile; [[ $app == radarr ]] && ep=moviefile
  local i fail=0
  for (( i = 0; i < n; i += 100 )); do
    api PUT "$BASE/$ep/bulk" "$(jq -c ".[$i:$((i + 100))]" "$body")" >/dev/null || fail=1
  done
  if (( fail )); then warn "$APP_NAME: updating some files failed — see $LOG"
  else ok "$APP_NAME: release name and languages restored on $n of $total files"; fi
  (( n < total )) && info "$APP_NAME: $((total - n)) not found here yet — importing the same file again later picks them up"
  return 0
}

# ─────────────────────────────────────── Emby
emby_tag_version() { local t=${EMBY_TAG:-}; [[ -n "$t" ]] || t=$(sed -n "s/^EMBY_TAG=['\"]\{0,1\}\([^'\"]*\).*/\1/p" "$ROOT/versions.env"); printf '%s' "${t%%-*}"; }
import_emby_check() {
  local old=${EMBY_VERSION:-unknown} new; new=$(emby_tag_version)
  old=${old%%-*}; old=${old%%+*}
  if [[ "$old" == unknown || -z "$new" ]]; then warn "Emby: couldn't compare versions (old $old, ninjarr $new) — going ahead"; return 0; fi
  if [[ "$(printf '%s\n%s\n' "$old" "$new" | sort -V | tail -n 1)" != "$new" ]]; then
    warn "Emby: your old Emby ($old) is newer than ninjarr's ($new). Emby can't move back a version."
    note "Set EMBY_TAG in ninjarr.env to a linuxserver/emby tag of $old or newer, run ./bootstrap.sh, then import again."
    return 1
  fi
  ok "Emby: $old → $new"
}
import_emby() {
  local dir="$NINJARR_DATA/appdata/emby" root=${EMBY_ROOT:-/var/lib/emby} f
  docker stop emby >/dev/null 2>&1 || true
  [[ -d "$dir" ]] && mv "$dir" "$dir.before-import-$IMPORT_TS"
  mkdir -p "$dir"
  tar -C "$dir" -xf "$IMPORT_DIR/emby.tar" || die "Emby: unpacking failed — see $LOG"
  # paths inside its settings: the old data folder becomes /config, a native install's ffmpeg the image's
  while IFS= read -r -d '' f; do
    sed -i -e "s#$root#/config#g" -e 's#/opt/emby-server#/app/emby#g' "$f"
    # with Dispatcharr coming along, its tuner and guide now live at http://dispatcharr:9191
    [[ -f "$IMPORT_DIR/dispatcharr.tar" ]] && sed -i -E 's#https?://[^/<"]+:9191#http://dispatcharr:9191#g' "$f"
  done < <(find "$dir/config" "$dir/root" -type f \( -name '*.xml' -o -name '*.mblink' \) -print0 2>/dev/null)
  # library folders pointing somewhere other than ninjarr's: map the old Sonarr/Radarr roots
  import_emby_roots "$dir"
  chown -R "$PUID:$PGID" "$dir"
  docker start emby >/dev/null
  wait_http Emby http://localhost:8096/emby/System/Info/Public 300 >/dev/null || die "Emby doesn't start with the imported data — docker logs emby; the old folder is $dir.before-import-$IMPORT_TS"
  ok "Emby: data imported (users, watch state, settings)"
  emby_take_login
  # Seerr was signed in to the fresh Emby; set it up again against the imported one
  if [[ -d "$NINJARR_DATA/appdata/seerr" ]]; then
    docker stop seerr >/dev/null 2>&1 || true
    mv "$NINJARR_DATA/appdata/seerr" "$NINJARR_DATA/appdata/seerr.before-import-$IMPORT_TS"
    mkdir -p "$NINJARR_DATA/appdata/seerr"; chown --reference="$NINJARR_DATA/appdata/seerr.before-import-$IMPORT_TS" "$NINJARR_DATA/appdata/seerr"
    docker start seerr >/dev/null 2>&1 || true
    info "Seerr: set up again with the imported Emby (it was new anyway)"
  fi
}
import_emby_roots() {
  local dir=$1 app kind r f
  for app in sonarr radarr; do
    [[ -f "$IMPORT_DIR/$app.json" ]] || continue
    kind=tv; [[ $app == radarr ]] && kind=movies
    for r in $(jq -r '.roots[].path' "$IMPORT_DIR/$app.json"); do
      r=${r%/}; [[ "$r" == "/library/$kind" ]] && continue
      while IFS= read -r -d '' f; do
        grep -qx "$r/\?" "$f" && printf '/library/%s' "$kind" >"$f"
      done < <(find "$dir/root" -name '*.mblink' -print0 2>/dev/null)
    done
  done
}
# ninjarr signs in to Emby as ADMIN_USER with ADMIN_PASSWORD. On the imported Emby that user may
# have another password, or not exist: sign in once with an old admin login and set it right.
emby_take_login() {
  local tok uid users me old_user old_pass pol
  tok=$(emby_token) || tok=""
  if [[ -n "$tok" ]]; then ok "Emby: ninjarr signs in as $ADMIN_USER"; return 0; fi
  info "Emby: your ninjarr login ($ADMIN_USER) doesn't work on the imported Emby yet"
  note "sign in once with an admin of your old Emby; ninjarr then sets its own password on"
  note "Emby user '$ADMIN_USER' (or creates it as an admin), so one login works everywhere"
  local tries=0
  while (( tries++ < 3 )); do
    old_user=${IMPORT_EMBY_USER:-}; old_pass=${IMPORT_EMBY_PASS:-}
    [[ -n "$old_user" ]] || ask_required old_user "old Emby admin username" "$ADMIN_USER"
    [[ -n "$old_pass" ]] || ask_secret old_pass "its password"
    tok=$(http POST "$EMBY/Users/AuthenticateByName" "$(jq -nc --arg u "$old_user" --arg p "$old_pass" '{Username: $u, Pw: $p}')" \
          -H "X-Emby-Authorization: $EMBY_AUTH" | jq -r '.AccessToken // empty') || true
    [[ -n "$tok" ]] && break
    warn "that login didn't work"; [[ -n "${IMPORT_EMBY_USER:-}" ]] && break
  done
  [[ -n "$tok" ]] || { warn "Emby: no admin login — ninjarr can't manage Emby until '$ADMIN_USER' signs in with the ninjarr password"; return 1; }
  users=$(http GET "$EMBY/Users" "" -H "X-Emby-Token: $tok") || users="[]"
  uid=$(jq -r --arg u "$ADMIN_USER" '[.[] | select((.Name | ascii_downcase) == ($u | ascii_downcase)) | .Id][0] // empty' <<<"$users")
  if [[ -z "$uid" ]]; then
    uid=$(http POST "$EMBY/Users/New" "$(jq -nc --arg u "$ADMIN_USER" '{Name: $u}')" -H "X-Emby-Token: $tok" | jq -r '.Id // empty') || uid=""
    [[ -n "$uid" ]] || { warn "Emby: could not create user $ADMIN_USER — see $LOG"; return 1; }
    pol=$(http GET "$EMBY/Users/$uid" "" -H "X-Emby-Token: $tok" | jq -c '.Policy | .IsAdministrator = true | .EnableAllFolders = true') || pol=""
    [[ -n "$pol" ]] && { http POST "$EMBY/Users/$uid/Policy" "$pol" -H "X-Emby-Token: $tok" >/dev/null || true; }
    info "Emby: created admin user $ADMIN_USER"
  fi
  me=$(jq -r --arg u "$old_user" '[.[] | select(.Name == $u) | .Id][0] // empty' <<<"$users")
  if [[ "$me" == "$uid" ]]; then
    http POST "$EMBY/Users/$uid/Password" "$(jq -nc --arg o "$old_pass" --arg n "$ADMIN_PASSWORD" '{CurrentPw: $o, NewPw: $n}')" -H "X-Emby-Token: $tok" >/dev/null || true
  else
    http POST "$EMBY/Users/$uid/Password" '{"ResetPassword": true}' -H "X-Emby-Token: $tok" >/dev/null || true
    http POST "$EMBY/Users/$uid/Password" "$(jq -nc --arg n "$ADMIN_PASSWORD" '{CurrentPw: "", NewPw: $n}')" -H "X-Emby-Token: $tok" >/dev/null || true
  fi
  if [[ -n "$(emby_token || true)" ]]; then ok "Emby: '$ADMIN_USER' now signs in with the ninjarr password"
  else warn "Emby: setting the password for $ADMIN_USER failed — see $LOG"; return 1; fi
}

# ─────────────────────────────────────── Dispatcharr
import_dispatcharr_check() {
  local cur=""
  [[ -f "$NINJARR_DATA/appdata/dispatcharr/db/PG_VERSION" ]] && cur=$(cat "$NINJARR_DATA/appdata/dispatcharr/db/PG_VERSION")
  if [[ -n "$cur" && -n "${DISPATCHARR_PG:-}" && "${DISPATCHARR_PG}" != unknown && "$cur" != "$DISPATCHARR_PG" ]]; then
    warn "Dispatcharr: your old one keeps its database in PostgreSQL $DISPATCHARR_PG, ninjarr's in $cur — they can't be copied across."
    note "Use Dispatcharr's own Settings → Backups instead: make a backup in the old one, restore it in ninjarr's."
    return 1
  fi
  ok "Dispatcharr: ${DISPATCHARR_IMAGE##*:} → $(sed -n "s/^DISPATCHARR_TAG=['\"]\{0,1\}\([^'\"]*\).*/\1/p" "$ROOT/versions.env")"
}
import_dispatcharr() {
  local dir="$NINJARR_DATA/appdata/dispatcharr"
  docker stop dispatcharr >/dev/null 2>&1 || true
  [[ -d "$dir" ]] && mv "$dir" "$dir.before-import-$IMPORT_TS"
  mkdir -p "$dir"
  tar -C "$dir" --numeric-owner -xpf "$IMPORT_DIR/dispatcharr.tar" || die "Dispatcharr: unpacking failed — see $LOG"
  # channels, accounts and the guide are managed in Dispatcharr from now on, not from ninjarr.env
  env_set IPTV yes; env_set IPTV_TYPE ""; env_set IPTV_URL ""; env_set IPTV_USER ""; env_set IPTV_PASS ""; env_set IPTV_EPG_URL ""
  env_save
  ok "Dispatcharr: data imported — your channels, accounts and profiles are managed in Dispatcharr"
}
