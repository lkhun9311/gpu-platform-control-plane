#!/usr/bin/env bash
# Measures whether a tenant's gateway rate limit survives a second replica and a Pod restart, on kind.
#
# The registration (arms, readings, validity checks) is experiments/gateway-replica-limit/README.md.
# It builds a throwaway cluster named gwlimit, so the shared `platform` cluster is never touched.
# KEEP=1 leaves the cluster up afterwards for inspection.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

CLUSTER=gwlimit
KCTX=kind-$CLUSTER
NS=gpu-platform-control-plane-system
SERVING_NS=serving
TAG=gwlimit
STUB_IMG=benchharness:$TAG
# Host ports differ from kind-config-gateway-path.yaml's 3008x so this can run beside a cluster using those.
GW_PORT=31080
STUB_PORT=31081
REPS=${REPS:-3}
RATE=10
DURATION=30s
RESTART_AT=15
EXP=experiments/gateway-replica-limit
OUT=hack/gateway-replica-limit-$(date -u +%Y%m%dT%H%M%SZ)
LOG=$OUT/log.txt
WORK=$(mktemp -d)
mkdir -p "$OUT"

log()  { echo -e "$*" | tee -a "$LOG"; }
run()  { echo "+ $*" >>"$LOG"; "$@" >>"$LOG" 2>&1; }
k()    { kubectl --context "$KCTX" "$@"; }
teardown() {
  rm -rf "$WORK"
  # The cluster list's stderr goes to the log: a sibling runner skipped its delete with nothing recorded about why.
  if [ "${KEEP:-0}" != 1 ] && grep -qx "$CLUSTER" <<<"$(kind get clusters 2>>"$LOG")"; then
    kind delete cluster --name "$CLUSTER" >>"$LOG" 2>&1 || echo "teardown: kind delete failed" >>"$LOG"
  fi
}
# Every failure exits non-zero and names its step, so a broken setup cannot pass for a run with no breach.
die() { log "FAILED at: $*"; tail -20 "$LOG" >&2; teardown; exit 1; }
# A cancelled run stops here: a handler that only cleaned up let the loop carry on against a deleted cluster.
trap 'teardown; exit 130' INT
trap 'teardown; exit 143' TERM
# The registration fixes three repetitions and the scorer checks exactly three, so any other count is refused
# before a cluster is built rather than ending VOID, or VALID while ignoring the extra repetitions.
[ "$REPS" = 3 ] || die "REPS=$REPS, but the registered protocol is three repetitions"

export PATH="$PWD/bin:$PATH"
# A fresh worktree has no bin/, so the pinned kustomize is fetched rather than whatever the host might carry.
command -v kustomize >/dev/null || make kustomize >>"$LOG" 2>&1 || die "make kustomize"
for tool in docker kind kubectl kustomize jq curl go python3; do
  command -v "$tool" >/dev/null || die "missing tool $tool"
done
log "commit $(git rev-parse HEAD), dirty files: $(git status --porcelain | wc -l)"

log "== build"
go build -buildvcs=false -o "$WORK/loadgen" ./$EXP/loadgen || die "build loadgen"
run make docker-build IMG=controller:$TAG || die "operator image"
run make docker-build-gateway GATEWAY_IMG=gateway:$TAG || die "gateway image"
run make docker-build-benchharness BENCHHARNESS_IMG="$STUB_IMG" || die "stub image"

log "== cluster $CLUSTER"
grep -qx "$CLUSTER" <<<"$(kind get clusters 2>>"$LOG")" && run kind delete cluster --name "$CLUSTER"
cat >"$WORK/kind.yaml" <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    extraPortMappings:
      - {containerPort: $GW_PORT, hostPort: $GW_PORT, listenAddress: "127.0.0.1", protocol: TCP}
      - {containerPort: $STUB_PORT, hostPort: $STUB_PORT, listenAddress: "127.0.0.1", protocol: TCP}
EOF
run kind create cluster --name "$CLUSTER" --config "$WORK/kind.yaml" || die "kind create"
for img in controller:$TAG gateway:$TAG "$STUB_IMG"; do
  run kind load docker-image "$img" --name "$CLUSTER" || die "kind load $img"
done

log "== kueue, CRDs, operator, gateway"
# The operator's controllers watch Kueue kinds and do not start their caches without these CRDs.
run k apply --server-side -f https://github.com/kubernetes-sigs/kueue/releases/download/v0.18.3/manifests.yaml || die "kueue"
run k -n kueue-system wait --for=condition=Available deploy/kueue-controller-manager --timeout=300s || die "kueue Available"
kustomize build config/crd | k apply --server-side -f - >>"$LOG" 2>&1 || die "CRDs"
k create namespace "$NS" --dry-run=client -o yaml | k apply -f - >>"$LOG" 2>&1
kustomize build config/operator | k apply --server-side -f - >>"$LOG" 2>&1 || die "operator"
OPDEP=$(k -n "$NS" get deploy -o name | grep controller-manager | head -1)
# Both kustomizations pin an ECR digest a kind node cannot pull, so the local builds are set explicitly.
run k -n "$NS" set image "$OPDEP" "*=controller:$TAG" || die "operator image set"
run k -n "$NS" rollout status "$OPDEP" --timeout=180s || die "operator rollout"
kustomize build config/gateway | k apply --server-side -f - >>"$LOG" 2>&1 || die "gateway"
k -n "$NS" create secret generic gateway-api-keys --from-literal=key-a=tenant-a >>"$LOG" 2>&1 || die "api keys"
run k -n "$NS" set image deploy/gateway "gateway=gateway:$TAG" || die "gateway image set"
run k -n "$NS" rollout status deploy/gateway --timeout=180s || die "gateway rollout"

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
  name: gateway-gwlimit
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
  name: stub-gwlimit
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

