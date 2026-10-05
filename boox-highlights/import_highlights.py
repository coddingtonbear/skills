#!/usr/bin/env python3
"""Import Boox e-reader highlight exports into Obsidian book notes.

Usage:
  import_highlights.py list [--device DIR] [--vault DIR] [--json]
  import_highlights.py render FOLDER [--device DIR] [--vault DIR]
                                     [--existing FILE] [--out FILE]
                                     [--today YYYY-MM-DD] [--json]

`list` inventories the books on a connected Boox and reports, per book, how
many highlights its newest export holds and how many of those are not yet in
the vault.  `render` merges one book's newest export into whatever its note
already contains and emits the complete note text.

The merge is insert-only: no line that already exists in the note body is ever
rewritten, reordered or removed, so hand-written prose survives a re-import.
Only the managed frontmatter keys are rewritten in place.

This script never writes to the vault and never writes to the device.  It reads
the existing note from disk and prints the merged text; the caller is expected
to write that text back through the Obsidian MCP.
"""
from __future__ import annotations

import argparse
import glob
import json
import re
import sys
import unicodedata
from bisect import bisect_right
from dataclasses import dataclass
from datetime import date, datetime
from pathlib import Path

# --- Boox export grammar ----------------------------------------------------
#
# Reading Notes | <<Folder Name (183)>>Author[,Author]
# [Chapter Heading]                  <- only when the chapter changed
# 2024-08-28 07:54  |  Page No.: 11  <- NBSP either side of the pipe
# highlighted text, possibly
# spanning several lines
# 【Annotation】my note               <- optional, 【Note】on older firmware
# -------------------                <- exactly 19 hyphens

SEPARATOR = re.compile(r"^-{3,}$")
TIMESTAMP = re.compile(r"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2})\s*\|\s*Page No\.:\s*(\d+)\s*$")
HEADER = re.compile(r"^Reading Notes\s*\|\s*<<(?P<stem>.*)>>(?P<authors>.*)$")
ANNOTATION = re.compile(r"^\s*【(?:Annotation|Note)】(?P<note>.*)$")

PAGE_COUNT_SUFFIX = re.compile(r"\s*\(\d+\)\s*$")
TRAILING_ARTICLE = re.compile(r"^(?P<body>.+?),\s*(?P<article>The|A|An)$")
HEADING = re.compile(r"^(#+)\s+(.*?)\s*$")
UNSAFE_IN_FILENAME = re.compile(r'[*"\\/<>:|?\[\]#^]')
SUBTITLE_COLON = re.compile(r"\s*:\s+")

MANAGED_KEYS = (
    "title",
    "author",
    "source",
    "boox-folder",
    "highlight-count",
    "first-highlighted",
    "last-highlighted",
    "imported",
)

EXPORT_GLOB = "*-annotation-*.txt"
DEVICE_GLOBS = (
    "/run/user/*/gvfs/mtp:host=*/*/note",
    "/run/user/*/gvfs/gphoto2:host=*/*/note",
)


# --- model ------------------------------------------------------------------


@dataclass(frozen=True)
class Highlight:
    """One highlighted passage, with the chapter that was in effect for it."""

    chapter: str
    when: datetime
    page: int
    text: str
    note: str | None


@dataclass(frozen=True)
class Book:
    folder: str
    title: str
    authors: tuple[str, ...]
    highlights: tuple[Highlight, ...]


@dataclass(frozen=True)
class MergeStats:
    added_highlights: int
    added_notes: int
    added_chapters: int
    already_present: int

    @property
    def changed(self) -> bool:
        return bool(self.added_highlights or self.added_notes or self.added_chapters)


# --- parsing ----------------------------------------------------------------


def normalize(text: str) -> str:
    """Collapse a passage to its comparison key.

    Page numbers and timestamps both drift between exports (EPUB reflow, and a
    firmware timezone change), so the text itself is the only stable identity a
    highlight has.
    """
    return " ".join(unicodedata.normalize("NFC", text).replace(" ", " ").split())


def _records(lines: list[str]) -> list[list[str]]:
    records: list[list[str]] = [[]]
    for line in lines:
        if SEPARATOR.match(line.strip()):
            records.append([])
        else:
            records[-1].append(line)
    return [[ln for ln in rec if ln.strip()] for rec in records]


