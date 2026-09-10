# Updating plugins and the harness

Updates to this project are done **by a coding agent, never by a script**. A
script can compare version numbers; it cannot read a diff and notice that a
search plugin grew a WebSocket endpoint. The agent's job is judgement, and
this file is its procedure.

Hand an agent this file and say "run an update pass". It should work through
the steps in order and come back with findings and a recommendation before
changing anything. No agent? The procedure works by hand too: every step is
a shell command plus a judgement call, and the judgement is the part that
matters. The actual change is small (step 7); the steps before it are what
make the change safe.

## Principles

**Nothing floats.** Every plugin is pinned to an immutable ref (a commit SHA,
or an exact npm version) in the `Dockerfile`. Branches and `main` are not
pins: they change under you. Tags are better than branches but can be moved,
so prefer the tag's commit SHA.

**Seven-day quarantine, loosely enforced.** Do not adopt anything released or
committed in the last 7 days. This is a default, not a law: tell the user the
age and let them override. Fresh releases are where mistakes and compromised
maintainer accounts show up. If a fix is urgent enough to override, say so
plainly and review it harder.

**Review what you install, install what you reviewed.** The pin you set must
be the exact ref you read. Never review `main` and then pin a tag, or vice
versa.

**Trust is proportional to reach.** A plugin running in-process with dsh
(filesystem, pty, network) deserves a line-by-line diff. A container on the
open network deserves less. Skins and locale packs less still.

## Step 0: inventory what is actually installed

Do not trust the Dockerfile alone; confirm what the last build resolved.

```sh
grep -oE 'DSH_VERSION=[0-9a-z.-]+|_SHA=[0-9a-f]+|_VERSION=[0-9a-z.-]+' Dockerfile
jq -r '.dependencies | to_entries[] | "\(.key) = \(.value)"' dsh-home/profiles/web/package.json
grep -oE 'codeload\.github\.com/[^/]+/[^/]+/tar\.gz/[0-9a-f]{8}' dsh-home/profiles/web/pnpm-lock.yaml | sort -u
bat -pp dsh-home/.seed-version
```

The lockfile is the ground truth for git-hosted plugins. If it disagrees with
the Dockerfile, something floated and you are running unreviewed code. Treat
that as the finding, not a footnote.

## Step 1: what is upstream

```sh
date -u +%Y-%m-%d                                    # anchor the quarantine clock
npm view <pkg> version time --json | jq -r '.version, .time[.version]'
gh api "repos/OWNER/REPO/commits?per_page=1" --jq '.[0] | "\(.sha[0:8]) \(.commit.committer.date[0:10])"'
gh api repos/OWNER/REPO/releases --jq '.[0] | "\(.tag_name) \(.published_at[0:10])"'
gh api repos/apple/container/releases/latest --jq .tag_name
curl -s "https://hub.docker.com/v2/repositories/OWNER/IMAGE/tags/latest" | jq -r .last_updated
```

## Step 2: release versus branch head

**Always check whether `main` has run ahead of the last release**, and by how
much:

```sh
TAG=$(gh api repos/OWNER/REPO/git/refs/tags/vX.Y.Z --jq .object.sha)
gh api "repos/OWNER/REPO/compare/$TAG...main" --jq '"\(.total_commits) commits, \(.files|length) files"'
```

A large gap means the branch carries unreleased, unannounced,
unchangelogged work. Read the release notes to see what the maintainer
*intended* to ship, and treat anything beyond the tag as work in progress.
Prefer the release tag's commit unless there is a specific reason to take
newer code.

## Step 3: quarantine triage

For each candidate, compute the age of the ref you would adopt. Anything
under 7 days is quarantined: report it, recommend holding, and let the user
decide. Note that for a repo that merges community pull requests in bursts,
the *commits* can be older than the *release* while the merge itself is
brand new. The merge is what you are adopting, so date it from the merge.

## Step 4: read the diff

Get the shape first, then read the parts that matter:

```sh
gh api repos/OWNER/REPO/compare/<old>...<new> > /tmp/cmp.json
jq -r '"\(.total_commits) commits  \(.files|length) files  +\([.files[].additions]|add)/-\([.files[].deletions]|add)"' /tmp/cmp.json
jq -r '.commits[] | "\(.sha[0:8]) \(.commit.committer.date[0:10]) \(.commit.message|split("\n")[0])"' /tmp/cmp.json
jq -r '.files[] | "\(.status[0:4]) +\(.additions)/-\(.deletions) \(.filename)"' /tmp/cmp.json
jq -r '.files[] | select(.filename=="package.json") | .patch' /tmp/cmp.json   # new deps
jq -r '.files[] | select(.filename|test("PATTERN")) | .patch' /tmp/cmp.json   # a specific file
```

