#!/usr/bin/env bash
# Rehearses, on kind and with Argo CD, the part of the training session (TRAIN=ddp in hack/eks-gitops-session.sh)
# that runs before anything is bought, and the arm runner it uses after, with the session's own library functions.
#
# The paid session can reach none of this without spending, since it runs `terraform apply` first. Here:
#   T1  train_sync_app syncs the manual gpu-platform-training Application through Argo;
#   T2  train_only_clusterqueue finds gpu-train-a Active and alone;
#   T3  train_qualification_held finds the qualification job Admitted with admittedAt and both Pods unplaced, while no
#       worker carries the training label: kind's stand-in for a gpu group at zero nodes;
#   T7  train_qualification_released, after the label is added as the stand-in for the scale-up, run twice:
#       - the session's own qualification command, which must FAIL here, because these nodes have no CUDA: the
#         qualification is what refuses a node group that is not GPU-capable;
#       - the same job with a command that only imports torch, which must pass, with every stamp the operator owes;
#   A   the four arms run by hack/lib/ddp-arms.sh with train.py carried as base64 and the gloo backend, scored by
#       experiments/multi-pod-ddp/analyze.py: all PASS under the gloo profile, and NOT all PASS under the nccl one,
#       since a CPU run must not satisfy the GPU criteria.
#
# Argo pulls from git, so the repository is served by `git daemon` on the kind network's gateway, and HEAD gets one
# local commit that changes only repoURL and targetRevision in config/argocd, on local branch rehearse/train, never
# pushed. It pulls the operator's ECR image with gpu-lab credentials, as an EKS node role does.
# A rehearsal and not a gate: about thirty minutes. KEEP=1 leaves the cluster up.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

CLUSTER=train-session
CTX=kind-$CLUSTER
ARGO_CHART=7.7.0
TRAIN_IMG=cpu-ddp:torch251
SIM_IMG=gpu-simulator:train-session
OUT=hack/train-session-rehearsal-$(date -u +%Y%m%dT%H%M%SZ)
LOG=$OUT/log.txt
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
LOG=$OUT/log.txt

log() { echo "$(date -u +%H:%M:%S) $*" | tee -a "$LOG"; }
die() { log "FATAL: $*"; echo "$*" >"$OUT/VOID"; exit 1; }
k() { kubectl --context "$CTX" --request-timeout=30s "$@"; }
verdicts=()
bar() { verdicts+=("$1 $2: $3"); log "$1 $2: $3"; }

DAEMON_PID=""
CREATED=""
cleanup() {
  for p in "${DDP_COLLECTORS[@]}"; do kill "$p" 2>>"$LOG"; done
  [[ -n "$DAEMON_PID" ]] && kill "$DAEMON_PID" 2>>"$LOG"
  [[ -n "$CREATED" ]] || return
  [[ "${KEEP:-0}" == 1 ]] && { log "KEEP=1: leaving $CLUSTER"; return; }
  if kind get clusters 2>>"$LOG" | grep -qx "$CLUSTER"; then
    kind delete cluster --name "$CLUSTER" >>"$LOG" 2>&1 && log "cleanup: deleted $CLUSTER" || log "cleanup: delete of $CLUSTER FAILED"
  fi
}
trap cleanup EXIT

# shellcheck source=hack/lib/train-session.sh
. hack/lib/train-session.sh
# shellcheck source=hack/lib/ddp-arms.sh
. hack/lib/ddp-arms.sh
TRAIN_POLL=5

