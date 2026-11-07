# Review r4: the Slurm lab and the operations documents (2026-11-07)

gpt-6-astra reviewed, without direction, the Slurm lab (`experiments/slurm-lab/`), the failure matrix and decision records (PR #469) and the 1,024-GPU design note (PR #470) at `116092ef`, read-only, and returned thirteen findings.
Each was then checked by Claude against the code, the archives and the arithmetic; the verdicts, figures and fixes below are Claude's.
astra's sandbox ran nothing; every test, re-score and mutation below was run by Claude on branch `fix/slurm-docs-review`.

## Verdicts

| # | finding (astra) | verdict (Claude) | evidence | change |
|---|---|---|---|---|
| 1 | a signal file that is not UTF-8 ends `gpuhc.py` with a traceback and no drain | CONFIRMED | `etc/gpuhc.py:74-78` caught only `OSError`; `UnicodeDecodeError` is a `ValueError` | decode explicitly, turn a decode error into `Unjudged` (drain) — `6f0a0529` |
| 2 | a transient `scontrol requeue` failure exempts the job for good, and records outlive the incident | CONFIRMED | `etc/gpuhc.py:158-167` appended every attempted id whatever the return code; only step 6 cleared the file | record only a requeue that took or the `--no-requeue` refusal; clear the record on a healthy reading — `6f0a0529` |
| 3 | the site row treats a DCI loss as a site loss and sends running jobs to the other site | CONFIRMED | design note "Failure domains": `site \| power, cooling, DCI loss \| … jobs restart at the other site`, while "Shape" says no collective crosses the DCI | separate site and DCI rows; ownership moves only after confirmation or fencing — `e86db0b7` |
| 4 | the load-none control counts as caught even when its restarted attempt also failed | CONFIRMED | `steps/05-train-requeue.sh:35-38` required the four expected lines and did not bound the rest | scorer `--load-none-control` passes only for exactly the five expected failures, with each rank trained 1..40 from zero and equal to the reference — `35868074` |
| 5 | the scorer accepts records from two jobs or one rank's records under the other's name | CONFIRMED | `score_requeue.py:90-92` checked `attempt` only; no `rank`, `run_id` or per-rank file check; resume matched by step, not directory | bind records to file rank and the case's `JobId`, require every rank of every attempt, require the resume directory attempt 0 published — `35868074` |
| 6 | a timed-out wait does not fail its step | CONFIRMED | `steps/lib.sh` `trace`/`wait_until` returned 1 and no caller acted; `evidence/2026-11-04/02a-account-quota.txt:86` is a timeout in a step that exited 0 | a timeout fails the step at exit unless the wait passes `-o`; the one observational wait (02a, `Resources`) now says so — `4eadadc1` |
| 7 | `run.sh` cleans up only after every step succeeded | CONFIRMED | `run.sh:28-30` after the loop, under `set -e` | `trap cleanup EXIT` before startup, status kept, `KEEP=1` honoured — `4eadadc1` |
| 8 | the design assumes an NCCL timeout requeues the job automatically | CONFIRMED | design note alert table: "Slurm or Kueue requeues"; the lab requeued only for a lost node (`slurm.conf` has `JobRequeue=1`, no `RequeueExit`); `distributed.maxRestarts` defaults to 0 | the cell now says retry is configured (`RequeueExit`, `maxRestarts`), not automatic — `e86db0b7` |
| 9 | the 1.6 s DCI lower bound double-counts a two-site exchange | PARTLY | 2(n−1)/n × 20 GB = 20 GB each way for n = 2; at 25 GB/s each way that is 0.8 s; 1.6 s holds only if 25 GB/s is the sum of both directions, which the assumption did not say | the bound is 0.8 s with the DCI stated as 25 GB/s each way; the conclusion stands — `e86db0b7` |
| 10 | ADR 1's mechanism sentence contradicts the ladder where time-slicing met the target | PARTLY | ADR 1 Evidence: met at 1.16 and 2.31 req/s, then "neither … reached it at the loads measured"; the decision text itself already names the load | the sentence names the loads where it was missed; the same clarification inline in `docs/11_WHAT_THIS_MEASURED.md` without moving its lines — `e86db0b7` |
| 11 | the design attributes quota release to the taint while the scorer measures it from deactivation | CONFIRMED | `internal/gpufault/score.go:593-595`: `quota_release` = `wholeSecond(release, deact)`; recomputed from `hack/gpu-fault/2026-10-27-run2/verdict.json`: taint→release upper ends 0.8676, 0.8658, 0.8649, 0.8677, 0.8674 s, median **0.867357 s** (ECC arm 0.867294 s) | both places in the design note give 0.867 s after the taint beside 0.774 s after the deactivation — `e86db0b7` |
| 12 | the failure matrix calls a same-queue witness a second tenant | CONFIRMED | `ready-timeout-witness-1/witness.yaml:5,7` and `mltrainingjob.yaml:5,7`: both namespace `partial`, queue `gpu-partial` | "a second workload in the same queue … not across tenants", in the matrix and inline in `docs/11` — `e86db0b7` |
| 13 | the Slurm comparison says the repository has no whole-job retry | CONFIRMED | `experiments/slurm-lab/README.md` comparison row vs `internal/controller/mltrainingjob_restart.go` (`maxRestarts` > 0) | the row distinguishes the default (no retry) from a set restart budget — `e86db0b7` |

Every correction to a published page carries its date and says what it replaced.

## What pins each fix

`hack/test/check-slurm-lab-host.sh`, added to `make harness-check` (so to CI's `infra-validate`), runs three things with no Slurm and no containers:

- `experiments/slurm-lab/check_gpuhc.py`, 22 cases against stub `scontrol`/`squeue`, three of them new (undecodable signal, transient requeue failure retried, a new fault after a healthy reading requeues again);
- `experiments/slurm-lab/check_score_requeue.py`, new: the archived step-5 runs and five doctored copies of them (a crashed control, rank 0 filed as rank 1, attempt 0 from another job, a missing rank log, a resume from a directory attempt 0 did not publish);
- `steps/lib.sh` against a stub `docker`: a timed-out `wait_until` or `trace` fails the step, `-o` does not, a step's own failure keeps its status, and a step trap like `00-fileless-gres.sh`'s keeps the rule; and `run.sh` against a stub `docker` whose build fails: the lab is torn down and exit 7 kept, and left with `KEEP=1`.

Each new check was mutated once after its fix was committed, and went red:

| mutation | red case |
|---|---|
| `gpuhc.py` catches `KeyError` instead of `UnicodeDecodeError` | a signal that is not UTF-8 drains |
| `gpuhc.py` records every attempted requeue | a requeue that timed out is tried again |
| `gpuhc.py` keeps the record on a healthy reading | a new fault after a healthy reading requeues the job again |
| `gpuhc.py` decodes as latin-1 | a signal that is not UTF-8 drains (it still drained, as malformed; the reason differs) |
| scorer drops the rank check | rank 0's records filed as rank 1 are refused |
| scorer drops the `JobId` check | attempt 0 records from another job are refused |
| scorer drops the every-rank-log check | a missing rank log is refused |
| `load_none_caught` returns true | a load-none control whose restarted attempt stopped at step 5 is not caught |
| scorer drops the resume-directory check | a resume from a directory attempt 0 did not publish is refused |
| `lib.sh` drops its `step_end` trap | both timed-out-wait cases |
| `wait_until` does not count its timeout | the `wait_until` case and the 00-style trap case |
| `trace` does not count its timeout | the `trace` case |
| `run.sh` drops its cleanup trap | the failed-build teardown case |

## Published results re-scored

The hardened scorer was run over every archived requeue run; no verdict changed:

| run | job | before (scorer of the day) | now |
|---|---|---|---|
| `evidence/2026-11-01-train` full | 3 | `30 passed, 0 failed` | `44 passed, 0 failed` |
| `evidence/2026-11-01-train` load-none | 4 | `18 passed, 5 failed` | `35 passed, 5 failed`, caught for the expected reason only |
| `evidence/2026-11-04` full | 36 | `30 passed, 0 failed` | `44 passed, 0 failed` |
| `evidence/2026-11-04` load-none | 37 | `18 passed, 5 failed` | `35 passed, 5 failed`, caught for the expected reason only |
| `evidence/2026-11-04` batch-host loss | 46 | `30 passed, 0 failed` | `44 passed, 0 failed` |

The step-6 and step-2 transcripts are unaffected in content; under the new `lib.sh`, step 2 would still exit 0 because its one timeout is now marked as an observation, which the README already reported.
The container lab itself was not re-run: no change alters what a step does to the cluster, only how its outcome is judged, and the judged archives are above.

## Not done here

- The design note's other ASSUMPTION rows were not re-derived; only the two figures astra named were recomputed.
- Step 5's use of `--load-none-control` and the `-o` flag in step 2 are exercised only by a full lab run, which was not repeated.
