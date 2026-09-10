# Web research pipeline

## What "self-hosted" buys and what it does not

SearXNG and Crawl4AI run on your Mac. That keeps the agent's query stream
and reading history off any third-party account, needs no API keys, and
makes every request auditable in your own logs. It does not make the web
self-hosted: SearXNG is a metasearch engine that fans each query out to
Google, Bing, Brave, DuckDuckGo, Startpage, Qwant and others, from your home
IP, against their public HTML endpoints. Crawl4AI renders real websites.
Those sites see a scraper. Everything below about rate limits follows from
that.

## Search: SearXNG

Container `searxng` on the `default` network, image `searxng/searxng:latest`
(2026.8.22 at time of writing), config mounted from `host/rendered/searxng/settings.yml`:

- `formats: [html, json]`, because dsh-web-tools uses the JSON API
- `limiter: false`, private instance, no bot detection of our own clients
- engines added for diversity: bing, mojeek, qwant, wikipedia; longer
  outgoing timeouts
- published to host loopback `127.0.0.1:8888`, relayed to `gw:8888`

dsh-web-tools config (`dsh-home/settings.yaml`, `dsh-web-tools:` key):
`defaultProvider: searxng`, `fallbackOrder: [searxng]`, `providerBaseUrls.searxng:
http://192.168.66.1:8888`. Plus the `WEB_TOOLS_SEARXNG=local` dummy
credential in `run.sh` (upstream bug, see [05-plugins.md](05-plugins.md)).

Check engine health from the Mac:

```sh
curl -s 'http://127.0.0.1:8888/search?q=test&format=json' | jq '{n: (.results|length), unresponsive: .unresponsive_engines}'
```

Check who is actually answering:

```sh
curl -s 'http://127.0.0.1:8888/search?q=test&format=json' | jq -r '[.results[].engines[]] | group_by(.) | map({e: .[0], n: length})'
```

## Fetch: Crawl4AI

Container `crawl4ai` on the `default` network, built from
`host/crawl4ai/Dockerfile` (upstream `unclecode/crawl4ai:latest`, 0.9.2,
plus a `config.yml` with `app.host: 0.0.0.0`). Chromium inside, 4 GB memory
limit. Published to `127.0.0.1:8890`, relayed to `gw:8890`, bearer token required.
The value lives in `secrets.env` as `CRAWL4AI_TOKEN`; `run.sh` passes it in as
`CRAWL4AI_API_TOKEN` and `./scripts/rotate-secrets.sh` replaces it.

Its built-in MCP server (SSE at `/mcp/sse`) is bridged to dsh by
`supergateway` (stdio), mounted as the `mcp-crawl4ai` row in
`dsh-home/cordis.patch.yml`. The agent sees `mcp__crawl4ai__md` (URL →
markdown, the workhorse), `screenshot`, `pdf`, `execute_js`, `crawl`,
`html`, `ask`.

That bridge connects once, when dsh boots, and exits permanently if crawl4ai
refuses the connection. There is no retry and nothing surfaces in the UI: the
agent simply has no fetch tools. `run.sh` therefore waits for crawl4ai to
answer `/health` before it creates the dsh container. Check the bridge came up
with `container logs dsh | grep -c tools`.

Direct use from the Mac:

```sh
curl -s -X POST http://127.0.0.1:8890/md -H "Authorization: Bearer <token>" \
  -H 'Content-Type: application/json' -d '{"url":"https://example.com"}' | jq -r .markdown
```

Because it is a real browser, Crawl4AI passes fingerprint checks that block
SearXNG's plain HTTP requests. That makes it the fallback search engine too:
fetch `https://www.bing.com/search?q=...` or
`https://html.duckduckgo.com/html/?q=...` as markdown and read the links.
The skills do this when SearXNG returns nothing.

## Rate limiting, the recurring reality

A 27B local model doing research issues many queries quickly. Engines see a
burst of programmatic requests from one residential IP and respond with
`too many requests`, `CAPTCHA`, or timeouts. SearXNG tracks these as
per-engine suspensions that expire on their own (minutes to hours). Observed
on day one: Brave, Google, Startpage suspended, Qwant captcha, DuckDuckGo
timing out, all within an hour of heavy use.

What helps, in order of effort:

1. **Pace the agent.** The skills cap searches per sub-question. Fewer,
   better queries.
2. **Engine diversity.** Already configured. Bing and Qwant carried the load
   while the others were suspended.
3. **Crawl4AI as fallback search.** Already in the skills.
4. **Rotate the egress IP.** SearXNG supports `outgoing.proxies` (HTTP or
   SOCKS). Point it at a box you control on the tailnet or a VPS and
   engines see a different address. Quiet non-hyperscaler IPs run for
   months; AWS/GCP ranges are the most blocked. Not done; needs a second
   machine.
5. **Browser impersonation in SearXNG.** Upstream work in progress
   (curl-cffi TLS fingerprints, PR #4801 / issue #5476). When it ships,
   update the image.

What does not help: Tor as the outgoing proxy (exit IPs are the most-blocked
addresses on the internet); automated captcha solving (closed upstream,
needs paid services).

## Mojeek specifically

Mojeek is the engine friendliest to metasearch and the one that captcha-walled
this IP first. Its captcha page comes back as HTTP 200 with no result
markers, and SearXNG's detector does not recognise it, so the engine reports
zero results with no error instead of "suspended". Solving the captcha in a
browser on the Mac does not clear it for SearXNG: a cookie-less request from
the same IP still gets the captcha, so the clearance is session-scoped. The
SearXNG docs' "answer the captcha from the server's IP" trick only works for
engines with IP-scoped clearance. Leave Mojeek enabled and let the wall
decay.

## Tuning knobs

| Want | Change |
|---|---|
| more engines | `engines:` list in `host/templates/searxng-settings.yml.tmpl`, then `./setup-host.sh` and `./run.sh` |
| longer per-engine waits | `outgoing.request_timeout` / `max_request_timeout` |
| different search categories per query | the skills pass hints; dsh-web-tools maps topic → SearXNG categories (it/science/news) |
| a different reader behaviour | Crawl4AI `md` accepts filter `fit` vs raw; the MCP tool exposes it |
| more Crawl4AI concurrency | `--cpus`/`--memory` in `run.sh`, and the work-queue settings in `host/crawl4ai/config.yml` |

## Auditing what the agent read

- SearXNG queries: `container logs searxng` (uwsgi access lines).
- Pages fetched: `container logs dsh | grep "url: 'http"` shows every
  `mcp__crawl4ai__md` call the bridge relayed, or `container logs crawl4ai`.
- Anything that tried to go around the pipeline: squid's access log and pf
  drops (tcpdump on the bridge).
