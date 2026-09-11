#!/bin/bash
# Preflight for the dsh research container. Read-only: it changes nothing and never asks for
# sudo. Run it before setup-host.sh to catch the problems that are expensive to
# diagnose later, and after an install to see what is actually in place.
#
# It does not prove the lockdown works. That is verify.sh, and it needs the box
# running.
cd "$(dirname "$0")"
. lib/config.sh
set +e   # a failing check must report and continue, not abort the run

PASS=0; FAIL=0; WARN=0
ok()      { printf '  \033[32mok\033[0m    %s\n' "$*"; PASS=$((PASS + 1)); }
bad()     { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; FAIL=$((FAIL + 1)); }
warn()    { printf '  \033[33mwarn\033[0m  %s\n' "$*"; WARN=$((WARN + 1)); }
section() { printf '\n\033[1m%s\033[0m\n' "$*"; }

# ------------------------------------------------------------------ machine --

section "This Mac"

arch="$(uname -m)"
if [ "$arch" = arm64 ]; then
  ok "Apple silicon ($arch)"
else
  bad "$arch: apple/container runs only on Apple silicon"
fi

macos="$(sw_vers -productVersion 2>/dev/null)"
if [ "${macos%%.*}" -ge 26 ] 2>/dev/null; then
  ok "macOS $macos"
else
  bad "macOS ${macos:-unknown}: the container networking this relies on needs 26 or newer"
fi

free_gb="$(df -g . 2>/dev/null | awk 'NR==2 {print $4}')"
if [ "${free_gb:-0}" -ge 15 ] 2>/dev/null; then
  ok "${free_gb}G free on this volume"
else
  warn "${free_gb:-?}G free: the images want roughly 10G, and the build needs room on top"
fi

bkdir="$HOME/Library/Application Support/com.apple.container/containers/buildkit"
if [ -d "$bkdir" ]; then
  bk_gb=$(( $(du -sk "$bkdir" 2>/dev/null | awk '{print $1}') / 1048576 ))
  if [ "${BUILDER_CACHE_MAX_GB:-25}" -gt 0 ] 2>/dev/null && [ "$bk_gb" -ge "${BUILDER_CACHE_MAX_GB:-25}" ]; then
    warn "builder cache ${bk_gb}G is past BUILDER_CACHE_MAX_GB=${BUILDER_CACHE_MAX_GB}; the next ./run.sh recreates it"
  else
    ok "builder cache ${bk_gb}G (limit ${BUILDER_CACHE_MAX_GB}G)"
  fi
fi

# ----------------------------------------------------------------- commands --

section "Commands"

# jq and python3 ship with current macOS, so a miss here means a broken PATH
# rather than something to install. Homebrew is the one genuine prerequisite.
for c in curl jq python3 openssl awk sed nc netstat; do
  if command -v "$c" >/dev/null 2>&1; then ok "$c"; else bad "$c not found on PATH"; fi
done

if [ -x "$BREW_PREFIX/bin/brew" ]; then
  ok "Homebrew at $BREW_PREFIX"
else
  bad "no Homebrew at $BREW_PREFIX: setup-host.sh installs squid and socat with it"
fi

if command -v container >/dev/null 2>&1; then
  ok "apple/container $(container --version 2>/dev/null | awk '{print $4}')"
else
  warn "apple/container not installed (setup-host.sh installs it)"
fi

# Homebrew's sbin is often off PATH, so look for the binaries where brew puts
# them rather than asking the shell.
for c in socat squid; do
  if [ -x "$BREW_PREFIX/bin/$c" ] || [ -x "$BREW_PREFIX/sbin/$c" ]; then
    ok "$c"
  else
    warn "$c not installed yet (setup-host.sh installs it)"
  fi
done

# ------------------------------------------------------------------ network --

section "Network"

# macOS abbreviates route destinations ("192.168.66", not "192.168.66.0/24"),
# so match the prefix followed by end-of-field, a dot, or a slash.
subnet_taken() {
  local p="${1%%/*}"; p="${p%.*}"
  local esc="${p//./\\.}"
  netstat -rn -f inet 2>/dev/null | awk '{print $1}' | grep -Eq "^${esc}($|[./])"
}

dshnet_subnet="$(container network inspect dshnet 2>/dev/null \
                 | jq -r '.[0].configuration.ipv4Subnet // empty' 2>/dev/null)"

if ! subnet_taken "$SUBNET"; then
  ok "$SUBNET is free"
elif [ "$SUBNET" = "$dshnet_subnet" ]; then
  ok "$SUBNET is routed by your own dshnet bridge"
