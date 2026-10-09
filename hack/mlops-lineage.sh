#!/usr/bin/env bash
# Runs the MLOps lineage experiment on a throwaway kind cluster: train, gate, serve, roll back, and the alias trap.
#
# The registration (steps, readings, validity checks) is experiments/mlops-lineage/README.md.
# The cluster is named `mlops` and is deleted at the end (KEEP=1 keeps it).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

CLUSTER=mlops
CONTEXT=kind-$CLUSTER
NS=mlops
SYS=gpu-platform-control-plane-system
TAG=mlops
IMG=mlops-lineage:$TAG
MLFLOW_IMG=ghcr.io/mlflow/mlflow:v2.17.2
EXP=experiments/mlops-lineage
MLFLOW_PORT=32000
PINNED_PORT=32001
ALIAS_PORT=32002
CYCLES=3
ALIAS_WAIT=60
OUT=hack/mlops-lineage-$(date -u +%Y%m%dT%H%M%SZ)
LOG=$OUT/log.txt
mkdir -p "$OUT"
TRACK="http://127.0.0.1:$MLFLOW_PORT"

log() { echo -e "$(date -u +%H:%M:%S) $*" | tee -a "$LOG"; }
k()   { kubectl --context "$CONTEXT" "$@"; }
# Wall-clock times of the runner's own actions, so the scorer can place them on each poll file's axis.
ev()  { printf '%s\t%s\n' "$1" "$(date +%s.%N)" >>"$OUT/events.tsv"; }
cleanup() {
  [ "${KEEP:-0}" = 1 ] && { log "cleanup: KEEP=1, leaving $CLUSTER"; return; }
  local listed
  listed=$(kind get clusters 2>>"$LOG") || log "cleanup: kind get clusters failed"
  if grep -qx "$CLUSTER" <<<"$listed"; then
    kind delete cluster --name "$CLUSTER" >>"$LOG" 2>&1 || log "cleanup: kind delete failed"
    if grep -qx "$CLUSTER" <<<"$(kind get clusters 2>>"$LOG")"; then log "cleanup: $CLUSTER STILL EXISTS"; else log "cleanup: deleted $CLUSTER"; fi
  else
    log "cleanup: $CLUSTER not listed"
  fi
}
die() {
  log "FAILED at: $*"
  # The cluster is deleted next, so what it looked like at the failure is written down first.
  { k get pods -A -o wide; k get events -A --sort-by=.lastTimestamp | tail -40; } >>"$OUT/failure-state.txt" 2>&1
  stop_pollers
  cleanup
  exit 1
}
# Pollers run in the background until a stop file appears, so a cancelled run must stop them before it leaves.
stop_pollers() {
  touch "$OUT/stop-pinned" "$OUT/stop-alias"
  [ -n "${pp:-}" ] && wait "$pp" 2>/dev/null
  [ -n "${pa:-}" ] && wait "$pa" 2>/dev/null
  return 0
}
trap 'stop_pollers; cleanup; exit 130' INT
trap 'stop_pollers; cleanup; exit 143' TERM
retry() {
  for _ in $(seq 1 20); do "$@" && return 0; sleep 3; done
  return 1
}

export PATH="$PWD/bin:$PATH"
command -v kustomize >/dev/null || make kustomize >>"$LOG" 2>&1 || die "make kustomize"
for tool in docker kind kubectl kustomize python3 curl jq; do command -v "$tool" >/dev/null || die "missing tool $tool"; done
COMMIT=$(git rev-parse HEAD)
log "commit $COMMIT, dirty files: $(git status --porcelain | wc -l)"

