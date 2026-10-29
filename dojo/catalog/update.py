#!/usr/bin/env python3
"""Refreshes Dojo's pick lists. Run by a maintainer, not by bootstrap.sh.

  providers.json  usenet providers: server, SSL port, connections, backbone, block account
                  source: https://usenet.rexum.space/api/providers (the list AIOStreams uses
                  for its backbone groupings)
  indexers.json   Newznab indexers Prowlarr has built-in definitions for: name, URL, API path
                  source: a running Prowlarr's /api/v1/indexer/schema

  python3 dojo/catalog/update.py http://localhost:9696 <prowlarr-api-key>
"""
import json, sys, urllib.request
from datetime import date
from pathlib import Path

HERE = Path(__file__).parent


def get(url, headers=None):
    req = urllib.request.Request(url, headers={"User-Agent": "ninjarr-catalog", **(headers or {})})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


def providers():
    out = {}
    for p in get("https://usenet.rexum.space/api/providers")["providers"]:
        servers = [s for s in p.get("server") or [] if s.get("nntp")]
        if not servers:
            continue
        s = next((x for x in servers if not x.get("ipv6")), servers[0])
        ssl = s.get("ports_ssl") or []
        conns = [c for c in s.get("connections") or [] if isinstance(c, int)]
        entry = {"name": p["name"].strip(), "host": s["nntp"].strip().lower(),
                 "port": 563 if 563 in ssl else (ssl[0] if ssl else 119), "tls": bool(ssl),
                 "connections": min(conns) if conns else 20, "backbone": s.get("backbone") or "",
                 "block": bool(p.get("block")), "url": p.get("url") or ""}
        out[entry["name"].lower()] = entry
    return sorted(out.values(), key=lambda e: e["name"].lower())


def indexers(prowlarr, key):
    out = []
    for d in get(prowlarr.rstrip("/") + "/api/v1/indexer/schema", {"X-Api-Key": key}):
        if d.get("protocol") != "usenet" or d.get("implementation") != "Newznab" or d.get("name") == "Generic Newznab":
            continue
        f = {x["name"]: x.get("value") for x in d.get("fields") or []}
        if f.get("baseUrl"):
            out.append({"name": d["name"], "url": f["baseUrl"].rstrip("/"), "apiPath": f.get("apiPath") or "/api"})
    return sorted(out, key=lambda e: e["name"].lower())


if __name__ == "__main__":
    stamp = str(date.today())
    (HERE / "providers.json").write_text(json.dumps({"updated": stamp, "source": "usenet.rexum.space", "providers": providers()}, indent=0, ensure_ascii=False) + "\n")
    if len(sys.argv) == 3:
        (HERE / "indexers.json").write_text(json.dumps({"updated": stamp, "source": "Prowlarr indexer definitions", "indexers": indexers(*sys.argv[1:])}, indent=0) + "\n")
    print("done")
