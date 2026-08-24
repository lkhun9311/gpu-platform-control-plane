#!/usr/bin/env bash
#
# The sharing matrix: does giving each tenant its own engine beat giving them one to share?
#
# That is the question, and it is the same mechanism M5-b measures seen from the other side. In the shared
# arm two tenants multiplex one vLLM, so they share a KV cache and the long-context tenant's occupancy is
# what costs the other one latency -- the pressure the admission guard exists to relieve. In the
# time-sliced arm each tenant gets its own engine with its own cache on half the card, so the KV coupling is
# gone and what remains is contention for the SMs. Neither is obviously better, which is why it is worth
# measuring rather than asserting.
#
#   shared        one engine, whole card, both tenants routed to it        (M5-b's topology)
#   timeSlicing   two engines, half card each, one tenant routed to each
#   mps           the same two engines, sharing through MPS instead
#
# MPS is not a third topology, it is a second mechanism for the same one, and the difference is worth
# stating because it is the reason both arms exist. Time-slicing interleaves kernels and does NOT partition
# memory -- the two engines draw on one pool and only convention keeps their utilizations summing below 1.
# MPS runs their kernels concurrently in one context AND caps each client's memory: the pinned control
# daemon issues set_default_device_pinned_mem_limit, read out of the binary rather than the documentation.
# So the arms differ in whether the tenants contend for SM time serially or concurrently, and in whether
# their memory ceiling is enforced or agreed.
#
# The routing is built from mechanisms this control plane already has: the gateway resolves a backend from
# the requesting tenant's GPUQuotaPolicy targetNamespace, so putting each engine in its own namespace and
# pointing one policy at each is all it takes. No new code, and the arm is a deployment difference rather
# than a code path.
#
# What this does NOT report is per-engine GPU utilisation. Under time-slicing a busy SM belongs to no single
# Pod and DCGM cannot attribute it -- config/nvidia-device-plugin/daemonset.yaml says so, and it is why the
# sharing node deliberately has no observer. The matrix reports what the CLIENTS measured, which is
# unambiguous and is also what a tenant actually experiences.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
export GOTOOLCHAIN=go1.26.0

KCTX="${KCTX:-$(kubectl config current-context 2>/dev/null)}"
NS_A="${NS_A:-m5c-a}"
NS_B="${NS_B:-m5c-b}"
MODEL="Qwen/Qwen2.5-3B-Instruct"
OUT="${OUT:-hack/m5c-run-$(date +%Y%m%d-%H%M%S)}"
LOG="$OUT/evidence.log"
GW_IMAGE="${GW_IMAGE:-gateway:m5c}"
REPS="${REPS:-2}"
# Which sharing mechanism the shared arm uses. Both are run in a full matrix; a session that only has time
# for one should say which rather than silently getting the default.
ARMS="${ARMS:-shared timeSlicing mps}"

k() { kubectl --context "$KCTX" "$@"; }
say() { echo "== $*" | tee -a "$LOG"; }
fail() { echo "MATRIX FAILED: $*" | tee -a "$LOG" >&2; exit 1; }

[ -n "${RATE:-}" ] || fail "RATE is unset. Measure it from a single contender prefill on THIS card, the way hack/m5b-gpu-session.sh does; the harness default of 20/s demands 3.8x an A10G's theoretical peak and would censor every arm."
[ -n "${REGISTRY:-}" ] || fail "REGISTRY is unset. EKS nodes cannot side-load an image, so the gateway must be pushed where they can pull it."

mkdir -p "$OUT" || fail "cannot create $OUT"
: > "$LOG"

WORK="$(mktemp -d)"
PF_PID=""
SCALED_UP=""
cleanup() {
  [ -n "$PF_PID" ] && kill "$PF_PID" 2>/dev/null
  k delete namespace "$NS_A" "$NS_B" --wait=false >/dev/null 2>&1
  k delete gpuquotapolicy m5c-premium m5c-standard >/dev/null 2>&1
  k delete clusterrolebinding m5c-gateway-role >/dev/null 2>&1
  rm -rf "$WORK"
  if [ -n "$SCALED_UP" ]; then
    echo
    echo "############################################################"
    echo "#  SCALE THE gpu_shared NODE GROUP BACK TO 0 NOW.          #"
    echo "############################################################"
  fi
}
trap cleanup EXIT INT TERM

