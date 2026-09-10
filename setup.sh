#!/bin/bash
# Interactive configuration for the dsh box. Writes config.env.
#
# Asks as little as possible: it probes for your model server, reads the model
# list from it, checks ports and subnets against what your Mac already uses,
# and only asks when it genuinely cannot tell. Re-run it any time; your current
# answers become the defaults.
#
# Nothing here touches the system. setup-host.sh does that, afterwards.
set -uo pipefail
cd "$(dirname "$0")"

if ! { exec 3</dev/tty; } 2>/dev/null; then
  echo "setup.sh needs a terminal." >&2
  echo "Copy config.example.env to config.env and edit it by hand instead." >&2
  exit 1
fi

# Checked up front because the failure is misleading otherwise: with no jq the
# model probe returns nothing, which reads as "this server has no models".
if ! command -v jq >/dev/null 2>&1; then
  echo "setup.sh needs jq to read the model list from your server." >&2
  echo "Install it with:  brew install jq" >&2
  exit 1
fi

# Both write to stderr: settle_port runs inside $( ), where anything on stdout
# is captured into the value instead of printed, silently corrupting config.env.
bold() { printf '\033[1m%s\033[0m\n' "$*" >&2; }
dim()  { printf '\033[2m%s\033[0m\n' "$*" >&2; }

# ask PROMPT DEFAULT -> echoes the answer
ask() {
  local prompt="$1" default="${2:-}" reply
  if [ -n "$default" ]; then
    printf '%s [%s]: ' "$prompt" "$default" >&2
  else
    printf '%s: ' "$prompt" >&2
  fi
  read -r reply <&3 || reply=""
  printf '%s' "${reply:-$default}"
}

yes_no() {
  local prompt="$1" default="${2:-y}" reply
  printf '%s [%s/%s]: ' "$prompt" "$([ "$default" = y ] && echo Y || echo y)" "$([ "$default" = y ] && echo n || echo N)" >&2
  read -r reply <&3 || reply=""
  reply="${reply:-$default}"
  [ "${reply:0:1}" = y ] || [ "${reply:0:1}" = Y ]
}

port_free() { ! nc -z 127.0.0.1 "$1" >/dev/null 2>&1; }

next_free_port() {
  local p="$1"
  while ! port_free "$p"; do p=$((p + 1)); done
  printf '%s' "$p"
}

# A subnet already routed on this Mac would collide with the container network.
# macOS abbreviates route destinations ("192.168.66", not "192.168.66.0/24"),
# so match the prefix followed by end-of-field, a dot, or a slash.
subnet_taken() {
  local p="${1%%/*}"; p="${p%.*}"
  local esc="${p//./\\.}"
  netstat -rn -f inet 2>/dev/null | awk '{print $1}' | grep -Eq "^${esc}($|[./])"
}

probe_models() {
  local host="$1"
  curl -sS -m 6 "http://${host}/v1/models" 2>/dev/null | jq -r '.data[]?.id // empty' 2>/dev/null
}

# carry existing answers forward as defaults
[ -f config.env ] && { set -a; . ./config.env; set +a; }
PREV_UI_PORT="${UI_PORT:-}"; PREV_SQUID_PORT="${SQUID_PORT:-}"
PREV_MODEL_RELAY_PORT="${MODEL_RELAY_PORT:-}"
PREV_SEARXNG_PORT="${SEARXNG_PORT:-}"; PREV_CRAWL4AI_PORT="${CRAWL4AI_PORT:-}"

bold "dsh box setup"
dim  "Writes config.env. Nothing is installed or changed on your system yet."
echo

# ---------------------------------------------------------------- model -----

bold "1. Model server"
dim "Looking for an OpenAI-compatible server on this Mac..."
FOUND=""
for cand in "${MODEL_HOST:-}" 127.0.0.1:8090 127.0.0.1:8080 127.0.0.1:11434 127.0.0.1:1234; do
  [ -n "$cand" ] || continue
  if curl -sS -m 3 -o /dev/null "http://${cand}/v1/models" 2>/dev/null; then
    FOUND="$cand"; dim "  found one at ${cand}"; break
  fi
done
[ -n "$FOUND" ] || dim "  none found on the usual ports (8090, 8080, 11434, 1234)"

MODEL_HOST="$(ask 'Model server host:port' "${FOUND:-${MODEL_HOST:-}}")"
while [ -z "$MODEL_HOST" ]; do
  dim "  A model server address is required (e.g. 127.0.0.1:8080 for llama.cpp, 127.0.0.1:11434 for Ollama)."
  MODEL_HOST="$(ask 'Model server host:port' '')"
done

MODELS="$(probe_models "$MODEL_HOST")"
while [ -z "$MODELS" ]; do
  echo
  dim "  Could not read a model list from http://${MODEL_HOST}/v1/models"
  if yes_no "  Continue anyway and set the model id by hand?" n; then
    break
  fi
  MODEL_HOST="$(ask 'Model server host:port' "$MODEL_HOST")"
  MODELS="$(probe_models "$MODEL_HOST")"
done

