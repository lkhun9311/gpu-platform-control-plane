# The trainer's side of a whole-job restart

A restartable distributed `MLTrainingJob` (`distributed.maxRestarts` above 0) starts every rank again after a failure, on whatever nodes Kueue admits it to.
The controller gives the new attempt `TRAINING_ATTEMPT` and starts it only after its stop barrier clears: the old Job, its Pods and its Workload are gone, and every node that held a rank is either still Ready, so its kubelet reported the Pods stopped, or named in the `platform.lkhun9311.github.io/fenced-nodes` annotation.
That annotation is an operator's acknowledgement that the machine is off, and the controller cannot verify it; for a node it cannot reach, "no rank of the old attempt still runs" holds only as far as that acknowledgement is true.
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
| `cut-writer` | rank 1's node is cut off from the API server while its rank runs on and writes to the shared volume; its Node is deleted; the machine is stopped, and only then fenced | no attempt 2 until the fence, though the rank was still writing for two minutes after its Node was gone; attempt 1's last write precedes the fence and attempt 2's first write; the reference's parameters at the end |
| `cut-writer-early` | the negative control: the same, but the fence is written while the rank still writes | attempt 2 starts on the fence, and attempt 1 is seen writing after attempt 2's first write |

`node-lost`, `cut-writer` and `cut-writer-early` each take a worker away for good, so each runs with `reference` on a cluster of its own; the script refuses a run holding more than one of them, and the scorer scores the cases the run lists in its provenance, refusing a list that is empty, repeats a case, names one it does not know, or lacks the reference.

The recorded run of the first five cases is `hack/distributed-restart-kind-20261101T003147Z`, of commit `e2d21e9d`, whose trainer saves everything listed above, and all 36 of its checks pass.
An earlier run, `hack/distributed-restart-kind-20261031T144217Z` of commit `65bf5f16`, also passes all 36 with the trainer before it, which saved the model, the optimizer and a per-rank data generator only; it is kept as the record of that trainer.
Both were recorded with 34 checks; the two added since check the run's list of cases.
Every resume and final-parameter check reads every rank: each rank of the world size must record a resume from the same checkpoint and final parameters equal to the reference's, and a case with a rank missing fails.
The scorer first read rank 0 alone, and a copy of the 20261101T003147Z run with every rank-1 record removed passed all its checks under it; under the per-rank scorer that copy fails 7.

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

## A rank cut off from the API server that keeps writing

`node-lost` freezes its node, and a frozen rank stops writing, so it could not show the case the fencing acknowledgement exists for.
`cut-writer` cuts rank 1's node off from the API server and nothing else, after the technique of the llm-d failover reproduction (`iptables` rules dropping traffic to the API server's address and port).
Inside the node container's root network namespace it drops, for IPv4 and IPv6, what the node sends to the control plane's port 6443 and what comes back from it, what its Pods send there through the Service, and what the API server sends to the kubelet's port 10250.
Traffic between Pods is addressed to Pods and is not matched, so gloo between the ranks and DNS go on, and the shared volume is a bind mount of a host directory that no rule touches.

The rank that is cut off has to keep writing for the case to mean anything, and a trainer whose peer dies exits, so two settings make it a writer that does not stop.
`CKPT_HEARTBEAT` appends a record of the attempt, rank, sequence number and wall-clock time to `a<attempt>/heartbeat-rank-<r>.jsonl` on the volume every half second, synced and closed each time.
`CKPT_LINGER` keeps a rank whose training loop raised alive, its heartbeat still writing, until it is killed from outside.
It stands in for a process the platform cannot reach and that does not exit, such as one blocked in a collective under torch's 30-minute default while a background writer runs; what it writes is a dedicated file, never a checkpoint, and both settings are off in every other case and in `check_protocol.py`, which passed with them off on 2026-11-01.
The scorer reads the heartbeats and every file's mtime from the host side of the volume, because a cut node's logs no longer reach the API server.

The case waits for two checkpoints, cuts the node, waits for its Node to be seen not Ready, deletes the Node, and waits for the barrier to say it waits for that node to be fenced.
It then holds 30 s, writing midway an unrelated annotation and a fence naming another node, neither of which may release the barrier.
Then it kills the node container with `docker kill`, which is the machine being switched off, waits until nothing under `a1/` has changed for five looks, and only then writes the fence.
A background sampler records the MLTrainingJob, Jobs, Workloads and Nodes about twice a second through all of it, and a sample whose reads failed, or a stretch longer than 3 s without a sample, fails the window it falls in rather than passing it.

The recorded run is `hack/distributed-restart-kind-20261101T055239Z`, of commit `d2412f49`, and all 27 of its checks pass, scored with the scorer as of the commit that adds this record.

```
python3 experiments/distributed-restart/score_kind.py hack/distributed-restart-kind-20261101T055239Z
```