def parse_export(path: Path) -> Book:
    raw = path.read_text(encoding="utf-8")
    lines = [ln.replace(" ", " ").rstrip() for ln in raw.split("\n")]
    if not lines:
        raise ValueError(f"{path}: empty file")

    header = HEADER.match(lines[0])
    if not header:
        raise ValueError(f"{path}: first line is not a Boox annotation header")
    folder = header.group("stem").strip()
    authors = tuple(a.strip() for a in header.group("authors").split(",") if a.strip())

    highlights: list[Highlight] = []
    chapter = ""
    for record in _records(lines[1:]):
        if not record:
            continue
        if not TIMESTAMP.match(record[0]):
            chapter = record[0].strip()
            record = record[1:]
        stamp = TIMESTAMP.match(record[0]) if record else None
        if not stamp:
            raise ValueError(f"{path}: record has no timestamp line: {record[:1]}")

        body, note = record[1:], None
        for index, line in enumerate(body):
            annotation = ANNOTATION.match(line)
            if annotation:
                # Everything from the marker on is the note; the user can have
                # typed newlines into it.
                tail = [annotation.group("note")] + body[index + 1 :]
                note = "\n".join(tail).strip() or None
                body = body[:index]
                break

        text = "\n".join(ln.rstrip() for ln in body).strip()
        if not text:
            continue
        highlights.append(
            Highlight(
                chapter=chapter,
                when=datetime.strptime(stamp.group(1), "%Y-%m-%d %H:%M"),
                page=int(stamp.group(2)),
                text=text,
                note=note,
            )
        )

    return Book(
        folder=folder,
        title=book_title(folder, authors),
        authors=authors,
        highlights=tuple(highlights),
    )


def _squash(text: str) -> str:
    return re.sub(r"[^a-z0-9]", "", text.lower())


def book_title(folder: str, authors: tuple[str, ...]) -> str:
    """Recover a book title from a Boox folder name.

    The folder name is the ebook's filename stem, so it usually carries a
    Calibre-style `Title - Author` shape and sometimes a `(page count)` suffix.
    The author is only stripped when it actually matches the header's author
    field, so a genuine `Something - Something` title survives.
    """
    title = PAGE_COUNT_SUFFIX.sub("", folder).strip()
    if authors and " - " in title:
        head, _, tail = title.rpartition(" - ")
        if _squash(tail) == _squash("".join(authors)):
            title = head.strip()

    article = TRAILING_ARTICLE.match(title)
    if article:
        title = f"{article.group('article')} {article.group('body')}".strip()
    return title


def note_filename(title: str) -> str:
    """A filename Obsidian will accept, keeping `Title: Subtitle` readable."""
    cleaned = SUBTITLE_COLON.sub(" - ", title)
    cleaned = UNSAFE_IN_FILENAME.sub("-", cleaned)
    return re.sub(r"-{2,}", "-", cleaned).strip(" -") or "Untitled"


# --- device discovery -------------------------------------------------------


def find_note_dir(explicit: str | None = None) -> Path:
    if explicit:
        path = Path(explicit).expanduser()
        if not path.is_dir():
            raise SystemExit(f"no such directory: {path}")
        return path

    candidates: list[Path] = []
    for pattern in DEVICE_GLOBS:
        for hit in glob.glob(pattern):
            path = Path(hit)
            if path.is_dir() and any(path.glob(f"*/{EXPORT_GLOB}")):
                candidates.append(path)
    if not candidates:
        raise SystemExit(
            "no Boox note folder found.  Connect the device by USB, unlock it, "
            "and choose 'File transfer' in the USB notification; then look for "
            "'Internal shared storage/note' under /run/user/*/gvfs/."
        )
    if len(candidates) > 1:
        joined = "\n  ".join(str(c) for c in candidates)
        raise SystemExit(f"several devices are mounted; pass --device:\n  {joined}")
    return candidates[0]


def newest_export(folder: Path) -> Path | None:
    """The newest export supersedes the rest -- every export is a full dump.

    Older exports are ignored rather than unioned, so a highlight deleted on
    the device is not resurrected on the next import.
    """
    exports = sorted(folder.glob(EXPORT_GLOB), key=lambda p: p.name)
    return exports[-1] if exports else None


