# Stranding where packing should lose, on a second layout, in counterbalanced order: a registration

Written 2026-10-22, before any cell.
**Registered 2026-10-23 by the owner's approval; frozen from the commit that adds this line, and no cell before it counts.**
Free: local kind clusters, no rented hardware.
Finding 8's six cells and their series stand as published (`docs/11_WHAT_THIS_MEASURED.md`, Finding 8); this is a new campaign with its own protocol version.

## Why

Finding 8 measured one layout, workers advertising 2, 1 and 1 devices, and one submission sequence, where GPU-aware `MostAllocated` packing protected the two-device node and the default scheduler split it in two of three repetitions.
It says itself what it needs before it generalises: a second layout, a demand mix where packing should lose, and an order that can cancel drift, since both arms rendered one cluster name and ran in sequence (`docs/11_WHAT_THIS_MEASURED.md`, "What each finding needs").
Six cells carried no statistic by registration; this campaign fixes its sample count and its test before any cell.

## Why packing can lose, read from the scheduler before any cell

`MostAllocated` over `nvidia.com/gpu` scores a node by its allocated fraction after placement, so it prefers the node a request fills by the larger fraction, not the one left with the most useful remainder.
The default profile does not score `nvidia.com/gpu` at all, so among nodes that fit it chooses by CPU and memory scores and ties, which on identical kind workers behave like a coin, as Finding 8's reference arm varied.

On two workers advertising **3 and 2**:
- **Sequence D2: 1, then 2, then 2.** `MostAllocated` puts the first request on the two-device worker (1/2 against 1/3), the second can then fit only the three-device worker, and the third finds one device free on each: two devices stranded, in every cell. If the first request lands on the three-device worker instead, which the default does about half the time, both twos fit. **Packing should lose.**
- **Sequence D3: 1, then 1, then 3.** `MostAllocated` puts both ones on the two-device worker (1/2, then 2/2), leaving all three on the other for the three-device request. The default strands three devices unless both ones land on the two-device worker, about three times in four. **Packing should win.**

These are read from the scoring rule, not measured on this layout, and the campaign can contradict either.

## Conditions and arms

| condition | layout | sequence | discriminating step | prediction, `S-gpu-most` / `S-default` |
|---|---|---|---|---|
| C1, Finding 8's own | 2, 1, 1 | Finding 8's six submissions | s3, two devices | strands in none / some |
| C2, packing should lose | 3, 2 | 1, 2, 2, then 1 | s3, two devices | strands in every cell / about half |
| C3, packing should win, second layout | 3, 2 | 1, 1, 3, then 1 | s3, three devices | strands in none / about three in four |

The arms are Finding 8's, unchanged: `S-default`, no scheduler configuration installed, and `S-gpu-most`, the mount, resource list and `MostAllocated` strategy together (`hack/stranded-protocol.yaml`, `arms`).
As there, the comparison attributes to supplying that configuration and nothing narrower.
`stranded_devices` is Finding 8's registered figure, `max(f_i) < q ≤ Σf_i` with the witness drawn from pending demand, read at the discriminating step.

## Sample count, order and the test, fixed now

- **12 cells per arm per condition, 72 cells.** Each cell builds its own cluster by the registered build order and deletes it after, so no cell inherits another's state and the arms need not run in sequence.
- **Order:** twelve blocks, each holding all six condition-arm cells once, in an order drawn by Python's `random.Random(20261022)` shuffling the list `C1/S-default, C1/S-gpu-most, C2/S-default, C2/S-gpu-most, C3/S-default, C3/S-gpu-most` once per block:

| block | order |
|---|---|
| 1 | C1/S-gpu-most, C2/S-gpu-most, C1/S-default, C3/S-default, C2/S-default, C3/S-gpu-most |
| 2 | C2/S-gpu-most, C2/S-default, C1/S-default, C3/S-default, C3/S-gpu-most, C1/S-gpu-most |
| 3 | C2/S-default, C3/S-gpu-most, C2/S-gpu-most, C3/S-default, C1/S-gpu-most, C1/S-default |
| 4 | C2/S-gpu-most, C1/S-default, C2/S-default, C3/S-default, C1/S-gpu-most, C3/S-gpu-most |
| 5 | C3/S-gpu-most, C2/S-default, C1/S-default, C2/S-gpu-most, C3/S-default, C1/S-gpu-most |
| 6 | C2/S-gpu-most, C1/S-default, C3/S-default, C3/S-gpu-most, C1/S-gpu-most, C2/S-default |
| 7 | C2/S-default, C3/S-gpu-most, C2/S-gpu-most, C3/S-default, C1/S-gpu-most, C1/S-default |
| 8 | C3/S-gpu-most, C2/S-gpu-most, C2/S-default, C1/S-gpu-most, C3/S-default, C1/S-default |
| 9 | C3/S-gpu-most, C3/S-default, C2/S-default, C2/S-gpu-most, C1/S-gpu-most, C1/S-default |
| 10 | C1/S-gpu-most, C3/S-gpu-most, C2/S-default, C3/S-default, C2/S-gpu-most, C1/S-default |
| 11 | C3/S-default, C2/S-default, C1/S-default, C3/S-gpu-most, C2/S-gpu-most, C1/S-gpu-most |
| 12 | C1/S-gpu-most, C3/S-default, C2/S-gpu-most, C3/S-gpu-most, C1/S-default, C2/S-default |

