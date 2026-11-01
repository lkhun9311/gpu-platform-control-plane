#!/usr/bin/env bash
# Runs the whole-job restart of a distributed MLTrainingJob through the faults the design names, on a throwaway kind
# cluster `rst` built from this tree, and deletes it at the end (KEEP=1 keeps it).
#
# The design is docs/superpowers/specs/2026-11-01-distributed-restart-design.md; the cases are its kind rows, and
# experiments/distributed-restart/score_kind.py reads the evidence this writes to hack/distributed-restart-kind-<UTC>/.
# Usage: hack/distributed-restart-kind.sh [case ...]
#   (default: reference rank-failed stale-workload deactivated node-lost; node-lost removes a node, so it runs last)
#   cut-writer and its negative control cut-writer-early each remove a node too, so each runs on a cluster of its own:
#   hack/distributed-restart-kind.sh reference cut-writer
#   hack/distributed-restart-kind.sh reference cut-writer-early
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

CLUSTER=rst
CONTEXT=kind-$CLUSTER
NS=rst
SYS=gpu-platform-control-plane-system
TAG=rst
IMG=distributed-restart:torch251
KUEUE_VERSION=v0.18.3
CERT_MANAGER_VERSION=v1.21.1
STEPS=20
CASE_BUDGET=420
OUT=hack/distributed-restart-kind-$(date -u +%Y%m%dT%H%M%SZ)
LOG=$OUT/log.txt
mkdir -p "$OUT"
# The ranks write as root inside the kind nodes, so the host directory is emptied from a node before it is removed.
SHARED=$(mktemp -d "${TMPDIR:-/tmp}/rst-shared-XXXXXX")
chmod 777 "$SHARED"

CASES=("$@")
[ ${#CASES[@]} -gt 0 ] || CASES=(reference rank-failed stale-workload deactivated node-lost)

log() { echo -e "$(date -u +%H:%M:%S) $*" | tee -a "$LOG"; }
k() { kubectl --context "$CONTEXT" "$@"; }
now() { python3 -c 'import datetime;print(datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="milliseconds"))'; }
COLLECTORS=()
PAUSED=""
cleanup() {
  for p in "${COLLECTORS[@]}"; do kill "$p" 2>>"$LOG"; done
  [ -n "${SAMPLER:-}" ] && { kill "$SAMPLER" 2>>"$LOG" || log "cleanup: sampler $SAMPLER not killed"; }
  # A paused node container cannot be deleted cleanly, and left paused it holds its memory after the run.
  [ -n "$PAUSED" ] && { docker unpause "$PAUSED" >>"$LOG" 2>&1 || log "cleanup: unpause $PAUSED failed"; }
  # Any running worker will do, since they all mount the same directory; a case may have killed one of them.
  local emptied=""
  for n in "$CLUSTER-worker" "$CLUSTER-worker2" "$CLUSTER-worker3"; do
    [ "$(docker inspect -f '{{.State.Running}}' "$n" 2>>"$LOG")" = true ] || continue
    docker exec "$n" sh -c 'find /shared -mindepth 1 -delete' >>"$LOG" 2>&1 && { emptied=$n; break; }
  done
  [ -n "$emptied" ] || log "cleanup: emptying /shared failed: no running worker could"
  rmdir "$SHARED" 2>>"$LOG" || log "cleanup: $SHARED not removed"
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
# A setup failure voids the run; the scorer refuses a directory holding VOID.
die() {
  log "VOID: $*"
  echo "$*" >"$OUT/VOID"
  { k get pods -A -o wide; k get events -A --sort-by=.lastTimestamp | tail -60; } >>"$OUT/failure-state.txt" 2>&1
  exit 1
}
retry() {
  for _ in $(seq 1 40); do "$@" && return 0; sleep 3; done
  return 1
}

# A case name the script does not know, or one given twice, would otherwise run as nothing and be scored as absent.
# Each of node-lost, cut-writer and cut-writer-early takes a worker away for good, and three workers leave a world size
# of two only one node to lose, so a run holds at most one of them.
seen=" "
removing=0
for c in "${CASES[@]}"; do
  case "$c" in
    reference | rank-failed | stale-workload | deactivated) ;;
    node-lost | cut-writer | cut-writer-early) removing=$((removing + 1)) ;;
    *) die "unknown case '$c'" ;;
  esac
  case "$seen" in *" $c "*) die "case '$c' given twice" ;; esac
  seen="$seen$c "
done
[ "$removing" -le 1 ] || die "more than one of node-lost, cut-writer and cut-writer-early in one run"
# The scorer compares every restarted case with the reference of its own run.
case "$seen" in *" reference "*) ;; *" rank-failed "* | *" stale-workload "* | *" node-lost "* | *" cut-writer "* | *" cut-writer-early "*)
  die "a restarted case needs reference in the same run" ;; esac

