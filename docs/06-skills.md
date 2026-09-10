# Skills

dsh skills are the same idea as Claude Code skills: a directory with a
`SKILL.md` (YAML frontmatter `name` and `description`, then instructions),
discovered from the filesystem, injected into the model's context as a
catalog so it can trigger them itself, and invocable by typing `/name` in
the composer.

## Where they live

Discovery roots (`@deepseek-ai/dsh-skill-filesystem`):

- `$DSH_HOME/skills/<name>/SKILL.md`, i.e. `dsh-home/skills/` on the Mac.
  User-level, survives rebuilds, versioned in this repo. This is where ours
  are.
- `<workspace>/.dsh/skills/` and `<workspace>/.agents/skills/`. Project-level.
- Flat `<name>.md` files in the same roots also count.

Names must match `^[a-z0-9]+(-[a-z0-9]+)*$`. The provider watches the
filesystem, so a new skill appears in the composer within seconds, no
restart. Extra files in the skill directory are available to the model by
path ("Base directory for this skill" is injected with the catalog), so a
skill can ship reference documents and scripts.

## Installed skills

### /research

One-shot deep exploration. Encodes what the agent needs to research well:

- decompose into sub-questions, at most 2 `web_search` calls per
  sub-question before reading pages (engines rate-limit bursts)
- treat empty search results as engine suspensions and fall back to
  fetching a results page through `mcp__crawl4ai__md`
  (`https://www.bing.com/search?q=...`, `https://html.duckduckgo.com/html/?q=...`)
- never use the built-in Fetch tool (its provider is unavailable) or bash
  curl (firewalled)
- read 2 to 4 pages per sub-question before claiming anything
- report: direct answer, findings by sub-question with links, open gaps and
  contradictions, sources actually read vs snippet-only

File: `dsh-home/skills/research/SKILL.md`.

### /deep-research family

A port of [Weizhena/Deep-Research-skills](https://github.com/Weizhena/Deep-Research-skills):
research as a curated dataset of items × fields with human checkpoints.
Prompts marked as hard constraints upstream were kept verbatim; only tool
names and paths were adapted (`WebSearch` → `web_search`, `WebFetch` →
`mcp__crawl4ai__md`, `Task` → `subagent`, `AskUserQuestion` →
`ask_user_question`). Named with the `deep-research-` prefix to avoid the
`/research` skill and the broken `deep_research` tool.

| Skill | Stage | Produces |
|---|---|---|
| `/deep-research <topic>` | ground the premise from sources, framework, premise + framework checkpoint, one researcher subagent supplements items and fields | `/workspace/<topic>/outline.yaml`, `fields.yaml` |
| `/deep-research-add-items` | refine | appends to `outline.yaml` |
| `/deep-research-add-fields` | refine | appends to `fields.yaml` |
| `/deep-research-run` | deep phase: batched parallel researcher subagents, one JSON per item, validated by `validate_json.py`, resumable; watches the circuit-breaker incident log and interrupts a tripped agent that goes quiet | `results/<item>.json` |
| `/deep-research-report` | report: generates and runs `generate_report.py` | `report.md` with TOC and per-category sections, `[uncertain]` values skipped |

Shared assets in `dsh-home/skills/deep-research/`: `web-search-agent.md`
(the researcher briefing every subagent reads first, with a "this box's
tools" preamble), `modules/` (search strategies: github-debug,
academic-papers, general-web, stackoverflow, chinese-tech),
`validate_json.py` (verbatim upstream). Subagent prompts reference these by
absolute container path `/home/dev/.dsh/skills/deep-research/`.

Typical run: `/deep-research <topic>` → answer its questions →
`/deep-research-run` (approve each batch) → `/deep-research-report`. Batch
size 2 is kinder to the search engines than 3.

## Lessons baked into the skills

- **A gate the agents can talk past is not a gate.** The 2026-09-01 research
  run's outline phase emitted fields.yaml in a flat shape the validator
  refused, so "task is complete only after validation passes" failed for
  every agent, and every agent reported complete anyway. Nothing downstream
  noticed until a human ran the validator by hand. The validator now accepts
  both shapes the skills emit; the durable lesson is that a checkpoint only
  works if its failure blocks something, because agents treat a failing
  side-check the way they treat advice.
- **Ground the premise before fanning out.** Every skill now requires reading
  a named entity's official page before reasoning about it, and
  `/deep-research` surfaces its understanding as the first checkpoint
  question with an explicit "No, that's wrong" option. A wrong premise
  handed to subagents is unfalsifiable from the inside: they search forever
  for something that does not exist. See the loop post-mortem in
  [04-troubleshooting.md](04-troubleshooting.md).
- **Hard budgets and stop conditions.** 12 searches, 15 page reads; never
  re-issue a query already run; two consecutive unproductive searches means
  stop and report. Reaching a budget is a reportable outcome, not a failure
  to conceal.
- **End the turn after launching background subagents.** dsh delivers
  completions between turns. A parent that busy-waits inside its turn (bash
  sleep loops, polling `job_list`/`list_agents`) never receives them and
  spins forever. `job_list` is a different subsystem and reports the
  subagent id as "unknown job". If it happens anyway: "Stop generating",
  then tell the parent to continue.
- **Breadth pass vs deep pass.** The outline stage's subagent was
  researching every item in depth. Its brief now says to identify missing
  items and fields quickly and not to research individual items.
- **Say which fetch tool to use.** Without it the model reaches for the
  built-in Fetch (fails) or bash curl (blocked) and reports "no network".

## Writing a new skill

1. `mkdir dsh-home/skills/<name>` and write `SKILL.md`:

   ```markdown
   ---
   name: <name>
   description: One or two sentences saying when to use it and what it does. This text is what the model sees in the catalog; make the trigger conditions explicit.
   ---

   # Title
   Instructions...
   ```

2. Name the tools available here by their real names: `web_search`,
   `mcp__crawl4ai__md`, `subagent`, `ask_user_question`, bash, file tools.
   State what not to use.
3. If it launches subagents, tell it to end the turn and wait for the
   completion.
4. Type `/` in the composer to confirm it was discovered, then run it once
   on a small task and read the trajectory.

Keep skills in this repo, not only on the volume: `dsh-home/` is the volume,
so that is automatic.
