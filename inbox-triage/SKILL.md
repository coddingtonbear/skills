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
- **On-screen text** — when caption and transcript don't carry the substance
  (a music reel with no speech, a "tracks to play" list, a recipe or tool
  shown rather than said), read it off the frames. Reels often flash the
  track/artist, product name, or key points as text overlays. The user wants
  these named — "open the reel to hear it" is not an acceptable entry. Fetch
  the video (the `-x` download above is audio only):

      yt-dlp --cookies-from-browser firefox --no-playlist -f "b[ext=mp4]/b" \
        -o "<scratchpad>/<shortcode>.video.%(ext)s" "<reel-url>"

  First get an overview contact sheet (one frame every 2 s, 8 across) and
  `Read` it as an image to see where the text sits and how often it changes:

      ffmpeg -i <video> -vf "fps=1/2,scale=270:-1,tile=8x2" -frames:v 1 <scratchpad>/sheet.jpg

  Overview tiles are too small to read reliably, and labels that change about
  once a second get skipped at that rate. So make a second sheet: crop to just
  the text band (fractions of `ih` picked from the overview), sample at
  `fps=2`, and stack vertically so every label is big enough to read:

      ffmpeg -i <video> -vf "fps=2,crop=iw:ih*0.13:0:ih*0.39,scale=600:-1,tile=4x16" -frames:v 1 <scratchpad>/labels.jpg

  Raise the tile row count if the reel is longer than ~32 s at 2 fps. On
  2026-10-08 this pulled all 27 tracks from a 30 s "night out in NYC" reel
  and the track from a speechless deep-house clip. Write the extracted list
  into the entry as a bullet list and say the names
  were read from on-screen labels.
- **Music → like it on Spotify.** Every track identified in a reel — from
  on-screen labels, the caption, or the transcript — gets liked on Spotify
  (user instruction, 2026-10-08). For each track, call the Spotify
  connector's `search` with `"<title> <artist>"`, then **check the result's
  artist and title against what the reel named** before saving: covers,
  remixes, karaoke versions and same-title songs by other artists are common
  near-misses. Only on a match, call `save_to_library` with the exact
  `spotify:track:` URI the search returned — never a guessed or constructed
  URI. No confident match → don't like it; list it as unmatched. If the
  connector reports it needs authentication, stop liking, tell the user to
  reconnect Spotify in connector settings, and list the tracks still to like.
  The daily-note entry is written either way; mark liked tracks in it (a
  trailing `♥` on each bullet). Liking happens only in a real run — a dry run
  lists the matches it would like.
- Cookie extraction reads the Firefox profile; if the permission system blocks
  it, ask the user to approve that command rather than degrading silently.
- On any failure: keep caption if it was obtained, mark the missing piece, and
  still write the entry — metadata plus annotation is the guaranteed floor.

### YouTube — description only

No transcription (user decision — videos are too long). Metadata only:

    yt-dlp --skip-download --write-info-json --no-playlist -o "<scratchpad>/<id>" "<url>"

Use `title`, `uploader`, and a trimmed `description`.

### Reddit — via the installed Chrome's cookies

The user is logged into Reddit in **whichever Google Chrome is installed**.
Unauthenticated fetches are blocked on every route, but with that browser's
cookies the JSON API answers normally (verified 2026-09-13).

1. Find the installed Chrome and its profile, rather than assuming a channel
   or path — the install has changed before (a Snap Chromium, since removed):

       readlink -f "$(command -v google-chrome)"

   The resolved binary names the channel, and the profile is the matching
   `~/.config` directory: `/opt/google/chrome-beta/…` →
   `~/.config/google-chrome-beta` (the install as of 2026-09-13),
   `/opt/google/chrome/…` → `~/.config/google-chrome`,
   `/opt/google/chrome-unstable/…` → `~/.config/google-chrome-unstable`.
   Don't use a bare `--cookies-from-browser chrome`: it always reads
   `~/.config/google-chrome`, which is a stale profile without the login
   whenever a non-stable channel is the one installed.

2. Export cookies once per run, into the scratchpad (the file holds live
   session tokens — never move it elsewhere, never send it to anything but
   reddit.com, delete it when the run ends):

       yt-dlp --cookies-from-browser "chrome:<profile-dir>" \
         --cookies "<scratchpad>/reddit-cookies.txt" --skip-download --simulate "<any-reddit-url>"

   yt-dlp's own Reddit extraction usually errors out afterwards (a 403, or
   a `latin-1` encoding error) and some cookies fail to decrypt — both are
   harmless as long as the file was written. Judge success by the file, not
   the exit code: it must contain a `reddit.com` `token_v2` cookie. If it
   doesn't, the profile is the wrong one or not logged in.

3. Resolve `/s/` share links to the real post URL:

       curl -sL -o /dev/null -w "%{url_effective}" "<share-url>"

3. Fetch the content as JSON (append `.json` to the resolved path, keep its
   query string; a comment permalink returns `[post, comment-tree]` — the
   comment body is `d[1].data.children[0].data.body`, the post is
   `d[0].data.children[0].data`):

       curl -sL -A "<a current desktop-Chrome UA string>" \
         -b "<scratchpad>/reddit-cookies.txt" "<resolved-url>.json?context=3"

Don't reach for **browser-fallback** here: headless Reddit answers with a
bot check. If any step fails, fall back to the resolved URL's slug (it
contains the post title), the annotation, and an explicit
`*(content unavailable — annotation only)*` marker — never a confident-looking
stub.

### Everything else

`WebFetch` the URL with a prompt asking for the gist and the single most
interesting passage. If that fails — a refused host, a 403, a login wall, or a
page with no real content — read it in a headless browser per the
**browser-fallback** skill. Only when that fails too: entry from title +
annotation with an explicit marker.

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
  **Heading levels in `vault_patch` content are relative to the target**: a
  leading `#` becomes a direct child of the target heading, so write each
  entry heading as `# <Composed title>` in the patch payload — it lands in the
  file as `##`. Passing `##` produces `###` (happened 2026-10-02; fixed by
  re-replacing the section). The `target` must be a JSON array of heading
  texts, e.g. `["Discoveries"]`, not a bare string.
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
  it was completed, left open, or skipped as non-content. For music reels,
  also report how many tracks were liked on Spotify and any left unmatched
  or not yet liked.

## Dry run

When the user asks for a dry run, produce every block exactly as it would be
written, plus the would-be note paths and sections — but touch neither the
vault nor Todoist, and complete nothing. Offer a dry run proactively on the
first-ever invocation over a large backlog.
