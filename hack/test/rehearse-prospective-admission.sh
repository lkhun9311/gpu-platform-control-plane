#!/usr/bin/env bash
#
# Runs the gateway's prospective admission and priority binding on a kind cluster, against a slow stub engine.
#
# WHY THIS EXISTS
#
# docs/superpowers/specs/2026-10-06-m5b-stays-closed-and-what-a-successor-needs-first.md asks for M5-b's
# successor mechanisms to be shown correct on kind before anything about them is registered or bought. The
# unit and pipeline specs run them inside one test process against httptest servers. What they cannot show is
# the real binary with its real flags, routing through an InferenceDeployment to a Service, and the holds
# keyed by the backend URL the router actually builds. That is what this runs.
#
# WHAT IT ASSERTS, each from evidence the cluster produces
#
#   * Of four standard requests sent at once against a stream cap of two, exactly two are served and two are
#     refused with standard_streams_full.
#   * Premium requests sent while the standard tier is full are all served.
#   * While the admitted standard requests wait for their first token, the gateway's gauges show their input
#     reserved and two streams held. After the first token the input is released and the streams are still
#     held. After they finish, both are zero.
#   * The engine received priority 0 on every premium request and 1 on every admitted standard one, and never
#     a request without a priority.
#
# WHAT IT CANNOT SAY
#
# Anything about protection. A stub's latency is its configuration, so no number here is a TTFT or a tail.
# The timing checks use margins of seconds around a stub configured to wait seconds, and they are about the
# order of events, not their durations.
#
# NOT IN A CI GATE, for the reason Makefile's harness-check gives for the other rehearsals: it builds a kind
# cluster. Run it by hand.
set -euo pipefail
cd "$(dirname "$0")/../.." || exit 1

CLUSTER="${CLUSTER:-prospective-rehearse}"
KCTX="kind-$CLUSTER"
NS="${NS:-prospective}"
MODEL="Qwen/Qwen2.5-3B-Instruct"
GW_IMAGE="${GW_IMAGE:-gateway:prospective-rehearse}"
STUB_IMAGE="${STUB_IMAGE:-benchstub:prospective-rehearse}"
SIM_IMAGE="${SIM_IMAGE:-gpu-simulator:latest}"
OPERATOR_NS="gpu-platform-control-plane-system"
KEEP="${KEEP:-0}"
WORK="$(mktemp -d)"
# The stub waits TTFT_MS before its first token and ITL_MS between tokens, so a request holds its stream for
# about TTFT_MS + (TOKENS-1) * ITL_MS. The checks below are placed well inside those windows.
TTFT_MS=6000
ITL_MS=5000
TOKENS=3
pass=0

say()  { printf '== %s\n' "$*"; }
ok()   { printf '  ok    %s\n' "$*"; pass=$((pass+1)); }
fail() { printf 'REHEARSAL FAILED: %s\n' "$*" >&2; exit 1; }
k() { kubectl --context "$KCTX" "$@"; }

for b in kind kubectl docker go curl; do
  command -v "$b" >/dev/null || fail "$b is not on PATH"
done
docker info >/dev/null 2>&1 || fail "the docker daemon is not reachable"

