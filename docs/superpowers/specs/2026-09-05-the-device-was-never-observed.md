# Observing the device — pre-registration

Date: 2026-09-05 · Pre-registered **before** the hardware is rented. Nothing here may be edited once the
instance is running.

## Why this exists

`queuelabrun -compare` prints a banner on every comparison this lab has ever produced:

    device: NOT OBSERVED -- every GPU-second below is a second of RESERVATION

That sentence is the largest caveat attached to the largest body of work in this repository — 16,731 lines
across `cmd/queuelabrun` and `internal/queuelab`, against 4,580 for the inference harness. It qualifies the
strongest result the lab has: over four interleaved runs on real Kueue, a tenant whose workload ignores
SIGTERM made the quota owner wait **29.0 seconds** longer to get its own quota back and left **30.0 more
GPU-seconds** unused, against a 5.906 second resolution floor.

Every one of those GPU-seconds is a second of *reservation*. Nothing observed a card.

The code to remove the banner is already written and has never been run:

| piece | where |
| --------------------------------- | ---------------------------------------------------- |
| refuses a run with no device evidence | `cmd/queuelabrun/main.go:261,347` (`-require-device`) |
| the observer's inputs | `-device-metrics` (DCGM `/metrics`), `-device-observer` |
| per-worker exporter routing, canary, session directory | `hack/gpu-session.sh`, 594 lines |
| the device loop itself | `internal/queuelab/submit.go:119` — PTX via `cuModuleLoadData` |
| the kernel's compile attestation | `hack/verify-ptx.sh`, targets sm_75 / sm_86 / sm_89 / sm_90 |
| the pre-spend gate | `cmd/queuelabrun/device_preflight.go` |
| the series read | `DCGM_FI_DEV_GPU_UTIL` |

This run buys the one thing none of that can produce on its own: a driver and a card.

**The workload is not a witness.** `internal/queuelab/device.go` states the rule this run has to satisfy:
the trace workload falls back to CPU arithmetic wherever the driver is absent, and its iteration counter
stays healthy while every operation runs on the CPU. Scheduling those Pods onto real hardware does not, by
itself, change the verdict. The observation has to come from something the workload cannot write to.

## What is being bought, and why it is not a $0.65 instance

The reclaim trace is three rows, each requesting one `nvidia.com/gpu`: `a1` holds one for the whole run,
`a2-borrow` takes a second beyond tenant A's quota, and `b1-owner` arrives to reclaim that second one. Two
Pods hold two distinct cards concurrently, which is why the protocol's gate demands `REQUIRED=2` devices on
the worker under test.

A single-GPU instance cannot run it. Time-slicing could advertise two devices from one card, and doing that
would void the run: under time-slicing DCGM cannot say whose work a busy SM was, and the exclusivity clause
refuses to attribute it. The point of this session is attribution.

AWS has no two-GPU instance in the G family, so the smallest that fits is a four-GPU one, with the surplus
two held by an occupier Pod as `hack/gpu-session.sh` already does.

| path | instance | cards | $/h | note |
| ------------------ | -------------- | ------: | ----: | ------------------------------------------ |
| Spot, today | g5.2xlarge | 1 | ~0.45 | **cannot run the protocol** |
| **On-demand, today** | **g4dn.12xlarge** | **4 × T4** | **4.81** | 48 vCPU against a 52 vCPU on-demand quota |
| On-demand, today | g5.12xlarge | 4 × A10G | 6.97 | no advantage here — see below |
| Spot, after a quota case | g4dn.12xlarge | 4 × T4 | 2.22 | Spot G/VT quota is **8 vCPU**, needs 48 |

The T4 is `sm_75` and the shipped PTX targets it. This workload is a small FMA kernel, not an inference
engine, so the A10G buys nothing for this run.

**The Spot path is less than half the price and needs a quota case that costs nothing but days.** If that
case is opened, this run waits for it. The figures below assume the on-demand path, which is the decision
this document does not make.

## What this session does NOT include

**M5-c is not in it.** The sharing matrix needs two vLLM engines on one card, and `hack/m5c-sharing-sizing.md`
records that a T4 gives each engine 3,652 MiB less than it needs — 284 KV tokens against a 7,695-token
contender prompt — so `SharingPlan.Validate` refuses it. It needs an A10G.

That is the smaller reason. The larger one is that the sharing modes require a time-slicing or MPS
device-plugin configuration, and the sizing page is explicit that the exclusive configuration is what
queuelab's device evidence depends on: a session that reconfigures it in place spends hardware to produce
"not attributable" on every run. The two studies want opposite things from the same component and do not
belong in one session.

