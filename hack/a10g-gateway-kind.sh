#!/usr/bin/env bash
#
# Gateway processing latency on kind for the single-A10G study (issue #673), with a stub backend and no GPU.
#
#   bash hack/a10g-gateway-kind.sh            writes hack/a10g-gateway-kind/<UTC time>/
#
# The kit on the GPU runner has no Kubernetes, so the gateway cannot sit in front of the A10G there.
# This measures the gateway's own share instead: the same open-loop stages, at the rates the GPU contract's ladder spans,
# replayed through the gateway and straight at the stub, with identical arrivals, on one kind node.
# The two numbers are never added to the GPU's; the contract forbids calling the sum end-to-end GPU latency.
#
# Fixed for every stage, and recorded in settings.txt:
#   admission    the gateway runs with --admission-mode=off, and the InferenceDeployment asks for admission Off
#   rate limit   an explicit GPUQuotaPolicy rateLimit of 600,000 requests a minute with a 10,000 burst, far above any rate here
#   recorder     off: the gateway gets no --request-record-path, so no request is fsynced
#   gateway      the deployed config/gateway Deployment, its 500m CPU limit included
#   stub         stub://profile?tokens=128&ttft-ms=20&itl-ms=8, unlimited concurrency
#   workload     the contract's: 512-token prompt, 128 output tokens, greedy, Poisson arrivals, 60 s per stage
#
# The cluster is its own (a10g-gw, host ports 30280 and 30281), created fresh and deleted at the end.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
if [ -f go.mod ]; then export GOTOOLCHAIN="go$(awk '/^go [0-9]/{print $2}' go.mod)"; fi

CLUSTER=a10g-gw
KCTX=kind-$CLUSTER
NS=gpu-platform-control-plane-system
SERVING_NS=serving
TAG=a10g-gw
GW_PORT=30280
STUB_PORT=30281
MODEL=qwen2.5-3b-instruct
# The CR names a Service, which cannot hold the dots in the model's name; the gateway resolves by spec.model.name.
NAME=qwen-a10g
TENANT=a10g
KEY=a10g-key
RATES="3 8 16 28 42"
STAGE_S=60
CONTRACT=experiments/a10g-capacity/kit/contract.json
REC=hack/a10g-gateway-kind/$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p "$REC" || exit 1
LOG=$REC/log.txt
WORK=$(mktemp -d)
CR=$WORK/capacityrun

log()  { echo -e "$*" | tee -a "$LOG"; }
step() { echo -e "\n===== $* =====" | tee -a "$LOG"; }
run()  { echo "+ $*" | tee -a "$LOG"; "$@" >>"$LOG" 2>&1; }
k() { kubectl --context "$KCTX" "$@"; }
teardown() {
  rm -rf "$WORK"
  if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then run kind delete cluster --name "$CLUSTER"; fi
}
# The cluster is deleted on failure too, so what explains the failure is copied into the record first.
die() {
  log "FAILED at: $*"
  if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
    { k -n "$NS" logs deploy/gateway --tail=100; k get pods -A -o wide; k -n "$SERVING_NS" get svc,endpoints,inferencedeployment -o wide; } > "$REC/failure-cluster.txt" 2>&1
  fi
  [ -f "$WORK/smoke.txt" ] && cp "$WORK/smoke.txt" "$REC/failure-smoke-body.txt"
  teardown
  exit 1
}

step "0. preflight"
for tool in docker kind kubectl jq curl go; do command -v "$tool" >/dev/null || die "missing $tool"; done
[ -z "$(git status --porcelain -- cmd internal api config)" ] || die "uncommitted changes under cmd, internal, api or config; the measured gateway must be a commit"
{
  echo "commit=$(git rev-parse HEAD)"
  echo "cluster=$CLUSTER (one node, experiments/a10g-capacity/gateway/kind-config.yaml)"
  echo "admission=off (gateway flag) and Off (InferenceDeployment spec.admission.mode)"
  echo "rate_limit=GPUQuotaPolicy rateLimit requestsPerMinute=600000 burst=10000"
  echo "recorder=off (no --request-record-path)"
  echo "stub=stub://profile?tokens=128&ttft-ms=20&itl-ms=8"
  echo "rates=$RATES stage_s=$STAGE_S contract=$(sha256sum "$CONTRACT" | cut -d' ' -f1)"
  echo "host=$(nproc) CPUs, $(free -g | awk '/^Mem:/{print $2}') GiB; docker $(docker version --format '{{.Server.Version}}'); kind $(kind version)"
} > "$REC/settings.txt"
cat "$REC/settings.txt" | tee -a "$LOG"

