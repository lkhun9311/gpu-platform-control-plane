#!/usr/bin/env bash
# Checks on kind that the gpu simulator advertises its devices again after its node's kubelet restarts.
#
# On 2026-09-29 a kind node's kubelet was stopped and started, and the node advertised 0 nvidia.com/gpu from then on
# while the simulator Pod stayed Running with 0 restarts: a starting kubelet deletes every plugin socket and forgets
# every registration, and the simulator never registered again.
# 97c52d51 made it notice and re-register; its tests run against a fake kubelet, and this is the check on a real one.
#
# Two arms, each on its own fresh cluster, the same steps in each:
#   fixed    the simulator built from this tree
#   control  the simulator built from 97c52d51^, the last commit without the fix
# The control is what makes the check able to fail: if the old simulator also recovers, this harness does not
# reproduce the fault, and the fixed arm's recovery says nothing.
#
# Predictions, written before the first run:
#   fixed:   within 30 s of the kubelet's start the worker advertises 2 again, the same simulator Pod with 0 restarts
#            logs that it registered again, its socket is back, and a Pod requesting 2 GPUs is scheduled.
#   control: 120 s after the kubelet's start the worker still advertises 0, the Pod still Running with 0 restarts,
#            no socket, and the 2-GPU Pod stays Pending.
# A stale reading cannot pass the fixed arm: the poll counts only after the node reports Ready on a heartbeat later
# than the restart, and the re-registration log line must postdate the restart.
#
#   hack/simulator-kubelet-restart.sh        # both arms; evidence in ex/simulator-kubelet-restart-<UTC>/
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
NODE_IMAGE=kindest/node:v1.31.0@sha256:53df588e04085fd41ae12de0c3fe4c72f7013bba32a20e7325357a1ac94ba865
CLUSTER=krs
CONTEXT=kind-$CLUSTER
WORKER=$CLUSTER-worker
PREFIX_COMMIT=97c52d51^
OUT=ex/simulator-kubelet-restart-$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p "$OUT"
LOG=$OUT/log.txt

log() { echo "$(date -u +%H:%M:%S) $*" | tee -a "$LOG" >&2; }
die() { log "FAIL: $*"; exit 1; }
k() { kubectl --context "$CONTEXT" "$@"; }

[ -z "$(git status --porcelain)" ] || die "the tree is dirty, so the fixed arm would not be any committed simulator"
kind get clusters | grep -qx "$CLUSTER" && die "a cluster named $CLUSTER already exists"
{
  echo "commit=$(git rev-parse HEAD)"
  echo "prefix_commit=$(git rev-parse "$PREFIX_COMMIT")"
  echo "kind=$(kind version)"
  echo "node_image=$NODE_IMAGE"
} >"$OUT/provenance.txt"

build_images() {
  log "building the fixed simulator from $(git rev-parse --short HEAD)"
  docker build -t gpu-simulator:krs-fixed -f Dockerfile.gpu-simulator . >>"$LOG" 2>&1 || die "fixed image"
  local wt
  wt=$(mktemp -d)
  git worktree add --detach "$wt" "$PREFIX_COMMIT" >>"$LOG" 2>&1 || die "prefix worktree"
  log "building the control simulator from $(git rev-parse --short "$PREFIX_COMMIT")"
  docker build -t gpu-simulator:krs-control -f "$wt/Dockerfile.gpu-simulator" "$wt" >>"$LOG" 2>&1 || die "control image"
  git worktree remove --force "$wt" >>"$LOG" 2>&1 || die "prefix worktree removal"
  for arm in fixed control; do
    echo "image_$arm=$(docker image inspect gpu-simulator:krs-$arm --format '{{.Id}}')" >>"$OUT/provenance.txt"
  done
}

# allocatable prints the worker's advertised nvidia.com/gpu, or 0 when the field is absent.
allocatable() {
  local v
  v=$(k get node "$WORKER" -o jsonpath='{.status.allocatable.nvidia\.com/gpu}')
  echo "${v:-0}"
}

