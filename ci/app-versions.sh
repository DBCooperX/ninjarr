#!/usr/bin/env bash
# ninjarr's version bot, run by .github/workflows/app-versions.yml (as root on a fresh runner):
# builds the whole stack with today's versions, tries every newer app image the same way Dojo's
# "Try it" does (snapshot, upgrade, full check, roll back on failure), keeps the ones that pass,
# then rebuilds with all of them together and checks once more, including that an AIOStreams outage
# can't cost the library anything (ci/outage-check.sh). Leaves the passing versions in
# versions.env and a release note in .state/release-note.txt; exits 0 with nothing to release
# when no newer version passed.
#
# No real usenet provider or indexer is needed: the check looks at the apps and their wiring, and
# a made-up provider only gives warnings.
set -Eeuo pipefail
cd "$(dirname "$(readlink -f "$0")")/.."
ROOT=$PWD

say() { printf '\n== %s\n' "$*"; }

# 1. a ninjarr.env for a stack nobody watches with: test login, made-up provider, live TV on
say "test ninjarr.env"
cp ninjarr.env.example ninjarr.env
sed -i -e "s/^ADMIN_PASSWORD=.*/ADMIN_PASSWORD='ci-$(openssl rand -hex 8)'/" \
       -e "s/^INDEXERS=.*/INDEXERS='[]'/" \
       -e "s/^IPTV=.*/IPTV='yes'/" \
       -e "s|^USENET_PROVIDERS=.*|USENET_PROVIDERS='[{\"id\":\"p1\",\"name\":\"news.example.com\",\"host\":\"news.example.com\",\"port\":563,\"tls\":true,\"username\":\"ci\",\"password\":\"ci\",\"maxConnections\":4,\"priority\":0,\"isBackup\":false,\"enabled\":true}]'|" \
       ninjarr.env
export NINJARR_UNATTENDED=1

# 2. today's versions, built and checked
say "building with today's versions"
./bootstrap.sh
./bootstrap.sh doctor

# 3. each newer version on its own; a failing one rolls back and is left out
mapfile -t found < <(python3 ci/newer_versions.py versions.env)
(( ${#found[@]} )) || { say "nothing newer"; exit 0; }
passed=() failed=()
for line in "${found[@]}"; do
  read -r app tag <<<"$line"
  say "trying $app $tag"
  if ./bootstrap.sh try-version "$app" "$tag"; then passed+=("$app $tag"); else failed+=("$app $tag"); fi
done
(( ${#passed[@]} )) || { say "no newer version passed: ${failed[*]}"; exit 0; }

# 4. all passing versions together, from versions.env this time, checked once more
say "all together: ${passed[*]}"
note=""
for line in "${passed[@]}"; do
  read -r app tag <<<"$line"
  old=$(sed -n "s/^${app^^}_TAG='\(.*\)'.*/\1/p" versions.env)
  sed -i "s/^${app^^}_TAG='.*'/${app^^}_TAG='$tag'/" versions.env
  sed -i "/^${app^^}_TAG=/d" ninjarr.env
  note+="- ${app}: ${old} → ${tag}"$'\n'
done
rm -rf .state/tries
./bootstrap.sh
./bootstrap.sh doctor

# 5. an AIOStreams outage must not cost the library anything with these versions
say "outage check"
if ! ci/outage-check.sh; then
  git checkout -- versions.env
  say "not released: with these versions an AIOStreams outage would lose library items (see above)"
  exit 1
fi

for line in "${failed[@]}"; do note+="- left out, didn't pass the check: ${line}"$'\n'; done
printf '%s' "$note" >"$ROOT/.state/release-note.txt"
say "release note"; cat "$ROOT/.state/release-note.txt"
