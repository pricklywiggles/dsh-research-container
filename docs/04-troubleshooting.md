# Troubleshooting

Every problem hit while building this project, as symptom → cause → fix. Newest
learnings are not at the bottom; entries are grouped by area.

Diagnose in this order: model server → relays and squid (test from inside
the container with `container exec dsh curl ...`) → pf rules
(`sudo pfctl -a dsh-egress -sr`) → dsh itself (`container logs dsh`).

## Host setup

**`sudo: a terminal is required to read the password`** when running a
script from Claude Code's `!` prefix. The `!` runner has no TTY. Both host
scripts now detect this and fall back to a macOS password dialog via an
osascript askpass helper. Or just run them from a real terminal.

**`Error: Running Homebrew as root is extremely dangerous`**. Someone ran
`sudo ./setup-host.sh`. The scripts must run as your normal user; they
escalate themselves only where needed. Both now refuse to start under root.

**Relay daemon shows `state = spawn failed`, `last exit code = 78: EX_CONFIG`**.
launchd could not create the daemon's log file. `/Library/Logs` is
`root:wheel 755` on this macOS and the relays run as your user, so their
`StandardErrorPath` had to move to `$(brew --prefix)/var/logs/`.

**Relay log full of bind failures**. Normal whenever no dshnet container is
running; the gateway IP does not exist until the bridge does. KeepAlive
retries every 15s.

**`as_root` output polluting a pipeline** (pf state recorded as `no` when
it was `yes`). The announcement line was printed to stdout and swallowed by
`head -1`. It now prints to stderr.

