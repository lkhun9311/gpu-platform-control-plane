# Does a killed training job resume where it stopped, or only look as if it did?

`experiments/cpu-ddp/` ran two-rank gloo DDP through `MLTrainingJob` and SIGKILLed a rank. The Job retried,
and every retry started again from step 0 (`experiments/cpu-ddp/README.md`). `MLTrainingJob.spec.stateVolume`
has existed since 2026-09-21 so that a replacement Pod can read what its predecessor wrote, and nothing has
used it for a model yet.

"The loss went down again after the restart" is the claim this experiment refuses to accept as evidence.
A run that reloads only the weights also shows a falling loss, while continuing a **different** training
than the one that was interrupted. So the test is stricter: the resumed run must end with the same parameters
as a run that was never interrupted, and two deliberately incomplete resumes must be caught by that test.

## Registered before the first run (2026-10-09)

Everything in this section was written before `hack/checkpoint-resume.sh` was run.

### Setup

- A throwaway three-node kind cluster named `ckpt`, built from this tree with Kueue v0.18.3, the operator and
  the simulated-GPU device plugin, with a one-GPU ClusterQueue. It is deleted at the end.
  (This line first named the long-lived `kind-platform` cluster. The first launch never reached an arm: that
  cluster refused the first `MLTrainingJob` create, because an old validating webhook configuration is still
  registered while its operator serves no webhook. The setup was changed before any arm ran.)
- Each run is one `MLTrainingJob` with `gpuCount: 1`, two gloo ranks under `torchrun` in one Pod, and a fresh
  PersistentVolumeClaim attached through `stateVolume`. The Job's default `backoffLimit` is what replaces a
  failed Pod; the experiment adds no restart logic of its own.
- `train.py` here: `Linear(4, 1)`, SGD with **momentum 0.9**, 40 steps. Each rank draws its batch from its own
  seeded `torch.Generator`, so the data order is state that a resume has to carry.
- A checkpoint is written after every completed step: each rank saves its own file atomically, then rank 0
  publishes the step number in `LATEST` after a barrier, so a reader never sees a half-written step.
- In killed arms rank 1 SIGKILLs itself at the start of step 25, once — a marker on the volume stops the
  replacement Pod from dying again.

### Arms

| arm | killed at step 25 | the replacement Pod loads | what it asks |
|---|---|---|---|
| `uninterrupted` | no | — | the reference |
| `restart` | yes | nothing | what the retry costs with no checkpoint |
| `resume` | yes | weights, optimizer, step, data generator | the claim under test |
| `resume-no-optimizer` | yes | weights, step, data generator | **negative control**: momentum lost |
| `resume-no-data-rng` | yes | weights, optimizer, step | **negative control**: data order restarts |

Three repetitions of each, in that order.

### Quantities

- `final` — rank 0's parameters after step 40, read from its last record.
- `diff` — the largest absolute difference between an arm's `final` and the `uninterrupted` run's `final` of
  the same repetition.
- `steps_run` — completed step records across every attempt of the run; 40 is no repeated work.

### Validity checks (a failure voids the run rather than being reported as a result)

1. **The reference is deterministic.** The three `uninterrupted` repetitions end with identical parameters.
2. **Every killed run was killed once and replaced once.** Exactly one `self_kill` record and exactly two
   attempts (two Pods) in every arm except `uninterrupted`, which has one attempt and no kill.
3. **The ranks stayed synchronised.** In every run's final step, both ranks report the same parameter digest.
4. **The negative controls can fail.** Each of `resume-no-optimizer` and `resume-no-data-rng` must show
   `diff > 1e-4` in all three repetitions. If either matches the reference, the test cannot tell a complete
   resume from an incomplete one and nothing it says about `resume` counts.

### Readings

| arm | reading | registered expectation |
|---|---|---|
| `resume` | `diff` | **≤ 1e-6 in all three** (expected bit-identical: gloo on two float32 values is deterministic) |
| `resume` | `steps_run` | **40**: step 25 never completed before the kill, so no completed step is redone |
| `restart` | `steps_run` | **64**: the 24 completed steps are thrown away and run again |
| `restart` | `diff` | ≤ 1e-6 — starting over from the same seed reaches the same end, only later |
| killed arms | seconds from the kill to the replacement's first step | reported, not judged |

## Result (2026-10-09): VALID, and the resumed run is bit-identical

Run `hack/checkpoint-resume-20261009T020455Z`, scored by `score.py`, which printed `VALID`. The tree was
`1240e34` plus this experiment's own files, uncommitted at run time and committed unchanged with this record;
the operator and the simulator were built from `1240e34` into the throwaway cluster.

| arm | `steps_run` (rep 1 / 2 / 3) | resumed from | `diff` against `uninterrupted` | kill → replacement's first record |
|---|---|---|---|---|
| `uninterrupted` | 40 / 40 / 40 | — | — (the three are identical) | — |
| `restart` | **64 / 64 / 64** | step 0 | 0 / 0 / 0 | 11.4 / 11.7 / 12.2 s |
| `resume` | **40 / 40 / 40** | step 24 | **0 / 0 / 0** | 12.0 / 11.3 / 11.4 s |
| `resume-no-optimizer` | 40 / 40 / 40 | step 24 | **0.358** ×3 | 11.4 / 11.6 / 11.6 s |
| `resume-no-data-rng` | 40 / 40 / 40 | step 24 | **0.245** ×3 | 11.7 / 12.4 / 11.3 s |

- **A resume that restores weights, optimizer, step and data generator ends exactly where the uninterrupted run
  ends** — difference 0, not merely under 1e-6 — and repeats no completed step. Every registered expectation held.
- **Restarting without a checkpoint also ends in the same place, 24 steps later.** Same seed, same data, same
  arithmetic. So "the final model is right" cannot tell a resume from a restart; only the work counter does.
- **Both incomplete resumes were caught**, which is what makes the first line evidence: dropping the momentum
  buffer moved the result by 0.358, restarting the data order by 0.245, and both ran their 40 steps and
  succeeded. Their loss curves would not have flagged anything.
- The platform's part — Job retry, a new Pod on the same volume — took 11 to 12 s from the kill to the
  replacement's first record in all twelve killed runs. That is the Job controller's backoff plus Pod start, on kind.

Before this run, four launches stopped while building the cluster, none of them after an arm had started: the
long-lived cluster's stale webhook (the setup change recorded above); Kueue's webhook refusing the operator's
apply before it served; a cleanup that skipped deleting the cluster and, with its stderr discarded, logged
nothing about why; and the simulator pulling from Docker Hub because the manifest's `:latest` had defaulted its
pull policy to `Always`. Each was fixed in `hack/checkpoint-resume.sh` before the next launch, and none of those
launch directories is kept.

### What this cannot show

- GPUs, NCCL, or a model large enough for a checkpoint's write time to matter. The checkpoint here is bytes.
- Losing a node. The volume is the kind provisioner's local path, which binds to one node, so the replacement
  Pod lands where the first one ran. A real cluster needs storage that survives the node.
- A kill in the middle of writing a checkpoint. The write is atomic by construction, and this run does not
  attack that construction.
- Preemption by Kueue. The kill is a process dying, not the queue reclaiming the GPU.
