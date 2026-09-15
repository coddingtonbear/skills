---
name: lab-results
description: >-
  Turns Labcorp and HealthLab lab-result PDFs into one note per measurement
  (plus a note per report and per test) under permanent/lab-results/ in the
  Obsidian vault, renaming each PDF to the vault's convention on the way in, so
  results can be tabled and charted over time with Obsidian Bases. Use when
  asked to process, import, extract or rename a lab result PDF, or to find lab
  reports that haven't been processed yet.
---

**Goal:** Every lab report PDF in the vault has a report note beside it, one result note per measurement it contains, and each result links to a test note that collects that test's history.

**Requirements:** Obsidian MCP tools for every vault read, write and move. PDFs are the two exceptions: the MCP can't read their contents, so read them from disk with the Read tool at the vault root (`~/Documents/Notes`), and it can't reach outside the vault at all, so a PDF still sitting in `~/Downloads` is moved in with a plain shell `mv`. Follow **obsidian-formatting** for anything written into a note body. Trend charts on test notes also need the SQLSeal and SQLSeal Charts plugins and the globals listed in [trend-chart.md](trend-chart.md).

**Not medical advice:** copy what the report says. Never compute a flag, judge a value, or add interpretation of your own.

---

## Layout

```
permanent/lab-results/
  Lab Results.base
  reports/   <stem>.pdf + <stem>.md    one report note per PDF, same file name
  results/   YYYY-MM-DD <Test>.md      one note per measurement
  tests/     <Test>.md                 one note per kind of test
```

- **Report** — one PDF: one specimen, collected at one time.
- **Result** — one measured value from one report.
- **Test** — a kind of measurement ("LDL Cholesterol"), regardless of date. It collects results from many reports.

Every link written by this skill uses the full path with display text, because short names like "Iron" can collide with other notes in the vault:

```yaml
test: "[[permanent/lab-results/tests/LDL Cholesterol|LDL Cholesterol]]"
```

---

## Lab profiles

Two providers, two layouts. Identify which before extracting anything — the header fields, the result table and the footnote conventions all differ, and running one lab's rules over the other's PDF produces wrong values silently.

| Provider | Recognise it by | Parsing rules |
|---|---|---|
| Labcorp | "Patient Report" heading; `Test │ Current Result and Flag │ Previous Result and Date │ Units │ Reference Interval` table; a "Performing Labs" key | Step 2 below |
| HealthLab | `PERFORMING LAB: HealthLab, …` at the foot of each page; three-column `NAME │ VALUE │ REFERENCE RANGE` table | [healthlab.md](healthlab.md) |

Anything matching neither: stop and ask the user. Don't approximate.

The steps, the note templates, the `results`/`tests`/`reports` layout, the value-parsing semantics under "Parsing values" and the review gate are shared by both. Each profile only supplies where the header fields come from and how a result row is read.

---

## File naming

A report PDF is named `YYYY-MM-DD_<Primary>[-plusN].pdf`, where the date is the **collection** date, `<Primary>` names what was ordered, and `N` counts the other ordered items. The report note takes the same stem.

The convention is Labcorp's own export naming, which is why a Labcorp download already complies — leave its name alone. Other providers name files their own way, so their PDFs are renamed before being written into the vault.

- **`<Primary>`** — Labcorp: the first entry in `ordered_items`. HealthLab: the panel heading. Turn spaces, `/`, `,` and `.` into `-`, drop the rest of what a file name can't hold (`\ : * ? " < > | # ^ [ ]`) along with parentheses, then collapse repeated `-`. So `Comp. Metabolic Panel (14)` → `Comp-Metabolic-Panel-14`, `CBC/Diff Ambiguous Default` → `CBC-Diff-Ambiguous-Default`, `Testosterone, Free, Direct` → `Testosterone-Free-Direct`.
- **Capitalisation** — keep the source's own, except for a heading printed in all capitals: title-case that one, leaving acronyms capitalised. `LIPID PANEL (AMA) W/LDL CALC` → `Lipid-Panel-AMA-W-LDL-Calc`.
- **`-plusN`** — only when the lab lists ordered items and there is more than one; `N` is that count less the primary. HealthLab exports one panel per PDF and lists no ordered items, so its names never carry the suffix.
- **Never take the date from the downloaded file name.** Provider suffixes lie: a file arriving as `… __101024.pdf` proved to have been collected 2024-09-30. The collection date comes from inside the PDF, always.
- Renaming a PDF that already has a report note means renaming both and rewriting the `pdf` link and the embed, so get the name right at Step 4.