if [ -n "$MODELS" ]; then
  echo
  dim "  Models this server reports:"
  i=1; while IFS= read -r m; do printf '    %d) %s\n' "$i" "$m" >&2; i=$((i+1)); done <<< "$MODELS"
  count=$((i-1))
  if [ "$count" -eq 1 ]; then
    MODEL_ID="$MODELS"
    dim "  only one, using: $MODEL_ID"
  else
    pick="$(ask "  Which model? (1-$count)" 1)"
    MODEL_ID="$(printf '%s' "$MODELS" | sed -n "${pick}p")"
    [ -n "$MODEL_ID" ] || MODEL_ID="$(printf '%s' "$MODELS" | head -1)"
  fi
else
  MODEL_ID="$(ask 'Model id (as the server reports it)' "${MODEL_ID:-}")"
fi

# Only ask for a key if the server actually wants one.
MODEL_API_KEY="${MODEL_API_KEY:-unused}"
code="$(curl -sS -m 5 -o /dev/null -w '%{http_code}' "http://${MODEL_HOST}/v1/models" 2>/dev/null)"
if [ "$code" = "401" ] || [ "$code" = "403" ]; then
  MODEL_API_KEY="$(ask 'Server requires a key. API key' "$MODEL_API_KEY")"
fi

if printf '%s' "$MODEL_ID" | grep -qi 'qwen'; then
  echo
  dim "  Qwen detected. docs/10-qwen-and-local-models.md covers its sampling"
  dim "  settings and the loop behavior the circuit-breaker plugin guards against."
fi

# ---------------------------------------------------------------- network ---

echo; bold "2. Container network"
PREV_SUBNET="${SUBNET:-}"
SUBNET="${SUBNET:-192.168.66.0/24}"
if [ "$SUBNET" = "$PREV_SUBNET" ] && subnet_taken "$SUBNET"; then
  # Our own dshnet bridge routes this subnet once the box has run. That is not
  # a collision with someone else, it is us.
  dim "  $SUBNET is already routed by your own container bridge. Keeping it."
elif subnet_taken "$SUBNET"; then
  dim "  $SUBNET collides with a route your Mac already has."
  for alt in 192.168.66.0/24 192.168.77.0/24 192.168.88.0/24 172.31.66.0/24; do
    subnet_taken "$alt" || { SUBNET="$alt"; dim "  suggesting $alt instead"; break; }
  done
else
  dim "  $SUBNET is free"
fi
SUBNET="$(ask 'Container subnet' "$SUBNET")"
SUBNET6="${SUBNET6:-fd66:2a5:1::/64}"

echo; bold "3. Ports"
dim "  Each gateway port is a hole in the firewall. Defaults shown; taken ports are bumped."
# Plain variables, not an associative array: macOS ships bash 3.2, which has
# no `declare -A`, and this script must run under /bin/bash.
UI_PORT="${UI_PORT:-3080}"; SQUID_PORT="${SQUID_PORT:-3128}"
MODEL_RELAY_PORT="${MODEL_RELAY_PORT:-8090}"
SEARXNG_PORT="${SEARXNG_PORT:-8888}"; CRAWL4AI_PORT="${CRAWL4AI_PORT:-8890}"

# settle_port NAME WANTED CONFIGURED -> echoes the port to use
settle_port() {
  local key="$1" want="$2" configured="$3" free
  if port_free "$want"; then printf '%s' "$want"; return; fi
  # A port already in config.env is almost certainly held by this box's own
  # running containers. Bumping it would break a working install.
  if [ -n "$configured" ] && [ "$want" = "$configured" ]; then
    dim "  $key: $want in use, and it is your current setting (your box is probably running). Keeping it."
    printf '%s' "$want"; return
  fi
  free="$(next_free_port "$want")"
  dim "  $key: $want is in use, suggesting $free"
  printf '%s' "$free"
}
UI_PORT="$(settle_port UI_PORT "$UI_PORT" "${PREV_UI_PORT:-}")"
SQUID_PORT="$(settle_port SQUID_PORT "$SQUID_PORT" "${PREV_SQUID_PORT:-}")"
MODEL_RELAY_PORT="$(settle_port MODEL_RELAY_PORT "$MODEL_RELAY_PORT" "${PREV_MODEL_RELAY_PORT:-}")"
SEARXNG_PORT="$(settle_port SEARXNG_PORT "$SEARXNG_PORT" "${PREV_SEARXNG_PORT:-}")"
CRAWL4AI_PORT="$(settle_port CRAWL4AI_PORT "$CRAWL4AI_PORT" "${PREV_CRAWL4AI_PORT:-}")"

if ! yes_no "  Accept these ports? (UI $UI_PORT, proxy $SQUID_PORT, model $MODEL_RELAY_PORT, search $SEARXNG_PORT, fetch $CRAWL4AI_PORT)" y; then
  UI_PORT="$(ask '  UI_PORT' "$UI_PORT")"
  SQUID_PORT="$(ask '  SQUID_PORT' "$SQUID_PORT")"
  MODEL_RELAY_PORT="$(ask '  MODEL_RELAY_PORT' "$MODEL_RELAY_PORT")"
  SEARXNG_PORT="$(ask '  SEARXNG_PORT' "$SEARXNG_PORT")"
  CRAWL4AI_PORT="$(ask '  CRAWL4AI_PORT' "$CRAWL4AI_PORT")"
