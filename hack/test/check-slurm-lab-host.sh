#!/usr/bin/env bash
# Runs the Slurm lab's host-side checks, which need no Slurm, no containers and no third-party Python.
# check_gpuhc.py runs the health check against stub scontrol and squeue; check_score_requeue.py feeds the requeue
# scorer hand-cut record sets, each of which it must refuse or accept.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fail=0
for t in check_gpuhc.py check_score_requeue.py; do
  python3 "$root/experiments/slurm-lab/$t" || { echo "check-slurm-lab-host: $t failed" >&2; fail=1; }
done
exit "$fail"
