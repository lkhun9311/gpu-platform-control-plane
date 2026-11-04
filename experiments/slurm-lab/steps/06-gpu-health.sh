#!/usr/bin/env bash
# Step 6: the GPU health check (etc/gpuhc.py) drains a node whose fault signal shows an Xid or a double-bit ECC count,
# or cannot be read, and never returns it; the operator does.
# The signal is a file per node in dcgm-exporter's shape; writing it is the fault, because the lab has no GPUs.
source "$(dirname "$0")/lib.sh"

Q="squeue -o '%.6i %.12j %.8u %.3t %.10M %.12b %N %R'"

# signal NODE XID0 DBE0 XID1 DBE1 rewrites the node's whole signal, as one exporter scrape would replace the last.
signal() {
	local n=$1
	at "$n" "printf '%s\n' \
'DCGM_FI_DEV_XID_ERRORS{gpu=\"0\",UUID=\"GPU-lab-$n-0\"} $2' \
'DCGM_FI_DEV_ECC_DBE_VOL_TOTAL{gpu=\"0\",UUID=\"GPU-lab-$n-0\"} $3' \
'DCGM_FI_DEV_XID_ERRORS{gpu=\"1\",UUID=\"GPU-lab-$n-1\"} $4' \
'DCGM_FI_DEV_ECC_DBE_VOL_TOTAL{gpu=\"1\",UUID=\"GPU-lab-$n-1\"} $5' >/var/lib/labgpu/metrics.prom.new && mv /var/lib/labgpu/metrics.prom.new /var/lib/labgpu/metrics.prom && cat /var/lib/labgpu/metrics.prom"
}

out 06a-gpu-health-drain.txt
at slurmctld "scontrol show config | grep -i health"
at c2 "sha256sum /etc/slurm/gpuhc.py"
at slurmctld "sinfo -N -o '%N %T %E'"
note "A GPU job runs on c2 when one of c2's cards faults; which card Slurm gave it is in its output."
at slurmctld -u bob "sbatch -J gpu-on-c2 -w c2 --gres=gpu:1 --requeue --wrap 'echo start \$(date -u +%T) on \$(hostname) gpus=\$CUDA_VISIBLE_DEVICES restart=\${SLURM_RESTART_COUNT:-0}; sleep 60; echo end \$(date -u +%T)'"
wait_until 30 "squeue -h -n gpu-on-c2 -t R | grep -q ."
at slurmctld "$Q"
note "Fault: Xid 79 (fallen off the bus) on c2's card 1; the drain is per node, whichever card the job holds."
signal c2 0 0 79 0
trace 60 "sinfo -h -n c2 -o %T | grep -q drain" "sinfo -h -n c2 -o '%T|%E'; squeue -h -n gpu-on-c2 -o '%i %T %N'"
at slurmctld "scontrol show node c2 | grep -E 'State=|Reason='"
at c2 "cat /var/log/slurm/gpuhc.log"
note "New work: an unpinned 2-GPU job goes to another node, and one that names c2 waits."
at slurmctld -u bob "sbatch -J new-anywhere --gres=gpu:2 --wrap 'sleep 20'"
at slurmctld -u bob "sbatch -J new-on-c2 -w c2 --gres=gpu:1 --wrap 'echo ran on \$(hostname); sleep 5'"
wait_until 30 "squeue -h -n new-anywhere -t R | grep -q ."
at slurmctld "$Q"
note "The job already on c2 is not stopped by the drain; wait for it to end by itself."
trace 120 "! squeue -h -n gpu-on-c2 | grep -q ." "sinfo -h -n c2 -o '%T'; squeue -h -n gpu-on-c2 -o '%i %T %N'"
at slurmctld "sacct -X -n -P -o JobID,JobName,State,ExitCode,Restarts,Start,End,NodeList | grep -E '\|gpu-on-c2\|'"
at c2 "cat /home/bob/slurm-\$(sacct -X -n -P -o JobID,JobName | grep '|gpu-on-c2\$' | cut -d'|' -f1).out"
note "The signal reads clean again. With the trace file set, every check logs its verdict, so the transcript shows the check ran on the clean signal and left the node drained."
at c2 "touch /var/lib/labgpu/trace"
signal c2 0 0 0 0
host "sleep 20"
at c2 "rm /var/lib/labgpu/trace; tail -6 /var/log/slurm/gpuhc.log"
at slurmctld "scontrol show node c2 | grep -E 'State=|Reason='"
at slurmctld "$Q"
note "The operator returns the node."
at slurmctld "scontrol update nodename=c2 state=resume"
wait_until 60 "sacct -X -n -P -o JobName,State | grep -q '^new-on-c2|COMPLETED'"
at slurmctld "sinfo -N -o '%N %T %E'"
at slurmctld "sacct -X -n -P -o JobID,JobName,State,Start,End,NodeList | grep -E '\|new-'"
at slurmctld "scancel -u bob"
wait_until 30 "[ -z \"\$(squeue -h)\" ]"