Existing report notes keep the names Labcorp gave them, off-by-one `-plusN` and all. Don't regenerate them.

---

## Step 1: Decide what to process

- **Targeted:** the user names a PDF. Process that one.
- **Sweep:** process every PDF that is either
  - a fresh download in `~/Downloads` the user has pointed at,
  - directly in `permanent/lab-results/` (a new download), or
  - in `reports/` with no `.md` of the same name beside it.

A PDF in `~/Downloads` is read in place, named per "File naming" above, and `mv`d into `permanent/lab-results/` once its extraction is approved in Step 4. Read every candidate's collection date before ordering the batch; the file names can't be trusted for it.

A PDF sitting directly in `permanent/lab-results/` moves into `reports/` (`vault_move` with destination `permanent/lab-results/reports/`) once its extraction is approved in Step 4. Never move a PDF before that.

Process one PDF at a time, oldest collection date first, completing Steps 2–5 for each before starting the next.

If the PDF already has a report note (a targeted re-run), say so and ask before replacing anything. When approved, update the existing notes in place rather than creating new ones.

---

## Step 2: Extract

Read the whole PDF and identify the provider against the "Lab profiles" table. Stop and ask the user if it matches neither.

**The rest of this step describes Labcorp's layout only.** For a HealthLab report, use [healthlab.md](healthlab.md) instead and rejoin the flow at "Parsing values"; everything from Step 3 on is shared.

### Report header

| Report-note field | Where it comes from |
|---|---|
| `lab` | `Labcorp` |
| `specimen_id` | "Specimen ID" |
| `collected` | "Date Collected" plus its time from "Specimen Details" (`MM/DD/YYYY HHMM Local`), written as `YYYY-MM-DDTHH:MM` |
| `reported` | "Date Reported", as `YYYY-MM-DD` |
| `fasting` | "Fasting": `Yes` → `true`, `No` → `false`, `Not Given` → `unknown`. A "Clinical Info: Fasting: 14 hours"-style line makes it `true`; "Clinical Info: Fasting: Unknown" keeps it `unknown`. |
| `ordering_physician` | "Ordering Physician", as printed |
| `practice` | The first line under "Physician Details" after the physician's name |
| `specimen_source` | "Clinical Info: SRC:…" when present (`SRC:Serum` → `Serum`, `SRC:ST` → `Stool`); omit otherwise |
| `ordered_items` | "Ordered Items", split on `;`, as printed |

Check the page footer says **Final Report**. If it says anything else (preliminary, corrected, amended), point that out in the Step 4 review.

Before extracting, search `reports/` for a note with the same `specimen_id`. If one exists, stop and tell the user: it's either a duplicate download or an amended report, and the user decides which. (HealthLab is the exception — it splits one specimen across several PDFs on purpose; see [healthlab.md](healthlab.md).)

**Never copy** patient address, phone, date of birth, age, patient ID, account numbers, control IDs, physician IDs or NPIs into any note. The specimen ID is the one identifier kept, because it identifies the report.

### Result rows

Results come from the tables headed `Test | Current Result and Flag | Previous Result and Date | Units | Reference Interval`, grouped under a panel heading. A heading ending in `(Cont.)` continues the panel from the previous page.

For each row:

