# Simulated MIG: the results

The pre-registration is `docs/superpowers/specs/2026-09-24-simulated-mig-profiles.md`, written before any
trial ran. This page reports what happened against the bars it fixed. Raw evidence is under `ex/`
(gitignored); the curated figures are here.

## What was actually asked

MIG has **never been judged** by this project, and cannot be: the account's SCP permits only `t3.*`, `g4dn.*`
and `g5.*`, and neither T4 nor A10G supports it. So this study does not measure MIG. It measures the chain a
platform would have to get right before MIG could be used at all:

    device-plugin registration → Node allocatable → Kueue admission → Job unsuspend → scheduler placement

The profile names are opaque fixtures. `nvidia.com/mig-1g.5gb` is a string shaped like a MIG profile;
nothing here models memory slices, SM partitions, a parent GPU, or which combinations a real card permits.

## Two plugins on one node, which had to work first

The simulator advertised one hard-coded resource on one hard-coded socket. Both are now settings, defaulting
to the old values — and the first attempt at this study proved why that mattered. With the node still
carrying the pre-change image, both profile plugins logged:

```
serving device plugin   {"socket": "/var/lib/kubelet/device-plugins/gpu-simulator.sock"}
registered with kubelet {"resource": "nvidia.com/gpu", "devices": 2}
```

Three instances fighting over one socket, and the node advertised no profile at all. After the rebuild:

| node | allocatable |
|---|---|
| `platform-worker` | `nvidia.com/gpu: 2`, **`nvidia.com/mig-1g.5gb: 2`** |
| `platform-worker2` | `nvidia.com/gpu: 2`, **`nvidia.com/mig-2g.10gb: 2`** |

The platform's own DaemonSet was rolled onto the same image and kept advertising `nvidia.com/gpu: 2` on all
three nodes — checked live, not inferred from the unit test that fixes the same property.

## 20 trials, four arms, zero invalid

Targets are plain `batch/v1` Jobs, not `MLTrainingJob`s: Finding 6 showed the CR reports `Running` whenever
`job.Status.Active > 0`, which counts pending Pods, so using it as the oracle would import a known defect
into a study about something else. Verdicts come from the Workload, `spec.suspend`, and `PodScheduled`.
(That defect was fixed on 2026-09-25 — the phase now reads `job.Status.Ready` — but this study's choice of
oracle stands: it was made while the defect was live, and the verdicts here were never derived from the CR.)

| arm | inventory | quota | verdict | bar |
|---|---|---|---|---|
| **P** positive | W1 `p=2`, W2 `q=2` | `p=1, q=1` | `scheduled` **5/5** | met |
| **Q** admission-negative | as P | `p=1, q=0` | `quota-blocked` **5/5** | met |
| **M** placement-negative | W1 `p=2`, **W2 `p=2`** | as P | `profile-mismatch` **5/5** | met |
| **I** independence | as P | `p=1, q=1` | `quota-blocked` **5/5** | met |

| instrument check | result |
|---|---|
| reservations carrying a key that was not requested | **0 of 20** |
| trials breaching the 5 s collection-gap rule | **0 of 20** (worst gap 1.28 s) |
| observation span | 178.8 – 179.7 s |

### M is the arm worth the trouble

P and M advertise the **same total device count — four** — and differ only in which key the second node
publishes. A check that counts devices in aggregate passes both. Only the per-profile arithmetic separates
them, and it does: the Job is admitted by Kueue and then refused by the scheduler, with `p` capacity sitting
free beside it.

That is the whole claim. Kubernetes does not substitute one extended resource for another, and Kueue's
quota for one profile is not spendable on the other — verified with a control (P) where both checks must
stay silent, and they did, 5/5.

### I separates quota from capacity

A `p` holder exhausts `p`'s quota while `p` capacity is still physically free. The second `p` request waits —
**and keeps waiting after `q` is released**, which is the part that matters: releasing an unrelated profile
does not unblock it. Only releasing the first `p` does.

## A gap this study documents rather than fixes

The admission guards count only `nvidia.com/gpu`: the name is a constant
(`internal/webhook/v1/gpupod_webhook.go:36`), `gpuRequestOf` sums that one key
(`internal/webhook/v1/gpupod_webhook.go:304`), and `GPUJobValidator.Handle` returns early with
`admission.Allowed("")` when the total is zero (`internal/webhook/v1/gpujob_webhook.go:73`).

**A Job requesting only a MIG-named resource reads as requesting no GPU and passes the guard untouched.**
This study measures accounting, not enforcement. A passing result here is not tenant-proof policy.

The quota API is single-key by construction too — `GPUQuotaLimits` carries one `GPUCount` and the reconciler
caps one hard-coded resource — so the per-profile accounting demonstrated here belongs to an
experiment-owned ClusterQueue, not to this platform's `GPUQuotaPolicy`.

## What this licenses

**Does:** on kind, MIG-shaped profiles were advertised as distinct extended resources by independent plugin
instances on one node; Kueue accounted for them independently, holding a request for one profile while the
other's quota stayed free; Kubernetes refused to place a request on a different profile's capacity; and four
pre-registered arms, including a positive control, came out 5/5 with no misclassification, no wrongly-keyed
reservation and no collection gap over 1.28 s.

**Does not:** real MIG creation or profile compatibility; GPU memory, SM or fault isolation;
noisy-neighbour behaviour; CUDA, NVML or DCGM; the NVIDIA device plugin's actual MIG strategies; parent-GPU
topology; the safety or duration of live repartitioning; `MLTrainingJob` or `GPUQuotaPolicy` profile
support; and — because the guards count only `nvidia.com/gpu` — any claim that a tenant cannot bypass this
accounting.

No paid GPU time was used.
