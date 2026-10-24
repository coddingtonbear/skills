#!/usr/bin/env python3
"""Prepare and rename scanner output on the seldon scans share.

Usage:
  scans.py list    [--dir DIR] [--json]
  scans.py prepare PDF [PDF ...] --out DIR [--dpi N]
  scans.py apply   PLAN.json [--dir DIR] [--backup DIR] [--dry-run]

`list` prints the PDFs that still carry the scanner's own name
(YYYYMMDD_HHMMSS_NNNNNN.pdf).  `prepare` renders every page of each PDF to a
PNG, OCRs it, and records tesseract's orientation guess, so the caller can
look at the pages and read the text before choosing a name.  `apply` carries
out an approved plan: it validates every new name, refuses to overwrite,
copies each original to the backup folder, rotates the pages the plan names,
and keeps the original modification time.

A plan is a JSON list:

  [{"src": "20261001_120619_000367.pdf",
    "name": "2026-10-01 - Contact Lens Rx - Big City Optical - exp 2027-10-01.pdf",
    "rotate": {"1": 180}}]

`rotate` maps 1-based page numbers to clockwise degrees (90, 180, 270) and may
be omitted.  Pages are never added, removed, merged or split.

Requires pdfinfo/pdftoppm (poppler), tesseract and pdftk on PATH.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass, field
from datetime import date
from pathlib import Path

DEFAULT_DIR = Path("/mnt/scans")

SCANNER_NAME = re.compile(r"^\d{8}_\d{6}_\d{6}\.pdf$")
# YYYY-MM-DD - Subject - Detail[ - more detail][ - exp YYYY-MM-DD].pdf
NAME = re.compile(
    r"^(?P<date>\d{4}-\d{2}-\d{2}) - (?P<body>.+?)"
    r"(?: - exp (?P<exp>\d{4}-\d{2}-\d{2}))?\.pdf$"
)
UNSAFE_IN_FILENAME = re.compile(r'[\\/:*?"<>|\x00-\x1f]')
ROTATIONS = {90: "right", 180: "down", 270: "left"}
OSD_ROTATE = re.compile(r"^Rotate:\s*(\d+)", re.MULTILINE)
OSD_CONFIDENCE = re.compile(r"^Orientation confidence:\s*([\d.]+)", re.MULTILINE)


class PlanError(ValueError):
    pass


@dataclass(frozen=True)
class Rename:
    src: str
    name: str
    rotate: dict[int, int] = field(default_factory=dict)


@dataclass(frozen=True)
class PageInfo:
    page: int
    image: str
    text: str
    osd_rotate: int | None
    osd_confidence: float | None


# --- validation --------------------------------------------------------------


def _valid_date(text: str) -> bool:
    try:
        date.fromisoformat(text)
    except ValueError:
        return False
    return True


def name_problems(name: str) -> list[str]:
    """Every way `name` breaks the naming convention; empty when it complies."""
    problems: list[str] = []
    if UNSAFE_IN_FILENAME.search(name):
        problems.append("contains a character a file name on the share can't hold")
    match = NAME.match(name)
    if not match:
        problems.append("is not 'YYYY-MM-DD - Subject - Detail[ - exp YYYY-MM-DD].pdf'")
        return problems
    if not _valid_date(match["date"]):
        problems.append(f"leading date {match['date']} is not a real date")
    if match["exp"] and not _valid_date(match["exp"]):
        problems.append(f"expiry date {match['exp']} is not a real date")
    parts = match["body"].split(" - ")
    if len(parts) < 2:
        problems.append("needs at least a Subject and a Detail after the date")
    if any(not part.strip() or part != part.strip() for part in parts):
        problems.append("has an empty or padded ' - ' segment")
    if re.search(r"\bexp\b", match["body"]):
        problems.append("expiry must be the last segment, as 'exp YYYY-MM-DD'")
    return problems


def parse_plan(raw: object) -> list[Rename]:
    if not isinstance(raw, list):
        raise PlanError("plan must be a JSON list")
    renames: list[Rename] = []
    for i, entry in enumerate(raw):
        if not isinstance(entry, dict):
            raise PlanError(f"entry {i} is not an object")
        src, name, rotate = entry.get("src"), entry.get("name"), entry.get("rotate", {})
        if not isinstance(src, str) or not isinstance(name, str):
            raise PlanError(f"entry {i} needs string 'src' and 'name'")
        if not isinstance(rotate, dict):
            raise PlanError(f"entry {i}: 'rotate' must be an object")
        pages: dict[int, int] = {}
        for page, degrees in rotate.items():
            if not str(page).isdigit() or int(page) < 1:
                raise PlanError(f"entry {i}: page {page!r} is not a 1-based page number")
            if degrees not in ROTATIONS:
                raise PlanError(f"entry {i}: rotation {degrees!r} must be 90, 180 or 270")
            pages[int(page)] = int(degrees)
        renames.append(Rename(src=src, name=name, rotate=pages))
    return renames


def check_plan(renames: list[Rename], directory: Path) -> list[str]:
    """Problems that must stop the whole plan before anything is touched."""
    problems: list[str] = []
    seen: set[str] = set()
    sources = {r.src for r in renames}
    for r in renames:
        if "/" in r.src or "/" in r.name:
            problems.append(f"{r.src}: src and name must be bare file names")
            continue
        if not (directory / r.src).is_file():
            problems.append(f"{r.src}: no such file in {directory}")
        problems.extend(f"{r.name}: {p}" for p in name_problems(r.name))
        if r.name in seen:
            problems.append(f"{r.name}: named twice in the plan")
        seen.add(r.name)
        if r.name in sources:
            problems.append(f"{r.name}: is also a source in this plan; rename chains aren't supported")
        elif (directory / r.name).exists():
            problems.append(f"{r.name}: already exists; refusing to overwrite")
        if r.rotate and (directory / r.src).is_file():
            count = page_count(directory / r.src)
            bad = [p for p in r.rotate if p > count]
            if bad:
                problems.append(f"{r.src}: has {count} pages, can't rotate page(s) {bad}")
    return problems


# --- PDF helpers -------------------------------------------------------------


def _run(*args: str) -> str:
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout


def page_count(pdf: Path) -> int:
    match = re.search(r"^Pages:\s*(\d+)", _run("pdfinfo", str(pdf)), re.MULTILINE)
    if not match:
        raise RuntimeError(f"pdfinfo reported no page count for {pdf}")
    return int(match[1])


def rotate_pdf(src: Path, dest: Path, rotate: dict[int, int]) -> None:
    ranges = [f"{p}{ROTATIONS[rotate[p]]}" if p in rotate else str(p) for p in range(1, page_count(src) + 1)]
    _run("pdftk", str(src), "cat", *ranges, "output", str(dest))


def osd(image: Path) -> tuple[int | None, float | None]:
    """Tesseract's orientation guess.  Unreliable on ID cards, receipts and
    blank pages, so it is only a hint for the caller's own look at the page."""
    result = subprocess.run(
        ["tesseract", str(image), "-", "--psm", "0"], capture_output=True, text=True
    )
    rotate, confidence = OSD_ROTATE.search(result.stdout), OSD_CONFIDENCE.search(result.stdout)
    return (int(rotate[1]) if rotate else None, float(confidence[1]) if confidence else None)


