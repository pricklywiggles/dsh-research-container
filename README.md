# dsh-research-container: DeepSeek Harness in a locked-down Apple container

A Debian VM-container (Apple `container` runs each container in its own
lightweight VM) with the DeepSeek Harness (`dsh`), Node 24, and general dev
tooling. Egress is default-deny, enforced on the macOS host with pf, so the
harness and anything it loads can only reach what you explicitly allow. The
container reaches exactly four things, all on the vmnet gateway:

- `192.168.66.1:8090`, a socat relay to your model server (`MODEL_HOST`)
- `192.168.66.1:3128`, a squid proxy gated by a domain allowlist
- `192.168.66.1:8888`, a socat relay to a self-hosted SearXNG. Web search for
  the agent; queries never leave your infrastructure.
- `192.168.66.1:8890`, a socat relay to a self-hosted Crawl4AI. It turns a URL
  into rendered markdown through its built-in MCP server, so no third party
  sees what the agent reads.

The subnet and all four ports are configurable. Those are the defaults.

Everything else leaving `192.168.66.0/24` is dropped by the `dsh-egress` pf
anchor. Telemetry needs no per-app hunting: unallowlisted destinations simply
never connect.

Full documentation (architecture, security posture, operations,
troubleshooting, plugin vetting, skills, dsh internals) lives in
[docs/](docs/README.md).

## Requirements

Apple silicon and macOS 26 or newer, which apple/container's networking needs.
Homebrew, which `setup-host.sh` uses to install squid and socat. `jq` and
`python3` ship with current macOS. apple/container is installed for you.

You also need an OpenAI-compatible model server the Mac can reach. llama.cpp,
Ollama, and LM Studio all work, on the same Mac or another machine. The container
never talks to it directly; a relay on the gateway does.

## One-time setup

Five commands, in this order. Each one needs the output of the one before it.

```sh
./setup.sh        # 1. interactive config; writes config.env
./doctor.sh       # 2. read-only preflight against that config; fix any FAIL
./setup-host.sh   # 3. prompts for sudo; installs apple/container, squid, socat,
                  #    the relays, and the pf anchor; generates secrets.env
./run.sh          # 4. network + image build + containers; prints the UI URL
./verify.sh       # 5. proves the lockdown works
```

1. `setup.sh` probes for your model server, reads its model list, and checks
   ports and subnets against what your Mac already uses. Everything it writes
   lands in `config.env`, documented field by field in `config.example.env`.
   Re-run it any time; your current answers become the defaults.
2. `doctor.sh` checks hardware, macOS version, disk, commands, the subnet,
   every port, and whether the model server answers, all read from
   `config.env`. It changes nothing and never asks for sudo. Warnings about
   apple/container, squid, or socat being absent are expected at this point;
   the next step installs them.
3. `setup-host.sh` is the only step that touches the host. On a first run it
   also generates `secrets.env` (two random values for Crawl4AI and SearXNG,
   mode 0600, never printed) and renders the host templates. Later runs keep
   the existing secrets. Run it as your normal user; it asks for your password
   itself.
4. `run.sh` refuses to start without `config.env` and `secrets.env`, which is
   why steps 1 and 3 come first. The first build takes a few minutes.
5. `verify.sh` needs the box running.

Then open **http://127.0.0.1:3080**. Type the IP form, not `localhost`: the
publish binds IPv4 loopback only, and apple/container cannot publish v4 and v6
on the same host port. In the workspace picker, click the pencil icon and type
`/workspace` — the picker opens in the container's (empty) home directory and
`/workspace` is not browsable from there.

