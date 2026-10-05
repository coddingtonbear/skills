"""Tests for the Boox highlight importer.

Run with:  python3 -m pytest boox-highlights/
"""
from __future__ import annotations

import textwrap
from datetime import date
from pathlib import Path

import pytest

import import_highlights as ih

NB = " "


def export(body: str, *, stem: str = "Alchemy - Rory Sutherland (183)", authors: str = "Rory Sutherland") -> str:
    """Build an export file, restoring the NBSPs a real Boox writes."""
    header = f"Reading Notes{NB}|{NB}<<{stem}>>{authors}"
    body = textwrap.dedent(body).strip("\n")
    body = body.replace("  |  Page No.:", f"{NB}{NB}|{NB}{NB}Page No.:")
    return f"{header}\n{body}\n"


def plus(body: str, extra: str) -> str:
    """Append a record, matching the indentation `export()` will dedent away."""
    return body + textwrap.indent(textwrap.dedent(extra).strip("\n"), "    ") + "\n"


def write(tmp_path: Path, text: str, name: str = "book-annotation-2026-01-01_00_00_00.txt") -> Path:
    path = tmp_path / name
    path.write_text(text, encoding="utf-8")
    return path


SIMPLE = """
    Prologue
    2024-08-28 07:54  |  Page No.: 11
    The opposite of a good idea can also be a good idea.
    -------------------
    2024-08-28 07:58  |  Page No.: 12
    Red Bull tastes kind of disgusting.
    【Annotation】worth remembering
    -------------------
    Introduction
    2024-08-29 17:24  |  Page No.: 21
    Most things aren't logical, they are psycho-logical.
    -------------------
"""


# --- parsing ----------------------------------------------------------------


def test_parses_chapters_timestamps_pages_and_annotations(tmp_path):
    book = ih.parse_export(write(tmp_path, export(SIMPLE)))

    assert book.folder == "Alchemy - Rory Sutherland (183)"
    assert book.title == "Alchemy"
    assert book.authors == ("Rory Sutherland",)
    assert len(book.highlights) == 3

    first, second, third = book.highlights
    assert first.chapter == "Prologue"
    assert first.page == 11
    assert first.when.isoformat() == "2024-08-28T07:54:00"
    assert first.text == "The opposite of a good idea can also be a good idea."
    assert first.note is None

    assert second.chapter == "Prologue", "chapter carries forward until it changes"
    assert second.note == "worth remembering"
    assert third.chapter == "Introduction"


def test_accepts_the_older_note_marker(tmp_path):
    text = export(
        """
        2024-08-28 07:54  |  Page No.: 11
        A passage.
        【Note】older firmware wrote this marker
        -------------------
        """
    )
    (highlight,) = ih.parse_export(write(tmp_path, text)).highlights
    assert highlight.note == "older firmware wrote this marker"


def test_keeps_multi_line_passages_intact(tmp_path):
    text = export(
        """
        2024-08-28 07:54  |  Page No.: 11
        Don't design for average.
        Dare to be trivial.
        -------------------
        """
    )
    (highlight,) = ih.parse_export(write(tmp_path, text)).highlights
    assert highlight.text == "Don't design for average.\nDare to be trivial."


def test_multi_line_annotation_is_kept_whole(tmp_path):
    text = export(
        """
        2024-08-28 07:54  |  Page No.: 11
        A passage.
        【Annotation】first line
        second line
        -------------------
        """
    )
    (highlight,) = ih.parse_export(write(tmp_path, text)).highlights
    assert highlight.note == "first line\nsecond line"


def test_rejects_a_file_that_is_not_an_export(tmp_path):
    path = tmp_path / "not-an-export.txt"
    path.write_text("just some text\n", encoding="utf-8")
    with pytest.raises(ValueError, match="not a Boox annotation header"):
        ih.parse_export(path)


# --- titles -----------------------------------------------------------------


@pytest.mark.parametrize(
    "folder,authors,expected",
    [
        ("Alchemy - Rory Sutherland (183)", ("Rory Sutherland",), "Alchemy"),
        ("Measure What Matters - John Doerr", ("John Doerr",), "Measure What Matters"),
        (
            "Elephant in the Brain, The - Kevin Simler & Robin Hanson",
            ("Kevin Simler", "Robin Hanson"),
            "The Elephant in the Brain",
        ),
        ("High Output Management - Andrew S. Grove (173)", ("Andrew S. Grove",), "High Output Management"),
        # ' - ' that is part of the title, not an author, is left alone.
        ("Nineteen Eighty-Four - A Novel - George Orwell", ("George Orwell",), "Nineteen Eighty-Four - A Novel"),
        ("Untitled Export", (), "Untitled Export"),
    ],
)
def test_book_title(folder, authors, expected):
    assert ih.book_title(folder, authors) == expected


