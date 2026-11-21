#!/usr/bin/env bash
# Measures the gateway's tenant rate limit at one and three replicas, on the memory store and on the shared Redis
# store, then stops Redis under load and kills a gateway Pod under load, on a throwaway kind cluster.
#
# Design: docs/superpowers/specs/2026-11-21-gateway-shared-ratelimit-design.md.
# The setup follows hack/gateway-replica-limit.sh, whose 2026-10-09 run measured 1.95x at two replicas.
#
# The cluster has its own kubeconfig under a temporary directory, so ~/.kube/config is never read or written,
# and it is deleted on every way out unless KEEP=1.
#
# Usage: hack/gateway-shared-ratelimit/run.sh <out-dir>
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

OUT=${1:?usage: run.sh <out-dir>}
CLUSTER=gwshared
NS=gpu-platform-control-plane-system
SERVING_NS=serving
TAG=gwshared
STUB_IMG=benchharness:$TAG
REDIS_IMG=redis:7.4.7-alpine
# The digest the unit tests pin; the run checks the loaded image has it, so the two cannot differ by a tag move.
REDIS_DIGEST=sha256:02f2cc4882f8bf87c79a220ac958f58c700bdec0dfb9b9ea61b62fb0e8f1bfcf
# Host ports differ from the other kind scripts', so this can run beside them.
GW_PORT=31180
STUB_PORT=31181
RATE=10
DURATION=30s
REPS=${REPS:-3}
EXP=experiments/gateway-replica-limit
WORK=$(mktemp -d)
KCFG=$WORK/kubeconfig
mkdir -p "$OUT"
LOG=$OUT/log.txt
: >"$LOG"

log()  { echo -e "$*" | tee -a "$LOG"; }
run()  { echo "+ $*" >>"$LOG"; "$@" >>"$LOG" 2>&1; }
k()    { kubectl --kubeconfig "$KCFG" --context "kind-$CLUSTER" "$@"; }
teardown() {
  if [ "${KEEP:-0}" != 1 ] && grep -qx "$CLUSTER" <<<"$(kind get clusters 2>>"$LOG")"; then
    kind delete cluster --name "$CLUSTER" --kubeconfig "$KCFG" >>"$LOG" 2>&1 || echo "teardown: kind delete failed" >>"$LOG"
  fi
  rm -rf "$WORK"
}
# Every failure exits non-zero and names its step, so a broken setup cannot pass for a run.
die() { log "FAILED at: $*"; tail -20 "$LOG" >&2; teardown; exit 1; }
trap 'teardown; exit 130' INT
trap 'teardown; exit 143' TERM

export PATH="$PWD/bin:$PATH"
command -v kustomize >/dev/null || make kustomize >>"$LOG" 2>&1 || die "make kustomize"
for tool in docker kind kubectl kustomize jq curl go python3; do
  command -v "$tool" >/dev/null || die "missing tool $tool"
done
log "commit $(git rev-parse HEAD), dirty files under cmd/ internal/: $(git status --porcelain -- cmd internal | wc -l)"
log "kubeconfig $KCFG (private to this run)"

log "== build"
go build -buildvcs=false -o "$WORK/loadgen" ./$EXP/loadgen || die "build loadgen"
run make docker-build IMG=controller:$TAG || die "operator image"
run make docker-build-gateway GATEWAY_IMG=gateway:$TAG || die "gateway image"
run make docker-build-benchharness BENCHHARNESS_IMG="$STUB_IMG" || die "stub image"
run docker pull "$REDIS_IMG" || die "redis pull"
got=$(docker inspect --format '{{range .RepoDigests}}{{.}} {{end}}' "$REDIS_IMG")
grep -q "$REDIS_DIGEST" <<<"$got" || die "redis image digest is [$got], not $REDIS_DIGEST"

log "== cluster $CLUSTER"
grep -qx "$CLUSTER" <<<"$(kind get clusters 2>>"$LOG")" && die "a cluster named $CLUSTER already exists; not touching it"
cat >"$WORK/kind.yaml" <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    extraPortMappings:
      - {containerPort: $GW_PORT, hostPort: $GW_PORT, listenAddress: "127.0.0.1", protocol: TCP}
      - {containerPort: $STUB_PORT, hostPort: $STUB_PORT, listenAddress: "127.0.0.1", protocol: TCP}
