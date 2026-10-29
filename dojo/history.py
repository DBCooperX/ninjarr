"""Dojo's watch history: who watched what, from usenet or live TV, on which device, and how it
played. Emby keeps no history of its own without Premiere plugins, so Dojo records it: every few
seconds it reads Emby's sessions (and Dispatcharr's viewers that don't come through Emby) and keeps
one row per play in a small SQLite file in Dojo's data folder, which every backup includes. On its
first run it also brings in what Emby's activity log remembers, so the history doesn't start empty.

Nothing in here talks to the apps directly; app.py hands in functions that return the current
sessions and the activity log, so this file only records and counts."""
import re
import sqlite3
import threading
import time
from collections import Counter, defaultdict
from pathlib import Path

DB = Path("/dojo-data/history.db")
POLL = 5            # seconds between looks at what's playing
MIN_WATCHED = 60    # a play counts from a minute of watching (skips zapping and previews)

# every column a play has; the table gains new ones by itself when Dojo is updated
COLUMNS = {
    "user": "TEXT", "user_id": "TEXT", "device": "TEXT", "client": "TEXT", "app_version": "TEXT", "ip": "TEXT",
    "via": "TEXT",          # usenet | livetv
    "kind": "TEXT",         # episode | movie | channel | other
    "title": "TEXT",        # "Show S01E02 — Name", a movie, a channel and programme
    "grp": "TEXT",          # what it adds up under: the series, the movie (with year), the channel
    "item_id": "TEXT", "group_id": "TEXT", "server_id": "TEXT",
    "season": "INTEGER", "episode": "INTEGER", "year": "INTEGER",
    "login": "TEXT",        # the IPTV login, for Dispatcharr's own viewers
    "method": "TEXT",       # direct play | direct stream | audio transcoding | transcoding
    "reasons": "TEXT", "source": "TEXT",
    "src_res": "TEXT", "src_codec": "TEXT", "src_hdr": "TEXT", "stream_res": "TEXT", "stream_codec": "TEXT",
    "bitrate": "INTEGER",   # kbit/s as played
    "audio": "TEXT", "subtitles": "TEXT",
    "started": "REAL", "last": "REAL", "watched": "REAL", "paused": "REAL", "position": "REAL", "runtime": "REAL",
    "origin": "TEXT",       # NULL: recorded by Dojo · emby-log: brought in from Emby's activity log
}
DESCRIPTIVE = [c for c in COLUMNS if c not in ("started", "last", "watched", "paused", "origin")]


_ready = []      # the table is checked and brought up to date once per start, not on every read


def connect():
    DB.parent.mkdir(parents=True, exist_ok=True)
    c = sqlite3.connect(DB, timeout=10)
    c.row_factory = sqlite3.Row
    if not _ready:
        _prepare(c)
        _ready.append(True)
    return c


def _prepare(c):
    # WAL: the pages read while the recorder writes every few seconds, without waiting for each other
    c.execute("PRAGMA journal_mode=WAL")
    c.execute("CREATE TABLE IF NOT EXISTS plays (id TEXT PRIMARY KEY)")
    have = {r[1] for r in c.execute("PRAGMA table_info(plays)")}
    for col, typ in COLUMNS.items():
        if col not in have:
            c.execute(f"ALTER TABLE plays ADD COLUMN {col} {typ}")
    c.execute("CREATE INDEX IF NOT EXISTS plays_started ON plays(started)")
    c.execute("CREATE INDEX IF NOT EXISTS plays_user ON plays(user)")
    c.execute("CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v TEXT)")
    c.execute("INSERT OR IGNORE INTO meta VALUES ('since', ?)", (str(time.time()),))
    c.commit()


def meta(db, k, v=None):
    if v is not None:
        db.execute("INSERT OR REPLACE INTO meta VALUES (?, ?)", (k, str(v)))
        db.commit()
        return v
    r = db.execute("SELECT v FROM meta WHERE k = ?", (k,)).fetchone()
    return r[0] if r else None


