---
name: pr-review-to-obsidian
description: >-
  Runs a code review of the current branch's pull request and writes the
  assessment into a new note in the Obsidian `code-review/` folder instead of
  displaying it in chat, leading with a map of the code paths whose effects a
  revert can't undo (database writes, sends to third parties, stored formats),
  cross-checking the PR against its linked Jira issue, and including a
  diagrammed architecture overview. Use when the user runs
  /pr-review-to-obsidian, or asks to "review this PR for my notes", "write up
  a code review in Obsidian", or similar.
---

**Goal:** Produce a code review for the current branch's PR, written to a new
Obsidian note under `code-review/` (not shown in chat). The note leads with
where to focus: the code paths whose effects outlive a revert (data written,
messages sent, formats stored), so the user can spend review attention there
and skim everything a follow-up change could fix. It is cross-checked
against the PR's linked Jira issue and includes a diagrammed architecture
overview of how the change composes with what it touches. The resulting
note becomes the basis for a comment back-and-forth in Sidemark
(**sidemark-comments**) as the user reads and questions the review. This
skill starts a live background watch on Sidemark's event stream for that
back-and-forth itself (Step 8) rather than waiting to be asked.

**Requirements:** `gh` CLI, Jira (Atlassian) MCP tools, the Obsidian MCP
tools — including `open_file`, Sidemark's comment tools (`comments_list`,
`comments_reply`, …), and `events_get_listener_url`, which Step 8's watch
depends on — and the `EnterWorktree`/`ExitWorktree` tools, which Step 1.3's
temporary worktree and Step 11's cleanup depend on.

---

## Step 1: Identify the PR

1. Determine the current branch and use `gh pr view --json title,url,number,headRefName,headRefOid,body`
   to get the open PR for it. Compare against `origin/main` via the merge-base,
   per **git-and-pr-conventions**, if you need the diff itself. Keep
   `headRefOid`: Step 2 builds permalinks from it.
2. If there's no open PR for the current branch, stop and tell the user — do
   not guess a target.
