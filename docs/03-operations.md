# Operations

## Starting everything

```sh
./run.sh        # the one command: starts the container system, creates the
                # network, builds the images, recreates all three containers
./verify.sh     # confirm the lockdown holds and the agent tools work
```

On a machine that has never run this: `./setup.sh` to write `config.env`,
`./doctor.sh` to preflight against it, then `./setup-host.sh` once for the
firewall, proxy, relays, and `secrets.env`. After that `./run.sh` is the only
command you need day to day.

After a reboot the host side comes back on its own: the pf loader and the
three relays are LaunchDaemons (`RunAtLoad`), squid is a Homebrew service
started at login. The containers do not: apple/container may restore `dsh`,
but `searxng` and `crawl4ai` come back **stopped**, which looks like "search
is broken" from the agent's side. `./run.sh` fixes that, since it recreates
all three regardless of what state they were in.

Start one service by hand: `container start searxng` (one name per
invocation; `container start a b` is rejected).

`./stop.sh` is the inverse of `run.sh`. Stopping containers alone leaves the
buildkit VM, the apiserver and the vmnet services running, and those hold most
of the memory, so the script follows the container stops with a
`container system stop`. It leaves the host side up: the relays and squid are
idle daemons, they need sudo, and the pf anchor is the lockdown itself.
`teardown-host.sh` removes those. Disk is untouched unless you pass `--cache`,
which deletes the build cache and costs one cold build.

## Daily commands

```sh
./run.sh                    # rebuild the images, recreate all three containers
./stop.sh                   # stop the containers and the runtime, memory back
./stop.sh --cache           # also delete the build cache, tens of GB back
./verify.sh                 # prove the lockdown still holds
./doctor.sh                 # read-only: what is installed, free, reachable
container ls                # what is running (dsh, searxng, crawl4ai, buildkit)
container logs dsh          # dsh server output (boot errors, MCP bridge chatter)
container exec -it dsh bash # shell in the box as user dev
container stop dsh && container start dsh   # restart without rebuilding
container system df         # image and container disk usage
```

Occasional, in `scripts/`:

```sh
./scripts/rotate-secrets.sh      # new crawl4ai token + searxng secret, then ./run.sh
./scripts/sync-model-context.sh  # match settings.yaml contextWindow to the server
./scripts/refresh-lockfile.sh    # regenerate profile-pnpm-lock.yaml after a pin change
```

The UI is `http://127.0.0.1:3080`. Type the IPv4 literal. `localhost` may
resolve to `::1`, which is not published (apple/container refuses to publish
the same host port on both loopbacks).

## What persists and what is disposable

| Path (host) | Path (container) | Survives `./run.sh` | Survives `rm -rf` of the dir |
|---|---|---|---|
| `workspace/` | `/workspace` | yes | your files, gone |
| `dsh-home/settings.yaml`, `cordis.patch.yml`, `skills/`, `sessions/`, `storages/`, `.credentials.yaml` | `/home/dev/.dsh/...` | yes | dsh state, gone |
| `dsh-home/profiles/` | `/home/dev/.dsh/profiles` | replaced whenever the image's `.seed-version` changes | regenerated from the image |
| everything else | `/usr/...`, `/opt/...`, `/etc/...` | no, comes from the image | n/a |

Rule: to add a file the agent should see, drop it in `workspace/`. To add a
tool or package permanently, edit the `Dockerfile`. Anything installed with
`container exec` is gone at the next `./run.sh`.

The two mounts are virtiofs and live in both directions; no restart needed.
Ownership is consistent because the container user is uid 501, same as your
macOS account.

## Rebuild and restart semantics

`./run.sh` does, in order: `container system start`, create `dshnet` if
missing, `container build` both images (layer-cached, so close to a no-op when
nothing changed), then stop, remove and recreate `searxng`, `crawl4ai` and
`dsh` in that order. Every container's IP changes each time; nothing should
depend on one.

Between crawl4ai and dsh it waits for both services to answer. That gate is
load-bearing: the crawl4ai MCP bridge opens its SSE connection once while dsh
boots and exits permanently if the connect is refused, which silently costs the
agent every `mcp__crawl4ai__*` tool. Since both services are recreated cold on
every run, and crawl4ai has a Chromium to start, without the wait dsh reliably
wins the race. If a service never answers, `run.sh` warns and starts dsh
anyway, on the grounds that a box with no fetch tools beats no box.

`entrypoint.sh` repeats that wait inside the container, because this one only
helps when the box came up through `run.sh`. A container system restart or a
plain `container start` starts everything at once and loses the same race.

The entrypoint compares `/opt/dsh-seed/.seed-version` (image) with
`dsh-home/.seed-version` (volume). If they differ it deletes
`dsh-home/profiles/` and copies the seed's. That is how plugin changes reach
the volume, and also why any hand edits inside `profiles/` are temporary.

