#!/usr/bin/env bash
# Runs the checkpoint-resume experiment through MLTrainingJob on an existing kind cluster.
#
# The registration (arms, readings, validity checks) is experiments/checkpoint-resume/README.md.
# It builds a throwaway kind cluster named `ckpt` from this tree and deletes it at the end (KEEP=1 keeps it).
# The long-lived `platform` cluster is not used: its operator runs without a webhook certificate while an old
# validating webhook configuration is still registered, so every MLTrainingJob create is refused there.
#
# Environment: REPS (default 3), WAIT_SECONDS per run (default 900).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

CLUSTER=ckpt
CONTEXT=kind-$CLUSTER
NS=ckpt
SYS=gpu-platform-control-plane-system
TAG=ckpt
IMG=ckpt-resume:torch251
EXP=experiments/checkpoint-resume
REPS=${REPS:-3}
WAIT_SECONDS=${WAIT_SECONDS:-900}
OUT=hack/checkpoint-resume-$(date -u +%Y%m%dT%H%M%SZ)
LOG=$OUT/log.txt
mkdir -p "$OUT"

log() { echo -e "$(date -u +%H:%M:%S) $*" | tee -a "$LOG"; }
k()   { kubectl --context "$CONTEXT" "$@"; }
# Says what it saw and what it did. A first version discarded `kind get clusters`' stderr, skipped the delete,
# and left a three-node cluster running for half an hour with nothing in the log to say why.
cleanup() {
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
# Retries a command that fails only until a webhook behind it starts answering.
# Kueue reports Available before its webhook accepts connections, and the first apply after it was refused.
retry() {
  for _ in $(seq 1 20); do "$@" && return 0; sleep 3; done
  return 1
}
# Every failure names its step and exits non-zero, so a broken setup cannot be read as a run.
die() {
  log "FAILED at: $*"
  # The cluster is deleted next, so what it looked like at the failure is written down first.
  { k get pods -A -o wide; k get events -A --sort-by=.lastTimestamp | tail -40
    k -n "$SYS" describe ds/gpu-simulator; k -n "$SYS" logs ds/gpu-simulator --tail=40; } >>"$OUT/failure-state.txt" 2>&1
  cleanup
  exit 1
}
# A cancelled run stops here: a handler that only cleaned up let the loop carry on against a deleted cluster.
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
# The registration fixes three repetitions and the scorer checks exactly three, so any other count is refused
# before a cluster is built rather than ending VOID, or VALID while ignoring the extra repetitions.
[ "$REPS" = 3 ] || die "REPS=$REPS, but the registered protocol is three repetitions"

export PATH="$PWD/bin:$PATH"
# A fresh worktree has no bin/, so the pinned kustomize is fetched rather than whatever the host might carry.
command -v kustomize >/dev/null || make kustomize >>"$LOG" 2>&1 || die "make kustomize"
for tool in docker kind kubectl kustomize python3; do command -v "$tool" >/dev/null || die "missing tool $tool"; done
log "commit $(git rev-parse HEAD), dirty files: $(git status --porcelain | wc -l), context $CONTEXT"

log "== image"
docker build -q -t "$IMG" "$EXP" >>"$LOG" 2>&1 || die "image build"
log "image $(docker image inspect "$IMG" --format '{{.Id}}')"

log "== cluster $CLUSTER"
make docker-build IMG=controller:$TAG >>"$LOG" 2>&1 || die "operator image"
make docker-build-gpu-simulator GPU_SIMULATOR_IMG=gpu-simulator:$TAG >>"$LOG" 2>&1 || die "simulator image"
grep -qx "$CLUSTER" <<<"$(kind get clusters 2>>"$LOG")" && { kind delete cluster --name "$CLUSTER" >>"$LOG" 2>&1 || die "delete old cluster"; }
kind create cluster --name "$CLUSTER" --config hack/kind-config.yaml >>"$LOG" 2>&1 || die "kind create"
for img in controller:$TAG gpu-simulator:$TAG "$IMG"; do
  kind load docker-image "$img" --name "$CLUSTER" >>"$LOG" 2>&1 || die "kind load $img"
done
k apply --server-side -f https://github.com/kubernetes-sigs/kueue/releases/download/v0.18.3/manifests.yaml >>"$LOG" 2>&1 || die "kueue"
k -n kueue-system wait --for=condition=Available deploy/kueue-controller-manager --timeout=300s >>"$LOG" 2>&1 || die "kueue Available"
kustomize build config/crd | k apply --server-side -f - >>"$LOG" 2>&1 || die "CRDs"
# config/operator deploys no webhook, so a create here is not refused by a webhook nobody serves.
# shellcheck disable=SC2317  # called through retry
apply_operator() { kustomize build config/operator | k apply --server-side -f - >>"$LOG" 2>&1; }
retry apply_operator || die "operator"
OPDEP=$(k -n "$SYS" get deploy -o name | grep controller-manager | head -1)
# Both images are pinned to ECR digests a kind node cannot pull, so the local builds are set explicitly.
k -n "$SYS" set image "$OPDEP" manager=controller:$TAG >>"$LOG" 2>&1 || die "operator image set"
kustomize build config/device-plugin | k apply -f - >>"$LOG" 2>&1 || die "device plugin"
k -n "$SYS" set image ds/gpu-simulator "*=gpu-simulator:$TAG" >>"$LOG" 2>&1 || die "simulator image set"
# The manifest's `:latest` made the API server default imagePullPolicy to Always at create, and changing the tag
# afterwards keeps that policy: the loaded image was ignored and every node tried Docker Hub.
k -n "$SYS" patch ds/gpu-simulator --type=json \
  -p '[{"op":"add","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"IfNotPresent"}]' >>"$LOG" 2>&1 ||
  die "simulator pull policy"
k -n "$SYS" set env ds/gpu-simulator FAKE_GPU_COUNT=2 >>"$LOG" 2>&1 || die "simulator count"
k -n "$SYS" rollout status "$OPDEP" --timeout=180s >>"$LOG" 2>&1 || die "operator rollout"
k -n "$SYS" rollout status ds/gpu-simulator --timeout=180s >>"$LOG" 2>&1 || die "simulator rollout"
k apply -f config/kueue/resourceflavor.yaml >>"$LOG" 2>&1 || die "resource flavor"
gpus=""
for _ in $(seq 1 40); do
  gpus=$(k get nodes -o jsonpath='{range .items[*]}{.status.allocatable.nvidia\.com/gpu}{" "}{end}')
  [[ "$gpus" =~ [1-9] ]] && break
  sleep 3
done
[[ "$gpus" =~ [1-9] ]] || die "no node advertises nvidia.com/gpu (allocatable: '$gpus')"
log "allocatable nvidia.com/gpu per node: $gpus"

log "== queue"
cat <<EOF | k apply -f - >>"$LOG" 2>&1 || die "queue"
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
EOF

# arm -> "load mode:die-at step"
declare -A ARM=(
  [uninterrupted]="none:0"
  [restart]="none:25"
  [resume]="full:25"
  [resume-no-optimizer]="no-optimizer:25"
  [resume-no-data-rng]="no-data-rng:25"
)
ORDER=(uninterrupted restart resume resume-no-optimizer resume-no-data-rng)
CHECKED_MOUNT=0

one() {
  local arm=$1 rep=$2 mode die name
  IFS=: read -r mode die <<<"${ARM[$arm]}"
  name="$arm-$rep"
  cat <<EOF | k apply -f - >>"$LOG" 2>&1 || die "submit $name"
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $name
  namespace: $NS
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 1Gi
---
apiVersion: platform.lkhun9311.github.io/v1
kind: MLTrainingJob
metadata:
  name: $name
  namespace: $NS
spec:
  queue: $NS
  image: $IMG
  gpuCount: 1
  parallelism: 1
  completions: 1
  stateVolume:
    claimName: $name
    mountPath: /state
  command:
    - sh
    - -c
    - |
      export CKPT_RUN_ID=$name CKPT_LOAD=$mode CKPT_DIE_AT_STEP=$die CKPT_DIR=/state OMP_NUM_THREADS=1
      exec torchrun --standalone --nnodes=1 --nproc-per-node=2 --max-restarts=0 /work/train.py
EOF
  # The operator on this cluster was not built in this run, so whether it mounts stateVolume is checked, not assumed.
  # Without the mount every "resume" would start from nothing and the arms would differ only by name.
  if [ "$CHECKED_MOUNT" = 0 ]; then
    local mp=""
    for _ in $(seq 1 30); do
      mp=$(k -n "$NS" get job "$name" -o jsonpath='{.spec.template.spec.containers[0].volumeMounts[*].mountPath}' 2>/dev/null)
      [ -n "$mp" ] && break
      sleep 2
    done
    [[ " $mp " == *" /state "* ]] || die "the operator built a Job without the /state mount (mounts: '$mp')"
    log "operator mounts stateVolume: $mp"
    CHECKED_MOUNT=1
  fi

  local deadline=$((SECONDS + WAIT_SECONDS)) phase=""
  while ((SECONDS < deadline)); do
    phase=$(k -n "$NS" get mltrainingjob "$name" -o jsonpath='{.status.phase}' 2>/dev/null)
    [[ "$phase" == Succeeded || "$phase" == Failed ]] && break
    sleep 3
  done
  [ "$phase" = Succeeded ] || die "$name ended in phase '$phase'"

  k -n "$NS" get pods -l "job-name=$name" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' >"$OUT/$name.pods" 2>>"$LOG" ||
    die "list pods of $name"
  : >"$OUT/$name.jsonl"
  while read -r pod; do
    [ -n "$pod" ] || continue
    k -n "$NS" logs "$pod" >>"$OUT/$name.jsonl" 2>>"$LOG" || die "logs of $pod"
  done <"$OUT/$name.pods"
  log "$name: phase $phase, $(wc -l <"$OUT/$name.pods") Pod(s), $(grep -c '"event": "step"' "$OUT/$name.jsonl") step records"
  # One GPU of quota: the next run is admitted only after this one is gone.
  k -n "$NS" delete mltrainingjob "$name" --wait=true >>"$LOG" 2>&1 || die "delete $name"
  k -n "$NS" delete pvc "$name" --wait=false >>"$LOG" 2>&1
}

for rep in $(seq 1 "$REPS"); do
  for arm in "${ORDER[@]}"; do one "$arm" "$rep"; done
done

log "== score"
python3 "$EXP/score.py" "$OUT" | tee -a "$LOG"
status=${PIPESTATUS[0]}
cleanup
exit "$status"
