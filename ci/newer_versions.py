#!/usr/bin/env python3
"""Prints the apps that have a newer image than versions.env pins, one "app tag" per line.
The search itself is Dojo's (dojo/upstream.py), so the bot and Dojo always agree.

A LinuxServer rebuild of the very same app version (only "-lsNNN" moved: a refreshed base system,
security fixes in its libraries) isn't worth a release of its own. Those are only printed when a
real version change goes out anyway, on Sundays, or when VERSION_BOT_ALL=1 (a run started by hand),
so they reach everyone within a week without an update every few days."""
import datetime
import os
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "dojo"))
from upstream import REPOS, newest  # noqa: E402


def rebuild_only(old, new):
    """Same app version, only LinuxServer's build number moved: 6.4.4.10685-ls324 → -ls325."""
    a, b = re.fullmatch(r"(.+)-ls\d+", old), re.fullmatch(r"(.+)-ls\d+", new)
    return bool(a and b and a.group(1) == b.group(1))


def main():
    versions = Path(sys.argv[1] if len(sys.argv) > 1 else "versions.env").read_text()
    found = []
    for app, repo in REPOS.items():
        m = re.search(rf"^{app.upper()}_TAG='([^']+)'", versions, re.M)
        if not m:
            continue
        try:
            new = newest(repo, m.group(1))
        except Exception as e:  # a registry hiccup skips this app tonight, it doesn't stop the others
            print(f"{app}: couldn't check ({e})", file=sys.stderr)
            continue
        if new:
            found.append((app, new, rebuild_only(m.group(1), new)))
    real = [f for f in found if not f[2]]
    weekly = os.environ.get("VERSION_BOT_ALL") == "1" or datetime.datetime.now(datetime.timezone.utc).isoweekday() == 7
    for app, new, rebuild in found:
        if rebuild and not (real or weekly):
            print(f"{app} {new}: only a rebuild of the same version, waits for Sunday or a real update", file=sys.stderr)
            continue
        print(app, new)


if __name__ == "__main__":
    main()