step "1. build capacityrun"
run go build -o "$CR" ./cmd/capacityrun || die "build capacityrun"

step "2. create the kind cluster"
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then run kind delete cluster --name "$CLUSTER"; fi
run kind create cluster --name "$CLUSTER" --config experiments/a10g-capacity/gateway/kind-config.yaml || die "kind create"

step "3. install Kueue v0.18.3 (the operator's caches need its CRDs)"
k apply --server-side -f https://github.com/kubernetes-sigs/kueue/releases/download/v0.18.3/manifests.yaml >>"$LOG" 2>&1 || die "kueue apply"
k -n kueue-system wait --for=condition=Available deploy/kueue-controller-manager --timeout=300s >>"$LOG" 2>&1 || die "kueue not Available"

step "4. build and load images (tag $TAG, so no other session's :latest is used)"
run make docker-build IMG=controller:$TAG || die "operator image"
run make docker-build-gateway GATEWAY_IMG=gateway:$TAG || die "gateway image"
run make docker-build-benchharness BENCHHARNESS_IMG=benchharness:$TAG || die "benchharness image"
for i in controller gateway benchharness; do run kind load docker-image "$i:$TAG" --name "$CLUSTER" || die "kind load $i"; done
docker image inspect --format '{{.Id}}' gateway:$TAG > "$REC/gateway-image-id.txt"

step "5. CRDs and the operator"
kubectl kustomize config/crd | k apply --server-side -f - >>"$LOG" 2>&1 || die "CRDs"
k create namespace "$NS" --dry-run=client -o yaml | k apply -f - >>"$LOG" 2>&1
kubectl kustomize config/operator | k apply --server-side -f - >>"$LOG" 2>&1 || die "operator"
DEP=$(k -n "$NS" get deploy -o name | grep controller-manager | head -1)
k -n "$NS" set image "$DEP" manager=controller:$TAG >>"$LOG" 2>&1 || die "operator image"
k -n "$NS" rollout status "$DEP" --timeout=180s >>"$LOG" 2>&1 || die "operator rollout"

step "6. the gateway, admission off and no recorder"
kubectl kustomize config/gateway | k apply --server-side -f - >>"$LOG" 2>&1 || die "gateway"
k -n "$NS" create secret generic gateway-api-keys --from-literal="$KEY=$TENANT" >>"$LOG" 2>&1 || die "api keys"
k -n "$NS" set image deploy/gateway gateway=gateway:$TAG >>"$LOG" 2>&1 || die "gateway image"
k -n "$NS" patch deploy/gateway --type=json \
  -p '[{"op":"add","path":"/spec/template/spec/containers/0/args","value":["--admission-mode=off"]}]' >>"$LOG" 2>&1 || die "gateway args"
k -n "$NS" rollout status deploy/gateway --timeout=180s >>"$LOG" 2>&1 || die "gateway rollout"
k -n "$NS" get deploy/gateway -o jsonpath='{.spec.template.spec.containers[0].args}{"\n"}{.spec.template.spec.containers[0].resources}{"\n"}' | tee -a "$LOG" > "$REC/gateway-container.txt"

step "7. the tenant's policy with an explicit rate limit, and the stub"
run k apply -f config/kueue/resourceflavor.yaml || die "resourceflavor"
k create namespace "$SERVING_NS" --dry-run=client -o yaml | k apply -f - >>"$LOG" 2>&1
cat <<EOF | k apply -f - >>"$LOG" 2>&1 || die "policy"
apiVersion: platform.lkhun9311.github.io/v1
kind: GPUQuotaPolicy
metadata:
  name: $TENANT-quota
