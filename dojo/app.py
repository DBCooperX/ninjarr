#!/usr/bin/env python3
"""Ninjarr Dojo Monitor — a status dashboard for the stack, plus a small set of
safe, well-defined write actions (currently: add a Generic Newznab indexer to
Prowlarr and trigger a sync). Everything else stays in each app's own UI.

Reads scraped API keys from /config/keys.json, written by bootstrap.sh after it
grabs them from each app's own config. This container starts before those keys
exist and just reports the affected services as unreachable until the file
shows up — no restart needed, keys.json is read fresh on every request.
"""
import json
import os
import re
import shutil
import threading
import time
from concurrent.futures import ThreadPoolExecutor

import requests
from flask import Flask, jsonify, render_template, request

app = Flask(__name__)

# Mounted read-only, same host paths sonarr/radarr/sabnzbd already use. All three are
# disk-space-sensitive in a way nothing else in the stack is: SAB pauses with "Too little
# diskspace" when INCOMPLETE fills, and a full DOWNLOADS or MEDIA volume fails imports silently.
DISK_PATHS = [
    {"id": "downloads", "label": "Downloads", "path": "/downloads"},
    {"id": "media", "label": "Media Library", "path": "/media"},
    {"id": "incomplete", "label": "Unpack Scratch", "path": "/incomplete"},
]

CONFIG_PATH = "/config/keys.json"
# Written by bootstrap.sh's write_storage_status() into Dojo's own /config volume (not a
# separate mount) — whether downloads/media share a filesystem (hardlink vs copy on import),
# media's filesystem type, and whether it's NFS. Lets the Storage panel show NAS-specific
# guidance only when it's actually relevant, instead of cluttering the dashboard for the common
# local-only case.
STORAGE_CHECK_PATH = "/config/storage-check.json"
TIMEOUT = 3

# Shared with the recyclarr container's own /config (see compose/core.yml) — writing
# recyclarr.yml and touching .trigger here is how a picked preset reaches it, since recyclarr's
# watch.sh is already polling for exactly that file, the same mechanism bootstrap.sh's own
# initial sync uses. No docker socket access needed in this container.
RECYCLARR_CONFIG_DIR = "/recyclarr-config"
RECYCLARR_TEMPLATES_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "recyclarr-templates")

# TRaSH Guides' own curated German dual-audio presets (via recyclarr/config-templates) — each
# pairs a Sonarr and a Radarr template of the same name. See dojo/recyclarr-templates/.
# Ordered with bootstrap.sh's RECYCLARR_DEFAULT_PRESET first (top-left in the grid), the rest
# grouped by tier — descriptions name a specific preset rather than say "above"/"below", since
# the grid can wrap to any number of columns depending on viewport width.
PRESETS = [
    {"id": "german-uhd-bluray-web", "label": "German — UHD Bluray + WEB",
     "desc": "4K ceiling. German dual-audio is scarcer at 2160p — expect more English grabs. bootstrap.sh's default."},
    {"id": "german-uhd-bluray-web-alternative", "label": "German — UHD Bluray + WEB (alternative)",
     "desc": "Same 4K ceiling as UHD Bluray + WEB, using TRaSH's alternate scoring weights."},
    {"id": "german-uhd-remux-web", "label": "German — UHD Remux + WEB",
     "desc": "4K ceiling, prefers remux quality when one exists."},
    {"id": "german-hd-bluray-web", "label": "German — HD Bluray + WEB",
     "desc": "1080p ceiling — lighter on storage and bandwidth than the UHD tiers."},
    {"id": "german-hd-remux-web", "label": "German — HD Remux + WEB",
     "desc": "1080p ceiling, prefers remux quality when one exists."},
    {"id": "german-anime-hd-bluray-web", "label": "German — Anime HD Bluray + WEB",
     "desc": "Tuned for anime release-naming patterns instead of general TV/movie ones."},
]
PRESET_IDS = {p["id"] for p in PRESETS}


def read_recyclarr_file(name):
    try:
        with open(os.path.join(RECYCLARR_CONFIG_DIR, name)) as f:
            return f.read().strip()
    except FileNotFoundError:
        return None


