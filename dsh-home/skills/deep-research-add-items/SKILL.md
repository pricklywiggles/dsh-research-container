---
name: deep-research-add-items
description: Add items (research objects) to an existing /deep-research outline. Use when refining a research outline before the deep phase, or when the user invokes /deep-research-add-items.
---

# Deep Research Add Items - Supplement Research Objects

## Trigger
`/deep-research-add-items`

## Workflow

### Step 1: Auto-locate Outline
Find `*/outline.yaml` file under /workspace, auto-read.

### Step 2: Get Supplement Sources in Parallel
Simultaneously:
- **A. Ask user**: What items to supplement? Any specific names?
- **B. Ask if Web Search needed**: Launch a researcher subagent (which must
  first read /home/dev/.dsh/skills/deep-research/web-search-agent.md) to
  search for more items?

### Step 3: Merge and Update
- Append new items to outline.yaml
- Display to user for confirmation
- Avoid duplicates
- Save updated outline

## Output
Updated `{topic}/outline.yaml` file (in-place modification)
