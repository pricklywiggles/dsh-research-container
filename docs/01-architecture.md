# Architecture

## The picture

```
macOS host
│
├─ pf firewall            anchor "dsh-egress": default-deny for 192.168.66.0/24
├─ squid :3128            domain allowlist (starts fully closed)
├─ socat relay gw:8090 ──► MODEL_HOST             your model server
├─ socat relay gw:8888 ──► 127.0.0.1:8888 ──► searxng container :8080
├─ socat relay gw:8890 ──► 127.0.0.1:8890 ──► crawl4ai container :11235
│
├─ container network "dshnet"  192.168.66.0/24 + fd66:2a5:1::/64 (gateway .1)
│    └─ dsh          Debian 12, Node 24, dsh 0.1.1-rc.2, runs as uid 501
│         ├─ dsh web on 127.0.0.1:3080
│         └─ socat 0.0.0.0:3081 → 3080, published to host 127.0.0.1:3080
│
└─ container network "default"  192.168.64.0/24 (open NAT egress)
     ├─ searxng      metasearch, JSON API on, private instance
     ├─ crawl4ai     Chromium page fetcher with built-in MCP server
     └─ buildkit     apple/container's image builder VM
```

Two networks, two trust levels. `dshnet` is where the untrusted thing (an
agent running code it wrote, plugins it loaded) lives. `default` is where the
services that must reach the internet live. The only path between them is
through the host, through a relay, through a pf rule you wrote.

## Components

| Component | Where | Version | Role |
|---|---|---|---|
| apple/container | host | 1.3.1 | runs each container as a lightweight VM (vmnet networking, virtiofs mounts) |
| pf | host kernel | macOS built-in | egress enforcement; rules scoped to the dshnet subnets only |
| squid | host, Homebrew | 7.6 | HTTP/CONNECT proxy with a `dstdomain` allowlist for dev traffic |
| socat | host, Homebrew | 1.8.1.3 | three relays, each a LaunchDaemon running as your user |
| dsh | container | 0.1.1-rc.2 | the harness: web UI on 3080, plugins, skills, sessions |
| node | container | 24.19 | dsh runtime; `NODE_USE_ENV_PROXY=1` makes fetch honor `HTTP_PROXY` |
| supergateway | container, global npm | latest at build | stdio↔SSE MCP bridge for crawl4ai |
| SearXNG | container (default net) | 2026.8.22 | search backend for the agent |
| Crawl4AI | container (default net) | 0.9.2 | URL → markdown page reader, MCP tools |
| llama.cpp | remote (tailnet) | b10453 era | the model: `qwen38`, 27B IQ4_XS, 114k context, multimodal |

## Data flows

**Model call.** dsh → `http://192.168.66.1:8090/v1/chat/completions` → pf
pass rule (gw port 8090) → socat (host, user process) → Tailscale →
llama.cpp. Plain HTTP, no proxy awareness needed, which is why a relay beats
NAT here: vmnet NAT into a Tailscale `utun` interface was unreliable, and
host-originated tailnet traffic always works.

**Web search.** dsh-web-tools plugin → `http://192.168.66.1:8888/search?format=json`
→ pf → socat → host loopback 8888 (the container publish forwarder) →
searxng:8080 → the search engines, from your home IP. NO_PROXY includes the
gateway, so this bypasses squid.

**Page fetch.** dsh mcp-client → spawns `supergateway --sse http://192.168.66.1:8890/mcp/sse`
(stdio bridge, with a bearer token) → pf → socat → host loopback 8890 →
crawl4ai:11235 → Chromium renders the page → markdown back. Appears to the
agent as `mcp__crawl4ai__md`, `mcp__crawl4ai__screenshot`, etc.

**Everything else** (npm, git, telemetry, a plugin phoning home) either goes
to squid, where the allowlist decides, or straight to pf's `block drop`,
where the SYN silently vanishes. Container-side DNS is dead on this macOS
beta anyway, so most stray attempts fail at name resolution.

**UI.** Browser → `127.0.0.1:3080` (publish) → container `0.0.0.0:3081`
(socat) → dsh on container loopback 3080. dsh refuses to bind non-loopback,
and browsers only expose `crypto.randomUUID` on secure origins, so both hops
are load-bearing.

## Why each decision

- **Apple container, not Docker Desktop.** Native, each container is its own
  VM (a real kernel boundary), and vmnet puts all container traffic through
  the host where pf can see it. Docker Desktop's VM would hide the traffic
  inside its own NAT.
- **pf anchor via a wrapper file, not editing /etc/pf.conf.** A wrapper
  (`/usr/local/etc/pf-dsh.conf`) `include`s Apple's stock ruleset verbatim
  and adds one anchor. No system file is ever modified; teardown is
  `pfctl -f /etc/pf.conf`. Every rule requires a dshnet address, so host
  traffic (Wi-Fi, Tailscale, VPNs, AirDrop) structurally cannot match.
- **Relays instead of pass rules to remote IPs.** The container talks to
  gateway ports only. What sits behind each port is a host-side decision you
  can change without touching the container or the firewall. It also makes
  the tailnet invisible to the container.
- **squid for domains, pf for IPs.** pf cannot allowlist by hostname. squid
  gives domain-granular allowlisting with an audit log, and pf guarantees
  nothing can bypass squid.
- **Self-hosted search and fetch.** SearXNG and Crawl4AI keep the agent's
  query stream and reading history off third-party API accounts. They do not
  make the web itself self-hosted: every query still fans out to Google,
  Bing, Brave etc. from your IP. See [07-web-research.md](07-web-research.md)
  for what that costs you (rate limits).
- **Plugins baked into the image, not installed at runtime.** The runtime
  container has no route to GitHub or npm. So plugins install at build time
  into a seed home (`/opt/dsh-seed`) inside the image, and the entrypoint
  copies the seed's `profiles/` into the volume whenever the seed version
  changes. See [05-plugins.md](05-plugins.md).
- **uid 501 inside the container.** Matches your macOS account, so files on
  the virtiofs mounts are owned by you on both sides.
- **Full access as the default permission preset.** dsh's own bash sandbox
  needs Landlock or bubblewrap, which the VM kernel lacks, so it would prompt
  on every command. The VM boundary plus pf is the real sandbox; the inner
  one was redundant. Trade-off: the agent can edit its own persistent config
  in `dsh-home/`. See [02-security-posture.md](02-security-posture.md).

## Addresses and ports at a glance

| What | Address | Notes |
|---|---|---|
| dsh UI | http://127.0.0.1:3080 | IPv4 literal only; `localhost` may resolve to ::1 which is not published |
| dshnet gateway | 192.168.66.1 | host side of the bridge; relays bind here |
| dsh container | 192.168.66.x | changes on every recreate; never rely on it |
| squid | gw:3128 | `HTTP_PROXY`/`HTTPS_PROXY` in the container |
| model relay | gw:8090 → `MODEL_HOST` | `baseURL` in settings.yaml |
| searxng relay | gw:8888 → 127.0.0.1:8888 → searxng:8080 | also directly usable from the Mac at 127.0.0.1:8888 |
| crawl4ai relay | gw:8890 → 127.0.0.1:8890 → crawl4ai:11235 | bearer token required (`secrets.env`) |
| default network | 192.168.64.0/24 | searxng, crawl4ai, buildkit; open egress |
