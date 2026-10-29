# shellcheck shell=bash
# ninjarr — terminal chrome: palette, banner, step/ok/warn lines, spinner and prompts.
# Sourced by bootstrap.sh; never run on its own.

# Colour on a terminal, and in Dojo's job log (NINJARR_COLOR=1, which Dojo shows in colour);
# animation (spinners, the banner drawn line by line) only on a live terminal.
if [[ -z "${NO_COLOR:-}" ]] && { [[ -t 1 ]] || [[ "${NINJARR_COLOR:-}" == 1 ]]; }; then
  R=$'\033[38;5;196m'; DR=$'\033[38;5;202m'; W=$'\033[38;5;255m'
  D=$'\033[38;5;244m'; DD=$'\033[38;5;238m'; G=$'\033[38;5;78m'
  Y=$'\033[38;5;221m'; B=$'\033[1m'; X=$'\033[0m'
  COLOR=1
else
  R=""; DR=""; W=""; D=""; DD=""; G=""; Y=""; B=""; X=""
  COLOR=0
fi
ANIMATE=0; [[ "$COLOR" == 1 && -t 1 ]] && ANIMATE=1

STAR="✦"; TICK="✔"; CROSS="✖"; ARROW="▸"
STEP_N=0; STEP_TOTAL=${STEP_TOTAL:-8}

# A shuriken flicker between steps. A no-op when output isn't a live terminal, so a log or CI
# run never waits on it or collects control codes.
shuriken() {
  [[ "$ANIMATE" == "1" ]] || return 0
  local n=${1:-10} frames=('✦' '✧' '✶' '✷' '✸' '✹' '✺' '✳') i
  for ((i = 0; i < n; i++)); do
    printf '\r   %s%s%s' "$DR" "${frames[i % ${#frames[@]}]}" "$X"
    sleep 0.035
  done
  printf '\r\033[K'
}

