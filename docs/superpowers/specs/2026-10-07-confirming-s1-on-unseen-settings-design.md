# Confirming S1 on settings it never saw: the design (stage 3a)

*Drafted 2026-10-07. This is a design, not yet a frozen registration. It records what stage 3 must build before a purchase can be registered, and it buys nothing.*

## What is being confirmed

S1 (`2026-10-07-graph-and-eager-mixed-steps.md`, frozen at `b57c104`) predicts a step's occupancy from two parts:
- non-attention terms fitted on the step-boundary archive;
- 36 × the attention kernel time measured on an A10G for the step's composition.

It passed every judged endpoint on that archive, at its fifth development use. A confirmation must use data it never saw, with nothing refitted.

## Design A or B

Both codex `gpt-6-astra`'s independent design review (2026-10-07) and my own reading favour **B, with old settings embedded as controls**.

| | What it establishes | What it cannot |
|---|---|---|
| A, the same settings, fresh seeds | repeatability and session drift at familiar compositions | generalisation; it re-asks a question S1 was fitted to answer |
| B, unseen settings | whether the step-cost model holds for compositions a simulator would meet and the fit never saw | scheduling, admission waits, inter-step gaps, TTFT and tails, which no step-cost confirmation can |

## Settings for B (proposed; to be fixed in the registration)

Chosen to test S1's weakest assumptions:
- the `u_graph` / `u_eager` boundary at 128 scheduled tokens;
- the f(P) knots and the (256, 512] segment no fold could support;
- decoder counts between 5 and 15;
- several prefills in one step.

| Episode | Settings (tokens) | Tests |
|---|---|---|
| Serial | lengths 128, 129, 255, 257, 384, 511, 512, 513, 1,023, 1,025, 1,536, 2,047, 2,048, 2,049, 4,608, 12,288; caps 1, 16 and 64 | the graph boundary without mixing; both sides of each knot; the interior of (256, 512]; chunking at longer contexts |
| Burst | (size, length) = (4, 32), (5, 32), (5, 384), (8, 384), (15, 384), (8, 1,536), (15, 1,536), (8, 6,144); the control (64, 256) | aggregate prefills of 128 and 160 tokens; several prefills per step; intermediate n |
| Stagger | (8, 6,144, P) for P = 119, 120, 121, 4,200 and 4,201 | steps of 127, 128 and 129 tokens, and final chunks either side of the boundary |
| Stagger | (n, 6,144, P) for n = 5, 15 and P = 384, 1,536; and (8, 1,024, 384) | intermediate decoder counts, new contexts |
| Stagger controls | (1, 256, 256) and (16, 8,192, 8,192) | the case that failed in O1, and the long mixed case |

Unchanged from the step-boundary study:
- the engine configuration and the instrument;
- decoder minimum = cap = 512, late-prefill cap 16;
- the conditioning warm-up and the registered lag and jitter.

Every request fits the 16,384 model length, and concurrency stays within 64.

## Cells and cost

**Nine `-step` cells:** one serial, one burst and one staggered per block, three blocks, distinct frozen seeds, the order balanced across blocks. No logged controls are needed, because the overhead was established by the step-boundary session.

**Estimated time:** the archive's median cells were 757, 594.5 and 3,019 s. The longer proposed traces scale that to about 5.2 hours of warm cells, so about **5.5 to 6 instance hours** on one g5.2xlarge Spot, roughly $4. A separate short g5.xlarge session (about 15 minutes) then times the kernel compositions.

## What must be built (stage 3b)

1. **A new study and episode design in `internal/bench`.**
   - Burst and stagger settings are package globals today. They must become fields of `episodeDesign`, defaulting to today's values, so that every earlier study's traces stay byte-identical. `TestSessionOneTracesAreByteIdentical` and the plan goldens pin that.
2. **Shell support:**
   - the `iv_*` study rules in `hack/lib/instrument-validation.sh`;
   - the nine-cell layout in `hack/m5c-matrix.sh`;
   - the completeness check in `hack/m5c-gpu-session.sh`.
3. **A prediction-only confirmation evaluator.** It must not refit, and it must fix the defects astra found in the development evaluators (file:line in its review):
   - it takes S1's coefficient vector as a frozen literal and fits nothing;
   - an endpoint the design requires but the data lack (a phase never observed, the 128-token boundary not crossed, no multi-prefill step) is **inconclusive and refuses**, never skipped;
   - per-block errors and every endpoint's step error are published, not only the worst means;
   - kernel times are bound to composition contents by a hash, and non-finite times refuse;
   - the rounding of c and K up to the KV block is stated as part of the frozen kernel method.
4. **The kernel-time procedure, frozen before step outcomes are seen.**
   - The compositions are extracted from the fresh step logs by a script that prints no occupancy.
   - The manifest is committed by hash.
   - The kernel session times all of it before the evaluator is run.
   - A composition the session cannot time refuses the confirmation.

## What would invalidate the confirmation

Each of these:
- refitting any coefficient;
- changing a threshold, a bin, the rounding or the 128-token boundary;
- choosing, repeating or adding kernel measurements after seeing step errors;
- dropping a failed endpoint;
- re-buying until it passes.

## Next

Stage 3b builds items 1 to 4 for free, with tests, a kind rehearsal of the session path and independent reviews. Then a registration freezes the settings, seeds, S1's coefficients, the evaluator and the kernel procedure, and the owner is asked to approve the purchase.
