#!/usr/bin/env bash
# Step 7: the same two-node training job as step 5, but the node killed is the batch host, which runs the batch script,
# rank 0 and the rendezvous; step 5 only ever killed the node running rank 1.
# The job must be requeued and its next attempt must resume from the shared checkpoint, scored by score_requeue.py.
# Step 5's load-none mutation is what shows the scorer fails a restart from zero; it is not repeated here.
source "$(dirname "$0")/lib.sh"
PREFIX=07
source "$(dirname "$0")/train-lib.sh"

out 07a-train-reference.txt
host "docker compose ps --format '{{.Service}} {{.Name}} {{.State}}'"
at slurmctld "sinfo -N -o '%N %T %E'"
note "train.py below its header hashes to $got, the pinned file of commit f7638229."
submit bh-ref full
trace 300 "! squeue -h -j $JOBID | grep -q ." "squeue -h -j $JOBID -o '%i %T %r %N'"
collect bh-ref
REF_LOGS=$EVID/07-bh-ref-logs

out 07b-batch-host-loss.txt
note "Case: CKPT_LOAD=full, the batch host killed. The scorer must pass."
requeue_case bh-full full batch
rc=$?

out 07-verdict.txt
note "batch-host case scorer exit $rc (expected 0)"
if [ "$rc" = 0 ]; then
	note "PASS: losing the batch host was requeued and resumed from the checkpoint"
	cat "$OUT"
	exit 0
fi
note "FAIL: the batch-host case was not scored as a resume"
cat "$OUT"
exit 1
