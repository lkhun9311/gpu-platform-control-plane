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

- `score_eks.py` found the fault delivered: its verdict is ACCEPTED or FAILED, not VOID. A FAILED recovery still gives a `d`, because the stop is measured before the recovery.
- Both stamps are present and `d ≥ 0`.
- The case's `timeline.jsonl` brackets each stamp between two of the collector's reads, and `d` lies inside the interval those reads allow, widened by 2 s.
  The two stamps are wall-clock times from separate `metav1.Now()` calls, possibly on two controller hosts; the collector's reads are on another clock, so a `d` outside its bracket means the controller's clock did not run continuously and `d` is not a measurement.
  Inside the bracket, `d` carries up to 1 s from the whole-second truncation of each stamp.

A case whose trigger is stamped and whose stop never is gives a lower bound instead: the time from its trigger to the collector's last read.

| outcome | rule, read in this order |
|---|---|
| REFUTED | any case's `d` ≥ 30 s, or any lower bound ≥ 30 s, whatever the other cases or the recoveries did |
| NOT ASSESSED | otherwise, any of the four cases has no `d` |
| SUPPORTED | otherwise, every `d` ≤ 15 s |
| INCONCLUSIVE | otherwise |

Read in that order the outcomes are exclusive and cover every case.
A slow stop is evidence against H1 on its own, so a refutation does not wait on the other cases or on what the recovery after it did.
15 s is chosen from the mechanism, not from data: TERM forwarded ends a rank in about a second on kind, and the barrier polls every 2 s (`stopPoll`), so a barrier no longer held by the grace period should end well inside 15 s; 30 s is just under `full`'s smallest `d`, 31 s.
On `full`'s archive the evaluator gives `d` = 39, 39, 31, 31 s, each inside its bracket: REFUTED, as the question's premise says.

What was known when. The bars (15 s, 30 s) were written while the kind rehearsal ran and before its figures were read.
The validity rules and the reading order were added on 2026-11-05, after the rehearsal had given `d` = 0 to 1 s on kind; they change which cases count, not the bars.

What H1 can and cannot say.
SUPPORTED says that the controller's measured interval from its trigger to its stop confirmation was short on EKS under this stage's revisions.
It does not say the ranks escaped the grace period: the controller can observe the failure after the remaining ranks' termination has begun (`FailureTarget`), so time spent terminating before `failureObservedAt` is not in `d`, and the collector keeps no Pod deletion or container exit timestamps to show it.
It does not attribute the change to TERM forwarding alone, because the trainer and the operator also changed since `full`.
The samples of `waitingFor` in each case's timeline are reported beside `d` as the record of what the barrier waited on.
Two observations per kind are neither a rate nor a bound on other faults.

## Descriptive figures

