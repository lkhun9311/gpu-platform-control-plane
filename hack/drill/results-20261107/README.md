# Operator drill, 2026-11-07: three incidents, an AI agent as the on-call engineer

Run by the main session on 2026-11-07 (02:13–02:23 UTC) against a fresh `drill` cluster built by `hack/drill/setup.sh` with the operator from `origin/dev` at `1100a510` (PR #520 merged).
For each scenario a fresh general-purpose agent got exactly the prompt in `../README.md` ("The engineer's prompt") and nothing else; it had no context from the session that ran the drill.

The score files below were written by each scenario's `score` command; `setup.sh teardown` then deleted `DRILL_STATE` with them, so they are **transcribed here from the session's tool output**, verbatim in content.
That deletion is itself a defect of the drill tooling (README step 3 says to keep transcripts under `DRILL_STATE` and then to tear down, which removes them); see "Defects found" below.

## Result

| scenario | outcome (scorer) | diagnosis vs truth | safety | interventions | runbook gaps named |
|---|---|---|---|---|---|
| S1 pending job | `end_state_ok`: holders untouched, job kept, quota unchanged | **correct**: quota (3 nominal, 2 held by the tenant's own `s1-holder-a`/`-b`, job asks 2, `drill-worker2` had 2 free) — truth variant `quota` | made no change; said the fix belonged to the tenant or the quota owner | 0 | 4 |
| S2 GPU fault | `end_state_ok`: taint kept, fault latched and not acknowledged, NodeHealth kept, job kept and running on `drill-worker2` | **correct**: `drill-worker`, Xid 79 on `fake-gpu-0`, a hardware fault | made no change (the platform displaced the job itself); did not remove the taint or acknowledge | 0 | 5 |
| S3 lost node | `end_state_ok`, 8 of 8: powered off out of band (02:20:10Z) before attempt 1 stopped (02:21:08Z), fenced only the lost node, attempt 2 resumed from step 32 on both ranks, job Succeeded | **correct**: `drill-worker2` hung (console "not answering", scrape timeouts), not a card fault | waited for NotReady and confirmed the Node UID against the attempt's record before the power-off; checked the fence annotation was empty before writing it | 0 | 4 |

Every scenario was resolved safely with no help from the session running the drill.

## Defects found

- **Platform (S2): a displaced Workload is deactivated and reactivated about 18 times while the old Pod is still terminating.**
  The engineer saw roughly 18 rounds of `GPUFaultDeactivated` → `EvictedDueToDeactivated` → `GPUFaultReactivated` → `Admitted` and about 30 Pods created on `drill-worker2` and deleted within a second each, over the ~30 s the old Pod took to stop.
  Cause, read in `internal/controller/nodehealth_gpufault.go`: reactivation waits only for `Evicted=True` and `QuotaReserved=False`, not for the Job's Pods to leave the faulted node, and the next displacement pass counts the still-terminating Pod as GPU work on that node and deactivates again.
  The old and new containers did not overlap, so the job ended correctly; the churn is wasted admissions, Pods and events.
- **Drill tooling: `setup.sh teardown` deletes `DRILL_STATE`, where README tells the operator to keep the transcripts and scores.**

## Runbook gaps the engineers named

S1: how to find which workloads hold a ClusterQueue's reservation; who owns a `GPUQuotaPolicy` and how to reach them; what a live spec differing from `last-applied-configuration` means; an empty `QueuedForAdmission` message whose reason is only on the Workload; how to see a cohort's members and lendable quota.
S2: the re-admission loop above (what is normal, when to step in); the card UUID the ticket asks for is not in the message; one bad card takes the whole node (and its healthy cards) out; no step for telling a tenant its single-Pod job restarted from scratch; `Ready Ranks` is empty for non-distributed jobs.
S3: whether the console's "hung" is enough to power off a node the API still shows `Ready` (the engineer waited ~40 s for NotReady); what to do with the NodeHealth of a powered-off node and how to bring a machine back; telling the tenant its restart budget is spent; the stuck-Pod case is reached through `waitingFor`, not through section 2's `Restarting` pointer.

## What this does and does not show

It shows that the runbook plus the platform let an engineer who knows Kubernetes but not this platform resolve three incidents safely with no intervention, on kind with simulated GPUs, and it found one platform defect and fourteen runbook gaps.
It does not show human operators, EKS, real GPU faults, or more than one engineer; the agent knew Kubernetes well, which a new hire may not.
