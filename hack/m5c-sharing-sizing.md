# Which card the sharing matrix can run on, decided before renting one

M5-c compares sharing modes: one engine with the card to itself, against two engines sharing it through
time-slicing and through MPS. The comparison only means something if both engines can actually serve, and
that is an arithmetic question with a hardware answer.

The arithmetic is in `internal/bench/sharing.go` rather than on this page, because a page cannot refuse a
plan and `SharingPlan.Validate` can. What follows is what it decided.

## Time-slicing and MPS do not partition memory

This is the whole trap. The device plugin advertises more `nvidia.com/gpu` than the node has cards, and
nothing about memory changes: the processes draw on one pool. Each engine's `--gpu-memory-utilization` is a
slice of the same total, and two engines at 0.90 claim 1.8 cards from a machine that has one.

Nothing warns you. The second engine starts, profiles, finds almost no room, and serves. The run produces
latencies, and they describe the allocator.

## The T4 cannot host the matrix

| card | engines | budget/engine | KV/engine | KV tokens/engine | |
|---|---|---|---|---|---|
| T4 16GB | 1 | 14,592 MiB | 7,306 MiB | 207,815 | fits — this is M5-b |
| **T4 16GB** | **2** | **7,296 MiB** | **10 MiB** | **284** | **refused** |
| A10G 24GB | 1 | 21,877 MiB | 14,591 MiB | 415,021 | fits |
| **A10G 24GB** | **2** | **10,938 MiB** | **3,652 MiB** | **103,887** | **fits** |

Weights are 5,886 MiB (measured: the sum of the safetensors on the Hub) and overhead is 1,400 MiB
(estimated, the same figure `hack/m5b-vllm-sizing.md` flags). A contender prompt is 7,695 tokens, so the
T4's 284 tokens per engine is **less than one prompt**. That arm would spend its life evicting.

`Validate` refuses it, and refuses the near miss too: a cache that cannot hold four contender prompts is
not a smaller experiment, it is a different one. It also distinguishes the two failures, because they
produce different mornings — a Pod that never became ready, and a Pod that did while its numbers were about
recomputation.

## So M5-c runs on g5.xlarge

`g5.xlarge` is one A10G and **four vCPU**, the same as `g4dn.xlarge`. The quota granted for
ap-northeast-2 on 2026-08-24 was 8 vCPU against a request for 96, and it is the G-family aggregate, so it
covers g5 as well: **M5-c is not blocked on the support case either.**

**Open decision, not made here.** M5-b is sized for a T4 and M5-c needs an A10G, so as things stand the two
milestones measure on different silicon and cross-milestone comparison is confounded. Moving M5-b to
g5.xlarge as well would remove that, cost the same vCPU, and invalidate every derived figure in
`hack/m5b-vllm-sizing.md` — including one that is not just a number: an A10G is sm_86 and supports
bfloat16, so `--dtype=half` stops being a startup condition and becomes a choice. Worth doing, worth doing
deliberately.

## What the matrix must not claim

`config/nvidia-device-plugin/daemonset.yaml` already says why, and it applies here:

> under any of those a device's utilisation is shared and the exclusivity clause refuses to attribute it

Under time-slicing and MPS, DCGM cannot say which engine's work a busy SM belonged to. So the matrix
reports what the **clients** observed — per-engine latency and throughput, which is unambiguous — and does
not report per-engine GPU utilisation. The question it answers is what tenants experience under each mode,
not how the SMs were divided.

That also means the sharing modes need their own device-plugin configuration, kept separate from the
exclusive one rather than replacing it. The exclusive config is what queuelab's device evidence depends on,
and a session that reconfigures it in place spends hardware to produce "not attributable" on every run.

## Still unmeasured

- The 1,400 MiB overhead is the only estimated input, and every token figure inherits it. vLLM prints the
  block count it allocated; check `KVTokensPerEngine` against it in the session's first minute.
- Card memory is vendor-reported. Confirm with `nvidia-smi` before deriving anything from it — a card that
  reports less than assumed is the case that silently produces a useless run rather than a failed one.
- Whether MPS is even usable through the device plugin on this driver and AMI. That is a session question,
  and the exclusive arm plus time-slicing is a publishable matrix without it.
