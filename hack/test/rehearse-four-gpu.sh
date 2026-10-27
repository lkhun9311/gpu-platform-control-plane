#!/usr/bin/env bash
# Rehearses experiment C (docs/superpowers/specs/2026-10-27-four-gpu-nccl-design.md) on kind, for free, with a fake
# device plugin advertising four nvidia.com/gpu on one worker. Nothing here is a GPU number: there is no CUDA and no
# NCCL, and every job is expected to be INVALID under the scorer, each for the reason this rehearsal names.
#
# It shows, on a real API server, Kueue and this tree's operator:
#   S   the operator renders a Pod of four GPUs with a 1 GiB memory-backed /dev/shm, and a Pod of one without it;
#   T3  train_qualification_held finds the one-Pod qualification job Admitted and unplaced before any device exists;
#   T6  train_qualify_nodes refuses the simulated node: a simulator is not a device plugin, and four is not one;
#   T7  train_qualification_released refuses a qualification run on a node with no nvidia-smi;
#   A   one job of each arm admitted as one Workload reserving four GPUs, every Pod on the one worker, torchrun giving
#       four distinct LOCAL_RANKs, the DDP bench's whole path on CPU with gloo (verified, and refused by the scorer as
#       cpu), the all-reduce bench refusing for want of CUDA, and nccl-tests failing for want of its tools;
#   X   the smoke stop rule ending the run after the first invalid smoke job.
#
# The cluster is kind-fourgpu, created here and deleted at the end (KEEP=1 keeps it). Evidence goes to
# hack/four-gpu-rehearsal-<UTC>/. About fifteen minutes.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

CLUSTER=kind-fourgpu
CTX=kind-$CLUSTER
TAG=fourgpu
KUEUE_VERSION=v0.18.3
CERT_MANAGER_VERSION=v1.21.1
SYS=gpu-platform-control-plane-system
CPU_IMG=cpu-ddp:torch251
OUT=hack/four-gpu-rehearsal-$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
LOG=$OUT/log.txt

log() { echo "$(date -u +%H:%M:%S) $*" | tee -a "$LOG"; }
die() { log "FATAL: $*"; echo "$*" >"$OUT/VOID"; exit 1; }
k() { kubectl --context "$CTX" --request-timeout=30s "$@"; }
verdicts=()
bar() { verdicts+=("$1 $2: $3"); log "$1 $2: $3"; }
retry() { for _ in $(seq 1 40); do "$@" && return 0; sleep 3; done; return 1; }

CREATED=""
cleanup() {
  for p in "${AR_COLLECTORS[@]}"; do kill "$p" 2>>"$LOG"; done
  [[ -n "$CREATED" ]] || return
  [[ "${KEEP:-0}" == 1 ]] && { log "KEEP=1: leaving $CLUSTER"; return; }
  kind delete cluster --name "$CLUSTER" >>"$LOG" 2>&1 && log "cleanup: deleted $CLUSTER" || log "cleanup: delete of $CLUSTER FAILED"
}
trap cleanup EXIT

# shellcheck source=hack/lib/train-session.sh
. hack/lib/train-session.sh
# shellcheck source=hack/lib/allreduce-arms.sh
. hack/lib/allreduce-arms.sh
TRAIN_POLL=3

export PATH="$PWD/bin:$PATH"
for tool in docker kind kubectl kustomize python3; do command -v "$tool" >/dev/null || die "missing tool $tool"; done
kind get clusters 2>>"$LOG" | grep -qx "$CLUSTER" && die "cluster $CLUSTER already exists; a rehearsal starts empty"
{
  echo "commit=$(git rev-parse HEAD)"
  echo "dirty_files=$(git status --porcelain | grep -vcF "$(basename "$OUT")")"
  echo "kind=$(kind version)"
  echo "kueue=$KUEUE_VERSION"
  echo "cert_manager=$CERT_MANAGER_VERSION"
  echo "bench_sha256=$(sha256sum experiments/multi-gpu-throughput/allreduce_bench.py | cut -d' ' -f1)"
  echo "step_sha256=$(sha256sum experiments/multi-gpu-throughput/ddp_step_bench.py | cut -d' ' -f1)"
} >"$OUT/provenance.txt"

log "== images"
docker image inspect "$CPU_IMG" >/dev/null 2>&1 || docker build -q -t "$CPU_IMG" experiments/cpu-ddp >>"$LOG" 2>&1 || die "cpu image"
make docker-build IMG=controller:$TAG >>"$LOG" 2>&1 || die "operator image"
make docker-build-gpu-simulator GPU_SIMULATOR_IMG=gpu-simulator:$TAG >>"$LOG" 2>&1 || die "simulator image"

