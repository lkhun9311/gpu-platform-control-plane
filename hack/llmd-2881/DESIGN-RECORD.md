# Design record: release-then-reject in llm-d-router (#2881)

Status: baseline and two alternatives measured on kind with a simulator.
The re-queue and endpoint-reservation designs are not implemented or measured yet; section 3 is where deterministic
tests of them will go.
Every number here comes from `runs/` and is reproduced by `analyze.py` and `table.py`; README.md has the setup and the
counting rule.

Read every comparison below as observational and simulator-bound:

- The "before #3065" arm is #3065's parent `69a3af43` (2026-10-07), and the main arm is `e922a7ae` (2026-11-18), 561
  commits later.
  It is not the same build with and without #3065, so a difference between them is consistent with #3065, not
  attributed to it.
- "A pod fit at release" and "no pod fit at release" are labels on a per-pod load rebuilt from log timestamps.
  They are not the producer's counters or the filter's observed decision state, and they cannot see dispatch
  reservations.
- Token counts are the detector's policy units: prompt tokens plus `max_tokens` (`addEstimatedOutputTokens: true`).
  They are not KV-cache occupancy and not GPU work, and that estimate fits this short, forced-length workload.
- "Fewer than 4 EPP-counted requests on a pod" means the EPP's count of routed requests was below the simulator's
  `--max-num-seqs`, not that a GPU, or the simulator, was idle.
- The load is built to find admission failures: 24 requests in 20 ms, a 1024-token budget, fixed simulator latency.
  It shows the failure exists; it says nothing about how often it happens in production.

## 1. Problem and measured baseline

Flow control releases a request when pool saturation is below 1.
The concurrency-detector filter then checks each endpoint on its own, against current load plus, in tokens and hybrid
modes, the request's own tokens.
With `failOpen: false`, a request the two disagree on leaves as `503 rejected-no-endpoints`, though flow control had
admitted it and the client could have waited.

Baseline on main `e922a7ae`, 3 seeded burst runs of 960 requests per mode, `failOpen: false`:

| mode | released then rejected | a pod fit at release (rebuilt label) | no pod fit at release (rebuilt label) |
|---|---|---|---|
| requests | 0 of 2880 | - | - |
| tokens | 1803 of 2880 (62.6%) | 656 | 1147 |
| hybrid | 1313 of 2880 (45.6%) | 133 | 1180 |

Low-load controls: 0 of 240 in every mode.
The control is a different arrival schedule, not the burst schedule thinned out: the burst size changes how many draws
each burst takes from the seeded source, so every burst gap after the first differs too.

The thread's three causes, as this lab sees them.
`detector.go` lines are main's, under `pkg/epp/framework/plugins/flowcontrol/saturationdetector/concurrency/`.

- **Cause 1, flow control does not count its own dispatches.**
  #3065 added dispatch reservations to `requests` mode and to the request term of `hybrid` mode
  (`detector.go:139` `ReserveDispatch`, added to the request ratio at `detector.go:226` and `:229`); the tokens-mode
  ratio has no such term (`detector.go:218`).
  Observed: 0 rejections in requests mode on main, against 1539 of 2880 (53.4%) on #3065's parent under the same
  load, all labelled "a pod fit at release" with every pod at 4 or more EPP-counted requests at rejection (1489 at
  4/4/4, 40 at 4/4/5, 10 at 4/5/5).
  That is consistent with #3065 closing this gap for requests mode, and the comparison does not isolate it.
  In tokens mode, 656 of the 1803 rejections carry the "a pod fit at release" label, consistent with requests
  dispatched in the next few milliseconds taking the room (`runs/20261119T122136Z-tokens-burst-s1/trace-example.txt`).
- **Cause 2, the two stages test different conditions.**
  Flow control reads a pool ratio without the request's tokens (an average of per-pod ratios in hybrid mode,
  `detector.go:186`); the filter tests each pod with them (`detector.go:249`, `admits` at `:294`).
  1147 tokens-mode and 1180 hybrid-mode rejections carry the "no pod fit even at release" label, consistent with this.
  Doubling the token budget to 2048 still left 1053 of 2880 rejected, 733 of them with that label.
