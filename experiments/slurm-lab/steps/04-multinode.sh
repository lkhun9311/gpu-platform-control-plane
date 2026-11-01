#!/usr/bin/env bash
# Step 4: a two-node job loses one node; what happens to the whole job under the default, --requeue, and --no-kill.
source "$(dirname "$0")/lib.sh"

Q="squeue -o '%.6i %.10j %.8u %.3t %.10M %.5D %.12b %N %R'"
# Each rank prints where it runs and then sleeps; the step is one srun over both nodes, as a distributed training launch would be.
WRAP="srun bash -c 'echo rank \\\$SLURM_PROCID on \\\$(hostname) restart=\\\${SLURM_RESTART_COUNT:-0} at \\\$(date -u +%T); sleep 900'"

# kill_one NAME stops the container of the job's node that is NOT its batch host, so the batch script survives and can be observed.
kill_one() {
	local name=$1 id nodes batch victim
	id=$(docker compose exec -T slurmctld squeue -h -n "$name" -o %i)
	nodes=$(docker compose exec -T slurmctld bash -c "scontrol show hostnames \$(squeue -h -j $id -o %N)" | tr '\n' ' ')
	batch=$(docker compose exec -T slurmctld bash -c "scontrol show job $id | grep -oE 'BatchHost=[^ ]+' | cut -d= -f2")
	for n in $nodes; do [ "$n" != "$batch" ] && victim=$n; done
	note "job $id ($name) runs on: $nodes; batch host $batch; stopping $victim"
	VICTIM=$victim
	JOBID=$id
	BATCH=$batch
	note "Positive control: the same probe used after the failure, run on the batch host while its rank is alive, must list the rank's sleep."
	probe_rank "$batch"
	host "docker compose stop -t 0 $victim"
}

# probe_rank NODE lists processes named exactly sleep whose command line is "sleep 900", which is what each rank runs.
# pgrep -x matches the process name, so the probe's own bash wrapper, whose name is bash, cannot match itself.
probe_rank() {
	at "$1" "pgrep -ax sleep | grep -E '^[0-9]+ sleep 900\$' || echo no sleep 900 process on $1"
}

for variant in default requeue nokill; do
	# JobRequeue=1 makes requeue the cluster default, so the two variants that must not requeue say --no-requeue.
	case $variant in
	default) flags="--no-requeue" ;;
	requeue) flags="--requeue" ;;
	nokill) flags="--no-kill --no-requeue" ;;
	esac
	out "04-multinode-$variant.txt"
	note "Variant $variant: a two-node job with flags [$flags]; one of its two nodes is stopped while it runs."
	at slurmctld -u alice "sbatch -J mn-$variant -N 2 --ntasks-per-node=1 --gres=gpu:1 --open-mode=append $flags --wrap \"$WRAP\""
	wait_until 30 "squeue -h -n mn-$variant -t R | grep -q ."
	sleep 2
	at slurmctld "$Q"
	kill_one "mn-$variant"
	# The node list is expanded first, because squeue prints c[1-2] and a grep for c2 would never match it.
	trace 200 "! scontrol show hostnames \$(squeue -h -j $JOBID -t R -o %N) | grep -qx $VICTIM" \
		"sinfo -h -n $VICTIM -o '%T %E'; squeue -h -j $JOBID -o '%i %T %r %N'; sacct -n -j $JOBID -o JobID%12,State,NodeList | grep -v batch"
	at slurmctld "$Q"
	at slurmctld "sacct -D -j $JOBID -o JobID%14,JobName%10,State,ExitCode,Start,End,NodeList"
	at slurmctld "scontrol show job $JOBID | grep -E 'JobState|Requeue|Restarts|NodeList=|BatchHost|EligibleTime'"
	at slurmctld "grep -hE 'JobId=$JOBID[^0-9]|$VICTIM' /var/log/slurm/slurmctld.log | grep -v debug | tail -8"
	probe_rank "$BATCH"
	if [ "$variant" = requeue ]; then
		note "Wait for the requeued job to start again on the nodes that are left."
		trace 200 "squeue -h -j $JOBID -t R | grep -q ." "squeue -h -j $JOBID -o '%i %T %r %N'"
		at slurmctld "$Q"
		at slurmctld "scontrol show job $JOBID | grep -E 'JobState|Restarts|NodeList=|BatchHost'"
	fi
	if [ "$variant" = nokill ]; then
		note "With --no-kill the allocation shrinks to the surviving node; the step that spanned both nodes is examined."
		at slurmctld "scontrol show job $JOBID | grep -E 'JobState|NumNodes|NodeList='"
		at slurmctld "sacct -j $JOBID -o JobID%14,State,ExitCode,NodeList"
	fi
	host "docker compose start $VICTIM"
	wait_until 60 "sinfo -h -n $VICTIM -o %T | grep -qE 'idle|mixed|alloc'"
	at slurmctld "sinfo -N -o '%N %T %E'"
	for n in c1 c2 c3; do at "$n" "cat /home/alice/slurm-$JOBID.out 2>/dev/null || echo no output file on $n"; done
	at slurmctld "scancel -u alice"
	wait_until 30 "[ -z \"\$(squeue -h)\" ]"
done
