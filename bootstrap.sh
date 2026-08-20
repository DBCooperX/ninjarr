#!/usr/bin/env bash
# ninjarr — one command, one stack, no clicking
# https://github.com/YOURNAME/ninjarr
set -Eeuo pipefail

NINJARR_VERSION="0.1.0"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$ROOT/.env"
LOG="$ROOT/.ninjarr.log"
# Applied by bootstrap on first run so the stack is German-tuned out of the box; change tiers
# any time afterward from Dojo Monitor's preset picker without re-running bootstrap.
RECYCLARR_DEFAULT_PRESET="german-uhd-bluray-web"

# ─────────────────────────────────────────────── palette
if [[ -t 1 ]] && [[ "${NO_COLOR:-}" == "" ]]; then
  R=$'\033[38;5;196m'; DR=$'\033[38;5;124m'; W=$'\033[38;5;255m'
  D=$'\033[38;5;244m'; DD=$'\033[38;5;238m'; G=$'\033[38;5;78m'
  Y=$'\033[38;5;221m'; B=$'\033[1m'; X=$'\033[0m'
  BLADE=(196 202 160 124 88 52)   # bright red fading to shadow, top to bottom of the banner
  ANIMATE=1
else
  R=""; DR=""; W=""; D=""; DD=""; G=""; Y=""; B=""; X=""
  BLADE=(); ANIMATE=0
fi

STAR="✦"; TICK="✔"; CROSS="✖"; ARROW="▸"
STEP_N=0; STEP_TOTAL=7

# ─────────────────────────────────────────────── chrome
# a shuriken flicker used to punctuate banner/step transitions — a no-op when output isn't a
# live terminal, so piping to a log or running in CI never waits on it or prints control codes
shuriken() {
  [[ "$ANIMATE" == "1" ]] || return 0
  local n=${1:-10} frames=('✦' '✧' '✶' '✷' '✸' '✹' '✺' '✳') i
  for ((i = 0; i < n; i++)); do
    printf '\r   %s%s%s' "$R" "${frames[i % ${#frames[@]}]}" "$X"
    sleep 0.035
  done
  printf '\r\033[K'
}

banner() {
  printf '%s\n' ""
  shuriken 14
  local -a art=(
    '  ███╗   ██╗██╗███╗   ██╗     ██╗ █████╗ ██████╗ ██████╗ '
    '  ████╗  ██║██║████╗  ██║     ██║██╔══██╗██╔══██╗██╔══██╗'
    '  ██╔██╗ ██║██║██╔██╗ ██║     ██║███████║██████╔╝██████╔╝'
    '  ██║╚██╗██║██║██║╚██╗██║██   ██║██╔══██║██╔══██╗██╔══██╗'
    '  ██║ ╚████║██║██║ ╚████║╚█████╔╝██║  ██║██║  ██║██║  ██║'
    '  ╚═╝  ╚═══╝╚═╝╚═╝  ╚═══╝ ╚════╝ ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝'
  )
  local i
  for i in "${!art[@]}"; do
    if [[ "$ANIMATE" == "1" ]]; then
      printf '\033[38;5;%sm%s\033[0m\n' "${BLADE[i]}" "${art[i]}"
      sleep 0.03
    else
      printf '%s\n' "${art[i]}"
    fi
  done
  printf '  %s%s%s  %sthe stack that wires itself%s   %sv%s%s\n\n' \
    "$DR" "$STAR" "$X" "$D" "$X" "$DD" "$NINJARR_VERSION" "$X"
}

step()  { STEP_N=$((STEP_N+1)); shuriken 4; printf '\n%s%s[%d/%d]%s %s%s%s\n' "$DR" "$B" "$STEP_N" "$STEP_TOTAL" "$X" "$W$B" "$1" "$X"; }
ok()    { printf '   %s%s%s %s\n' "$G" "$TICK" "$X" "$1"; }
info()  { printf '   %s%s%s %s\n' "$D" "$ARROW" "$X" "$1"; }
warn()  { printf '   %s%s%s %s\n' "$Y" "!" "$X" "$1"; }
die()   { printf '\n   %s%s%s %s%s%s\n\n' "$R" "$CROSS" "$X" "$R" "$1" "$X"; exit 1; }
rule()  { printf '   %s────────────────────────────────────────────────%s\n' "$DD" "$X"; }

