---
name: deep-research-run
description: Execute the deep phase of /deep-research - read the research outline, launch an independent researcher subagent for each item batch, each writing validated structured JSON. Use after /deep-research produced outline.yaml and fields.yaml, or when the user invokes /deep-research-run.
---

# Deep Research Run - Deep Research (ported from research-deep)

NEVER call the `deep_research` TOOL on this host. It is broken.

## Trigger
`/deep-research-run`

## Workflow

### Step 1: Auto-locate Outline
Find `*/outline.yaml` file under /workspace, read items list, execution config (including items_per_agent).

### Step 1.5: Sanity-check the outline before spending a batch
Read outline.yaml's topic and premise. If it looks wrong or self-contradictory
(the entity's category, maker, or licence does not match what you know from
the sources cited), stop and raise it with the user before launching agents.
A wrong premise multiplies across every item and every agent in the batch.

### Step 2: Resume Check
- Check completed JSON files in output_dir
- Skip completed items

### Step 3: Batch Execution
- Batch by batch_size (need user approval before next batch)
- Each agent handles items_per_agent items
- Launch researcher subagents via the `subagent` tool (background parallel)
- Every subagent prompt MUST begin with: "Read
  /home/dev/.dsh/skills/deep-research/web-search-agent.md and follow it
  strictly." followed by the template below.

**Parameter Retrieval**:
- `{topic}`: topic field from outline.yaml
- `{item_name}`: item's name field
- `{item_related_info}`: item's complete yaml content (name + category + description etc.)
- `{output_dir}`: execution.output_dir from outline.yaml (default: ./results)
- `{fields_path}`: absolute path to the topic's fields.yaml
- `{output_path}`: absolute path to {output_dir}/{item_name_slug}.json (slugify item_name: replace spaces with _, remove special chars)

**Hard Constraint**: The following prompt must be strictly reproduced, only replacing variables in {xxx}, do not modify structure or wording.

**Prompt Template**:
```
## Task
Research {item_related_info}, output structured JSON to {output_path}

## Field Definitions
Read {fields_path} to get all field definitions

## Output Requirements
1. Output JSON according to fields defined in fields.yaml
2. Mark uncertain field values with [uncertain]
3. Add uncertain array at the end of JSON, listing all uncertain field names
4. All field values must be in English

## Limits
Budget: 12 searches and 15 page reads for this item. Never re-issue a query
you already ran. If two consecutive searches add nothing, stop and fill the
remaining fields with [uncertain]. An honest gap beats an invented value or
an endless search. If what you find contradicts the item's description in
outline.yaml, say so in your report rather than searching until it fits.
If any tool call comes back denied by the circuit breaker, do not retry or
rephrase it: write your JSON immediately from what you already have and stop.

## Output Path
{output_path}

## Validation
After completing JSON output, run validation script to ensure complete field coverage:
python3 /home/dev/.dsh/skills/deep-research/validate_json.py -f {fields_path} -j {output_path}
Task is complete only after validation passes.
```

### Step 4: Wait and Monitor
- After launching a batch, END YOUR TURN with a one-line status message.
  Completions are delivered BETWEEN turns. Busy-waiting in-turn (bash sleep
  loops, polling `job_list`/`list_agents`) starves the notifications and
  deadlocks you.
- When completions arrive, verify the batch's JSON files exist, then ask the
  user before launching the next batch
- Display progress

**Circuit-breaker incidents.** At the start of every turn while agents are
outstanding, read `/workspace/.circuit-breaker-incidents.jsonl` (it may not
exist; that is fine). A line there means that agent tripped the breaker and
was told to report immediately. A denial is not a kill: a truly stuck agent
ignores the instruction and never completes, so without this check you wait
forever on a result that is not coming.

- Trip is under 5 minutes old, or the item's JSON now exists: no action.
- Older than 5 minutes with no output: match the incident to a `list_agents`
  id (the `agent` field, or by elimination against your outstanding items),
  call `interrupt_agent` on it, and re-dispatch that item ONCE, appending to
  the briefing: "A previous agent tripped the circuit breaker on this item
  (tool {tool}, repeated {count} times). Treat that line of investigation as
  exhausted."
- The replacement also trips: stop retrying. Mark the item's fields
  [uncertain] and move on. A second trip usually means the item itself is
  unsatisfiable, most often a wrong premise, so surface that to the user.

### Step 5: Cleanup, verify no subagents are left running (MANDATORY)
Before declaring the run done:
1. Call `list_agents` and check for any agent with status `running`.
2. For every `running` agent that belongs to this research run, call
   `interrupt_agent` with its id. If it does not settle, retry the interrupt
   once more.
3. Re-run `list_agents` and confirm zero agents are `running`. Only settled
   (`ready`/`idle`) agents may remain. They are inert history.
4. State the result explicitly in your final message: "All subagents stopped"
   or list any that could not be settled and why.

Do NOT skip this step even if you believe all agents finished on their own.
A late-arriving or stuck agent can still write duplicate/contradictory output
files after the summary is produced. This check is what catches it.

### Step 6: Summary Report
After all complete AND cleanup verified, output:
- Completion count
- Failed/uncertain marked items
- Output directory
- Confirmation that no subagents remain running

## Agent Config
- Background execution: Yes
- Resume support: Yes

## Follow-up
- `/deep-research-report` - Generate the summary report
