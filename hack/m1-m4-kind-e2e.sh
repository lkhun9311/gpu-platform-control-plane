#!/usr/bin/env bash
# M1-M4a kind end-to-end: CRDs, NodeHealth quarantine, quota enforcement and the serving phase ladder.
#
# M1 through M4-a were verified by envtest and nothing else. Their code exists, their tests pass, and no run
# log showed the four of them behaving on a real cluster -- the same gap M6 had before hack/m6-kind-e2e.sh,
# closed the same way: drive them end to end on kind and commit what happened.
#
# Evidence goes to hack/m1-m4-e2e-evidence.log. The cluster is left standing so the final state can be
# inspected; tear it down with `kind delete cluster --name m1m4`.
#
# On its own cluster, deliberately. The long-lived `platform` cluster carries 47 days of state from M6 and M7,
# and this repository has already been bitten once by an old cluster that made an incomplete procedure look
# complete. Only a fresh cluster can show what these four milestones do unaided.
#
# What is asserted, and why each is worth a line rather than a green tick:
#
#   1. The CRDs install and the operator reaches Ready.
#   2. NodeHealth mirrors a Node's Ready condition, and on a NotReady node it moves to Quarantine AND puts
#      the platform.lkhun9311.github.io/unhealthy taint on the node -- then takes it off on recovery. A phase
#      that moves without the taint following it is a status field reporting an enforcement that never happened.
#   3. GPUQuotaPolicy syncs a ResourceQuota whose hard requests.nvidia.com/gpu ceiling actually refuses an
#      over-quota pod. A quota object that exists but does not bind is the failure this asserts against.
#   4. A policy meeting a ResourceQuota of its own deterministic name that it does NOT own refuses to take it
#      over: it goes Degraded and leaves the object untouched. The one assertion here that shows a boundary
#      rather than a feature, and worth running because envtest is the only thing that has ever exercised
#      metav1.IsControlledBy on this path.
#   5. InferenceDeployment walks to Ready, and at zero replicas resolves to Ready for the reason ScaledToZero
#      -- "scaled to zero" and "no replicas ready yet" are different states that a naive reading conflates,
#      and the reason string is where that distinction is actually recorded.
set -uo pipefail

# bin/ first, because kustomize is installed there by the Makefile and is not on PATH otherwise.
export PATH="$PWD/bin:$PATH"

CLUSTER="${CLUSTER:-m1m4}"
KCTX="kind-${CLUSTER}"
NS=gpu-platform-control-plane-system
NS_TENANT="${NS_TENANT:-m1m4-tenant}"
LOG="${LOG:-hack/m1-m4-e2e-evidence.log}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

: >"$LOG"
log()  { echo -e "$*" | tee -a "$LOG"; }
step() { echo -e "\n===== $* =====" | tee -a "$LOG"; }
run()  { echo "+ $*" | tee -a "$LOG"; "$@" >>"$LOG" 2>&1; }
cap()  { echo "+ $*" | tee -a "$LOG"; "$@" 2>&1 | tee -a "$LOG"; }
die()  { echo "FAILED at: $*" | tee -a "$LOG"; exit 1; }
k()    { kubectl --context "$KCTX" "$@"; }

API=platform.lkhun9311.github.io/v1
TAINT=platform.lkhun9311.github.io/unhealthy

# The serving runtime stand-in, built from hack/serving-stub.
#
# The controller passes --model and --model-path and attaches an HTTP /health readiness AND liveness probe, so
# a serving image must accept those arguments and answer on its port. registry.k8s.io/pause does neither: the
# first run of this script used it, the probes were refused, the kubelet restarted the container six times and
# the CR sat at Pending reporting "no replicas ready yet" -- which was the truth about the image, not about
# the controller. A placeholder that cannot satisfy the contract measures the placeholder.
#
# The tag is deliberately not :latest. A :latest tag defaults to imagePullPolicy Always, so the kubelet
# ignores the image kind load already placed on the node and tries a registry that does not have it -- the
# fifth run of this script died in ImagePullBackOff for exactly that reason. The operator does not set a pull
# policy on the container it builds, and patching the Deployment it owns would be undone on the next
# reconcile, so the tag is the only place this can be fixed.
STUB=serving-stub:e2e