log "== cluster $CLUSTER: one control plane, one worker"
printf 'kind: Cluster\napiVersion: kind.x-k8s.io/v1alpha4\nnodes:\n  - role: control-plane\n  - role: worker\n' >"$OUT/kind.yaml"
kind create cluster --name "$CLUSTER" --config "$OUT/kind.yaml" >>"$LOG" 2>&1 || die "kind create"
CREATED=1
WORKER="$CLUSTER-worker"
for img in controller:$TAG gpu-simulator:$TAG "$CPU_IMG"; do
  kind load docker-image "$img" --name "$CLUSTER" >>"$LOG" 2>&1 || die "kind load $img"
done
k apply -f "https://github.com/cert-manager/cert-manager/releases/download/$CERT_MANAGER_VERSION/cert-manager.yaml" >>"$LOG" 2>&1 || die "cert-manager"
k -n cert-manager wait --for=condition=Available deploy --all --timeout=300s >>"$LOG" 2>&1 || die "cert-manager Available"
k apply --server-side -f "https://github.com/kubernetes-sigs/kueue/releases/download/$KUEUE_VERSION/manifests.yaml" >>"$LOG" 2>&1 || die "kueue"
k -n kueue-system wait --for=condition=Available deploy/kueue-controller-manager --timeout=300s >>"$LOG" 2>&1 || die "kueue Available"
kustomize build config/crd | k apply --server-side -f - >>"$LOG" 2>&1 || die "CRDs"
apply_operator() { kustomize build config/operator-webhook | k apply --server-side -f - >>"$LOG" 2>&1; }
retry apply_operator || die "operator"
OPDEP=$(k -n "$SYS" get deploy -o name | grep controller-manager | head -1)
[[ -n "$OPDEP" ]] || die "no controller-manager deployment"
k -n "$SYS" set image "$OPDEP" manager=controller:$TAG >>"$LOG" 2>&1 || die "operator image set"
k -n "$SYS" patch "$OPDEP" --type=json \
  -p '[{"op":"replace","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"IfNotPresent"}]' >>"$LOG" 2>&1 || die "pull policy"
k -n "$SYS" rollout status "$OPDEP" --timeout=240s >>"$LOG" 2>&1 || die "operator rollout"
# The admission policy the EKS cluster runs, so a job without a class is refused here as it would be there.
kustomize build config/policy | k apply -f - >>"$LOG" 2>&1 || die "admission policy"
k apply -f config/kueue/resourceflavor.yaml >>"$LOG" 2>&1 || die "resource flavor"
apply_training() { kustomize build config/training | k apply -f - >>"$LOG" 2>&1; }
retry apply_training || die "config/training"
nominal=""
for _ in $(seq 1 60); do
  nominal=$(k get clusterqueue gpu-train-a -o jsonpath='{.spec.resourceGroups[0].flavors[0].resources[0].nominalQuota}' 2>>"$LOG")
  [[ "$nominal" == 4 ]] && break
  sleep 3
done
[[ "$nominal" == 4 ]] && bar Q4 PASS "config/training made ClusterQueue gpu-train-a with nominal nvidia.com/gpu 4" ||
  die "ClusterQueue gpu-train-a nominal '$nominal', want 4"

AR_CONTEXT="$CTX" AR_NS=train-a AR_QUEUE=gpu-train-a AR_GPU_CLASS=a10g AR_OUT="$OUT" AR_BUDGET=240
AR_TORCH_IMAGE="$CPU_IMG" AR_NCCLTESTS_IMAGE="$CPU_IMG" AR_REHEARSAL=1
AR_BENCH_FILE=experiments/multi-gpu-throughput/allreduce_bench.py AR_STEP_FILE=experiments/multi-gpu-throughput/ddp_step_bench.py
AR_SCORER=experiments/multi-gpu-throughput/analyze.py
SCORE_ARGS=(--bench-sha256 "$(sha256sum "$AR_BENCH_FILE" | cut -d' ' -f1)" --step-sha256 "$(sha256sum "$AR_STEP_FILE" | cut -d' ' -f1)" --node "$WORKER")

