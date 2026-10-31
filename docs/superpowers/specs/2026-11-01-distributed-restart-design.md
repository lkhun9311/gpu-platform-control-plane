# Distributed restart: a distributed MLTrainingJob survives the loss of a rank by restarting the whole job from a checkpoint

Written 2026-11-01. Status: **DRAFT**, design only; nothing below is built or measured yet, and every file:line is at `origin/dev` `6647d9bd`.
Engines: the contract was attacked and redesigned with codex `gpt-6-astra` (2026-10-31, read-only); the choice of a same-name Job below departs from its proposal and says why.

## The problem

A distributed `MLTrainingJob` today cannot recover from anything.
Its Indexed Job runs with `backoffLimit` 0, because the Job controller's retry is per index and a replaced rank cannot rejoin a group whose other ranks are mid-step (`internal/controller/mltrainingjob_distributed.go:85`).
The API refuses `stateVolume` with `distributed`, because one claim could not follow ranks onto different nodes (`api/v1/mltrainingjob_types.go:36`).
So a GPU fault the platform already detects and acts on (the NodeHealth path measured on a card on 2026-10-27) ends a distributed job as Failed, and nothing it trained survives.
The operations question an AI infrastructure team asks is not whether a fault is seen, but how long until training is running again and how much work was lost; this project cannot answer it for any distributed job.

## What changes

### API

- `stateVolume` is allowed with `distributed` when the claim is ReadWriteMany; the rule at `api/v1/mltrainingjob_types.go:36` is replaced by a validating-webhook check that reads the claim (CEL cannot inspect another object) and refuses one that is not bound or not RWX.
  RWX is necessary, not sufficient: a claim that is RWX on paper but node-local in practice is caught by the restart test below, not by validation.
- `distributed.maxRestarts`, an integer 0 to 10, default 0, fixed at creation like the rest of `distributed`.
  0 keeps today's behaviour exactly: any rank failing fails the job.
  A positive value requires `stateVolume`, since a restart that cannot read a checkpoint restarts from step zero and would be reported as recovery.
- Status gains `attempts`: a bounded list, one entry per attempt, with the attempt number, the Job UID, the trigger (rank failure, Pod deleted, Kueue eviction, node not ready), and timestamps the controller observed: `failureObservedAt`, `stopConfirmedAt`, `createdAt`, `admittedAt`, `allRanksReadyAt`.
  The controller does not claim training resumed; readiness is not training (`api/v1/mltrainingjob_types.go:192` already says so), so the first optimizer step after a restart is read from the trainer's own record by the experiment, never written by the controller.

### Controller: one Job name, one attempt at a time

The Job keeps the MLTrainingJob's name, and an attempt is retired by deleting it, not by renaming it.
codex proposed a name per attempt; that is cleaner in isolation but breaks the invariant three places rely on — the Workload-to-job mapping (`internal/controller/mltrainingjob_controller.go:633`), ownership checks (`:646`) and the webhook's lookup (`internal/webhook/v1/mltrainingjob_webhook.go:246`) — so this design keeps the name and pays for it with the stop rule below.

The sequence, persisted in status before each step so a controller restart resumes it rather than repeating it:

1. **Detect**: any rank Pod Failed, an owned Pod deleted while the attempt was running, the Job's `FailureTarget` or `Failed`, or the Workload evicted or deactivated (which is how NodeHealth's fault path acts).
   The trigger is recorded once per attempt.
2. **Stop**: delete the Job with foreground propagation.
3. **Confirm stopped**: the next attempt is not created until no Pod carrying this MLTrainingJob's UID label and the old attempt's number exists at all, read uncached, and the old Workload no longer holds quota.
   The controller never force-deletes.
   A Pod on a node that stopped answering stays Terminating until the node object is removed (for an instance that was terminated, by the cloud node lifecycle controller) or the operator acts; the attempt waits, visibly, rather than starting a second writer next to a rank that may still be running.
   That wait is part of what the experiment measures.
4. **Restart**: if attempts remain, create the Job again under the same name, suspended, with `TRAINING_ATTEMPT=N` in every rank's environment and the attempt number on every Pod's labels and in the rendezvous Service's selector, so DNS can only return this attempt's ranks.
   Kueue admits it as a new Workload; this controller never unsuspends it.
   If none remain, the job is Failed with the reason, and the attempts list says how it got there.