PIDS=()
cleanup() {
  for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
  if [ "$KEEP" = "1" ]; then
    say "KEEP=1: leaving cluster $CLUSTER up. Delete it with: kind delete cluster --name $CLUSTER"
  else
    kind delete cluster --name "$CLUSTER" >/dev/null 2>&1 || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

say "cluster $CLUSTER"
kind delete cluster --name "$CLUSTER" >/dev/null 2>&1 || true
kind create cluster --name "$CLUSTER" --wait 120s >/dev/null || fail "kind create cluster"
kubectl kustomize config/crd | k apply -f - >/dev/null || fail "apply the CRDs"

# The gateway's RBAC through its overlay, exactly as hack/test/rehearse-m5c-deploy.sh does and for its reasons.
k create ns "$OPERATOR_NS" --dry-run=client -o yaml | k apply -f - >/dev/null
kubectl kustomize config/gateway > "$WORK/gateway-all.yaml" || fail "render config/gateway"
awk 'BEGIN{RS="\n---\n"} /(^|\n)kind: (ClusterRole|ClusterRoleBinding|Role|RoleBinding|ServiceAccount)(\n|$)/ {print "---"; print $0}' \
  "$WORK/gateway-all.yaml" > "$WORK/gateway-rbac.yaml"
grep -q "name: gateway-role" "$WORK/gateway-rbac.yaml" || fail "the RBAC filter kept no ClusterRole named gateway-role"
k apply -f "$WORK/gateway-rbac.yaml" >/dev/null || fail "apply the gateway RBAC"

say "build and side-load the gateway, the stub and the GPU simulator"
CGO_ENABLED=0 GOOS=linux go build -o "$WORK/gateway" ./cmd/gateway || fail "build gateway"
CGO_ENABLED=0 GOOS=linux go build -o "$WORK/benchharness" ./cmd/benchharness || fail "build benchharness"
printf 'FROM gcr.io/distroless/static:nonroot\nCOPY gateway /gateway\nUSER 65532:65532\nENTRYPOINT ["/gateway"]\n' > "$WORK/Dockerfile"
docker build -q -t "$GW_IMAGE" "$WORK" >/dev/null || fail "build the gateway image"
printf 'FROM gcr.io/distroless/static:nonroot\nCOPY benchharness /benchharness\nUSER 65532:65532\nENTRYPOINT ["/benchharness","stub-serve"]\n' > "$WORK/Dockerfile"
docker build -q -t "$STUB_IMAGE" "$WORK" >/dev/null || fail "build the stub image"
docker build -q -t "$SIM_IMAGE" -f Dockerfile.gpu-simulator . >/dev/null || fail "build the gpu-simulator image"
for img in "$GW_IMAGE" "$STUB_IMAGE" "$SIM_IMAGE"; do
  kind load docker-image "$img" --name "$CLUSTER" >/dev/null || fail "kind load $img"
done

# The fake device plugin, because the stub engine asks for nvidia.com/gpu the way a real engine does.
kubectl kustomize config/device-plugin | k apply -f - >/dev/null || fail "apply the simulator device plugin"
k -n "$OPERATOR_NS" patch ds gpu-simulator --type=json \
  -p '[{"op":"add","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"IfNotPresent"}]' >/dev/null 2>&1 || true
k -n "$OPERATOR_NS" rollout status ds/gpu-simulator --timeout=180s >/dev/null || fail "the simulator device plugin never became ready"
adv=0
for _ in $(seq 1 30); do
  adv=$(k get nodes -o jsonpath='{.items[0].status.allocatable.nvidia\.com/gpu}' 2>/dev/null)
  [ "${adv:-0}" -ge 1 ] 2>/dev/null && break
  sleep 2
done
[ "${adv:-0}" -ge 1 ] || fail "the node advertises ${adv:-0} nvidia.com/gpu"

say "one slow stub engine that both tenants share"
k create ns "$NS" >/dev/null
k apply -f - >/dev/null <<EOF || fail "stub engine"
apiVersion: apps/v1
kind: Deployment
metadata: {name: vllm-shared, namespace: $NS}
spec:
  replicas: 1
  selector: {matchLabels: {engine: vllm-shared}}
  template:
    metadata:
      labels: {engine: vllm-shared}
    spec:
      containers:
        - name: stub
          image: $STUB_IMAGE
          imagePullPolicy: IfNotPresent
          args: ["--addr=:8000", "--ttft-ms=$TTFT_MS", "--itl-ms=$ITL_MS", "--tokens=$TOKENS"]
          ports: [{containerPort: 8000, name: http}]
          resources: {limits: {nvidia.com/gpu: 1}}
---
apiVersion: v1
kind: Service
metadata: {name: vllm-shared, namespace: $NS}
spec:
  selector: {engine: vllm-shared}
  ports: [{name: http, port: 8000, targetPort: http}]
---
apiVersion: platform.lkhun9311.github.io/v1
kind: InferenceDeployment
metadata: {name: vllm-shared, namespace: $NS}
spec:
  model: {name: $MODEL, storageUri: "hf://$MODEL"}
  image: registry.k8s.io/pause:3.9
  gpuCount: 0
  replicas: 0
  port: 8000
---
apiVersion: platform.lkhun9311.github.io/v1
kind: GPUQuotaPolicy
metadata:
  name: prospective-premium
  annotations: {platform.lkhun9311.github.io/tier: premium}
spec: {tenant: premium-1, targetNamespace: $NS, gpuClass: a10g, limits: {gpuCount: 1}, rateLimit: {requestsPerMinute: 6000, burst: 100}}
---
apiVersion: platform.lkhun9311.github.io/v1
kind: GPUQuotaPolicy
metadata: {name: prospective-standard}
spec: {tenant: standard-1, targetNamespace: $NS, gpuClass: a10g, limits: {gpuCount: 1}, rateLimit: {requestsPerMinute: 6000, burst: 100}}
EOF
k rollout status deploy/vllm-shared -n "$NS" --timeout=180s >/dev/null || fail "the stub engine never became ready"

k create secret generic gateway-api-keys -n "$NS" \
  --from-literal=premium-key=premium-1 --from-literal=standard-key=standard-1 \
  --dry-run=client -o yaml | k apply -f - >/dev/null
k create serviceaccount gateway -n "$NS" --dry-run=client -o yaml | k apply -f - >/dev/null
k create clusterrolebinding prospective-rehearse-gateway --clusterrole=gateway-role \
  --serviceaccount="$NS:gateway" --dry-run=client -o yaml | k apply -f - >/dev/null
k apply -f - >/dev/null <<EOF || fail "secret-reader role"
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: {name: gateway-secret-reader, namespace: $NS}
rules: [{apiGroups: [""], resources: ["secrets"], verbs: ["get","list","watch"]}]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: {name: gateway-secret-reader, namespace: $NS}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: Role, name: gateway-secret-reader}
subjects: [{kind: ServiceAccount, name: gateway, namespace: $NS}]
EOF

