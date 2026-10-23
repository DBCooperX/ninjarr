# shellcheck shell=bash
# ninjarr — shared plumbing: HTTP helpers, waiting, secrets, the env file.

# api METHOD URL [JSON] — for the *arr apps (X-Api-Key header). Prints the body on 2xx.
# API_KEY must be set by the caller (arr_use does that).
api() {
  local m=$1 url=$2 body=${3:-} out code resp
  local -a args=(-sS --max-time 60 -w $'\n%{http_code}' -X "$m" "$url" -H "X-Api-Key: ${API_KEY:-}")
  [[ -n "$body" ]] && args+=(-H 'Content-Type: application/json' --data-binary "$body")
  out=$(curl "${args[@]}" 2>>"$LOG") || { printf 'API %s %s -> curl failed\n\n' "$m" "$url" >>"$LOG"; return 1; }
  code=${out##*$'\n'}; resp=${out%$'\n'*}
  if [[ "$code" =~ ^2 ]]; then printf '%s' "$resp"; return 0; fi
  printf 'API %s %s -> HTTP %s\n%s\n%s\n\n' "$m" "$url" "$code" "${body:0:2000}" "${resp:0:2000}" >>"$LOG"
  return 1
}

# http METHOD URL [JSON] [extra curl args...] — plain JSON HTTP with no auth header
http() {
  local m=$1 url=$2 body=${3:-} out code resp; shift 3 2>/dev/null || shift $#
  local -a args=(-sS --max-time 60 -w $'\n%{http_code}' -X "$m" "$url" "$@")
  [[ -n "$body" ]] && args+=(-H 'Content-Type: application/json' --data-binary "$body")
  out=$(curl "${args[@]}" 2>>"$LOG") || { printf 'HTTP %s %s -> curl failed\n\n' "$m" "$url" >>"$LOG"; return 1; }
  code=${out##*$'\n'}; resp=${out%$'\n'*}
  if [[ "$code" =~ ^2 ]]; then printf '%s' "$resp"; return 0; fi
  printf 'HTTP %s %s -> HTTP %s\n%s\n\n' "$m" "$url" "$code" "${resp:0:2000}" >>"$LOG"
  return 1
}

# wait_http NAME URL [TIMEOUT] — polls until the URL answers 2xx/3xx
wait_http() {
  local name=$1 url=$2 timeout=${3:-180} t=0
  local frames=('✦' '✧' '✶' '✷' '✸' '✹' '✺' '✳') i=0
  while (( t < timeout )); do
    if curl -fsS --max-time 3 -o /dev/null "$url" 2>/dev/null; then
      [[ "$ANIMATE" == "1" ]] && printf '\r\033[K'
      ok "$name is up"; return 0
    fi
    if [[ "$ANIMATE" == "1" ]]; then
      printf '\r   %s%s%s waiting for %s %s(%ds)%s' "$DR" "${frames[i]}" "$X" "$name" "$DD" "$t" "$X"
      i=$(( (i+1) % ${#frames[@]} ))
    fi
    sleep 2; t=$((t+2))
  done
  [[ "$ANIMATE" == "1" ]] && printf '\r\033[K'
  warn "$name did not answer within ${timeout}s"
  return 1
}

gen_hex()  { openssl rand -hex "${1:-16}"; }                 # 16 bytes = 32 hex chars, the *arr key format
gen_pass() { openssl rand -base64 24 | tr -d '/+=' | cut -c1-24; }

# ─────────────────────────────────────────────── env file
# ninjarr.env holds every answer and every generated secret. Values are single-quoted, which both
# bash (when sourced) and Docker Compose (as an env file) read literally — $, #, spaces and JSON
# all survive. The one character that can't appear in a value is the single quote itself; the
# wizard refuses it up front.

ENV_KEYS=()  # order in which keys were first set, so the file stays readable

env_set() { # env_set KEY VALUE — set in memory; written by env_save
  local k=$1 v=$2
  [[ "$v" == *"'"* ]] && die "value for $k contains a single quote ('), which ninjarr cannot store safely"
  printf -v "$k" '%s' "$v"
  export "${k?}"
  local x; for x in "${ENV_KEYS[@]}"; do [[ "$x" == "$k" ]] && return 0; done
  ENV_KEYS+=("$k")
}

env_load() {
  [[ -f "$ENV_FILE" ]] || return 1
  local line k
  while IFS= read -r line; do
    [[ "$line" =~ ^([A-Z0-9_]+)= ]] || continue
    k=${BASH_REMATCH[1]}
    local x found=0; for x in "${ENV_KEYS[@]}"; do [[ "$x" == "$k" ]] && found=1; done
    (( found )) || ENV_KEYS+=("$k")
  done <"$ENV_FILE"
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
}

env_save() {
  local tmp k
  tmp=$(mktemp "$ENV_FILE.XXXX")
  {
    printf '# ninjarr %s — written %s\n' "$NINJARR_VERSION" "$(date -Iseconds)"
    printf '# Every answer and every generated secret for this stack. Keep it private and keep a copy:\n'
    printf '# with this file and a fresh VM, ./bootstrap.sh rebuilds the whole stack unattended.\n'
    printf '# Edit values here, then run ./bootstrap.sh again to apply them.\n\n'
    for k in "${ENV_KEYS[@]}"; do printf "%s='%s'\n" "$k" "${!k}"; done
  } >"$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$ENV_FILE"
}

# env_default KEY VALUE — set only if not already set (from the file or the environment)
env_default() { [[ -n "${!1:-}" ]] && { env_set "$1" "${!1}"; return 0; }; env_set "$1" "$2"; }

# The host's primary LAN address, for URLs in the summary and AIOStreams' BASE_URL
host_ip() {
  local ip=""
  [[ -n "${NINJARR_HOST_IP:-}" ]] && { printf '%s' "$NINJARR_HOST_IP"; return 0; }
  if command -v ip >/dev/null; then
    ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}') || true
  fi
  [[ -n "$ip" ]] || ip=$(hostname -I 2>/dev/null | awk '{print $1}') || true
  printf '%s' "${ip:-localhost}"
}