def test_note_filename_strips_characters_obsidian_rejects():
    assert ih.note_filename("Weird: A/B Test?") == "Weird - A-B Test"


# --- rendering a new note ---------------------------------------------------


def test_renders_a_new_note(tmp_path):
    book = ih.parse_export(write(tmp_path, export(SIMPLE)))
    text, stats = ih.render_book(book, "", date(2026, 9, 15))

    assert text == textwrap.dedent(
        """\
        ---
        title: Alchemy
        author:
          - "[[Rory Sutherland]]"
        source: boox
        boox-folder: Alchemy - Rory Sutherland (183)
        highlight-count: 3
        first-highlighted: 2024-08-28
        last-highlighted: 2024-08-29
        imported: 2026-09-15
        ---

        # Prologue

        - The opposite of a good idea can also be a good idea. (p. 11)
        - Red Bull tastes kind of disgusting. (p. 12)
            - Note: worth remembering

        # Introduction

        - Most things aren't logical, they are psycho-logical. (p. 21)
        """
    )
    assert stats.added_highlights == 3
    assert stats.added_chapters == 2


def test_multi_line_passage_renders_as_one_bullet(tmp_path):
    text = export(
        """
        Rules
        2024-08-28 07:54  |  Page No.: 11
        Don't design for average.
        Dare to be trivial.
        -------------------
        """
    )
    book = ih.parse_export(write(tmp_path, text))
    rendered, _ = ih.render_book(book, "", date(2026, 9, 15))
    assert "- Don't design for average.\n  Dare to be trivial. (p. 11)" in rendered


# --- merging ----------------------------------------------------------------


def test_reimport_of_unchanged_export_is_a_no_op(tmp_path):
    book = ih.parse_export(write(tmp_path, export(SIMPLE)))
    first, _ = ih.render_book(book, "", date(2026, 9, 15))
    second, stats = ih.render_book(book, first, date(2026, 12, 25))

    assert second == first, "a re-import must not churn the note"
    assert not stats.changed
    assert stats.already_present == 3
    assert "imported: 2026-09-15" in second, "unchanged notes keep their import date"


def test_new_highlight_lands_in_chapter_order_not_at_the_end(tmp_path):
    book = ih.parse_export(write(tmp_path, export(SIMPLE)))
    note, _ = ih.render_book(book, "", date(2026, 9, 15))

    grown = export(
        SIMPLE.replace(
            """    2024-08-28 07:58  |  Page No.: 12""",
            """    2024-08-28 07:56  |  Page No.: 11
    A passage added between the other two.
    -------------------
    2024-08-28 07:58  |  Page No.: 12""",
        )
    )
    merged, stats = ih.render_book(ih.parse_export(write(tmp_path, grown, "b.txt")), note, date(2026, 12, 25))

    assert stats.added_highlights == 1
    body = [ln for ln in merged.split("\n") if ln.startswith("- ")]
    assert body == [
        "- The opposite of a good idea can also be a good idea. (p. 11)",
        "- A passage added between the other two. (p. 11)",
        "- Red Bull tastes kind of disgusting. (p. 12)",
        "- Most things aren't logical, they are psycho-logical. (p. 21)",
    ]
    assert "imported: 2026-12-25" in merged


def test_a_new_chapter_is_inserted_after_the_chapter_before_it(tmp_path):
    book = ih.parse_export(write(tmp_path, export(SIMPLE)))
    note, _ = ih.render_book(book, "", date(2026, 9, 15))

    grown = export(
        SIMPLE.replace(
            """    Introduction""",
            """    Interlude
    2024-08-28 09:00  |  Page No.: 15
    A passage in a chapter that did not exist before.
    -------------------
    Introduction""",
        )
    )
    merged, stats = ih.render_book(ih.parse_export(write(tmp_path, grown, "b.txt")), note, date(2026, 12, 25))

    assert stats.added_chapters == 1
    headings = [ln for ln in merged.split("\n") if ln.startswith("# ")]
    assert headings == ["# Prologue", "# Interlude", "# Introduction"]


def test_hand_written_prose_survives_a_reimport(tmp_path):
    book = ih.parse_export(write(tmp_path, export(SIMPLE)))
    note, _ = ih.render_book(book, "", date(2026, 9, 15))
    edited = note.replace(
        "# Introduction\n",
        "# Introduction\n\nI came back to this chapter twice.\n",
    ) + "\n# My own thoughts\n\nThe whole argument turns on this.\n"

    grown = export(
        plus(
            SIMPLE,
            """
            2024-08-30 10:00  |  Page No.: 30
            A brand new passage.
            -------------------
            """,
        )
    )
    merged, stats = ih.render_book(ih.parse_export(write(tmp_path, grown, "b.txt")), edited, date(2026, 12, 25))

    assert stats.added_highlights == 1
    assert "I came back to this chapter twice." in merged
    assert "# My own thoughts" in merged
    assert "The whole argument turns on this." in merged
    assert "- A brand new passage. (p. 30)" in merged


