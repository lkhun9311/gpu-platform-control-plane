#!/usr/bin/env bash
# Rehearses the hold-cap product transfer study's runner on a throwaway kind cluster, against a stub engine.
#
#   hack/eks-serve/holdcap-study/rehearse-kind.sh            # build, run all six cells, score, delete the cluster
#   hack/eks-serve/holdcap-study/rehearse-kind.sh set-arm A  # used by run.sh during a rehearsal; not for operators
#
# What it exercises: the two tenants on one backend under three ResourceQuotas, the gateway's real per-backend
# HoldCap path (serial-prefill and priority binding) and its Off path, engine replacement, the collector replaying
# the full frozen traces, metrics read by Pod IP, export, hashing, and the scorer.
# What it fakes, and so does not exercise: the controller-rendered engine and the status gate. The CRD pins the vLLM
# image, which cannot run here, so the operator renders the engine's Deployment and is then stopped; the Deployment
# is pointed at `benchharness stub-serve`, and status.admission is written by this script. That gate was shown on an
# A10G (hack/holdcap-conformance/runs/20261011T030610Z/README.md) and is covered by envtest.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
CLUSTER=hcstudy
CONTEXT=kind-$CLUSTER
SYS=gpu-platform-control-plane-system
SERVE_NS=serve-a
SERVE_INFD=qwen25-3b-holdcap
TAG=hcstudy
KUEUE_VERSION=v0.18.3
# Representative of the A10G's shape, not of its numbers: a first token after 80 ms and a token every 20 ms.
STUB_ARGS='--port=8000 --metrics --tokens-from-request --ttft-ms=80 --itl-ms=20'

k() { kubectl --context "$CONTEXT" --request-timeout=30s "$@"; }

engine_deploy() { k -n "$SERVE_NS" get deploy -l "app.kubernetes.io/instance=$SERVE_INFD" -o jsonpath='{.items[0].metadata.name}'; }

# set_arm points the stub at the arm and writes the status the stopped operator would have written.
set_arm() {
  local arm=$1 dep gen args before after
  dep="$(engine_deploy)"
  if [[ "$arm" == HoldCap ]]; then
    k -n "$SERVE_NS" patch inferencedeployment "$SERVE_INFD" --type merge -p '{"spec":{"admission":{"mode":"HoldCap","maxHold":"25s"}}}'
    args="$STUB_ARGS --long-prefill-token-threshold=384"
  else
    k -n "$SERVE_NS" patch inferencedeployment "$SERVE_INFD" --type merge -p '{"spec":{"admission":{"mode":"Off","maxHold":null}}}'
    args="$STUB_ARGS"
  fi
  before="$(k -n "$SERVE_NS" get deploy "$dep" -o jsonpath='{.spec.template.spec.containers[0].args}')"
  k -n "$SERVE_NS" patch deploy "$dep" --type json -p "$(python3 -c '
import json, sys
print(json.dumps([{"op": "replace", "path": "/spec/template/spec/containers/0/args", "value": sys.argv[1].split()}]))' "$args")"
  after="$(k -n "$SERVE_NS" get deploy "$dep" -o jsonpath='{.spec.template.spec.containers[0].args}')"
  # The same arm twice changes no template, so the Pod is deleted to give the cell a fresh engine.
  if [[ "$before" == "$after" ]]; then
    k -n "$SERVE_NS" delete pod -l "app.kubernetes.io/instance=$SERVE_INFD" --wait=false
  fi
  gen="$(k -n "$SERVE_NS" get inferencedeployment "$SERVE_INFD" -o jsonpath='{.metadata.generation}')"
  write_status "$arm" "$gen"
}

# write_status writes what the stopped operator would: the admission in force and, since #365, the EngineInForce
# condition the gateway binds a tier on. A merge patch replaces the conditions list whole, which a stub does not mind.
write_status() {
  local arm=$1 gen=$2 now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  k -n "$SERVE_NS" patch inferencedeployment "$SERVE_INFD" --subresource=status --type merge -p "{\"status\":{
    \"admission\":{\"mode\":\"$arm\",\"observedGeneration\":$gen},
    \"conditions\":[{\"type\":\"EngineInForce\",\"status\":\"True\",\"reason\":\"RenderedEngineInForce\",
      \"message\":\"written by the rehearsal for the stub engine\",\"observedGeneration\":$gen,\"lastTransitionTime\":\"$now\"}]}}"
}

