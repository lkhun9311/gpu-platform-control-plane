# Review r5, safety of paid cloud sessions: findings, verdicts and fixes

Written 2026-11-07.
gpt-6-astra (high effort, read-only sandbox, no tests run) reviewed `116092ef` on `dev` for whether a paid session can leave billed resources running, destroy what it should not, act on the wrong account or Region, or report a teardown done when it is not.
It returned twelve findings.
Each was re-read against the code by Claude before anything was changed; codex is not the source of any verdict below.
Every fix has a test, and every new check was mutated once on the committed fix to show its test goes red (27 mutations, all red on their final tests; two first survived and their tests were corrected, see 7 and the review of these fixes).
Nothing was run against AWS: every test uses stub `aws` and `terraform`.

| # | finding (astra) | verdict (Claude) | fix | test | mutation |
|---:|---|---|---|---|---|
| 1 | a watchdog left by a failed session destroys the next session's cluster | CONFIRMED | `e425ff88` | `check-session-teardown.sh` | m1, m4 red |
| 2 | force-unlock can release a live lock held from another checkout | CONFIRMED | `e425ff88` | `check-session-teardown.sh` | m2 red |
| 3 | losing the launcher host leaves the non-GPU infrastructure billing | CONFIRMED | proposal P1 | — | — |
| 4 | three Spot launchers bypass the sweeper | CONFIRMED (five runners, not three) | `f17e1428` | `check-spot-run-guards.sh`, spot goldens | m12–m15 red |
| 5 | an accepted asynchronous scale-down is treated as done | PARTLY | `c10ae4ca`; rest proposal P2 | `check-train-session-lib.sh` | m16, m17 red |
| 6 | the watchdog says SUCCEEDED without the residue census | CONFIRMED | `e425ff88` | `check-session-teardown.sh` | m3 red |
| 7 | the CNI sweep can delete another cluster's interfaces | CONFIRMED | `a892cb84`, `86cd213b` | `check-cni-eni-sweep.sh` | m7, m8 red |
| 8 | a profile name does not establish the account | CONFIRMED | `a892cb84`, `f17e1428`; Terraform part proposal P3 | `check-train-session-refusals.sh`, `check-spot-run-guards.sh` | m5, m6, m10, m11 red |
| 9 | the region SCP allows workloads in `us-east-1` | CONFIRMED | README corrected `205b15df`; policy change proposal P4 | — | — |
| 10 | a custom cluster name never reaches the Argo root | CONFIRMED | `a892cb84` | `check-session-teardown.sh` | m9 red |
| 11 | the SCP simulator passes calls the policies deny | CONFIRMED | `da01c22c` | `check-scp-eval.sh` | m18–m21 red |
| 12 | the teardown replay no longer runs the shipped decision | CONFIRMED | `c2c8d804` | the replay itself, now in `harness-check` | m22, m23 red |

## The findings

### 1. A stale watchdog and the shared state

Every session builds into `infra/aws/cluster`'s one state (`infra/aws/cluster/backend.tf`), and the watchdog destroys whatever that state holds when its TTL fires (`hack/lib/session-teardown.sh`, the destroy loop).
Nothing stopped a session from starting while an earlier session's watchdog was still armed; the session's own comment above the disarm decision already described the next session being "torn down under it".
Fixed: the watchdog's program carries a marker line, `killswitch_others` lists this user's armed watchdogs by it, and the session refuses to arm while one is alive, before it arms its own.
Not done: binding the destroy to an immutable session identity, as astra also asked; the refusal closes the case astra described, a relaunch after manual cleanup, without changing what a watchdog destroys.

### 2. Who holds the state lock

`live_holders` matched a terraform whose working directory was exactly this checkout's cluster root, or whose `-chdir` was spelled relative to it.
A terraform started from inside another checkout's cluster root, or given an absolute `-chdir` into one, was not seen, and its lock could be force-unlocked.
Fixed: each terraform process's directory is resolved as terraform resolves it (its `-chdir` against its own working directory) and any directory ending in `infra/aws/cluster` counts.
Tested with holders inside another checkout, by absolute `-chdir`, by a `-chdir` relative to another directory, and with a terraform on an unrelated root, which must not block the release.
Remaining: a copy of the root under another name, or the same user@host on another machine, is still not seen; astra's alternative, removing the automatic unlock, was not taken, because it is what lets a watchdog finish when the stopped session left a lock behind.

