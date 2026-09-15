# Quest Diagnostics reports

Patient-portal exports from MyQuest. Recognise them by the `MyQuest` logo and patient banner at the top of page 1, the two-column `Analyte │ Value` tables with the reference range printed beside each value as `Reference Range: …`, and the "Performing Sites" / "Key" block and Quest Diagnostics logo at the end. The downloaded file is named `labreport_<Specimen>.pdf`. None of the Labcorp rules about footnote markers, a Units column or a Previous Result column apply here.

**One PDF per specimen.** Unlike HealthLab, every test ordered on the requisition prints in the same PDF, so the Step 2 duplicate check on `specimen_id` applies unchanged.

---

## Report header

| Report-note field | Where it comes from |
|---|---|
| `lab` | `Quest Diagnostics` |
| `specimen_id` | "Specimen" |
| `collected` | "Collected" (`MM/DD/YYYY HH:MM`), written as `YYYY-MM-DDTHH:MM` |
| `reported` | "Reported", date part only, as `YYYY-MM-DD` |
| `fasting` | "Fasting": `Y`/`Yes` → `true`, `N`/`No` → `false`, blank → `unknown` |
| `ordering_physician` | the first line of the client block under "Client #" (`FRANCO,CELEZTE`), as printed |
| `practice` | the next line of that block (`MINUTECLINIC 8747`) |
| `ordered_items` | every section heading, in order, as printed; a heading printed twice in a row counts once |

MyQuest prints no specimen source, so `specimen_source` is omitted. "Received" is when the lab took the specimen in, not when it released the result, so it's not used for `reported`.

Quest prints the ordered tests as the bold section headings (`COMPREHENSIVE METABOLIC PANEL`, `HEPATITIS B SURFACE ANTIGEN W/REFL CONFIRM`), which is why they stand in for Labcorp's "Ordered Items" list. A panel with a group heading directly over an identical subheading (`HIV 1/2 ANTIGEN/ANTIBODY,FOURTH GENERATION W/RFL` twice) is one ordered item.

"Report Status" should begin with **FINAL** (`FINAL / SEE REPORT` is normal). Anything else goes in the Step 4 review.

**Never copy** patient name, date of birth, age, sex, phone, Patient ID, Requisition, Lab Reference ID, Client #, the numeric line in the client block (`21321`), or the practice's street address and phone. The specimen number is the one identifier kept, because it identifies the report.

---

## Result rows

Each section heading is followed by an `Analyte │ Value` column header, then one row per analyte:

```
CREATININE                                1.11   Reference Range: 0.60-1.29 mg/dL
```

- **`reported_name`** — the Analyte column as printed, all capitals included (`UREA NITROGEN (BUN)`, `HIV AG/AB, 4TH GEN`). There are no footnote markers to strip.
- **`panel`** — the section heading above the row, as printed.
- **`result`** — the Value column, parsed per the shared "Parsing values" rules.
- The `Analyte  Value` line is a column header, not a row; on a section that breaks across a page it can print on one page with the rows on the next.

### Flags

Quest marks an out-of-range value with an icon, keyed at the end of the report as "Priority Out of Range" and "Out of Range", and doesn't reliably print an `H`/`L` letter. The first Quest report processed had no out-of-range values, so how a flagged row reads in the extracted text is still unknown. When a Quest row carries either marker or a trailing letter, show it in the Step 4 review, ask how to record the flag, and add the answer here. Never infer a flag by comparing the value with the range.

### Reference range and unit

Quest prints both in the one cell after a `Reference Range:` label, with the unit trailing the interval and sometimes a `(calc)` marker after it. Drop the label; `(calc)` only says the value was calculated, so it goes in neither field.

| Printed | `reference_range` | `ref_low` | `ref_high` | `unit` |
|---|---|---|---|---|
| `Reference Range: 65-99 mg/dL` | `"65-99"` | `65` | `99` | `mg/dL` |
| `Reference Range: 1.9-3.7 g/dL (calc)` | `"1.9-3.7"` | `1.9` | `3.7` | `g/dL` |
| `Reference Range: 1.0-2.5 (calc)` | `"1.0-2.5"` | `1.0` | `2.5` | — |
| `Reference Range: > OR = 60mL/min/1.73m2` | `"> OR = 60"` | `60` | — | `mL/min/1.73m2` |
| `Reference Range: NON-REACTIVE` | `"NON-REACTIVE"` | — | — | — |

`> OR =` and `< OR =` are Quest's spelling of `>=` and `<=`; the unit can follow the number with no space.

### What never becomes a result

- A row whose Value is `SEE NOTE:` followed by a "Not Reported: …" explanation (`BUN/CREATININE RATIO` when BUN and creatinine are both in range). No value was reported; list it as skipped in the review.
- `COMMENT` rows whose value is only a `See Note N` pointer, and the numbered `Note N` text at the end of the report (FAQ links).
- The monospace text Quest prints under a row that is its standing wording for that test rather than a note about this specimen: `Fasting reference interval` under glucose, the "HCV antibody was non-reactive…" and "HIV-1 antigen and HIV-1/HIV-2 antibodies were not detected…" interpretations, the state-law disclosure paragraph, FAQ links. A comment specific to this specimen ("Specimen hemolyzed") still goes in the result note body.
- The "Performing Sites" and "Key" blocks, the page footer (patient name, page count, print date) and the trademark and privacy text.

---

## File naming

`<Primary>` is the first entry in `ordered_items`, title-cased per "File naming" because Quest prints headings in capitals, and `-plusN` counts the rest: `COMPREHENSIVE METABOLIC PANEL` with five other headings → `2024-07-09_Comprehensive-Metabolic-Panel-plus5.pdf`.

---

## Name matching

Quest's names are capitalised and worded differently from Labcorp's and HealthLab's (`UREA NITROGEN (BUN)` vs `BUN`, `GLOBULIN` vs `Globulin, Total`, `HEPATITIS C ANTIBODY` vs `Hep C Virus Ab`). Matching already ignores case, so `SODIUM` matches `Sodium` without a new variant; the rest go through Step 3 as ordinary new variants, appended to `reported_as` as printed. Watch for tests that sound alike but aren't: Quest's `HEPATITIS B CORE AB TOTAL` is not Labcorp's `Hep B Core Ab, IgM`.