class Recorder:
    """Polls what's playing and keeps the plays table current. `sample()` returns a list of
    dicts: key (stable while one thing plays on one device), paused, and the columns above.
    `on_change()` runs when what's playing changed. `backfill()` (optional) returns plays from
    Emby's activity log, brought in once."""

    def __init__(self, sample, on_change=None, backfill=None):
        self.sample, self.on_change, self.backfill = sample, on_change, backfill
        self.active = {}
        self.sig = None

    def start(self):
        threading.Thread(target=self.loop, daemon=True, name="history").start()

    def loop(self):
        try:
            db = connect()
        except (OSError, sqlite3.Error):
            return          # no writable data folder: Dojo works on without a history
        try:
            tidy_log_plays(db)
        except sqlite3.Error:
            pass
        if self.backfill and not meta(db, "emby_log"):
            try:
                n = import_plays(db, self.backfill())
                meta(db, "emby_log", n)
            except Exception:  # Emby not reachable yet: try again on the next start
                pass
        tidied = 0
        while True:
            try:
                self.step(db, self.sample())
            except Exception:  # one bad answer from an app must never stop the recorder
                pass
            if time.time() - tidied > 86400:      # once a day: posters nobody looked at for a month go
                tidied = time.time()
                for f in (DB.parent / "art").glob("*.jpg"):
                    try:
                        if time.time() - f.stat().st_mtime > 30 * 86400:
                            f.unlink()
                    except OSError:
                        pass
            time.sleep(POLL)

    def step(self, db, now_playing, now=None):
        now = now or time.time()
        seen = set()
        for p in now_playing:
            k = p["key"]
            seen.add(k)
            a = self.active.get(k)
            if a is None:
                a = self.active[k] = {"id": f"{int(now)}-{abs(hash(k)) % 10**8}", "t": now, "watched": 0.0, "paused": 0.0, "started": now}
            dt = now - a["t"]
            if 0 < dt <= POLL * 6:
                a["paused" if p.get("paused") else "watched"] += dt
            a["t"] = now
            row = {c: p.get(c) for c in DESCRIPTIVE}
            row.update(id=a["id"], started=a["started"], last=now, watched=round(a["watched"], 1), paused=round(a["paused"], 1))
            cols = list(row)
            db.execute(f"INSERT INTO plays ({', '.join(cols)}) VALUES ({', '.join(':' + c for c in cols)}) "
                       f"ON CONFLICT(id) DO UPDATE SET {', '.join(f'{c} = excluded.{c}' for c in cols if c not in ('id', 'started'))}", row)
        for k in list(self.active):
            if k not in seen:
                del self.active[k]
        db.execute("DELETE FROM plays WHERE watched < 15 AND last < ? AND origin IS NULL", (now - 120,))   # zapping
        db.commit()
        sig = sorted((p["key"], bool(p.get("paused"))) for p in now_playing)
        if self.sig is not None and sig != self.sig and self.on_change:
            self.on_change()
        self.sig = sig


SERIES_TEXT = re.compile(r"^(?P<series>.+?) - S(?P<s>\d+), ?Ep(?P<e>\d+)(?: - (?P<name>.+))?$")
RECORDING_TEXT = re.compile(r"^(?P<ch>.+?) - .+? \d{4}_\d{2}_\d{2}_\d{2}_\d{2}_\d{2}$")


def describe_text(what):
    """What Emby's log says was played, when the item itself is gone from Emby (a replaced file, a
    live TV programme that has passed): "Series - S5, Ep7 - Name" or "Channel - Programme 2026_10_20_17_00_00"."""
    m = SERIES_TEXT.match(what or "")
    if m:
        s, e = int(m.group("s")), int(m.group("e"))
        return {"kind": "episode", "via": "usenet", "grp": m.group("series").strip(), "season": s, "episode": e,
                "title": f"{m.group('series').strip()} S{s:02d}E{e:02d}" + (f" — {m.group('name').strip()}" if m.group("name") else "")}
    m = RECORDING_TEXT.match(what or "")
    if m:
        return {"kind": "channel", "via": "livetv", "grp": m.group("ch").strip(), "title": m.group("ch").strip()}
    return None


