---
name: deep-research
description: Structured deep research with human-in-the-loop control (ported from Weizhena/Deep-Research-skills). Generates a research outline (items + fields as YAML) for a topic, refined with the user before any deep investigation. Use for academic research, benchmark research, technology selection, market surveys, or when the user invokes /deep-research. Follow-ups - /deep-research-add-items, /deep-research-add-fields, /deep-research-run, /deep-research-report.
---

# Deep Research - Preliminary Research (outline stage)

NEVER call the `deep_research` TOOL on this host. It is broken (workflow
engine unreachable). This skill family replaces it.

## Trigger
`/deep-research <topic>`

## Workflow

### Step 0: Ground the premise (MANDATORY, do not skip)

Everything downstream inherits whatever you believe the topic *is*. If that
belief is wrong, subagents chase a target that does not exist and cannot
converge. This step exists because that happened: a font was confabulated as
"a blackletter typeface by Christian Schwartz" when it is a geometric sans by
another foundry, and the resulting subagent burned 33 minutes and 1,200
searches on an impossible goal.

If the topic names a specific entity (a product, font, library, company,
paper, standard) you MUST establish what it actually is from a source
before writing any framework:

1. Find its official page: `web_search` for the exact name, then read the
   official/canonical URL with `mcp__crawl4ai__md`. For visual subjects
   (fonts, UI, design), also `mcp__crawl4ai__screenshot` and actually look.
2. Record {premise}: what it is, who makes it, its category, its licence,
   and one distinguishing property, each traceable to a URL you read.
3. If you cannot confirm the entity from a source, say so plainly and ask
   the user for a URL. Do NOT proceed on memory.

**Never describe a named entity from memory.** Confidence is not knowledge:
if you can produce a detailed description without having read anything, treat
that as a warning sign, not a starting point.

### Step 1: Generate Initial Framework
Using {premise} from Step 0 (not memory), generate:
- Main research objects/items list in this domain
- Suggested research field framework

Output {step1_output}, use ask_user_question to confirm. The FIRST question
must surface the premise itself so a wrong one is caught here, in one glance,
rather than by a subagent an hour later:

- "I understand {topic} to be: {premise} (source: {url}). Is that right?"
  Options should include an explicit "No, that's wrong" that stops the flow.
- Need to add/remove items?
- Does field framework meet requirements?

If the user corrects the premise at any point, here or later, discard the
framework built on the old one and redo Step 0 against the source they give.
Do not patch the old framework; a wrong premise contaminates every item in it.

### Step 2: Web Search Supplement
Use ask_user_question to ask for time range (e.g., last 6 months, since 2024, unlimited).

**Parameter Retrieval**:
- `{topic}`: User input research topic
- `{YYYY-MM-DD}`: Current date (run `date +%Y-%m-%d`)
- `{step1_output}`: Complete output from Step 1
- `{time_range}`: User specified time range
- `{premise}`: The grounded description from Step 0
- `{premise_urls}`: The URLs it was established from

**Hard Constraint**: The following prompt must be strictly reproduced, only replacing variables in {xxx}, do not modify structure or wording.

Launch 1 researcher subagent (background) via the `subagent` tool. Then END
YOUR TURN with a one-line status message. Subagent completions are delivered
BETWEEN turns, so busy-waiting (bash sleep loops, polling `job_list` or
`list_agents`) starves the notification and deadlocks you. Never wait
in-turn; the completion will arrive as your next input. Scope note: this subagent SUPPLEMENTS the outline (new
items + fields with one-line rationales); it must not deep-research each item.
Its prompt MUST begin with: "Read
/home/dev/.dsh/skills/deep-research/web-search-agent.md and follow it
strictly. This is a breadth pass: identify missing items and fields quickly;
do not exhaustively research individual items." followed by this
**Prompt Template**:
```
## Task
Research topic: {topic}
Current date: {YYYY-MM-DD}

## Verified premise (established from sources: treat as fact, do not re-guess)
{premise}
Source(s): {premise_urls}

If your searches keep failing to match this premise, the premise is right and
your queries are wrong. Change the queries, and if that does not work, STOP
and report the mismatch. Never widen the search to make a guess fit.

Based on the following initial framework, supplement latest items and recommended research fields.

## Existing Framework
{step1_output}

## Goals
1. Verify if existing items are missing important objects
2. Supplement items based on missing objects
3. Continue searching for {topic} related items within {time_range} and supplement
4. Supplement new fields

## Output Requirements
Return structured results directly (do not write files):

### Supplementary Items
- item_name: Brief explanation (why it should be added)
...

### Recommended Supplementary Fields
- field_name: Field description (why this dimension is needed)
...

### Sources
- [Source1](url1)
- [Source2](url2)
```

### Step 3: Ask User for Existing Fields
Use ask_user_question to ask if user has existing field definition file, if so read and merge.

### Step 4: Generate Outline (Separate Files)
Merge {step1_output}, {step2_output} and user's existing fields, generate two files:

**outline.yaml** (items + config):
- topic: Research topic
- premise: The grounded description from Step 0, one or two sentences
- premise_sources: The URLs it was established from
- items: Research objects list
- execution:
  - batch_size: Number of parallel agents (confirm with ask_user_question)
  - items_per_agent: Items per agent (confirm with ask_user_question)
  - output_dir: Results output directory (default: ./results)

**fields.yaml** (field definitions):
- Field categories and definitions
- Each field's name, description, detail_level
- detail_level hierarchy: brief -> moderate -> detailed
- uncertain: Uncertain fields list (reserved field, auto-filled in deep phase)

### Step 5: Output and Confirm
- Create directory: `/workspace/{topic_slug}/`
- Save: `outline.yaml` and `fields.yaml`
- Show to user for confirmation

## Output Path
```
/workspace/{topic_slug}/
  |- outline.yaml    # items list + execution config
  |- fields.yaml     # field definitions
```

## Follow-up Commands
- `/deep-research-add-items` - Supplement items
- `/deep-research-add-fields` - Supplement fields
- `/deep-research-run` - Start deep research
