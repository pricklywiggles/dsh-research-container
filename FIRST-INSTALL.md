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
- [x] 8. `./stop.sh` stopped all three containers and the runtime (apiserver
  confirmed down); `./run.sh` brought everything back warm. A marker file
  written to /workspace before the stop, the circuit-breaker incident log,
  and the tool-web `fetch: false` override all survived; verify.sh again
  0 failed / 0 warned.
- [x] 9. `./teardown-host.sh` removed all four launchd jobs, restored the
  stock pf ruleset, deleted both pf files, and stopped squid restoring its
  pre-dsh config. Post-teardown checks: no dsh plists or launchd jobs, pf
  files gone, squid unloaded. `./setup-host.sh` reinstall over the clean
  teardown succeeded (kept secrets.env, re-bootstrapped everything) and its
  "pf was enabled before setup: yes" line confirms teardown had restored
  pf's enabled state. doctor.sh 31 ok / 0 warn / 0 fail after reinstall;
  run.sh + verify.sh brought the box back green. One bug found and fixed on
  the way (entry 9).

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

### 7. The point of the project was buried — README restructured

- **README said:** `/research` and `/deep-research` existed only as a
  "Skills" list inside the **UI: better-sidebar** section, after pnpm
  build-script and node-pty compilation trivia. The setup flow ended at
  "Choose `/workspace` and go" — go *where* was never said.
- **What happened:** verified in the UI that both are live and discoverable
  (`/` opens the command menu; `/research` and all five `/deep-research-*`
  skills appear under Skills). The machinery is fine; the README just never
  points a new user at it.
- **What a user would think:** they finish setup facing a blank chat box,
  ask it something, shrug, and never learn the box replaces their hosted
  deep-research tools — unless they read 90 lines past "go" into a section
  ostensibly about a sidebar plugin.
- **Change:** gave the skills their own `## Research skills` section (after
  Web research, before the loop guard) framed as the reason the box exists,
  and added a line right after the workspace-picker instruction: "Then type
  `/research <your topic>`...". No content removed; the sidebar section now
  covers only the sidebar.

### 8. Dead Fetch tool now unregistered instead of documented — fixed

- **Follow-up to entry 5**, at the owner's request ("is there an easy way to
  not register the tool that shows the error that we dont even use").
- **What was happening:** dsh-web-tools' own patch layer sets `tool-web:
  fetch: true`, registering the model-facing `web_fetch` tool, while `web:
  fetchProvider: dsh-web-tools-fetch` points it at a provider pool that is
  deliberately empty in this box. Every fetch attempt errored red; the
  skills carried a prompt-level "do NOT use the built-in Fetch tool"
  workaround — the kind of instruction the README's own loop-guard section
  argues cannot be relied on.
- **Change:** added a `tool-web` override (`fetch: false`, search keys
  restated since patch config rows replace wholesale) to
  `host/templates/cordis.patch.yml.tmpl`, re-rendered
  `dsh-home/cordis.patch.yml` via the repo's own `render()`, and restarted
  the dsh container. Verified with a fresh research turn: SearXNG search →
  `mcp__crawl4ai__md` directly, no Fetch step, no red error; answer (socat
  1.8.1.3, 2026-06-26) cited and correct. The README sentence from entry 5
  was updated to describe the disabled tool rather than the expected error.

### 9. Host scripts' no-TTY sudo fallback broke when SUDO_ASKPASS was preset — fixed

- **What happened:** setup-host.sh and teardown-host.sh have a thoughtful
  no-TTY fallback (osascript password dialog, commented "e.g. run from
  Claude Code") — but they only passed `-A` to sudo when they *created* the
  helper. With `SUDO_ASKPASS` already exported by the caller and no TTY,
  the scripts skipped both the helper and `-A`, so sudo ignored the
  variable and died: "a terminal is required to read the password".
  teardown-host.sh exited 1 having torn down nothing.
- **What a user would think:** an agent-driven or scripted invocation that
  sets its own askpass (a natural thing to do) fails with a sudo error that
  looks like the environment's fault, not the script's.
- **Change:** in both scripts, `-A` is now set whenever stdin is not a TTY,
  whether or not the helper had to be created. Verified: teardown and the
  reinstall both ran to completion via the scripts' own GUI dialog.

### Non-repo notes (environment, not README failures)

- The wizard's local-port probe correctly found nothing (model server is on a
  Tailscale peer) and prompted; typing the host:port worked first try, and it
  discovered the single model `qwen38` and picked it without asking. Good UX.
- The model server had to be woken first; while offline, `curl /v1/models`
  from this Mac just timed out. Nothing in the repo could have told the user
  that; not a README failure.
