"""Stats → System: the VM itself, apart from what's being watched. Right now from /proc (in a
container it shows the whole VM: memory, CPU, the kernel's memory-pressure figures), the history
from what the host writes every 5 minutes (bootstrap.sh host-status → .state/system.tsv,
memory.tsv, dns.tsv), and the forecasts built on it: an app whose memory keeps growing, a disk
that is filling up. The same numbers feed the health checks on Home."""
import time
from collections import Counter, defaultdict
from datetime import datetime

NAMES = {"aiostreams": "AIOStreams", "prowlarr": "Prowlarr", "sonarr": "Sonarr", "radarr": "Radarr",
         "bazarr": "Bazarr", "emby": "Emby", "seerr": "Seerr", "dojo": "Dojo", "dispatcharr": "Dispatcharr",
         "caddy": "Caddy"}

# who looks up what: names seen while Docker's DNS piled up, and the apps that use them
WHO = [("servarr.com", "Sonarr, Radarr or Prowlarr"), ("sonarr.tv", "Sonarr"), ("radarr.video", "Radarr"),
       ("prowlarr.com", "Prowlarr"), ("emby.media", "Emby"), ("mb3admin.com", "Emby"),
       ("themoviedb.org", "Radarr, Seerr or Emby"), ("tmdb.org", "Radarr, Seerr or Emby"),
       ("thetvdb.com", "Sonarr or Emby"), ("tvmaze.com", "Sonarr"), ("opensubtitles", "Bazarr"),
       ("subdl", "Bazarr"), ("dispatcharr", "Dispatcharr"), ("ghcr.io", "an update check"),
       ("docker.io", "an update check"), ("github.com", "an update check")]


def nice(name):
    return NAMES.get(name, name.capitalize())


def gb(mb):
    return f"{mb / 1024:.1f} GB" if mb >= 1024 else f"{round(mb)} MB"


def who_asks(host):
    return next((w for k, w in WHO if k in host), None)


def _num(x):
    try:
        return float(x)
    except (TypeError, ValueError):
        return None


# The host rewrites these files every 5 minutes, while Home asks for its checks every 20 seconds:
# each file is parsed once per change, then only filtered.
_parsed = {}


def _rows(path, parse):
    try:
        st = path.stat()
    except OSError:
        return None
    sig = (st.st_mtime_ns, st.st_size)
    hit = _parsed.get(path)
    if hit and hit[0] == sig:
        return hit[1]
    try:
        rows = parse(path.read_text().splitlines())
    except OSError:
        return None
    _parsed[path] = (sig, rows)
    return rows


def _parse_system(lines):
    out = []
    for line in lines:
        p = [_num(x) for x in line.split("\t")]
        if len(p) < 9 or p[0] is None:
            continue
        out.append({"t": p[0], "cpu": p[1] or 0, "avail": p[2], "swap": p[3] or 0, "some": p[4] or 0, "full": p[5] or 0,
                    "dused": p[6], "dsize": p[7], "piles": int(p[8] or 0),
                    "rx": p[9] if len(p) > 10 else None, "tx": p[10] if len(p) > 10 else None})
    return out


def read_system(state, since=0):
    """.state/system.tsv: time, CPU %, memory available MB, swap used MB, % of time waiting for
    memory (some apps / all apps), disk used / size MB, DNS pile-ups, network bytes in / out."""
    return [r for r in _rows(state / "system.tsv", _parse_system) or [] if r["t"] >= since]


def _parse_memory(lines):
    by = defaultdict(list)
    for line in lines:
        p = line.split("\t")
        if len(p) < 3:
            continue
        t, mb = _num(p[0]), _num(p[2])
        if t is None or mb is None:
            continue
        by[p[1]].append({"t": t, "mb": mb, "cpu": _num(p[3]) if len(p) > 3 else None,
                         "rx": _num(p[4]) if len(p) > 4 else None, "tx": _num(p[5]) if len(p) > 5 else None})
    for rs in by.values():
        rs.sort(key=lambda r: r["t"])
    return by


def read_memory(state, since=0):
    """.state/memory.tsv: time, app, MB, and (since 1.0.3) CPU %, network in / out MB since the app started."""
    by = defaultdict(list)
    for app, rs in (_rows(state / "memory.tsv", _parse_memory) or {}).items():
        kept = [r for r in rs if r["t"] >= since]
        if kept:
            by[app] = kept
    return by