EOF
run kind create cluster --name "$CLUSTER" --kubeconfig "$KCFG" --config "$WORK/kind.yaml" || die "kind create"
for img in controller:$TAG gateway:$TAG "$STUB_IMG"; do
  run kind load docker-image "$img" --name "$CLUSTER" || die "kind load $img"
done
# The pulled Redis is a multi-platform index whose other platforms' layers are not on this host, and kind's import
# fails on the first missing blob ("content digest ... not found"), so one platform is saved and loaded as an archive.
run docker save --platform linux/amd64 -o "$WORK/redis.tar" "$REDIS_IMG" || die "save redis"
run kind load image-archive "$WORK/redis.tar" --name "$CLUSTER" || die "kind load redis archive"

log "== kueue, CRDs, operator, gateway, redis"
# The operator's controllers watch Kueue kinds and do not start their caches without these CRDs.
run k apply --server-side -f https://github.com/kubernetes-sigs/kueue/releases/download/v0.18.3/manifests.yaml || die "kueue"
run k -n kueue-system wait --for=condition=Available deploy/kueue-controller-manager --timeout=300s || die "kueue Available"
kustomize build config/crd | k apply --server-side -f - >>"$LOG" 2>&1 || die "CRDs"
k create namespace "$NS" --dry-run=client -o yaml | k apply -f - >>"$LOG" 2>&1
# Kueue's Deployment turns Available before its webhook serves, and the webhook mutates every Deployment applied
# here, so the first apply is retried until the webhook answers; a real refusal still fails all thirty attempts.
applied=0
for _ in $(seq 1 30); do
  if kustomize build config/operator | k apply --server-side -f - >>"$LOG" 2>&1; then applied=1; break; fi
  sleep 5
done
[ "$applied" = 1 ] || die "operator"
OPDEP=$(k -n "$NS" get deploy -o name | grep controller-manager | head -1)
run k -n "$NS" set image "$OPDEP" "*=controller:$TAG" || die "operator image set"
run k -n "$NS" rollout status "$OPDEP" --timeout=180s || die "operator rollout"
kustomize build config/gateway | k apply --server-side -f - >>"$LOG" 2>&1 || die "gateway"
k -n "$NS" create secret generic gateway-api-keys --from-literal=key-a=tenant-a >>"$LOG" 2>&1 || die "api keys"
run k -n "$NS" set image deploy/gateway "gateway=gateway:$TAG" || die "gateway image set"
run k -n "$NS" rollout status deploy/gateway --timeout=180s || die "gateway rollout"
cat <<EOF | k apply -f - >>"$LOG" 2>&1 || die "redis"
apiVersion: apps/v1
kind: Deployment
metadata: {name: redis, namespace: $NS}
spec:
  replicas: 1
  selector: {matchLabels: {app: gw-redis}}
  template:
    metadata: {labels: {app: gw-redis}}
    spec:
      containers:
        - name: redis
          image: $REDIS_IMG
          imagePullPolicy: Never
          # No persistence: a restarted Redis starts with every bucket full, which the Redis-down arm records.
          args: ["--save", "", "--appendonly", "no"]
          ports: [{containerPort: 6379, name: redis}]
          readinessProbe: {tcpSocket: {port: 6379}, periodSeconds: 1}
---
apiVersion: v1
kind: Service
metadata: {name: redis, namespace: $NS}
spec:
  selector: {app: gw-redis}
  ports: [{name: redis, port: 6379, targetPort: redis}]
EOF
run k -n "$NS" rollout status deploy/redis --timeout=120s || die "redis rollout"

log "== tenant policy and stub backend"
k create namespace "$SERVING_NS" --dry-run=client -o yaml | k apply -f - >>"$LOG" 2>&1
cat <<EOF | k apply -f - >>"$LOG" 2>&1 || die "policy and backend"
apiVersion: platform.lkhun9311.github.io/v1
kind: GPUQuotaPolicy
metadata:
  name: tenant-a-quota
spec:
  tenant: tenant-a
  targetNamespace: $SERVING_NS
  gpuClass: l40s
  limits:
    gpuCount: 4
  rateLimit:
    requestsPerMinute: 60
    burst: 5
---
apiVersion: platform.lkhun9311.github.io/v1
kind: InferenceDeployment
metadata:
  name: stub
  namespace: $SERVING_NS
