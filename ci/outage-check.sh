#!/usr/bin/env bash
# ninjarr's outage check, run by the version bot after the final build (as root): makes sure an
# AIOStreams outage can't cost the library anything with the app versions about to be released.
#
# ninjarr's library is symlinks on the VM's own disk pointing into AIOStreams' mount. While
# AIOStreams is down (an update, a crash) those links point at nothing. Today that is harmless:
# Emby keeps every item and its watched state, and Sonarr/Radarr's rescans give up instead of
# forgetting the file (which would make them grab a new release). A future version could
# behave differently; this check makes sure such a version is never released.
#
# How: an episode and a movie get a library link to a stand-in file; Emby marks them watched;
# the stand-in is removed (the outage); Sonarr, Radarr and Emby rescan; nothing may be lost.
# Uses the first series/movie with a file when there is one, else adds Breaking Bad and The
# Matrix (needs Sonarr's and Radarr's metadata servers) and removes them again afterwards.
# Exits 0 when everything survived (or when the test couldn't be set up), 1 when something was lost.
set -Eeuo pipefail
cd "$(dirname "$(readlink -f "$0")")/.."
DATA=$(sed -n "s/^NINJARR_DATA='\(.*\)'.*/\1/p" ninjarr.env); DATA=${DATA:-/opt/ninjarr}
STANDIN_DIR="$DATA/library/.outage-check"
STANDIN=/library/.outage-check/standin.mkv           # the same file as the apps see it
say() { printf '   %s\n' "$*"; }
py() { docker exec -i dojo python3 -; }

# the Python side talks to the apps with Dojo's own helpers (keys, addresses)
read -r -d '' LIB <<'EOF' || true
import sys, time, json; sys.path.insert(0, "/app")
import app as A
ctx = A.app.test_request_context("/"); ctx.push()
env = A.env_read()
def wait_cmd(app, cid):
    for _ in range(120):
        st = A.get_json(app, f"/api/v3/command/{cid}", env, {})
        if st.get("status") in ("completed", "failed", "aborted"): return st.get("status")
        time.sleep(1)
    return "timeout"
def command(app, body):
    return wait_cmd(app, A.call(app, "/api/v3/command", env, "POST", json=body).json()["id"])
def emby_scan():
    A.call("emby", "/emby/Library/Refresh", env, "POST"); time.sleep(3)
    for _ in range(150):
        t = [x for x in A.get_json("emby", "/emby/ScheduledTasks", env, []) if x.get("Key") == "RefreshLibrary"]
        if t and t[0].get("State") == "Idle": break
        time.sleep(2)
    time.sleep(2)
EOF

# 1. pick (or add) an episode and a movie, and note their files' paths
mkdir -p "$STANDIN_DIR"
head -c 2000000 /dev/urandom >"$STANDIN_DIR/standin.mkv"
chmod -R a+rX "$STANDIN_DIR"
state=$(py <<EOF
$LIB
out = {"added": []}
def episode():
    for s in A.get_json("sonarr", "/api/v3/series", env, []) or []:
        fs = A.get_json("sonarr", f"/api/v3/episodefile?seriesId={s['id']}", env, []) or []
        if fs: return s, fs[0]
    return None, None
s, f = episode()
if not s:
    look = (A.get_json("sonarr", "/api/v3/series/lookup?term=tvdb:81189", env, []) or [None])[0]
    if look:
        prof = A.get_json("sonarr", "/api/v3/qualityprofile", env, [])[0]["id"]
        look.update(qualityProfileId=prof, rootFolderPath="/library/tv", monitored=False, seasonFolder=True,
                    addOptions={"searchForMissingEpisodes": False, "monitor": "none"})
        s = A.call("sonarr", "/api/v3/series", env, "POST", json=look).json()
        out["added"].append(["sonarr", s.get("id")])
        time.sleep(5)
        out["new_episode"] = s.get("path", "") + "/Season 01/Breaking Bad - S01E01.mkv"
        out["series"] = s.get("id")
else:
    out["episode"], out["series"] = s["path"] + "/" + f["relativePath"], s["id"]
m = next((x for x in A.get_json("radarr", "/api/v3/movie", env, []) or [] if x.get("hasFile")), None)
if m:
    out["movie"], out["movie_id"] = m["movieFile"]["path"], m["id"]
else:
    look = A.get_json("radarr", "/api/v3/movie/lookup/tmdb?tmdbId=603", env, None)
    if look:
        prof = A.get_json("radarr", "/api/v3/qualityprofile", env, [])[0]["id"]
        look.update(qualityProfileId=prof, rootFolderPath="/library/movies", monitored=False,
                    addOptions={"searchForMovie": False})
        m = A.call("radarr", "/api/v3/movie", env, "POST", json=look).json()
        out["added"].append(["radarr", m.get("id")])
        out["new_movie"], out["movie_id"] = m.get("path", "") + "/The Matrix (1999).mkv", m.get("id")
print(json.dumps(out))
EOF
)
get() { jq -r ".$1 // empty" <<<"$state"; }
host() { printf '%s/%s' "$DATA" "${1#/}"; }       # an app's /library/… path on this machine