def merge_preset(preset_id, son_key, rad_key):
    """Same substitution bootstrap.sh's write_recyclarr_config does in bash: swap the
    placeholder base_url/api_key lines for real values, matched by key name so this survives
    the upstream template's exact placeholder wording changing."""
    son_path = os.path.join(RECYCLARR_TEMPLATES_DIR, "sonarr", f"{preset_id}.yml")
    rad_path = os.path.join(RECYCLARR_TEMPLATES_DIR, "radarr", f"{preset_id}.yml")
    if not os.path.isfile(son_path) or not os.path.isfile(rad_path):
        return None

    def patch(path, base_url, api_key):
        with open(path) as f:
            text = f.read()
        text = re.sub(r"(?m)^([ \t]*base_url:).*$", lambda m: f"{m.group(1)} {base_url}", text)
        text = re.sub(r"(?m)^([ \t]*api_key:).*$", lambda m: f"{m.group(1)} {api_key}", text)
        return text

    return patch(son_path, "http://sonarr:8989", son_key) + "\n" + patch(rad_path, "http://radarr:7878", rad_key)

# host:port are the docker-network service names — this container shares the
# "ninjarr" network with everything else, so these resolve the same way they
# do inside Sonarr/Radarr/Bazarr's own containers. "desc" is plain UI copy,
# not fetched from anywhere.
# Ordered to match the actual request pipeline, not alphabetically — the frontend renders these
# left to right as a connected flow, not a uniform grid, and relies on this order to do it. Each
# carries a "step" label naming its stage in that flow.
SERVICES = {
    "seerr": {
        "label": "Seerr", "host": "seerr", "port": 5055, "key": None, "step": "Request",
        "desc": "Search & request movies and TV — the front door for everyone else.",
    },
    "prowlarr": {
        "label": "Prowlarr", "host": "prowlarr", "port": 9696, "key": "PRO_KEY", "step": "Find",
        "desc": "Manages indexers and feeds them to Sonarr & Radarr.",
    },
    "sabnzbd": {
        "label": "SABnzbd", "host": "sabnzbd", "port": 8080, "key": "SAB_KEY", "step": "Fetch",
        "desc": "Downloads and unpacks what Sonarr and Radarr send it.",
    },
    "sonarr": {
        "label": "Sonarr", "host": "sonarr", "port": 8989, "key": "SON_KEY", "step": "Organize",
        "desc": "Tracks TV shows and grabs new episodes automatically.",
    },
    "radarr": {
        "label": "Radarr", "host": "radarr", "port": 7878, "key": "RAD_KEY", "step": "Organize",
        "desc": "Tracks movies and grabs new releases automatically.",
    },
    "bazarr": {
        "label": "Bazarr", "host": "bazarr", "port": 6767, "key": "BAZ_KEY", "step": "Subtitle",
        "desc": "Finds and downloads subtitles for the library.",
    },
}


def load_keys():
    try:
        with open(CONFIG_PATH) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def safe_get(url, **kwargs):
    """A failed fetch of one supplementary stat shouldn't take the others down
    with it — every caller gets None back instead of an exception, and decides
    for itself whether that stat is worth showing."""
    try:
        r = requests.get(url, timeout=TIMEOUT, **kwargs)
        return r if r.ok else None
    except requests.RequestException:
        return None


def add_stat(stats, label, value):
    stats.append({"label": label, "value": value})