## The run

One worker, four cards, two held by an occupier. Kueue is the admission engine, the operator provides
`MLTrainingJob` and the quota sync, and `hack/gpu-session.sh` prepares the exporter route and takes the
termination canary before any measurement.

**Factor.** One knob, the same one the kind study varied: whether the victim's workload honours SIGTERM.
Everything else — trace, dose, queue policy, cohort, worker — is identical, and `sameMechanism` refuses a
fixture that differs in any field defining the experiment.

**Arms.** `A-honor` and `A-ignore`.

**Dose.** Grace-bounded only. The kind study ran both regimes and the grace-bounded one produced its
strongest separation; buying the second regime doubles the bill for a comparison this run is not making.

**Repetitions.** Four per arm, interleaved, which is `hack/gpu-session.sh`'s own default and its stated
reason: with n=2 a cell's spread is one number and cannot be told from its own noise.

**Eight runs at roughly three minutes each**, plus cluster preparation and the preflight.

## The gate that runs before any measurement

Charged first because it is the failure that wastes the whole session, and it costs minutes.

1. `nvidia-smi` reports four cards and their memory, and the memory is what the plan assumed.
2. The real device plugin — not `config/device-plugin`, which is the kind cluster's fake one — advertises
   four `nvidia.com/gpu` on the worker.
3. A probe Pod runs the shipped PTX kernel through the CUDA driver and completes without
   `ptx-load-failed`, `ctx-failed`, `no-device` or `alloc-failed`.
4. `DCGM_FI_DEV_GPU_UTIL` scraped through the per-Pod forward shows non-zero utilisation on the card that
   probe Pod held, and zero on a card no Pod held.

**If any of the four fails, the session terminates and buys nothing else.** Item 4 is the one that matters:
the first three can all pass on a machine where attribution is still impossible, and attribution is the
deliverable.

## Pre-registered readings

Evaluated against records `-require-device` accepted. A record it refused is not evidence and is not
scored.

### 1. The banner comes off — POSITIVE, and this is the deliverable

Every run in the set carries a device observation from a source the workload cannot write to, and
`queuelabrun -compare` prints its comparison **without** the `device: NOT OBSERVED` line.

The reported quantity changes meaning with it: GPU-seconds become observed device-seconds rather than
seconds of reservation. That is the whole purchase.

### 2. Reservation and occupancy disagree — POSITIVE, and more interesting than reading 1

The kind study's numbers are reservation. If the observed device-seconds differ from the reserved
GPU-seconds by more than the run's own floor, then reservation was never a proxy for use, and every figure
this lab has published — including the 30.0 GPU-second difference between the arms — described something
other than what it was read as.

Report both quantities side by side for both arms. Do not replace one with the other.

### 3. The arms still separate — the result survives its own instrument

The A-honor and A-ignore difference in owner wait, measured on real hardware, remains larger than the sum
of the two arms' floors. The kind study measured 29.0 seconds against 5.906.

A smaller separation is a finding, not a failure: it would mean the kind result was partly an artifact of
the fake plugin's scheduling, which is exactly what an unobserved device leaves open.

### 4. Nothing is attributable — INVALID, and the session says so

If DCGM cannot attribute utilisation to a Pod on this driver and AMI, no reading above is decidable. Record
what was tried, publish the negative, and do not re-buy this instance type for this purpose.

## Budget and the stop rule

| stage | wall clock | on-demand cost | gate |
| ------------------------------ | ---------: | -------------: | ----------------------------- |
| instance up, driver, cluster | 25 min | $2.01 | — |
| preflight, the four checks | 10 min | $0.80 | all four must pass |
| eight runs, interleaved | 30 min | $2.41 | `-require-device` accepts each |
| evidence off the box, teardown | 10 min | $0.80 | — |
| **total** | **75 min** | **$6.02** | |
| hard stop | 120 min | $9.62 | terminate regardless |

**The hard stop is a timer, not a judgement.** At $4.81 an hour, a session that is going badly costs eight
cents a minute to keep thinking about.

Every artifact leaves the box before teardown. An instance terminated with the only copy of its records on
it has spent the money and bought nothing, which is the same outcome as reading 4 and more annoying.

## What this run cannot say

It observes one card model on one driver on one AMI. It does not measure inference, it does not compare
sharing modes, and it says nothing about whether reservation tracks occupancy for any workload other than
this kernel.

It also cannot make the kind study's twelve records retroactively device-observed. Those runs measured what
they measured. If reading 2 fires, the honest consequence is that the earlier figures are relabelled as
reservation rather than corrected — they were never wrong about reservation.