# 2. give each one a library link to the stand-in (keeping whatever was there)
linked=()
for k in episode movie new_episode new_movie; do
  p=$(get "$k"); [[ -n "$p" ]] || continue
  h=$(host "$p"); mkdir -p "$(dirname "$h")"
  if [[ -e "$h" || -L "$h" ]]; then mv "$h" "$h.outage-check-keep"; fi
  ln -s "$STANDIN" "$h"; linked+=("$h")
done
if (( ${#linked[@]} < 2 )); then
  say "outage check skipped: no series or movie to test with (metadata servers unreachable?)"
fi

restore() {
  rm -rf "$STANDIN_DIR"
  for h in "${linked[@]}"; do
    rm -f "$h"; if [[ -e "$h.outage-check-keep" || -L "$h.outage-check-keep" ]]; then mv "$h.outage-check-keep" "$h"; fi
  done
  py <<EOF >/dev/null 2>&1 || true
$LIB
for app, i in json.loads('''$(jq -c '.added' <<<"$state")'''):
    if i: A.call(app, f"/api/v3/{'series' if app == 'sonarr' else 'movie'}/{i}?deleteFiles=true", env, "DELETE")
EOF
}
trap restore EXIT
(( ${#linked[@]} )) || exit 0

# 3. the apps take the files in; Emby marks them watched
before=$(py <<EOF
$LIB
st = json.loads('''$state''')
if st.get("series"): command("sonarr", {"name": "RefreshSeries", "seriesId": st["series"]})   # metadata, then the files
if st.get("movie_id"): command("radarr", {"name": "RefreshMovie", "movieIds": [st["movie_id"]]})
emby_scan()
uid = A.get_json("emby", "/emby/Users", env, [])[0]["Id"]
paths = {st.get(k) for k in ("episode", "movie", "new_episode", "new_movie")} - {None}
items = A.get_json("emby", f"/emby/Users/{uid}/Items?Recursive=true&IncludeItemTypes=Episode,Movie&Fields=Path", env, {}).get("Items", [])
mine = [i for i in items if i.get("Path") in paths]
for i in mine: A.call("emby", f"/emby/Users/{uid}/PlayedItems/{i['Id']}", env, "POST")
ep = A.get_json("sonarr", f"/api/v3/episodefile?seriesId={st['series']}", env, []) if st.get("series") else []
mv = A.get_json("radarr", f"/api/v3/movie/{st['movie_id']}", env, {}) if st.get("movie_id") else {}
print(json.dumps({"emby": sorted(i["Id"] for i in mine), "sonarr": len(ep or []), "radarr": bool(mv.get("hasFile"))}))
EOF
)
say "before the outage: $before"
if [[ "$(jq '.emby | length' <<<"$before")" == 0 || "$(jq '.sonarr' <<<"$before")" == 0 || "$(jq '.radarr' <<<"$before")" != true ]]; then
  say "outage check skipped: the apps didn't take in the test files ($before)"; exit 0
fi

# 4. the outage: the stand-in disappears; everything rescans
rm -f "$STANDIN_DIR/standin.mkv"
after=$(py <<EOF
$LIB
st = json.loads('''$state''')
command("sonarr", {"name": "RescanSeries", "seriesId": st["series"]})
command("radarr", {"name": "RescanMovie", "movieId": st["movie_id"]})
emby_scan()
uid = A.get_json("emby", "/emby/Users", env, [])[0]["Id"]
want = json.loads('''$before''')["emby"]
items = A.get_json("emby", f"/emby/Users/{uid}/Items?Recursive=true&IncludeItemTypes=Episode,Movie", env, {}).get("Items", [])
kept = sorted(i["Id"] for i in items if i["Id"] in want and (i.get("UserData") or {}).get("Played"))
ep = A.get_json("sonarr", f"/api/v3/episodefile?seriesId={st['series']}", env, [])
mv = A.get_json("radarr", f"/api/v3/movie/{st['movie_id']}", env, {})
print(json.dumps({"emby": kept, "sonarr": len(ep or []), "radarr": bool(mv.get("hasFile"))}))
EOF
)
say "after the outage:  $after"
lost=()
[[ "$(jq -c '.emby' <<<"$after")" == "$(jq -c '.emby' <<<"$before")" ]] || lost+=("Emby dropped items or their watched state")
[[ "$(jq '.sonarr' <<<"$after")" == "$(jq '.sonarr' <<<"$before")" ]] || lost+=("Sonarr forgot an episode file")
[[ "$(jq '.radarr' <<<"$after")" == true ]] || lost+=("Radarr forgot a movie file")
if (( ${#lost[@]} )); then
  say "OUTAGE CHECK FAILED: ${lost[*]}"
  exit 1
fi
say "outage check passed: Emby, Sonarr and Radarr kept everything while AIOStreams was away"
