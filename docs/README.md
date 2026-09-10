# dsh box documentation

Everything learned building and running this setup: a DeepSeek Harness
(dsh) agent in an Apple `container` VM with default-deny egress enforced on
the macOS host, plus a self-hosted web research pipeline.

If you read one file, read [01-architecture.md](01-architecture.md). If
something is broken, go straight to
[04-troubleshooting.md](04-troubleshooting.md).

| File | What it covers |
|---|---|
| [01-architecture.md](01-architecture.md) | Components, networks, ports, data flows, and why each decision was made |
| [02-security-posture.md](02-security-posture.md) | Threat model, what each layer enforces, what it does not cover, host safety guarantees, secrets, incident response |
| [03-operations.md](03-operations.md) | Daily commands, what persists vs what is disposable, rebuilds, upgrades, allowlisting, logs, pinning status, maintenance checklist |
| [04-troubleshooting.md](04-troubleshooting.md) | Every problem hit so far: symptom, cause, fix |
| [05-plugins.md](05-plugins.md) | What is installed, how dsh plugins actually load, how to install the next one, the vetting checklist |
| [06-skills.md](06-skills.md) | dsh skills, the `/research` and `/deep-research` workflows, how to write more |
| [07-web-research.md](07-web-research.md) | SearXNG + Crawl4AI pipeline, rate limiting realities, tuning knobs |
| [08-dsh-internals.md](08-dsh-internals.md) | Non-obvious facts about dsh itself (rc.2): profiles, presets, cordis realms, config keys, UI quirks |
| [09-updating.md](09-updating.md) | The agent-driven procedure for updating plugins and the harness: inventory, quarantine, diff review, verification, rollback |
| [10-qwen-and-local-models.md](10-qwen-and-local-models.md) | Running Qwen3.8/local models as the agent: vendor sampling values, why penalties miss agent loops, KV cache and DRY regressions with measurements, post-restart verification, diagnosing and stopping runaway subagents |

## Sixty-second orientation

- The agent lives in the `dsh` container on the isolated `dshnet` network.
  It can reach four ports on the network gateway (`192.168.66.1`) and nothing
  else: squid proxy (3128), model relay (8090), SearXNG relay (8888),
  Crawl4AI relay (8890). The macOS pf firewall drops everything else.
- SearXNG and Crawl4AI run as separate containers on the open `default`
  network because they must talk to the real internet. The agent only reaches
  them through the relays.
- The model is an OpenAI-compatible server at `MODEL_HOST` (`qwen38` by
  default). The host relays to it; the container never sees that network.
- First install, in order: `./setup.sh` writes `config.env` interactively;
  `./doctor.sh` is the read-only preflight against it (hardware, commands,
  ports, subnet, model reachability, what is already installed);
  `./setup-host.sh` installs the host side, generates `secrets.env`, and asks
  for sudo itself (`./teardown-host.sh` reverts it completely); `./run.sh`
  builds and recreates the containers; `./verify.sh` proves the lockdown.
- Your files: `workspace/` (mounted at `/workspace`) and `dsh-home/` (mounted
  at `/home/dev/.dsh`). Everything else in the container is disposable.
- Browse the UI at `http://127.0.0.1:3080`, IPv4 literal, always.

## Conventions used in these docs

Paths without a leading slash are relative to the project root, wherever you
cloned it. "gw" means the dshnet gateway
`192.168.66.1`. Commands prefixed `sudo` need your password; the scripts ask
for it themselves and must be run as your normal user, never under `sudo`.