spec:
  model:
    name: stub
    storageUri: "stub://profile?tokens=4&ttft-ms=5&itl-ms=2"
  image: $STUB_IMG
  gpuCount: 0
  replicas: 1
  port: 8090
---
apiVersion: v1
kind: Service
metadata:
  name: gateway-gwshared
  namespace: $NS
spec:
  type: NodePort
  selector:
    app.kubernetes.io/name: gpu-platform-control-plane
    app.kubernetes.io/component: gateway
  ports:
    - {name: http, port: 8080, targetPort: http, nodePort: $GW_PORT}
---
apiVersion: v1
kind: Service
metadata:
  name: stub-gwshared
  namespace: $SERVING_NS
spec:
  type: NodePort
  selector:
    app.kubernetes.io/instance: stub
  ports:
    - {name: http, port: 8090, targetPort: http, nodePort: $STUB_PORT}
EOF
for _ in $(seq 1 40); do k -n "$SERVING_NS" get deploy stub >/dev/null 2>&1 && break; sleep 3; done
run k -n "$SERVING_NS" rollout status deploy/stub --timeout=180s || die "stub rollout"

URL="http://127.0.0.1:$GW_PORT/v1/chat/completions"
smoke=""
for _ in $(seq 1 40); do
  smoke=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 -H 'Authorization: Bearer key-a' \
    -H 'Content-Type: application/json' -d '{"model":"stub","messages":[{"role":"user","content":"hi"}],"stream":true}' "$URL" 2>>"$LOG")
  [ "$smoke" = 200 ] && break
  sleep 3
done
[ "$smoke" = 200 ] || die "smoke request answered $smoke, not 200"
log "smoke 200"

ready_endpoints() {
  k -n "$NS" get endpointslices -l kubernetes.io/service-name=gateway-gwshared \
    -o jsonpath='{range .items[*].endpoints[?(@.conditions.ready==true)]}x{end}' 2>>"$LOG" | wc -c
}

# configure sets the store and the replica count, and returns once exactly that many Pods are Service endpoints.
configure() {
  local store=$1 replicas=$2 policy=${3:-local} args
  if [ "$store" = redis ]; then
    args="[\"--rate-limit-store=redis\",\"--rate-limit-redis-addr=redis.$NS.svc.cluster.local:6379\",\"--rate-limit-redis-failure-policy=$policy\"]"
  else
    args='["--rate-limit-store=memory"]'
  fi
  run k -n "$NS" patch deploy gateway --type=json \
    -p "[{\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/args\",\"value\":$args},{\"op\":\"replace\",\"path\":\"/spec/replicas\",\"value\":$replicas}]" \
    || die "configure $store $replicas"
  run k -n "$NS" rollout status deploy/gateway --timeout=180s || die "rollout $store $replicas"
  local n=0
  for _ in $(seq 1 90); do
    n=$(ready_endpoints)
    # Terminating Pods of the old ReplicaSet are not ready, so equality means only the new Pods serve.
    [ "$n" = "$replicas" ] && [ "$(k -n "$NS" get pods -l app.kubernetes.io/component=gateway --no-headers 2>>"$LOG" | wc -l)" = "$replicas" ] && return 0
    sleep 1
  done
  die "service has $n ready endpoints, wanted $replicas"
}

# Per-Pod 200 counts, and the shared-store series, read through the API server's Pod proxy.
# A failed scrape stops the arm: read as zero it would hide a Pod.
pod_metrics() {
  local pods p m out=""
  pods=$(k -n "$NS" get pods -l app.kubernetes.io/component=gateway --field-selector=status.phase=Running -o name 2>>"$LOG") || return 1
  [ -n "$pods" ] || return 1
  for p in $pods; do
    m=$(k get --raw "/api/v1/namespaces/$NS/pods/${p#pod/}:8081/proxy/metrics" 2>>"$LOG") || return 1
    grep -q '^gpuaas_gateway_' <<<"$m" || return 1
    out+="${p#pod/}:ok=$(awk '/^gpuaas_gateway_requests_total\{/ && /tenant="tenant-a"/ && /code="200"/ {s+=$NF} END {print s+0}' <<<"$m")"
    out+=",degraded=$(awk '/^gpuaas_gateway_ratelimit_degraded_decisions_total\{/ {s+=$NF} END {print s+0}' <<<"$m")"
    out+=",redis_errors=$(awk '/^gpuaas_gateway_ratelimit_redis_errors_total / {s+=$NF} END {print s+0}' <<<"$m") "
  done
  echo "$out"
}

