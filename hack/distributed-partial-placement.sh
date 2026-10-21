#!/usr/bin/env bash
# Runs the partial-placement study registered in experiments/distributed-partial-placement/README.md.
#
# It builds a throwaway kind cluster `partial` from this tree, runs the registered eight runs in their registered
# order, and deletes the cluster at the end (KEEP=1 keeps it).
# The cluster setup repeats hack/multi-pod-ddp.sh's rather than sourcing it, so that harness stays byte-identical
# to the version its recorded run used.
#
# Evidence goes to hack/distributed-partial-placement-<UTC>/, and experiments/distributed-partial-placement/analyze.py
# scores it.
# Usage: hack/distributed-partial-placement.sh [setting:scenario:rep ...]   (default: the registered eight)
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

CLUSTER=partial
CONTEXT=kind-$CLUSTER
NS=partial
CQ=gpu-$NS
SQUAT_NS=squat
SQUAT_POD=squatter
SYS=gpu-platform-control-plane-system
TAG=partial
IMG=cpu-ddp:torch251
KUEUE_VERSION=v0.18.3
CERT_MANAGER_VERSION=v1.21.1
# The registered window per run, and when the `late` scenario frees the second worker's device.
# Overridable only to rehearse the harness; analyze.py voids any run whose recorded window is not the registered one.
WINDOW=${WINDOW:-600}
LATE_AT=${LATE_AT:-300}
# Long enough that a stranded rank has no reason of its own to stop inside the window.
RENDEZVOUS_TIMEOUT=1500
OUT=hack/distributed-partial-placement-$(date -u +%Y%m%dT%H%M%SZ)
LOG=$OUT/log.txt
mkdir -p "$OUT"

