# Design record: release-then-reject in llm-d-router (#2881)

Status: baseline and two alternatives measured on kind; the re-queue design is not implemented.
Every number here comes from `runs/` and is reproduced by `analyze.py` and `table.py`; README.md has the setup and the counting rule.

## 1. Problem and measured baseline

Flow control releases a request when pool saturation is below 1.
The concurrency-detector filter then checks each endpoint on its own, against current load plus, in tokens and hybrid modes, the request's own tokens.
With `failOpen: false`, a request the two disagree on leaves as `503 rejected-no-endpoints`, though flow control had admitted it and the client could have waited.

Baseline on main `e922a7ae`, 3 seeded burst runs of 960 requests per mode, `failOpen: false`:

| mode | released then rejected | a pod fit at release (rebuilt) | no pod fit at release (rebuilt) | goodput req/s by seed |
|---|---|---|---|---|
| requests | 0 of 2880 | - | - | 20.0 / 15.7 / 15.3 |
| tokens | 1803 of 2880 (62.6%) | 656 | 1147 | 8.8 / 6.8 / 5.1 |
| hybrid | 1313 of 2880 (45.6%) | 133 | 1180 | 14.3 / 9.4 / 6.7 |

Low-load controls: 0 of 240 in every mode.

The thread's three causes, as this lab sees them:

- **Cause 1, flow control does not count its own dispatches.**
  #3065 added dispatch reservations to `requests` mode and to the request term of `hybrid` mode.
  Measured: 0 rejections in requests mode on main, against 1539 of 2880 (53.4%) on the commit before #3065 under the same load, all of them with a pod that fit at release and every pod full at rejection.
  Tokens mode has no reservation, and 656 of its 1803 rejections had a pod that fit at release, taken by requests dispatched in the next few milliseconds (`runs/20261119T122136Z-tokens-burst-s1/trace-example.txt`).
- **Cause 2, the two stages test different conditions.**
  Flow control reads a pool ratio without the request's tokens (an average of per-pod ratios in hybrid mode); the filter tests each pod with them.
  1147 tokens-mode and 1180 hybrid-mode rejections had no pod that fit even at release.
  Doubling the token budget to 2048 still left 1053 of 2880 rejected, 733 of them with no pod fitting at release.
- **Cause 3, different endpoint sets (#3077).** Not exercised: no subsetting header, one EPP replica.

The split between causes 1 and 2 is read off a load rebuilt from log timestamps; a single request can need both.

## 2. Candidate designs

### A. Fail open (#2883, the short-term fix)

Mechanism: when every endpoint is over its limit, the filter returns all of them and the scorers pick one.
Measured on the same load (`failOpen: true`):

| mode | 503 | routed over the detector limit | routed past 4 engine slots | peak pod load | goodput req/s | FC queue p50 ms |
|---|---|---|---|---|---|---|
| tokens | 0 | 1927 of 2880 | 1700 | 15 requests, 4358 tokens | 19.5 / 15.6 / 15.2 | 4392 / 597 / 918 |
| hybrid | 0 | 1211 of 2880 | 4 | 5 requests, 1620 tokens | 19.6 / 15.6 / 15.2 | 4532 / 776 / 966 |

It removes the 503s by ignoring the limit the operator set: in tokens mode two thirds of requests land on a pod already past it, and the engine queues them instead of flow control.

### B. Projected-cost check before release (#3173)

Mechanism: before releasing a request in tokens or hybrid mode, flow control checks whether any endpoint can take the request's projected cost, and keeps it queued otherwise.
It checks without reserving.
Measured with the PR cherry-picked onto `e922a7ae` (clean apply, local commit `19a68cfe`):

| mode | 503 | a pod fit at release | goodput req/s | FC queue p50 ms | routed over the detector limit |
|---|---|---|---|---|---|
| tokens | 27 of 2880 (0.9%) | 25 | 17.6 / 15.4 / 14.6 | 6800 / 1399 / 1776 | 94 |
| hybrid | 22 of 2880 (0.8%) | 21 | 17.7 / 15.4 / 14.6 | 6769 / 1375 / 1837 | 78 |

It removes cause 2 at the gate; what is left is cause 1, the room another request takes between release and filter, which a check without a reservation cannot close.
Release to rejection fell from a median of 4 to 6 ms to 0.1 to 0.4 ms, which suggests the PR also moves the token preparation ahead of release.
TODO: confirm that from the PR's code rather than from the timing.

### C. Re-queue with a hold (ahg-g, 2026-10-07; mechanics in blacksoxx, 2026-10-15)

Mechanism: a filter that empties the set because of saturation returns a distinct error; the director puts a flow-control-admitted request back in its queue with its original enqueue time and TTL, releases its dispatch reservation, and the processor holds it until it has taken a newer saturation sample.
A retry cap turns exhaustion into 429, not 503.
Expected effect, not measured: the 1803 and 1313 rejections above become waits, as with B, and the residual cause-1 rejections that B leaves (27 and 22) also become waits, up to the cap.
It keeps the filter's limit, unlike A, and it turns cause-3 rejections into waits as well, which a pool-level gate like B cannot see.
Its costs are the repeated producer work on each retry and the extra queue time; both are TODO until implemented.

## 3. Why re-queue

TODO until implemented and measured on this load against A and B.
The questions this section has to answer with numbers: does re-queue reach B's 503 rate or lower; what queue wait and goodput does it cost against B; how many requests exhaust the retry cap and leave as 429; and does it hold when cause 3 is exercised.

## 4. Cost

This run: $0 in cloud spend; one local kind cluster on the workstation, about 80 minutes of wall time for 36 measured runs (12:09 to 13:27 UTC), deleted afterwards.

Plan for a real-vLLM confirmation, not approved and not started:

- One g5.12xlarge (4 x A10G), three vLLM replicas of a small model with `--max-num-seqs 4`, the same EPP configs and seeded load, arms: baseline, fail-open, #3173, and re-queue once it exists.
- 36 to 48 runs at about 2 minutes each plus setup: about 2.5 hours.
- At an on-demand list price of about $5.67 an hour (not re-checked today), about $14, under the $40 standing cap.
- What it would add: real engine timing and KV pressure instead of the simulator's fixed per-token latency, so the 503 rates and queue waits above can be checked against an engine that slows under load.
