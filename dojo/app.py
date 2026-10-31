"""Dojo — ninjarr's control panel.

Runs in a container on the home network. It reads and edits ninjarr.env directly (ninjarr's
folder is mounted at /ninjarr) and talks to the apps over the ninjarr network. Anything that needs
the host — building, re-wiring, restarting, backups, updates — is queued as a job in
/ninjarr/.state/jobs/queue and run by `bootstrap.sh run-jobs` on the host.

Before ninjarr.env is complete it serves the first-run setup, unlocked by the code the terminal
shows. After that it asks for the ninjarr login.
"""
import hmac
import json
from collections import Counter
import os
import sys
import queue
import re
import secrets
import shutil
import socket
import ssl
import threading
import time
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlsplit

import requests
import history
import push
import upstream
from flask import Flask, Response, abort, g, has_request_context, jsonify, request, send_file, session

ROOT = Path("/ninjarr")
ENV_FILE = ROOT / "ninjarr.env"
STATE = ROOT / ".state"
JOBS = STATE / "jobs"
DATA = Path("/data")
T = 6  # seconds, for calls to the apps

APPS = {
    "sonarr": "http://sonarr:8989", "radarr": "http://radarr:7878", "prowlarr": "http://prowlarr:9696",
    "bazarr": "http://bazarr:6767", "emby": "http://emby:8096", "seerr": "http://seerr:5055",
    "aiostreams": "http://aiostreams:3000", "dispatcharr": "http://dispatcharr:9191",
}
SERVICES = ["aiostreams", "prowlarr", "sonarr", "radarr", "bazarr", "emby", "seerr", "dojo", "dispatcharr", "caddy"]
LANGUAGES = ["German", "French", "Spanish", "Italian", "Dutch", "Portuguese", "Polish", "Swedish", "Danish",
             "Norwegian", "Finnish", "Czech", "Hungarian", "Turkish", "Russian", "Japanese", "Korean",
             "Chinese", "Greek", "English"]

# how Sonarr/Radarr's media info names audio tracks (ISO 639 codes, sometimes the name itself)
LANG_CODES = {"German": "ger deu de", "French": "fre fra fr", "Spanish": "spa es", "Italian": "ita it",
              "Dutch": "dut nld nl", "Portuguese": "por pt", "Polish": "pol pl", "Swedish": "swe sv",
              "Danish": "dan da", "Norwegian": "nor nob nno no nb", "Finnish": "fin fi", "Czech": "cze ces cs",
              "Hungarian": "hun hu", "Turkish": "tur tr", "Russian": "rus ru", "Japanese": "jpn ja",
              "Korean": "kor ko", "Chinese": "chi zho zh", "Greek": "gre ell el", "English": "eng en"}

def file_language(f, lang):
    """Whether a Sonarr/Radarr file has audio in LANG, and how we know. The audio tracks themselves
    (media info) count first: a dual-language release named without its language (e.g. only "DL")
    is parsed as English, but its German track is right there. Then the release name."""
    f = f or {}
    if not lang:
        return False, None
    audio = re.split(r"[\s/,|;]+", ((f.get("mediaInfo") or {}).get("audioLanguages") or "").lower())
    audio = {a for a in audio if a}
    if audio & set(LANG_CODES.get(lang, "").split() + [lang.lower()]):
        return True, "audio"
    if any(c.get("name") == f"{lang} Audio" for c in f.get("customFormats") or []) \
            or any((l or {}).get("name") == lang for l in f.get("languages") or []):
        return True, "name"
    return False, "audio" if audio else "name"

app = Flask(__name__, static_folder=None)
# changes whenever Dojo's page or code changes, so an open tab can tell it's out of date
HERE = Path(__file__).parent
BUILD = __import__("hashlib").sha1(b"".join((HERE / f).read_bytes() for f in (
    "app.py", "history.py", "push.py", "templates/index.html", "static/dojo.css", "static/dojo.js", "static/sw.js"))).hexdigest()[:12]
PAGE = (HERE / "templates" / "index.html").read_text().replace("{{BUILD}}", BUILD)


# ─────────────────────────────────────────────── ninjarr.env
ENV_LINE = re.compile(r"^([A-Z0-9_]+)='(.*)'\s*(#.*)?$")


# Dojo can't write ninjarr's folder (it's mounted read-only). Settings it changes go to its own
# folder as proposals; the host merges them into ninjarr.env (lib/core.sh: adopt_dojo_settings),
# only for the keys below and only with values of the right shape. Until then Dojo reads them on top.
DOJO_STATE = STATE / "dojo"
PENDING = DOJO_STATE / "ninjarr.env"
DOJO_KEYS = {"TZ", "ADMIN_USER", "ADMIN_PASSWORD", "USENET_PROVIDERS", "INDEXERS", "PREFERRED_LANGUAGE", "REQUIRE_LANGUAGE",
             "LANGUAGE_WAIT_MINUTES", "OPENSUBTITLES_USER", "OPENSUBTITLES_PASS", "IPTV", "IPTV_TYPE", "IPTV_URL", "IPTV_USER",
             "IPTV_PASS", "IPTV_EPG_URL", "IPTV_MAX_STREAMS", "DISCORD_WEBHOOK", "DOMAIN", "DOJO_HTTPS", "AUTO_REBOOT",
             "ACME_EMAIL", "BACKUP_KEEP", "BACKUP_SCHEDULE", "DISPATCHARR_API_KEY"}


def env_parse(f):
    env = {}
    try:
        for line in f.read_text().splitlines():
            m = ENV_LINE.match(line)
            if m:
                env[m.group(1)] = m.group(2)
    except OSError:
        pass
    return env


def env_read():
    # read once per request (the guard, the handler and its helpers all ask)
    if has_request_context() and "env" in g:
        return dict(g.env)
    env = env_parse(ENV_FILE)
    env.update({k: v for k, v in env_parse(PENDING).items() if k in DOJO_KEYS})
    if has_request_context():
        g.env = env
    return dict(env)


def env_write(updates):
    """Proposes new values for the host to take over (see above)."""
    for k, v in updates.items():
        if k not in DOJO_KEYS:
            raise ValueError(f"{k} can't be changed from Dojo")
        if "'" in str(v) or "\n" in str(v):
            raise ValueError(f"{k}: single quotes and line breaks can't be stored")
    pending = env_parse(PENDING)
    pending.update({k: str(v) for k, v in updates.items()})
    DOJO_STATE.mkdir(parents=True, exist_ok=True)
    tmp = DOJO_STATE / ".ninjarr.env.new"
    tmp.write_text("".join(f"{k}='{v}'\n" for k, v in pending.items()))
    os.chmod(tmp, 0o600)
    os.replace(tmp, PENDING)
    if has_request_context():
        g.pop("env", None)


def setup_mode(env=None):
    env = env if env is not None else env_read()
    return env.get("USENET_PROVIDERS", "") in ("", "[]")


# ─────────────────────────────────────────────── login
def secret_key():
    f = DOJO_STATE / "secret-key"
    if not f.exists():
        old = STATE / "dojo-secret"          # where it lived before Dojo's own folder: keeps sessions
        DOJO_STATE.mkdir(parents=True, exist_ok=True)
        f.write_text(old.read_text().strip() if old.exists() else secrets.token_hex(32))
        os.chmod(f, 0o600)
    return f.read_text().strip()


app.secret_key = secret_key()
app.config.update(SESSION_COOKIE_HTTPONLY=True, SESSION_COOKIE_SAMESITE="Strict", PERMANENT_SESSION_LIFETIME=30 * 86400)
_failures = {}


def authed():
    if setup_mode():
        return session.get("setup") is True
    return session.get("user") == env_read().get("ADMIN_USER") and session.get("user") is not None


@app.before_request
def guard():
    open_paths = {"/", "/api/session", "/api/login", "/sw.js"}
    # /hook/ is called by Sonarr, Radarr and Seerr, and checks its own token
    if request.path in open_paths or request.path.startswith(("/static/", "/hook/")):
        return None
    # the setup page keeps following its build log after setup is complete (which ends setup mode)
    setup_follow = (session.get("setup") is True and request.method == "GET" and request.path.startswith("/api/jobs")
                    and (STATE / "setup-code").exists())     # gone once the first build went through
    if not authed() and not setup_follow:
        return jsonify(ok=False, message="Please sign in."), 401
    # simple CSRF guard: state-changing calls must come from Dojo's own page
    if request.method != "GET" and request.headers.get("X-Dojo") != "1":
        return jsonify(ok=False, message="Refused."), 403
    return None


@app.get("/api/session")
def api_session():
    env = env_read()
    return jsonify(setup=setup_mode(env), authed=authed(), user=session.get("user"),
                   version=ninjarr_version(), build=BUILD)


def host_status():
    """The VM's update status, written by the host every 15 minutes (bootstrap.sh host-status)."""
    try:
        return json.loads((STATE / "host.json").read_text())
    except (OSError, ValueError):
        return None


@app.get("/api/host")
def api_host():
    return jsonify(ok=True, host=host_status())


@app.get("/api/apps")
def api_apps():
    """The mission report's list: each app's port on the home network, plus its public name
    when Caddy serves it. The page builds the LAN links from the address it was opened with."""
    env = env_read()
    domain = env.get("DOMAIN", "").strip()
    iptv = env.get("IPTV", "no") == "yes"
    # each app's own icon, as the app itself serves it (nothing copied into ninjarr)
    # in the order of the chain on Home: request → search → grab → stream → play
    rows = [
        ("Dojo", 1337, "this page", "dojo" if env.get("DOJO_HTTPS") == "yes" else None),
        ("Seerr", 5055, "request", "request"),
        ("Prowlarr", 9696, "search", None),
        ("Sonarr", 8989, "grab shows", None),
        ("Radarr", 7878, "grab movies", None),
        ("AIOStreams", 3000, "stream", "stream"),
    ]
    if iptv:
        rows.append(("Dispatcharr", 9191, "live TV", None))
    rows += [("Emby", 8096, "watch", "emby"), ("Bazarr", 6767, "subtitles", None)]
    apps = [{"name": n, "port": p, "job": j, "icon": f"/api/appicon/{n.lower()}" if n != "Dojo" else "/static/icon-192.png",
             "remote": f"https://{sub}.{domain}" if sub and domain else None, "home_only": sub == "dojo"}
            for n, p, j, sub in rows]
    return jsonify(ok=True, domain=domain, iptv=iptv, user=env.get("ADMIN_USER", ""), apps=apps)


# each app's own icon, as the app itself serves it (nothing copied into ninjarr). Dojo passes it on,
# so the icons also show when Dojo is opened over HTTPS, where a browser blocks images from http://.
APP_ICONS = {"seerr": "/apple-touch-icon.png", "prowlarr": "/Content/Images/logo.svg", "sonarr": "/Content/Images/logo.svg",
             "radarr": "/Content/Images/logo.svg", "aiostreams": "/logo.png", "dispatcharr": "/static/logo.png",
             "emby": "/web/favicon.ico", "bazarr": "/images/logo128.png"}


@app.get("/api/appicon/<name>")
def api_appicon(name):
    if name not in APP_ICONS:
        abort(404)

    def fetch():
        try:
            r = requests.get(APPS[name] + APP_ICONS[name], timeout=5)
        except requests.RequestException:
            return None
        ctype = r.headers.get("Content-Type", "").split(";")[0]
        return (ctype, r.content) if r.ok and ctype.startswith("image/") else None
    got = cached(f"appicon-{name}", 86400, fetch)
    if not got:
        _cache.pop(f"appicon-{name}", None)      # the app may just be starting: ask again next time
        abort(404)
    resp = app.response_class(got[1], mimetype=got[0])
    resp.headers["Cache-Control"] = "private, max-age=86400"
    return resp


@app.post("/api/login")
def api_login():
    ip = request.remote_addr or "?"
    if request.host.startswith("dojo.") and request.headers.get("X-Forwarded-For"):
        ip = request.headers["X-Forwarded-For"].split(",")[0].strip()   # through Caddy: the device's own address
    if sum(list(_failures.values())) >= 50:  # someone is guessing: stop until Dojo restarts
        return jsonify(ok=False, message="Too many wrong attempts. Restart Dojo (docker restart dojo) to try again."), 429
    if _failures.get(ip, 0) >= 5:
        time.sleep(3)
    body = request.get_json(silent=True) or {}
    env = env_read()
    ok = False
    if setup_mode(env):
        code_file = STATE / "setup-code"
        code = code_file.read_text().strip() if code_file.exists() else ""
        ok = bool(code) and hmac.compare_digest(str(body.get("code", "")).strip(), code)
        if ok:
            session.permanent = True
            session["setup"] = True
    else:
        u, p = str(body.get("user", "")), str(body.get("password", ""))
        ok = hmac.compare_digest(u, env.get("ADMIN_USER", "\0")) and hmac.compare_digest(p, env.get("ADMIN_PASSWORD", "\0"))
        if ok:
            session.permanent = True
            session["user"] = u
    if not ok:
        _failures[ip] = _failures.get(ip, 0) + 1
        time.sleep(1)
        return jsonify(ok=False, message="That didn't match."), 401
    _failures.pop(ip, None)
    return jsonify(ok=True)


@app.post("/api/logout")
def api_logout():
    session.clear()
    return jsonify(ok=True)


# ─────────────────────────────────────────────── jobs (run on the host)
ALLOWED_JOBS = {"apply", "wire", "update", "backup", "doctor", "reboot", "settings"}


def queue_job(line):
    cmd = line.split()
    if not cmd or not (cmd[0] in ALLOWED_JOBS and len(cmd) == 1
                       or cmd[0] == "restart" and len(cmd) == 2 and cmd[1] in SERVICES
                       or cmd[0] in ("restore", "delete-backup") and len(cmd) == 2 and BACKUP_NAME.match(cmd[1])
                       or cmd[0] == "try-version" and len(cmd) == 3 and cmd[1] in UPSTREAM and re.fullmatch(r"[A-Za-z0-9._-]{1,64}", cmd[2])
                       or cmd[0] == "revert-version" and len(cmd) == 2 and cmd[1] in UPSTREAM):
        raise ValueError("not a job Dojo can ask for")
    if running_job():
        raise RuntimeError("another job is still running. Try again when it's done.")
    jid = datetime.now().strftime("%Y%m%d-%H%M%S-") + secrets.token_hex(3)
    q = JOBS / "queue"
    q.mkdir(parents=True, exist_ok=True)
    tmp = q / f".{jid}"
    tmp.write_text(line + "\n")
    os.replace(tmp, q / jid)
    return jid


def job_info(jid, with_log=False, offset=0):
    try:
        return _job_info(jid, with_log, offset)
    except OSError:          # the host's runner just took it from the queue or pruned it: look again
        return {"id": jid, "cmd": "", "status": "queued", "log": "", "offset": offset}


def _job_info(jid, with_log, offset):
    d = JOBS / jid
    if (JOBS / "queue" / jid).exists():
        return {"id": jid, "cmd": (JOBS / "queue" / jid).read_text().strip(), "status": "queued", "log": "", "offset": 0}
    if not d.is_dir():
        return None
    def read(n):
        try:
            return (d / n).read_text().strip()
        except OSError:
            return ""
    info = {"id": jid, "cmd": read("cmd"), "status": read("status") or "starting",
            "started": read("started"), "finished": read("finished")}
    if with_log and (d / "log").exists():
        data = (d / "log").read_bytes()
        # whole lines only while it runs, so a colour code or a multi-byte character is never cut in two
        end = len(data) if info["status"] in ("ok", "failed") else data.rfind(b"\n") + 1
        end = max(end, offset)
        info["log"] = data[offset:end].decode("utf-8", "replace")
        info["offset"] = end
    return info


def running_job():
    queue = JOBS / "queue"
    if queue.exists() and any(not p.name.startswith(".") for p in queue.iterdir()):
        return True
    for f in JOBS.glob("*/status") if JOBS.exists() else []:
        try:
            if f.read_text().strip() == "running":
                return True
        except OSError:
            pass
    return False


@app.get("/api/jobs")
def api_jobs():
    ids = []
    if JOBS.exists():
        ids = [p.name for p in (JOBS / "queue").glob("*") if not p.name.startswith(".")] if (JOBS / "queue").exists() else []
        ids += sorted((p.name for p in JOBS.iterdir() if p.is_dir() and p.name != "queue"), reverse=True)[:20]
    return jsonify([j for j in (job_info(i) for i in ids) if j])


@app.get("/api/jobs/<jid>")
def api_job(jid):
    if not re.fullmatch(r"[A-Za-z0-9_-]{1,64}", jid):
        abort(404)
    info = job_info(jid, True, int(request.args.get("offset", 0)))
    if info and info.get("status") in ("ok", "failed"):
        _cache.pop("health", None)   # a fix just ran: the next look should see its effect
    return jsonify(info) if info else (jsonify(ok=False), 404)


