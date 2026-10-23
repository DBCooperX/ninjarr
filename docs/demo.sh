#!/usr/bin/env bash
# Replays a first bootstrap.sh run for the README's demo (docs/demo.gif). Not part of the
# stack: no network, no Docker, nothing written. It sources the real lib/ui.sh, so banner,
# spinner, prompts and colours are exactly what a real run shows; the answers are typed out
# and the wiring lines are canned copies of a real run's output.
#
# Record it with VHS (brew install vhs):  vhs docs/demo.tape
set -Eeuo pipefail
cd "$(dirname "$(readlink -f "$0")")/.."

# shellcheck disable=SC2034  # read by lib/ui.sh
NINJARR_VERSION="1.0.0"; STEP_TOTAL=6; LOG=/dev/null
# shellcheck source=lib/ui.sh
. lib/ui.sh

pause() { sleep "${1:-0.4}"; }
slow_ok() { ok "$1"; sleep "${2:-0.12}"; }
slow_info() { info "$1"; sleep "${2:-0.12}"; }
work() { spin "$1" sleep "$2"; }   # the real spinner, wrapped around a sleep

# typed "prompt" "default" "answer" — the same prompt line ask() prints, then keystrokes
typed() {
  if [[ -n "$2" ]]; then
    printf '   %s%s%s %s %s[%s]%s ' "$DR" "$ARROW" "$X" "$1" "$DD" "$2" "$X"
  else
    printf '   %s%s%s %s ' "$DR" "$ARROW" "$X" "$1"
  fi
  pause 0.45
  local i
  for ((i = 0; i < ${#3}; i++)); do printf '%s' "${3:i:1}"; sleep 0.055; done
  pause 0.2; printf '\n'
}
secret() { printf '   %s%s%s %s ' "$DR" "$ARROW" "$X" "$1"; pause 1.1; printf '\n'; }
yesno()  { local hint="[y/N]"; [[ "$2" == y ]] && hint="[Y/n]"; typed "$1 $DD$hint$X" "" "$3"; }

banner
pause 0.6

step "Checking the dojo"
slow_ok "Debian GNU/Linux 13 (trixie)"
slow_ok "virtualisation: kvm"
slow_ok "curl, jq, openssl, sqlite3"
slow_info "Docker isn't installed yet — using Docker's official install script"
work "installing Docker (a few minutes)" 2.2
slow_ok "docker 29.1.3, compose 5.0.1"
slow_ok "FUSE available"
slow_ok "8 GB RAM"
slow_ok "61 GB free disk"
pause 0.5

step "Setup in your browser"
work "building Dojo" 1.4
work "starting Dojo" 0.8
work "Dojo is up" 0.6
printf '\n   %s┌──────────────────────────────────────────────┐%s\n' "$DR" "$X"
printf   '   %s│%s  open   %s%-37s%s%s│%s\n' "$DR" "$X" "$W$B" "http://192.168.1.50:1337" "$X" "$DR" "$X"
printf   '   %s│%s  code   %s%-37s%s%s│%s\n' "$DR" "$X" "$W$B" "482913" "$X" "$DR" "$X"
printf   '   %s└──────────────────────────────────────────────┘%s\n' "$DR" "$X"
note "keep this terminal open — the build runs here once you press Build on the page"
note "rather answer in the terminal? Ctrl-C, then ./bootstrap.sh --terminal"
printf '\n'
# the browser part happens now: login, provider and indexer tested, language, extras, Build
pause 4.5
printf '\n'
STEP_N=0
step "Checking the dojo"
slow_ok "Debian GNU/Linux 13 (trixie)" 0.05
slow_ok "docker 29.1.3, compose 5.0.1" 0.05
step "Reading ninjarr.env"
slow_ok "found — nothing to ask"
pause 0.3
step "Laying out the dojo"
slow_ok "data in /opt/ninjarr (library, app configs, stream mount point)"
slow_info "making /opt/ninjarr/stream a shared mount (was: private)"
slow_ok "mount propagation shared at /opt/ninjarr/stream"
slow_ok "sonarr: API key pre-set"
slow_ok "radarr: API key pre-set"
slow_ok "prowlarr: API key pre-set"
slow_ok "nightly backup at ~04:30 into /opt/ninjarr/backups, keeping 7"
slow_ok "AIOStreams configured (1 usenet provider(s), library mount, Sonarr/Radarr links)"
pause 0.4

step "Summoning the clan"
work "pulling images (the slow bit, ~5 GB the first time)" 2.8
work "building Dojo Monitor" 1.2
work "starting containers" 1.0
slow_ok "8 containers running"
pause 0.4

step "Tying it all together"
for app in AIOStreams Sonarr Radarr Prowlarr Emby Seerr Bazarr Dojo; do work "$app is up" 0.25; done
slow_ok "library mount visible in Sonarr at /mnt/aiostreams"
heading "Emby"
slow_ok "Emby: setup done, admin admin" 0.08
slow_ok "Emby: API key for ninjarr" 0.08
slow_ok "Emby: libraries Movies, TV Shows" 0.08
for app in Sonarr Radarr; do
  heading "$app"
  slow_ok "$app: login admin" 0.07
  slow_ok "$app: download client AIOStreams" 0.07
  slow_ok "$app: quality profile 'ninjarr' — German first (+1000), 2160p +200, AV1 -300, junk blocked" 0.07
  slow_ok "$app: waits 60 min for German, grabs German at once" 0.07
  slow_ok "$app: Emby library updates on import" 0.07
done
heading "Prowlarr"
slow_ok "Prowlarr → Sonarr, Radarr (full sync)" 0.08
slow_ok "Prowlarr: indexer My Indexer (redirect on)" 0.08
heading "Seerr"
slow_ok "Seerr: signed in through Emby, libraries enabled" 0.08
slow_ok "Seerr → Sonarr, Radarr (profile ninjarr)" 0.08
heading "Bazarr"
slow_ok "Bazarr: languages profile DE+EN, connected to Sonarr and Radarr" 0.08
slow_ok "Bazarr: subtitle providers gestdown, podnapisi" 0.08
pause 0.5

step "Mission report"
rule
printf '   %s%-12s %-34s%s\n' "$D" "APP" "ON YOUR NETWORK" "$X"
rule
for line in "Dojo 1337" "Seerr 5055" "Prowlarr 9696" "Sonarr 8989" "Radarr 7878" "AIOStreams 3000" "Emby 8096" "Bazarr 6767"; do
  read -r name port <<<"$line"
  printf '   %s%-12s%s %s\n' "$W" "$name" "$X" "http://192.168.1.50:$port"; sleep 0.07
done
rule
printf '   %-12s %s\n' "login" "admin / (the password you chose)"
printf '\n   %s•%s Request something in Seerr — it lands in Emby within a minute or two\n' "$DR" "$X"
printf '\n   %s╔══════════════════════╗%s\n' "$DR" "$X"
printf   '   %s║%s%s ✦ MISSION COMPLETE ✦ %s%s║%s\n' "$DR" "$X" "$W$B" "$X" "$DR" "$X"
printf   '   %s╚══════════════════════╝%s\n\n' "$DR" "$X"
sleep 4
