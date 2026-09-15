# HealthLab reports

Patient-portal exports ordered through Lau Medical and performed by HealthLab. Recognise them by the `PERFORMING LAB: HealthLab, …` line near the foot of each page and by the three-column `NAME | VALUE | REFERENCE RANGE` table. None of the Labcorp rules about footnote markers, a Units column or a Previous Result column apply — that layout doesn't exist here.

**One panel per PDF.** The portal exports each ordered panel as its own file, so several PDFs routinely share one Accession ID: one specimen, collected at one moment, split across files. That is expected and is *not* the duplicate case Step 2 warns about. Each PDF still gets its own report note. Stop and ask only when two PDFs share an Accession ID **and** the same panel heading.

---

## Report header

| Report-note field | Where it comes from |
|---|---|
| `lab` | `HealthLab` |
| `specimen_id` | "Accession ID" |
| `collected` | "Collection Date" (`MM/DD/YYYY HH:MM:SS`), written as `YYYY-MM-DDTHH:MM` |
| `received` | "Received" (`MM/DD/YYYY HH:MM:SS`), written as `YYYY-MM-DDTHH:MM` |
| `ordering_physician` | "Ordering Physician", as printed (`LAU, DENNY`) |
| `practice` | the practice name in the top-right header block (`Lau Medical`) |
| `panel` | the panel heading — the line directly above the `NAME`/`VALUE` column headers |

`Requesting Physician` is normally the same person as `Ordering Physician`; when it is, write only `ordering_physician`. When the two differ, add `requesting_physician` as printed.

These reports print no date reported, no fasting state, no ordered-items list and no specimen source, so **`reported`, `fasting`, `ordered_items` and `specimen_source` are omitted** from the report note, and results from these reports carry no `fasting` field either. Don't substitute `received` for `reported`: it's when the lab received the specimen, not when it released the result.

Check the header says **FINAL RESULT**. Anything else goes in the Step 4 review.

**Never copy** patient name, date of birth, age, sex, the `Acc No.` in the patient banner, phone number, street address, or `Lab Ref ID`. The Accession ID is the one identifier kept, because it identifies the specimen.

---

## Result rows

Rows sit under the panel heading, each beginning with a one-letter status column:

```
F         Bilirubin, Total                    1.3 H              0.2-1.2 (mg/dL)
```

- **Status letter** — `F` is a final result. Strip it; it never enters a note. Any other letter is unexplained by these reports: flag it in the Step 4 review and ask before writing the row.
- **`reported_name`** — the NAME column as printed (`Blood Urea Nitrogen`, `eGFRcr (CKD-EPI 2021)`, `CHOL/HDL Ratio`, `NRBC's`). There are no footnote markers to strip here.
- **`panel`** — the panel heading exactly as printed (`LIPID PANEL (AMA) W/LDL CALC`). Take it from the PDF text, not the downloaded file name, which replaces `/` with `_`.
- On a panel that runs to a second page the `NAME  VALUE  REFERENCE RANGE` line reprints under the patient banner. That's a column header, not a row.

### Value and flag

The VALUE cell carries the result and, when abnormal, the flag right after it:

| Printed VALUE | `result` | `value` | `flag` |
|---|---|---|---|
| `6.5` | `"6.5"` | `6.5` | — |
| `51.8 H` | `"51.8"` | `51.8` | `high` |
| `31.7 L` | `"31.7"` | `31.7` | `low` |
| `Non Reactive` | `"Non Reactive"` | — | — |

Trailing letters map as they do under the Labcorp rules: `H` → `high`, `L` → `low`, `A` → `abnormal`, `HH`/`LL`/`AA` or an explicit "Critical" → `critical`. Copy the flag HealthLab printed; never derive one by comparing the value against the range. `result` keeps the printed precision as a quoted string, and `<`/`>` prefixes set `beyond_measurable_range` exactly as under the shared rules.

### Reference range and unit

HealthLab prints both in the one cell, with the unit in trailing parentheses and sometimes a qualifier in front:

| Printed REFERENCE RANGE | `reference_range` | `ref_low` | `ref_high` | `unit` |
|---|---|---|---|---|
| `3.5-10.5 (10'3/uL)` | `"3.5-10.5"` | `3.5` | `10.5` | `10'3/uL` |
| `(Based on documented legal sex) 4.30-5.80 (10'6/uL)` | `"(Based on documented legal sex) 4.30-5.80"` | `4.3` | `5.8` | `10'6/uL` |
| `>40 (mg/dL)` | `">40"` | `40` | — | `mg/dL` |
| `>=60 (mL/min/1.73 m2)` | `">=60"` | `60` | — | `mL/min/1.73 m2` |
| `0-199 (mg/dL)` | `"0-199"` | `0` | `199` | `mg/dL` |
| `0.0-5.0 (.)` | `"0.0-5.0"` | `0.0` | `5.0` | — |
| `No reference range established (10'3/uL)` | `"No reference range established"` | — | — | `10'3/uL` |
| `No Reference Range (mg/dL)` | `"No Reference Range"` | — | — | `mg/dL` |
| `No defined reference range (%)` | `"No defined reference range"` | — | — | `%` |
| `0.0 (%)` | `"0.0"` | — | — | `%` |

- Keep a qualifier such as `(Based on documented legal sex)` in `reference_range` — it's part of what the lab printed — but read the bounds from the numeric interval that follows it.
- `(.)` is HealthLab's placeholder for a unitless ratio: omit `unit`.
- A bare single number (`0.0` for `NRBC's`) is not an interval. Write it as `reference_range` and set no bounds; mention it in the Step 4 review.

### Comments and boilerplate

Free text printed between rows is HealthLab's standing explanation of the test, not a note about this specimen: the ADA HbA1c targets, the NCEP triglyceride table, the Martin/Hopkins LDL-C change and its citations, the B12 normal/indeterminate/deficient ranges, the definition of Immature Granulocytes. It prints on every report of that test, so it is skipped — the same rule the Labcorp section applies to reference tables and methodology. A comment genuinely specific to this specimen still goes in the result note body.

The trailing `Result:` / `Notes:` / `PERFORMING LAB:` lines and the repeated patient banner are page furniture, never rows.

---

## Name matching

HealthLab's names differ from Labcorp's for the same measurement (`Blood Urea Nitrogen` vs `BUN`, `Total Cholesterol` vs `Cholesterol, Total`, `HGB` vs `Hemoglobin`, `TSH` vs `TSH`). Step 3 handles this as it handles any new variant: propose the existing test note and, on approval, append the HealthLab name to its `reported_as`. Expect a long list of these on the first HealthLab report processed, and very few afterwards.
