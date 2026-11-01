# Distributed restart: a distributed MLTrainingJob survives the loss of a rank by restarting the whole job from a checkpoint

Written 2026-11-01. Status: **DRAFT v2** (revised after a cold attack, 2026-11-01; the findings and answers are at the end), design only; nothing below is built or measured yet, and every file:line is at `origin/dev` `6647d9bd`.
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

### Controller: one Job name, one attempt at a time, and a barrier between them

The Job keeps the MLTrainingJob's name, and an attempt is retired by deleting it, not by renaming it.
A name per attempt is cleaner in isolation but breaks the invariant three places rely on — the Workload-to-job mapping (`internal/controller/mltrainingjob_controller.go:633`), ownership checks (`:646`) and the webhook's lookup (`internal/webhook/v1/mltrainingjob_webhook.go:246`).
**Revised after the cold attack (v2):** keeping the name is safe only behind a barrier, because the deployed Kueue v0.18.3 finds a Job's Workload by the owner's **name** (`pkg/controller/jobframework/reconciler.go:1146` at v0.18.3, read 2026-11-01), so a Workload left over from the retired attempt would be matched to the new Job of the same name and could hand it its old, deactivated state.
The barrier below waits for the old Job and the old Workload to be gone by UID; if that wait proves fragile in the integration tests, the fallback is a name per attempt with the three lookups rewritten, decided then and recorded here.

**State is a durable machine, not a set of flags.** Each attempt moves `Preparing → Active → Stopping → Stopped → (next attempt | Failed)`, written with resource-version conflicts honoured, before the action it authorises.
Each attempt carries a token (`<mltrainingjob-uid>-a<N>`) on its Job's labels; the attempt's Job UID is recorded as soon as the create returns, and on a lost create response the controller adopts a Job only if its token matches.
Deletes are preconditioned on the recorded UID, so replaying a delete can never remove a newer attempt's Job.
The restart budget is spent when an attempt enters `Stopping`, once, so a retried reconcile does not spend it twice.

1. **Detect** (level-based, so a missed event is found on the next reconcile): a rank Pod Failed, fewer live ranks than recorded for an `Active` attempt, the Job's `FailureTarget` or `Failed`, or the Workload evicted or deactivated by the fault path (marked as such, below).
   The controller watches owned Pods and Jobs and the Workloads; a deactivation an operator made is not a trigger (below).
2. **Stop**: delete the attempt's Job, UID-preconditioned, with foreground propagation.
3. **Confirm stopped**, all of: the Job is NotFound on an uncached read; no Pod with the attempt's token or with any recorded rank Pod UID exists; the attempt's Workload, by its recorded UID, is NotFound; and every node that held a rank either still answers and its rank's container is reported terminated, or is **fenced**.
   A Pod's disappearance from the API is not fencing: PodGC can remove a Pod whose node is unreachable while its process still writes to NFS.
   A node is fenced only when an explicit acknowledgement says the machine is off — an annotation `platform.lkhun9311.github.io/fenced-at` on the MLTrainingJob naming the node, written by the operator or by the experiment's runner after it has read the instance as terminated from EC2.
   The controller never force-deletes, never strips finalizers, and never treats Node deletion alone as fencing; until fencing, the attempt waits in `Stopping` and says which node it waits for.
   That wait is part of what the experiment measures.
4. **Restart**: if attempts remain, create the Job again under the same name, suspended, with `TRAINING_ATTEMPT=N` in every rank's environment, the token on every Pod, and a **rendezvous Service of the attempt's own** (`<name>-ddp-a<N>`, subdomain and `MASTER_ADDR` derived from it) created before the Job, so a resolver cannot return a cached address of the retired attempt's rank 0.
   Kueue admits it as a new Workload; this controller never unsuspends it.
   If none remain, the job is Failed with the reason, and the attempts list says how it got there.

### Webhook

Between attempts the Job does not exist, and today that is exactly the condition under which the webhook lets template fields change (`internal/webhook/v1/mltrainingjob_webhook.go:128`).
The rule becomes: before the controller creates the first Job it writes a reservation into status (the hash of the template-baked fields and the generation it was taken from), and from then on the webhook compares every update against that reservation on the stored object, Job present or not.
Updates that only delete or touch finalizers keep the existing exceptions; a Job created before this change, with no reservation, is backfilled by the controller on its next reconcile.

### NodeHealth

`reactivateDisplaced` reactivates Workloads the fault path deactivated (`internal/controller/nodehealth_gpufault.go:418`), with a patch that does not check the resource version (`:426`–`:435`).
For a distributed job with `maxRestarts` above 0 that would race the restart.
The fault path, when it deactivates such a Workload, marks it in the same update as handed to the MLTrainingJob controller; NodeHealth then never reactivates it, and the MLTrainingJob controller treats exactly that mark — not any deactivation — as a trigger.
A Workload an operator deactivated has no mark and stops the job, as it does today.
The reactivation patch for the remaining cases gains an optimistic-lock precondition.

## Checkpoint protocol (the trainer's side)