def test_an_annotation_added_later_is_attached_to_its_highlight(tmp_path):
    book = ih.parse_export(write(tmp_path, export(SIMPLE)))
    note, _ = ih.render_book(book, "", date(2026, 9, 15))

    annotated = export(
        SIMPLE.replace(
            "Most things aren't logical, they are psycho-logical.",
            "Most things aren't logical, they are psycho-logical.\n    【Annotation】the thesis of the book",
        )
    )
    merged, stats = ih.render_book(ih.parse_export(write(tmp_path, annotated, "b.txt")), note, date(2026, 12, 25))

    assert (stats.added_highlights, stats.added_notes) == (0, 1)
    assert (
        "- Most things aren't logical, they are psycho-logical. (p. 21)\n"
        "    - Note: the thesis of the book" in merged
    )


def test_a_moved_page_number_is_not_treated_as_a_new_highlight(tmp_path):
    """EPUB reflow renumbers pages between exports; the text is the identity."""
    book = ih.parse_export(write(tmp_path, export(SIMPLE)))
    note, _ = ih.render_book(book, "", date(2026, 9, 15))

    reflowed = export(SIMPLE.replace("Page No.: 21", "Page No.: 9").replace("17:24", "19:24"))
    merged, stats = ih.render_book(ih.parse_export(write(tmp_path, reflowed, "b.txt")), note, date(2026, 12, 25))

    assert not stats.changed
    assert "(p. 21)" in merged, "the first-seen page is kept rather than churned"


def test_unmanaged_frontmatter_keys_are_preserved(tmp_path):
    book = ih.parse_export(write(tmp_path, export(SIMPLE)))
    note, _ = ih.render_book(book, "", date(2026, 9, 15))
    edited = note.replace("---\ntitle:", "---\nrating: 5\ntags:\n  - marketing\ntitle:")

    grown = export(
        plus(
            SIMPLE,
            """
            2024-08-30 10:00  |  Page No.: 30
            A brand new passage.
            -------------------
            """,
        )
    )
    merged, _ = ih.render_book(ih.parse_export(write(tmp_path, grown, "b.txt")), edited, date(2026, 12, 25))

    assert "rating: 5" in merged
    assert "tags:\n  - marketing" in merged
    assert merged.count("title: Alchemy") == 1


def test_note_without_frontmatter_gains_one_without_losing_content(tmp_path):
    book = ih.parse_export(write(tmp_path, export(SIMPLE)))
    merged, stats = ih.render_book(book, "# Prologue\n\nSome earlier prose.\n", date(2026, 9, 15))

    assert merged.startswith("---\ntitle: Alchemy")
    assert "Some earlier prose." in merged
    assert stats.added_highlights == 3


# --- device layout ----------------------------------------------------------


def test_only_the_newest_export_is_used(tmp_path):
    folder = tmp_path / "note" / "Alchemy - Rory Sutherland (183)"
    folder.mkdir(parents=True)
    old = folder / "Alchemy - Rory Sutherland (183)-annotation-2024-02-12_13_30_32.txt"
    new = folder / "Alchemy - Rory Sutherland (183)-annotation-2026-09-15_21_57_46.txt"
    old.write_text(export(SIMPLE), encoding="utf-8")
    new.write_text(export(SIMPLE), encoding="utf-8")

    assert ih.newest_export(folder) == new
    assert ih.book_folders(tmp_path / "note") == [folder]


def test_folders_holding_only_a_notebook_pdf_are_skipped(tmp_path):
    note_dir = tmp_path / "note"
    (note_dir / "Notebook-7").mkdir(parents=True)
    (note_dir / "Notebook-7" / "Notebook-7.pdf").write_bytes(b"%PDF-1.4\n")
    assert ih.book_folders(note_dir) == []


def test_missing_device_explains_how_to_connect_it(tmp_path, monkeypatch):
    monkeypatch.setattr(ih, "DEVICE_GLOBS", (str(tmp_path / "nothing-here" / "*"),))
    with pytest.raises(SystemExit, match="File transfer"):
        ih.find_note_dir(None)


def test_an_explicit_device_path_that_is_missing_is_reported(tmp_path):
    with pytest.raises(SystemExit, match="no such directory"):
        ih.find_note_dir(str(tmp_path / "note"))
