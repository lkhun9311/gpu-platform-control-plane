# The trainer's side of a whole-job restart

A restartable distributed `MLTrainingJob` (`distributed.maxRestarts` above 0) starts every rank again after a failure, on whatever nodes Kueue admits it to.
The controller guarantees that no rank of the old attempt still runs and gives the new one `TRAINING_ATTEMPT`.
What the ranks load is the workload's business, and `train.py` here is the protocol this repository's experiments will use, from `docs/superpowers/specs/2026-11-01-distributed-restart-design.md`.

`experiments/checkpoint-resume/train.py` is not changed.
Its results are registered and published, and the file they were measured with stays as it was.

## What the protocol refuses

| what could be loaded | why it would be wrong | what stops it |
|---|---|---|
| a checkpoint some ranks finished and others did not | the job died between the shards and the manifest | rank 0 writes `MANIFEST` only after every rank reported its shard's hash and size, and a checkpoint without one is never offered |
| shards of different steps | one rank ran ahead | every rank sees every report, so all refuse the checkpoint together and `LATEST` stays where it was |
| a shard that changed after publication | a torn or truncated file | each rank rehashes its own shard against the manifest before loading |
| two different checkpoints on two ranks | each rank picked its own newest | rank 0 offers, every rank answers, and a `MIN` all-reduce decides; all load the offer or all move to the next |
| a checkpoint path written twice | a rollback reaching the same step again | every checkpoint directory is `a<attempt>/<step>-<uuid>`, and temporary names are unique too |

A volume with nothing on it is an explicit `restart_from_zero` record, never a resume.

## What each rank saves

Every rank writes its own shard with its whole training state, even where DDP replicates it, because a resume that restores only what a loss curve shows can still feed different batches or different dropout masks.

| component | what it is | why a resume needs it |
|---|---|---|
| `model` | a 4-8-1 MLP with dropout 0.25 | the weights |
| `optimizer` | SGD with momentum 0.9 | the momentum buffers and the current learning rate |
| `scheduler` | `StepLR`, halving the learning rate every 4 steps | where the next decay falls |
| `sampler` | the epoch and the number of batches already taken in it | `DistributedSampler(shuffle=True)` over a fixed 40-sample dataset gives each rank 5 batches of 4 an epoch, in an order seeded by the epoch |
| `rng` | the global CPU RNG state | dropout draws its masks from it |
| `cuda_rng` | every CUDA device's RNG state, only when CUDA is available | not exercised: the image is CPU-only, so this path has never run |

The global RNG is restored after the model, the optimizer and the scheduler are built, so nothing drawn while constructing the attempt moves it.
Batches are taken from the sampler's order directly rather than through a `DataLoader`, because each new `DataLoader` iterator draws a seed from the global RNG (checked in the image), and re-entering an epoch on resume would spend a draw the uninterrupted run never made.

`CKPT_LOAD` selects what a resume restores: `full`, `none`, or one negative control per component, `no-optimizer`, `no-scheduler`, `no-sampler` and `no-rng`, each restoring everything except its component.

## Checked locally

`check_protocol.py` runs `train.py` under `torchrun`, two gloo ranks, in the `cpu-ddp:torch251` image, with a fresh directory standing in for the volume.

```
python3 experiments/distributed-restart/check_protocol.py
```

Each case kills or corrupts at one point, starts a second attempt and requires it to resume from the step named below and to end with exactly the parameters of a run never interrupted (12 steps).

| case | resumes from |
|---|---|
| rank 1 killed before its shard of step 6 is synced | 5 |
| rank 0 killed with every shard of step 6 written, before the manifest | 5 |
| rank 0 killed with the manifest of step 6 written, before `LATEST` | 5, because `LATEST` is what is offered first |
| rank 0 killed right after `LATEST` names step 6 | 6 |
| rank 1 labels its shard of step 6 as step 7 | 5; both ranks record the refusal |
| rank 1's shard of the published step 6 truncated | 5; rank 0 accepts its own shard, rank 1 rejects its own, and both move on |
| nothing on the volume | `restart_from_zero` |

A resume from step 5 starts at the second epoch's first batch; a resume from step 6 starts one batch into it, with the learning rate halved once and its next decay due after step 8.

Each negative control is killed right after `LATEST` names step 6, resumes from it without one component, and must end with parameters different from the reference; without them, an equality test that always passed would look the same.

The learning rate, epoch and position below are read from each control's `start` record in one run on 2026-11-01, where `full` started at learning rate 0.025, epoch 1, position 1; the rest follows from the code.

| control | resumes without | how it starts |
|---|---|---|
| `no-optimizer` | the optimizer | learning rate 0.05 instead of 0.025, and no momentum |
| `no-scheduler` | the scheduler | learning rate 0.025, but a fresh `StepLR` decays 4 steps after the resume, after step 10 rather than step 8 |
| `no-sampler` | the epoch and position | epoch 0, position 0 instead of epoch 1, position 1 |
| `no-rng` | the global RNG | the RNG as model construction left it, so different dropout masks |

