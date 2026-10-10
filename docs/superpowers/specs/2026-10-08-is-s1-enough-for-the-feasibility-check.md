# Is S1 enough for the feasibility check? No; item 2 stays closed

*Written 2026-10-08, after S1's confirmation failed (`2026-10-07-confirming-s1-on-unseen-settings.md`). This is a judgement for the owner. It buys nothing and changes no recorded verdict.*

## The question

S1 failed 12 of 158 endpoints on fresh settings, all at short prefills. Everything it was built for passed:
- mixed steps on both sides of the 128-token graph boundary;
- late prefills and long-context decoders;
- several prefills per step;
- decode.

Item 2 of M5-b's successor ranking is a computational feasibility check of prospective admission. Could it run on S1 restricted to the domain the confirmation passed?

## The answer

**No.** A first draft of this page said yes, on the sharing-matrix load. codex `gpt-6-astra`'s cold review rejected it, and the parts I could check, I confirmed from the archive.

**The draft confused request sizes with scheduled step sizes.**
- It read the failed bursts as 128- and 160-token prefill-only steps. The step records show otherwise. Each 32-token burst's first request was scheduled alone (a P = 32 prefill-only step, 12 steps per setting). The rest joined the next step beside it as one mixed step:
  - P = 96, n = 1, for (4, 32);
  - P = 128, n = 1, for (5, 32).

  These are compositions 167 to 169 in `data/2026-10-08-confirm-compositions.json`.
- So the prefill-only failures are P = 32, and the mixed failure is a 129-token mixed step. They are not the sizes the draft named.

**A frozen load does not fix the step sizes.**
- The sharing-matrix tuple (256-token premiums, 8,192-token contenders, budget 2,048) does not produce only P = 256 and P = 2,048 prefill-only steps.
- A contender that starts beside one finishing decoder gets 2,047 tokens, and a later prefill-only chunk of P = 1.
- Two or three premiums admitted together give P = 512 or 768 with no decoder.
- The scheduler admits between steps, so the sizes a simulator meets depend on arrivals and on its own predictions. They are not set by the prompt lengths.

**The confirmation did not cover what the successor would meet.**
- Its endpoints are averages per setting and phase. A passing average does not confirm every composition of the same P.
- It did not test the successor's arrival and concurrency pattern.
- Narrowing the domain after seeing the failures would itself need prospective confirmation.

**And item 2 needs more than step occupancy.**
- The successor's question is about premium TTFT. That depends on the P → A wait and the inter-step gap, which S1 leaves out and the step-boundary session recorded as preconditions for simulator readiness.
- The admission reservation in the gateway is `ceil(chars / 4)`, not exact tokens, so a simulated feasible point might not be the implemented mechanism's.

## What item 2 would need, if it is pursued

Recorded so that a later decision starts from it, not as a plan this page adopts:
1. A step-time model confirmed on fresh cells across the step compositions a simulator actually reaches, including short prefill-only chunks such as P = 1 and P = 32, several-request prefill-only steps (P = 512, 768), and the 128- and 256-token boundaries.
2. A kernel-coverage procedure. A simulated run's compositions are enumerated; missing kernel times are measured under the grid-3 method; the run is repeated. If timing changes create further unmeasured compositions, the run refuses rather than inventing them.
3. Measured or modelled P → A waits and inter-step gaps, with their uncertainty carried into the feasibility decision.
4. The admission unit reconciled between the gateway and the simulator.

Each is a registration. Items 1 to 3 each need GPU purchases.

## The recommendation

Item 2 stays closed.

Before any further step-time work, the owner should decide whether the successor's question is better answered directly: by measuring prospective admission on the GPU (item 3), with its own registration, rather than by first simulating it. The reasoning:
- three development registrations, two kernel grids and a nine-cell confirmation have produced a model good for mixed and decode steps;
- each further fix moves the boundary of what is unconfirmed rather than removing it.

That is a judgement about where the effort goes, and it is the owner's.
