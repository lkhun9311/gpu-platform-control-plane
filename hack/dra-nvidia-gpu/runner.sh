#!/bin/bash
# The on-instance part of hack/dra-nvidia-gpu-session.sh: the cluster, the driver build, then the scenarios in SCENARIOS.
#
#   runner.sh <dir with the shipped inputs> <out dir> <harness-end epoch>
#
# Every phase is its own script with its own bound, and the bounds below are the session script's, which its offline
# test holds equal.
# The cluster and the build gate everything after them.
# This session runs S1 as the control and then S5, #1278's force-delete reproducer.
# S1 comes first because a leak S5 finds holds the node's only GPU, and no claim made after it could prepare.
# S4, upstream's bats baseline, is not run: S5's validity rests on its own reads (PrepareCompleted, both objects gone
# from the API while the plugin was down, the plugin back), and S1 in the same run shows kubelet and the plugin
# completing an unprepare after a plugin outage on this rig, which is closer to S5's question than the bats files.
# S4 passed on this rig, at this commit, in attempts 4 and 5.
# S2, S3 and S4 stay runnable: a SCENARIOS that lists S4 must list it first, because it needs a fresh cluster (it runs
# with SKIP_CLEANUP=true, which skips upstream's cleanup-from-previous-run.sh, and its setup_suite refuses any helm
# release of the chart), and a failing S4 stops the run, since a rig that fails upstream's own baseline cannot support
# a claim about the rest.
# The other scenarios are independent, so one that fails is recorded and the next still runs.
# They exit 4 when the experiment itself was not valid (a precondition never held), so the session can tell that apart
# from a valid run, whatever it observed.
# With UPLOAD_PREFIX set, each phase's evidence leaves the instance as that phase ends, so a Spot reclaim loses at most
# the phase it interrupted.
set -u
IN=$1
OUT=$2
HE=$3
CLUSTER_S=840
BUILD_S=720
S4_S=1020
S1_S=960
S2_S=900
S3_S=360
S5_S=1500
# The scenarios, in the order they run; the session ships exactly these, and its offline test holds the two equal.
SCENARIOS="s1 s5"
DRA_REPO=https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu
# origin/main on 2026-11-18, the commit STATUS.md and #1639's reproduction name.
DRA_COMMIT=e775fdb63e593a121b40fc1cc4c9a9c89955e635
# Upstream's nvkind CI default (hack/ci/gcp-nvkind/e2e-test.sh): DRA is GA in 1.34.
K8S_VERSION=v1.34.3
CLUSTER=dra-session
# The archive and upload after each phase come out of that phase's bound, so the bounds still sum to the schedule.
PHASE_UPLOAD_S=45
SRC=/opt/dra/src
# cloud-init runs this without HOME, and setup-nvkind-node.sh installs Go tools under $HOME/go.
export HOME="${HOME:-/root}"
export PATH="/usr/local/go/bin:$HOME/go/bin:$PATH" KUBECONFIG="$HOME/.kube/config"
export IN SRC DRA_REPO DRA_COMMIT K8S_VERSION CLUSTER

mkdir -p "$OUT"
# To stderr, because phase's stdout is its exit status and is captured.
say() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*" | tee -a "$OUT/steps.log" >&2; }
printf 'phase\texit\tseconds\tbound\n' >"$OUT/summary.tsv"

# phase NAME BOUND runs NAME.sh under min(BOUND, time to the harness end) and echoes its exit status.
phase() {
  local name=$1 bound=$2 b t0 rc
  b=$(( HE - $(date +%s) ))
  [ "$b" -gt "$bound" ] && b=$bound
  if [ "$b" -lt $(( PHASE_UPLOAD_S + 45 )) ]; then
    say "phase $name not started: $b s to the harness end"
    printf '%s\tskipped\t0\t%s\n' "$name" "$bound" >>"$OUT/summary.tsv"
    echo 124
    return
  fi
  mkdir -p "$OUT/$name"
  say "phase $name: start, bound $b s"
  t0=$(date +%s)
  D="$OUT/$name" DL=$(( t0 + b - PHASE_UPLOAD_S - 15 )) WORKER="${WORKER:-}" \
    timeout --kill-after=15 $(( b - PHASE_UPLOAD_S - 15 )) bash "$IN/$name.sh" >"$OUT/$name/out.log" 2>&1
  rc=$?
  printf '%s\t%s\t%s\t%s\n' "$name" "$rc" "$(( $(date +%s) - t0 ))" "$bound" >>"$OUT/summary.tsv"
  say "phase $name: exit $rc after $(( $(date +%s) - t0 )) s"
  if [ -n "${UPLOAD_PREFIX:-}" ]; then
    tar --warning=no-file-changed -czf "${TMPDIR:-/tmp}/phase-$name.tgz" -C "$OUT" "$name" summary.tsv steps.log 2>>"$OUT/upload.log"
    timeout 30 aws s3 cp --only-show-errors "${TMPDIR:-/tmp}/phase-$name.tgz" "$UPLOAD_PREFIX/phase-$name.tgz" >>"$OUT/upload.log" 2>&1 ||
      say "the evidence of $name did not upload"
  fi
  echo "$rc"
}

{ nvidia-smi; nvidia-smi -q; } >"$OUT/nvidia-smi-start.txt" 2>&1

rc=$(phase cluster "$CLUSTER_S")
[ "$rc" = 0 ] || { say "CLUSTER FAILED; nothing else runs"; exit 2; }
# The one kind node that carries the GPU; the checkpoint and the kubelet live inside it.
WORKER=$(docker ps --filter "label=io.x-k8s.kind.cluster=$CLUSTER" --filter label=io.x-k8s.kind.role=worker --format '{{.Names}}')
[ "$(wc -w <<<"$WORKER")" = 1 ] || { say "expected one worker node container, found '$WORKER'"; exit 2; }
export WORKER
say "worker node $WORKER"

rc=$(phase build "$BUILD_S")
[ "$rc" = 0 ] || { say "BUILD FAILED; nothing else runs"; exit 2; }

case " $SCENARIOS " in *" s4 "*) [ "${SCENARIOS%% *}" = s4 ] || { say "S4 must run first, on a fresh cluster"; exit 2; } ;; esac
bound_of() { case $1 in s1) echo "$S1_S" ;; s2) echo "$S2_S" ;; s3) echo "$S3_S" ;; s4) echo "$S4_S" ;; s5) echo "$S5_S" ;; *) return 1 ;; esac; }
for s in $SCENARIOS; do
  b=$(bound_of "$s") || { say "no bound for scenario $s"; exit 2; }
  rc=$(phase "$s" "$b")
  if [ "$s" = s4 ] && [ "$rc" != 0 ]; then
    say "S4 FAILED (exit $rc): the rig fails upstream's own baseline, so nothing after it is run"
    { nvidia-smi; nvidia-smi -q; } >"$OUT/nvidia-smi-end.txt" 2>&1
    exit 3
  fi
  [ "$rc" = 0 ] || say "$s exited $rc; the next scenario still runs"
done
{ nvidia-smi; nvidia-smi -q; } >"$OUT/nvidia-smi-end.txt" 2>&1
say "all scenarios done"
