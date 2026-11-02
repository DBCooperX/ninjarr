# shellcheck shell=bash
# ninjarr — imports stuck on broken file names.
#
# Some releases carry their file names in an old encoding (an umlaut stored as a single Latin-1
# byte, say), and AIOStreams hands them on as they are. Sonarr and Radarr can't reliably open a path
# that isn't valid UTF-8, so the import sits at "Downloaded - Importing" for ever, though the data
# is fine. From the host-status timer (every 5 minutes): a download that has sat in import for
# 15 minutes and whose folder holds such names gets those files linked into the library under a
# cleaned name, pointing where the import would have pointed; the app rescans and takes them. Once
# every episode (or the movie) has its file, the stuck entry leaves the queue — kept in AIOStreams,
# since the library plays from it. Sonarr and Radarr rename by episode/movie title as usual, so the
# cleaned name only has to carry SxxEyy.
#
# .state/namefix.seen     app downloadId first-seen      (downloads stuck in import right now)
# .state/namefix.pending  app downloadId linked-at count state   (state: wait | gaveup)
# .state/namefix.tsv      at<TAB>app<TAB>fixed|partly<TAB>title<TAB>files   (for Dojo, 30 days)

NAMEFIX_WAIT=900         # stuck this long (seconds) before anything is touched
NAMEFIX_GIVEUP=3600      # linked this long without every file showing up: leave it to a person

# name_broken NAME — not valid UTF-8, or carrying U+FFFD/FFFE/FFFF or a control character
name_broken() {
  local LC_ALL=C n=$1
  printf '%s' "$n" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1 || return 0
  [[ "$n" == *$'\xef\xbf\xbd'* || "$n" == *$'\xef\xbf\xbe'* || "$n" == *$'\xef\xbf\xbf'* ]] && return 0
  [[ "$n" =~ [[:cntrl:]] ]] && return 0
  return 1
}

# clean_name NAME — the same name with whatever broke it left out
clean_name() {
  printf '%s' "$1" | LC_ALL=C sed 's/\xef\xbf[\xbd\xbe\xbf]//g' | iconv -f UTF-8 -t UTF-8 -c 2>/dev/null | LC_ALL=C tr -d '[:cntrl:]'
}

is_video() { [[ "${1,,}" =~ \.(mkv|mp4|m4v|avi|ts|m2ts|wmv|mov)$ && ! "${1,,}" =~ (^|[._ -])sample([._ -]|$) ]]; }