**`~/Library/Application Support/com.apple.container` has grown to tens of
GB**. Expected, and not your fault. apple/container abandons the previous
snapshot every time a build replaces a tag, so each `./run.sh` strands about
4 GB. `container system df` shows the reclaimable figure and
`container image prune` recovers it. Upstream bug
[#2164](https://github.com/apple/container/issues/2164); the full procedure,
including the buildkit cache, is in
[03-operations.md](03-operations.md).

**A container starts by hand but `container start` fails on a mount path**.
Its definition predates a change to that path. A container freezes its ports,
mounts and env at creation, so a rewrite that moves a mounted file leaves the
old container pointing at nothing. `run.sh` recreates all three containers on
every run for exactly this reason; a container created before that change, or
by hand, needs `container rm <name>` once.

**Probing the gateway from inside the container reports every port closed**.
If the probe used `container exec dsh sh -c '... /dev/tcp/...'`, that is a
false negative: Debian's `/bin/sh` is dash, which has no `/dev/tcp`. Use
`container exec dsh bash -c` or curl.

## Networking and DNS

**Image build fails with `Temporary failure resolving 'deb.debian.org'`**
while the base image pulled fine. The builder VM's resolver is the vmnet
gateway (192.168.64.1), and on macOS 27 (build 26A5421a) with
apple/container 1.3.1 nothing answers on it (the apiserver's DNS resolver binds `127.0.0.1:2053`
instead). Raw TCP egress works; only DNS is dead. Fix: `--dns 1.1.1.1` on
`container build` and on every open-network `container run`. Already in
`run.sh`.

**Container-side DNS in the dsh container is dead**. Same cause, and
irrelevant: squid resolves names on the host for CONNECT, the model and
relays are reached by IP. Tools that must resolve a name locally before
using the proxy will fail; nothing we use does.

**Host probes to 192.168.66.x fail with `No route to host` or hang, while
the same request works from inside the container**. macOS Local Network
privacy (TCC) gates the Claude Code shell. It is not a real network problem.
Test container networking from inside: `container exec dsh curl ...`. Your
browser gets the permission prompt once and then works.

**`http --timeout ... GET http://192.168.66.1:8090` times out from the
host** even with nothing bound. Same TCC gating; do not diagnose relays from
the sandboxed shell.

**`container run` fails: `host ports for different publish port specs may
not overlap`**. You tried to publish `127.0.0.1:3080` and `[::1]:3080`.
apple/container cannot publish one host port on both loopbacks. Publish
IPv4 only and browse the IPv4 literal.

**Web research dies but the lockdown still passes: searxng returns zero
results, and even a raw-IP curl from the crawl4ai container times out**. A pf
reload flushed the vmnet NAT. apple/container injects its NAT for the open
`default` network at runtime into pf's `com.apple` anchor, and any full
`pfctl -f` reload (setup-host.sh step 6, or the pf watchdog restoring the
egress anchor) clears it. Only the locked network relies on the host relays,
so `verify.sh` stays green and the breakage is silent. Confirm from inside a
default-network container: a raw-IP `curl` that returns `000` means NAT is
gone. Fix: bounce the container system so it re-injects,
`container system stop && container system start`, then `./run.sh`.
setup-host.sh now does this bounce itself after reloading pf.

## The UI

**Workspace picker shows `crypto.randomUUID is not a function` and an empty
list**. You opened the UI on a non-localhost origin (e.g. the container IP).
Browsers withhold `crypto.randomUUID` outside secure contexts (HTTPS or
localhost). Browse `http://127.0.0.1:3080`, which is why the port is
published to loopback in the first place.

**`unable to connect` in the browser**. One of: you typed `localhost`
(resolves to `::1`, not published); you used an old container-IP URL (the
IP changes on recreate); or the container was mid-restart. Use
`http://127.0.0.1:3080`.

**UI unreachable on the published port even though dsh is running**. dsh
binds `127.0.0.1:3080` only and rejects `--host 0.0.0.0`. The entrypoint runs
`socat TCP-LISTEN:3081,fork,reuseaddr TCP:127.0.0.1:3080` and the publish
targets 3081. If socat is missing from the image, this breaks.

**Selecting a preset silently reverts to Standard; console shows
`[web-runtime] connection lost, retry`**. The preset failed validation at
mount and dsh rolled the runtime back. In our case a custom preset published
`workflowEngine` at the preset root, which the `leakedServices` guard
rejects. Nothing is logged to stdout. Check with the browser console.

**New session runs the wrong preset**. New sessions inherit the composer's
last-selected preset. Verify the mode button label before sending. To check
what a past session used:
`zstd -dc dsh-home/sessions/--workspace--/session-*/session.jsonl.zstd | grep -oE 'agentPreset":"[a-z]+'`.

## dsh runtime

**Every bash tool call fails with `sandbox mode "workspace-write" is
requested but no sandbox backend is usable on this host`** or asks to
escalate to `danger-full-access`. dsh's inner sandbox needs Landlock or
bubblewrap; the VM kernel has neither. Two fixes: switch the session's
access mode to Full access (the composer's access-mode button, with a
one-time risk checkbox), now the default via
`permission.defaultPreset: danger-full-access` in `settings.yaml`; or add
`bubblewrap` to the image to make the inner sandbox work. We chose full
access: the VM plus pf is the real sandbox, and the only asset the inner one
protected was `dsh-home/` from the agent itself.

**Boot fails: `plugin tree failed to load: 1 entry did not activate ...
pending (waiting for service: workflows)`**. A plugin injects a service no
row provides. Cordis treats static injections as hard requirements; one
unresolved injection hangs the whole profile. For dsh-deep-research the
cause was the plugin targeting a service (`workflows`) that current dsh
renamed to `workflowEngine`. Fix was pinning to the PR branch that resolves
the engine from the agent scope. General rule: read the pending entry's
`inject` list and find who provides each name (or nobody does).

**Boot fails: `profile bundle "X" declares no dsh.bundle in its
package.json`**. You added a raw cordis plugin to the profile's `bundles`
list. Only packages with `dsh.bundle` metadata go there. Raw plugins mount
as a row in `dsh-home/cordis.patch.yml`. See [05-plugins.md](05-plugins.md).

**`dsh plugin add` succeeded but the plugin is inert** (e.g.
`@deepseek-ai/dsh-mcp-client`). Same thing: it landed in `dependencies` but
not in `bundles`, and it is not a bundle anyway. Mount it via a patch row.

**Settings edits made in the UI do not take effect**. Some plugins read
config at activation. Restart: `container stop dsh && container start dsh`.

**`deep_research requires an Agent preset with workflowEngine`**. The
`deep_research` tool from dsh-deep-research cannot work on the web profile
in rc.2: the engine is mounted inside each preset's isolated realm and agent
contexts do not inherit preset realm labels, so host-scope lookups fail
whatever the preset does. Confirmed by a Creator-mode inspection session and
by trying `agentPresets.serviceForAgent`. Use the `/deep-research` skill
family instead, which is why it exists.

**Parent session polls `job_list` forever with `Error: unknown job <id>`
after launching a subagent; sidebar says "1 subagent running"; nothing
completes**. dsh delivers subagent completions between the parent's turns.
A parent that busy-waits inside one turn (bash `sleep` loops, polling
`job_list` or `list_agents`) starves the notification it is waiting for.
`job_list` is a different subsystem; the id is legitimately unknown to it.
Recovery: click "Stop generating" on the parent, which ends the turn and
lets the queued completion land, then tell it to continue. Prevention is
written into the deep-research skills: end the turn after launching.

**Agent claims "search provider is down" but curl from the container
works**. dsh-web-tools puts a provider in fail-fast cooldown after a network
error (typically from a container restart tearing the bridge mid-search).
It expires on its own. Or SearXNG returned zero results, which the plugin
reports as empty rather than as an error; see the web research section.

## Plugins and builds

**`ERR_PNPM_GIT_DEP_PREPARE_NOT_ALLOWED`** during the image build. pnpm
refuses to run a git-hosted dependency's build script until its exact key
(`name@https://codeload.github.com/owner/repo/tar.gz/<sha>`) is under
`allowBuilds:` in the profile's `pnpm-workspace.yaml`. The Dockerfile appends
that line before `dsh plugin add`. The error message prints the exact key to
use.

**Terminal panel says degraded / no pty**. `node-pty` did not compile. It
has no linux-arm64 prebuild and builds via node-gyp, so the image needs
`build-essential` and `python3` (present) and `node-pty: true` under
`allowBuilds` (present). Check for
`profiles/web/node_modules/node-pty/build/Release/pty.node` in the volume.

**A hand-patched file in `dsh-home/profiles/` disappeared**. Expected: the
entrypoint replaces `profiles/` whenever `.seed-version` changes. Patches
must live in the Dockerfile (applied to the seed) to survive.

**Wrong package: `@deepseek-ai/dsh-workflow-workerthread` does not exist on
npm**. The real package is `dsh-workflow-worker-thread` (hyphenated); some
plugin READMEs use the unhyphenated name. Neither provides a service called
`workflows`.

## Web research

**`SearXNG unreachable at http://192.168.66.1:8888: TypeError: fetch
failed`**. Usually transient after a dsh container restart (bridge blip
during a search), then held by the plugin's cooldown. Check the path from
inside the container; if `curl` gets 200 there, wait a few minutes or
restart dsh.

**Searches succeed but return zero results**. Upstream engines suspended
the IP: `curl -s 'http://127.0.0.1:8888/search?q=test&format=json' | jq
.unresponsive_engines` shows `too many requests`, `CAPTCHA`, `timeout` per
engine. Agent bursts trigger this. Suspensions expire on their own. Engine
diversity in `host/templates/searxng-settings.yml.tmpl` keeps results flowing meanwhile.

**Mojeek returns zero for everything, no error**. Mojeek captcha-walls the
IP and SearXNG does not recognise its captcha page, so it reports empty
instead of suspended. Solving the captcha in your browser does not help:
Mojeek's clearance is cookie-scoped, not IP-scoped (verified with a
cookie-less request after solving). Wait it out, or wait for SearXNG's
browser-impersonation work to ship.