def book_folders(note_dir: Path) -> list[Path]:
    return sorted(
        (child for child in note_dir.iterdir() if child.is_dir() and newest_export(child)),
        key=lambda p: p.name,
    )


# --- frontmatter ------------------------------------------------------------


def split_frontmatter(text: str) -> tuple[list[str], str]:
    if not text.startswith("---\n"):
        return [], text
    end = text.find("\n---", 3)
    if end == -1:
        return [], text
    inner = text[4:end].split("\n")
    rest = text[end + 4 :]
    return inner, rest.lstrip("\n")


def frontmatter_blocks(lines: list[str]) -> list[tuple[str | None, list[str]]]:
    """Group frontmatter into (key, raw lines) blocks, preserving everything."""
    blocks: list[tuple[str | None, list[str]]] = []
    for line in lines:
        match = re.match(r"^([A-Za-z0-9_-]+):(.*)$", line)
        if match:
            blocks.append((match.group(1), [line]))
        elif blocks:
            blocks[-1][1].append(line)
        else:
            blocks.append((None, [line]))
    return blocks


def managed_frontmatter(book: Book, imported: date, count: int) -> dict[str, list[str]]:
    dates = [h.when.date() for h in book.highlights]
    authors = book.authors or (book_title(book.folder, ()),)
    fields: dict[str, list[str]] = {
        "title": [f"title: {_yaml_scalar(book.title)}"],
        "author": ["author:"] + [f'  - "[[{a}]]"' for a in authors],
        "source": ["source: boox"],
        "boox-folder": [f"boox-folder: {_yaml_scalar(book.folder)}"],
        "highlight-count": [f"highlight-count: {count}"],
        "imported": [f"imported: {imported.isoformat()}"],
    }
    if dates:
        fields["first-highlighted"] = [f"first-highlighted: {min(dates).isoformat()}"]
        fields["last-highlighted"] = [f"last-highlighted: {max(dates).isoformat()}"]
    return fields


def _yaml_scalar(value: str) -> str:
    if value and not re.search(r'[:#\[\]{}"\'\n]|^\s|\s$', value):
        return value
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def render_frontmatter(existing: list[str], fields: dict[str, list[str]]) -> list[str]:
    out: list[str] = []
    written: set[str] = set()
    for key, raw in frontmatter_blocks(existing):
        if key in fields:
            if key not in written:
                out.extend(fields[key])
                written.add(key)
        else:
            out.extend(raw)
    for key in MANAGED_KEYS:
        if key in fields and key not in written:
            out.extend(fields[key])
    return out


# --- body rendering ---------------------------------------------------------


def render_highlight(highlight: Highlight) -> list[str]:
    lines = highlight.text.split("\n")
    block = [f"- {lines[0]}"] + [f"  {ln}" for ln in lines[1:]]
    block[-1] = f"{block[-1]} (p. {highlight.page})"
    if highlight.note:
        block.extend(render_note(highlight.note))
    return block


def render_note(note: str) -> list[str]:
    lines = note.split("\n")
    return [f"    - Note: {lines[0]}"] + [f"      {ln}" for ln in lines[1:]]


# --- merge ------------------------------------------------------------------


class _Body:
    """A note body indexed so passages can be located by their text."""

    def __init__(self, text: str) -> None:
        self.lines = text.split("\n") if text else []
        self._offsets: list[int] = []
        parts: list[str] = []
        position = 0
        for line in self.lines:
            self._offsets.append(position)
            squashed = normalize(line)
            if squashed:
                parts.append(squashed)
                position += len(squashed) + 1
        self.joined = " ".join(parts)

    def find(self, passage: str) -> tuple[int, int] | None:
        """Line span containing `passage`, or None when it is absent."""
        needle = normalize(passage)
        if not needle:
            return None
        at = self.joined.find(needle)
        if at == -1:
            return None
        return self._line_at(at), self._line_at(at + len(needle) - 1)

    def contains(self, passage: str) -> bool:
        return self.find(passage) is not None

    def _line_at(self, offset: int) -> int:
        return max(0, bisect_right(self._offsets, offset) - 1)

    def block_end(self, line: int) -> int:
        """Extend past indented continuation lines and `- Note:` children."""
        end = line
        while end + 1 < len(self.lines):
            nxt = self.lines[end + 1]
            if nxt.strip() and nxt[:1].isspace():
                end += 1
            else:
                break
        return end

    def heading(self, title: str) -> int | None:
        wanted = normalize(title)
        for index, line in enumerate(self.lines):
            match = HEADING.match(line)
            if match and normalize(match.group(2)) == wanted:
                return index
        return None

    def after_heading(self, line: int) -> int:
        end = line
        while end + 1 < len(self.lines) and not self.lines[end + 1].strip():
            end += 1
        return end

    def section_end(self, line: int) -> int:
        end = len(self.lines) - 1
        for index in range(line + 1, len(self.lines)):
            if HEADING.match(self.lines[index]):
                end = index - 1
                break
        while end > line and not self.lines[end].strip():
            end -= 1
        return end


