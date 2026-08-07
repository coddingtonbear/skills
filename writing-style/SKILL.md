---
name: writing-style
description: >-
  Applies the user's writing style to public material by loading Obsidian
  writing samples. Use when writing PR descriptions, Jira comments, Confluence
  pages, commit message wording, or any public document under the user's name.
---

**Goal:** Match the user's voice and formatting conventions in any public material written under their name.

**Requirements:** Obsidian MCP tools must be available.

---

## Step 1: Load writing samples

When writing any public material under my name -- be it a document, a Jira comment, a confluence issue, a pull request, a code comment or any other document, please follow my writing style. You can find representative documents by searching for obsidian documents matching this expression:

```json
{"==": [{ "var": "frontmatter.writing-sample" }, true]}
```

Read several samples before drafting. Match tone, sentence structure, and level of detail — not just formatting rules below.

---

## Step 2: Apply formatting conventions

Use bold and italicization sparingly. In general:

- You may use italicization for emphasis (e.g.`It's not _not_ that I do that.`).
- You may use bold text for titling bullet points (e.g. `- *Conflicts*: Defer to me on them.`).

---

## Step 3: Draft and review

Apply these conventions to the final output. If the material will also follow another skill (e.g. **git-and-pr-conventions** for commit messages, **jira-ticket-workflow** for ticket-related notes, **obsidian-formatting** when the output is vault markdown), satisfy both — style does not override structural requirements from those skills.