# spinner around a blocking command
spin() {
  local msg="$1"; shift
  local frames=('✦' '✧' '✶' '✷' '✸' '✹' '✺' '✳') i=0
  "$@" >>"$LOG" 2>&1 &
  local pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    printf '\r   %s%s%s %s' "$DR" "${frames[i]}" "$X" "$msg"
    i=$(( (i+1) % ${#frames[@]} )); sleep 0.08
  done
  wait "$pid"; local rc=$?
  printf '\r\033[K'
  if [[ $rc -eq 0 ]]; then ok "$msg"; else printf '   %s%s%s %s\n' "$R" "$CROSS" "$X" "$msg"; return $rc; fi
}

ask() { # ask VAR "prompt" "default"
  local __v=$1 __p=$2 __d=${3:-} __in
  if [[ -n "$__d" ]]; then
    printf '   %s%s%s %s %s[%s]%s ' "$DR" "$ARROW" "$X" "$__p" "$DD" "$__d" "$X"
  else
    printf '   %s%s%s %s ' "$DR" "$ARROW" "$X" "$__p"
  fi
  read -r __in </dev/tty || true
  printf -v "$__v" '%s' "${__in:-$__d}"
}

confirm() {
  local __in
  printf '   %s%s%s %s %s[y/N]%s ' "$DR" "$ARROW" "$X" "$1" "$DD" "$X"
  read -r __in </dev/tty || true
  [[ "${__in,,}" == y* ]]
}

trap 'printf "\n   %s%s%s aborted — see %s\n\n" "$R" "$CROSS" "$X" "$LOG"' ERR

# ═══════════════════════════════════════════════ 1. preflight
preflight() {
  step "Checking the dojo"
  local missing=()
  for c in docker curl jq; do command -v "$c" >/dev/null || missing+=("$c"); done
  [[ ${#missing[@]} -gt 0 ]] && die "missing: ${missing[*]} — install these first"
  docker compose version >/dev/null 2>&1 || die "docker compose v2 not available"
  docker info >/dev/null 2>&1 || die "cannot talk to the docker daemon (are you in the docker group?)"
  ok "docker $(docker version --format '{{.Server.Version}}')"
  ok "compose $(docker compose version --short)"
  ok "curl, jq"
}

persist_ids() { # rewrite PUID/PGID in .env so the answer sticks across runs
  PUID=$1; PGID=$2
  sed -i.bak -e "s/^PUID=.*/PUID=$PUID/" -e "s/^PGID=.*/PGID=$PGID/" "$ENV_FILE"
  rm -f "$ENV_FILE.bak"
  export PUID PGID
  ok "saved $PUID:$PGID to .env"
}

# Never blindly recursive-chown a network filesystem — could be slow over the wire, shared
# with other systems that expect their own ownership, or simply refused depending on how the
# export is configured. Local paths are safe to claim outright; a network path just gets a
# clear warning so the user fixes it deliberately (NAS-side mapping, or PUID/PGID to match).
check_ownership() { # check_ownership LABEL PATH
  local label=$1 path=$2 det_uid det_gid fs_type
  if [[ ! -d "$path" ]]; then
    warn "$path ($label) does not exist yet — it will be created as ${PUID}:${PGID}"
    return
  fi
  det_uid=$(stat -c '%u' "$path"); det_gid=$(stat -c '%g' "$path")
  fs_type=$(stat -f -c '%T' "$path" 2>/dev/null || echo unknown)
  ok "$label ${B}$path${X} owned by ${B}${det_uid}:${det_gid}${X} (${fs_type})"
  [[ "${PUID:-}" == "$det_uid" && "${PGID:-}" == "$det_gid" ]] && return
  if [[ "$det_uid" == "0" ]]; then
    case "$fs_type" in
      nfs*|cifs*|smb*)
        warn "$label is root-owned on a network filesystem — not auto-claiming that over the network. Fix ownership on the NAS side, or chown it yourself, then re-run." ;;
      *)
        info "$label is owned by root — taking ownership as $PUID:$PGID"
        chown -R "$PUID:$PGID" "$path" 2>/dev/null || warn "chown failed — run as root?" ;;
    esac
  else
    warn "your .env says ${PUID:-?}:${PGID:-?} but $label is $det_uid:$det_gid"
    confirm "use the detected $det_uid:$det_gid instead?" && persist_ids "$det_uid" "$det_gid"
  fi
}

# Hardlinks only work within one filesystem — prove it rather than infer it from filesystem
# type alone (bind mounts, overlay setups, etc. can make that guess wrong either way). Same
# manual test this project has always documented (touch, link, check the inode, clean up),
# just automated so it runs every time instead of only when someone remembers to check.
check_hardlink() { # sets LINK_MODE: hardlink | copy | unknown
  LINK_MODE="unknown"
  [[ -d "$DOWNLOADS" && -d "$MEDIA" ]] || return
  local a="$DOWNLOADS/.ninjarr-linktest" b="$MEDIA/.ninjarr-linktest"
  rm -f "$a" "$b" 2>/dev/null
  : > "$a" 2>/dev/null || { rm -f "$a" "$b" 2>/dev/null; return; }
  if ln "$a" "$b" 2>/dev/null; then LINK_MODE="hardlink"; else LINK_MODE="copy"; fi
  rm -f "$a" "$b" 2>/dev/null
}

# Written to Dojo's own config volume (not a new mount) so its Storage panel can show NAS-
# specific guidance only when it's actually relevant, instead of cluttering the dashboard for
# the common case where everything's local and already lines up.
write_storage_status() {
  local media_fs
  media_fs=$(stat -f -c '%T' "$MEDIA" 2>/dev/null || echo unknown)
  jq -n \
    --arg downloads "$DOWNLOADS" --arg media "$MEDIA" --arg media_fs "$media_fs" \
    --arg link_mode "${LINK_MODE:-unknown}" --argjson is_nfs "${IS_NFS:-0}" \
    --arg checked_at "$(date -Iseconds)" \
    '{downloads: $downloads, media: $media, media_fs: $media_fs, link_mode: $link_mode,
      is_nfs: ($is_nfs == 1), checked_at: $checked_at}' \
    > "$APPDATA/dojo/storage-check.json" 2>>"$LOG" || warn "could not write storage status for Dojo"
}

# ═══════════════════════════════════════════════ 2. detect
detect() {
  step "Reading the terrain"

  check_ownership "downloads" "$DOWNLOADS"
  check_ownership "media"     "$MEDIA"

  # --- NFS: media specifically, since that's what a media server actually reads from
  MEDIA_FS_TYPE=$(stat -f -c '%T' "$MEDIA" 2>/dev/null || echo unknown)
  case "$MEDIA_FS_TYPE" in
    nfs*) warn "media is on NFS — inotify will not fire, connect entries are mandatory"; IS_NFS=1 ;;
    *)    ;;
  esac

  check_hardlink
  case "$LINK_MODE" in
    hardlink) ok "downloads and media share one filesystem — imports hardlink instantly" ;;
    copy)     warn "downloads and media are on different filesystems — imports will copy, not hardlink (expected for a remote NAS; costs more time and I/O per import, not broken)" ;;
    *)        warn "could not verify hardlink capability between downloads and media — see log" ;;
  esac
  write_storage_status
}

