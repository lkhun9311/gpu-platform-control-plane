#!/usr/bin/env bash
# Runs the multi-Pod DDP experiment registered in experiments/multi-pod-ddp/README.md.
#
# It builds a throwaway kind cluster `ddp` from this tree, runs the four arms one after another, and deletes the
# cluster at the end (KEEP=1 keeps it).
# The long-lived `platform` cluster is not used: its webhook configuration is stale and refuses MLTrainingJob creates.
#
# Evidence goes to hack/multi-pod-ddp-<UTC>/, and experiments/multi-pod-ddp/analyze.py scores it.
# Usage: hack/multi-pod-ddp.sh [arm ...]   (default: pass no-sync bad-address one-rank-fails)
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

CLUSTER=ddp
CONTEXT=kind-$CLUSTER
NS=ddp
SYS=gpu-platform-control-plane-system
TAG=ddp
IMG=cpu-ddp:torch251
KUEUE_VERSION=v0.18.3
CERT_MANAGER_VERSION=v1.21.1
# The registered budget per arm; collection runs until the job is terminal or this passes.
ARM_BUDGET=300
OUT=hack/multi-pod-ddp-$(date -u +%Y%m%dT%H%M%SZ)
LOG=$OUT/log.txt
mkdir -p "$OUT"

ARMS=("$@")
[ ${#ARMS[@]} -gt 0 ] || ARMS=(pass no-sync bad-address one-rank-fails)

log() { echo -e "$(date -u +%H:%M:%S) $*" | tee -a "$LOG"; }
k() { kubectl --context "$CONTEXT" "$@"; }
# Background collectors are tracked so cleanup can stop them; an orphaned `kubectl logs -f` outlives the cluster.
COLLECTORS=()
cleanup() {
  for p in "${COLLECTORS[@]}"; do kill "$p" 2>>"$LOG"; done
  [ "${KEEP:-0}" = 1 ] && { log "cleanup: KEEP=1, leaving $CLUSTER"; return; }
  local listed
  listed=$(kind get clusters 2>>"$LOG") || log "cleanup: kind get clusters failed"
  if grep -qx "$CLUSTER" <<<"$listed"; then
    kind delete cluster --name "$CLUSTER" >>"$LOG" 2>&1 || log "cleanup: kind delete failed"
    listed=$(kind get clusters 2>>"$LOG")
    if grep -qx "$CLUSTER" <<<"$listed"; then log "cleanup: $CLUSTER STILL EXISTS"; else log "cleanup: deleted $CLUSTER"; fi
  else
    log "cleanup: $CLUSTER not listed (listed: $(tr '\n' ' ' <<<"$listed"))"
  fi
}
trap cleanup EXIT
# A setup failure voids the run; it is written where analyze.py reads it, so it can never be scored as an arm.
die() {
  log "VOID: setup failed at: $*"
  echo "$*" >"$OUT/VOID"
  { k get pods -A -o wide; k get events -A --sort-by=.lastTimestamp | tail -60; } >>"$OUT/failure-state.txt" 2>&1
  exit 1
}
retry() {
  for _ in $(seq 1 40); do "$@" && return 0; sleep 3; done
  return 1
}

export PATH="$PWD/bin:$PATH"
command -v kustomize >/dev/null || make kustomize >>"$LOG" 2>&1 || die "make kustomize"
for tool in docker kind kubectl kustomize python3; do command -v "$tool" >/dev/null || die "missing tool $tool"; done

{
  echo "commit=$(git rev-parse HEAD)"
  echo "dirty_files=$(git status --porcelain | wc -l)"
  echo "kind=$(kind version)"
  echo "kubectl=$(kubectl version --client -o json | python3 -c 'import json,sys;print(json.load(sys.stdin)["clientVersion"]["gitVersion"])')"
  echo "kueue=$KUEUE_VERSION"
  echo "cert_manager=$CERT_MANAGER_VERSION"
  echo "train_py_sha256=$(sha256sum experiments/cpu-ddp/train.py | cut -d' ' -f1)"
  echo "arms=${ARMS[*]}"
} >"$OUT/provenance.txt"
log "provenance: $(tr '\n' ' ' <"$OUT/provenance.txt")"

log "== images"
docker build -q -t "$IMG" experiments/cpu-ddp >>"$LOG" 2>&1 || die "image build"
echo "workload_image=$(docker image inspect "$IMG" --format '{{.Id}}')" >>"$OUT/provenance.txt"
echo "torch=$(docker run --rm "$IMG" python -c 'import torch;print(torch.__version__)' 2>>"$LOG")" >>"$OUT/provenance.txt"
make docker-build IMG=controller:$TAG >>"$LOG" 2>&1 || die "operator image"
make docker-build-gpu-simulator GPU_SIMULATOR_IMG=gpu-simulator:$TAG >>"$LOG" 2>&1 || die "simulator image"

log "== cluster $CLUSTER"
grep -qx "$CLUSTER" <<<"$(kind get clusters 2>>"$LOG")" && { kind delete cluster --name "$CLUSTER" >>"$LOG" 2>&1 || die "delete old cluster"; }
kind create cluster --name "$CLUSTER" --config hack/kind-config.yaml >>"$LOG" 2>&1 || die "kind create"
echo "node_image=$(docker inspect "$CLUSTER-worker" --format '{{.Config.Image}}')" >>"$OUT/provenance.txt"
echo "kubelet=$(k get nodes -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}')" >>"$OUT/provenance.txt"
for img in controller:$TAG gpu-simulator:$TAG "$IMG"; do
  kind load docker-image "$img" --name "$CLUSTER" >>"$LOG" 2>&1 || die "kind load $img"
done

k apply -f "https://github.com/cert-manager/cert-manager/releases/download/$CERT_MANAGER_VERSION/cert-manager.yaml" >>"$LOG" 2>&1 || die "cert-manager"
k -n cert-manager wait --for=condition=Available deploy --all --timeout=300s >>"$LOG" 2>&1 || die "cert-manager Available"
k apply --server-side -f "https://github.com/kubernetes-sigs/kueue/releases/download/$KUEUE_VERSION/manifests.yaml" >>"$LOG" 2>&1 || die "kueue"
k -n kueue-system wait --for=condition=Available deploy/kueue-controller-manager --timeout=300s >>"$LOG" 2>&1 || die "kueue Available"
kustomize build config/crd | k apply --server-side -f - >>"$LOG" 2>&1 || die "CRDs"
# shellcheck disable=SC2317  # called through retry
apply_operator() { kustomize build config/operator-webhook | k apply --server-side -f - >>"$LOG" 2>&1; }
retry apply_operator || die "operator"
OPDEP=$(k -n "$SYS" get deploy -o name | grep controller-manager | head -1)
[ -n "$OPDEP" ] || die "no controller-manager deployment"
# The manifests pin an ECR digest a kind node cannot pull, so the local build is set explicitly.
k -n "$SYS" set image "$OPDEP" manager=controller:$TAG >>"$LOG" 2>&1 || die "operator image set"
k -n "$SYS" patch "$OPDEP" --type=json \
  -p '[{"op":"replace","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"IfNotPresent"}]' >>"$LOG" 2>&1 ||
  die "operator pull policy"
k -n "$SYS" rollout status "$OPDEP" --timeout=240s >>"$LOG" 2>&1 || die "operator rollout"

kustomize build config/device-plugin | k apply -f - >>"$LOG" 2>&1 || die "device plugin"
k -n "$SYS" set image ds/gpu-simulator "*=gpu-simulator:$TAG" >>"$LOG" 2>&1 || die "simulator image set"
k -n "$SYS" patch ds/gpu-simulator --type=json \
  -p '[{"op":"add","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"IfNotPresent"}]' >>"$LOG" 2>&1 ||
  die "simulator pull policy"
# One device per worker is what forces the two ranks onto different nodes; that is by construction, and recorded.
k -n "$SYS" set env ds/gpu-simulator FAKE_GPU_COUNT=1 >>"$LOG" 2>&1 || die "simulator count"
k -n "$SYS" rollout status ds/gpu-simulator --timeout=180s >>"$LOG" 2>&1 || die "simulator rollout"
gpus=""
for _ in $(seq 1 60); do
  gpus=$(k get nodes -l '!node-role.kubernetes.io/control-plane' -o jsonpath='{range .items[*]}{.status.allocatable.nvidia\.com/gpu}{" "}{end}')
  [ "$gpus" = "1 1 " ] && break
  sleep 3
done
[ "$gpus" = "1 1 " ] || die "workers do not each advertise one nvidia.com/gpu (allocatable: '$gpus')"
log "allocatable nvidia.com/gpu per worker: $gpus"

log "== queue"
k apply -f config/kueue/resourceflavor.yaml >>"$LOG" 2>&1 || die "resource flavor"
# shellcheck disable=SC2317  # called through retry
apply_policy() {
  cat <<EOF | k apply -f - >>"$LOG" 2>&1
apiVersion: v1
kind: Namespace
metadata:
  name: $NS
---
apiVersion: platform.lkhun9311.github.io/v1
kind: GPUQuotaPolicy
metadata:
  name: $NS-quota
spec:
  tenant: $NS
  targetNamespace: $NS
  limits:
    gpuCount: 2
  trainingQuota: true
EOF
}
retry apply_policy || die "policy"
nominal=""
for _ in $(seq 1 60); do
  nominal=$(k get clusterqueue "gpu-$NS" -o jsonpath='{.spec.resourceGroups[0].flavors[0].resources[0].nominalQuota}' 2>>"$LOG")
  label=$(k get ns "$NS" -o jsonpath='{.metadata.labels.platform\.lkhun9311\.github\.io/gpu-quota-enforced}')
  lq=$(k -n "$NS" get localqueue "gpu-$NS" -o name 2>>"$LOG")
  [ "$nominal" = 2 ] && [ "$label" = true ] && [ -n "$lq" ] && break
  sleep 3
done
[ "$nominal" = 2 ] && [ "$label" = true ] && [ -n "$lq" ] ||
  die "policy did not produce ClusterQueue gpu-$NS with nominal 2, its LocalQueue, and the namespace label (nominal='$nominal' label='$label' lq='$lq')"
{ k get clusterqueue "gpu-$NS" -o yaml; k get ns "$NS" -o yaml; k get validatingwebhookconfiguration -o yaml; } >"$OUT/setup-state.yaml" 2>&1

# collect_pods streams every Pod's log from the moment its container starts, so a Pod the Job controller deletes keeps its records.
collect_pods() {
  local name=$1 dir=$2 started=" "
  # This runs in a subshell, so the log streams it starts are its own children and are stopped with it.
  # shellcheck disable=SC2046  # word splitting of the pid list is intended
  trap 'kill $(jobs -p) 2>>"$LOG"; exit 0' TERM
  while :; do
    k -n "$NS" get pods -l "platform.lkhun9311.github.io/mltrainingjob=$name" -o json >"$dir/.pods.json" 2>>"$LOG" || { sleep 1; continue; }
    python3 - "$dir/.pods.json" "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" >>"$dir/pods.jsonl" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
for p in doc["items"]:
    cs = (p.get("status", {}).get("containerStatuses") or [{}])[0]
    print(json.dumps({
        "observed": sys.argv[2], "uid": p["metadata"]["uid"], "name": p["metadata"]["name"],
        "index": p["metadata"].get("annotations", {}).get("batch.kubernetes.io/job-completion-index"),
        "node": p["spec"].get("nodeName"), "phase": p.get("status", {}).get("phase"),
        "deletionTimestamp": p["metadata"].get("deletionTimestamp"), "state": cs.get("state"),
    }, sort_keys=True))
PY
    for pair in $(python3 -c 'import json,sys
for p in json.load(open(sys.argv[1]))["items"]:
    cs=(p.get("status",{}).get("containerStatuses") or [{}])[0]
    if cs.get("state",{}).get("running") or cs.get("state",{}).get("terminated"):
        print(p["metadata"]["name"]+":"+p["metadata"]["uid"])' "$dir/.pods.json"); do
      case "$started" in *" $pair "*) continue ;; esac
      started="$started$pair "
      k -n "$NS" logs -f "${pair%%:*}" >"$dir/log-${pair##*:}.txt" 2>>"$LOG" &
    done
    sleep 1
  done
}

# run_arm submits one fresh job and samples it once a second until it is terminal or the budget is spent.
run_arm() {
  local arm=$1 extra name dir t0 phase
  case "$arm" in
    pass) extra="" ;;
    no-sync) extra="export DDP_NO_SYNC=1" ;;
    bad-address) extra="export MASTER_ADDR=nowhere.invalid" ;;
    one-rank-fails) extra="export DDP_FAIL_RANK=1 DDP_FAIL_DELAY_SECONDS=10 DDP_HOLD_SECONDS=900" ;;
    *) die "unknown arm $arm" ;;
  esac
  name="ddp-$arm-$(date -u +%H%M%S)"
  dir=$OUT/$arm
  mkdir -p "$dir"
  log "== arm $arm as $name"
  cat <<EOF >"$dir/mltrainingjob.yaml"
