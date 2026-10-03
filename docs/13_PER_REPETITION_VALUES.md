# Per-repetition values behind every published spread

**Every spread, range or width this repository publishes is recomputed from the rows below, by
`hack/test/check-published-spreads.sh`, with no archive and no GPU.**

## Why this file exists

A published sentence read `R1`'s five repetitions span 173.579–174.393 ms, a width of **0.8 ms**. Those two
numbers are the row's **first and last** values. The extremes are 171.882 and 175.269, and the width is
**3.387 ms** — the endpoints and the width were both wrong, and the archive's own `readings.txt` had already
printed "spread of 3.9 ms" for the control. A figure that contradicted the tool in the same directory went
out in prose, and nothing in the repository could have caught it: `make docs-check` tests that backticked
names resolve, and the token-unit gate tests wordings. Neither recomputes a number.

The fix is not a sharper reader. It is that **a spread claim has to carry the values it was computed from**,
so a check can do the arithmetic again. That is why the rows are here rather than in a run archive: the
archives are `.gitignore`d, so a check that reads them cannot run in CI, and a local-only gate is one
nobody runs.

## What a block is

One block per published statistic. The header fields are a fixed schema — the checker refuses an unknown
field, a missing one, a duplicate `id`, a repetition id that appears twice, and a value it cannot parse.

- `id` — what a claim cites. Unique across this file.
- `archive` — the run directory the values came from.
- `source` — the exact file and block inside the archive, so a reader can go back to it.
- `arm`, `tenant`, `population` — which rows the statistic was computed over.
- `statistic`, `unit` — what each value is.
- `input_level` — `per-repetition-statistic` means these values are each already a statistic over requests.
  **The checker verifies the range computed FROM them; it cannot verify that each p99 was computed
  correctly from the requests underneath.** Nothing here establishes that.
- `reps` — the repetition ids expected, as a set. A missing or extra one fails.
- `aggregation`, `rounding` — how a claim's displayed figure is derived: compute in decimal, round once at
  the end. The checker never subtracts rounded endpoints.

## Blocks

<!-- spread-block
id: m5c-15cell-r1-premium-ttft-p99
archive: hack/m5c-20261002-014903
source: readings.txt, "Per-repetition premium TTFT p99 (ms)" block, row R1
arm: R1
tenant: premium-1
population: completed premium requests
statistic: TTFT p99
unit: ms
input_level: per-repetition-statistic
reps: 1,2,3,4,5
aggregation: min, max, max-minus-min
rounding: half-up at the displayed decimal place
-->

| rep | TTFT p99 (ms) |
| --- | ---: |
| 1 | 173.579 |
| 2 | 175.269 |
| 3 | 171.882 |
| 4 | 174.268 |
| 5 | 174.393 |

<!-- spread-block
id: m5c-15cell-shared-premium-ttft-p99
archive: hack/m5c-20261002-014903
source: readings.txt, "Per-repetition premium TTFT p99 (ms)" block, row shared
arm: shared
tenant: premium-1
population: completed premium requests
statistic: TTFT p99
unit: ms
input_level: per-repetition-statistic
reps: 1,2,3,4,5
aggregation: min, max, max-minus-min
rounding: half-up at the displayed decimal place
-->

| rep | TTFT p99 (ms) |
| --- | ---: |
| 1 | 3999.396 |
| 2 | 4000.785 |
| 3 | 4002.120 |
| 4 | 3998.261 |
| 5 | 4000.579 |

<!-- spread-block
id: m5c-15cell-timeslicing-premium-ttft-p99
archive: hack/m5c-20261002-014903
source: readings.txt, "Per-repetition premium TTFT p99 (ms)" block, row timeSlicing
arm: timeSlicing
tenant: premium-1
population: completed premium requests
statistic: TTFT p99
unit: ms
input_level: per-repetition-statistic
reps: 1,2,3,4,5
aggregation: min, max, max-minus-min
rounding: half-up at the displayed decimal place
-->

| rep | TTFT p99 (ms) |
| --- | ---: |
| 1 | 14351.471 |
| 2 | 14868.019 |
| 3 | 14873.862 |
| 4 | 14430.285 |
| 5 | 15078.434 |

<!-- spread-block
id: m5c-10cell-r1-premium-ttft-p99
archive: hack/m5c-20261001-023515
source: benchharness report over the archive's raw rows, "Per-repetition premium TTFT p99 (ms)" block, row R1
arm: R1
tenant: premium-1
population: completed premium requests
statistic: TTFT p99
unit: ms
input_level: per-repetition-statistic
reps: 1,2,3,4,5
aggregation: min, max, max-minus-min
rounding: half-up at the displayed decimal place
-->

| rep | TTFT p99 (ms) |
| --- | ---: |
| 1 | 174.078 |
| 2 | 173.832 |
| 3 | 174.297 |
| 4 | 174.387 |
| 5 | 174.034 |

<!-- spread-block
id: m5c-10cell-shared-premium-ttft-p99
archive: hack/m5c-20261001-023515
source: benchharness report over the archive's raw rows, "Per-repetition premium TTFT p99 (ms)" block, row shared
arm: shared
tenant: premium-1
population: completed premium requests
statistic: TTFT p99
unit: ms
input_level: per-repetition-statistic
reps: 1,2,3,4,5
aggregation: min, max, max-minus-min
rounding: half-up at the displayed decimal place
-->

| rep | TTFT p99 (ms) |
| --- | ---: |
| 1 | 3996.117 |
| 2 | 4000.349 |
| 3 | 4000.510 |
| 4 | 3998.338 |
| 5 | 3997.887 |

## Ratios are joined by repetition, not divided as ranges

A published ratio spread is the range of the per-repetition ratios, `range(Aᵢ/Bᵢ)`. It is **not**
`range(A)/range(B)`, and the two are different numbers. The checker computes the first from the blocks above,
pairing by `rep`, and refuses a block pair whose repetition id sets differ.

| ratio | derived from | pairing |
| --- | --- | --- |
| `shared`/`R1` premium TTFT p99, fifteen cells | `m5c-15cell-shared-premium-ttft-p99` ÷ `m5c-15cell-r1-premium-ttft-p99` | by `rep` |
| `timeSlicing`/`shared` premium TTFT p99, fifteen cells | `m5c-15cell-timeslicing-premium-ttft-p99` ÷ `m5c-15cell-shared-premium-ttft-p99` | by `rep` |

## What this file does not establish

| | |
| --- | --- |
| that each p99 is correct | these are per-repetition statistics, not request latencies. The requests underneath are in the archives, and this file cannot recompute them |
| that the values came from the run they name | a copied or edited number is self-consistent. `docs/12_EVIDENCE_CHECKSUMS.md` commits the archive digests; that is the chain which answers this, and it answers it only for a reader who has the archive |
| that every repetition is here | `reps` is declared, so a missing one fails — but a repetition dropped from BOTH the claim and the declaration stays consistent |
| that the spread means what the prose says | 3.4 ms is an observed range over five replays of one trace on one card in one session. It is not a confidence interval and not variation over loads, seeds, cards or sessions |