@app.post("/api/jobs")
def api_job_new():
    body = request.get_json(silent=True) or {}
    try:
        return jsonify(ok=True, id=queue_job(str(body.get("cmd", ""))))
    except (ValueError, RuntimeError) as e:
        return jsonify(ok=False, message=str(e)), 409


# ─────────────────────────────────────────────── tests used by setup and settings
def nntp_test(host, port, tls, user, password):
    sock = None
    try:
        raw = socket.create_connection((host, int(port)), timeout=10)
        sock = raw
        sock = ssl.create_default_context().wrap_socket(raw, server_hostname=host) if tls else raw
        f = sock.makefile("rwb")

        def cmd(line=None):
            if line:
                f.write(line.encode() + b"\r\n")
                f.flush()
            return f.readline().decode("utf-8", "replace").strip()

        greet = cmd()
        if not greet[:3] in ("200", "201"):
            return False, f"the server answered: {greet[:80]}"
        r = cmd(f"AUTHINFO USER {user}")
        if r.startswith("381"):
            r = cmd(f"AUTHINFO PASS {password}")
        cmd("QUIT")
        if r.startswith("281"):
            return True, "logged in"
        if r[:3] in ("481", "482"):
            return False, "username or password is wrong"
        if r.startswith("502"):
            return False, "the server refused the login (connection limit reached, or the account isn't active)"
        return False, f"the server answered: {r[:80]}"
    except ssl.SSLError:
        return False, "SSL/TLS didn't work on this port. Try 563 with SSL, or 119 without."
    except (socket.timeout, TimeoutError):
        return False, "No answer. Check the server and port."
    except OSError as e:
        return False, f"can't connect: {e.strerror or e}"
    finally:
        if sock:
            sock.close()


def indexer_test(url, key, api_path="/api"):
    base = url.rstrip("/")
    api = base if base.endswith(api_path.rstrip("/")) else base + "/" + api_path.strip("/")
    try:
        r = requests.get(api, params={"t": "caps", "apikey": key}, timeout=15)
    except requests.RequestException:
        return False, "can't reach that URL"
    body = r.text[:4000]
    if "<caps" in body:
        return True, "API key accepted"
    m = re.search(r'<error code="(\d+)" description="([^"]*)"', body)
    if m:
        return False, f"the indexer says: {m.group(2)}"
    return False, f"that doesn't look like a Newznab API (HTTP {r.status_code})"


def iptv_test(kind, url, user, password):
    try:
        if kind == "xtream":
            r = requests.get(url.rstrip("/") + "/player_api.php", params={"username": user, "password": password}, timeout=15)
            info = (r.json() or {}).get("user_info") or {}
            if str(info.get("auth")) != "1":
                return False, "login rejected by the provider", {}
            extra = {"max_connections": info.get("max_connections")}
            exp = info.get("exp_date")
            when = datetime.fromtimestamp(int(exp), timezone.utc).strftime("%Y-%m-%d") if exp and str(exp).isdigit() else "no end date"
            return True, f"Logged in · {info.get('status', 'active')}, until {when}, {info.get('max_connections', '?')} connection(s)", extra
        with requests.get(url, timeout=20, stream=True) as r:      # the first 4 KB is enough; let go of the rest
            head = next(r.iter_content(4096), b"")
        if b"#EXTM3U" in head:
            return True, "playlist found", {}
        return False, f"that URL doesn't return an M3U playlist (HTTP {r.status_code})", {}
    except (requests.RequestException, ValueError):
        return False, "can't reach the provider", {}


def domain_test(domain, dojo=False):
    out, ok = [], True
    for sub in ("emby", "request", "stream") + (("dojo",) if dojo else ()):
        host = f"{sub}.{domain}"
        try:
            ips = sorted({a[4][0] for a in socket.getaddrinfo(host, 443)})
            out.append(f"{host} → {', '.join(ips)}")
        except OSError:
            ok = False
            out.append(f"{host} doesn't resolve yet")
    return ok, "; ".join(out)


@app.post("/api/dispatcharr/connect")
def api_dispatcharr_connect():
    b = request.get_json(silent=True) or {}
    user, pw = (b.get("username") or "").strip(), b.get("password") or ""
    if not user or not pw:
        return jsonify(ok=False, message="Enter your Dispatcharr username and password.")
    try:
        r = requests.post(APPS["dispatcharr"] + "/api/accounts/token/", json={"username": user, "password": pw}, timeout=T)
        if r.status_code in (400, 401):
            return jsonify(ok=False, message="Dispatcharr didn't accept that login.")
        tok = r.json().get("access")
        h = {"Authorization": f"Bearer {tok}"}
        key = (requests.get(APPS["dispatcharr"] + "/api/accounts/api-keys/", headers=h, timeout=T).json() or {}).get("key")
        if not key:   # only made when the user has none, so a key in use elsewhere keeps working
            key = (requests.post(APPS["dispatcharr"] + "/api/accounts/api-keys/generate/", headers=h, json={}, timeout=T).json() or {}).get("key")
    except (requests.RequestException, ValueError, AttributeError):
        return jsonify(ok=False, message="Dispatcharr isn't answering.")
    if not key:
        return jsonify(ok=False, message="Dispatcharr didn't hand out an API key.")
    if running_job():
        return jsonify(ok=False, message="Another job is still running. Try again when it's done.")
    env_write({"DISPATCHARR_API_KEY": key})
    queue_job("settings")       # the host takes the key over now, no rebuild needed
    return jsonify(ok=True, message="Connected. Stats → Watching now shows what's playing through Dispatcharr.")


@app.post("/api/test/<kind>")
def api_test(kind):
    b = request.get_json(silent=True) or {}
    env = env_read()
    if kind == "usenet":
        pw = b.get("password") or next((p.get("password", "") for p in json.loads(env.get("USENET_PROVIDERS") or "[]")
                                        if p.get("host") == b.get("host")), "")
        ok, msg = nntp_test(b.get("host", ""), b.get("port", 563), bool(b.get("tls", True)), b.get("username", ""), pw)
        return jsonify(ok=ok, message=msg)
    if kind == "indexer":
        key = b.get("apikey") or next((i.get("apikey", "") for i in json.loads(env.get("INDEXERS") or "[]")
                                       if i.get("url") == b.get("url")), "")
        ok, msg = indexer_test(b.get("url", ""), key, b.get("apiPath") or "/api")
        return jsonify(ok=ok, message=msg)
    if kind == "iptv":
        ok, msg, extra = iptv_test(b.get("type", ""), b.get("url", ""), b.get("user", ""),
                                   b.get("password") or env.get("IPTV_PASS", ""))
        return jsonify(ok=ok, message=msg, **extra)
    if kind == "domain":
        ok, msg = domain_test(b.get("domain", "").strip(), bool(b.get("dojo_https")))
        return jsonify(ok=ok, message=msg)
    abort(404)


# ─────────────────────────────────────────────── pick lists (dojo/catalog, refreshed by update.py)
_catalog = {}


def catalog():
    if not _catalog:
        here = Path(__file__).parent / "catalog"
        for name, key in (("providers.json", "providers"), ("indexers.json", "indexers")):
            try:
                _catalog[key] = json.loads((here / name).read_text())[key]
            except (OSError, ValueError, KeyError):
                _catalog[key] = []
    return _catalog


@app.get("/api/catalog")
def api_catalog():
    return jsonify(catalog())


# ─────────────────────────────────────────────── settings
def settings_view(env):
    providers = json.loads(env.get("USENET_PROVIDERS") or "[]")
    indexers = json.loads(env.get("INDEXERS") or "[]")
    return {
        "setup": setup_mode(env),
        "admin_user": env.get("ADMIN_USER", ""),
        "tz": env.get("TZ", ""),
        "providers": [{k: p.get(k) for k in ("host", "port", "tls", "username", "maxConnections", "isBackup")}
                      | {"has_password": bool(p.get("password"))} for p in providers],
        # main providers on one priority share the load; different priorities mean "in order"
        "usenet_balanced": len({p.get("priority", 0) for p in providers if not p.get("isBackup")}) <= 1,
        "indexers": [{"name": i.get("name"), "url": i.get("url"), "preset": i.get("preset", ""), "apiPath": i.get("apiPath", "/api"),
                      "has_key": bool(i.get("apikey"))} for i in indexers],
        "language": env.get("PREFERRED_LANGUAGE", "German"),
        "require_language": env.get("REQUIRE_LANGUAGE", "no") == "yes",
        "wait_minutes": int(env.get("LANGUAGE_WAIT_MINUTES") or 0),
        # a language set by hand (or in the terminal) that isn't on the list stays selectable, so saving
        # another setting never quietly switches the language off
        "languages": LANGUAGES + ([env.get("PREFERRED_LANGUAGE")] if env.get("PREFERRED_LANGUAGE", "none").lower() != "none"
                                 and env.get("PREFERRED_LANGUAGE") not in LANGUAGES else []),
        "opensubtitles_user": env.get("OPENSUBTITLES_USER", ""),
        "has_opensubtitles_pass": bool(env.get("OPENSUBTITLES_PASS")),
        "iptv": env.get("IPTV", "no") == "yes",
        "iptv_type": env.get("IPTV_TYPE", ""),
        "iptv_url": env.get("IPTV_URL", ""),
        "iptv_user": env.get("IPTV_USER", ""),
        "has_iptv_pass": bool(env.get("IPTV_PASS")),
        "has_dispatcharr_key": bool(env.get("DISPATCHARR_API_KEY")),
        "auto_reboot": env.get("AUTO_REBOOT", "no") == "yes",
        "iptv_epg_url": env.get("IPTV_EPG_URL", ""),
        "iptv_max_streams": int(env.get("IPTV_MAX_STREAMS") or 1),
        "discord_webhook": env.get("DISCORD_WEBHOOK", ""),
        "domain": env.get("DOMAIN", ""),
        "acme_email": env.get("ACME_EMAIL", ""),
        "dojo_https": env.get("DOJO_HTTPS", "no") == "yes",
        "backup_keep": int(env.get("BACKUP_KEEP") or 7),
        "backup_schedule": env.get("BACKUP_SCHEDULE", "daily"),
    }


@app.get("/api/settings")
def api_settings():
    return jsonify(settings_view(env_read()))


def build_updates(b, env):
    """Turns the settings form into ninjarr.env values; raises ValueError with a readable message."""
    u = {}
    old_providers = {p.get("host"): p for p in json.loads(env.get("USENET_PROVIDERS") or "[]")}
    providers = []
    balanced = bool(b.get("usenet_balanced", True))
    main_n = 0
    for n, p in enumerate(b.get("providers") or [], start=1):
        host = (p.get("host") or "").strip()
        if not host:
            continue
        pw = p.get("password") or old_providers.get(host, {}).get("password", "")
        backup = bool(p.get("isBackup")) and n > 1
        # load-balanced: every main provider on priority 0; in order: 0, 1, 2 … (backups after them)
        prio = 100 + n if backup else (0 if balanced else main_n)
        main_n += 0 if backup else 1
        providers.append({"id": f"p{n}", "name": host, "host": host, "port": int(p.get("port") or 563),
                          "tls": bool(p.get("tls", True)), "username": (p.get("username") or "").strip(), "password": pw,
                          "maxConnections": int(p.get("maxConnections") or 20), "priority": prio,
                          "isBackup": backup, "enabled": True})
    if not providers:
        raise ValueError("add at least one usenet provider")
    u["USENET_PROVIDERS"] = json.dumps(providers, separators=(",", ":"))

    old_idx = {i.get("url"): i for i in json.loads(env.get("INDEXERS") or "[]")}
    indexers = []
    for i in b.get("indexers") or []:
        url = (i.get("url") or "").strip().rstrip("/")
        if not url:
            continue
        key = i.get("apikey") or old_idx.get(url, {}).get("apikey", "")
        entry = {"name": (i.get("name") or url).strip(), "url": url, "apikey": key}
        preset = (i.get("preset") or "").strip()
        if preset and any(c["name"] == preset for c in catalog()["indexers"]):
            entry["preset"] = preset            # Prowlarr's own definition for this indexer
        api_path = (i.get("apiPath") or "/api").strip()
        if api_path != "/api" and re.fullmatch(r"/[A-Za-z0-9/_-]{1,40}", api_path):
            entry["apiPath"] = api_path
        indexers.append(entry)
    u["INDEXERS"] = json.dumps(indexers, separators=(",", ":"))

    lang = (b.get("language") or "none").strip()
    if lang.lower() != "none" and lang not in LANGUAGES and lang != env.get("PREFERRED_LANGUAGE"):
        raise ValueError("pick a language from the list")
    u["PREFERRED_LANGUAGE"] = lang if lang.lower() != "none" else "none"
    u["REQUIRE_LANGUAGE"] = "yes" if b.get("require_language") and lang.lower() != "none" else "no"
    u["LANGUAGE_WAIT_MINUTES"] = str(max(0, int(b.get("wait_minutes") or 0))) if u["REQUIRE_LANGUAGE"] == "no" else "0"

    u["OPENSUBTITLES_USER"] = (b.get("opensubtitles_user") or "").strip()
    u["OPENSUBTITLES_PASS"] = b.get("opensubtitles_pass") or (env.get("OPENSUBTITLES_PASS", "") if u["OPENSUBTITLES_USER"] else "")

    if b.get("iptv"):
        kind = b.get("iptv_type") or ""
        if kind not in ("xtream", "m3u", ""):
            raise ValueError("unknown IPTV type")
        u.update(IPTV="yes", IPTV_TYPE=kind, IPTV_URL=(b.get("iptv_url") or "").strip().rstrip("/"),
                 IPTV_USER=(b.get("iptv_user") or "").strip() if kind == "xtream" else "",
                 IPTV_PASS=(b.get("iptv_pass") or env.get("IPTV_PASS", "")) if kind == "xtream" else "",
                 IPTV_EPG_URL=(b.get("iptv_epg_url") or "").strip() if kind == "m3u" else "",
                 IPTV_MAX_STREAMS=str(max(1, int(b.get("iptv_max_streams") or 1))))
        if kind and not u["IPTV_URL"]:
            raise ValueError("Live TV: the provider URL is missing")
    else:
        u["IPTV"] = "no"

    hook = (b.get("discord_webhook") or "").strip()
    if hook and not hook.startswith("https://discord.com/api/webhooks/"):
        raise ValueError("a Discord webhook starts with https://discord.com/api/webhooks/")
    u["DISCORD_WEBHOOK"] = hook

    domain = (b.get("domain") or "").strip().lower()
    domain = re.sub(r"^https?://", "", domain).strip("/")
    if domain and not re.fullmatch(r"[a-z0-9.-]+\.[a-z]{2,}", domain):
        raise ValueError("that doesn't look like a domain (e.g. example.com)")
    u["DOMAIN"] = domain
    if "dojo_https" in b:
        u["DOJO_HTTPS"] = "yes" if b.get("dojo_https") and domain else "no"
    if "auto_reboot" in b:
        u["AUTO_REBOOT"] = "yes" if b.get("auto_reboot") else "no"
    u["ACME_EMAIL"] = (b.get("acme_email") or "").strip() if domain else ""
    if domain and "@" not in u["ACME_EMAIL"]:
        raise ValueError("with a domain, an e-mail for Let's Encrypt is needed")

    u["BACKUP_KEEP"] = str(min(60, max(1, int(b.get("backup_keep") or 7))))
    u["BACKUP_SCHEDULE"] = "off" if b.get("backup_schedule") == "off" else "daily"

    if setup_mode(env):  # the login is set once, here; the time zone can change any time (below)
        user = (b.get("admin_user") or "").strip()
        pw = b.get("admin_password") or ""
        if not re.fullmatch(r"[A-Za-z0-9._-]+", user):
            raise ValueError("username: letters, digits, dot, dash and underscore only")
        if len(pw) < 8 or "," in pw or pw != pw.strip():
            raise ValueError("password: 8+ characters, no comma, no space at either end")
        u["ADMIN_USER"], u["ADMIN_PASSWORD"] = user, pw
    tz = (b.get("tz") or "").strip()
    if tz:
        if not re.fullmatch(r"[A-Za-z0-9_+-]+(?:/[A-Za-z0-9_+-]+){0,2}", tz):
            raise ValueError("pick a time zone from the list")
        u["TZ"] = tz
    return u


@app.post("/api/settings")
def api_settings_save():
    b = request.get_json(silent=True) or {}
    env = env_read()
    if running_job():
        return jsonify(ok=False, message="A job is still running. Try again when it's done."), 409
    try:
        updates = build_updates(b, env)
        env_write(updates)
    except (ValueError, TypeError) as e:
        return jsonify(ok=False, message=str(e)), 400
    try:
        jid = queue_job("apply")
    except RuntimeError:     # a job started in the meantime: the settings wait for the next one
        return jsonify(ok=False, message="Saved. Another job started just now, so they're applied when you press Save and apply again after it."), 409
    return jsonify(ok=True, id=jid)