apiVersion: platform.lkhun9311.github.io/v1
kind: MLTrainingJob
metadata:
  name: $name
  namespace: $NS
spec:
  queue: gpu-$NS
  image: $IMG
  gpuCount: 1
  distributed:
    worldSize: 2
  command:
    - sh
    - -c
    - |
      export DDP_RUN_ID=$name DDP_OUT_DIR=/tmp/evidence OMP_NUM_THREADS=1 DDP_RENDEZVOUS_TIMEOUT_SECONDS=60
      $extra
      exec python /work/train.py
EOF
  k apply -f "$dir/mltrainingjob.yaml" >>"$LOG" 2>&1 || { log "arm $arm: create refused"; echo "create refused" >"$dir/VOID"; return; }
  t0=$(date +%s)
  collect_pods "$name" "$dir" &
  local collector=$!
  COLLECTORS+=($collector)
  phase=""
  while [ $(($(date +%s) - t0)) -le $ARM_BUDGET ]; do
    # Assembled by python from whole objects, one line per sample.
    # The first version spliced jsonpath output into a printf, and a stray newline and an empty status split or
    # emptied records, so a scorer that skipped unparsable lines saw no readyRanks at all.
    observed=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)
    k -n "$NS" get mltrainingjob "$name" -o json >"$dir/.mltj.json" 2>>"$LOG" || echo null >"$dir/.mltj.json"
    k -n "$NS" get job "$name" -o json >"$dir/.job.json" 2>>"$LOG" || echo null >"$dir/.job.json"
    python3 - "$observed" "$dir/.mltj.json" "$dir/.job.json" >>"$dir/timeline.jsonl" <<'PY'
