# Distributed restart: a distributed MLTrainingJob survives the loss of a rank by restarting the whole job from a checkpoint

Written 2026-11-01. Status: **built and run on kind; not yet run on GPUs.** The controller, webhook and trainer protocol were merged to `dev` in #465, and what ran is in `experiments/distributed-restart/README.md`: the kind cases, including a rank cut from the API server that kept writing until it was fenced, and the checkpoint protocol's local check. The paid GPU session's apparatus is the DRAFT section "The paid session: apparatus" below, not yet approved.
Until this line it said: "DRAFT v2 (revised after a cold attack, 2026-11-01; the findings and answers are at the end), design only; nothing below is built or measured yet". The text below is that draft, and every file:line in it is at `origin/dev` `6647d9bd`, before the merge.
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

## The paid session: apparatus

Written 2026-11-01. Status: **`smoke` approved by the owner on 2026-11-02; `full` not approved.** Nothing else here authorises a purchase; only the owner's explicit approval starts a paid session.
The approval came after the kind rehearsal found D1 and before it was fixed, so `smoke` starts only from a commit whose kind rehearsal recovers `terminate-wait-1` on a late replacement.
This section is step 5 above, the GPU session, as an apparatus: what is built, what is scored, what stops it, and what it costs.
It was attacked as a plan by codex `gpt-6-astra` (read-only, 2026-11-01) before it was written down; its twenty findings were each checked against the code at `863154a7`, and where one changed the plan the item says so (`A<n>`).
The runner's plan was attacked the same way before the runner was written, and its eighteen findings, checked the same way, are marked `B<n>`; three of them corrected this section as first committed (the trigger's attempt, the deadline and the cost).
Prices and the quota are my own read-only reads in `gpu-lab` (account 007635145730) on 2026-11-01; no figure here comes from codex.
The finished apparatus at `f57e11a1` was attacked a third time before any purchase, by codex `gpt-6-astra` (read-only) and, separately, by a bare `codex review` of its diff; their findings are marked `C<n>` where they changed this section.
The worst was that the registered session could never start: 22 cases needed a 684-minute deadline and 724 minutes of credential, and the `gpu-lab` permission set issues credentials for at most 720 (`SessionDuration` PT12H) (C1).
So the session is now two stages, a small `smoke` run inspected before anything else is bought and a `full` run that needs its own approval.
The scorer accepted a rank 1 whose final parameters were NaN, records from another run, contradictory clock probes and a missing fence; each was reproduced as an ACCEPTED fixture before it was fixed (C4, C5, C6, C9).
The runner then ran end to end on kind (`hack/restart-lifecycle-kind-20261101T143009Z`, #480), and what that rehearsal and the codex `gpt-6-astra` attack on its finding changed is marked `D<n>`.
The worst was that `terminate-wait`, as registered, could not recover on EKS: attempt 2 starts one rank on the survivor at once, because Kueue admits on quota and not on node capacity, and that rank gave up on its peer after the 60 s collective timeout, long before a g5 replacement could pull its image (D1).

### What must be true before it can run

These are not built by this apparatus, and each one alone stops the session.

- **The restart controller is on `main` since 2026-11-01.** Argo deploys the operator from `main` (`config/argocd/operator.yaml`); `dev` was promoted in #477 (`d24645b1`), which contains `65874ddb`, and CI pinned the operator image built from it in `84736e23` (A2, C3).
  The runner still refuses before it buys anything when the deployed CRD lacks `distributed.maxRestarts` or the operator Pod's image digest is not the one `main` pins, because what Argo deploys on the day is what counts.
- **Design step 3 has run on kind over NFS, against ganesha and not EFS.** The kind cases first ran on a shared host directory, "without NFS's semantics" (`hack/kind-config-restart.yaml`) (A16).
  The torn-checkpoint cases now run against an in-cluster NFS-Ganesha server with the mount options AWS recommends for EFS (`STORAGE=nfs`; `experiments/distributed-restart/README.md`, "Over NFS, on kind").
  They found two defects in the trainer that the host directory could not: every rank creating the shared directories killed the reference at step 1 (`hack/distributed-restart-kind-20261101T090308Z`), and a rank whose node cached its shard's name as absent refused every checkpoint through the bounded retry and restarted from step zero (`hack/distributed-restart-kind-20261101T091435Z`).
  Both are fixed, and `hack/distributed-restart-kind-20261101T092646Z` and `hack/distributed-restart-kind-20261101T093539Z` pass all their checks.
  The second fix is a mitigation measured on Linux 7.0 against ganesha; whether EFS and the EKS kernel need it, or more, is not shown, and the paid session's restarts are where that would be paid for.
  The API-cut case of step 4 has since run on kind as `cut-writer`, with an early-fence control (`experiments/distributed-restart/README.md`, `hack/distributed-restart-kind-20261101T055239Z`).
- **The case procedure has run end to end on kind** (C2): `restart_run` in the `smoke` stage and three scenario runs (a censored case, a retirement that was never confirmed, two VOIDs in a row), CPU ranks over the NFS server above, with only the EC2, Auto Scaling, GPU and DCGM boundary replaced (`hack/restart-lifecycle-kind-20261101T143009Z/README.md`).
  It found five defects in the runner, each fixed with a check that failed first: the log collector's request timeout cut every log stream at about 400 s, the log follows outlived the collector, clock probes went to an exporter on a node already scaled in, an unretired case's NCCL logs were not copied, and uutils `date` 0.8.0, the date of the machine the session runs from, printed `%6N` without its leading zeros, which could move a mark by up to 0.9 s.
  Its `terminate-wait-1` came out FAILED, not recovered, which is D1; the kind rehearsal is run again on the commit that fixes it, and `smoke` starts only from a commit whose rehearsal recovers that case on a replacement that joins after the 60 s.
- **The owner's approval of this section, with the stage, the case list and the cost ceiling below.** Given for `smoke` on 2026-11-02.

The quota is not a blocker any more: `L-DB2E81BA` (Running On-Demand G and VT instances) in ap-northeast-2 reads **128 vCPU**, the increase request closed at 128 on 2026-11-01 (`aws service-quotas get-service-quota`, `list-requested-service-quota-change-history-by-quota`).
Comments in `infra/aws/cluster` still say 52; they describe what was granted when they were written.

### Topology

One EKS cluster built by `hack/eks-gitops-session.sh` in a new mode, `TRAIN=restart`, so the session inherits that script's refusals, watchdog, GPU deadline and scale-down instead of a second copy of them.

- **Three `g5.xlarge` in the `gpu` node group**, one A10G and 4 vCPU each (`describe-instance-types`).
  All three carry the `train` label Kueue's `gpu` flavor selects on, because they are one group; the separate `gpu_single` group does not carry it (`infra/aws/cluster/eks.tf`) and is not used.
  Which node is the spare is not configured: two ranks of one GPU each leave exactly one node idle.
  `gpu_max_nodes` is widened from 1..2 to 1..3 for this, and no further.
- **One zone, ap-northeast-2a**, through `gpu_availability_zone`.
  g5.xlarge is offered in 2a, 2c and 2d (`describe-instance-type-offerings`).
  2a because the CPU node group and the single NAT gateway are in the first subnet, which is 2a, so the 3.3 GB torch image is not pulled across zones on every replacement node, and earlier g5 sessions found capacity there.
  A capacity failure in 2a is a VOID session, not a reason to fall back to another zone, since the zone is what the figures inherit.
- **One EFS file system**, regional, encrypted, bursting throughput, with one mount target in 2a's private subnet and a security group admitting TCP 2049 from the node security group only; the `aws-efs-csi-driver` addon pinned at `v3.5.3-eksbuild.1`, the default for Kubernetes 1.35 (`describe-addon-versions`), with an IRSA role.
  All of it behind `efs_enabled`, off by default and refused without a zone pin.
  The volume is provisioned statically: a PersistentVolume naming the file system and a ReadWriteMany claim, rendered by the runner from `terraform output efs_file_system_id`, because the cluster root drives no Kubernetes provider.
  Bursting rather than Elastic, because Elastic bills $0.07 per GB written (Price List API) and every rank writes every step.
- **The trainer** is `experiments/distributed-restart/train.py` with `CKPT_BACKEND=nccl`, on the image the EKS training sessions already pin, `docker.io/pytorch/pytorch@sha256:c8268a92…755` (torch 2.5.1+cu124, CUDA 12.4, NCCL 2.21.5, as its ranks recorded in `hack/four-gpu`), carried by the existing base64 prelude with its in-container sha256 check, so nothing is pushed to a registry.
  The controller sets `RANK` and `WORLD_SIZE` but no `LOCAL_RANK`, and each Pod sees one GPU, so the trainer defaults the device to `cuda:0` (A4).
  Python is started without `exec`: as PID 1 the trainer refuses to fire a kill fault, and the prelude of `hack/lib/ddp-arms.sh` ends in `exec python` (A5).
  `experiments/distributed-restart/Dockerfile.cuda` builds the same thing as an image for local use; it is not pushed.

### Cases, registered before purchase

Every case is one restartable `MLTrainingJob`: `worldSize` 2, `gpuCount` 1, `gpuClass` a10g, `maxRestarts` 1, `stateVolume` the EFS claim.
Every case has its own `CKPT_JOB_ID`, the job's name with a nonce, so no case reads another's checkpoints or fault markers (A8).
Every case runs 30 steps with `CKPT_STEP_SLEEP=2`, about a minute of training an attempt, and `CKPT_BALLAST_MB=16`, so each shard is a stated 16 MiB rather than a few kilobytes.
`CKPT_COLLECTIVE_TIMEOUT=60`, because the controller does not watch Pods or Nodes: it restarts when the Job fails, is deleted, or carries the NodeHealth hand-off (`internal/controller/mltrainingjob_restart.go`, `runAttempt`), and a surviving rank blocked in a collective keeps the Job running until that timeout fails it (A6).
The registered timeout is therefore part of every figure where the faulted rank cannot report its own failure, and the record says so.
`CKPT_RENDEZVOUS_TIMEOUT=600` bounds only the ranks' join, before training: `train.py` builds the rendezvous store with that wait from whichever rank arrives first, then puts the store and every collective back at the 60 s (D1).
Without it the join was bounded by the 60 s too, and a `terminate-wait` attempt 2, whose rank 1 waits for a replacement node, its image pull and its mount, failed at 61 s with "1/2 clients joined" on kind.
600 s is below the 720 s case budget, so a peer that never comes fails the attempt rather than only censoring it.
`experiments/distributed-restart/check_rendezvous.py` shows a rank 15 s late joining from either side, the same start failing without the setting, and a peer frozen after the join still failing the survivor at the collective timeout and not the rendezvous one; on gloo only, so NCCL's exchange through the store at its first collective, which the restored store timeout is for, is not exercised.
Whether a g5 replacement joins, pulls 3.3 GB and mounts EFS within the 720 s case budget is not known before `smoke`; a case it does not fit is FAILED, censored, and the budget is not widened for it.
`NCCL_DEBUG=INFO`, `NCCL_DEBUG_SUBSYS=INIT,NET` and `NCCL_DEBUG_FILE` on the shared volume, so NCCL's lines do not share stdout with the trainer's JSON records; on stdout they already interleaved mid-line in `hack/four-gpu/2026-10-29-run5` (A17).
The file is named by attempt and rank, `a<attempt>-r<rank>-%h.%p.log`, because an Indexed Job's hostnames repeat across attempts and NCCL truncates a file it opens, and its directory is created and checked by the container's shell before Python starts, because NCCL creates no directory and falls back to stdout without one (B2).
The scorer still reads trainer records wherever they start in a line, in case anything else shares stdout.

| order | case | `smoke` | `full` | fault | injected when |
|---|---|---|---|---|---|
| 1 | `reference` | 1 | 1 | none | — |
| 2 | `no-rng-control` | 1 | 1 | rank 0 `kill-after-latest:12`, resumed with `CKPT_LOAD=no-rng` | by the trainer |
| 3 | `rank-kill` | — | 2 | rank 1 `kill-before-fsync:12:1`, a `SIGKILL` mid-checkpoint | by the trainer |
| 4 | `dcgm` | 1 | 2 | XID 79 written into the host engine of rank 1's node (`hack/lib/gpu-fault.sh`, `gf_inject 230 79`) | once `LATEST` names step 10 or later |
| 5 | `terminate-spare` | — | 2 | `aws ec2 terminate-instances` on rank 1's instance, three nodes up | once `LATEST` names step 10 or later |
| 6 | `terminate-wait` | 1 | 2 | the same with the group at two nodes, so attempt 2 can only start on the instance the Auto Scaling group launches | once `LATEST` names step 10 or later |

`RESTART_STAGE` is required and names one of the two columns.
`smoke` is four cases, one of every path the session depends on (NCCL save and resume, the DCGM fault path and its reset, a cold replacement on EFS, EC2 termination and fencing), and its evidence is read before `full` is asked for (C1).
`full` was registered at five of every kind; at two it needs a 524-minute deadline, and at three 689, past what a fresh credential covers (below), so two is the most one session can hold.
Two runs of a kind are evidence that the path works twice, not a distribution, and the record says so.

An external fault waits for a published checkpoint, read from `LATEST` through rank 0's own mount, and is refused, and the case VOID, if step 25 has already been recorded, checked last, immediately before the injection, so a fault cannot land after training ended or before anything could be resumed (A9, B11).
The `reference` run's final parameters are what every resumed case is compared with, and the `no-rng-control` must differ from them: CPU equality cannot vouch for the CUDA RNG path, which has never run, and a control that drops it shows the comparison can see it (A11).

**Between cases**, the runner deletes the case's job and waits for its Jobs, Pods and Workloads to be gone before it copies the case's files off the volume and deletes them, so a case censored at its budget stops writing before its state goes and never shares the queue with the next (B5).
It then waits until the group holds its registered count of qualified nodes (three, or two for `terminate-wait`), none tainted by the fault path, creates a NodeHealth for, and warms, any node it has not seen, which is how a replacement is prepared, after the case it arrived in and before it can be some later case's spare (A10, A14, B10).
No case starts, and no termination is made, when the GPU deadline leaves less than the case's whole slot, because a replacement the group launches on its own after that deadline has fired would run with none (A20, B7).
**A slot** is one absolute deadline for everything a case does, so the session's budget is the sum of limits the runner enforces and not of waits it merely hopes for (C11): before the case, 300 s to requalify the group, or 900 s for the scale-in to two before `terminate-wait`, or 900 s for a lost node's replacement to join and 900 s to warm it; then 120 s to submit, the 720 s case budget, 120 s to collect evidence, 300 s to retire, 120 s to copy files and score, and 180 s more after a `dcgm` case for its reset.
Retirement's deadline is counted back from the slot's end, so a slow case cannot take its own cleanup's time.
A case voided before its fault (missing rank records, the fault window missed, a clock probe that failed, a create whose answer was lost) is retired like any other, and a retirement that is not confirmed stops the run, every later case NOTRUN, because a job still holding Pods, a Workload or a GPU would share the queue with the next (C7).
An unretired case's files stay on the volume, and the runner still writes their listing, the job's final status, the nodes and the timeline, read-only, so the scorer can say why.
After a `dcgm` case it injects the baseline, 0, into field 230 and waits for that node's NodeHealth to read clear and its taint to go, as `gf_reset` does.
The fault path is opt-in, and it scrapes only nodes named by a NodeHealth object (`internal/controller/gpufault_source.go`, `Tick`), so the runner creates one per GPU node, including each replacement, and starts the operator with `--gpu-fault-source=dcgm --gpu-fault-evict-workloads` (A3).
Both Argo Applications that would revert that, the root and the operator, sync automatically with self-heal, so the runner turns their automated sync off, patches the Deployment, and requires the flags still present 90 s later before the first `dcgm` case; it is recorded as a deviation from what `main` deploys.
Flags are not a working fault path, so before the first case the runner also requires (R6, C10): both flags, each as a whole argument, on every operator Pod; every GPU node's exporter serving the XID (230) and ECC (310, 311) fields; and every NodeHealth reading `GPUSignal` and `GPUHealthy` True, with no fingerprint and no taint, within 180 s.
That an injected XID reaches the exporter and the operator latches, taints and evicts on it cannot be checked without a GPU; `smoke`'s `dcgm-1` is where it is first shown.
The exporter with a host engine is `config/dcgm-exporter-fault`, which no Argo Application manages, applied by hand.

**The fault window** is read last: the runner first resolves the instance, the exporter Pod and the GPU deadline, then reads the job's phase, the rank records and `LATEST` immediately before the destructive call, and records the step it saw there, because API calls in between could carry training past step 25 (C8).
**Termination and fencing.** After `terminate-instances`, the runner writes `platform.lkhun9311.github.io/fenced-nodes` on the job only once EC2 describes the instance as `terminated`, marking `fence-request` before the annotate call and `fenced` after it returns, and samples the job's status right after.
The stop barrier waits for the Job, then the Pods, then the Workloads, and only then for fencing (`stopBarrier`), so the annotation cannot release it early (A7).
What releases the Pods on EKS is the Node object of a terminated instance being removed and PodGC following; that is expected, not shown, and a case it does not reach within its budget is a failed observation, not a VOID.

### What is scored

`experiments/distributed-restart/score_eks.py` reads one run directory and gives every registered case one of ACCEPTED, FAILED, VOID or NOTRUN with a reason; the summary counts all of them, never dropping one (A18).
FAILED is reported in two parts: censored at its budget, when the job never reached an end, and not recovered, when it ended Failed or recovered wrongly; VOID is the apparatus's part (C13).
Whether a job ended within its budget is read from the job's own stamps, its `creationTimestamp` and its status's `lastTransitionTime`, and not from when the runner read it, because the runner reads the final status only after its last clock probe, past the budget; a job that ended later than 720 s after its creation is censored whatever its phase, and one without both stamps is VOID (D2).
The stamps are whole seconds from two clocks, the API server's and the controller's, whose offset nothing measures, so an end within 2 s of the budget is VOID rather than placed on either side of it; the 2 s assumes both clocks are synchronised to within 1 s.
NOTRUN is a case the runner chose not to start, after an abort or for want of deadline, and says why; a registered case with no directory at all is VOID (B17).
The runner scores each case as it ends (`--partial`), because a bad reference, a bad control or two VOID cases in a row must stop the spending, not be found at the end (B14).
The checks run in a fixed order, the fault's delivery, then the job's outcome, then the evidence, then what the recovery restored, so a recovery that timed out is FAILED for timing out and not VOID for lacking the records a timeout cannot produce (B17).

- **Recovery time:** from the fault to the moment every rank of the next attempt has recorded its first `step`, the latest of the ranks' first step records.
  The fault time is the trainer's own `fault` record for `rank-kill`; for `dcgm`, the node clock printed in the same `kubectl exec` as the injection, which `gf_inject` alone does not print (B13); for `terminate-*`, the runner's mark taken before the `terminate-instances` call, so the call's own latency is inside the recovery (B12).
- **Clocks:** the runner probes every GPU node it can reach, by `date` inside that node's exporter Pod bracketed by its own clock, before the fault and again after attempt 2's first step; a terminated node has only the first and a replacement only the second (B12).
  Every node whose timestamp a figure uses must have a probe; offsets are applied, and the case is refused when any probe's bracket is wider than 0.5 s or when a node's offset is larger than 2 s, because the scorer would otherwise subtract a skewed clock from a precise one (A13).
  A node up before the fault needs a probe before it, every node but the terminated one a probe after, and a node whose probes disagree by more than 0.5 s is a clock that moved and VOIDs the case; the median's distance to the far end of all its probes is reported as `clock_uncertainty_s` (C6).
  A case other than the `reference` whose probe before the fault fails is VOID before its fault and is not injected.
  Whether `kubectl exec` on EKS brackets inside 0.5 s is not known until `smoke`.
- **Lost steps:** the highest step any rank of the faulted attempt recorded, minus the step the next attempt resumed from.
- **Checkpoint cost:** each `checkpoint` record's `save_s`, the rank's monotonic time from agreeing on the checkpoint to the barrier after `LATEST`, as median and maximum per attempt of every case; the EFS burst credit balance (CloudWatch, read-only) is recorded before and after, because bursting throughput depends on it.
- **Recovery class**, read from evidence, never assumed: `same-nodes` when attempt 2 ran on the nodes attempt 1 had, `spare` when on a node that was up and qualified before the fault, `replacement` when on a node created after it.
  Nodes are told apart by their Node UID, not their name, because a replacement can reuse a name; a spare must appear among the prepared nodes before the fault, a `terminate-wait` must recover on a node absent before it, and attempt 2 on the terminated Node itself is VOID (C12).
  A `terminate-spare` case that recovered on a replacement is reported as `replacement`, on its own line, not refused and not counted as spare (A14).

A case is ACCEPTED only when all of these hold, and FAILED or VOID naming the first that does not (A11, A12, A17):

- every record is bound to the case: its `run_id` is the job's name, it came from a Pod the collector listed, its rank is that Pod's index, a Pod prints one attempt and an (attempt, rank) comes from one Pod on a node the controller recorded for that attempt, and the world size is 2 (C5);
- the fault reached its target: the trainer's `fault` record, from rank 1 for rank-kill and rank 0 for the control, at the registered point and step; for `dcgm` a readback of 79 and the target node's NodeHealth latched and the node tainted, recorded before the reset; for `terminate-*` the terminated instance is rank 1's node by provider ID, EC2 reported it terminated, and the marks run fault-start, terminated-read, fence-request, fenced in that order with the job's annotation naming the node, or the case is VOID;
- for `terminate-*`, attempt 2 appeared only after the fence was asked for: a status sample before `fence-request` showing it, or a `createdAt` more than 1 s plus the 2 s unprobed-clock allowance before it, is the stop barrier failing and FAILED; it is judged from the request and not the response, because the controller can act on the annotation before the call returns (C9);
- the job Succeeded with exactly two attempts, and attempt 1's trigger is the one the fault implies (`RankFailed` for `rank-kill` and `terminate-*`, `NodeFault` for `dcgm`); the controller writes the trigger on the attempt it stops, not on the one it starts (`trigger` in `internal/controller/mltrainingjob_restart.go`), which the first draft of this section had backwards (B1);
- every rank of both attempts recorded `start` with `backend` nccl and a `cuda` device, and every rank of every attempt has its own NCCL log whose every transport line is `NET/Socket`, the transport registered for one GPU per node over the VPC network: a `P2P`, `SHM` or `NET/IB` channel, a network other than `Socket`, a missing log or no transport line refuses the case (B15);
- every rank of attempt 2 recorded a `resume`, all from the same checkpoint, from a step above zero, and from the step the fault leaves for the in-trainer faults; a `restart_from_zero` is a FAILED recovery, not a resume;
  the checkpoint resumed from is an earlier attempt's, its directory agrees with the step, its `MANIFEST` is in the volume's listing, and each rank's steps of attempt 2 run exactly from that step plus one to 30 (C5);
- every rank's final parameters finite and equal to the reference's within 1e-6 on every component, with the largest difference recorded; the `reference` itself needs one attempt and both ranks finite and agreeing, and the `no-rng-control` needs every rank to differ by more than 1e-6 (B3); the first scorer read rank 0 alone and accepted a rank 1 of NaN (C4).

### Abort conditions

Before anything is built: a dirty tree, `APPROVED_TRAIN_SHA256` not the trainer's hash, no `TRAIN_AZ`, no `RESTART_STAGE` or one other than `smoke` and `full`, a stage whose deadline plus the 40-minute destroy exceeds the 700 minutes a fresh 720-minute credential is allowed to cover, a `TTL_MINUTES` below the stage's minimum, a credential that expires before the session's deadline plus teardown, the nightly destroy workflow queued or running, or, unless it is disabled by hand, a start inside its window, running G and VT On-Demand vCPU plus 12 above the quota, or the g5.xlarge On-Demand price above `TRAIN_MAX_PRICE` ($1.40).
After the cluster exists and before any GPU: T1 to T5 of `train_run`; the claim not Bound; the operator gate, which reads the revision Argo deployed, requires it to contain `65874ddb`, requires every Ready operator Pod to run the digest that revision's `config/manager/kustomization.yaml` pins, requires `distributed.maxRestarts` in the deployed CRD, and requires the webhook to refuse, on a server-side dry run, a job naming a claim that does not exist and to accept a registered case (B9); and the fault path not running 90 s after it is switched on, or failing R6 once the GPU nodes exist.
After the nodes exist: T6 and T7 on three nodes, a warm-up that runs the torch image with the EFS claim mounted on every one of the three, so the spare's first pull and first mount are not inside a measured recovery (A15); the `reference` or the `no-rng-control` not ACCEPTED; two consecutive VOID cases; a case whose retirement is not confirmed; a DCGM fault that cannot be reset; and the GPU deadline.
`full` does not check that `smoke` ran; reading `smoke`'s evidence first is the owner's step, and the approval for `full` is a separate one.
Every case after an abort is recorded NOTRUN with the reason.

### Termination chain

Unchanged from `TRAIN=ddp`, with the restart session's variables in every apply and destroy:

1. a detached watchdog (`setsid`) runs `terraform destroy` of the cluster root at `TTL_MINUTES`, with `-var=gpu_max_nodes=3 -var=efs_enabled=true -var=gpu_availability_zone=ap-northeast-2a`;
2. an EventBridge Scheduler deadline (`hack/lib/gpu-ttl.sh`, `ttl_arm`) forces the `gpu` group to desiredSize 0 ten minutes before it, on AWS's clock;
3. `train_down` on every exit scales the group to 0 and follows every instance it ever recorded to `terminated`, replacements included;
4. the cluster destroy at the end, which removes the mount target, the file system and the security group with it.

This is not a hard cap, and the record says so (A20).
The watchdog runs on the operator's machine; if that machine is lost, only the EventBridge deadline acts, and it stops the GPUs, not the CPU node, the control plane, the NAT gateway or the file system, about $0.26 an hour (below), until someone destroys the cluster.
The deadline fires once, so the runner starts no case and makes no termination once less time remains before it than that case's slot.
A single kubectl or exec call can still overrun its phase by its own timeout, and the DCGM reset and the `gpu-fault.sh` helpers have no per-call timeout; those are covered only by the 3,600 s margin.

### Cost

Price List API, On-Demand, ap-northeast-2, read 2026-11-01:

| item | rate | per hour |
|---|---|---|
| 3 × g5.xlarge | $1.237/h | $3.711 |
| 3 × 100 GiB gp3 root volumes | $0.0912/GB-month | $0.037 |
| EKS control plane | $0.10/h | $0.100 |
| NAT gateway | $0.059/h | $0.059 |
| t3.large CPU node | $0.104/h | $0.104 |
| total with the GPUs up | | $4.011 |

Data: 3 initial pulls of the 3.3 GB torch image and one per replacement, through the NAT at $0.059/GB: `smoke` has one termination, 4 × 3.3 = 13.2 GB, $0.78; `full` has four, 7 × 3.3 = 23.1 GB, $1.36.
EFS: `full`'s 10 cases × 2 ranks × 30 steps × 16 MiB is under 10 GiB, deleted after each case's evidence is copied; at $0.33/GB-month for the session's hours, under $0.10.
The NAT gateway's public IPv4 address is $0.005/h, under $0.10 either way.

**The deadline.** The first draft put the ceiling at `TTL_MINUTES=330`, and the waits the runner actually had did not fit in it (B6); the second summed them to 684 minutes, which no credential this account issues outlives (C1); and that sum counted the three warm-ups, the replacement's warm-up and the work between cases as one wait each, which they were not (C11).
`restart_gpu_budget` now sums what the runner enforces: preparation 4,080 s (node 900, device plugin 600, qualification 1,500, the three warm-ups in parallel under one 900, the fault-path check 180), each case's slot (above), and the scale-down 600 s and 300 s.
`smoke`'s slots are 1,680 + 1,680 + 1,860 + 2,280 s, so its GPU budget is 12,480 s; with the 1,200 s of syncs and the held qualification and the 3,600 s margin, `TTL_MINUTES` must be at least **288**, and 328 minutes of credential.
`full`'s GPU budget is 6,840 + 9,900 s per repetition, 26,640 s at two; `TTL_MINUTES` must be at least **524**, and 564 minutes of credential.
Both figures are computed by `restart_gpu_budget` from the code and checked by hand against it on 2026-11-01.

**The ceiling** assumes everything waits to its bound: the GPUs up until the EventBridge deadline, ten minutes before `TTL_MINUTES`, and the rest billing until the destroy ends, 40 minutes after it; the previous ceiling, $48, was a calculation at one price and not an enforced cap, and the third attack said so (C14).
It is given at the price read, $1.237/h, and at `TRAIN_MAX_PRICE`, $1.40/h, the most the session accepts:

| stage | `TTL_MINUTES` | GPUs and volumes | the rest ($0.263/h) | data, EFS, IPv4 | ceiling at $1.237 | ceiling at $1.40 |
|---|---|---|---|---|---|---|
| `smoke` | 288 | 4.63 h × $3.748 = $17.37 | 5.47 h, $1.44 | $0.91 | **$19.71** | **$21.98** |
| `full` | 524 | 8.57 h × $3.748 = $32.11 | 9.40 h, $2.47 | $1.51 | **$36.09** | **$40.28** |

The expected sessions are far shorter, because each wait is a bound and not a duration.
At about 25 minutes of preparation, 4 minutes a rank-kill case, 6 a DCGM case with its reset, 8 a spare termination and 12 a waited one, `smoke`'s GPUs are up about 1 h and it costs **about $5**, and `full`'s about 1.6 h and **about $8**; these are estimates from the budgets, not measurements, and `smoke` is what measures them.
The nightly destroy workflow runs at 18:00 UTC and the session refuses to overlap it within two hours, so a session must start at or after 20:00 UTC and end its deadline by 16:00: a 288-minute one between 20:00 and 11:12 UTC (05:00 to 20:12 KST) and a 524-minute one between 20:00 and 07:16 UTC (05:00 to 16:16 KST); with the workflow disabled by hand, the window is lifted, and a queued or running destroy is still refused.
