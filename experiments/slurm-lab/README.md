# Slurm lab: the same policy questions as the Kueue setup, asked of Slurm

This is a local Slurm cluster in containers on one machine, at zero cost.
It asks Slurm the questions this repository already asks Kueue and Kubernetes: who gets GPUs when they are short, what a tenant's quota does, what preemption does to the job it takes from, and what a dead node does to a single-node and a two-node job.
Step 5 then runs real two-rank CPU training (gloo DDP) under Slurm, kills a node mid-training, and checks that the requeued job resumed from its checkpoint and ended with the same parameters as an uninterrupted run.
It compares **policy meaning**, not speed.

**The GPUs here are declared, not physical.**
Each compute node advertises two GPUs that Slurm schedules, binds and accounts, and no GPU exists behind them.
This is the same arrangement as the fake device plugin (`cmd/gpu-simulator`) this repository uses on kind.

Every claim below cites a raw transcript under `evidence/2026-10-31/`, `evidence/2026-10-31-rerun04/` or, for step 5, `evidence/2026-11-01-train/`.
Each transcript records the exact command, the UTC time it ran, its full output and its exit status.
A prompt `alice@slurmctld$` means the command ran as user alice inside the slurmctld container (`docker compose exec -T -u alice slurmctld bash -c '…'`); `host$` means it ran on the host in this directory.

## What it is

| piece | what | pinned as |
|---|---|---|
| base image | Debian 13 slim | `debian:trixie-slim@sha256:f6b08b09…` in `Dockerfile` |
| Slurm | slurmctld, slurmd, slurmdbd, client | Debian package `24.11.5-4+deb13u1` |
| MUNGE | authentication between daemons | Debian package `0.5.16-1.1~deb13u1` |
| accounting database | MariaDB | `mariadb:11.4@sha256:d1891ede…` in `compose.yaml` |
| compute nodes | `c1`, `c2`, `c3`: 4 CPUs, 2000 MB, 2 declared GPUs each | `etc/slurm.conf`, `etc/gres.conf` |
| training (step 5) | CPU torch in a venv at `/opt/torch`, Debian's Python 3.13.5 | `torch==2.5.1+cpu` and every dependency at the version the Kubernetes trainer image has, in `Dockerfile` |
| trainer (step 5) | `train.py`, copied from `experiments/distributed-restart/train.py` on branch `feat/distributed-restart` | commit `f7638229ff3c9f96a16ac483f60aad5724ca73ac`; step 5 refuses to run unless the copy hashes to that commit's file |
| checkpoint volume (step 5) | Docker named volume `ckpt`, mounted at `/ckpt` on c1, c2, c3 and read-only on slurmctld | `compose.yaml` |

The versions that actually ran are recorded in `evidence/2026-10-31/00-cluster.txt` (`dpkg-query` prints `24.11.5-4+deb13u1` for every Slurm package, and `scontrol --version` prints `slurm-wlm 24.11.5`).
Apt packages are pinned by exact version; if the Debian archive stops carrying that version, the build fails rather than installing a different one.

One partition `gpu` holds all three nodes, so the cluster has six declared GPUs.
Two accounts stand for two tenants: `teama` with user alice and `teamb` with user bob (`evidence/2026-10-31/00-accounting.txt`).
Two QoS levels: `normal` (priority 0) and `high` (priority 100, may preempt `normal`), with preemption by QoS and requeue as the cluster-wide preemption mode.

### How the GPUs are declared, and why not with a bare count

The plan was a `gres.conf` line with only a count and no device file.
Slurm 24.11 drops it for GPUs: with that line, `slurmd -G` prints `warning: Ignoring file-less GPU gpu:(null) from final GRES list` and reports no GPU at all, while the committed file-backed line reports `Count=2` (`evidence/2026-10-31/00-fileless-gres.txt`).
So `entrypoint.sh` creates two character device nodes `/dev/labgpu0` and `/dev/labgpu1` with major number 240, which Linux reserves for local experimental use, and `gres.conf` names them with File=.
No driver answers that major number.
A job given one of them sees `CUDA_VISIBLE_DEVICES=0`, and `cat /dev/labgpu0` fails with `Operation not permitted` (`evidence/2026-10-31/00-cluster.txt`).

### What had to change to run in containers