### 3. The launcher host is the only whole-cluster kill switch

Confirmed: the EventBridge schedule only scales the GPU node group to zero (`hack/lib/gpu-ttl.sh`); the CPU node, the EKS control plane, the NAT gateway, its address and EFS are destroyed only by the laptop's watchdog or the nightly workflow, and the retarget and corelimit registrations require that workflow disabled.
No local fix: it needs a cloud-side cleanup. Proposal P1.

### 4. Spot launches without a sweeper deadline

The sweeper terminates only instances carrying a `study-deadline` tag in `ap-northeast-2` (`infra/aws/bootstrap/sweeper/sweeper.py`).
Five runners launched without one: `m5b-scheduler-microtest`, `m5b-price-of-protection`, `queuelab-gpu-session`, `attention-microbench`, and `m5c-gpu-session` outside its pilot stages.
Fixed: `spot_launch` refuses a launch outside `ap-northeast-2` or whose tags carry no zoned future `study-deadline`, before it calls `run-instances`; the five runners add one at each launch attempt, their in-instance backstop plus twenty minutes (`spot_tags_with_deadline`).
The four characterised runners' goldens changed in exactly one way, the added tag (59 golden files, 68 lines, every change a `run-instances` line, one line for one line); all four suites pass, 84 scenarios.
Not done: checking the sweeper is healthy before each launch; `gpu-fault-session.sh` and `mps-capability-session.sh` do it, the older runners do not.

### 5. The scale-down update

`train_scale_down` read an accepted `update-nodegroup-config` plus terminated instances and an empty Auto Scaling group as done, without following the update.
Fixed: the update's id is read from the accepted answer and followed with `describe-update` until `Successful`; `Failed` or `Cancelled` fails at once, and an id that cannot be read, or an update still in progress at the deadline, fails the scale-down.
The answer's shape is UpdateNodegroupConfig's documented response; it was not captured from AWS, which no test here can do.
The EventBridge half is not fixed: the schedule invokes the update once and is deleted after it (`ActionAfterCompletion=DELETE`), and nothing reconciles its outcome. Proposal P2.

### 6. The watchdog's SUCCEEDED

A destroy that returned zero was called SUCCEEDED and the GPU deadline deleted, without the residue census the foreground teardown runs.
Fixed: the watchdog's program carries `teardown_residue` and runs it after a zero destroy, into `EXDIR/ttl-residue`; it says SUCCEEDED and removes the GPU deadline only when every query answered empty (the session's own deadline schedule excepted, since it is removed next), and otherwise says INCOMPLETE and keeps the deadline.

### 7. The CNI sweep's VPC

The sweep took the one project-tagged VPC left as this session's.
Fixed: the session reads its VPC from its own cluster right after `update-kubeconfig` (`SESSION_VPC`, also written to `EXDIR/vpc-id.txt`), and the sweep lists and deletes only in that VPC; with none recorded it deletes nothing and asks nothing.
The first test of "none recorded" unset the variable, which the shell's `set -u` turned into an error before the guard could matter, so its mutation survived (m8); the test now gives the empty value a failed read leaves, and the mutation is red.

### 8. The account