Read the full patch for anything that:

- **adds a network listener or client**: `WebSocketServer`, `listen(`,
  `createServer`, `new WebSocket`, `fetch(`, `axios`
- **touches an existing security control**: anything named fence, guard,
  sanitize, allowlist, origin, csp, auth, token, or credential. A weakened
  check is easy to miss because the diff looks like a bug fix
- **executes or renders**: `child_process`, `spawn`, `eval`, `new Function`,
  `dangerouslySetInnerHTML`, template compilation
- **adds install-time behaviour**: `preinstall`, `postinstall`, `prepare`
- **adds a dependency**: check each new package's age, maintainer count, and
  whether the name is a plausible typosquat
- **persists secrets**: writes to a credentials service, keychain, or disk

For each finding, decide: is this feature justified, is it default-off, and
does it widen what an attacker who controls the model's output could do?
Report weakenings even when they are well-justified; the user decides
whether the trade is acceptable.

## Step 5: known issues

```sh
gh api repos/OWNER/REPO/security-advisories --jq length
gh api "search/issues?q=repo:OWNER/REPO+is:issue+is:open+security" --jq '.items[0:5][] | "#\(.number) \(.title)"'
```

Plus a web search for the project name with "vulnerability", "advisory",
"malicious", "compromised". Absence of advisories is weak evidence for a
young project; say so rather than implying it was audited.

## Step 6: report and decide

Bring the user a table of component, installed, available, age, and a
recommendation per item, plus the findings from step 4. Ask before changing
anything. Small hygiene changes with no functional delta (pinning a spec to
the commit already installed) can be bundled in, but say that you did.

## Step 7: apply

Edit the `ARG` pins in the `Dockerfile` and bump the `.seed-version` string
in the same `RUN`. The entrypoint only re-syncs `profiles/` when that string
changes, so forgetting it means the rebuild appears to do nothing.

Record provenance in the Dockerfile comment block: for each pin, what it is,
its date, when it was reviewed, and why it is that ref and not another.

For dsh itself, bump `DSH_VERSION`. For apple/container, bump
`CONTAINER_TARGET_VERSION` in `setup-host.sh` and re-run it.

Then regenerate the transitive tree, because the build installs it with
`--frozen-lockfile` and will refuse to proceed otherwise:

```sh
./scripts/refresh-lockfile.sh
git diff profile-pnpm-lock.yaml     # review it: this is a supply-chain change
./run.sh
```

`ERR_PNPM_OUTDATED_LOCKFILE` during a build means you changed a pin and
skipped this step. Read the lockfile diff rather than rubber-stamping it: a
plugin bump can drag in new transitive packages that were never reviewed.

## Step 8: verify

```sh
container logs dsh 2>&1 | grep -iE 'error|did not activate'    # boot clean?
grep -oE 'codeload\.github\.com/[^/]+/[^/]+/tar\.gz/[0-9a-f]{8}' dsh-home/profiles/web/pnpm-lock.yaml | sort -u
bat -pp dsh-home/.seed-version
./verify.sh                                                  # lockdown intact
```

Then exercise the thing you changed, in the UI, for real. A plugin that loads
is not a plugin that works: after pinning the search plugin, run an actual
search and read the results. If you removed a feature, confirm it is gone
(`find .../node_modules/<pkg>/lib -type f -name '*<feature>*' | wc -l`).

## Step 9: record

Update `docs/05-plugins.md` (inventory and pins), the pinning table in
`docs/03-operations.md`, and add anything surprising to
`docs/04-troubleshooting.md`. Note the review date next to each pin so the
next pass knows what was already read.

## Rolling back

Every update is one `ARG` line plus a `.seed-version` bump, so a rollback is
the same edit in reverse and a `./run.sh`. The volume's `profiles/` is
replaced wholesale from the image seed, so nothing from the bad version
survives. User state (`settings.yaml`, `cordis.patch.yml`, `skills/`,
`sessions/`) is untouched by the sync. If a plugin wrote itself into any of
those, remove it by hand.

## Worked example: 2026-08-24

The pass that produced this file, kept because the failure mode is the point.