def merge_body(existing: str, book: Book) -> tuple[str, MergeStats]:
    body = _Body(existing)
    plan: dict[int, list[str]] = {}
    added_highlights = added_notes = already = 0
    new_chapters: set[str] = set()

    chapters: list[str] = []
    for highlight in book.highlights:
        if highlight.chapter and highlight.chapter not in chapters:
            chapters.append(highlight.chapter)

    def queue(anchor: int, lines: list[str]) -> None:
        plan.setdefault(anchor, []).extend(lines)

    # Where a brand new chapter section should be attached.
    def chapter_anchor(chapter: str) -> int:
        position = chapters.index(chapter)
        for earlier in reversed(chapters[:position]):
            heading = body.heading(earlier)
            if heading is not None:
                return body.section_end(heading)
            if earlier in new_chapters:
                return chapter_anchor(earlier)
        return len(body.lines) - 1

    for highlight in book.highlights:
        chapter = highlight.chapter
        heading = body.heading(chapter) if chapter else None
        found = body.find(highlight.text)

        if found is not None:
            already += 1
            if highlight.note and not body.contains(highlight.note):
                queue(body.block_end(found[1]), render_note(highlight.note))
                added_notes += 1
            continue

        added_highlights += 1
        rendered = render_highlight(highlight)

        # Anchor just after the nearest earlier highlight of the same chapter
        # that the note already has, so new passages land in reading order.
        anchor: int | None = None
        for earlier in reversed(_preceding(book.highlights, highlight, chapter)):
            span = body.find(earlier.text)
            if span is not None:
                anchor = body.block_end(span[1])
                break

        if anchor is not None:
            queue(anchor, rendered)
        elif heading is not None:
            queue(body.after_heading(heading), rendered)
        elif chapter and chapter in new_chapters:
            queue(chapter_anchor(chapter), rendered)
        elif chapter:
            new_chapters.add(chapter)
            at = chapter_anchor(chapter)
            queue(at, ["", f"# {chapter}", ""] + rendered)
        else:
            queue(len(body.lines) - 1, rendered)

    if not plan:
        return existing, MergeStats(0, 0, 0, already)

    lines = list(body.lines)
    for anchor in sorted(plan, reverse=True):
        at = min(max(anchor, -1), len(lines) - 1)
        lines[at + 1 : at + 1] = plan[anchor]

    merged = "\n".join(lines).strip("\n") + "\n"
    return merged, MergeStats(added_highlights, added_notes, len(new_chapters), already)


def _preceding(
    highlights: tuple[Highlight, ...], highlight: Highlight, chapter: str
) -> list[Highlight]:
    index = highlights.index(highlight)
    return [h for h in highlights[:index] if h.chapter == chapter]


def render_book(book: Book, existing: str, imported: date) -> tuple[str, MergeStats]:
    front, body = split_frontmatter(existing)
    merged, stats = merge_body(body, book)
    count = len(book.highlights)
    if existing.strip():
        count = max(count, _count_bullets(merged))
    fields = managed_frontmatter(book, imported, count)
    if not stats.changed and existing.strip():
        fields.pop("imported")
    rendered = ["---"] + render_frontmatter(front, fields) + ["---"]
    return "\n".join(rendered) + "\n\n" + merged.lstrip("\n"), stats


def _count_bullets(body: str) -> int:
    return sum(1 for line in body.split("\n") if line.startswith("- "))


# --- commands ---------------------------------------------------------------


def vault_note_path(vault: Path, title: str) -> Path:
    return vault / "book notes" / f"{note_filename(title)}.md"


