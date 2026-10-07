# Decoder waves in a mixed step: a second development tournament

*Registered 2026-10-07, before any candidate below is fitted. No card is bought. The evaluator is `hack/tail-crossing-model/step_family_waves.py`.*

## Why these candidates and no others

The diagnostic tables (`2026-10-07-where-the-mixed-step-time-goes-diagnostic-tables.md`) were registered with their readings before they were computed.
- **Falsified:** that the misses are scheduler cost; that decoder context costs per token (ΣK, which every earlier candidate assumed); and that it costs once per step, by the longest context.
- **Standing:** decoder waves. At a 256-token prefill chunk, the long-context increment was 13.3 ms with 1 or 4 decoders and 55.0 ms with 16, which is ⌈16/w⌉ for w about 3.9.

The mechanism this suggests is not established by those tables. When a step mixes a prefill with decoders, FlashAttention's variable-length kernel gives each decoder's head its own block, which walks the whole context. The A10G has 80 SMs and Qwen2.5-3B has 16 query heads, so about five decoders run at once. The candidates test the shape, not that mechanism.

## The candidates, all of them

Each is candidate B of the first development study:
`c + f(P) + d1·n + d2·n² + m·P·n + h·H + k_pure·K·[P=0] + k_mixed·K·[P>0] + u·[P>0, n>0]`

plus one wave column v·V, where:
- K_max is the step's largest decoder context (computed + 1);
- q_max is the largest number of tokens scheduled for any prefilling request in the step.

| | V | Why |
|---|---|---|
| W4 | ⌈n/4⌉ · K_max · [P>0, n>0] | waves of four, the w the tables read (3.9) |
| W5 | ⌈n/5⌉ · K_max · [P>0, n>0] | waves of five, from 80 SMs / 16 heads |
| W4g | W4's V, only when q_max > 16 | the tables showed almost no long-context increment at q = 4 and q = 16 (0.09 and 0.37 ms) |
| W5g | W5's V, only when q_max > 16 | the same |

Candidate B is fitted and reported again beside them as the reference. It cannot be selected: it has already failed.

## The test and the fit

They are the first development study's, unchanged:
- squared relative error, with equal weight per (setting, exclusive phase);
- leave one composition out;
- an endpoint fails beyond ±10% on its mean or 15% on its mean |step error|;
- 10-step floor and 10% unjudged limit;
- condition limit 100;
- fewest columns among passes (here all four have 13), ties to the earlier row of the table above;
- the all-data fit is the predictor.

**One rule is added, and it is adaptive.** I add it after seeing the 512-token serial fold fail, and say so.
- An endpoint is **unsupported** when its fold's training data has no step of its exclusive phase in its f(P) knot segment. Without such a step, the segment's slope is not identified by the training data, and the fold measures extrapolation, not the model.
- Unsupported endpoints are published and not judged, and they count toward the 10% unjudged limit with the under-floor ones.
- The diagnostic tables found exactly this for the three 512-token serial endpoints: 0 training steps in the (256, 512] segment. Those endpoints say nothing either way.

## Stopping, and what a selection licenses

- **Runs:** one, at the freezing commit.
- **If none passes:** the waves hypothesis, as these four shapes, does not produce a family within the bounds on this archive.
- **If one passes:** it licenses registering a confirmation on fresh cells, bought only with the owner's approval. Those cells must include:
  - a prefill-only step in (256, 512];
  - n between 5 and 15 beside long contexts. The archive holds those only inside burst-16 episodes.

This archive has now been used by three registrations. Nothing it gives is a held-out result.

## Result, 2026-10-07 — no wave candidate passes

`step_family_waves.py` at the freezing commit `511474a` was run once, on a clean tree. It exited 3. Its output is `data/2026-10-07-decoder-waves-tournament.txt`.

| | Judged | Not judged (unsupported + thin) | Failing | Worst late-prefill | Verdict |
|---|---:|---:|---:|---:|---|
| B (reference) | 114 | 3 + 3 | 3 | (1, 8,192, 256) −20.3% | FAIL |
| W4 | 114 | 3 + 3 | 4 | (16, 8,192, 256) −19.9% | FAIL |
| W5 | 114 | 3 + 3 | 3 | (16, 8,192, 256) −18.2% | FAIL |
| W4g | 114 | 3 + 3 | 3 | (16, 8,192, 256) −18.6% | FAIL |
| W5g | 114 | 3 + 3 | 3 | (1, 8,192, 256) −17.8% | FAIL |

**SELECTED: none.**
- The support rule removed the three 512-token serial endpoints from judgement, as the diagnostic tables predicted.
- Every remaining failure, in every candidate, is a short (256-token) late prefill joining long-context decoders: (1, 8,192, 256), and (16, 8,192, 256), and once (4, 8,192, 256). All are under-predicted, by 10.1% to 20.3%.
- In every wave candidate's all-data fit, `k_mixed` (the ΣK term in mixed steps) went to 0 or near it: the wave column took its place, as the diagnostic tables' falsification of H-sum implied.

**Why, read from the diagnostic tables' own numbers.** These are not a new fit. Dividing each long-context increment by ⌈n/4⌉ × K_max gives a cost per wave-token, by the prefill chunk q in the step:

| q | n | Increment (ms) | Per wave-token (µs) |
|---:|---:|---:|---:|
| 4 | 1 | 0.09 | 0.010 |
| 16 | 4 | 0.37 | 0.044 |
| 64 | 16 | 41.76 | 1.239 |
| 256 | 1 | 13.27 | 1.612 |
| 256 | 4 | 13.64 | 1.646 |
| 256 | 16 | 55.03 | 1.633 |
| 2,032 | 16 | 52.64 | 1.562 |
| 2,047 | 1 | 5.70 | 0.696 |

- At q = 256 the wave shape holds exactly: 1.61 to 1.65 µs per wave-token at n = 1, 4 and 16.
- But the cost per wave depends on the prefill chunk beside it. It is nearly zero for chunks of 4 or 16 tokens, about 1.6 µs from 256 to 2,032, and less than half that, 0.70, for one decoder beside a full 2,047-token chunk.
- One wave coefficient fits the average, about 1.15 µs, and so under-predicts every q = 256 step.
- This reads like a decoder's attention work being partly hidden behind a large prefill's own work, and fully exposed beside a medium one. That is a description of these numbers, not an established mechanism.

**What follows.** A fourth family on this archive would be fitted to a shape read off this table, and would test nothing. The mechanism can be checked on fresh data directly and cheaply: time the attention kernel alone, on one A10G, over a grid of (q, n, K_max) chosen before measuring. That is the operator-level approach of Vidur (arXiv 2405.05465), which models prefill and decode attention separately. It needs a short paid session and the owner's approval.
