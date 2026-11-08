# shellcheck shell=bash
# ninjarr — episodes and movies that stop early.
#
# Some releases are damaged on usenet: pieces in the middle are gone. AIOStreams fills what it can,
# but past a bad spot it can lose track of the video and serve nothing more, while the file still
# shows its full size. Emby plays the first minutes, reaches that early end and jumps to the end of
# the episode. Sonarr and Radarr never hear of it, so the broken copy stays. From the host-status
# timer (every 5 minutes) a few library files at a time get a quick read at the start, the middle
# and the end (3 MB each). A file that stops early, on two looks at least 10 minutes apart, is
# replaced: its release is marked failed in Sonarr/Radarr (which blocklists it), the file leaves
# the library and a search for another release starts. Every file is looked at again after 30 days.
#
# .state/cutcheck.checked  at<TAB>ok|unreadable<TAB>path   (library links looked at; unreadable: again in a day)
# .state/cutcheck.suspect  first-at<TAB>path   (stopped early once, looked at again before replacing)
# .state/cutcheck.failed   app grabId   (grabs marked failed, so a season pack is marked once)
# .state/cutcheck.tsv      at<TAB>app<TAB>replaced|manual<TAB>title<TAB>file   (for Dojo, 30 days)
# .state/cutcheck.days     day<TAB>checked<TAB>stopped-early   (for Dojo, 30 days)
# .state/cutcheck.json     the last pass and the library's numbers (for Dojo → Stats → Files)

CUTCHECK_PASS=40         # files looked at per 5-minute pass
CUTCHECK_PER_RUN=$CUTCHECK_PASS
CUTCHECK_SECONDS=90      # and no longer than this
CUTCHECK_AGAIN=2592000   # each file again after 30 days
CUTCHECK_CONFIRM=600     # stops early on two looks this far apart before anything is replaced
CUTCHECK_MAX_DAY=10      # releases replaced a day at most (a season pack is one); more wait a day

cut_say() { [[ -n "${CUT_SAY:-}" ]] && "${2:-info}" "$1" >&2; return 0; }