slurmd starts a cgroup plugin even with process tracking by PID and no task plugin, and an unprivileged container without systemd cannot give it one.
`etc/cgroup.conf` disables the plugin, which Slurm 24.11 accepts; that is why jobs here are tracked by parent PID and **not confined**.
The compute nodes are unprivileged containers; the default Docker capabilities are enough to create the device nodes.
An Ubuntu 24.04 base with Slurm 23.11 was tried first and abandoned during development; no transcript of that attempt was kept, so nothing below relies on it.

## How to run

```sh
cd experiments/slurm-lab
./run.sh            # build, start, run every step into evidence/<UTC date>/, then docker compose down -v
KEEP=1 ./run.sh     # the same, leaving the cluster up for inspection
docker compose down -v   # when finished with KEEP=1
```

The steps can also be run one at a time against a running cluster, in order: `steps/00-fileless-gres.sh`, `steps/00-setup.sh`, `steps/01-gres.sh`, `steps/02-quota-preempt.sh`, `steps/03-node-failure.sh`, `steps/04-multinode.sh`, `steps/05-train-requeue.sh`.
`steps/00-setup.sh` creates the accounts and QoS, so it runs once per fresh cluster.
Steps 0 to 4 took about 15 minutes, most of it Slurm's requeue delay; step 5 took about 8 minutes on its own (`evidence/2026-11-01-train/`, 23:41:54 to 23:49:58 UTC).
Nothing is pulled except the two pinned base images and the pinned torch wheels, and nothing is pushed.

The image is now tagged `slurmlab:24.11.5-torch251`, because step 5 added torch to it.
Steps 0 to 4 in `evidence/2026-10-31*/` ran on the earlier `slurmlab:24.11.5`, which had no torch, and were not rerun on the new image.
Step 5 ran on a fresh cluster after only `steps/00-setup.sh`, whose transcripts for that cluster are in `evidence/2026-11-01-train/`.
The first recording of `00-cluster.txt` and `00-accounting.txt` there had a missing space in the `docker image inspect` line, so the image ID was never captured.
Both were rewritten on 2026-11-01 at 05:21 UTC by rerunning `steps/00-setup.sh` on a second fresh cluster from the same image (`sha256:1691aad9bffb…`), so those two files are not from the cluster step 5 ran on.

## Step 1: GRES placement and the `Resources` reason

Transcript: `evidence/2026-10-31/01-gres.txt`.

One 1-GPU holder was pinned to c1 and one to c2, so four GPUs were free in total but only c3 had two.
A 2-GPU job with no node named landed on c3, and Slurm bound both of c3's GPUs to it:

```
     4    two-gpu    alice   R   gres/gpu:2 c3 c3
     Nodes=c3 CPU_IDs=0 Mem=0 GRES=gpu:2(IDX:0-1)
```

With c3 full, two GPUs were still free, one on c1 and one on c2.
A second 2-GPU job stayed pending, and the reason Slurm gave was `Resources`:

```
     5  two-gpu-b    alice  PD   gres/gpu:2  (Resources)
   JobState=PENDING Reason=Resources Dependency=(null)
```

Cancelling c1's holder gave c1 two free GPUs, and the same job 5 started there without being resubmitted.

The reason string does not distinguish "two GPUs free but split across nodes" from "fewer than two free anywhere".
That is the same blindness this repository measured for the Kubernetes scheduler in `experiments/fragmentation/README.md`, where the fragmented and the aggregate-short arms produced the same message.

## Step 2: account quota, QoS quota and preemption

### 2a. An account's GPU limit (GrpTRES)

Transcript: `evidence/2026-10-31/02a-account-quota.txt`.

teama was limited to 2 GPUs at once and teamb to 4.
alice ran a 2-GPU job, then submitted a 1-GPU job, which pended with the account-limit reason while c2 and c3 were idle:

```
     7   a-second    alice    teama  PD   gres/gpu:1  (AssocGrpGRES)
     6    a-first    alice    teama   R   gres/gpu:2 c1 c1
c2    idle      gpu:2     gpu:0
c3    idle      gpu:2     gpu:0
```

bob then ran two 2-GPU jobs inside his own limit, taking c2 and c3, while alice's job kept waiting.
alice's idle quota was not lent to anyone and nobody's idle capacity was lent to her: a limit here is a hard ceiling with no borrowing.