# want_field OBJ JSONPATH WANT TIMEOUT -- poll one field until it equals WANT.
#
# No `|| true` in this wait. A poll whose failure is swallowed reports a value it never reached, which is the
# defect this repository's own notes record from an earlier study.
want_field() {
  local obj="$1" path="$2" want="$3" timeout="${4:-120}" got="" start=$SECONDS
  local deadline=$((SECONDS + timeout))
  while ((SECONDS < deadline)); do
    got="$(k get $obj -o jsonpath="$path" 2>/dev/null)"
    [ "$got" = "$want" ] && { log "  $obj $path = $got  (after $((SECONDS - start))s)"; return 0; }
    sleep 3
  done
  log "  TIMEOUT: $obj $path is '${got:-<empty>}', wanted '$want' after ${timeout}s"
  return 1
}

# taint_present NODE -- 0 the taint is on the node, 1 it is not, 2 the node could not be read.
#
# The third answer is the point. The first version piped a failed `kubectl` into grep, so an unreadable node
# produced empty output, grep failed, and "absent" came back -- which the want-no branch then accepted as a
# taint successfully removed. A read that did not happen is not an observation of absence.
taint_present() {
  local out rc
  out=$(k get node "$1" -o jsonpath="{.spec.taints[?(@.key=='$TAINT')].effect}" 2>/dev/null)
  rc=$?
  [ "$rc" -eq 0 ] || return 2
  case "$out" in
    *NoSchedule*) return 0 ;;
    *) return 1 ;;
  esac
}

# want_taint NODE yes|no TIMEOUT -- wait for the taint to be present or absent.
#
# Separate from want_field because the taint lives on the Node, not on the CR, and the point of step 2 is that
# the two move together: reading the phase twice would prove nothing about the node.
want_taint() {
  local node="$1" want="$2" timeout="${3:-120}" start=$SECONDS
  local deadline=$((SECONDS + timeout))
  local rc
  while ((SECONDS < deadline)); do
    taint_present "$node"; rc=$?
    case "$rc" in
      0) [ "$want" = yes ] && { log "  taint present on $node (after $((SECONDS - start))s)"; return 0; } ;;
      1) [ "$want" = no ] && { log "  taint absent from $node (after $((SECONDS - start))s)"; return 0; } ;;
      # Neither answer. A node this script cannot read says nothing about its taints, and the want-no branch
      # must not collect that silence as a removal -- it keeps polling until the node answers or time runs out.
      2) log "  could not read node $node; still waiting for an answer rather than counting it as absent" ;;
    esac
    sleep 3
  done
  log "  TIMEOUT: wanted taint $want on $node after ${timeout}s; taints are:"
  k get node "$node" -o jsonpath='{.spec.taints}' 2>&1 | tee -a "$LOG"; echo | tee -a "$LOG"
  return 1
}

step "0. cluster"
# Its own config, written here rather than reusing hack/kind-config.yaml, which hardcodes `name: platform`.
CFG_DIR=$(mktemp -d)
# Nothing removed this directory, so every run left one in tmpfs; this script sets no other trap.
trap 'rm -rf "$CFG_DIR"' EXIT
CFG="$CFG_DIR/kind-m1m4.yaml"
cat >"$CFG" <<'YAML'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
  - role: worker
  - role: worker
YAML
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  log "cluster $CLUSTER already exists; reusing it"
else
  run kind create cluster --name "$CLUSTER" --config "$CFG" || die "kind create cluster"
fi
cap k get nodes -o custom-columns='NODE:.metadata.name,VERSION:.status.nodeInfo.kubeletVersion'

