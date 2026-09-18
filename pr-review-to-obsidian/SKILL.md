---
name: pr-review-to-obsidian
description: >-
  Runs a code review of the current branch's pull request and writes the
  assessment into a new note in the Obsidian `code-review/` folder instead of
  displaying it in chat, cross-checking the PR against its linked Jira issue.
  Use when the user runs /pr-review-to-obsidian, or asks to "review this PR
  for my notes", "write up a code review in Obsidian", or similar.
---

**Goal:** Produce a code review for the current branch's PR, written to a new
Obsidian note under `code-review/` (not shown in chat), cross-checked against
the PR's linked Jira issue. The resulting note becomes the basis for a
comment back-and-forth via a Sidemark/MRSF sidecar (**sidemark-comments**) as
the user reads and questions the review. This skill starts a live background
watch for that back-and-forth itself (Step 6) rather than waiting to be asked.

**Requirements:** `gh` CLI, Obsidian MCP tools, and Jira (Atlassian) MCP tools
must be available.

---

## Step 1: Identify the PR

1. Determine the current branch and use `gh pr view --json title,url,number,headRefName,body`
   to get the open PR for it. Compare against `origin/main` via the merge-base,
   per **git-and-pr-conventions**, if you need the diff itself.
2. If there's no open PR for the current branch, stop and tell the user — do
   not guess a target.

## Step 2: Run the code review

1. Invoke the **code-review** skill against this PR. Pass along any effort
   level or review instructions the user gave when invoking this skill (e.g.
   `/pr-review-to-obsidian high`, or "focus on security"); otherwise let it
   use its own default.
2. Do **not** pass `--comment` or `--fix` — this workflow never posts to
   GitHub or touches the working tree.
3. Capture the findings yourself as you generate them. Do not call
   `ReportFindings` and do not print the review in chat — the whole point of
   this skill is that the review is read in Obsidian, not here.

## Step 3: Fetch and compare against the Jira issue

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

## Step 4: Build the filename

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

## Step 5: Write the note

1. Follow **obsidian-formatting** for heading structure (strict heading
   ladder starting at `#`) and linking (wikilink names/dates).
2. Frontmatter:
   ```yaml
   ---
   url: "<PR URL>"
   jira-issue-key: "<ISSUE_KEY>"          # omit entirely if none was found
   jira-issue-summary: "<ISSUE_SUMMARY>"  # omit entirely if none was found
   ---
   ```
3. Body sections (in order):
   - `# Jira alignment` (only if a ticket was found) — the comparison from
     Step 3.
   - `# Findings` — the code-review skill's findings, most severe first, same
     substance as it would otherwise report via `ReportFindings`.
4. Write the file with the Obsidian tools (this creates the `code-review/`
   folder automatically if it doesn't exist yet).

## Step 6: Start watching for comments

Start this immediately after writing the note, before confirming to the user.
Comments arrive later in a `<note>.md.review.yaml` Sidemark/MRSF sidecar file
beside the note (**sidemark-comments**). That sidecar doesn't exist yet right
after writing a brand-new note — watch for it to be *created*, not just for
changes to an existing one.

1. Resolve on-disk paths. The vault root is
   `/home/acoddington/Documents/Notes`, so the note is at
   `<vault root>/<vault-relative path>.md` and its Sidemark sidecar at the
   same path plus `.review.yaml`.
2. Write a small polling script to the scratchpad directory (Python is fine)
   that, every ~2 seconds, reads the sidecar if it exists (`yaml.safe_load`)
   and reports any comment `id` not seen before and not authored by `Claude`.
   It must not error out when the sidecar doesn't exist yet — that's the
   normal starting state. Track known ids in memory across polls so only
   genuinely new ones are reported once.
3. Launch it with the **Monitor** tool (a live background watch, not a
   one-shot check) with a description naming the note.
4. Monitor caps a single watch at 30 minutes. When it expires with no new
   activity worth stopping for, re-arm it with the same script for as long as
   this review conversation continues. Stop only when the user says to, or
   the session ends.
5. When a notification reports a new comment or reply, read the sidecar,
   locate the anchored passage in the note, and follow **sidemark-comments**
   to answer or act on it. Treat it like any other question about the
   review: investigate the actual code/PR to give a real, checked answer
   rather than restating the finding text, the same way you would in chat.

## Step 7: Confirm — don't restate

Reply in chat with only a short confirmation: the note's vault-relative path,
plus a clickable `obsidian://` link so the user can jump straight to it. The
vault is at `/home/acoddington/Documents/Notes`, so the vault name is `Notes`:

```
obsidian://open?vault=Notes&file=<url-encoded vault-relative path, no .md extension>
```

For example, a note at `code-review/Fix ⁄ retry logic.md` becomes:

```
obsidian://open?vault=Notes&file=code-review%2FFix%20%E2%81%84%20retry%20logic
```

Do not repeat, summarize, or paraphrase the findings or the Jira comparison in
chat — that content lives in the note. Once the Step 6 watch is confirmed
running, add one more line stating that plainly, e.g.:

> I'm watching that document for comments now; feel free to ask questions on
> "<note title>" in Obsidian.

## Step 8: Ongoing discussion

The Step 6 watch means new comments and replies surface as they're written,
without the user needing to ask. Keep re-arming it (per Step 6.4) for the
rest of the conversation. Follow **sidemark-comments** for reading, replying
to, and resolving threads; no other special handling is needed beyond that
skill's normal behavior.

---

## Related skills

- **code-review** — the underlying review engine this wraps
- **git-and-pr-conventions** — branch/ticket inference, merge-base diffing
- **obsidian-formatting** — heading and linking conventions for the note body
- **sidemark-comments** — handles the follow-up comment loop after the note
  is written
- **jira-ticket-workflow** — related but distinct: that skill is for working
  an issue, not reviewing a PR against one
