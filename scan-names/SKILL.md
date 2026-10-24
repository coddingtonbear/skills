---
name: scan-names
description: >-
  Reads the PDFs the document scanner drops on the seldon scans share
  (//seldon.local/scans, mounted at /mnt/scans), works out what each one is,
  and renames it to "YYYY-MM-DD - Subject - Detail[ - exp YYYY-MM-DD].pdf",
  turning any sideways or upside-down pages upright on the way. Use when asked
  to look at, identify, sort, name or rename scans or scanned documents, to
  find out what is in the scans folder, or when a file named like
  20261024_143650_000386.pdf needs a real name.
---

**Goal:** Every scan on the share has a name that says what it is, when it's from and, if it runs out, when it expires, and every page in it is upright.

**Requirements:** poppler (`pdfinfo`, `pdftoppm`), `tesseract`, `pdftk`, and ImageMagick `montage` for the contact sheet. Everything runs through [scans.py](scans.py).

---

## The share

- `//seldon.local/scans` is a CIFS automount at `/mnt/scans`. Listing it mounts it. If the listing fails, say so and stop. Don't try to mount it yourself.
- The scanner names files `YYYYMMDD_HHMMSS_NNNNNN.pdf`: the scan time, then a running counter. The scanner's clock is about two hours off the file mtime, so read the date from the file name, never from the mtime.
- The PDFs are images with **no text layer**, so `pdftotext` returns nothing. Read them by OCR and by looking at the page images.
- Ignore `.Trash-1000/`. It holds files the user deleted on purpose.
- Files that already follow the convention are done. Leave them alone unless the user names one.

---

## Naming convention

```
YYYY-MM-DD - Subject - Detail[ - more detail][ - exp YYYY-MM-DD].pdf
```

- **Leading date:** the document's own date, in ISO format. It goes first so the folder sorts by time.
  - IDs: the issue date.
  - Prescriptions: the exam or fitting date.
  - Receipts, invoices and repair tickets: the transaction date.
  - Medical summaries: the visit date, not the date it was printed.
  - Letters and statements: the date printed on them.
  - Undated things like product manuals: the scan date from the scanner's file name. That's roughly when the product arrived, which is the date that matters for it.
- **Subject:** what the user would look for first.
  - Records about the user, such as IDs and prescriptions: the document type (`Contact Lens Rx`, `US Passport Card`).
  - Purchases, receipts and quotes: the vendor (`Bryn Mawr Jewelry`).
  - Manuals: brand and model (`Kunphy SC-187 Ultrasonic Cleaner`).
  - Documents about someone else: that person's name (`Janice Elkins`). Their relationship to the user isn't needed, so don't ask for it.
- **Detail:** whatever makes the name complete. That's the document type when the Subject is a vendor or product (`Ring Resize Receipt`, `User Manual`), the issuer when the Subject is a document type (`Big City Optical`), or the holder's name on an ID.
- **`exp YYYY-MM-DD`:** always the last segment, on anything that runs out or needs renewing: IDs, prescriptions, insurance cards, warranties, policies. This is the part the user acts on.
- **Never put identifying numbers in a name:** no license, passport, account or card numbers. Don't repeat them in chat either.
- **Characters:** keep the document's own capitalisation and spell brands its way. Apostrophes are fine. `\ / : * ? " < > |` are not.
- **One scan, one file, always.** Never merge, split or drop pages. A receipt that goes with a repair ticket gets its own name with the same date and vendor, so the two sort side by side. Blank back pages stay in.

Names the user approved, 2026-10-24:

```
2023-03-28 - US Passport Card - Adam Coddington - exp 2033-03-27.pdf
2026-05-24 - Illinois Driver's License - Adam Coddington - exp 2029-03-02.pdf
2026-07-11 - Bryn Mawr Jewelry - Ring Resize Ticket.pdf
2026-07-11 - Bryn Mawr Jewelry - Ring Resize Receipt.pdf
2026-09-16 - Pomodoro Timer Cube - User Guide.pdf
2026-09-17 - Kunphy SC-187 Ultrasonic Cleaner - User Manual.pdf
2026-09-23 - Janice Elkins - Patient Summary.pdf
2026-10-01 - Contact Lens Rx - Big City Optical - exp 2027-10-01.pdf
2026-10-01 - Contact Lens Price Quote - Big City Optical.pdf
2026-10-01 - Eyeglass Rx - Big City Optical - exp 2027-10-01.pdf
2026-10-04 - Digital Microscope 109A - User Manual.pdf
```

`scans.py` checks every name against this convention before it renames anything.

---

## Steps

Work in the session scratchpad: `$SCRATCH` below stands for its absolute path.

1. **Find the work.**
   - `scan-names/scans.py list` prints each file that still has a scanner name, with its page count.
   - If the user named particular files, do just those.

2. **Prepare the pages.**
   - Run `scan-names/scans.py prepare /mnt/scans/<file>.pdf ... --out $SCRATCH/prep`.
   - It renders every page to a PNG, OCRs it, and writes `prepare.json`, which holds the OCR text plus tesseract's orientation guess for each page.
   - It also writes `contact-sheet.png`, which shows every page at once.

3. **Read each document.**
   - Look at the page images with the Read tool. Use the OCR text to get names, dates and amounts exactly right.
   - On a page scanned upside down or sideways the OCR comes out as garbage. Read the image instead, or rotate it first with `convert <png> -rotate 180` and OCR that.
   - Find the dates the convention needs: the leading date and any expiry. On IDs the expiry is also in the machine-readable zone (`YYMMDD` after the birth date), which helps check a blurry print.

4. **Check orientation by eye.**
   - Look at the contact sheet. For each page, work out the clockwise rotation (90, 180 or 270) that makes the text read normally.
   - **Don't trust tesseract's guess.** On 2026-10-24 it got the passport card and the license wrong at low confidence, and it guesses at random on blank pages. Treat it as a hint only.
   - A folded leaflet scanned flat should come out landscape. Don't force it to portrait.

5. **Propose, then wait.**
   - Show the user a table: current file, what it is (one line, including the key facts such as amount, expiry or patient), proposed name, and any rotations.
   - Ask about anything you can't tell from the page. Don't rename anything until the user approves the list. They may change names, and their edits are binding.

6. **Apply.**
   - Write the approved plan to `$SCRATCH/plan.json` in the format described in `scans.py --help`. `rotate` maps page numbers to clockwise degrees.
   - Run `scan-names/scans.py apply $SCRATCH/plan.json --backup $SCRATCH/backup --dry-run`, then run it again without `--dry-run`.
   - If any entry has a problem, `apply` rejects the whole plan and changes nothing. Fix the plan rather than working around the check.
   - Each original is copied to the backup folder before anything changes. A rotated file replaces its original and keeps the original's mtime.

7. **Verify.**
   - Run `prepare` again on every rotated file and look at the new contact sheet, to confirm each page is upright. Then list the share.
   - Report the final names. Tell the user where the backups are, and that the scratchpad doesn't last.

Don't add an OCR text layer, compress, or otherwise rewrite a PDF unless the user asks for it.

---

## Tests

```bash
python3 -m pytest scan-names/
```

`test_scans.py` covers the name validator, plan parsing, and `apply`. The `apply` tests build PDFs with ImageMagick and check renaming, rotation, backups, mtime, refusing to overwrite, and rejecting the whole plan when one entry is bad. Add a case before you change the convention or what `apply` does.