log "== images and cluster"
docker build -q -t "$IMG" "$EXP" >>"$LOG" 2>&1 || die "experiment image"
# The node pulls this one itself. `kind load` fails on it with "content digest ... not found" — it imports with
# --all-platforms and only one platform of the multi-platform index is on this host — and a `FROM` rebuild
# failed the same way, so the pinned tag is pulled from ghcr.io inside the node instead.
make docker-build IMG=controller:$TAG >>"$LOG" 2>&1 || die "operator image"
make docker-build-gpu-simulator GPU_SIMULATOR_IMG=gpu-simulator:$TAG >>"$LOG" 2>&1 || die "simulator image"
grep -qx "$CLUSTER" <<<"$(kind get clusters 2>>"$LOG")" && { kind delete cluster --name "$CLUSTER" >>"$LOG" 2>&1 || die "delete old cluster"; }
cat >"$OUT/kind.yaml" <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    extraPortMappings:
      - {containerPort: $MLFLOW_PORT, hostPort: $MLFLOW_PORT, listenAddress: "127.0.0.1", protocol: TCP}
      - {containerPort: $PINNED_PORT, hostPort: $PINNED_PORT, listenAddress: "127.0.0.1", protocol: TCP}
      - {containerPort: $ALIAS_PORT, hostPort: $ALIAS_PORT, listenAddress: "127.0.0.1", protocol: TCP}
EOF
kind create cluster --name "$CLUSTER" --config "$OUT/kind.yaml" >>"$LOG" 2>&1 || die "kind create"
for img in controller:$TAG gpu-simulator:$TAG "$IMG"; do
  kind load docker-image "$img" --name "$CLUSTER" >>"$LOG" 2>&1 || die "kind load $img"
done

log "== platform"
k apply --server-side -f https://github.com/kubernetes-sigs/kueue/releases/download/v0.18.3/manifests.yaml >>"$LOG" 2>&1 || die "kueue"
k -n kueue-system wait --for=condition=Available deploy/kueue-controller-manager --timeout=300s >>"$LOG" 2>&1 || die "kueue Available"
kustomize build config/crd | k apply --server-side -f - >>"$LOG" 2>&1 || die "CRDs"
# shellcheck disable=SC2317  # called through retry
apply_operator() { kustomize build config/operator | k apply --server-side -f - >>"$LOG" 2>&1; }
# Kueue reports Available before its webhook accepts connections, and the first apply after it was refused.
retry apply_operator || die "operator"
OPDEP=$(k -n "$SYS" get deploy -o name | grep controller-manager | head -1)
k -n "$SYS" set image "$OPDEP" manager=controller:$TAG >>"$LOG" 2>&1 || die "operator image set"
kustomize build config/device-plugin | k apply -f - >>"$LOG" 2>&1 || die "device plugin"
k -n "$SYS" set image ds/gpu-simulator "*=gpu-simulator:$TAG" >>"$LOG" 2>&1 || die "simulator image set"
# The manifest's `:latest` defaulted the pull policy to Always at create, and a later tag change keeps it.
k -n "$SYS" patch ds/gpu-simulator --type=json \
  -p '[{"op":"add","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"IfNotPresent"}]' >>"$LOG" 2>&1 ||
  die "simulator pull policy"
k -n "$SYS" rollout status "$OPDEP" --timeout=180s >>"$LOG" 2>&1 || die "operator rollout"
k -n "$SYS" rollout status ds/gpu-simulator --timeout=180s >>"$LOG" 2>&1 || die "simulator rollout"
k apply -f config/kueue/resourceflavor.yaml >>"$LOG" 2>&1 || die "resource flavor"

log "== namespace, queue and tracking server"
cat <<EOF | k apply -f - >>"$LOG" 2>&1 || die "mlops namespace"
apiVersion: v1
kind: Namespace
metadata:
  name: $NS
---
apiVersion: kueue.x-k8s.io/v1beta1
kind: ClusterQueue
metadata:
  name: $NS
spec:
  namespaceSelector:
    matchLabels:
      kubernetes.io/metadata.name: $NS
  resourceGroups:
    - coveredResources: ["nvidia.com/gpu"]
      flavors:
        - name: gpu
          resources:
            - name: "nvidia.com/gpu"
              nominalQuota: 1
---
apiVersion: kueue.x-k8s.io/v1beta1
kind: LocalQueue
metadata:
  name: $NS
  namespace: $NS
spec:
  clusterQueue: $NS
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mlflow
  namespace: $NS