log "== T3: the one-Pod qualification job, submitted while no node advertises a GPU"
ar_render_job train-qualify nccltests-1pod4gpu "$(ar_qualification_body)" >"$OUT/qualification.json" || die "render qualification"
k apply -f "$OUT/qualification.json" >>"$LOG" 2>&1 || die "qualification refused"
why="$(train_qualification_held "$CTX" train-a train-qualify 300 1)" && bar T3 PASS "$why" || bar T3 FAIL "$why"
why="$(train_qualification_held "$CTX" train-a train-qualify 0 2)" && bar T3-count FAIL "two Pods expected and still passed: $why" ||
  bar T3-count PASS "expecting two Pods of a one-Pod job refuses: $why"

log "== the simulated device plugin: four nvidia.com/gpu on the worker"
kustomize build config/device-plugin | k apply -f - >>"$LOG" 2>&1 || die "device plugin"
k -n "$SYS" set image ds/gpu-simulator "*=gpu-simulator:$TAG" >>"$LOG" 2>&1 || die "simulator image set"
k -n "$SYS" patch ds/gpu-simulator --type=json \
  -p '[{"op":"add","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"IfNotPresent"}]' >>"$LOG" 2>&1 || die "simulator pull policy"
k -n "$SYS" set env ds/gpu-simulator FAKE_GPU_COUNT=4 >>"$LOG" 2>&1 || die "simulator count"
k -n "$SYS" rollout status ds/gpu-simulator --timeout=180s >>"$LOG" 2>&1 || die "simulator rollout"
gpus=""
for _ in $(seq 1 60); do
  gpus=$(k get node "$WORKER" -o jsonpath='{.status.allocatable.nvidia\.com/gpu}')
  [[ "$gpus" == 4 ]] && break
  sleep 3
done
[[ "$gpus" == 4 ]] || die "the worker advertises '$gpus' nvidia.com/gpu, want 4"
log "the worker advertises nvidia.com/gpu $gpus"

log "== T6 against the simulated node"
k label node "$WORKER" eks.amazonaws.com/nodegroup=gpu --overwrite >>"$LOG" 2>&1 || die "label"
why="$(train_qualify_nodes "$CTX" gpu 1 0 4)" && bar T6 FAIL "a simulated node qualified: $why" || bar T6 PASS "the simulated node is refused: $why"
why="$(train_qualify_nodes "$CTX" gpu 1 0 1)" && bar T6-count FAIL "four GPUs qualified as one: $why" || bar T6-count PASS "four GPUs where one is expected: $why"

log "== T7: the qualification job, now placed, on a node with no nvidia-smi"
why="$(train_qualification_released "$CTX" train-a train-qualify 300)" && bar T7 FAIL "succeeded with no GPU tools: $why" ||
  bar T7 PASS "refused: $why"
k -n train-a logs -l batch.kubernetes.io/job-name=train-qualify --tail=-1 >"$OUT/qualification.log" 2>>"$LOG"
grep -q "nvidia-smi: not found\|nvidia-smi: command not found\|AR_QUALIFY_REFUSED" "$OUT/qualification.log" &&
  bar T7-why PASS "the Pod's own log names the missing tool" || bar T7-why FAIL "$(tail -3 "$OUT/qualification.log")"
k -n train-a delete mltrainingjob train-qualify --wait=true --timeout=120s >>"$LOG" 2>&1

log "== A: one job of each arm"
for arm in $AR_ARMS; do
  ar_run_job "c-r-${arm%%-*}-${arm##*-}" "$arm" "$OUT/jobs/$arm"
done
python3 - "$OUT/jobs" "$WORKER" >"$OUT/arms-check.txt" 2>&1 <<'PY'
import glob, json, os, sys
root, worker = sys.argv[1], sys.argv[2]
for arm in sorted(os.listdir(root)):
    d = os.path.join(root, arm)
    spec = json.load(open(f"{d}/mltrainingjob.json"))["spec"]
    pods = {}
    for line in open(f"{d}/pods.jsonl"):
        s = json.loads(line)
        pods[s["uid"]] = s
    wl = json.load(open(f"{d}/final-workloads.json"))
    uid = json.load(open(f"{d}/final-job.json"))["metadata"]["uid"]
    owned = [w for w in wl["items"] if any(r.get("uid") == uid for r in w["metadata"].get("ownerReferences", []))]
    reserved = sum(int(a["resourceUsage"]["nvidia.com/gpu"]) for w in owned for a in w["status"]["admission"]["podSetAssignments"])
    lines = [l for f in glob.glob(f"{d}/log-*.txt") for l in open(f)]
    shm = sorted({l.split()[1] for l in lines if l.startswith("AR_SHM_KB ")})
    starts = [json.loads(l) for l in lines if l.startswith("{") and '"event": "start"' in l]
    local_ranks = sorted(str(s.get("local_rank_env")) for s in starts)
    steps = [json.loads(l) for l in lines if l.startswith("{") and '"event": "steps"' in l]
    refused = sorted({json.loads(l).get("error") for l in lines if l.startswith("{") and '"event": "refused"' in l})
    print(f"{arm}: gpuCount {spec['gpuCount']} distributed {spec.get('distributed')} workloads {len(owned)} reserved {reserved} "
          f"pods {len(pods)} nodes {sorted({p['node'] for p in pods.values()})} on_worker {all(p['node'] == worker for p in pods.values())} "
          f"shm_kib {shm} local_rank_env {local_ranks} steps_verified {[s.get('verified') for s in steps]} "
          f"buckets {steps[0].get('ddp_buckets') if steps else None} refused {refused}")
