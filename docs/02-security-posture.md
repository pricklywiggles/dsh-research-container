# Security posture

## What we are defending against

The agent inside the container runs code it wrote, tools it chose, and
plugins pulled from GitHub by people we do not know. Assume any of that can
be malicious or prompt-injected. The goals, in priority order:

1. Nothing in the container can touch macOS, your files outside the two
   mounts, or your LAN.
2. Nothing in the container can reach the internet except through paths you
   explicitly opened, and you can see what it tried.
3. A compromise is cheap to recover from: `container rm`, rotate two tokens,
   rebuild.

## Enforcement layers, outermost first

**VM boundary (apple/container).** Each container is a separate Linux VM.
No shared kernel with macOS. Filesystem access is limited to the two
virtiofs mounts (`workspace/`, `dsh-home/`).

**pf on the host.** Anchor `dsh-egress`, loaded through the wrapper
`/usr/local/etc/pf-dsh.conf`. Rules, in order (all `quick`, first match
wins):

1. `pass out` from anywhere to the dshnet subnets, stateful. Lets the host
   reach the container (UI publish, `container exec`) and lets replies back.
2. `pass in` TCP from dshnet to gw ports 3128, 8090, 8888, 8890. The four
   holes.
3. `pass in` UDP from dshnet to gw port 53. Currently moot (the gateway
   resolver is dead on this macOS beta) but harmless.
4. `block drop in` everything else from dshnet, IPv4 and IPv6.

The container cannot run pf rules, cannot see the host, and has no second
interface. There is no route around this.

**squid.** Only source `192.168.66.0/24` may use it, only to domains listed
in `$(brew --prefix)/etc/squid-dsh-allowlist.txt`, only ports 80/443, CONNECT
only to 443. The allowlist ships fully closed. Every request, allowed or
denied, lands in `$(brew --prefix)/var/logs/squid-dsh-access.log`. squid
resolves hostnames on the host, so the container needs no DNS.

**Relays.** Each socat relay binds the gateway IP specifically, so it is
reachable from dshnet and from the host, and from nothing else. The crawl4ai
relay additionally requires a bearer token (`CRAWL4AI_API_TOKEN`).

**Inside the container.** `HTTP_PROXY`/`HTTPS_PROXY` point at squid with
`NO_PROXY` for the gateway, and `NODE_USE_ENV_PROXY=1` makes Node's fetch
honor them. `DSH_TELEMETRY_DISABLED=1` is set for good measure, but the
network is what actually stops telemetry.

## What the posture does not cover

Be precise about this; it decides whether a plugin review is optional.

- **Inside the container is one trust zone.** A malicious plugin runs
  in-process with dsh. It can read `/workspace`, read and rewrite
  `dsh-home/` (settings, `.credentials.yaml`, skills, the profile's
  `node_modules`), and open a pty. Full-access mode means the agent can too.
- **The relays are exfiltration channels.** Crawl4AI fetches any URL. Data
  encoded into a query string reaches an attacker's web log. SearXNG queries
  leak to search engines by design. The lockdown makes exfiltration
  *observable* (relay and squid logs) and *narrow*, not impossible.
- **The open-network containers are not locked down.** SearXNG and Crawl4AI
  have unrestricted egress because they need it. They are our own images,
  but a vulnerability in either is a foothold with internet access. They
  cannot reach dshnet (apple/container isolates custom networks) but they
  can reach each other and the host's published loopback ports.
- **The host's own traffic is untouched.** Deliberately. Nothing here
  protects the Mac from the Mac.
- **Model prompts leave the box.** Everything the agent thinks goes to the
  llama.cpp server on the tailnet. That is your machine, but it is a
  network hop.

Consequence: a plugin compromise is container-scoped and recoverable, which
lowers the bar for trying things, but it does not remove the need to review
what runs in-process. See the vetting checklist in
[05-plugins.md](05-plugins.md).

