---
name: inbox-triage
description: >-
  Sweep online-content items (Instagram reels, Reddit links, articles) out of
  the TickTick Inbox into the daily note for each item's capture date —
  caption plus Whisper transcript for reels, a summary of what was interesting
  anchored on the user's own annotation, and completion of the triaged item.
  Use when the user says "triage my inbox", "sweep my inbox", "process my
  TickTick inbox", or asks for saved reels or links to be filed into daily
  notes.
---

# Triaging the TickTick Inbox

Content encountered on the phone gets shared into the TickTick Inbox as a bare
link and then sits there. This skill moves each such item into the daily note
for the day it was captured, in the same block format desktop clipping already
uses, then completes the Inbox item. Everything that is not online content is
left exactly where it is.

## Authorization: the Inbox carve-out

Inbox items are the user's own untagged tasks, which the **claude-tasks**
boundary normally forbids touching. The user explicitly granted this carve-out
on 2026-08-25 ("If you've entered the thing into my notes, you can close it.
These are very low-stakes!"): **completing an Inbox item is authorized only
after its entry has been written into a daily note in the same run.** Nothing
else about the user's tasks is in scope — no edits, no retitling, no touching
items that were skipped or that failed triage. Those stay open and get
reported instead.

## Scope: what gets triaged

Fetch open Inbox items: resolve the Inbox project id via
`mcp__ticktick__list_projects` (the virtual `inbox` entry), then
`mcp__ticktick__filter_tasks` with `{"status": [0], "projectIds": ["<inbox-id>"]}`.

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

Run yt-dlp **via uvx**, not the system install (`~/bin/yt-dlp` is 2024.10 and
gets login-walled; verified 2026-08-25 that the current release with Firefox
cookies succeeds where the system one fails):

    uvx yt-dlp --cookies-from-browser firefox --no-playlist \
      -x --audio-format mp3 --write-info-json \
      -o "<scratchpad>/<shortcode>.%(ext)s" "<reel-url>"

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

    uvx yt-dlp --skip-download --write-info-json --no-playlist -o "<scratchpad>/<id>" "<url>"

Use `title`, `uploader`, and a trimmed `description`.

### Reddit — best effort, expect failure

Resolve `/s/` share links first (this works and yields the real post URL):

    curl -sL -o /dev/null -w "%{url_effective}" "<share-url>"

Content retrieval is unreliable: as of 2026-08-25, `www.reddit.com` and
`old.reddit.com` serve block pages to curl (even with a browser UA and
`.json`), and WebFetch refuses the domain. Try WebFetch on the resolved URL
anyway (things change); if the **claude-in-chrome** skill is available in the
session, that is the reliable route since it uses the user's real browser
session. Otherwise write the entry from the resolved URL's slug (it contains
the post title), the annotation, and an explicit
`*(content unavailable — annotation only)*` marker.

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

- **Which note**: the item's *capture date* — TickTick `createdTime` converted
  to America/Chicago. Derive the daily-note path from
  `mcp__obsidian__periodic_note_get_path` (today's path shows the folder and
  filename pattern; substitute the capture date — e.g. `daily/2026-08-08.md`).
- **Missing note**: create it from `daily/template.md` (five h1 sections:
  Noise Floor, Events, Insights, Discoveries, Pomodoros). Sparse notes for
  days that only saved a link are fine and expected.
- **Placement**: append under `# Insights` or `# Discoveries` per the
  classification, via `vault_patch` (heading target, `append`) — never a
  whole-file write over an existing note.
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

- Complete each item (`mcp__ticktick__complete_task`) **only after** its entry
  was successfully written. An item whose entry could not be written stays
  open.
- End with a per-item report: title → daily note and section, what substance
  was obtained (transcript / caption / excerpt / annotation-only), and whether
  it was completed, left open, or skipped as non-content.

## Dry run

When the user asks for a dry run, produce every block exactly as it would be
written, plus the would-be note paths and sections — but touch neither the
vault nor TickTick, and complete nothing. Offer a dry run proactively on the
first-ever invocation over a large backlog.