else
  bad "$SUBNET collides with a route this Mac already has (see: netstat -rn -f inet)"
fi

# A port in use is only a problem when something OTHER than this project holds
# it: squid stays up from the moment setup-host.sh installs it, the service
# containers hold their publishes while running, and a same-Mac model server
# legitimately owns MODEL_RELAY_PORT on loopback.
svc_running() { container ls 2>/dev/null | grep -q "^$1 "; }
check_port() {
  local name="$1" port="$2" holder="$3" holder_up="$4"
  if ! nc -z 127.0.0.1 "$port" >/dev/null 2>&1; then
    ok "$name $port is free"
  elif [ "$holder_up" = yes ]; then
    ok "$name $port is held by your own $holder"
  else
    bad "$name $port is held by something else (see: lsof -iTCP:$port -sTCP:LISTEN)"
  fi
}
squid_up=no; pgrep -x squid >/dev/null 2>&1 && squid_up=yes
model_here=no
[ "$MODEL_HOST" = "127.0.0.1:$MODEL_RELAY_PORT" ] && model_here=yes
dsh_up=no;      svc_running dsh      && dsh_up=yes
searxng_up=no;  svc_running searxng  && searxng_up=yes
crawl4ai_up=no; svc_running crawl4ai && crawl4ai_up=yes
check_port UI_PORT          "$UI_PORT"          "dsh container"     "$dsh_up"
check_port SQUID_PORT       "$SQUID_PORT"       "squid"             "$squid_up"
check_port MODEL_RELAY_PORT "$MODEL_RELAY_PORT" "model server"      "$model_here"
check_port SEARXNG_PORT     "$SEARXNG_PORT"     "searxng container" "$searxng_up"
check_port CRAWL4AI_PORT    "$CRAWL4AI_PORT"    "crawl4ai container" "$crawl4ai_up"

# -------------------------------------------------------------------- model --

section "Model server"

if [ -z "$MODEL_HOST" ]; then
  bad "MODEL_HOST is not set: run ./setup.sh, or set it in config.env"
  code=skip
else
  code="$(curl -sS -m 6 -o /dev/null -w '%{http_code}' "http://${MODEL_HOST}/v1/models" 2>/dev/null)"
fi
case "$code" in
  skip) ;;
  200)
    ok "$MODEL_HOST answers /v1/models"
    if curl -sS -m 6 "http://${MODEL_HOST}/v1/models" 2>/dev/null \
       | jq -e --arg id "$MODEL_ID" '.data[]? | select(.id == $id)' >/dev/null 2>&1; then
      ok "it serves MODEL_ID $MODEL_ID"
    else
      bad "MODEL_ID $MODEL_ID is not in that server's model list"
    fi
    ;;
  401|403) warn "$MODEL_HOST wants credentials: set MODEL_API_KEY in config.env" ;;
  000|"")  bad "$MODEL_HOST is unreachable" ;;
  *)       warn "$MODEL_HOST answered HTTP $code" ;;
esac

# ------------------------------------------------------------ install state --

section "Install state"

[ -f config.env ]  && ok "config.env"  || warn "config.env not written yet (./setup.sh)"
[ -f secrets.env ] && ok "secrets.env" || warn "secrets.env not generated yet (./setup-host.sh)"

for label in pf dsh-model-relay dsh-searxng-relay dsh-crawl4ai-relay; do
  if [ -f "/Library/LaunchDaemons/${LABEL_PREFIX}.${label}.plist" ]; then
    ok "launchd ${LABEL_PREFIX}.${label}"
  else
    warn "launchd ${LABEL_PREFIX}.${label} not installed (./setup-host.sh)"
  fi
done

if [ -f /etc/pf.anchors/dsh-egress ]; then
  ok "pf anchor installed"
else
  warn "pf anchor not installed (./setup-host.sh)"
fi

# ------------------------------------------------------------------ verdict --

printf '\n%d ok, %d warn, %d fail\n' "$PASS" "$WARN" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "Fix the failures above before ./setup-host.sh."
  exit 1
fi
# Point at the actual next step instead of re-listing the whole pipeline:
# the checks above already established what is and is not in place.
if [ ! -f config.env ]; then
  echo "Preflight clear. Next: ./setup.sh"
elif [ ! -f secrets.env ] || [ ! -f /etc/pf.anchors/dsh-egress ]; then
  echo "Preflight clear. Next: ./setup-host.sh, then ./run.sh and ./verify.sh"
elif [ "$dsh_up" != yes ]; then
  echo "Preflight clear. Next: ./run.sh, then ./verify.sh"
else
  echo "Preflight clear. The box is running; ./verify.sh proves the lockdown."
fi