if [[ "${1:-}" == set-arm ]]; then
  set_arm "$2"
  exit 0
fi

EXDIR="$REPO/hack/eks-serve/holdcap-study/rehearsal-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$EXDIR"
LOG="$EXDIR/rehearsal.log"
log() { printf '%s  %s\n' "$(date -u +%H:%M:%S)" "$*" | tee -a "$LOG"; }
die() {
  log "REHEARSAL FAILED at: $*"
  exit 1
}
cleanup() {
  [[ "${KEEP:-0}" == 1 ]] && { log "KEEP=1: leaving $CLUSTER"; return; }
  kind delete cluster --name "$CLUSTER" >>"$LOG" 2>&1 && log "deleted $CLUSTER" || log "could not delete $CLUSTER"
}
trap cleanup EXIT

export PATH="$REPO/bin:$PATH"
command -v kustomize >/dev/null || (cd "$REPO" && make kustomize >>"$LOG" 2>&1) || die "kustomize"
cd "$REPO"
log "images"
make docker-build IMG=controller:$TAG >>"$LOG" 2>&1 || die "operator image"
make docker-build-gateway GATEWAY_IMG=gateway:$TAG >>"$LOG" 2>&1 || die "gateway image"
make docker-build-gpu-simulator GPU_SIMULATOR_IMG=gpu-simulator:$TAG >>"$LOG" 2>&1 || die "simulator image"
make docker-build-benchharness BENCHHARNESS_IMG=benchharness:$TAG >>"$LOG" 2>&1 || die "stub image"

log "cluster"
grep -qx "$CLUSTER" <<<"$(kind get clusters 2>>"$LOG")" && { kind delete cluster --name "$CLUSTER" >>"$LOG" 2>&1 || die "delete old cluster"; }
kind create cluster --name "$CLUSTER" --config hack/kind-config.yaml >>"$LOG" 2>&1 || die "kind create"
for img in controller:$TAG gateway:$TAG gpu-simulator:$TAG benchharness:$TAG; do
  kind load docker-image "$img" --name "$CLUSTER" >>"$LOG" 2>&1 || die "load $img"
done
k apply --server-side -f "https://github.com/kubernetes-sigs/kueue/releases/download/$KUEUE_VERSION/manifests.yaml" >>"$LOG" 2>&1 || die "kueue"
k -n kueue-system wait --for=condition=Available deploy/kueue-controller-manager --timeout=300s >>"$LOG" 2>&1 || die "kueue Available"
kustomize build config/crd | k apply --server-side -f - >>"$LOG" 2>&1 || die "CRDs"
for _ in $(seq 1 20); do kustomize build config/operator | k apply --server-side -f - >>"$LOG" 2>&1 && break; sleep 3; done
OP="$(k -n "$SYS" get deploy -o name | grep controller-manager | head -1)"
[[ -n "$OP" ]] || die "no operator Deployment"
k -n "$SYS" set image "$OP" manager=controller:$TAG >>"$LOG" 2>&1 || die "operator image"
k -n "$SYS" rollout status "$OP" --timeout=240s >>"$LOG" 2>&1 || die "operator rollout"
kustomize build config/device-plugin | k apply -f - >>"$LOG" 2>&1 || die "device plugin"
k -n "$SYS" set image ds/gpu-simulator "*=gpu-simulator:$TAG" >>"$LOG" 2>&1 || die "simulator image"
k -n "$SYS" patch ds/gpu-simulator --type=json \
  -p '[{"op":"add","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"IfNotPresent"}]' >>"$LOG" 2>&1 || die "simulator pull policy"
k -n "$SYS" set env ds/gpu-simulator FAKE_GPU_COUNT=1 >>"$LOG" 2>&1 || die "simulator count"
k -n "$SYS" rollout status ds/gpu-simulator --timeout=180s >>"$LOG" 2>&1 || die "simulator rollout"

log "gateway"
kustomize build config/gateway-kind | k apply -f - >>"$LOG" 2>&1 || die "gateway"
k -n "$SYS" set image deploy -l app.kubernetes.io/component=gateway "*=gateway:$TAG" >>"$LOG" 2>&1 || die "gateway image"
k -n "$SYS" create secret generic gateway-api-keys --from-literal=placeholder=nobody >>"$LOG" 2>&1 || die "key secret"
k -n "$SYS" rollout status deploy -l app.kubernetes.io/component=gateway --timeout=240s >>"$LOG" 2>&1 ||
  k -n "$SYS" rollout status "deploy/$(k -n "$SYS" get deploy -l app.kubernetes.io/component=gateway -o jsonpath='{.items[0].metadata.name}')" --timeout=240s >>"$LOG" 2>&1 ||
  die "gateway rollout"