# ═══════════════════════════════════════════════ 3. env
setup_env() {
  step "Sharpening the config"
  if [[ -f "$ENV_FILE" ]]; then
    ok ".env found"
  else
    info "no .env yet — a few questions and we're done"
    printf '\n'
    ask NEW_DOWNLOADS "where should completed downloads land? (local, fast disk)" "/data/downloads"
    ask NEW_MEDIA     "where's your media library? (this VM, or an already-mounted NAS path)" "/data/media"
    ask NEW_APP       "where should app configs live?" "/opt/appdata"
    ask NEW_INC       "scratch space for unpacking (fast local disk)?" "/opt/incomplete"
    ask NEW_TZ        "timezone?" "$(cat /etc/timezone 2>/dev/null || echo Europe/Zurich)"
    # PUID/PGID aren't worth asking a newbie to guess: if the media library already exists,
    # its owner is the only correct answer — exactly what a NAS mount's real ownership looks
    # like, and what has to match for Sonarr/Radarr to write there at all. Otherwise fall back
    # to whoever's running this script, or 1000:1000 if that's root. detect() still runs right
    # after and offers to fix this if it ever turns out mismatched.
    local du dg
    if [[ -d "$NEW_MEDIA" ]]; then
      du=$(stat -c '%u' "$NEW_MEDIA"); dg=$(stat -c '%g' "$NEW_MEDIA")
      info "media directory already exists — using its owner ${B}${du}:${dg}${X} for PUID/PGID"
    else
      du=$(id -u); dg=$(id -g)
      if [[ "$du" == "0" ]]; then
        du=1000; dg=1000
        info "running as root with no existing media directory yet — defaulting PUID/PGID to ${B}1000:1000${X}"
      else
        info "using your account's ${B}${du}:${dg}${X} for PUID/PGID"
      fi
    fi
    NEW_UID=$du
    NEW_GID=$dg
    cat > "$ENV_FILE" <<EOF
# generated by ninjarr $(date -Iseconds)
PUID=$NEW_UID
PGID=$NEW_GID
TZ=$NEW_TZ
DOWNLOADS=$NEW_DOWNLOADS
MEDIA=$NEW_MEDIA
APPDATA=$NEW_APP
INCOMPLETE=$NEW_INC
EOF
    printf '\n'; ok "wrote .env"
  fi
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
  : "${DOWNLOADS:?}" "${MEDIA:?}" "${APPDATA:?}" "${INCOMPLETE:?}" "${PUID:?}" "${PGID:?}"
  mkdir -p "$APPDATA" "$APPDATA/dojo" "$INCOMPLETE" "$DOWNLOADS" "$MEDIA/movies" "$MEDIA/tv"
  # seerr and recyclarr both run as uid 1000 internally, ignoring PUID/PGID
  mkdir -p "$APPDATA/seerr" && chown -R 1000:1000 "$APPDATA/seerr" 2>/dev/null || true
  mkdir -p "$APPDATA/recyclarr" && chown -R 1000:1000 "$APPDATA/recyclarr" 2>/dev/null || true
  # DOWNLOADS is always local by convention, safe to claim outright here. MEDIA might be a NAS
  # mount — ownership there is detect()'s job, since a blind recursive chown over the network
  # could be slow, unwanted, or simply not permitted depending on how the export is configured.
  chown -R "$PUID:$PGID" "$DOWNLOADS" "$INCOMPLETE" 2>/dev/null || \
    warn "could not chown $DOWNLOADS — check it is writable by $PUID:$PGID"
  chown -R 1000:1000 "$APPDATA/seerr" "$APPDATA/recyclarr" 2>/dev/null || true
  ok "directory tree ready, owned $PUID:$PGID"
}

# ═══════════════════════════════════════════════ 4. up
compose_up() {
  step "Summoning the clan"
  spin "pulling images (this is the slow bit)" docker compose --env-file "$ENV_FILE" --project-directory "$ROOT" -f "$ROOT/compose/core.yml" pull
  spin "starting containers"                   docker compose --env-file "$ENV_FILE" --project-directory "$ROOT" -f "$ROOT/compose/core.yml" up -d
  docker compose --env-file "$ENV_FILE" --project-directory "$ROOT" -f "$ROOT/compose/core.yml" ps --format '{{.Name}}' | while read -r n; do info "$n"; done
}