Raising teama's limit to 3 removed the quota reason, but the cluster was now full.
The step expected the reason to turn to `Resources`; it did not within 30 s, and squeue showed `(None)` instead, which the transcript records as a TIMEOUT.
When one of bob's jobs was cancelled, alice's pending job 7 started on c3 at once, without being resubmitted.

### 2b. A QoS's GPU limit

Transcript: `evidence/2026-10-31/02b-qos-quota.txt`.

The same kind of limit on QoS `high` instead of an account caps every account using that QoS together.
With `high` limited to 2 GPUs and alice holding 2 under it, bob's 1-GPU `high` job pended with the QoS reason:

```
    11     b-high      bob    teamb   high  PD   gres/gpu:1  (QOSGrpGRES)
```

### 2c. Preemption by QoS, mode REQUEUE

Transcript: `evidence/2026-10-31/02c-preempt-requeue.txt`.

bob filled all six GPUs with three 2-GPU `normal` jobs submitted with `--requeue`.
alice submitted a 2-GPU `high` job at 11:11:42.7 and it was running three seconds later on c1, where bob's job 12 had been:

```
    12   b-norm-1      bob normal  PD       0:00   gres/gpu:2  (BeginTime)
    15   a-urgent    alice   high   R       0:01   gres/gpu:2 c1 c1
[2026-10-31T11:11:45.001] preempted JobId=12 has been requeued to reclaim resources for JobId=15
```

The preempted job was killed and put back in the queue under the same job id.
It was not eligible to start again for about two minutes: requeued at 11:11:45, `EligibleTime=2026-10-31T11:13:46`, reason `BeginTime`.
Nothing in `etc/slurm.conf` sets that delay, and the same roughly two-minute `BeginTime` appeared on every requeue in this evidence (steps 3b, 3c and the requeue variant of step 4).
It restarted at 11:13:47 with `Restarts=1`, and from the beginning: its own output, appended across both runs, reads

```
start 11:11:42 on c1 restart=0
slurmstepd-c1: error: *** JOB 12 ON c1 CANCELLED AT 2026-10-31T11:11:45 DUE TO PREEMPTION ***
start 11:13:47 on c1 restart=1
```

Accounting keeps both runs: one record `PREEMPTED` and a second `RUNNING`.

### 2d. The same contention with PreemptMode CANCEL

Transcript: `evidence/2026-10-31/02d-preempt-cancel.txt`.

With QoS `normal`'s own PreemptMode set to cancel, the preempted job was ended and not requeued, although it had been submitted with `--requeue`:

```
16           b-cancel-1       bob     normal  PREEMPTED      0:0 2026-10-31T11:13:50 2026-10-31T11:13:53
[2026-10-31T11:13:53.001] preempted JobId=16 has been killed to reclaim resources for JobId=19
```

It does not appear in the queue afterwards.

### 2e. Mode REQUEUE, but the job said `--no-requeue`

Transcript: `evidence/2026-10-31/02e-preempt-norequeue.txt`.

With the cluster back on REQUEUE, a preemptable job submitted with `--no-requeue` was killed instead:

```
20            b-noreq-1       bob     normal  PREEMPTED      0:0 2026-10-31T11:13:56 2026-10-31T11:13:59
[2026-10-31T11:13:59.001] slurm_job_preempt: preempted JobId=20 had to be killed
```

So what happens to a preempted job is decided by two settings together: the mode on its QoS or the cluster, and whether the job itself may be requeued.

## Step 3: node failure

### 3a. Drain does not kill the running job

Transcript: `evidence/2026-10-31/03a-drain.txt`.

c2 was drained while bob's 60-second job ran on it.
The node went to `draining`, the job kept running, and it completed normally with exit 0:

```
c2 draining gpu:2 lab: drain while a job runs
## seen at 2026-10-31T11:14:05.324Z
draining
State=MIXED+DRAIN
24 RUNNING
24                on-c2  COMPLETED      0:0 2026-10-31T11:14:02 2026-10-31T11:15:03              c2
```

