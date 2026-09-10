#!/bin/bash
# Create/refresh the dsh box: network, image build, container run.
# Safe to re-run; it replaces the running container with a fresh one.
cd "$(dirname "$0")"
. lib/config.sh

NET=dshnet
NAME=dsh
IMAGE=dsh-box
GW="$GATEWAY"

# Containers store their ports, mounts and env at creation time. Starting a
# stopped one keeps whatever config it was born with, so a stale mount path or
# an old port survives every re-run. All three are recreated instead. searxng
# and crawl4ai hold no state of their own (searxng's config comes from the
# mount, crawl4ai persists nothing). Rebuilding and recreating adds about 30s.
recreate() { container stop "$1" 2>/dev/null || true; container rm "$1" 2>/dev/null || true; }

# Everything below stops and removes containers, so refuse to start without
# the secret run.sh must hand to crawl4ai. setup-host.sh generates it.
if [ -z "${MODEL_HOST:-}" ]; then
  echo "MODEL_HOST is not set. Run ./setup.sh first; it finds your model server." >&2
  exit 1
fi

if [ -z "${CRAWL4AI_TOKEN:-}" ]; then
  echo "CRAWL4AI_TOKEN is not set: secrets.env is missing or empty." >&2
  echo "Run ./setup-host.sh first; it generates secrets.env." >&2
  exit 1
fi

container system start 2>/dev/null || true

# A network freezes its subnet at creation, exactly like a container freezes
# its mounts. If config.env changed SUBNET, a kept network would put dsh on a
# subnet the pf anchor no longer covers: no default-deny, dead relays.
have_subnet="$(container network inspect "$NET" 2>/dev/null | jq -r '.[0].configuration.ipv4Subnet // empty')"
if [ -n "$have_subnet" ] && [ "$have_subnet" != "$SUBNET" ]; then
  echo "dshnet is $have_subnet but config.env says $SUBNET; recreating the network"
  recreate "$NAME"
  container network delete "$NET"
  have_subnet=""
fi
if [ -z "$have_subnet" ]; then
  # explicit v6 prefix so the pf anchor can pin it down (host/templates/dsh-egress.pf.conf.tmpl)
  container network create "$NET" --subnet "$SUBNET" --subnet-v6 "$SUBNET6"
fi

# The builder cache exists only to make the next build fast, grows without
# bound, and apple/container has no partial GC. Past the configured limit,
# trade one cold build for the space back. BUILDER_CACHE_MAX_GB=0 disables.
if [ "${BUILDER_CACHE_MAX_GB}" -gt 0 ] 2>/dev/null; then
  bkdir="$HOME/Library/Application Support/com.apple.container/containers/buildkit"
  if [ -d "$bkdir" ]; then
    bk_gb=$(( $(du -sk "$bkdir" 2>/dev/null | awk '{print $1}') / 1048576 ))
    if [ "$bk_gb" -ge "$BUILDER_CACHE_MAX_GB" ]; then
      echo "builder cache is ${bk_gb}G, at or over BUILDER_CACHE_MAX_GB=${BUILDER_CACHE_MAX_GB}."
      echo "Recreating it; the next build runs cold, roughly four minutes."
      container builder delete -f 2>/dev/null || true
      container builder start --cpus 2 --memory 2048M --dns 1.1.1.1
    fi
  fi
fi

# explicit resolver: the gateway DNS forwarder is broken on this macOS beta,
# and the builder VM needs working DNS for apt/npm (queries go out via NAT)
container build --dns 1.1.1.1 --build-arg UID="$USER_UID" -t "$IMAGE" .
container build --dns 1.1.1.1 -t crawl4ai-local -f host/crawl4ai/Dockerfile host/crawl4ai

# SearXNG: self-hosted search backend for the agent's web research. Lives on
# the OPEN default network (it must query real search engines); dsh reaches it
# only via the gateway relay on 8888 -> host loopback -> here.
recreate searxng
container run -d --name searxng --network default --dns 1.1.1.1 \
  --cpus 2 --memory 1G \
  -p 127.0.0.1:${SEARXNG_PORT}:8080 \
  -v "$PWD/host/rendered/searxng:/etc/searxng" \
  docker.io/searxng/searxng@sha256:11a9b34cdc0b1ec2b991470a2762ecb5a1a531898289fb51dcd015260450729e