log "serving bundle, rendered by the operator and then pointed at the stub"
k apply -f config/kueue/resourceflavor.yaml >>"$LOG" 2>&1 || true
for _ in $(seq 1 20); do k apply -k config/serving >>"$LOG" 2>&1 && break; sleep 3; done
for _ in $(seq 1 60); do [[ -n "$(engine_deploy 2>/dev/null)" ]] && break; sleep 2; done
DEP="$(engine_deploy)"
[[ -n "$DEP" ]] || die "the operator rendered no engine Deployment"
# The study's tenants go in while the operator still runs, because their ResourceQuotas are its to create; once
# created, the API server enforces them with the operator stopped. run.sh applies the same file again, unchanged.
k apply -f "$HERE/tenants.yaml" >>"$LOG" 2>&1 || die "tenants"
for _ in $(seq 1 60); do
  n="$(k -n "$SERVE_NS" get resourcequota -o json | python3 -c 'import json,sys; print(sum(1 for q in json.load(sys.stdin)["items"] if "requests.nvidia.com/gpu" in (q.get("status",{}).get("hard") or {})))')"
  [[ "$n" -ge 3 ]] && break
  sleep 3
done
[[ "$n" -ge 3 ]] || die "the operator did not create the study's two ResourceQuotas ($n with a GPU limit)"
k -n "$SYS" scale "$OP" --replicas=0 >>"$LOG" 2>&1 || die "stop the operator"
k -n "$SYS" wait --for=delete pod -l control-plane=controller-manager --timeout=120s >>"$LOG" 2>&1 || true
k -n "$SERVE_NS" get deploy "$DEP" -o yaml >"$EXDIR/engine-deployment-as-rendered.yaml"
k -n "$SERVE_NS" patch deploy "$DEP" --type json -p "$(python3 -c '
import json, sys
print(json.dumps([
    {"op": "replace", "path": "/spec/template/spec/containers/0/image", "value": "benchharness:" + sys.argv[1]},
    {"op": "replace", "path": "/spec/template/spec/containers/0/imagePullPolicy", "value": "IfNotPresent"},
    {"op": "replace", "path": "/spec/template/spec/containers/0/command", "value": ["/benchharness", "stub-serve"]},
    {"op": "replace", "path": "/spec/template/spec/containers/0/args", "value": sys.argv[2].split() + ["--long-prefill-token-threshold=384"]},
]))' "$TAG" "$STUB_ARGS")" >>"$LOG" 2>&1 || die "point the engine at the stub"
# The rendered affinity asks for a g5 node marked for GPU work; one kind worker is labelled to be it.
W="$(k get nodes -o name | grep worker | head -1)"
k label "$W" node.kubernetes.io/instance-type=g5.xlarge platform.lkhun9311.github.io/gpu=true --overwrite >>"$LOG" 2>&1 || die "label worker"
gen="$(k -n "$SERVE_NS" get inferencedeployment "$SERVE_INFD" -o jsonpath='{.metadata.generation}')"
write_status HoldCap "$gen" >>"$LOG" 2>&1 || die "status"
k -n "$SERVE_NS" rollout status "deploy/$DEP" --timeout=240s >>"$LOG" 2>&1 || die "stub engine rollout"

log "runner"
export CONTEXT EXDIR STUDY_REHEARSAL=1 STUDY_DEADLINE=$(($(date +%s) + 4 * 3600)) WAIT_ENGINE=300
if ! "$HERE/run.sh"; then
  die "runner stopped: $(cat "$EXDIR/holdcap-study/STOPPED" 2>/dev/null || echo 'no reason recorded')"
fi
log "runner finished"
# The rehearsal passes only when the runner finished and the scorer produced a verdict at all; which verdict a stub
# earns is not the point, but no verdict means the evidence could not be read.
verdict="$(head -1 "$EXDIR/holdcap-study/verdict.txt" 2>/dev/null || true)"
[[ "$verdict" == verdict:* ]] || die "the scorer produced no verdict"
log "$verdict"
