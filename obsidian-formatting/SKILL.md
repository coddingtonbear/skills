---
name: obsidian-formatting
description: >-
  Applies heading, linking, and markdown structure conventions when creating or
  editing notes in the Obsidian vault. Use when writing or updating any Obsidian
  note, vault markdown, personal notes, meeting notes, or documentation stored
  in Obsidian — including but not limited to Jira ticket notes.
---

**Goal:** Keep Obsidian vault markdown consistent with vault conventions whenever a note is created or edited.

**Requirements:** Obsidian MCP tools must be available when reading or writing vault files.

---

## Headings

Notes do *not* need a heading describing the content of the file as a whole -- the filename performs that function. Do not change the filename without asking for explicit confirmation.

Sub-sections of the document should use h1 headings, and sub-sections of those headings should be h2 and so on.

When editing Obsidian vault markdown, use a strict heading ladder: the first heading in the body after frontmatter should be #. Do not use ## until a # has appeared above it in the same file; nest subsections one level deeper under their parent (no skipped levels).

---

## Linking

When mentioning certain kinds of things in an Obsidian note, be sure to make it a link by surrounding it in double-brackets:

- Names: If you're mentioning somebody's name, that should be a link (e.g. `Mark Twain` should be entered as `[[Mark Twain]]`).
- Dates: If you're mentioning an ISO date, that should be a link (e.g. `2026-01-01` should be entered as `[[2026-01-01]]`).

Exceptions:

- This link should not be performed in any code blocks.

### Wikilink syntax

Obsidian wikilinks use double brackets: `[[note name]]`. To show different link text than the target, use a pipe:

```markdown
[[path/to/note|display text]]
```

The left side is the **link target** (note path or title, without `.md`). The right side is what renders in the note.

### Jira issue notes (`issues/`)

Issue notes live under `issues/` with filenames like `issues/ORC-7159 - Create new Goal via Drawer.md`. Each note's frontmatter includes the issue key as an alias (e.g. `aliases: [ORC-7159]`).

**Do not rely on alias-only links** such as `[[ORC-7159]]` or `[[SECURITY-3467]]`. In practice these often fail to resolve when the filename is long or the alias has not been indexed yet.

**Preferred pattern** when linking to an issue from another note (daily notes, meeting notes, etc.):

```markdown
[[issues/ORC-7159 - Create new Goal via Drawer|ORC-7159]]
```

- **Left of pipe:** full path from vault root, matching the filename without `.md` (include the `issues/` prefix).
- **Right of pipe:** short display text — usually the Jira issue key.

Examples:

```markdown
See [[issues/SECURITY-3467 - Vulnerability Disclosure - IDOR — cross-tenant data exposure on go.airship.com (AI Journeys usage API)|SECURITY-3467]] for full write-up.

### [[issues/ORC-7207 - Unable to create a message center message in campaign agent|ORC-7207]]: Adding a Message Center message
```

When creating a new issue note, still add the issue key to `aliases` in frontmatter (see **create-jira-note-in-obsidian**). Aliases are useful for Obsidian search and backlink display, but **outbound links from other notes should use the pipe form above**.

To find the correct left-hand path, list `issues/` or read the note's `path` from `vault_read`.

---

## Related skills

- **obsidian-dev-logs** — when and how to maintain Development Log sections during active work
- **create-jira-note-in-obsidian** — issue note filenames, frontmatter, and `aliases` setup
- **jira-ticket-workflow** — ticket kickoff and Airship plans
- **writing-style** — voice and tone for public material under the user's name (apply alongside this skill when both apply)