# --- the rehearsal ref ------------------------------------------------------------------------------------------
kind get clusters 2>>"$LOG" | grep -qx "$CLUSTER" && die "cluster $CLUSTER already exists; a rehearsal starts empty"
COMMON="$(cd "$(git rev-parse --git-common-dir)" && pwd)"
REPO_DIR="$(dirname "$COMMON")"
BASE="$(dirname "$REPO_DIR")"
GW="$(docker network inspect kind --format '{{range .IPAM.Config}}{{.Gateway}} {{end}}' 2>>"$LOG" | tr ' ' '\n' | grep -E '^[0-9.]+$' | head -1)"
[[ -n "$GW" ]] || die "no IPv4 gateway on the docker network kind; create and delete any kind cluster once so the network exists"
REPO_URL="git://$GW/$(basename "$REPO_DIR")"
wt="$(mktemp -d)"
git worktree add -q --detach "$wt" HEAD >>"$LOG" 2>&1 || die "worktree"
sed -i -e "s|repoURL: https://github.com/lkhun9311/gpu-platform-control-plane.git|repoURL: $REPO_URL|" \
  -e "s|targetRevision: main|targetRevision: rehearse/train|" "$wt"/config/argocd/*.yaml
git -C "$wt" grep -n "github.com/lkhun9311" -- config/argocd >>"$LOG" && die "an Application still names GitHub after the redirect"
git -C "$wt" -c core.hooksPath=/dev/null commit -q -am "chore: point the argo applications at the local rehearsal daemon" >>"$LOG" 2>&1 || die "redirect commit"
git branch -f rehearse/train "$(git -C "$wt" rev-parse HEAD)" >>"$LOG" 2>&1 || die "branch"
git worktree remove --force "$wt" >>"$LOG" 2>&1
{
  echo "head=$(git rev-parse HEAD) rehearse/train=$(git rev-parse rehearse/train)"
  # This run's own directory is untracked and already exists, so it is left out of the count.
  echo "dirty_files=$(git status --porcelain | grep -vcF "$(basename "$OUT")")"
  echo "kind=$(kind version)"
  echo "kubectl=$(kubectl version --client -o json | python3 -c 'import json,sys;print(json.load(sys.stdin)["clientVersion"]["gitVersion"])')"
  echo "argo_chart=$ARGO_CHART"
  echo "train_py_sha256=$(sha256sum experiments/cpu-ddp/train.py | cut -d' ' -f1)"
} >"$OUT/provenance.txt"
git daemon --export-all --reuseaddr --listen="$GW" --port=9418 --base-path="$BASE" "$REPO_DIR" >>"$OUT/git-daemon.log" 2>&1 &
DAEMON_PID=$!
sleep 2
git ls-remote "$REPO_URL" rehearse/train >"$OUT/ls-remote.txt" 2>>"$LOG" && [[ $(wc -l <"$OUT/ls-remote.txt") == 1 ]] ||
  die "the daemon does not serve rehearse/train at $REPO_URL"

# --- the cluster: three workers, none labelled for training yet ---------------------------------------------------
log "== cluster"
cat >"$OUT/kind.yaml" <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
  - role: worker
  - role: worker
  - role: worker
EOF
CREATED=1
kind create cluster --name "$CLUSTER" --config "$OUT/kind.yaml" --wait 180s >>"$LOG" 2>&1 || die "kind create"
TRAIN_NODES=("$CLUSTER-worker2" "$CLUSTER-worker3")
for n in "${TRAIN_NODES[@]}"; do
  k taint node "$n" nvidia.com/gpu=present:NoSchedule >>"$LOG" 2>&1 || die "taint $n"
done
echo "node_image=$(docker inspect "$CLUSTER-worker" --format '{{.Config.Image}}')" >>"$OUT/provenance.txt"

log "== images"
docker build -q -t "$TRAIN_IMG" experiments/cpu-ddp >>"$LOG" 2>&1 || die "training image"
echo "workload_image=$(docker image inspect "$TRAIN_IMG" --format '{{.Id}}')" >>"$OUT/provenance.txt"
make docker-build-gpu-simulator GPU_SIMULATOR_IMG="$SIM_IMG" >>"$LOG" 2>&1 || die "simulator image"
for img in "$TRAIN_IMG" "$SIM_IMG"; do kind load docker-image "$img" --name "$CLUSTER" >>"$LOG" 2>&1 || die "kind load $img"; done
pw="$(AWS_PROFILE=gpu-lab aws ecr get-login-password --region ap-northeast-2 2>>"$LOG")" || die "ECR password (is the gpu-lab SSO session live?)"
for kz in config/manager/kustomization.yaml config/gateway/kustomization.yaml; do
  python3 -c '
import re, sys
for digest, repo in re.findall(r"digest: (sha256:[0-9a-f]{64})\s*\n\s*name: \S+\s*\n\s*newName: (\S+)", open(sys.argv[1]).read()):
    print(f"{repo}@{digest}")
' "$kz"
done | sort -u >"$OUT/ecr-images.txt"
[[ $(wc -l <"$OUT/ecr-images.txt") -ge 2 ]] || die "found $(wc -l <"$OUT/ecr-images.txt") ECR image pins, want the operator's and the gateway's"
for node in $(kind get nodes --name "$CLUSTER"); do
  while read -r img; do
    docker exec "$node" crictl pull --creds "AWS:$pw" "$img" >>"$LOG" 2>&1 || die "pull $img on $node"
  done <"$OUT/ecr-images.txt"
done

log "== argo cd $ARGO_CHART"
helm repo add argo https://argoproj.github.io/argo-helm >>"$LOG" 2>&1
helm repo update argo >>"$LOG" 2>&1
helm --kube-context "$CTX" install argo-cd argo/argo-cd --version "$ARGO_CHART" -n argocd --create-namespace --wait --timeout 10m >>"$LOG" 2>&1 ||
  die "argo-cd install"
git show rehearse/train:config/argocd/root.yaml | k apply -f - >>"$LOG" 2>&1 || die "apply the root"
# Every automated Application Synced and Healthy, which is the session's GitOps baseline in miniature.
deadline=$((SECONDS + 1500))
while :; do
  table="$(k -n argocd get applications -o json 2>&1 | python3 -c '
import json, sys
for a in json.load(sys.stdin)["items"]:
    s, st = a["spec"], a.get("status", {})
    print(a["metadata"]["name"], "automated" if (s.get("syncPolicy") or {}).get("automated") is not None else "manual",
          (st.get("sync") or {}).get("status", "-"), (st.get("health") or {}).get("status", "-"))
' 2>&1)"
  notyet="$(awk '$2 == "automated" && ($3 != "Synced" || $4 != "Healthy")' <<<"$table")"
  [[ -n "$table" && -z "$notyet" ]] && grep -q '^gpu-platform-kueue ' <<<"$table" && break
  ((SECONDS >= deadline)) && { echo "$table" >"$OUT/apps.txt"; die "automated Applications did not converge: $(tr '\n' ';' <<<"$notyet")"; }
  sleep 15
done
echo "$table" >"$OUT/apps.txt"
log "baseline: $(awk '$2 == "automated"' <<<"$table" | wc -l) automated Applications Synced/Healthy"
# One simulated device per worker, as one GPU per g5.xlarge. No Application deploys the simulator, so it is applied
# here, as hack/test/rehearse-kueue-gitops.sh does.
SYS=gpu-platform-control-plane-system
k kustomize config/device-plugin | sed "s|image: gpu-simulator:latest|image: $SIM_IMG|" | k apply -n "$SYS" -f - >>"$LOG" 2>&1 || die "simulator"
k -n "$SYS" patch ds/gpu-simulator --type=json -p '[{"op":"replace","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"Never"}]' >>"$LOG" 2>&1 || die "simulator pull policy"
k -n "$SYS" set env ds/gpu-simulator FAKE_GPU_COUNT=1 >>"$LOG" 2>&1 || die "simulator count"
k -n "$SYS" rollout status ds/gpu-simulator --timeout=180s >>"$LOG" 2>&1 || die "simulator rollout"
free=""
for _ in $(seq 1 30); do
  free="$(k get nodes -o jsonpath='{range .items[*]}{.metadata.name}={.status.allocatable.nvidia\.com/gpu} {end}')"
  [[ "$free" == *"$CLUSTER-worker=1"* && "$free" == *"$CLUSTER-worker2=1"* && "$free" == *"$CLUSTER-worker3=1"* ]] && break
  sleep 6
done
echo "$free" >"$OUT/allocatable.txt"
[[ "$free" == *"$CLUSTER-worker2=1"* && "$free" == *"$CLUSTER-worker3=1"* ]] || die "the training workers do not each advertise one device: $free"

# --- T1, T2: the training Application and its queue ---------------------------------------------------------------
why="$(train_sync_app "$CTX" gpu-platform-training 600)" && bar T1 PASS "$why" || bar T1 FAIL "$why"
why="$(train_only_clusterqueue "$CTX" gpu-train-a 300)" && bar T2 PASS "$why" || bar T2 FAIL "$why"
k get clusterqueues -o yaml >"$OUT/clusterqueues.yaml" 2>&1

DDP_CONTEXT="$CTX" DDP_NS=train-a DDP_QUEUE=gpu-train-a DDP_IMAGE="$TRAIN_IMG" DDP_SCRIPT=/tmp/train.py
DDP_OUT="$OUT/ddp" DDP_BUDGET=300
# The session's own class, read from its file, as the qualification command is.
DDP_GPU_CLASS="$(sed -n 's/^TRAIN_GPU_CLASS=//p' hack/eks-gitops-session.sh)"
[[ -n "$DDP_GPU_CLASS" ]] || die "could not read TRAIN_GPU_CLASS from hack/eks-gitops-session.sh"
mkdir -p "$DDP_OUT"

label() { # on|off
  local n
  for n in "${TRAIN_NODES[@]}"; do
    if [[ "$1" == on ]]; then
      k label node "$n" platform.lkhun9311.github.io/train=true --overwrite >>"$LOG" 2>&1 || return 1
    else
      k label node "$n" platform.lkhun9311.github.io/train- >>"$LOG" 2>&1 || return 1
    fi
  done
}

# qualify NAME BODY WANT: held while no worker is labelled, then released by the label; WANT is pass or refuse.
qualify() {
  local name="$1" body="$2" want="$3" why
  label off || die "unlabel"
  ddp_render_job "$name" "$body" >"$OUT/$name.json" || die "render $name"
  k apply -f "$OUT/$name.json" >>"$LOG" 2>&1 || die "submit $name"
  why="$(train_qualification_held "$CTX" train-a "$name" 300 2)" && bar T3 PASS "$name: $why" || bar T3 FAIL "$name: $why"
  k -n train-a get mltrainingjob "$name" -o json >"$OUT/$name-held.json" 2>&1
  k -n train-a get pods -l "platform.lkhun9311.github.io/mltrainingjob=$name" -o json >"$OUT/$name-held-pods.json" 2>&1
  label on || die "label"
  local released=""
  why="$(train_qualification_released "$CTX" train-a "$name" 900)" && released=1
  k -n train-a get mltrainingjob "$name" -o json >"$OUT/$name-final.json" 2>&1
  k -n train-a get pods -l "platform.lkhun9311.github.io/mltrainingjob=$name" -o json >"$OUT/$name-final-pods.json" 2>&1
  if [[ "$want" == pass ]]; then
    [[ -n "$released" ]] && bar T7 PASS "$name released and passed: $why" || bar T7 FAIL "$name: $why"
  elif [[ -n "$released" ]]; then
    bar T7 FAIL "$name passed, and it must refuse on a node without CUDA: $why"
  else
    # Any refusal is not this one: a timeout or a stall also refuses. The job must have failed with at least one rank
    # ending in the command's own exit 3, which only the CUDA check returns. The others may not have reached it: the
    # distributed Job has backoffLimit 0, so the first rank to fail has the rest stopped, by SIGTERM (143) or SIGKILL
    # (137), possibly before they start (codex review of ba73d88). Any other code is a failure this did not intend.
    local exits
    exits="$(python3 -c '
import json, sys
job = json.load(open(sys.argv[1]))
pods = json.load(open(sys.argv[2]))["items"]
codes = sorted(str(((p.get("status") or {}).get("containerStatuses") or [{}])[0].get("state", {}).get("terminated", {}).get("exitCode", "none"))
               for p in pods)
phase = (job.get("status") or {}).get("phase")
verdict = "OK" if phase == "Failed" and "3" in codes and set(codes) <= {"3", "137", "143", "none"} else "NO"
print(verdict, phase, codes)
' "$OUT/$name-final.json" "$OUT/$name-final-pods.json" 2>&1)"
    if [[ "$exits" == OK\ * ]]; then
      bar T7 PASS "$name refused, as it must on a node without CUDA: the job Failed and a rank exited 3 (${exits#OK }): $why"
    else
      bar T7 FAIL "$name refused, but not for want of CUDA: phase and exit codes ${exits#NO }: $why"
    fi
  fi
  k -n train-a get pods -l "platform.lkhun9311.github.io/mltrainingjob=$name" -o wide >"$OUT/$name-pods.txt" 2>&1
  for p in $(k -n train-a get pods -l "platform.lkhun9311.github.io/mltrainingjob=$name" -o name 2>>"$LOG"); do
    k -n train-a logs "$p" >"$OUT/$name-${p#pod/}.log" 2>&1
  done
  # The next job needs the quota this one holds.
  k -n train-a delete mltrainingjob "$name" --wait=true --timeout=120s >>"$LOG" 2>&1 || log "could not delete $name"
}

log "== T3 and T7: the qualification job held, then released"
# The command the session runs, from the session's own file, so the rehearsal cannot pass a different one.
QUAL_BODY="$(sed -n "s/^  ddp_render_job train-qualify \"\(.*\)\" \\\\\$/\1/p" hack/eks-gitops-session.sh)"
[[ "$QUAL_BODY" == "exec python -c "* ]] || die "could not read the qualification command from hack/eks-gitops-session.sh: '$QUAL_BODY'"
echo "qualification_body=$QUAL_BODY" >>"$OUT/provenance.txt"
qualify train-qualify "$QUAL_BODY" refuse
# The session's command with the CUDA check removed, so on a CPU node it takes the path a GPU node would.
qualify train-qualify-import "exec python -c 'import sys, time, torch; time.sleep(60); sys.exit(0)'" pass

# --- A: the arms, by the EKS runner, on gloo -----------------------------------------------------------------------
log "== arms by hack/lib/ddp-arms.sh, gloo"
label on || die "label"
DDP_PRELUDE="$(ddp_prelude_for experiments/cpu-ddp/train.py "$DDP_SCRIPT" gloo)" || die "prelude"
ARMS="pass no-sync bad-address one-rank-fails"
{
  echo "commit=$(git rev-parse HEAD)"
  echo "dirty_files=$(git status --porcelain | grep -vcF "$(basename "$OUT")")"
  echo "train_py_sha256=$(sha256sum experiments/cpu-ddp/train.py | cut -d' ' -f1)"
  echo "workload_image=$TRAIN_IMG"
  echo "profile=gloo"
  echo "arms=$ARMS"
} >"$DDP_OUT/provenance.txt"
for arm in $ARMS; do ddp_run_arm "$arm" || log "arm $arm could not be run"; done
python3 experiments/multi-pod-ddp/analyze.py "$DDP_OUT" >"$OUT/score-gloo.txt" 2>&1
rc=$?
((rc == 0)) && bar A PASS "every arm PASS under the gloo profile: $(grep -cE '^PASS' "$OUT/score-gloo.txt") of 4" ||
  bar A FAIL "gloo profile exit $rc: $(grep -E '^(PASS|FAIL|VOID)' "$OUT/score-gloo.txt" | paste -sd';')"
# The same evidence under the nccl profile, with provenance saying nccl so the profile check does not void it first.
cp -r "$DDP_OUT" "$OUT/ddp-as-nccl"
sed -i 's/^profile=gloo$/profile=nccl/' "$OUT/ddp-as-nccl/provenance.txt"
python3 experiments/multi-pod-ddp/analyze.py --profile nccl --script-sha256 "$(sha256sum experiments/cpu-ddp/train.py | cut -d' ' -f1)" \
  "$OUT/ddp-as-nccl" >"$OUT/score-nccl.txt" 2>&1
rc=$?
((rc == 1)) && grep -q 'BAD backend gloo / gloo by rank' "$OUT/score-nccl.txt" &&
  bar A PASS "the nccl profile refuses this CPU run, on its backend among others" ||
  bar A FAIL "the nccl profile on a CPU run exited $rc: $(grep -E '^(PASS|FAIL|VOID)|BAD' "$OUT/score-nccl.txt" | head -4 | paste -sd';')"

printf '%s\n' "${verdicts[@]}" >"$OUT/verdicts.txt"
log "== verdicts"
cat "$OUT/verdicts.txt" | tee -a "$LOG"
if grep -q ' FAIL: ' "$OUT/verdicts.txt"; then exit 1; fi
exit 0
