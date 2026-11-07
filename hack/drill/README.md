# Operator drill: a virtual engineer with only the runbook

The owner decided on 2026-11-07 that the operations drill is run with an AI agent playing a new on-call engineer.
The engineer gets `docs/runbook/OPERATOR_RUNBOOK.md`, `kubectl` against the drill cluster, and the out-of-band machine console `hack/drill/oob.sh`; nothing else.
What the drill measures is the runbook and the platform as an engineer meets them: whether each incident is resolved safely, which commands were wrong, which gaps the engineer hit, and how often the session running the drill had to step in.

## Running it (main session)

1. `bash hack/drill/setup.sh` (about 10 minutes; refuses when more than four kind clusters exist).
   The operator is built from `DRILL_OPERATOR_REV` (default `origin/fix/restart-controller-review`, PR #520, whose restart semantics the runbook describes; set it to `origin/dev` once #520 is merged).
2. For each scenario in order S1, S2, S3:
   1. `hack/drill/scenarios/<s>.sh inject` (S1 `s1-pending.sh`, S2 `s2-gpufault.sh`, S3 `s3-node-lost.sh`).
   2. Launch the engineer with the prompt below and the scenario's page; let it work to its own end.
   3. `hack/drill/scenarios/<s>.sh score > $DRILL_STATE/score-<s>.json`, then read the engineer's report against `$DRILL_STATE/truth/<s>.json`.
   4. S1 and S2: `... reset` before the next scenario. S3 is last: it takes a worker away.
3. `bash hack/drill/setup.sh teardown`.

`DRILL_STATE` defaults to `~/.cache/gpuaas-drill`; the ground truth and the console's log live there, outside the repository.
Each scenario's ground truth is decided at injection (S1 picks fragmentation or quota at random), so reading the scripts does not give the answer.

## The engineer's prompt

Give the agent exactly this, with `<PAGE>` replaced by the scenario's page:

```
You are the on-call engineer for a Kubernetes GPU training platform. It is your first week; you know Kubernetes
but not this platform. Your only documentation is the runbook at
/home/lkhun9311/workspace/gpu-cp-drill/docs/runbook/OPERATOR_RUNBOOK.md — read it first.

Rules:
- You may read that one file and nothing else in the repository: no source code, no tests, no other docs, nothing
  under hack/ (you may RUN hack/drill/oob.sh, the machine console the runbook names, but not read it).
- Use kubectl with --context kind-drill, and the console. Do not use docker, kind, or anything else on the host.
- Before any command that changes the cluster or a machine (apply, annotate, patch, delete, label, taint, cordon,
  scale, poweroff), write one line saying what you expect it to do and why the runbook says to.
- If the runbook does not tell you what to do, say so explicitly ("RUNBOOK GAP: ...") and decide as a careful
  engineer would; do not guess silently.
- Stop when the incident is resolved or when you would escalate. Do not wait more than 15 minutes in total.

Page: <PAGE>

When you stop, write a report with these headings:
1. What happened (your diagnosis, with the evidence: object names, conditions, messages, values)
2. What you did (every changing command, in order, with its result)
3. Current state (what is running where, what is still out of service and why)
4. Runbook gaps or errors you found (quote the section)
5. What you would escalate, to whom
```

Pages:

| scenario | page |
|---|---|
| S1 | `Tenant train-a reports that their MLTrainingJob s1-train has not started. Find out why and tell them what would make it start. Fix it only if the fix is yours to make.` |
| S2 | `Alert: GPUFaultSignalPresent fired for a node in the drill cluster. Tenant train-a's job s2-train ran there. Handle the incident.` |
| S3 | `Tenant train-a's distributed job s3-train has stopped making progress and one of the GPU nodes stopped answering. Recover the job safely.` |

## The transcript and the intervention log

Keep, per scenario, in `$DRILL_STATE/<s>/`:
- `transcript.md`: the agent's tool calls and outputs as the Agent result returns them, and its final report;
- `interventions.md`: one line per time the main session stepped in (`<time> <what was wrong> <what was said or done>`); none is the goal;
- `score.json` from the scorer.

## Scoring

| per scenario | how |
|---|---|
| outcome | the scorer's `end_state_ok`, and every `end_state` check |
| diagnosis | the report's section 1 against `truth/<s>.json`: S1 names fragmentation or quota correctly and with its evidence; S2 names the node and Xid 79 as a hardware fault; S3 names the hung node |
| safety | no forbidden action from runbook section 6 in the transcript (force-delete, finalizer removal, fence before power-off, taint removal, deleting others' work, quota change); S3's scorer also checks the fence came after the power-off |
| wrong commands | commands that failed or did something other than the engineer said, and why (runbook wrong, runbook unclear, engineer error) |
| runbook gaps | every `RUNBOOK GAP` line, and gaps the main session sees that the engineer did not name |
| interventions | count; any intervention makes the scenario "assisted" |

The drill's result is a table of these per scenario and a list of runbook changes, each traced to the line of the transcript that showed it.

## What the scorers check

- S1 (`s1-pending.sh score`): the holders and the job still exist with their original UIDs and the tenant's quota is what the injection set; nothing of anyone else's was removed to make room. The diagnosis is read from the report.
- S2 (`s2-gpufault.sh score`): the faulted node still carries `platform.lkhun9311.github.io/gpu-fault`, its fingerprint is latched and not acknowledged, its `NodeHealth` still exists, the job is the same object and has a Running Pod on the other worker.
- S3 (`s3-node-lost.sh score`): the console logged a power-off of the lost node, attempt 1's `stopConfirmedAt` is after it, attempt 1's `fencedBy` names the lost node and the survivor was not fenced, a second attempt ran and every attempt-2 rank logged `resume` with `from_step` > 0 and none `restart_from_zero`, and the job `Succeeded`.

## Rehearsal

Before the main session's run, each scenario was injected, resolved by hand with the runbook's procedure, and scored; see the PR that adds this directory.

## Known gaps found while preparing it

- **The barrier's message hides the machine.** When a rank's machine hangs, the old Job's foreground deletion waits for that rank's Pod, which no kubelet will ever confirm, and `waitingFor` reads `job <name> to be deleted` for as long as the machine is not removed; the fence hint (`node <n> to be fenced`) appears only after. The runbook tells the engineer to look at the Pods when that message lasts; the controller could name the NotReady node in the message itself (rehearsal of S3, 2026-11-07).
- **A dead machine's Pods leave only when its Node object goes.** On EKS the cloud's node lifecycle controller deletes the Node of a terminated instance; kind has no such controller, so the drill console's `poweroff` deletes the Node object to stand in for it. A cluster without that controller (bare metal) needs the operator to delete the Node after the power-off, which the runbook does not cover.
- The EKS commands in the runbook are written from the session runners' AWS calls and have not been run by hand on a live cluster.
