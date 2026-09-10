# Plugins

## What is installed

| Plugin | Source | Pin | Status | Why it is here |
|---|---|---|---|---|
| dsh-web-tools | `github:A3Boy/dsh-web-tools` | commit `4e319e9c` = v0.2.0 tag, reviewed 2026-08-24 | works | multi-provider search adapter; we use only its SearXNG provider |
| @dsh-external/dsh-deep-research | `github:FengHuoLinShan/dsh-deep-research` | commit `1108d4a8`, reviewed 2026-08-23 | loads; its `deep_research` tool does not work on the web profile | kept for when upstream fixes agent-scope engine resolution; the `/deep-research` skills replace it |
| @deepseek-ai/dsh-mcp-client | npm `@0.0.1-rc.1` | exact version | works, mounted via `dsh-home/cordis.patch.yml` | exposes Crawl4AI's MCP tools to the agent |
| dsh-better-sidebar | `github:omdsh-dev/DSH-better-sidebar` | commit `4c0da8119b6ca37ce3daf5c102076154a10010de` | works, pty terminal compiled | files, editor, terminal, git, tasks, browser beside the chat |
| dsh-circuit-breaker | `github:pricklywiggles/dsh-circuit-breaker` | commit `8aa4ffeb`, published and pinned 2026-09-01 | works, verified live | denies repeated identical tool calls, caps per-agent calls, logs incidents for parent supervision; written for this project, installed from its public repo like every other plugin |

Base bundles that come with dsh: `@deepseek-ai/dsh-base`,
`@deepseek-ai/dsh-web-app`. The current `.seed-version` is
`dsh-0.1.1-rc.2+web-tools-2+research-4+sidebar-1+breaker-5+locked-2`.

Updating any of these is an agent-driven review, not a version bump: see
[09-updating.md](09-updating.md).

## How dsh loads plugins (rc.2)

Getting this wrong cost hours; the model is:

- **A profile** (`dsh-home/profiles/web/`) is a pnpm workspace. Its
  `package.json` has `dependencies` (what pnpm installs) and
  `dsh.profile.bundles` (what dsh activates). Being installed is not being
  active.
- **Bundles** are packages with `dsh.bundle` metadata in their
  `package.json` (usually pointing at a `cordis.patch.yml` that inserts
  rows). `dsh plugin --profile web add <spec>` installs one and appends it to
  `bundles`. dsh-web-tools, dsh-deep-research and the sidebar are bundles.
- **Raw cordis plugins** have no `dsh.bundle`. Listing one in `bundles`
  crashes boot (`declares no dsh.bundle`). They mount as a row in a patch
  layer instead. `@deepseek-ai/dsh-mcp-client` is one; "one instance = one
  MCP server", so each server is its own row.
- **Patch layers** compose bottom-up: dsh-base, then each bundle's patch,
  then the profile's `profiles/web/cordis.patch.yml`, then the home layer
  `$DSH_HOME/cordis.patch.yml`. The home layer is the right place for your
  rows: it applies to every profile and is outside `profiles/`, so seed syncs
  never touch it.
- **Settings** for plugins live in `dsh-home/settings.yaml` under the
  plugin's settings namespace (e.g. `dsh-web-tools:`). Some plugins read
  them at activation only; restart after editing.
- **Credentials** resolve by ref name from `.credentials.yaml` or the
  launching environment. dsh-web-tools uses `WEB_TOOLS_<SUFFIX>`; that is
  how `WEB_TOOLS_SEARXNG=local` in `run.sh` reaches it.
- **Agent presets** are separate from plugins: `agent.cordis.yml` files
  under the app's shipped `config/agent-presets/` or the user root
  `$DSH_HOME/.agent-presets/<id>/`. The composer's mode picker lists them.
  Rows that publish a service inside a preset must be in an `isolate` realm
  or the mount fails. We do not currently ship a custom preset.

## The seed mechanism

The runtime container cannot reach GitHub or npm, so plugins install at
image build time:

1. The Dockerfile runs `DSH_HOME=/opt/dsh-seed dsh plugin --profile web add ...`
   for each bundle, in the builder VM (which has network).
2. It writes a version string to `/opt/dsh-seed/.seed-version`.
3. At container start, `entrypoint.sh` compares that with
   `dsh-home/.seed-version`. If different, it replaces
   `dsh-home/profiles/` with the seed's copy and records the new version.

Consequences: bump the version string whenever the seed RUN changes,
otherwise the volume keeps the old `profiles/`; never hand-edit anything
under `profiles/` expecting it to last; `settings.yaml`, `cordis.patch.yml`,
`skills/`, `sessions/` are never touched by the sync.

## pnpm's guard rails

The profile's `pnpm-workspace.yaml` sets `autoInstallPeers: false`, so a
plugin's peer dependencies are not pulled in silently (the sidebar declares
a third-party one, `@huanlin/dsh-plugin-better-locale`, which stays out).

pnpm refuses to run build scripts (`prepare`, `postinstall`) of git-hosted
packages until allowlisted. The Dockerfile appends, before installing the
sidebar:

```
allowBuilds:
  "dsh-better-sidebar@https://codeload.github.com/omdsh-dev/DSH-better-sidebar/tar.gz/<sha>": true
  node-pty: true
```

Keep it that narrow. Allowing a package to build is allowing it to run code
at install time; the exact-SHA key means a new commit needs a new,
deliberate line.

## Installing the next plugin

1. **Vet it** (checklist below). Decide whether it is worth an in-process
   shell's trust.
2. **Find its shape.** Does `package.json` have `dsh.bundle`? Then it is a
   bundle. Otherwise it is a raw plugin needing a patch row. Does it declare
   `prepare`/`postinstall`? Then it needs an `allowBuilds` entry. Does it
   have native deps? Then the image needs the toolchain (it already has
   build-essential and python3).
