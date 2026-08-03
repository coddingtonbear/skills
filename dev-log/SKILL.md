---
name: dev-log
description: Manage Development Logs in the Obsidian vault — find the right project note, add decision/finding entries, and mark entries obsolete. Use when documenting a decision, trade-off, or finding during development work, when the user mentions "dev log" or "development log", or before reading or updating any "Development Logs" section of a vault note.
---

# Development Logs

Decisions, trade-offs, and durable findings made during development are documented in a `# Development Logs` section of the relevant project note in the Obsidian vault. Write these entries **proactively, without waiting to be asked** — whenever we decide an implementation detail, accept a trade-off, uncover something a future reader of the work would need, or spot something to raise in a demo.

All vault access goes through the `mcp__obsidian__*` tools — never filesystem reads/writes, even if a directory of look-alike markdown files is visible.

## Finding the relevant note

Most things have a URL — a GitHub repository, issue, or discussion; a website; almost anything. The note for a thing is the one whose `url` frontmatter matches:

```json
{"==": [{"var": "frontmatter.url"}, "<the-url>"]}
```

via `mcp__obsidian__search_query`.

For a git checkout, get the URL from `git remote get-url origin` and normalize it: `git@github.com:owner/repo` and `https://github.com/owner/repo` are the same repository, and the **HTTPS form is what the vault uses**. Strip any trailing `.git`.

If no note matches, ask the user whether to create one rather than guessing at a location.

## Entry format

Entries go under an h1 section named exactly `Development Logs` (create it if the note doesn't have one). Each entry is an h2 whose heading is an ISO timestamp plus a short summary, followed by a long description of the decision and the context that led to it:

```markdown
## 2026-05-06T10:01 -- Selected "modular" approach

A trade-off was found between taking the "fast" approach and a "modular" one, and we selected the "modular" approach together.
```

Get the timestamp from the shell — never from memory: `date +%Y-%m-%dT%H:%M`.

Write for a future reader with no session context: what was decided, what alternatives were on the table, why this one won, and pointers (files/functions, branch names, related entries) that make the work findable later.

## Immutability and obsolescence

Entries are **immutable** once written, with one exception: when an entry's content has been superseded, add a WARNING-type admonition at the top of that entry (and optionally mark the heading `(Obsolete)`), pointing at the authoritative later entry when one exists:

```markdown
## 2026-05-06T10:01 -- (Obsolete) Selected "modular" approach

> [!WARNING]
> This section is obsolete; refer to "Adjusted "modular" approach following revelation about flux capacitors" below for the current version.

A trade-off was found between taking the "fast" approach and a "modular" one, and we selected the "modular" approach together.
```

Never rewrite, trim, or delete an existing entry's body — new information gets a new entry.

## Mechanics and cautions

- **Long documents**: Development Logs get *extensive*. Call `vault_get_document_map` first to see the headings that exist, then read only the sections that matter (`vault_read` with `targetType`/`target`) instead of the whole note.
- **Appending an entry**: prefer a targeted `vault_patch` append to the `Development Logs` heading over rewriting the file.
- **Human edits race with mine**: vault notes may be edited between my read and my write. Before any operation that could lose data (`vault_write`, or `vault_patch` with the `replace` method), re-fetch the relevant content and confirm it still matches what my draft was based on.