The entrypoint also reconciles the config-derived keys in
`dsh-home/settings.yaml` (`baseURL`, the searxng URL, the model id) with
config.env on every boot, touching only those lines; the UI owns the rest of
the file. Changing `SUBNET`, a port, or `MODEL_ID` therefore needs nothing
beyond `./run.sh`, which also recreates the dshnet network itself when its
subnet no longer matches config.env.

`run.sh` recreates all three containers on every run, so a config change needs
nothing more than `./run.sh`. It works that way because a container freezes its
ports, mounts, and env at creation: restarting one silently keeps whatever
config it was born with, which is how a stale mount path outlives a rewrite.

## Allowing the agent to reach something

**A domain** (npm, GitHub, a docs site): add it to
`$(brew --prefix)/etc/squid-dsh-allowlist.txt` (leading dot allows subdomains),
then `$(brew --prefix)/opt/squid/sbin/squid -k reconfigure`. Tools inside the
container find the proxy via the environment. squid only permits ports 80
and 443.

**A raw IP or port**: add a `pass in quick` line to
`host/templates/dsh-egress.pf.conf.tmpl`, then `./setup-host.sh` (idempotent;
it re-renders and reloads the anchor). Prefer adding a relay instead when the target is a
service: it keeps the container ignorant of the real address.

**A new relay**: add a `relay_plist` call in `setup-host.sh` with the label,
listen port and target (it renders `host/templates/relay.plist.tmpl`), add the
port to the pf pass rule, add the label to the `for plist in ...` loops in both
`setup-host.sh` and `teardown-host.sh`, run `./setup-host.sh`.

## Host-side files and services

| Item | Path | Owner |
|---|---|---|
| pf wrapper | `/usr/local/etc/pf-dsh.conf` | root, copied from `host/pf-dsh.conf` |
| pf anchor | `/etc/pf.anchors/dsh-egress` | root, rendered from `host/templates/dsh-egress.pf.conf.tmpl` |
| pf loader daemon | `/Library/LaunchDaemons/$LABEL_PREFIX.pf.plist` | runs `pfctl -E -f` at boot and when `/etc/pf.conf` changes |
| relay daemons | `/Library/LaunchDaemons/$LABEL_PREFIX.dsh-{model,searxng,crawl4ai}-relay.plist` | run socat as your user, KeepAlive, 15s throttle |
| squid config | `$(brew --prefix)/etc/squid.conf` (original kept as `squid.conf.pre-dsh`) | Homebrew service, your user |
| squid allowlist | `$(brew --prefix)/etc/squid-dsh-allowlist.txt` | user-edited; setup never overwrites it |
| pf prior state | `.pf-was-enabled` (repo root) | read by teardown |

Logs live in `$(brew --prefix)/var/logs/`. The relays write
`$LABEL_PREFIX.dsh-{model,searxng,crawl4ai}-relay.log`, squid writes
`squid-dsh-access.log` and `cache.log`, and the pf loader writes
`$LABEL_PREFIX.pf.log`.

Relay daemons crash-loop quietly (15s backoff) whenever the dshnet bridge
does not exist, which is whenever no dshnet container is running. Expected.

Check a daemon: `launchctl print system/$LABEL_PREFIX.dsh-searxng-relay | grep -E 'state|last exit'`.
Check the anchor: `sudo pfctl -a dsh-egress -sr`.

## Upgrading each component

| Component | How | Then |
|---|---|---|
| dsh | bump `DSH_VERSION` in `Dockerfile` and the `.seed-version` string | `./run.sh`; re-check every plugin still loads (`container logs dsh`) |
| apple/container | bump `CONTAINER_TARGET_VERSION` in `setup-host.sh` | `./setup-host.sh` (downloads the signed pkg, stops the system, installs) |
| a plugin | change its spec in the Dockerfile seed RUN, bump `.seed-version` | `./run.sh`; re-vet first if it runs in-process (see 05) |
| SearXNG | `container stop searxng && container rm searxng`, `./run.sh` pulls `:latest` | check engines: `curl -s 'http://127.0.0.1:8888/search?q=test&format=json' \| jq .unresponsive_engines` |
| Crawl4AI | same as SearXNG; the derived image in `host/crawl4ai/` rebuilds on top of `:latest` | re-verify `config.yml` still matches upstream's schema; the app.host override is the only change |
| squid, socat | `brew upgrade squid socat` | `brew services restart squid` |
| macOS | after any OS update | `./verify.sh`; if pf rules vanished, `./setup-host.sh` |

dsh is a developer preview. Treat every bump as a potential breaking change
and read `container logs dsh` after the first boot.

## Pinning status