The EKS session required only a non-empty profile; the Spot runners read an account and used it.
Fixed: the EKS session refuses credentials in the environment (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`, which take precedence over a profile) and any account but gpu-lab (`007635145730`), before it arms the kill switch; `spot_account` does the same for every Spot runner.
Not done: Terraform's `allowed_account_ids`. Proposal P3.

### 9. The region SCP

`deny-region.json` allows every action in `us-east-1`; its README said it pinned the workload to one Region.
The services this repository calls in `us-east-1` are already in the `NotAction` list, which applies in every Region.
The README now says what the policy does. The policy file is unchanged. Proposal P4.

### 10. The Argo root's cluster name

The Argo root's providers authenticate with `aws eks get-token --cluster-name var.cluster_name`, default `gpu-platform`, and the session passed neither the name nor the Region.
Fixed for both its apply and its destroy.

### 11. The SCP simulator

The region check collapsed the exemption `kms:DescribeKey` into all of `kms`, and the family check searched the request for eleven prefixes, so `m7i.large` passed; CloudTrail lookups discarded their errors.
Fixed: `infra/aws/org/scp/scp_eval.py` evaluates each statement's own action patterns and its `aws:RequestedRegion` and `ec2:InstanceType` conditions, reports a launch that names no instance type as not evaluated rather than as approved, and fails on an unreadable event; `simulate.sh` keeps each lookup's error and fails the run on it.
Not done: whether `--max-results 200` returns every event in the window is unverified without AWS.

### 12. The teardown replay

`hack/test/teardown-replay/replay.sh` extracted a `still()` that had moved into the library as `teardown_residue`, stopped at its first step, and was run by nothing.
Fixed: it sources the library's census, extracts the session's current disarm decision, checks the stub answers every census label (EFS added, with a scenario), and it and `tagcheck-replay.sh` now run in `make harness-check`.

## Proposals that need the owner

- **P1 — a cloud-side whole-session cleanup (finding 3).** Before the first billed resource, register an EventBridge schedule that invokes a small Lambda in gpu-lab, authenticated by its own role, which at the session's TTL plus the destroy allowance deletes the EKS node groups and cluster, the NAT gateway and its address, and the EFS file system carrying this session's tags, and is removed only by a verified teardown. It needs `terraform apply` in the bootstrap root and an IAM role; nothing here applies it.
- **P2 — a scale-down that reconciles (finding 5).** Replace the one-shot schedule target with a Lambda that calls `UpdateNodegroupConfig`, follows the update to `Successful`, re-checks the desired size and instances, and retries until then, keeping the schedule until it has. Bootstrap root change; needs apply.
- **P3 — `allowed_account_ids` in every root's provider (finding 8).** `["007635145730"]` in `infra/aws/cluster`, `infra/aws/argo-bootstrap` and `infra/aws/bootstrap`. Safe to merge only after checking the nightly destroy workflow's role is in that account; not changed here because no plan was run.
- **P4 — narrow the region SCP to `ap-northeast-2` (finding 9).** Remove `us-east-1` from `aws:RequestedRegion` in `deny-region.json`, keeping the `NotAction` list. Apply only after `simulate.sh` passes on a week of recorded calls and a full non-GPU apply/destroy cycle under the new policy, as the README already requires for any change.

## Which engine established what

- gpt-6-astra: the twelve findings, from static reading of `116092ef`; it ran no test.
- Claude: each verdict, by reading the cited code and the code around it (finding 4 widened from three runners to five; finding 5 narrowed to PARTLY); every fix and test; the stub runs and the 23 mutations; the golden diff check.
- A bare `codex review --base origin/dev` (gpt-6-astra, high) of the branch, below.

## The review of these fixes

A bare `codex review` of the branch, given only the diff, returned three findings; all three were confirmed and fixed in `c14cb35e`, `b6aaffd1` and `2583ccf1`.

- **P1, the fix for finding 2 regressed.** terraform changes into its `-chdir` before it takes the lock, so a holder started from `infra/aws` with `-chdir=cluster` already has `infra/aws/cluster` as its working directory, and resolving `-chdir` against that again gave `.../cluster/cluster` and missed it. Confirmed on terraform's own process (`/proc/PID/cwd` of `terraform -chdir=cluster console` started from `infra/aws` is `infra/aws/cluster`). The test's stand-in had not changed directory, which is why the suite passed: a fixture imagined instead of taken from the producer. `live_holders` now reads the working directory first; the stand-in changes into its `-chdir` as terraform does, and a case started from the parent with `-chdir=cluster` was added (m26 red).
- **P2, a deadline recomputed per retry broke the launch's idempotency.** A retry under one client token with a deadline a second later is a different request, which EC2 answers `IdempotentParameterMismatch`. The tags are now fixed once per token, beside it; the spot characterisation compares, on the raw transcript, the tags of every retry under one token and prints a line only when they differ. The goldens normalise the deadline away and a stub retry falls within the same second, so the mutation (m24) needed a real 1.1 s pause between attempts to go red; m25 removes the tags from a runner's call and is red.
- **P2, the update id was read as JSON from a call that did not ask for JSON.** `--output json` is now on the request, and the test pins it; the first version of the test did not, and the mutation removing it survived (m27) until it did.

27 mutations in all, every one red on its final test; two (m8, m27) first survived and their tests were corrected.
