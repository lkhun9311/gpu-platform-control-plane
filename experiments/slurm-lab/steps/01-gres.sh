#!/usr/bin/env bash
# Step 1: a 2-GPU job lands only on a node with two GPUs free, and stays PENDING (Resources) when no node has two, even with two free in total.
source "$(dirname "$0")/lib.sh"

out 01-gres.txt
note "Holders: one GPU on c1 and one on c2, so only c3 has two free; four GPUs are free in total."
at slurmctld -u alice "sbatch -J hold-c1 -w c1 --gres=gpu:1 --wrap 'sleep 900'"
at slurmctld -u alice "sbatch -J hold-c2 -w c2 --gres=gpu:1 --wrap 'sleep 900'"
wait_until 30 "[ \$(squeue -h -t R -u alice | wc -l) -eq 2 ]"
at slurmctld "sinfo -N -O NodeList:6,StateLong:10,Gres:10,GresUsed:24"

note "A 2-GPU job with no node pin: the only node it fits is c3."
at slurmctld -u alice "sbatch -J two-gpu --gres=gpu:2 --wrap 'echo CUDA_VISIBLE_DEVICES=\$CUDA_VISIBLE_DEVICES; sleep 900'"
wait_until 30 "squeue -h -n two-gpu -t R | grep -q ."
at slurmctld "squeue -o '%.6i %.10j %.8u %.3t %.12b %N %R'"
at slurmctld "scontrol -d show job \$(squeue -h -n two-gpu -o %i) | grep -E 'JobState|NodeList=|GRES=|TresPerNode'"

note "Now two GPUs are free in total, one on c1 and one on c2, and no node has two."
at slurmctld "sinfo -N -O NodeList:6,StateLong:10,Gres:10,GresUsed:24"
at slurmctld -u alice "sbatch -J two-gpu-b --gres=gpu:2 --wrap 'sleep 60'"
wait_until 30 "squeue -h -n two-gpu-b -o %r | grep -q Resources"
at slurmctld "squeue -o '%.6i %.10j %.8u %.3t %.12b %N %R'"
at slurmctld "scontrol show job \$(squeue -h -n two-gpu-b -o %i) | grep -E 'JobState|Reason|TresPerNode'"

note "Freeing c1's holder gives c1 two free GPUs, and the pending job starts there without being resubmitted."
at slurmctld -u alice "scancel -n hold-c1"
wait_until 30 "squeue -h -n two-gpu-b -t R | grep -q ."
at slurmctld "squeue -o '%.6i %.10j %.8u %.3t %.12b %N %R'"

at slurmctld -u alice "scancel -u alice"
wait_until 30 "[ -z \"\$(squeue -h)\" ]"
at slurmctld "sacct -X -u alice -o JobID,JobName%10,State,AllocTRES%40,NodeList"
