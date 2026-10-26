# Future work candidates after run 3: a second card, resume after preemption, and Finding 10's open cells

Written 2026-10-22. Status: **DRAFT, none registered, nothing run.**
Each section says what it would add, what must change, how it would be rehearsed or run, and what it would not license.
The first throughput figure and more than one GPU per Pod are a separate draft: `docs/superpowers/specs/2026-10-22-multi-gpu-per-pod-throughput-design.md`.
Sections B and C cost nothing to run; section A is paid and needs the owner's approval and its own registration.

## A. A second card model: T4 on g4dn

### What is on record

- The SCP allows g4dn and g5 only (`docs/superpowers/specs/2026-09-05-the-device-was-never-observed.md:70-72`), so the T4 (g4dn) is the only second NVIDIA card this account can launch.
- g4dn.12xlarge (4 T4, 48 vCPU) is the `gpu` node group's default type (`infra/aws/cluster/variables.tf:126`), On-Demand $4.812/h on record (`docs/09_AWS_INFRA_ARCHITECTURE.md:382`), and scored 1 of 10 for Spot placement in every zone on 2026-09-05 (`docs/superpowers/specs/2026-09-05-the-device-was-never-observed.md:60`).
- No g4dn.xlarge price is recorded anywhere in the tree; it must be read by the session's price gate before a budget is written.
- Every paid GPU result in this repository so far ran on A10G: device observation and Finding 1 on g5.12xlarge, serving and Finding 9 on g5.xlarge and g5.2xlarge, and run 3 on g5.xlarge.
- `hack/verify-ptx.sh:22` already compiles the queuelab kernel for `sm_75`, the T4's architecture, so the burn kernel needs no change.

### Which study gains most

Finding 9's own "what it needs before it generalises" row names a second card model (`docs/11_WHAT_THIS_MEASURED.md`, the table after the findings).
It is the study whose claim is most card-specific: hold-cap protects the premium tail at one load, and that load was frozen from A10G prefill times, so the same trace on a slower card is a different load, not the same experiment on other hardware.

So a T4 run of Finding 9 is not a replay. It needs, registered before it runs:
- the load re-derived on the T4 by the same rule that froze the A10G load, from a calibration cell on the T4 itself, so "the same relative load" is a measured statement;
- the engine as it runs there: `config/vllm/deployment.yaml` pins `--dtype=half`, which the T4 supports, and `--gpu-memory-utilization=0.90` of 16 GB rather than 24 GB, so the KV pool is smaller and the contention point moves;
- the attention backend vLLM selects on `sm_75`, read from the engine's start-up log and recorded, because it is not the A10G's and a difference could be the backend rather than the card (which backend vLLM v0.27.1 picks on Turing is not established in this tree and must be read, not assumed).

The second most useful is device observation (Finding 1, reservation against use), because DCGM's utilisation reading is what that finding rests on and has been read on one architecture only.
It is less useful than Finding 9 because Finding 1's claim is about the gap between reservation and use, which a second architecture would confirm or not, without a re-derived load.

Sharing (Finding 3) gains little: neither card supports MIG, which is what Finding 3's row asks for.

### What a T4 run would and would not license

It would license a statement about the same rule on a second card at a load derived the same way.
It would not license "hold-cap generalises across cards" from two cards, nor any comparison of the two cards' absolute latencies, which differ by design.

### Cost shape, for the owner

One g4dn.xlarge in `gpu_single` would replace the g5.xlarge the serving sessions use; its price must be read first.
A g4dn.12xlarge for four T4s is the default `gpu` type and needs the 48 of 52 vCPU the g5.12xlarge does, so it cannot run beside one.

## B. Checkpoint resume after Kueue preemption (kind, free)

### What is on record and what is not

`experiments/checkpoint-resume/` showed, on kind, that a resume restoring weights, optimizer, step and data generator ends bit-identical to an uninterrupted run, and that two incomplete resumes are caught.
The interruption was the process killing itself; its own record says it does not show "Preemption by Kueue" (`experiments/checkpoint-resume/README.md`, "What this cannot show").
Under preemption the path is different at every step: Kueue evicts the Workload, the Job is suspended, the Job controller deletes the running Pod with SIGTERM and the grace period (capped at 120 s by `internal/webhook/v1/gpupod_webhook.go:81`), and only on re-admission is a new Pod created.
None of that path has carried a checkpoint here.

