#!/bin/bash
# Sync the harness's declared context window to the model server's real n_ctx.
#
# dsh's token meter uses settings.yaml `contextWindow` to decide context
# pressure and when to compact. If it exceeds the server's actual n_ctx, dsh
# happily builds a prompt the server cannot accept, and with
# --no-context-shift llama.cpp errors instead of degrading gracefully.
#
# Re-run this after ANY change to the server's -c flag.
set -euo pipefail
cd "$(dirname "$0")/.."

. "$(dirname "$0")/../lib/config.sh"   # provides MODEL_HOST
require jq
require python3 python
RESERVE="${RESERVE:-4096}"   # headroom for the response inside n_ctx

n_ctx=$(curl -sS -m 10 "http://${MODEL_HOST}/props" 2>/dev/null \
        | jq -r '.default_generation_settings.n_ctx // empty')
[ -n "$n_ctx" ] || { echo "could not read n_ctx from ${MODEL_HOST}" >&2; exit 1; }

window=$(( n_ctx - RESERVE ))
current=$(grep -oE 'contextWindow: [0-9]+' dsh-home/settings.yaml | head -1 | grep -oE '[0-9]+' || echo "unset")

echo "server n_ctx:      $n_ctx"
echo "reserve (output):  $RESERVE"
echo "contextWindow now: $current  ->  $window"

if [ "$current" = "$window" ]; then
  echo "already in sync"; exit 0
fi

python3 - "$window" "$RESERVE" <<'PY'
import pathlib, re, sys
window, reserve = sys.argv[1], sys.argv[2]
p = pathlib.Path('dsh-home/settings.yaml'); s = p.read_text()
s2 = re.sub(r'contextWindow: \d+', f'contextWindow: {window}', s, count=1)
if 'maxTokens:' in s2:
    s2 = re.sub(r'maxTokens: \d+', f'maxTokens: {reserve}', s2, count=1)
else:
    s2 = s2.replace(f'contextWindow: {window}',
                    f'contextWindow: {window}\n          maxTokens: {reserve}', 1)
assert s2 != s, "settings.yaml unchanged; check the contextWindow line exists"
p.write_text(s2)
PY

echo "updated. restart dsh to apply:  container stop dsh && container start dsh"