export PATH="$PWD/bin:$PATH"
command -v kustomize >/dev/null || make kustomize >>"$LOG" 2>&1 || die "make kustomize"
for tool in docker kind kubectl kustomize python3; do command -v "$tool" >/dev/null || die "missing tool $tool"; done
{
  echo "commit=$(git rev-parse HEAD)"
  # Every tracked file, since go.mod, the Dockerfiles and the Makefile feed the images as much as the sources do, and
  # untracked files only where a build would pick them up; this run's own evidence directory is untracked too.
  echo "dirty_files=$(($(git status --porcelain --untracked-files=no | wc -l) + $(git status --porcelain -- cmd internal api config experiments/distributed-restart | grep -c '^??')))"
  echo "kind=$(kind version)"
  echo "kueue=$KUEUE_VERSION"
  echo "cert_manager=$CERT_MANAGER_VERSION"
  echo "train_py_sha256=$(sha256sum experiments/distributed-restart/train.py | cut -d' ' -f1)"
  echo "steps=$STEPS"
  echo "cases=${CASES[*]}"
} >"$OUT/provenance.txt"
log "provenance: $(tr '\n' ' ' <"$OUT/provenance.txt")"

log "== images"
docker build -q -t "$IMG" experiments/distributed-restart >>"$LOG" 2>&1 || die "image build"
echo "workload_image=$(docker image inspect "$IMG" --format '{{.Id}}')" >>"$OUT/provenance.txt"
make docker-build IMG=controller:$TAG >>"$LOG" 2>&1 || die "operator image"
make docker-build-gpu-simulator GPU_SIMULATOR_IMG=gpu-simulator:$TAG >>"$LOG" 2>&1 || die "simulator image"

log "== cluster $CLUSTER"
grep -qx "$CLUSTER" <<<"$(kind get clusters 2>>"$LOG")" && { kind delete cluster --name "$CLUSTER" >>"$LOG" 2>&1 || die "delete old cluster"; }
sed "s|SHARED_DIR|$SHARED|" hack/kind-config-restart.yaml >"$OUT/kind-config.yaml"
kind create cluster --name "$CLUSTER" --config "$OUT/kind-config.yaml" >>"$LOG" 2>&1 || die "kind create"
echo "node_image=$(docker inspect "$CLUSTER-worker" --format '{{.Config.Image}}')" >>"$OUT/provenance.txt"
for img in controller:$TAG gpu-simulator:$TAG "$IMG"; do
  kind load docker-image "$img" --name "$CLUSTER" >>"$LOG" 2>&1 || die "kind load $img"
done
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
# One device per worker places the two ranks on two nodes by construction, and leaves two after one node is lost.
k -n "$SYS" set env ds/gpu-simulator FAKE_GPU_COUNT=1 >>"$LOG" 2>&1 || die "simulator count"
k -n "$SYS" rollout status ds/gpu-simulator --timeout=180s >>"$LOG" 2>&1 || die "simulator rollout"
gpus=""
for _ in $(seq 1 60); do
  gpus=$(k get nodes -l '!node-role.kubernetes.io/control-plane' -o jsonpath='{range .items[*]}{.status.allocatable.nvidia\.com/gpu}{" "}{end}')
  [ "$gpus" = "1 1 1 " ] && break
  sleep 3
done
[ "$gpus" = "1 1 1 " ] || die "workers do not each advertise one nvidia.com/gpu (allocatable: '$gpus')"

# The controllers run on the control-plane node, so freezing a worker can only take ranks with it.
# One rehearsal froze the worker the operator happened to run on, and nothing reconciled the job after that.
pin='{"spec":{"template":{"spec":{"nodeSelector":{"node-role.kubernetes.io/control-plane":""},
  "tolerations":[{"key":"node-role.kubernetes.io/control-plane","operator":"Exists","effect":"NoSchedule"}]}}}}'
for dep in "$SYS/${OPDEP#*/}" kueue-system/kueue-controller-manager cert-manager/cert-manager \
  cert-manager/cert-manager-webhook cert-manager/cert-manager-cainjector kube-system/coredns; do
  # Retried: Kueue's webhook mutates Deployments and refuses connections for a while after its own rollout.
  retry k -n "${dep%%/*}" patch deploy "${dep#*/}" --type=strategic -p "$pin" >>"$LOG" 2>&1 || die "pin $dep"
  k -n "${dep%%/*}" rollout status deploy "${dep#*/}" --timeout=240s >>"$LOG" 2>&1 || die "rollout of pinned $dep"
