---
name: inbox-triage
description: >-
  Sweep online-content items (Instagram reels, Reddit links, articles) out of
  the Todoist Inbox into the daily note for each item's capture date —
  caption plus Whisper transcript for reels, a summary of what was interesting
  anchored on the user's own annotation, and completion of the triaged item.
  Use when the user says "triage my inbox", "sweep my inbox", "process my
  Todoist inbox", or asks for saved reels or links to be filed into daily
  notes.
---

# Triaging the Todoist Inbox

Content encountered on the phone gets shared into the Todoist Inbox as a bare
link and then sits there. This skill moves each such item into the daily note
for the day it was captured, in the same block format desktop clipping already
uses, then completes the Inbox item. Everything that is not online content is
left exactly where it is.

## Authorization: the Inbox carve-out

Inbox items are the user's own unlabeled tasks, which the **claude-tasks**
boundary normally forbids touching. The user explicitly granted this carve-out
on 2026-08-25 ("If you've entered the thing into my notes, you can close it.
These are very low-stakes!"): **completing an Inbox item is authorized only
after its entry has been written into a daily note in the same run.** Nothing
else about the user's tasks is in scope — no edits, no retitling, no touching
items that were skipped or that failed triage. Those stay open and get
reported instead.

## Scope: what gets triaged

Fetch open Inbox items with the official Todoist CLI: `td inbox --json --all`.
Each item's title is its `content` field; reference items as `id:<id>` in
every later call (a bare ref is a fuzzy title search).

An item is **content** when its title contains a URL — usually a markdown link
with a free-text annotation glued after it:

    [Trevor Noah on Instagram](https://www.instagram.com/reel/DcY7oI7jzdy/) on communication

The trailing fragment ("on communication") is the user's own record of why the
item mattered — often the *only* signal for a reel. Parse out title, URL, and
annotation; **the annotation must survive into the daily note** and anchors
the summary. Items without a URL (`Shark Clip?`, `book Tripic of Capricorn`)
are not content: leave them untouched, list them as skipped in the report.

## Fetching the substance, per platform

Work in the session scratchpad. Every tier that fails falls through to the
next, and a shortfall is always **marked explicitly in the written entry** —
`*(transcript unavailable)*`, `*(content unavailable — annotation only)*` —
never silently papered over.

### Instagram reels — caption + transcript

Run yt-dlp with Firefox cookies (verified working 2026-08-25):

    yt-dlp --cookies-from-browser firefox --no-playlist \
      -x --audio-format mp3 --write-info-json \
      -o "<scratchpad>/<shortcode>.%(ext)s" "<reel-url>"

If Instagram returns "login required" errors, the likeliest cause is a stale
extractor — the system yt-dlp (updated to 2026.08 by the user on 2026-08-25)
will drift again: retry the same command via `uvx yt-dlp` (always current)
before concluding the cookies are the problem.

- **Caption**: the `description` field of the written `.info.json`; `uploader`
  gives the human name for the entry title (yt-dlp's `title` field is junk for
  reels — "Video by trevornoah" — so compose the entry heading from uploader
  plus the annotation or caption topic instead).
- **Transcript**:

      whisper "<scratchpad>/<shortcode>.mp3" --model base --output_format txt --output_dir "<scratchpad>"

  The `base` model transcribed a 48 s reel in ~11 s and is accurate; only
  reach for a bigger model if the result is visibly garbled. Omit
  `--language` unless the language is known — whisper auto-detects.
- Cookie extraction reads the Firefox profile; if the permission system blocks
  it, ask the user to approve that command rather than degrading silently.
- On any failure: keep caption if it was obtained, mark the missing piece, and
  still write the entry — metadata plus annotation is the guaranteed floor.

### YouTube — description only

No transcription (user decision — videos are too long). Metadata only:

    yt-dlp --skip-download --write-info-json --no-playlist -o "<scratchpad>/<id>" "<url>"

Use `title`, `uploader`, and a trimmed `description`.

### Reddit — via Chromium cookies

The user is logged into Reddit in **Chromium (the Snap build — its profile is
at `~/snap/chromium/common/chromium`, not `~/.config/chromium`)**. Verified
2026-08-25: unauthenticated fetches are blocked on every route, but with those
cookies the JSON API answers normally.

1. Export cookies once per run, into the scratchpad (the file holds live
   session tokens — never move it elsewhere, never send it to anything but
   reddit.com, delete it when the run ends):

       yt-dlp --cookies-from-browser "chromium:~/snap/chromium/common/chromium" \
         --cookies "<scratchpad>/reddit-cookies.txt" --skip-download --simulate "<any-reddit-url>"

2. Resolve `/s/` share links to the real post URL:

       curl -sL -o /dev/null -w "%{url_effective}" "<share-url>"

3. Fetch the content as JSON (append `.json` to the resolved path, keep its
   query string; a comment permalink returns `[post, comment-tree]` — the
   comment body is `d[1].data.children[0].data.body`, the post is
   `d[0].data.children[0].data`):

       curl -sL -A "<a current desktop-Chrome UA string>" \
         -b "<scratchpad>/reddit-cookies.txt" "<resolved-url>.json?context=3"

If any step fails, fall back to the resolved URL's slug (it contains the post
title), the annotation, and an explicit
`*(content unavailable — annotation only)*` marker — never a confident-looking
stub.

### Everything else

`WebFetch` the URL with a prompt asking for the gist and the single most
interesting passage. On failure, same rule: entry from title + annotation with
an explicit marker.

## Classifying: Insight vs Discovery

The user's rule (2026-08-25): something *communicating an insight* — a reel or
essay making a point worth remembering — is an **Insight**; a GitHub project,
product, tool, or something funny — a thing worth finding again — is a
**Discovery**. When it fits neither cleanly, make the best guess **erring
toward Discovery**. Mis-categorization is explicitly tolerated.

## Writing the daily note entry

Follow **obsidian-formatting**; all vault access via `mcp__obsidian__*` tools.

- **Which note**: the item's *capture date* — Todoist `addedAt` converted
  to America/Chicago. (Items migrated from TickTick in 2026-08 carry the
  migration date, not the original capture date — for those, fall back to any
  date evident from the item itself, else today's note, and say so.)
- **Getting the note** (never copy `daily/template.md` by hand — user
  instruction, 2026-08-25):
  - capture date is *today*: `mcp__obsidian__periodic_note_get_path`
    (`period: "daily"`) — it returns the path and creates the note with the
    configured template if missing. Its path also reveals the folder and
    filename pattern for the next case.
  - capture date is *in the past*: substitute the date into that pattern
    (e.g. `daily/2026-08-08.md`). If the note does not exist (`vault_patch`
    cannot create files — verified), create it as an **empty** note with
    `vault_write` — but only after confirming it is absent, since
    `vault_write` overwrites. Sparse notes for days that only saved a link
    are fine and expected.
- **Placement**: append under `# Insights` or `# Discoveries` per the
  classification, via `vault_patch` (heading target, `append`,
  `createTargetIfMissing: true` so the section is created in an empty note) —
  never a whole-file write over an existing note.
- **Block format** — match the existing desktop-clipped entries exactly:

      ## <Composed title>
      URL: <url>

      <1-3 sentences on what was interesting, anchored on the user's annotation>

      > <the interesting excerpt — the caption, the key passage, or the comment text>

  For reels with a transcript, add it below the excerpt as a folded callout so
  long transcripts don't swamp the note but stay searchable:

      > [!quote]- Transcript
      > <full transcript text>

## Disposing and reporting

- Complete each item (`td task complete id:<id>`) **only after** its entry
  was successfully written. An item whose entry could not be written stays
  open.
- End with a per-item report: title → daily note and section, what substance
  was obtained (transcript / caption / excerpt / annotation-only), and whether
  it was completed, left open, or skipped as non-content.

## Dry run

When the user asks for a dry run, produce every block exactly as it would be
written, plus the would-be note paths and sections — but touch neither the
vault nor Todoist, and complete nothing. Offer a dry run proactively on the
first-ever invocation over a large backlog.