spec:
  replicas: 1
  selector:
    matchLabels: {app: mlflow}
  template:
    metadata:
      labels: {app: mlflow}
    spec:
      containers:
        - name: mlflow
          image: $MLFLOW_IMG
          command: ["mlflow", "server", "--host", "0.0.0.0", "--port", "5000",
                    "--backend-store-uri", "sqlite:////mlflow/mlflow.db",
                    "--serve-artifacts", "--artifacts-destination", "/mlflow/artifacts"]
          ports: [{containerPort: 5000, name: http}]
          readinessProbe: {httpGet: {path: /health, port: http}}
          volumeMounts: [{name: data, mountPath: /mlflow}]
      volumes: [{name: data, emptyDir: {}}]
---
apiVersion: v1
kind: Service
metadata:
  name: mlflow
  namespace: $NS
spec:
  type: NodePort
  selector: {app: mlflow}
  ports: [{name: http, port: 5000, targetPort: http, nodePort: $MLFLOW_PORT}]
EOF
k -n "$NS" rollout status deploy/mlflow --timeout=300s >>"$LOG" 2>&1 || die "mlflow rollout"
for _ in $(seq 1 30); do curl -sf "$TRACK/health" >/dev/null && break; sleep 2; done
curl -sf "$TRACK/health" >/dev/null || die "mlflow not answering on $TRACK"

log "== step 1: train v1 (clean) and v2 (noisy)"
train() {
  local name=$1 variant=$2 phase=""
  cat <<EOF | k apply -f - >>"$LOG" 2>&1 || die "submit $name"
apiVersion: platform.lkhun9311.github.io/v1
kind: MLTrainingJob
metadata:
  name: $name
  namespace: $NS
spec:
  queue: $NS
  image: $IMG
  gpuCount: 1
  command:
    - sh
    - -c
    - |
      export MLFLOW_TRACKING_URI=http://mlflow:5000 VARIANT=$variant GIT_COMMIT=$COMMIT OMP_NUM_THREADS=1
      exec python3 /work/train.py
EOF
  for _ in $(seq 1 200); do
    phase=$(k -n "$NS" get mltrainingjob "$name" -o jsonpath='{.status.phase}' 2>/dev/null)
    [[ "$phase" == Succeeded || "$phase" == Failed ]] && break
    sleep 3
  done
  k -n "$NS" logs "job/$name" >"$OUT/$name.log" 2>>"$LOG" || die "logs of $name"
  [ "$phase" = Succeeded ] || die "$name ended in phase '$phase'"
  grep '^{' "$OUT/$name.log" | tail -1 >"$OUT/$name.json"
  jq -e .model_version "$OUT/$name.json" >/dev/null || die "$name printed no training record"
  log "$name: $(jq -c '{variant, model_version, eval_accuracy}' "$OUT/$name.json")"
}
train train-v1 clean
train train-v2 noisy

log "== step 2: gate"
python3 "$EXP/gate.py" "$TRACK" clf 1 >"$OUT/gate-v1.json" 2>>"$LOG" || die "gate v1"
python3 "$EXP/gate.py" "$TRACK" clf 2 >"$OUT/gate-v2.json" 2>>"$LOG" || die "gate v2"
log "gate v1: $(cat "$OUT/gate-v1.json")"
log "gate v2: $(cat "$OUT/gate-v2.json")"