def _parse_dns(lines):
    out = []
    for line in lines:
        p = line.split("\t")
        if len(p) >= 3:
            out.append((_num(p[0]) or 0, p[1], int(_num(p[2]) or 0)))
    return out


def read_dns(state, since=0):
    c = Counter()
    for t, name, n in _rows(state / "dns.tsv", _parse_dns) or []:
        if t >= since:
            c[name] += n
    return c


def transferred(rows, since, rx="rx", tx="tx"):
    """How much went in and out from SINCE on, from counters that run from a start (an app's since it
    started, the VM's since it booted): each reading's growth over the one before; a counter that
    fell had restarted, so all it holds is new."""
    got, prev, seen = {"in": 0.0, "out": 0.0}, None, False
    for r in rows:
        if r[rx] is None or r[tx] is None:
            prev = None
            continue
        if prev is not None and r["t"] >= since:
            for k, key in (("in", rx), ("out", tx)):
                got[k] += r[key] - prev[key] if r[key] >= prev[key] else r[key]
            seen = True
        prev = r
    return got if seen else None


def today_traffic(state):
    """For Home: what Emby sent to the players today, and what AIOStreams fetched from usenet for it."""
    midnight = datetime.now().replace(hour=0, minute=0, second=0, microsecond=0).timestamp()
    rows = read_memory(state, midnight - 3600)          # the reading before midnight is the starting point
    emby, aio = transferred(rows.get("emby", []), midnight), transferred(rows.get("aiostreams", []), midnight)
    if not emby and not aio:
        return None
    return {"streamed_mb": round(emby["out"]) if emby else None, "fetched_mb": round(aio["in"]) if aio else None}


# ── right now, straight from the kernel
_cpu_prev = [None]


def _proc_cpu():
    with open("/proc/stat") as f:
        v = [int(x) for x in f.readline().split()[1:]]
    return sum(v), v[3] + (v[4] if len(v) > 4 else 0)


def live():
    out = {}
    try:
        mi = {}
        with open("/proc/meminfo") as f:
            for line in f:
                k, v = line.split(":", 1)
                mi[k] = int(v.split()[0]) // 1024
        out.update(mem_total_mb=mi["MemTotal"], mem_avail_mb=mi["MemAvailable"],
                   swap_mb=mi.get("SwapTotal", 0), swap_used_mb=mi.get("SwapTotal", 0) - mi.get("SwapFree", 0))
    except (OSError, KeyError, ValueError):
        pass
    try:
        with open("/proc/pressure/memory") as f:
            for line in f:
                kind, *kv = line.split()
                d = dict(x.split("=") for x in kv)
                out[f"wait_{kind}"] = float(d["avg60"])        # % of the last minute
    except (OSError, KeyError, ValueError):
        pass
    try:
        now = time.time()
        a = _proc_cpu()
        prev = _cpu_prev[0]
        if not prev or now - prev[0] < 1 or now - prev[0] > 600:
            time.sleep(0.4)
            prev, a, now = (now, *a), _proc_cpu(), time.time()
        busy, total = (a[0] - prev[1]) - (a[1] - prev[2]), a[0] - prev[1]
        out["cpu_pct"] = round(100 * busy / total, 1) if total > 0 else None
        _cpu_prev[0] = (now, *a)
    except (OSError, ValueError):
        pass
    return out


# ── forecasts
def fit(xs, ys):
    """Least squares: slope and how well a straight line explains it (r², 0…1)."""
    n = len(xs)
    if n < 3:
        return 0.0, 0.0
    mx, my = sum(xs) / n, sum(ys) / n
    sxx = sum((x - mx) ** 2 for x in xs)
    syy = sum((y - my) ** 2 for y in ys)
    sxy = sum((x - mx) * (y - my) for x, y in zip(xs, ys))
    if sxx == 0:
        return 0.0, 0.0
    slope = sxy / sxx
    return slope, (sxy * sxy / (sxx * syy) if syy else 0.0)


MIN_SPAN = 2 * 86400     # two days before an app's memory is judged


