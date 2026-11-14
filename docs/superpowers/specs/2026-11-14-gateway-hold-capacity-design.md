# Gateway hold capacity: a bound on held requests

Date: 2026-11-14. Status: implemented with this page (the second half of backlog item A6; the first half, read deadlines, is #547).

## Problem

Three admitters hold a standard request at the gateway instead of refusing it: serial-prefill, HoldCap (serial-prefill per backend) and fixed-spacing.
A held request is a goroutine and its buffered body, kept until its turn comes, its client leaves, or its hold (`maxHold`, tens of seconds) runs out.
Nothing bounds how many are held.

The body is read before admission and kept for the forward, up to `maxBodyBytes` (1 MiB).
The gateway Deployment's memory limit is 256 Mi (`config/gateway/deployment.yaml`).
About two hundred held requests at the body cap are therefore enough to have the gateway OOM-killed, which drops every request it was serving, premium included.
The fair line (`fairline.go`) decides whose turn is next, but it does not stop one tenant from taking every slot the gateway can hold.

## Decision

A gateway-wide hold budget, taken before a request starts waiting and given back when it stops, whichever way it stops.

| Limit | Flag | Default |
|---|---|---|
| Held requests, all tenants | `--admission-hold-max-requests` | 1024 |
| Held body bytes, all tenants | `--admission-hold-max-bytes` | 64 MiB |
| Held requests, one tenant | `--admission-hold-tenant-max-requests` | 512 |
| Held body bytes, one tenant | `--admission-hold-tenant-max-bytes` | 32 MiB |

- **Only waiting is charged.** A request admitted at once never holds anything at the gateway and is not charged. A waiter is charged from the moment it joins a line until its `Reserve` returns, so one that the line has already dropped as expired is still charged until its own timer fires, because its goroutine and body are still alive until then.
- **One budget for every reserving admitter.** The process-wide admitter and the HoldCap admitter share the same budget, because they share the same memory.
- **Every limit must be above zero, and a tenant limit cannot exceed its total.** A zero would refuse every request that ever had to wait, and look like a rule working, which is the same reason serial-prefill has no default hold.

### Why 503 and not 429

`internal/bench/report.go` reads every 429 as the admission guard shedding work (`shedByAdmission`), and the admitted-work fraction and per-tenant dispositions are built on that reading.
A hold-capacity refusal is the gateway running out of room, not the policy under test deciding, so a 429 would credit the policy with refusals it never made.
429 also tells a caller it exceeded its own rate, which may be false here.
So both limits answer 503 with `Retry-After` and name themselves in `X-Admission-Reason`: `hold_full` for the total, `hold_tenant_full` for a tenant's share.

### What the harness does with it

- `refusedForHoldCapacity` recognises the two reasons on a 503.
- `Summarize` counts such rows in `ArmSummary.HoldRefused` and keeps them out of both terms of the admitted-work fraction, where before this change a 503 counted as admitted work.
- A compared arm with any such row is invalid: it measured the gateway's capacity, not its policy.
- The HoldCap study scorer (`hack/eks-serve/holdcap-study/score.py`) already fails a HoldCap cell on any refusal, so it needs no change.
- The registered v26/v27 pilot scorers (`hack/prospective-pilot/pilot_report.py`) are left as registered. Their "hold refusals" line names only the two hold timeouts, but `contender_outcomes` counts any refusal as a failed contender, so a hold-capacity refusal still lands against the contender completion limit (>= 0.95) rather than passing unseen.

### Why these defaults

The registered runs must not reach them.
The HoldCap diagnostic traces send 185 to 232 contender requests over 420 s, each at most 40,000 characters (`hack/eks-serve/holdcap-study/diagnostic/trace-off-*.jsonl`).
Even if every contender request were held at once that is under 10 MiB and 232 requests, below the tenant limits.
64 MiB of held bodies is a quarter of the memory limit, which leaves room for in-flight responses and the cache.

## Not covered

- **In-flight requests.** A request forwarded upstream keeps its body for a retry until the response ends. This page bounds waiting, not concurrency to the engines.
- **Modes that do not hold.** off, static-cap, kv-aware and prospective refuse or forward at once and hold nothing.

## Verification

- Unit: the budget's take and give, totals and tenant shares, and flag validation.
- Admitters: a waiter over a limit is refused with the right reason; each way a waiter stops (turn, timeout, client gone) gives its charge back; a request admitted at once is never charged.
- Server: the refusal is a 503 carrying the reason and `Retry-After`.
- Harness: a 503 with either reason is counted as `HoldRefused`, removed from the admitted-work terms, and invalidates the comparison.
- Each test is broken on purpose once to confirm it goes red.
