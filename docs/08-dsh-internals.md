# dsh internals, as observed in 0.1.1-rc.2

Facts about DeepSeek Harness that took real digging to learn. dsh is a
developer preview and renames things between release candidates; verify
against `container logs dsh` and the installed source under
`/usr/local/lib/node_modules/@deepseek-ai/dsh/` before relying on any of
this after an upgrade.

## Layout

- Global install: `/usr/local/lib/node_modules/@deepseek-ai/dsh/`. Its
  `config/agent-presets/` holds the shipped presets (`standard`, `code`,
  `minimal`, `cordis`); `node_modules/@deepseek-ai/*` holds the core
  plugins.
- `$DSH_HOME` (`/home/dev/.dsh`, the `dsh-home/` mount): `settings.yaml`,
  `.credentials.yaml`, `cordis.patch.yml` (home patch layer),
  `profiles/<profile>/` (pnpm workspace per profile), `skills/`,
  `.agent-presets/` (user presets), `sessions/--workspace--/session-*/session.jsonl.zstd`,
  `storages/`.
- Profiles: `web` (what `dsh web` runs), `tui`, `headless`. Each has
  `package.json` (dependencies + `dsh.profile.bundles`), `cordis.yml`,
  `cordis.patch.yml`, `pnpm-workspace.yaml`.

## Cordis, realms and services

Everything is a cordis plugin row. Rows provide and inject services;
activation is service-availability driven, not order driven. A static
`inject` that nobody provides leaves the row "pending" and, at boot, the
loader throws `plugin tree failed to load: N entries did not activate`.

Presets can wrap rows in a group with `isolate: { serviceName: true }`,
giving that group an entry-local realm for the service. The standard preset
does this for `workflowEngine` inside its `delegation` group. Two hard rules
learned from `dsh-agent-presets`:

- A row inside a preset that publishes a service outside an isolate realm
  trips the `leakedServices` guard at mount; the UI surfaces this as
  `agent-preset-invalid`, rolls back, and the browser console says
  `[web-runtime] connection lost`.
- An agent's context does not inherit the preset's realm labels. Host-level
  code holding `exec.agent` cannot `ctx.get()` a preset-isolated service.
  The documented read path is `ctx.agentPresets.serviceForAgent(agent, name)`;
  in our test it still returned nothing for `workflowEngine`.

Service naming that bit us: `@deepseek-ai/dsh-workflow` provides
`ctx.workflowEngine`; `@deepseek-ai/dsh-workflow-worker-thread` is the
engine implementation (injects `subagents`); `@deepseek-ai/dsh-tool-workflow`
is the model-facing tool. There is no `workflows` service in rc.2 and no
`dsh-workflow-workerthread` package, whatever plugin READMEs say.

## Agent presets

Shipped root: `config/agent-presets/<id>/{agent.cordis.yml,preset.yml}`.
The boot code hard-sets that root and overwrites any `roots` given via the
`agent-presets` row, but the Creator preset's guidance says user presets
live at `$DSH_HOME/.agent-presets/<id>/`, and that works (they appear in
the mode picker). Never edit the shipped directory; upgrades overwrite it
and corrupting `cordis` disables Creator mode.

`preset.yml` is `name`, `description`, `order`. `agent.cordis.yml` is the
row list. Copy `standard` to start.

Presets available: Standard, PTC (Code Mode SDK), Minimal, Creator
(`cordis`: runtime inspection, plugin experiments, preset authoring), plus
ours if any. The composer's mode button switches them per session; new
sessions inherit the last selection; `agent-presets.default` in
`settings.yaml` sets the default.

Creator mode is the right tool when a plugin or preset misbehaves: it can
read the live composition and the source, and it found the `leakedServices`
root cause in one session. Give it Full access (it must write `$DSH_HOME`)
and a concrete deliverable, and nudge it to conclude; it will otherwise read
source for half an hour.

## Permissions and the inner sandbox

Access modes per session: Read Only, Workspace Write, Full access. The first
two run bash inside dsh's own sandbox, which needs Landlock or bubblewrap;
absent both (our VM kernel), every command asks to escalate. Full access =
sandbox open, approvals never. `permission.defaultPreset:
danger-full-access` in `settings.yaml` makes it the default. Named presets
pairing sandbox and approval policy exist (`dsh-permission-presets`).

## Subagents, jobs, workflows

Three different subsystems with different tools:

- `subagent` (spawn or fork providers, `backgroundMode: continuable`)
  launches an agent; completion arrives in the parent's conversation
  between turns.
- `job_list` and friends belong to `dsh-tool-jobs`/`dsh-jobs-local`, a
  separate background job system. Asking it about a subagent id yields
  `unknown job`.
