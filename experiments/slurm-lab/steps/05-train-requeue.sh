#!/usr/bin/env bash
# Step 5: a two-node gloo DDP training job loses a node, Slurm requeues it, and the new attempt must resume from the shared checkpoint.
# Three jobs run: an uninterrupted reference, a requeue with CKPT_LOAD=full, and the same requeue with CKPT_LOAD=none as a mutation.
# score_requeue.py must pass the full case and fail the mutation; the step exits nonzero if either verdict is not the expected one.
source "$(dirname "$0")/lib.sh"

STEPS=${STEPS:-40}
# A checkpoint per step and one second between steps, so the kill lands mid-training with checkpoints already published.
STEP_SLEEP=${STEP_SLEEP:-1}
KILL_AFTER=${KILL_AFTER:-12}
# The sha256 of experiments/distributed-restart/train.py at f7638229ff3c9f96a16ac483f60aad5724ca73ac, the file train.py copies below its four header lines.
TRAIN_SHA=abbfa46593dbd7b690abaf40ee6615c40df38b1a31c946bf24aa3096d9066abd

got=$(tail -n +5 "$LAB/train.py" | sha256sum | cut -d' ' -f1)
if [ "$got" != "$TRAIN_SHA" ]; then
	echo "train.py below its header hashes to $got, not the pinned $TRAIN_SHA; refusing to run a trainer that is not the pinned one" >&2
	exit 1
fi
NONCE=$(date -u +%H%M%S)

# submit NAME LOAD submits train.sbatch as alice and sets JOBID and CKPT_ID.
submit() {
	CKPT_ID=$1-$NONCE
	# The variables ride on sbatch's default --export=ALL rather than --export=ALL,VAR=…, because a job submitted the second way made slurmd on c1 call _get_user_env and exit with "fatal: clone: Operation not permitted".
	at slurmctld -u alice "CKPT_JOB_ID=$CKPT_ID CKPT_LOAD=$2 CKPT_STEPS=$STEPS CKPT_STEP_SLEEP=$STEP_SLEEP sbatch -J $1 /opt/lab/train.sbatch"
	JOBID=$(jobid_of "$1")
	note "job $JOBID ($1) writes /ckpt/$CKPT_ID"
}

# collect NAME copies the job's records and Slurm's final view of it into the evidence directory.
collect() {
	at slurmctld "scontrol show job $JOBID"
	at slurmctld "sacct -D -j $JOBID -o JobID%14,JobName%10,State,ExitCode,Restarts,Start,End,NodeList"
	docker compose exec -T slurmctld scontrol show job "$JOBID" >"$EVID/05-$1-scontrol.txt" 2>&1
	rm -rf "${EVID:?}/05-$1-logs"
	docker compose cp "slurmctld:/ckpt/$CKPT_ID/logs" "$EVID/05-$1-logs"
	host "ls -l $EVID/05-$1-logs"
	at slurmctld "cat /ckpt/slurm-$1-$JOBID.out"
	at slurmctld "cat /ckpt/$CKPT_ID/logs/*.host"
	at slurmctld "cat /ckpt/$CKPT_ID/LATEST; echo; ls /ckpt/$CKPT_ID"
}

# rank_procs NODE lists train.py processes; awk's own command line has train.py only inside its program text, never as its third field.
rank_procs() {
	at "$1" "ps -eo pid,ppid,args | awk '\$4 == \"/opt/lab/train.py\"' | grep . || echo no train.py process on $1"
}

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

# requeue_case NAME LOAD runs one requeue case and scores it, returning the scorer's exit status.
requeue_case() {
	local name=$1 load=$2 victim batch nodes rc
	submit "$name" "$load"
	note "Wait until rank 0 has recorded $KILL_AFTER published checkpoints, so the kill lands mid-training."
	trace 300 "[ \$(grep -c '\"event\": \"checkpoint\"' /ckpt/$CKPT_ID/logs/attempt-0-rank-0.jsonl) -ge $KILL_AFTER ]" \
		"squeue -h -j $JOBID -o '%i %T %r %N'; cat /ckpt/$CKPT_ID/LATEST 2>&1"
	nodes=$(docker compose exec -T slurmctld bash -c "scontrol show hostnames \$(squeue -h -j $JOBID -o %N)" | tr '\n' ' ')
	batch=$(docker compose exec -T slurmctld bash -c "scontrol show job $JOBID | grep -oE 'BatchHost=[^ ]+' | cut -d= -f2")
	victim=""
	for n in $nodes; do [ "$n" != "$batch" ] && victim=$n; done
	# docker compose kill with no service kills every container, the controller included.
	if [ -z "$victim" ]; then
		note "REFUSED: no node other than the batch host [$batch] in [$nodes]; nothing was killed"
		return 2
	fi
	note "job $JOBID runs on: $nodes; batch host and rank 0 on $batch; killing $victim, which runs rank 1 and not the controller"
	at slurmctld "scontrol show job $JOBID | grep -E 'JobState|Restarts|NodeList=|BatchHost'"
	note "Positive control: the rank on the node about to be killed is a running train.py."
	rank_procs "$victim"
	host "docker compose kill $victim"
	host "docker inspect -f '{{.State.Status}} exit={{.State.ExitCode}} restarts={{.RestartCount}}' slurmlab-$victim-1"
	note "Wait for Slurm to notice, requeue the job and start it again."
	trace 400 "scontrol show job $JOBID | grep -q 'Restarts=[1-9]' && squeue -h -j $JOBID -t R | grep -q ." \
		"sinfo -h -n $victim -o '%T %E'; squeue -h -j $JOBID -o '%i %T %r %N'; scontrol show job $JOBID | grep -oE 'Restarts=[0-9]+'"
	at slurmctld "grep -hE 'JobId=$JOBID[^0-9]|$victim' /var/log/slurm/slurmctld.log | grep -v debug | tail -12"
	at slurmctld "sinfo -N -o '%N %T %E'"
	at slurmctld "scontrol show job $JOBID | grep -E 'JobState|Restarts|NodeList=|BatchHost'"
	note "Wait for the requeued attempt to finish."
	trace 300 "! squeue -h -j $JOBID | grep -q ." "squeue -h -j $JOBID -o '%i %T %r %N'; cat /ckpt/$CKPT_ID/LATEST 2>&1"
	collect "$name"
	note "Return the killed node: start its container; ReturnToService=1 lets a node DOWN for not responding return when its slurmd registers."
	at slurmctld "sinfo -h -n $victim -o '%N %T %E'"
	host "docker compose start $victim"
	wait_until 90 "sinfo -h -n $victim -o %T | grep -qx idle"
	at slurmctld "sinfo -N -o '%N %T %E'"
	note "Score: reference against this case."
	{
		echo
		echo "host\$ python3 score_requeue.py $REF_LOGS $EVID/05-$name-logs $EVID/05-$name-scontrol.txt $STEPS"
	} >>"$OUT"
	python3 "$LAB/score_requeue.py" "$REF_LOGS" "$EVID/05-$name-logs" "$EVID/05-$name-scontrol.txt" "$STEPS" >>"$OUT" 2>&1
	rc=$?
	echo "# exit $rc" >>"$OUT"
	return $rc
}

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