scale() {
  run k -n "$NS" scale deploy/gateway --replicas="$1" || die "scale $1"
  run k -n "$NS" rollout status deploy/gateway --timeout=180s || die "rollout at $1"
  # Ready Pods are not yet Service endpoints; an arm that starts early measures one Pod and calls it two.
  for _ in $(seq 1 60); do
    n=$(k -n "$NS" get endpointslices -l kubernetes.io/service-name=gateway-gwlimit \
      -o jsonpath='{range .items[*].endpoints[?(@.conditions.ready==true)]}x{end}' | wc -c)
    [ "$n" = "$1" ] && return 0
    sleep 1
  done
  die "service has $n ready endpoints, wanted $1"
}
# Per-Pod 200 counts read through the API server's Pod proxy, so each replica is asked separately.
# A failed scrape must stop the arm: read as zero, it would credit a Pod's whole lifetime to one arm or hide it.
pod_oks() {
  local pods p m c out=""
  pods=$(k -n "$NS" get pods -l app.kubernetes.io/component=gateway --field-selector=status.phase=Running -o name 2>>"$LOG") || return 1
  [ -n "$pods" ] || return 1
  for p in $pods; do
    m=$(k get --raw "/api/v1/namespaces/$NS/pods/${p#pod/}:8081/proxy/metrics" 2>>"$LOG") || return 1
    # Any gateway series proves this is the gateway's exposition; a Pod that has served nobody yet legitimately has no tenant-a series.
    grep -q '^gpuaas_gateway_' <<<"$m" || return 1
    c=$(awk '/^gpuaas_gateway_requests_total\{/ && /tenant="tenant-a"/ && /code="200"/ {s+=$NF} END {print s+0}' <<<"$m")
    out+="${p#pod/}=$c"$'\n'
  done
  sort <<<"$out" | tr '\n' ' '
}

printf 'arm\trep\tstub_served\tdelete_s\tpods_before\tpods_after\n' >"$OUT/arms.tsv"
arm() {
  local name=$1 rep=$2 replicas=$3 pinned=$4 restart=$5
  scale "$replicas"
  # Ten idle seconds refill a 5-token bucket at 1/s twice over, so every arm starts from a full bucket.
  sleep 10
  curl -sS -X POST --max-time 5 "http://127.0.0.1:$STUB_PORT/stats/reset" >/dev/null || die "stub reset"
  local before after delete_s="" t0
  before=$(pod_oks) || die "per-Pod counters before $name-$rep"
  t0=$(date +%s.%N)
  "$WORK/loadgen" -url "$URL" -key key-a -model stub -rate $RATE -duration $DURATION -pinned="$pinned" \
    -out "$OUT/$name-$rep.tsv" >"$OUT/$name-$rep.summary" 2>>"$LOG" &
  local lg=$!
  if [ "$restart" = 1 ]; then
    sleep $RESTART_AT
    delete_s=$(python3 -c "import time; print(f'{time.time() - $t0:.3f}')")
    run k -n "$NS" delete pod -l app.kubernetes.io/component=gateway --wait=false || die "delete gateway pod"
  fi
  wait "$lg" || die "loadgen $name-$rep"
  after=$(pod_oks) || die "per-Pod counters after $name-$rep"
  served=$(curl -sS --max-time 5 "http://127.0.0.1:$STUB_PORT/stats" | jq -r '.requestsServed') || die "stub stats"
  [[ "$served" =~ ^[0-9]+$ ]] || die "stub stats returned '$served'"
  log "$name rep $rep: $(cat "$OUT/$name-$rep.summary") stub=$served pods before [$before] after [$after]"
  # Per-Pod counters are cumulative over a Pod's life, so the scorer reads which Pods moved from the pair.
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$rep" "$served" "$delete_s" "$before" "$after" >>"$OUT/arms.tsv"
}

for rep in $(seq 1 "$REPS"); do
  arm R1-fresh   "$rep" 1 false 0
  arm R2-fresh   "$rep" 2 false 0
  arm R2-pinned  "$rep" 2 true  0
  # The restart arm was removed by Amendment 1 of the registration; RESTART_ARM=1 still runs it, unregistered.
  if [ "${RESTART_ARM:-0}" = 1 ]; then arm R1-restart "$rep" 1 false 1; fi
done

log "== score"
python3 $EXP/score.py "$OUT" | tee -a "$LOG"
status=${PIPESTATUS[0]}
teardown
exit "$status"
