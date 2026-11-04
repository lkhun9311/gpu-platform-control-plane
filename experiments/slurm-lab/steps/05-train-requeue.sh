#!/usr/bin/env bash
# Step 5: a two-node gloo DDP training job loses a node, Slurm requeues it, and the new attempt must resume from the shared checkpoint.
# Three jobs run: an uninterrupted reference, a requeue with CKPT_LOAD=full, and the same requeue with CKPT_LOAD=none as a mutation.
# score_requeue.py must pass the full case and fail the mutation; the step exits nonzero if either verdict is not the expected one.
source "$(dirname "$0")/lib.sh"
# lib.sh has changed to the lab directory, so a path relative to $0 no longer resolves; $LAB does.
source "$LAB/steps/train-lib.sh"

out 05a-train-reference.txt
note "Placement: slurmctld runs in its own container and is never a compute node; c1..c3 are the only slurmd containers."
host "docker compose ps --format '{{.Service}} {{.Name}} {{.State}}'"
at slurmctld "sinfo -N -o '%N %T %E'"
at c1 "/opt/torch/bin/python -c 'import torch, sys; print(torch.__version__, sys.version.split()[0])'"
note "train.py below its header hashes to $got, the pinned file of commit f7638229."
submit tr-ref full
trace 300 "! squeue -h -j $JOBID | grep -q ." "squeue -h -j $JOBID -o '%i %T %r %N'"
collect tr-ref
REF_LOGS=$EVID/05-tr-ref-logs

out 05b-train-requeue.txt
note "Case: CKPT_LOAD=full. The scorer must pass."
requeue_case tr-full full
full_rc=$?

out 05c-train-requeue-load-none.txt
note "Mutation: CKPT_LOAD=none, so the requeued attempt ignores the checkpoint and trains from step 0. The scorer must fail."
requeue_case tr-none none
none_rc=$?

none_out=$OUT
# Exit 1 alone is not the mutation caught: a scorer that crashed on missing logs, or a requeued attempt that never
# ran, exits 1 too. The control counts only when the scorer finished, and failed because both ranks restarted from
# zero and neither resumed.
none_caught=0
if ! grep -q '^Traceback' "$none_out" && grep -qE '^[0-9]+ passed, [1-9][0-9]* failed$' "$none_out" &&
	[ "$(grep -cE '^FAIL: attempt [1-9][0-9]* rank [01] did not restart from zero' "$none_out")" = 2 ] &&
	[ "$(grep -cE '^FAIL: attempt [1-9][0-9]* rank [01] has one resume record with from_step > 0' "$none_out")" = 2 ]; then
	none_caught=1
fi

out 05-verdict.txt
note "full case scorer exit $full_rc (expected 0); load-none mutation scorer exit $none_rc (expected 1), caught for the expected reason: $none_caught"
if [ "$full_rc" = 0 ] && [ "$none_rc" = 1 ] && [ "$none_caught" = 1 ]; then
	note "PASS: the resume was scored as a resume, and a restart from zero was caught"
	cat "$OUT"
	exit 0
fi
note "FAIL: at least one verdict was not the expected one"
cat "$OUT"
exit 1