step "1. build and load images, install CRDs, deploy the operator and the fake device plugin"
run make docker-build IMG=controller:latest || die "operator image build"
run make docker-build-gpu-simulator GPU_SIMULATOR_IMG=gpu-simulator:latest || die "simulator image build"
run kind load docker-image controller:latest --name "$CLUSTER" || die "kind load operator"
run kind load docker-image gpu-simulator:latest --name "$CLUSTER" || die "kind load simulator"
run docker build -t "$STUB" hack/serving-stub || die "serving stub image build"
run kind load docker-image "$STUB" --name "$CLUSTER" || die "kind load serving stub"

# The committed CRDs, not freshly generated ones. `make install` would be the obvious call and is wrong here
# twice over: it depends on `manifests`, so it regenerates the very files this run is supposed to be evidence
# about, and its kubectl carries no --context, so it would install into whatever the current context happens
# to be rather than into the cluster created above.
kustomize build config/crd | k apply --server-side -f - >>"$LOG" 2>&1 || die "install CRDs"

# Kueue, although nothing in M1-M4a uses it. The operator does not start without it: GPUQuotaPolicy Owns
# ClusterQueue and LocalQueue, and MLTrainingJob puts a field index and a watch on Workload, so the manager's
# cache cannot start those informers when the Kueue CRDs are absent. A milestone can be independent of a
# dependency and still need it installed to be observed at all.
if k -n kueue-system get deploy kueue-controller-manager >/dev/null 2>&1; then
  log "Kueue already installed; reusing it"
else
  k apply --server-side -f https://github.com/kubernetes-sigs/kueue/releases/download/v0.18.3/manifests.yaml \
    >>"$LOG" 2>&1 || die "kueue apply"
fi
k -n kueue-system wait --for=condition=Available deploy/kueue-controller-manager --timeout=300s \
  >>"$LOG" 2>&1 || die "kueue not Available"

# --force-conflicts because the image override below takes ownership of
# .spec.template.spec.containers[name="manager"].image as the field manager "kubectl-set", and a later
# server-side apply of the same manifest is then refused with a conflict.
#
# It is not visible on a fresh cluster -- there is no other manager to collide with -- so it appears only from
# the second run onwards. On this cluster the manifest is the field's rightful owner and the override is a
# local substitution re-asserted every run, so claiming it back is the correct resolution rather than a way
# past an inconvenient refusal.
kustomize build config/operator | k apply --server-side --force-conflicts -f - >>"$LOG" 2>&1 \
  || die "deploy operator"
DEP=$(k -n "$NS" get deploy -o name | grep controller-manager | head -1)
[ -n "$DEP" ] || die "no controller-manager deployment after apply"
log "operator deployment: $DEP"

# config/manager pins the operator image to an ECR digest that ci.yml rewrites on every publish, and this
# cluster has no credentials for that registry. The pin's own comment says the kind path is meant to override
# it -- `make deploy` does so by rewriting the committed kustomization, which this run must not do, since the
# tree it installs from is the thing being evidenced. Overriding the live Deployment instead leaves the
# repository untouched and puts the substitution in this log where a reader can see it.
#
# Without this the Pods sit in ImagePullBackOff and the rollout times out, which is exactly how this script
# failed the first time it ran.
k -n "$NS" set image "$DEP" manager=controller:latest >>"$LOG" 2>&1 || die "override operator image"

# :latest implies imagePullPolicy Always, so the kubelet re-pulls an image kind load already placed on the
# node -- and a locally built tag exists in no registry. Patched here rather than diagnosed afterwards.
k -n "$NS" patch "$DEP" --type=json \
  -p '[{"op":"add","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"IfNotPresent"}]' \
  >>"$LOG" 2>&1 || true
kustomize build config/device-plugin | k apply -f - >>"$LOG" 2>&1 || die "deploy device-plugin"
k -n "$NS" set env ds/gpu-simulator FAKE_GPU_COUNT=2 >>"$LOG" 2>&1 || die "set FAKE_GPU_COUNT"
k -n "$NS" patch ds gpu-simulator --type=json \
  -p '[{"op":"add","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"IfNotPresent"}]' \
  >>"$LOG" 2>&1 || true