3. Create a temporary worktree for this review and switch into it, so the
   review and the potentially hours-long comment watch (Steps 8–10) run in
   their own checkout instead of tying up your main one while you work on
   something else:
   - The PR's branch is likely already checked out in your main working
     tree (it's the current branch), so check out its current commit
     detached rather than by branch name, e.g.
     `git fetch origin <headRefName> && git worktree add --detach
     .claude/worktrees/pr-review-<PR number> FETCH_HEAD`.
   - Switch the session into it with `EnterWorktree({path: "<path above>"})`
     so the rest of this skill (Steps 2–10) runs from there. Remember this
     path — Step 11 removes it.

## Step 2: Map the lasting effects

Before the line-level review, find every code path in the PR whose effect a
revert can't undo. The test is not "does this write?" but **"if this ships
and we then revert the PR, is everything back the way it was?"** This map
leads the note and steers Step 3's review, so the user can focus on these
paths and accept that anything else may need a follow-up change.

1. **Find the paths.** Walk each changed function or component and follow
   its calls until they reach one of these boundaries (or don't). The PR
   doesn't have to touch the boundary itself — a changed caller of an
   existing write path counts:
   - **Persisted data:** database writes and deletes, schema or data
     migrations and backfills, caches with long lifetimes, search indexes,
     object storage, files.
   - **Sends:** push notifications, emails, SMS, webhooks, queue or
     event-bus messages, analytics events, calls to third-party APIs that
     change state there.
   - **Stored formats and contracts:** anything that builds a payload or
     blob that gets saved (e.g. a ComposerData UIState built in frontend
     code, a JSON column, a serialized config) or that external clients
     depend on (API response shapes, event schemas). Frontend code that
     builds something later saved is a write path, even though it looks
     like UI code.
   - **Access:** permission, authentication, or tenant-scoping changes,
     where a mistake exposes data that can't be un-exposed.
2. **Tier each path** by what a bug there would leave behind:
   - **Irreversible** — a revert can't undo it and no repair job can
     either: a send that reached people or a third party, a delete, a
     destructive migration, data exposed to the wrong party.
   - **Repairable** — the bad effect persists after a revert, but a
     backfill, cleanup script, or data fix could repair it: wrong values
     written to a record, a blob saved in a shape old code can't read.
   - **Reversible** — display, read-only, and in-memory code: a revert or
     a follow-up change fully fixes it. These don't get a path entry; they
     go in the skipped list (item 4).
3. **Record each Irreversible or Repairable path** with:
   - An **ID**: `W1`, `W2`, … for persisted data and stored formats; `S1`,
     `S2`, … for sends; `A1`, … for access changes. Diagram edges and
     findings refer to paths by this ID.
   - The **class/function name** and a GitHub permalink with its line
     range at the PR's head commit:
     `<repo URL>/blob/<headRefOid>/<path>#L<start>-L<end>`. Take the repo
     URL from the PR URL (everything before `/pull/`).
   - **What** is written or sent, and **where** (table, queue, service).
   - The **call chain** that reaches it, e.g. `onSave` → `CampaignService.save`
     → `campaigns` table.
   - Whether the PR **adds** this path, **changes** an existing one, or
     **adds a new caller** of an unchanged one.
   - **Feature flag:** gated or not, and by which flag.
   - **Retry safety:** whether running it twice (a retry, a double click,
     a redelivered message) writes or sends twice.
   - **Revert safety:** for persisted data and formats, whether the code
     on `main` can still read what this PR's code writes, once the PR is
     reverted.
   - **Uncertainty:** say plainly where you could not confirm a path (e.g.
     the write happens in a service outside this repo, or through dynamic
     dispatch you couldn't follow).
4. **List what you judged Reversible.** For each changed area that is not
   a path, one line with the area and why it is reversible (e.g. "the
   `CampaignList` sorting change — display only, reads from the existing
   endpoint"). The triage is itself a risk: if it misses a write, the user
   skips the code that needed them. This list lets them check it.
5. **Draw one lasting-effects diagram** as a structural delta (`flowchart`)
   per **delta-diagrams**, at the level of systems, not functions:
   - Nodes: the PR's code (grouped by component or service), data stores
     (tables, caches, indexes), queues, and third-party services.
   - Edges: read, write, or send, labeled with the path ID and the verb
     (e.g. `W1: writes`, `S1: sends push`). Unlabeled reads are fine for
     context but keep them few.
   - Color by what the PR changed, per **delta-diagrams**. Leave
     Reversible code out unless it is needed to show where a path starts.
6. **When there are no paths**, say so in one line instead of drawing an
   empty diagram: *"Nothing in this PR persists or sends data; a revert
   undoes all of it."* Still give the item 4 list, so the user can check
   that call.
7. For a larger diff, delegate the tracing to a `fork` subagent with a
   directive to report each path's item 3 fields and the item 4 list as a
   compact outline, not prose. Step 5's structural-facts subagent can share
   this one, since both read the same neighbors.
8. This becomes the note's first section (Step 7) — draft it now so Step 7
   can place it directly.

## Step 3: Run the code review

1. Invoke the **code-review** skill against this PR. Pass along any effort
   level or review instructions the user gave when invoking this skill (e.g.
   `/pr-review-to-obsidian high`, or "focus on security"); otherwise let it
   use its own default. Also tell it to give the Step 2 paths the most
   scrutiny — name them with their locations — and to check each one's
   retry safety and revert safety.
2. Do **not** pass `--comment` or `--fix` — this workflow never posts to
   GitHub or touches the working tree.
3. Capture the findings yourself as you generate them. Do not call
   `ReportFindings` and do not print the review in chat — the whole point of
   this skill is that the review is read in Obsidian, not here.
4. For each finding that describes an actual bug or runtime problem (not a
   style/simplification/reuse/architecture-only observation), trace out its
   concrete local-repro path while you still have the failure scenario fresh
   from investigating it — the starting preconditions, the exact inputs or
   actions, and the buggy-vs-expected result — rather than leaving it to be
   reconstructed from memory at write-up time in Step 7. Note it down
   alongside the finding as you go.
5. Rate each finding's **Reversibility** — Irreversible, Repairable, or
   Reversible, with the same meanings as Step 2.2 — by the finding's
   consequence, not by where its code sits: "if this ships as-is and we
   then revert, is the damage undone?" A naming nit inside a write path is
   still Reversible. Note the Step 2 path ID it lands on, if any.
6. Rate **Severity** without counting reversibility: Severity is how bad
   the effect is, Reversibility is whether it can be undone. Folding one
   into the other counts it twice and makes every irreversible finding
   Critical.
7. **Check the map against the findings.** A finding rated Irreversible or
   Repairable with no matching path means Step 2 missed one: add the path
   to Step 2's list and diagram, and give the finding that ID.

## Step 4: Fetch and compare against the Jira issue

1. Infer the Jira ticket key from the branch name or PR title, per
   **git-and-pr-conventions** (`PROJECT-NUMBER`, `PROJECT-NUMBER-suffix`,
   `PROJECT-NUMBER__description`).
2. If a ticket key is found, fetch the issue via the Atlassian tools
   (include comments). If none is found, skip Jira entirely — leave
   `jira-issue-key`/`jira-issue-summary` out of frontmatter and skip the
   comparison section. Don't ask the user to supply one.
3. Compare what the PR actually does against what the issue describes. Note
   whether it roughly matches, and call out anything the issue asked for that
   the PR doesn't seem to address (or vice versa) as its own section in the
   note — this is a first-class part of the review, not a footnote.

## Step 5: Build an architecture overview

Give the reader a birds-eye view of how the change composes with the code it
sits inside — a structural read, not a re-statement of Step 3's line-level
findings — with actual diagrams, not just prose. This runs by default; skip
it only when the PR is genuinely structure-free (a typo fix, a copy change, a
config/constant tweak, a single straight-line function with nothing else
touching it) — a diagram that would just restate "file A calls file B" isn't
worth drawing. When in doubt, do it: it's cheap relative to the review itself.
This is about composition; data stores and third-party services already
have their own diagram in Step 2, so don't redraw those edges here.

1. **Gather the structural facts.** For a small diff, read the changed files
   and their immediate neighbors (what calls them, what they call, what state
   they share) directly. For a larger diff, delegate to a `fork` subagent
   with a directive like: *"report diagram-ready structural facts — component/
   hook names, call graph, data flow direction, where state lives, state
   machine transitions — as a compact bulleted outline, not prose. Do NOT
   re-run a code review; fold in \[the specific reuse/simplification/
   efficiency/altitude findings from Step 3] as annotations rather than
   rediscovering them."** Reusing Step 3's already-found structural findings
   this way avoids paying for the same analysis twice.
2. **Decide what's worth drawing.** Apply the judgment from
   **artifact-diagramming** even though the output here is Mermaid, not
   inline SVG: depict the mechanism (the state machine, the data flow, the
   fan-out/fan-in a design decision hinges on), not a restated component
   list; label every edge; match diagram count and complexity to what the
   architecture actually turns on — a single clean diagram beats three thin
   ones. Typical candidates: a hook/component composition graph, a state
   machine for a mode/lifecycle the PR introduces, a data- or control-flow
   graph for a fan-out/coupling point.
3. **Draw them as Mermaid**, since Obsidian renders `mermaid` fences natively
   — no image asset, no Artifact required for this to appear in the note.
   Use `flowchart` for composition/data-flow graphs, `sequenceDiagram` for
   runtime interactions, and `stateDiagram-v2` for state machines. Label
   edges.
4. **Show what the PR changed, not just the end state.** Draw the diagrams
   as *delta* diagrams per **delta-diagrams**: one after-state diagram that
   color-codes the change instead of a separate before and after pair. That
   skill has when to use the structural vs. the sequence form, the `gap:`
   edge and inferred-state `note` conventions, the exact Mermaid palette and
   templates, and when to fall back to a before/after pair.
5. **Caption each diagram** with what it shows, and where a friction point it
   surfaces matches a Step 3 finding (especially one already filed under
   reuse/simplification/efficiency/altitude), name that finding by its Step 7
   heading text (e.g. "see 'updateData never refreshes width/height' below")
   so a reader can trace from the picture to the itemized write-up. Findings
   are no longer a numbered list, so don't invent numbering (①②③…) to stand
   in for it. End each delta diagram's caption with the legend line from
   **delta-diagrams**.
6. **Close with "Angles worth raising, not conclusions"** — a short (≤4
   item) numbered list of restructuring directions the diagrams suggest,
   phrased as discussion prompts the PR author can weigh, not a decided
   redesign. This is discussion fodder, not a recommendation to implement.
7. This becomes its own top-level section in the note (Step 7) — draft it
   now so Step 7 can place it directly.

## Step 6: Build the filename

1. Take the PR title as-is.
2. Encode it into a filesystem-safe stem using this homoglyph mapping (the
   same scheme rclone/Bear use, ported from
   [icloud-md's titleFilename.ts](https://github.com/coddingtonbear/icloud-md/blob/a5160cc78e2bfeab35b8c8b365b1ef25662b21bb/src/notes/titleFilename.ts)):

   | char | replacement |
   |---|---|
   | `/` | `⁄` (U+2044 FRACTION SLASH) |
   | `\` | `⧵` (U+29F5 REVERSE SOLIDUS OPERATOR) |
   | `:` | `꞉` (U+A789 MODIFIER LETTER COLON) |
   | `*` | `∗` (U+2217 ASTERISK OPERATOR) |
   | `?` | `？` (U+FF1F FULLWIDTH QUESTION MARK) |
   | `"` | `”` (U+201D RIGHT DOUBLE QUOTATION MARK) |
   | `<` | `‹` (U+2039 SINGLE LEFT-POINTING ANGLE QUOTATION MARK) |
   | `>` | `›` (U+203A SINGLE RIGHT-POINTING ANGLE QUOTATION MARK) |
   | `\|` | `❘` (U+2758 LIGHT VERTICAL BAR) |
   | `#` | `＃` (U+FF03 FULLWIDTH NUMBER SIGN — Obsidian heading link) |
   | `^` | `＾` (U+FF3E FULLWIDTH CIRCUMFLEX ACCENT — Obsidian block link) |
   | `[` | `［` (U+FF3B FULLWIDTH LEFT SQUARE BRACKET — Obsidian wikilink) |
   | `]` | `］` (U+FF3D FULLWIDTH RIGHT SQUARE BRACKET — Obsidian wikilink) |

   Apply character-by-character; leave every other character untouched. (No
   need for the escape/decode direction from the original tool — this only
   ever generates a filename from a title, never round-trips.)
3. The resulting file is `code-review/<encoded title>.md`.

## Step 7: Write the note

1. Follow **obsidian-formatting** for heading structure (strict heading
   ladder starting at `#`) and linking (wikilink names/dates).
2. Write every prose passage — the lasting-effects summary and path
   descriptions, the Jira alignment comparison, diagram captions and
   "Angles worth raising", and each finding's write-up and suggested
   comments — in Simplified Technical English. Invoke
   **asd-ste100-skill** in STE-flavored mode (this is explanatory/status
   prose, not a procedure or error string, so the lexical rules stay
   advisory) to rewrite each passage before it goes in the note. Headings,
   frontmatter, the label lines (Confidence/Severity/Reversibility/Path and
   each path's field labels), and the fixed checklists are structural, not
   prose — leave them as specified below rather than running them through
   the rewrite.
3. Frontmatter:
   ```yaml
   ---
   url: "<PR URL>"
   jira-issue-key: "<ISSUE_KEY>"          # omit entirely if none was found
   jira-issue-summary: "<ISSUE_SUMMARY>"  # omit entirely if none was found
   ---
   ```
4. Body sections (in order):
   - `# Where to focus: lasting effects` — the map from Step 2, always
     present:
     - A one- or two-sentence summary: how many paths there are in each
       tier, or the no-paths line from Step 2.6.
     - The lasting-effects diagram, captioned and ending with the
       **delta-diagrams** legend line.
     - One `##` subsection per path, Irreversible paths first, then
       Repairable; within a tier, in ID order. Heading: the ID, the
       function, and what it does, e.g.
       `## W1 — CampaignService.save writes the campaigns table`. Under it,
       a bullet list of the Step 2.3 fields, starting with
       `Tier: **Irreversible**` (or `**Repairable**`) and the permalink,
       then the findings that land on this path by their heading text (or
       "no findings"), then one checkbox:
       ```
       - [ ] Reviewed
       ```
     - `## Judged reversible` — the Step 2.4 list.
   - `# Jira alignment` (only if a ticket was found) — the comparison from
     Step 4.
   - `# Architecture: how this composes` (only if Step 5 produced one) — the
     diagrams and friction callouts from Step 5, as their own top-level
     section between the Jira alignment and the findings.
   - `# Findings` — one `##` subsection per finding, ordered by
     Reversibility first (Irreversible, then Repairable, then Reversible),
     then by Severity within each (Critical, then High, Medium, Low); break
     remaining ties in the order the review skill surfaced them. Each
     subsection:
     - **Heading:** a short descriptive title for the finding, not a
       file:line (that belongs in the body) — e.g.
       `## updateData never refreshes width or height`.
     - The label lines immediately under the heading, in this order:
       ```
       Confidence Level: **High**
       Severity: **Low**
       Reversibility: **Repairable**
       Path: W1
       ```
       Confidence is one of High/Medium/Low. Severity is one of
       Critical/High/Medium/Low. Reversibility is one of
       Irreversible/Repairable/Reversible (Step 3.5). Path is the Step 2
       path ID the finding lands on; omit the Path line when it lands on
       none.
     - The finding's full write-up — same substance and depth as it would
       otherwise report via `ReportFindings` (file:line references, the
       concrete failure scenario, why it matters), just not a numbered list
       item anymore. For an Irreversible or Repairable finding, say what a
       revert would leave behind.
     - `### Reproduction Steps` — for a finding that describes an actual bug
       or runtime problem (not a style/simplification/reuse/architecture-only
       observation), a numbered list of concrete steps to hit the problem in
       a local dev environment: starting preconditions/setup, the exact
       inputs or actions to take (real values, routes, commands, requests, or
       UI actions — not "trigger the edge case"), and the observed (buggy)
       result versus the expected (correct) one. Write it so someone with no
       memory of this review could follow it literally and land on the same
       bug. Use the repro path you already traced for this finding in Step
       3.4 rather than reconstructing it from memory now. Omit this
       subsection when there's nothing to reproduce (a simplification/reuse
       suggestion, a style nit, an architectural observation with no
       concrete failure).
     - `### Suggested Comments` — one block per distinct file/line the
       finding touches, in the form:
       ```
       at `<file path>` on line <N>:

       > <comment text, phrased as you'd actually post it in review>
       ```
       Most findings get exactly one block; give a finding that spans
       multiple locations one block per location. Omit this subsection only
       when there's genuinely no actionable inline comment to suggest (e.g.
       a purely architectural observation already covered in Step 5).
       Strongly prefer a line that's actually within the PR's diff (a
       changed line, or a line in the diff's surrounding context) — the user
       can only place an inline comment on a line near the diff, not one far
       outside it. When a finding is really about an untouched line well
       away from the diff, point the comment at the nearest in-diff line
       instead (e.g. the touched line that calls the problematic code, or
       the top of the changed hunk) and say in the comment text itself where
       the actual problem lives.
     - `### Resolution` — always exactly:
       ```
       - [ ] Reviewed
       - [ ] Commented
       - [ ] Ignored
       ```
5. Write the file with the Obsidian tools (this creates the `code-review/`
   folder automatically if it doesn't exist yet).

## Step 8: Start watching for comments

Start this immediately after writing the note, before confirming to the user.
Comments arrive as Sidemark threads on the note (**sidemark-comments**), and
Sidemark publishes each one as an event — so follow the event stream rather
than polling for a sidecar file.

1. Call `events_get_listener_url` with `emitter: "sidemark"`, `event:
   "comment-added"`, a `ttlSeconds` long enough to cover the conversation, and
   a filter naming this note and excluding your own replies:

   ```json
   {"and": [{"==": [{"var": "path"}, "code-review/<the note>.md"]},
            {"!=": [{"var": "author"}, "Claude"]}]}
   ```

   `comment-added` fires for new threads and for replies, which is the whole
   back-and-forth. The URL it returns is signed, so nothing downstream needs
   the API key.
2. Launch the stream with the **Monitor** tool (a live background watch, not a
   one-shot check) with a description naming the note and `timeout_ms:
   1800000` — Monitor's hard cap, so each watch runs the longest it can and
   you re-arm (step 3) as rarely as possible. Each message's `data:` is a
   JSON object carrying `path`, `id`, `thread`, `author`, `timestamp` and
   `text`. Filter out the keepalives, or every heartbeat becomes its own
   notification for the length of the watch:

   ```sh
   curl -sN '<url>' | grep -E --line-buffered '^(id|data|event):'
   ```

   That keeps the payload and the `id:` counters step 4 needs, and drops the
   `retry:` preamble and the `:` heartbeats. `--line-buffered` is required:
   without it `grep` holds matches in its own buffer, and comments arrive late
   and in clumps.
3. Monitor caps a single watch at 30 minutes. When it expires with no activity
   worth stopping for, re-arm it on the same URL, which stays valid for its
   `ttlSeconds`; past that — or after Obsidian restarts, which drops every
   subscription — get a fresh URL from `events_get_listener_url` first. Keep
   re-arming for as long as this review conversation continues. Stop only when
   the user says to, or the session ends. The old watch's connection is dead
   for however long it takes you to notice the expiry and re-arm, and nothing
   is buffered or replayed for that gap (unlike the epoch case in the next
   step, which only covers events the filter itself dropped) — so before
   resuming the wait on every re-arm, `comments_list` the note and handle
   anything with a timestamp after the last event you actually saw, so a
   comment posted mid-gap doesn't sit unanswered until something else
   happens to prompt a check.
4. A change of epoch in an event's `id:` means messages were missed and
   nothing is replayed; `comments_list` the note to catch up. A **gap in the
   counter does not**, as long as you are filtering on `author`: the counter
   advances for events the filter dropped, so your own replies consume the
   values in between and a healthy stream arrives as 1, 3, 5, 7. Treat a gap
   as suspicious only when it is wider than the number of replies you posted.
5. When an event reports a new comment or reply, read its thread with
   `comments_get`, find the passage from the returned `anchor`, and follow
   **sidemark-comments** to answer or act on it. Treat it like any other
   question about the review: investigate the actual code/PR to give a real,
   checked answer rather than restating the finding text, the same way you
   would in chat. Reply with `comments_reply`, as `author: "Claude"`.
6. Don't re-arm forever on silence alone. If you've re-armed the watch
   repeatedly (per Step 8.3) with no activity across several hours, stop and
   ask the user whether they're done with this review before arming it
   again, instead of continuing to watch indefinitely unasked. A "yes" (or
   the user independently saying they're done with this PR review at any
   other point in the conversation) means stop watching and move to Step 11;
   a "no" or no response either way means just re-arm as usual.

## Step 9: Open the note, then confirm — don't restate

1. Open the note in Obsidian with `open_file`, passing the vault-relative
   path (e.g. `code-review/Fix ⁄ retry logic.md`) and `newLeaf: true` so it
   opens in a new pane rather than replacing whatever the user has open.
2. Reply in chat with only a short confirmation: the note's vault-relative
   path, plus a clickable `obsidian://` link so the user can jump straight
   back to it later. The vault is at `/home/acoddington/Documents/Notes`, so
   the vault name is `Notes`:

```
obsidian://open?vault=Notes&file=<url-encoded vault-relative path, no .md extension>
```

For example, a note at `code-review/Fix ⁄ retry logic.md` becomes:

```
obsidian://open?vault=Notes&file=code-review%2FFix%20%E2%81%84%20retry%20logic
```

Do not repeat, summarize, or paraphrase the lasting-effects map, the
findings, the architecture overview, or the Jira comparison in chat — that
content lives in the note. Once the Step 8 watch is confirmed running, add
one more line stating that plainly, e.g.:

> I'm watching that document for comments now; feel free to ask questions on
> "<note title>" in Obsidian.

## Step 10: Ongoing discussion

The Step 8 watch means new comments and replies surface as they're written,
without the user needing to ask. Keep it armed (per Step 8.3) for the rest of
the conversation. Follow **sidemark-comments** for reading, replying to, and
resolving threads; no other special handling is needed beyond that skill's
normal behavior.

## Step 11: Wrapping up

Reached either because the quiet-watch check in Step 8.6 got a "yes, I'm
done" answer, or because the user said as much unprompted at any other point
in the conversation.

1. Stop watching: let the current Monitor watch lapse rather than re-arming
   it (or stop it outright if it's still running and you don't want to wait
   for its window to close).
2. Remove the Step 1.3 worktree: it was entered with `path`, so
   `ExitWorktree({action: "keep"})` only returns the session to your
   original working directory — it will not delete the worktree itself.
   Follow that with `git worktree remove <the path from Step 1.3>` to
   actually delete it.
3. Confirm in chat, briefly, that you've stopped watching and cleaned up the
   worktree.

---

## Related skills

- **code-review** — the underlying review engine this wraps
- **git-and-pr-conventions** — branch/ticket inference, merge-base diffing
- **delta-diagrams** — the Mermaid conventions for Step 2's lasting-effects
  diagram and Step 5's architecture diagrams
- **artifact-diagramming** — drawing judgment for the Step 5 architecture
  diagrams (what's worth depicting, how to label it) — used for that
  judgment only; the diagrams themselves are Mermaid, not an Artifact
- **obsidian-formatting** — heading and linking conventions for the note body
- **asd-ste100-skill** — rewrites Step 7's prose passages into Simplified
  Technical English (STE-flavored mode) before they're written to the note
- **sidemark-comments** — handles the follow-up comment loop after the note
  is written
- **jira-ticket-workflow** — related but distinct: that skill is for working
  an issue, not reviewing a PR against one
