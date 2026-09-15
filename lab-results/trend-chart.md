# Trend chart

A test note gets a `# Trend` section, directly above `# History`, once any of its results has a non-zero numeric `value`. Tests whose results are all qualitative (screens, cultures) or all zero get no Trend section; their History table is enough.

The block is identical on every test note and is copied verbatim, never edited per test. Its query finds the note's results by matching each result's `test` link against the note's own path (`@path`).

---

## Requirements

The chart needs the **SQLSeal** and **SQLSeal Charts** plugins, plus these global configurations under SQLSeal Charts settings → Global configurations. A chart that references a missing global renders an error instead of falling back to defaults, so check these first when a chart is reported broken.

| Global | Controls |
|---|---|
| `labAxisLine` | axis lines and tick marks |
| `labAxisLabel` | axis numbers, dates and the unit title |
| `labSplitLine` | grid lines |
| `labReferenceArea` | the reference-range band |
| `labResultLine` | the result line |
| `labResultLabel` | the printed-result label on each point |
| `labPointColor` | point (and label) color, keyed by `flag`, `none` when unflagged |
| `labPointSymbol` | point shape, keyed by `beyond_measurable_range`, `within` otherwise |
| `labPointRotation` | point rotation, same keys as `labPointSymbol` (flips the triangle for `below`) |

Styling lives in the globals, so restyle there rather than in every test note. Two limits of SQLSeal Charts decide what can move into a global: a global replaces a whole value (the chart parser has no spread), and it can't hold a function (globals are parsed as JSON5). That is why the tooltip formatter, the point callbacks and the unit-based axis name stay in the block.

Colors are mid-tones or translucent greys because the chart draws on a canvas that can't read Obsidian's theme variables; these values stay legible on both light and dark themes.

---

## What the block handles

- **Exact test match.** The note's results are found by comparing the start of each result's `test` link with `[[<this note's path>|`. Not `LIKE`: test names such as `Basophils (%)` contain `%`, a `LIKE` wildcard, which would pull in `Basophils (Absolute)` results too.
- **Zeros don't plot.** SQLSeal stores every falsy frontmatter value as NULL, so `value: 0` looks the same as a missing value and that result is left off the chart; a test whose results are all zero would show a chart error instead, which is why such tests get no Trend section until a non-zero result arrives. Accepted as a SQLSeal quirk rather than worked around by parsing `result`. `ref_low: 0` is lost the same way, which is harmless because a missing lower limit already means 0.
- **Numbers arrive as text.** SQLSeal creates every column of its `files` table with type `TEXT`, so SQLite converts numeric frontmatter to text as it's inserted, and `MAX` then compares strings (`"89"` beats `"110"`). Anything compared is cast to `REAL` first.
- **Reference band.** Stacked from `band_low` up by `band_span`, stepped so a changed reference interval shows where it changed.
  - Two-sided range: `ref_low` to `ref_high`.
  - Lower limit only (`>59`): from the limit to 10% above the highest result.
  - Upper limit only: from 0 to the limit.
  - Neither (`Not Estab.`): no band.
  - A band needs at least two results to be visible.
- **Beyond measurable range.** `<3.1` / `>1500` plot at the limit as a triangle, ▲ above and ▼ below, still labeled with the printed result.
- **Flags.** Point and label color come from `labPointColor[flag]`; the tooltip appends the flag.
- **Axes.** X is a true time scale, so uneven gaps between reports keep their proportions; Y doesn't start at zero.

---

## Block

````markdown
# Trend

```sqlseal
CHART {
  tooltip: {
    trigger: 'item',
    formatter: (p) => `${p.data.collected_label}<br/>${p.data.result} ${p.data.unit}${p.data.flag_note}<br/>Reference ${p.data.reference_range}`
  },
  grid: { left: 56, right: 24, top: 40, bottom: 32 },
  xAxis: { type: 'time', axisLine: labAxisLine, axisTick: labAxisLine, axisLabel: labAxisLabel, splitLine: labSplitLine },
  yAxis: { type: 'value', scale: true, name: unit[0], nameTextStyle: labAxisLabel, axisLabel: labAxisLabel, splitLine: labSplitLine },
  series: [
    {
      name: 'Reference low',
      type: 'line',
      encode: { x: 'collected', y: 'band_low' },
      stack: 'reference',
      step: 'end',
      symbol: 'none',
      lineStyle: { opacity: 0 },
      silent: true,
      tooltip: { show: false }
    },
    {
      name: 'Reference range',
      type: 'line',
      encode: { x: 'collected', y: 'band_span' },
      stack: 'reference',
      step: 'end',
      symbol: 'none',
      lineStyle: { opacity: 0 },
      areaStyle: labReferenceArea,
      silent: true,
      tooltip: { show: false }
    },
    {
      name: 'Result',
      type: 'line',
      encode: { x: 'collected', y: 'value' },
      symbol: (v, p) => labPointSymbol[p.data.range_position],
      symbolRotate: (v, p) => labPointRotation[p.data.range_position],
      symbolSize: 9,
      lineStyle: labResultLine,
      itemStyle: { color: (p) => labPointColor[p.data.flag_status] },
      label: labResultLabel
    }
  ]
}
SELECT
  collected,
  replace(collected, 'T', ' ') AS collected_label,
  result,
  value,
  unit,
  COALESCE(reference_range, 'not given') AS reference_range,
  COALESCE(' (' || flag || ')', '') AS flag_note,
  COALESCE(flag, 'none') AS flag_status,
  COALESCE(beyond_measurable_range, 'within') AS range_position,
  CASE WHEN ref_low IS NULL AND ref_high IS NULL THEN NULL
    ELSE COALESCE(CAST(ref_low AS REAL), 0) END AS band_low,
  CASE WHEN ref_low IS NULL AND ref_high IS NULL THEN NULL
    ELSE COALESCE(CAST(ref_high AS REAL), MAX(MAX(CAST(value AS REAL)) OVER (), CAST(ref_low AS REAL)) * 1.1) - COALESCE(CAST(ref_low AS REAL), 0) END AS band_span
FROM files
WHERE path LIKE 'permanent/lab-results/results/%'
  AND substr(test, 1, length(@path)) = '[[' || substr(@path, 1, length(@path) - 3) || '|'
  AND value IS NOT NULL
ORDER BY collected
```
````

---

## Global values

The values these globals held when the charts were designed, for recreating them in another vault:

`labAxisLine`

```json5
{
  "lineStyle": {
    "color": "rgba(128, 128, 128, 0.6)"
  }
}
```

`labAxisLabel`

```json5
{
  "color": "rgba(128, 128, 128, 1)"
}
```

`labSplitLine`

```json5
{
  "lineStyle": {
    "color": "rgba(128, 128, 128, 0.2)"
  }
}
```

`labReferenceArea`

```json5
{
  "color": "rgba(80, 180, 120, 0.2)"
}
```

`labResultLine`

```json5
{
  "color": "#4f9dde",
  "width": 2,
  "type": "solid"
}
```

`labResultLabel`

```json5
{
  "show": true,
  "position": "top",
  "color": "inherit",
  "textBorderWidth": 0,
  "fontWeight": "bold",
  "formatter": "{@result}"
}
```

`labPointColor`

```json5
{
  "none": "#4f9dde",
  "high": "#e0645a",
  "low": "#e0645a",
  "abnormal": "#e0645a",
  "critical": "#d13d3d"
}
```

`labPointSymbol`

```json5
{
  "within": "circle",
  "above": "triangle",
  "below": "triangle"
}
```

`labPointRotation`

```json5
{
  "within": 0,
  "above": 0,
  "below": 180
}
```
