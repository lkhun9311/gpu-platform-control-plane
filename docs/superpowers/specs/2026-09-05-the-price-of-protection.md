# What protection costs — pre-registration

Date: 2026-09-05 · Pre-registered **before** the run is bought. Nothing here may be edited after the run.
Supersedes `2026-09-04-m5b-pilot-stopping-rule.md`, whose question (does the KV guard see anything?) was
answered by the free re-scoring: it does not, and the threshold it needs is structurally unreachable at this
load.

## Why this exists

M5-b has one measured, reproduced result and one unmeasured half.

The measured half: reactive KV-occupancy shedding did not protect the premium tail — 83.7x against a
pre-registered 1.25x, four repetitions, isolation control at 1.0x. The engine-level microtest then showed a
scheduler configuration holding the same interference to 1.57x with no gateway involved.

The unmeasured half is what those numbers cost. Re-scoring the already-paid 2026-09-03 evidence with
throughput and per-tenant share — no new spend — gives:

| arm | premium TTFT p99 | output tok/s | premium share | noisy share |
| --- | ---: | ---: | ---: | ---: |
| R1 (isolated) | 82.2 ms | 46.4 | 100% | — |
| off | 10,595.3 ms | 57.3 | 80% | 20% |
| static-cap | 81.2 ms | 46.3 | 100% | 0% |
| kv-aware | 6,882.0 ms | 55.7 | 83% | 17% |

`static-cap` matched isolation's latency **and** isolation's throughput, because it did not make the engine
efficient — it deleted the long tenant. `off` served 24% more tokens than the arm that "won" on tail. Every
check the report made was a tail ratio, so this was invisible for four paid runs.

The question this run asks is therefore not "can the tail be protected" — two arms already did that, one by
discarding all contending work. It is:

> **Is there a configuration that protects the premium tail without deleting the contending tenant's work,
> and what does it cost the tenant it protects?**

## Design

Engine-level, no gateway. The gateway's admission guard is not an arm here: its own evidence says it cannot
observe the pressure it gates on, and a milestone that adds a control plane on top of a misconfigured engine
is measuring the wrong layer. What a gateway adds on top of a *correctly configured* engine is a later
question, and this run is what would make it askable.

**Factors.** Batch budget `max_num_batched_tokens` ∈ {256, 512, 1024, 2048} × scheduling policy ∈ {fcfs,
priority}. Eight cells. The microtest measured three budgets at two policies and found the interaction
non-monotone — 1.57x at 512, 4.85x at 2048, 11.83x at 8192 — so 8192 is dropped (both policies degenerate
there) and 256 is added below the only cell that worked, because the pattern between 512 and 2048 is
unexplained and one point on either side of it is worth more than a fourth point above.

**Load.** Not the microtest's two requests. Two offered loads, both open-loop arrival processes with many
concurrent prefills, since the two-request result cannot speak to a p99:

- **L1 — the 2026-09-03 trace**, unchanged, so this run is comparable to the paid evidence above.
- **L2 — the same trace at half the noisy arrival rate**, to separate "this configuration protects" from
  "this configuration only protects when the offered load is what it happens to be".

**Control.** `fcfs` at the engine's own default budget, which is what an operator who configures nothing
gets. It is the arm every other cell must beat, and it is not the isolated baseline: R1 is measured too, as
the ceiling.

**Repetitions.** 3 per cell per load. The bootstrap resamples repetitions, so the repetition count is the n
of the only interval reported; 3 is the floor at which the 2.5/97.5 percentiles are not simply the range.

## What every arm must report

Both halves, for every cell, or the cell is not scored:

1. premium TTFT p50/p95/p99, with the tail sample size beside it
2. **aggregate output tokens per second, over the summed per-repetition spans**
3. **output tokens by tenant** — the share that separates protection from deletion
4. **TPOT p50/p99** — a guard that protects the first token and wrecks the stream after it must not pass
5. the engine's resolved startup configuration, captured from its own log, not from the flags we passed

Items 2–4 did not exist for the first four paid runs. They exist now and are fault-injected.

## Pre-registered readings

Evaluated in this order against **L1**; L2 then decides whether the finding is a configuration or a
coincidence. The first reading that fires is the answer. The readings are written so that each is decidable
from the table above without reference to any other, which is the defect that made the microtest's
pre-registration unusable.

### 1. Protection without deletion — POSITIVE, and this is the deliverable

A cell fires this if **all four** hold against the `fcfs`-at-default control:

- premium TTFT p99 at or below **2x** the isolated R1 baseline, and
- noisy tenant's output-token share at or above **75% of its share under `off`**, and
- aggregate output tok/s at or above **95% of `off`'s**, and
- premium TPOT p99 no more than **1.25x** R1's.

The first two are the point: a tail held without the contending tenant losing its work. The third and fourth
exist because "protection" that costs a quarter of the machine's throughput, or that pays for a fast first
token with a slow stream, is a different trade being reported as the same one.

If more than one cell fires, the answer is the cell with the highest noisy share; ties go to the smaller
budget, because a smaller budget is the cheaper thing to operate.

### 2. Protection only by deletion — NEGATIVE, and M5-b closes here

If every cell that meets the p99 bar fails the noisy-share bar, then on this model, this GPU and this load,
holding the premium tail requires discarding the contending tenant's work — which the gateway's static cap
already does, more simply, at the control plane. There is nothing an engine configuration adds, and the
milestone's finding is that the protection/throughput trade at this scale is not a control-plane problem.

That is a publishable negative with a measured explanation, and it is the second-best outcome here, not a
failure of the run.

### 3. No cell beats the control — INCONCLUSIVE, do not spend again on this design

If no cell improves premium p99 by more than the control's own repetition-to-repetition spread, the factors
do not have a lever on this load. The next step is a different load or a different engine, not another
sweep of the same two knobs.

### 4. The load did not create contention — INVALID, no card time on this trace again

If the control's premium p99 is under 5x R1's, the trace is not producing the interference the run exists to
study, and every cell is comparing configurations under a load that has no problem to solve.

## L2's role, stated in advance

L2 does not get its own readings. It answers one question about whatever L1 concludes: **does the winning
cell still fire reading 1 at half the noisy arrival rate?** If yes, the finding is a configuration. If no,
the finding is that the configuration is tuned to one offered load and the write-up says so in its first
sentence.

## Budget

| stage | cost | gate |
| --- | ---: | --- |
| harness development | $0 | done — `stub-serve`, re-scored paid evidence |
| pilot: control + the 512/priority cell, L1, 1 rep | $0.65 | reading 4 must not fire |
| confirmatory: 8 cells × 3 reps, L1 | $3.45 | readings evaluated |
| L2: winning cell + control, 3 reps | $3.45 | only if reading 1 fired |
| unspent reserve | $2.45 | — |

A standalone Spot g5.xlarge in a public subnet measured $0.65/h effective, with no NAT data charge. The
pilot exists so that reading 4 — the failure mode that wastes the whole run — costs 65 cents to detect.

## What this run cannot say

It measures one model on one GPU at one prompt-size distribution. It cannot say the winning budget is the
right budget elsewhere, and the microtest's non-monotone result is a standing warning that it will not
transfer by interpolation. It also measures no gateway, so it says nothing about what a control plane adds —
it only makes that question askable against a baseline that is not misconfigured.
