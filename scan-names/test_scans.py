"""Tests for the scan renamer.

Run with:  python3 -m pytest scan-names/
"""
from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path

import pytest

import scans

TOOLS = ("pdfinfo", "pdftk", "convert")
needs_tools = pytest.mark.skipif(
    any(shutil.which(t) is None for t in TOOLS), reason=f"needs {', '.join(TOOLS)}"
)


def make_pdf(path: Path, pages: int) -> Path:
    """A portrait PDF of `pages` blank pages, built with ImageMagick."""
    subprocess.run(
        ["convert", *(["-size", "100x200", "xc:white"] * pages), str(path)], check=True, capture_output=True
    )
    return path


def page_sizes(pdf: Path) -> list[tuple[int, int]]:
    """(width, height) of each page as rendered, i.e. after /Rotate."""
    out = subprocess.run(["pdfinfo", "-f", "1", "-l", "99", str(pdf)], check=True, capture_output=True, text=True).stdout
    sizes: list[tuple[int, int]] = []
    for line in out.splitlines():
        if line.startswith("Page") and "size:" in line:
            w, h = line.split("size:")[1].split("pts")[0].split(" x ")
            sizes.append((round(float(w)), round(float(h))))
    rotations = [int(l.split()[-1]) for l in out.splitlines() if l.startswith("Page") and "rot:" in l]
    return [(h, w) if rot % 180 else (w, h) for (w, h), rot in zip(sizes, rotations)]


# --- name_problems -------------------------------------------------------------


@pytest.mark.parametrize(
    "name",
    [
        "2026-10-01 - Contact Lens Rx - Big City Optical - exp 2027-10-01.pdf",
        "2026-05-24 - Illinois Driver's License - Adam Coddington - exp 2029-03-02.pdf",
        "2026-07-11 - Bryn Mawr Jewelry - Ring Resize Receipt.pdf",
        "2026-10-04 - Digital Microscope 109A - User Manual.pdf",
    ],
)
def test_accepts_convention(name: str) -> None:
    assert scans.name_problems(name) == []


@pytest.mark.parametrize(
    ("name", "fragment"),
    [
        ("Contact Lens Rx - 2026-10-01.pdf", "is not"),
        ("20261001 - Contact Lens Rx - Big City Optical.pdf", "is not"),
        ("2026-02-30 - Contact Lens Rx - Big City Optical.pdf", "not a real date"),
        ("2026-10-01 - Contact Lens Rx - Big City Optical - exp 2027-13-01.pdf", "not a real date"),
        ("2026-10-01 - Contact Lens Rx.pdf", "Subject and a Detail"),
        ("2026-10-01 - Rx: Contacts - Big City Optical.pdf", "character"),
        ("2026-10-01 - Contact Lens Rx -  Big City Optical.pdf", "padded"),
        ("2026-10-01 - Contact Lens Rx - exp 2027-10-01 - Big City Optical.pdf", "last segment"),
    ],
)
def test_rejects_breaks(name: str, fragment: str) -> None:
    assert any(fragment in p for p in scans.name_problems(name)), scans.name_problems(name)


def test_scanner_name_pattern() -> None:
    assert scans.SCANNER_NAME.match("20261024_143650_000386.pdf")
    assert not scans.SCANNER_NAME.match("2026-10-01 - Eyeglass Rx - Big City Optical.pdf")


# --- parse_plan ----------------------------------------------------------------


def test_parse_plan_reads_rotation() -> None:
    [r] = scans.parse_plan([{"src": "a.pdf", "name": "b.pdf", "rotate": {"2": 180}}])
    assert r.rotate == {2: 180}


@pytest.mark.parametrize(
    "raw",
    [
        {"src": "a.pdf"},
        [{"src": "a.pdf"}],
        [{"src": "a.pdf", "name": "b.pdf", "rotate": {"1": 45}}],
        [{"src": "a.pdf", "name": "b.pdf", "rotate": {"0": 90}}],
    ],
)
def test_parse_plan_rejects(raw: object) -> None:
    with pytest.raises(scans.PlanError):
        scans.parse_plan(raw)


