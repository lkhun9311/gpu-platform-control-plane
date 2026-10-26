#!/usr/bin/env bash
# Rehearses experiment A's runner on a throwaway kind cluster, kind-prefixroute, against two stub engines that model a
# prefix cache.
#
#   hack/eks-serve/prefix-route-study/rehearse-kind.sh               # build, run all twelve cells, score, delete the cluster
#   hack/eks-serve/prefix-route-study/rehearse-kind.sh write-status  # used by run.sh during a rehearsal; not for operators
#
# What it exercises: the gateway's real routing policies set through each InferenceDeployment's spec, fresh engines
# and a fresh gateway every cell, warm-up by Pod IP, the collector replaying the four frozen traces in full, metrics
# read by Pod IP, export, hashing, and the scorer on the result.
# What it fakes, and so does not exercise: the controller-rendered vLLM engine and its status. The CRD pins the vLLM
# image, which cannot run here, so the operator renders both engines and is then stopped; each Deployment is pointed
# at `benchharness stub-serve --enable-prefix-caching`, and EngineInForce is written by this script.
# The stubs model a cache of 513,000 of their own tokens, about two thirds of the 77 prompts, which is where the
# A10G's measured 393,232 real tokens put the engine (design page, "Load"); the scorer is told so, and says so.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
CLUSTER=prefixroute
CONTEXT=kind-$CLUSTER
SYS=gpu-platform-control-plane-system
NS=prefix-route
TAG=prefixroute
KUEUE_VERSION=v0.18.3
# The stub's cache counts 16 tokens per 64 characters, so a 41,000-character request is 10,240 of its tokens and the
# 77 prompts are about 770,000; 513,000 holds two thirds of them, the ratio the engine's capacity gives the real prompts.
# Its prefill is 130 µs a token, so a full miss takes about 1.3 s, near the 1.35 s Finding 9 measured for 7,695 tokens.
STUB_KV=513000
STUB_ARGS="--port=8000 --metrics --tokens-from-request --ttft-ms=20 --itl-ms=5 --enable-prefix-caching --stub-kv-capacity-tokens=$STUB_KV --stub-prefill-us-per-token=130 --stub-serial-prefill"

k() { kubectl --context "$CONTEXT" --request-timeout=30s "$@"; }

# write_status writes what the stopped operator would: EngineInForce True for each engine's current generation.
write_status() {
  local e gen now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  for e in qwen-a qwen-b; do
    gen="$(k -n "$NS" get inferencedeployment "$e" -o jsonpath='{.metadata.generation}')"
    k -n "$NS" patch inferencedeployment "$e" --subresource=status --type merge -p "{\"status\":{
      \"conditions\":[{\"type\":\"EngineInForce\",\"status\":\"True\",\"reason\":\"RenderedEngineInForce\",
        \"message\":\"written by the rehearsal for the stub engine\",\"observedGeneration\":$gen,\"lastTransitionTime\":\"$now\"}]}}"
  done
}

if [[ "${1:-}" == write-status ]]; then
  write_status
  exit 0
fi

