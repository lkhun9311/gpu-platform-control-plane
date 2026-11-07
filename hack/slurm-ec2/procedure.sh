#!/usr/bin/env bash
# The checks of the Slurm on EC2 session, B1 to B4, run as root on head once both workers are idle.
# docs/superpowers/specs/2026-11-07-slurm-ec2-session-design.md registers them; this file records raw observations
# under /shared/evidence and decides nothing: hack/slurm-ec2/score.py reads them on the laptop.
# Inputs: T0 and ROLE=head, from instance.sh's environment.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
# shellcheck source=hack/slurm-ec2/common.sh
. hack/slurm-ec2/common.sh
: "${T0:?}"
CHECKS_END=$(( T0 + CHECKS_END_S ))
BIN=$SHARED/bin
PY=$SHARED/venv/bin/python
# Only the local rehearsal trains on the CPU; it has no GPU behind /dev/nvidia0.
TRAIN_DEVICE=cuda
[ "${SLURMEC2_REHEARSAL:-0}" = 1 ] && TRAIN_DEVICE=cpu

mkdir -p "$BIN" && cp hack/slurm-ec2/probe_cuda.py hack/slurm-ec2/alloc.py hack/slurm-ec2/train_gpu.py "$BIN/" && chmod 755 "$BIN"/*

as_tenant() { runuser -u "$TENANT" -- "$@"; }
now() { date +%s.%N | cut -c1-14; }
notrun() { mkdir -p "$EVID/$1" && echo "$2" >"$EVID/$1/NOTRUN"; log "$1 NOTRUN: $2"; }

# job_done ID END: waits until the job has left the queue, or END; returns 1 on END.
job_done() {
  local id=$1 end=$2
  until_true "$end" 2 bash -c "[ -z \"\$(squeue -h -j $id -o %i)\" ]"
}

# root_on NODE FILE CMD...: runs CMD as root on NODE through Slurm and writes its output to FILE.
root_on() {
  local node=$1 file=$2
  shift 2
  timeout 120 srun -w "$node" -N1 -n1 --mem=100M -t 2 "$@" >"$file" 2>&1
  # The status beside the output, so the scorer can tell a failed instrument from a reading.
  echo $? >"$file.rc"
}

# --------------------------------------------------------------- configuration as it is, before any check
C=$EVID/config
mkdir -p "$C"
scontrol show config >"$C/scontrol-config.txt" 2>&1
sinfo -N -l >"$C/sinfo.txt" 2>&1
cp /etc/slurm/slurm.conf /etc/slurm/gres.conf /etc/slurm/cgroup.conf "$C/"
cp "$SHARED"/nodeinfo/*.env "$SHARED"/nodeinfo/*.conf "$C/" 2>>"$C/copy-errors.txt"
dpkg-query -W slurmctld slurmdbd slurm-client munge mariadb-server >"$C/head-packages.txt" 2>&1
# Every time the checks compare is read on head (its polls, slurmctld's accounting), so no clock offset enters them.
for n in gpu1 gpu2; do
  root_on "$n" "$C/slurmd-pid-$n-start.txt" systemctl show -p MainPID --value slurmd
done
echo "config_done=$(now)" >>"$EVID/timeline.env"

# --------------------------------------------------------------- B1: device confinement
b1() {
  local rep=$1 node=$2 d=$EVID/b1/rep-$1 a u
  mkdir -p "$d" && chmod 777 "$d"
  echo "node=$node" >"$d/node.env"
  a=$(as_tenant sbatch --parsable -w "$node" --gres=gpu:1 --mem=4G -t 5 -o "$d/alloc.json" -e "$d/alloc.err" \
    --wrap "$PY $BIN/probe_cuda.py") || { echo "sbatch failed" >"$d/alloc.sbatch-error"; return; }
  echo "alloc_job=$a" >>"$d/node.env"
  job_done "$a" $(( $(date +%s) + 240 )) || echo "alloc job $a did not end in 240 s" >"$d/alloc.timeout"
  u=$(as_tenant sbatch --parsable -w "$node" --mem=4G -t 5 -o "$d/unalloc.json" -e "$d/unalloc.err" \
    --export=ALL,PROBE_UNSET=1 --wrap "$PY $BIN/probe_cuda.py") || { echo "sbatch failed" >"$d/unalloc.sbatch-error"; return; }
  echo "unalloc_job=$u" >>"$d/node.env"
  job_done "$u" $(( $(date +%s) + 240 )) || echo "unalloc job $u did not end in 240 s" >"$d/unalloc.timeout"
}
for spec in 1:gpu1 2:gpu1 3:gpu1 4:gpu2; do
  # Each check is admitted only with its own worst case left, so none is cut short; one that is not is NOTRUN.
  if [ "$(left "$CHECKS_END")" -lt 480 ]; then notrun "b1/rep-${spec%%:*}" "fewer than 480 s left for the checks"; continue; fi
  b1 "${spec%%:*}" "${spec##*:}"
done
echo "b1_done=$(now)" >>"$EVID/timeline.env"
ship || log "the evidence after b1 could not be shipped"

# --------------------------------------------------------------- B2: memory confinement
cat >"$SHARED/jobs/b2.sh" <<'EOF'
#!/bin/bash
# B2: a step that touches 2 GiB under a 512 MiB job; then the job's own memory.events, two levels above this task.
srun python3 /shared/bin/alloc.py
echo "srun_rc=$?"
cg=$(sed -n 's/^0:://p' /proc/self/cgroup)
jobcg=${cg%%/step_batch*}
echo "job_cgroup=$jobcg"
sed 's/^/job_memory_events /' "/sys/fs/cgroup$jobcg/memory.events"
echo "job_memory_max=$(cat "/sys/fs/cgroup$jobcg/memory.max")"
EOF
chmod 755 "$SHARED/jobs/b2.sh"
root_on gpu2 "$EVID/b2-slurmd-pid-before.txt" systemctl show -p MainPID --value slurmd
for rep in 1 2 3; do
  d=$EVID/b2/rep-$rep
  if [ "$(left "$CHECKS_END")" -lt 300 ]; then notrun "b2/rep-$rep" "fewer than 300 s left for the checks"; continue; fi
  mkdir -p "$d" && chmod 777 "$d"
  t_start=$(date +%s)
  id=$(as_tenant sbatch --parsable -w gpu2 --mem=512M -t 5 -o "$d/job.out" -e "$d/job.err" "$SHARED/jobs/b2.sh") ||
    { echo "sbatch failed" >"$d/sbatch-error"; continue; }
  echo "job=$id" >"$d/job.env"
  job_done "$id" $(( $(date +%s) + 240 )) || echo "job $id did not end in 240 s" >"$d/timeout"
  t_end=$(( $(date +%s) + 2 ))
  echo "t_start=$t_start" >>"$d/job.env"
  echo "t_end=$t_end" >>"$d/job.env"
  sacct -j "$id" -n -P -o JobID,State,ExitCode,MaxRSS >"$d/sacct.txt" 2>&1
  echo $? >"$d/sacct.txt.rc"
  root_on gpu2 "$d/kernel.txt" journalctl -k -o short-iso --no-pager --since "@$(( t_start - 1 ))" --until "@$t_end"
  root_on gpu2 "$d/slurmd-pid-after.txt" systemctl show -p MainPID --value slurmd
  scontrol show node gpu2 >"$d/node-after.txt" 2>&1
done
echo "b2_done=$(now)" >>"$EVID/timeline.env"
ship || log "the evidence after b2 could not be shipped"

# --------------------------------------------------------------- B3: limits and the pending reason
# poll_pair DIR ID1 ID2 SECONDS: one squeue line per second for both jobs, timestamped, until both are gone or SECONDS.
poll_pair() {
  local d=$1 i1=$2 i2=$3 until_t=$(( $(date +%s) + $4 ))
  while [ "$(date +%s)" -lt "$until_t" ]; do
    squeue -h -j "$i1,$i2" -o "%i %T %r" | sed "s/^/$(now) /" >>"$d/poll.txt"
    [ -n "$(squeue -h -j "$i1,$i2" -o %i)" ] || break
    sleep 1
  done
  sacct -j "$i1,$i2" -n -P -X -o JobID,State,Submit,Start,End,Reason >"$d/sacct.txt" 2>&1
  echo $? >"$d/sacct.txt.rc"
}
b3() {
  local name=$1 d=$EVID/b3/$1 i1 i2
  shift
  mkdir -p "$d" && chmod 777 "$d"
  i1=$(as_tenant sbatch --parsable "$@" -t 5 -o /dev/null --wrap "sleep 60") || { echo "sbatch 1 failed" >"$d/sbatch-error"; return; }
  echo "$(now) submitted $i1" >>"$d/poll.txt"
  until_true $(( $(date +%s) + 60 )) 1 bash -c "[ \"\$(squeue -h -j $i1 -o %T)\" = RUNNING ]" || echo "first job never RUNNING" >"$d/first-not-running"
  i2=$(as_tenant sbatch --parsable "$@" -t 5 -o /dev/null --wrap "sleep 60") || { echo "sbatch 2 failed" >"$d/sbatch-error"; return; }
  echo "$(now) submitted $i2" >>"$d/poll.txt"
  printf 'first=%s\nsecond=%s\n' "$i1" "$i2" >"$d/jobs.env"
  poll_pair "$d" "$i1" "$i2" 200
}
if [ "$(left "$CHECKS_END")" -ge 540 ]; then
  b3 a -A acct-a --gres=gpu:1 --mem=1G
  b3 b -q qone --mem=500M
else
  notrun b3 "fewer than 540 s left for the checks"
fi
echo "b3_done=$(now)" >>"$EVID/timeline.env"
ship || log "the evidence after b3 could not be shipped"

# --------------------------------------------------------------- B4: drain, requeue, resume
b4() {
  local d=$EVID/b4 ref run t_fault
  mkdir -p "$d" && chmod 777 "$d"
  ref=$(as_tenant sbatch --parsable -w gpu2 --gres=gpu:1 --mem=4G -t 10 -o "$d/reference.jsonl" -e "$d/reference.err" \
    --export=ALL,TRAIN_DIR=$SHARED/ckpt/reference,TRAIN_STEPS=60,TRAIN_STEP_SLEEP=0,TRAIN_DEVICE=$TRAIN_DEVICE \
    --wrap "$PY $BIN/train_gpu.py") || { echo "reference sbatch failed" >"$d/sbatch-error"; return; }
  echo "reference_job=$ref" >"$d/jobs.env"
  job_done "$ref" $(( $(date +%s) + 600 )) || { echo "reference did not end in 600 s" >"$d/reference.timeout"; return; }

  scontrol update nodename=gpu2 state=drain reason=b4-hold
  run=$(as_tenant sbatch --parsable --requeue --gres=gpu:1 --mem=4G -t 15 --open-mode=append -o "$d/run.jsonl" -e "$d/run.err" \
    --export=ALL,TRAIN_DIR=$SHARED/ckpt/run,TRAIN_STEPS=60,TRAIN_STEP_SLEEP=1,TRAIN_DEVICE=$TRAIN_DEVICE \
    --wrap "$PY $BIN/train_gpu.py") || { echo "run sbatch failed" >"$d/sbatch-error"; scontrol update nodename=gpu2 state=resume; return; }
  echo "run_job=$run" >>"$d/jobs.env"
  until_true $(( $(date +%s) + 300 )) 1 grep -q '"event": "ckpt", .*"step": 20,' "$d/run.jsonl" ||
    { echo "the run never checkpointed step 20 in 300 s" >"$d/run.no-ckpt"; scontrol update nodename=gpu2 state=resume; return; }
  scontrol show job "$run" >"$d/run-job-before.txt" 2>&1
  scontrol update nodename=gpu2 state=resume
  echo "gpu2_resumed=$(now)" >>"$d/events.env"
  uuid=$(grep -oE 'UUID="[^"]+"' "$SHARED/gpuhc/gpu1.prom" | head -1)
  printf 'DCGM_FI_DEV_XID_ERRORS{gpu="0",%s} 79\nDCGM_FI_DEV_ECC_DBE_VOL_TOTAL{gpu="0",%s} 0\n' "$uuid" "$uuid" >"$SHARED/gpuhc/gpu1.prom.tmp"
  mv "$SHARED/gpuhc/gpu1.prom.tmp" "$SHARED/gpuhc/gpu1.prom"
  t_fault=$(now)
  echo "fault_written=$t_fault" >>"$d/events.env"
  for _ in $(seq 1 60); do
    # A failed read is written as such, so the scorer can tell it from a node that was not drained.
    line=$(scontrol show node gpu1) && echo "$(now) $(grep -oE 'State=\S+|Reason=.*' <<<"$line" | paste -sd' ')" >>"$d/gpu1-state.txt" ||
      echo "$(now) READ-FAILED" >>"$d/gpu1-state.txt"
    sleep 1
  done
  job_done "$run" $(( $(date +%s) + 600 )) || echo "the run did not end in 600 s after the fault" >"$d/run.timeout"
  scontrol show job "$run" >"$d/run-job-after.txt" 2>&1
  echo $? >"$d/run-job-after.txt.rc"
  sacct -j "$run" -n -P -D -o JobID,State,NodeList,Start,End,ExitCode >"$d/run-sacct.txt" 2>&1
  echo $? >"$d/run-sacct.txt.rc"
  "$PY" - "$SHARED/ckpt/reference/final.pt" "$SHARED/ckpt/run/final.pt" >"$d/param-diff.txt" 2>&1 <<'EOF'
import sys, torch
a, b = torch.load(sys.argv[1]), torch.load(sys.argv[2])
print("max_abs_diff=%r" % max(float((a[k] - b[k]).abs().max()) for k in a))
EOF
  cp "$SHARED/gpuhc/gpu1.log" "$SHARED/gpuhc/gpu2.log" "$d/" 2>>"$d/copy-errors.txt"
  # gpu1 back in service, because collect.sh reads its journal through a job: the healthy signal first, or gpuhc would
  # drain it again on its next run.
  printf 'DCGM_FI_DEV_XID_ERRORS{gpu="0",%s} 0\nDCGM_FI_DEV_ECC_DBE_VOL_TOTAL{gpu="0",%s} 0\n' "$uuid" "$uuid" >"$SHARED/gpuhc/gpu1.prom.tmp"
  mv "$SHARED/gpuhc/gpu1.prom.tmp" "$SHARED/gpuhc/gpu1.prom"
  sleep 10
  scontrol update nodename=gpu1 state=resume
  echo "gpu1_resumed=$(now)" >>"$d/events.env"
}
# B4 waits at most 600 + 300 + 60 + 600 + 10 s, and the margin is collection's.
if [ "$(left "$CHECKS_END")" -ge 1700 ]; then b4; else notrun b4 "fewer than 1,700 s left for the checks"; fi
echo "b4_done=$(now)" >>"$EVID/timeline.env"
ship || log "the evidence after b4 could not be shipped"