done
k get pods -A -o wide >"$OUT/placement.txt" 2>>"$LOG"
for ns in "$SYS" kueue-system cert-manager kube-system; do
  off=$(k -n "$ns" get pods -o jsonpath='{range .items[?(@.metadata.ownerReferences[0].kind=="ReplicaSet")]}{.spec.nodeName}{"\n"}{end}' |
    grep -v "^$CLUSTER-control-plane$" | grep -c .)
  [ "$off" = 0 ] || die "$off controller Pod(s) in $ns run off the control plane (see placement.txt)"
done

log "== queue and shared volume"
k apply -f config/kueue/resourceflavor.yaml >>"$LOG" 2>&1 || die "resource flavor"
# shellcheck disable=SC2317  # called through retry
apply_setup() {
  cat <<EOF | k apply -f - >>"$LOG" 2>&1
apiVersion: v1
kind: Namespace
metadata:
  name: $NS
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
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: rst-shared
spec:
  capacity:
    storage: 1Gi
  accessModes: ["ReadWriteMany"]
  storageClassName: ""
  hostPath:
    path: /shared
    type: Directory
  claimRef:
    namespace: $NS
    name: shared
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: shared
  namespace: $NS
spec:
  accessModes: ["ReadWriteMany"]
  storageClassName: ""
  volumeName: rst-shared
  resources:
    requests:
      storage: 1Gi
EOF
}
retry apply_setup || die "queue and volume"
lq=""
for _ in $(seq 1 60); do
  lq=$(k -n "$NS" get localqueue "gpu-$NS" -o name 2>>"$LOG")
  bound=$(k -n "$NS" get pvc shared -o jsonpath='{.status.phase}')
  [ -n "$lq" ] && [ "$bound" = Bound ] && break
  sleep 3
done
[ -n "$lq" ] && [ "$bound" = Bound ] || die "no LocalQueue gpu-$NS or claim not Bound (lq='$lq' pvc='$bound')"

# sample appends one line of what the case is waiting on: the MLTrainingJob's status, every Job and Workload of the
# namespace with the attempt each belongs to, and the Nodes.
# A read that fails is named in the sample's errors, so an empty list it stands in for is never read as "none existed".
# The optional third and fourth arguments let a background sampler write its own file through its own scratch files.
sample() {
  local name=$1 dir=$2 out=${3:-timeline.jsonl} tag=${4:-fg} started errors=""
  started=$(now)
  k -n "$NS" get mltrainingjob "$name" -o json >"$dir/.$tag.mltj.json" 2>>"$LOG" || { echo null >"$dir/.$tag.mltj.json"; errors="$errors mltj"; }
  k -n "$NS" get jobs -o json >"$dir/.$tag.jobs.json" 2>>"$LOG" || { echo '{"items":[]}' >"$dir/.$tag.jobs.json"; errors="$errors jobs"; }
  k -n "$NS" get workloads -o json >"$dir/.$tag.wls.json" 2>>"$LOG" || { echo '{"items":[]}' >"$dir/.$tag.wls.json"; errors="$errors workloads"; }
  k get nodes -o json >"$dir/.$tag.nodes.json" 2>>"$LOG" || { echo '{"items":[]}' >"$dir/.$tag.nodes.json"; errors="$errors nodes"; }
  python3 - "$(now)" "$dir" "$tag" "$started" "$errors" >>"$dir/$out" <<'PY'
import json, sys
d, tag = sys.argv[2], sys.argv[3]
load = lambda f: json.load(open(f"{d}/.{tag}.{f}"))
mltj, jobs, wls, nodes = load("mltj.json"), load("jobs.json"), load("wls.json"), load("nodes.json")
attempt = "platform.lkhun9311.github.io/mltrainingjob-attempt"
ready = lambda n: next((c["status"] for c in n["status"].get("conditions", []) if c["type"] == "Ready"), None)
print(json.dumps({
    "observed": sys.argv[1],
    "started": sys.argv[4],
    "errors": sys.argv[5].split(),
    "status": (mltj or {}).get("status"),
    "annotations": ((mltj or {}).get("metadata") or {}).get("annotations"),
    "jobs": [{"name": j["metadata"]["name"], "uid": j["metadata"]["uid"], "attempt": j["metadata"].get("labels", {}).get(attempt),
              "created": j["metadata"].get("creationTimestamp"),
              "deleting": "deletionTimestamp" in j["metadata"], "suspend": j["spec"].get("suspend"),
              "conditions": [f"{c['type']}:{c.get('reason')}" for c in (j.get("status") or {}).get("conditions", [])
                             if c.get("status") == "True"],
              "active": (j.get("status") or {}).get("active", 0)} for j in jobs["items"]],
    "workloads": [{"name": w["metadata"]["name"], "uid": w["metadata"]["uid"], "finalizers": w["metadata"].get("finalizers"),
                   "deleting": "deletionTimestamp" in w["metadata"], "active": w["spec"].get("active", True)}
                  for w in wls["items"]],
    "nodes": {n["metadata"]["name"]: ready(n) for n in nodes["items"]},
}, sort_keys=True))
PY
}