now() { python3 -c 'import time; print(f"{time.time():.3f}")'; }
rel() { python3 -c "print(f'{$1 - $2:.3f}')"; }

printf 'arm\trep\treplicas\tstore\tpolicy\tevent\tstub_served\tevent1_s\tevent2_s\tpods_before\tpods_after\n' >"$OUT/arms.tsv"
# arm runs 10 requests per second for 30 s from one tenant and, for an event arm, acts on the cluster mid-run.
arm() {
  local name=$1 rep=$2 replicas=$3 store=$4 policy=$5 event=$6
  configure "$store" "$replicas" "$policy"
  # Ten idle seconds refill a 5-token bucket at 1/s twice over, in Redis and in every Pod, so every arm starts full.
  sleep 10
  curl -sS -X POST --max-time 5 "http://127.0.0.1:$STUB_PORT/stats/reset" >/dev/null || die "stub reset"
  local before after e1="" e2="" t0
  before=$(pod_metrics) || die "per-Pod metrics before $name-$rep"
  t0=$(now)
  "$WORK/loadgen" -url "$URL" -key key-a -model stub -rate $RATE -duration $DURATION \
    -out "$OUT/$name-$rep.tsv" >"$OUT/$name-$rep.summary" 2>>"$LOG" &
  local lg=$!
  case "$event" in
    redis-down)
      # Redis goes away at about 10 s and comes back at about 20 s; the second stamp is when it is ready again.
      sleep 10
      e1=$(rel "$(now)" "$t0")
      run k -n "$NS" scale deploy/redis --replicas=0 || die "redis down"
      sleep 10
      run k -n "$NS" scale deploy/redis --replicas=1 || die "redis up"
      run k -n "$NS" rollout status deploy/redis --timeout=60s || die "redis back"
      e2=$(rel "$(now)" "$t0")
      ;;
    podkill)
      # One of three gateway Pods is killed with no grace at about 15 s; the second stamp is when three are ready again.
      sleep 15
      local victim
      victim=$(k -n "$NS" get pods -l app.kubernetes.io/component=gateway -o name | head -1)
      e1=$(rel "$(now)" "$t0")
      run k -n "$NS" delete "$victim" --grace-period=0 --force || die "pod kill"
      for _ in $(seq 1 120); do
        [ "$(ready_endpoints)" = 3 ] && [ "$(k -n "$NS" get pods -l app.kubernetes.io/component=gateway --no-headers | grep -c ' Running ')" = 3 ] && break
        sleep 0.5
      done
      e2=$(rel "$(now)" "$t0")
      log "killed $victim at ${e1}s; three ready endpoints again at ${e2}s"
      ;;
  esac
  wait "$lg" || die "loadgen $name-$rep"
  after=$(pod_metrics) || die "per-Pod metrics after $name-$rep"
  local served
  served=$(curl -sS --max-time 5 "http://127.0.0.1:$STUB_PORT/stats" | jq -r '.requestsServed') || die "stub stats"
  [[ "$served" =~ ^[0-9]+$ ]] || die "stub stats returned '$served'"
  log "$name rep $rep: $(cat "$OUT/$name-$rep.summary") stub=$served events=[$e1 $e2] pods before [$before] after [$after]"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$rep" "$replicas" "$store" "$policy" "$event" \
    "$served" "$e1" "$e2" "$before" "$after" >>"$OUT/arms.tsv"
}

for rep in $(seq 1 "$REPS"); do
  arm memory-1 "$rep" 1 memory - none
  arm memory-3 "$rep" 3 memory - none
  arm redis-3  "$rep" 3 redis local none
done
arm redis-3-down-local  1 3 redis local  redis-down
arm redis-3-down-closed 1 3 redis closed redis-down
arm redis-3-podkill     1 3 redis local  podkill

log "== score"
python3 -I hack/gateway-shared-ratelimit/score.py "$OUT" | tee "$OUT/score.txt" | tee -a "$LOG"
status=${PIPESTATUS[0]}
teardown
log "cluster $CLUSTER deleted: $(grep -cx "$CLUSTER" <<<"$(kind get clusters 2>>"$LOG")" | sed 's/^0$/yes/;s/^1$/NO/')"
exit "$status"