# namefix_place SRC DEST — links SRC (a host path in the stream folder) into the library folder
# DEST (as the apps see it, /library/…) under a cleaned name, pointing where SRC points
namefix_place() {
  local src=$1 dest=$2 target clean h
  [[ "$dest" == /library/tv/?* || "$dest" == /library/movies/?* ]] || return 1
  target=$(readlink "$src") || target="/mnt/${src#"$NINJARR_DATA/stream/"}"
  clean=$(clean_name "${src##*/}")
  [[ -n "$clean" && "$clean" != */* ]] || return 1
  h="$NINJARR_DATA$dest"
  [[ -d "$h" ]] || { mkdir -p "$h" && chown "$PUID:$PGID" "$h" "${h%/*}"; } || return 1
  [[ -e "$h/$clean" || -L "$h/$clean" ]] && return 0
  ln -s "$target" "$h/$clean" && chown -h "$PUID:$PGID" "$h/$clean"
}

namefix_log() { # namefix_log APP fixed|partly TITLE FILES
  local f="$ROOT/.state/namefix.tsv" cut
  cut=$(date -d '30 days ago' +%s)
  { [[ ! -f "$f" ]] || awk -F'\t' -v c="$cut" '$1 >= c' "$f"; printf '%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$1" "$2" "${3//$'\t'/ }" "$4"; } >"$f.tmp"
  mv -f "$f.tmp" "$f"
}

# namefix_link APP GROUP — links the broken-named files of one stuck download; prints how many
namefix_link() {
  local app=$1 g=$2 path media dir f name n=0 best="" size=0 s e ep series files dest
  path=$(jq -r .path <<<"$g"); media=$(jq -r .media <<<"$g")
  dir="$NINJARR_DATA/stream/${path#/mnt/}"
  [[ "$path" == /mnt/aiostreams/* && -d "$dir" ]] || { echo -1; return 0; }
  local LC_ALL=C broken=()
  for f in "$dir"/*; do
    name=${f##*/}
    is_video "$name" && name_broken "$name" && broken+=("$f")
  done
  (( ${#broken[@]} )) || { echo -1; return 0; }        # nothing wrong with the names: not ours to fix
  if [[ "$app" == radarr ]]; then
    local movie; movie=$(api GET "$BASE/movie/$media") || { echo 0; return 0; }
    if [[ "$(jq -r .hasFile <<<"$movie")" != true ]]; then
      for f in "${broken[@]}"; do                       # the main file: the biggest one
        s=$(stat -Lc %s "$f" 2>/dev/null || echo 0); (( s > size )) && { best=$f; size=$s; }
      done
      [[ -n "$best" ]] && namefix_place "$best" "$(jq -r .path <<<"$movie")" && n=1
    fi
  else
    series=$(api GET "$BASE/series/$media") || { echo 0; return 0; }
    files=$(api GET "$BASE/episodefile?seriesId=$media") || files='[]'
    for f in "${broken[@]}"; do
      name=${f##*/}
      [[ "$name" =~ [Ss]([0-9]{1,2})[._\ -]?[Ee]([0-9]{1,3}) ]] || continue
      s=$((10#${BASH_REMATCH[1]})); e=$((10#${BASH_REMATCH[2]}))
      ep=$(api GET "$BASE/episode?seriesId=$media&seasonNumber=$s" | jq -c --argjson e "$e" 'first(.[] | select(.episodeNumber == $e)) // empty')
      [[ -n "$ep" && "$(jq -r .hasFile <<<"$ep")" == false ]] || continue
      # next to the season's other episodes, else in Sonarr's usual season folder
      dest=$(jq -r --argjson s "$s" 'first(.[] | select(.seasonNumber == $s) | .path) // empty' <<<"$files")
      if [[ -n "$dest" ]]; then dest=${dest%/*}; else dest="$(jq -r .path <<<"$series")/Season $s"; fi
      namefix_place "$f" "$dest" && n=$((n + 1))
    done
  fi
  if (( n )); then
    if [[ "$app" == radarr ]]; then api POST "$BASE/command" "{\"name\":\"RescanMovie\",\"movieId\":$media}" >/dev/null || true
    else api POST "$BASE/command" "{\"name\":\"RescanSeries\",\"seriesId\":$media}" >/dev/null || true; fi
  fi
  echo "$n"
}

# namefix_done APP GROUP — every episode (the movie) of the download has its file now
namefix_done() {
  local app=$1 g=$2 media
  media=$(jq -r .media <<<"$g")
  if [[ "$app" == radarr ]]; then
    [[ "$(api GET "$BASE/movie/$media" | jq -r .hasFile)" == true ]]
  else
    api GET "$BASE/episode?seriesId=$media" | jq -e --argjson want "$(jq -c .eps <<<"$g")" \
      '[.[] | select(.id as $i | $want | index($i)) | .hasFile] | length > 0 and all' >/dev/null
  fi
}

namefix_app() {
  local app=$1 queue stuck now g id title first line n at count state
  local seenf="$ROOT/.state/namefix.seen" pend="$ROOT/.state/namefix.pending" seen="" keep=""
  arr_use "$app"
  queue=$(api GET "$BASE/queue?pageSize=1000") || return 0
  # finished downloading, sitting in import, from AIOStreams' library — one entry per download
  stuck=$(jq -c '[.records[]? | select(.status == "completed"
              and ((.trackedDownloadState // "") | IN("importPending", "importing", "importBlocked"))
              and ((.outputPath // "") | startswith("/mnt/aiostreams/")))]
            | group_by(.downloadId) | map({id: .[0].downloadId, title: .[0].title, path: .[0].outputPath,
                media: (.[0].seriesId // .[0].movieId), q: map(.id), eps: map(.episodeId // empty)})
            | map(select(.id and .media))[]' <<<"$queue") || return 0
  now=$(date +%s)
  while IFS= read -r g; do
    [[ -n "$g" ]] || continue
    id=$(jq -r .id <<<"$g"); title=$(jq -r .title <<<"$g")
    [[ "$id" =~ ^[A-Za-z0-9_.-]{1,128}$ ]] || continue
    first=$(awk -v a="$app" -v i="$id" '$1 == a && $2 == i {print $3; exit}' "$seenf" 2>/dev/null || true)
    seen+="$app $id ${first:-$now}"$'\n'
    line=$(awk -v a="$app" -v i="$id" '$1 == a && $2 == i {print; exit}' "$pend" 2>/dev/null || true)
    if [[ -n "$line" ]]; then
      read -r _ _ at count state <<<"$line"
      if [[ "$state" == wait ]] && namefix_done "$app" "$g"; then
        # the files are in: the stuck entry goes, the download stays (the library plays from it)
        api DELETE "$BASE/queue/bulk?removeFromClient=false&blocklist=false" "$(jq -c '{ids: .q}' <<<"$g")" >/dev/null \
          && { namefix_log "$app" fixed "$title" "$count"; continue; }
      elif [[ "$state" == wait ]] && (( now - at > NAMEFIX_GIVEUP )); then
        namefix_log "$app" partly "$title" "$count"; state=gaveup
      fi
      keep+="$app $id $at $count $state"$'\n'
      continue
    fi
    (( now - ${first:-$now} >= NAMEFIX_WAIT )) || continue
    n=$(namefix_link "$app" "$g" || echo 0)
    (( ${n:-0} >= 0 )) && keep+="$app $id $now $n wait"$'\n'
  done <<<"$stuck"
  # only downloads still stuck are remembered
  { grep -vs "^$app " "$seenf" || true; printf '%s' "$seen"; } >"$seenf.tmp"; mv -f "$seenf.tmp" "$seenf"
  { grep -vs "^$app " "$pend" || true; printf '%s' "$keep"; } >"$pend.tmp"; mv -f "$pend.tmp" "$pend"
}

namefix() {
  [[ -n "${NINJARR_DATA:-}" && -n "${PUID:-}" && -n "${PGID:-}" ]] || return 0
  command -v iconv >/dev/null || return 0
  mkdir -p "$ROOT/.state"
  [[ -n "${SONARR_API_KEY:-}" ]] && { namefix_app sonarr || true; }
  [[ -n "${RADARR_API_KEY:-}" ]] && { namefix_app radarr || true; }
  return 0
}