## Host safety guarantees

These were hard requirements and still hold:

- No system-owned file is modified. `/etc/pf.conf`, system DNS, routes,
  `/etc/hosts`, macOS proxy settings, the application firewall: untouched.
  `container system dns create`, the one apple/container command that writes
  `/etc/resolver/`, is deliberately not used.
- Every pf rule requires a dshnet address. Host traffic cannot match.
- Enabling pf with Apple's stock rules plus our anchor changes nothing for
  host traffic; the stock ruleset is permissive.
- Failure direction is always "container gets more access", never "Mac
  loses network". If the anchor fails to load, the box is merely unlocked.
- `teardown-host.sh` restores the exact prior state, including that pf was
  disabled before setup (`.pf-was-enabled` records it).

## Secrets in this repo

| Secret | Where | Exposure | Rotate by |
|---|---|---|---|
| Crawl4AI bearer token | `secrets.env`, rendered into `dsh-home/cordis.patch.yml` | reachable only from host loopback and dshnet | `./scripts/rotate-secrets.sh`, then `./run.sh` |
| SearXNG `secret_key` | `secrets.env`, rendered into `host/rendered/searxng/settings.yml` | signs SearXNG session cookies on a private instance | `./scripts/rotate-secrets.sh`, then `./run.sh` |
| `WEB_TOOLS_SEARXNG=local` | `run.sh` | not a secret; dummy value that works around a plugin bug | n/a |
| dsh credentials | `dsh-home/.credentials.yaml` (if created via UI) | inside the container trust zone | rotate at the provider |

None of these protect anything reachable from outside the Mac. They matter
if the repo is ever pushed somewhere public; rotate them first if so.

## Verifying the posture

`./verify.sh` checks two halves and exits non-zero if either fails. The
lockdown: model reachable through the relay, direct egress dropped, squid
denies a non-allowlisted domain, squid denies npm until you allow it. Then the
agent's tools: open-network egress, the crawl4ai MCP bridge, searxng results,
and the UI. That second half exists because a green lockdown over a dead agent
happened twice, once from a pf reload flushing the vmnet NAT and once from the
MCP bridge losing a startup race.
The egress probe bypasses the proxy env and targets a literal IP, because a
request that dies at squid or on dead DNS would report "blocked" even with
the pf anchor unloaded. Run it after any host change or macOS update.

To watch traffic live: `sudo tcpdump -i bridgeN 'net 192.168.66.0/24'` (find
N with `ifconfig | grep bridge`). During an agent session you should see only
flows to gw:3128/8090/8888/8890 and dead SYNs for anything else.

To audit what the agent tried through the proxy:
`tail -f $(brew --prefix)/var/logs/squid-dsh-access.log`.

## If a plugin turns out to be malicious

1. `container stop dsh` (the relays stay up; nothing else is affected).
2. Rotate the Crawl4AI token and any provider keys in `.credentials.yaml`.
3. Read `squid-dsh-access.log` and the relay logs for what it reached.
4. Remove the plugin from the Dockerfile, bump `.seed-version`, `./run.sh`
   (the entrypoint replaces `profiles/` wholesale, so the plugin's files go).
5. Inspect `dsh-home/settings.yaml`, `cordis.patch.yml`, and `skills/` for
   edits you did not make; a plugin with full access could have persisted
   itself there.
6. `workspace/` is yours to judge; the plugin could read and modify it.

## Things worth tightening later

- Pin the remaining plugins and container images to SHAs/digests and commit
  the profile lockfile (see the pinning table in
  [03-operations.md](03-operations.md)).
- Move relays from LaunchDaemons to user LaunchAgents so `run.sh` can
  kickstart them without sudo after container restarts.
- Close the port-53 rule if a future macOS revives the gateway resolver.
- A pf rule blocking LAN access to the relay ports, in case a relay ever
  binds more broadly than the gateway IP.