# ─────────────────────────────────────────────── app access
def key_for(name, env):
    if name == "sonarr": return {"X-Api-Key": env.get("SONARR_API_KEY", "")}
    if name == "radarr": return {"X-Api-Key": env.get("RADARR_API_KEY", "")}
    if name == "prowlarr": return {"X-Api-Key": env.get("PROWLARR_API_KEY", "")}
    if name == "emby": return {"X-Emby-Token": env.get("EMBY_API_KEY", "")}
    if name == "bazarr":
        return {"X-API-KEY": env.get("BAZARR_API_KEY", "")}        # saved by bootstrap.sh (wire_bazarr)
    if name == "seerr":
        f = DATA / "appdata/seerr/settings.json"
        try:
            return {"X-Api-Key": json.loads(f.read_text())["main"]["apiKey"]}
        except (OSError, KeyError, ValueError):
            return {}
    return {}


def call(name, path, env, method="GET", **kw):
    return requests.request(method, APPS[name] + path, headers=key_for(name, env), timeout=kw.pop("timeout", T), **kw)


def get_json(name, path, env, default=None):
    try:
        r = call(name, path, env)
        return r.json() if r.ok else default
    except (requests.RequestException, ValueError):
        return default


# ─────────────────────────────────────────────── health
def check(group, label, status, detail="", fix=None):
    return {"group": group, "label": label, "status": status, "detail": detail, "fix": fix}


HEALTH_TTL = 20   # every open page and the push watcher share one result; a finished job clears it


def shared_health(env=None):
    return cached("health", HEALTH_TTL, lambda: health_checks(env or env_read()))


@app.get("/api/health")
def api_health():
    return jsonify(checks=shared_health())


def gb(mb):
    return f"{mb / 1024:.1f} GB" if mb >= 1024 else f"{mb} MB"


def memory_check(hs):
    """The VM's memory, from the host's status file: which apps use the most, and any app that was
    stopped and restarted for running out of memory (its ceiling, compose/stack.yml) this week."""
    m = (hs or {}).get("memory")
    if not m:
        return check("Host", "Memory", "ok", "")
    used = m["total_mb"] - m["available_mb"]
    top = ", ".join(f"{a['name'].capitalize()} {gb(a['mb'])}" for a in (m.get("apps") or [])[:3])
    oom = [o for o in m.get("oom") or [] if o.get("app") in SERVICES and time.time() - o["at"] < 7 * 86400]
    if oom:
        last = oom[-1]
        name = last["app"].capitalize()
        lim = next((a["limit_mb"] for a in m.get("apps") or [] if a["name"] == last["app"]), None)
        what = f"hit its memory ceiling ({gb(lim)})" if last.get("ceiling") and lim else "ran out of memory"
        more = f" ({len(oom)} times this week)" if len(oom) > 1 else ""
        return check("Host", "Memory", "warn", f"{name} {what} on {datetime.fromtimestamp(last['at']).strftime('%a %d %b, %H:%M')}{more} "
                     f"and was cut off there; the rest of the VM kept running. If it keeps happening, raise it with "
                     f"{last['app'].upper()}_MEM in ninjarr.env.")
    if m["available_mb"] < 0.1 * m["total_mb"]:
        return check("Host", "Memory", "warn", f"almost full: {gb(used)} of {gb(m['total_mb'])} in use · most: {top}")
    return check("Host", "Memory", "ok", f"{gb(used)} of {gb(m['total_mb'])} in use · most: {top}")


def health_checks(env):
    out = []
    restart = lambda s: {"job": f"restart {s}", "label": f"Restart {s.capitalize()}"}
    rewire = {"job": "wire", "label": "Re-apply settings"}

    status_paths = {"sonarr": "/api/v3/system/status", "radarr": "/api/v3/system/status",
                    "prowlarr": "/api/v1/system/status", "emby": "/emby/System/Info",
                    "seerr": "/api/v1/status", "bazarr": "/api/system/status"}
    up = {}
    for name, path in status_paths.items():
        js = get_json(name, path, env)
        up[name] = js is not None
        ver = (js or {}).get("version") or (js or {}).get("Version") or ((js or {}).get("data") or {}).get("bazarr_version")
        out.append(check("Apps", name.capitalize(), "ok" if js is not None else "fail",
                         f"version {ver}" if ver else ("" if js is not None else "not answering"),
                         None if js is not None else restart(name)))
    try:
        sab = requests.get(APPS["aiostreams"] + "/api/v1/sabnzbd/api", timeout=T, params={
            "mode": "version", "output": "json", "apikey": f"arr:{env.get('ARR_CLIENT_PASSWORD', '')}"})
        up["aiostreams"] = sab.ok
    except requests.RequestException:
        up["aiostreams"] = False
    out.append(check("Apps", "AIOStreams", "ok" if up["aiostreams"] else "fail",
                     "download client API answers" if up["aiostreams"] else "not answering",
                     None if up["aiostreams"] else restart("aiostreams")))

    app_warnings = {}
    for name in ("sonarr", "radarr"):
        if not up[name]:
            continue
        label = name.capitalize()
        fs = get_json(name, "/api/v3/filesystem?path=/mnt/aiostreams/usenet/completed/&allowFoldersWithoutTrailingSlashes=true", env)
        mounted = isinstance(fs, dict) and "directories" in fs
        out.append(check("Streaming chain", f"{label} sees the AIOStreams library", "ok" if mounted else "fail",
                         "" if mounted else "imports will fail until the mount is back", None if mounted else restart("aiostreams")))
        clients = get_json(name, "/api/v3/downloadclient", env, []) or []
        client = next((c for c in clients if c.get("name") == "AIOStreams"), None)
        if not client:
            out.append(check("Streaming chain", f"{label} → AIOStreams", "fail", "download client missing", rewire))
        else:
            try:
                r = call(name, "/api/v3/downloadclient/test", env, "POST", json=client, timeout=20)
                good = r.ok
            except requests.RequestException:
                good = False
            out.append(check("Streaming chain", f"{label} → AIOStreams", "ok" if good else "fail",
                             "connection test passed" if good else "connection test failed", None if good else restart("aiostreams")))
        roots = get_json(name, "/api/v3/rootfolder", env, []) or []
        good = bool(roots) and all(r.get("accessible") for r in roots)
        out.append(check("Streaming chain", f"{label} library folder", "ok" if good else "fail",
                         ", ".join(r.get("path", "") for r in roots) if good else "missing or not accessible", None if good else rewire))
        app_warnings[label] = [h.get("message", "") for h in get_json(name, "/api/v3/health", env, []) or []]

    if up["prowlarr"]:
        idx = get_json("prowlarr", "/api/v1/indexer", env, []) or []
        st = get_json("prowlarr", "/api/v1/indexerstatus", env, []) or []
        names = {i["id"]: i.get("name") for i in idx}
        out.append(check("Search", "Indexers", "ok" if idx else "warn",
                         f"{len(idx)} in Prowlarr" if idx else "None yet, so nothing can be searched.",
                         None if idx else {"go": "settings/indexers", "label": "Add an indexer"}))
        if not idx:   # Sonarr and Radarr say the same four ways; the line above covers it
            app_warnings = {k: [m for m in v if not m.startswith("No indexers available")] for k, v in app_warnings.items()}
        for s in st:
            if s.get("disabledTill"):
                out.append(check("Search", f"Indexer {names.get(s.get('indexerId'), '?')}", "warn",
                                 f"paused after errors until {s['disabledTill'][:16].replace('T', ' ')}"))

    # what Sonarr/Radarr report themselves: one line per app
    for label, msgs in app_warnings.items():
        if msgs:
            out.append(check("Warnings", f"{label} says", "warn", msgs[0] + (f" (and {len(msgs) - 1} more)" if len(msgs) > 1 else ""),
                             {"open": {"Sonarr": 8989, "Radarr": 7878}[label], "path": "/system/status", "label": f"Open {label}"}))

    if up["emby"]:
        libs = get_json("emby", "/emby/Library/VirtualFolders", env, []) or []
        out.append(check("Playback", "Emby libraries", "ok" if len(libs) >= 2 else "fail",
                         ", ".join(l.get("Name", "") for l in libs) or "missing", None if len(libs) >= 2 else rewire))
    if up["seerr"]:
        pub = get_json("seerr", "/api/v1/settings/public", env, {}) or {}
        good = pub.get("initialized") and pub.get("mediaServerType") == 3
        out.append(check("Playback", "Seerr signed in through Emby", "ok" if good else "fail", "", None if good else rewire))
    if up["bazarr"]:
        prov = ((get_json("bazarr", "/api/system/settings", env, {}) or {}).get("general") or {}).get("enabled_providers") or []
        out.append(check("Playback", "Subtitle providers", "ok" if prov else "warn", ", ".join(prov) or "none", None if prov else rewire))

    if env.get("IPTV") == "yes":
        try:
            m3u = requests.get(APPS["dispatcharr"] + "/output/m3u", timeout=T).text
            n = m3u.count("#EXTINF")
            out.append(check("Live TV", "Dispatcharr channels", "ok" if n else "warn",
                             f"{n} channel(s) for Emby" if n else "None yet. Pick the channels you want in Dispatcharr.",
                             None if n else {"open": 9191, "label": "Open Dispatcharr"}))
            tuners = (get_json("emby", "/emby/System/Configuration/livetv", env, {}) or {}).get("TunerHosts") or []
            tuner = any("dispatcharr" in (t.get("Url") or "") for t in tuners)
            out.append(check("Live TV", "Emby's tuner", "ok" if tuner else "fail", "Dispatcharr" if tuner else "Dispatcharr isn't set up as Emby's tuner",
                             None if tuner else rewire))
            if not env.get("DISPATCHARR_API_KEY"):
                out.append(check("Live TV", "Live TV in Dojo", "warn",
                                 "Dojo can't see what's playing through Dispatcharr yet.",
                                 {"go": "settings/livetv", "label": "Connect"}))
        except requests.RequestException:
            out.append(check("Live TV", "Dispatcharr", "fail", "not answering", restart("dispatcharr")))

    hs = host_status()
    if hs is None or not hs.get("auto"):
        out.append(check("Host", "Security updates", "warn", "Not automatic yet. Updating ninjarr sets them up.",
                         {"job": "update", "label": "Update"}))
    elif hs.get("reboot_required"):
        pk = ", ".join(hs.get("reboot_packages") or [])
        out.append(check("Host", "Security updates", "warn", "A restart finishes a security update" + (f" ({pk})" if pk else "") + ".",
                         {"job": "reboot", "label": "Restart now"}))
    else:
        out.append(check("Host", "Security updates", "ok", "install automatically"
                         + (f", last on {datetime.fromtimestamp(hs['last_update']).strftime('%d %b')}" if hs.get("last_update") else "")))

    gpu = (hs or {}).get("gpu")
    if gpu:
        name = {"intel": "Intel", "amd": "AMD"}.get(gpu, gpu)
        if not hs.get("gpu_ready"):
            out.append(check("Host", "Hardware transcoding", "warn",
                             f"The {name} GPU's driver loads after a restart." if hs.get("reboot_required")
                             else f"An {name} GPU is here, but without a driver. Updating ninjarr installs it.",
                             {"job": "reboot", "label": "Restart now"} if hs.get("reboot_required") else {"job": "update", "label": "Update"}))
        elif not hs.get("emby_gpu"):
            out.append(check("Host", "Hardware transcoding", "warn", f"The {name} GPU is ready, but Emby doesn't have it yet.",
                             {"job": "apply", "label": "Give it to Emby"}))
        else:
            enc = get_json("emby", "/emby/System/Configuration/encoding", env, {}) if up.get("emby") else {}
            off = (enc or {}).get("HardwareAccelerationMode") == 0
            out.append(check("Host", "Hardware transcoding", "warn" if off else "ok",
                             f"Emby has the {name} GPU, but hardware acceleration is off in its Transcoding settings." if off
                             else f"Emby transcodes on the {name} GPU",
                             {"open": 8096, "path": "/web/index.html#!/transcoding", "label": "Open Emby"} if off else None))
    out.append(memory_check(hs))
    du = shutil.disk_usage(DATA)
    pct = round(du.used * 100 / du.total)
    out.append(check("Host", "Disk", "ok" if pct < 90 else "warn", f"{pct}% used, {du.free // 2**30} GB free"))
    backups = list_backups(env)
    if not backups and backup_path(env) is None:
        # kept in a folder Dojo can't see (BACKUP_DIR elsewhere): the host notes each one it makes
        try:
            m = re.search(r"ninjarr-(\d{8}-\d{6})\.tar\.gz", (STATE / "last-backup").read_text())
            t = datetime.strptime(m.group(1), "%Y%m%d-%H%M%S").timestamp() if m else None
        except (OSError, ValueError):
            t = None
        if t:
            backups = [{"mtime": t, "when": datetime.fromtimestamp(t).strftime("%Y-%m-%d %H:%M")}]
    if not backups:
        out.append(check("Host", "Backups", "warn", "none yet", {"job": "backup", "label": "Back up now"}))
    else:
        age = (time.time() - backups[0]["mtime"]) / 86400
        out.append(check("Host", "Backups", "ok" if age <= 2 else "warn", f"last one {backups[0]['when']}",
                         None if age <= 2 else {"job": "backup", "label": "Back up now"}))
    return out


# ─────────────────────────────────────────────── library actions
def replace_broken(app_name, env):
    """Files whose release AIOStreams found incomplete or gone: the release goes on the blocklist
    (marked failed, so it's never grabbed again), the file is removed, and a search starts for
    another release. 25 at a time. File ids keep this safe if Sonarr/Radarr replaced one meanwhile."""
    lib = cached("library", 600, lambda: collect_library(env))
    todo = [f for f in lib["files"] if f["app"] == app_name and f.get("usenet") and f.get("id")][:25]
    if not todo:
        return jsonify(ok=True, message="Nothing to replace.")
    blocked, search = set(), []
    for f in todo:
        if f.get("nzo") and f["nzo"] not in blocked:
            hist = get_json(app_name, f"/api/v3/history?downloadId={f['nzo']}&eventType=1&pageSize=10", env, {}) or {}
            recs = hist.get("records") or []
            if recs:
                call(app_name, f"/api/v3/history/failed/{recs[0]['id']}", env, "POST")
            blocked.add(f["nzo"])
        if app_name == "sonarr":
            eps = [e["id"] for e in get_json("sonarr", f"/api/v3/episode?episodeFileId={f['id']}", env, []) or []]
            if call("sonarr", f"/api/v3/episodefile/{f['id']}", env, "DELETE").ok:
                search += eps
        else:
            if call("radarr", f"/api/v3/moviefile/{f['id']}", env, "DELETE").ok:
                search.append(f["owner"])
    if search:
        cmd = {"name": "EpisodeSearch", "episodeIds": search} if app_name == "sonarr" else {"name": "MoviesSearch", "movieIds": search}
        call(app_name, "/api/v3/command", env, "POST", json=cmd)
    _cache.pop("library", None)
    publish({"src": app_name, "toast": None}, library=True)
    what = "episode" if app_name == "sonarr" else "movie"
    if not search:
        return jsonify(ok=False, message=f"{app_name.capitalize()} didn't take any of them. Its log says why.")
    return jsonify(ok=True, message=f"{app_name.capitalize()} is looking for a complete release of {plural_py(len(search), what)}.")


def plural_py(n, one):
    return f"{n} {one}" + ("" if n == 1 else "s")


@app.post("/api/library/<app_name>/<action>")
def api_library(app_name, action):
    env = env_read()
    if app_name not in ("sonarr", "radarr") or action not in ("search-missing", "upgrade-language", "replace-broken", "upgrade-hard"):
        abort(404)
    try:
        if action == "replace-broken":
            return replace_broken(app_name, env)
        if action == "upgrade-hard":
            lib = cached("library", 600, lambda: collect_library(env))
            ids = sorted({f["owner"] for f in lib["files"] if f["app"] == app_name and f.get("owner")
                          and (f.get("codec") == "AV1" or f.get("range") == "DV")})
            if not ids:
                return jsonify(ok=True, message="Nothing to look for.")
            cmd = [{"name": "SeriesSearch", "seriesId": i} for i in ids[:25]] if app_name == "sonarr" \
                else [{"name": "MoviesSearch", "movieIds": ids[:25]}]
            for c in cmd:
                call(app_name, "/api/v3/command", env, "POST", json=c)
            what = "series" if app_name == "sonarr" else "movie"
            return jsonify(ok=True, message=f"{app_name.capitalize()} is looking for better versions of {len(ids[:25])} {what}{'' if what == 'series' or len(ids) == 1 else 's'}.")
        if action == "search-missing":
            cmd = {"name": "MissingEpisodeSearch"} if app_name == "sonarr" else {"name": "MissingMoviesSearch"}
            call(app_name, "/api/v3/command", env, "POST", json=cmd).raise_for_status()
            return jsonify(ok=True, message="Search for everything missing started.")
        # titles with a file that has no audio in your language (by its tracks, else its name), 25 at a
        # time — the library Library already collected knows which (no walk through every series again)
        lib = cached("library", 600, lambda: collect_library(env))
        todo = sorted({f["owner"] for f in lib["files"] if f["app"] == app_name and f.get("owner") and not f.get("in_lang")})
        if app_name == "sonarr":
            for sid in todo[:25]:
                call("sonarr", "/api/v3/command", env, "POST", json={"name": "SeriesSearch", "seriesId": sid})
        elif todo:
            call("radarr", "/api/v3/command", env, "POST", json={"name": "MoviesSearch", "movieIds": todo[:25]})
        if not todo:
            return jsonify(ok=True, message="Everything is already in your language.")
        more = f" ({len(todo) - 25} more next time)" if len(todo) > 25 else ""
        return jsonify(ok=True, message=f"Searching {min(25, len(todo))} title(s) for a release in your language{more}.")
    except requests.RequestException:
        return jsonify(ok=False, message=f"{app_name.capitalize()} isn't answering."), 502