fi

# ---------------------------------------------------------------- host ------

echo; bold "4. Host"
LABEL_PREFIX="$(ask 'launchd label prefix' "${LABEL_PREFIX:-local.dshbox}")"

cores="$(sysctl -n hw.ncpu 2>/dev/null || echo 8)"
gb="$(( $(sysctl -n hw.memsize 2>/dev/null || echo 17179869184) / 1073741824 ))"
DSH_CPUS="$(ask 'CPUs for the agent container' "${DSH_CPUS:-$(( cores > 4 ? 4 : cores ))}")"
DSH_MEMORY="$(ask 'Memory for the agent container' "${DSH_MEMORY:-$(( gb >= 16 ? 8 : 4 ))G}")"
dim "  The image build cache speeds up rebuilds but grows without bound."
dim "  run.sh wipes and rebuilds it past this size; one warm build is ~16G,"
dim "  so stay above that or every build runs cold. 0 keeps it forever."
BUILDER_CACHE_MAX_GB="$(ask 'Build cache limit in GB' "${BUILDER_CACHE_MAX_GB:-25}")"

# ---------------------------------------------------------------- write -----

bad=0
need() {  # need NAME REGEX DESCRIPTION
  printf '%s' "${!1}" | grep -Eq "^$2$" && return 0
  echo "  $1='${!1}' is not $3" >&2; bad=1
}
need MODEL_HOST '[A-Za-z0-9.-]+:[0-9]+' 'a host:port'
need SUBNET '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+' 'a CIDR subnet'
need SUBNET6 '[0-9A-Fa-f:]+/[0-9]+' 'a v6 CIDR subnet'
for pv in UI_PORT SQUID_PORT MODEL_RELAY_PORT SEARXNG_PORT CRAWL4AI_PORT; do
  need "$pv" '[0-9]+' 'a port number'
done
need DSH_CPUS '[0-9]+' 'a CPU count'
need BUILDER_CACHE_MAX_GB '[0-9]+' 'a whole number of GB (0 disables)'
need DSH_MEMORY '[0-9]+[KMGkmg]?' 'a memory size like 8G'
need LABEL_PREFIX '[A-Za-z0-9.-]+' 'a reverse-DNS style label'
[ "$bad" -eq 0 ] || { echo "Fix the answers above and re-run." >&2; exit 1; }

echo
bold "Summary"
cat >&2 <<SUMMARY
  model      http://${MODEL_HOST}  (${MODEL_ID})
  subnet     ${SUBNET}   gateway $(printf '%s' "$SUBNET" | awk -F'[./]' '{print $1"."$2"."$3".1"}')
  UI         http://127.0.0.1:${UI_PORT}
  gateway    proxy ${SQUID_PORT} · model ${MODEL_RELAY_PORT} · search ${SEARXNG_PORT} · fetch ${CRAWL4AI_PORT}
  launchd    ${LABEL_PREFIX}.*
  container  ${DSH_CPUS} CPUs, ${DSH_MEMORY}, build cache capped at ${BUILDER_CACHE_MAX_GB}G
SUMMARY
echo
yes_no "Write this to config.env?" y || { echo "Nothing written."; exit 0; }

[ -f config.env ] && cp config.env "config.env.bak.$(date +%s)"
# Values come from free-text prompts and this file gets sourced, so quote
# every one: kv single-quotes the value ('' -> '\''), which stops both
# word-splitting and $(...) from running as code on the next source.
kv() { printf "%s='%s'\n" "$1" "$(printf '%s' "$2" | sed "s/'/'\\\\''/g")"; }
{
  echo "# Written by ./setup.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ). Re-run it to change."
  echo "# Field documentation lives in config.example.env."
  echo
  kv MODEL_HOST "$MODEL_HOST"
  kv MODEL_ID "$MODEL_ID"
  kv MODEL_API_KEY "$MODEL_API_KEY"
  echo
  kv SUBNET "$SUBNET"
  kv SUBNET6 "$SUBNET6"
  kv UI_PORT "$UI_PORT"
  kv SQUID_PORT "$SQUID_PORT"
  kv MODEL_RELAY_PORT "$MODEL_RELAY_PORT"
  kv SEARXNG_PORT "$SEARXNG_PORT"
  kv CRAWL4AI_PORT "$CRAWL4AI_PORT"
  echo
  kv LABEL_PREFIX "$LABEL_PREFIX"
  kv DSH_CPUS "$DSH_CPUS"
  kv DSH_MEMORY "$DSH_MEMORY"
  kv BUILDER_CACHE_MAX_GB "$BUILDER_CACHE_MAX_GB"
} > config.env

echo
bold "Wrote config.env"
echo "Next:"
echo "  ./setup-host.sh    installs the firewall, proxy and relays (asks for sudo)"
echo "  ./run.sh           builds and starts the box"
echo "  ./verify.sh        proves the lockdown works"