Only when it had finished did the node become `drained` (`State=IDLE+DRAIN`).
Meanwhile a job naming c2 waited with `ReqNodeNotAvail`, and an unpinned 2-GPU job went to c1.
`scontrol update nodename=c2 state=resume` returned c2 to service, and the waiting job started there.

### 3b. A node stops answering

Transcript: `evidence/2026-10-31/03b-node-down.txt`.

Two 1-GPU jobs ran on c3: `rq-yes` with `--requeue` and `rq-no` with `--no-requeue`.
c3's container was stopped with no grace period at 11:15:12.2, which ends its slurmd and the job processes without a word to the controller.
The controller's log shows the sequence:

```
[2026-10-31T11:15:34.013] agent/is_node_resp: node:c3 RPC:REQUEST_PING : Communication connection failure
[2026-10-31T11:15:35.000] error: Nodes c3 not responding
[2026-10-31T11:15:48.000] requeue job JobId=29 due to failure of node c3
[2026-10-31T11:15:48.000] Killing JobId=30 on failed node c3
[2026-10-31T11:15:48.000] error: Nodes c3 not responding, setting DOWN
```

So the node was declared DOWN about 36 s after it died, with SlurmdTimeout set to 20 s in `etc/slurm.conf`.
Until then both jobs were reported `RUNNING` on a node that no longer existed.
Both jobs' first runs were recorded as `NODE_FAIL`.
The `--no-requeue` job ended there.
The `--requeue` job went back to the queue, again behind the two-minute `BeginTime` delay (`EligibleTime=2026-10-31T11:17:48`), and restarted on c1 at 11:18:17 with `Restarts=1`, about three minutes after the node died.
Its output shows two runs on two nodes, each starting from the beginning: `start 11:15:12 on c3 restart=0` on c3's disk and `start 11:18:17 on c1 restart=1` on c1's.

When c3's container was started again it returned to `idle` with no command, because ReturnToService=1 returns a node that was DOWN only for not responding.

### 3c. `scontrol requeue` by hand

Transcript: `evidence/2026-10-31/03c-scontrol-requeue.txt`.

`scontrol requeue` on the running `rq-yes` job put it back to `PENDING (BeginTime)` with `Restarts=2` and the same two-minute delay; it ran again at 11:20:47.
On a job submitted with `--no-requeue`, the same command was refused with `Requested operation is presently disabled for job 31` and the job kept running.

## Step 4: a two-node job loses one node

Transcripts: `evidence/2026-10-31-rerun04/04-multinode-default.txt`, `04-multinode-requeue.txt` and `04-multinode-nokill.txt` in the same directory, with that run's `00-cluster.txt` and `00-accounting.txt` beside them.

**Why step 4 has its own directory.**
The first step-4 run, still kept under `evidence/2026-10-31/04-multinode-*.txt`, checked for a surviving rank with `pgrep -af 'sleep 900'`.
That pattern matches the probe's own `bash -c` wrapper, so the probe always succeeded, and the claim "no `sleep 900` process was left on c1" rested on reading its output by eye rather than on the probe.
The probe now lists only processes named exactly `sleep` (`pgrep -ax sleep`) and keeps the line `sleep 900`, so its own wrapper cannot match.
Every variant runs it twice on the batch host: once while the job is alive, as a positive control, and once after the failure.
Step 4 was rerun on a fresh cluster with the new probe; the other steps were not rerun, and their transcripts stay in `evidence/2026-10-31/`.

Each variant is one batch job with `-N 2 --ntasks-per-node=1 --gres=gpu:1`, whose script is a single `srun` over both nodes, as a distributed training launch would be.
Each ran on c1 and c2 with c1 as the batch host, and c2's container was stopped.
In all three variants the positive control found the rank on c1 while the job ran (`120 sleep 900`, `200 sleep 900`, `343 sleep 900`), and the same probe after the failure printed `no sleep 900 process on c1`.

**Default (`--no-requeue`): the whole job ends.**
About 36 s after c2 died (stopped at 11:40:31.5, `NODE_FAIL` at 11:41:07) the job was marked `NODE_FAIL`, and the rank on the healthy node c1 was cancelled with it:

