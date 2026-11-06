#!/usr/bin/env bash
# Runs the Slurm lab's host-side checks, which need no Slurm, no containers and no third-party Python.
# check_gpuhc.py runs the health check against stub scontrol and squeue; check_score_requeue.py feeds the requeue
# scorer the archived runs and doctored copies of them; the last block runs steps/lib.sh's waits against a stub docker.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
lab="$root/experiments/slurm-lab"
fail=0
for t in check_gpuhc.py check_score_requeue.py; do
  python3 "$lab/$t" || { echo "check-slurm-lab-host: $t failed" >&2; fail=1; }
done

# A step whose wait timed out must exit nonzero even when its last command succeeded, unless the wait passed -o;
# and a step that sets its own EXIT trap the way 00-fileless-gres.sh does must keep that rule.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/steps" "$tmp/evid"
printf '#!/bin/sh\nexit 1\n' >"$tmp/bin/docker"
chmod +x "$tmp/bin/docker"
cp "$lab/steps/lib.sh" "$tmp/steps/lib.sh"
step() {
  printf '%s\n' '#!/usr/bin/env bash' 'source "$(dirname "$0")/lib.sh"' 'out t.txt' "$1" 'note done' >"$tmp/steps/t.sh"
  PATH="$tmp/bin:$PATH" EVID="$tmp/evid" bash "$tmp/steps/t.sh" >"$tmp/stderr" 2>&1
}
expect() {
  local name=$1 want=$2 got=0
  step "$3" || got=$?
  if [ "$got" = "$want" ]; then echo "ok   $name"; else echo "FAIL $name: exit $got, want $want"; cat "$tmp/stderr"; fail=1; fi
}
expect "a step with no wait exits 0" 0 'true'
expect "a timed-out wait_until fails the step" 1 'wait_until 1 false'
expect "a timed-out trace fails the step" 1 'trace 1 false true'
expect "a wait_until -o timeout is an observation" 0 'wait_until -o 1 false'
expect "a step's own failure keeps its status" 3 'wait_until 1 false; exit 3'
expect "a step trap like 00's keeps the rule" 1 "trap 'rc=\$?; true; (exit \"\$rc\"); step_end' EXIT; wait_until 1 false"

# run.sh removes the containers on a failure too, keeps the failure's status, and leaves them with KEEP=1.
mkdir -p "$tmp/run"
cp "$lab/run.sh" "$tmp/run/run.sh"
cat >"$tmp/run/docker" <<'STUB'
#!/bin/sh
echo "$*" >>"$CALLS"
[ "$2" = build ] && exit 7
exit 0
STUB
chmod +x "$tmp/run/docker"
runcase() {
  local name=$1 keep=$2 want_down=$3 got=0
  : >"$tmp/calls"
  PATH="$tmp/run:$PATH" CALLS="$tmp/calls" KEEP="$keep" bash "$tmp/run/run.sh" >"$tmp/stderr" 2>&1 || got=$?
  local downs
  downs=$(grep -c '^compose down -v' "$tmp/calls" || true)
  if [ "$got" = 7 ] && [ "$downs" = "$want_down" ]; then echo "ok   $name"; else
    echo "FAIL $name: exit $got (want 7), $downs down call(s) (want $want_down)"; cat "$tmp/calls"; fail=1; fi
}
runcase "run.sh tears down after a failed build and keeps its status" 0 2
runcase "run.sh with KEEP=1 leaves the lab after a failure" 1 1
exit "$fail"