def tidy_log_plays(db):
    """Plays from Emby's log whose item was already gone got the log's raw text as their name:
    sort them under their series or channel like every other play."""
    for r in db.execute("SELECT id, grp, title FROM plays WHERE origin = 'emby-log' AND (grp = title OR kind IS NULL OR kind = 'other')").fetchall():
        d = describe_text(r["grp"]) or describe_text(r["title"])
        if d:
            db.execute("UPDATE plays SET kind = ?, via = ?, grp = ?, title = ?, season = ?, episode = ? WHERE id = ?",
                       (d["kind"], d["via"], d["grp"], d["title"], d.get("season"), d.get("episode"), r["id"]))
    db.commit()


def import_plays(db, plays):
    """Plays from Emby's activity log (start and stop of each), kept apart as origin emby-log."""
    n = 0
    for p in plays:
        row = {c: p.get(c) for c in COLUMNS}
        row.update(id=p["id"], origin="emby-log")
        cols = list(row)
        cur = db.execute(f"INSERT OR IGNORE INTO plays ({', '.join(cols)}) VALUES ({', '.join(':' + c for c in cols)})", row)
        n += cur.rowcount
    first = db.execute("SELECT MIN(started) FROM plays").fetchone()[0]
    if first and first < float(meta(db, "since")):
        meta(db, "since", first)
    db.commit()
    return n


# ─────────────────────────────────────────────── reading it back
def _open():
    try:
        return connect()
    except (OSError, sqlite3.Error):
        return None


def _where(since=None, until=None, user=None, kind=None, via=None, grp=None, q=None, why=None):
    w, a = ["watched >= ?"], [MIN_WATCHED]
    for cond, val in (("started >= ?", since), ("started < ?", until), ("user = ?", user), ("via = ?", via), ("grp = ?", grp)):
        if val is not None:
            w.append(cond)
            a.append(val)
    if kind:
        w.append("kind = ?")
        a.append(kind)
    if why:                      # one of the reasons Emby gave for converting
        w.append("method IN ('transcoding', 'audio transcoding') AND ('; ' || reasons || '; ') LIKE ?")
        a.append(f"%; {why}; %")
    if q:
        w.append("(title LIKE ? OR grp LIKE ? OR user LIKE ? OR device LIKE ? OR client LIKE ?)")
        a += [f"%{q}%"] * 5
    return " AND ".join(w), a


def rows(**f):
    db = _open()
    if not db:
        return None
    w, a = _where(**f)
    out = [dict(r) for r in db.execute(f"SELECT * FROM plays WHERE {w} ORDER BY started", a)]
    db.close()
    return out


def since():
    db = _open()
    if not db:
        return None
    v = float(meta(db, "since"))
    db.close()
    return v


def recent(limit=60, user=None):
    """The latest plays, for the timeline (or one person's)."""
    db = _open()
    if not db:
        return []
    w, a = _where(user=user)
    out = [dict(r) for r in db.execute(f"SELECT * FROM plays WHERE {w} ORDER BY started DESC LIMIT ?", a + [limit])]
    db.close()
    return out


def page(page=1, size=25, **f):
    """One page of the history table, newest first, with the filters applied."""
    db = _open()
    if not db:
        return None
    w, a = _where(**f)
    total = db.execute(f"SELECT COUNT(*) FROM plays WHERE {w}", a).fetchone()[0]
    out = [dict(r) for r in db.execute(f"SELECT * FROM plays WHERE {w} ORDER BY started DESC LIMIT ? OFFSET ?",
                                       a + [size, (max(1, page) - 1) * size])]
    users = [r[0] for r in db.execute("SELECT user FROM plays WHERE watched >= ? GROUP BY user ORDER BY MAX(started) DESC", (MIN_WATCHED,))]
    db.close()
    return {"total": total, "rows": out, "users": users}