# ─────────────────────────────────────────────── the timeline (Stats → Timeline) and its helpers
def ts(s):
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()
    except (AttributeError, ValueError):
        return 0


REASONS = {
    "VideoCodecNotSupported": "the device can't decode this video codec",
    "AudioCodecNotSupported": "the device can't decode this audio codec",
    "ContainerNotSupported": "the device doesn't take this file type",
    "ContainerBitrateExceedsLimit": "the bitrate is above the device's or connection's limit",
    "VideoBitrateNotSupported": "the bitrate is above the device's limit",
    "AudioBitrateNotSupported": "the audio bitrate is above the device's limit",
    "VideoRangeNotSupported": "the device can't show HDR",
    "VideoRangeTypeNotSupported": "the device can't show this kind of HDR (e.g. Dolby Vision)",
    "VideoProfileNotSupported": "the device doesn't support this video profile",
    "VideoLevelNotSupported": "the device doesn't support this video level",
    "VideoResolutionNotSupported": "the device can't show this resolution",
    "VideoFramerateNotSupported": "the device doesn't support this frame rate",
    "VideoBitDepthNotSupported": "the device doesn't support this bit depth (often 10-bit)",
    "AudioChannelsNotSupported": "more audio channels than the device takes",
    "AudioProfileNotSupported": "the device doesn't support this audio profile",
    "SubtitleCodecNotSupported": "the subtitles have to be burned into the picture",
    "AnamorphicVideoNotSupported": "the device can't play anamorphic video",
    "InterlacedVideoNotSupported": "the device can't play interlaced video",
    "DirectPlayError": "direct play failed on the device",
}


def session_info(s_):
    """One Emby playback session as Dojo shows it: who, where, what, and how it plays."""
    item = s_.get("NowPlayingItem") or {}
    name = item.get("Name", "")
    live = item.get("Type") in ("TvChannel", "Program") or item.get("ChannelType") == "TV"
    if live and (item.get("CurrentProgram") or {}).get("Name"):
        name = f"{name} — {item['CurrentProgram']['Name']}"
    if item.get("SeriesName") and not live:
        name = f"{item['SeriesName']} S{item.get('ParentIndexNumber', 0):02d}E{item.get('IndexNumber', 0):02d} — {name}"
    video = next((m for m in item.get("MediaStreams") or [] if m.get("Type") == "Video"), {})
    src = []
    if video.get("Codec"):
        src.append(video["Codec"].upper().replace("H264", "H.264"))
    rng = video.get("VideoRangeType") or video.get("VideoRange") or ""
    if rng and rng.upper() not in ("SDR", ""):
        src.append("Dolby Vision" if "DOVI" in rng.upper() or "DOLBY" in rng.upper() else "HDR")
    if video.get("Height"):
        src.append(res_label(video["Height"]))        # the same labels as the watch history
    tc = s_.get("TranscodingInfo") or {}
    if not tc:
        how = "direct play"
    elif tc.get("IsVideoDirect", False) and tc.get("IsAudioDirect", False):
        how = "direct stream"
    elif tc.get("IsVideoDirect", False):
        how = "audio transcoding"
    else:
        how = "transcoding"
    reasons = [REASONS.get(r, re.sub(r"(?<!^)(?=[A-Z])", " ", r).lower()) for r in tc.get("TranscodeReasons") or []]
    bitrate = tc.get("Bitrate") or item.get("Bitrate")
    return {"user": s_.get("UserName", ""), "device": s_.get("DeviceName") or s_.get("Client", ""), "client": s_.get("Client", ""),
            "title": name, "source": " ".join(src), "how": how, "reasons": reasons,
            "via": "dispatcharr" if live else "aiostreams",
            "mbps": round(bitrate / 1e6, 1) if bitrate else None,
            "hw": bool(tc.get("VideoDecoderIsHardware") or tc.get("VideoEncoderIsHardware")) if how == "transcoding" else None,
            "paused": (s_.get("PlayState") or {}).get("IsPaused", False),
            "link": src_link("emby", f"/web/index.html#!/item?id={item['Id']}&serverId={s_.get('ServerId', '')}") if item.get("Id") else None}


@app.get("/api/activity")
def api_activity():
    env = env_read()
    ev = []
    kinds = {"grabbed": "grab", "downloadFolderImported": "import", "episodeFileImported": "import",
             "movieFileImported": "import", "downloadFailed": "failed", "importFailed": "failed",
             "episodeFileDeleted": "deleted", "movieFileDeleted": "deleted"}
    for name, inc in (("sonarr", "includeSeries=true&includeEpisode=true"), ("radarr", "includeMovie=true")):
        js = get_json(name, f"/api/v3/history?pageSize=40&sortKey=date&sortDirection=descending&{inc}", env, {}) or {}
        for r in js.get("records", []):
            kind = kinds.get(r.get("eventType"))
            if not kind:
                continue
            if name == "sonarr":
                ep = r.get("episode") or {}
                title = f"{(r.get('series') or {}).get('title', '?')} S{ep.get('seasonNumber', 0):02d}E{ep.get('episodeNumber', 0):02d}"
                link = arr_link("sonarr", (r.get("series") or {}).get("titleSlug"))
            else:
                title = f"{(r.get('movie') or {}).get('title', '?')} ({(r.get('movie') or {}).get('year', '')})"
                link = arr_link("radarr", (r.get("movie") or {}).get("titleSlug"))
            data = r.get("data") or {}
            detail = r.get("sourceTitle", "")
            if kind == "failed":
                detail = data.get("message") or detail
            ev.append({"t": ts(r.get("date")), "kind": kind, "app": name, "title": title, "detail": detail,
                       "score": r.get("customFormatScore"), "link": link})
    reqs = get_json("seerr", "/api/v1/request?take=20&skip=0&sort=added", env, {}) or {}
    for r in reqs.get("results", []):
        media = r.get("media") or {}
        who = (r.get("requestedBy") or {}).get("displayName", "")
        title = media.get("title") or media.get("name") or seerr_title(r.get("type"), media.get("tmdbId"), env)
        tmdb = media.get("tmdbId")
        ev.append({"t": ts(r.get("createdAt")), "kind": "request", "app": "seerr", "title": title,
                   "detail": f"by {who}" if who else "",
                   "link": src_link("seerr", f"/{'tv' if r.get('type') == 'tv' else 'movie'}/{tmdb}") if tmdb else None})
    # what people watched, from Dojo's own watch history
    for r in history.recent(60):
        mins = round(r["watched"] / 60)
        via = "live TV" if r["via"] == "livetv" else "usenet"
        done = r["via"] != "livetv" and r["runtime"] and r["position"] and r["position"] >= 0.9 * r["runtime"]
        ev.append({"t": r["started"], "kind": "play", "app": "emby", "title": r["title"],
                   "detail": f"{r['user']} on {r['device'] or r['client']} · {mins} min{' · to the end' if done else ''} · {via}"
                             + (" · transcoding" if r["method"] == "transcoding" else "")
                             + (f" · IPTV login {r['login']}" if r["login"] else ""),
                   "link": src_link("emby", f"/web/index.html#!/item?id={r['item_id']}&serverId={r['server_id'] or ''}") if r["item_id"] else None})
    ev.sort(key=lambda e: e["t"], reverse=True)
    return jsonify(events=ev[:100])


# ─────────────────────────────────────────────── backups and versions
BACKUP_NAME = re.compile(r"^ninjarr-\d{8}-\d{6}\.tar\.gz$")


def backup_path(env):
    host_dir = env.get("BACKUP_DIR") or f"{env.get('NINJARR_DATA', '/opt/ninjarr')}/backups"
    data = env.get("NINJARR_DATA", "/opt/ninjarr").rstrip("/")
    if host_dir == data or host_dir.startswith(data + "/"):
        return DATA / host_dir[len(data):].lstrip("/")
    return None  # outside the data folder: Dojo can't see it


def list_backups(env):
    d = backup_path(env)
    if not d or not d.is_dir():
        return []
    out = []
    for f in sorted(d.glob("ninjarr-*.tar.gz"), key=lambda p: p.stat().st_mtime, reverse=True):
        if BACKUP_NAME.match(f.name):
            st = f.stat()
            out.append({"name": f.name, "size": st.st_size, "mtime": st.st_mtime,
                        "when": datetime.fromtimestamp(st.st_mtime).strftime("%Y-%m-%d %H:%M")})
    return out


@app.get("/api/backups")
def api_backups():
    env = env_read()
    return jsonify(backups=list_backups(env), visible=backup_path(env) is not None,
                   schedule=env.get("BACKUP_SCHEDULE", "daily"), keep=int(env.get("BACKUP_KEEP") or 7))


@app.get("/api/backups/<name>")
def api_backup_download(name):
    env = env_read()
    d = backup_path(env)
    if not BACKUP_NAME.match(name) or not d or not (d / name).is_file():
        abort(404)
    return send_file(d / name, as_attachment=True, download_name=name)


def ninjarr_version():
    try:
        m = re.search(r'^NINJARR_VERSION="([^"]+)"', (ROOT / "bootstrap.sh").read_text(), re.M)
        return m.group(1) if m else "?"
    except OSError:
        return "?"


def git_head():
    try:
        head = (ROOT / ".git/HEAD").read_text().strip()
        if head.startswith("ref: "):
            ref = ROOT / ".git" / head[5:]
            if ref.exists():
                return ref.read_text().strip()
            packed = (ROOT / ".git/packed-refs").read_text()
            m = re.search(rf"^([0-9a-f]{{40}}) {re.escape(head[5:])}$", packed, re.M)
            return m.group(1) if m else None
        return head
    except OSError:
        return None


def current_tags(env):
    """The version each app runs: versions.env, or the version tried in its place (ninjarr.env)."""
    tags = {}
    vf = ROOT / "versions.env"
    if vf.exists():
        for line in vf.read_text().splitlines():
            m = ENV_LINE.match(line)
            if m:
                tags[m.group(1).removesuffix("_TAG").lower()] = env.get(m.group(1)) or m.group(2)
    return tags


def news_for(head, tags, fresh=False):
    """whats_new for this copy, at most every 10 minutes (GitHub allows 60 calls an hour without a
    login), or every 30 seconds when someone presses "Check now"."""
    try:
        cfg = (ROOT / ".git/config").read_text()
    except OSError:
        return None
    m = re.search(r"url = https://github.com/([^/\s]+/[^/\s]+?)(?:\.git)?\s", cfg)
    if not (m and head):
        return None
    key = f"news-{head}"
    if fresh and time.time() - _cache.get(key, (0,))[0] > 30:
        _cache.pop(key, None)
    return cached(key, 600, lambda: whats_new(m.group(1), head, tags))


@app.get("/api/versions")
def api_versions():
    env = env_read()
    tags = current_tags(env)
    head = git_head()
    news = news_for(head, tags, bool(request.args.get("fresh")))
    behind = news["behind"] if news else None
    tries = []
    for f in sorted((STATE / "tries").glob("*.json")) if (STATE / "tries").exists() else []:
        try:
            t = json.loads(f.read_text())
            tries.append({k: t.get(k) for k in ("app", "from", "to", "state", "when")})
        except (OSError, ValueError):
            pass
    trying = {t["app"]: t["to"] for t in tries if t["state"] in ("running", "trying")}
    # the list is from the last check: drop what an update or a try has caught up with since
    newer = [dict(u, running=tags[u["app"]]) for u in (_upstream["apps"] or [])
                if u["app"] in tags and trying.get(u["app"]) != u["newest"]
                and vkey(u["newest"]) > vkey(tags[u["app"]])]
    return jsonify(ninjarr=ninjarr_version(), commit=(head or "")[:7], update_available=behind, images=tags,
                   news=news if behind else None, upstream=newer, tries=tries)


# ─────────────────────────────────────────────── newer app versions than ninjarr tested
# ninjarr runs the versions in versions.env and moves them forward in its own releases, once they
# work together. Dojo still shows when an app has published something newer, so you know.
UPSTREAM = upstream.REPOS
vkey = upstream.vkey
_upstream = {"t": 0, "apps": None}


def check_upstream():
    """Every 6 hours, and right away when the versions in use change (an update, a try): not on
    every settings save. A failure is logged and tried again later; the thread never ends."""
    seen = None
    while True:
        try:
            tags = current_tags(env_read())
            if tags != seen:
                seen, out = tags, []
                for app_, repo in UPSTREAM.items():
                    cur = tags.get(app_)
                    if not cur or cur == "latest":
                        continue
                    try:
                        new = upstream.newest(repo, cur, pages=30)
                    except Exception:        # a registry hiccup skips this app until the next look
                        continue
                    if new:
                        out.append({"app": app_, "running": cur, "newest": new})
                _upstream.update(t=time.time(), apps=out)
        except Exception as e:
            print(f"newer-versions check: {type(e).__name__}: {e}", flush=True)
        for _ in range(6 * 60):
            time.sleep(60)
            if current_tags(env_read()) != seen:
                break
        else:
            seen = None              # 6 hours passed: look again even if nothing changed here


TRAILER = re.compile(r"^(Co-Authored-By|Claude-Session|Signed-off-by|https://claude\.ai/)", re.I)


def whats_new(repo, head, tags):
    """What an update would bring: the changes since this copy (each commit's title and its
    explanation), the new ninjarr version, and which apps move to another version."""
    gh = {"Accept": "application/vnd.github+json"}
    try:
        r = requests.get(f"https://api.github.com/repos/{repo}/commits/main", timeout=8, headers=gh)
        if not r.ok:
            return None
        latest = r.json()
    except (requests.RequestException, ValueError):
        return None
    if latest.get("sha") == head:
        return {"behind": False}
    out = {"behind": True, "sha": latest.get("sha"), "restarted": False, "changes": [], "version": None, "apps": []}
    try:
        c = requests.get(f"https://api.github.com/repos/{repo}/compare/{head}...{latest['sha']}", timeout=8, headers=gh)
        if c.status_code != 404 and not c.ok:
            return None                 # rate limit or an outage: couldn't check, say so
        commits = c.json().get("commits", []) if c.ok else None
    except (requests.RequestException, ValueError):
        return None
    if commits is None:      # 404: this copy's commit isn't on GitHub any more, the history was started over
        out["restarted"] = True
        commits = [latest]
    for cm in reversed(commits[-30:]):
        lines = [l for l in (cm.get("commit", {}).get("message") or "").splitlines() if not TRAILER.match(l.strip())]
        title = lines[0].strip() if lines else ""
        body = "\n".join(lines[1:]).strip()
        out["changes"].append({"title": title, "body": re.sub(r"\s*\n\s*(?!-)", " ", body)[:1200],
                               "when": ts(cm.get("commit", {}).get("committer", {}).get("date"))})
    try:
        raw = f"https://raw.githubusercontent.com/{repo}/{latest['sha']}"
        b = requests.get(f"{raw}/bootstrap.sh", timeout=8)
        m = re.search(r'^NINJARR_VERSION="([^"]+)"', b.text, re.M) if b.ok else None
        out["version"] = m.group(1) if m else None
        v = requests.get(f"{raw}/versions.env", timeout=8)
        if v.ok:
            for line in v.text.splitlines():
                mm = ENV_LINE.match(line)
                if mm:
                    app_ = mm.group(1).removesuffix("_TAG").lower()
                    if app_ in tags and tags[app_] != mm.group(2):
                        out["apps"].append({"app": app_, "from": tags[app_], "to": mm.group(2)})
    except requests.RequestException:
        pass
    return out


# ─────────────────────────────────────────────── stack: what only shows when the apps are joined up
# AIOStreams has its own detailed usenet dashboard; nothing here repeats it. Dojo measures the
# joins: request → grab → library → watched, which indexer actually fed the library, whether dead
# releases got replaced, and whether the library ends up the way the quality rules intend.
WINDOW_HOURS = {"24h": 24, "7d": 168, "30d": 720}
_cache = {}
_aio = {"s": None}