wait_http() { # wait_http NAME URL TIMEOUT
  local name=$1 url=$2 timeout=${3:-120} t=0
  local frames=('✦' '✧' '✶' '✷' '✸' '✹' '✺' '✳') i=0
  while (( t < timeout )); do
    if curl -fsS --max-time 3 -o /dev/null "$url" 2>/dev/null; then
      printf '\r\033[K'; ok "$name is up"; return 0
    fi
    printf '\r   %s%s%s waiting for %s %s(%ds)%s' "$DR" "${frames[i]}" "$X" "$name" "$DD" "$t" "$X"
    i=$(( (i+1) % ${#frames[@]} )); sleep 2; t=$((t+2))
  done
  printf '\r\033[K'; warn "$name did not answer in ${timeout}s — skipping its wiring"
  return 1
}

# ═══════════════════════════════════════════════ 5. keys
grab_keys() {
  step "Stealing the keys"
  SAB_KEY=$(awk -F' *= *' '/^api_key/{print $2; exit}' "$APPDATA/sabnzbd/sabnzbd.ini" 2>/dev/null || true)
  SON_KEY=$(sed -n 's:.*<ApiKey>\(.*\)</ApiKey>.*:\1:p' "$APPDATA/sonarr/config.xml" 2>/dev/null || true)
  RAD_KEY=$(sed -n 's:.*<ApiKey>\(.*\)</ApiKey>.*:\1:p' "$APPDATA/radarr/config.xml" 2>/dev/null || true)
  PRO_KEY=$(sed -n 's:.*<ApiKey>\(.*\)</ApiKey>.*:\1:p' "$APPDATA/prowlarr/config.xml" 2>/dev/null || true)
  # Bazarr's key lives under the "auth:" block of its YAML config — plex/jellyfin sections also
  # have an "apikey" key, so this has to stay scoped to auth: rather than grep the whole file.
  BAZ_KEY=$(awk '/^auth:/{f=1;next} /^[^ ]/{f=0} f && /^[[:space:]]*apikey:/{print $2; exit}' \
            "$APPDATA/bazarr/config/config.yaml" 2>/dev/null | tr -d '"\047' || true)
  for pair in "SABnzbd:$SAB_KEY" "Sonarr:$SON_KEY" "Radarr:$RAD_KEY" "Prowlarr:$PRO_KEY" "Bazarr:$BAZ_KEY"; do
    local n=${pair%%:*} k=${pair#*:}
    if [[ -n "$k" ]]; then ok "$n  ${DD}${k:0:8}…${X}"; else warn "$n key not found (first run may need another minute)"; fi
  done
}

# Dojo reads this fresh on every request — no restart needed when a key shows up late (e.g. an
# app's first boot ran slower than the others). Any key not yet found is simply omitted; dojo
# reports that service as "no key yet" rather than erroring.
write_dojo_keys() {
  jq -n \
    --arg son "${SON_KEY:-}" --arg rad "${RAD_KEY:-}" --arg pro "${PRO_KEY:-}" \
    --arg sab "${SAB_KEY:-}" --arg baz "${BAZ_KEY:-}" \
    '{SON_KEY: $son, RAD_KEY: $rad, PRO_KEY: $pro, SAB_KEY: $sab, BAZ_KEY: $baz}
     | with_entries(select(.value != ""))' > "$APPDATA/dojo/keys.json" \
    && ok "wrote dojo config" \
    || warn "could not write dojo config — see log"
}

api() { # api METHOD BASE PATH KEY [json]
  local m=$1 base=$2 path=$3 key=$4 body=${5:-} out code resp
  if [[ -n "$body" ]]; then
    out=$(curl -sS -w $'\n%{http_code}' -X "$m" "$base$path" -H "X-Api-Key: $key" \
          -H 'Content-Type: application/json' -d "$body" 2>>"$LOG") || return 1
  else
    out=$(curl -sS -w $'\n%{http_code}' -X "$m" "$base$path" -H "X-Api-Key: $key" 2>>"$LOG") || return 1
  fi
  code=${out##*$'\n'}; resp=${out%$'\n'*}
  [[ "$code" =~ ^2 ]] && { printf '%s' "$resp"; return 0; }
  printf 'API %s %s -> HTTP %s\n%s\n\n' "$m" "$path" "$code" "$resp" >>"$LOG"
  return 1
}

# SABnzbd authenticates via an apikey query parameter, not the X-Api-Key header the arrs use,
# so it needs its own helper rather than reusing api(). It also reports failures with HTTP 200
# and {"status": false}, so a 2xx code alone doesn't mean success.
sab_api() { # sab_api MODE [key=value ...]
  local mode=$1; shift
  local -a curl_args=(-sS -w $'\n%{http_code}' -G "$SAB/api"
    --data-urlencode "mode=$mode" --data-urlencode "output=json" --data-urlencode "apikey=$SAB_KEY")
  local kv
  for kv in "$@"; do curl_args+=(--data-urlencode "$kv"); done
  local out code resp
  out=$(curl "${curl_args[@]}" 2>>"$LOG") || return 1
  code=${out##*$'\n'}; resp=${out%$'\n'*}
  if [[ "$code" =~ ^2 ]] && jq -e '.status != false' <<<"$resp" >/dev/null 2>&1; then
    printf '%s' "$resp"; return 0
  fi
  printf 'SAB API mode=%s -> HTTP %s\n%s\n\n' "$mode" "$code" "$resp" >>"$LOG"
  return 1
}

# Bazarr authenticates via an X-API-KEY header and, unlike the arrs, has no per-resource JSON API
# for settings — everything (connections, default profiles) goes through one form-encoded POST to
# /api/system/settings. Verified against bazarr/api/system/settings.py and app/config.py upstream:
# form keys are "settings-<section>-<field>", only submitted keys change (existing settings are
# left alone), and booleans must be the literal strings "true"/"false".
bazarr_api() { # bazarr_api METHOD PATH [form-field=value ...]
  local m=$1 path=$2; shift 2
  local -a curl_args=(-sS -w $'\n%{http_code}' -X "$m" "$BAZ$path" -H "X-API-KEY: $BAZ_KEY")
  local kv
  for kv in "$@"; do curl_args+=(--data-urlencode "$kv"); done
  local out code resp
  out=$(curl "${curl_args[@]}" 2>>"$LOG") || return 1
  code=${out##*$'\n'}; resp=${out%$'\n'*}
  [[ "$code" =~ ^2 ]] && { printf '%s' "$resp"; return 0; }
  printf 'Bazarr API %s %s -> HTTP %s\n%s\n\n' "$m" "$path" "$code" "$resp" >>"$LOG"
  return 1
}

# Bazarr's languages-profiles endpoint is read-only (GET, list only) — profiles are created
# through the settings endpoint as a JSON-encoded string, wrapped in an array, in the
# "languages-profiles" field. profileId is caller-assigned, not server-generated, so the
# reference file's id becomes the real id. Sets BAZ_PROFILE_ID rather than returning it on
# stdout, since ok/info/warn already write to stdout and would corrupt a captured value.
bazarr_languages_profile() { # bazarr_languages_profile JSONFILE
  local f=$1 name existing
  [[ -f "$f" ]] || { warn "no Bazarr languages profile reference file"; return 1; }
  name=$(jq -r .name "$f")
  BAZ_PROFILE_ID=$(jq -r .profileId "$f")

  existing=$(bazarr_api GET /api/system/languages/profiles) || { warn "could not read Bazarr languages profiles — see log"; return 1; }
  if jq -e --arg n "$name" 'any(.[]?; .name == $n)' <<<"$existing" >/dev/null 2>&1; then
    info "Bazarr languages profile '$name' already present"
    return 0
  fi

  local -a args=("languages-profiles=$(jq -c '[.]' "$f")")
  local l
  for l in $(jq -r '[.items[].language] | unique | .[]' "$f"); do args+=("languages-enabled=$l"); done

  bazarr_api POST /api/system/settings "${args[@]}" >/dev/null \
    && ok "Bazarr languages profile '$name' created" \
    || { warn "Bazarr languages profile '$name' failed — see log"; return 1; }
}

# Connects Bazarr to Sonarr/Radarr and assigns the default languages profile. DEFAULT_PREFIX is
# "serie" for Sonarr and "movie" for Radarr — Bazarr's general.* keys don't mirror the app name,
# so this is passed explicitly rather than derived, to avoid guessing at a naming convention.
bazarr_connect() { # bazarr_connect APP HOST PORT KEY DEFAULT_PREFIX PROFILE_ID
  local app=$1 host=$2 port=$3 key=$4 prefix=$5 pid=$6 current
  current=$(bazarr_api GET /api/system/settings) || { warn "could not read Bazarr settings — see log"; return 1; }
  if jq -e --arg a "$app" --arg k "$key" --argjson p "$pid" --arg pre "$prefix" \
       '.[$a].apikey == $k and .[$a].only_monitored == true and .general[$pre+"_default_profile"] == $p and .general[$pre+"_default_enabled"] == true' \
       <<<"$current" >/dev/null 2>&1; then
    info "Bazarr already connected to $app"
    return 0
  fi
  # Download Only Monitored keeps Bazarr from fetching subtitles for episodes/movies the arr
  # isn't tracking (unmonitored back catalogue, excluded specials) — matching what the arrs
  # themselves would grab.
  bazarr_api POST /api/system/settings \
    "settings-general-use_${app}=true" \
    "settings-${app}-ip=${host}" \
    "settings-${app}-port=${port}" \
    "settings-${app}-base_url=/" \
    "settings-${app}-ssl=false" \
    "settings-${app}-apikey=${key}" \
    "settings-${app}-only_monitored=true" \
    "settings-general-${prefix}_default_enabled=true" \
    "settings-general-${prefix}_default_profile=${pid}" \
    >/dev/null && ok "Bazarr connected to $app (profile $pid, only monitored)" \
    || { warn "Bazarr $app connection failed — see log"; return 1; }
}

wire_bazarr() {
  [[ -n "${BAZ_KEY:-}" ]] || { warn "no Bazarr API key yet — skipping Bazarr wiring"; return 1; }
  bazarr_languages_profile "$ROOT/config/languages-profiles/bazarr.json" || return 1
  if [[ -n "${SON_KEY:-}" ]]; then
    bazarr_connect sonarr sonarr 8989 "$SON_KEY" serie "$BAZ_PROFILE_ID" || warn "Bazarr→Sonarr connection failed — see log"
  fi
  if [[ -n "${RAD_KEY:-}" ]]; then
    bazarr_connect radarr radarr 7878 "$RAD_KEY" movie "$BAZ_PROFILE_ID" || warn "Bazarr→Radarr connection failed — see log"
  fi
}

# SABnzbd rejects requests addressed to a hostname that is not whitelisted.
# Sonarr connects as http://sabnzbd:8080, gets 403, and reports a 400 on save.
whitelist_sabnzbd() {
  local ini="$APPDATA/sabnzbd/sabnzbd.ini"
  [[ -f "$ini" ]] || { warn "sabnzbd.ini not found yet"; return 0; }
  grep -q '^host_whitelist *= *sabnzbd' "$ini" && { info "host_whitelist already set"; return 0; }
  docker stop sabnzbd >>"$LOG" 2>&1          # it rewrites the ini on shutdown
  if grep -q '^host_whitelist' "$ini"; then
    sed -i 's/^host_whitelist.*/host_whitelist = sabnzbd,localhost/' "$ini"
  else
    sed -i '/^\[misc\]/a host_whitelist = sabnzbd,localhost' "$ini"
  fi
  docker start sabnzbd >>"$LOG" 2>&1
  ok "SABnzbd host_whitelist set"
  wait_http SABnzbd "http://localhost:8080" 90 || true
}

# SAB defaults complete_dir/download_dir to paths under its own /config that nothing else in the
# stack can see. Point both at the compose-mounted paths so a category's relative "dir" (tv/movies)
# resolves to somewhere Sonarr/Radarr actually share via their own /data mount — otherwise they
# report the download client's output directory as missing inside their own container.
sab_storage_paths() {
  local current
  current=$(sab_api get_config section=misc) || { warn "could not read SAB storage paths — see log"; return 1; }
  if jq -e '.config.misc.complete_dir == "/data/usenet/complete" and .config.misc.download_dir == "/data/usenet/incomplete"' <<<"$current" >/dev/null 2>&1; then
    info "SAB storage paths already set"
    return 0
  fi
  # set_config on a flat section (misc) sets exactly one option per call — it looks up
  # CFG_DATABASE[section][keyword] and reads the new value from "value", not from a
  # top-level "complete_dir=..." kwarg the way categories/servers/rss accept multiple fields.
  sab_api set_config section=misc keyword=complete_dir value=/data/usenet/complete >/dev/null \
    && sab_api set_config section=misc keyword=download_dir value=/data/usenet/incomplete >/dev/null \
    && ok "SAB storage paths set (complete, incomplete)" \
    || warn "SAB storage paths failed — see log"
}

# Direct Unpack extracts into complete_dir on the NAS while the download is still running,
# saturating it at close to line rate and starving SABnzbd's own web/API threads — which then
# stop answering, so Sonarr/Radarr mark the job failed and grab a replacement, adding load to
# the thing that was already overloaded. Off is correct regardless of hardware; it just costs
# wall-clock time (download then unpack, sequentially, instead of overlapped). Pausing during
# post-processing avoids a second failure mode: unpacking competing with the next download for
# the same local disk. Both default off in SAB itself and are known to drift back on via the
# setup wizard, an upgrade, or a config restore, so this is worth reasserting on every run.
sab_unpack_safety() {
  local current
  current=$(sab_api get_config section=misc) || { warn "could not read SAB unpack settings — see log"; return 1; }
  # OptionBool serializes as integer 0/1 over the API, not JSON true/false — SAB's own
  # get_dict()/__call__() explicitly cast to int "since many places assume 0/1".
  if jq -e '.config.misc.direct_unpack == 0 and .config.misc.pause_on_post_processing == 1' <<<"$current" >/dev/null 2>&1; then
    info "SAB unpack safety settings already set"
    return 0
  fi
  sab_api set_config section=misc keyword=direct_unpack value=0 >/dev/null \
    && sab_api set_config section=misc keyword=pause_on_post_processing value=1 >/dev/null \
    && ok "SAB unpack safety set (Direct Unpack off, pause during post-processing)" \
    || warn "SAB unpack safety settings failed — see log"
}

# Build a payload from the app's own schema instead of hardcoding field lists —
# the arrs change field names between versions and a hardcoded body breaks silently.
add_download_client() { # add_download_client BASE KEY APIV CATEGORY
  local base=$1 key=$2 v=$3 cat=$4
  api GET "$base" "/api/$v/downloadclient" "$key" | jq -e '.[] | select(.implementation=="Sabnzbd")' >/dev/null 2>&1 && {
    info "download client already present"; return 0; }
  local schema payload
  schema=$(api GET "$base" "/api/$v/downloadclient/schema" "$key" \
           | jq '.[] | select(.implementation=="Sabnzbd")')
  [[ -z "$schema" ]] && { warn "no Sabnzbd schema exposed"; return 1; }
  payload=$(jq -c --arg key "$SAB_KEY" --arg cat "$cat" '
    .name = "SABnzbd" | .enable = true |
    .fields |= map(
      if   .name == "host"     then .value = "sabnzbd"
      elif .name == "port"     then .value = 8080
      elif .name == "apiKey"   then .value = $key
      elif .name == "category" or .name == "tvCategory" or .name == "movieCategory" then .value = $cat
      else . end)' <<<"$schema")
  api POST "$base" "/api/$v/downloadclient" "$key" "$payload" >/dev/null && ok "SABnzbd wired ($cat)"
}

add_root_folder() { # add_root_folder BASE KEY APIV PATH
  local base=$1 key=$2 v=$3 p=$4
  api GET "$base" "/api/$v/rootfolder" "$key" | jq -e --arg p "$p" '.[]|select(.path==$p)' >/dev/null 2>&1 && {
    info "root folder $p already set"; return 0; }
  api POST "$base" "/api/$v/rootfolder" "$key" "$(jq -nc --arg p "$p" '{path:$p}')" >/dev/null \
    && ok "root folder $p"
}

# Custom formats and quality profiles are no longer hand-built here — Recyclarr owns both,
# pulling TRaSH Guides' actual maintained definitions (see write_recyclarr_config below) rather
# than this script's own hand-rolled regex and scoring. Real language-detection based matching,
# not a title regex, and far more thoroughly tuned than anything worth maintaining by hand here.

# Reference files (config/quality-profiles/, config/custom-formats/) and the schema-driven
# profile-building code that read them were removed along with this — see git history if you
# need to see what the hand-rolled version looked like.

# recyclarr.yml is built by concatenating a Sonarr and a Radarr TRaSH-preset template
# (dojo/recyclarr-templates/{sonarr,radarr}/<preset>.yml — both top-level keys, sonarr: and
# radarr:, coexist fine in one file) with the placeholder base_url/api_key lines swapped for the
# real ones. Matched by key name via a POSIX character class, not the placeholder wording itself
# (GNU sed's \s isn't in BSD sed, and the exact wording isn't guaranteed to survive an upstream
# template update either way).
write_recyclarr_config() { # write_recyclarr_config PRESET
  local preset=$1
  local son_tmpl="$ROOT/dojo/recyclarr-templates/sonarr/$preset.yml"
  local rad_tmpl="$ROOT/dojo/recyclarr-templates/radarr/$preset.yml"
  if [[ ! -f "$son_tmpl" || ! -f "$rad_tmpl" ]]; then
    warn "unknown recyclarr preset '$preset'"; return 1
  fi
  {
    sed -e "s|^\([[:space:]]*base_url:\).*|\1 http://sonarr:8989|" \
        -e "s|^\([[:space:]]*api_key:\).*|\1 $SON_KEY|" "$son_tmpl"
    printf '\n'
    sed -e "s|^\([[:space:]]*base_url:\).*|\1 http://radarr:7878|" \
        -e "s|^\([[:space:]]*api_key:\).*|\1 $RAD_KEY|" "$rad_tmpl"
  } > "$APPDATA/recyclarr/recyclarr.yml" \
    && printf '%s' "$preset" > "$APPDATA/recyclarr/.applied-preset" \
    && ok "recyclarr config written (preset: $preset)" \
    || { warn "could not write recyclarr config — see log"; return 1; }
}

# The recyclarr container is already up by this point (compose_up brought up every service) and
# its watch.sh is already polling for /config/.trigger — reuse that instead of a second, sepa-
# rately-configured docker run. One code path for "apply a preset", same one Dojo's on-demand
# trigger uses, rather than guessing at the compose project's network name to invoke a standalone
# container (that name isn't pinned anywhere — it's derived from the clone directory's basename).
sync_recyclarr() {
  [[ -f "$APPDATA/recyclarr/recyclarr.yml" ]] || { warn "no recyclarr.yml to sync"; return 1; }
  local last_sync=$APPDATA/recyclarr/.last-sync before after
  local frames=('✦' '✧' '✶' '✷' '✸' '✹' '✺' '✳') i=0 t=0 timeout=180
  before=$(cat "$last_sync" 2>/dev/null || true)
  : > "$APPDATA/recyclarr/.trigger"
  while (( t < timeout )); do
    after=$(cat "$last_sync" 2>/dev/null || true)
    if [[ -n "$after" && "$after" != "$before" ]]; then
      printf '\r\033[K'; ok "recyclarr sync complete"; return 0
    fi
    printf '\r   %s%s%s syncing custom formats & quality profiles %s(%ds)%s' "$DR" "${frames[i]}" "$X" "$DD" "$t" "$X"
    i=$(( (i+1) % ${#frames[@]} )); sleep 3; t=$((t+3))
  done
  printf '\r\033[K'; warn "recyclarr sync did not finish in ${timeout}s — check: docker logs recyclarr"
  return 1
}

# Media Management and Naming are singleton config resources — GET returns one object with its
# own id, PUT sends the same object back — not a list you POST new items into, and there's no
# /schema endpoint to build a payload from. GET first and flip only the fields that matter, so
# whatever else the user has configured there survives untouched.
#
# Hardlinks off doubles disk usage on every import (a straight copy instead of a link) — safe to
# force on regardless of environment. Auto-unmonitoring a deleted file stops a re-scan from
# silently re-requesting something that was deliberately removed.
set_media_management() { # set_media_management BASE KEY APIV UNMONITOR_FIELD
  local base=$1 key=$2 v=$3 unmonitor_field=$4 current id payload
  current=$(api GET "$base" "/api/$v/config/mediamanagement" "$key") || { warn "could not read media management config — see log"; return 1; }
  if jq -e --arg f "$unmonitor_field" '.copyUsingHardlinks == true and .[$f] == true' <<<"$current" >/dev/null 2>&1; then
    info "media management already set (hardlinks, unmonitor deleted)"
    return 0
  fi
  id=$(jq -r .id <<<"$current")
  payload=$(jq -c --arg f "$unmonitor_field" '.copyUsingHardlinks = true | .[$f] = true' <<<"$current")
  api PUT "$base" "/api/$v/config/mediamanagement/$id" "$key" "$payload" >/dev/null \
    && ok "media management set (hardlinks on, unmonitor deleted on)" \
    || { warn "media management update failed — see log"; return 1; }
}

set_naming_rename() { # set_naming_rename BASE KEY APIV RENAME_FIELD
  local base=$1 key=$2 v=$3 rename_field=$4 current id payload
  current=$(api GET "$base" "/api/$v/config/naming" "$key") || { warn "could not read naming config — see log"; return 1; }
  if jq -e --arg f "$rename_field" '.[$f] == true' <<<"$current" >/dev/null 2>&1; then
    info "renaming already enabled"
    return 0
  fi
  id=$(jq -r .id <<<"$current")
  payload=$(jq -c --arg f "$rename_field" '.[$f] = true' <<<"$current")
  api PUT "$base" "/api/$v/config/naming/$id" "$key" "$payload" >/dev/null \
    && ok "renaming enabled" \
    || { warn "renaming update failed — see log"; return 1; }
}

link_prowlarr() { # link_prowlarr NAME APPURL APPKEY IMPL
  local name=$1 appurl=$2 appkey=$3 impl=$4
  api GET "$PRO" "/api/v1/applications" "$PRO_KEY" | jq -e --arg n "$name" '.[]|select(.name==$n)' >/dev/null 2>&1 && {
    info "$name already linked to Prowlarr"; return 0; }
  local schema payload
  schema=$(api GET "$PRO" "/api/v1/applications/schema" "$PRO_KEY" | jq --arg i "$impl" '.[]|select(.implementation==$i)')
  [[ -z "$schema" ]] && { warn "no $impl schema in Prowlarr"; return 1; }
  payload=$(jq -c --arg n "$name" --arg u "$appurl" --arg k "$appkey" '
    .name = $n | .syncLevel = "fullSync" |
    .fields |= map(
      if   .name == "prowlarrUrl" then .value = "http://prowlarr:9696"
      elif .name == "baseUrl"     then .value = $u
      elif .name == "apiKey"      then .value = $k
      else . end)' <<<"$schema")
  api POST "$PRO" "/api/v1/applications" "$PRO_KEY" "$payload" >/dev/null && ok "$name linked to Prowlarr"
}

# An older version of this script tried to create categories by appending raw [[tv]]/[[movies]]
# blocks to sabnzbd.ini. On a fresh install there's no [categories] section yet for those blocks
# to land in, so they end up as inert junk at EOF. SAB's ConfigCat never writes a "name = " line
# inside a category block (the name lives only in the [[section header]]), so its presence is an
# unambiguous fingerprint of that old bug. Anyone who ran the broken version needs a re-run to
# pick up this cleanup — there's nothing to detect until then.
heal_orphaned_sab_categories() {
  local ini=$1 orphans
  orphans=$(awk '
    function flush() { if (in_blk && has_name) print hdr; in_blk=0; has_name=0 }
    /^\[/ {
      flush()
      if ($0 == "[[tv]]" || $0 == "[[movies]]") { hdr=$0; in_blk=1 }
      next
    }
    in_blk && /^name = / { has_name=1; next }
    END { flush() }
  ' "$ini")
  [[ -z "$orphans" ]] && return 0

  warn "stripping orphaned SAB category block(s) from an older ninjarr version: $(tr '\n' ' ' <<<"$orphans")"
  docker stop sabnzbd >>"$LOG" 2>&1        # SAB rewrites the ini on shutdown
  local tmp; tmp=$(mktemp)
  awk '
    function flush() { if (capturing && !drop) printf "%s", buf; buf=""; capturing=0; drop=0 }
    /^\[/ {
      flush()
      if ($0 == "[[tv]]" || $0 == "[[movies]]") { capturing=1; buf=$0 ORS; next }
    }
    capturing { buf = buf $0 ORS; if ($0 ~ /^name = /) drop=1; next }
    { print }
    END { flush() }
  ' "$ini" > "$tmp" && mv "$tmp" "$ini"
  docker start sabnzbd >>"$LOG" 2>&1
  wait_http SABnzbd "$SAB" 90 || true
  ok "orphaned category blocks removed"
}

# The arrs refuse a download client whose category is unknown to SAB. Create tv/movies over the
# API — it applies live, no container restart needed — rather than editing the ini directly.
sab_categories() {
  local ini="$APPDATA/sabnzbd/sabnzbd.ini" c
  [[ -f "$ini" ]] || { warn "sabnzbd.ini missing"; return 0; }
  [[ -n "${SAB_KEY:-}" ]] || { warn "no SABnzbd API key yet — skipping categories"; return 1; }

  heal_orphaned_sab_categories "$ini"

  local existing
  existing=$(sab_api get_config section=categories) || { warn "could not read SAB categories — see log"; return 1; }

  for c in tv movies; do
    if jq -e --arg c "$c" '.config.categories[]? | select(.name==$c)' <<<"$existing" >/dev/null 2>&1; then
      info "SAB category '$c' already present"
      continue
    fi
    sab_api set_config section=categories "keyword=$c" "dir=$c" "pp=3" "script=None" "priority=-100" >/dev/null \
      && ok "SAB category '$c' created" \
      || warn "SAB category '$c' creation failed — see log"
  done

  local verify
  verify=$(sab_api get_config section=categories) || { warn "could not verify SAB categories — see log"; return 1; }
  for c in tv movies; do
    jq -e --arg c "$c" '.config.categories[]? | select(.name==$c)' <<<"$verify" >/dev/null 2>&1 \
      || { warn "SAB category '$c' missing after creation"; printf 'sab_categories verify failed for %s:\n%s\n\n' "$c" "$verify" >>"$LOG"; }
  done
}

# ═══════════════════════════════════════════════ 6. wire
wire() {
  step "Tying it all together"
  SON="http://localhost:8989"; RAD="http://localhost:7878"
  PRO="http://localhost:9696"; SAB="http://localhost:8080"
  BAZ="http://localhost:6767"

  wait_http SABnzbd  "$SAB" 180 || true
  wait_http Sonarr   "$SON/ping" 180 || true
  wait_http Radarr   "$RAD/ping" 180 || true
  wait_http Prowlarr "$PRO/ping" 180 || true
  wait_http Bazarr   "$BAZ" 180 || true
  wait_http Seerr    "http://localhost:5055" 180 || true
  wait_http Dojo     "http://localhost:1337" 60 || true
  grab_keys
  write_dojo_keys
  rule
  whitelist_sabnzbd || warn "SABnzbd host_whitelist failed — see log"
  sab_storage_paths || warn "SAB storage paths failed — see log"
  sab_unpack_safety || warn "SAB unpack safety settings failed — see log"
  sab_categories || warn "SAB categories failed — see log"

  if [[ -n "${SON_KEY:-}" ]]; then
    add_download_client "$SON" "$SON_KEY" v3 tv || warn "Sonarr download client failed — see log"
    add_root_folder     "$SON" "$SON_KEY" v3 "/data/media/tv" || warn "Sonarr root folder failed"
    set_media_management "$SON" "$SON_KEY" v3 autoUnmonitorPreviouslyDownloadedEpisodes || warn "Sonarr media management failed"
    set_naming_rename    "$SON" "$SON_KEY" v3 renameEpisodes || warn "Sonarr renaming failed"
  fi
  if [[ -n "${RAD_KEY:-}" ]]; then
    add_download_client "$RAD" "$RAD_KEY" v3 movies || warn "Radarr download client failed — see log"
    add_root_folder     "$RAD" "$RAD_KEY" v3 "/data/media/movies" || warn "Radarr root folder failed"
    set_media_management "$RAD" "$RAD_KEY" v3 autoUnmonitorPreviouslyDownloadedMovies || warn "Radarr media management failed"
    set_naming_rename    "$RAD" "$RAD_KEY" v3 renameMovies || warn "Radarr renaming failed"
  fi
  if [[ -n "${SON_KEY:-}" && -n "${RAD_KEY:-}" ]]; then
    write_recyclarr_config "$RECYCLARR_DEFAULT_PRESET" && sync_recyclarr \
      || warn "recyclarr custom formats / quality profiles failed — see log"
  else
    warn "Sonarr/Radarr keys not both available yet — skipping recyclarr sync"
  fi
  wire_bazarr || warn "Bazarr wiring failed — see log"
  if [[ -n "${PRO_KEY:-}" ]]; then
    [[ -n "${SON_KEY:-}" ]] && { link_prowlarr Sonarr "http://sonarr:8989" "$SON_KEY" Sonarr || warn "Prowlarr→Sonarr link failed"; }
    [[ -n "${RAD_KEY:-}" ]] && { link_prowlarr Radarr "http://radarr:7878" "$RAD_KEY" Radarr || warn "Prowlarr→Radarr link failed"; }
  fi
}

# ═══════════════════════════════════════════════ 7. done
summary() {
  step "Mission report"
  rule
  printf '   %-14s %s\n' "SERVICE" "URL"
  rule
  local ip; ip=$(hostname -I 2>/dev/null | awk '{print $1}'); ip=${ip:-localhost}
  while read -r name port; do
    printf '   %s%-14s%s %shttp://%s:%s%s\n' "$W" "$name" "$X" "$D" "$ip" "$port" "$X"
  done <<EOF
Seerr 5055
Sonarr 8989
Radarr 7878
Prowlarr 9696
SABnzbd 8080
Bazarr 6767
Dojo 1337
EOF
  rule
  printf '\n   %s%sStill yours to do:%s\n' "$W" "$B" "$X"
  printf '   %s1.%s SABnzbd  → add your Usenet provider (host, port 563, SSL on)\n' "$DR" "$X"
  printf '   %s2.%s Prowlarr → add your indexer, then %sSync App Indexers%s\n' "$DR" "$X" "$W" "$X"
  printf '   %s3.%s Seerr    → run the wizard, pick your media server\n' "$DR" "$X"
  printf '   %s4.%s Bazarr   → Settings → Subtitles Providers, enable at least one\n' "$DR" "$X"
  printf '        (e.g. OpenSubtitles.com) — without one, subtitle search finds nothing\n'
  if [[ "${IS_NFS:-0}" == "1" ]]; then
    printf '   %s5.%s %sNFS detected%s — add a Connect entry in Sonarr/Radarr for your\n' "$DR" "$X" "$Y" "$X"
    printf '        media server, or new files will never appear. inotify does not\n'
    printf '        fire over NFS. This is not optional.\n'
  fi

  # hardcoded to the title's real 22-column width, not ${#title} — that's byte length, not
  # character count, under a non-UTF-8 locale (LC_ALL=C, common on a fresh minimal LXC/VM),
  # so ✦'s 3 UTF-8 bytes would counted as 3 columns instead of 1 and skew the border
  local title=" ✦ MISSION COMPLETE ✦ " border="══════════════════════"
  printf '\n   %s╔%s╗%s\n' "$DR" "$border" "$X"
  printf   '   %s║%s%s%s%s%s║%s\n' "$DR" "$X" "$W$B" "$title" "$X" "$DR" "$X"
  printf   '   %s╚%s╝%s\n' "$DR" "$border" "$X"

  printf '\n   %s%s%s log: %s\n\n' "$DR" "$STAR" "$X" "$LOG"
}

# ═══════════════════════════════════════════════ main
main() {
  : > "$LOG"
  banner
  preflight
  setup_env
  detect
  compose_up
  wire
  summary
}
main "$@"
