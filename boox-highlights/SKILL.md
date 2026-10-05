---
name: boox-highlights
description: >-
  Imports highlights and margin notes from a Boox e-reader connected by USB
  into one note per book under "book notes/" in the Obsidian vault, merging
  new passages into notes that already exist without disturbing anything
  written by hand. Use when asked to import highlights from the e-reader,
  Boox, or e-ink reader, to check what is new on the device, or to pull
  reading notes or annotations off a book.
---

**Goal:** Every book highlighted on the Boox has a note under `book notes/` holding all of its highlights, in chapter and reading order, and re-running the import adds only what is genuinely new.

**Requirements:** The Boox connected by USB and mounted over MTP. Obsidian MCP tools for every vault write. Follow **obsidian-formatting** for anything written into a note body.

**Read-only on the device:** never create, modify, move or delete anything under the Boox's `note/` directory. The export files are the user's only copy.

---

## Layout

```
~/Documents/Notes/book notes/<Title>.md      one note per book
```

`book notes/` is deliberately separate from `reading notes/`, which Readwise syncs and manages on its own. Never write into `reading notes/`.

On the device, each book is a folder under `Internal shared storage/note/`:

```
note/
  Alchemy - Rory Sutherland (183)/
    Alchemy - Rory Sutherland (183)-annotation-2026-09-15_21_57_46.txt
  Notebook-7/
    Notebook-7.pdf        <- a handwritten notebook, not a book; skipped
```

---

## Running an import

Everything is driven by [import_highlights.py](import_highlights.py). It reads the device and the existing note, and prints the merged note text. **It never writes to the vault** — that write goes through the Obsidian MCP, so a running Obsidian sees the change.

1. **Inventory the device.** `./import_highlights.py list` prints each book, its title, how many highlights the newest export holds and how many of those are not yet in the vault. Books showing `+0 highlights` need no work; say so and move on rather than rewriting the note.

2. **Render each book that has something new.**

   ```
   ./import_highlights.py render "<device folder name>" --out /tmp/<slug>.md
   ```

   The folder name is the `folder:` line from `list`, quoted exactly — it contains spaces, commas and sometimes `&`. A JSON summary goes to stderr; the merged note goes to `--out`.

   The script reads the current note from `~/Documents/Notes/book notes/<Title>.md` on disk to merge against. Pass `--vault` if the vault is elsewhere.

3. **Write it to the vault** with the Obsidian MCP `vault_write`, to `book notes/<Title>.md`, using the rendered file's contents verbatim.

4. **Report** what landed: per book, highlights added, annotations added, chapters added. Mention books that were already up to date in one line, not one line each.

If the device is not mounted the script says so and explains how to connect it. Relay that rather than guessing at a path.

---

## Note format

```markdown
---
title: The Elephant in the Brain
author:
  - "[[Kevin Simler]]"
  - "[[Robin Hanson]]"
source: boox
boox-folder: Elephant in the Brain, The - Kevin Simler & Robin Hanson
highlight-count: 23
first-highlighted: 2026-03-03
last-highlighted: 2026-07-13
imported: 2026-09-15
---

# Introduction

- It's not that we're literally incapable of perceiving these motives... (p. 19)
    - Note: thesis

# 2 Competition

- The problem with words is that they cost almost nothing; talk is usually too cheap. (p. 59)
    - Note: this makes me think of LLMs and costly versus cheap signaling.
```

- **No title heading.** The filename carries the title, per **obsidian-formatting**; chapters are the first heading level (`#`).
- **Dates in frontmatter stay plain ISO**, unlinked, so Obsidian reads them as dates and Bases can sort on them. The date-linking rule in **obsidian-formatting** applies to note bodies, and nothing this skill writes into a body is a date.
- **`boox-folder`** ties the note back to the device folder after the title has been normalized. Leave it alone.

Titles come from the device folder name, which is the ebook's filename stem: the `(183)` page-count suffix is dropped, a trailing ` - <author>` is dropped when it matches the export's author field, and `Elephant in the Brain, The` becomes `The Elephant in the Brain`.

---

## What the export file looks like

```
Reading Notes | <<Alchemy - Rory Sutherland (183)>>Rory Sutherland
Prologue: Challenging Coca-Cola
2024-08-28 07:58  |  Page No.: 12
When I say that Red Bull 'tastes kind of disgusting', this is not
a subjective opinion.
【Annotation】worth remembering
-------------------
```

Four things about this format bite anyone parsing it by hand, and the script already handles all of them:

- The spaces around `|` in the header and timestamp lines are **non-breaking spaces**, not ordinary ones.
- A **chapter line is optional** — it appears only when the chapter changed since the previous record. A record whose first line is not a timestamp starts with a chapter heading.
- The note marker is `【Annotation】` on current firmware and **`【Note】` on older exports**. Both occur in the same vault.
- Highlight text and notes can both span several lines; the record ends at a line of exactly 19 hyphens.

---

## Why re-imports match on text

Each export is a **complete dump**, not a delta, so only the newest file in a book's folder is read. Older exports are ignored rather than merged, so a highlight deleted on the device is not resurrected.

Two fields that look like good identity keys are not:

- **Page numbers drift.** An EPUB reflows, so the same passage in *Measure What Matters* is page 12 in the 2024 export and page 9 in the 2026 one.
- **Timestamps drift.** A firmware change shifted every recorded time by two hours between those same two exports.

So a highlight's identity is its **text**, normalised to NFC with whitespace collapsed. The page recorded in the note is whatever the first import saw, and is never rewritten — it is an approximate locator, not a fact about the book.

---

## What a merge will and will not touch

The merge into an existing note is **insert-only**. No line already in the body is rewritten, reordered or removed, so prose the user added survives untouched. Only the managed frontmatter keys are rewritten.

- A new highlight is inserted **after the nearest earlier highlight of its chapter that the note already has**, so it lands in reading order rather than at the end.
- A new chapter becomes a new `#` section placed after the section before it.
- An annotation added on the device after the highlight was already imported is attached to that highlight as a `- Note:` child.
- If nothing is new, the note is returned byte-identical and `imported:` is left at its previous value. Do not write it back.

---

## Tests

```
python3 -m pytest boox-highlights/
```

`test_import_highlights.py` covers the format quirks above, title normalisation, and the merge guarantees — including that hand-written prose survives, that a reflowed page number is not mistaken for a new highlight, and that a re-import of an unchanged export produces no diff. Add a case here before changing parsing or merge behaviour.
