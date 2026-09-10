#!/bin/bash
# Prove the box: the lockdown holds, and the agent's tools actually work.
#
# Both halves matter, and only the first used to be checked. A green lockdown
# over a dead agent has happened twice here: a pf reload flushed the vmnet NAT
# so nothing on the open network could reach the internet, and the crawl4ai MCP
# bridge lost a startup race and left the agent with no fetch tools. Both times
# every security check passed. Exits non-zero if anything fails.
cd "$(dirname "$0")"
. lib/config.sh
set +e

GW="$GATEWAY"
run() { container exec dsh "$@"; }

FAIL=0; WARN=0
ok()   { printf '   \033[32mok\033[0m    %s\n' "$*"; }
bad()  { printf '   \033[31mFAIL\033[0m  %s\n' "$*"; FAIL=$((FAIL + 1)); }
warn() { printf '   \033[33mwarn\033[0m  %s\n' "$*"; WARN=$((WARN + 1)); }

printf '\033[1mLockdown\033[0m\n'

echo "1) model relay (expect any HTTP status):"
code="$(run curl -sS -m 5 -o /dev/null -w '%{http_code}' "http://${GW}:${MODEL_RELAY_PORT}/v1/models" 2>/dev/null)"
if [ -n "$code" ] && [ "$code" != "000" ]; then
  ok "HTTP $code"
else
  bad "relay down, or the model server is unreachable from the host"
fi

echo "2) direct egress (expect failure, default-deny):"
# This check must test the firewall, nothing else. --noproxy '*' because the
# container ships HTTPS_PROXY and a proxied request dies at squid even with
# the pf anchor unloaded; a literal IP because container DNS is dead, so a
# hostname fails to resolve anchor-or-no-anchor and would mask a leak too.
if run curl -sS --noproxy "*" -m 5 -o /dev/null http://1.1.1.1 2>/dev/null; then
  bad "LEAK: direct egress succeeded. The pf anchor is not active"
else
  ok "blocked, as intended"
fi

echo "3) proxy, example.com, not allowlisted (expect a squid 403):"
out="$(run curl -sS -m 10 -x "http://${GW}:${SQUID_PORT}" -o /dev/null -w '%{http_code}' https://example.com 2>&1)"
if [[ "$out" == *"response 403"* ]]; then
  ok "denied by squid (403), as intended"
elif [[ "$out" =~ ^[0-9]+$ ]]; then
  bad "reached it (HTTP $out): example.com should not be allowlisted"
else
  bad "$out"
fi

echo "4) proxy, registry.npmjs.org (allowed only if you allowlisted it):"
out="$(run curl -sS -m 10 -x "http://${GW}:${SQUID_PORT}" -o /dev/null -w '%{http_code}' https://registry.npmjs.org 2>&1)"
if [[ "$out" =~ ^[0-9]+$ ]]; then
  ok "allowed (HTTP $out), it is on the allowlist"
else
  ok "denied by squid, as intended when it is not allowlisted"
fi

printf '\n\033[1mAgent tools\033[0m\n'

echo "5) open-network egress (searxng and crawl4ai must reach the internet):"
# The NAT canary. apple/container injects the open network's NAT at runtime and
# any full pfctl reload flushes it, which kills web research while leaving every
# lockdown check above green.
if ! container ls 2>/dev/null | grep -q '^crawl4ai '; then
  bad "the crawl4ai container is not running. Fix: ./run.sh"
elif container exec crawl4ai curl -sS -m 8 -o /dev/null http://1.1.1.1 2>/dev/null; then
  ok "crawl4ai reaches the internet"
else
  bad "crawl4ai is running but cannot reach a raw IP: the vmnet NAT is gone. Fix: container system stop && container system start, then ./run.sh"
fi

echo "6) crawl4ai MCP bridge (the agent's page reader):"
logs="$(container logs dsh 2>&1)"
if printf '%s' "$logs" | grep -q 'stdin closed'; then
  bad "the bridge exited, so the agent has no mcp__crawl4ai__* tools. Fix: restart dsh once crawl4ai answers"
elif printf '%s' "$logs" | grep -q 'tools/list'; then
  ok "bridge negotiated its tool list"
else
  bad "no tool list in the dsh log; the bridge never connected"
fi

echo "7) searxng returns results:"
n="$(run curl -sS -m 25 "http://${GW}:${SEARXNG_PORT}/search?q=verify+probe&format=json" 2>/dev/null | jq -r '.results | length' 2>/dev/null)"
if [ "${n:-0}" -gt 0 ] 2>/dev/null; then
  ok "$n results"
else
  # Upstream engines suspend a busy IP on their own, so zero is not proof of a
  # broken box unless check 5 also failed.
  warn "zero results: engine suspensions, or the NAT problem in check 5"
fi

echo "8) UI on the host:"
if curl -sS -m 5 -o /dev/null "http://127.0.0.1:${UI_PORT}/" 2>/dev/null; then
  ok "http://127.0.0.1:${UI_PORT}"
else
  bad "the UI does not answer on 127.0.0.1:${UI_PORT}"
fi

printf '\n%d failed, %d warned\n' "$FAIL" "$WARN"
echo
echo "Live traffic view (run on the Mac, then watch dsh work):"
echo "  sudo tcpdump -i \$(ifconfig | grep -oE 'bridge[0-9]+' | tail -1) 'net ${SUBNET}'"

[ "$FAIL" -eq 0 ]