say "gateway: prospective admission, two standard streams, priority bound to tier"
k apply -f - >/dev/null <<EOF || fail "gateway"
apiVersion: apps/v1
kind: Deployment
metadata: {name: gateway, namespace: $NS}
spec:
  replicas: 1
  selector: {matchLabels: {app: gateway}}
  template:
    metadata:
      labels: {app: gateway}
    spec:
      serviceAccountName: gateway
      containers:
        - name: gateway
          image: $GW_IMAGE
          imagePullPolicy: IfNotPresent
          args: ["-admission-mode=prospective", "-admission-prospective-prefill-tokens=100000",
                 "-admission-prospective-streams=2", "-bind-priority"]
          env:
            - {name: GATEWAY_NAMESPACE, value: $NS}
            - {name: GATEWAY_API_KEY_SECRET, value: gateway-api-keys}
          ports: [{containerPort: 8080, name: http}, {containerPort: 8081, name: metrics}]
EOF
k rollout status deploy/gateway -n "$NS" --timeout=180s >/dev/null \
  || fail "the gateway never became ready: $(k logs -n "$NS" deploy/gateway --tail=20 2>&1)"

k port-forward -n "$NS" deploy/gateway 18080:8080 18081:8081 >"$WORK/pf-gw" 2>&1 &
PIDS+=($!)
k port-forward -n "$NS" deploy/vllm-shared 18090:8000 >"$WORK/pf-stub" 2>&1 &
PIDS+=($!)
sleep 3
curl -s --max-time 5 -o /dev/null http://127.0.0.1:18081/metrics || fail "the gateway's metrics port is not reachable"
curl -s --max-time 5 -o /dev/null http://127.0.0.1:18090/stats || fail "the stub's stats are not reachable"