RUNS=("$@")
[ ${#RUNS[@]} -gt 0 ] || RUNS=(
  off:never:1 off:late:1 off:never:2 off:late:2
  ready-timeout:never:1 ready-timeout:late:1 ready-timeout:never:2 ready-timeout:late:2
)

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
# A setup failure voids the whole study; it is written where analyze.py reads it, so it is never scored as a run.
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
python3 -c 'import yaml' 2>>"$LOG" || die "python3 has no yaml module"

{
  echo "commit=$(git rev-parse HEAD)"
  echo "dirty_files=$(git status --porcelain | wc -l)"
  echo "kind=$(kind version)"
  echo "kubectl=$(kubectl version --client -o json | python3 -c 'import json,sys;print(json.load(sys.stdin)["clientVersion"]["gitVersion"])')"
  echo "kueue=$KUEUE_VERSION"
  echo "cert_manager=$CERT_MANAGER_VERSION"
  echo "train_py_sha256=$(sha256sum experiments/cpu-ddp/train.py | cut -d' ' -f1)"
  echo "window=$WINDOW late_at=$LATE_AT rendezvous_timeout=$RENDEZVOUS_TIMEOUT"
  echo "runs=${RUNS[*]}"
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
# The squatter needs an image the nodes already hold, so it pulls nothing and starts at once.
SQUAT_IMG=$IMG

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
# One device per worker is what makes one occupied device strand one rank.
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
WORKERS=$(k get nodes -l '!node-role.kubernetes.io/control-plane' -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}')
SQUAT_NODE=$(awk '{print $2}' <<<"$WORKERS")
[ -n "$SQUAT_NODE" ] || die "no second worker in '$WORKERS'"
echo "workers=$WORKERS squat_node=$SQUAT_NODE" >>"$OUT/provenance.txt"

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
apiVersion: v1
kind: Namespace
metadata:
  name: $SQUAT_NS
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
  nominal=$(k get clusterqueue "$CQ" -o jsonpath='{.spec.resourceGroups[0].flavors[0].resources[0].nominalQuota}' 2>>"$LOG")
  lq=$(k -n "$NS" get localqueue "$CQ" -o name 2>>"$LOG")
  [ "$nominal" = 2 ] && [ -n "$lq" ] && break
  sleep 3
done
[ "$nominal" = 2 ] && [ -n "$lq" ] || die "policy did not produce ClusterQueue $CQ with nominal 2 and its LocalQueue (nominal='$nominal' lq='$lq')"
k get clusterqueue "$CQ" -o yaml >"$OUT/setup-clusterqueue.yaml" 2>&1

# set_kueue writes the registered setting into kueue-manager-config and restarts Kueue, recording what it can show
# about the setting being in force; analyze.py judges it.
set_kueue() {
  local setting=$1 dir=$OUT/settings/$1 before
  mkdir -p "$dir"
  k -n kueue-system get configmap kueue-manager-config -o json >"$dir/configmap-before.json" 2>>"$LOG" || die "read kueue config"
  python3 - "$setting" "$dir/configmap-before.json" "$dir/controller_manager_config.yaml" <<'PY' || die "edit kueue config"
import json, sys, yaml
setting, src, dst = sys.argv[1:]
cm = json.load(open(src))
cfg = yaml.safe_load(cm["data"]["controller_manager_config.yaml"])
assert cfg["apiVersion"] == "config.kueue.x-k8s.io/v1beta2", cfg["apiVersion"]
cfg.pop("waitForPodsReady", None)
if setting == "ready-timeout":
    cfg["waitForPodsReady"] = {
        "timeout": "120s", "recoveryTimeout": "120s", "blockAdmission": False,
        "requeuingStrategy": {"timestamp": "Eviction", "backoffBaseSeconds": 30,
                              "backoffMaxSeconds": 3600, "backoffLimitCount": 2},
    }
elif setting != "off":
    sys.exit(f"unknown setting {setting}")
open(dst, "w").write(yaml.safe_dump(cfg, sort_keys=True))
PY
  sha256sum "$dir/controller_manager_config.yaml" >"$dir/config.sha256"
  k -n kueue-system create configmap kueue-manager-config --from-file=controller_manager_config.yaml="$dir/controller_manager_config.yaml" \
    --dry-run=client -o yaml | k apply -f - >>"$LOG" 2>&1 || die "write kueue config"
  date -u +%Y-%m-%dT%H:%M:%SZ >"$dir/written-at.txt"
  before=$(k -n kueue-system get pods -l control-plane=controller-manager -o jsonpath='{.items[*].metadata.uid}' 2>>"$LOG")
  echo "$before" >"$dir/pods-before.txt"
  k -n kueue-system rollout restart deploy/kueue-controller-manager >>"$LOG" 2>&1 || die "restart kueue"
  k -n kueue-system rollout status deploy/kueue-controller-manager --timeout=300s >>"$LOG" 2>&1 || die "kueue rollout"
  # The old Pod can linger in Terminating after the rollout reports done; the record must show one Pod.
  for _ in $(seq 1 60); do
    [ "$(k -n kueue-system get pods -l control-plane=controller-manager -o name 2>>"$LOG" | wc -l)" = 1 ] && break
    sleep 2
  done
  k -n kueue-system get pods -l control-plane=controller-manager -o json >"$dir/pods-after.json" 2>>"$LOG" || die "read kueue pods"
  local pod
  pod=$(k -n kueue-system get pods -l control-plane=controller-manager -o jsonpath='{.items[0].metadata.name}' 2>>"$LOG")
  k -n kueue-system logs "$pod" >"$dir/controller-startup.log" 2>>"$LOG" || die "read kueue log"
  # Waiting for its webhook too: a Job created before it answers is refused, and that would read as the setting failing.
  k -n kueue-system wait --for=condition=Available deploy/kueue-controller-manager --timeout=300s >>"$LOG" 2>&1 || die "kueue Available"
  log "kueue setting $setting applied; $(grep -c 'Configuration loaded' "$dir/controller-startup.log") 'Configuration loaded' line(s)"
}

# isolated reports whether nothing of an earlier run is left; the run records the answer and analyze.py judges it.
isolated() {
  local dir=$1
  python3 - "$CONTEXT" "$NS" "$CQ" "$SQUAT_NS" >"$dir/isolation.json" <<'PY'
import json, subprocess, sys
ctx, ns, cq, squat = sys.argv[1:]
def get(*a):
    p = subprocess.run(["kubectl", "--context", ctx, *a, "-o", "json"], capture_output=True, text=True)
    return json.loads(p.stdout) if p.returncode == 0 else {"error": p.stderr.strip()[:300]}
left = get("-n", ns, "get", "jobs,pods,workloads.kueue.x-k8s.io")
q = get("get", "clusterqueue", cq)
s = get("-n", squat, "get", "pods")
nodes = get("get", "nodes", "-l", "!node-role.kubernetes.io/control-plane")
reserved = [r for f in (q.get("status") or {}).get("flavorsReservation") or [] for r in f.get("resources") or []
            if r.get("name") == "nvidia.com/gpu"]
print(json.dumps({
    "leftovers": [o["kind"] + "/" + o["metadata"]["name"] for o in left.get("items", [])],
    "readErrors": [x["error"] for x in (left, q, s, nodes) if "error" in x],
    "gpuReserved": [r.get("total") for r in reserved],
    "squatters": [p["metadata"]["name"] for p in s.get("items", [])],
    "allocatable": [n["status"]["allocatable"].get("nvidia.com/gpu") for n in nodes.get("items", [])],
}, sort_keys=True))
PY
  python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
ok = not d["leftovers"] and not d["readErrors"] and not d["squatters"] and d["gpuReserved"] in ([], ["0"], [0]) and d["allocatable"]==["1","1"]
sys.exit(0 if ok else 1)' "$dir/isolation.json"
}

# stream_logs follows one rank Pod's log until its container has terminated, restarting a stream that ends early.
stream_logs() {
  local pod=$1 uid=$2 dir=$3 n=0 state
  while :; do
    n=$((n + 1))
    k -n "$NS" logs -f "$pod" >"$dir/log-$uid.$n.txt" 2>>"$dir/log-$uid.err"
    state=$(k -n "$NS" get pod "$pod" -o jsonpath='{.metadata.uid} {.status.containerStatuses[0].state.terminated.reason}' 2>>"$dir/log-$uid.err")
    # Gone, replaced under the same name, or terminated: nothing more will be written.
    [ "${state%% *}" = "$uid" ] || break
    [ -n "${state#* }" ] && break
    sleep 1
  done
}

# collect_logs starts one stream per rank Pod as soon as its container has started.
collect_logs() {
  local name=$1 dir=$2 started=" "
  # shellcheck disable=SC2046  # word splitting of the pid list is intended
  trap 'kill $(jobs -p) 2>>"$LOG"; exit 0' TERM
  while :; do
    for pair in $(k -n "$NS" get pods -l "platform.lkhun9311.github.io/mltrainingjob=$name" -o json 2>>"$LOG" | python3 -c 'import json,sys
try: items=json.load(sys.stdin)["items"]
except Exception: items=[]
for p in items:
    cs=(p.get("status",{}).get("containerStatuses") or [{}])[0]
    if cs.get("state",{}).get("running") or cs.get("state",{}).get("terminated"):
        print(p["metadata"]["name"]+":"+p["metadata"]["uid"])'); do
      case "$started" in *" $pair "*) continue ;; esac
      started="$started$pair "
      stream_logs "${pair%%:*}" "${pair##*:}" "$dir" &
    done
    sleep 1
  done
}

# run_one runs one registered run: isolation check, squatter, job, sampling for the window, then teardown.
run_one() {
  local setting=$1 scenario=$2 rep=$3 name dir t0 until deleted=""
  name="pp-${setting/ready-timeout/rt}-$scenario-$rep-$(date -u +%H%M%S)"
  dir=$OUT/runs/$setting-$scenario-$rep
  mkdir -p "$dir"
  echo "$setting $scenario $rep $name" >"$dir/run.txt"
  log "== run $setting $scenario $rep as $name"
  local ok=""
  for _ in $(seq 1 120); do isolated "$dir" && { ok=1; break; }; sleep 5; done
  [ -n "$ok" ] || log "run $name: NOT isolated after 600 s; recorded, and analyze.py voids it"
  cat <<EOF >"$dir/squatter.yaml"
apiVersion: v1
kind: Pod
metadata:
  name: $SQUAT_POD
  namespace: $SQUAT_NS
spec:
  nodeName: $SQUAT_NODE
  terminationGracePeriodSeconds: 0
  containers:
    - name: hold
      image: $SQUAT_IMG
      imagePullPolicy: IfNotPresent
      command: ["sleep", "infinity"]
      resources:
        limits:
          nvidia.com/gpu: 1
EOF
  k apply -f "$dir/squatter.yaml" >>"$LOG" 2>&1 || { log "run $name: squatter refused"; echo "squatter refused" >"$dir/VOID"; return; }
  k -n "$SQUAT_NS" wait --for=condition=Ready "pod/$SQUAT_POD" --timeout=120s >>"$LOG" 2>&1 ||
    { log "run $name: squatter not Ready"; echo "squatter not Ready" >"$dir/VOID"; }
  cat <<EOF >"$dir/mltrainingjob.yaml"
apiVersion: platform.lkhun9311.github.io/v1
kind: MLTrainingJob
metadata:
  name: $name
  namespace: $NS
spec:
  queue: $CQ
  image: $IMG
  gpuCount: 1
  distributed:
    worldSize: 2
  command:
    - sh
    - -c
    - |
      export DDP_RUN_ID=$name DDP_OUT_DIR=/tmp/evidence OMP_NUM_THREADS=1 DDP_RENDEZVOUS_TIMEOUT_SECONDS=$RENDEZVOUS_TIMEOUT
      exec python /work/train.py
EOF
  # The watches start before the job exists, so its first events are in them; they are the record of transitions.
  local watchers=() kind
  for kind in workloads.kueue.x-k8s.io mltrainingjobs jobs pods; do
    python3 experiments/distributed-partial-placement/watch.py "$CONTEXT" "$NS" "$kind" "$(($(date +%s) + WINDOW + 30))" \
      "$dir/watch.${kind%%.*}.jsonl" 2>>"$dir/watch.err" &
    watchers+=($!)
  done
  COLLECTORS+=("${watchers[@]}")
  sleep 2
  k apply -f "$dir/mltrainingjob.yaml" >>"$LOG" 2>&1 || {
    log "run $name: create refused"
    echo "create refused" >"$dir/VOID"
    kill "${watchers[@]}" 2>>"$LOG"
    return
  }
  t0=$(date +%s)
  date -u -d "@$t0" +%Y-%m-%dT%H:%M:%SZ >"$dir/created-at.txt"
  until=$((t0 + WINDOW))
  collect_logs "$name" "$dir" &
  local logger=$!
  python3 experiments/distributed-partial-placement/sample.py "$CONTEXT" "$NS" "$name" "$CQ" "$SQUAT_NS" "$SQUAT_POD" \
    "$until" "$dir/timeline.jsonl" 2>>"$dir/sampler.err" &
  local sampler=$!
  COLLECTORS+=("$logger" "$sampler")
  if [ "$scenario" = late ]; then
    while [ "$(date +%s)" -lt $((t0 + LATE_AT)) ]; do sleep 1; done
    deleted=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)
    k -n "$SQUAT_NS" delete pod "$SQUAT_POD" --wait=false >>"$LOG" 2>&1 || log "run $name: squatter delete failed"
    echo "$deleted" >"$dir/squatter-deleted-at.txt"
  fi
  wait "$sampler"
  log "run $name: window over; phase '$(k -n "$NS" get mltrainingjob "$name" -o jsonpath='{.status.phase}' 2>>"$LOG")'"
  sleep 5
  kill "$logger" "${watchers[@]}" 2>>"$LOG"
  wait "$logger" "${watchers[@]}" 2>>"$LOG"
  k -n "$NS" get mltrainingjob "$name" -o json >"$dir/final-mltj.json" 2>>"$LOG"
  k -n "$NS" get workloads -o json >"$dir/final-workloads.json" 2>>"$LOG"
  k -n "$NS" get events -o json >"$dir/events.json" 2>>"$LOG"
  k -n "$NS" delete mltrainingjob "$name" --wait=true --timeout=180s >>"$LOG" 2>&1 || log "run $name: job delete did not finish"
  k -n "$SQUAT_NS" delete pod "$SQUAT_POD" --ignore-not-found --wait=true --timeout=60s >>"$LOG" 2>&1 || log "run $name: squatter delete did not finish"
}

current=""
for spec in "${RUNS[@]}"; do
  IFS=: read -r setting scenario rep <<<"$spec"
  case "$setting:$scenario" in off:never | off:late | ready-timeout:never | ready-timeout:late) ;; *) die "unknown run $spec" ;; esac
  [ "$setting" = "$current" ] || { set_kueue "$setting"; current=$setting; }
  run_one "$setting" "$scenario" "$rep"
done
log "== done; scoring"
python3 experiments/distributed-partial-placement/analyze.py "$OUT" | tee -a "$LOG"
exit "${PIPESTATUS[0]}"
