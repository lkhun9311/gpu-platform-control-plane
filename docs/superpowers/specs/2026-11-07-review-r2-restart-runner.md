# Review r2: the restart runner and its scorers (2026-11-07)

gpt-6-astra read `116092ef` (dev) without direction, area "the restart experiments and their published results", and returned six findings.
Finding 1 belongs to the controller and is handled on `fix/restart-controller-review`; findings 2 to 6 are this page's.
Every verdict below is mine, from the code and the archives; astra's text was the starting point, not the evidence.
astra's review was static (its sandbox is read-only); every test and mutation run below is mine.

| # | astra's claim | verdict | change | pinned by | mutation |
|---|---|---|---|---|---|
| 1 | retirement trusts absent objects while an unreachable rank may still write | handled elsewhere | — | — | — |
| 2 | a case worker killed by a signal is scored, and one VOID lets the next case run | CONFIRMED | `f3e78098` | `check-restart-session.sh`: SIGKILL and SIGTERM of a case worker | red (both) |
| 3 | the rendezvous cases' budget is checked against the last step and a rank's exit | CONFIRMED | `453b3c11` | `check-restart-directed-kind.sh`: the 451 s and 647 s lines, and a copy ending at 730 s | red |
| 4 | the stale-workload, deactivated and node-lost holds accept an unobserved hold | CONFIRMED | `453b3c11`, `aa9fdacf`, `93a3d120`, `76c7f7e5` | thinned, shortened and unread copies of `20261101T003147Z` | red (gap, duration); see below |
| 5 | the kind driver's cleanup can wait forever on a helper that ignores TERM | CONFIRMED | `046c4d3f` | `check-restart-kind-driver.sh`: a TERM-resistant helper with a TERM-resistant child | red (both mutations) |
| 6 | a failed log stream of a container already ended is never read again | CONFIRMED | `0d50ff5c` | `check-restart-session.sh`: failed stream, terminated status, clean second read | red |

## 2. A case worker that ends in a status it never returns

`restart_run` (`hack/lib/restart-session.sh`, the loop after `paid_phase "case-$case"`) handled 124 and 125 as an interrupted phase and 2 as an unconfirmed retirement; any other status went to the scorer.
`restart_run_case` itself returns only 0, 1 (a VOID it retired) and 2, so a 137 or 143 is a worker killed before its retirement, whose job may still run.
Now any other status is VOID with "retirement unconfirmed" and stops every later case.
Test: the worker for `no-rng-control` kills itself with SIGKILL, then SIGTERM; `dcgm-1` must be NOTRUN with that reason.

## 3. The case budget at the job's end

Recomputed from `hack/distributed-restart-kind-20261104T120147Z`:

| case | what the README called its end | the job's terminal phase (`status.lastTransitionTime`) |
|---|---|---|
| `nfs-rendezvous-late` | 448 s (attempt 2's last step, 447.760 s) | `Succeeded` at 451 s |
| `nfs-rendezvous-never` | 614 s (the lone rank's exit, 12:24:57) | `Failed` at 647 s (attempt 2's `stopConfirmedAt`) |

Both stay inside the 720 s budget, so no verdict changes.
The scorer now checks the budget against the terminal phase and prints the step or exit beside it; the archive's README carries a dated correction of the two figures.

## 4. Holds observed throughout

`score_kind.py` read these holds with `Case.window`, which needs only one sample.
They now go through `held_window`, which requires the hold to have lasted its registered length (60, 60, 20 and 30 s, from `hack/distributed-restart-kind.sh`) and, for samples with a `started` field, `observed_window`'s rules (reads begun inside, no failed reads, no gap over 3 s).
Runs before `f43df078` (2026-11-01) recorded neither `started` nor failed reads; for them the gap and the duration are checked, and a failed read, which left an empty status or empty lists, is already refused by every predicate over a hold (`no_second_attempt` wants exactly one attempt).
A separate "every sample carries the job's attempts" condition was added and then removed (`76c7f7e5`) after its mutation stayed green for that reason; the test that pins the outcome stays, and it goes red when `no_second_attempt` accepts fewer than one attempt.

Re-scored from this branch, every committed `hack/distributed-restart-kind-*` archive gives the same verdict on every check as before (twelve archives; only the budget checks' names changed).
`20261031T144217Z` and `20261101T003147Z`, published as "all 36 checks pass", still pass: their holds had 53 to 54 samples over 60 s, 18 over 20 s and 27 over 30 s, the longest unobserved stretch 1.1 to 1.2 s.

## 5. The kind driver's TERM grace

`rstk_kill_tree` waited on the helper before killing anything that ignored TERM, and never killed the helper itself.
It now polls the helper (as a process, not with `kill -0`, which succeeds on a zombie) for `RSTK_TERM_GRACE` seconds, default 10, then kills the helper and its tree and reaps it.
Mutations: the old wait-first order, and a kill that skips the helper; both held the test until its 15 s watchdog.

## 6. A failed stream of an ended container

The collector ended a Pod's follows whenever the container read as anything but running, even after a stream that failed.
Now a stream that exited non-zero is read again unless the Pod is gone; `score_eks.py` judges a Pod by its last stream, so a clean re-read is what lets it count the Pod's log as complete.

## What the runner relies on for finding 1

`restart_retire` declares a case retired when its MLTrainingJob, Jobs, Workloads and Pods are gone, and then deletes its files.
That is sound only if "Pods gone" means each rank was seen to stop or its node was fenced; the controller change on `fix/restart-controller-review` (a rank-stopped finalizer held until then, also across the MLTrainingJob's deletion) is what makes it so.
Until that merges, a paid session must not rely on retirement after a partition.

## Engines

astra (gpt-6-astra, read-only) proposed the six findings.
I (Claude) confirmed each in the code, recomputed the archive figures, wrote the changes and tests, re-scored the archives, and ran every mutation.
