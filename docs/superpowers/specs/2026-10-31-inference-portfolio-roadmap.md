# Remaining work after 2026-10-31: an inference-first roadmap, the llm-d gaps it builds on, and fragmentation on real GPUs

Written 2026-10-31. Status: **DRAFT, none registered, nothing run.**
The owner approved one item on 2026-10-31: the free reproduction of the llm-d failover gaps (item B0 below, "작업(B의 무료 재현) 승인").
Every paid item needs its own registration and its own approval; nothing here is one.

This page orders what is left so the repository's next results serve LLM inference platform work, and says for each item what already exists, what it would add and what it would not license.
The hiring evidence behind the order is recorded outside this repository and is not a claim this page makes.

## What already stands

| result | where | what it licenses |
|---|---|---|
| A competing tenant on one engine costs the premium tenant 23.0x its isolated TTFT p99 | `docs/11_WHAT_THIS_MEASURED.md`, Finding 3b | one A10G, one engine version, one load |
| HoldCap cuts that p99 to about 0.30 of no admission, 0.28 to 0.31 on the EKS product path | Finding 9 | the same scope; a tuned fixed spacing tied it at the load it was tuned for |
| Prefix-aware routing raised the engines' hit ratio from about 0.55 to 0.82 and the p50 to about 80 ms, and its registered verdict was NOT MET on p99 | `2026-10-27-prefix-aware-routing-design.md`, "Run 2" | two A10Gs, one gateway replica, four frozen traces |
| Reservation and use came apart by a factor of four | Finding 1 | utilisation of two solo arms; nothing about interference |
| A job the platform could not place was reported `Running`, and packing configuration removed or caused stranding depending on the mix | Findings 6 and 8 | **simulated devices on kind only** |

## The gap the HA work builds on: llm-d-router at `18637db2`

Read from source on 2026-10-31, llm-d/llm-d-router at commit 18637db291b4b6f9004097dc5cf9248860f65f9f.
Each line is a property of that commit, not of llm-d in general.
The citations are upstream paths, linked rather than spelled as names, because none of them exists in this repository.

