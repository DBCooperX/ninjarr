# shellcheck shell=bash
# ninjarr — trying a newer app version than ninjarr tested, safely, without waiting for a release.
#
#   ./bootstrap.sh try-version APP TAG   snapshot APP's data, move it to TAG, run the full check;
#                                        if anything fails, put the old version and data back
#   ./bootstrap.sh revert-version APP    go back to the version (and data) from before the try
#
# A tried version is a *_TAG line in ninjarr.env, which overrides versions.env. Once a ninjarr
# update brings the same or a newer version, the line is dropped and the app is back on ninjarr's
# tested versions (drop_outdated_overrides, run by every update).

TRY_APPS=(aiostreams prowlarr sonarr radarr bazarr emby seerr dispatcharr)
TRY_DIR="$ROOT/.state/tries"

app_port() { case $1 in aiostreams) echo 3000;; prowlarr) echo 9696;; sonarr) echo 8989;; radarr) echo 7878;;
             bazarr) echo 6767;; emby) echo 8096;; seerr) echo 5055;; dispatcharr) echo 9191;; esac; }
tested_tag() { sed -n "s/^${1^^}_TAG='\(.*\)'.*/\1/p" "$ROOT/versions.env"; }
running_tag() { local k="${1^^}_TAG"; printf '%s' "${!k:-$(tested_tag "$1")}"; }
newer_than() { [[ "$1" != "$2" && "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" == "$1" ]]; }

env_unset() { # env_unset KEY — drop a key from ninjarr.env (written by env_save)
  local -a keep=() x
  for x in "${ENV_KEYS[@]}"; do [[ "$x" == "$1" ]] || keep+=("$x"); done
  ENV_KEYS=("${keep[@]}")
  unset "$1"
}

# The app's data folder, as it is now, without logs and caches (the backup's exclusions)
snapshot_app() { # snapshot_app APP FILE
  local -a ex=() x
  for x in "${BACKUP_EXCLUDES[@]}"; do ex+=(--exclude="$x"); done
  tar -C "$NINJARR_DATA/appdata" "${ex[@]}" -czf "$2" "./$1" 2>>"$LOG"
}

# Put a snapshot back exactly (a database folder must match), keeping the caches it left out
restore_app() { # restore_app APP FILE
  local d="$NINJARR_DATA/appdata/$1" old p
  old="$d.tried-$(date +%Y%m%d-%H%M%S)"
  mv "$d" "$old" || return 1
  tar -C "$NINJARR_DATA/appdata" -xzf "$2" 2>>"$LOG" || { rm -rf "$d"; mv "$old" "$d"; return 1; }
  for p in logs log cache Backups MediaCover metadata transcoding-temp backups recordings; do
    [[ -e "$old/$p" && ! -e "$d/$p" ]] && mv "$old/$p" "$d/$p"
  done
  rm -rf "$old"
}

app_up() { # app_up APP — pull its image, (re)start it, wait until it answers
  spin "pulling $1 $(running_tag "$1")" compose pull "$1" || return 1
  spin "starting $1" compose up -d --no-deps "$1" || return 1
  wait_http "${1^}" "http://localhost:$(app_port "$1")" 300
}