# --- apply_plan ----------------------------------------------------------------

GOOD = "2026-10-01 - Contact Lens Rx - Big City Optical - exp 2027-10-01.pdf"


@needs_tools
def test_apply_renames_rotates_and_backs_up(tmp_path: Path) -> None:
    share, backup = tmp_path / "share", tmp_path / "backup"
    share.mkdir()
    src = make_pdf(share / "20261001_120619_000367.pdf", pages=3)
    os.utime(src, (1_700_000_000, 1_700_000_000))

    plan = scans.parse_plan([{"src": src.name, "name": GOOD, "rotate": {"1": 180, "3": 90}}])
    scans.apply_plan(plan, share, backup, dry_run=False)

    dest = share / GOOD
    assert not src.exists()
    assert (backup / src.name).is_file()
    assert sorted(p.name for p in share.iterdir()) == [GOOD]
    assert dest.stat().st_mtime == 1_700_000_000
    assert scans.page_count(dest) == 3
    sizes = page_sizes(dest)
    assert sizes[0][0] < sizes[0][1]  # 180 keeps portrait
    assert sizes[1][0] < sizes[1][1]  # untouched
    assert sizes[2][0] > sizes[2][1]  # 90 turns landscape


@needs_tools
def test_apply_refuses_whole_plan_on_any_problem(tmp_path: Path) -> None:
    make_pdf(tmp_path / "20261001_120619_000367.pdf", pages=1)
    make_pdf(tmp_path / "20261001_120644_000368.pdf", pages=1)
    make_pdf(tmp_path / GOOD, pages=1)
    plan = scans.parse_plan(
        [
            {"src": "20261001_120619_000367.pdf", "name": "2026-10-01 - Contact Lens Price Quote - Big City Optical.pdf"},
            {"src": "20261001_120644_000368.pdf", "name": GOOD},
        ]
    )
    with pytest.raises(scans.PlanError, match="refusing to overwrite"):
        scans.apply_plan(plan, tmp_path, tmp_path / "backup", dry_run=False)
    assert (tmp_path / "20261001_120619_000367.pdf").exists()
    assert not (tmp_path / "backup").exists()


@needs_tools
def test_apply_rejects_rotation_past_last_page(tmp_path: Path) -> None:
    make_pdf(tmp_path / "20261001_120619_000367.pdf", pages=1)
    plan = scans.parse_plan([{"src": "20261001_120619_000367.pdf", "name": GOOD, "rotate": {"2": 90}}])
    with pytest.raises(scans.PlanError, match="has 1 pages"):
        scans.apply_plan(plan, tmp_path, tmp_path / "backup", dry_run=False)


@needs_tools
def test_dry_run_changes_nothing(tmp_path: Path) -> None:
    src = make_pdf(tmp_path / "20261001_120619_000367.pdf", pages=1)
    plan = scans.parse_plan([{"src": src.name, "name": GOOD}])
    assert scans.apply_plan(plan, tmp_path, tmp_path / "backup", dry_run=True)
    assert src.exists() and not (tmp_path / GOOD).exists()


@needs_tools
def test_rejects_duplicate_and_chained_names(tmp_path: Path) -> None:
    a = make_pdf(tmp_path / "20261001_120619_000367.pdf", pages=1)
    b = make_pdf(tmp_path / "20261001_120644_000368.pdf", pages=1)
    dupes = scans.parse_plan([{"src": a.name, "name": GOOD}, {"src": b.name, "name": GOOD}])
    assert any("named twice" in p for p in scans.check_plan(dupes, tmp_path))
    chain = scans.parse_plan([{"src": a.name, "name": b.name}, {"src": b.name, "name": GOOD}])
    assert any("rename chains" in p for p in scans.check_plan(chain, tmp_path))


def test_unnamed_lists_only_scanner_names(tmp_path: Path) -> None:
    (tmp_path / "20261024_143650_000386.pdf").write_bytes(b"")
    (tmp_path / GOOD).write_bytes(b"")
    (tmp_path / ".Trash-1000").mkdir()
    assert [p.name for p in scans.unnamed(tmp_path)] == ["20261024_143650_000386.pdf"]
