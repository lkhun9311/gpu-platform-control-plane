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

## What this does not show

Every rank runs in one container on one local disk.
Visibility across NFS clients, where a file renamed on one node may not yet appear on another, is the reason for the bounded retry in `shard_ok`, and it is not exercised here.
That, a rank killed by losing its node rather than by `SIGKILL`, and the restart driven by the controller are the kind cases with an in-cluster NFS server, step 4 of the design.