### Webhook

Between attempts the Job does not exist, and today that is exactly the condition under which the webhook lets template fields change (`internal/webhook/v1/mltrainingjob_webhook.go:128`).
The rule becomes: once any attempt has been created, the fields baked into the template are frozen for the life of the MLTrainingJob, Job present or not.

### NodeHealth

`reactivateDisplaced` reactivates Workloads the fault path deactivated (`internal/controller/nodehealth_gpufault.go:418`).
For a distributed job with `maxRestarts` above 0 that would race the restart: the old Workload is reactivated while this controller is deleting its Job.
Such Workloads are left to this controller: NodeHealth marks them and does not reactivate them, and the MLTrainingJob controller treats the deactivation as a trigger.

## Checkpoint protocol (the trainer's side)

The platform provides the volume and the attempt number; the protocol is the workload's, implemented in an extension of `experiments/checkpoint-resume/train.py`, which today covers one Pod on a node-local volume.

- Paths are immutable: `<mltrainingjob-uid>/ckpt-<step>/rank-<r>.pt` and `<mltrainingjob-uid>/ckpt-<step>/MANIFEST`.
- After optimizer step S, ranks agree on S with a collective, each writes its own shard to a temporary name, flushes, `fsync`s and renames it.
- Rank 0 gathers each rank's shard hash and size, verifies all N, writes `MANIFEST`, `fsync`s it, then publishes `LATEST` by writing a temporary file and renaming it over `LATEST` in the same directory.
  On NFS (EFS) the rename is atomic for the name, not a multi-file transaction, which is why the manifest, not the directory, is what a reader trusts.
- A missing shard, a hash that does not match, or shards from different steps reject the checkpoint; resume falls back to the previous complete one and says so.
- Every rank saves its full state (model, optimizer, scheduler, RNG, sampler position) even under DDP, where most of it is replicated, because the cheap version — rank 0's optimizer for everyone — passes a loss-curve check and is wrong.
- Each line the trainer logs carries the attempt number, the step and a wall-clock time, so the experiment can read the first optimizer step completed by all ranks after a restart.

## What would make a measurement lie, and the test that catches each

| failure | test |
|---|---|
| two attempts at once after a controller crash or a conflict | envtest: fail the status update or the create at each step boundary; exactly one attempt exists and the budget is spent once |
| a rank of the old attempt still writing after the new one starts | kind: cut one worker from the API server (the B0 rule technique) while it keeps NFS; the next attempt must not start until the node object is gone |
| a re-admitted old Workload restarting the old attempt | kind with Kueue: deactivate and reactivate the Workload mid-stop; no Pod of the retired attempt number may run again |
| ranks checkpointing different steps | kind, gloo on CPU: one rank writes S+1; the manifest is refused and resume uses the previous checkpoint |
| a torn checkpoint | kind with an NFS server: kill writers before `fsync`, between shards and manifest, and around the `LATEST` rename; only complete checkpoints load |
| ready Pods read as training resumed | hold one rank before its first step; the experiment's resume time must wait for it |
| weights-only restore passing | uninterrupted and restarted runs must match within a registered tolerance; dropping optimizer or RNG state must fail it |

## Order and what can be shown before renting a GPU

1. API, webhook and defaulting, with envtest (1 to 2 days).
2. The attempt lifecycle and the NodeHealth hand-off, with the envtest crash and conflict cases (3 to 4 days).
3. The checkpoint protocol in the trainer, with the CPU tests on kind against an in-cluster NFS server (2 to 3 days).
4. The kind fault cases above, including the API-server cut (2 days).
5. Only then the GPU session: two `g5.xlarge` and a spare in one zone, EFS, faults injected through DCGM and by terminating an instance, five each, registered separately before purchase.

Everything up to step 4 runs on CPU with gloo; it shows the contract and the protocol, not CUDA, NCCL, EFS or cloud fencing.

## What this does not do

No elastic world size: a restart keeps the world size, and a job that cannot get worldSize Pods again waits in the queue.
No partial restart of one rank.
No automatic force deletion of an unreachable node's Pods, ever; that decision stays with an operator or the cloud's node lifecycle.