```
JobState=NODE_FAIL Reason=NodeDown FailedNode=c2
srun: error: Node failure on c2
slurmstepd-c1: error: *** STEP 2.0 ON c1 CANCELLED AT 2026-10-31T11:41:07 DUE TO NODE FAILURE, SEE SLURMCTLD LOG FOR DETAILS ***
srun: error: c1: task 0: Terminated
root@c1$ pgrep -ax sleep | grep -E '^[0-9]+ sleep 900$' || echo no sleep 900 process on c1
no sleep 900 process on c1
```

No rank survived on c1.

**`--requeue`: the whole job is requeued as a unit.**
At 11:41:44, 32 s after c2 died, both ranks were cancelled and the job went back to `PENDING (BeginTime)`; the probe then found no rank left on c1.
After the two-minute delay it started again, on c1 and c3, with both ranks restarted from the beginning:

```
[2026-10-31T11:41:44.000] requeue job JobId=3 due to failure of node c2
     3 mn-requeue    alice   R       0:01     2   gres/gpu:1 c[1,3] c[1,3]
rank 1 on c3 restart=1 at 11:43:51
rank 0 on c1 restart=1 at 11:43:51
```

**`--no-kill`: the allocation shrinks, but the step that used the dead node is still killed.**
Slurm removed c2 from the job instead of ending it, and killed the step that spanned c2:

```
[2026-10-31T11:44:19.001] error: Removing failed node c2 from JobId=4
[2026-10-31T11:44:19.001] Killing JobId=4 StepId=0 due to failed node c2
srun: error: c1: task 0: Killed
no sleep 900 process on c1
```

The batch script then had nothing left to run, exited 1, and the job ended `FAILED` on one node (`NodeList=c1`, `NumNodes=1`).
Keeping the allocation helps only a script that launches a new step on what is left; a two-rank step did not survive losing a rank under any of the three settings.

The time to detect the dead node was 22 to 36 s across the four stops in step 3b and the rerun of step 4 (36, 36, 32 and 22 s).
What makes it vary was not measured.

Step 4 shows that Slurm restarts a process, not that training resumes: its ranks only print and sleep.
Step 5 answers the second question.

## Step 5: a requeued two-node training job resumes from its checkpoint

`train.sbatch` is one batch job with `-N 2 --ntasks-per-node=1 --requeue --open-mode=append`, whose script is a single `srun` starting one rank of `train.py` per node.
`MASTER_ADDR` is the first host of `SLURM_JOB_NODELIST`, `RANK` is `SLURM_PROCID`, `WORLD_SIZE` is `SLURM_NTASKS`, and `TRAINING_ATTEMPT` is `SLURM_RESTART_COUNT`, defaulted to 0 because Slurm leaves it unset on the first start.
Checkpoints go to `/ckpt/<job>/`, on the one volume every compute node mounts, so a requeued attempt on other nodes can read what the first attempt wrote.
Each rank's JSON records go to `/ckpt/<job>/logs/attempt-<A>-rank-<R>.jsonl`, because a dead node's share of srun's forwarded output is lost with it.

`train.py` is the trainer the Kubernetes whole-job restart uses, copied unchanged from commit `f7638229` of `feat/distributed-restart` (see its header).
Its checkpoint protocol is that branch's: rank 0 publishes a manifest only after every rank's shard is verified, `LATEST` names the newest published checkpoint, and on resume every rank must accept the same one or all start from zero, which they record as `restart_from_zero`.
That trainer was being changed while this copy was taken; what ran here is that one commit's file, and the step refuses to run if the copy no longer hashes to it.
The trainer in `experiments/distributed-restart/` has since added the scheduler, sampler position and global RNG to every shard; this copy predates that and saves model, optimizer and a per-rank data generator.

Three jobs ran, each 40 steps with a checkpoint after every step and one second's sleep between steps, as alice, on a fresh cluster (`evidence/2026-11-01-train/`):

| job | what | transcript |
|---|---|---|
| 2 `tr-ref` | uninterrupted reference | `05a-train-reference.txt` |
| 3 `tr-full` | `CKPT_LOAD=full`; c2 killed after rank 0 recorded 12 checkpoints | `05b-train-requeue.txt` |
| 4 `tr-none` | the same, with `CKPT_LOAD=none`: the mutation, whose second attempt ignores every checkpoint | `05c-train-requeue-load-none.txt` |

