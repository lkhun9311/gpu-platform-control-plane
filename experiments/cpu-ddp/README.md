# Distributed training, actually executed

`docs/11_WHAT_THIS_MEASURED.md` refuses the claim **"I built a training platform"**. The `MLTrainingJob` CRD
exists and admits through Kueue, but nothing had ever trained: the tenant samples run `busybox`, and the one
sample that looks like training names `pytorch/pytorch:2.3.0-cuda12.1-cudnn8-runtime` with
`command: [python, train.py]` while **no `train.py` exists anywhere in the repository**.

This directory runs a real one — two ranks, real gradients, real synchronisation — and says exactly how far
that gets, which is not as far as the refused claim.

## The arithmetic is the evidence

A falling loss proves nothing here. A single rank's loss falls too, and two ranks that never communicate
both report a falling loss while drifting apart. So the model is one scalar weight and the data is chosen so
the correct synchronised answer is a number a reader can check without running anything:

    w starts at 0, x = 1, rank 0 gets y = 1 and rank 1 gets y = 3.
    loss = (w*x - y)^2, so dL/dw = 2*(w*x - y)*x  →  -2 on rank 0, -6 on rank 1.
    DDP averages them: -4. One SGD step at lr = 0.1 gives w = 0.4 on BOTH ranks.

**0.4 is the signature of a working all-reduce.** Without synchronisation rank 0 lands on 0.2 and rank 1 on
0.6.

## What was run

Three runs through the platform's own CRD on kind, plus a queue-contention pair. `cpu-ddp:torch251` is
`python:3.12-slim` with the CPU-only torch wheel — 262 MB against the ~7 GB the repository's sample image
would have pulled, because this experiment never calls CUDA.

| run | rank 0 local grad | rank 1 local grad | after reduction | w after one step | all-reduce futures completed |
|---|---:|---:|---:|---:|---:|
| **synchronised** | −2.0 | −6.0 | **−4.0** | **0.4 / 0.4** | 1 per step |
| **control** (`DDP_NO_SYNC=1`) | −2.0 | −6.0 | −2.0 / −6.0 | **0.2 / 0.6** | **0** |

The control is the part that makes the first row worth reading. Its three checks — `grad_matches`,
`w_matches`, `all_ranks_agree` — all come back false, and `futures_completed` is zero, so the evidence says
in its own numbers that no collective ever completed. A check that cannot fail has not verified anything.

**Entering the comm hook is not evidence; the future completing is.** The hook records the bucket's contents
before reduction (that is where the local −2.0 and −6.0 come from), issues the real `all_reduce`, and counts
the future's completion separately from the call. The write-up quotes the completion.

## Kueue actually withheld capacity

Every earlier run was admitted in the same second it was submitted, which shows Kueue is in the path and
nothing more. Against a `ClusterQueue` whose nominal quota is one GPU:

| time | event |
|---|---|
| 15:50:57 | holder submitted, takes the only GPU |
| 15:50:59 | waiter submitted — **pending immediately** |
| 15:51:00 | `pendingWorkloads=1`, reason recorded |
| 15:52:04 | **waiter admitted 65.1 s after submission**, once the holder released |

Kueue's own reason: `couldn't assign flavors to pod set main: insufficient unused quota for nvidia.com/gpu
in flavor gpu, 1 more needed`. The holder was told to keep the GPU for 60 s; the extra 5 s is Pod startup
and teardown, not queueing.

The computation is entirely on the CPU. The `gpuCount: 1` request exists so the job passes the same
admission path a real training job would, against the simulated device plugin.

## The failure contract, and a deadline that lied about it

Rank 1 sends itself `SIGKILL` at step 2 — a hard kill rather than an exception, because that is how an OOM
or an eviction presents. The Job then works through its `backoffLimit`, which the operator never sets, so it
is Kubernetes' default of **6**.

The first attempt at this run reported a defect that does not exist. The runner waited 600 s, gave up, and
recorded the `MLTrainingJob` stuck in `Admitted` with its GPU quota apparently still held. The retry
sequence takes about **10 m 46 s**, and Kubernetes attached the `Failed` condition at 15:48:01 — **42
seconds after** the runner stopped looking. Re-read afterwards: phase `Failed` with reason `JobFailed`, the
Kueue Workload `Finished=True reason=Failed`, the ClusterQueue back to zero.

Nothing was wrong except the observation window. The wait is now 1500 s, and when it does expire the runner
writes the Job's conditions beside the warning so the next reader can tell a hang from a deadline. Re-run
with that wait, the same injection reached `phase=Failed` on its own: submitted 15:52:45, terminal 16:03:34
— **10 m 49 s**, inside the new budget and well outside the old one.

**What the recovery actually is.** A new Pod, from step 0. There is no checkpoint resume here: the CRD can
attach a `PersistentVolumeClaim`, but nothing saves model, optimiser, step counter or RNG state, so a
resumed attempt would repeat the work rather than continue it. Claiming resume would need all four persisted
and compared against an uninterrupted run.

## Two ranks in one Pod, and why not two Pods

`torchrun --standalone --nnodes=1 --nproc-per-node=2` starts both ranks as processes inside a single Pod.
That is a deliberate limit of the platform, not of the experiment.

`parallelism: 2` would **not** make this distributed. The operator's `BuildJob` sets no `completionMode`, no
`subdomain`, and creates no headless Service — searched for and absent — so two Pods would start, neither
would be given an index, and they would never find each other. A headless Service alone does not fix it: it
resolves to several addresses and elects no rank-0 host, so a c10d rendezvous needs a single store endpoint
that nothing here provides.

Two-Pod rendezvous is therefore a controller change (Indexed Job, `JOB_COMPLETION_INDEX` as rank, subdomain,
a headless Service with `publishNotReadyAddresses`), which also means regenerating CRDs and RBAC and
re-taking the termination canary's Pod-template hash. That is a separate piece of work, and pretending the
current manifest achieves it would be the same kind of claim this document exists to refuse.

## Evidence plumbing, and one defect it caught

The CRD's only volume field is `stateVolume`, which takes a PVC name — no ConfigMap, no `emptyDir`. So the
script prints its JSONL records to stdout and the runner collects them with `kubectl logs`.

Both ranks share that stdout. The first cluster run came back with two JSON objects concatenated on one
line, and the collector died on `Extra data` **while the job itself had succeeded** — a corrupted evidence
file behind a green run. Each record is now written with a single `os.write`, which is atomic below
`PIPE_BUF`, and the collector uses `raw_decode` in a loop so that a split record costs one record rather
than the whole file.

## What this does and does not license

**Does:** on kind, through this repository's own CRD and Kueue admission, two gloo ranks synchronised their
gradients — verified by hand-checkable arithmetic with a control that fails — a queue withheld capacity from
a second job until the first released it, and a hard-killed rank drove the Job through its retry budget to a
`Failed` CR with its quota returned.

**Does not:** NCCL, CUDA, any GPU, multi-Pod or multi-node communication, RDMA, scaling efficiency, model
quality, checkpoint resume, or a claim that this is a training platform. It is a training *job* that the
control plane admitted, ran, and failed correctly.