- **The test, per condition:** the number of cells stranded at the discriminating step, compared between arms by a one-sided Fisher exact test in the predicted direction at 0.05, each condition its own question with no correction across the three, which is stated here so that it is not chosen later.
  At 12 per arm, C1 and C3 reach it when `S-default` strands in at least 4 of 12 and `S-gpu-most` in none; C2 reaches it when `S-gpu-most` strands in 12 of 12 and `S-default` in at most 8.
  If `S-default` strands with probability one half, the power is 0.93; at two thirds it falls to 0.60 in C2, which is the honest weakness of this size.
- **Whatever the tests say, the full series is published**, cell by cell, as Finding 8's was.

## The readings, per condition

- **C2:** "packing lost on this mix" when the test passes in the predicted direction; "packing stranded every time and the default too often to tell apart" when `S-gpu-most` strands in all 12 and the test does not pass; and **"the prediction failed"** when `S-gpu-most` avoids stranding in any C2 cell, with that cell's placements, because the scoring rule above said it cannot.
- **C1 and C3:** "packing removed stranding on this layout and mix" when the test passes; "not distinguished" otherwise; and "the prediction failed" when `S-gpu-most` strands in any cell.
- A sign reversal between C2 and C3 on the same layout is the finding Finding 8 said a different mix could produce, and it is reported only if both C2 and C3 pass.

## Validity

Finding 8's invalidation list, unchanged (`hack/stranded-protocol.yaml`, `invalidates_a_cell`), with the layout check reading `3, 2` or `2, 1, 1` as the condition registers, and one replacement per invalid cell, at most 144 attempts.
The arm is established by `qualify-arm` and the qualification probe in every cell; on the empty `3, 2` layout a one-device probe already separates the arms (1/2 against 1/3), so no holder is needed there, while C1 keeps Finding 8's holder.
A tie, an identical outcome, or a stranding figure of zero does not invalidate a cell, as in Finding 8.

## Building it

- `hack/stranded-protocol-v2.yaml`, version 2: the three conditions, what each predicts, the order above with its seed, and the test. Each condition names its own file, `hack/stranded-protocol-v2/c1.yaml` to `hack/stranded-protocol-v2/c3.yaml`, in the first campaign's schema with its layout, its sequence and 12 repetitions per arm (24 cells, at most 48 attempts), so `check-cell` judges every cell by the first campaign's rules with no second copy of any.
  The layout check keeps its registered reason name, `advertised_capacity_not_2_1_1_at_start`, which in C2 and C3 means the advertised capacity was not 3,2.
- `cmd/strandedrun check-campaign-v2`: refuses a version-1 file by its version; judges each condition's records, kept in a directory of their own and each naming by `protocol_sha256` the file it was performed against, since C2 and C3 share submission names and a misfiled record would otherwise pass, by `check-campaign`'s rules; then the Fisher test, exact from big-integer binomials, with a table-driven test against the values above (12/12 against 8/12 gives 0.0466 and against 9/12 0.1087 one-sided; 4/12 against 0/12 gives 0.0466), and the readings above, including the sign reversal only when both C2 and C3 pass. Each new refusal and reading is pinned by a test that fails when it is removed.
- `hack/test/check-stranded-v2-order.sh`, in `make harness-check`: redraws the twelve blocks from the seed and compares, since Go cannot redraw Python's shuffle and `check-campaign-v2` checks only that each block is a permutation.
- `hack/stranded-cell.sh`: the qualification probe chosen by the condition's layout: Finding 8's holder on `stranded-worker3` for 2,1,1, no holder for 3,2, and a refusal for any other layout.
- `hack/stranded-campaign-v2.sh`: every cell in the registered order on its own fresh cluster, built by the registered steps and deleted after; an invalid attempt is replaced at once, and a second invalidation of one cell stops the campaign.
- A rehearsal of one cell of each condition and arm (`REHEARSE=1`, block 1 only), reported as a rehearsal and not counted.
  Run 2026-10-23 from `e06b570f`, before this line, into `ex/stranded-v2-rehearsal-20261023T030928Z/`: all six cells stood under `check-cell`, each on its own cluster created and deleted by the registered steps, each layout read back as its condition registers, each record naming its own condition's protocol file, and the qualification probe of every `S-gpu-most` cell placed on the two-device worker, with Finding 8's holder only in C1.
  It showed what the harness does, not what the campaign will find, and its stranding figures are not reported.

## Cost and time

No rented hardware.
At about two minutes to build a cluster and three to run a cell, 72 cells take about six hours; the rehearsal measures this, and the order above is not changed if it is slower.
The rehearsal's six cells took 39 to 50 s each, cluster included, so the campaign should take about an hour; nothing above depends on its duration.

## What it does not say, whatever the result

It is three layouts and sequences on simulated devices, not real GPUs or real demand; the treatment is the whole configuration; and a fixed sequence is not an arrival process.
