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
