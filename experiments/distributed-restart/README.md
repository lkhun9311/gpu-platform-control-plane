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

The negative control resumes from step 6 without the optimizer state and must end with different parameters, and does; without it, an equality test that always passed would look the same.

On 2026-10-31 every case passed, and each of three mutations of `train.py` failed at least one case.
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

The recorded run is `hack/distributed-restart-kind-20261031T144217Z`, of commit `65bf5f16`, and all 34 of its checks pass:

```
python3 experiments/distributed-restart/score_kind.py hack/distributed-restart-kind-20261031T144217Z
```

`rank-failed` resumed from step 5 and `stale-workload` from step 8, as their faults leave them; `node-lost` froze `rst-worker3`, which held rank 1, and attempt 2 resumed from step 3 on `rst-worker` and `rst-worker2`.
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