def _load_existing(path: Path | None) -> str:
    if path and path.is_file():
        return path.read_text(encoding="utf-8")
    return ""


def cmd_list(args: argparse.Namespace) -> int:
    note_dir = find_note_dir(args.device)
    vault = Path(args.vault).expanduser()
    rows: list[dict[str, object]] = []
    for folder in book_folders(note_dir):
        export = newest_export(folder)
        assert export is not None
        try:
            book = parse_export(export)
        except ValueError as exc:
            rows.append({"folder": folder.name, "error": str(exc)})
            continue
        note = vault_note_path(vault, book.title)
        existing = _load_existing(note)
        _, stats = render_book(book, existing, date.today())
        rows.append(
            {
                "folder": folder.name,
                "title": book.title,
                "authors": list(book.authors),
                "export": export.name,
                "exports": len(list(folder.glob(EXPORT_GLOB))),
                "highlights": len(book.highlights),
                "note": str(note.relative_to(vault)),
                "note_exists": note.is_file(),
                "new_highlights": stats.added_highlights,
                "new_notes": stats.added_notes,
                "new_chapters": stats.added_chapters,
            }
        )

    if args.json:
        print(json.dumps({"device": str(note_dir), "books": rows}, indent=2))
        return 0

    print(f"device: {note_dir}")
    for row in rows:
        if "error" in row:
            print(f"  !! {row['folder']}: {row['error']}")
            continue
        state = "new note" if not row["note_exists"] else "existing"
        extra = f"+{row['new_highlights']} highlights"
        if row["new_notes"]:
            extra += f", +{row['new_notes']} annotations"
        if row["exports"] != 1:
            extra += f" ({row['exports']} exports, newest used)"
        print(f"  {row['title']}  [{row['highlights']} highlights, {state}]  {extra}")
        print(f"      folder: {row['folder']}")
        print(f"      note:   {row['note']}")
    return 0


def cmd_render(args: argparse.Namespace) -> int:
    note_dir = find_note_dir(args.device)
    folder = note_dir / args.folder
    if not folder.is_dir():
        raise SystemExit(f"no such book folder on the device: {args.folder}")
    export = newest_export(folder)
    if export is None:
        raise SystemExit(f"{args.folder}: no annotation export in this folder")

    book = parse_export(export)
    vault = Path(args.vault).expanduser()
    note = Path(args.existing).expanduser() if args.existing else vault_note_path(vault, book.title)
    today = date.fromisoformat(args.today) if args.today else date.today()
    text, stats = render_book(book, _load_existing(note), today)

    if args.out:
        Path(args.out).expanduser().write_text(text, encoding="utf-8")
    else:
        sys.stdout.write(text)

    summary = {
        "folder": book.folder,
        "title": book.title,
        "authors": list(book.authors),
        "export": export.name,
        "note": str(note),
        "note_existed": note.is_file(),
        "highlights_in_export": len(book.highlights),
        "added_highlights": stats.added_highlights,
        "added_annotations": stats.added_notes,
        "added_chapters": stats.added_chapters,
        "already_present": stats.already_present,
        "changed": stats.changed,
    }
    stream = sys.stdout if args.json and not args.out else sys.stderr
    print(json.dumps(summary, indent=2), file=stream)
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--device", help="Boox 'note' directory (default: autodetect the MTP mount)")
    parser.add_argument("--vault", default="~/Documents/Notes", help="Obsidian vault root")
    sub = parser.add_subparsers(dest="command", required=True)

    listing = sub.add_parser("list", help="inventory the books on the device")
    listing.add_argument("--json", action="store_true")
    listing.set_defaults(func=cmd_list)

    render = sub.add_parser("render", help="emit the merged note for one book")
    render.add_argument("folder", help="book folder name as it appears on the device")
    render.add_argument("--existing", help="note to merge into (default: the vault note for this title)")
    render.add_argument("--out", help="write the merged note here instead of stdout")
    render.add_argument("--today", help="date to record as `imported` (YYYY-MM-DD)")
    render.add_argument("--json", action="store_true")
    render.set_defaults(func=cmd_render)

    args = parser.parse_args(argv)
    return int(args.func(args))


if __name__ == "__main__":
    sys.exit(main())