k -n "$NS" rollout restart "$DEP" >>"$LOG" 2>&1 || true
k -n "$NS" rollout restart ds/gpu-simulator >>"$LOG" 2>&1 || true
run k -n "$NS" rollout status "$DEP" --timeout=180s || die "operator rollout"
run k -n "$NS" rollout status ds/gpu-simulator --timeout=180s || die "device-plugin rollout"

# Capacity is read back, not inferred from the rollout: plugin registration completes after the pod is Ready,
# so a rollout that returned is not capacity advertised.
log "waiting for a node to advertise nvidia.com/gpu..."
adv=""
for _ in $(seq 1 40); do
  adv=$(k get nodes -o jsonpath='{range .items[*]}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}' 2>/dev/null | grep -v '^$' | head -1)
  [ -n "$adv" ] && { log "  a node advertises nvidia.com/gpu=$adv"; break; }
  sleep 3
done
[ -n "$adv" ] || die "no node advertised nvidia.com/gpu"
log "  the CRDs this operator owns:"
cap k get crd -o name | grep platform.lkhun9311.github.io

step "2. M2 NodeHealth mirrors the node, and quarantine taints it"
# By role, not by index: which node sorts second is not something this test should depend on.
WORKER="$(k get nodes -l '!node-role.kubernetes.io/control-plane' -o jsonpath='{.items[0].metadata.name}')"
[ -n "$WORKER" ] || die "no worker node found"
log "  target node: $WORKER"
cat <<YAML | k apply -f - >>"$LOG" 2>&1 || die "apply NodeHealth"
apiVersion: $API
kind: NodeHealth
metadata:
  name: nh-$WORKER
spec:
  nodeName: $WORKER
  gpuClass: l40s
YAML
want_field "nodehealth/nh-$WORKER" '{.status.phase}' Ready 120 || die "NodeHealth never reached Ready"
taint_present "$WORKER"; rc=$?
case "$rc" in
  0) die "the unhealthy taint is on a healthy node" ;;
  2) die "could not read node $WORKER, so an absent taint is not something this run observed" ;;
esac
log "  no unhealthy taint while the node is Ready, as required"

log "  -- stopping the kubelet so the Node goes NotReady --"
run docker exec "$WORKER" systemctl stop kubelet || die "could not stop kubelet"
want_field "nodehealth/nh-$WORKER" '{.status.phase}' Quarantine 240 || die "NodeHealth never quarantined"
want_taint "$WORKER" yes 120 || die "quarantine phase set but the node was never tainted"
log "  the taint the quarantine applied:"
cap k get node "$WORKER" -o jsonpath='{.spec.taints}'; echo | tee -a "$LOG"
log "  fault signal recorded on the CR:"
cap k get "nodehealth/nh-$WORKER" -o jsonpath='{.status.faultSignal}'; echo | tee -a "$LOG"

log "  -- restarting the kubelet; the taint must come off, not merely the phase --"
run docker exec "$WORKER" systemctl start kubelet || die "could not start kubelet"
want_field "nodehealth/nh-$WORKER" '{.status.phase}' Ready 240 || die "NodeHealth never recovered"
want_taint "$WORKER" no 120 || die "phase recovered but the taint was left on the node"

step "3. M3 GPUQuotaPolicy syncs a ResourceQuota that actually binds"
# The policies go first, and they are cluster-scoped so deleting the namespace does not touch them.
#
# Left standing, a policy from an earlier run still carries phase Synced, and the wait below matches that
# stale status in 0s -- on the fifth run it reported Synced and the very next line read the ResourceQuota as
# NotFound, because the object had just gone with the namespace. The assertion passed without the controller
# having done anything in this run.
run k delete gpuquotapolicy m1m4-policy m1m4-collide --ignore-not-found --wait=true --timeout=120s || true