import json, sys
mltj = json.load(open(sys.argv[2]))
job = json.load(open(sys.argv[3]))
print(json.dumps({
    "observed": sys.argv[1],
    "mltj": (mltj or {}).get("status"),
    "jobConditions": ((job or {}).get("status") or {}).get("conditions"),
}, sort_keys=True))
PY
    phase=$(k -n "$NS" get mltrainingjob "$name" -o jsonpath='{.status.phase}' 2>>"$LOG")
    jobdone=$(k -n "$NS" get job "$name" -o jsonpath='{.status.conditions[?(@.status=="True")].type}' 2>>"$LOG")
    if [[ "$phase" =~ ^(Succeeded|Failed)$ ]] && [[ "$jobdone" =~ (Complete|Failed) ]]; then break; fi
    sleep 1
  done
  log "arm $arm: phase '$phase' after $(($(date +%s) - t0)) s"
  # A few more seconds for the last log lines and the last Pod sample.
  sleep 5
  kill "$collector" 2>>"$LOG"
  wait "$collector" 2>>"$LOG"
  k -n "$NS" get mltrainingjob "$name" -o json >"$dir/final-mltj.json" 2>>"$LOG"
  k -n "$NS" get service "$name-ddp" -o json >"$dir/final-service.json" 2>>"$LOG"
  k -n "$NS" get job "$name" -o json >"$dir/final-job.json" 2>>"$LOG"
  k -n "$NS" get workloads -o json >"$dir/final-workloads.json" 2>>"$LOG"
  echo "$name" >"$dir/name"
}

for arm in "${ARMS[@]}"; do run_arm "$arm"; done
log "== done; scoring"
python3 experiments/multi-pod-ddp/analyze.py "$OUT" | tee -a "$LOG"
exit "${PIPESTATUS[0]}"