spec:
  tenant: $TENANT
  targetNamespace: $SERVING_NS
  gpuClass: l40s
  limits:
    gpuCount: 4
  trainingQuota: true
  rateLimit:
    requestsPerMinute: 600000
    burst: 10000
EOF
cat <<EOF | k apply -f - >>"$LOG" 2>&1 || die "stub InferenceDeployment"
apiVersion: platform.lkhun9311.github.io/v1
kind: InferenceDeployment
metadata:
  name: $NAME
  namespace: $SERVING_NS
spec:
  model:
    name: $MODEL
    storageUri: "stub://profile?tokens=128&ttft-ms=20&itl-ms=8"
  image: benchharness:$TAG
  gpuCount: 0
  replicas: 1
  port: 8090
  admission:
    mode: "Off"
EOF
for _ in $(seq 1 40); do k -n "$SERVING_NS" get deploy "$NAME" >/dev/null 2>&1 && break; sleep 3; done
k -n "$SERVING_NS" rollout status "deploy/$NAME" --timeout=180s >>"$LOG" 2>&1 || die "stub rollout"
cat <<EOF | k apply -f - >>"$LOG" 2>&1 || die "evidence services"
apiVersion: v1
kind: Service
metadata: {name: gateway-evidence, namespace: $NS}
spec:
  type: NodePort
  selector: {app.kubernetes.io/name: gpu-platform-control-plane, app.kubernetes.io/component: gateway}
  ports: [{name: http, port: 8080, targetPort: http, nodePort: $GW_PORT}]
---
apiVersion: v1
kind: Service
metadata: {name: stub-evidence, namespace: $SERVING_NS}
spec:
  type: NodePort
  selector: {app.kubernetes.io/instance: $NAME}
  ports: [{name: http, port: 8090, targetPort: http, nodePort: $STUB_PORT}]
EOF
k get pods -A -o wide >> "$LOG" 2>&1

step "8. smoke: one request each way"
for target in "http://127.0.0.1:$GW_PORT" "http://127.0.0.1:$STUB_PORT"; do
  code=""
  for _ in $(seq 1 40); do
    code=$(curl -sS --max-time 10 -o "$WORK/smoke.txt" -w '%{http_code}' -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
      -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":2,\"stream\":true}" "$target/v1/chat/completions" 2>>"$LOG")
    [ "$code" = 200 ] && break
    sleep 3
  done
  log "smoke $target: $code"
  [ "$code" = 200 ] || die "smoke $target"
done

step "9. the stages, arms alternating in order by rate"
i=0
for r in $RATES; do
  seed=$(( 6760 + i ))
  if [ $(( i % 2 )) = 0 ]; then order="gw direct"; else order="direct gw"; fi
  for arm in $order; do
    if [ "$arm" = gw ]; then t="http://127.0.0.1:$GW_PORT"; else t="http://127.0.0.1:$STUB_PORT"; fi
    "$CR" stage --contract "$CONTRACT" --segments "kind:$r:$STAGE_S" --seed "$seed" --target "$t" --api-key "$KEY" \
      --out "$REC/$arm-$r" --request-id-prefix "$arm-$r" 2>&1 | tee -a "$LOG" || die "stage $arm $r"
    sleep 5
  done
  i=$(( i + 1 ))
done
k -n "$NS" logs deploy/gateway --tail=200 > "$REC/gateway.log" 2>&1
k -n "$NS" get deploy/gateway -o yaml > "$REC/gateway-deployment.yaml" 2>&1

step "10. latency"
python3 experiments/a10g-capacity/gateway/latency.py "$REC" | tee -a "$LOG" || die "latency"
# The raw rows are kept compressed; the summary and the logs stay readable.
for d in "$REC"/gw-* "$REC"/direct-*; do gzip -9 "$d/raw.jsonl" "$d/raw.live.jsonl" "$d/trace.jsonl"; done
( cd "$REC" && find . -type f ! -name SHA256SUMS | LC_ALL=C sort | xargs -d '\n' sha256sum > SHA256SUMS )
teardown
log "record: $REC"