def probe(service_id, svc, keys):
    base = f"http://{svc['host']}:{svc['port']}"
    key = keys.get(svc["key"]) if svc["key"] else None
    result = {
        "id": service_id, "label": svc["label"], "port": svc["port"], "step": svc["step"],
        "desc": svc["desc"], "up": False, "waiting": False, "stats": [],
    }

    if svc["key"] and not key:
        result["waiting"] = True
        return result

    stats = result["stats"]

    if service_id == "seerr":
        r = safe_get(f"{base}/api/v1/status")
        result["up"] = r is not None
        if r is not None:
            try:
                version = r.json().get("version")
            except ValueError:
                version = None
            if version:
                add_stat(stats, "version", version)

    elif service_id in ("sonarr", "radarr"):
        headers = {"X-Api-Key": key}
        r = safe_get(f"{base}/api/v3/system/status", headers=headers)
        result["up"] = r is not None
        if result["up"]:
            q = safe_get(f"{base}/api/v3/queue", headers=headers)
            if q is not None:
                try:
                    add_stat(stats, "downloading", str(q.json().get("totalRecords", 0)))
                except ValueError:
                    pass

            m = safe_get(f"{base}/api/v3/wanted/missing", headers=headers, params={"pageSize": 1})
            if m is not None:
                try:
                    add_stat(stats, "missing", str(m.json().get("totalRecords", 0)))
                except ValueError:
                    pass

            lib_path = "series" if service_id == "sonarr" else "movie"
            lib_label = "series" if service_id == "sonarr" else "movies"
            lib = safe_get(f"{base}/api/v3/{lib_path}", headers=headers)
            if lib is not None:
                try:
                    items = lib.json()
                    monitored = sum(1 for x in items if x.get("monitored"))
                    add_stat(stats, lib_label, f"{monitored}/{len(items)} monitored")
                except ValueError:
                    pass

    elif service_id == "prowlarr":
        headers = {"X-Api-Key": key}
        r = safe_get(f"{base}/api/v1/system/status", headers=headers)
        result["up"] = r is not None
        if result["up"]:
            idx = safe_get(f"{base}/api/v1/indexer", headers=headers)
            if idx is not None:
                try:
                    add_stat(stats, "indexers", str(len(idx.json())))
                except ValueError:
                    pass

            st = safe_get(f"{base}/api/v1/indexerstats", headers=headers)
            if st is not None:
                try:
                    rows = st.json().get("indexers") or []
                    grabs = sum(x.get("numberOfGrabs", 0) for x in rows)
                    queries = sum(x.get("numberOfQueries", 0) for x in rows)
                    failed = sum(x.get("numberOfFailedQueries", 0) for x in rows)
                    add_stat(stats, "grabs", str(grabs))
                    if queries:
                        add_stat(stats, "queries", f"{queries} ({failed} failed)")
                except ValueError:
                    pass

    elif service_id == "sabnzbd":
        r = safe_get(f"{base}/api", params={"mode": "queue", "output": "json", "apikey": key})
        result["up"] = r is not None
        if result["up"]:
            try:
                q = r.json()["queue"]
                add_stat(stats, "status", q.get("status", "?"))
                if q.get("status") == "Downloading":
                    add_stat(stats, "speed", q.get("speed", "?"))
                    add_stat(stats, "eta", q.get("timeleft", "?"))
                add_stat(stats, "queue", f"{q.get('noofslots', 0)} item(s), {q.get('sizeleft', '?')} left")
            except (KeyError, ValueError):
                pass

    elif service_id == "bazarr":
        r = safe_get(f"{base}/api/system/status", headers={"X-API-KEY": key})
        result["up"] = r is not None
        if result["up"]:
            b = safe_get(f"{base}/api/badges", headers={"X-API-KEY": key})
            if b is not None:
                try:
                    d = b.json()
                    add_stat(stats, "missing subs", f"{d.get('episodes', 0)} ep / {d.get('movies', 0)} mv")
                    if d.get("providers", 0):
                        add_stat(stats, "throttled providers", str(d["providers"]))
                except ValueError:
                    pass

    return result


@app.route("/")
def index():
    return render_template("index.html")


@app.route("/api/status")
def status():
    keys = load_keys()
    with ThreadPoolExecutor(max_workers=len(SERVICES)) as pool:
        results = list(pool.map(lambda kv: probe(kv[0], kv[1], keys), SERVICES.items()))
    return jsonify(results)


@app.route("/api/disk")
def disk():
    results = []
    for d in DISK_PATHS:
        entry = {"id": d["id"], "label": d["label"], "ok": False}
        try:
            usage = shutil.disk_usage(d["path"])
            entry["ok"] = True
            entry["total"] = usage.total
            entry["free"] = usage.free
            entry["used_pct"] = round((usage.total - usage.free) / usage.total * 100, 1) if usage.total else 0
        except OSError:
            pass
        results.append(entry)
    return jsonify(results)


