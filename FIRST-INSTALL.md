# First-install log

## Verification results (2026-09-10)

- [x] 1. Five setup commands ran in the README's order. After the fixes below,
  no step needed outside knowledge except the workspace-picker pencil trick
  (entry 4, now in the README).
- [x] 2. `./doctor.sh` after setup-host.sh: 31 ok, 0 warn, **0 FAIL**.
- [x] 3. `./verify.sh`: all checks pass — **0 failed, 0 warned** (the script
  runs 8 checks, not 4: lockdown ×4 plus agent-tools ×4).
- [x] 4. UI loads at http://127.0.0.1:3080, workspace picker accepted
  `/workspace` (via pencil icon), chat turn answered by qwen38
  ("17 × 23 = 391.", 82 tok/s).
- [x] 5. Web research: asked for the latest stable Squid release. Agent
  searched via SearXNG (query visible in trajectory), fetched
  squid-cache.org/Versions and the GitHub SQUID_7_7 tag via
  `mcp__crawl4ai__md` (both calls visible in `container logs dsh`), and
  answered v7.7 / 2026-08-24 with both URLs cited. Answer matches the squid
  7.7 Homebrew just installed. One expected red Fetch error (entry 5).
- [x] 6. Lockdown from inside: `container exec dsh curl -m 5
  https://example.com` fails (squid CONNECT 403 via the shipped proxy env;
  the raw no-proxy path is blocked by pf per verify check 2), and an explicit
  squid request to an unallowlisted domain is denied 403.
- [x] 7. Circuit breaker: tripped it deliberately (20 identical `date`
  calls → 6 ran, 14 denied with the breaker's message; one `duplicate`
  incident in `/workspace/.circuit-breaker-incidents.jsonl`). No plugin
  reports "did not activate". Note: `container logs dsh` shows no activation
  line at boot (entry 6).
- [ ] 8. stop.sh / run.sh persistence cycle — NOT RUN (stopped here on the
  owner's instruction).
- [ ] 9. teardown-host.sh + reinstall — NOT RUN (same).

A cold install of dsh-research-container on a clean Mac (Apple silicon,
macOS 27 / Darwin 27.0.0), following README.md literally, top to bottom.
One entry per friction point: what the README said, what actually happened,
what a user would think, and what changed in the repo.

Model server: an OpenAI-compatible server on a Tailscale peer
(`100.66.202.15:8090`).

---

## Entries

(entries appear in the order a user hits them)

### 1. setup.sh's "Next:" list skips doctor.sh — fixed

- **README said:** "Five commands, in this order. Each one needs the output
  of the one before it." Step 2 is `./doctor.sh`.
- **What happened:** `setup.sh` finished and printed
  `Next: ./setup-host.sh → ./run.sh → ./verify.sh`, with no mention of
  doctor.sh.
- **What a user would think:** People follow the tool's own prompt over a
  README they read ten minutes ago. Most would run `setup-host.sh` next and
  skip the preflight entirely — exactly the step designed to catch a broken
  config before anything touches the host.
- **Change:** added the `./doctor.sh` line to setup.sh's closing Next list.

### 2. Cosmetic: doctor.sh "Next" line re-lists ./setup.sh — logged only

- **What happened:** doctor.sh ends with
  `Preflight clear. Next: ./setup.sh, ./setup-host.sh, ./run.sh, ./verify.sh`
  even when `config.env` already exists (doctor itself just verified it).
- **What a user would think:** momentary "wait, do I need to run setup.sh
  again?" It reads as the full pipeline, not the next action.
- **Change:** none (cosmetic; left for the maintainer to decide phrasing).

### 3. run.sh dies instantly and silently on every first run — fixed

- **README said:** "4. `run.sh` ... The first build takes a few minutes."
- **What happened:** `./run.sh` exited with code 1 and printed *nothing*.
  Cause: `have_subnet="$(container network inspect dshnet 2>/dev/null | jq ...)"`
  runs under `set -euo pipefail` (inherited from lib/config.sh). On a first
  run the `dshnet` network does not exist yet, `container network inspect`
  (apple/container 1.3.1) exits 1, pipefail makes the substitution fail, and
  `set -e` kills the script — with the only error message redirected to
  /dev/null.
- **What a user would think:** "It just... exits? No error, no log, nothing."
  This is the worst failure of the install: it happens to 100% of first runs,
  right after three steps that all succeeded, and gives zero clues. A user
  without bash-trace skills is dead in the water.
- **Change:** appended `|| true` to that pipeline so a missing network reads
  as the intended empty string (same pattern the script already uses for
  `container image prune` further down).

### 4. "Choose /workspace and go" hides a picker maze — README fixed

- **README said:** "Then open http://127.0.0.1:3080 ... Choose `/workspace`
  and go."
- **What happened:** the workspace picker opens in the container's home
  directory (`/home/dev`), which is empty, with no visible way to reach
  `/workspace`. You have to notice the small pencil icon, click it, and type
  the path. Pressing Enter in the path field does nothing visible; you must
  click Open.
- **What a user would think:** "The picker is empty. Where is /workspace?"
  Thirty seconds of confusion at the exact moment the README says "and go".
- **Change:** README now says to click the pencil and type `/workspace`.

### 5. First research turn shows a red Fetch error — README note added

- **README said:** "ask it to research something and it searches via SearXNG,
  reads pages via Crawl4AI, and cites them."
- **What happened:** exactly that — but the trajectory first shows a red
  `Error: configured web provider "dsh-web-tools-fetch" is registered but
  unavailable`, because dsh-web-tools registers a generic Fetch tool whose
  fetch-capable providers (tavily, jina, firecrawl...) are all deliberately
  blank in `dsh-home/settings.yaml`. The agent then falls back to
  `mcp__crawl4ai__md` and the turn succeeds with citations.
- **What a user would think:** "Something is broken" — red error text in
  their very first research turn, even though the answer arrives cited.
- **Change:** documented the error as expected in the README's Web research
  section. Whether the plugin should be configured to not register its Fetch
  tool at all is a design question left for the maintainer (plugin config is
  pinned/reviewed; out of scope here).

### 6. Nothing in `container logs dsh` proves the circuit-breaker is live — logged only

- **What happened:** the container log shows the seed-version string
  (`...breaker-5...`) and nothing else about plugins; there is no
  "activated" line. The only way to confirm the breaker works is to trip it
  (I asked the agent to run the same command 20 times: 6 ran, 14 denied,
  one incident row in `/workspace/.circuit-breaker-incidents.jsonl`).
- **What a user would think:** they can't tell the loop guard is armed
  without deliberately provoking it; most will simply trust it.
- **Change:** none in the repo (activation logging is upstream dsh/plugin
  behavior). Noted here so the maintainer can decide whether entrypoint or
  verify.sh should probe for it.

### Non-repo notes (environment, not README failures)

- The wizard's local-port probe correctly found nothing (model server is on a
  Tailscale peer) and prompted; typing the host:port worked first try, and it
  discovered the single model `qwen38` and picked it without asking. Good UX.
- The model server had to be woken first; while offline, `curl /v1/models`
  from this Mac just timed out. Nothing in the repo could have told the user
  that; not a README failure.