# field prints one value of the MLTrainingJob's status computed by a Python expression over `s`, or nothing.
field() {
  k -n "$NS" get mltrainingjob "$1" -o json 2>>"$LOG" | python3 -c "
import json,sys
try:
    s=json.load(sys.stdin).get('status') or {}
    a=s.get('attempts') or []
    v=$2
    print('' if v is None else v)
except Exception as e:
    print('', end='')"
}

# wait_for samples once a second until the expression is truthy or the budget is spent; it never dies, so a case
# that does not reach a state is scored as such rather than voiding the run.
wait_for() {
  local name=$1 dir=$2 expr=$3 budget=$4 t0=$SECONDS v
  while ((SECONDS - t0 < budget)); do
    sample "$name" "$dir"
    v=$(field "$name" "$expr")
    [ -n "$v" ] && [ "$v" != False ] && return 0
    sleep 1
  done
  log "  timed out after $budget s waiting for: $expr"
  return 1
}

# hold samples for the given seconds; the scorer checks what each sample of the window shows.
hold() {
  local name=$1 dir=$2 seconds=$3 t0=$SECONDS
  while ((SECONDS - t0 < seconds)); do sample "$name" "$dir"; sleep 1; done
}

# wait_steps waits until the ranks' own records show n steps: Ready Pods are not yet training, and a fault injected
# between the two would test a job that had not started.
wait_steps() { wait_events "$1" "$2" step "$3"; }

# wait_events waits until the ranks' own records show n records of one event.
wait_events() {
  local name=$1 dir=$2 event=$3 n=$4 t0=$SECONDS got
  while ((SECONDS - t0 < 180)); do
    sample "$name" "$dir"
    got=$(cat "$dir"/log-*.txt 2>>"$LOG" | grep -c "\"event\": \"$event\"")
    [ "${got:-0}" -ge "$n" ] && return 0
    sleep 1
  done
  log "  timed out after 180 s waiting for $n $event records"
  return 1
}

mark() { echo "{\"at\": \"$(now)\", \"mark\": \"$2\"}" >>"$1/marks.jsonl"; }

# listing prints every file and directory of a job's tree on the shared volume as "<mtime> <size> <path>", read from the
# host side of the bind mount, so it needs no node and no API server.
listing() { (cd "$SHARED" && find "$1" -printf '%T@ %s %p\n' | sort -k3) 2>>"$LOG"; }

# The background sampler keeps sampling while the foreground acts, so no stretch of a case goes unobserved between the
# actions it takes; it writes its own file, which the scorer merges with the foreground's.
SAMPLER=""
start_sampler() {
  local name=$1 dir=$2
  # shellcheck disable=SC2317  # the trap runs in the background subshell
  (trap 'exit 0' TERM; while :; do sample "$name" "$dir" timeline-bg.jsonl bg; sleep 0.5; done) &
  SAMPLER=$!
}
stop_sampler() {
  [ -n "$SAMPLER" ] || return 0
  kill "$SAMPLER" 2>>"$LOG"
  wait "$SAMPLER" 2>>"$LOG"
  SAMPLER=""
}

collect_pods() {
  local name=$1 dir=$2 started=" "
  # shellcheck disable=SC2046  # word splitting of the pid list is intended
  trap 'kill $(jobs -p) 2>>"$LOG"; exit 0' TERM
  while :; do
    k -n "$NS" get pods -l "platform.lkhun9311.github.io/mltrainingjob=$name" -o json >"$dir/.pods.json" 2>>"$LOG" || { sleep 1; continue; }
    for pair in $(python3 -c 'import json,sys
for p in json.load(open(sys.argv[1]))["items"]:
    cs=(p.get("status",{}).get("containerStatuses") or [{}])[0]
    if cs.get("state",{}).get("running") or cs.get("state",{}).get("terminated"):
        m=p["metadata"]
        print(":".join([m["name"], m["uid"], p["spec"].get("nodeName") or "",
                        m.get("labels",{}).get("platform.lkhun9311.github.io/mltrainingjob-attempt",""),
                        m.get("annotations",{}).get("batch.kubernetes.io/job-completion-index","")]))' "$dir/.pods.json"); do
      case "$started" in *" $pair "*) continue ;; esac
      started="$started$pair "
      IFS=: read -r pod uid node attempt index <<<"$pair"
      # The attempt and the rank bind a Pod, and the node it ran on, to the records its rank writes.
      echo "{\"pod\": \"$pod\", \"uid\": \"$uid\", \"node\": \"$node\", \"attempt\": \"$attempt\", \"rank\": \"$index\"}" >>"$dir/pods.jsonl"
      k -n "$NS" logs -f "$pod" >"$dir/log-$uid.txt" 2>>"$LOG" &
    done
    sleep 1
  done
}