### The mechanism, with no change to the CRD

Preemption by reclaim within the cohort, as queuelab's a1 / a2-borrow / b1-owner trace already uses (`internal/queuelab/trace.go:125-127`):
- two tenants, A and B, each with nominal quota 1, in the shared cohort with `reclaimWithinCohort: Any` (`internal/controller/kueue_quota.go:87-88`);
- a kind cluster with two simulated GPUs;
- A submits a filler job (inside its quota), then the training job J, which borrows B's unit;
- after J has completed some steps, B submits a short job; Kueue reclaims by preempting a borrowing workload of A's, and J, admitted last at equal priority, is the expected candidate (recorded, not assumed: which workload Kueue picks is read from its `Evicted` condition);
- B's job finishes; J is re-admitted and its new Pod resumes from the claim.

J is the checkpoint-resume workload unchanged in substance: one Pod, `torchrun --standalone --nproc-per-node=2`, gloo, `stateVolume` on a fresh claim.
A claim on kind's local-path provisioner binds to one node, so the replacement Pod is pinned where the first ran and waits for that node's device; the wait is recorded and not judged.

### What must change

- **`train.py` (`experiments/checkpoint-resume/`): a SIGTERM record.** The arms so far ended by SIGKILL from the process itself, so no handler was needed. Under preemption the evidence that the platform ended the attempt is a `sigterm` record before the last step record, written the way `experiments/cpu-ddp/train.py`'s `on_sigterm` writes one. Under `torchrun`, the launcher receives the signal and forwards it to the workers, which are not PID 1; that forwarding is torch's, is not established in this tree, and is a prediction the run checks.
- **The status the platform reports (design only, not built).** Across a preemption `computeMLTJPhase` reads the Workload as not admitted and reports `Pending` (`internal/controller/mltrainingjob_controller.go:356-362`), with nothing saying the job was preempted rather than never admitted. `admittedAt` and `runningObservedAt` are written once, so the second attempt's admission-to-running wait is not reported. A `Preempted` condition carrying the Workload's eviction reason and a count of evictions would make the CR say what happened; whether to build it is a decision, and the experiment should first measure what the CR says without it.
- **Distributed jobs are out of reach as specified.** `stateVolume` cannot be combined with `distributed` (`api/v1/mltrainingjob_types.go:36`), so a multi-Pod job has no claim to resume from. That is the next design, not this one.

### The question that matters most for distributed jobs, and costs one cell

Does a Pod the Job controller deletes because the Job was suspended count toward `.status.failed`?
A distributed job sets `backoffLimit: 0` (`internal/controller/mltrainingjob_distributed.go:85-86`). If a preemption's deletions count as failures, a preempted distributed job is marked `Failed` instead of waiting for re-admission, and the platform turns every preemption of a multi-Pod job into a lost job.
This tree does not establish the answer; it is read from the Job's status after one preemption of a two-rank `distributed` job (with no checkpoint, since only the Job's accounting is asked).

### Arms

| arm | interruption | loads | asks |
|---|---|---|---|
| `uninterrupted` | none | — | the reference, as before |
| `preempt-resume` | Kueue reclaim | weights, optimizer, step, data generator | the claim under test |
| `preempt-restart` | Kueue reclaim | nothing | the work a preemption costs with no checkpoint |
| `preempt-no-optimizer` | Kueue reclaim | weights, step, data generator | negative control |
| `preempt-distributed` | Kueue reclaim of a two-rank `distributed` job | — | the `.status.failed` question above |

Three repetitions of the first four, one of the last, in that order.

### Readings and validity

