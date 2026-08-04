---
name: release-notes
description: Write GitHub release notes organized by problem solved — an at-a-glance summary, then Features and Bug fixes sections whose entries each state what the software couldn't do before and what it does now. Use when drafting, rewriting, or reviewing release notes or a GitHub release body, when cutting a release, or when the user says "write the release notes", "what goes in the release", or "release notes for vX.Y.Z".
---

# Release Notes

A release note is not a changelog. A changelog answers "what commits landed"; a release note answers **"what could I not do before, that I can do now?"** — for someone who uses the software and has no idea what happens inside it.

The reference implementation of this format is [obsidian-local-rest-api 5.0.0](https://github.com/coddingtonbear/obsidian-local-rest-api/releases/tag/5.0.0). Read it before drafting a large release.

If a `writing-style` skill (or any skill describing the user's prose voice) is available, load it before drafting — it governs sentence-level voice, and this skill governs structure. Where they disagree about phrasing, the writing-style skill wins.

## Gather the material first

Never draft from memory or from a commit-message skim alone. Collect:

```bash
git log --oneline <prev-tag>..HEAD        # what landed
git diff --stat <prev-tag>..HEAD          # where the weight is
gh pr list --state merged --search "merged:>=<date-of-prev-tag>" --json number,title,body
gh issue view <n>                         # for anything a PR says it fixes
```

Read the PR bodies. They usually already contain the "before" state — the reason the work was done — which is the hardest part of each section to reconstruct later.

Every claim in the notes must trace to something in the diff, a PR, or an issue. If a fix has evidence behind it (a fuzz run, a capture, a live test), say so with the number. If something is a guard against a shape never observed in the wild, say that too — the reader calibrates their upgrade urgency on it.

## Problem, not pain

Every section is organized around **the problem the change solves** — a fact about the software, stated plainly. It is *not* organized around the reader's frustration.

The difference is the subject of the sentence:

- Pain framing: *"Getting the delimiter wrong produced confusing failures — or worse, a 'successful' write to the wrong place. You had to fight the header soup on every request."*
- Problem framing: **"A PATCH instruction was assembled from up to eight separate headers. A heading containing the delimiter had to be escaped by hand, and a mis-escaped target addressed a different section than the caller meant — a write that reported success against the wrong place."**

Same facts, no adjectives about how it felt. The test: if the "before" paragraph stops making sense once you delete every word describing annoyance, it was never about the problem. State what was structurally wrong, what it made impossible, and what it made unreliable; the reader supplies their own feelings about it.

Related: never sell. No "we're excited to", no "powerful new", no "seamlessly". The change is interesting because of what it removes from the reader's way, and that is best conveyed by describing it exactly.

## Shape of the document

Two top-level sections carry the release — **Features** and **Bug fixes** — so a reader can tell at a glance whether this release gives them something new or fixes something that was wrong. Each entry inside them is an `###`.

```markdown
<Opening paragraph: what kind of release this is and what the headline change is.
 One or two sentences for a patch release; a short paragraph for a major one.
 See "The opening paragraph" below — this is the easiest line in the document
 to over-write.>

## At a glance                         <!-- see "The at-a-glance list"; not links -->

**Features**
- **<short label>** — <the problem it solves, in a few words>

**Bug fixes**
- **<short label>** — <what was wrong>

---

## Features

### <Change name>: <the problem it solves, in one clause>

**The problem:** <What the software did or couldn't do before. Concrete, mechanical.>

**What's new:** <What it does now. Show the shape — a JSON body, a CLI invocation,
a flag — wherever an example is shorter than the prose describing it.>

### <next change>

...

## Bug fixes

### <Fix name>: <what was wrong, in one clause>

<As much or as little as the fix merits — see "Bug fixes" below.>

**Also fixed**                         <!-- the one-liners, if any -->

- <Problem, then resolution, one or two sentences.> (#12)

---

## Breaking changes and migration      <!-- last, and only when something breaks -->
```

Within each section, order entries by how much the change alters the reader's day — the one most people will notice first goes first — not by merge order and not by size of diff.

Drop a top-level section entirely when it's empty; never leave a `## Features` heading with nothing under it. A release that is only fixes keeps just `## Bug fixes`, and a single-fix patch release can skip both headings and run the opening paragraph straight into one `##` entry — the split exists to make a long list scannable, and there's nothing to scan in a release with one thing in it.

### The at-a-glance list

Include one whenever the release has four or more entries. Below that it costs more space than it saves.

**It cannot be a clickable table of contents.** GitHub renders headings inside a release body as bare `<h2>`/`<h3>` with no `id` and no `<a name>` — verified across repos — so a `[label](#anchor)` link in a release body points at a target that does not exist and silently does nothing when clicked. Write the list as plain bolded labels, never as links.

Each line is a short label — the change's name, not its whole heading — then an em dash and the problem in a few words, so the list reads as a summary of the release on its own:

```markdown
## At a glance

**Features**
- **`clone --filename-as-title`** — a vault shaped for editors where the file name is the title

**Bug fixes**
- **`restore` discarded local-only frontmatter** — the one write path that dropped a layer no pull brings back
```

If the notes need real navigation — a major release with a dozen entries — the destination has to be a rendered file in the repo (a `CHANGELOG.md`, a docs page), where GitHub does generate heading anchors, with the release body linking out to it.

### The opening paragraph

Say what the release does, in the words the reader would use. Name the actual changes rather than an abstraction of them, and prefer the direct construction to the arranged one:

- Stilted: *"A fix release on two threads: the writes this tool sends are now ones your other devices accept, and the notes it writes to disk are spelled the way you typed them."*
- Direct: **"Two fixes here: edits you push now stick on your other devices instead of being silently discarded, and notes written to disk no longer pick up stray backslashes."**

The stilted version isn't wrong, it's *arranged* — a framing device ("on two threads"), a symmetry the content didn't ask for, and each change described one step away from itself. Watch for the tells: announcing the document's own structure, parallel clauses built for balance rather than meaning, and periphrasis where a plain verb would do ("are ones your other devices accept" → "stick on your other devices").

A little playfulness or a light metaphor is welcome when it lands in passing. Cut it when it has to be unpacked to be understood, when it's carrying the structure of the sentence, or when it's the *only* thing the sentence does. The same standard applies throughout the document, but the opening is where over-writing collects, because it's the one paragraph with no specific mechanism to anchor it.

For a small release, drop the `**The problem:** / **What's new:**` labels and write each section as one tight paragraph that still moves problem → resolution in that order. Keep the labels when a release has enough sections that the reader is scanning rather than reading.

## Writing a section

**The heading** names the change and states its problem in one clause: `### Trash by Default: deleting a file was permanent, with no recovery path`. A reader scanning only headings should come away with an accurate list of what this release fixes. Avoid headings that name only the feature (`### COPY`) or only the mechanism (`### Refactor the substring graph`).

**The problem paragraph** describes the previous behavior in enough mechanical detail that a reader can recognize it as something they hit. Name the workaround people used, since that's how they'll identify themselves: *"required either a full read-modify-write of the whole section, or asking users to hand-add a `^block-id` anchor to every list you might ever want to extend."*

**The what's-new paragraph** is specific about the new contract, including its limits. State invariants the reader can now rely on in a form they could test — *"read at scope S, then replace at scope S, is a no-op"*, *"replacing a section with its own content is guaranteed byte-identical"*. Where a change costs something, say so in the same breath and point at what covers the gap: *"The accepted trade-off: content-scope append can no longer continue an existing list — see `within`, below."*

**Examples** earn their space when they're shorter than describing the shape in words. One realistic call, not a tour of the parameters.

**Cross-references** hold the document together: when one change only makes sense on top of another, say so (*"Everything else in this document builds on this rewrite"*) rather than repeating the explanation.

## Bug fixes

Every fix lives here, whatever its size — a fix is never promoted into Features for being important. What varies is depth, and each fix gets exactly as much as it merits:

- **Its own `###` entry**, written like a feature entry, when someone could have lost data or shipped wrong results without knowing, when the reader has to *do* something (re-sync, re-run, change a call), or when telling it honestly takes more than two sentences. These come first, most consequential first, and there's no upper bound on length — a subtle merge bug can earn several paragraphs and the evidence that settles it.
- **A bullet under a final `**Also fixed**` line**, when a sentence or two covers it: a crash, a wrong error code, a broken flag. Still problem-then-resolution, still carrying its issue or PR number.

Use only the form the release needs. A handful of one-liners is just the bullet list, with no `**Also fixed**` label to introduce it.

A fix that was never observed in the wild — a guard against a shape the code could meet but hasn't — says so in its own words. The reader is deciding how urgently to upgrade, and "this has never happened to anyone" is the fact that decides it.

Housekeeping with no reader-visible effect (CI runner bumps, dependency upgrades, internal refactors, added test coverage) is left out entirely — unless it is *why* the reader should trust a fix above it, in which case it belongs in that fix's section as evidence, not as its own entry. Verification that backs the release as a whole rather than any one change (a new live suite, a differential fuzz against the previous version) goes in the opening paragraph, in a clause — evidence always sits with the claim it supports.

## Breaking changes and migration

When anything breaks, it gets its own top-level `##` section, last in the document and listed in the table of contents, containing:

- **What changed**, and the deprecation/sunset signal if there is one (header, warning, version).
- **You are affected if you...** — a list of concrete things the reader might be doing. Follow it with an explicit **Not affected:** line; most readers are in it, and telling them so is the single most valuable line in the section.
- **The escape hatch**, if one exists (a version pin, a compatibility flag) and when it expires.
- **What to try first** — an ordered shortlist by situation: do nothing / pin the old behavior / migrate now, with a link to the full migration guide rather than the guide itself inline.

Say plainly where there is *no* escape hatch. A reader who discovers that at runtime treats every future release note as unreliable.

## Sizing

- **Patch** — opening line, then `## Bug fixes` alone. One fix on its own needs no section headings and no TOC at all.
- **Minor** — the full shape: TOC, `## Features` with an entry per user-visible change, `## Bug fixes`.
- **Major** — the same, plus `## Breaking changes and migration` at the end.

Length follows the number of distinct problems solved, never the number of commits.

## Publishing

Draft into a file, review it as rendered markdown, then:

```bash
gh release create <tag> --title "<tag>" --notes-file <path>   # new
gh release edit <tag> --notes-file <path>                     # rewrite an existing one
```

Confirm with the user before creating or editing a public release — it's outward-facing and notifies watchers.

Then confirm the body contains no in-page anchor links, which never resolve in a release body:

```bash
grep -n '](#' <path>          # expect no matches
```