submit() {
  local name=$1 dir=$2 env=$3
  cat <<EOF >"$dir/mltrainingjob.yaml"
apiVersion: platform.lkhun9311.github.io/v1
kind: MLTrainingJob
metadata:
  name: $name
  namespace: $NS
spec:
  queue: gpu-$NS
  image: $IMG
  gpuCount: 1
  distributed:
    worldSize: 2
    maxRestarts: 1
  stateVolume:
    claimName: shared
    mountPath: /shared
  command:
    - sh
    - -c
    - |
      export CKPT_RUN_ID=$name CKPT_DIR=/shared CKPT_JOB_ID=$name CKPT_STEPS=$STEPS CKPT_STEP_SLEEP=1 OMP_NUM_THREADS=1 $env
      python /work/train.py
EOF
  # python is started without exec: as the container's PID 1 it cannot SIGKILL itself, an injected kill is a no-op,
  # and the rank trains on. The first rehearsal ran it with exec, and its killed ranks finished their jobs on attempt 1.
  k apply -f "$dir/mltrainingjob.yaml" >>"$LOG" 2>&1 || { log "  create refused"; echo "create refused" >"$dir/VOID"; return 1; }
  collect_pods "$name" "$dir" &
  COLLECTORS+=($!)
}

finish() {
  local name=$1 dir=$2
  sleep 5
  kill "${COLLECTORS[-1]}" 2>>"$LOG"
  wait "${COLLECTORS[-1]}" 2>>"$LOG"
  stop_sampler
  k -n "$NS" get mltrainingjob "$name" -o json >"$dir/final-mltj.json" 2>>"$LOG"
  k -n "$NS" get job "$name" -o json >"$dir/final-job.json" 2>>"$LOG"
  # Read from the host side of the bind mount, which every node shares, so a node a case killed is not needed for it.
  (cd "$SHARED" && find "$name" -type f | sort) >"$dir/shared-files.txt" 2>>"$LOG"
  listing "$name" >"$dir/listing-final.txt"
  if compgen -G "$SHARED/$name/a*/heartbeat-rank-*.jsonl" >/dev/null; then
    mkdir -p "$dir/volume"
    for f in "$SHARED/$name"/a*/heartbeat-rank-*.jsonl; do
      cp "$f" "$dir/volume/$(basename "$(dirname "$f")")-$(basename "$f")" 2>>"$LOG" || log "  copying $f failed"
    done
  fi
  echo "$name" >"$dir/name"
  log "  phase '$(field "$name" "s.get('phase')")', attempts $(field "$name" "len(a)")"
  k -n "$NS" delete mltrainingjob "$name" --wait=true --timeout=120s >>"$LOG" 2>&1 || log "  delete of $name did not finish"
}

# void_case ends a case whose fault could not be injected: its evidence would show a job that was never faulted.
void_case() {
  local name=$1 dir=$2
  shift 2
  log "  VOID case: $*"
  echo "$*" >"$dir/VOID"
  kill "${COLLECTORS[-1]}" 2>>"$LOG"
  stop_sampler
  k -n "$NS" delete mltrainingjob "$name" --wait=true --timeout=120s >>"$LOG" 2>&1 || log "  delete of $name did not finish"
}

workload_of() { field "$1" "a[0].get('workloadName')"; }
rank_node() {
  k -n "$NS" get pods -l "platform.lkhun9311.github.io/mltrainingjob=$1" \
    -o jsonpath="{range .items[?(@.metadata.annotations.batch\.kubernetes\.io/job-completion-index==\"$2\")]}{.spec.nodeName}{end}"
}

# fence writes the acknowledgement that the victim is off, with a mark on each side of the write.
fence() {
  local name=$1 dir=$2 victim=$3
  mark "$dir" "fence-start $victim"
  k -n "$NS" annotate --overwrite mltrainingjob "$name" "platform.lkhun9311.github.io/fenced-nodes=$victim" >>"$LOG" 2>&1 ||
    { void_case "$name" "$dir" "annotating the fence failed"; return 2; }
  mark "$dir" "fenced $victim"
}