**Crawl4AI: `Connection reset by peer` on the published port**. Crawl4AI
0.9.2 binds `127.0.0.1` by default and its startup guard refuses a
non-loopback bind without `CRAWL4AI_API_TOKEN`. The derived image in
`host/crawl4ai/` bakes a `config.yml` with `app.host: 0.0.0.0` and `run.sh`
sets the token. Single-file bind mounts were unreliable, hence the derived
image.

**No `mcp__crawl4ai__*` tools, and `container logs dsh` shows
`SSE error: ... ECONNREFUSED 192.168.66.1:8890` followed by
`[supergateway] stdin closed. Exiting...`**. A startup race, not a config
problem. supergateway opens its SSE connection once while dsh boots and exits
for good when that connect is refused, so the agent loses every fetch tool
while the UI, the model, and `verify.sh` all still look healthy. Crawl4AI has
a Chromium to start, so dsh wins the race whenever both come up together.

Two gates now cover it. `run.sh` waits for `/health` on the published crawl4ai
port before creating dsh, and `entrypoint.sh` waits again inside the container
before starting the server. The second one matters because the first only
covers the `run.sh` path: a container system restart, a plain `container start`,
or an automatic restore after a reboot brings everything up at once and loses
the race exactly the same way. Seen live on 2026-09-05, when the containers
restarted outside `run.sh` and the agent silently had no fetch tools.