3. **Pin it.** Prefer the latest *release* tag's commit over `main`, and
   check how far `main` has run ahead of it. The gap is unreleased work the
   maintainer has not announced.
   `gh api repos/OWNER/REPO/git/refs/tags/vX.Y.Z --jq .object.sha`. Use
   `github:OWNER/REPO#<sha>`. Never a branch, and never a bare tag name
   (tags can be moved; commits cannot).
4. **Add to the Dockerfile** in the seed RUN chain:
   `&& DSH_HOME=/opt/dsh-seed dsh plugin --profile web add "github:OWNER/REPO#<sha>"`
   preceded by the `allowBuilds` printf if needed. For a raw plugin use
   `npm install`-style resolution via `dsh plugin add` anyway (it lands in
   `dependencies`), then add a row to `dsh-home/cordis.patch.yml` with its
   config.
5. **Bump `.seed-version`** in the same RUN.
6. **Network needs.** If the plugin must reach a service, add a squid
   allowlist domain, or better a relay plus pf port
   ([03-operations.md](03-operations.md)). If it must reach a hosted API
   with a key, decide whether you accept that third party seeing the
   traffic.
7. **`./run.sh`**, then `container logs dsh` for `did not activate`,
   `declares no dsh.bundle`, or pnpm errors. Then `./verify.sh`.
8. **Smoke test** the feature in the UI, and add it to the table at the top
   of this file with its pin.

To remove one: delete its line from the Dockerfile, bump `.seed-version`,
`./run.sh`. The sync replaces `profiles/` wholesale.

## Vetting checklist

This is what was done for the sidebar; repeat it for anything that runs
in-process. A plugin with UI-only scope still runs server-side code.

Provenance

- Age of org and repo, forks, open issues, release cadence. Stars alone are
  weak evidence; forks and issue traffic are harder to fake.
- Is there an npm package, or only git? Git-only means you are trusting the
  repo state at a SHA; pin it.

`package.json`

- `scripts`: any `preinstall`, `postinstall`, `prepare`, `prepack`? What do
  they run? `prepare: tsdown` (a build) is fine; a curl or an obfuscated
  node one-liner is not.
- `dependencies`: recognisable, mainstream, no typosquats. Peer deps from
  unknown maintainers (check `npm view <pkg> maintainers`).
- `dsh.client.inject` and `dsh.bundle` tell you what it hooks into.

Source sweep (clone it, `rg` over `src/`)

- Outbound network: `fetch(`, `axios`, `http.request`, `net.connect`,
  `new WebSocket` (client, as opposed to `WebSocketServer`). For each hit,
  read the surrounding code: user-initiated or automatic? To where?
- Process execution: `child_process`, `spawn(`, `exec(`, `node-pty`. Expected
  for a terminal plugin; unexpected for a theme.
- Dynamic code: `eval(`, `new Function`, `Buffer.from(..., 'base64')`,
  `atob(`. Any of these is a stop-and-read.
- Secrets: how does it touch `settings`, `credentials`, env? The sidebar
  reads settings with `redactSecrets: true`; that is the good pattern.
- Every literal host: `grep -roE "https?://[a-zA-Z0-9._-]+" src/ | sort | uniq -c`.
  Expect w3.org (SVG), docs links, nothing else.

Repo hygiene

- No committed `lib/`/`dist/` (built from source at install, so what you
  read is what runs) and no binaries.
- Lockfile sources all `registry.npmjs.org`; no tarball URLs.

Then decide, pin to the SHA you read, install, verify, record it here.

## Notes on specific plugins

**dsh-deep-research.** Upstream main injects a `workflows` service that
current dsh does not provide; the whole profile hangs at boot. The pinned PR
branch (#5) avoids the hang by resolving `workflowEngine` from the calling
agent's context, but on the web profile that lookup fails because the engine
lives in the preset's isolated realm and agent contexts do not inherit realm
labels. A Creator-mode session confirmed this and tried the documented
`agentPresets.serviceForAgent` path, which also failed in practice. Custom
presets that publish the engine at the preset root trip the `leakedServices`
guard and crash preset selection. Conclusion: not fixable from our side in
rc.2. The `/deep-research` skills provide the workflow without it.

**dsh-web-tools.** Pinned to the v0.2.0 release tag, deliberately not
`main`. On 2026-08-24 the spec was still floating and had pulled `main`,
which sat 19 commits past the release and carried an unreleased browser
bridge: an MV3 extension, a pairing relay with a persisted credential, and a
WebSocket upgrade route registered unconditionally at plugin load. None of it
was in the release notes because none of it was released. The pinned tag has
no bridge files at all. Only the SearXNG provider is used. Its fetch providers
are all hosted APIs with hardcoded endpoints (base-URL override ignored in
`jina.js` and `firecrawl.js`), so page reading goes through Crawl4AI's MCP
tools instead. Two upstream bugs worked around: keyless SearXNG skipped when
the key pool is empty (dummy `WEB_TOOLS_SEARXNG`), and the UI order editor
leaving `fallbackOrder: []` (set it in `settings.yaml`).

**dsh-better-sidebar.** Reviewed at `4c0da81` on 2026-08-24: no install
hooks, no dynamic code, no telemetry hosts, one defensive outbound fetch
(header probe, loopback blocked, 8s timeout), its own DNS-rebinding fence,
secrets redacted. Provenance was young (org ~3 weeks old, 2748 stars, 220
forks, 124 issues). Capability is the risk: it is a shell and editor in the
browser, which is the product. Re-review before moving the SHA.