def watched_groups(user=None):
    """Every series, movie and channel anyone (or one person) ever watched, lower case."""
    db = _open()
    if not db:
        return None
    w, a = _where(user=user)
    out = {(r[0] or "").lower() for r in db.execute(f"SELECT DISTINCT grp FROM plays WHERE {w}", a)}
    db.close()
    return out


def watched_ids(user=None):
    """The Emby ids (episode or movie, and series) of everything watched, for matching requests."""
    db = _open()
    if not db:
        return None
    w, a = _where(user=user)
    out = set()
    for item, group in db.execute(f"SELECT DISTINCT item_id, group_id FROM plays WHERE {w}", a):
        out |= {x for x in (item, group) if x}
    db.close()
    return out


def totals(since):
    """Just the headline numbers (Home), without everything overview() works out."""
    db = _open()
    if not db:
        return None
    w, a = _where(since=since)
    n, secs, people, titles = db.execute(f"SELECT COUNT(*), COALESCE(SUM(watched), 0), COUNT(DISTINCT user), COUNT(DISTINCT grp) "
                                         f"FROM plays WHERE {w}", a).fetchone()
    db.close()
    return {"plays": n, "hours": H(secs), "viewers": people, "titles": titles}



def player_name(client):
    """Emby's app name without "Emby for" (Apple TV, Samsung, …)."""
    return re.sub(r"(?i)^emby (for|theater)\s*", "", client or "").strip() or "a player"


COSTS = ["subtitles", "video", "bitrate", "container", "audio"]     # heaviest first


def reason_cost(reason):
    """What a conversion reason costs: burned-in subtitles and the picture are heavy, the sound and
    the file type are light, the bitrate is a setting in the player."""
    r = reason.lower()
    return ("subtitles" if "subtitle" in r else "audio" if "audio" in r else "container" if "file type" in r
            else "bitrate" if "bitrate" in r else "video")


def codec_players(codec, since):
    """Which players played files in this codec since then: {"converted": {player: plays}} for those
    Emby had to convert because they can't decode it (not for bitrate or the like), {"direct": …}
    for those that played it as it is. A player is its app's name without "Emby for" (Apple TV, …)."""
    db = _open()
    if not db:
        return None
    w, a = _where(since=since)
    out = {"converted": {}, "direct": {}}
    for client, method, reasons, n in db.execute(f"SELECT client, method, reasons, COUNT(*) FROM plays WHERE {w} AND src_codec = ? "
                                                 f"GROUP BY client, method, reasons", a + [codec]):
        name = player_name(client)
        if method == "transcoding" and "video codec" in (reasons or ""):
            side = out["converted"]          # converted because it can't decode the codec, not for bitrate etc.
        elif method != "transcoding":
            side = out["direct"]
        else:
            continue
        side[name] = side.get(name, 0) + n
    for name in out["converted"]:
        out["direct"].pop(name, None)
    db.close()
    return out

# ─────────────────────────────────────────────── the numbers
H = lambda s: round(s / 3600, 1)


def done(r):
    return bool(r["via"] != "livetv" and r["runtime"] and r["position"] and r["position"] >= 0.9 * r["runtime"])


def buckets(start, end):
    """Time buckets for the charts: hours for a day, days up to two months, then weeks."""
    span = end - start
    if span <= 2 * 86400:
        step, fmt = 3600, "%H:00"
    elif span <= 62 * 86400:
        step, fmt = 86400, "%a %d"
    else:
        step, fmt = 7 * 86400, "%d %b"
    lt = time.localtime(start)
    first = time.mktime((lt.tm_year, lt.tm_mon, lt.tm_mday, lt.tm_hour if step == 3600 else 0, 0, 0, 0, 0, -1))
    out, t = [], first
    while t < end:
        out.append((t, time.strftime(fmt, time.localtime(t))))
        t += step
    return out, step


