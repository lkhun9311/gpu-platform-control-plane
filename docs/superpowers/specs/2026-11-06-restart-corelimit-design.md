# Distributed restart, `corelimit`: what holds the rank-kill stop for 38 s

Written 2026-11-06, before any run of this stage.
Status: **registered for one paid session; not yet run.**
The owner approved the purchase on 2026-11-06 ("유료 승인, 전부 병렬 수행"), after this design was proposed in the session; the session still starts only once the gates below are met.
The apparatus, the scorer and every rule not restated here are those of `docs/superpowers/specs/2026-11-01-distributed-restart-design.md` and `docs/superpowers/specs/2026-11-04-restart-retarget-design.md`, whose threat model this page adopts unchanged.

## The question

In `retarget` (`hack/distributed-restart-eks/2026-11-05-retarget`) the `dcgm` stop fell to 2 s and the `rank-kill` stop stayed at 38 and 39 s, as in `full`; H1 was REFUTED by `rank-kill` alone.
Read again on 2026-11-06, all four `rank-kill` cases of both runs show the same sequence in their logs:
- rank 1 kills itself for its fault (`kill-before-fsync`), and its log ends `Killed`;
- 0.17 to 0.21 s later rank 0's NCCL watchdog reports the peer gone (`ncclRemoteError`, "remote process exited"), says it is taking the process down, and ends with `terminate called after throwing an instance of 'c10::DistBackendError'`, which is `std::terminate` and so `abort()`;
- yet rank 0's log stream ends 41 to 42 s after that line, and the controller's barrier reads `job … to be deleted` until it does.

A process that aborts should be gone in milliseconds.
The leading explanation is a core dump: Amazon Linux 2023 pipes cores to `systemd-coredump` (`kernel.core_pattern = |/usr/lib/systemd/systemd-coredump …`), containerd's unit sets `LimitCORE=infinity` and its containers inherit it, and a CUDA process's dump can take tens of seconds to write, during which the process has not exited.
The rival explanation is a teardown that hangs until the Pod's 30 s grace period ends in SIGKILL.
The `dcgm` cases are consistent with both: their ranks are stopped by TERM, never abort, and ended in 2 s.
Nothing in either archive separates the two, because neither recorded how or when rank 0's container ended.
gpt-6-astra, asked the same question of the same archives without this explanation, reached the same timeline and left the mechanism open between these two; that is why this stage measures rather than assumes.

## Cases

`RESTART_STAGE=corelimit`: `reference`, `rank-kill-1` to `rank-kill-6`, `dcgm-1` to `dcgm-3`, in that order (`hack/lib/restart-session.sh`, `restart_cases`).
The even `rank-kill` cases run with core dumps off: each rank's shell sets `ulimit -c 0` before it starts the trainer (`restart_core_limit`, `RESTART_NOCORE_CASES`), so the trainer and nothing else inherits the limit.
The odd ones keep the limit the node gives.
The arms alternate so that neither runs all early or all late in the session.
The `dcgm` cases keep the node's limit; they repeat retarget's measurement to three cases and are descriptive here.
No `no-rng-control`, no termination: neither is asked anything by this question.
Every other setting is `retarget`'s: three `g5.xlarge` in `ap-northeast-2a`, EFS, 30 steps, case budget 720 s, rendezvous 600 s, collective 60 s, the same trainer and the same operator.