say "preflight"
case "$KCTX" in kind-*) fail "context $KCTX is a kind cluster; this is the paid matrix" ;; esac

# The sharing node, and it must be the sharing one: the exclusive plugin advertises one device per card, so
# the second engine would sit Pending and the arm would silently become a one-engine arm with half the memory.
shared_nodes=$(k get nodes -l 'platform.lkhun9311.github.io/gpu-sharing=true' -o name 2>/dev/null | wc -l)
if [ "$shared_nodes" -eq 0 ]; then
  cat <<EOF

No sharing node. Scale gpu_shared up, then re-run:

    aws eks update-nodegroup-config --cluster-name <cluster> \\
      --nodegroup-name gpu_shared --scaling-config minSize=0,maxSize=1,desiredSize=1

EOF
  fail "no node carries platform.lkhun9311.github.io/gpu-sharing"
fi
SCALED_UP=1
[ "$shared_nodes" -eq 1 ] || fail "$shared_nodes sharing nodes are up; two engines on two nodes are not sharing a card, and nothing downstream could tell that apart from a sharing result"

# The two sharing overlays select the SAME node, so exactly one may be applied at a time: two plugins
# registering nvidia.com/gpu against one kubelet socket is not a configuration worth debugging on a rented
# card. Deleting the other one first is the mechanism; remembering is not.
apply_sharing_plugin() {
  local mode="$1" other keep
  case "$mode" in
    timeSlicing) keep=config/nvidia-device-plugin-timeslicing; other=config/nvidia-device-plugin-mps ;;
    mps)         keep=config/nvidia-device-plugin-mps;         other=config/nvidia-device-plugin-timeslicing ;;
    *) fail "apply_sharing_plugin: unknown mode $mode" ;;
  esac
  k delete -k "$other" --ignore-not-found --wait=true >/dev/null 2>&1
  k apply -k "$keep" >/dev/null || fail "apply the $mode plugin"

  say "wait for the card to advertise two devices under $mode"
  for i in $(seq 1 60); do
    adv=$(k get nodes -l 'platform.lkhun9311.github.io/gpu-sharing=true' \
      -o jsonpath='{.items[0].status.allocatable.nvidia\.com/gpu}' 2>/dev/null)
    [ "${adv:-0}" -ge 2 ] 2>/dev/null && break
    [ "$i" = 60 ] && fail "the node advertises ${adv:-0} device(s) after applying a $mode config that asks for 2: the plugin is ignoring CONFIG_FILE, and both engines would compete for one device -- which is a one-engine arm wearing a two-engine label"
    sleep 10
  done
  say "node advertises $adv devices for one physical card under $mode"

  # MPS has a second failure that time-slicing does not: the control daemon can be absent or unreachable
  # while the plugin still advertises, and every client then silently runs WITHOUT MPS. An arm that fell
  # back that way is the time-slicing arm under another name, and nothing downstream could tell.
  if [ "$mode" = mps ]; then
    k rollout status ds/nvidia-mps-control-daemon -n system --timeout=180s >/dev/null \
      || fail "the MPS control daemon never became ready; clients would fall back to running without MPS and the arm would be time-slicing under another name"
  fi
}

say "build and push the gateway"
CGO_ENABLED=0 GOOS=linux go build -o "$WORK/gateway" ./cmd/gateway || fail "build gateway"
go build -o "$WORK/benchharness" ./cmd/benchharness || fail "build benchharness"
printf 'FROM gcr.io/distroless/static:nonroot\nCOPY gateway /gateway\nUSER 65532:65532\nENTRYPOINT ["/gateway"]\n' > "$WORK/Dockerfile"
docker build -q -t "$GW_IMAGE" "$WORK" >/dev/null || fail "build gateway image"
docker tag "$GW_IMAGE" "$REGISTRY/$GW_IMAGE" && docker push "$REGISTRY/$GW_IMAGE" >/dev/null || fail "push gateway image"
GW_IMAGE="$REGISTRY/$GW_IMAGE"