# ready_after prints yes when the worker is Ready on a heartbeat later than the epoch second given.
ready_after() {
  local status beat
  status=$(k get node "$WORKER" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
  beat=$(k get node "$WORKER" -o jsonpath='{.status.conditions[?(@.type=="Ready")].lastHeartbeatTime}')
  if [ "$status" = True ] && [ -n "$beat" ] && [ "$(date -d "$beat" +%s)" -gt "$1" ]; then echo yes; else echo no; fi
}

run_arm() {
  local arm=$1 dir=$OUT/$1
  mkdir -p "$dir"
  log "== arm $arm"
  cat >"$dir/kind-config.yaml" <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
- role: worker
EOF
  kind create cluster --name "$CLUSTER" --image "$NODE_IMAGE" --config "$dir/kind-config.yaml" >>"$LOG" 2>&1 || die "cluster"
  kind load docker-image "gpu-simulator:krs-$arm" --name "$CLUSTER" >>"$LOG" 2>&1 || die "image load"
  k create namespace system >>"$LOG" 2>&1 || die "namespace"
  k apply -f config/device-plugin/daemonset.yaml >>"$LOG" 2>&1 || die "daemonset"
  k -n system set image ds/gpu-simulator "*=gpu-simulator:krs-$arm" >>"$LOG" 2>&1 || die "image set"
  # The manifest names :latest, so it says Always, and a new tag does not change that; kind has no registry to pull from.
  k -n system patch ds/gpu-simulator --type=json \
    -p '[{"op":"add","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"IfNotPresent"}]' >>"$LOG" 2>&1 ||
    die "pull policy"
  k -n system set env ds/gpu-simulator FAKE_GPU_COUNT=2 >>"$LOG" 2>&1 || die "count"
  k -n system rollout status ds/gpu-simulator --timeout=180s >>"$LOG" 2>&1 || die "rollout"

  local i
  for i in $(seq 60); do [ "$(allocatable)" = 2 ] && break; sleep 1; done
  [ "$(allocatable)" = 2 ] || die "arm $arm: the worker never advertised 2 before the restart"
  local pod uid0 restarts0
  pod=$(k -n system get pods -l app.kubernetes.io/component=gpu-simulator --field-selector "spec.nodeName=$WORKER" -o jsonpath='{.items[0].metadata.name}')
  [ -n "$pod" ] || die "arm $arm: no simulator Pod on $WORKER"
  uid0=$(k -n system get pod "$pod" -o jsonpath='{.metadata.uid}')
  restarts0=$(k -n system get pod "$pod" -o jsonpath='{.status.containerStatuses[0].restartCount}')
  echo "before: allocatable=2 pod=$pod uid=$uid0 restarts=$restarts0" >"$dir/result.txt"

  # Stop, then start: the 2026-09-29 injection, which let the node go NotReady before the kubelet came back.
  docker exec "$WORKER" systemctl stop kubelet >>"$LOG" 2>&1 || die "kubelet stop"
  sleep 5
  local started
  started=$(date -u +%s)
  docker exec "$WORKER" systemctl start kubelet >>"$LOG" 2>&1 || die "kubelet start"
  echo "kubelet_started_at=$(date -u -d "@$started" +%FT%TZ)" >>"$dir/result.txt"

  local window=30 recovered=""
  [ "$arm" = control ] && window=120
  for i in $(seq "$window"); do
    sleep 1
    [ "$(ready_after "$started")" = yes ] || continue
    if [ "$(allocatable)" = 2 ] && [ -z "$recovered" ]; then
      recovered=$(( $(date -u +%s) - started ))
      [ "$arm" = fixed ] && break
    fi
  done
  local ready_now
  ready_now=$(ready_after "$started")

  local uid1 restarts1 sock line
  uid1=$(k -n system get pod "$pod" -o jsonpath='{.metadata.uid}')
  restarts1=$(k -n system get pod "$pod" -o jsonpath='{.status.containerStatuses[0].restartCount}')
  k -n system logs "$pod" >"$dir/simulator.log" 2>>"$LOG" || die "arm $arm: simulator log"
  docker exec "$WORKER" ls /var/lib/kubelet/device-plugins >"$dir/device-plugins.txt" 2>>"$LOG" || die "arm $arm: socket listing"
  sock=$(grep -cx 'gpu-simulator.sock' "$dir/device-plugins.txt" || true)
  line=$(grep -c 'kubelet restarted, serving and registering again' "$dir/simulator.log" || true)

  cat >"$dir/probe.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: krs-probe
  namespace: default
spec:
  restartPolicy: Never
  containers:
  - name: c
    image: registry.k8s.io/pause:3.10
    resources:
      limits:
        nvidia.com/gpu: 2
EOF
  k apply -f "$dir/probe.yaml" >>"$LOG" 2>&1 || die "probe"
  local scheduled=""
  for i in $(seq 20); do
    scheduled=$(k get pod krs-probe -o jsonpath='{.status.conditions[?(@.type=="PodScheduled")].status}')
    [ "$scheduled" = True ] && break
    sleep 1
  done
  k get pod krs-probe -o json >"$dir/probe.json" 2>>"$LOG" || die "probe read"

  {
    echo "after: ready_after_restart=$ready_now allocatable=$(allocatable) recovered_after_s=${recovered:-never}"
    echo "after: same_pod=$([ "$uid1" = "$uid0" ] && echo yes || echo no) restarts=$restarts1"
    echo "after: socket_present=$sock reregistered_log_lines=$line probe_scheduled=${scheduled:-unknown}"
  } >>"$dir/result.txt"
  cat "$dir/result.txt" | tee -a "$LOG" >&2

  kind delete cluster --name "$CLUSTER" >>"$LOG" 2>&1 || die "cluster delete"
}

# verdict compares an arm's result with its registered prediction and prints held or contradicted with the reason.
verdict() {
  local arm=$1 r=$OUT/$1/result.txt want got
  if [ "$arm" = fixed ]; then
    want="ready_after_restart=yes allocatable=2 same_pod=yes restarts=0 socket_present=1 reregistered_log_lines=1 probe_scheduled=True"
  else
    want="ready_after_restart=yes allocatable=0 recovered_after_s=never same_pod=yes restarts=0 socket_present=0 reregistered_log_lines=0"
  fi
  # Only the after lines: the before line also says allocatable=2 and restarts=0, and would pass a fixed arm that
  # never recovered.
  local after
  after=" $(grep '^after:' "$r" | sed 's/^after://' | tr '\n' ' ') "
  got=""
  local w
  for w in $want; do
    case "$after" in *" $w "*) ;; *) got="$got missing:$w" ;; esac
  done
  if [ "$arm" = fixed ]; then
    local s
    s=$(echo "$after" | sed -n 's/.* recovered_after_s=\([0-9][0-9]*\) .*/\1/p')
    { [ -n "$s" ] && [ "$s" -le 30 ]; } || got="$got recovered_after_s_not_within_30"
  else
    case "$after" in *" probe_scheduled=True "*) got="$got probe_scheduled" ;; esac
  fi
  if [ -z "$got" ]; then echo "$arm: held"; else echo "$arm: contradicted:$got"; fi
}

build_images
run_arm control
run_arm fixed
{ verdict control; verdict fixed; } | tee "$OUT/verdict.txt" | tee -a "$LOG"
log "evidence in $OUT"