# cut_writer runs cut-writer, or its negative control cut-writer-early, from the point where both ranks are training.
# Rank 1's node loses the API server and keeps its rank, which goes on writing to the shared volume; the Node is then
# deleted, and the next attempt must wait for the fencing acknowledgement.
# In cut-writer the machine is stopped and seen to have stopped writing before the acknowledgement is written.
# In cut-writer-early the acknowledgement comes first, as an operator who trusted it too soon would write it, and the
# machine is stopped only after attempt 2 has been writing for 20 s.
cut_writer() {
  local case=$1 name=$2 dir=$3 victim cp4 cp6 fam ipt ip ready t0 prev cur same
  victim=$(rank_node "$name" 1)
  [ -n "$victim" ] || { void_case "$name" "$dir" "no node for rank 1"; return 2; }
  docker inspect "$victim" --format '{{.Id}}' >"$dir/victim-id.txt" 2>>"$LOG" || { void_case "$name" "$dir" "no container $victim"; return 2; }
  cp4=$(docker inspect "$CLUSTER-control-plane" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>>"$LOG")
  cp6=$(docker inspect "$CLUSTER-control-plane" --format '{{range .NetworkSettings.Networks}}{{.GlobalIPv6Address}}{{end}}' 2>>"$LOG")
  [ -n "$cp4" ] || { void_case "$name" "$dir" "no IPv4 address for $CLUSTER-control-plane"; return 2; }
  echo "victim=$victim control_plane_ipv4=$cp4 control_plane_ipv6=$cp6" >"$dir/cut.txt"

  mark "$dir" "cut-start $victim"
  # The kubelet, kube-proxy and kindnet run in the node's root namespace and reach the API server at the control plane's
  # address; Pods reach it through the Service, whose DNAT leaves that address for FORWARD; and the API server reaches the
  # kubelet on 10250 for logs and exec.
  # The inbound half of connections already open is dropped too: a receiver takes data whose ACKs never leave, so a watch
  # the kubelet already holds could otherwise still hear of its Pod's deletion and stop the rank this case keeps running.
  # Pod-to-Pod traffic, gloo's and DNS's, is addressed to Pods and is not matched, and the volume is a bind mount.
  for fam in 4 6; do
    ipt=iptables ip=$cp4
    [ "$fam" = 6 ] && { ipt=ip6tables ip=$cp6; }
    [ -n "$ip" ] || continue
    { docker exec "$victim" "$ipt" -I OUTPUT 1 -d "$ip" -p tcp --dport 6443 -j DROP &&
      docker exec "$victim" "$ipt" -I INPUT 1 -s "$ip" -p tcp --sport 6443 -j DROP &&
      docker exec "$victim" "$ipt" -I FORWARD 1 -d "$ip" -p tcp --dport 6443 -j DROP &&
      docker exec "$victim" "$ipt" -I INPUT 1 -s "$ip" -p tcp --dport 10250 -j DROP; } >>"$LOG" 2>&1 ||
      { void_case "$name" "$dir" "inserting the IPv$fam rules on $victim failed"; return 2; }
  done
  mark "$dir" "cut $victim"
  { docker exec "$victim" iptables -S; docker exec "$victim" ip6tables -S; } >"$dir/cut-rules.txt" 2>&1 ||
    { void_case "$name" "$dir" "listing the rules on $victim failed"; return 2; }

  # The kubelet can no longer renew its lease, so the node lifecycle controller marks the Node not Ready.
  t0=$SECONDS ready=True
  while ((SECONDS - t0 < 180)); do
    ready=$(k get node "$victim" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>>"$LOG") || ready=read-failed
    { [ "$ready" = Unknown ] || [ "$ready" = False ]; } && break
    sleep 1
  done
  { [ "$ready" = Unknown ] || [ "$ready" = False ]; } || { log "  $victim not seen not Ready 180 s after the cut (last '$ready')"; return 1; }
  # One more sample before the deletion, so the timeline the scorer reads holds the not-Ready Node and not only this loop.
  sample "$name" "$dir"
  mark "$dir" "notready $victim $ready"

  mark "$dir" "node-delete-start $victim"
  k delete node "$victim" --wait=false >>"$LOG" 2>&1 || { void_case "$name" "$dir" "deleting node $victim failed"; return 2; }
  mark "$dir" "node-deleted $victim"
  # Pod garbage collection removes the Pods of a Node that no longer exists; then only the fencing remains.
  # A controller that let the deleted Node count as fenced would start attempt 2 instead, and the wait ends on that too,
  # so the scorer sees a premature attempt rather than a timeout.
  wait_for "$name" "$dir" "'to be fenced' in (a[0].get('waitingFor') or '') or len(a) > 1" 300 || return 1
  mark "$dir" "fence-hold-start"
  listing "$name" >"$dir/listing-hold-start.txt"
  hold "$name" "$dir" 10
  # Neither an unrelated annotation nor a fence naming another node may release the barrier.
  k -n "$NS" annotate --overwrite mltrainingjob "$name" rst.test/poke=1 \
    "platform.lkhun9311.github.io/fenced-nodes=$CLUSTER-no-such-node" >>"$LOG" 2>&1 ||
    { void_case "$name" "$dir" "the decoy annotations failed"; return 2; }
  mark "$dir" "decoy-annotated"
  hold "$name" "$dir" 20
  listing "$name" >"$dir/listing-hold-end.txt"
  mark "$dir" "fence-hold-end"
  # Read now: the kill takes the node's network namespace, and these counters, with it.
  { docker exec "$victim" iptables -L -v -n -x; docker exec "$victim" ip6tables -L -v -n -x; } >"$dir/cut-counters.txt" 2>&1 ||
    { void_case "$name" "$dir" "reading the counters on $victim failed"; return 2; }

  if [ "$case" = cut-writer-early ]; then
    fence "$name" "$dir" "$victim" || return 2
    t0=$SECONDS
    while ((SECONDS - t0 < 300)) && [ ! -s "$SHARED/$name/a2/heartbeat-rank-0.jsonl" ]; do sample "$name" "$dir"; sleep 1; done
    [ -s "$SHARED/$name/a2/heartbeat-rank-0.jsonl" ] || { log "  attempt 2 wrote nothing 300 s after the early fence"; return 1; }
    mark "$dir" "a2-writing"
    hold "$name" "$dir" 20
    mark "$dir" "overlap-hold-end"
  fi

  # Power off: SIGKILL to the node's init ends every process in it, the lingering rank among them.
  mark "$dir" "kill-start $victim"
  docker kill "$victim" >>"$LOG" 2>&1 || { void_case "$name" "$dir" "killing $victim failed"; return 2; }
  mark "$dir" "killed $victim"
  docker inspect "$victim" --format '{{json .State}}' >"$dir/victim-state.json" 2>>"$LOG" ||
    { void_case "$name" "$dir" "inspecting $victim after the kill failed"; return 2; }

  if [ "$case" = cut-writer ]; then
    # The acknowledgement is written only once nothing under a1/ has changed for five consecutive looks.
    t0=$SECONDS prev="" same=0
    while ((SECONDS - t0 < 90)); do
      sample "$name" "$dir"
      cur=$(listing "$name" | grep " $name/a1/")
      if [ "$cur" = "$prev" ]; then same=$((same + 1)); else same=0; fi
      prev=$cur
      [ "$same" -ge 5 ] && break
      sleep 1
    done
    [ "$same" -ge 5 ] || { log "  attempt 1's files still changing 90 s after the kill"; return 1; }
    listing "$name" >"$dir/listing-prefence.txt"
    fence "$name" "$dir" "$victim" || return 2
  fi
  wait_for "$name" "$dir" "s.get('phase') == 'Succeeded' and len(a) == 2" "$CASE_BUDGET"
}

