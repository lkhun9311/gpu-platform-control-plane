# Review r1, 2026-11-07: the distributed restart contract in the controller and webhook

The owner asked on 2026-11-07 for every piece of the 42dot track to be attacked with gpt-6-astra and its defects fixed.
This ledger covers area r1: `api/v1` (the restart fields), `internal/controller` (the attempt lifecycle, the stop barrier, fencing, the fault path's handoff) and `internal/webhook/v1` (the state-volume check).
gpt-6-astra (high) read `116092ef` read-only and without direction beyond the area; every finding was then checked against the code by Claude, and every fix and test is Claude's.
After the fixes, a bare `codex review --base origin/dev` (astra, high) read the branch's diff and wrote and ran its own probes; its three findings are the second table.

## The first read: eight findings

| # | finding (astra) | verdict (Claude) | change | pinned by |
|---|---|---|---|---|
| 1 | a rank never observed by the controller (controller away, node lost, Pod garbage-collected) is left out of fencing | **confirmed**: `discover` only lists Pods that exist | rank Pods carry `platform.lkhun9311.github.io/rank-stopped` from the Job template; the controller removes it only after recording the Pod's node and seeing the rank stopped | envtest "keeps a rank Pod it never saw…", "renders the rank Pods…" |
| 2 | late discovery records a replacement Node's UID as the old machine's | **confirmed** | a Node created after the rank's published binding is recorded as `replaced` and needs fencing; with no binding published yet the decision waits | envtest "does not take a Node registered after…", unit `TestAReplacedNodeIsPinnedToItsAttempt` |
| 3 | a Ready node with its Pods gone is taken as the ranks having stopped, with no termination reported | **confirmed** (an operator's force delete produces it; the design's step 3 already asked for a reported termination) | the same finalizer: a Pod leaves the API only once its kubelet reported it terminal, or its node is fenced | envtest "keeps a Pod force-deleted from a Ready node…" |
| 4 | a fence acknowledgement stays valid after the machine boots and runs a later attempt | **confirmed**; an existing test had pinned the reuse as intended | an entry is spent by the attempt that stopped on it (`status.attempts[].fencedBy`); later attempts need `name#N` or `name@id#N` | envtest "spends a fence entry…", unit `TestAFenceEntryIsSpentByTheAttemptThatStoppedOnIt` |
| 5 | Kueue eviction (preemption) bypasses the attempt and the barrier, though the API promises it | **confirmed** | trigger `Evicted` for an eviction that is not a deactivation | envtest "takes a Kueue eviction as Evicted…" |
| 6 | the fault path's handoff patch can land over an operator's deactivation | **confirmed**: plain `MergeFrom` after a cached read | the patch carries the Workload's resource version | `TestGPUFaultDoesNotHandOverAWorkloadAnOperatorDeactivatedMeanwhile` |
| 7 | a failed Job is classified `RankFailed` from a cached Workload that has not seen the handoff | **confirmed** (a race, classification only) | the handoff is read again uncached before `RankFailed` | envtest "reads the handoff past a cache…" |
| 8 | the webhook accepts an unbound claim, against the design's "bound" | **partly**: the code never checked binding, but requiring `Bound` would refuse every job on the WaitForFirstConsumer class this repository ships | refuses `Lost` and being-deleted claims, accepts `Pending`; the design is corrected | webhook rows "Pending…", "Lost", "being deleted" |

Deleting a restartable MLTrainingJob is held the same way (finding 1 of area r2 asked for it): the job's finalizer goes only after every rank Pod is known stopped, so a runner that deletes files once the objects are gone does not delete them under a live writer.

## The bare review of the fixes: three findings, all confirmed

| finding | change | pinned by |
|---|---|---|
| P1: deleting the job while the stop barrier deletes its Job in the foreground deadlocks: the Job waits for its Pods and the Pods for the controller, which returned before releasing them | the deletion path releases stopped ranks first, whatever the Job is doing | envtest "releases the ranks of a deleted job whose Job the stop barrier is already deleting…" |
| P2: a Workload an operator deactivated after an earlier preemption, still showing `Evicted/Preempted`, restarts the job; Kueue also writes `DeactivatedDueTo<cause>` | an inactive Workload is never an eviction trigger, and the deactivation reason is matched by prefix, as Kueue v0.20.4 matches it | the same eviction spec, two more rows |
| P2: a Pod with no published binding was dated by its creation, so an autoscaler's node for a Pending rank read as a replacement for good | no binding time, no decision; a later pass decides | envtest "decides a node's identity only once the rank's binding is published" |

## What ran

- `go test` over every package but e2e with envtest 1.37.0: green; the controller suite ran 191 of 191 specs.
- `make lint`: 0 issues.
- Mutations, each on the committed fix, each restored and the tree checked clean: 15 for the first table and 4 for the second, all red.
  One mutation of the first set (dropping the "node recorded" condition on release) stayed green until a unit test reached it; `discover` always records before it releases, so only `TestARankIsReleasedOnlyOnceItsNodeIsRecorded` can see the rule.
  One mutation first read red because it did not compile; it was rewritten to keep the build and then went red on two specs.
- The Job controller copying a template's finalizers onto its Pods, the kubelet reporting a deleted Pod `Failed` while the finalizer holds it, and a foreground-deleted Job waiting for it were each checked on a throwaway kind v1.31 cluster before the design relied on them.
- `hack/restart-lifecycle-kind.sh` runs `a` and `c` at commit `f9939cc6` (before the second table's fixes): run `a` (reference, no-rng-control, dcgm-1, terminate-wait-1) ACCEPTED all four through the kind shim, with the unmodified EKS scorer voiding them for gloo on CPU as in every earlier rehearsal; run `c` ACCEPTED reference and rank-kill-1 and recorded rank-kill-2 NOTRUN behind the rehearsal's own stuck finalizer, as it is meant to; `check_lifecycle.py` and the outcome check found 0 FAIL each (`hack/restart-lifecycle-kind-20261106T233833Z/README.md`).

## What it changes for published results

None of the published runs exercised these paths: no controller restart during a fault, no force delete, no preemption, no deletion during a barrier.
A future run's stop can be up to one stop poll (2 s) longer, because a rank Pod now leaves the API only after the controller sees its kubelet's terminal report.