Current and needing nothing: apple/container 1.2.2, dsh 0.1.1-rc.2,
dsh-mcp-client 0.0.1-rc.1, supergateway 3.4.3, deep-research (branch
unchanged, PR #5 still open upstream). No advisories on any repo.

**dsh-web-tools: the finding.** Its Dockerfile spec was
`github:A3Boy/dsh-web-tools` with no ref. That day's rebuild resolved it to
`cf6f3cef`, and the lockfile proved we were running it. Reading the history:
v0.2.0 was tagged 2026-08-22 with release notes describing a settings-UI
refresh and a background update check. But `main` was **19 commits and 118
files past that tag**, and those unreleased commits added a browser-bridge
subsystem: an MV3 browser extension, a pairing relay with a persisted
credential, and a WebSocket upgrade route registered *unconditionally* at
plugin load. Verified by fetching `src/host/sources/bridge-server.ts` at both
refs: 404 at the tag, 200 on main.

Nothing was announced because nothing was released. A search adapter had
grown a browser-remote-control endpoint inside the box purely because the
spec floated. Resolution: pin to the v0.2.0 tag's commit
`4e319e9cea48d79a6747e9113fedf168aab2cb06`. Search was unaffected (SearXNG is
still a first-class provider; all four config keys unchanged), the bridge
files are gone from the install, and a live search returned correct results
in 11 seconds.

Incidentally, v0.2.0's "silent background update check" phones GitHub
Releases, and the lockdown drops it, since GitHub is not in the squid
allowlist. The posture doing its job without being asked.

**better-sidebar: held.** v0.16.0 was available: 48 commits, +3981/-189,
including a twelve-contributor pull-request train merged in a single burst
the day before. The security-relevant parts reviewed well. The new
markdown-HTML renderer uses DOMPurify with an explicit denylist
(no `script`/`iframe`/`form`, no `srcdoc`/`formaction`) and the new loopback
allowlist is opt-in with default-deny preserved. One genuine weakening: the
trust fence changed Origin comparison from `host` to `hostname`, so any other
port on localhost now passes it, justified by an Edge 151 serialization bug
and documented honestly in the code. With the release zero days old, the
recommendation was to hold and re-diff after 2026-08-31. Pin stayed at
`4c0da81`.

**Images and the npm tree, pinned the same day.** The three container images
(`node:24-bookworm`, searxng, crawl4ai) moved from moving tags to digests,
taken from the images already running and verified, not from whatever the
registry served at that moment, which would have silently adopted a two-day-old
SearXNG. The ~260-package transitive tree moved into a committed
`profile-pnpm-lock.yaml` installed with `--frozen-lockfile`, closing the last
gap where a pinned plugin could still pull a changed dependency.

**Bundled hygiene.** deep-research moved from a branch ref to that branch's
commit, and dsh-mcp-client from an unversioned spec to `0.0.1-rc.1`. Both
were the code already installed, zero functional change, done so the next pass has
something immutable to diff against.

## Worked example: 2026-09-01, apple/container 1.2.2 to 1.3.1

Triggered by a disk investigation rather than a scheduled pass, which is worth
noting: the runtime is the one pin nothing else reminds you about.

**Why.** 1.3.1 is a security patch fixing six advisories in Containerization,
four of which matter directly to a box whose whole premise is that the agent
cannot reach the host:

| Advisory | What it is |
|---|---|
| GHSA-x7pf-2jmj-pgcq | unchecked ID allows file deletion outside the container bundle |
| GHSA-f689-h8m7-3jp2 | unvalidated OCI descriptor digests allow path traversal |
| GHSA-r3h2-rgqf-9hv9 | symlink handling allows reading host files |
| GHSA-mx96-5vvg-x2mg | CVE-2026-65388, `RegistryClient` follows an unvalidated `WWW-Authenticate` realm |
| GHSA-697p-8837-37h3 | crafted image layer crashes on a long filename |
| GHSA-g3rx-2m58-rr63 | extended-attribute crash on invalid length names |

The first three are container-to-host reads and writes. The fourth matters
because this project pulls images by digest from a registry.

**Breaking changes checked.** 1.3.0 removed `--scheme auto` for image
operations and made HTTPS the default. This repo never passes `--scheme`; the
whole CLI surface used here is `container build`, `ls`, `network create`,
`run`, and `system start`/`stop`, none of which changed. 1.3.0 also relaxed
`maskedPaths` and `readonlyPaths` for container machines, which does not touch
the pf-based egress lockdown.

**Not fixed by this bump.** The snapshot leak
([#2164](https://github.com/apple/container/issues/2164)) is still open and
was filed against main after 1.3.1. Expect to keep running
`container image prune`. See [03-operations.md](03-operations.md).

**Applying it.** `CONTAINER_TARGET_VERSION` in `setup-host.sh` is now `1.3.1`.
Run `./setup-host.sh` to install it: it stops the container system, installs
the signed pkg, and re-lays the pf anchor and relays. Then `./run.sh` and
`./verify.sh`.