def _idx(t, bks, step):
    if not bks or t < bks[0][0]:
        return None
    i = int((t - bks[0][0]) // step)
    return i if i < len(bks) else len(bks) - 1


def overview(start, end=None):
    """Everything on the Watching page for one period."""
    end = end or time.time()
    rs = rows(since=start, until=end)
    if rs is None:
        return None
    first = since()
    total = sum(r["watched"] for r in rs)
    live = sum(r["watched"] for r in rs if r["via"] == "livetv")
    vod = [r for r in rs if r["via"] != "livetv" and r["runtime"]]
    trans = sum(r["watched"] for r in rs if r["method"] == "transcoding")

    # top lists: the most watched titles and people, each ranked
    def top(key, filt=lambda r: True, by="watched", n=5):
        g = defaultdict(lambda: {"watched": 0.0, "plays": 0, "viewers": set(), "last": 0, "item": None, "group_id": None, "server": None, "kind": None, "via": None, "user_id": None})
        for r in rs:
            if not filt(r):
                continue
            x = g[key(r)]
            x["watched"] += r["watched"]; x["plays"] += 1; x["viewers"].add(r["user"]); x["last"] = max(x["last"], r["started"])
            x["item"] = x["item"] or r["item_id"]; x["group_id"] = x["group_id"] or r["group_id"]; x["server"] = r["server_id"] or x["server"]
            x["kind"], x["via"], x["user_id"] = r["kind"], r["via"], x["user_id"] or r["user_id"]
        order = sorted(g.items(), key=lambda kv: (-len(kv[1]["viewers"]) if by == "viewers" else -kv[1][by], -kv[1]["watched"]))
        return [{"name": k, "hours": H(v["watched"]), "plays": v["plays"], "viewers": len(v["viewers"]), "last": v["last"],
                 "art": v["group_id"] or v["item"], "server": v["server"], "kind": v["kind"], "via": v["via"], "user_id": v["user_id"]}
                for k, v in order[:n] if k]
    # top titles per kind, ranked by time watched and by how many people watched
    kinds_ = {"series": lambda r: r["kind"] == "episode", "movies": lambda r: r["kind"] == "movie",
              "channels": lambda r: r["via"] == "livetv"}
    cards = {k: {"hours": top(lambda r: r["grp"], f, n=6), "viewers": top(lambda r: r["grp"], f, by="viewers", n=6)}
             for k, f in kinds_.items()}
    cards["people"] = top(lambda r: r["user"], n=8)
    last = rs[-1] if rs else None

    # charts over time: plays and hours per bucket, by kind and by how it played
    bks, step = buckets(start, end)
    kinds = {"episode": "Episodes", "movie": "Movies", "channel": "Live TV"}
    by_time = [{"t": t, "label": lab, "plays": {k: 0 for k in kinds.values()}, "hours": {k: 0.0 for k in kinds.values()},
                "how": {"Direct play": 0.0, "Direct stream": 0.0, "Transcode": 0.0}} for t, lab in bks]
    for r in rs:
        i = _idx(r["started"], bks, step)
        if i is None:
            continue
        k = kinds.get(r["kind"], "Episodes" if r["via"] != "livetv" else "Live TV")
        by_time[i]["plays"][k] += 1
        by_time[i]["hours"][k] = round(by_time[i]["hours"][k] + r["watched"] / 3600, 2)
        how = "Transcode" if r["method"] in ("transcoding", "audio transcoding") else "Direct stream" if r["method"] == "direct stream" else "Direct play"
        if r["method"]:
            by_time[i]["how"][how] = round(by_time[i]["how"][how] + r["watched"] / 3600, 2)

    # when: weekday and hour of day (local time), watched hours
    heat = [[0.0] * 24 for _ in range(7)]
    for r in rs:
        t, stop = r["started"], r["started"] + r["watched"]
        while t < stop:
            s = min(900, stop - t)
            lt = time.localtime(t)
            heat[lt.tm_wday][lt.tm_hour] += s / 60
            t += s
    heat = [[round(m) for m in d] for d in heat]

    # most at once
    edges = sorted([(r["started"], 1) for r in rs] + [(r["last"], -1) for r in rs], key=lambda e: (e[0], e[1]))
    peak, cur, peak_at = 0, 0, None
    for t, d in edges:
        cur += d
        if cur > peak:
            peak, peak_at = cur, t

    # picture: what files are, against what reaches the screen
    res = defaultdict(lambda: {"source": 0, "stream": 0})
    for r in rs:
        if r["src_res"]:
            res[r["src_res"]]["source"] += 1
            res[r["stream_res"] or r["src_res"]]["stream"] += 1
    order = ["2160p", "1440p", "1080p", "720p", "576p", "480p", "SD"]
    resolution = [{"res": k, **res[k]} for k in sorted(res, key=lambda k: order.index(k) if k in order else 99)]

    reasons = defaultdict(Counter)       # reason → {player: plays}
    devices = defaultdict(lambda: [0.0, 0.0, 0, Counter()])     # watched, converted, plays, reasons
    for r in rs:
        d = devices[r["client"] or r["device"] or "?"]
        d[0] += r["watched"]; d[2] += 1
        if r["method"] in ("transcoding", "audio transcoding"):
            d[1] += r["watched"]
            for x in (r["reasons"] or "").split("; "):
                if x:
                    reasons[x][player_name(r["client"] or r["device"])] += 1
                    d[3][x] += 1
    longest = max(rs, key=lambda r: r["watched"], default=None)
    return {
        "since": first, "start": start, "end": end, "step": step,
        "totals": {"hours": H(total), "plays": len(rs), "viewers": len({r["user"] for r in rs}),
                   "titles": len({r["grp"] for r in rs}), "live_pct": round(100 * live / total) if total else 0,
                   "finished_pct": round(100 * sum(1 for r in vod if done(r)) / len(vod)) if vod else None,
                   "transcode_pct": round(100 * trans / total) if total else 0, "peak": peak, "peak_at": peak_at,
                   "paused_h": H(sum(r["paused"] or 0 for r in rs)),
                   "from_log": sum(1 for r in rs if r["origin"] == "emby-log")},
        "cards": cards,
        "last": {"title": last["title"], "grp": last["grp"], "via": last["via"], "user": last["user"], "user_id": last["user_id"],
                 "when": last["started"], "art": last["group_id"] or last["item_id"],
                 "server": last["server_id"]} if last else None,
        "by_time": by_time,
        "weekday": [round(sum(d) / 60, 1) for d in heat],
        "hour": [round(sum(heat[w][h] for w in range(7)) / 60, 1) for h in range(24)],
        "heat": heat,
        "resolution": resolution,
        "devices": sorted(({"device": player_name(k), "hours": H(w), "plays": n, "transcode_pct": round(100 * t / w) if w else 0,
                            "why": why.most_common(1)[0][0] if why else None}
                           for k, (w, t, n, why) in devices.items()), key=lambda x: -x["hours"])[:10],
        "reasons": sorted(({"reason": k, "n": sum(c.values()), "cost": reason_cost(k), "players": [p for p, _ in c.most_common(3)],
                            "more_players": max(0, len(c) - 3)} for k, c in reasons.items()),
                          key=lambda x: (COSTS.index(x["cost"]), -x["n"])),
        "longest": {"user": longest["user"], "title": longest["grp"] or longest["title"], "hours": H(longest["watched"]), "when": longest["started"]} if longest else None,
    }


def person(user, now=None):
    """One person: totals for several periods, players, addresses, recent plays."""
    now = now or time.time()
    rs = rows(user=user)
    if rs is None:
        return None
    periods = []
    for label, secs in (("Last 24 hours", 86400), ("Last 7 days", 7 * 86400), ("Last 30 days", 30 * 86400), ("All time", None)):
        p = [r for r in rs if secs is None or r["started"] >= now - secs]
        periods.append({"label": label, "plays": len(p), "hours": H(sum(r["watched"] for r in p))})
    players = defaultdict(lambda: {"plays": 0, "watched": 0.0, "last": 0, "device": ""})
    ips = defaultdict(lambda: {"plays": 0, "last": 0, "player": ""})
    for r in rs:
        pl = players[r["client"] or r["device"] or "?"]
        pl["plays"] += 1; pl["watched"] += r["watched"]; pl["last"] = max(pl["last"], r["started"]); pl["device"] = r["device"] or pl["device"]
        if r["ip"]:
            ip = ips[r["ip"]]
            ip["plays"] += 1; ip["last"] = max(ip["last"], r["started"]); ip["player"] = r["client"] or r["device"] or ""
    first = min((r["started"] for r in rs), default=None)
    last = max((r["started"] for r in rs), default=None)
    user_id = next((r["user_id"] for r in reversed(rs) if r["user_id"]), None)
    return {
        "user": user, "user_id": user_id, "first": first, "last": last, "periods": periods,
        "players": sorted(({"player": k, "device": v["device"], "plays": v["plays"], "hours": H(v["watched"]), "last": v["last"]}
                           for k, v in players.items()), key=lambda x: -x["plays"]),
        "ips": sorted(({"ip": k, **v} for k, v in ips.items()), key=lambda x: -x["last"])[:10],
        "recent": [{"title": r["title"], "grp": r["grp"], "art": r["group_id"] or r["item_id"], "item": r["item_id"], "server": r["server_id"],
                    "when": r["started"], "kind": r["kind"], "via": r["via"]} for r in sorted(rs, key=lambda r: -r["started"])[:12]],
    }


def title(grp, via=None):
    """One series, movie or channel: who watched it, how much, and every play."""
    rs = rows(grp=grp, via=via)
    if rs is None:
        return None
    viewers = defaultdict(lambda: {"plays": 0, "watched": 0.0, "last": 0, "done": 0, "user_id": None})
    eps = defaultdict(lambda: {"title": "", "viewers": set(), "plays": 0, "season": None, "episode": None, "item": None, "done": set()})
    for r in rs:
        v = viewers[r["user"]]
        v["plays"] += 1; v["watched"] += r["watched"]; v["last"] = max(v["last"], r["started"]); v["done"] += done(r); v["user_id"] = v["user_id"] or r["user_id"]
        if r["kind"] == "episode":
            e = eps[r["item_id"] or r["title"]]
            e.update(title=r["title"], season=r["season"], episode=r["episode"], item=r["item_id"])
            e["viewers"].add(r["user"]); e["plays"] += 1
            if done(r):
                e["done"].add(r["user"])
    head = rs[-1] if rs else {}
    return {
        "grp": grp, "kind": head.get("kind"), "via": head.get("via"), "art": head.get("group_id") or head.get("item_id"), "server": head.get("server_id"),
        "totals": {"plays": len(rs), "hours": H(sum(r["watched"] for r in rs)), "viewers": len(viewers),
                   "first": min((r["started"] for r in rs), default=None), "last": max((r["started"] for r in rs), default=None)},
        "viewers": sorted(({"user": k, "user_id": v["user_id"], "plays": v["plays"], "hours": H(v["watched"]), "last": v["last"], "done": v["done"]}
                           for k, v in viewers.items()), key=lambda x: -x["hours"]),
        "episodes": sorted(({"title": e["title"], "season": e["season"], "episode": e["episode"], "item": e["item"], "plays": e["plays"],
                             "viewers": sorted(e["viewers"]), "done": sorted(e["done"])} for e in eps.values()),
                           key=lambda e: (e["season"] or 0, e["episode"] or 0)),
    }
