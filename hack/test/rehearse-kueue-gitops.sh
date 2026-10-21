#!/usr/bin/env bash
# Rehearses, on kind and with Argo CD, the switch from the kueue-crds Application to gpu-platform-kueue
# (docs/superpowers/specs/2026-10-16-nccl-groundwork-design.md, section 1, "Rehearsed with Argo, not with
# `kustomize build`").
#
# It starts from OLD_REF's root (default origin/main, which still has kueue-crds), lets it converge, switches the
# root to NEW_REF (default HEAD) and records:
#   - the four old Kueue CRDs taken over with their UIDs unchanged, and the other seven created;
#   - every automated Application Synced and Healthy, before and after;
#   - gpu-train-a Active from Kueue once the manual training Application is synced;
#   - a two-rank MLTrainingJob's Pods carrying the flavor's toleration and node selector, on the labelled workers,
#     with a GPU free on an unlabelled one;
#   - three drifts repaired by self-heal: the controller Deployment deleted, its replicas changed, a webhook
#     configuration deleted;
#   - fifteen minutes of Application status, for an OutOfSync caused by Kueue's certificate writes.
#
# Argo pulls from git, and both refs must be pulled as they are, so the repository is served from this machine by
# `git daemon` on the kind network's gateway, and each ref gets one local commit that changes only repoURL and
# targetRevision in config/argocd. Those commits live on local branches rehearse/kueue-old and rehearse/kueue-new,
# are recorded in provenance.txt, and are never pushed.
#
# A rehearsal and not a gate: it builds a cluster, pulls the ECR images with gpu-lab credentials, and takes about
# forty minutes. KEEP=1 leaves the cluster up.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

CLUSTER=kueue-gitops
CTX=kind-$CLUSTER
OLD_REF="${OLD_REF:-origin/main}"
NEW_REF="${NEW_REF:-HEAD}"
ARGO_CHART=7.7.0
TRAIN_IMG=cpu-ddp:torch251
SIM_IMG=gpu-simulator:kueue-gitops
WATCH_SECONDS="${WATCH_SECONDS:-900}"
OUT=hack/kueue-gitops-rehearsal-$(date -u +%Y%m%dT%H%M%SZ)
LOG=$OUT/log.txt
mkdir -p "$OUT"

log() { echo "$(date -u +%H:%M:%S) $*" | tee -a "$LOG"; }
die() { log "FATAL: $*"; echo "$*" >"$OUT/VOID"; exit 1; }
k() { kubectl --context "$CTX" --request-timeout=30s "$@"; }
verdicts=()
bar() { verdicts+=("$1 $2: $3"); log "$1 $2: $3"; }

DAEMON_PID=""
cleanup() {
  [[ -n "$DAEMON_PID" ]] && kill "$DAEMON_PID" 2>>"$LOG"
  [[ "${KEEP:-0}" == 1 ]] && { log "KEEP=1: leaving $CLUSTER"; return; }
  if kind get clusters 2>>"$LOG" | grep -qx "$CLUSTER"; then
    kind delete cluster --name "$CLUSTER" >>"$LOG" 2>&1 && log "cleanup: deleted $CLUSTER" || log "cleanup: delete of $CLUSTER FAILED"
  fi
}
trap cleanup EXIT

# --- the rehearsal refs ---------------------------------------------------------------------------------------
kind get clusters 2>>"$LOG" | grep -qx "$CLUSTER" && die "cluster $CLUSTER already exists; a rehearsal starts empty"
COMMON="$(cd "$(git rev-parse --git-common-dir)" && pwd)"
REPO_DIR="$(dirname "$COMMON")"
BASE="$(dirname "$REPO_DIR")"
GW="$(docker network inspect kind --format '{{range .IPAM.Config}}{{.Gateway}} {{end}}' 2>>"$LOG" | tr ' ' '\n' | grep -E '^[0-9.]+$' | head -1)"
[[ -n "$GW" ]] || die "no IPv4 gateway on the docker network kind; create any kind cluster once so the network exists"
REPO_URL="git://$GW/$(basename "$REPO_DIR")"