# One routing record per engine namespace, replicas 0 and a no-op image for the reason
# hack/m5b-gpu-session.sh gives: InferenceDeploymentSpec has no args and no volumes, so it cannot describe a
# vLLM container. The engine Deployment must exist FIRST or the operator takes the name.
routing_record() {
  local ns="$1" name="$2"
  k apply -f - >/dev/null <<EOF || fail "routing record in $ns"
apiVersion: platform.lkhun9311.github.io/v1
kind: InferenceDeployment
metadata: {name: $name, namespace: $ns}
spec:
  model: {name: $MODEL, storageUri: "hf://$MODEL"}
  image: registry.k8s.io/pause:3.9
  gpuCount: 0
  replicas: 0
  port: 8000
EOF
}

deploy_arm() {
  local arm="$1"
  k delete namespace "$NS_A" "$NS_B" --wait=true >/dev/null 2>&1
  k create ns "$NS_A" >/dev/null; k create ns "$NS_B" >/dev/null
  case "$arm" in
    shared)
      # One engine with the whole card. Both policies point at the same namespace, so both tenants resolve
      # to it -- which is exactly M5-b's topology and exactly what makes their KV caches one cache.
      k apply -f config/vllm/deployment.yaml -n "$NS_A" >/dev/null || fail "apply the exclusive engine"
      k apply -f config/vllm/service.yaml -n "$NS_A" >/dev/null || fail "apply the exclusive service"
      k rollout status deploy/vllm-qwen25-3b -n "$NS_A" --timeout=900s >/dev/null || fail "the exclusive engine never became ready"
      routing_record "$NS_A" vllm-qwen25-3b
      PREMIUM_NS="$NS_A"; STANDARD_NS="$NS_A"
      ;;
    timeSlicing|mps)
      apply_sharing_plugin "$arm"
      k apply -f config/vllm-shared/engine-a.yaml -n "$NS_A" >/dev/null || fail "apply engine a"
      k apply -f config/vllm-shared/engine-b.yaml -n "$NS_B" >/dev/null || fail "apply engine b"
      k rollout status deploy/vllm-shared-a -n "$NS_A" --timeout=900s >/dev/null || fail "engine a never became ready"
      k rollout status deploy/vllm-shared-b -n "$NS_B" --timeout=900s >/dev/null || fail "engine b never became ready"
      # Both engines must be on the SAME node or they are not sharing a card. max_size 1 should guarantee
      # it; checking is cheap and the failure is invisible in the numbers.
      na=$(k get pod -n "$NS_A" -l app.kubernetes.io/component=vllm-shared -o jsonpath='{.items[0].spec.nodeName}')
      nb=$(k get pod -n "$NS_B" -l app.kubernetes.io/component=vllm-shared -o jsonpath='{.items[0].spec.nodeName}')
      [ -n "$na" ] && [ "$na" = "$nb" ] || fail "the two engines are on different nodes ($na, $nb); that is not sharing a card"
      routing_record "$NS_A" vllm-shared-a
      routing_record "$NS_B" vllm-shared-b
      PREMIUM_NS="$NS_A"; STANDARD_NS="$NS_B"
      ;;
  esac

  k apply -f - >/dev/null <<EOF || fail "policies for $arm"
apiVersion: platform.lkhun9311.github.io/v1
kind: GPUQuotaPolicy
metadata:
  name: m5c-premium
  annotations: {platform.lkhun9311.github.io/tier: premium}
spec: {tenant: premium-1, targetNamespace: $PREMIUM_NS, gpuClass: a10g, limits: {gpuCount: 1}}
---
apiVersion: platform.lkhun9311.github.io/v1
kind: GPUQuotaPolicy
metadata: {name: m5c-standard}
spec: {tenant: standard-noisy, targetNamespace: $STANDARD_NS, gpuClass: a10g, limits: {gpuCount: 1}}
EOF

  k create secret generic gateway-api-keys -n "$NS_A" \
    --from-literal=premium-key=premium-1 --from-literal=standard-key=standard-noisy \
    --dry-run=client -o yaml | k apply -f - >/dev/null
  k create serviceaccount gateway -n "$NS_A" --dry-run=client -o yaml | k apply -f - >/dev/null
  k create clusterrolebinding m5c-gateway-role --clusterrole=gateway-role \
    --serviceaccount="$NS_A:gateway" --dry-run=client -o yaml | k apply -f - >/dev/null
  k apply -f - >/dev/null <<EOF || fail "secret-reader role"
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: {name: gateway-secret-reader, namespace: $NS_A}
rules: [{apiGroups: [""], resources: ["secrets"], verbs: ["get","list","watch"]}]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: {name: gateway-secret-reader, namespace: $NS_A}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: Role, name: gateway-secret-reader}
subjects: [{kind: ServiceAccount, name: gateway, namespace: $NS_A}]
EOF

  # Admission OFF in both arms. The matrix varies the TOPOLOGY; leaving the guard on would vary two things
  # and hand the difference to whichever one the reader already believed.
  k apply -f - >/dev/null <<EOF || fail "gateway for $arm"
