"""Newer app images than ninjarr runs: used by Dojo (System → "Newer app versions") and by the
nightly version bot (ci/newer_versions.py). Standard library only, so the bot needs nothing else.

The newest tag is one shaped like the one in use (same pattern, bigger numbers), so a stable release
never moves to a nightly, and LinuxServer's "-lsNNN" rebuilds count too."""
import json
import re
import urllib.request

REPOS = {"aiostreams": "viren070/aiostreams", "seerr": "seerr-team/seerr", "dispatcharr": "dispatcharr/dispatcharr",
         "prowlarr": "linuxserver/prowlarr", "sonarr": "linuxserver/sonarr", "radarr": "linuxserver/radarr",
         "bazarr": "linuxserver/bazarr", "emby": "linuxserver/emby"}


def vkey(tag):
    return tuple(int(x) for x in re.findall(r"\d+", tag))


def _get(url, token=None, timeout=20):
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"} if token else {})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r), r.headers.get("Link", "")


def newest(repo, current, pages=40):
    """The newest tag on ghcr.io like `current`, if it's newer; None otherwise. Raises on network errors."""
    pat = re.compile("^" + re.sub(r"\d+", r"\\d+", re.escape(current)) + "$")
    token = _get(f"https://ghcr.io/token?scope=repository:{repo}:pull")[0]["token"]
    url, tags = f"/v2/{repo}/tags/list?n=1000", []
    for _ in range(pages):
        data, link = _get("https://ghcr.io" + url, token)
        tags += [t for t in data.get("tags") or [] if pat.match(t)]
        m = re.search(r"<([^>]+)>", link)
        if not m:
            break
        url = m.group(1)
    best = max(tags, key=vkey, default=None)
    return best if best and vkey(best) > vkey(current) else None