# Deleted and recreated, never reused.
#
# A previous run leaves its serving pod behind, and a pod in CrashLoopBackOff still holds its GPU against the
# quota. The next run's ReplicaSet then cannot create a single pod -- "exceeded quota ... used: 1, limited: 1"
# -- and the InferenceDeployment sits at Pending for a reason that has nothing to do with the code under test.
# That is what happened on the fourth run of this script, and the quota was right to refuse.
if k get namespace "$NS_TENANT" >/dev/null 2>&1; then
  log "  tenant namespace exists from an earlier run; deleting it so this run starts from nothing"
  run k delete namespace "$NS_TENANT" --wait=true --timeout=180s || die "delete stale tenant namespace"
fi
run k create namespace "$NS_TENANT" || die "create tenant namespace"
cat <<YAML | k apply -f - >>"$LOG" 2>&1 || die "apply GPUQuotaPolicy"
apiVersion: $API
kind: GPUQuotaPolicy
metadata:
  name: m1m4-policy
spec:
  tenant: m1m4
  targetNamespace: $NS_TENANT
  gpuClass: l40s
  limits:
    gpuCount: 1
YAML
want_field "gpuquotapolicy/m1m4-policy" '{.status.phase}' Synced 120 || die "policy never synced"
log "  the ResourceQuota the policy created, with its hard ceiling:"
cap k -n "$NS_TENANT" get resourcequota gpuquota-m1m4-policy -o jsonpath='{.spec.hard}'; echo | tee -a "$LOG"

log "  -- a pod asking for 2 GPUs against a ceiling of 1 must be REFUSED --"
out=$(cat <<YAML | k -n "$NS_TENANT" apply -f - 2>&1
apiVersion: v1
kind: Pod
metadata:
  name: over-quota
spec:
  restartPolicy: Never
  containers:
    - name: hold
      image: $STUB
      resources:
        limits:
          nvidia.com/gpu: "2"
YAML
)
rc=$?
printf '%s\n' "$out" >>"$LOG"
if [ "$rc" -eq 0 ]; then
  log "  !! the over-quota pod was ACCEPTED; the ResourceQuota exists but does not bind"
  die "quota did not enforce"
fi
log "  refused, as the ceiling requires. The API server said:"
printf '%s\n' "$out" | tail -2 | sed 's/^/    /' | tee -a "$LOG"

step "4. a policy refuses to take over a same-named ResourceQuota it does not own"
# The synced name is deterministic -- gpuquota-<policy> -- so the collision can be planted before the policy
# exists. Planted first, deliberately: created the other way round the policy would own the object, and there
# would be nothing left to refuse.
cat <<YAML | k -n "$NS_TENANT" apply -f - >>"$LOG" 2>&1 || die "plant the foreign quota"
apiVersion: v1
kind: ResourceQuota
metadata:
  name: gpuquota-m1m4-collide
spec:
  hard:
    pods: "7"
YAML
cat <<YAML | k apply -f - >>"$LOG" 2>&1 || die "apply the colliding policy"
apiVersion: $API
kind: GPUQuotaPolicy
metadata:
  name: m1m4-collide
spec:
  tenant: m1m4
  targetNamespace: $NS_TENANT
  limits:
    gpuCount: 4
YAML
want_field "gpuquotapolicy/m1m4-collide" '{.status.phase}' Degraded 120 \
  || die "the policy did not report Degraded on a quota it does not own"
log "  the refusal it recorded:"
cap k get gpuquotapolicy m1m4-collide \
  -o jsonpath='{.status.conditions[?(@.type=="Synced")].message}'; echo | tee -a "$LOG"
log "  and the planted object, which must still be the one that was planted:"
hard=$(k -n "$NS_TENANT" get resourcequota gpuquota-m1m4-collide -o jsonpath='{.spec.hard}')
log "    $hard"
case "$hard" in
  *'"pods":"7"'*) log "  untouched: the policy neither hijacked nor deleted it" ;;
  *) log "  !! the foreign ResourceQuota was modified"; die "ownership boundary violated" ;;