- **Cause 3, different endpoint sets (#3077).** Not exercised: no subsetting header, one EPP replica.

A single request can need both causes, so the 656/1147 split is a description of the rebuild, not an attribution.

## 2. Candidate designs and what they cost

Throughput below is **successful completion throughput**: successful completions over first send to last completion.
It applies no latency target, so it is not SLO goodput.
TTFT and FC queue percentiles are nearest-rank over successful completions only.
An arm that rejects requests drops them from those percentiles, which favours it: the fail-closed baseline's low TTFT
p50 below comes from serving only the requests that were not rejected.
E2E is over every request, rejections included.
In these records TTFT is the first SSE `data:` line, whatever it carried; the loadgen now times the first event that
carries generated text, and runs after this change report that.

### A. Fail open (#2883, the short-term fix)

Mechanism: when every endpoint is over its limit, the filter returns all of them and the scorers pick one.
Measured on the same load (`failOpen: true`):

| mode | 503 | routed over the detector limit | routed past 4 engine slots | peak pod load |
|---|---|---|---|---|
| tokens | 0 | 1927 of 2880 | 1700 | 15 requests, 4358 estimated tokens |
| hybrid | 0 | 1211 of 2880 | 4 | 5 requests, 1620 estimated tokens |

It removes the 503s by not enforcing the limit the operator set: in tokens mode 1927 of 2880 requests (66.9%) left
their pod above the limit once counted, 1123 (39.0%) of them on a pod already above it before, and the engine queues
them instead of flow control.

### B. Projected-cost check before release (#3173)

Mechanism, from the PR's code (local cherry-pick `19a68cfe` on `e922a7ae`, clean apply):

- While a request waits in flow control, a preparation goroutine locates its candidate endpoints from the request's
  own metadata, runs the screeners, and runs the admission data producers, tokenization first
  (`requestcontrol/queued_preparation.go:65`, `:79`-`:86`, `:119`-`:127`; paths under `pkg/epp/`).
- At each dispatch cycle the processor re-locates the request's candidates, checks that the set has not changed, and
  asks the scheduler's `FilterForAdmission` whether the selected profile can take the request's projected cost
  (`flowcontrol/controller/internal/processor.go:586`, `requestFits` at `:684`, `readyRequest` at `:753`).
  For a single-profile monolithic-decode setup this runs the saturation filter over the decode candidates; the disagg
  handler checks its own profiles; any other handler skips the gate (`scheduling/admission.go:31`-`:59`).
- The admitted endpoint set per profile is handed to scheduling (`requestcontrol/director.go:465`,
  `scheduling/scheduler.go:68` `ScheduleWithAdmission`), and the prepared tokenization is copied onto the request
  (`director.go:382`-`:383`), so the tokenizer skips its post-release run
  (`requesthandling/dataproducer/tokenizer/tokenizer.go:463`).
- It checks without reserving: two requests can both pass against the same remaining room.

So #3173 is a per-request, per-profile admission check located from request metadata, not a pool-level check that
ignores subsetting.
The earlier version of this record called it pool-level and claimed re-queue would see cause-3 rejections it could
not; that was wrong, and is withdrawn.
Whether it handles #3077's subsetting case end to end is not tested here.

The old TODO, whether the PR moves token preparation ahead of release, is answered from the code: it does.
That is consistent with release to rejection falling from a median of 4.1 to 6.3 ms (tokens mode) to 0.1 to 0.4 ms;
the timing alone did not establish it.
On main, tokenization runs after `Admit` returns
(main `requestcontrol/director.go:343`, then the producers at `:389`), so the window in which other dispatches can take room includes a
render call.

| mode | 503 | "a pod fit at release" label | routed over the detector limit |
|---|---|---|---|
| tokens | 27 of 2880 (0.9%) | 25 | 94 |
| hybrid | 22 of 2880 (0.8%) | 21 | 78 |

46 of the 49 residual rejections carry the "fit at release" label, consistent with the check-without-reserve window;
3 (2 tokens, 1 hybrid) carry "no pod fit at release".

### Performance trade-off, by seed

Same seeded load in every arm; fail-closed baseline is main `e922a7ae` with `failOpen: false`.

| mode | arm | seed | 200 / 503 | successful completions/s | TTFT p50 / p99 ms (successes) | e2e p50 / p99 ms (all) | FC queue p50 / p99 ms |
|---|---|---|---|---|---|---|---|
| tokens | baseline | 1 | 360 / 600 | 8.77 | 112 / 551 | 7 / 884 | 0 / 0 |
| tokens | baseline | 2 | 415 / 545 | 6.83 | 115 / 516 | 11 / 877 | 0 / 0 |
| tokens | baseline | 3 | 302 / 658 | 5.09 | 114 / 506 | 7 / 852 | 0 / 0 |
| tokens | fail-open | 1 | 960 / 0 | 19.53 | 4563 / 10608 | 4977 / 11014 | 4392 / 10336 |
| tokens | fail-open | 2 | 960 / 0 | 15.65 | 866 / 3233 | 1331 / 3700 | 597 / 3003 |
| tokens | fail-open | 3 | 960 / 0 | 15.20 | 1115 / 3775 | 1515 / 4195 | 918 / 3489 |
| tokens | #3173 | 1 | 954 / 6 | 17.56 | 6904 / 15393 | 7356 / 15903 | 6800 / 15289 |
| tokens | #3173 | 2 | 949 / 11 | 15.36 | 1521 / 4830 | 1932 / 5223 | 1399 / 4724 |
| tokens | #3173 | 3 | 950 / 10 | 14.57 | 1897 / 5559 | 2268 / 5993 | 1776 / 5454 |
| hybrid | baseline | 1 | 587 / 373 | 14.30 | 500 / 2731 | 670 / 2961 | 396 / 2626 |
| hybrid | baseline | 2 | 568 / 392 | 9.35 | 116 / 1525 | 505 / 1897 | 3 / 1420 |
| hybrid | baseline | 3 | 412 / 548 | 6.69 | 113 / 2162 | 291 / 2369 | 0 / 2057 |
| hybrid | fail-open | 1 | 960 / 0 | 19.56 | 4615 / 10501 | 5040 / 10948 | 4509 / 10396 |
| hybrid | fail-open | 2 | 960 / 0 | 15.63 | 882 / 3265 | 1340 / 3700 | 776 / 3158 |
| hybrid | fail-open | 3 | 960 / 0 | 15.21 | 1069 / 3679 | 1488 / 4084 | 963 / 3573 |
| hybrid | #3173 | 1 | 955 / 5 | 17.67 | 6873 / 15160 | 7340 / 15643 | 6769 / 15055 |
| hybrid | #3173 | 2 | 950 / 10 | 15.40 | 1480 / 4685 | 1869 / 5083 | 1375 / 4580 |
| hybrid | #3173 | 3 | 953 / 7 | 14.61 | 1941 / 5622 | 2301 / 5978 | 1837 / 5517 |

What this shows, on a simulator:

- #3173 turns almost every rejection into a wait, and pays for it in latency: on every seed its TTFT p50 and p99 and
  its e2e p99 are higher than fail-open's, and its successful completion throughput is lower (17.56 against 19.53 on
  seed 1).
  Fail-open serves faster because it overfills pods and the simulator's fixed per-token latency does not slow down
  under that overfill; a real engine may, so this ordering may not hold on vLLM.