The entrypoint reads the SSE URL out of the same `cordis.patch.yml` row
supergateway uses, so the two cannot drift, and it warns and boots anyway if
crawl4ai never answers. Confirm with `container logs dsh | grep -c tools`,
which should be non-zero; zero means the bridge never negotiated. Restarting
dsh once crawl4ai answers is always a safe manual fix.

**dsh MCP client cannot connect to Crawl4AI**. Crawl4AI's MCP is SSE only;
dsh speaks stdio and streamable HTTP. `supergateway` (global npm in the
image) bridges: the patch row runs
`supergateway --sse http://192.168.66.1:8890/mcp/sse --header "Authorization: Bearer ..."`.
Test the bridge by hand: `container exec dsh timeout 10 supergateway --sse ... --header ...`
should print `SSE connected`.

**dsh-web-tools: `web search failed after 1 attempt(s): no usable
provider`** with SearXNG configured correctly. Upstream bug: the keyless
SearXNG path falls through into the key-health filter, and an empty key pool
is "unhealthy". Workaround: `WEB_TOOLS_SEARXNG=local` in the container
environment (credential ref `WEB_TOOLS_<SUFFIX>` is read from env; SearXNG
ignores the resulting `api_key` param). Also `fallbackOrder` must list
`searxng`; the UI's order editor can leave it empty.

**`configured web provider "dsh-web-tools-fetch" is registered but
unavailable`**. Cosmetic. dsh-web-tools' own fetch needs a fetch-capable
provider (all hosted APIs) and every one hardcodes its endpoint, ignoring
the base-URL override. Page reading goes through the Crawl4AI MCP tools
instead; the skills say so.

## Research loops and hallucinated premises

**A research subagent runs for tens of minutes, repeating the same searches,
and will not recover even when told it is looping.** Diagnosed 2026-08-25 from
session `5e1cd694`: 622 steps, 626 tool calls, 33 minutes, 1,200 search
queries of which only 74 were distinct. Two queries repeated 555 times each,
verbatim. Every search returned results; nothing failed.

Root cause is a hallucinated premise, not a search failure. qwen38 did not
know the topic (the font Wotfard), confabulated a confident and wrong identity
for it (a blackletter typeface, by the wrong designer, at the wrong
foundry), and that false premise was written
into the subagent's task as fact. The subagent then searched for something
that does not exist, could never converge, and degenerated into verbatim
repetition. The loop began at step 28, *before* the first compaction, so
context pruning did not cause it. The six compactions that followed
erased the evidence of repetition, which is why telling it "you are in a
loop" did not help.

The same model, harness and skill behaved normally in a sibling session
(`13dcbba7`: 60 steps, 10 queries, 10 distinct) when the premise was merely
imprecise rather than impossible. So the trigger is an unsatisfiable goal.

Fixed in the skills 2026-08-25: a mandatory premise-grounding step that
requires reading the entity's official page before writing any framework, the
premise surfaced as the first human checkpoint question, the verified premise
propagated into subagent prompts, plus hard budgets (12 searches, 15 page
reads), a never-repeat-a-query rule, a two-strikes stop, and an explicit
"question the premise" instruction. Verified by re-running the original query:
the model now reads atipofoundry.com first and correctly identifies Wotfard as
a humanist sans, then asks for confirmation.

Model-side causes, tuning, and how to stop a runaway subagent are covered in
[10-qwen-and-local-models.md](10-qwen-and-local-models.md).

Contributing factors worth knowing: `--presence-penalty 1.5`
cannot prevent turn-level loops at all, because llama.cpp applies penalties
over `--repeat-last-n` (default 64 tokens), so it never sees a repeat that spans
turns. Raising `--repeat-last-n` and enabling the DRY sampler address that.
dsh itself has no loop detection or step cap, so nothing external stops a
runaway subagent.

## Model

**Chat completions hang with zero bytes while `/v1/models` answers
instantly**, even when called directly from the Mac. The llama.cpp box is
loading or wedged. Nothing on this side; check that machine.

## Tooling

**A command that works on the Mac fails inside the container, or vice versa**.
The image installs `bat`, `fd`, `jq`, `procps`, `ripgrep`, and `socat`; it does
not install `eza`. The host scripts assume only what macOS ships, so they use
`grep` and `find` rather than `rg` and `fd`. Keep that split in mind when
copying a command from one side to the other.

**Driving these scripts from an agent or CI**. `setup.sh` needs a real
terminal and refuses without one. `setup-host.sh` needs sudo and falls back to
a macOS password dialog when it has no TTY. Neither may run under `sudo`
directly.