def app_trend(rows, limit_mb):
    """Whether an app's memory keeps growing: the floor it falls back to when quiet (the lowest
    reading of each 6 hours) rising steadily for two days or more. A restart — memory dropping by
    40% at once, or the network counters starting again — begins a new record."""
    start = 0
    for i in range(1, len(rows)):
        a, b = rows[i - 1], rows[i]
        if b["mb"] < 0.6 * a["mb"] or (a["rx"] is not None and b["rx"] is not None and b["rx"] < a["rx"]):
            start = i
    seg = rows[start:]
    if not seg:
        return {"state": "collecting", "left_h": MIN_SPAN / 3600}
    span = seg[-1]["t"] - seg[0]["t"]
    if span < MIN_SPAN:
        return {"state": "collecting", "left_h": round((MIN_SPAN - span) / 3600)}
    floors = defaultdict(lambda: float("inf"))
    for r in seg:
        k = int((r["t"] - seg[0]["t"]) // 21600)
        floors[k] = min(floors[k], r["mb"])
    ks = sorted(floors)[:-1] or sorted(floors)     # the newest 6 hours aren't over yet
    xs, ys = [k * 0.25 for k in ks], [floors[k] for k in ks]
    slope, r2 = fit(xs, ys)                         # MB a day
    now_mb = seg[-1]["mb"]
    growing = slope >= max(20, 0.01 * (limit_mb or 0)) and r2 >= 0.6 and ys[-1] > ys[0]
    out = {"state": "growing" if growing else "steady", "per_day": round(slope), "days": round(span / 86400, 1)}
    if growing and limit_mb and limit_mb > now_mb:
        out["to_limit_days"] = round((limit_mb - now_mb) / slope, 1)
    return out


def disk_trend(rows):
    pts = [(r["t"], r["dused"]) for r in rows if r["dused"]]
    if len(pts) < 12 or pts[-1][0] - pts[0][0] < 86400:
        return {"state": "collecting"}
    slope, r2 = fit([(t - pts[0][0]) / 86400 for t, _ in pts], [u for _, u in pts])
    size = next((r["dsize"] for r in reversed(rows) if r["dsize"]), None)
    out = {"state": "steady", "per_day": round(slope)}
    if slope > 50 and r2 >= 0.5 and size:
        out.update(state="filling", to_full_days=round((size - pts[-1][1]) / slope))
    return out


# ── the page
def buckets(window, now):
    if window == "7d":
        return 7 * 86400, 3 * 3600, "%a %H:%M"
    return 86400, 1800, "%H:%M"


def page(state, hs, window="24h"):
    now = time.time()
    span, step, fmt = buckets(window, now)
    since = now - span
    srows_all = read_system(state, now - 7 * 86400)
    mem = (hs or {}).get("memory") or {}
    lv = live()
    total = lv.get("mem_total_mb") or mem.get("total_mb") or 0

    first = int(since // step) * step
    n = int((now - first) // step) + 1
    labels = [datetime.fromtimestamp(first + i * step).strftime(fmt) for i in range(n)]
    acc = defaultdict(lambda: defaultdict(list))
    prev = None
    for r in srows_all:
        i = int((r["t"] - first) // step)
        # GB through the VM's network card in each bucket (the counters restart at a reboot)
        if prev and r["rx"] is not None and prev["rx"] is not None and 0 <= i < n:
            acc[i]["in"].append((r["rx"] - prev["rx"] if r["rx"] >= prev["rx"] else r["rx"]) / 2**30)
            acc[i]["out"].append((r["tx"] - prev["tx"] if r["tx"] >= prev["tx"] else r["tx"]) / 2**30)
        prev = r
        if not 0 <= i < n:
            continue
        acc[i]["cpu"].append(r["cpu"])
        acc[i]["wait"].append(r["some"])
        if r["avail"] is not None and total:
            acc[i]["mem"].append(max(0, total - r["avail"]) / 1024)
    pick = lambda k, f: [round(f(acc[i][k]), 2) if acc[i][k] else 0 for i in range(n)]
    avg = lambda v: sum(v) / len(v)
    series = {"cpu": pick("cpu", avg), "wait": pick("wait", max), "mem": pick("mem", max),
              "in": pick("in", sum), "out": pick("out", sum)}

    # the apps: now, their memory over the period against their ceiling, and where it's heading
    mrows = read_memory(state, now - 7 * 86400)
    limits = {a["name"]: a.get("limit_mb") for a in mem.get("apps") or []}
    apps = []
    for name, rs in mrows.items():
        if name not in NAMES or not rs or now - rs[-1]["t"] > 3600:
            continue
        last = rs[-1]
        spark, traffic = [None] * n, [None] * n
        for j, r in enumerate(rs):
            i = int((r["t"] - first) // step)
            if 0 <= i < n:
                spark[i] = max(spark[i] or 0, r["mb"])
                # MB in and out together in each bucket, for the traffic line
                pr = rs[j - 1] if j else None
                if pr and r["rx"] is not None and pr["rx"] is not None and r["tx"] is not None and pr["tx"] is not None:
                    d = (r["rx"] - pr["rx"] if r["rx"] >= pr["rx"] else r["rx"]) + (r["tx"] - pr["tx"] if r["tx"] >= pr["tx"] else r["tx"])
                    traffic[i] = round((traffic[i] or 0) + d, 1)
        net = transferred(rs, since)       # MB in and out over the period shown
        lim = limits.get(name)
        apps.append({"name": name, "label": nice(name), "mb": round(last["mb"]), "limit_mb": lim, "cpu": last["cpu"],
                     "net": net, "spark": spark, "traffic": traffic, "trend": app_trend(rs, lim)})
    apps.sort(key=lambda a: -a["mb"])

    dns = read_dns(state, now - 7 * 86400)
    piles = [r for r in srows_all if r["piles"]]
    day = defaultdict(int)
    for r in piles:
        day[datetime.fromtimestamp(r["t"]).strftime("%a %d %b")] += r["piles"]
    last = srows_all[-1] if srows_all else None
    return {
        "ok": True, "window": window, "labels": labels, "step": step, "series": series,
        "since": srows_all[0]["t"] if srows_all else None, "sampled": last["t"] if last else None,
        "now": {**lv, "mem_total_mb": total, "cores": ((hs or {}).get("system") or {}).get("cores"),
                "disk_used_mb": last["dused"] if last else None, "disk_size_mb": last["dsize"] if last else None},
        "ceilings_mb": sum(v for v in limits.values() if v),
        # the whole VM over the period, in MB (its counters are bytes)
        "net_mb": {k: round(v / 1048576) for k, v in (transferred(srows_all, since) or {}).items()} or None,
        "apps": apps,
        "disk": disk_trend(srows_all),
        "dns": {"piles_24h": sum(r["piles"] for r in piles if r["t"] >= now - 86400), "piles_7d": sum(r["piles"] for r in piles),
                "last_at": piles[-1]["t"] if piles else None, "days": [{"day": k, "n": v} for k, v in day.items()],
                "names": [{"name": k, "n": v, "who": who_asks(k)} for k, v in dns.most_common(5)]},
        "oom": [o for o in mem.get("oom") or [] if o.get("app") in NAMES],
    }


# ── the health checks (Home → Host), from the same numbers
def checks(state, hs, check):
    now = time.time()
    rows = read_system(state, now - 7 * 86400)
    day = [r for r in rows if r["t"] >= now - 86400]
    lv = live()
    out = []
    at = lambda t: datetime.fromtimestamp(t).strftime("%H:%M" if now - t < 86400 else "%a %H:%M")
    more = {"go": "stats/system", "label": "Details"}

    wait_now = lv.get("wait_some")
    worst = max(day, key=lambda r: r["some"]) if day else None
    if wait_now is not None and wait_now >= 10:
        out.append(check("Host", "Waiting for memory", "warn",
                         f"Apps spent {wait_now:.0f}% of the last minute waiting for memory: the VM is short of it right now. "
                         "Stats → System shows which app holds the most.", more))
    elif worst and worst["some"] >= 25:
        out.append(check("Host", "Waiting for memory", "warn",
                         f"At {at(worst['t'])} apps spent {worst['some']:.0f}% of five minutes waiting for memory — the VM was short "
                         "of it then. Stats → System shows who held what.", more))
    elif wait_now is not None or day:
        top = max([wait_now or 0] + [r["some"] for r in day])
        out.append(check("Host", "Waiting for memory", "ok",
                         "never in the last 24 hours" if top < 0.05 else f"at most {top:.1f}% of the time in the last 24 hours"))

    mem = (hs or {}).get("memory") or {}
    limits = {a["name"]: a.get("limit_mb") for a in mem.get("apps") or []}
    trends = {name: app_trend(rs, limits.get(name)) for name, rs in read_memory(state, now - 7 * 86400).items()
              if name in NAMES and rs and now - rs[-1]["t"] < 3600}
    soon = sorted(((n, t) for n, t in trends.items() if t.get("to_limit_days") is not None and t["to_limit_days"] <= 7),
                  key=lambda x: x[1]["to_limit_days"])
    growing = [(n, t) for n, t in trends.items() if t["state"] == "growing"]
    if soon:
        name, t = soon[0]
        d = datetime.fromtimestamp(now + t["to_limit_days"] * 86400)
        gap = (d.date() - datetime.fromtimestamp(now).date()).days
        when = "within hours" if t["to_limit_days"] < 0.5 else "today" if gap == 0 else "tomorrow" if gap == 1 else d.strftime("around %A")
        out.append(check("Host", "Memory trend", "warn",
                         f"{nice(name)} has grown about {t['per_day']} MB a day for {t['days']:g} days and reaches its "
                         f"{gb(limits.get(name) or 0)} ceiling {when}. Restarting it frees the memory for now.",
                         {"job": f"restart {name}", "label": f"Restart {nice(name)}"}))
    elif growing:
        out.append(check("Host", "Memory trend", "ok", "growing slowly: " + ", ".join(f"{nice(n)} about {t['per_day']} MB a day" for n, t in growing)))
    elif trends and all(t["state"] == "collecting" for t in trends.values()):
        left = max(t.get("left_h", 0) for t in trends.values())
        out.append(check("Host", "Memory trend", "ok", f"learning how the apps use memory (another {left} hours or so)"))
    elif trends:
        out.append(check("Host", "Memory trend", "ok", "no app keeps growing"))

    sw_total, sw_used = lv.get("swap_mb"), lv.get("swap_used_mb")
    if sw_total:
        held = [r["swap"] for r in day]
        if sw_used > 0.25 * sw_total and len(held) >= 100 and min(held) > 0.15 * sw_total:
            out.append(check("Host", "Swap", "warn",
                             f"{gb(sw_used)} of {gb(sw_total)} swap has stayed in use all day: the apps need more memory than the VM "
                             "has, and run slower for it. Give the VM more memory, or lower an app's ceiling in ninjarr.env.", more))
        else:
            out.append(check("Host", "Swap", "ok", f"{gb(sw_used)} of {gb(sw_total)} in use" if sw_used >= 1 else f"unused ({gb(sw_total)} ready)"))

    if rows:
        n24 = sum(r["piles"] for r in day)
        n7 = sum(r["piles"] for r in rows)
        if n24:
            last = max(r["t"] for r in day if r["piles"])
            names = read_dns(state, now - 86400).most_common(1)
            asked = (f", mostly for {names[0][0]}" + (f" ({who_asks(names[0][0])})" if who_asks(names[0][0]) else "")) if names else ""
            out.append(check("Host", "DNS", "warn",
                             f"Docker's DNS had more lookups waiting than it can hold {'once' if n24 == 1 else f'{n24} times'} today "
                             f"(last at {at(last)}){asked}. It often comes with memory running short.", more))
        else:
            out.append(check("Host", "DNS", "ok", "no pile-ups today" + (f" ({n7} earlier this week)" if n7 else "")))
    return out


def disk_note(state):
    """A few words for the Disk check: how fast it fills, and when it would be full."""
    t = disk_trend(read_system(state, time.time() - 7 * 86400))
    if t["state"] == "filling":
        if t["to_full_days"] > 90:
            return f"about {gb(t['per_day'])} more a day", t["to_full_days"]
        return f"filling about {gb(t['per_day'])} a day: full in about {t['to_full_days']} days", t["to_full_days"]
    if t["state"] == "steady":
        return ("not filling up" if t["per_day"] < 50 else f"about {gb(t['per_day'])} a day"), None
    return "", None
