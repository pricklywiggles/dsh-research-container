# First-install log

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

### Non-repo notes (environment, not README failures)

- The wizard's local-port probe correctly found nothing (model server is on a
  Tailscale peer) and prompted; typing the host:port worked first try, and it
  discovered the single model `qwen38` and picked it without asking. Good UX.
- The model server had to be woken first; while offline, `curl /v1/models`
  from this Mac just timed out. Nothing in the repo could have told the user
  that; not a README failure.