- The baseline's low TTFT is the rejected requests missing from the sample, not a faster path.
- None of this establishes that enforcing the configured token limit improves inference performance.
  What the arms differ in is who waits and where: in flow control (#3173), in the engine (fail-open), or not at all
  (baseline, which rejects).

### C. Re-queue with a hold (ahg-g, 2026-10-07; mechanics in blacksoxx, 2026-10-15)

Mechanism: a filter that empties the set because of saturation returns a distinct error; the director puts a
flow-control-admitted request back in its queue with its original enqueue time and TTL, releases its dispatch
reservation, and the processor holds it until capacity changes or a bounded backoff passes.
A retry cap turns exhaustion into 429, not 503.
Expected effect, not measured on this load: the rejections that B leaves become waits, up to the cap.
Like B, it keeps the filter's limit, unlike A.
It cannot claim a hard bound on per-pod load: the filter-to-PreRequest race that lets two requests pass against the
same room survives it.
Its costs are repeated producer work on each retry, extra queue time, and retry churn when saturation outlasts the
cap; none of these is measured yet.

### D. Rank, then atomically reserve the selected endpoint

Mechanism: scheduling ranks the candidates as now, then the chosen endpoint's capacity is reserved with a
compare-and-add; a lost race re-queues the request rather than failing it.
It is the only one of these designs that closes the local placement race, and it needs one accounting authority per
endpoint, a reservation released exactly once, and, across EPP replicas, coordination it does not have today.

## 3. Comparison in deterministic tests

TODO: filled by the Phase 2 tests (races, fragmentation, subset saturation, long saturation, oversized request,
cancellation and duplicate ids, two EPP replicas).

## 4. Cost

This run: $0 in cloud spend; one local kind cluster on the workstation, about 80 minutes of wall time for 36 measured
runs (12:09 to 13:27 UTC), deleted afterwards.

Plan for a real-vLLM confirmation, not approved and not started:

- One g5.12xlarge (4 x A10G), three vLLM replicas of a small model with `--max-num-seqs 4`, the same EPP configs and
  seeded load, arms: baseline, fail-open, #3173, and the chosen design, plus #3173 with it.
- It should measure SLO goodput (successful requests meeting predeclared TTFT and TPOT targets), actual generated
  tokens, engine queue time and KV occupancy, not only 503 counts.
- 36 to 48 runs at about 2 minutes each plus setup: about 2.5 hours.
- At an on-demand list price of about $5.67 an hour (not re-checked), about $14, a planning estimate under the $40
  standing cap.