- **`reported_name`**: the Test column with its trailing footnote markers removed. Markers are the performing-lab code (a two-digit number listed under "Performing Labs", e.g. `01`) optionally preceded by a comment letter (`A, 02`). They're often glued to the name (`BUN01`). Strip a trailing number only if it matches a listed performing-lab code; if a name could legitimately end in those digits, keep it and point it out in the review. Names can wrap onto a second line (`Sex Horm Binding Glob,` / `Serum01`); join them.
- **`panel`**: the panel heading, without `(Cont.)`.
- **Result, flag, units, reference interval**: see "Parsing values" below.
- **Comments**: free text printed under a row (e.g. "Specimen received hemolyzed.") goes in that result note's body. General explanations that print on every report of that test (reference tables, methodology, citations, "Prediabetes: 5.7 - 6.4" notes) are skipped.

### What never becomes a result

- The **Previous Result and Date** columns: they repeat other reports' values.
- **Historical Results & Insights** chart pages and **Cardiovascular Tests** history tables: also other reports' values.
- Administrative rows: `Ambig Abbrev … Default`, `Interpretation` / `Note`, `PDF` / `.`, `Please Note:`, `Venipuncture`.
- Rows with no result at all.

### Litholink pages

Some reports append a Litholink "Cardiovascular Report" (pages headed "Litholink Patient Results Report"). Its "Current Laboratory Results" tables repeat most main-report values under other names (`LDL(calc)`, `HDL-C`, `AST`, `Protein, Total, Serum`), often more than once.

From these pages, extract **only analytes that don't appear anywhere in the main report**. In practice that's `Anion Gap` and `non-HDL cholesterol`. Their `panel` is `Cardiovascular Report`. When unsure whether a Litholink name is the same test as a main-report row, treat it as the same test and leave it out, and mention it in the review. A duplicate point on a chart is worse than a missing one.

### Culture and narrative results

When the result cell says `Final report` and the actual finding is a sentence on a following `Result 1` row ("No Campylobacter species isolated."), that is one result: `reported_name` is the parent row's name (`Campylobacter Culture`), and `result` is the sentence. Explanatory text about the method ("These results were obtained using…") is skipped.

---

## Parsing values

### Result

`result` is always the result exactly as printed, as a quoted string (`"1.20"`, `"<3.1"`, `"Non Reactive"`). It keeps precision a YAML number would lose (`1.20` → `1.2`).

| Printed | `value` | `beyond_measurable_range` |
|---|---|---|
| `5.4` | `5.4` | — |
| `<3.1` | `3.1` | `below` |
| `>1500` | `1500` | `above` |
| `Negative`, `Non Reactive`, a sentence | — | — |

Omit a field rather than writing it empty or `null`.

### Flag

Copy the flag Labcorp printed; never derive one from the value and reference range.

| Printed | `flag` |
|---|---|
| `High`, `H` | `high` |
| `Low`, `L` | `low` |
| `Abnormal`, `A` | `abnormal` |
| `HH`, `LL`, `AA`, panic `<` / `>`, "Critical" / "Alert" | `critical` |

### Units and reference interval

`unit` is the Units column as printed, even when it looks truncated (`mL/min/1.73`). Omit it when blank.

`reference_range` is the Reference Interval as printed. Also set numeric bounds when the interval is parseable:

| Printed | `ref_low` | `ref_high` |
|---|---|---|
| `3.4-10.8` | `3.4` | `10.8` |
| `>59` | `59` | — |
| `<5.0` | — | `5.0` |
| `Immunity>9.9` | `9.9` | — |
| `Not Estab.`, `Negative`, `Non Reactive`, blank | — | — |

---

## Step 3: Match each result to a test note

Every note in `tests/` has a `reported_as` list of the Labcorp names it covers. For each result:

1. Compare `reported_name` against every test note's `reported_as`, ignoring case and repeated whitespace. An exact match is the test.
2. No match: never guess silently. Propose either an existing test note (when the name is clearly a variant, e.g. `Protein, Total` vs `Protein, Total, Serum`) or a new test note, and let the user decide in Step 4.

New test note names are readable and specific ("Hepatitis C Antibody", not "Hep C Virus Ab"). File names can't contain `/ \ : * ? " < > | # ^ [ ]`: write `BUN-Creatinine Ratio`, not `BUN/Creatinine Ratio`.

---

## Step 4: Review with the user