# point REF BRANCH: one commit on REF that redirects config/argocd to the daemon and to BRANCH, kept on BRANCH.
point() {
  local ref="$1" branch="$2" wt
  wt="$(mktemp -d)"
  git worktree add -q --detach "$wt" "$ref" >>"$LOG" 2>&1 || return 1
  sed -i -e "s|repoURL: https://github.com/lkhun9311/gpu-platform-control-plane.git|repoURL: $REPO_URL|" \
    -e "s|targetRevision: main|targetRevision: $branch|" "$wt"/config/argocd/*.yaml
  if git -C "$wt" grep -n "github.com/lkhun9311" -- config/argocd >>"$LOG"; then
    echo "an Application in $ref still names GitHub after the redirect"
    return 1
  fi
  git -C "$wt" -c core.hooksPath=/dev/null commit -q -am "chore: point the argo applications at the local rehearsal daemon" >>"$LOG" 2>&1 || return 1
  git branch -f "$branch" "$(git -C "$wt" rev-parse HEAD)" >>"$LOG" 2>&1 || return 1
  git worktree remove --force "$wt" >>"$LOG" 2>&1
}
point "$OLD_REF" rehearse/kueue-old || die "could not build rehearse/kueue-old from $OLD_REF"
point "$NEW_REF" rehearse/kueue-new || die "could not build rehearse/kueue-new from $NEW_REF"
{
  echo "old_ref=$OLD_REF $(git rev-parse "$OLD_REF") rehearse/kueue-old=$(git rev-parse rehearse/kueue-old)"
  echo "new_ref=$NEW_REF $(git rev-parse "$NEW_REF") rehearse/kueue-new=$(git rev-parse rehearse/kueue-new)"
  echo "repo_url=$REPO_URL argo_chart=$ARGO_CHART watch_seconds=$WATCH_SECONDS"
  echo "kind=$(kind version) kubectl=$(kubectl version --client -o json | python3 -c 'import json,sys;print(json.load(sys.stdin)["clientVersion"]["gitVersion"])')"
} >"$OUT/provenance.txt"
log "provenance: $(tr '\n' ' ' <"$OUT/provenance.txt")"

git daemon --export-all --reuseaddr --listen="$GW" --port=9418 --base-path="$BASE" "$REPO_DIR" >>"$OUT/git-daemon.log" 2>&1 &
DAEMON_PID=$!
sleep 2
git ls-remote "$REPO_URL" rehearse/kueue-old rehearse/kueue-new >"$OUT/ls-remote.txt" 2>>"$LOG" && [[ $(wc -l <"$OUT/ls-remote.txt") == 2 ]] ||
  die "the daemon does not serve both rehearsal branches at $REPO_URL"

# --- the cluster ------------------------------------------------------------------------------------------------
log "== cluster"
cat >"$OUT/kind.yaml" <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
  - role: worker
  - role: worker
    labels: {platform.lkhun9311.github.io/train: "true"}
  - role: worker
    labels: {platform.lkhun9311.github.io/train: "true"}
EOF
kind create cluster --name "$CLUSTER" --config "$OUT/kind.yaml" --wait 180s >>"$LOG" 2>&1 || die "kind create"
for n in $CLUSTER-worker2 $CLUSTER-worker3; do
  k taint node "$n" nvidia.com/gpu=present:NoSchedule >>"$LOG" 2>&1 || die "taint $n"
done
k get nodes -o wide >"$OUT/nodes.txt" 2>&1

log "== images"
docker build -q -t "$TRAIN_IMG" experiments/cpu-ddp >>"$LOG" 2>&1 || die "training image"
make docker-build-gpu-simulator GPU_SIMULATOR_IMG="$SIM_IMG" >>"$LOG" 2>&1 || die "simulator image"
for img in "$TRAIN_IMG" "$SIM_IMG"; do kind load docker-image "$img" --name "$CLUSTER" >>"$LOG" 2>&1 || die "kind load $img"; done
# The operator and gateway are pinned to ECR digests; a node pull with gpu-lab's ECR password is what an EKS node
# role does, and no manifest is changed to arrange it.
pw="$(AWS_PROFILE=gpu-lab aws ecr get-login-password --region ap-northeast-2 2>>"$LOG")" || die "ECR password (is the gpu-lab SSO session live?)"
for ref in "$OLD_REF" "$NEW_REF"; do
  for kz in config/manager/kustomization.yaml config/gateway/kustomization.yaml; do
    # Each pin is written "- digest: ...", "  name: ...", "  newName: <ECR repository>", in that order.
    git show "$ref:$kz" | python3 -c '
import re, sys
for digest, repo in re.findall(r"digest: (sha256:[0-9a-f]{64})\s*\n\s*name: \S+\s*\n\s*newName: (\S+)", sys.stdin.read()):
    print(f"{repo}@{digest}")
'
  done
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

# apps writes every Application as "name automated|manual sync health revision".
apps() {
  k -n argocd get applications -o json | python3 -c '
import json, sys
for a in json.load(sys.stdin)["items"]:
    s, st = a["spec"], a.get("status", {})
    print(a["metadata"]["name"], "automated" if (s.get("syncPolicy") or {}).get("automated") is not None else "manual",
          (st.get("sync") or {}).get("status", "-"), (st.get("health") or {}).get("status", "-"),
          (st.get("sync") or {}).get("revision", "-")[:12])
'
}
# converge LABEL SECONDS [ABSENT...]: every automated Application Synced and Healthy, and each named one absent.
converge() {
  local label="$1" wait="$2" deadline=$((SECONDS + $2)) table bad
  shift 2
  while :; do
    table="$(apps 2>&1)" && bad="$(awk '$2 == "automated" && ($3 != "Synced" || $4 != "Healthy")' <<<"$table")" || bad="unreadable: $table"
    for gone in "$@"; do grep -q "^$gone " <<<"$table" && bad="$bad $gone still exists"; done
    [[ -z "$bad" && -n "$table" ]] && break
    ((SECONDS >= deadline)) && { echo "$table" >"$OUT/apps-$label.txt"; return 1; }
    sleep 15
  done
  echo "$table" >"$OUT/apps-$label.txt"
}
crds() { k get crd -o json | python3 -c '
import json, sys
for c in json.load(sys.stdin)["items"]:
    n = c["metadata"]["name"]
    if n.endswith(".kueue.x-k8s.io"):
        print(n, c["metadata"]["uid"], c["metadata"].get("labels", {}).get("app.kubernetes.io/instance", "-"),
              c["metadata"]["creationTimestamp"])
' | sort; }

# --- the old root -----------------------------------------------------------------------------------------------
log "== old root ($OLD_REF)"
git show rehearse/kueue-old:config/argocd/root.yaml | k apply -f - >>"$LOG" 2>&1 || die "apply the old root"
converge old 1200 && bar B0 met "the old root converged: $(awk '$2=="automated"' "$OUT/apps-old.txt" | wc -l) automated Applications Synced/Healthy" ||
  die "the old root did not converge in 1200 s; see apps-old.txt"
crds >"$OUT/crds-before.txt"
log "kueue CRDs before: $(wc -l <"$OUT/crds-before.txt")"

# --- the switch -------------------------------------------------------------------------------------------------
log "== switch the root to $NEW_REF"
k -n argocd patch application gpu-platform-root --type merge \
  -p '{"spec":{"source":{"targetRevision":"rehearse/kueue-new"}}}' >>"$LOG" 2>&1 || die "switch the root"
if converge new 1500 kueue-crds; then
  bar B2 met "after the switch every automated Application is Synced/Healthy and kueue-crds is gone: $(awk '$2=="automated"{print $1}' "$OUT/apps-new.txt" | paste -sd' ')"
else
  bar B2 "NOT met" "$(awk '$2=="automated" && ($3!="Synced"||$4!="Healthy")' "$OUT/apps-new.txt" | paste -sd';') (apps-new.txt)"
fi
k -n kueue-system wait --for=condition=Available deploy/kueue-controller-manager --timeout=300s >>"$LOG" 2>&1 ||
  bar B2b "NOT met" "kueue-controller-manager not Available"
crds >"$OUT/crds-after.txt"
python3 - "$OUT/crds-before.txt" "$OUT/crds-after.txt" >"$OUT/takeover.txt" <<'EOF'
import sys
before = {l.split()[0]: l.split() for l in open(sys.argv[1]) if l.strip()}
after = {l.split()[0]: l.split() for l in open(sys.argv[2]) if l.strip()}
kept = [n for n in before if n in after and after[n][1] == before[n][1]]
changed = [n for n in before if n in after and after[n][1] != before[n][1]]
lost = [n for n in before if n not in after]
new = [n for n in after if n not in before]
owners = {n: after[n][2] for n in after}
print(f"before {len(before)} after {len(after)} kept {len(kept)} recreated {len(changed)} lost {len(lost)} new {len(new)}")
print("owners", sorted(set(owners.values())))
ok = len(before) == 4 and len(kept) == 4 and not changed and not lost and len(after) == 11 and set(owners.values()) == {"gpu-platform-kueue"}
print("OK" if ok else "NOT OK")
EOF
grep -q "^OK" "$OUT/takeover.txt" && bar B1 met "$(head -2 "$OUT/takeover.txt" | paste -sd' ')" || bar B1 "NOT met" "$(paste -sd' ' "$OUT/takeover.txt")"

# --- training queue ---------------------------------------------------------------------------------------------
log "== training Application"
k -n argocd patch application gpu-platform-training --type merge \
  -p '{"operation":{"initiatedBy":{"username":"rehearsal"},"sync":{"revision":"rehearse/kueue-new"}}}' >>"$LOG" 2>&1 || die "sync training"
cq=""
for _ in $(seq 1 40); do
  cq="$(k get clusterqueues.v1beta1.kueue.x-k8s.io gpu-train-a -o jsonpath='{.status.conditions[?(@.type=="Active")].status}' 2>>"$LOG")"
  [[ "$cq" == True ]] && break
  sleep 15
done
k get clusterqueues.v1beta1.kueue.x-k8s.io -o yaml >"$OUT/clusterqueues.yaml" 2>&1
ncq="$(k get clusterqueues.v1beta1.kueue.x-k8s.io -o name 2>>"$LOG" | wc -l)"
[[ "$cq" == True ]] && bar B3 met "gpu-train-a Active from Kueue; $ncq ClusterQueue(s) on the cluster" || bar B3 "NOT met" "gpu-train-a Active=$cq"

# --- placement --------------------------------------------------------------------------------------------------
log "== placement"
SYS=gpu-platform-control-plane-system
k kustomize config/device-plugin | sed "s|image: gpu-simulator:latest|image: $SIM_IMG|" | k apply -n "$SYS" -f - >>"$LOG" 2>&1 || die "simulator"
k -n "$SYS" patch ds/gpu-simulator --type=json -p '[{"op":"replace","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"Never"}]' >>"$LOG" 2>&1
k -n "$SYS" set env ds/gpu-simulator FAKE_GPU_COUNT=1 >>"$LOG" 2>&1
k -n "$SYS" rollout status ds/gpu-simulator --timeout=180s >>"$LOG" 2>&1 || die "simulator rollout"
for _ in $(seq 1 20); do
  free="$(k get nodes -o jsonpath='{range .items[*]}{.metadata.name}={.status.allocatable.nvidia\.com/gpu} {end}')"
  [[ "$free" == *"$CLUSTER-worker=1"* && "$free" == *"$CLUSTER-worker2=1"* && "$free" == *"$CLUSTER-worker3=1"* ]] && break
  sleep 6
done
echo "$free" >"$OUT/allocatable.txt"
cat >"$OUT/mltrainingjob.yaml" <<EOF
apiVersion: platform.lkhun9311.github.io/v1
kind: MLTrainingJob
metadata:
  name: placement
  namespace: train-a
spec:
  queue: gpu-train-a
  image: $TRAIN_IMG
  gpuCount: 1
  distributed:
    worldSize: 2
  command:
    - sh
    - -c
    - |
      export DDP_RUN_ID=placement DDP_OUT_DIR=/tmp/evidence OMP_NUM_THREADS=1 DDP_RENDEZVOUS_TIMEOUT_SECONDS=120
      exec python /work/train.py
EOF
k apply -f "$OUT/mltrainingjob.yaml" >>"$LOG" 2>&1 || die "MLTrainingJob"
phase=""
for _ in $(seq 1 60); do
  phase="$(k -n train-a get mltrainingjob placement -o jsonpath='{.status.phase}' 2>>"$LOG")"
  [[ "$phase" == Succeeded || "$phase" == Failed ]] && break
  sleep 5
done
k -n train-a get pods -o json >"$OUT/placement-pods.json" 2>&1
k -n train-a get mltrainingjob placement -o yaml >"$OUT/placement-mltj.yaml" 2>&1
python3 - "$OUT/placement-pods.json" "$CLUSTER" >"$OUT/placement.txt" <<'EOF'
import json, sys
pods = json.load(open(sys.argv[1]))["items"]
cluster = sys.argv[2]
ok = len(pods) == 2
for p in pods:
    s = p["spec"]
    sel = (s.get("nodeSelector") or {}).get("platform.lkhun9311.github.io/train")
    tol = any(t.get("key") == "nvidia.com/gpu" and t.get("value") == "present" and t.get("effect") == "NoSchedule"
              for t in s.get("tolerations") or [])
    node = s.get("nodeName")
    ok &= sel == "true" and tol and node in (f"{cluster}-worker2", f"{cluster}-worker3")
    print(p["metadata"]["name"], "node", node, "selector", sel, "toleration", tol)
ok &= len({p["spec"].get("nodeName") for p in pods}) == 2
print("OK" if ok else "NOT OK")
EOF
grep -q "^OK" "$OUT/placement.txt" && bar B4 met "both ranks carry the train selector and the gpu toleration, on worker2 and worker3, with $CLUSTER-worker's GPU free; job $phase" ||
  bar B4 "NOT met" "$(paste -sd' ' "$OUT/placement.txt"); job $phase"

# --- drift ------------------------------------------------------------------------------------------------------
log "== drift"
# repaired NAME SECONDS CHECK...: time until CHECK succeeds after a drift.
repaired() {
  local name="$1" wait="$2" start=$SECONDS
  shift 2
  while ((SECONDS - start < wait)); do
    "$@" >>"$LOG" 2>&1 && { bar "D-$name" met "repaired in $((SECONDS - start)) s"; return; }
    sleep 5
  done
  bar "D-$name" "NOT met" "not repaired within $wait s"
}
available() { [[ "$(k -n kueue-system get deploy kueue-controller-manager -o jsonpath='{.status.availableReplicas}/{.spec.replicas}')" == 1/1 ]]; }
webhook_back() { k get validatingwebhookconfiguration kueue-validating-webhook-configuration -o jsonpath='{.webhooks[0].clientConfig.caBundle}' | grep -q .; }
k -n kueue-system delete deploy kueue-controller-manager --wait=false >>"$LOG" 2>&1
repaired deployment-deleted 600 available
k -n kueue-system scale deploy kueue-controller-manager --replicas=3 >>"$LOG" 2>&1
sleep 5
repaired replicas-changed 600 available
k delete validatingwebhookconfiguration kueue-validating-webhook-configuration >>"$LOG" 2>&1
repaired webhook-deleted 600 webhook_back

# --- certificate writes -----------------------------------------------------------------------------------------
log "== watching for $WATCH_SECONDS s"
end=$((SECONDS + WATCH_SECONDS))
: >"$OUT/watch.txt"
while ((SECONDS < end)); do
  echo "@$(date -u +%H:%M:%S)" >>"$OUT/watch.txt"
  apps >>"$OUT/watch.txt" 2>&1
  sleep 15
done
samples="$(grep -c '^@' "$OUT/watch.txt")"
outs="$(grep -c '^gpu-platform-kueue .* OutOfSync ' "$OUT/watch.txt")"
others="$(awk '$2 == "automated" && $3 == "OutOfSync" && $1 != "gpu-platform-kueue"' "$OUT/watch.txt" | wc -l)"
[[ "$outs" == 0 && "$samples" -ge $((WATCH_SECONDS / 20)) ]] && bar B5 met "gpu-platform-kueue Synced in all $samples samples over $WATCH_SECONDS s; other automated OutOfSync samples: $others" ||
  bar B5 "NOT met" "gpu-platform-kueue OutOfSync in $outs of $samples samples; others $others"

k -n kueue-system get validatingwebhookconfiguration,mutatingwebhookconfiguration -o yaml >"$OUT/webhooks.yaml" 2>&1
apps >"$OUT/apps-final.txt" 2>&1
printf '%s\n' "${verdicts[@]}" >"$OUT/verdicts.txt"
log "== verdicts"
cat "$OUT/verdicts.txt" | tee -a "$LOG"
grep -q "NOT met" "$OUT/verdicts.txt" && exit 1
exit 0