# The ninjarr logo, symbol and name, drawn with half blocks (two pixels per character cell).
# Each letter in a row is one pixel, the colour from pal (a = first), "." empty. Made from
# dojo/static/logo.png; a terminal without colour gets one plain line instead.
banner() {
  printf '\n'
  if [[ "$COLOR" != "1" ]]; then
    printf '  ninjarr — the stack that wires itself   v%s\n\n' "$NINJARR_VERSION"
    return 0
  fi
  shuriken 14
  local pal=(166 166 172 202 208 231 253 254 255)
  local -a px=(
    '........bd....eee..........................................................'
    '.....ee..bdee...eee........................................................'
    '....ee.db.bdee..b.ee.......................................................'
    '...e.dd....ddded.dd.e......................................................'
    '..e.bd.....bedddb.dd.e.....................................................'
    '.ee.d..b...bdeddd..d.ce....................................................'
    '.e.d..db...beeebdd..d................hh...........gf.......................'
    '.e..bdd...bdeeeb.bb.bb...............hh...........hf.......................'
    'eb.bdddbbddeeeeb.......b...................................................'
    'e..ddddeeeeeeeed......d....gifffffh..ih..hfffffi..hf..ddddddd..bddddb.ddddd'
    '..dddeeeee.e..eda....bd....hi....hf..hh.hfh...hfh.hf.......bdb.dd....bdb...'
    '..ededdeee....eedbabbdd....ih.....f..hh.hf.....ih.hf...dbbdbdb.dd....bd....'
    '.eebbbbdeee...eeeddeed.....ih.....f..ih.if.....ih.hf..ddbbdbdb.dd....bd....'
    '.eb....bde....eeeeeddd.....ih.....f..ih.hf.....hh.hf..db....dd.dd....bd....'
    '.d......dceeeeedeeddd..e...fh.....fh.ih.hf.....ih.hf..dddddddb.dd....bd....'
    'b.......beeeeddbbbddb..e..........................hf.......................'
    '..bb.bb.beeeda...ddb..ee.........................ihf.......................'
    '...b..dddeeeb...bd..d.e.........................gfih.......................'
    '.ee.d..dddedb...b..d.ee....................................................'
    '..e.bd..ddded.....db.e.....................................................'
    '...e.dd..dddd....dd.e......................................................'
    '....ee.b..deed..d.ee.......................................................'
    '.....eee....edd..ce........................................................'
    '.......eee....eb...........................................................'
  )
  local -A c=() ; local i y x t b line abc=abcdefghijklmnopqrstuvwxyz
  for i in "${!pal[@]}"; do c[${abc:i:1}]=${pal[i]}; done
  for ((y = 0; y < ${#px[@]}; y += 2)); do
    line='  '
    for ((x = 0; x < ${#px[y]}; x++)); do
      t=${px[y]:x:1}; b=${px[y+1]:x:1}
      if [[ $t == . && $b == . ]]; then line+=' '; continue; fi
      if [[ $t == . ]]; then line+=$'\033[38;5;'"${c[$b]}m▄"
      elif [[ $b == . ]]; then line+=$'\033[38;5;'"${c[$t]}m▀"
      elif [[ $b == "$t" ]]; then line+=$'\033[38;5;'"${c[$t]}m█"
      else line+=$'\033[38;5;'"${c[$t]};48;5;${c[$b]}m▀"$'\033[49m'
      fi
    done
    line+=$X
    printf '%s\n' "$line"
    [[ "$ANIMATE" == 1 ]] && sleep 0.03
  done
  printf '\n  %s%s%s  %sthe stack that wires itself%s   %sv%s%s\n\n' \
    "$DR" "$STAR" "$X" "$D" "$X" "$DD" "$NINJARR_VERSION" "$X"
}

step()  { STEP_N=$((STEP_N+1)); shuriken 4; printf '\n%s%s[%d/%d]%s %s%s%s\n' "$DR" "$B" "$STEP_N" "$STEP_TOTAL" "$X" "$W$B" "$1" "$X"; }
ok()    { printf '   %s%s%s %s\n' "$G" "$TICK" "$X" "$1"; }
info()  { printf '   %s%s%s %s\n' "$D" "$ARROW" "$X" "$1"; }
warn()  { printf '   %s%s%s %s\n' "$Y" "!" "$X" "$1"; WARNINGS=$(( ${WARNINGS:-0} + 1 )); }
die()   { printf '\n   %s%s%s %s%s%s\n\n' "$R" "$CROSS" "$X" "$R" "$1" "$X"; exit 1; }
rule()  { printf '   %s────────────────────────────────────────────────%s\n' "$DD" "$X"; }
note()  { printf '     %s%s%s\n' "$DD" "$1" "$X"; }
heading() { printf '\n   %s%s%s%s\n' "$W" "$B" "$1" "$X"; }

# spin "message" command [args...] — runs the command with output to the log. A failure shows ✖,
# or "!" with SOFT=1 in front, for steps whose failure the caller checks and explains itself.
spin_failed() { if [[ "${SOFT:-0}" == 1 ]]; then printf '   %s!%s %s\n' "$Y" "$X" "$1"; else printf '   %s%s%s %s\n' "$R" "$CROSS" "$X" "$1"; fi; }
spin() {
  local msg="$1"; shift
  if [[ "$ANIMATE" != "1" ]]; then
    if "$@" >>"$LOG" 2>&1; then ok "$msg"; return 0; else spin_failed "$msg"; return 1; fi
  fi
  local frames=('✦' '✧' '✶' '✷' '✸' '✹' '✺' '✳') i=0
  "$@" >>"$LOG" 2>&1 &
  local pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    printf '\r   %s%s%s %s' "$DR" "${frames[i]}" "$X" "$msg"
    i=$(( (i+1) % ${#frames[@]} )); sleep 0.08
  done
  local rc=0; wait "$pid" || rc=$?
  printf '\r\033[K'
  if [[ $rc -eq 0 ]]; then ok "$msg"; else spin_failed "$msg"; return $rc; fi
}

# All prompts read from the terminal, not stdin, so `curl … | bash` style runs still work.
TTY=/dev/tty
[[ -r "$TTY" ]] || TTY=/dev/stdin

ask() { # ask VAR "prompt" "default"
  local __v=$1 __p=$2 __d=${3:-} __in
  if [[ -n "$__d" ]]; then
    printf '   %s%s%s %s %s[%s]%s ' "$DR" "$ARROW" "$X" "$__p" "$DD" "$__d" "$X"
  else
    printf '   %s%s%s %s ' "$DR" "$ARROW" "$X" "$__p"
  fi
  read -r __in <"$TTY" || true
  printf -v "$__v" '%s' "${__in:-$__d}"
}

ask_required() { # ask_required VAR "prompt" "default" — repeats until non-empty
  local __v=$1
  while :; do
    ask "$@"
    [[ -n "${!__v}" ]] && return 0
    printf '     %sthis one is needed%s\n' "$Y" "$X"
  done
}

ask_secret() { # ask_secret VAR "prompt" — hidden input; empty keeps the current value
  local __v=$1 __p=$2 __in
  printf '   %s%s%s %s ' "$DR" "$ARROW" "$X" "$__p"
  read -rs __in <"$TTY" || true
  printf '\n'
  [[ -n "$__in" ]] && printf -v "$__v" '%s' "$__in"
  return 0
}

confirm() { # confirm "question" [default y|n]
  local __in __def=${2:-n} __hint="[y/N]"
  [[ "$__def" == y ]] && __hint="[Y/n]"
  printf '   %s%s%s %s %s%s%s ' "$DR" "$ARROW" "$X" "$1" "$DD" "$__hint" "$X"
  read -r __in <"$TTY" || true
  __in=${__in:-$__def}
  [[ "${__in,,}" == y* ]]
}
