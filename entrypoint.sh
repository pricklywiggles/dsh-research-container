#!/bin/bash
set -euo pipefail

# debug hatch: `container run dsh-box <cmd>` runs <cmd> instead of the server
if [ "$#" -gt 0 ]; then
  exec "$@"
fi

# profiles/ is derived state (bundle manifests + pnpm modules). Sync it from
# the image seed when the seed changes, so plugins baked at build time appear
# without runtime network. User data (settings.yaml, sessions/, storages/,
# credentials) is never touched.
SEED=/opt/dsh-seed
if [ -d "$SEED/profiles" ]; then
  seedver="$(cat "$SEED/.seed-version" 2>/dev/null || echo seed)"
  curver="$(cat "$DSH_HOME/.seed-version" 2>/dev/null || echo none)"
  if [ "$seedver" != "$curver" ]; then
    echo "syncing plugin profiles from image seed ($seedver)"
    rm -rf "$DSH_HOME/profiles"
    cp -R "$SEED/profiles" "$DSH_HOME/profiles"
    echo "$seedver" > "$DSH_HOME/.seed-version"
  fi
fi

# Reconcile the config-derived keys in settings.yaml with config.env (handed
# in as DSH_SYNC_* by run.sh). The UI owns the rest of the file, so only these
# lines are touched, atomically. Exactly one match patches; zero means the user
# removed the key and it is left alone; more than one aborts the boot rather
# than guessing which to change.
if [ -n "${DSH_SYNC_GATEWAY:-}" ] && [ -f "$DSH_HOME/settings.yaml" ]; then
  python3 - "$DSH_HOME/settings.yaml" <<'PYSYNC'
import os, re, sys, tempfile

path = sys.argv[1]
gw = os.environ["DSH_SYNC_GATEWAY"]
model_port = os.environ["DSH_SYNC_MODEL_PORT"]
searx_port = os.environ["DSH_SYNC_SEARXNG_PORT"]
model_id = os.environ.get("DSH_SYNC_MODEL_ID", "")

src = open(path).read()
s = src

def patch(text, pattern, value, name, required):
    hits = re.findall(pattern, text, flags=re.M)
    if len(hits) > 1:
        sys.exit("settings sync: %d '%s' lines; refusing to guess, fix settings.yaml" % (len(hits), name))
    if len(hits) == 0:
        if required:
            sys.exit("settings sync: no '%s' line in settings.yaml" % name)
        return text
    out = re.sub(pattern, lambda m: m.group(1) + value, text, count=1, flags=re.M)
    return out

s = patch(s, r"^(\s*baseURL: )http://\S+$", "http://%s:%s/v1" % (gw, model_port), "baseURL", True)
s = patch(s, r"^(\s*searxng: )http://\S+$", "http://%s:%s" % (gw, searx_port), "searxng", False)
if model_id:
    s = patch(s, r"^(\s*- id: )\S+$", model_id, "- id", False)
    s = patch(s, r"^(\s*model: )\S+$", model_id, "model", False)

if s != src:
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path))
    with os.fdopen(fd, "w") as f:
        f.write(s)
    os.replace(tmp, path)
    print("settings sync: reconciled settings.yaml with config.env")
PYSYNC
fi

# The crawl4ai MCP bridge (supergateway) opens its SSE connection once as dsh
# boots and exits for good if the connect is refused, silently costing the agent
# every mcp__crawl4ai__* tool. run.sh waits for crawl4ai before it creates this
# container, but that only covers the run.sh path: a container system restart or
# a plain `container start` brings everything up at once and loses the race. The
# URL comes from the same patch row supergateway reads, so the two cannot drift.
sse_url="$(grep -oE 'https?://[^"[:space:]]+/mcp/sse' "$DSH_HOME/cordis.patch.yml" 2>/dev/null | head -1 || true)"
if [ -n "$sse_url" ]; then
  health="${sse_url%/mcp/sse}/health"
  tries=90
  printf 'waiting for crawl4ai at %s' "$health"
  while [ "$tries" -gt 0 ]; do
    if curl -sS -m 3 -o /dev/null "$health" 2>/dev/null; then printf ' ok\n'; break; fi
    printf '.'; sleep 2; tries=$((tries - 1))
  done
  # Booting without fetch tools beats not booting at all, so this only warns.
  [ "$tries" -gt 0 ] || printf '\nwarning: crawl4ai never answered; the MCP bridge will have no tools\n' >&2
fi

# dsh refuses to bind non-loopback (no remote auth yet). The vmnet subnet is
# host-only, so relaying the UI onto it exposes it to the Mac and nothing else.
socat TCP-LISTEN:3081,fork,reuseaddr TCP:127.0.0.1:3080 &

exec dsh web --no-open
