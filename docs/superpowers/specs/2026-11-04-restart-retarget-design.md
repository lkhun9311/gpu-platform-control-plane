# Distributed restart, `retarget`: the rank-kill and DCGM recoveries after the changes made since `full`

Written 2026-11-04, before any run of this stage; revised 2026-11-05 after codex `gpt-6-astra`'s attack, still before any paid run.
Status: **registered for one paid session; not yet run.**
The owner approved the purchase on 2026-11-04 on the condition that codex `gpt-6-astra` attack it first ("codex astra로 결함 및 적대적 검토 후 진행 / 유료 승인"); that attack and its dispositions are under "Review".
The apparatus, the scorer and every rule not restated here are those of `docs/superpowers/specs/2026-11-01-distributed-restart-design.md`, "The paid session: apparatus".

## The question

In `full` (2026-11-04, `hack/distributed-restart-eks/2026-11-04-full`), each of the four `rank-kill` and `dcgm` cases spent 31 to 39 s between the controller's trigger and its stop confirmation, and the samples taken in that interval read `job … to be deleted`.
The rank command then ran the trainer under a PID-1 shell with no TERM trap; on kind, a Pod with that command took 31.8 s to delete and one whose shell forwarded TERM took 1.0 s.
Since `full` the command forwards TERM and waits for the trainer to end (#495, #496), the trainer's checkpoint search and rendezvous changed (#490), and the controller reads the GPU fault handoff first and records node UIDs (#489).

This stage asks one registered question and records the rest descriptively:

- **H1.** With the changed command, does the controller's trigger-to-stop-confirmation interval of a `rank-kill` or `dcgm` case fall well below `full`'s 31 to 39 s on EKS?
- **Descriptive.** Do the changed trainer and controller recover the same cases, with the same verdicts, and what are the recovery figures beside `full`'s?

## Cases

`RESTART_STAGE=retarget`: `reference`, `no-rng-control`, `rank-kill-1`, `rank-kill-2`, `dcgm-1`, `dcgm-2`, in that order (`hack/lib/restart-session.sh`, `restart_cases`).
No termination is bought.
Its code did not change in a way this question reads, and the stage is kept to the cases H1 needs; four termination cases would add their 335.7 to 345.4 s EC2 waits and their replacement nodes to a session that asks nothing of them.
Every other setting is `full`'s: three `g5.xlarge` in `ap-northeast-2a`, EFS, 30 steps, case budget 720 s, rendezvous 600 s, collective 60 s.
The fault window is the code's: an external fault waits for a published checkpoint of at least step 10 (`RESTART_FAULT_MIN_STEP`) and is refused if the last step read before it is 25 or later (`RESTART_FAULT_MAX_STEP`).
The step read last before the injection is recorded in each case's `case.json` (`step_before_fault`); it is not the step the fault lands on, which nothing instruments.

## H1, registered before the run

`experiments/distributed-restart/h1_retarget.py` evaluates it; `hack/test/check-restart-session.sh` pins each rule below.

For each of `rank-kill-1`, `rank-kill-2`, `dcgm-1`, `dcgm-2`, `d` is `status.attempts[0].stopConfirmedAt − status.attempts[0].failureObservedAt` in the final MLTrainingJob, for the attempt numbered 1.
A case gives a `d` only when all of these hold; otherwise it is INVALID with its reason, and is reported, not dropped:

- `score_eks.py`'s delivery check (`Case.check_delivered`, after its `load` and `bind`) passes on the evidence. Nothing the scorer checks after delivery is consulted, so a recovery that failed never removes a `d`; the scorer's verdict is reported beside it.
  `load` and `bind` read the case's spec, final object, Pods, marks and rank logs, and `bind` refuses logs it cannot tie to the case, which can remove a `d`; the clock probes, which only the recovery uses, are read when first used, so an unreadable probe file does not.
  A VOID the runner wrote is reported beside `d` and does not decide it: the runner voids a `rank-kill` whose probe before the fault failed, and its trainer's own fault may have fired by then.
- Attempt 1's trigger is the one the kind registers (`RankFailed` for `rank-kill`, `NodeFault` for `dcgm`), so the stop measured is the fault's and not, say, a deletion's.
- The controller observed that failure no earlier than 2 s before the fault and no later than 60 s after it, the fault's time being the trainer's own fault record or the node's time of the DCGM injection, raw; on both paid archives and the kind rehearsal the gap was 0.5 to 3.0 s.
  A matching trigger name alone does not tie the stop to the fault.
- When no stop was published, no log line and no Pod of the case shows a later attempt, since a later attempt runs only after a published stop.
- The run passes the scorer's run-level refusals (`run_refusals`: a clean tree, the approved trainer).
- Both stamps are present, `d ≥ 0`, and every successful read that shows a stamp shows the final object's value for it, with no read after the first that shows it without it.
- The case's `timeline.jsonl` brackets each stamp between two of the collector's successful reads, and `d` lies inside the interval those reads allow, widened by 2 s. A failed or malformed read, a row that is not JSON, one whose time cannot be read and one whose first attempt is not attempt 1 included, is skipped, not read as an absent stamp; both evaluators use one reader for this (`timeline_reads`).
  The two stamps are wall-clock times from separate `metav1.Now()` calls, possibly on two controller hosts, and the collector's reads are on another clock.
  What a read brackets is when the stamp was visible through the API, not when the controller made it: the controller stamps before its status update, and each read is timed when its response came back, not when it was asked.
  Neither latency is measured; the 2 s allows for them, and a larger one makes a correct `d` fall outside the bracket.
  So this is a consistency check, not a proof of one continuous clock: a `d` outside the bracket is INVALID, which can lose a correct measurement but cannot make one, and a `d` inside it is consistent only to the bracket's width, which is reported beside it.
  On `full` the brackets were 7.7 s wide for `rank-kill` and about 31 s for `dcgm`, whose injection holds the collector's loop; a discontinuity smaller than that would not be seen.
  Inside the bracket, `d` carries up to 1 s from the whole-second truncation of each stamp.

A case whose trigger is stamped and whose stop no successful read ever showed, with no later attempt in the final object, any read, its logs or its Pods, gives no `d`: it is reported as an unpublished stop, with the time from the read that first showed its trigger to the collector's last read (`unpublished_stop_observed_s`).
That time is a description, not a bound, and it refutes nothing: it is two readings of the collector's wall clock, so a jump of that clock alone turned a 2 s observation into a 62 s refutation while the controller's evidence stayed the same (sixth attack, 4).
A final object that lacks a stop the timeline or a later attempt shows is contradictory evidence and INVALID, not a stop that never came; so is an attempt 1 shown `Stopped` without its `stopConfirmedAt`, because the controller writes the two in one update (sixth attack, 3).
`d` assumes the controller's clock ran continuously between the two stamps it wrote; nothing in the run can show that, and the collector's bracket only bounds how far it can be wrong.

| outcome | rule, read in this order |
|---|---|
| REFUTED | any case's `d` ≥ 30 s, whatever the other cases or the recoveries did |
| NOT ASSESSED | otherwise, any of the four cases has no `d`, an unpublished stop among them; the evaluator names the unpublished ones |
| SUPPORTED | otherwise, every `d` ≤ 15 s |
| INCONCLUSIVE | otherwise |

Read in that order the outcomes are exclusive and cover every case.
A slow stop is evidence against H1 on its own, so a refutation does not wait on the other cases or on what the recovery after it did.
15 s is chosen from the mechanism, not from data: TERM forwarded ends a rank in about a second on kind, and the barrier polls every 2 s (`stopPoll`), so a barrier no longer held by the grace period should end well inside 15 s; 30 s is just under `full`'s smallest `d`, 31 s.
On `full`'s archive the evaluator gives `d` = 39, 39, 31, 31 s, each inside its bracket: REFUTED, as the question's premise says.

What was known when. The bars (15 s, 30 s) were written while the kind rehearsal ran and before its figures were read.
The validity rules and the reading order were added on 2026-11-05, after the first rehearsal had given `d` = 0 to 1 s on kind; they change which cases count, not the bars.
The unpublished-stop refutation was removed the same day, after the sixth attack and before any paid run of this stage; no rehearsal or archive had an unpublished stop, so the change moved no outcome that had been read.

What H1 can and cannot say.
SUPPORTED says that the controller's measured interval from its trigger to its stop confirmation was short on EKS under this stage's revisions.
It does not say the ranks escaped the grace period: the controller can observe the failure after the remaining ranks' termination has begun (`FailureTarget`), so time spent terminating before `failureObservedAt` is not in `d`, and the collector keeps no Pod deletion or container exit timestamps to show it.
It does not attribute the change to TERM forwarding alone, because the trainer and the operator also changed since `full`.
The samples of `waitingFor` in each case's timeline are reported beside `d` as the record of what the barrier waited on.
Two observations per kind are neither a rate nor a bound on other faults.

## Descriptive figures

Reported beside `full`'s and never pooled with them: each case's verdict and class, recovery (`score_eks.py`'s `recovery_s`), lost steps, parameter gap, checkpoint cost, and `phases_eks.py`'s milestones.
A difference in recovery is not attributed to any one change.
The scorer at the launch commit includes three fixes the first attack found (`9499dba5`):
- A job past its budget after every rank of attempt 2 stepped is "past its budget after a recovery", with its recovery kept, not a censored recovery.
- A censored recovery is reported with when observation of it ended, from the fault to the last read of the job, and not as a bound on it, because nothing shows the logs were followed throughout (`307f3541`).
- A save record without a finite, non-negative cost, or an attempt without costs from both ranks, is VOID, and a NaN or infinite clock is refused.
- Each rank of each attempt must have a save record for every step it recorded but at most its last, which a fault can cut before its save; both paid archives meet that, and a thinner sample is VOID rather than a median over it (`7d7e7fb4`).
- The steps themselves must be all there: the reference's from 1 to 30 on each rank, attempt 1's from 1 without a gap, and an in-trainer fault's rank up to the step its fault record names, since losing a step with its save passed the check above (`1729ad8a`).
- After the sixth attack (`e2e0633f`): a late recovery keeps its time only when each rank's first step of attempt 2 is the one after its checkpoint, and otherwise says only later progress was observed; an attempt that completed must have every save, its last included; two different save records for one rank and step VOID the case; and each node of attempt 2 must have been probed after its first step, or an ACCEPTED case is VOID and a late one's time is withheld.
Both committed archives keep every published verdict and figure under it (`hack/test/check-restart-session.sh`).

## Revisions it runs

- **Trainer:** `experiments/distributed-restart/train.py` with sha256 `2c5cdbf09fdb4c8149443a806396fdf73f7176ea1adb174f5fe8052cb53f572c`, passed as `APPROVED_TRAIN_SHA256`.
- **Runner and scorer:** this repository at the launch commit, a clean tree.
- **Operator:** the image GitOps deploys from `main`, which at registration is `44bd5e74`, pinning digest `sha256:12d60cfce8a5c0c0f9c3b9e8981059ee5de70c813585eec2d823887a6ac82d3c` built from `cb6cb9b2`.
  The gate checks that the deployed revision contains the UID record (`f7b8f9ca`) and that the running manager's image ID ends in that revision's pinned digest; it does not check what source the digest was built from.
  For this stage it also requires the deployed revision and its digest to equal the registered ones (`restart_operator_pin`, with `RESTART_OPERATOR_REV=44bd5e741559d45d573f1b7c8fc9020e09f999f6` and `RESTART_OPERATOR_DIGEST` as above), before any GPU is bought, and the session log keeps that line.
  No promotion is made from registration to teardown; one made anyway refuses the launch, or, after the gate, is a different operator and voids the run's H1 by this page.
  It does not contain the fence binding (#499), which this stage never exercises, because no case fences.

## Threat model

Added on 2026-11-05 after six attacks, when gpt-6-astra classified their 55 findings and 10 of them needed someone to edit the evidence; this page is judged against it.

- **Trusted:** the pinned trainer and operator above, and the collecting host with this repository's scripts at the launch commit.
- **In scope:** hung clients and their descendants, failed or slow AWS and Kubernetes APIs, interrupted writes, lost log records, ordinary clock faults on the collector, and a teardown that fails or lags.
- **Out of scope:** deliberate fabrication or editing of the evidence, compromised infrastructure, and a schema-valid value changed arbitrarily inside an otherwise intact record.

A rule that only an edited record can defeat is therefore not a defect of this registration, and a review finding of that kind is recorded with this reason rather than fixed.
That follows the scoping of SLSA, which names the threats it does not address and trusts its signer, and of MLPerf Training, which trusts its logger and bounds a reviewer's remedy to a rerun or a withdrawal.
Sealing the evidence (a manifest of every file's hash, anchored by a commit before scoring) would make an edit detectable; it is deferred, because it repairs nothing in scope.

## Budget and cost

Computed by `restart_gpu_budget` and pinned in `hack/test/check-restart-session.sh`:
- **Slots:** 1,680 s for each of `reference`, `no-rng-control` and the two `rank-kill` cases, and 1,860 s for each `dcgm` case with its reset; 10,440 s in all.
- **GPU budget:** preparation 4,080 s, plus the slots, plus the scale-down 900 s, which is 15,420 s.
- **Deadline:** with the 1,200 s of syncs and the held qualification and the 3,600 s margin, `TTL_MINUTES` must be at least 337. The session uses **340**, so it needs 380 minutes of credential.

These are the deadlines the runner sets, not billing limits.
What enforces them is one mechanism, `hack/lib/phase-supervisor.sh` (`docs/superpowers/specs/2026-11-05-paid-phase-supervisor-design.md`): from the scale-up to the scale-down, every step runs as a paid phase, a cgroup of its own killed whole at the step's deadline, so no client, credential helper or descendant of one, setsid or not, can hold the session past it.
The launcher's steps are the scale-up, T6, the node dump, Z2, T7, the qualification's last read, R5, R6, the final scorer, the scale-down and the GPU deadline's removal; the runner's, for each case, the GPU deadline's check, the group wait and warm-up, the case itself within its slot, and its verdict.
The launcher refuses to buy unless it has shown the mechanism works there (K1), by killing a sleeper in a cgroup it made.
A case its slot's end kills is VOID, never scored from what it left, and nothing more starts, because its job may still hold GPUs.
The per-call cuts it replaced as the bound (`restart_by`, `rk`, `rkd`, `rkt`, `session_kubectl_by`) stay, because refusing a call once its deadline has passed is cheaper than killing it; until `1729ad8a` they were the only bound, and the sixth attack showed both a credential helper that outlived one (1 s deadline, 2 s grace, 6.03 s taken) and calls none covered.
A phase is checked against its deadline every 0.5 s, and SECONDS counts whole seconds, so a phase can outlast its deadline by up to about 1.5 s.
What bounds the spend is still the EventBridge schedule, which asks for the GPU node group's scale-down 10 minutes before `TTL_MINUTES`, and the watchdog's destroy after it; neither is part of any phase, and killing a local client cancels no request AWS has already accepted.
The scale-down request is asynchronous and the destroy can fail; if it does, resources keep billing until they are removed by hand.

The estimate below assumes both act on time: the GPUs bill until the scale-down request 10 minutes before `TTL_MINUTES`, and the rest until the destroy ends 40 minutes after it.
The minutes the scale-down takes after its request are not in it, and nothing here has measured them; each 10 minutes of them adds $0.62 at $1.237/h.

| | at $1.237/h | at $1.40/h (`TRAIN_MAX_PRICE`) |
|---|---|---|
| 3 GPUs and their volumes, 5.50 h | 5.50 × $3.748 = $20.61 | 5.50 × $4.237 = $23.30 |
| the rest, 6.33 h at $0.263/h | $1.67 | $1.67 |
| data (3 × 3.3 GB through the NAT at $0.059/GB), EFS, IPv4 | $0.71 | $0.71 |
| **conditional estimate** | **$22.99** | **$25.68** |

That total is an estimate conditional on both backstops acting on time, not a ceiling: a scale-down that lags or a destroy that fails bills past it, and nothing here can cap the spend in dollars.

The expected session is far shorter, about 25 minutes of preparation and about 30 minutes of cases.
That puts the GPUs up for about 1 h, at **about $3 to $5**; `full`, with ten cases, came to about $5.5 by the same kind of estimate.
These are estimates, not billing.

## When it may start

The nightly destroy (`.github/workflows/destroy.yml`, 18:00 UTC) removes the cluster, and the launcher refuses a session that comes within two hours of it.
With `TTL_MINUTES=340` that leaves a window from 20:00 UTC to 10:20 UTC the next day, and none from 10:20 to 20:00 UTC.
Its cron has been seen to run hours late, and a run scheduled after the launcher's one look at the queue is not seen, so the window is not enough on its own.
For this session the workflow is therefore disabled by hand (`gh workflow disable destroy.yml`, with the owner's approval at launch) whatever the hour, and it is re-enabled once the teardown is confirmed.
Since `73444604` the launcher refuses `RESTART_STAGE=retarget` unless the workflow is `disabled_manually`.
Since `1729ad8a` it lists every run of the workflow's history, page by page, and refuses any not completed; asking status by status, as it did from `73444604`, missed a run that changed status between two of the questions.
On 2026-11-05 that listing read 115 runs over two pages, none of them unfinished.

## Gates before the launch

- Every gate of the earlier registration, including the operator gate's CRD and UID-commit checks.
- A clean tree at the launch commit and `APPROVED_TRAIN_SHA256` as above.
- `origin/main` is `44bd5e74`, and `RESTART_OPERATOR_REV` and `RESTART_OPERATOR_DIGEST` are given as above.
- The nightly destroy workflow is `disabled_manually` and no destroy run is pending.
- `aws sts get-caller-identity --profile gpu-lab` read in the same shell.
- The kind rehearsal of this stage (`RUNS=e hack/restart-lifecycle-kind.sh`): every case ACCEPTED through `score_kind_shim.py` and its lifecycle and outcome checks 0 FAIL, from a commit whose runner, scorer and trainer equal the launch commit's.
  The unmodified `score_eks.py` voids every kind case, because kind's ranks train with gloo on the CPU; that is the boundary the shim moves.
  Four earlier rehearsals, `hack/restart-lifecycle-kind-20261104T142003Z` at `5f83e8e2`, `hack/restart-lifecycle-kind-20261105T020442Z` at `c817c612`, `hack/restart-lifecycle-kind-20261105T034118Z` at `a38089c4` and `hack/restart-lifecycle-kind-20261105T044327Z` at `7d7e7fb4`, ran runners that later fixes replaced and are kept as records.
  The gate is met by `hack/restart-lifecycle-kind-20261105T054801Z` at `1729ad8a`: every case ACCEPTED, both checks 0 FAIL, and H1 SUPPORTED on kind with `d` = 0, 1, 1, 1 s.
  No runner, scorer, trainer, launcher or evaluator line changed between `1729ad8a` and the launch commit.
  The launcher's own path to the first case (T6, T7, R5) is not part of a kind run; the tests pin its deadlines.
  On kind every wait ends in seconds, so the rehearsal cannot show that a wait longer than 20 s survives; a test pins that every such wait goes through `rkt`.

## Review

codex `gpt-6-astra` attacked this page and the stage's commits on 2026-11-04 (read-only, at `5f83e8e2`, with the page staged), verdict "needs changes first", 14 findings.
Bare `codex review` of `7bd79840` found that the kind driver still refused run `e` (fixed in `5f83e8e2`, whose review found nothing).
Each finding was checked against the code or the archive before it was accepted; the dispositions:

| # | finding | disposition |
|---|---|---|
| 1 | the DCGM injection's `kubectl exec` has no deadline | first deferred; fixed after the second attack in `c817c612`, with a hanging-exec test |
| 2 | nested calls can overrun the evidence and reset allowances | first deferred; fixed in `c817c612` (`restart_by`, `GF_DEADLINE`), with a hanging-cluster test |
| 3 | an ACCEPTED case does not establish `d`: missing stamps, a negative `d`, a missing timeline all passed | fixed: `h1_retarget.py` with the validity rules above, each rule mutated to show its test fail |
| 4 | the outcome was conditioned on recovery, so a failed recovery could erase a refutation | fixed: a delivered fault gives `d` whatever the recovery; REFUTED is read first |
| 5 | SUPPORTED overstated what a short `d` shows | fixed: narrowed to the controller's interval |
| 6 | ±1 s assumed one continuous clock | fixed: the collector cross-check; a `d` outside it is INVALID |
| 7 | completion censoring is reported as recovery censoring | first deferred; fixed in `9499dba5` |
| 8 | checkpoint costs can omit a rank or every save | first deferred; fixed in `9499dba5` |
| 9 | non-finite clocks give ACCEPTED NaN | first deferred; fixed in `9499dba5` |
| 10 | the fault window was written as steps 12 to 25 | fixed: the code's 10 and 25, and what `step_before_fault` is |
| 11 | the operator is a moving target | fixed: the digest and its source registered, `origin/main` a gate |
| 12 | process timeouts presented as billing limits | fixed: "conditional ceiling", and what bills if teardown fails |
| 13 | the launch evidence was not committed | fixed by the launch commit, which carries the rehearsal archive and this page |
| 14 | EFS outage, the termination cost comparison, the window's end | fixed: each sentence corrected |

The second attack (2026-11-05, at `f5bb6f61`) found the first round's fixes incomplete, verdict "NO-GO", and bare reviews of `f5bb6f61` found its findings 3 and 4 independently.
Each was reproduced on the archives before it was fixed, and each fix has a test that was shown to fail with the fix reverted:

| # | finding | disposition |
|---|---|---|
| 1 | a VOID after delivery (missing after-probes) turned REFUTED into NOT ASSESSED | fixed in `083a84cb`: delivery is the scorer's delivery check alone |
| 2 | a failed read was read as an absent stamp; the bracket does not prove clock continuity | fixed: failed reads skipped; the check is described as consistency to the bracket's width, which is reported |
| 3 | a final object missing its stop gave a 43.9 s lower bound and a false REFUTED | fixed: contradictory evidence is INVALID |
| 4 | H1 skipped the scorer's run-level refusals | fixed: `run_refusals` first |
| 5 | `attempts: [null]` aborted the report | fixed: shapes checked, the case isolated |
| 6 | the lifecycle checker could not read the committed `.xz` timelines (6 FAIL) | fixed: it reads them, and the committed rehearsal's replay is a test |
| 7 | the operator pin was a local check | fixed in `eb661f70`: `restart_operator_pin` in the gate |
| 8 | the destroy check cannot exclude a late scheduled run | fixed: the workflow is disabled for the session |
| 9 to 13 | the first round's deferred 1, 2, 7, 8, 9 | fixed before this run instead of deferred, as above, and rehearsed again |

Bare `codex review` of the fixes (`083a84cb`, `9499dba5`, `eb661f70`, `c817c612`) found nothing in `eb661f70` and `c817c612` and three P2 defects in the others, each fixed in `eca90990` with a test shown to fail with the fix reverted:

| commit | finding | disposition |
|---|---|---|
| `083a84cb` | a read whose attempts are `[null]` counted as a successful read and, alone after the trigger, set a 59 s lower bound | fixed: a malformed read is skipped |
| `9499dba5` | a censored recovery's bound ran to the last row, failed reads included, and ignored log follows given up before it | fixed: the bound ends at the last successful read and is withheld when a follow was given up |
| `9499dba5` | a late recovery's time skipped the check that the probes labelled before the fault ran before it | fixed: `placed_fault` applies it on every path |
| `eca90990` | an attempt-1 Pod's given-up follows withheld the bound, though it cannot print attempt 2's step | fixed in `f483bfde`: only Pods not labelled attempt 1 count |

The third attack (2026-11-05, at `60bee411`, the checkout advancing to `f483bfde` during it) gave "NO-GO" with seven findings, the seventh already fixed by `f483bfde`.
Each was reproduced or read in the code first, and each fix has a test shown to fail with it reverted:

| # | finding | disposition |
|---|---|---|
| 1 | a hanging credential helper held `rk` past its deadline; `rkd` called after an enclosing deadline | fixed in `570b2423`: the real kubectl held a call 150 s without the cut, 3 s with it |
| 2 | a censored recovery's lower bound assumed log coverage nothing records | fixed in `307f3541`: reported as where observation ended, never as a bound |
| 3 | an unreadable clock probe file removed `d` through the shared loader | fixed in `307f3541`: the probes are read when first used |
| 4 | the collector brackets visibility, not stamping, and response time, not request time | narrowed: the limit is stated under H1, an outside `d` can only be lost, and a never-published stop is counted as the restart it held; the collector is not changed |
| 5 | the two evaluators skipped different malformed rows, and an unreadable time ended a case | fixed in `307f3541`: one reader, `status_reads`, for both |
| 6 | the pending-destroy check read the latest five runs only | fixed in `73444604`: every unfinished status counted, and the retarget launch refuses an enabled workflow |
| 7 | attempt-1 follows withheld the bound | already fixed in `f483bfde` |

Bare `codex review` of those fixes found nothing in `307f3541`, `7a12ae1d`, `6e719510` and `804c6735`, and these in the others:

| commit | finding | disposition |
|---|---|---|
| `570b2423` | P1: the new 20 s cut of `rk` also ended the reader's 600 s wait, the fault path's 300 s rollout and the warm-up's wait, which on EKS outlast 20 s | fixed in `804c6735`: those waits go through `rkt` with their own duration, and a test refuses any wait through `rk` or `rkd`; the kind rehearsal could not have shown it, because its waits end in seconds |
| `570b2423` | P2: its tests ran ahead of the scorer and launcher commits that follow it, so the suite fails at that commit alone | accepted, not rewritten: the suite passes from `73444604` on |
| `570b2423` | P2: the credential test needed a real kubectl, which the self-contained harness does not provision | fixed: the stub kubectl ignores its request timeout instead, and the real client's behaviour is recorded as measured by hand |
| `73444604` | P2: `action_required` is a conclusion of a finished run, and counting it would refuse every later session | fixed in `6e719510` |

Mutating the launcher's destroy refusal for the tests above armed two real TTL watchdogs that the tests' stray check did not see, because the watchdog's command quotes a case name with spaces; both were stopped by hand, the check now matches the pid file under the run directory (`7a12ae1d`), and a mutation showed it catching one.

The fourth attack (2026-11-05, at `52c64df1`) gave "NO-GO" with eight findings.
Each was reproduced on the archives or read in the code first; the fixes are in `7d7e7fb4`, each with a test shown to fail with its fix reverted:

| # | finding | disposition |
|---|---|---|
| 1 | the node qualification's own kubectl calls carried only a request timeout | fixed: run with the deadline-cut kubectl; under a 4 s deadline a hanging client held it 30 s without the cut and 5 s with it |
| 2 | a runner VOID removed a delivered `rank-kill`'s valid `d`, and its reason said nothing was injected | fixed: H1 reads delivery on the evidence and reports the runner's VOID beside `d`; the reason now says the trainer's own fault may have fired |
| 3 | the plugin's allowance was taken before the kubeconfig read, and the group wait and warm-up were not under their deadlines as a whole | fixed, the plugin's taken after the read and both waits under `restart_by`; narrowed for the sampling before a fault, whose overrun is stated under "Budget and cost" |
| 4 | a final stamp moved 20 s, the reads showing it at 1 s, gave `d` = 20 inside a 26 s bracket | fixed: every read that shows a stamp must show the final object's value |
| 5 | a restart triggered by a deletion gave a valid `d` for a `dcgm` case | fixed: attempt 1's trigger must be the kind's |
| 6 | one row that was not JSON ended the case, and the two readers kept different attempt shapes | fixed: `timeline_reads` parses row by row, and one rule for attempt shape serves both |
| 7 | 2 of the reference's 60 saves gave an ACCEPTED median | fixed: a save for every step but at most the last |
| 8 | the scorer's docstring still called censoring a bound, and H1 called an unpublished stop a `d` | fixed: both reworded |

The fifth attack (2026-11-05, at `21613c02`) gave "NO-GO" with six findings, three on the paid launch's own path and three on evidence that contradicts itself.
Each was reproduced first; the fixes are in `1729ad8a`, each with a test shown to fail with its fix reverted:

| # | finding | disposition |
|---|---|---|
| 1 | the launcher's first qualification (T6), its release (T7) and the first warm-up (R5) ran without the deadline-cut kubectl or their deadlines | fixed: `session_kubectl_by` for T6 and T7, `restart_by` for R5; a hanging kubectl held a call 30 s without the cut, 3 s with it under a 3 s deadline |
| 2 | the probe before a fault started after the case's deadline with an allowance of its own | fixed: it runs under the case's deadline, and a case whose deadline its sampling spent is VOID before its fault |
| 3 | a trigger the reads contradicted, or a stop missing from every status while the logs showed attempt 2, gave an unpublished-stop refutation | fixed: the trigger is checked against the reads before either branch, and a later attempt in the logs or Pods makes a missing stop INVALID |
| 4 | a step lost with its save hid from the save check, the reference kept ACCEPTED on 2 saves and `lost_steps` moved from 1 to 0 | fixed: the reference's steps must run 1 to 30, attempt 1's from 1 without a gap, and the fault rank's to its fault's step |
| 5 | a matching trigger name was taken as the fault's cause, an injection moved past the job's end still passing | fixed: the observed failure must come within -2 to +60 s of the fault, raw |
| 6 | asking the destroy runs status by status missed one that moved between two questions | fixed: one listing of every run, not completed counted |

## What this does not show

- No termination, fence or replacement: those ran in `full` on their recorded revisions and are not re-measured here.
- No EFS outage: no stage has run one on EKS.
- Nothing about the trainer's corrected failure modes. Those were induced on kind (#502), and none is induced here.
- Nothing about the fence binding (#499), which is not in the deployed operator and which no case reaches.
- No rate or tail: two cases per kind.