| Component | Pinned to | Gap |
|---|---|---|
| apple/container | `1.3.1` in `setup-host.sh` | none; reviewed 2026-09-01 |
| dsh | `0.1.1-rc.2` | none |
| dsh-better-sidebar | commit `4c0da81…` | its ~30 transitive deps re-resolve `^` ranges on each build |
| dsh-web-tools | commit `4e319e9c` (the v0.2.0 release tag) | as above |
| dsh-deep-research | commit `1108d4a8` | as above |
| dsh-mcp-client | `0.0.1-rc.1` | none |
| node base image | digest `sha256:934240a1…` | none |
| searxng image | digest `sha256:11a9b34c…` | none |
| crawl4ai image | digest `sha256:bd36741e…` (in `host/crawl4ai/Dockerfile`) | none |
| transitive npm tree (~260 pkgs) | `profile-pnpm-lock.yaml`, installed `--frozen-lockfile` | none |

Everything is pinned to an immutable ref as of 2026-08-24: nothing in a
rebuild resolves to "whatever is newest". Changing any plugin pin therefore
requires regenerating the lockfile (`./scripts/refresh-lockfile.sh`) or the
build fails with `ERR_PNPM_OUTDATED_LOCKFILE`, a deliberate tripwire, since
a pin change *is* a supply-chain change. See [09-updating.md](09-updating.md).

To close the gap: commit `dsh-home/profiles/web/pnpm-lock.yaml` to the repo
and COPY it into `/opt/dsh-seed/profiles/web/` in the Dockerfile before the
plugin installs; pin the remaining git specs to SHAs; reference images by
`@sha256:` digest. Builds only happen when you run them and the runtime
container has no internet, so this is a supply-chain hygiene item, not an
emergency.

## Disk: apple/container leaks a snapshot per build

apple/container stores each image generation as an uncompressed snapshot under
`~/Library/Application Support/com.apple.container/snapshots/`, and replacing a
tag abandons the previous generation instead of collecting it. Every `./run.sh`
therefore strands roughly 4 GB for dsh-box and 7.6 GB for crawl4ai-local.
Nothing reclaims them on its own. One machine here reached 98 GB this way.

This is upstream [apple/container#2164](https://github.com/apple/container/issues/2164),
open as of 2026-09-01, which reports three separate leaks: replace abandons the
old snapshot, `image delete` does not reclaim the deleted image's snapshot, and
a single unreadable image record disables the cleanup sweep permanently. That
last one means an interrupted pull can lock you out of reclaiming anything.

`run.sh` now handles both routine cases itself: it prunes dangling images
after every successful bring-up, and it recreates the builder before building
whenever the cache passes `BUILDER_CACHE_MAX_GB` (config.env, default 25;
0 disables; the build that follows runs cold and re-warms the cache). Manual
tools for everything else:

```sh
container system df       # TOTAL / ACTIVE / SIZE / RECLAIMABLE per type
container image prune     # removes dangling images and their snapshots
```

`container image prune` is safe to run at any time and needs no arguments. It
does not touch images a container is using.

`./stop.sh --cache` does the builder wipe below for you, and works whether
the box is running or already stopped.

Two heavier levers, in the order to reach for them:

- `container image prune --all` also drops unused *tagged* images. That
  includes the base images (`node`, `searxng/searxng`, `unclecode/crawl4ai`)
  and `dsh-box-lockrefresh`, the throwaway `scripts/refresh-lockfile.sh`
  builds. All are pinned by digest, so the next build re-pulls them.
- `container builder delete -f` discards buildkit's cache, which grows to tens
  of GB on its own. Recreate it with
  `container builder start --cpus 2 --memory 2048M --dns 1.1.1.1`. The next
  build then runs cold, roughly four minutes here. Worth doing deliberately
  before publishing, because a cold build is the only real test that the
  pinned refs still resolve from nothing.

Do not delete snapshot directories by hand. Nobody upstream has confirmed that
is safe, and the tooling has no way to notice what you removed.

## Maintenance checklist

Occasionally:

- `./verify.sh` after any macOS update, apple/container update, or host
  change.
- `container system df`, and `container image prune` when the reclaimable
  figure has grown. Budget one leaked snapshot per rebuild.
- Skim `$(brew --prefix)/var/logs/squid-dsh-access.log` for denied domains you
  did not expect the agent to want.
- Check SearXNG's engine health (command in the table above). Suspended
  engines recover on their own; a persistent zero from one engine usually
  means a captcha wall (see [07-web-research.md](07-web-research.md)).
- Back up `workspace/` and `dsh-home/` (minus `profiles/`, which is
  regenerated). They are the only state.

Before pushing this repo anywhere public: rotate the two tokens in
[02-security-posture.md](02-security-posture.md).

## Full reset

```sh
container stop dsh searxng crawl4ai; container rm dsh searxng crawl4ai
container image rm dsh-box crawl4ai-local        # optional
container network rm dshnet                      # optional
rm -rf dsh-home/profiles dsh-home/.seed-version  # forces a clean plugin sync
./run.sh
```

Keep `workspace/` and the rest of `dsh-home/` unless you want a truly blank
box. `./teardown-host.sh` undoes the host side entirely.