@app.route("/api/storage-check")
def storage_check():
    try:
        with open(STORAGE_CHECK_PATH) as f:
            return jsonify(json.load(f))
    except (FileNotFoundError, json.JSONDecodeError):
        return jsonify(None)


@app.route("/api/indexer", methods=["POST"])
def add_indexer():
    """Add a Generic Newznab indexer to Prowlarr and trigger a sync to the arrs.
    Schema-driven, same principle as bootstrap.sh: fetch Prowlarr's own template
    for the Newznab implementation and only override name/baseUrl/apiPath/apiKey
    — everything else stays whatever Prowlarr itself defaults to."""
    keys = load_keys()
    key = keys.get("PRO_KEY")
    if not key:
        return jsonify(ok=False, message="Prowlarr's API key isn't available yet — try again shortly."), 503

    body = request.get_json(silent=True) or {}
    name = (body.get("name") or "").strip()
    base_url = (body.get("baseUrl") or "").strip()
    api_key = (body.get("apiKey") or "").strip()
    api_path = (body.get("apiPath") or "/api").strip()

    if not name or not base_url or not api_key:
        return jsonify(ok=False, message="Name, base URL, and API key are all required."), 400

    base = "http://prowlarr:9696"
    headers = {"X-Api-Key": key}

    try:
        schema_resp = requests.get(f"{base}/api/v1/indexer/schema", headers=headers, timeout=TIMEOUT)
        schema_resp.raise_for_status()
        schema = next((s for s in schema_resp.json() if s.get("implementation") == "Newznab"), None)
        if not schema:
            return jsonify(ok=False, message="Prowlarr has no Newznab indexer template — check its version."), 502

        schema["name"] = name
        schema["enable"] = True
        # Asserted explicitly, not left to Prowlarr's own default (which already happens to be
        # true) — with this off, Prowlarr fetches the NZB itself and hands SABnzbd the raw
        # file, so every grab looks like it came from Prowlarr's IP/client, not SABnzbd's. Some
        # indexers ban on sight for that. With it on, Prowlarr redirects SABnzbd straight to the
        # indexer's own NZB URL, so it's SABnzbd making that request the same as always.
        schema["redirect"] = True
        for field in schema.get("fields", []):
            if field.get("name") == "baseUrl":
                field["value"] = base_url
            elif field.get("name") == "apiPath":
                field["value"] = api_path
            elif field.get("name") == "apiKey":
                field["value"] = api_key

        create_resp = requests.post(f"{base}/api/v1/indexer", headers=headers, json=schema, timeout=TIMEOUT)
        if not create_resp.ok:
            return jsonify(ok=False, message=f"Prowlarr rejected the indexer: HTTP {create_resp.status_code}"), 502

        requests.post(
            f"{base}/api/v1/command", headers=headers, json={"name": "ApplicationIndexerSync"}, timeout=TIMEOUT
        )
        return jsonify(ok=True, message=f"'{name}' added and synced to Sonarr/Radarr.")
    except requests.RequestException as e:
        return jsonify(ok=False, message=f"Could not reach Prowlarr: {e}"), 502


@app.route("/api/presets")
def list_presets():
    return jsonify(
        presets=PRESETS,
        applied=read_recyclarr_file(".applied-preset"),
        last_sync=read_recyclarr_file(".last-sync"),
    )


# Sonarr and Radarr both ship these six on a fresh install (verified against a clean container
# of each) — Recyclarr never touches them.
STOCK_QUALITY_PROFILE_NAMES = {"Any", "SD", "HD-720p", "HD-1080p", "Ultra-HD", "HD - 720p/1080p"}


def _preset_profile_name(app, preset_id):
    """The exact profile name Recyclarr's sync creates for (app, preset) — read from the
    template's own header comment rather than hardcoded, and verified empirically (via a real
    sync against a live Sonarr) to match byte-for-byte, not just be descriptive text. Sonarr and
    Radarr can get different names for the same preset id, so this is looked up per app."""
    path = os.path.join(RECYCLARR_TEMPLATES_DIR, app, f"{preset_id}.yml")
    try:
        with open(path) as f:
            for line in f:
                m = re.match(r"^## TRaSH Guides:\s*(.+?)\s*$", line)
                if m:
                    return m.group(1)
    except OSError:
        pass
    return None