Then type `/research <your topic>` in the chat box. That command — and the
`/deep-research` family next to it — is what this box exists for: deep,
cited web research where no query, page fetch, or model token ever leaves
your own infrastructure. [Research skills](#research-skills) describes them.

## Allowing a destination

Domains (dev traffic: npm, GitHub, and the like). Edit
`$(brew --prefix)/etc/squid-dsh-allowlist.txt`, then
`$(brew --prefix)/opt/squid/sbin/squid -k reconfigure`. In-container tools pick
the proxy up from `HTTP_PROXY`/`HTTPS_PROXY` automatically.

Raw IPs and ports: add a `pass in quick` rule to
`host/templates/dsh-egress.pf.conf.tmpl` and re-run `./setup-host.sh`, which
re-renders the anchor and reloads it. Editing `host/rendered/dsh-egress`
directly works for a quick test, but the next render overwrites it.

## Web research

The agent searches through the [dsh-web-tools](https://github.com/A3Boy/dsh-web-tools)
plugin (baked into the image at build time; the entrypoint syncs it into the
`dsh-home` volume via `.seed-version`) pointed at a self-hosted SearXNG
metasearch instance. SearXNG runs as a second container on the *open* default
network, published to host loopback :8888; the dsh container reaches it only
through the gateway relay. Its config is rendered to
`host/rendered/searxng/settings.yml` (JSON API on, limiter off) from
`host/templates/searxng-settings.yml.tmpl`, which is the file to edit if you
want the change to survive. `dsh-home/settings.yaml` already points the plugin
at the relay, so there is nothing to set in the UI. No API keys, and search
queries stay on your machines.

Page fetching runs through a self-hosted [Crawl4AI](https://github.com/unclecode/crawl4ai)
container (same trust pattern: open network, gateway relay on 8890; image
derived in `host/crawl4ai/` to bind non-loopback, token auth). Its built-in
MCP server speaks SSE, so a supergateway stdio bridge (baked into the image)
connects it to `@deepseek-ai/dsh-mcp-client`, mounted as a row in
`dsh-home/cordis.patch.yml`. The mcp-client is a raw plugin rather than a
bundle, and the home patch layer survives seed syncs. The agent gets
`mcp__crawl4ai__*` tools (markdown-from-URL, screenshots, crawling) and uses
them: ask it to research something and it searches via SearXNG, reads pages
via Crawl4AI, and cites them.

dsh-web-tools also ships a generic `web_fetch` tool, but every fetch-capable
provider behind it is deliberately unconfigured here (Crawl4AI is the
fetcher), so this box disables its registration outright: the `tool-web` row
in `host/templates/cordis.patch.yml.tmpl` sets `fetch: false`. Without it,
each research turn logged a red "registered but unavailable" error before
falling back to Crawl4AI, and the skills had to carry a prompt-level "do not
use Fetch" warning that a looping model would eventually ignore.

The [@dsh-external/dsh-deep-research](https://github.com/omdsh-dev/dsh-deep-research)
orchestrator is also baked in (pinned to the PR #5 branch) but does NOT work
on dsh 0.1.1-rc.2's web profile: its `deep_research` tool cannot reach the
preset-isolated workflowEngine from host scope. Agent contexts do not inherit
preset realm labels, confirmed via a Creator-mode inspection session, and even
`agentPresets.serviceForAgent` resolution failed in practice. Multi-page cited
research works fine without it via the search+fetch loop above.

## Research skills

The reason this box exists: slash-invocable research commands that replace
hosted deep-research tools, running entirely on infrastructure you control.
They are dsh's Claude-style SKILL.md dirs, live-discovered from
`dsh-home/skills/` — type `/` in the chat box to see them.

- `/research <topic>` runs a one-shot deep exploration with pacing, fetch
  fallbacks, and a cited gaps-and-contradictions report.
- The `/deep-research` family is a port of
  [Weizhena/Deep-Research-skills](https://github.com/Weizhena/Deep-Research-skills):
  structured items×fields research with human-in-the-loop checkpoints.
  Flow: `/deep-research <topic>` (outline as outline.yaml + fields.yaml in
  /workspace) → `/deep-research-add-items` / `-add-fields` (refine) →
  `/deep-research-run` (parallel researcher subagents write validated JSON
  per item) → `/deep-research-report` (markdown report, uncertain values
  skipped). The researcher briefing + search-strategy modules live in
  `dsh-home/skills/deep-research/`.

## Loop guard: dsh-circuit-breaker

Local models in agent loops fail in one specific way: degenerate repetition.
Building this box, two research subagents went past a thousand tool calls
each, one query repeated 555 times, with every call succeeding and nothing
erroring. One of them had just read a briefing capping it at 12 searches.
Prompts do not reach a model in that state, so the guard is code.

[dsh-circuit-breaker](https://github.com/pricklywiggles/dsh-circuit-breaker)
registers through dsh's synchronous pre-execution check and denies a tool
call once the same tool has run with the same significant arguments too many
times. It also caps calls per agent and appends every denial to
`workspace/.circuit-breaker-incidents.jsonl`, which is how a parent agent
notices a tripped subagent (the `/deep-research-run` skill watches it). The
Dockerfile installs it at build time from the public repo, pinned to a
reviewed commit, so it is active on first boot with nothing to set up. Its
config lives in the `circuit-breaker` row of `dsh-home/cordis.patch.yml`
(rendered from the template in `host/templates/`); a `circuit-breaker:`
section in `settings.yaml` does not reach it. Background and measurements are
in `docs/10-qwen-and-local-models.md`.

## UI: better-sidebar

[DSH-better-sidebar](https://github.com/omdsh-dev/DSH-better-sidebar) adds a
workbench beside the conversation: file tree + CodeMirror editor, a real pty
terminal, Source Control, Tasks, Side Chat, and an embedded browser. Pinned in
the Dockerfile to the exact commit that was security-reviewed (`SIDEBAR_SHA`).
Never float it to a branch: the plugin runs in-process with filesystem and pty
access, so an unreviewed update is an unreviewed shell in the box. Re-review
before bumping.

pnpm blocks build scripts from git dependencies, so the Dockerfile appends an
`allowBuilds` entry (for that exact SHA, plus `node-pty`) to the seed
profile's `pnpm-workspace.yaml` before installing. node-pty has no linux-arm64
prebuild and compiles from source via node-gyp, which is why `build-essential`
and `python3` are in the image. Without the compile the plugin still loads,
just with the terminal disabled ("degraded mode").

## Daily use

```sh
container exec -it dsh bash        # shell in the box (rg, fd, bat, jq, git,
                                   # python3, pipx, pnpm preinstalled)
container logs dsh                 # dsh server output
./run.sh                           # rebuild + replace the containers
./stop.sh                          # stop it all and hand the memory back
./doctor.sh                        # what is installed and what is not
```

`./stop.sh` stops the containers and the container runtime, which is the part
that matters: stopping containers alone leaves the builder VM and the apiserver
holding memory. Pass `--cache` to also delete the build cache and reclaim tens
of GB, at the cost of one cold build.

State that survives a rebuild: `workspace/` (your files) and `dsh-home/`
(dsh settings + credentials), both plain dirs here. Delete them for a truly
fresh start.

`./run.sh` recreates all three containers rather than restarting them, because
a container freezes its ports, mounts, and env at creation. Restarting one
would silently keep whatever config it was born with.

## Upgrading

- dsh: bump `DSH_VERSION` in the `Dockerfile`, `./run.sh`. It's a developer
  preview; expect breaking changes, upgrade deliberately.
- apple/container: bump `CONTAINER_TARGET_VERSION` in `setup-host.sh`, re-run it.
- Plugins and images are pinned to immutable refs. Moving a pin is four
  steps: edit the `ARG` in the `Dockerfile`, bump the `.seed-version` string
  in the same `RUN` (the entrypoint only re-syncs plugins when it changes),
  run `./scripts/refresh-lockfile.sh` and read its diff, then `./run.sh`.
  Skipping the refresh fails the build with `ERR_PNPM_OUTDATED_LOCKFILE`,
  on purpose. `docs/09-updating.md` is the review discipline around those
  four steps: what to read upstream before you move a pin, how long to
  quarantine a fresh release, and how to verify and roll back.

Rotate the two generated secrets with `./scripts/rotate-secrets.sh`, then
`./run.sh`. The values go straight into `secrets.env` and are never printed.

## What setup-host.sh touches (and teardown-host.sh reverts)

- `/etc/pf.anchors/dsh-egress`, `/usr/local/etc/pf-dsh.conf` (new files; the
  wrapper `include`s `/etc/pf.conf`, which is **never edited**)
- `/Library/LaunchDaemons/$LABEL_PREFIX.{pf,dsh-model-relay,dsh-searxng-relay,dsh-crawl4ai-relay}.plist`
- Homebrew: squid + socat, squid.conf (original backed up as `squid.conf.pre-dsh`)

No changes to system DNS, routes, macOS proxy settings, or the application
firewall. Every pf rule is scoped to your container subnet (plus its v6 twin),
which exists only on the container bridge, so host traffic can never match. If
the anchor ever fails to load, the failure direction is "container gets more
access", never "Mac loses network". `./teardown-host.sh` restores the exact
pre-setup state, including whether pf was enabled.

## Notes

- The dsh UI only binds loopback in-container (upstream has no remote auth
  yet); the entrypoint relays it to :3081 on the vmnet, and `container run`
  publishes that to the Mac's 127.0.0.1:3080. Always browse via 127.0.0.1. On
  any other origin (the container IP, for instance) the browser withholds
  `crypto.randomUUID` and the workspace picker breaks. LAN machines cannot
  route to the container subnet.
- The model relay crash-loops quietly (15s backoff) until the dshnet bridge
  exists, i.e. until the first container starts. That's expected; the log is at
  `$(brew --prefix)/var/logs/$LABEL_PREFIX.dsh-model-relay.log`.
- Image builds run in the builder VM on the *default* network, so rebuilds pull
  apt/npm freely without loosening the runtime lockdown.
- Container-side DNS is effectively dead: the pf anchor only allows the gateway
  resolver, and on macOS 27 that forwarder doesn't answer anyway. Nothing needs
  it. Squid resolves hostnames on the host (proxy CONNECT), and the model is
  reached by IP. Builds use `--dns 1.1.1.1` since the builder VM does need real
  DNS. A DNS exfiltration channel therefore doesn't exist right now; if a later
  macOS fixes the gateway resolver, comment out the port-53 rule in
  `host/templates/dsh-egress.pf.conf.tmpl` to keep it closed.
