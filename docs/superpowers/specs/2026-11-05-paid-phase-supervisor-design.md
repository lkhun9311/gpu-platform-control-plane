# Paid-phase supervisor and evidence-bounded figures for the retarget run

Status: design approved 2026-11-05; not implemented.
It amends `docs/superpowers/specs/2026-11-04-restart-retarget-design.md` before its paid run, and does not replace it.

## Why

Six adversarial attacks of the retarget registration found 14, 13, 7, 8, 6 and 7 defects, and the count did not fall towards zero.
gpt-6-astra, asked to classify all 55 findings, put 19 in the apparatus and its spending (A), 21 in the scoring of the run's own evidence (B), 10 that need someone to edit the evidence (C), and 5 in documentation and readiness (D).
Two causes kept the count up.
The registration named no threat model, so every edited-evidence counterexample was treated as a launch blocker.
And every deadline was a wrapper around one call (`rk`, `rkd`, `rkt`, `session_kubectl_by`, `restart_by`), so each call or descendant a wrapper did not reach was a new finding: the sixth attack's first two were a credential helper that outlived `timeout -k` while holding the caller's pipe (1 s deadline, 2 s grace, 6.03 s taken) and the Z2, node-dump, scheduler and teardown calls no wrapper covered.

astra stated the smallest set after which it would return GO; this design is that set, and nothing more.
Evidence sealing (a hash manifest anchored by a commit) is deferred: astra judged it optional for a trusted one-off run, and it does not repair B.

## Threat model

The registration gains this paragraph, and the final review is asked to judge against it.

Trusted: the pinned trainer (`APPROVED_TRAIN_SHA256`) and operator (`RESTART_OPERATOR_REV`, `RESTART_OPERATOR_DIGEST`), and the collecting host with its scripts at the launch commit.
In scope: hung clients and their descendants, failed or slow AWS and Kubernetes APIs, interrupted writes, lost log records, ordinary clock faults on the collector, and teardown that fails or lags.
Out of scope: deliberate fabrication or editing of evidence, compromised infrastructure, and schema-valid values changed arbitrarily inside an otherwise intact record.
This follows the scoping of SLSA, which names the threats it does not address and trusts its signer, and of MLPerf Training, which trusts its logger and bounds a reviewer's remedy to a rerun or a withdrawal.

## 1. One supervisor for every paid phase

A new library, hack/lib/phase-supervisor.sh, holds one function: paid_phase NAME DEADLINE FN ARGS...

- FN runs in a subshell that first moves itself into a new child cgroup of the session's own cgroup, so every descendant it starts, including one that calls setsid, is a member of that cgroup.
- Its stdout and stderr go to a temporary file, never a pipe, so a descendant that survives cannot keep the caller's command substitution open.
- A timer outside the phase's cgroup writes `cgroup.kill` at DEADLINE (in SECONDS); after FN returns, any member left is killed the same way, and the cgroup is removed once `cgroup.events` reports it empty.
- It prints the file and returns FN's status, or 124 when the deadline ended the phase.
- State the caller keeps (`stop`, `prev`, `want`, `SCALED_UP`, `GPU_ARMED`) stays in the parent shell; a phase reports through its output and its files only.

The launcher, when `TRAIN` buys GPUs, re-executes itself under `systemd-run --user --scope -p Delegate=yes` before anything is bought, and refuses to buy if the session's cgroup is not writable to it.
On this host (systemd 259.5, cgroup2) a probe on 2026-11-05 confirmed the mechanism: a child cgroup holding a setsid-escaped sleep and a TERM-ignoring sleep that kept the output file open was emptied by one `cgroup.kill` in 2 s, with no survivor.

Phases put under it, from the scale-up to the scale-down:

- the launcher: the scale-up call, T6, the node dump, Z2, T7, the qualification's final dump, R5, R6, and the final scorer;
- `restart_run`, for each case: `restart_deadline_ok`, `restart_scale_group`, the group wait and node preparation, `restart_run_case`, and `restart_verdict`;
- `train_down`: `train_scale_down` and `ttl_disarm`, each with its own deadline, so a phase killed earlier still reaches them.

`restart_by`, `rk`, `rkd`, `rkt` and `session_kubectl_by` stay: they refuse a call once its deadline has passed, which is cheaper than killing it.
The bound itself is now the cgroup, and the registration says so.
The TTL watchdog and the EventBridge scale-down stay outside every phase's cgroup as independent backstops; neither is claimed to bound spending.

A killed phase loses what it had not written.
A case so ended is VOID or NOT ASSESSED, never scored from a partial write, and a case whose delivery or retirement is uncertain stops the cases after it, as `restart_run` already does for its return status 2.

Tests, in `hack/test/check-restart-session.sh`, drive the launcher and runner paths with stubs and assert that all descendants are gone and teardown is reached:

- a credential helper that ignores TERM and keeps stderr open after kubectl exits;
- a descendant that called setsid;
- a phase started with its budget already spent.

Each test is mutated to show it fails: without the `cgroup.kill`, and with the output sent through a pipe again.

## 2. H1 decides only from published stops

The evaluator's unpublished-stop branch in `experiments/distributed-restart/h1_retarget.py`, whose span was reported as a lower bound, no longer contributes to REFUTED; the span is now `unpublished_stop_observed_s`.
A case with no `stopConfirmedAt` for attempt 1 yields no `d`; it is reported as an unpublished stop, with the collector's wall-clock span of observation as a description and not as a bound.
REFUTED and SUPPORTED are decided over the cases with a valid `d`, with the bars unchanged: any valid `d` of 30 s or more still refutes.
This removes the false bound a collector clock jump produced (sixth attack, 4) and makes a missing timestamp beside a published `Stopped` irrelevant to the verdict (sixth attack, 3).
The registration states that `d` assumes the controller's clock ran continuously between the two timestamps it wrote.

Tests: a missing-stop fixture and one whose collector clock jumps 60 s cannot refute; the `full` archive still evaluates REFUTED with `d` = 39, 39, 31, 31 s; the latest kind rehearsal still evaluates SUPPORTED.

## 3. Descriptive figures only from the evidence they need

In `experiments/distributed-restart/score_eks.py`:

- A late recovery time is reported only when each rank's first resumed step is the step after its checkpoint; otherwise the figure is withheld and marked as later progress observed, while the FAILED or late verdict stands.
- Checkpoint statistics require every save of an attempt that completed; the allowance for a missing last save applies only to an interrupted attempt.
- Two records for one attempt, rank and step with different costs withhold the statistic; identical replayed records still count once.
- A probe counts as after only if it is timed after the recovery or completion it brackets; with none, the recovery time is withheld.

Tests are the sixth attack's three reproductions as fixtures, each mutated to show it fails.

## 4. Registration and the final review

The registration's "Budget and cost" section is corrected where it is now false: the claim that the only overrun left is the sampling before a fault, and the reading of $22.99 as a ceiling, which is a conditional estimate.
The threat model above is added.
Then the gates run again on the launch commit: the shell tests with their mutations, the scorer and evaluator tests, a new kind rehearsal archived under `hack/`, and the launch checks (operator pin, destroy workflow disabled by hand, deadlines armed).

The final review is a bare `codex review --commit` of the changes, plus one astra pass asked for GO or NO-GO against the threat model and these four items rather than for an open-ended attack.
A finding in scope is fixed; a finding out of scope is recorded in the registration's dispositions with its reason.
The paid run still starts only on the user's confirmation at launch.