- Flow-control queues and fairness accounting are per Endpoint Picker replica and in memory ([operations.md lines 52-55 and 79-80](https://github.com/llm-d/llm-d-router/blob/18637db291b4b6f9004097dc5cf9248860f65f9f/docs/operations.md#L52-L80)).
- There is no atomic cluster-wide admission quota ([operations.md lines 82-84](https://github.com/llm-d/llm-d-router/blob/18637db291b4b6f9004097dc5cf9248860f65f9f/docs/operations.md#L82-L84)).
- During the 10 to 30 s leader switchover the default fail-open mode sends requests past flow control ([operations.md line 378](https://github.com/llm-d/llm-d-router/blob/18637db291b4b6f9004097dc5cf9248860f65f9f/docs/operations.md#L378)).
- A leader that lost its lease keeps accepting requests for its drain timeout ([runner.go lines 350-358](https://github.com/llm-d/llm-d-router/blob/18637db291b4b6f9004097dc5cf9248860f65f9f/cmd/epp/runner/runner.go#L350-L358)), so nothing fences it.
- Weighted fair share charges a tenant at end of stream, so a stream cut by an Endpoint Picker failure is never charged.
- The approximate prefix index is keyed by a Pod's namespace and name, not its UID ([types.go lines 54-55](https://github.com/llm-d/llm-d-router/blob/18637db291b4b6f9004097dc5cf9248860f65f9f/pkg/epp/framework/plugins/requestcontrol/dataproducer/approximateprefix/types.go#L54-L55)).
- Related upstream work: #3345 (warm-start routing state, open), #3710 (leaked in-flight entries, open), #1593 (shared scheduling state RFC, closed 2026-09-30), PR #3064 (drain on lease loss, merged).

This repository's gateway has the same limitation: HoldCap reservations and the prefix index live in one process (`docs/05_LLM_SERVING_GATEWAY.md`).
So the HA work extends llm-d and contributes the failure scenarios upstream rather than rebuilding a router.
None of the above is a claim that the gap is unknown upstream; that is checked in B0 before anything is called new.

## Items, in order

### B0. Reproduce the llm-d failover gaps without a GPU (approved, free)

On kind, with `llm-d-inference-sim` in place of vLLM, measure what default llm-d HA does to tenant protection when the Endpoint Picker fails:
1. kill the leader under a two-tenant load with weighted fair share, and measure each tenant's share and the flooding tenant's admitted work during the switchover;
2. take the lease from a leader that is still running, and measure whether it dispatches new requests while the new leader also does;
3. kill the Endpoint Picker while one tenant holds long streams, and measure whether that tenant's accounting is charged.

Each scenario must first be shown to fail by itself (a control in which the fault is absent shows no violation), and every result counts offered, admitted, refused and completed requests, because a scenario that refuses everything shows no violation either.
It licenses statements about the pinned commit and the simulator, not about GPU latency.

### B. Failure-consistent tenant admission on top of llm-d

Fence stale authority at an admission or forwarding boundary, a degraded per-tenant quota while the Endpoint Picker is down, fairness accounting carried across replicas and failover, and a reservation for streams whose outcome is unknown, reconciled afterwards.
Baselines: default llm-d HA and a plain centralised admission service.
Primary measure: quota overshoot and share against weight during a fixed failure window, reported beside offered, refused, completed and SLO-qualified work.
Paid validation only after B0 and CPU state-machine tests pass: three single-GPU nodes, one session.

### A. Mixed-workload inference gateway, and an SLO-keeping fleet consolidation study

Bulk and interactive work on one fleet, an external or partner model as bounded fallback, per-tenant token cost, and replica count driven by TTFT, TPOT and KV pressure.
The consolidation study asks how far inference work can be packed (dedicated engines, shared with HoldCap, time-slicing, a tensor-parallel model across two GPUs) before the premium SLO breaks, measured as a utilisation-against-p99 curve under a fixed offered load.
It starts from what is measured: Finding 1's fourfold gap, the time-slicing ladder that met a 139 ms target at 1.16 and 2.31 req/s and breached at 4.61, and Finding 9.
Cost per item must carry a quality criterion fixed before any run.

### C. A launch and regression gate for inference

Shadow traffic, canary and automatic rollback across engine-version and quantisation changes, judged by correctness and performance baselines, with cold start decomposed (the last engine start on record took 388 s, Run 2 of the routing study).
Primary measure: seeded regressions caught and missed, false alarms, time to rollback.

### B4. Incarnation-aware cache routing

Key the prefix index by Pod UID and engine incarnation, and allow HoldCap per Pod with prefix affinity.
Correctness (the stale-affinity window after an engine restart) is measured separately from performance (p99 and hit ratio), and HoldCap and affinity are ablated one at a time.
It does not assume HoldCap explains the NOT MET p99; that is what the ablation asks.

### F. Fragmentation and stranding on real GPUs

Findings 6 and 8 ran on simulated devices; their own "what it needs" row asks for real devices, an arrival process and more than three workers.
What changes on AWS, and has to be registered before a cell:

- **Layouts are not free to choose.** The SCP allows g4dn and g5; their nodes carry 1, 4 or 8 GPUs, so the 2-device worker of C1 and the 3- and 2-device workers of C2 and C3 do not exist as instances. A layout is built from a 4-GPU node with some devices held by a placeholder Pod, and that placeholder is part of the treatment, not invisible: it is a workload the scheduler sees.
- **The device plugin is NVIDIA's, not the simulator.** Advertised counts, health and restart behaviour come from the real plugin; Finding 6's phase fix (the phase reads `job.Status.Ready`) must be re-checked on it rather than assumed.
- **Utilisation becomes observable.** DCGM reports what stranded devices did, so stranded GPU-seconds can be priced, which simulated devices could not give.
- **An arrival process replaces the fixed sequence**, or the run repeats the registered sequences and says it did.
- Cheapest layout to price first: g4dn.12xlarge (4 T4; On-Demand $4.812/h on record, `docs/09_AWS_INFRA_ARCHITECTURE.md`) against g5.12xlarge (4 A10G), read by the session's price gate.

It licenses statements about the real plugin and scheduler on those layouts, not about multi-GPU-per-node fragmentation at fleet scale.

## Defects and gaps to close along the way

- `docs/05_LLM_SERVING_GATEWAY.md` said routing was unmeasured after Run 2 measured it; corrected in the change that adds this page.
- `GpuSharingBenchmark` still has no status writer, so a result is the harness's and not the CR's.
- `internal/gateway/priority.go` maps every non-premium tier to one engine priority; A needs a batch class with its own meaning.
- The CRD refuses HoldCap on the prefix-cache profile; B4 lifts that only after a combined profile passes conformance on a real engine.
- The gateway is fixed at `replicas: 1`; B decides how admission state survives more than one.