Before writing anything, show the user:

1. **Name**: the file name the PDF will take, when it isn't already correct, and the name it arrived with.
2. **Header**: the report-note fields from Step 2, plus any footer that isn't "Final Report".
3. **Results table**: test note (marked *new* where applicable), reported name, panel, result, unit, reference range, flag, beyond measurable range, and any comment going in the body.
4. **Name matching**: every proposed new test note, and every proposed match of a new name variant to an existing test.
5. **Skipped rows**: each one with its reason, including every Litholink row left out as a duplicate.

Wait for approval. Apply corrections and show the changed rows again. During a multi-PDF sweep the user may say "approve all remaining": keep showing each table, but continue without waiting.

---

## Step 5: Write

Write in this order. The report note goes **last** because its existence is what marks a PDF as processed, so an interrupted run gets picked up again by the next sweep.

1. **Move the PDF** into `reports/` if it isn't there already, renaming it to the approved name at the same time. A PDF coming from `~/Downloads` is `mv`d with the shell; one already inside the vault moves with `vault_move`.
2. **Test notes**: create each approved new test note (template below). For an approved new name variant on an existing test note, append it to `reported_as` with `vault_patch` (frontmatter target, `append`).
3. **Result notes**: one per result, at `results/YYYY-MM-DD <Test>.md`, where the date is the date part of `collected`.
   - If a note at that path already links this same report, it's from an interrupted earlier run: replace it.
   - If a note at that path belongs to a different report (two reports on the same day both measured the test), use `results/YYYY-MM-DD <Test> <specimen_id>.md` instead.
4. **Report note** at `reports/<PDF stem>.md`.

If the user later corrects a report note's `fasting`, update `fasting` on every result that links that report. The report note is the source of truth.

### Result note

```markdown
---
test: "[[permanent/lab-results/tests/Hemoglobin A1c|Hemoglobin A1c]]"
reported_name: Hemoglobin A1c
panel: Hemoglobin A1c
collected: 2025-01-15T08:30
result: "5.4"
value: 5.4
unit: "%"
reference_range: "4.8-5.6"
ref_low: 4.8
ref_high: 5.6
fasting: true
report: "[[permanent/lab-results/reports/2025-01-15_Hemoglobin-A1c|2025-01-15_Hemoglobin-A1c]]"
---
Specimen received hemolyzed. Clinical correlation indicated.
```

Fields that don't apply (`value`, `beyond_measurable_range`, `unit`, `ref_low`, `ref_high`, `flag`) are omitted. The body is empty unless the row had a comment.

### Report note

```markdown
---
lab: Labcorp
specimen_id: 000-000-0000-0
collected: 2025-01-15T08:30
reported: 2025-01-16
fasting: true
ordering_physician: A SMITH
practice: Example Clinic
specimen_source: Serum
ordered_items:
  - Hemoglobin A1c
  - Lipid Panel
pdf: "[[permanent/lab-results/reports/2025-01-15_Hemoglobin-A1c.pdf|2025-01-15_Hemoglobin-A1c.pdf]]"
---
![[permanent/lab-results/reports/2025-01-15_Hemoglobin-A1c.pdf]]
```

### Test note

Created with the Labcorp name that prompted it; the embedded base lists every result that links to the note. When the test has a non-zero numeric result, the `# Trend` section from [trend-chart.md](trend-chart.md) goes between the frontmatter and `# History`; the template below shows a test with none.

````markdown
---
reported_as:
  - Hemoglobin A1c
---
# History

```base
filters:
  and:
    - file.inFolder("permanent/lab-results/results")
    - file.hasLink(this.file)
views:
  - type: table
    name: History
    order:
      - collected
      - result
      - unit
      - reference_range
      - flag
      - beyond_measurable_range
      - fasting
      - report
```
````

---

## Step 6: Report back

Tell the user which PDFs were processed and what each was renamed to, how many result notes each produced, which test notes were created or given new name variants, which test notes got a trend chart, and anything flagged along the way (non-final reports, possible duplicate specimen IDs, uncertain footnote stripping).