Each rank's log begins with one line the shell writes before the trainer starts: `rank-env: core_limit=… core_pattern=… torch_nccl_async_error_handling=…`, read inside the container.
Each case's `case.json` records its arm (`core_limit`: `0` or `inherited`).
The collector (#506) records, for every log stream, the container's state when the stream ended and, for a container that ended, its exit code, reason, start and finish times, and the Pod's `deletionTimestamp` with its `deletionGracePeriodSeconds`.
It also records every change to the case's Pods from a watch of its own (`pod-watch.json`), because a status read only at a stream's end found the Pod already deleted in the kind rehearsal and kept no exit code for the surviving rank.

## H2, registered before the run

`experiments/distributed-restart/h2_corelimit.py` evaluates it; `hack/test/check-restart-session.sh` pins each rule.

**H2.** With core dumps off, the `rank-kill` stop is short: every treated case's `d` is at most 15 s, while the untreated cases' stop stays slow.

`d` is measured for each of the six `rank-kill` cases by `h1_retarget.py`'s rules, unchanged: the same delivery check, trigger, chronology, publication, bracket and consistency conditions, and the same INVALID for a case that fails any.
A case also gives no `d` when its arm is not shown: its `case.json` must record the registered arm, and its attempt-1 ranks must have logged a core limit that agrees with it, `0` for a treated case and anything but `0` for an untreated one.
A limit the shell failed to set would otherwise be read as the treatment.
A treated case also gives no `d` unless a limit of 0 is shown to stop a dump under the `core_pattern` its ranks logged.
The kernel ignores RLIMIT_CORE when it pipes a core to a program (core(5)), so under a pipe the limit acts only through the program: `systemd-coredump` receives it as `%c` and, below a page, returns "Resource limits disable core dumping" before it reads the core from its stdin (systemd v256, `src/coredump/coredump.c`; the same check is in v252), and the kernel's write into the closed pipe then ends.
A file pattern the kernel limits itself.
So a treated case counts under a file pattern or a `systemd-coredump` pipe given `%c`, and under any other handler it is INVALID: there the treatment may have changed nothing, and a slow stop would be read as clearing the dump.
A limit of 1 would make the kernel refuse a piped dump on its own ("RLIMIT_CORE is set to 1, aborting core", Linux 6.12 `fs/coredump.c`); it is not used, because 0 is the limit an operator would set and the one whose effect is worth knowing.

| outcome | rule, read in this order |
|---|---|
| REFUTED | any treated case's `d` ≥ 30 s |
| NOT ASSESSED | otherwise, any of the six cases has no `d` |
| INCONCLUSIVE | otherwise, any untreated case's `d` < 30 s: the slow stop did not recur, so the arms cannot be compared |
| SUPPORTED | otherwise, every treated `d` ≤ 15 s |
| INCONCLUSIVE | otherwise |

The bars are H1's, chosen then from the mechanism and kept so the two read alike: 30 s is just under every slow stop seen (38 to 39 s), and 15 s leaves the barrier's 2 s poll and a TERM'd rank's second well inside it.

What H2 can and cannot say.
SUPPORTED says that, on these nodes, turning core dumps off for the ranks shortened the stop after a rank's death, three cases against three.
It does not by itself say a core dump took the time; the mechanism is read beside it, not decided by it:
- `h2_corelimit.py` prints, for each case, how the surviving rank's container ended: its exit code (134 for SIGABRT, 137 for SIGKILL), its reason, its finish time after the fault, and when its deletion was asked for.
  The stream records give the end, or the Pod watch's last terminated state when the Pod was deleted first; with neither, the end is printed as unread, never left out.
  The deletion request is the first `deletionTimestamp` less its `deletionGracePeriodSeconds`: the API server stamps the request plus the grace, so the stamp itself is the grace deadline, 30 s after the request.
- An untreated survivor ending 134 about 40 s after the fault, and a treated one ending 134 within seconds, is what a core dump predicts.
- An untreated survivor ending 137 about 30 s after its deletion was asked for is what a SIGKILL at the end of the grace period predicts.
  It does not say no dump was being written: a dump still in progress at the grace's end is killed the same way, so 137 separates "ended by its own abort" from "ended by the kubelet", not "dumped" from "did not".
- `rank-env` shows the node's `core_pattern` as the rank saw it, which is the only record of it this run makes.

REFUTED says that setting the ranks' core limit to 0 did not make the stop short.
It does not rule out every part of a core dump as the cause: with a pipe, the kernel still stops the process's other threads, starts the helper and begins the dump before the helper declines and closes the pipe (Linux 6.12 `fs/coredump.c`), and `systemd-coredump` gathers the process's metadata before it reads the limit (systemd v256 `src/coredump/coredump.c`).
Under REFUTED those parts remain candidates this run cannot separate; finding where the process waits needs host-side evidence it does not collect.
Three cases per arm are neither a rate nor a tail.

## Descriptive figures

As `retarget`'s, with `score_eks.py`'s summary split by arm for `rank-kill` (`same-nodes, core limit 0` and `same-nodes, core limit inherited`), never pooled, and `phases_eks.py`'s milestones.
The three `dcgm` cases are reported beside `retarget`'s two and `full`'s two, never pooled with them.
A recovery figure is not attributed to the arm beyond what H2 decides.

## Revisions it runs

- **Trainer:** `experiments/distributed-restart/train.py`, sha256 `2c5cdbf09fdb4c8149443a806396fdf73f7176ea1adb174f5fe8052cb53f572c`, unchanged since `retarget`.
- **Runner and scorer:** this repository at the launch commit, a clean tree.
- **Operator:** the registered `retarget` operator, revision `44bd5e741559d45d573f1b7c8fc9020e09f999f6`, digest `sha256:12d60cfce8a5c0c0f9c3b9e8981059ee5de70c813585eec2d823887a6ac82d3c`, required by `restart_operator_pin` for this stage as for `retarget`, and checked again after R4 (#506).

## Budget and cost

Computed by `restart_gpu_budget` and pinned in `hack/test/check-restart-session.sh`:
- **GPU budget:** 22,320 s (preparation 4,080 s, seven 1,680 s slots and three 1,860 s, scale-down 900 s).
- **Deadline:** `TTL_MINUTES` must be at least 452; the session uses **460**, which needs 500 minutes of credential, within the 720 the account issues.
  A first computation gave 18,720 s and 392, because it was run without the session's own waits for the GPU node, its plugin, the qualification and the node's removal (`WAIT_*` in `hack/eks-gitops-session.sh`); the figures here are those the session computes.

The deadlines are enforced as in `retarget`, by the phase supervisor; the EventBridge scale-down and the watchdog's destroy bound the spend, not any phase.

| | at $1.237/h |
|---|---|
| 3 GPUs and their volumes until the scale-down request 10 min before `TTL_MINUTES`, 7.5 h | 7.5 × $3.748 = $28.11 |
| the rest, 8.17 h at $0.263/h | $2.15 |
| data (3 × 3.3 GB through the NAT), EFS, IPv4 | $0.71 |
| **conditional estimate** | **$30.97** |

That total is conditional on both backstops acting on time, not a ceiling.
The expected session is about 25 minutes of preparation and about 35 minutes of cases, so about an hour of GPUs: **about $3 to $5**, an estimate; `retarget` came to about $2.1 by the same kind of estimate.

## When it may start

As `retarget`: the nightly destroy workflow is disabled by hand for the session and re-enabled once the teardown is confirmed, and the launcher refuses this stage unless it is `disabled_manually` and no run of it is unfinished.

## Gates before the launch

- `hack/test/check-restart-session.sh`, `hack/test/check-train-session-refusals.sh` and `hack/test/check-phase-supervisor.sh` pass at the launch commit.
- A kind rehearsal of this stage (`RUNS=f bash hack/restart-lifecycle-kind.sh`) at a commit whose runner is the launch commit's: every case ACCEPTED, both checks 0 FAIL, every rank's `rank-env` line present with the arm's limit, and the collector's stream records carrying the container's state.
  Kind cannot show a core dump's cost: its ranks run on CPU and this host writes no cores (`ulimit -c` is 0), so the rehearsal shows the arms applied, logged and scored, not H2.
  `hack/restart-lifecycle-kind-20261106T013822Z` at `8aa8f43d` met it for that runner: every case ACCEPTED, the lifecycle check 0 FAIL, the outcome check 0 FAIL once run `f` was registered in it, each rank's limit logged in its arm, and H2 through the kind shim INCONCLUSIVE because the slow stop does not recur on kind, as expected.
  The collector changed after it (below), so the gate is met again only by a rehearsal of the changed runner, which must also show the Pod watch recorded and every survivor's end read from it or from its streams.
- A bare `codex review` of the changes since `3ca2ed0e`, its findings fixed or recorded.
- The launch checks of `retarget`: operator pin, destroy workflow disabled by hand, deadlines armed, a fresh SSO login.

## Revisions before the run

On 2026-11-06, after every gate above was first met and before any purchase, gpt-6-astra was asked for an adversarial review of the stage and returned NO-GO with six findings.
Each was checked against the code and the kind rehearsal before it was fixed; none changes H2's rule or its bars.

| # | finding | checked | change |
|---|---|---|---|
| 1 | `RESTART_NOCORE_CASES` set, even empty, replaced the registered arms, and the scorer accepted the run; only H2, after the purchase, would say NOT ASSESSED | an empty value gives six `inherited` arms | the launcher refuses a registered stage given `RESTART_NOCORE_CASES`, before anything is bought (`restart_launch_refusal`) |
| 2 | a reused `EXDIR` keeps the last session's case directories, whose `VOID` markers and logs the scorer reads | case directories are made with `mkdir -p` and appended to | the launcher refuses an `EXDIR` that already holds `restart/` |
| 3 | REFUTED was said to rule the dump out, but a limit of 0 under a pipe leaves the kernel's thread stop, the helper's start and `systemd-coredump`'s metadata read in place; and 137 does not exclude a dump cut by SIGKILL | Linux 6.12 `fs/coredump.c` (`coredump_wait` before the helper starts, `dump_vma_snapshot` and the write after); systemd v256 and v252 (`gather_pid_metadata_*` before `save_external_coredump` reads the limit) | the reading of REFUTED and of 137 is narrowed above |
| 4 | the survivor's exit code is read only when its stream ends, and a Pod deleted first leaves none | kind run `f`, `rank-kill-1/streams.jsonl`: the survivor runs, runs, then is `gone` | a Pod watch apart from the streams (`pod-watch.json`); `h2_corelimit.py` reads the end from it when the streams have none, and prints it as unread when neither has it |
| 5 | `deletion` was the Pod's `deletionTimestamp`, which is the request plus the grace | kind run `f`, `dcgm-1/streams.jsonl`: finished `01:52:29`, `deletion` `01:52:59` | the grace is recorded beside it, and the request is the first stamp less its grace |
| 6 | `phases_eks.py` pooled the arms in its medians | its key was `(kind, class)` | the key and label carry the arm when a kind ran two |

## What this does not show

- Which of the core dump's parts takes the time (the kernel's walk of the mappings, the pipe, `systemd-coredump`'s compression and storage); the stage removes the dump, it does not profile it.
- Whether `TORCH_NCCL_ASYNC_ERROR_HANDLING` or a shorter grace period would do as well; neither is varied.
- Anything about a GPU's own core dump (`CUDA_ENABLE_COREDUMP_ON_EXCEPTION`), which is off by default and is not what aborted here.
- A rate or tail: three cases per arm, three `dcgm` cases.
- Turning core dumps off has a cost this stage does not weigh: a crash leaves no core to debug.