# {"sonarr": {preset_id: name, ...}, "radarr": {...}} — every name any bundled preset can
# produce, so a leftover profile from a preset that's no longer applied can be recognized as
# "ours" without ever touching a profile the user created by hand outside of ninjarr.
PRESET_PROFILE_NAMES = {
    app: {p["id"]: _preset_profile_name(app, p["id"]) for p in PRESETS}
    for app in ("sonarr", "radarr")
}


def prune_unmanaged_quality_profiles():
    """Keeps Sonarr/Radarr down to exactly one quality profile: whichever the currently applied
    preset creates. Removes the stock defaults, plus any profile left behind by a preset that
    used to be applied before a switch — Recyclarr only ever creates/updates whatever's in the
    config it's currently given, it never cleans up a profile a previous config created. Never
    touches a profile it can't positively identify as one of ours."""
    applied = read_recyclarr_file(".applied-preset")
    keys = load_keys()
    for service_id in ("sonarr", "radarr"):
        svc = SERVICES[service_id]
        key = keys.get(svc["key"])
        if not key:
            continue
        base = f"http://{svc['host']}:{svc['port']}"
        headers = {"X-Api-Key": key}
        r = safe_get(f"{base}/api/v3/qualityprofile", headers=headers)
        if r is None:
            continue
        try:
            profiles = r.json()
        except ValueError:
            continue

        names_by_preset = PRESET_PROFILE_NAMES[service_id]
        expected_name = names_by_preset.get(applied) if applied else None
        known_preset_names = {n for n in names_by_preset.values() if n}

        def is_stale(name, expected_name=expected_name, known_preset_names=known_preset_names):
            if name in STOCK_QUALITY_PROFILE_NAMES:
                return True
            # only treat a preset-named profile as stale once we know what should replace it —
            # otherwise (unreadable .applied-preset, template files changed) leave it alone
            return bool(expected_name) and name in known_preset_names and name != expected_name

        # never delete down to zero: only proceed once at least one profile would survive
        if not any(not is_stale(p.get("name")) for p in profiles):
            continue

        for p in profiles:
            if not is_stale(p.get("name")):
                continue
            try:
                requests.delete(f"{base}/api/v3/qualityprofile/{p['id']}", headers=headers, timeout=TIMEOUT)
            except requests.RequestException:
                pass


def watch_recyclarr_sync():
    """Runs for the container's lifetime. bootstrap.sh's first sync, a preset switch from this
    UI, and recyclarr's own weekly schedule all go through the same .last-sync file — whenever
    it changes, whatever's stale (stock defaults, or a profile from a preset that's no longer
    applied) is pruned right after."""
    last_seen = None
    while True:
        current = read_recyclarr_file(".last-sync")
        if current and current != last_seen:
            last_seen = current
            prune_unmanaged_quality_profiles()
        time.sleep(5)


@app.route("/api/presets/apply", methods=["POST"])
def apply_preset():
    """Write the merged recyclarr.yml and touch .trigger — recyclarr's own watch.sh is already
    polling for that file and picks it up within a few seconds. No docker socket, no separate
    container invocation; this container can only ever write into its own config volume."""
    body = request.get_json(silent=True) or {}
    preset_id = (body.get("preset") or "").strip()
    if preset_id not in PRESET_IDS:
        return jsonify(ok=False, message="Unknown preset."), 400

    keys = load_keys()
    son_key, rad_key = keys.get("SON_KEY"), keys.get("RAD_KEY")
    if not son_key or not rad_key:
        return jsonify(ok=False, message="Sonarr and Radarr API keys aren't both available yet — try again shortly."), 503

    combined = merge_preset(preset_id, son_key, rad_key)
    if combined is None:
        return jsonify(ok=False, message="That preset's template files are missing from this image."), 500

    try:
        with open(os.path.join(RECYCLARR_CONFIG_DIR, "recyclarr.yml"), "w") as f:
            f.write(combined)
        with open(os.path.join(RECYCLARR_CONFIG_DIR, ".applied-preset"), "w") as f:
            f.write(preset_id)
        with open(os.path.join(RECYCLARR_CONFIG_DIR, ".trigger"), "w"):
            pass
    except OSError as e:
        return jsonify(ok=False, message=f"Could not write recyclarr's config: {e}"), 500

    return jsonify(ok=True, message=f"'{preset_id}' applied — recyclarr will sync within a few seconds.")