# drive runs one case: it returns 2 when the case is void (its job was refused, or its fault could not be injected),
# and otherwise 0 or 1, both of which are recorded and scored; 1 is a state the case waited for and never reached.
drive() {
  local case=$1 name=$2 dir=$3
  case "$case" in
    reference)
      submit "$name" "$dir" "" || return 2
      wait_for "$name" "$dir" "s.get('phase') == 'Succeeded'" "$CASE_BUDGET"
      ;;
    rank-failed)
      # Rank 1 dies with its shard of step 6 unsynced: the restart must resume from step 5 on a fresh attempt.
      submit "$name" "$dir" "CKPT_FAULT=kill-before-fsync:6:1" || return 2
      wait_for "$name" "$dir" "s.get('phase') == 'Succeeded' and len(a) == 2" "$CASE_BUDGET"
      ;;
    stale-workload)
      # Rank 0 dies at step 8; attempt 1's Workload is held by a finalizer until the hold has been sampled.
      submit "$name" "$dir" "CKPT_FAULT=kill-after-latest:8" || return 2
      wait_for "$name" "$dir" "a[0].get('workloadName') if a else None" 120 || return 1
      local wl
      wl=$(workload_of "$name")
      k -n "$NS" patch workload "$wl" --type=merge -p '{"metadata":{"finalizers":["rst.test/hold"]}}' >>"$LOG" 2>&1 || { void_case "$name" "$dir" "finalizer patch on $wl failed"; return 2; }
      mark "$dir" "finalizer-added $wl"
      # What it waits on first may be the Job, which foreground deletion keeps until its dependents are gone; the
      # scorer reads from the samples that the held Workload is among what the attempt waited on.
      wait_for "$name" "$dir" "a[0].get('state') == 'Stopping' and a[0].get('waitingFor')" 180 || return 1
      mark "$dir" "hold-start"
      # Long enough for the ranks' Pods to be gone, so what is left holding the attempt is the Workload.
      hold "$name" "$dir" 60
      mark "$dir" "hold-end"
      k -n "$NS" patch workload "$wl" --type=json -p '[{"op":"remove","path":"/metadata/finalizers"}]' >>"$LOG" 2>&1 || { void_case "$name" "$dir" "finalizer removal from $wl failed"; return 2; }
      wait_for "$name" "$dir" "s.get('phase') == 'Succeeded' and len(a) == 2" "$CASE_BUDGET"
      ;;
    deactivated)
      submit "$name" "$dir" "" || return 2
      wait_for "$name" "$dir" "a[0].get('allRanksReadyAt') if a else None" 180 || return 1
      # Three steps on each of the two ranks.
      wait_steps "$name" "$dir" 6 || return 1
      local dwl
      dwl=$(workload_of "$name")
      k -n "$NS" patch workload "$dwl" --type=merge -p '{"spec":{"active":false}}' >>"$LOG" 2>&1 ||
        { void_case "$name" "$dir" "deactivating $dwl failed"; return 2; }
      mark "$dir" "deactivated $dwl"
      hold "$name" "$dir" 60
      mark "$dir" "hold-end"
      ;;
    node-lost)
      # Rank 1's node is frozen; rank 0's collective times out after 20 s and fails the attempt.
      submit "$name" "$dir" "CKPT_COLLECTIVE_TIMEOUT=20" || return 2
      wait_for "$name" "$dir" "a[0].get('allRanksReadyAt') if a else None" 180 || return 1
      wait_steps "$name" "$dir" 6 || return 1
      local victim
      victim=$(rank_node "$name" 1)
      [ -n "$victim" ] || { void_case "$name" "$dir" "no node for rank 1"; return 2; }
      docker pause "$victim" >>"$LOG" 2>&1 || { void_case "$name" "$dir" "pausing $victim failed"; return 2; }
      PAUSED=$victim
      mark "$dir" "paused $victim"
      # The frozen node's Pods cannot report gone, so the barrier waits on them, or on the Job they keep from going.
      wait_for "$name" "$dir" "a[0].get('state') == 'Stopping' and a[0].get('waitingFor')" 240 || return 1
      mark "$dir" "pods-hold-start"
      hold "$name" "$dir" 20
      mark "$dir" "pods-hold-end"
      k delete node "$victim" --wait=false >>"$LOG" 2>&1 || { void_case "$name" "$dir" "deleting node $victim failed"; return 2; }
      mark "$dir" "node-deleted $victim"
      # Pod garbage collection removes the Pods of a Node that no longer exists; then only the fencing remains.
      wait_for "$name" "$dir" "'to be fenced' in (a[0].get('waitingFor') or '')" 240 || return 1
      mark "$dir" "fence-hold-start"
      hold "$name" "$dir" 30
      mark "$dir" "fence-hold-end"
      k -n "$NS" annotate mltrainingjob "$name" "platform.lkhun9311.github.io/fenced-nodes=$victim" >>"$LOG" 2>&1 || { void_case "$name" "$dir" "annotating the fence failed"; return 2; }
      mark "$dir" "fenced $victim"
      wait_for "$name" "$dir" "s.get('phase') == 'Succeeded' and len(a) == 2" "$CASE_BUDGET"
      ;;
    cut-writer | cut-writer-early)
      # A 12 s step keeps attempt 1 training through the cut, the Node going not Ready, its deletion and Pod garbage
      # collection, so the attempt fails because a rank's Pod vanished, not because its training ended first.
      submit "$name" "$dir" "CKPT_STEP_SLEEP=12 CKPT_HEARTBEAT=0.5 CKPT_LINGER=1" || return 2
      start_sampler "$name" "$dir"
      wait_for "$name" "$dir" "a[0].get('allRanksReadyAt') if a else None" 180 || return 1
      # Two published checkpoints, two records on each rank, so attempt 2 has one to resume from whatever the cut does.
      wait_events "$name" "$dir" checkpoint 4 || return 1
      cut_writer "$case" "$name" "$dir"
      ;;
    *) log "unknown case $case"; echo "unknown case" >"$dir/VOID"; return 2 ;;
  esac
}

run_case() {
  local case=$1 name dir
  name="rst-$case-$(date -u +%H%M%S)"
  dir=$OUT/$case
  mkdir -p "$dir"
  log "== case $case as $name"
  drive "$case" "$name" "$dir"
  [ $? = 2 ] && return
  finish "$name" "$dir"
}

for c in "${CASES[@]}"; do run_case "$c"; done
log "== done; scoring"
python3 experiments/distributed-restart/score_kind.py "$OUT" | tee -a "$LOG"
exit "${PIPESTATUS[0]}"