out 06b-gpu-health-requeue.txt
note "With the requeue policy on c3, a fault also requeues c3's running jobs, as the platform's --gpu-fault-evict-workloads deactivates Kueue Workloads."
at c3 "echo requeue >/var/lib/labgpu/policy; cat /var/lib/labgpu/policy"
note "c1 and c2 are held briefly so both test jobs land on c3; then the holders end."
at slurmctld -u bob "sbatch -J hold-1 -w c1 --gres=gpu:2 --wrap 'sleep 900'"
at slurmctld -u bob "sbatch -J hold-2 -w c2 --gres=gpu:2 --wrap 'sleep 900'"
wait_until 30 "[ \$(squeue -h -u bob -t R | wc -l) -eq 2 ]"
at slurmctld -u alice "sbatch -J hc-rq-yes --requeue --open-mode=append --gres=gpu:1 --wrap 'echo start \$(date -u +%T) on \$(hostname) gpus=\$CUDA_VISIBLE_DEVICES restart=\${SLURM_RESTART_COUNT:-0}; sleep 900'"
at slurmctld -u alice "sbatch -J hc-rq-no --no-requeue --gres=gpu:1 --wrap 'sleep 900'"
wait_until 30 "[ \$(squeue -h -u alice -t R | wc -l) -eq 2 ]"
at slurmctld -u bob "scancel -n hold-1; scancel -n hold-2"
wait_until 30 "[ -z \"\$(squeue -h -u bob)\" ]"
at slurmctld "$Q"
note "Fault: a double-bit ECC count of 2 on c3's card 0."
signal c3 0 2 0 0
trace 300 "squeue -h -n hc-rq-yes -t R -o %N | grep -qv c3" \
	"sinfo -h -n c3 -o '%T|%E'; squeue -h -u alice -o '%i %j %T %r %N'; scontrol show job \$(squeue -h -n hc-rq-yes -o %i) | grep -oE 'Restarts=[0-9]+'"
at c3 "cat /var/log/slurm/gpuhc.log"
at slurmctld "scontrol show job \$(squeue -h -n hc-rq-yes -o %i) | grep -E 'JobState|Requeue|Restarts|SubmitTime|EligibleTime|StartTime|NodeList='"
at slurmctld "$Q"
at slurmctld "sacct -D -n -u alice -S now-15minutes -o JobID,JobName,State,ExitCode,Restarts,Start,End,NodeList | grep -E 'hc-rq'"
id=$(docker compose exec -T slurmctld squeue -h -n hc-rq-yes -o %i)
node=$(docker compose exec -T slurmctld squeue -h -n hc-rq-yes -o %N)
note "The requeued job's output on ${node:-none}, and its first run's on c3; nothing is shared between their home directories."
at "${node:-c1}" "cat /home/alice/slurm-${id:-0}.out"
at c3 "cat /home/alice/slurm-${id:-0}.out"
at c3 "echo >/var/lib/labgpu/policy; rm -f /var/lib/labgpu/requeued"
signal c3 0 0 0 0
at slurmctld "scancel -u alice"
wait_until 30 "[ -z \"\$(squeue -h)\" ]"
at slurmctld "scontrol update nodename=c3 state=resume"
wait_until 30 "sinfo -h -n c3 -o %T | grep -qx idle"
at slurmctld "sinfo -N -o '%N %T %E'"

out 06c-gpu-health-unreadable.txt
note "The signal disappears, as it would if the exporter stopped writing it: the check cannot judge the cards and drains."
at c1 "rm /var/lib/labgpu/metrics.prom; ls /var/lib/labgpu"
trace 60 "sinfo -h -n c1 -o %T | grep -q drain" "sinfo -h -n c1 -o '%T|%E'"
at slurmctld "scontrol show node c1 | grep -E 'State=|Reason='"
at c1 "tail -2 /var/log/slurm/gpuhc.log"
signal c1 0 0 0 0
at slurmctld "scontrol update nodename=c1 state=resume"
wait_until 30 "sinfo -h -n c1 -o %T | grep -qx idle"
at slurmctld "sinfo -N -o '%N %T %E'"