@app.route("/api/presets/resync", methods=["POST"])
def resync_preset():
    """Re-touch .trigger without changing recyclarr.yml — for pulling in an upstream TRaSH
    Guides update without switching tiers. No-ops if no preset has been applied yet."""
    if not read_recyclarr_file(".applied-preset"):
        return jsonify(ok=False, message="No preset has been applied yet."), 400
    try:
        with open(os.path.join(RECYCLARR_CONFIG_DIR, ".trigger"), "w"):
            pass
    except OSError as e:
        return jsonify(ok=False, message=f"Could not trigger a sync: {e}"), 500
    return jsonify(ok=True, message="Recyclarr will re-sync within a few seconds.")


def _sabnzbd_mode(mode, verb):
    keys = load_keys()
    key = keys.get("SAB_KEY")
    if not key:
        return jsonify(ok=False, message="SABnzbd's API key isn't available yet — try again shortly."), 503
    svc = SERVICES["sabnzbd"]
    base = f"http://{svc['host']}:{svc['port']}"
    r = safe_get(f"{base}/api", params={"mode": mode, "apikey": key, "output": "json"})
    if r is None:
        return jsonify(ok=False, message="Could not reach SABnzbd."), 502
    return jsonify(ok=True, message=f"Queue {verb}.")


@app.route("/api/sabnzbd/pause", methods=["POST"])
def sabnzbd_pause():
    return _sabnzbd_mode("pause", "paused")


@app.route("/api/sabnzbd/resume", methods=["POST"])
def sabnzbd_resume():
    return _sabnzbd_mode("resume", "resumed")


def _search_missing(service_id, key_name, command_name, verb):
    keys = load_keys()
    key = keys.get(key_name)
    if not key:
        return jsonify(ok=False, message=f"{SERVICES[service_id]['label']}'s API key isn't available yet — try again shortly."), 503
    svc = SERVICES[service_id]
    base = f"http://{svc['host']}:{svc['port']}"
    try:
        r = requests.post(f"{base}/api/v3/command", headers={"X-Api-Key": key},
                           json={"name": command_name}, timeout=TIMEOUT)
        r.raise_for_status()
    except requests.RequestException:
        return jsonify(ok=False, message=f"Could not reach {svc['label']}."), 502
    return jsonify(ok=True, message=f"Searching for missing {verb} now.")


@app.route("/api/sonarr/search-missing", methods=["POST"])
def sonarr_search_missing():
    return _search_missing("sonarr", "SON_KEY", "MissingEpisodeSearch", "episodes")


@app.route("/api/radarr/search-missing", methods=["POST"])
def radarr_search_missing():
    return _search_missing("radarr", "RAD_KEY", "MissingMoviesSearch", "movies")


# Each app self-diagnoses real problems (indexer down, no download client, missing languages
# profile, disk full) via its own health endpoint — none of that surfaced in Dojo before this,
# even though it's free, read-only, and often more actionable than the stats already shown.
def _arr_health(service_id):
    svc = SERVICES[service_id]
    key = load_keys().get(svc["key"])
    if not key:
        return []
    base = f"http://{svc['host']}:{svc['port']}"
    path = "/api/v1/health" if service_id == "prowlarr" else "/api/v3/health"
    r = safe_get(f"{base}{path}", headers={"X-Api-Key": key})
    if r is None:
        return []
    try:
        items = r.json()
    except ValueError:
        return []
    return [
        {"app": svc["label"], "severity": item.get("type", "warning"), "message": item.get("message", "")}
        for item in items
    ]