serve() {
  local name=$1 uri=$2 port=$3
  cat <<EOF | k apply -f - >>"$LOG" 2>&1 || die "serve $name"
apiVersion: platform.lkhun9311.github.io/v1
kind: InferenceDeployment
metadata:
  name: $name
  namespace: $NS
spec:
  model:
    name: clf
    storageUri: "$uri"
  image: $IMG
  gpuCount: 0
  replicas: 1
  port: 8090
---
apiVersion: v1
kind: Service
metadata:
  name: $name-np
  namespace: $NS
spec:
  type: NodePort
  selector: {app.kubernetes.io/instance: $name}
  ports: [{name: http, port: 8090, targetPort: 8090, nodePort: $port}]
EOF
}
# Blocks until N consecutive answers on PORT name VERSION, so a step starts from a settled state.
settled() {
  local port=$1 want=$2 n=0 v
  for _ in $(seq 1 1500); do
    v=$(curl -s --max-time 2 "http://127.0.0.1:$port/predict" | jq -r '.model_version // empty' 2>/dev/null)
    if [ "$v" = "$want" ]; then n=$((n + 1)); [ "$n" -ge 20 ] && return 0; else n=0; fi
    sleep 0.2
  done
  return 1
}
set_uri() { k -n "$NS" patch inferencedeployment "$1" --type=merge -p "{\"spec\":{\"model\":{\"storageUri\":\"$2\"}}}" >>"$LOG" 2>&1; }

log "== step 3: serve the pinned champion and read the lineage"
serve clf-pinned models:/clf/1 "$PINNED_PORT"
settled "$PINNED_PORT" 1 || die "pinned server never answered v1"
curl -s "http://127.0.0.1:$PINNED_PORT/predict" >"$OUT/pinned-first.json" || die "pinned query"
log "pinned answer: $(cat "$OUT/pinned-first.json")"

log "== step 4: forced bad deploy and rollback, $CYCLES cycles"
for c in $(seq 1 "$CYCLES"); do
  rm -f "$OUT/stop-pinned"
  python3 "$EXP/poll.py" "http://127.0.0.1:$PINNED_PORT/predict" "$OUT/poll-rollback-$c.tsv" "$OUT/stop-pinned" \
    >"$OUT/poll-rollback-$c.meta" 2>>"$LOG" &
  pp=$!
  sleep 5
  ev "cycle$c-force-v2"
  set_uri clf-pinned models:/clf/2 || die "force v2 (cycle $c)"
  settled "$PINNED_PORT" 2 || die "v2 never took over (cycle $c)"
  sleep 5
  ev "cycle$c-rollback-v1"
  set_uri clf-pinned models:/clf/1 || die "rollback (cycle $c)"
  settled "$PINNED_PORT" 1 || die "v1 never came back (cycle $c)"
  sleep 5
  touch "$OUT/stop-pinned"
  wait "$pp" || die "poller (cycle $c)"
  log "cycle $c: $(cat "$OUT/poll-rollback-$c.meta")"
done

log "== step 5: the alias trap"
serve clf-alias models:/clf@champion "$ALIAS_PORT"
settled "$ALIAS_PORT" 1 || die "alias server never answered v1"
rm -f "$OUT/stop-alias"
python3 "$EXP/poll.py" "http://127.0.0.1:$ALIAS_PORT/predict" "$OUT/poll-alias.tsv" "$OUT/stop-alias" \
  >"$OUT/poll-alias.meta" 2>>"$LOG" &
pa=$!
sleep 5
ev "alias-forced-v2"
python3 "$EXP/gate.py" "$TRACK" clf 2 --force >"$OUT/gate-v2-forced.json" 2>>"$LOG" || die "force alias"
sleep "$ALIAS_WAIT"
ev "alias-restart"
k -n "$NS" rollout restart deploy/clf-alias >>"$LOG" 2>&1 || die "restart alias server"
settled "$ALIAS_PORT" 2 || die "alias server never answered v2 after the restart"
sleep 5
touch "$OUT/stop-alias"
wait "$pa" || die "alias poller"
log "alias: $(cat "$OUT/poll-alias.meta")"

log "== registry snapshot"
curl -sf "$TRACK/api/2.0/mlflow/model-versions/search?filter=name%3D%27clf%27" >"$OUT/registry-versions.json" || die "registry versions"
for run in $(jq -r '.model_versions[].run_id' "$OUT/registry-versions.json"); do
  curl -sf "$TRACK/api/2.0/mlflow/runs/get?run_id=$run" >"$OUT/registry-run-$run.json" || die "registry run $run"
done

log "== score"
python3 "$EXP/score.py" "$OUT" | tee -a "$LOG"
status=${PIPESTATUS[0]}
cleanup
exit "$status"
