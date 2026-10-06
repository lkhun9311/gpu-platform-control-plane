# M5-b stays closed, and what a successor needs first

Date: 2026-10-06 · A decision record, not a registration. **No card is bought by this page.**

**Why it exists.** The owner asked for M5-b to be attempted again. M5-b asked whether the gateway's KV-aware admission guard holds the premium tier's TTFT p99 within 1.25x of isolation. On 2026-09-03 it failed at 83.7x. Two of its three checks were void, and its stopping rule (`2026-09-04-m5b-pilot-stopping-rule.md`) forbids spending again on that design. Before anything was written, I and codex `gpt-6-astra` each judged independently whether a legitimate retry exists.

## 1. What both of us concluded

**M5-b stays closed as a paid study.** Repairing arm B, lowering the KV threshold, or lightening the load until the guard passes would re-ask the old question until it said yes.

astra re-derived the deciding figures from the raw rows, and they agree with the record:
- The premium p99 ratio is 6,881.98 / 82.18 = 83.75x.
- The guard refused 274 of 1,788 eligible requests, 15.3%.
- The best engine-scheduling cell of the price-of-protection run was 20.73x.
- The KV trigger needs about 43 long prompts in flight, against at most 13 observed.

## 2. Where I was wrong

I first argued that a shared engine cannot meet the bar at this load: one 2,048-token chunk takes about 270 ms, more than a 1.25x budget of about 84 ms.

astra showed that this is not an impossibility proof. The blocking interval depends on the batch budget and the scheduler's boundaries, not on a whole long prompt. The scheduler microtest's 512-token budget with priority scheduling gave 76.01 / 48.55 = 1.57x on two requests. That is above 1.25x, but it is not the order-of-magnitude miss a fixed 2,048-token chunk implies. So the question is not settled by arithmetic, and a successor is not ruled out.

## 3. The successor question, and why it is not M5-b again

astra's proposal, which I adopt as the direction:

> Does **prospective** admission — reserving a standard request's exact input work before forwarding it and releasing it at its first token, with a bound on active standard streams — protect the premium tail better than pressure-blind shedding at comparable admitted work, **on an engine whose priority is bound to the tenant's tier and whose batch budget is fixed in advance**?

It differs from M5-b in three ways:
- It is not reactive to KV occupancy.
- It assumes trusted priority and a fixed chunked-prefill budget, which M5-b never had together.
- Its control is matched on admitted work.

It must also not win by deletion. Contender work and output share must stay at or above 75% of an unshed arm, and aggregate throughput at or above 95%. Those bars are astra's, extended from the price-of-protection safeguards. Like the reservation caps, the load and the blocks, they are frozen in its own registration, not here.

## 4. What must exist first, all of it free

1. **Trusted priority.** Today the gateway resolves a tenant's tier (`internal/gateway/server.go`, step 7) but never binds the engine's `priority` to it. The benchmark profile refuses a client-sent `priority`, and the only priority anywhere is what the harness sends. The gateway must write the tier's priority into the request it forwards and must ignore any client value. That is the first change and lands with tests.
2. **Reservation hooks.** `internal/gateway/admission.go` exposes a decision but no lifecycle, so it has no reserve before forward and no release at first token, error or cancellation.
3. **Correctness on kind**, with a stub engine. Kind cannot establish TTFT protection, so nothing measured there is a protection claim.
4. **A computational feasibility check**, only once a step-time model exists. The logged-engine registration of 2026-10-06 is the current attempt at one, and its fit has never been computed.

## 5. Ranking

1. Keep M5-b closed. Build 4.1 to 4.3, at no cost.
2. Run the computational feasibility check, conditional on a step-time model.
3. Register and buy the successor, only after 1 and 2.
4. True physical separation, if an operational objective justifies its cost.

Item 3 cannot be bought before item 2: without a step-time model, nothing predicts whether a reachable point exists.

## Update, 2026-10-06 — 4.1 is built; 4.4 has no step-time model to run on

- **4.1, trusted priority, is built** (`0dc1629`). `--bind-priority` makes the gateway write priority 0 for premium and 1 for standard into every forwarded request, overwriting any caller value. It sets the body, `GetBody` and `ContentLength` together, so a retry rewinds to the bound priority. Four specs pin it, and each fails when its line is reverted. It is off by default and has run against no engine.
- **4.4 cannot run yet.** The logged-engine registration's pilot failed under both mixed-step conventions. The staggered late prefill's client TTFT was predicted at 0.45 to 0.98 of what was observed. So no step-time model of mixing exists for the simulator to use, and a computational feasibility check built on it would inherit that failure.
- So item 3 of the ranking stays unbuyable. 4.2 and 4.3, the reservation hooks and their kind correctness, remain free and open.

## Update, 2026-10-06 — 4.2 and 4.3 are built; the successor's mechanisms work on kind

- **4.2, reservation hooks** (`2ebfe45`, `8d91105`, `8fc0da3`). `--admission-mode=prospective` reserves a standard request's estimated input and a stream slot per backend, in one critical section. It releases the input when the first body byte reaches the client and the stream when the request ends, however it ends. Premium is admitted without holding anything. Both caps are required flags with no default.
  - A cold review by codex `gpt-6-astra` found that a reserved request could fall back to an unreserved backend and break both caps there. A reserved request now goes only to the backend it reserved on.
  - The holds are published as `gpuaas_gateway_admission_reserved_input_tokens` and `gpuaas_gateway_admission_running_standard_streams`.
  - Nine specs pin it under `-race`. Each of eight mutations fails a spec, including releasing the input on the status line instead of the first body byte.
- **4.3, kind** (`hack/test/rehearse-prospective-admission.sh`). The real gateway and a slow stub engine ran on a fresh kind cluster, routed through an InferenceDeployment. All 8 checks passed:
  - Of four standard requests against a two-stream cap, two were served and two refused with `standard_streams_full`.
  - Two premium requests sent meanwhile were both served.
  - The gauges showed the input held until the first token and the streams until the end, then zero.
  - The engine received priority 0 twice and 1 twice, and nothing unprioritised.
  - Run with a three-stream cap and no priority binding, it failed on its first check, as it should.
- The estimate is ceil(characters / 4), not the engine's count. A registration that compares admitted work must say how it reconciles the two, as M5-b's exact-token correction showed.
- **What this does not establish:** any protection. A stub's latency is its configuration. Whether these mechanisms move the premium tail is the successor's question, and it stays unbuyable until 4.4 has a step-time model to run on.

## Update, 2026-10-07 — 4.4 still has no step-time model

The step-boundary session (`2026-10-06-where-the-late-prefill-waits-step-boundary-session.md`) measured mixed steps directly and fitted the family on measured occupancy, and Q3 failed in the same places as the pilot. So the computational feasibility check still has no model to run on, and item 3 of the ranking stays unbuyable. What the session adds:
- the wait a late prefill pays for the step in flight, measured;
- an instrument a future family can be fitted and tested with.