esac
if printf '%s' "$hard" | grep -q 'nvidia.com/gpu'; then
  die "the policy wrote its GPU ceiling into a quota it does not own"
fi
run k delete gpuquotapolicy m1m4-collide || true

step "5. M4-a InferenceDeployment walks the phase ladder"
# Step 2 stopped and started a worker's kubelet, which empties /var/lib/kubelet/device-plugins and leaves the
# simulator pod Running with 0 restarts and nothing re-registered -- that node advertises 0 GPUs for the rest
# of the run. Recorded rather than worked around: reordering the steps would hide the observation, not fix it.
log "  GPU capacity by node before scheduling a serving replica:"
cap k get nodes -o custom-columns='NODE:.metadata.name,GPU:.status.allocatable.nvidia\.com/gpu'

# One GPU, under the ceiling of 1 that step 3 left standing: this deployment runs inside the enforced quota.
cat <<YAML | k -n "$NS_TENANT" apply -f - >>"$LOG" 2>&1 || die "apply InferenceDeployment"
apiVersion: $API
kind: InferenceDeployment
metadata:
  name: m1m4-serving
spec:
  model:
    name: m1m4-model
    storageUri: s3://models/m1m4
  image: $STUB
  gpuClass: l40s
  gpuCount: 1
  replicas: 1
  port: 8080
YAML
if ! want_field "-n $NS_TENANT inferencedeployment/m1m4-serving" '{.status.phase}' Ready 300; then
  # The phase says "not Ready"; it never says why. The Deployment's own conditions do -- a ReplicaFailure
  # carries the API server's refusal verbatim -- and printing them here is what turns a timeout into a
  # diagnosis instead of a manual dig through pod events, which this script cost twice before it said this.
  log "  why the Deployment could not get there:"
  cap k -n "$NS_TENANT" get deploy m1m4-serving \
    -o jsonpath='{range .status.conditions[*]}    {.type}={.status} {.reason}: {.message}{"\n"}{end}'
  log "  the pods it has, if any:"
  cap k -n "$NS_TENANT" get pods -l app.kubernetes.io/instance=m1m4-serving -o wide
  die "InferenceDeployment never reached Ready"
fi
log "  the Available condition's reason with a replica up:"
cap k -n "$NS_TENANT" get inferencedeployment m1m4-serving \
  -o jsonpath='{.status.conditions[?(@.type=="Available")].reason}'; echo | tee -a "$LOG"
log "  the Deployment and Service it created:"
cap k -n "$NS_TENANT" get deploy,svc -o name
# Ready is a status field; this is the probe the kubelet actually ran. A replica counted ready whose container
# never answered /health is the failure the first run of this script produced.
log "  the pod's own readiness, and its restart count:"
cap k -n "$NS_TENANT" get pods -l app.kubernetes.io/instance=m1m4-serving \
  -o custom-columns='POD:.metadata.name,READY:.status.containerStatuses[0].ready,RESTARTS:.status.containerStatuses[0].restartCount,NODE:.spec.nodeName'

log "  -- scaled to zero: 'zero wanted' and 'none ready yet' must not read the same --"
run k -n "$NS_TENANT" patch inferencedeployment m1m4-serving --type=merge -p '{"spec":{"replicas":0}}'
want_field "-n $NS_TENANT inferencedeployment/m1m4-serving" '{.status.phase}' Ready 180 \
  || die "scaled-to-zero did not resolve to Ready"
# Ready alone would not tell the two apart; the reason is where the distinction is recorded.
want_field "-n $NS_TENANT inferencedeployment/m1m4-serving" \
  '{.status.conditions[?(@.type=="Available")].reason}' ScaledToZero 120 \
  || die "zero replicas did not report ScaledToZero"

step "done"
log "evidence: $LOG"
log "the cluster is left standing; tear it down with: kind delete cluster --name $CLUSTER"