PY
cat "$OUT/arms-check.txt" | tee -a "$LOG"
# The bench fails here, so the Job controller retries its one Pod (the default backoffLimit); the count is not judged.
grep -q "^allreduce-1pod4gpu: gpuCount 4 distributed None workloads 1 reserved 4 pods [0-9]* .*on_worker True shm_kib \['1048576'\]" "$OUT/arms-check.txt" &&
  bar A-1pod PASS "one Pod of four: one Workload reserving 4, on the worker, /dev/shm 1 GiB" || bar A-1pod FAIL "see arms-check.txt"
grep -q "^allreduce-4pod1gpu: gpuCount 1 distributed {'worldSize': 4} workloads 1 reserved 4 pods 4 .*on_worker True" "$OUT/arms-check.txt" &&
  ! grep -q "^allreduce-4pod1gpu: .*shm_kib \['1048576'\]" "$OUT/arms-check.txt" &&
  bar A-4pod PASS "four Pods of one: one Workload reserving 4, all on the worker, the runtime's own /dev/shm" || bar A-4pod FAIL "see arms-check.txt"
grep -q "^ddp-1pod4gpu: .*local_rank_env \['0', '1', '2', '3'\] steps_verified \[True, True, True, True\]" "$OUT/arms-check.txt" &&
  bar A-torchrun PASS "torchrun gave four distinct LOCAL_RANKs, and the DDP bench's oracle verified on CPU" || bar A-torchrun FAIL "see arms-check.txt"
grep -q "^ddp-4pod1gpu: .*local_rank_env \['None', 'None', 'None', 'None'\] steps_verified \[True, True, True, True\]" "$OUT/arms-check.txt" &&
  bar A-ddp-pods PASS "four Pods of one: no launcher, four ranks through the platform's rendezvous, verified on CPU" || bar A-ddp-pods FAIL "see arms-check.txt"
grep -q "^allreduce-1pod4gpu: .*refused \['CUDA is not available, and this bench measures GPUs only'\]" "$OUT/arms-check.txt" &&
  bar A-bench PASS "the all-reduce bench refuses without CUDA" || bar A-bench FAIL "see arms-check.txt"

log "== the scorer on each job: every one INVALID, for its own reason"
for arm in $AR_ARMS; do
  out="$(python3 "$AR_SCORER" --job "$OUT/jobs/$arm" "${SCORE_ARGS[@]}" 2>&1)"
  rc=$?
  echo "$out" >"$OUT/jobs/$arm/score.txt"
  case "$arm" in
    ddp-*) want="not cuda" ;;
    allreduce-*) want="CUDA is not available" ;;
    # The image here has no nvidia-smi or mpirun, so the Pod fails and is retried until the budget ends.
    nccltests-*) want="not Succeeded" ;;
  esac
  ((rc != 0)) && [[ "$out" == *"$want"* ]] && bar "S-$arm" PASS "INVALID: $want" || bar "S-$arm" FAIL "rc $rc: ${out:0:300}"
done

log "== X: the smoke stop rule"
AR_SCORER_ARGS="${SCORE_ARGS[*]}"
mkdir -p "$OUT/stop"
if AR_OUT="$OUT/stop" ar_run_all; then
  bar X FAIL "the run did not stop"
else
  n="$(find "$OUT/stop/jobs" -mindepth 1 -maxdepth 1 -type d | wc -l)"
  [[ "$n" == 1 ]] && bar X PASS "stopped after $n job: $(cut -c1-160 "$OUT/stop/STOPPED")" || bar X FAIL "$n jobs ran before the stop"
fi

printf '%s\n' "${verdicts[@]}" >"$OUT/verdicts.txt"
log "== verdicts"
cat "$OUT/verdicts.txt"
grep -q " FAIL: " "$OUT/verdicts.txt" && exit 1
exit 0
