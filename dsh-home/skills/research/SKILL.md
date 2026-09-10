---
name: research
description: Deep web research using this box's self-hosted pipeline (SearXNG search + Crawl4AI page reading). Use whenever the user asks to research, investigate, look up, or deep-dive a topic online, or invokes /research. Encodes pacing to avoid search-engine rate limits, fallback fetch methods, and a cited synthesis format.
---

# Deep research

You are on a locked-down box with a self-hosted research pipeline. Everything
below reflects how this specific infrastructure behaves.

## Tools and their quirks

- `web_search` goes to a self-hosted SearXNG. Upstream engines rate-limit
  bursts: pace yourself (see below). An empty result set usually means engine
  suspensions, not "no results exist", so switch to the fallback.
- `mcp__crawl4ai__md` is your page reader: real Chromium, returns markdown for
  any URL. This is how you READ sources. Also your search fallback.
- Do NOT use the built-in Fetch tool (its provider is unavailable here) and do
  NOT use bash curl for the web (outbound network is firewalled).

## Stop conditions (these override the method below)

Never re-issue a query you already ran. If two consecutive searches add
nothing, stop and report what you searched and what is missing. If results
keep describing something other than what you were asked about, the premise
is probably wrong. Say that instead of searching until it fits. If a tool
call comes back denied by the circuit breaker, report immediately with what
you have rather than retrying variants. Budget: 12
searches, 15 page reads. Reaching the budget is a normal outcome to report,
not a failure to conceal.

## Method

0. **Ground any named entity first.** If the question names a specific
   product, font, library, company, paper, or standard, establish what it
   actually is from its official page (`web_search` for the name, then
   `mcp__crawl4ai__md` on the canonical URL) BEFORE reasoning about it.
   Never describe a named entity from memory: a confident description you
   did not read is a hallucination risk, not a head start. If you cannot
   confirm it, say so and ask for a URL.

1. **Scope.** Restate the question as a decision or deliverable. Decompose
   into 3-6 sub-questions. Skip this ceremony for narrow questions.
2. **Search, paced.** At most 2 focused `web_search` queries per sub-question
   before reading pages. Prefer one specific query over three vague ones.
   Batch-plan queries up front instead of reactively re-searching.
3. **Fallback when search is thin.** If `web_search` errors or returns empty,
   fetch a search engine's results page directly with `mcp__crawl4ai__md`:
   `https://www.bing.com/search?q=...` or
   `https://html.duckduckgo.com/html/?q=...`, then extract result links
   yourself. Do not hammer a failing engine with retries.
4. **Read before you claim.** Open the 2-4 most promising pages per
   sub-question with `mcp__crawl4ai__md`. Snippets are leads, not evidence.
5. **Track evidence.** For each sub-question keep: confirmed (with source),
   uncertain (conflicting or single-source), gap (nothing found). Note
   contradictions instead of averaging them away.
6. **One gap round.** If gaps remain and the topic warrants it, run one more
   targeted round on the gaps only. Then stop; report gaps honestly.
7. **Synthesize.** Deliver: a direct answer first, then findings grouped by
   sub-question with inline source links, then open gaps and contradictions.
   Distinguish pages you actually read from search-snippet-only claims. Never
   pad thin evidence with generic knowledge without labeling it as such.