# cut_target LINK — the host path a library link plays from (only links into AIOStreams' library)
cut_target() {
  local t; t=$(readlink "$1") || return 1
  [[ "$t" == /mnt/aiostreams/* ]] || return 1
  printf '%s' "$NINJARR_DATA/stream/${t#/mnt/}"
}

# cut_probe FILE — 0 plays to the end, 1 stops early, 2 can't tell now (AIOStreams busy or away)
cut_probe() {
  local f=$1 s mb o n
  s=$(stat -Lc %s "$f" 2>/dev/null) || return 2
  mb=$((s / 1048576))
  (( mb >= 8 )) || return 0
  for o in 0 $((mb / 2)) $((mb - 2)); do
    n=$(set -o pipefail; timeout 60 dd if="$f" bs=1M skip="$o" count=1 status=none 2>/dev/null | wc -c) || return 2
    if (( n == 0 )); then
      (( o == 0 )) && return 2          # not even the start: AIOStreams trouble, not this file
      return 1
    fi
  done
  return 0
}

cut_log() { # cut_log APP replaced|manual TITLE FILE
  local f="$ROOT/.state/cutcheck.tsv" cut
  cut=$(date -d '30 days ago' +%s)
  { [[ ! -f "$f" ]] || awk -F'\t' -v c="$cut" '$1 >= c' "$f"
    printf '%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$1" "$2" "${3//$'\t'/ }" "${4//$'\t'/ }"; } >"$f.tmp"
  mv -f "$f.tmp" "$f"
}

cut_replaced_today() {
  awk -F'\t' -v c="$(( $(date +%s) - 86400 ))" '$1 >= c && $3 == "replaced" && !seen[$4]++' "$ROOT/.state/cutcheck.tsv" 2>/dev/null | wc -l
}

# cut_replace LINK — prints "replaced|manual|gone<TAB>title<TAB>app"; fails when the app can't be asked
cut_replace() {
  local link=$1 p app media fid eps='[]' hist grab gid title
  p="/library/${link#"$NINJARR_DATA/library/"}"
  case $p in /library/tv/*) app=sonarr ;; /library/movies/*) app=radarr ;; *) return 1 ;; esac
  arr_use "$app"
  [[ -n "${API_KEY:-}" ]] || return 1
  if [[ $app == sonarr ]]; then
    media=$(api GET "$BASE/series" | jq -r --arg p "$p" 'first(.[] | select(.path as $s | $p | startswith($s + "/")) | .id) // empty') || return 1
    [[ -n "$media" ]] || { printf 'gone\t%s\t%s\n' "${link##*/}" "$app"; return 0; }
    fid=$(api GET "$BASE/episodefile?seriesId=$media" | jq -r --arg p "$p" 'first(.[] | select(.path == $p) | .id) // empty') || return 1
    [[ -n "$fid" ]] || { printf 'gone\t%s\t%s\n' "${link##*/}" "$app"; return 0; }
    eps=$(api GET "$BASE/episode?seriesId=$media" | jq -c --argjson f "$fid" '[.[] | select(.episodeFileId == $f) | .id]') || return 1
    hist=$(api GET "$BASE/history/series?seriesId=$media") || return 1
  else
    media=$(api GET "$BASE/movie" | jq -r --arg p "$p" 'first(.[] | select(.movieFile.path? == $p) | "\(.id) \(.movieFile.id)") // empty') || return 1
    [[ -n "$media" ]] || { printf 'gone\t%s\t%s\n' "${link##*/}" "$app"; return 0; }
    fid=${media#* }; media=${media%% *}
    hist=$(api GET "$BASE/history/movie?movieId=$media") || return 1
  fi
  # the grab this file came from: by its import's download id, else the newest grab of its episodes
  grab=$(jq -c --arg p "$p" --argjson eps "$eps" '
    (map(select(.eventType == "downloadFolderImported" and .data.importedPath? == $p)) | max_by(.date) | .downloadId?) as $d
    | map(select(.eventType == "grabbed")) as $g
    | ($g | map(select($d != null and .downloadId == $d))) as $m
    | (if ($m | length) > 0 then $m else $g | map(select(($eps | length) == 0 or (.episodeId as $e | $eps | index($e) != null))) end)
    | max_by(.date) // empty | {id, title: .sourceTitle}' <<<"$hist") || grab=""
  title=$(jq -r '.title // empty' <<<"${grab:-null}" 2>/dev/null || true); [[ -n "$title" ]] || title=${link##*/}
  gid=$(jq -r '.id // empty' <<<"${grab:-null}" 2>/dev/null || true)
  # without the grab the release can't be blocklisted, and a search would likely take it again
  [[ "$gid" =~ ^[0-9]+$ ]] || { printf 'manual\t%s\t%s\n' "$title" "$app"; return 0; }
  # a season pack: its first episode that stops early marks the grab failed, the others follow it
  local failed="$ROOT/.state/cutcheck.failed"
  if ! grep -qsx "$app $gid" "$failed"; then
    api POST "$BASE/history/failed/$gid" >/dev/null || { printf 'manual\t%s\t%s\n' "$title" "$app"; return 0; }
    printf '%s %s\n' "$app" "$gid" >>"$failed"
  fi
  if [[ $app == sonarr ]]; then
    api DELETE "$BASE/episodefile/$fid" >/dev/null || return 1
    api POST "$BASE/command" "$(jq -nc --argjson e "$eps" '{name: "EpisodeSearch", episodeIds: $e}')" >/dev/null || true
  else
    api DELETE "$BASE/moviefile/$fid" >/dev/null || return 1
    api POST "$BASE/command" "{\"name\":\"MoviesSearch\",\"movieIds\":[$media]}" >/dev/null || true
  fi
  printf 'replaced\t%s\t%s\n' "$title" "$app"
}

# cut_suspects — looks again at the files that stopped early once; replaces the ones that still do
cut_suspects() {
  local sus="$ROOT/.state/cutcheck.suspect" chk="$ROOT/.state/cutcheck.checked" now first link f r out state title app
  [[ -s "$sus" ]] || return 0
  now=$(date +%s)
  local keep="" done_=""
  while IFS=$'\t' read -r first link <&3; do
    [[ -n "$link" && -L "$link" ]] || continue
    f=$(cut_target "$link") || continue
    if (( now - first < CUTCHECK_CONFIRM )); then keep+="$first"$'\t'"$link"$'\n'; continue; fi
    r=0; cut_probe "$f" || r=$?
    case $r in
      0) done_+="$now"$'\t'ok$'\t'"$link"$'\n'; cut_say "${link##*/}: plays to the end now" ok ;;
      2) keep+="$first"$'\t'"$link"$'\n' ;;
      1)
        if [[ -n "${CUT_DRYRUN:-}" ]]; then cut_say "${link##*/}: stops early — would be replaced" warn; keep+="$first"$'\t'"$link"$'\n'; continue; fi
        if (( $(cut_replaced_today) >= CUTCHECK_MAX_DAY )); then
          keep+="$first"$'\t'"$link"$'\n'; cut_say "${link##*/}: stops early — enough replaced today, tomorrow" warn; continue
        fi
        out=$(cut_replace "$link") || { keep+="$first"$'\t'"$link"$'\n'; continue; }
        IFS=$'\t' read -r state title app <<<"$out"
        done_+="$now"$'\t'ok$'\t'"$link"$'\n'
        case $state in
          replaced) cut_log "$app" replaced "$title" "${link##*/}"; cut_say "${title}: stops early — blocklisted, ${app^} searches for another release" ok ;;
          manual)   cut_log "$app" manual "$title" "${link##*/}"; cut_say "${title}: stops early, but ${app^} doesn't know which download it came from — replace it there" warn ;;
        esac ;;
    esac
  done 3<"$sus"
  [[ -n "${CUT_DRYRUN:-}" ]] && return 0
  printf '%s' "$keep" >"$sus.tmp"; mv -f "$sus.tmp" "$sus"
  printf '%s' "$done_" >>"$chk"
}

