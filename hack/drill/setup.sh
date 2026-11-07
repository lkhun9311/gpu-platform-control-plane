#!/usr/bin/env bash
# Builds the operator drill's throwaway kind cluster `drill`: a control plane and two GPU workers with two simulated
# GPUs and a fake DCGM exporter each, the operator with its GPU fault path on, Kueue, a tenant `train-a` with a
# four-GPU training quota, a shared ReadWriteMany volume, and one NodeHealth per worker.
#
#   bash hack/drill/setup.sh            # build and leave the cluster up for the drill
#   bash hack/drill/setup.sh teardown   # delete the cluster and the drill's state
#
# The pieces are those of hack/restart-lifecycle-kind.sh and hack/distributed-restart-kind.sh (pins, the vendored
# Kueue, the hostPath RWX volume, the controllers on the control plane), cut down to three nodes: the host's inotify
# instances are shared with every other kind cluster, and a five-node cluster has failed to come up beside them.
#
# The operator is built from DRILL_OPERATOR_REV (default: origin/fix/restart-controller-review, PR #520, while it is
# unmerged), because the runbook's restart section describes that branch's rank-stopped finalizer and fencedBy.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

CLUSTER=drill
CONTEXT=kind-$CLUSTER
SYS=gpu-platform-control-plane-system
NS=train-a
TAG=drill
IMG=distributed-restart:drill
NODE_IMAGE='kindest/node:v1.37.0@sha256:a1ed56cfb0e7b93589bdf97c8cd566405a265939e3620fc4f5de89adff580ae5'
CERT_MANAGER_VERSION=v1.21.1
DRILL_OPERATOR_REV=${DRILL_OPERATOR_REV:-origin/fix/restart-controller-review}
# Outside the repository, so an engineer who is told not to read the repository has nothing of the drill's to find.
DRILL_STATE=${DRILL_STATE:-$HOME/.cache/gpuaas-drill}
LOG=$DRILL_STATE/setup.log

k() { kubectl --context "$CONTEXT" "$@"; }
log() { echo "$(date -u +%H:%M:%S) $*" | tee -a "$LOG"; }
die() {
  log "FAILED: $*"
  exit 1
}
retry() {
  local i
  for i in $(seq 1 20); do "$@" && return 0; sleep 6; done
  return 1
}

if [ "${1:-}" = teardown ]; then
  if kind get clusters | grep -qx "$CLUSTER"; then kind delete cluster --name "$CLUSTER"; fi
  # The shared directory holds files the ranks wrote as root inside the nodes.
  if [ -d "$DRILL_STATE/shared" ]; then
    docker run --rm -v "$DRILL_STATE/shared:/s" busybox:1.37.0 sh -c 'rm -rf /s/*' || echo "could not empty $DRILL_STATE/shared"
  fi
  rm -rf "$DRILL_STATE"
  exit 0
fi

mkdir -p "$DRILL_STATE"
: >"$LOG"
clusters=$(kind get clusters) || die "kind get clusters"
if grep -qx "$CLUSTER" <<<"$clusters"; then die "a cluster $CLUSTER already exists; run '$0 teardown' first"; fi
n=$(grep -c . <<<"$clusters")
[ "$n" -le 4 ] || die "$n kind clusters exist; the host's inotify instances will not hold another (refusing above 4)"

log "== images (operator from $DRILL_OPERATOR_REV)"
git fetch -q origin || die "git fetch"
rev=$(git rev-parse --short=8 "$DRILL_OPERATOR_REV") || die "no revision $DRILL_OPERATOR_REV"
src=$(mktemp -d "${TMPDIR:-/tmp}/drill-src-XXXXXX")
trap 'rm -rf "$src"' EXIT
git archive "$DRILL_OPERATOR_REV" | tar -x -C "$src" || die "git archive $DRILL_OPERATOR_REV"
make -C "$src" docker-build IMG=controller:$TAG >>"$LOG" 2>&1 || die "operator image"
make -C "$src" docker-build-gpu-simulator GPU_SIMULATOR_IMG=gpu-simulator:$TAG >>"$LOG" 2>&1 || die "simulator image"
docker build -q -t "$IMG" "$src/experiments/distributed-restart" >>"$LOG" 2>&1 || die "trainer image"
echo "operator_rev=$rev" >"$DRILL_STATE/provenance.txt"