def _bazarr_health():
    svc = SERVICES["bazarr"]
    key = load_keys().get(svc["key"])
    if not key:
        return []
    base = f"http://{svc['host']}:{svc['port']}"
    r = safe_get(f"{base}/api/system/health", headers={"X-API-KEY": key})
    if r is None:
        return []
    try:
        items = r.json().get("data", [])
    except ValueError:
        return []
    # Bazarr's own health check has no severity levels — everything it reports is worth fixing
    return [{"app": "Bazarr", "severity": "warning", "message": item.get("issue") or item.get("object", "")} for item in items]


def _sabnzbd_health():
    svc = SERVICES["sabnzbd"]
    key = load_keys().get(svc["key"])
    if not key:
        return []
    base = f"http://{svc['host']}:{svc['port']}"
    r = safe_get(f"{base}/api", params={"mode": "warnings", "apikey": key, "output": "json"})
    if r is None:
        return []
    try:
        warnings = r.json().get("warnings", [])
    except ValueError:
        return []
    return [{"app": "SABnzbd", "severity": "warning", "message": w} for w in warnings]


@app.route("/api/health")
def health():
    issues = []
    for service_id in ("sonarr", "radarr", "prowlarr"):
        issues.extend(_arr_health(service_id))
    issues.extend(_bazarr_health())
    issues.extend(_sabnzbd_health())
    return jsonify(issues)


# Discord is the one notification target wired here — a single well-known, webhook-only
# provider, same "cover the common case simply" choice as the Generic Newznab indexer form.
# Sonarr/Radarr share the same notification schema; Bazarr's notifications run on Apprise
# provider URLs instead, a different enough mechanism to leave for a separate pass.
def _wire_discord(service_id, key_name, webhook_url):
    svc = SERVICES[service_id]
    key = load_keys().get(key_name)
    if not key:
        return f"{svc['label']}'s API key isn't available yet — try again shortly."
    base = f"http://{svc['host']}:{svc['port']}"
    headers = {"X-Api-Key": key}
    try:
        schema_resp = requests.get(f"{base}/api/v3/notification/schema", headers=headers, timeout=TIMEOUT)
        schema_resp.raise_for_status()
        schema = next((s for s in schema_resp.json() if s.get("implementation") == "Discord"), None)
        if not schema:
            return f"{svc['label']} has no Discord notification template — check its version."

        schema["name"] = "ninjarr-discord"
        schema["onGrab"] = True
        schema["onDownload"] = True
        schema["onHealthIssue"] = True
        for field in schema.get("fields", []):
            if field.get("name") == "webHookUrl":
                field["value"] = webhook_url

        # idempotent: update the existing ninjarr-created notification instead of piling up
        # a duplicate every time this form is submitted again
        existing_resp = requests.get(f"{base}/api/v3/notification", headers=headers, timeout=TIMEOUT)
        existing_resp.raise_for_status()
        existing = next((n for n in existing_resp.json() if n.get("name") == "ninjarr-discord"), None)

        if existing:
            schema["id"] = existing["id"]
            save_resp = requests.put(f"{base}/api/v3/notification/{existing['id']}", headers=headers, json=schema, timeout=TIMEOUT)
        else:
            save_resp = requests.post(f"{base}/api/v3/notification", headers=headers, json=schema, timeout=TIMEOUT)

        if not save_resp.ok:
            return f"{svc['label']} rejected the webhook — double check the URL."
        return None
    except requests.RequestException:
        return f"Could not reach {svc['label']}."


@app.route("/api/notifications/discord", methods=["POST"])
def add_discord_notification():
    body = request.get_json(silent=True) or {}
    webhook_url = (body.get("webhookUrl") or "").strip()
    if not webhook_url:
        return jsonify(ok=False, message="A webhook URL is required."), 400

    errors = []
    for service_id, key_name in (("sonarr", "SON_KEY"), ("radarr", "RAD_KEY")):
        err = _wire_discord(service_id, key_name, webhook_url)
        if err:
            errors.append(err)

    if errors:
        return jsonify(ok=False, message=" / ".join(errors)), 502
    return jsonify(ok=True, message="Discord notifications wired into Sonarr and Radarr.")


if __name__ == "__main__":
    threading.Thread(target=watch_recyclarr_sync, daemon=True).start()
    app.run(host="0.0.0.0", port=5000)
