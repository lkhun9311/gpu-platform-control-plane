# Which layer holds the fix — the answer

Date: 2026-09-04 · Result of the test pre-registered in `2026-09-04-scheduler-microtest.md`.
Cost: about $0.40, 37 minutes, one Spot g5.xlarge, no NAT data charge.
Raw results: `data/2026-09-04-scheduler-microtest-results.json`.

## Reading B fired

> The engine can protect the tail, but only when told to prioritise.

| batch budget | policy | uncontended (ms) | contended median (ms) | contended range | long TTFT (ms) | ratio |
| ---: | --- | ---: | ---: | ---: | ---: | ---: |
| 512 | fcfs | 48.7 | 671.9 | 668.1–672.8 | 685 | 13.79x |
| 512 | priority | 48.5 | 76.0 | 73.2–76.8 | 684 | 1.57x |
| 2048 | fcfs | 48.8 | 609.4 | 606.6–611.1 | 623 | 12.48x |
| 2048 | priority | 48.6 | 235.5 | 232.4–235.9 | 628 | 4.85x |
| 8192 | fcfs | 48.7 | 575.3 | 573.3–595.9 | 588 | 11.81x |
| 8192 | priority | 48.6 | 575.3 | 572.4–575.9 | 588 | 11.83x |

Ten repetitions per cell. In all sixty, the engine reported the long request as running before the short one
was sent, so every measurement is of an actual overlap rather than a race the client lost.

## What it says

**Chunk size alone does nothing.** Under `fcfs` the ratio is 12–14x at every budget, including 512, where a
7,695-token prompt is split into about fifteen pieces. Splitting the work does not let a later arrival
overtake it: the scheduler serves the waiting queue in order, and a short request behind a long one waits for
all of its chunks. That is the mechanism two cold reviews identified from source, and it is now measured.

It also closes my own earlier hypothesis, which was that the prompt ran as one indivisible step because the
default budget exceeded it. The engine's startup line settles that too:

```
Chunked prefill is enabled with max_num_batched_tokens=512.
```

**Priority alone does nothing either.** At a budget of 8192 the ratio is 11.83x with priority against 11.81x
without it. A 7,695-token prompt fits inside an 8192-token budget, so it occupies one whole step and there is
no boundary for a higher-priority request to enter at.

**The two together are the fix.** Priority at a budget of 512 gives **1.57x**, inside the pre-registered 2x
band. Chunking creates the boundaries; priority decides who crosses them. Neither is sufficient and both are
necessary, which no amount of reading the source would have established.

**And it cost the long request nothing measurable.** At a budget of 512 its own TTFT is 685 ms under `fcfs`
and 684 ms under `priority` -- the short request went in ahead of it and the difference is inside the noise
of ten repetitions. This is not a trade of one tenant's latency for another's; it is a scheduler that was
making both wait for no reason, since the short request's prefill costs about 68 tokens against 7,695.

## Consequence, as pre-registered

Reading B says this is a data-plane finding and a successor milestone is registered for it.

**M5-b's control-plane contribution does not stand for this problem.** The premium tail is protected by two
engine flags, not by a gateway that refuses requests. The guard was not merely mistuned; it was solving a
problem the layer below it already solves better, and the 84 percent of its refusals that landed on an idle
engine were the visible symptom of that.

M5-b closes as a negative result with a measured explanation:

- Reactive KV-occupancy shedding did not protect premium TTFT p99 at this load (83.7x against a
  pre-registered 1.25x, reproduced across four repetitions).
- The tail is head-of-line blocking behind admitted long prefills, a clean staircase of about 944 ms per
  concurrent one.
- The engine can be configured to prevent it, and the configuration is scheduling policy plus batch budget
  together.

## Not concluded here

Whether 512 is the right budget, why 2048 with priority lands at 4.85x rather than near either end, and
whether priority preempts a running prefill or only reorders the waiting queue. The no-retuning rule holds:
these are questions for a new pre-registration, not adjustments to this one.

Nor does this say admission control is useless in general. It says that for THIS failure — one long prefill
blocking one short request on one engine — the layer below already has the lever. A gateway still owns
fairness across tenants, quota, and the case where the engine's own queue is the wrong place to arbitrate.