apiVersion: apps/v1
kind: Deployment
metadata: {name: gateway, namespace: $NS_A}
spec:
  replicas: 1
  selector: {matchLabels: {app: m5c-gateway}}
  template:
    metadata:
      labels: {app: m5c-gateway}
      annotations: {arm: "$arm"}
    spec:
      serviceAccountName: gateway
      containers:
        - name: gateway
          image: $GW_IMAGE
          args: ["-admission-mode=off"]
          env:
            - {name: GATEWAY_NAMESPACE, value: $NS_A}
            - {name: GATEWAY_API_KEY_SECRET, value: gateway-api-keys}
          ports: [{containerPort: 8080, name: http}]
EOF
  k rollout status deploy/gateway -n "$NS_A" --timeout=180s >/dev/null || fail "gateway never became ready for $arm"
}

DURATION_MS=$(python3 -c "print(int(500 / (float('$RATE')/2) * 1000))")
say "rate ${RATE}/s, duration $((DURATION_MS/1000))s per arm, ${REPS} repetitions, output $OUT"

for rep in $(seq 1 "$REPS"); do
  for arm in $ARMS; do
    say "rep $rep arm $arm"
    deploy_arm "$arm"
    [ -n "$PF_PID" ] && kill "$PF_PID" 2>/dev/null
    k port-forward -n "$NS_A" deploy/gateway 18080:8080 >/dev/null 2>&1 &
    PF_PID=$!
    sleep 3

    # arm is spelled "off" in the manifest because the harness's allowed arms are the ADMISSION arms; the
    # sharing mode is this run's variable and is recorded in the output path, not in the manifest's arm.
    "$WORK/benchharness" gen-trace --seed 11 --duration-ms "$DURATION_MS" --rate "$RATE" \
      --arm off --gateway-url "http://127.0.0.1:18080" \
      --trace-out "$OUT/trace-$arm-$rep.jsonl" --manifest-out "$OUT/manifest-$arm-$rep.yaml" || fail "gen-trace $arm"
    "$WORK/benchharness" replay --manifest "$OUT/manifest-$arm-$rep.yaml" \
      --target "http://127.0.0.1:18080" \
      --api-keys "premium-1=premium-key,standard-noisy=standard-key" \
      --raw-out "$OUT/raw-$arm-$rep.jsonl" || fail "replay $arm"
    [ -s "$OUT/raw-$arm-$rep.jsonl" ] || fail "no raw evidence for $arm rep $rep"
    say "  $(wc -l < "$OUT/raw-$arm-$rep.jsonl") rows"
  done
done

# The raw files are NOT report inputs, and saying so here is cheaper than the confusion. Both arms replay
# with --arm off, because the harness's arm vocabulary is the ADMISSION arms and the sharing mode is this
# run's variable; feeding both files to `benchharness report` would pool them into one arm and produce a
# number for a comparison that was never made.
cat > "$OUT/README.txt" <<EOF
Raw evidence from the M5-c sharing matrix.

The variable is the SHARING MODE, recorded in each filename, not in the manifests: every row carries
arm="off" because the harness's arm field names admission modes and admission was off in both.

Do NOT pass these to \`benchharness report\`. It would pool both modes into one arm.
Compare raw-shared-*.jsonl against raw-timeSlicing-*.jsonl on premium TTFT instead.
EOF

say "MATRIX DONE. Raw evidence in $OUT (see its README.txt before analysing)."
say "The comparison is premium TTFT p99 across the sharing modes at equal offered load."
say "Per-engine GPU utilisation is deliberately absent: under time-slicing nothing can attribute it."