The platform provides the volume and the attempt number; the protocol is the workload's, implemented in an extension of `experiments/checkpoint-resume/train.py`, which today covers one Pod on a node-local volume.

- Paths are immutable and never revisited: `<mltrainingjob-uid>/a<attempt>/<step>-<checkpoint-uuid>/rank-<r>.pt` and `.../MANIFEST`, temporary names likewise unique, so resuming from S−1 and reaching S again writes a new directory instead of renaming onto a rejected or partial one.
- After optimizer step S, ranks agree on S and on the checkpoint UUID with a collective, each writes its own shard to a temporary name, flushes, `fsync`s, closes and renames it.
- Rank 0 gathers each rank's shard hash and size, verifies all N, writes `MANIFEST` (every shard, rank, step and world size), `fsync`s and closes it, then publishes `LATEST` by writing a temporary file and renaming it over `LATEST` in the same directory.
  On NFS (EFS) the rename is atomic for the name, not a multi-file transaction, and EFS gives close-to-open consistency rather than a snapshot across clients, which is why the manifest, not the directory, is what a reader trusts.
- On resume, rank 0 alone reads `LATEST`, validates the manifest and broadcasts its identity; every rank reopens and validates its own shard and the ranks agree collectively to load it or to fall back together to the previous complete checkpoint, retrying visibility a bounded number of times.
  Ranks never choose independently, because two valid checkpoints seen by different clients would otherwise be loaded at once.
- A missing shard, a hash that does not match, or shards from different steps reject the checkpoint; no checkpoint at all is an explicit step-zero restart, recorded as such.
- Every rank saves its full state (model, optimizer, scheduler, RNG, sampler position) even under DDP, where most of it is replicated, because the cheap version — rank 0's optimizer for everyone — passes a loss-curve check and is wrong.
- Each line the trainer logs carries the attempt number, the step and a wall-clock time, so the experiment can read the first optimizer step completed by all ranks after a restart.

## What would make a measurement lie, and the test that catches each

| failure | test |
|---|---|
| two attempts at once after a controller crash or a conflict | envtest: fail the status update or the create at each step boundary, and lose a successful create's response; exactly one attempt exists, it is adopted by token, and the budget is spent once |
| a rank of the old attempt still writing after the new one starts | kind: cut one worker from the API server (the B0 rule technique) while it keeps NFS, then delete its Node object; the next attempt must stay blocked in `Stopping` until the fencing acknowledgement, and starts after it |
| a re-admitted old Workload restarting the old attempt, or matched to the new Job | kind with the pinned Kueue v0.18.3: keep the old Workload alive with a finalizer during the stop; the new Job must not be created until it is gone by UID, and no Pod of the retired token may run again |
| an operator's stop read as a fault | kind: deactivate the Workload by hand; the job stops and no new attempt is made |
| a cached address of the old rank 0 | kind: the new attempt's `MASTER_ADDR` is a name the retired attempt never had |
| budget exhausted, or no checkpoint at all | envtest and kind: the job ends Failed with the attempts list; a restart with no checkpoint is recorded as step zero, not as a resume |
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
No automatic force deletion of an unreachable node's Pods, ever; that decision stays with an operator, and fencing is an explicit acknowledgement, not an inference from Node deletion.

## The cold attack on v1 (codex `gpt-6-astra`, 2026-11-01) and where v2 answers it

| # | finding | answer |
|---|---|---|
| 1 | Pod absence does not prove a writer stopped; PodGC can remove Pods of an unreachable node | fencing is an explicit acknowledgement after the machine is read as off; Node deletion alone never authorises a restart |
| 2 | Kueue v0.18.3 finds Workloads by owner name, so a surviving old Workload can be matched to a same-named new Job | verified in Kueue's source; the barrier waits for the old Workload by UID, with a name per attempt as the recorded fallback |
| 3 | foreground deletion needs a completion barrier | uncached Job NotFound, dependents checked by UID, finalizer stalls reported, never stripped |
| 4 | attempt selectors do not isolate rendezvous names; DNS caches survive | a rendezvous Service and `MASTER_ADDR` per attempt, created before the Job |
| 5 | "persist before each step" is not a recovery algorithm | a durable state machine, attempt tokens, UID-preconditioned deletes, adoption by token after a lost create, budget spent once on `Stopping` |
| 6 | the webhook freeze has an undefined boundary | a template reservation written before the first Job and compared on the stored object, with backfill |
| 7 | NodeHealth hand-off could override an operator's stop | only the fault path's mark is a trigger; an operator's deactivation stops the job; the reactivation patch gains a precondition |
| 8 | detection relied on events | level-based detection from recorded rank identities, with Pod and Job watches |
| 9 | checkpoint paths were revisited after a rollback | paths carry the attempt and a checkpoint UUID |
| 10 | NFS resume needs collective agreement | rank 0 selects and broadcasts; ranks accept or fall back together |
| 11 | envtest alone cannot establish the contract | integration cases on kind with the pinned Kueue added to the table |
