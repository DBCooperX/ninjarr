#!/usr/bin/env bash
# Replays a canned bootstrap.sh run for the README's demo GIF (docs/demo.gif, built via
# docs/demo.tape + VHS). Not part of the stack itself — makes no network/docker calls, just
# reuses bootstrap.sh's real palette and output style so the recording matches the real thing.
set -Eeuo pipefail

DR=$'\033[38;5;124m'; W=$'\033[38;5;255m'
D=$'\033[38;5;244m'; G=$'\033[38;5;78m'
B=$'\033[1m'; X=$'\033[0m'
BLADE=(196 202 160 124 88 52)
STAR="✦"; TICK="✔"

step() { printf '\n%s%s[%s/7]%s %s%s%s\n' "$DR" "$B" "$1" "$X" "$W$B" "$2" "$X"; }
ok()   { printf '   %s%s%s %s\n' "$G" "$TICK" "$X" "$1"; sleep 0.28; }
rule() { printf '   %s────────────────────────────────────────────────%s\n' "$D" "$X"; }
row()  { printf '   %s%-14s%s %shttp://%s:%s%s\n' "$W" "$1" "$X" "$D" "$2" "$3" "$X"; sleep 0.16; }

art=(
  '  ███╗   ██╗██╗███╗   ██╗     ██╗ █████╗ ██████╗ ██████╗ '
  '  ████╗  ██║██║████╗  ██║     ██║██╔══██╗██╔══██╗██╔══██╗'
  '  ██╔██╗ ██║██║██╔██╗ ██║     ██║███████║██████╔╝██████╔╝'
  '  ██║╚██╗██║██║██║╚██╗██║██   ██║██╔══██║██╔══██╗██╔══██╗'
  '  ██║ ╚████║██║██║ ╚████║╚█████╔╝██║  ██║██║  ██║██║  ██║'
  '  ╚═╝  ╚═══╝╚═╝╚═╝  ╚═══╝ ╚════╝ ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝'
)
printf '\n'
for i in "${!art[@]}"; do
  printf '\033[38;5;%sm%s\033[0m\n' "${BLADE[i]}" "${art[i]}"
  sleep 0.07
done
printf '  %s%s%s  %sthe stack that wires itself%s   %sv0.1.0%s\n' "$DR" "$STAR" "$X" "$D" "$X" "$D" "$X"
sleep 0.9

step 2 "Reading the terrain"
ok "downloads /data/downloads owned by 1000:1000 (ext4)"
ok "media /data/media owned by 1000:1000 (ext4)"
ok "downloads and media share one filesystem — imports hardlink instantly"
sleep 0.8

step 6 "Tying it all together"
ok "SABnzbd categories tv, movies wired"
ok "Sonarr → SABnzbd, root folder, TRaSH quality profile"
ok "Radarr → SABnzbd, root folder, TRaSH quality profile"
ok "Bazarr → Sonarr, Radarr, German-first languages profile"
ok "Prowlarr → Sonarr, Radarr synced"
sleep 0.8

step 7 "Mission report"
rule
printf '   %-14s %s\n' "SERVICE" "URL"
rule
row Seerr    10.0.0.42 5055
row Sonarr   10.0.0.42 8989
row Radarr   10.0.0.42 7878
row Prowlarr 10.0.0.42 9696
row SABnzbd  10.0.0.42 8080
row Bazarr   10.0.0.42 6767
row Dojo     10.0.0.42 1337
rule

title=" ✦ MISSION COMPLETE ✦ "
border="══════════════════════"
printf '\n   %s╔%s╗%s\n' "$DR" "$border" "$X"
printf   '   %s║%s%s%s%s%s║%s\n' "$DR" "$X" "$W$B" "$title" "$X" "$DR" "$X"
printf   '   %s╚%s╝%s\n\n' "$DR" "$border" "$X"
sleep 2.5