log "== cluster $CLUSTER"
mkdir -p "$DRILL_STATE/shared" && chmod 777 "$DRILL_STATE/shared"
cat >"$DRILL_STATE/kind-config.yaml" <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
  - role: worker
    extraMounts: [{hostPath: $DRILL_STATE/shared, containerPath: /shared}]
  - role: worker
    extraMounts: [{hostPath: $DRILL_STATE/shared, containerPath: /shared}]
EOF
kind create cluster --name "$CLUSTER" --image "$NODE_IMAGE" --config "$DRILL_STATE/kind-config.yaml" --wait 240s >>"$LOG" 2>&1 ||
  die "kind create (see $LOG)"
for img in controller:$TAG gpu-simulator:$TAG "$IMG"; do
  kind load docker-image "$img" --name "$CLUSTER" >>"$LOG" 2>&1 || die "kind load $img"
done
WORKERS="$CLUSTER-worker $CLUSTER-worker2"
for w in $WORKERS; do k label node "$w" drill.lkhun9311.github.io/gpu=true >>"$LOG" 2>&1 || die "label $w"; done

log "== cert-manager, Kueue, CRDs, operator"
k apply -f "https://github.com/cert-manager/cert-manager/releases/download/$CERT_MANAGER_VERSION/cert-manager.yaml" >>"$LOG" 2>&1 || die "cert-manager"
k -n cert-manager wait --for=condition=Available deploy --all --timeout=300s >>"$LOG" 2>&1 || die "cert-manager Available"
# The vendored Kueue without its EKS flavor, then the plain flavor every kind harness uses.
kubectl kustomize "$src/config/kueue-controller" >"$DRILL_STATE/kueue.yaml" || die "render kueue"
python3 -c '
import sys
docs = open(sys.argv[1]).read().split("\n---\n")
print("\n---\n".join(d for d in docs if "\nkind: ResourceFlavor\n" not in "\n" + d + "\n"))' "$DRILL_STATE/kueue.yaml" >"$DRILL_STATE/kueue-noflavor.yaml" || die "split flavor"
k apply --server-side -f "$DRILL_STATE/kueue-noflavor.yaml" >>"$LOG" 2>&1 || die "kueue"
k -n kueue-system wait --for=condition=Available deploy/kueue-controller-manager --timeout=300s >>"$LOG" 2>&1 || die "kueue Available"
apply_flavor() { k apply -f "$src/config/kueue/resourceflavor.yaml" >>"$LOG" 2>&1; }
retry apply_flavor || die "resource flavor"
kubectl kustomize "$src/config/crd" | k apply --server-side -f - >>"$LOG" 2>&1 || die "CRDs"
apply_operator() { kubectl kustomize "$src/config/operator-webhook" | k apply --server-side -f - >>"$LOG" 2>&1; }
retry apply_operator || die "operator"
OPDEP=$(k -n "$SYS" get deploy -o name | grep controller-manager | head -1)
[ -n "$OPDEP" ] || die "no controller-manager deployment"
k -n "$SYS" set image "$OPDEP" manager=controller:$TAG >>"$LOG" 2>&1 || die "operator image set"
# The fault path as the paid sessions run it, reading the simulator's fake exporter on each worker.
k -n "$SYS" patch "$OPDEP" --type=json -p '[
  {"op":"replace","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"IfNotPresent"},
  {"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--gpu-fault-source=dcgm"},
  {"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--gpu-fault-evict-workloads"},
  {"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--gpu-fault-exporter-selector=app.kubernetes.io/component=gpu-simulator"}]' >>"$LOG" 2>&1 ||
  die "operator flags"
pin='{"spec":{"template":{"spec":{"nodeSelector":{"node-role.kubernetes.io/control-plane":""},
  "tolerations":[{"key":"node-role.kubernetes.io/control-plane","operator":"Exists","effect":"NoSchedule"}]}}}}'
for dep in "$SYS/${OPDEP#*/}" kueue-system/kueue-controller-manager cert-manager/cert-manager \
  cert-manager/cert-manager-webhook cert-manager/cert-manager-cainjector kube-system/coredns; do
  retry k -n "${dep%%/*}" patch deploy "${dep#*/}" --type=strategic -p "$pin" >>"$LOG" 2>&1 || die "pin $dep"
  k -n "${dep%%/*}" rollout status deploy "${dep#*/}" --timeout=240s >>"$LOG" 2>&1 || die "rollout $dep"