# Crawl4AI: self-hosted URL->markdown fetcher (Playwright/Chromium inside),
# same trust pattern as SearXNG: open network, reachable only via gw:8890 relay.
# Token required: crawl4ai refuses a non-loopback bind without one.
recreate crawl4ai
container run -d --name crawl4ai --network default --dns 1.1.1.1 \
  --cpus 2 --memory 4G \
  -p 127.0.0.1:${CRAWL4AI_PORT}:11235 \
  -e CRAWL4AI_API_TOKEN="$CRAWL4AI_TOKEN" \
  crawl4ai-local

mkdir -p workspace dsh-home

# dsh must not boot before these answer. The crawl4ai MCP bridge (supergateway)
# opens its SSE connection once at dsh startup and exits for good on a refused
# connect, taking every mcp__crawl4ai__* tool with it and logging nothing the
# agent can act on. Recreating both above means they are always cold here, and
# crawl4ai has a Chromium to start. A slow service is worth waiting for; one
# that never comes up is still better than no dsh at all, so this warns rather
# than aborting.
wait_for() {
  local name="$1" url="$2" tries=90
  printf 'waiting for %s' "$name"
  while [ "$tries" -gt 0 ]; do
    if curl -sS -m 3 -o /dev/null "$url" 2>/dev/null; then printf ' ok\n'; return 0; fi
    printf '.'; sleep 2; tries=$((tries - 1))
  done
  printf '\n'
  echo "warning: $name never answered $url; dsh will boot without it" >&2
  return 1
}
wait_for searxng  "http://127.0.0.1:${SEARXNG_PORT}/"       || true
wait_for crawl4ai "http://127.0.0.1:${CRAWL4AI_PORT}/health" || true

recreate "$NAME"

# publish to host loopback: the UI must be browsed via 127.0.0.1. On a
# non-localhost http origin the browser disables crypto.randomUUID and the
# workspace picker breaks.
container run -d --name "$NAME" --network "$NET" --cpus "$DSH_CPUS" --memory "$DSH_MEMORY" \
  -p 127.0.0.1:${UI_PORT}:3081 \
  -v "$PWD/workspace:/workspace" \
  -v "$PWD/dsh-home:/home/dev/.dsh" \
  -e HTTP_PROXY="http://${GW}:${SQUID_PORT}" \
  -e HTTPS_PROXY="http://${GW}:${SQUID_PORT}" \
  -e NO_PROXY="localhost,127.0.0.1,${GW}" \
  -e LOCAL_MODEL_API_KEY="${MODEL_API_KEY:-unused}" \
  `# the entrypoint reconciles settings.yaml's config-derived keys from these` \
  -e DSH_SYNC_GATEWAY="$GW" \
  -e DSH_SYNC_MODEL_PORT="$MODEL_RELAY_PORT" \
  -e DSH_SYNC_SEARXNG_PORT="$SEARXNG_PORT" \
  -e DSH_SYNC_MODEL_ID="$MODEL_ID" \
  -e WEB_TOOLS_SEARXNG=local \
  `# dummy key: dsh-web-tools skips keyless SearXNG when its key pool is empty (upstream bug); SearXNG ignores the api_key param` \
  "$IMAGE"

# The image generation a rebuild replaces is garbage apple/container never
# collects on its own (upstream #2164, about 4G each). Sweep it every run.
pruned=$(container image prune 2>/dev/null | wc -l | tr -d ' ') || pruned=0
if [ "${pruned:-0}" -gt 0 ]; then
  echo "pruned ${pruned} stale image record(s) from earlier builds"
fi

echo
echo "dsh UI:    http://127.0.0.1:${UI_PORT}"
echo "shell:     container exec -it $NAME bash"
echo "verify:    ./verify.sh"