**Placement.**
slurmctld, slurmdbd and MariaDB each run in their own container; only c1, c2 and c3 run slurmd, so killing a compute node never killed the controller.
Both requeue jobs started on c1 and c2, with c1 as batch host and rank 0 (and so `MASTER_ADDR`), and rank 1 on c2.
c2 was the node killed, with `docker compose kill c2` (SIGKILL to the whole container); just before it, the same transcript lists rank 1's `train.py` running on c2, and right after it `docker inspect` shows `exited exit=137 restarts=0`, so the compose restart policy did not bring it back.

**What Slurm did (job 3).**

```
host$ docker compose kill c2                                   # 23:42:53.990
[2026-10-31T23:43:08.001] error: Nodes c2 not responding
[2026-10-31T23:43:24.000] requeue job JobId=3 due to failure of node c2
[2026-10-31T23:43:24.000] error: Nodes c2 not responding, setting DOWN
[2026-10-31T23:45:43.972] sched/backfill: _start_job: Started JobId=3 in gpu on c[1,3]
```

The job was requeued 30 s after the kill, waited for its `BeginTime` about two minutes later, and started again on c1 and c3 with `Restarts=1`, while `sinfo` showed c2 `down* Not responding`.
`sacct -D` keeps both attempts under the same id:

```
             3    tr-full  NODE_FAIL      1:0        0 2026-10-31T23:42:41 2026-10-31T23:43:23          c[1-2]
             3    tr-full  COMPLETED      0:0        1 2026-10-31T23:45:43 2026-10-31T23:46:14          c[1,3]
```

Job 4 did the same: requeued 31 s after its kill (23:46:29.8 to 23:47:01), restarted at 23:49:13 on c1 and c3.

**What training did.**
In job 3, both ranks of attempt 1 recorded `"event": "resume", "from_dir": "a0/00000012-bd1091ba…", "from_step": 12`, their first step record was step 13, and they trained to step 40.
Step 12 was the last checkpoint attempt 0 published; it had reached step 12 and no further.
The final parameters of both ranks were equal, value for value, to the reference's, and so was the state digest (`3c58b01c8a53faf1…` on every rank of both runs).
In job 4, both ranks of attempt 1 recorded `restart_from_zero` and trained steps 1 to 40.

**The scorer.**
`score_requeue.py` reads the reference logs, the case logs and the case's `scontrol show job`, and exits 1 if any check fails.
It requires effects, not the fault: `JobState=COMPLETED` with `Restarts` at least 1, one log per attempt from 0 to `Restarts`, every record carrying the attempt Slurm's restart count gave it, an attempt 0 that published a checkpoint and stopped before step 40, a final attempt whose every rank has one `resume` record with `from_step > 0` and none `restart_from_zero`, the same checkpoint on every rank, that checkpoint being attempt 0's last published one, the remaining steps trained in order, and final parameters equal to the reference's.
On job 3 it printed `30 passed, 0 failed` and exited 0.
On job 4 it printed `18 passed, 5 failed` and exited 1, failing on the `restart_from_zero` records and the missing `resume` records.
`05-verdict.txt` records both exit statuses, and the step exits nonzero unless they are 0 and 1.