def prepare(pdf: Path, out: Path, dpi: int) -> list[PageInfo]:
    out.mkdir(parents=True, exist_ok=True)
    stem = out / pdf.stem
    _run("pdftoppm", "-r", str(dpi), "-png", str(pdf), str(stem))
    pages: list[PageInfo] = []
    for image in sorted(out.glob(f"{pdf.stem}-*.png")):
        number = int(image.stem.rsplit("-", 1)[1])
        text = subprocess.run(["tesseract", str(image), "-"], capture_output=True, text=True).stdout
        rotate, confidence = osd(image)
        pages.append(PageInfo(number, str(image), text.strip(), rotate, confidence))
    return pages


# --- commands ----------------------------------------------------------------


def unnamed(directory: Path) -> list[Path]:
    return sorted(p for p in directory.iterdir() if p.is_file() and SCANNER_NAME.match(p.name))


def apply_plan(renames: list[Rename], directory: Path, backup: Path, dry_run: bool) -> list[str]:
    problems = check_plan(renames, directory)
    if problems:
        raise PlanError("\n".join(problems))
    done: list[str] = []
    if dry_run:
        return [f"would rename {r.src} -> {r.name}" + (f" rotating {r.rotate}" if r.rotate else "") for r in renames]
    backup.mkdir(parents=True, exist_ok=True)
    for r in renames:
        src, dest = directory / r.src, directory / r.name
        shutil.copy2(src, backup / r.src)
        if r.rotate:
            # Write the rotated copy beside its target, then swap it in, so a
            # pdftk failure leaves the original where it was.
            tmp = directory / f".{r.name}.partial"
            rotate_pdf(src, tmp, r.rotate)
            stat = src.stat()
            os.utime(tmp, (stat.st_atime, stat.st_mtime))
            tmp.rename(dest)
            src.unlink()
        else:
            src.rename(dest)
        done.append(f"{r.src} -> {r.name}" + (f" (rotated {r.rotate})" if r.rotate else ""))
    return done


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    p_list = sub.add_parser("list")
    p_list.add_argument("--dir", type=Path, default=DEFAULT_DIR)
    p_list.add_argument("--json", action="store_true")

    p_prep = sub.add_parser("prepare")
    p_prep.add_argument("pdfs", nargs="+", type=Path)
    p_prep.add_argument("--out", type=Path, required=True)
    p_prep.add_argument("--dpi", type=int, default=150)

    p_apply = sub.add_parser("apply")
    p_apply.add_argument("plan", type=Path)
    p_apply.add_argument("--dir", type=Path, default=DEFAULT_DIR)
    p_apply.add_argument("--backup", type=Path, required=True)
    p_apply.add_argument("--dry-run", action="store_true")

    args = parser.parse_args(argv)

    if args.command == "list":
        files = unnamed(args.dir)
        if args.json:
            print(json.dumps([{"file": f.name, "pages": page_count(f)} for f in files], indent=2))
        else:
            for f in files:
                print(f"{f.name}\t{page_count(f)} page(s)")
        return 0

    if args.command == "prepare":
        report = {
            pdf.name: [page.__dict__ for page in prepare(pdf, args.out, args.dpi)] for pdf in args.pdfs
        }
        (args.out / "prepare.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
        images = [page["image"] for pages in report.values() for page in pages]
        if shutil.which("montage") and images:
            # One image of every page, labelled, to check orientation at a glance.
            sheet = args.out / "contact-sheet.png"
            _run("montage", "-label", "%t", *images, "-tile", "6x", "-geometry", "300x300+4+4", str(sheet))
            print(f"contact sheet: {sheet}")
        for name, pages in report.items():
            print(f"== {name}")
            for page in pages:
                hint = f"osd rotate {page['osd_rotate']} (conf {page['osd_confidence']})"
                print(f"  page {page['page']}: {page['image']}  [{hint}]  {len(page['text'])} chars OCR")
        print(f"OCR text and hints: {args.out / 'prepare.json'}")
        return 0

    try:
        renames = parse_plan(json.loads(args.plan.read_text(encoding="utf-8")))
        for line in apply_plan(renames, args.dir, args.backup, args.dry_run):
            print(line)
    except PlanError as error:
        print(f"plan rejected, nothing changed:\n{error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
