# Where the mixed-step time goes: diagnostic tables, registered before they are computed

*Registered 2026-10-07. Nothing is fitted and no card is bought. The script is `hack/tail-crossing-model/step_diagnostics.py`.*

## Why tables before another fit

The development study (`2026-10-07-a-mixed-step-family-developed-on-the-seen-archive.md`) found no family within 10%. Its misses are systematic: the three blocks agree to within 0.1 points.

Fitting a fifth family on the same archive would choose its terms from the misses. These tables are computed first, and each states in advance what reading would falsify a hypothesis. The next candidate registration may include only the hypotheses the tables leave standing.

## The data

The same population as the development study:
- the 12 `-step` cells of hack/m5c-20261006-133937;
- steps in exactly one measured episode, from `step_boundary.episodes_of_cell`.

Each step is read from the instrument's own records, joined by its t0:
- **sched** is t0 → t1, the scheduler's `schedule` call;
- **exec** is t1 → t2, model preparation, forward pass and sampling;
- **update** is t2 → t3, `update_from_output`;
- each scheduled request's tokens q and computed tokens c. A decoder's context is c + 1, and K_max is the largest decoder context in the step.

The engine facts these tables use are from the archive's own engine log (`engine-log-serial-step-1.txt`):
- attention backend `FLASH_ATTN`;
- CUDA graph mode `FULL_AND_PIECEWISE`;
- capture sizes 1 to 128 tokens.

So a step of more than 128 scheduled tokens runs without a captured graph.

## The tables, and what each reading means

**T1 — where the time is.** Mean sched, exec and update per exclusive phase (prefill-only, mixed, decode). Also listed for each failing endpoint of candidate B: the six short-late-prefill settings, and the 512-token serial prefill.
- *H-cpu, scheduler or update cost.* Falsified for the misses if sched + update averages under 1 ms in every failing endpoint, because the misses are 8 to 19 ms.

**T2 — mixed steps at fixed shape.** Mixed steps with exactly one prefilling request, grouped by its exact q, by exact n, and by K_max bin ({≤1,024}, (1,024, 4,096], above 4,096). Reported per group: mean exec, mean ΣK, mean K_max, and step count. Groups with fewer than 5 steps are listed and not read.

The reading holds q fixed and takes, for each n, the long-context increment:

Δ(n) = mean exec at K_max above 4,096 − mean exec at K_max ≤ 1,024.

The ratio is Δ(16) / Δ(1). These hypotheses predict it:

| Hypothesis | Predicted ratio for n = 16 against n = 1 | Falsified if |
|---|---|---|
| *H-sum*, decoder context costs per token, as all four candidates assumed (ΣK) | about 16 | the ratio is below 8 |
| *H-max*, decoder context costs once per step, by the longest (K_max) | about 1 | the ratio is above 2 |
| *H-wave*, decoders run in waves of w | about ⌈16/w⌉ | read as the w the ratio implies; w is only described here |

**T3 — pure decode around the graph sizes.**
- Mean pure-decode occupancy by exact n and K/n bin, marking n ≤ 128 (always, here) as graph-eligible.
- The same for mixed steps by their total scheduled tokens T, ≤ 128 against above.
- *H-graph, a step leaving the captured graph pays a fixed cost.* Falsified if mixed steps with T ≤ 128 and T > 128 show no step change beyond what their extra tokens predict along the prefill-only curve of T5. It is not read where no mixed step has T ≤ 128.

**T4 — support for each failing fold.** For each failing composition of candidate B, count the steps in other compositions that share:
- its exclusive phase;
- its f(P) knot segment;
- its n bin and K_max bin.
- *H-support, the 512-token miss is missing training support, not physics.* Read as standing if the 512 serial fold leaves under 100 prefill-only steps in its knot segment (256, 512].

**T5 — prefill-only by size.** Mean prefill-only occupancy by exact P and by chunk position (first, middle, last).

## What the tables decide

Only which hypotheses may enter the next candidate registration.
- A falsified hypothesis does not enter.
- A standing one may, with its feature defined from these records.

No verdict, threshold or result of the development study changes. The archive stays development data and nothing here is a held-out result.

## Result, 2026-10-07

`step_diagnostics.py` at the freezing commit `14c11a3` was run once, on a clean tree. Its output is `data/2026-10-07-mixed-step-diagnostic-tables.txt`.

| Hypothesis | Reading | Verdict |
|---|---|---|
| H-cpu | sched + update is at most 0.398 ms in any failing endpoint | **falsified** |
| H-sum | at q = 256 the long-context increment is 13.267 ms at n = 1, 13.640 at n = 4 and 55.025 at n = 16; ratio 4.15 | **falsified** (below 8) |
| H-max | the same ratio, 4.15 | **falsified** (above 2) |
| H-wave | ratio 4.15 = ⌈16/w⌉ for w about 3.9: one wave at n = 1 and n = 4, four at n = 16 | **standing** |
| H-support | the (256, 512] prefill-only segment has 0 training steps outside the 512-token serial composition | **standing** |
| H-graph | 138 mixed steps ran within the captured sizes, at a mean occupancy of 35.5 ms for 39 tokens. Pure decode at similar sizes takes 16 to 25 ms. | **standing**: a mixed step costs about 15 ms more than a pure-decode step even inside the captured sizes. Candidate B's `u` already carries that. Not "the graph" itself, which both use. |

What the tables also show, outside the registered readings, so as observations for the next registration and not as verdicts:
- **The long-context increment depends on the prefill chunk's size.** At q = 4 and q = 16 it is 0.09 and 0.37 ms. At q = 64 it is 41.8 ms with 16 decoders, and at q = 256 it is 13.3 to 55.0 ms. A late prefill's final 4-token chunk pays almost nothing for long-context decoders.
- **Later prefill chunks cost more per token than first chunks:** 0.1285 against 0.1078 ms per token at 2,048, and 0.1235 against 0.1113 at 1,024. The family's `h·H` term is for this.
- The 512-token miss cannot be judged by leave-one-composition-out on this archive: no other composition puts a prefill-only step in its segment.
