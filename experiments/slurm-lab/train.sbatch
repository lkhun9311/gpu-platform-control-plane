#!/bin/bash
# One rank of train.py per node, started by one srun, so losing either node takes the whole step down as a distributed launch would.
# --requeue lets Slurm start the job again after a node failure, and --open-mode=append keeps the first attempt's output when it does.
#SBATCH -N 2
#SBATCH --ntasks-per-node=1
#SBATCH --requeue
#SBATCH --open-mode=append
#SBATCH --output=/ckpt/slurm-%x-%j.out
# The submitter sets CKPT_JOB_ID, CKPT_LOAD, CKPT_STEPS and CKPT_STEP_SLEEP in its own environment, which sbatch exports by default.
set -euo pipefail

# Rank 0 is the first node of the allocation, and the rendezvous runs there.
MASTER_ADDR=$(scontrol show hostnames "$SLURM_JOB_NODELIST" | head -1)
export MASTER_ADDR
export MASTER_PORT=29500
export WORLD_SIZE=$SLURM_NTASKS
# Slurm counts the times it requeued this job, which is the attempt number the trainer names its checkpoint directories by.
# The variable is absent on the first start, so it is defaulted rather than assumed.
export TRAINING_ATTEMPT=${SLURM_RESTART_COUNT:-0}
export CKPT_DIR=/ckpt
export CKPT_RUN_ID=$SLURM_JOB_ID
# A peer whose node died must not hold this rank in a collective for torch's default 30 minutes.
export CKPT_COLLECTIVE_TIMEOUT=${CKPT_COLLECTIVE_TIMEOUT:-120}
# The containers have no network but the compose bridge on eth0, and naming it stops gloo from guessing.
export GLOO_SOCKET_IFNAME=eth0

LOGS=/ckpt/$CKPT_JOB_ID/logs
mkdir -p "$LOGS"
echo "attempt=$TRAINING_ATTEMPT job=$SLURM_JOB_ID nodes=$SLURM_JOB_NODELIST master=$MASTER_ADDR batch_host=$(hostname) load=$CKPT_LOAD at=$(date -u +%FT%TZ)"

# Each rank writes its own records to the shared volume, because a dead node's share of srun's forwarded output is lost with it.
# python is a child of bash, not exec'd, so it is never a container's PID 1, and the placement line is written before it starts.
srun --kill-on-bad-exit=1 bash -c '
	export RANK=$SLURM_PROCID
	base=$0/attempt-$TRAINING_ATTEMPT-rank-$RANK
	echo "rank=$RANK host=$(hostname) attempt=$TRAINING_ATTEMPT at=$(date -u +%FT%TZ)" >>"$base.host"
	/opt/torch/bin/python /opt/lab/train.py >>"$base.jsonl" 2>>"$base.err"
' "$LOGS"