EXDIR="${EXDIR:-$REPO/hack/eks-serve/prefix-route-study/rehearsal-$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$EXDIR"
LOG="$EXDIR/rehearsal.log"
log() { printf '%s  %s\n' "$(date -u +%H:%M:%S)" "$*" | tee -a "$LOG"; }
die() {
  log "REHEARSAL FAILED at: $*"
  exit 1
}
cleanup() {
  [[ "${KEEP:-0}" == 1 ]] && { log "KEEP=1: leaving $CLUSTER"; return; }
  if kind delete cluster --name "$CLUSTER" >>"$LOG" 2>&1; then log "deleted $CLUSTER"; else log "could not delete $CLUSTER"; fi
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
GW_DEP="$(k -n "$SYS" get deploy -l app.kubernetes.io/component=gateway -o jsonpath='{.items[0].metadata.name}')"
k -n "$SYS" rollout status "deploy/$GW_DEP" --timeout=240s >>"$LOG" 2>&1 || die "gateway rollout"

log "study objects, rendered by the operator and then pointed at the stub"
k apply -f config/kueue/resourceflavor.yaml >>"$LOG" 2>&1 || true
for _ in $(seq 1 20); do k apply -f "$HERE/study.yaml" >>"$LOG" 2>&1 && break; sleep 3; done
for e in qwen-a qwen-b; do
  sed "s/NAME/$e/" "$HERE/engine.yaml.tmpl" | k apply -f - >>"$LOG" 2>&1 || die "create $e"
  sleep 2
done
for e in qwen-a qwen-b; do
  for _ in $(seq 1 60); do [[ -n "$(k -n "$NS" get deploy -l "app.kubernetes.io/instance=$e" -o name 2>>"$LOG")" ]] && break; sleep 2; done
  [[ -n "$(k -n "$NS" get deploy -l "app.kubernetes.io/instance=$e" -o name)" ]] || die "the operator rendered no Deployment for $e"
done
for _ in $(seq 1 60); do
  n="$(k -n "$NS" get resourcequota -o json | python3 -c 'import json,sys; print(sum(1 for q in json.load(sys.stdin)["items"] if "requests.nvidia.com/gpu" in (q.get("status",{}).get("hard") or {})))')"
  [[ "$n" -ge 1 ]] && break
  sleep 3
done
[[ "$n" -ge 1 ]] || die "the operator created no GPU ResourceQuota in $NS"
k -n "$SYS" scale "$OP" --replicas=0 >>"$LOG" 2>&1 || die "stop the operator"
k -n "$SYS" wait --for=delete pod -l control-plane=controller-manager --timeout=120s >>"$LOG" 2>&1 || true
for e in qwen-a qwen-b; do
  dep="$(k -n "$NS" get deploy -l "app.kubernetes.io/instance=$e" -o jsonpath='{.items[0].metadata.name}')"
  k -n "$NS" get deploy "$dep" -o yaml >"$EXDIR/engine-$e-as-rendered.yaml"
  k -n "$NS" patch deploy "$dep" --type json -p "$(python3 -c '
import json, sys
print(json.dumps([
    {"op": "replace", "path": "/spec/template/spec/containers/0/image", "value": "benchharness:" + sys.argv[1]},
    {"op": "replace", "path": "/spec/template/spec/containers/0/imagePullPolicy", "value": "IfNotPresent"},
    {"op": "replace", "path": "/spec/template/spec/containers/0/command", "value": ["/benchharness", "stub-serve"]},
    {"op": "replace", "path": "/spec/template/spec/containers/0/args", "value": sys.argv[2].split()},
]))' "$TAG" "$STUB_ARGS")" >>"$LOG" 2>&1 || die "point $e at the stub"
done
# The rendered affinity asks for a g5 node marked for GPU work; both workers are made one only now, after the stubs replaced
# the rendered template. Labelled earlier, the rendered Pods start pulling the 9 GiB vLLM image, and a Pod mid-pull
# stays Terminating long past any rollout's wait (the first rehearsal failed exactly so).
for w in $(k get nodes -o name | grep worker); do
  k label "$w" node.kubernetes.io/instance-type=g5.xlarge platform.lkhun9311.github.io/gpu=true --overwrite >>"$LOG" 2>&1 || die "label $w"
done
write_status >>"$LOG" 2>&1 || die "status"
for e in qwen-a qwen-b; do
  k -n "$NS" rollout status "deploy/$(k -n "$NS" get deploy -l "app.kubernetes.io/instance=$e" -o jsonpath='{.items[0].metadata.name}')" --timeout=240s >>"$LOG" 2>&1 ||
    die "stub engine $e rollout"
done

log "runner"
export CONTEXT EXDIR STUDY_REHEARSAL=1 STUDY_DEADLINE=$(($(date +%s) + 6 * 3600)) WAIT_ENGINE=300 SCORE_ARGS="--capacity-tokens $STUB_KV"
if ! "$HERE/run.sh"; then
  die "runner stopped: $(cat "$EXDIR/prefix-route-study/STOPPED" 2>/dev/null || echo 'no reason recorded')"
fi
log "runner finished"
verdict="$(head -1 "$EXDIR/prefix-route-study/verdict.txt" 2>/dev/null || true)"
[[ "$verdict" == verdict:* ]] || die "the scorer produced no verdict"
log "$verdict"