- `diff` and `steps_run` as `experiments/checkpoint-resume/README.md` defines them; `preempt-resume` must end at `diff ≤ 1e-6` and repeat at most the one step the SIGTERM interrupted.
- Valid only if: the `Evicted` condition on J's Workload names preemption; exactly two Pods of J were created; the first carries a `sigterm` record; the negative control shows `diff > 1e-4`.
- Recorded and not judged: seconds from B's submission to J's eviction, to J's first Pod's deletion, to J's re-admission, and to the replacement's first step; and what J's CR said throughout.

### What it would and would not license

It would license: on kind with Kueue v0.18.3, a single-Pod job preempted by cohort reclaim resumes exactly from its checkpoint through `stateVolume`, and what the platform reported across it.
It would not license: GPUs, a node lost with its storage (local-path binds to one node), a kill during a checkpoint write, priority-based preemption (the CRD sets no priority class), or anything about distributed jobs beyond the one accounting question.

## C. Finding 10's open cells: more ranks, a competing job, and `blockAdmission` (kind, free)

### What is on record

Finding 10 measured one two-rank job stranded by one occupied device, with Kueue's `waitForPodsReady` off and at a 120 s timeout with `blockAdmission: false` (`docs/superpowers/specs/2026-10-21-distributed-partial-placement-design.md`, "Settings and scenarios").
Its own record names what it does not cover: "more than two ranks, other jobs in the cohort, `blockAdmission`, or gang placement" (`docs/11_WHAT_THIS_MEASURED.md`, Finding 10, "What it does not say").
The phase fix that followed was confirmed on one `off` run per scenario at a 300 s window, not under the registered 600 s window nor with `ready-timeout`.

### Questions

1. **The fix under the registered conditions.** Rerun Finding 10's registered design unchanged, eight runs, at the current controller. This is first because every later cell reads the phase the fix now writes.
2. **More ranks.** With `worldSize: 4`, one simulated GPU on each of four workers and one squatted, does the CR stay `Admitted` while three of four ranks are Ready, and does the timeout evict and re-admit as at two ranks? The harness needs a four-worker kind config; `hack/kind-config.yaml` has two.
3. **A competing job in the cohort.** While the stranded job holds its quota, tenant B submits a placeable one-GPU job whose own nominal quota is 0 within a cohort whose total is the stranded job's 2 plus 1. Is B admitted by borrowing, does it wait, and does the stranded job's reservation delay it? Measured as B's submission-to-admission and admission-to-running times, under `off` and `ready-timeout`.
4. **`blockAdmission: true`.** Kueue then admits no further workload until the admitted one is ready. The prediction to register: B waits until the stranded job is evicted by the timeout, so B's admission lags its submission by about the timeout, where with `blockAdmission: false` it is admitted at once if quota allows. Whether that holds in v0.18.3, and what each CR says during the wait, is what the cell reads.

### Settings and scenarios

The four `waitForPodsReady` settings below, each the release's `config.kueue.x-k8s.io/v1beta2` document with only that stanza added or removed, as `hack/distributed-partial-placement.sh` already does:

| setting | stanza |
|---|---|
| `off` | absent |
| `ready-timeout` | Finding 10's: `timeout: 120s`, `recoveryTimeout: 120s`, `blockAdmission: false`, `requeuingStrategy` as before |
| `block` | the same with `blockAdmission: true` |

Scenarios: `never` (the squatter stays), `freed-300s` (deleted at 300 s), each with and without B's competing job, at `worldSize` 2 and 4.
That is 3 × 2 × 2 × 2 = 24 cells; two repetitions each at 600 s is about 8 hours of kind time, so the registration should cut it, and the natural cut is to run `worldSize: 4` only with `never`.

### What must change

- The harness: a four-worker kind config; a second tenant and its quota policy; the `block` setting; B's job and its timestamps in the collector.
- The scorer: B's times; and the per-attempt quota hold, generalised from two ranks to N.
- The controller: nothing. These cells measure the platform as it is.

### What it would and would not license

It would license, on kind with simulated devices and Kueue v0.18.3: what the CR reports and how long quota is held for a stranded job of two or four ranks, how a placeable job in the same cohort fares beside it, and what `blockAdmission` changes.
It would not license anything about GPUs, NCCL, real scheduling latency, gang scheduling (none of these settings is gang placement), or Kueue versions other than v0.18.3.
