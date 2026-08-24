---
name: weekly-review
description: >-
  Generates a weekly review of ORC Jira activity for the past calendar week and
  writes it into the Obsidian weekly periodic note under
  "# ORC Project Weekly Summary". Use when asked for a weekly review, ORC weekly
  summary, or to update the weekly note with last week's Jira activity.
---

**Goal:** Produce a detailed weekly review of the ORC project in Jira for the past calendar week and save it directly to the Obsidian weekly periodic note.

**Requirements:** Jira and Obsidian MCP tools must be available. Use Confluence tools when tickets reference Confluence pages. When editing the Obsidian note, follow **obsidian-formatting**.

---

## Workflow

Fetch the Jira data first, draft the summary, then patch the Obsidian note. Confirm when done.

### Step 1: Determine the date range

Use the **past calendar week** (Monday–Sunday, or the vault’s configured week start if known). Note the start and end dates; you will need the first date when locating the weekly note.

### Step 2: Collect ORC Jira activity

1. Search Jira (`jira_search`) for ORC issues updated during that week. Prefer JQL scoped to `project = ORC` and the week’s date bounds (e.g. `updated >= "YYYY-MM-DD" AND updated <= "YYYY-MM-DD"`). Paginate if needed.
2. For issues that matter, fetch details and comments (`jira_get_issue` with comments included and a high `comment_limit`).
3. **Grouping:** Group tickets by Epic. If a ticket isn’t assigned to an Epic but clearly belongs to one, infer the Epic and group it accordingly. Create an "Escalations / Support" or "Misc" group for outliers.
4. **Details:** For each ticket, note who was working on it, summarize comments or discussions, and note status changes (e.g. moved from Backlog to In Progress).
5. **Confluence:** If any Confluence documents are mentioned in the tickets, look them up (`confluence_get_page` / `confluence_search`) and summarize their purpose under the relevant ticket.

### Step 3: Draft the summary

- Keep summaries detailed — this is ongoing context, not a skim.
- Add Obsidian-style Markdown admonitions under any ticket that might need attention, for example:
  - `> [!warning]`
  - `> [!info]`
  - `> [!note]`
- Inside the admonition, explicitly state *what kind* of attention is needed (e.g. "We need a decision from stakeholders on this item", "This requires your approval", "Project is blocked pending X", or "This work was cancelled").

Suggested structure under the section (heading itself is owned by the note / patch target — do not duplicate it in replace content unless using `markerAndContent`):

```markdown
_Week of [[YYYY-MM-DD]] – [[YYYY-MM-DD]]_

## Epic Name

### ORC-1234 Title
- Assignees / participants: …
- Status changes: …
- Discussion summary: …
- Confluence (if any): …

> [!warning]
> What attention is needed, and why.
```

### Step 4: Update the Obsidian weekly note

1. Resolve the weekly note path with `periodic_note_get_path` (`period: "weekly"`). That tool returns the **current** weekly note. If the past calendar week is a different note than the current one, locate the correct weekly note by vault path / search using the first date in the review range, then operate on that path.
2. Use `vault_get_document_map` to find the heading. Target heading text is exactly `ORC Project Weekly Summary`. If an existing heading has date ranges in the title, treat it as this section anyway — match on that core text when patching.
3. Replace that entire section’s contents with the new summary via `vault_patch`:
   - `targetType`: `heading`
   - `target`: `ORC Project Weekly Summary` (or the exact heading from the document map if it includes a date range)
   - `operation`: `replace`
   - `contentType`: `text/markdown`
4. If the section does not exist, create it (`createTargetIfMissing: true`) or append it to the document with `vault_append`.

### Step 5: Confirm

Tell the user the weekly note path that was updated and briefly call out any tickets that received attention admonitions.