_cache_locks, _cache_guard = {}, threading.Lock()


def cached(key, ttl, fn):
    hit = _cache.get(key)
    if hit and time.time() - hit[0] < ttl:
        return hit[1]
    # several pages asking at once: one works it out, the others wait for its answer
    with _cache_guard:
        lock = _cache_locks.setdefault(key, threading.Lock())
    with lock:
        hit = _cache.get(key)
        if hit and time.time() - hit[0] < ttl:
            return hit[1]
        val = fn()
        _cache[key] = (time.time(), val)
        return val


def aio_get(path, env):
    """AIOStreams' dashboard API with the ninjarr login (the same as AIOStreams' admin login)."""
    for _ in range(2):
        if _aio["s"] is None:
            sess = requests.Session()
            try:
                r = sess.post(APPS["aiostreams"] + "/api/v1/auth/login", timeout=T,
                              json={"username": env.get("ADMIN_USER", ""), "password": env.get("ADMIN_PASSWORD", "")})
                if not r.ok:
                    return None
            except requests.RequestException:
                return None
            _aio["s"] = sess
        try:
            r = _aio["s"].get(APPS["aiostreams"] + "/api/v1/dashboard" + path, timeout=T, allow_redirects=False)
            if r.status_code in (401, 302, 403):
                _aio["s"] = None
                continue
            return (r.json() or {}).get("data") if r.ok else None
        except (requests.RequestException, ValueError):
            return None
    return None


