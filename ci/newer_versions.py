#!/usr/bin/env python3
"""Prints the apps that have a newer image than versions.env pins, one "app tag" per line.
The search itself is Dojo's (dojo/upstream.py), so the bot and Dojo always agree."""
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "dojo"))
from upstream import REPOS, newest  # noqa: E402


def main():
    versions = Path(sys.argv[1] if len(sys.argv) > 1 else "versions.env").read_text()
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
            print(app, new)


if __name__ == "__main__":
    main()