- `ctx.workflowEngine` runs model-written orchestration scripts in a worker
  thread (`workflow` tool). Its engine lives in the preset's isolated realm.

The busy-wait deadlock: a parent turn that never ends never receives its
subagent's completion. Interrupt with "Stop generating".

## settings.yaml keys seen

```yaml
llm-pi-ai:                      # model providers (api: openai-completions, baseURL, apiKeyEnv, models[], compat)
agent-default-model:            # provider + model for new sessions
agent-presets:  default: standard
permission:     defaultPreset: danger-full-access
ui-theme:       preference: dark
ui-onboarding:  welcomeNoticeVersion   # written by dsh itself
dsh-web-tools:                  # providerBaseUrls, searchRoutingPolicy, defaultProvider, fallbackOrder
```

dsh writes into this file too (the onboarding key appeared after dismissing
the first-run notice), so it is shared state, not a pure input. That is also
why the entrypoint patches the provider keys in place instead of moving them
to `cordis.patch.yml`: dsh-base's own patch documents that an `llm-pi-ai:`
section here overrides the composed value, and the Models page writes this
section, so a patch-layer copy would lose to whatever the UI last saved.

Provider model entries accept `input: [text, image]` and `contextWindow`;
`compat.maxTokensField: max_tokens` and `supportsDeveloperRole: false` suit
llama.cpp.

## Plugin config paths that work, and one that does not

Tested live (2026-09-01): a bundle plugin's config is NOT reachable through a
settings.yaml section named after the plugin (a `circuit-breaker:` section
there was silently ignored; `dsh-web-tools:` works because that plugin reads
settings itself). What does work for any row is an id-targeted override in
the home patch layer:

```yaml
- id: circuit-breaker
  config:
    incidentLog: /workspace/.circuit-breaker-incidents.jsonl
```

Also established: the agent object handed to `ctx.tools.guard()` carries the
agent's uuid, and it is the same id that `list_agents` reports, that
`interrupt_agent` takes, and that names the agent's session directory under
`sessions/--workspace--/`. One identifier throughout.

## MCP client config

`@deepseek-ai/dsh-mcp-client`, one instance per server, mounted as a patch
row. `transport: stdio` takes `command`, `args`, `env`, `cwd`;
`transport: streamable-http` takes `url`, `headers`. Common: `serverName`
(1 to 32 chars, becomes the `mcp__<serverName>__<tool>` prefix),
`toolCallTimeoutMs`, `failOnStartupError`, `reconnect` policy. No SSE
transport, hence supergateway for SSE-only servers.

## Skills

See [06-skills.md](06-skills.md). Provider: `dsh-skill-filesystem`; roots:
`$DSH_HOME/skills`, `~/.agents/skills`, `<project>/.dsh/skills`,
`<project>/.agents/skills`; directory bundles with `SKILL.md` or flat
`<name>.md`; live watched.

## CLI

- `dsh web --no-open` (what the entrypoint runs); `--port N`; `--host
  0.0.0.0` is rejected by design (no remote auth yet).
- `dsh plugin --profile <web|tui|headless> add <spec>` where spec is an npm
  name, `github:owner/repo[#ref]`, `git+https://...`, or a local path.
  Installs into `$DSH_HOME/profiles/<profile>/` with pnpm and appends
  bundles. Run with `DSH_HOME` pointing elsewhere to build a seed.
- `dsh --profile tui` etc. to run other profiles. Launcher flags come
  first; the first unrecognised token starts the app's own arguments.

## Environment variables that matter

`DSH_HOME`, `DSH_TELEMETRY_DISABLED=1` (read in `profile-boot`),
`NODE_USE_ENV_PROXY=1` (Node 24: fetch honors `HTTP_PROXY`/`NO_PROXY`),
credential refs like `WEB_TOOLS_SEARXNG`, `DEEPSEEK_API_KEY` (built-in
search, unused here).

## UI quirks

- Secure-context requirement: browse `127.0.0.1`, not the container IP.
- `Waiting for approval` cards block the composer; the mode and access
  buttons hide while a turn runs.
- The sidebar plugin adds Files, Source Control, Tasks, Side Chat,
  Terminal, Browser tabs behind "Expand sidebar" on the right.
- Session transcripts are zstd-compressed JSONL; `zstd -dc` on the Mac to
  inspect (`agentPreset`, `mode`, tool calls).

## Where to look when something is off

1. `container logs dsh` for boot errors and the MCP bridge chatter.
2. Browser console for preset/runtime rollbacks.
3. The installed source: `rg` under the global install's `node_modules/@deepseek-ai/`
   for a service name or error string. Files are unminified.
4. `dsh-home/profiles/web/package.json` for what is installed vs active.
5. A Creator-mode session for anything about realms.