def iso_since(hours):
    return datetime.fromtimestamp(time.time() - hours * 3600, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def short_app(ua):
    """A player's name from its user agent: 'Emby', 'TiviMate', 'VLC', …"""
    ua = ua or ""
    for name in ("Emby", "TiviMate", "VLC", "Kodi", "IPTVnator", "Channels", "ffmpeg", "Lavf", "Chrome", "Safari", "Firefox"):
        if name.lower() in ua.lower():
            return {"Lavf": "ffmpeg"}.get(name, name)
    return (ua.split("/")[0].strip() or "a player")[:24]


def dispatcharr_status(env):
    """Live TV through Dispatcharr right now: channels, who watches them, and how many of each
    IPTV login's connections are in use. Needs DISPATCHARR_API_KEY (Settings → Live TV)."""
    if env.get("IPTV") != "yes":
        return None
    key = env.get("DISPATCHARR_API_KEY", "")
    if not key:
        return {"ok": False, "reason": "no-key"}
    h = {"X-API-Key": key}
    try:
        st = requests.get(APPS["dispatcharr"] + "/proxy/ts/status", headers=h, timeout=T)
        if st.status_code in (401, 403):
            return {"ok": False, "reason": "rejected"}
        st.raise_for_status()
        accounts = cached("dispatcharr-accounts", 300, lambda: requests.get(
            APPS["dispatcharr"] + "/api/m3u/accounts/", headers=h, timeout=T).json())
    except (requests.RequestException, ValueError):
        return {"ok": False, "reason": "down"}
    profiles = {}
    for acc in accounts if isinstance(accounts, list) else []:
        for pr in acc.get("profiles") or []:
            label = acc.get("name", "?") if len(acc.get("profiles") or []) == 1 else f"{acc.get('name', '?')} · {pr.get('name', '')}"
            profiles[pr.get("id")] = {"name": label, "max": pr.get("max_streams") or acc.get("max_streams") or 0,
                                      "active": acc.get("is_active", True) and pr.get("is_active", True), "used": 0}
    channels = []
    for c in (st.json() or {}).get("channels") or []:
        pid = c.get("m3u_profile_id")
        if pid in profiles:
            profiles[pid]["used"] += 1
        channels.append({
            "name": c.get("channel_name") or c.get("stream_name") or "a channel",
            "watchers": [{"app": short_app(x.get("user_agent")), "ip": x.get("ip_address", "")} for x in c.get("clients") or []],
            "clients": c.get("client_count", 0),
            "kbps": round(c["avg_bitrate_kbps"]) if c.get("avg_bitrate_kbps") else None,
            "quality": " ".join(x for x in (c.get("resolution") or "", (c.get("video_codec") or "").upper()) if x),
            "login": (profiles.get(pid) or {}).get("name"),
            "healthy": c.get("healthy", True),
            "minutes": round((c.get("uptime") or 0) / 60),
        })
    logins = [p for p in profiles.values() if p["active"] and p["name"] != "custom"]
    return {"ok": True, "channels": channels, "logins": logins}


# ─────────────────────────────────────────────── watch history (recorded by history.py)
def res_label(h):
    if not h:
        return None
    return "2160p" if h > 1600 else "1440p" if h > 1200 else "1080p" if h > 900 else "720p" if h > 600 else "576p" if h > 500 else "480p" if h > 400 else "SD"


def play_details(x):
    """The technical side of one Emby session: what the file is, what reaches the screen."""
    item = x.get("NowPlayingItem") or {}
    ps = x.get("PlayState") or {}
    tc = x.get("TranscodingInfo") or {}
    streams = item.get("MediaStreams") or []
    video = next((m for m in streams if m.get("Type") == "Video"), {})
    audio = next((m for m in streams if m.get("Type") == "Audio" and m.get("Index") == ps.get("AudioStreamIndex")), None) \
        or next((m for m in streams if m.get("Type") == "Audio"), {})
    sub = next((m for m in streams if m.get("Type") == "Subtitle" and m.get("Index") == ps.get("SubtitleStreamIndex")), None) \
        if (ps.get("SubtitleStreamIndex") or -1) >= 0 else None
    codec = (video.get("Codec") or "").upper().replace("H264", "H.264").replace("H265", "HEVC")
    rng = video.get("VideoRangeType") or video.get("VideoRange") or ""
    hdr = "Dolby Vision" if "DOVI" in rng.upper() or "DOLBY" in rng.upper() or rng.upper().startswith("DV") else \
          ("HDR10+" if "10+" in rng or "PLUS" in rng.upper() else "HDR10" if "HDR" in rng.upper() else "HLG" if "HLG" in rng.upper() else None)
    video_tc = tc and not tc.get("IsVideoDirect", False)
    bitrate = tc.get("Bitrate") or item.get("Bitrate")
    a_txt = " ".join(str(v) for v in ((audio.get("Codec") or "").upper(),
                                      {1: "mono", 2: "stereo", 6: "5.1", 8: "7.1"}.get(audio.get("Channels"), ""),
                                      audio.get("Language") or "") if v)
    if tc and not tc.get("IsAudioDirect", True) and tc.get("AudioCodec"):
        a_txt += f" → {tc['AudioCodec'].upper()}"
    s_txt = None
    if sub:
        s_txt = (sub.get("Language") or sub.get("DisplayTitle") or "on") + (" · burned in" if any("Subtitle" in r for r in tc.get("TranscodeReasons") or []) else "")
    return {"src_res": res_label(video.get("Height")), "src_codec": codec or None, "src_hdr": hdr,
            "stream_res": res_label(tc.get("Height")) if video_tc and tc.get("Height") else res_label(video.get("Height")),
            "stream_codec": (tc.get("VideoCodec") or "").upper() if video_tc else (codec or None),
            "bitrate": round(bitrate / 1000) if bitrate else None, "audio": a_txt or None, "subtitles": s_txt}


# What's playing, as last seen: the recorder refreshes it every few seconds, and every page reads it
# from here instead of asking Emby and Dispatcharr again. Older than LIVE_MAX, it's fetched afresh.
_live = {"t": 0.0, "sessions": [], "livetv": None, "playing": []}
_live_fetch = threading.Lock()
LIVE_MAX = 8


def live_snapshot(env=None, force=False):
    if not force and time.time() - _live["t"] <= LIVE_MAX:
        return _live
    # one refresh at a time; meanwhile a page gets the last look rather than waiting on a slow Emby
    if not _live_fetch.acquire(blocking=force or _live["t"] == 0):
        return _live
    try:
        if force or time.time() - _live["t"] > LIVE_MAX:
            env = env or env_read()
            sessions = get_json("emby", "/emby/Sessions", env, []) or []
            lt = dispatcharr_status(env)
            _live.update(sessions=sessions, livetv=lt, playing=playing_from(sessions, lt), t=time.time())
    finally:
        _live_fetch.release()
    return _live


def now_playing():
    """What's playing right now, for the history (see playing_from)."""
    return live_snapshot()["playing"]


def playing_from(sessions, lt):
    """Emby's sessions, plus Dispatcharr's own viewers (an IPTV app straight on Dispatcharr) — not
    the stream Emby itself pulls from Dispatcharr."""
    out = []
    for x in sessions:
        item = x.get("NowPlayingItem")
        if not item:
            continue
        info = session_info(x)
        live = info["via"] == "dispatcharr"
        kind = "channel" if live else {"Episode": "episode", "Movie": "movie"}.get(item.get("Type"), "other")
        grp = item.get("Name") if live else item.get("SeriesName") or item.get("Name")
        if kind == "movie" and item.get("ProductionYear"):
            grp = f"{grp} ({item['ProductionYear']})"
        ps = x.get("PlayState") or {}
        out.append({"key": f"emby:{x.get('Id')}:{item.get('Id')}", "paused": ps.get("IsPaused", False),
                    "user": x.get("UserName") or "?", "user_id": x.get("UserId"), "device": x.get("DeviceName") or "",
                    "client": x.get("Client") or "", "app_version": x.get("ApplicationVersion"), "ip": x.get("RemoteEndPoint"),
                    "via": "livetv" if live else "usenet", "kind": kind, "title": info["title"], "grp": grp,
                    "item_id": item.get("Id"), "group_id": item.get("SeriesId"), "server_id": x.get("ServerId"),
                    "season": item.get("ParentIndexNumber") if kind == "episode" else None,
                    "episode": item.get("IndexNumber") if kind == "episode" else None, "year": item.get("ProductionYear"),
                    "login": None, "method": info["how"], "reasons": "; ".join(info["reasons"]), "source": info["source"],
                    "position": (ps.get("PositionTicks") or 0) / 1e7 or None, "runtime": (item.get("RunTimeTicks") or 0) / 1e7 or None,
                    **play_details(x)})
    if lt and lt.get("ok"):
        try:
            emby_ip = socket.gethostbyname("emby")
        except OSError:
            emby_ip = None
        for c in lt["channels"]:
            for w in c["watchers"]:
                if w["ip"] == emby_ip or w["app"] in ("Emby", "ffmpeg"):
                    continue
                out.append({"key": f"disp:{c['name']}:{w['ip']}:{w['app']}", "paused": False, "user": w["app"],
                            "device": w["ip"], "client": w["app"], "ip": w["ip"], "via": "livetv", "kind": "channel",
                            "title": c["name"], "grp": c["name"], "login": c.get("login"), "method": "direct play", "reasons": "",
                            "source": c.get("quality"), "bitrate": c.get("kbps"),
                            "src_res": res_label(int(c["quality"].split("x")[1].split()[0])) if "x" in (c.get("quality") or "") else None})
    return out


PLAY_START = re.compile(r"^(?P<user>.+?) (?:is playing|started playing|is now playing) (?P<what>.+?)(?: on (?P<dev>[^,]+))?$", re.I)
PLAY_STOP = re.compile(r"^(?P<user>.+?) (?:has finished playing|stopped playing|has stopped playing|finished playing) (?P<what>.+?)(?: on (?P<dev>[^,]+))?$", re.I)


def emby_log_plays():
    """Plays Emby's activity log still remembers (usually the last weeks): each start paired with
    its stop. No pauses or stream details there, so these count as approximate."""
    env = env_read()
    log = get_json("emby", "/emby/System/ActivityLog/Entries?StartIndex=0&Limit=20000", env, None)
    if log is None:
        raise RuntimeError("Emby isn't answering")
    entries = sorted(log.get("Items") or [], key=lambda e: ts(e.get("Date")))
    users = {(u.get("Name") or "").lower(): u.get("Id") for u in get_json("emby", "/emby/Users", env, []) or []}
    opened, pairs = {}, []
    for e in entries:
        typ = (e.get("Type") or "").lower()
        name = e.get("Name") or ""
        if not e.get("ItemId") or "playback" not in typ and "videoplayback" not in typ and "audioplayback" not in typ:
            continue
        stop = "stop" in typ
        m = (PLAY_STOP if stop else PLAY_START).match(name)
        if not m:
            continue
        key = (m.group("user").lower(), e["ItemId"])
        if not stop:
            opened[key] = (e, m)
        elif key in opened:
            (se, sm), t1 = opened.pop(key), ts(e.get("Date"))
            pairs.append((se, sm, t1))
    ids = sorted({se["ItemId"] for se, _, _ in pairs})
    items = {}
    for i in range(0, len(ids), 100):
        js = get_json("emby", "/emby/Items?Ids=" + ",".join(ids[i:i + 100]) + "&Fields=ProductionYear,RunTimeTicks", env, {}) or {}
        items.update({it["Id"]: it for it in js.get("Items") or []})
    server = (get_json("emby", "/emby/System/Info", env, {}) or {}).get("Id")
    out = []
    for se, sm, t1 in pairs:
        it = items.get(se["ItemId"]) or {}
        t0 = ts(se.get("Date"))
        runtime = (it.get("RunTimeTicks") or 0) / 1e7 or None
        watched = max(0.0, t1 - t0)
        if runtime:
            watched = min(watched, runtime * 1.1)
        typ = it.get("Type")
        live = typ in ("TvChannel", "Program")
        kind = "channel" if live else {"Episode": "episode", "Movie": "movie"}.get(typ, "other")
        grp = it.get("SeriesName") or it.get("Name") or sm.group("what")
        if kind == "movie" and it.get("ProductionYear"):
            grp = f"{grp} ({it['ProductionYear']})"
        if kind == "episode":
            title_ = f"{it.get('SeriesName')} S{it.get('ParentIndexNumber', 0):02d}E{it.get('IndexNumber', 0):02d} — {it.get('Name')}"
        else:
            title_ = it.get("Name") or sm.group("what")
        guess = None if it else history.describe_text(sm.group("what"))   # the item is gone from Emby: read the log's text
        if guess:
            kind, live, grp, title_ = guess["kind"], guess["via"] == "livetv", guess["grp"], guess["title"]
        out.append({"id": f"log-{se.get('Id')}", "user": sm.group("user"), "user_id": users.get(sm.group("user").lower()),
                    "device": (sm.group("dev") or "").strip(), "client": (sm.group("dev") or "").strip(),
                    "via": "livetv" if live else "usenet", "kind": kind, "title": title_, "grp": grp,
                    "item_id": se["ItemId"], "group_id": it.get("SeriesId"), "server_id": server,
                    "season": (guess or {}).get("season") or (it.get("ParentIndexNumber") if kind == "episode" else None),
                    "episode": (guess or {}).get("episode") or (it.get("IndexNumber") if kind == "episode" else None), "year": it.get("ProductionYear"),
                    "started": t0, "last": t1, "watched": watched, "paused": None,
                    "position": watched if runtime else None, "runtime": runtime})
    return out


def preferred_language(env):
    """The audio language to prefer, or "" when it's set to none."""
    lang = env.get("PREFERRED_LANGUAGE", "German")
    return "" if lang.lower() == "none" else lang


def seerr_title(kind, tmdb, env, fallback=None):
    """Seerr's request lists carry no titles: look one up, once a day per title."""
    if not tmdb:
        return fallback if fallback is not None else "?"
    det = cached(f"seerr-title-{kind}-{tmdb}", 86400,
                 lambda: get_json("seerr", f"/api/v1/{'tv' if kind == 'tv' else 'movie'}/{tmdb}", env, {}) or {})
    return det.get("title") or det.get("name") or (fallback if fallback is not None else f"TMDB {tmdb}")


def requests_by(env, user=None):
    """Seerr requests (everyone's, or one person's) with their titles and whether they're in the library."""
    out = []
    for r in (get_json("seerr", "/api/v1/request?take=200&skip=0&sort=added&filter=all", env, {}) or {}).get("results", []):
        m = r.get("media") or {}
        by = r.get("requestedBy") or {}
        names = {(by.get(k) or "").lower() for k in ("displayName", "username", "jellyfinUsername")} - {""}
        if user and user.lower() not in names:
            continue
        title_ = m.get("title") or m.get("name") or seerr_title(r.get("type"), m.get("tmdbId"), env, fallback="")
        if title_:
            out.append({"title": title_, "by": by.get("displayName", ""), "when": ts(r.get("createdAt")), "added": ts(m.get("mediaAddedAt")),
                        "ready": m.get("status") in (4, 5), "emby_id": m.get("jellyfinMediaId") or m.get("jellyfinMediaId4k"),
                        "link": src_link("seerr", f"/{'tv' if r.get('type') == 'tv' else 'movie'}/{m.get('tmdbId')}") if m.get("tmdbId") else None})
    return out


def norm_title(t):
    """For matching Seerr's title with Emby's: no year in brackets, "&" is "and", no punctuation."""
    t = re.sub(r"\s*\(\d{4}\)\s*$", "", (t or "").lower()).replace("&", " and ")
    return re.sub(r"[\W_]+", " ", t).strip()


def request_watched(x, titles, ids):
    """A request counts as watched once its Emby item (or series) is in Dojo's history, or a title
    there matches after normalising."""
    if x.get("emby_id") and x["emby_id"] in ids:
        return True
    t = norm_title(x["title"])
    return bool(t and any(g == t or g.startswith(t + " ") for g in titles))


def seen_sets(user=None):
    return {norm_title(g) for g in (history.watched_groups(user) or set())}, history.watched_ids(user) or set()


WINDOWS = {"24h": 86400, "7d": 7 * 86400, "30d": 30 * 86400, "90d": 90 * 86400}


@app.get("/api/watching")
def api_watching():
    window = request.args.get("window", "7d")
    start = (history.since() or time.time()) if window == "all" else time.time() - WINDOWS.get(window, 7 * 86400)
    st = history.overview(start)
    if st is None:
        return jsonify(ok=False, message="Dojo can't write its data folder, so there's no watch history.")
    return jsonify(ok=True, window=window, **st)


# ─────────────────────────────────────────────── home: what's on, what's new, the week in numbers
def emby_admin_id(env):
    users = get_json("emby", "/emby/Users", env, []) or []
    admin = next((u for u in users if (u.get("Policy") or {}).get("IsAdministrator")), users[0] if users else None)
    return admin and admin.get("Id")


def recently_added(env, limit=14):
    """Emby's "latest" shelf: one entry per new movie, and per series with new episodes."""
    uid = cached("emby-admin", 3600, lambda: emby_admin_id(env))
    if not uid:
        return []
    items = get_json("emby", f"/emby/Users/{uid}/Items/Latest?Limit={limit}&GroupItems=true"
                     "&IncludeItemTypes=Episode,Movie&Fields=DateCreated,ProductionYear", env, []) or []
    server = (get_json("emby", "/emby/System/Info/Public", env, {}) or {}).get("Id", "")
    out = []
    for x in items:
        t = x.get("Type")
        if t == "Episode":
            title, sub, art = x.get("SeriesName") or x.get("Name"), f"S{x.get('ParentIndexNumber', 0):02d}E{x.get('IndexNumber', 0):02d}", x.get("SeriesId")
        elif t in ("Series", "Season"):
            n = x.get("ChildCount") or (x.get("UserData") or {}).get("UnplayedItemCount")
            title, sub, art = x.get("SeriesName") or x.get("Name"), f"{n} new episodes" if n and n > 1 else "new episode", x.get("SeriesId") or x.get("Id")
        else:
            title, sub, art = x.get("Name"), str(x.get("ProductionYear") or ""), x.get("Id")
        out.append({"title": title, "sub": sub, "art": art, "kind": "movie" if t == "Movie" else "series", "added": ts(x.get("DateCreated")),
                    "link": {"app": "Emby", "port": 8096, "path": f"/web/index.html#!/item?id={x.get('Id')}&serverId={server}"}})
    return out


@app.get("/api/home")
def api_home():
    env = env_read()
    now = []
    for p in now_playing():
        pct = round(100 * p["position"] / p["runtime"]) if p.get("position") and p.get("runtime") else None
        now.append({k: p.get(k) for k in ("user", "user_id", "title", "grp", "kind", "via", "device", "client", "method", "paused")}
                   | {"art": p.get("group_id") or p.get("item_id"), "pct": pct})
    t = history.totals(time.time() - 7 * 86400) or {}
    return jsonify(now=now, recent=cached("recent-added", 120, lambda: recently_added(env)),
                   week={"hours": t.get("hours"), "plays": t.get("plays"), "viewers": t.get("viewers"), "titles": t.get("titles")})


@app.get("/api/watching/history")
def api_watching_history():
    a = request.args
    kind = a.get("kind") or None
    via = "livetv" if kind == "channel" else None
    res = history.page(page=int(a.get("page") or 1), size=min(100, int(a.get("size") or 25)), user=a.get("user") or None,
                       kind=kind, via=via, grp=a.get("grp") or None, q=(a.get("q") or "").strip() or None,
                       why=a.get("why") or None)
    if res is None:
        return jsonify(ok=False, message="Dojo can't write its data folder, so there's no watch history.")
    return jsonify(ok=True, **res)


@app.get("/api/watching/person")
def api_watching_person():
    user = request.args.get("user") or ""
    p = history.person(user)
    if p is None:
        return jsonify(ok=False, message="No watch history.")
    window = request.args.get("window", "30d")
    start = (history.since() or time.time()) if window == "all" else time.time() - WINDOWS.get(window, 30 * 86400)
    rows_ = history.rows(since=start, user=user) or []
    heat = [[0.0] * 24 for _ in range(7)]
    for r in rows_:
        lt = time.localtime(r["started"])
        heat[lt.tm_wday][lt.tm_hour] += r["watched"] / 60
    groups = Counter()
    for r in rows_:
        groups[(r["grp"], r["via"], r["group_id"] or r["item_id"], r["server_id"])] += r["watched"]
    env = env_read()
    titles, ids = seen_sets(user)
    reqs = requests_by(env, user)
    for x in reqs:   # this person's own plays only (Emby's played marks don't say who)
        x["watched"] = x["ready"] and request_watched(x, titles, ids)
    trans = sum(r["watched"] for r in rows_ if r["method"] in ("transcoding", "audio transcoding"))
    tot = sum(r["watched"] for r in rows_)
    vod = [r for r in rows_ if r["via"] != "livetv" and r["runtime"]]
    p.update(window=window, heat=[[round(m) for m in d] for d in heat],
             top=[{"name": g, "via": v, "art": art, "server": srv, "hours": round(w / 3600, 1)} for (g, v, art, srv), w in groups.most_common(8)],
             finished_pct=round(100 * sum(1 for r in vod if history.done(r)) / len(vod)) if vod else None,
             transcode_pct=round(100 * trans / tot) if tot else 0,
             requests={"n": len(reqs), "ready": sum(1 for x in reqs if x["ready"]), "watched": sum(1 for x in reqs if x["watched"]), "latest": reqs[:8]})
    return jsonify(ok=True, **p)


@app.get("/api/watching/title")
def api_watching_title():
    t = history.title(request.args.get("grp") or "", request.args.get("via") or None)
    if t is None:
        return jsonify(ok=False, message="No watch history.")
    return jsonify(ok=True, **t)


ART = Path("/dojo-data/art")


@app.get("/api/art/<item_id>")
def api_art(item_id):
    """A poster from Emby (or a user's picture), kept a week in Dojo's data folder."""
    if not re.fullmatch(r"[A-Za-z0-9]{1,64}", item_id):
        abort(404)
    kind = "user" if request.args.get("user") else "item"
    w = 300 if request.args.get("w") != "big" else 600
    f = ART / f"{kind}-{item_id}-{w}.jpg"
    try:
        if f.exists() and time.time() - f.stat().st_mtime < 7 * 86400:
            pass
        else:
            path = f"/emby/Users/{item_id}/Images/Primary" if kind == "user" else f"/emby/Items/{item_id}/Images/Primary"
            r = call("emby", f"{path}?maxWidth={w}&quality=85", env_read())
            if not r.ok or not r.headers.get("Content-Type", "").startswith("image/"):
                abort(404)
            ART.mkdir(parents=True, exist_ok=True)
            f.write_bytes(r.content)
        resp = send_file(f, mimetype="image/jpeg")
        resp.headers["Cache-Control"] = "private, max-age=86400"
        return resp
    except (OSError, requests.RequestException):
        abort(404)


# ─────────────────────────────────────────────── live: open pages update when something happens
# Sonarr, Radarr and Seerr call /hook/<app> on every event (ninjarr wires them with a token);
# playback comes from the watch-history recorder, which looks every few seconds anyway (Emby only
# sends webhooks with Premiere). Each open page listens on /api/events and reloads what it shows.
_listeners, _live_lock = set(), threading.Lock()


def hook_token():
    """Made by bootstrap.sh when it wires the webhooks (lib/arr.sh); without one, no hook is accepted."""
    try:
        return (STATE / "hook-token").read_text().strip()
    except OSError:
        return ""


def publish(ev, library=False):
    # a start, stop or pause changes nothing Library shows: only app events reset its numbers
    if ev.get("src") != "play":
        for k in [k for k in list(_cache) if k.startswith("stack-") or (library and k == "library")]:
            _cache.pop(k, None)
    with _live_lock:
        for q in list(_listeners):
            try:
                q.put_nowait(ev)
            except queue.Full:
                pass


def episodes_label(b):
    eps = b.get("episodes") or []
    if not eps:
        return ""
    e = eps[0]
    first = f"S{e.get('seasonNumber', 0):02d}E{e.get('episodeNumber', 0):02d}"
    return f" {first}" + (f" (+{len(eps) - 1})" if len(eps) > 1 else "")


def describe_hook(src, b):
    """(message for a toast or None, whether the library changed) for one event."""
    kind = b.get("eventType") or ""
    if src in ("sonarr", "radarr"):
        title = ((b.get("series") or {}).get("title") or "?") + episodes_label(b) if src == "sonarr" \
            else (b.get("movie") or {}).get("title") or "?"
        if kind == "Grab":
            return f"Grabbed: {title}", False
        if kind == "Download":
            return (f"Upgraded: {title}" if b.get("isUpgrade") else f"Ready to watch: {title}"), True
        if kind in ("Health",):
            return f"{src.capitalize()}: {b.get('message') or 'a health warning'}", False
        if kind == "ManualInteractionRequired":
            return f"{src.capitalize()} needs a hand with {title}", False
        return None, kind in ("Rename", "ImportComplete", "SeriesAdd", "SeriesDelete", "EpisodeFileDelete", "MovieAdded",
                              "MovieDelete", "MovieFileDelete", "HealthRestored")
    if src == "seerr":
        t, subj = b.get("type") or "", b.get("subject") or "?"
        if t in ("MEDIA_PENDING", "MEDIA_AUTO_APPROVED", "MEDIA_AUTO_REQUESTED"):
            return f"Requested: {subj}", False
        if t == "MEDIA_FAILED":
            return f"Request failed: {subj}", False
        if t == "MEDIA_AVAILABLE":
            return f"Ready to watch: {subj}", True
    return None, False


@app.post("/hook/<src>")
def hook(src):
    token = hook_token()
    if src not in ("sonarr", "radarr", "seerr") or not token or not hmac.compare_digest(request.args.get("t", ""), token):
        abort(403)
    b = request.get_json(silent=True) or {}
    if (b.get("eventType") or b.get("type")) not in ("Test", "TEST_NOTIFICATION"):
        msg, lib = describe_hook(src, b)
        publish({"src": src, "toast": msg}, library=lib)
        if src == "seerr" and b.get("type") == "MEDIA_AVAILABLE":
            who = (b.get("requestedBy") or "").strip()
            notify("ready", f"Ready to watch: {b.get('subject') or 'your request'}",
                   f"Requested by {who}" if who and "{{" not in who else "It's in Emby now.", "/#library", tag="ready")
    return "", 204


@app.get("/api/events")
def api_events():
    q = queue.Queue(maxsize=50)
    with _live_lock:
        _listeners.add(q)

    def stream():
        try:
            yield "retry: 5000\n\n"
            while True:
                try:
                    ev = q.get(timeout=20)
                except queue.Empty:
                    yield ": still here\n\n"
                    continue
                yield f"data: {json.dumps(ev)}\n\n"
        finally:
            with _live_lock:
                _listeners.discard(q)
    r = Response(stream(), mimetype="text/event-stream")
    r.headers["Cache-Control"] = "no-cache"
    r.headers["X-Accel-Buffering"] = "no"
    return r


def aio_grabs_by_indexer(env):
    """Every release Sonarr/Radarr sent to AIOStreams, with the Prowlarr indexer it came from and
    AIOStreams' verdict (complete, missing parts, gone). Sonarr/Radarr hand AIOStreams Prowlarr's
    download link (http://prowlarr:9696/<indexer id>/download?…), so AIOStreams' own stats file
    them all under "prowlarr"; the indexer id in the link tells them apart."""
    indexers = get_json("prowlarr", "/api/v1/indexer", env, []) or []
    names = {str(i.get("id")): i.get("name") or "" for i in indexers}
    # each indexer's address, reduced once (not again for every library entry)
    by_core = {}
    for n, urls in indexer_hosts(env, indexers).items():
        for u in urls:
            if _core(u):
                by_core.setdefault(_core(u), n)
    out = []
    offset = 0
    while offset < 5000:
        d = aio_get(f"/usenet/library?origin=sabnzbd&statuses=available,degraded,failed&limit=500&offset={offset}", env)
        if d is None:
            return None
        entries = d.get("entries") or []
        for e in entries:
            url = e.get("nzbUrl") or ""
            m = re.match(r"https?://[^/]+/(\d+)/download", url)
            name = names.get(m.group(1)) if m else None
            if not name:   # a link straight to the indexer: match its address
                name = by_core.get(_core(url))
            out.append({"indexer": (name or "").lower(), "status": e.get("status"), "added": ts(e.get("addedAt")),
                        "nzo": e.get("nzoId"), "name": e.get("name") or ""})
        offset += len(entries)
        if not entries or offset >= (d.get("total") or 0):
            break
    return out


def indexer_hosts(env, indexers=None):
    """Prowlarr's indexers by name, with the addresses they're reached at."""
    out = {}
    for i in indexers if indexers is not None else get_json("prowlarr", "/api/v1/indexer", env, []) or []:
        urls = list(i.get("indexerUrls") or [])
        urls += [f.get("value") for f in i.get("fields") or [] if f.get("name") == "baseUrl" and isinstance(f.get("value"), str)]
        out[(i.get("name") or "").lower()] = [u for u in urls if u]
    return out


def collect_stack(env, window):
    """Everything the Stack page needs, fetched from the apps."""
    hours = WINDOW_HOURS[window]
    since = iso_since(hours)
    raw = {"window": window, "hours": hours, "now": time.time()}
    raw["requests"] = (get_json("seerr", "/api/v1/request?take=200&skip=0&sort=added&filter=all", env, {}) or {}).get("results", [])
    raw["sonarr_history"] = get_json("sonarr", f"/api/v3/history/since?date={since}&includeSeries=true&includeEpisode=true", env, []) or []
    raw["radarr_history"] = get_json("radarr", f"/api/v3/history/since?date={since}&includeMovie=true", env, []) or []
    raw["activity"] = (get_json("emby", f"/emby/System/ActivityLog/Entries?MinDate={since}&Limit=1000", env, {}) or {}).get("Items", [])
    played_ids = list({a["ItemId"] for a in raw["activity"] if a.get("ItemId") and is_play(a)})[:200]
    raw["played_items"] = []
    if played_ids:
        raw["played_items"] = (get_json("emby", "/emby/Items?Recursive=true&Fields=ProviderIds&Ids=" + ",".join(played_ids), env, {}) or {}).get("Items", [])
        series_ids = list({i["SeriesId"] for i in raw["played_items"] if i.get("SeriesId")})
        if series_ids:
            raw["played_items"] += (get_json("emby", "/emby/Items?Fields=ProviderIds&Ids=" + ",".join(series_ids), env, {}) or {}).get("Items", [])
    raw["livetv"] = live_snapshot(env)["livetv"]
    raw["indexer_hosts"] = cached("indexer-hosts", 600, lambda: indexer_hosts(env))
    raw["aio_grabs"] = cached("aio-grabs", 600, lambda: aio_grabs_by_indexer(env))
    raw["aio_stats"] = aio_get(f"/usenet/stats?window={window}", env) or {}
    raw["library"] = cached("library", 600, lambda: collect_library(env))
    raw["language"] = preferred_language(env)
    return raw


def episode_code(f):
    """S03E07 from an episode file's name (Sonarr's file list doesn't carry episode numbers)."""
    m = re.search(r"(?i)\bS(\d{1,2})[ ._-]?E(\d{1,3})(?:[ ._-]?E?(\d{1,3}))?", f.get("relativePath") or f.get("sceneName") or "")
    if not m:
        return f"season {f.get('seasonNumber')}" if f.get("seasonNumber") is not None else ""
    code = f"S{int(m.group(1)):02d}E{int(m.group(2)):02d}"
    return code + (f"-E{int(m.group(3)):02d}" if m.group(3) else "")


def release_of(f):
    """The AIOStreams release a library file plays from, read from its symlink. AIOStreams links by
    id (/mnt/aiostreams/usenet/by-id/<nzbHash>/<file number>/<file>) — that id is returned — or, in
    older setups, by name (…/usenet/completed/<category>/<release>/…)."""
    path = f.get("path") or ""
    if not path.startswith("/library/"):
        return None
    try:
        parts = Path(os.readlink(DATA / path.lstrip("/"))).parts
    except OSError:
        return None
    for marker, at in (("by-id", 1), ("completed", 2)):
        if marker in parts and len(parts) > parts.index(marker) + at:
            return parts[parts.index(marker) + at]
    return None


def picture_of(f):
    """Codec and HDR kind from a file's media info (the release name when Sonarr/Radarr didn't read it)."""
    mi = f.get("mediaInfo") or {}
    codec = (mi.get("videoCodec") or "").upper()
    rng = (mi.get("videoDynamicRangeType") or mi.get("videoDynamicRange") or "").upper()
    name = f.get("sceneName") or f.get("relativePath") or ""
    if not codec and re.search(r"(?i)\bAV1\b", name):
        codec = "AV1"
    if not rng:
        dv = re.search(r"(?i)\b(dv|dovi|dolby[ ._-]?vision)\b", name)
        hdr = re.search(r"(?i)\bhdr(10)?\+?\b|\bhlg\b", name)
        rng = "DV HDR10" if dv and hdr else "DV" if dv else "HDR10" if hdr else ""
    return {"codec": codec, "range": rng}


def collect_library(env):
    """The library as Sonarr, Radarr and AIOStreams see it — refreshed every 10 minutes."""
    files = []
    profiles = {}
    lang = preferred_language(env)
    for name in ("sonarr", "radarr"):
        for p in get_json(name, "/api/v3/qualityprofile", env, []) or []:
            profiles[(name, p["id"])] = p.get("cutoffFormatScore") or 0
    series = get_json("sonarr", "/api/v3/series", env, []) or []
    for s_ in series:
        if not (s_.get("statistics") or {}).get("episodeFileCount"):
            continue
        cut = profiles.get(("sonarr", s_.get("qualityProfileId")), 0)
        for f in get_json("sonarr", f"/api/v3/episodefile?seriesId={s_['id']}", env, []) or []:
            ok_, how = file_language(f, lang)
            files.append({"app": "sonarr", "title": s_.get("title"), "formats": [c.get("name") for c in f.get("customFormats") or []],
                          "in_lang": ok_, "lang_by": how, "ep": episode_code(f), "slug": s_.get("titleSlug"),
                          "id": f.get("id"), "owner": s_["id"], "from": release_of(f), "season": f.get("seasonNumber"),
                          "score": f.get("customFormatScore") or 0, "cutoff": cut, "release": f.get("sceneName") or f.get("relativePath") or "",
                          "resolution": (f.get("quality") or {}).get("quality", {}).get("resolution"), **picture_of(f)})
    movies = get_json("radarr", "/api/v3/movie", env, []) or []
    for m in movies:
        f = m.get("movieFile")
        if not f:
            continue
        ok_, how = file_language(f, lang)
        files.append({"app": "radarr", "title": m.get("title"), "formats": [c.get("name") for c in f.get("customFormats") or []],
                      "in_lang": ok_, "lang_by": how, "slug": m.get("titleSlug"),
                      "id": f.get("id"), "owner": m["id"], "from": release_of(f),
                      "score": f.get("customFormatScore") or 0, "cutoff": profiles.get(("radarr", m.get("qualityProfileId")), 0),
                      "release": f.get("sceneName") or f.get("relativePath") or "",
                      "resolution": (f.get("quality") or {}).get("quality", {}).get("resolution"), **picture_of(f)})
    # aired, monitored, no file yet
    wanted = get_json("sonarr", "/api/v3/wanted/missing?pageSize=250&monitored=true&includeSeries=true", env, {}) or {}
    missing_eps = [((r.get("series") or {}).get("title") or "?", (r.get("series") or {}).get("titleSlug"))
                   for r in wanted.get("records") or []]
    missing_movies = [(m.get("title"), m.get("titleSlug")) for m in movies
                      if m.get("monitored") and not m.get("hasFile") and m.get("isAvailable")]
    # AIOStreams' nightly check of every release it holds: complete, missing parts, or gone. Only
    # releases a library file still plays from count; older ones Sonarr/Radarr already replaced don't.
    # Matched by AIOStreams' id for the release (what the library links point at), else by name.
    plays = None
    problems, entries = {}, []
    for st in ("degraded", "failed"):
        d = aio_get(f"/usenet/library?origin=sabnzbd&statuses={st}&limit=500&sort=activity", env)
        if d is None:
            problems = None
            break
        for e in d.get("entries") or []:
            hit = {"status": st, "nzo": e.get("nzoId") or e.get("nzbHash"), "used": False}
            entries.append(hit)
            for k in (e.get("nzbHash"), e.get("nzoId"), e.get("name")):
                if k:
                    problems[k] = hit
    if problems is not None:
        for f in files:
            # a file known by its link only takes that release's verdict: AIOStreams can hold a
            # failed earlier copy under the same name while the file plays a healthy one
            hit = problems.get(f["from"]) if f.get("from") else problems.get(f.get("release"))
            if hit:
                f["usenet"], f["nzo"], hit["used"] = hit["status"], hit["nzo"], True
        # releases with problems that no library file plays from any more (Sonarr/Radarr replaced them)
        plays = {"unused": sum(1 for h in entries if not h["used"])}
    return {"files": files, "series": sum(1 for s_ in series if (s_.get("statistics") or {}).get("episodeFileCount")),
            "movies": sum(1 for m in movies if m.get("hasFile")),
            "missing": {"episodes": wanted.get("totalRecords", len(missing_eps)), "episode_titles": missing_eps,
                        "movies": len(missing_movies), "movie_titles": missing_movies[:8]},
            "plays": plays}

def is_play(a):
    t = (a.get("Type") or "").lower()
    return "playback" in t and "stop" not in t


def pct(n, d):
    return round(100 * n / d) if d else None


def median(xs):
    xs = sorted(xs)
    if not xs:
        return None
    m = len(xs) // 2
    return xs[m] if len(xs) % 2 else (xs[m - 1] + xs[m]) / 2


def _core(name):
    """"example" from "Example.io", "api.example.io" or "Example (Prowlarr)"."""
    n = re.sub(r"\s*\(prowlarr\)$", "", (name or "").lower().strip())
    n = re.sub(r"^https?://", "", n).split("/")[0].split(":")[0]
    labels = [x for x in n.split(".") if x]
    if len(labels) >= 2 and re.fullmatch(r"[a-z0-9-]+", labels[-1]):
        n = labels[-2]           # the name in front of the top-level domain
    return re.sub(r"[^a-z0-9]", "", n)


def aio_indexer(name, aio_rows, hosts):
    """AIOStreams' completeness numbers for a Sonarr/Radarr indexer. AIOStreams names an indexer
    by the host its NZB came from (e.g. api.example.io), Sonarr/Radarr by the name in Prowlarr,
    so match through Prowlarr's address for that indexer, else by the name itself."""
    clean = re.sub(r"\s*\(Prowlarr\)$", "", name or "")
    keys = {_core(clean)} | {_core(h) for h in hosts.get(clean.lower(), [])}
    keys.discard("")
    hit = [a for a in aio_rows if _core(a.get("indexer")) in keys
           or (a.get("indexer") or "").lower() == clean.lower()]
    if not hit:
        return None
    ok = sum(a.get("ok") or 0 for a in hit)
    # grabs AIOStreams could check: whole, partly missing, or gone (not ones it couldn't fetch)
    checked = ok + sum((a.get("degraded") or 0) + (a.get("failedMissing") or 0) for a in hit)
    return {"ok": ok, "checked": checked, "missing": sum(a.get("failedMissing") or 0 for a in hit)}


# Where a number comes from: a page in the app behind it, opened from Dojo (the glue) to dig in.
APP_PORTS = {"sonarr": (8989, "Sonarr"), "radarr": (7878, "Radarr"), "prowlarr": (9696, "Prowlarr"),
             "seerr": (5055, "Seerr"), "emby": (8096, "Emby"), "aiostreams": (3000, "AIOStreams"),
             "dispatcharr": (9191, "Dispatcharr")}


def src_link(app_, path=""):
    port, label = APP_PORTS[app_]
    return {"port": port, "path": path, "app": label}


def arr_link(app_, slug):
    """A series in Sonarr or a movie in Radarr, by its title slug."""
    if not slug:
        return None
    return src_link(app_, f"/series/{slug}" if app_ == "sonarr" else f"/movie/{slug}")


def stuck_link(r, status):
    """Where to look at a stuck request: Seerr while it waits for approval, else its page in
    Sonarr/Radarr (by the slug Seerr keeps; Radarr's slug is the TMDB id anyway)."""
    m = r.get("media") or {}
    tv = r.get("type") == "tv"
    if status == 2:
        return {"port": 5055, "path": f"/{'tv' if tv else 'movie'}/{m.get('tmdbId')}", "app": "Seerr"} if m.get("tmdbId") else None
    slug = m.get("externalServiceSlug")
    if tv:
        if slug:
            return {"port": 8989, "path": f"/series/{slug}", "app": "Sonarr"}
        return {"port": 8989, "path": f"/add/new?term=tvdb%3A{m['tvdbId']}", "app": "Sonarr"} if m.get("tvdbId") else None
    ref = slug or m.get("tmdbId")
    return {"port": 7878, "path": f"/movie/{ref}", "app": "Radarr"} if ref else None


def compute_stack(raw):
    """Pure arithmetic over collect_stack()'s data, so it can be tested on its own."""
    now, hours = raw["now"], raw["hours"]
    start = now - hours * 3600
    out = {"window": raw["window"]}

    # ── flow: requested → grabbed → in library → watched
    reqs = [r for r in raw["requests"] if ts(r.get("createdAt")) >= start]
    def media_key(m, kind):
        return (kind, str(m.get("tmdbId") or m.get("tvdbId") or ""))
    req_keys = {media_key(r.get("media") or {}, r.get("type")) for r in reqs}
    events = [("sonarr", h) for h in raw["sonarr_history"]] + [("radarr", h) for h in raw["radarr_history"]]
    grabs = [(a, h) for a, h in events if h.get("eventType") == "grabbed"]
    imports = [(a, h) for a, h in events if h.get("eventType") in ("downloadFolderImported", "episodeFileImported", "movieFileImported")]
    failed = [(a, h) for a, h in events if h.get("eventType") in ("downloadFailed", "importFailed")]

    tmdb_played = set()
    items = {i.get("Id"): i for i in raw["played_items"]}
    plays = [a for a in raw["activity"] if is_play(a)]
    for a in plays:
        it = items.get(a.get("ItemId")) or {}
        series = items.get(it.get("SeriesId")) or {}
        prov = (series or it).get("ProviderIds") or {}
        kind = "tv" if it.get("SeriesId") else "movie"
        if prov.get("Tmdb"):
            tmdb_played.add((kind, str(prov["Tmdb"])))
        if prov.get("Tvdb"):
            tmdb_played.add((kind, str(prov["Tvdb"])))
    watched_requests = sum(1 for k in req_keys if k in tmdb_played)
    available = [r for r in reqs if (r.get("media") or {}).get("status") in (4, 5)]

    to_play = []
    for r in available:
        added = ts((r.get("media") or {}).get("mediaAddedAt"))
        created = ts(r.get("createdAt"))
        if added and created and added >= created:
            to_play.append((added - created) / 60)
    stuck = []
    for r in reqs:
        st = (r.get("media") or {}).get("status")
        age_h = (now - ts(r.get("createdAt"))) / 3600
        if st in (2, 3) and age_h >= 2:
            stuck.append({"title": r.get("_title") or "?", "age_h": round(age_h), "by": (r.get("requestedBy") or {}).get("displayName", ""),
                          "status": "waiting for approval" if st == 2 else "no release found yet",
                          "link": stuck_link(r, st)})
    stuck.sort(key=lambda x: -x["age_h"])
    out["flow"] = {
        "requested": len(reqs), "available": len(available), "watched": watched_requests,
        "grabs": len(grabs), "imports": len(imports), "failed": len(failed),
        "minutes_to_play_median": round(median(to_play)) if to_play else None,
        "minutes_to_play_worst": round(max(to_play)) if to_play else None,
        "stuck": stuck[:8],
    }

    # ── indexers: what each one actually got into the library
    by_dl = {}
    for a, h in grabs:
        if h.get("downloadId"):
            by_dl[h["downloadId"]] = (h.get("data") or {}).get("indexer") or "unknown"
    rows = {}
    def row(name):
        return rows.setdefault(name, {"indexer": name, "grabs": 0, "imported": 0, "failed": 0})
    for a, h in grabs:
        row((h.get("data") or {}).get("indexer") or "unknown")["grabs"] += 1
    for a, h in imports:
        if h.get("downloadId") in by_dl:
            row(by_dl[h["downloadId"]])["imported"] += 1
    for a, h in failed:
        if h.get("downloadId") in by_dl:
            row(by_dl[h["downloadId"]])["failed"] += 1
    # completeness per indexer: AIOStreams' nightly verdict on the releases grabbed in this window.
    # Sonarr/Radarr usually upload the NZB itself (AIOStreams then only knows "local-nzb://…"), so
    # the reliable link is the download id: the grab in Sonarr/Radarr's history names the indexer,
    # AIOStreams' library entry with that id has the verdict. A link that names it is the fallback.
    by_ix = {}
    def tally(ix, status):
        if ix and status in ("available", "degraded", "failed"):
            c = by_ix.setdefault(ix, {"ok": 0, "checked": 0, "missing": 0})
            c["checked"] += 1
            c["ok"] += status == "available"
            c["missing"] += status == "failed"
    # match by download id, else by release name (the grab's title is the NZB's name in AIOStreams)
    rel = lambda x: re.sub(r"[^a-z0-9]", "", re.sub(r"\.nzb$", "", (x or "").lower()))
    aio_by_nzo = {g["nzo"]: g for g in raw.get("aio_grabs") or [] if g.get("nzo")}
    aio_by_name = {rel(g.get("name")): g for g in raw.get("aio_grabs") or [] if g.get("name")}
    used = set()
    for a, h in grabs:
        ix = re.sub(r"\s*\(Prowlarr\)$", "", (h.get("data") or {}).get("indexer") or "").lower()
        g = aio_by_nzo.get(h.get("downloadId")) or aio_by_name.get(rel(h.get("sourceTitle")))
        if ix and g and id(g) not in used:
            tally(ix, g["status"])
            used.add(id(g))
    for g in raw.get("aio_grabs") or []:
        if id(g) not in used and g["indexer"] and g["added"] >= start:
            tally(g["indexer"], g["status"])
    for r_ in rows.values():
        a_ = by_ix.get(re.sub(r"\s*\(Prowlarr\)$", "", r_["indexer"]).lower()) \
            or aio_indexer(r_["indexer"], (raw["aio_stats"] or {}).get("indexers") or [], raw.get("indexer_hosts") or {})
        r_["complete_pct"] = round(100 * a_["ok"] / a_["checked"]) if a_ and a_["checked"] else None
        r_["dead_on_arrival"] = a_["missing"] if a_ else None
        r_["landed_pct"] = pct(r_["imported"], r_["grabs"])
    out["indexers"] = sorted(rows.values(), key=lambda r: -r["grabs"])
    out["indexer_check"] = {"aio": None if raw.get("aio_grabs") is None else len(raw["aio_grabs"]), "matched": len(used)}

    # ── self-healing: releases that failed, and whether the same episode/movie came back
    healed, lost = 0, []
    for a, h in failed:
        key = ("ep", h.get("episodeId")) if a == "sonarr" else ("mv", h.get("movieId"))
        t_fail = ts(h.get("date"))
        back = any((("ep", i.get("episodeId")) if a2 == "sonarr" else ("mv", i.get("movieId"))) == key and ts(i.get("date")) > t_fail
                   for a2, i in imports)
        if back:
            healed += 1
        else:
            if a == "sonarr":
                ep = h.get("episode") or {}
                title = f"{(h.get('series') or {}).get('title', '?')} S{ep.get('seasonNumber', 0):02d}E{ep.get('episodeNumber', 0):02d}"
                slug = (h.get("series") or {}).get("titleSlug")
            else:
                title = (h.get("movie") or {}).get("title", "?")
                slug = (h.get("movie") or {}).get("titleSlug")
            lost.append((title, a, slug))
    waiting = sorted(set(lost))
    out["healing"] = {"failed": len(failed), "replaced": healed, "waiting_count": len(waiting),
                      "waiting": [{"title": t, "link": arr_link(a, sl)} for t, a, sl in waiting[:8]]}

    # ── library: what it holds, whether it plays, what's missing, language, picture, upgrades
    lib = raw["library"]
    files = lib["files"]
    n = len(files)
    lang_name = raw.get("language") or ""
    in_lang = [f for f in files if f.get("in_lang")]
    other = Counter((f["title"], f["app"]) for f in files if not f.get("in_lang"))
    first_ep, slugs = {}, {}
    for f in files:
        slugs.setdefault((f["title"], f["app"]), f.get("slug"))
        if not f.get("in_lang") and f["app"] == "sonarr":
            first_ep.setdefault(f["title"], f.get("ep") or "")

    def lang_title(key, c):
        title, app_ = key
        link = arr_link(app_, slugs.get(key))
        if app_ != "sonarr":
            return {"title": title, "n": 1, "link": link}
        if c == 1:
            return {"title": f"{title} {first_ep.get(title, '')}".strip(), "n": 1, "link": link}
        return {"title": title, "n": c, "unit": "episode", "link": link}
    by_audio = sum(1 for f in files if f.get("lang_by") == "audio")
    res = Counter()
    for f in files:
        r = f.get("resolution") or 0
        res["2160p" if r >= 2160 else "1080p" if r >= 1080 else "720p" if r >= 720 else "lower"] += 1
    hdr = sum(1 for f in files if f.get("range"))
    # files many TVs can't play as they are: Emby converts them, and HDR comes out washed out
    hard = []
    for f in files:
        why = "AV1" if f.get("codec") == "AV1" else "Dolby Vision without HDR" if f.get("range") == "DV" else None
        if why:
            hard.append((f, why))
    hard_groups = {"AV1": {}, "DV": {}}
    for f, why in hard:
        g = hard_groups["AV1" if why == "AV1" else "DV"].setdefault(
            (f["title"], f["app"]), {"title": f["title"], "app": f["app"], "n": 0, "link": arr_link(f["app"], f.get("slug"))})
        g["n"] += 1

    def hard_titles(groups):
        return [{"title": g["title"], "n": g["n"], "unit": "episode" if g["app"] == "sonarr" else None, "link": g["link"]}
                for g in sorted(groups.values(), key=lambda g: -g["n"])[:5]]
    below = sum(1 for f in files if f["cutoff"] and f["score"] < f["cutoff"])
    upgraded = sum(1 for h in raw["sonarr_history"] + raw["radarr_history"]
                   if h.get("eventType") in ("episodeFileDeleted", "movieFileDeleted") and (h.get("data") or {}).get("reason") == "Upgrade")
    miss = lib["missing"]
    plays = None
    if lib["plays"]:
        bad = [f for f in files if f.get("usenet")]
        groups = {}
        for f in bad:
            g = groups.setdefault((f["title"], f["app"]), {"title": f["title"], "app": f["app"], "link": arr_link(f["app"], f.get("slug")),
                                                         "eps": [], "dead": 0, "degraded": 0})
            g["dead" if f["usenet"] == "failed" else "degraded"] += 1
            if f.get("ep"):
                g["eps"].append(f["ep"])
        items = []
        for g in sorted(groups.values(), key=lambda g: -(g["dead"] * 1000 + g["degraded"])):
            label = g["title"]
            if g["app"] == "sonarr":
                eps = sorted(set(g["eps"]))
                label += f" {eps[0]}" if len(eps) == 1 else f" ({len(eps)} episodes)"
            items.append({"title": label, "link": g["link"], "dead": g["dead"] > 0})
        plays = {"files": n, "unused": lib["plays"]["unused"], "degraded": sum(1 for f in bad if f["usenet"] == "degraded"),
                 "dead": sum(1 for f in bad if f["usenet"] == "failed"), "items": items[:8], "more": max(0, len(items) - 8)}
    out["library"] = {
        "files": n, "series": lib["series"], "episodes": sum(1 for f in files if f["app"] == "sonarr"), "movies": lib["movies"],
        "plays": plays,
        "missing": {"episodes": miss["episodes"], "movies": miss["movies"],
                    "titles": [{"title": t, "n": c, "unit": "episode", "link": arr_link("sonarr", sl)}
                               for (t, sl), c in Counter(map(tuple, miss["episode_titles"])).most_common(6)]
                              + [{"title": t, "n": 1, "link": arr_link("radarr", sl)} for t, sl in miss["movie_titles"][:4]]},
        "language": {"name": lang_name, "pct": pct(len(in_lang), n), "other": n - len(in_lang),
                     "by_audio": by_audio,
                     "titles": [lang_title(k, c) for k, c in other.most_common(6)]} if lang_name else None,
        "picture": {"2160p": res["2160p"], "1080p": res["1080p"], "720p": res["720p"], "lower": res["lower"], "hdr": hdr,
                    "av1": sum(1 for _, w in hard if w == "AV1"), "dv_only": sum(1 for _, w in hard if w != "AV1"),
                    # whether AV1 is actually a problem here: what the household's players did with it lately
                    "av1_players": history.codec_players("AV1", time.time() - 30 * 86400) if any(w == "AV1" for _, w in hard) else None,
                    "av1_titles": hard_titles(hard_groups["AV1"]), "dv_titles": hard_titles(hard_groups["DV"])},
        "upgrades": {"done": upgraded, "waiting": below},
    }

    out["livetv"] = raw.get("livetv")        # Library notes when live TV isn't reachable
    return out


def now_block(sessions, aio_stats, livetv):
    """Right now: viewers, how they play, and the usenet load behind it."""
    viewers = [session_info(x) for x in sessions if x.get("NowPlayingItem")]
    transcoding = sum(1 for v in viewers if v["how"] == "transcoding")
    st = aio_stats or {}
    live, pool = st.get("live") or {}, st.get("pool") or {}
    used = sum(p.get("acquired", 0) for p in pool.get("providers", []))
    cap = sum(p.get("max", 0) for p in pool.get("providers", []))
    backup_share = sum(p.get("articleShare", 0) for p in st.get("providers", []) if p.get("isBackup"))
    return {"sessions": viewers, "viewers": len(viewers), "transcoding": transcoding, "direct": len(viewers) - transcoding,
                  "mbps": round((live.get("currentBytesPerSec") or 0) / 1e6, 1), "streams": live.get("activeStreams", 0),
                  "connections": used, "connections_max": cap,
                  "backup_share_pct": round(100 * backup_share) if st.get("providers") else None,
                  "has_backup": any(p.get("isBackup") for p in st.get("providers", [])),
                  "livetv": livetv}


@app.get("/api/now")
def api_now():
    """Only what's playing and the usenet load behind it (Stats → Watching), not the whole /api/stack."""
    env = env_read()
    snap = live_snapshot(env)
    stats = cached("aio-live", 5, lambda: aio_get("/usenet/stats?window=24h", env) or {})
    return jsonify(now_block(snap["sessions"], stats, snap["livetv"]))


@app.get("/api/stack")
def api_stack():
    env = env_read()
    window = request.args.get("window", "7d")
    if window not in WINDOW_HOURS:
        window = "7d"
    raw = cached(f"stack-{window}", 30, lambda: collect_stack(env, window))
    # Seerr's request list has no titles; look up the few the page shows
    for r in raw["requests"]:
        if "_title" not in r and (r.get("media") or {}).get("status") in (2, 3):
            r["_title"] = seerr_title(r.get("type"), (r.get("media") or {}).get("tmdbId"), env)
    return jsonify(compute_stack(raw))


# ─────────────────────────────────────────────── push notifications
# Each phone or browser that turns them on picks its own topics; see push.py for how they travel.
PUSH = push.Store("/dojo-data/push.json")
_notifier = []


def notify(topic, title, body="", url="/", tag=None):
    if _notifier:
        _notifier[0].notify(topic, title, body, url, tag)


@app.get("/api/push")
def api_push():
    return jsonify(key=PUSH.public_key(), topics=push.TOPICS,
                   devices=[{k: d.get(k) for k in ("endpoint", "name", "topics", "added")} for d in PUSH.devices()])


@app.post("/api/push/subscribe")
def api_push_subscribe():
    b = request.get_json(silent=True) or {}
    sub = b.get("subscription") or {}
    if not (str(sub.get("endpoint", "")).startswith("https://") and (sub.get("keys") or {}).get("p256dh")
            and sub["keys"].get("auth")):
        return jsonify(ok=False, message="That browser didn't hand over a push address."), 400
    dev = PUSH.upsert(sub, str(b.get("name") or "")[:60], b.get("topics") or push.TOPICS)
    return jsonify(ok=True, topics=dev["topics"])


@app.post("/api/push/topics")
def api_push_topics():
    b = request.get_json(silent=True) or {}
    dev = next((d for d in PUSH.devices() if d["endpoint"] == b.get("endpoint")), None)
    if not dev:
        return jsonify(ok=False, message="This device isn't signed up any more. Turn notifications on again."), 404
    PUSH.upsert({"endpoint": dev["endpoint"], "keys": dev["keys"]}, dev.get("name"), b.get("topics") or [])
    return jsonify(ok=True)


@app.post("/api/push/remove")
def api_push_remove():
    PUSH.remove((request.get_json(silent=True) or {}).get("endpoint"))
    return jsonify(ok=True)


@app.post("/api/push/test")
def api_push_test():
    """Sent right away (not queued), so the page can say whether the push service took it."""
    ep = (request.get_json(silent=True) or {}).get("endpoint")
    with push._lock:
        d = PUSH.load()
        key = PUSH.key(d)
        dev = next((x for x in d["devices"] if x["endpoint"] == ep), None)
    if not dev:
        return jsonify(ok=False, message="This device isn't signed up any more. Turn notifications on again."), 404
    res = push.send_one(key, dev, {"title": "Dojo can reach you", "body": "This is how ninjarr's notifications look.",
                                   "url": "/#settings", "tag": "test"}, "high")
    if res == "gone":
        PUSH.remove(ep)
        return jsonify(ok=False, message="The browser's push service says this device unsubscribed. Turn notifications on again.")
    return jsonify(ok=res == "ok", message="Sent. It should pop up within a few seconds." if res == "ok"
                   else f"The push service refused it ({res})." if res.startswith("HTTP")
                   else f"Dojo couldn't reach this browser's push service ({urlsplit(ep).netloc}: {res}). Can this machine reach the internet?")


# who started watching: the recorder's samples, compared with the last half hour (so a short
# hiccup in Emby's session list doesn't announce the same play twice)
_plays_seen, _plays_primed = {}, []


def sample_playing():
    ps = live_snapshot(force=True)["playing"]     # the recorder keeps the shared snapshot fresh
    now = time.time()
    for p in ps:
        if _plays_primed and p["key"] not in _plays_seen:
            how = "live TV" if p.get("via") == "livetv" else ""
            where = p.get("device") or p.get("client") or ""
            notify("playing", f"{p.get('user') or 'Someone'} is watching {p.get('title') or p.get('grp') or 'something'}",
                   " · ".join(x for x in (where, how) if x), "/#home", tag=f"playing-{p.get('user') or ''}")
        _plays_seen[p["key"]] = now
    for k in [k for k, t in _plays_seen.items() if now - t > 1800]:
        del _plays_seen[k]
    if not _plays_primed:
        _plays_primed.append(True)
    return ps


def watch_for_push():
    """The slow watchers: health every 5 minutes, backups and restarts every 15, updates every hour.
    Each fact is announced once (remembered in push.json across restarts), and again only after it
    changed. Something broken has to fail two checks in a row, and checks pause while a job runs —
    an update or a re-apply restarts apps on purpose."""
    pending, n = set(), 0
    while True:
        time.sleep(60)
        n += 1
        try:
            env = env_read()
            if setup_mode(env) or not PUSH.devices():
                continue
            if n % 5 == 0 and _notifier[0].wanted("broken"):
                if running_job():
                    pending = set()
                else:
                    fails = {f"{c['label']}": c["detail"] for c in shared_health(env) if c["status"] == "fail"}
                    announced = set(PUSH.seen("broken", []))
                    new = (set(fails) & pending) - announced
                    fixed = announced - set(fails)
                    if new:
                        lines = [f"{k}: {fails[k]}" if fails[k] else k for k in sorted(new)]
                        notify("broken", "Something's wrong" if len(new) == 1 else f"{len(new)} things are wrong",
                               "; ".join(lines), "/#home", tag="broken")
                    elif fixed and not (announced - fixed):
                        notify("broken", "All good again", "; ".join(sorted(fixed)) + " — working again.", "/#home", tag="broken")
                    if new or fixed:
                        PUSH.mark("broken", sorted((announced - fixed) | new))
                    pending = set(fails)
            if n % 15 == 0:
                backups = list_backups(env)
                if backups and env.get("BACKUP_SCHEDULE", "daily") != "off":
                    newest = backups[0]
                    late = time.time() - newest["mtime"] > 30 * 3600
                    if late and PUSH.seen("backup_late") != newest["name"]:
                        notify("backup", "No backup last night",
                               f"The newest one is from {newest['when']}. Dojo → System → Back up now shows what's wrong.",
                               "/#system", tag="backup")
                        PUSH.mark("backup_late", newest["name"])
                hs = host_status() or {}
                due = bool(hs.get("reboot_required"))
                if due and not PUSH.seen("restart"):
                    pk = ", ".join(hs.get("reboot_packages") or [])
                    notify("restart", "A restart is due", ("A security update" + (f" ({pk})" if pk else "") + " needs one. ")
                           + ("It restarts by itself at about 04:45." if env.get("AUTO_REBOOT") == "yes" else "Home → Restart now."),
                           "/#home", tag="restart")
                if due != bool(PUSH.seen("restart")):
                    PUSH.mark("restart", due)
                # an app stopped and restarted for running out of memory (the VM kept running)
                ooms = [o for o in ((hs.get("memory") or {}).get("oom") or []) if o.get("app") in SERVICES]
                seen_at = PUSH.seen("oom", None)
                fresh = [o for o in ooms if seen_at is not None and o["at"] > seen_at]
                if fresh and _notifier[0].wanted("broken"):
                    o = fresh[-1]
                    notify("broken", f"{o['app'].capitalize()} ran out of memory",
                           "It was cut off at its memory ceiling and everything else kept running. Home → Memory has the details.", "/#home", tag="oom")
                if ooms and (seen_at is None or ooms[-1]["at"] > seen_at):
                    PUSH.mark("oom", ooms[-1]["at"])     # first look only remembers; later ones announce
                elif seen_at is None:
                    PUSH.mark("oom", 0)
            if n % 60 == 1 and _notifier[0].wanted("update"):
                news = news_for(git_head(), current_tags(env))
                if news and news.get("behind") and news.get("sha") and PUSH.seen("update") != news["sha"]:
                    first = (news.get("changes") or [{}])[0].get("title", "")
                    notify("update", f"ninjarr {news.get('version') or 'update'} is out",
                           (first.split(": ", 1)[-1] if first else "") + " — Dojo → System → Update.", "/#system", tag="update")
                    PUSH.mark("update", news["sha"])
        except Exception as e:  # a watcher must never die: log and look again next minute
            print(f"push watcher: {type(e).__name__}: {e}", flush=True)


# ─────────────────────────────────────────────── page
@app.get("/")
def index():
    r = Response(PAGE, mimetype="text/html")
    r.headers["Cache-Control"] = "no-cache"   # always ask, so an update shows up on the next load
    return r


STATIC_FILES = {"dojo.css", "dojo.js", "logo.png", "mark.png", "badge.png", "favicon.png", "apple-touch-icon.png", "icon-192.png", "icon-512.png",
                "icon-maskable.png", "manifest.webmanifest"}


@app.get("/static/<name>")
def static_file(name):
    """ninjarr's logo and icons — only these files, nothing else from the folder."""
    if name not in STATIC_FILES:
        abort(404)
    kind = {".webmanifest": "application/manifest+json", ".css": "text/css", ".js": "text/javascript"}.get(Path(name).suffix)
    r = send_file(HERE / "static" / name, mimetype=kind)
    # the page asks for dojo.css/js with ?v=<build>, so a new Dojo is a new address and can be kept long
    r.headers["Cache-Control"] = "public, max-age=31536000, immutable" if request.args.get("v") else "public, max-age=86400"
    return r


# The installed app's service worker; it must sit at the root to cover the whole page
@app.get("/sw.js")
def service_worker():
    r = send_file(HERE / "static" / "sw.js", mimetype="text/javascript")
    r.headers["Cache-Control"] = "no-cache"
    return r


if __name__ == "__main__" and sys.argv[1:] == ["checks"]:
    # ./bootstrap.sh doctor asks this, so the terminal and Dojo check the apps the same way
    print(json.dumps(health_checks(env_read())))
    sys.exit(0)

if __name__ == "__main__":
    # always on: before setup there's simply nothing playing to record
    _notifier.append(push.Notifier(PUSH, log=lambda m: print(m, flush=True)))
    history.Recorder(sample_playing, on_change=lambda: publish({"src": "play", "toast": None}), backfill=emby_log_plays).start()
    threading.Thread(target=check_upstream, daemon=True, name="upstream").start()
    threading.Thread(target=watch_for_push, daemon=True, name="push-watch").start()
    app.run(host="0.0.0.0", port=5000, threaded=True)