# cut_scan — looks at library files not looked at for 30 days, newest first
cut_scan() {
  local chk="$ROOT/.state/cutcheck.checked" sus="$ROOT/.state/cutcheck.suspect" now start link f r
  local probed=0 cuts=0 new_sus="" new_chk="" rel=""
  local -A releases=()
  now=$(date +%s); start=$SECONDS
  touch "$chk" "$sus"
  while IFS= read -r link <&3; do
    (( probed < CUTCHECK_PER_RUN && SECONDS - start < CUTCHECK_SECONDS )) || break
    is_video "${link##*/}" || continue
    f=$(cut_target "$link") || continue
    probed=$((probed + 1))
    r=0; cut_probe "$f" || r=$?
    case $r in
      0) new_chk+="$now"$'\t'ok$'\t'"$link"$'\n' ;;
      1) cuts=$((cuts + 1)); rel=${f#*/by-id/}; releases[${rel%%/*}]=1; new_sus+="$now"$'\t'"$link"$'\n'; cut_say "${link##*/}: stops early" warn ;;
      2) new_chk+="$now"$'\t'unreadable$'\t'"$link"$'\n' ;;   # again in a day
    esac
  done 3< <(find "$NINJARR_DATA/library/tv" "$NINJARR_DATA/library/movies" -type l -printf '%T@\t%p\n' 2>/dev/null \
             | sort -rn | cut -f2- \
             | awk -F'\t' -v c="$((now - ${CUTCHECK_SKIP:-$CUTCHECK_AGAIN}))" -v d="$((now - ${CUTCHECK_SKIP:-86400}))" -v ck="$chk" -v sk="$sus" '
                 FILENAME == ck { if (($2 == "ok" && $1 >= c) || ($2 == "unreadable" && $1 >= d)) seen[$3] = 1; next }
                 FILENAME == sk { seen[$2] = 1; next }
                 !($0 in seen)' "$chk" "$sus" -)
  # many releases at once is AIOStreams having trouble, not that many damaged ones: nothing is kept
  # (a season pack is one release, however many of its episodes stop early)
  local brake=0
  if (( ${#releases[@]} >= 5 && cuts * 2 >= probed )); then
    cut_say "$cuts of $probed files stop early — that looks like AIOStreams trouble, so nothing is replaced" warn
    brake=1
  fi
  [[ -n "${CUT_DRYRUN:-}" ]] && return 0
  if (( ! brake )); then
    printf '%s' "$new_sus" >>"$sus"
    # only the newest look per file, none older than 30 days
    { cat "$chk"; printf '%s' "$new_chk"; } \
      | awk -F'\t' -v c="$((now - CUTCHECK_AGAIN))" '$1 >= c { last[$3] = $1 "\t" $2 } END { for (p in last) print last[p] "\t" p }' >"$chk.tmp"
    mv -f "$chk.tmp" "$chk"
    cut_days "$probed" "$cuts"
  fi
  cut_summary "$probed" "$cuts" "$((SECONDS - start))" "$brake"
}

# cut_days CHECKED CUT — adds a pass to today's numbers, keeps 30 days
cut_days() {
  local f="$ROOT/.state/cutcheck.days"
  (( $1 > 0 )) || return 0
  { [[ ! -f "$f" ]] || cat "$f"; printf '%s\t%s\t%s\n' "$(date +%F)" "$1" "$2"; } \
    | awk -F'\t' -v c="$(date -d '30 days ago' +%F)" '$1 >= c { n[$1] += $2; s[$1] += $3 } END { for (d in n) print d "\t" n[d] "\t" s[d] }' \
    | sort >"$f.tmp"
  mv -f "$f.tmp" "$f"
}

# cut_summary PROBED CUT SECONDS BRAKE — the numbers Dojo shows
cut_summary() {
  local f="$ROOT/.state/cutcheck.json" chk="$ROOT/.state/cutcheck.checked" sus="$ROOT/.state/cutcheck.suspect"
  local now total ok bad waiting brake_at=0
  now=$(date +%s)
  total=$(find "$NINJARR_DATA/library/tv" "$NINJARR_DATA/library/movies" -type l 2>/dev/null \
            | grep -Eic '\.(mkv|mp4|m4v|avi|ts|m2ts|wmv|mov)$' || true)
  ok=$(awk -F'\t' '$2 == "ok"' "$chk" 2>/dev/null | wc -l)
  bad=$(awk -F'\t' -v d="$((now - 86400))" '$2 == "unreadable" && $1 >= d' "$chk" 2>/dev/null | wc -l)
  waiting=$(grep -c . "$sus" 2>/dev/null || true)
  brake_at=$(jq -r '.brake_at // 0' "$f" 2>/dev/null || echo 0)
  (( $4 )) && brake_at=$now
  jq -n --argjson at "$now" --argjson total "${total:-0}" --argjson ok "${ok:-0}" --argjson bad "${bad:-0}" \
        --argjson waiting "${waiting:-0}" --argjson probed "$1" --argjson cut "$2" --argjson secs "$3" \
        --argjson brake_at "${brake_at:-0}" --argjson per_run "$CUTCHECK_PASS" --argjson max_day "$CUTCHECK_MAX_DAY" \
    '{at: $at, library: $total, checked: $ok, unreadable: $bad, waiting: $waiting,
      pass: {files: $probed, stopped: $cut, seconds: $secs}, brake_at: $brake_at, per_run: $per_run, max_day: $max_day}' >"$f.tmp" \
    && mv -f "$f.tmp" "$f"
}

# cutcheck — the 5-minute pass from host-status
cutcheck() {
  [[ -n "${NINJARR_DATA:-}" && -d "$NINJARR_DATA/library" ]] || return 0
  [[ -n "${SONARR_API_KEY:-}${RADARR_API_KEY:-}" ]] || return 0
  [[ -d "$NINJARR_DATA/stream/aiostreams/usenet" ]] || return 0     # AIOStreams' library isn't mounted
  mkdir -p "$ROOT/.state"
  cut_suspects || true
  cut_scan || true
}

# check-files [--list] — every library file at once, also ones looked at lately (--list: only
# say which files stop early, change nothing)
check_files() {
  [[ -d "$NINJARR_DATA/stream/aiostreams/usenet" ]] || die "AIOStreams' library isn't mounted — is AIOStreams running?"
  mkdir -p "$ROOT/.state"
  [[ "${1:-}" == --list ]] && CUT_DRYRUN=1
  info "reading 3 MB at the start, middle and end of every library file — this takes a while"
  CUT_SAY=1 CUTCHECK_PER_RUN=1000000 CUTCHECK_SECONDS=1000000 CUTCHECK_SKIP=0 cut_scan
  if [[ -n "${CUT_DRYRUN:-}" ]]; then ok "done — nothing was changed"; return 0; fi
  CUT_SAY=1 CUTCHECK_CONFIRM=0 cut_suspects
  ok "done"
}