Reported beside `full`'s and never pooled with them: each case's verdict and class, recovery (`score_eks.py`'s `recovery_s`), lost steps, parameter gap, checkpoint cost, and `phases_eks.py`'s milestones.
A difference in recovery is not attributed to any one change.
The scorer's known limits, found in the same attack and not fixed before this run so that the run uses the rehearsed scorer, apply to these figures and are stated beside them:

- A FAILED case "censored at its budget" may have recovered and then not completed within 720 s; the label does not say which.
- A checkpoint cost aggregate does not check that every save record carries a numeric cost from both ranks.
- A non-finite clock probe is not refused.

Each figure that reaches the results is checked by hand against these before it is published.

## Revisions it runs

- **Trainer:** `experiments/distributed-restart/train.py` with sha256 `2c5cdbf09fdb4c8149443a806396fdf73f7176ea1adb174f5fe8052cb53f572c`, passed as `APPROVED_TRAIN_SHA256`.
- **Runner and scorer:** this repository at the launch commit, a clean tree.
- **Operator:** the image GitOps deploys from `main`, which at registration is `44bd5e74`, pinning digest `sha256:12d60cfce8a5c0c0f9c3b9e8981059ee5de70c813585eec2d823887a6ac82d3c` built from `cb6cb9b2`.
  The gate checks that the deployed revision contains the UID record (`f7b8f9ca`) and that the running manager's image ID ends in that revision's pinned digest; it does not check what source the digest was built from.
  So `main` must still be `44bd5e74` at launch; a promotion after this page is a different operator and needs this line revised first.
  It does not contain the fence binding (#499), which this stage never exercises, because no case fences.

## Budget and cost

Computed by `restart_gpu_budget` and pinned in `hack/test/check-restart-session.sh`:
- **Slots:** 1,680 s for each of `reference`, `no-rng-control` and the two `rank-kill` cases, and 1,860 s for each `dcgm` case with its reset; 10,440 s in all.
- **GPU budget:** preparation 4,080 s, plus the slots, plus the scale-down 900 s, which is 15,420 s.
- **Deadline:** with the 1,200 s of syncs and the held qualification and the 3,600 s margin, `TTL_MINUTES` must be at least 337. The session uses **340**, so it needs 380 minutes of credential.

These are the deadlines the runner sets, not billing limits.
The budget charges each phase an allowance that some nested calls can overrun (evidence collection, the DCGM reset), and the DCGM injection's `kubectl exec` has no deadline of its own.
What bounds the spend is the EventBridge schedule, which asks for the GPU node group's scale-down 10 minutes before `TTL_MINUTES`, and the watchdog's destroy after it.
The scale-down request is asynchronous and the destroy can fail; if it does, resources keep billing until they are removed by hand.

The estimate below assumes both act on time: the GPUs bill until the scale-down request 10 minutes before `TTL_MINUTES`, and the rest until the destroy ends 40 minutes after it.
The minutes the scale-down takes after its request are not in it, and nothing here has measured them; each 10 minutes of them adds $0.62 at $1.237/h.

| | at $1.237/h | at $1.40/h (`TRAIN_MAX_PRICE`) |
|---|---|---|
| 3 GPUs and their volumes, 5.50 h | 5.50 × $3.748 = $20.61 | 5.50 × $4.237 = $23.30 |
| the rest, 6.33 h at $0.263/h | $1.67 | $1.67 |
| data (3 × 3.3 GB through the NAT at $0.059/GB), EFS, IPv4 | $0.71 | $0.71 |
| **conditional ceiling** | **$22.99** | **$25.68** |

The expected session is far shorter, about 25 minutes of preparation and about 30 minutes of cases.
That puts the GPUs up for about 1 h, at **about $3 to $5**; `full`, with ten cases, came to about $5.5 by the same kind of estimate.
These are estimates, not billing.

## When it may start

The nightly destroy (`.github/workflows/destroy.yml`, 18:00 UTC) removes the cluster, and the launcher refuses a session that comes within two hours of it.
With `TTL_MINUTES=340` that leaves a window from 20:00 UTC to 10:20 UTC the next day, and none from 10:20 to 20:00 UTC.
Its cron has been seen to run hours late, so the window is not enough on its own: the launcher also refuses while a destroy run is queued or in progress.
The window is not enforced only when the workflow is disabled by hand, which is then re-enabled after the session's teardown.

## Gates before the launch

- Every gate of the earlier registration, including the operator gate's CRD and UID-commit checks.
- A clean tree at the launch commit and `APPROVED_TRAIN_SHA256` as above.
- `origin/main` is `44bd5e74`.
- `aws sts get-caller-identity --profile gpu-lab` read in the same shell.
- The kind rehearsal of this stage (`RUNS=e hack/restart-lifecycle-kind.sh`): every case ACCEPTED through `score_kind_shim.py` and its lifecycle and outcome checks 0 FAIL, from a commit whose runner, scorer and trainer equal the launch commit's.
  The unmodified `score_eks.py` voids every kind case, because kind's ranks train with gloo on the CPU; that is the boundary the shim moves.
  Met by `hack/restart-lifecycle-kind-20261104T142003Z` at `5f83e8e2`.

## Review

codex `gpt-6-astra` attacked this page and the stage's commits on 2026-11-04 (read-only, at `5f83e8e2`, with the page staged), verdict "needs changes first", 14 findings.
Bare `codex review` of `7bd79840` found that the kind driver still refused run `e` (fixed in `5f83e8e2`, whose review found nothing).
Each finding was checked against the code or the archive before it was accepted; the dispositions:

| # | finding | disposition |
|---|---|---|
| 1 | the DCGM injection's `kubectl exec` has no deadline | accepted; not fixed before this run, so the run uses the rehearsed runner. The spend is bounded by the EventBridge scale-down and the destroy, as "Budget and cost" now says; the fix is on its own branch |
| 2 | nested calls can overrun the evidence and reset allowances | accepted; same treatment as 1 |
| 3 | an ACCEPTED case does not establish `d`: missing stamps, a negative `d`, a missing timeline all passed | fixed: `h1_retarget.py` with the validity rules above, each rule mutated to show its test fail |
| 4 | the outcome was conditioned on recovery, so a failed recovery could erase a refutation | fixed: a delivered fault gives `d` whatever the recovery; REFUTED is read first |
| 5 | SUPPORTED overstated what a short `d` shows | fixed: narrowed to the controller's interval |
| 6 | ±1 s assumed one continuous clock | fixed: the collector cross-check; a `d` outside it is INVALID |
| 7 | completion censoring is reported as recovery censoring | accepted; scorer fix on its own branch, stated as a limit under "Descriptive figures" |
| 8 | checkpoint costs can omit a rank or every save | accepted; same as 7 |
| 9 | non-finite clocks give ACCEPTED NaN | accepted; same as 7 |
| 10 | the fault window was written as steps 12 to 25 | fixed: the code's 10 and 25, and what `step_before_fault` is |
| 11 | the operator is a moving target | fixed: the digest and its source registered, `origin/main` a gate |
| 12 | process timeouts presented as billing limits | fixed: "conditional ceiling", and what bills if teardown fails |
| 13 | the launch evidence was not committed | fixed by the launch commit, which carries the rehearsal archive and this page |
| 14 | EFS outage, the termination cost comparison, the window's end | fixed: each sentence corrected |

## What this does not show

- No termination, fence or replacement: those ran in `full` on their recorded revisions and are not re-measured here.
- No EFS outage: no stage has run one on EKS.
- Nothing about the trainer's corrected failure modes. Those were induced on kind (#502), and none is induced here.
- Nothing about the fence binding (#499), which is not in the deployed operator and which no case reaches.
- No rate or tail: two cases per kind.