**Why equal parameters are not enough.**
Job 4's final parameters were also equal to the reference's on both ranks, because this trainer is deterministic and a restart from step 0 replays the same data.
A check on the final parameters alone would have passed the mutation; only the resume record tells a resume from a rerun.
The equality check was itself made to fail once, outside the step: with one final parameter of job 3's rank 1 moved by one float ulp in a scratch copy of the logs, the scorer printed `FAIL: attempt 1 rank 1 final parameters equal the reference's exactly` and exited 1.
That copy was not kept.

**How the node was returned.**
`docker compose start c2`; c2 was `idle` at the first poll after the container started, with no `scontrol update`, because `ReturnToService=1` returns a node that was DOWN only for not responding when its slurmd registers.

**What ended rank 0, and an ordering this depends on.**
Rank 0 on c1 did not wait for Slurm: its gloo collective failed with `Connection closed by peer`, and srun printed `c1: task 0: Exited with exit code 1` before `Node failure on c2` (`/ckpt/slurm-tr-full-3.out` in `05b-train-requeue.txt`).
The job was still requeued, because the batch step had not ended when slurmctld declared c2 DOWN: `sacct` shows `3.batch` ending at 23:43:24, the second of the requeue, and the attempt as `NODE_FAIL`.
Had the batch script exited first, the attempt would have ended `FAILED` with exit 1; sbatch's documentation lists node failure, preemption and an explicit requeue as what `--requeue` covers, not a nonzero exit, and nothing in this lab sets `RequeueExit`.
That ordering was not varied here, so whether a faster-failing script loses the requeue is not shown.

**A launch detail.**
The job variables are passed in sbatch's environment, not as `--export=ALL,VAR=…`.
A job submitted the second way during development made slurmd on c1 log `_get_user_env: get env for user alice here` and then `fatal: clone: Operation not permitted`, after which compose restarted the container and slurmctld requeued the job (`Batch JobId=2 missing from batch node c1`).
That run was a scratch smoke test whose transcript was not kept; the cause beyond those two log lines was not investigated.

## Slurm behaviour mapped to this repository

| observed in Slurm | evidence | this repository's counterpart | same / different / not comparable | why |
|---|---|---|---|---|
| A 2-GPU job is placed only on a node with two free GPUs, and waits with reason `Resources` when the free GPUs are split | `01-gres.txt` | the Kubernetes scheduler placing a Pod's `nvidia.com/gpu` request, measured in `experiments/fragmentation/README.md` | **same** | both treat a per-node GPU request as indivisible, and both give one reason for fragmentation and for real shortage |
| An account's GrpTRES gpu limit holds a job at `AssocGrpGRES` while GPUs are idle | `02a-account-quota.txt` | a tenant's ClusterQueue nominal quota, written from `GPUQuotaPolicy` by `internal/controller/kueue_quota.go` | **same** in what it limits | each is a per-tenant ceiling on concurrent GPUs charged at admission, separate from what is physically free |
| The ceiling is hard: alice waited with 4 GPUs idle and nothing was lent | `02a-account-quota.txt` | cohort borrowing: every tenant ClusterQueue joins cohort `gpu-platform`, so idle nominal quota is lent (`hack/m6-kind-e2e.md`) | **different** | Kueue lends idle quota within a cohort; a Slurm association limit has no borrowing, and sharing beyond a ceiling would be done with fair-share priority, which this lab did not configure |
| A limit on a QoS caps every account that uses it together (`QOSGrpGRES`) | `02b-qos-quota.txt` | none: quota here is per tenant ClusterQueue only | **not comparable** | the repository has no cross-tenant class with its own ceiling |
| A higher QoS preempts a lower one; the victim is requeued, waits about two minutes and restarts from the beginning under the same id | `02c-preempt-requeue.txt` | Kueue preemption, configured with `reclaimWithinCohort: Any` and `withinClusterQueue: LowerPriority`; the victim's Job is suspended and its MLTrainingJob returns to `Pending` (`hack/m6-kind-e2e.md`) | **different** | both evict and requeue, but Kueue's trigger is quota reclaim within a cohort or priority within one queue, and Slurm's here is QoS rank across the whole cluster; the two-minute requeue delay is Slurm's own and Kueue has no fixed equivalent |
| With PreemptMode CANCEL, or a job that may not be requeued, the victim is killed and leaves the queue | `02d-preempt-cancel.txt`, `02e-preempt-norequeue.txt` | none: in this repository a Kueue-preempted Job is suspended and its MLTrainingJob returns to `Pending` (`hack/m6-kind-e2e.md`); no kill option is configured | **different** | Slurm lets the operator or the user choose kill over requeue; the repository's preemption always keeps the workload |
| Drain stops new placement and leaves the running job to finish | `03a-drain.txt` | the NodeHealth reconciler's `NoSchedule` taint `platform.lkhun9311.github.io/unhealthy` (`internal/controller/reconcile_helpers.go`) | **same** | both stop placement without evicting; neither kills what is running |
| A node that stops answering is declared DOWN about 36 s later; a requeue-able job is requeued and restarts elsewhere, a non-requeue-able one ends `NODE_FAIL` | `03b-node-down.txt` | a NotReady node tainted by NodeHealth; the Pods on it are handled by Kubernetes' own node lifecycle, not by this repository | **not comparable** | this lab measured Slurm's detection and requeue; this repository has no measurement of what happens to a training Pod on a node that dies |
| `scontrol requeue` restarts a job by hand, and is refused for a `--no-requeue` job | `03c-scontrol-requeue.txt` | none | **not comparable** | the repository has no operator command to requeue a running training job |
| A two-node job loses one node: by default the whole job ends, including the healthy rank | `evidence/2026-10-31-rerun04/04-multinode-default.txt` | the distributed MLTrainingJob: one Indexed Job with `backoffLimit: 0` (`internal/controller/mltrainingjob_distributed.go`), where one rank's failure fails the whole Job (`experiments/multi-pod-ddp/README.md`, arm `one-rank-fails`) | **same** in outcome, **different** in cause | both end every rank when one is lost and do not retry; the repository's run killed a rank's process, not a node, so node loss itself was not tested there |
| With `--requeue`, the two-node job is requeued as one unit and restarts on whichever two nodes are free | `evidence/2026-10-31-rerun04/04-multinode-requeue.txt` | none: `backoffLimit: 0` and no requeue path for a failed distributed MLTrainingJob | **different** | Slurm can retry the whole gang; the repository's code in this tree fails it and leaves the retry to the tenant. Slurm's retry restarts processes from the beginning of the script: whether training resumes is decided by the workload, which the next row tests |
| With `--requeue`, a shared checkpoint volume and the trainer's checkpoint protocol, the requeued attempt resumed from attempt 0's last published checkpoint (step 12) and ended with parameters equal to an uninterrupted run's | `evidence/2026-11-01-train/05b-train-requeue.txt`, scored by `score_requeue.py` | the whole-job restart of a distributed MLTrainingJob (`distributed.maxRestarts`), run on kind with the same trainer protocol in `experiments/distributed-restart/README.md`: a killed rank, a held Workload and a lost node each resumed from the last complete checkpoint with equal parameters | **same** in outcome, **different** in trigger and barrier | both start every rank again from the last published checkpoint under a new attempt number; Slurm's `--requeue` covers node failure and preemption, not a rank's nonzero exit, while the Kubernetes restart is also triggered by a failed rank; and Slurm restarted on other nodes once it declared the dead node DOWN, while the Kubernetes restart waits for a lost node to be fenced. One run of each, on toy models |
| With `--no-kill`, the allocation shrinks to the survivor but the spanning step is still killed | `evidence/2026-10-31-rerun04/04-multinode-nokill.txt` | none | **not comparable** | the repository has no notion of an allocation outliving its ranks |

## What this does not show

- **No real GPUs.** The GPUs are device nodes with no driver; nothing here says anything about CUDA, NCCL, GPU health checks or device faults.
- **No real network.** All containers share one Docker bridge on one host; there is no fabric, no MPI and no PMIx; step 4's ranks only print and sleep, and step 5's ranks talk gloo over TCP on that bridge.
- **Toy training.** Step 5 trains a 5-parameter linear model on CPU for 40 steps; it shows that the checkpoint protocol carried over a Slurm requeue, not anything about the size, speed or storage cost of real checkpoints.
- **A local volume, not a shared filesystem.** The checkpoint volume is one Docker volume on one disk, which every container sees immediately; NFS or Lustre visibility delays, which the trainer retries for, were not exercised.
- **Only the non-master node was killed.** In both step-5 kills the dead node ran rank 1; losing the batch host, which also runs rank 0 and the rendezvous, was not tried.
- **One host.** "Node failure" is a stopped container; a real node can fail partially, hang, or keep its processes running while its slurmd dies, and none of that was tried.
- **No confinement.** With the cgroup plugin disabled, a job is not limited to its CPUs, memory or devices.
- **No accounting at scale.** Two accounts, two users, two QoS levels and a few dozen jobs; nothing about scheduler throughput, backfill under load, or fair-share decay.
- **Single runs.** Each behaviour was observed once in this evidence; timings such as the 22 to 36 s detection (30 and 31 s in step 5) and the two-minute requeue delay are single observations, not distributions.
  Step 5's resume was observed in one job, with the kill landing after step 12's checkpoint and before any step-13 record; a kill inside a checkpoint write was not aimed at.
- **Shared lab secrets.** The MUNGE key is baked into the local image and the database password is in `etc/slurmdbd.conf`; both are for this lab only, and the image is never pushed.