try_version() { # try_version APP TAG
  local app=$1 tag=$2 key from snap ts
  [[ " ${TRY_APPS[*]} " == *" $app "* ]] || die "not an app ninjarr runs: $app"
  [[ "$tag" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || die "not a version: $tag"
  env_load || die "no ninjarr.env — run ./bootstrap.sh first"
  [[ "$app" == dispatcharr && "${IPTV:-no}" != yes ]] && die "Live TV is off, so Dispatcharr isn't running"
  key="${app^^}_TAG"; from=$(running_tag "$app")
  [[ "$from" == "$tag" ]] && { ok "$app already runs $tag"; return 0; }
  # shellcheck disable=SC2034  # read by step() in lib/ui.sh
  STEP_TOTAL=3
  step "Snapshot of ${app^} $from"
  ts=$(date +%Y%m%d-%H%M%S); mkdir -p "$TRY_DIR"; chmod 700 "$TRY_DIR"
  snap="$(backup_dir)/try-$app-$ts.tar.gz"; mkdir -p "$(backup_dir)"
  docker stop "$app" >/dev/null 2>&1 || true
  snapshot_app "$app" "$snap" || { docker start "$app" >/dev/null 2>&1; die "the snapshot failed — nothing was changed (see $LOG)"; }
  ok "snapshot $(du -h "$snap" | cut -f1) — the way back"
  jq -n --arg app "$app" --arg from "$from" --arg to "$tag" --arg snap "$snap" --arg when "$(date -Iseconds)" \
     --argjson tested_from "$([[ "$from" == "$(tested_tag "$app")" ]] && echo true || echo false)" \
     '{app: $app, from: $from, to: $to, snapshot: $snap, when: $when, from_was_tested: $tested_from, state: "trying"}' >"$TRY_DIR/$app.json"

  step "${app^} $tag"
  env_set "$key" "$tag"; env_save
  if app_up "$app"; then
    if doctor; then
      rm -f "$TRY_DIR/$app.failed.json"
      jq '.state = "running"' "$TRY_DIR/$app.json" >"$TRY_DIR/$app.json.new" && mv "$TRY_DIR/$app.json.new" "$TRY_DIR/$app.json"
      ok "${app^} runs $tag. If something feels off later: Dojo → System → Go back (or ./bootstrap.sh revert-version $app)"
      return 0
    fi
  fi
  warn "${app^} $tag didn't pass — going back to $from"
  jq '.state = "rolled back"' "$TRY_DIR/$app.json" >"$TRY_DIR/$app.failed.json"
  revert_version "$app" quiet
  die "${app^} $tag didn't work here, so ${app^} is back on $from with its data from before. The log above says what failed."
}

revert_version() { # revert_version APP [quiet]
  local app=$1 f="$TRY_DIR/$1.json" from snap key
  [[ -f "$f" ]] || die "no tried version of $app to go back from"
  [[ -n "${ENV_KEYS[*]:-}" ]] || env_load || die "no ninjarr.env"
  from=$(jq -r .from "$f"); snap=$(jq -r .snapshot "$f"); key="${app^^}_TAG"
  [[ -f "$snap" ]] || die "the snapshot $snap is gone — can't go back safely"
  # shellcheck disable=SC2034  # read by step() in lib/ui.sh
  [[ "${2:-}" == quiet ]] || { STEP_TOTAL=2; step "Back to ${app^} $from"; }
  docker stop "$app" >/dev/null 2>&1 || true
  restore_app "$app" "$snap" || die "putting ${app^}'s data back failed — its data is untouched; see $LOG"
  ok "${app^}'s data from $(jq -r .when "$f" | cut -c1-16 | tr T ' ') is back"
  if [[ "$(jq -r .from_was_tested "$f")" == true ]]; then env_unset "$key"; else env_set "$key" "$from"; fi
  env_save
  app_up "$app" || warn "${app^} $from didn't come up — see $LOG"
  rm -f "$f" "$snap"            # the data is back in place: the snapshot has done its job
  [[ "${2:-}" == quiet ]] && return 0
  doctor || true
}

# After a ninjarr update: a tried version that ninjarr has now caught up with isn't needed any more
drop_outdated_overrides() {
  local app key tag tested
  for app in "${TRY_APPS[@]}"; do
    key="${app^^}_TAG"; tag=${!key:-}; tested=$(tested_tag "$app")
    [[ -n "$tag" && -n "$tested" && "$tag" != latest ]] || continue
    if ! newer_than "$tag" "$tested"; then
      env_unset "$key"
      [[ -f "$TRY_DIR/$app.json" ]] && rm -f "$(jq -r .snapshot "$TRY_DIR/$app.json")"
      rm -f "$TRY_DIR/$app.json" "$TRY_DIR/$app.failed.json"
      info "${app^}: ninjarr now tests $tested — back on its tested versions"
    fi
  done
  env_save
}