send() {
  local key="$1" tag="$2"
  curl -s -o "$WORK/body-$tag" -D "$WORK/head-$tag" -w '%{http_code}' --max-time 60 \
    -X POST http://127.0.0.1:18080/v1/chat/completions \
    -H "Authorization: Bearer $key" -H 'Content-Type: application/json' \
    -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"hello there\"}],\"stream\":true}" \
    > "$WORK/code-$tag" 2>/dev/null || true
}
gauge() {
  curl -s --max-time 5 http://127.0.0.1:18081/metrics | awk -v m="$1" '$1 ~ "^"m"[{]" {s += $2} END {print s + 0}'
}

say "four standard requests at once, against a cap of two streams"
for i in 1 2 3 4; do send standard-key "s$i" & PIDS+=($!); done
sleep 2
held_tokens=$(gauge gpuaas_gateway_admission_reserved_input_tokens)
held_streams=$(gauge gpuaas_gateway_admission_running_standard_streams)
[ "$held_streams" = "2" ] && ok "two standard streams held while the stub has not answered" \
  || fail "the gateway reports $held_streams standard streams held, not 2"
[ "$held_tokens" -gt 0 ] 2>/dev/null && ok "their input is reserved ($held_tokens estimated tokens) before the first token" \
  || fail "no input is reserved before the first token ($held_tokens)"

say "two premium requests while the standard tier is full"
for i in 1 2; do send premium-key "p$i" & PIDS+=($!); done

# Past the first token (TTFT_MS, about 6 s) and well before the end (TTFT_MS + (TOKENS-1) * ITL_MS, about 16 s);
# two seconds have already passed above.
sleep $(( TTFT_MS / 1000 + 1 ))
held_tokens=$(gauge gpuaas_gateway_admission_reserved_input_tokens)
held_streams=$(gauge gpuaas_gateway_admission_running_standard_streams)
[ "$held_tokens" = "0" ] && ok "the input reservation was released once the first token reached the client" \
  || fail "$held_tokens estimated tokens still reserved after the first token"
[ "$held_streams" = "2" ] && ok "the two streams are still held until the requests end" \
  || fail "$held_streams standard streams held mid-stream, not 2"

wait_all() {
  for _ in $(seq 1 60); do
    n=0
    for f in "$WORK"/code-*; do [ -s "$f" ] && n=$((n+1)); done
    [ "$n" -ge 6 ] && return 0
    sleep 1
  done
  return 1
}
wait_all || fail "not every request finished"

say "outcomes"
served=0; refused=0
for i in 1 2 3 4; do
  c=$(cat "$WORK/code-s$i")
  if [ "$c" = "200" ]; then
    served=$((served+1))
  elif [ "$c" = "429" ] && grep -q standard_streams_full "$WORK/body-s$i"; then
    refused=$((refused+1))
  else
    fail "standard request s$i ended $c: $(head -c 200 "$WORK/body-s$i")"
  fi
done
[ "$served" = "2" ] && [ "$refused" = "2" ] && ok "standard: 2 served, 2 refused with standard_streams_full" \
  || fail "standard: $served served and $refused refused, not 2 and 2"
for i in 1 2; do
  c=$(cat "$WORK/code-p$i")
  [ "$c" = "200" ] || fail "premium request p$i ended $c while the standard tier was full"
  grep -qi '^x-engine-priority: 0' "$WORK/head-p$i" || fail "premium request p$i was not told it was forwarded at priority 0"
done
ok "premium: both served while the standard tier was full, each forwarded at priority 0"

held_tokens=$(gauge gpuaas_gateway_admission_reserved_input_tokens)
held_streams=$(gauge gpuaas_gateway_admission_running_standard_streams)
[ "$held_tokens" = "0" ] && [ "$held_streams" = "0" ] && ok "nothing is held once every request has ended" \
  || fail "after every request ended the gateway still holds $held_tokens tokens and $held_streams streams"

stats=$(curl -s --max-time 5 http://127.0.0.1:18090/stats)
by=$(printf '%s' "$stats" | sed -n 's/.*"requestsByPriority":\({[^}]*}\).*/\1/p')
[ "$by" = '{"0":2,"1":2}' ] && ok "the engine received priority 0 twice and 1 twice, and nothing unprioritised: $by" \
  || fail "the engine received $by, not {\"0\":2,\"1\":2}"

say "PASS: $pass checks"