done

log "== simulated GPUs and fake DCGM on the workers"
kubectl kustomize "$src/config/device-plugin" | k apply -f - >>"$LOG" 2>&1 || die "device plugin"
k -n "$SYS" patch ds/gpu-simulator --type=json -p "[
  {\"op\":\"add\",\"path\":\"/spec/template/spec/nodeSelector\",\"value\":{\"drill.lkhun9311.github.io/gpu\":\"true\"}},
  {\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/image\",\"value\":\"gpu-simulator:$TAG\"},
  {\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/imagePullPolicy\",\"value\":\"IfNotPresent\"}]" >>"$LOG" 2>&1 ||
  die "simulator placement"
k -n "$SYS" set env ds/gpu-simulator FAKE_GPU_COUNT=2 FAKE_DCGM_ADDR=:9400 >>"$LOG" 2>&1 || die "simulator env"
k -n "$SYS" patch ds/gpu-simulator --type=json -p '[{"op":"add","path":"/spec/template/spec/containers/0/env/-","value":{"name":"NODE_NAME","valueFrom":{"fieldRef":{"fieldPath":"spec.nodeName"}}}}]' >>"$LOG" 2>&1 ||
  die "simulator node name"
k -n "$SYS" rollout status ds/gpu-simulator --timeout=180s >>"$LOG" 2>&1 || die "simulator rollout"
gpus=""
for _ in $(seq 1 60); do
  gpus=$(k get nodes -l drill.lkhun9311.github.io/gpu=true -o jsonpath='{range .items[*]}{.status.allocatable.nvidia\.com/gpu}{" "}{end}')
  [ "$gpus" = "2 2 " ] && break
  sleep 3
done
[ "$gpus" = "2 2 " ] || die "workers do not each advertise two nvidia.com/gpu (allocatable: '$gpus')"

log "== tenant $NS, its quota and a shared volume"
apply_tenant() {
  cat <<EOF | k apply -f - >>"$LOG" 2>&1
apiVersion: v1
kind: Namespace
metadata: {name: $NS}
---
apiVersion: platform.lkhun9311.github.io/v1
kind: GPUQuotaPolicy
metadata: {name: $NS-quota}
spec:
  tenant: $NS
  targetNamespace: $NS
  limits: {gpuCount: 4}
  trainingQuota: true
---
apiVersion: v1
kind: PersistentVolume
metadata: {name: drill-shared}
spec:
  capacity: {storage: 1Gi}
  accessModes: ["ReadWriteMany"]
  storageClassName: ""
  hostPath: {path: /shared, type: Directory}
  claimRef: {namespace: $NS, name: shared}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: shared, namespace: $NS}
spec:
  accessModes: ["ReadWriteMany"]
  storageClassName: ""
  volumeName: drill-shared
  resources: {requests: {storage: 1Gi}}
EOF
}
retry apply_tenant || die "tenant"
for w in $WORKERS; do
  cat <<EOF | k apply -f - >>"$LOG" 2>&1 || die "nodehealth $w"
apiVersion: platform.lkhun9311.github.io/v1
kind: NodeHealth
metadata: {name: $w}
spec: {nodeName: $w}
EOF
done
ok=""
for _ in $(seq 1 80); do
  lq=$(k -n "$NS" get localqueue "gpu-$NS" -o name 2>>"$LOG")
  pvc=$(k -n "$NS" get pvc shared -o jsonpath='{.status.phase}' 2>>"$LOG")
  healthy=$(k get nodehealths -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="GPUHealthy")].status}{" "}{end}' 2>>"$LOG")
  if [ -n "$lq" ] && [ "$pvc" = Bound ] && [ "$healthy" = "True True " ]; then ok=1 && break; fi
  sleep 3
done
[ -n "$ok" ] || die "not ready: localqueue='$lq' pvc='$pvc' GPUHealthy='$healthy'"

{
  echo "context=$CONTEXT"
  echo "namespace=$NS"
  echo "queue=gpu-$NS"
  echo "trainer_image=$IMG"
  echo "workers=$WORKERS"
} >>"$DRILL_STATE/provenance.txt"
log "ready: kubectl --context $CONTEXT; operator $rev; state in $DRILL_STATE"