On 2026-11-01 every case passed, all four controls among them, and the check exited 0.
Four mutations of `train.py`'s `full` resume each failed all six cases that compare a full resume with the reference (`kill-before-fsync`, `kill-before-manifest`, `kill-before-latest`, `kill-after-latest`, `skew` and `torn shard`): not restoring the scheduler, not restoring the sampler, restoring the epoch but not the position within it, and not restoring the global RNG.
A fifth made `no-rng` restore the RNG as `full` does, and only `no-rng negative control` failed, with "matched the reference": a control that drops nothing is reported, not passed.
Each mutation was reverted, and `train.py` was checked to be byte-identical to the committed file.

On 2026-10-31, with the trainer that saved only the model, the optimizer and a per-rank data generator, every case passed, and each of three mutations of `train.py` failed at least one case.
Accepting a skewed manifest failed the skew case: no rank recorded a refusal.
Skipping the shard hash failed the torn-shard case: no rank rejected the truncated step 6, and rank 0 recorded a resume from it.
Letting each rank decide alone also failed the torn-shard case, as a deadlock: rank 0 loaded step 6 while rank 1 waited for the next offer, and the attempt timed out.
A timed-out attempt is a failed case, and its container is removed by name; the first version of the check crashed on the timeout instead, which reads as neither a pass nor a catch.

## Through the controller, on kind

`hack/distributed-restart-kind.sh` runs the same trainer as a restartable `MLTrainingJob` (`worldSize: 2`, `maxRestarts: 1`) on a throwaway cluster `rst`, and `score_kind.py` reads what it recorded.
Kueue is v0.18.3, as on EKS, and the operator runs with its admission webhooks.
Three workers each advertise one simulated GPU, so the two ranks run on two nodes and two are left when one is lost.
Every worker mounts one host directory, offered as a `ReadWriteMany` hostPath volume: ranks on different nodes share a file system, without NFS's semantics.
The operator, Kueue, cert-manager and CoreDNS are pinned to the control-plane node, so a frozen worker can take ranks with it and nothing else.

| case | what happens | what must hold |
|---|---|---|
| `reference` | no fault | succeeds on attempt 1; its final parameters are the reference |
| `rank-failed` | rank 1 is `SIGKILL`ed with its shard of step 6 unsynced | attempt 1 stops on `RankFailed`, attempt 2 resumes from step 5 under a rendezvous name attempt 1 never had, and ends with the reference's parameters |
| `stale-workload` | rank 0 dies at step 8 while a finalizer holds attempt 1's Workload for 60 s | no Job of attempt 2 exists while it is held; then the same as above |
| `deactivated` | the Workload is deactivated by hand while both ranks run | no second attempt and no trigger over the following minute |
| `node-lost` | rank 1's node container is frozen, then its Node deleted | no attempt 2 while its Pods remain, nor after, until the node is named in `platform.lkhun9311.github.io/fenced-nodes`; attempt 2 runs on the other two nodes and ends with the reference's parameters |

The recorded run is `hack/distributed-restart-kind-20261101T003147Z`, of commit `e2d21e9d`, whose trainer saves everything listed above, and all 34 of its checks pass.
An earlier run, `hack/distributed-restart-kind-20261031T144217Z` of commit `65bf5f16`, also passed all 34 with the trainer before it, which saved the model, the optimizer and a per-rank data generator only; it is kept as the record of that trainer.

```
python3 experiments/distributed-restart/score_kind.py hack/distributed-restart-kind-20261101T003147Z
```

In both runs `rank-failed` resumed from step 5 and `stale-workload` from step 8, as their faults leave them; `node-lost` froze `rst-worker3`, which held rank 1, and attempt 2 resumed from step 3 on `rst-worker` and `rst-worker2`.
Each restarted case ended with exactly the reference's parameters.
The scorer refuses a run of uncommitted code.
Five rehearsals on an uncommitted tree came before the recorded run, and two found defects in the harness, not in the controller.
The trainer was started with `exec`, which made it the container's PID 1, and the kernel drops a `SIGKILL` that PID 1 sends itself: the killed ranks trained on and their jobs finished on attempt 1.
`train.py` now refuses to fire a kill fault as PID 1.
And one rehearsal froze the worker a controller was most likely running on, after which nothing reconciled the job; where the controllers ran was not recorded, which is why it is now.

## What this does not show

Visibility across NFS clients, where a file renamed on one node may not yet appear on another, is the reason for the bounded retry in `shard_ok`; neither the local check nor kind exercises it, and the shared volume on EFS is where it would.
A frozen node is not a node that keeps running cut off from the API server: its rank stops writing when it is frozen, so a rank still writing to the shared volume after the next attempt has started is not exercised.
That is what the fencing acknowledgement exists for, and the barrier is shown to wait for it, not shown to have been needed.
One run of each case is evidence that the path works, not a rate.
Saving and restoring the CUDA RNG is written but has never run, because every check here uses the CPU image.