Rank 1 ran on `rst-worker`, and every time below is from the run's own records.

| when (UTC) | what |
|---|---|
| 05:55:53.671 | the rules are in place; both ranks then publish 11 more checkpoints, each needing both ranks' shards |
| 05:56:35.989 | the Node is seen `Unknown`, and is deleted 6 ms later |
| 05:57:36.627 | attempt 1's Job is first seen `FailureTarget` (`BackoffLimitExceeded`), a minute after the deletion; the samples do not record the cut rank's Pod being removed, only its consequence |
| 05:58:06.229 | rank 0's last heartbeat; its last step record is from 05:58:05 |
| 05:58:07.310 to 05:58:37.735 | the hold: every sample says `node rst-worker to be fenced`, before and after the decoys |
| 05:58:17.336 | rank 1's first `lingering` heartbeat: its training loop has raised, and it writes on; what it raised is in its stdout, which stopped reaching the API server at 05:56:05 |
| 05:58:37.794 to 05:58:38.038 | `docker kill rst-worker`; the container is then reported not running |
| 05:58:37.843 | attempt 1's last write, the latest of every heartbeat and every mtime under `a1/` |
| 05:58:43.807 | the fence is written |
| 05:58:43 | attempt 2's Job is created (the API server keeps whole seconds) |
| 05:58:45.002 | attempt 2's first write |

From the Node's deletion to the kill, rank 1 wrote 243 heartbeat records, never more than 0.5 s apart, and its file grew on the host over the hold; no sample in those 128 s shows a second attempt or a Job of attempt 2.
The drop rules counted 966 IPv4 and 921 IPv6 packets from the node to the API server.
Attempt 2 resumed every rank from step 13, ran on `rst-worker2` and `rst-worker3`, and ended with exactly the reference's parameters on both ranks.

The negative control is `hack/distributed-restart-kind-20261101T060053Z`, of the same commit, and all 26 of its checks pass.
Its fence was written at 06:07:12.151 while rank 1 on `rst-worker2` was still writing; attempt 2's Job was created in that second and wrote first at 06:07:13.413, and rank 1 went on writing 42 records over 20.5 s after that, the last at 06:07:34.318, until its node was killed at 06:07:34.713.
Scored as `cut-writer`, the same evidence fails exactly the two checks that compare attempt 1's writes with the fence and with attempt 2's first write, and nothing else.
So the checks that pass on the recorded run can see the overlap they exist to rule out.

The barrier was also broken on purpose: a rehearsal of a controller that counted a deleted Node as fenced started attempt 2's Job at 06:17:40 while the cut rank wrote until 06:18:11, and failed four checks, the barrier holding, the barrier naming the node, the Job being created after the fence, and attempt 1's last write preceding attempt 2's first.
The controller was then restored, and `git diff` was empty.
Each of 25 one-subject mutations of copies of the recorded evidence failed the check aimed at it, among them a Node that stays Ready, a sample with a failed read or a 5 s gap in the barrier's window, the drop counters at zero, a 5 s pause or a repeated sequence number in the heartbeats, a container still running, an attempt-1 manifest or `LATEST` written after the fence, and an unknown or repeated case name.
Two of them first went unseen, and one of those was the scorer's: it looked for the node's name inside the barrier's message, and `rst-worker` is inside `rst-worker2`; names are now compared whole, in `node-lost` too.

### What the platform trusts

`platform.lkhun9311.github.io/fenced-nodes` is an operator's promise that the machine is off, and the controller cannot check it.
The control shows what a promise made too early does: attempt 2 starts on it, the platform cannot tell, and for 20.9 s two attempts write to one volume.
Here the overlap was harmless only because the old rank wrote a heartbeat of its own and no rank 0 was left to publish `LATEST`; a real trainer's lingering rank could write a checkpoint, and nothing in the platform would stop it.
What the platform does guarantee is narrower: it does not start the next attempt, for a node it cannot hear from, before someone says that node is off.

## What this does not show

Visibility across NFS clients, where a file renamed on one node may not yet appear on another, is the reason for the bounded retry in `shard_ok`; neither the local check nor kind exercises it, and the shared volume on EFS is where it would.
`cut-writer` shows the barrier holding for a deleted Node; a Node that is still Ready is trusted to have stopped its Pods, so a Ready condition that is stale, or a new machine registering under the old name, is not exercised.
The fence names a node and is never consumed, so an acknowledgement left from one loss would cover a later loss of a machine with the same name; one restart per job here never reaches that.
A node is fenced only if the controller recorded it, from the attempt's Pods; a rank whose Pod vanishes before the controller first sees it is not exercised.
The samples are not atomic: each reads four resources one after another, and an ordering finer than about a second is read from the volume's own times and the script's marks, not from the samples.
One run of each case is evidence that the path works, not a rate.
Saving and restoring the CUDA RNG is written but has never run, because every check here uses the CPU image.
