---
name: deep-research-add-fields
description: Add field definitions to an existing /deep-research outline. Use when refining what data gets collected per item before the deep phase, or when the user invokes /deep-research-add-fields.
---

# Deep Research Add Fields - Supplement Research Fields

## Trigger
`/deep-research-add-fields`

## Workflow

### Step 1: Auto-locate Fields File
Find `*/fields.yaml` file under /workspace, auto-read existing fields definitions.

### Step 2: Get Supplement Source
Ask user to choose:
- **A. User direct input**: User provides field names and descriptions
- **B. Web Search**: Launch a researcher subagent (which must first read
  /home/dev/.dsh/skills/deep-research/web-search-agent.md) to search common
  fields in this domain

### Step 3: Display and Confirm
- Display suggested new fields list
- User confirms which fields to add
- User specifies field category and detail_level

### Step 4: Save Update
Append confirmed fields to fields.yaml, save file.

## Output
Updated `{topic}/fields.yaml` file (in-place modification, requires user confirmation)
