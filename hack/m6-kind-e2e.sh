#!/usr/bin/env bash
#
# M6 kind end-to-end: two-tenant Kueue fair-sharing and preemption with a fake GPU.
#
# This script creates a kind cluster, installs Kueue, deploys the operator and the
# fake GPU device plugin, and then drives two tenants through borrowing and reclaim
# so the fair-sharing and preemption behaviour can be observed with no real GPU.
#
# It captures evidence to hack/m6-e2e-evidence.log and does not tear the cluster down,
# so the final state can be inspected; run `kind delete cluster --name platform` when done.
set -uo pipefail

cd "$(dirname "$0")/.."
export PATH="$PWD/bin:$PATH"
export GOTOOLCHAIN=go1.26.9

# Overridable, because they were not and an attempt to run this against a throwaway cluster silently went to
# `platform` anyway and overwrote the committed evidence log. A plain assignment ignores the environment
# without saying so, which is the same class of quiet failure this script's own waits used to have.
CLUSTER=${CLUSTER:-platform}
KCTX=kind-$CLUSTER
NS=gpu-platform-control-plane-system
LOG=${LOG:-hack/m6-e2e-evidence.log}
: > "$LOG"

log()  { echo -e "$*" | tee -a "$LOG"; }
step() { echo -e "\n===== $* =====" | tee -a "$LOG"; }
run()  { echo "+ $*" | tee -a "$LOG"; "$@" >>"$LOG" 2>&1; }
cap()  { echo "+ $*" | tee -a "$LOG"; "$@" 2>&1 | tee -a "$LOG"; }
die()  { echo "FAILED at: $*" | tee -a "$LOG"; exit 1; }

k() { kubectl --context "$KCTX" "$@"; }

phases() {
  echo "--- MLTrainingJob phases ---" | tee -a "$LOG"
  k get mltrainingjob -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,PHASE:.status.phase 2>&1 | tee -a "$LOG"
  echo "--- Workloads (admitted) ---" | tee -a "$LOG"
  k get workloads -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,QUEUE:.spec.queueName,ADMITTED:'.status.conditions[?(@.type=="Admitted")].status' 2>&1 | tee -a "$LOG"
  echo "--- ClusterQueue usage ---" | tee -a "$LOG"
  # cohortName, not cohort: v1beta2 renamed the field, and querying the old one made every
  # ClusterQueue in the evidence log read COHORT <none> even though the cohort was set.
  k get clusterqueue -o custom-columns=NAME:.metadata.name,COHORT:.spec.cohortName,PENDING:.status.pendingWorkloads,ADMITTED:.status.admittedWorkloads 2>&1 | tee -a "$LOG"
}

# wait_phase NS NAME WANT TIMEOUT
wait_phase() {
  local ns=$1 name=$2 want=$3 timeout=${4:-90} i
  for ((i=0; i<timeout; i+=3)); do
    local got
    got=$(k -n "$ns" get mltrainingjob "$name" -o jsonpath='{.status.phase}' 2>/dev/null)
    [ "$got" = "$want" ] && { log "  $ns/$name reached phase $want after ${i}s"; return 0; }
    sleep 3
  done
  log "  TIMEOUT: $ns/$name never reached $want (last: $(k -n "$ns" get mltrainingjob "$name" -o jsonpath='{.status.phase}' 2>/dev/null))"
  return 1
}

submit_job() {
  local name=$1 ns=$2 queue=$3
  cat <<EOF | k apply -f - >>"$LOG" 2>&1
apiVersion: platform.lkhun9311.github.io/v1
kind: MLTrainingJob
metadata:
  name: $name
  namespace: $ns
spec:
  queue: $queue
  image: busybox:1.36
  command: ["sh","-c","sleep 600"]
  gpuCount: 1
  parallelism: 1
  completions: 1
EOF
  # The apply's status decides what this line may say. It used to be printed unconditionally with the output
  # redirected into the log, so "+ submitted" appeared whether or not anything had been created.
  local rc=$?
  [ "$rc" -eq 0 ] || die "could not submit MLTrainingJob $ns/$name (kubectl apply exited $rc; see $LOG)"
  log "+ submitted MLTrainingJob $ns/$name (queue $queue)"
}

step "1. create kind cluster ($CLUSTER)"
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  log "cluster $CLUSTER already exists; reusing it (delete it first for a clean run)"
else
  kind create cluster --name "$CLUSTER" --config hack/kind-config.yaml >>"$LOG" 2>&1 || die "kind create cluster"
fi
cap k cluster-info

step "2. install Kueue v0.18.3"
if k -n kueue-system get deploy kueue-controller-manager >/dev/null 2>&1; then
  log "Kueue already installed; reusing it"
else
  k apply --server-side -f https://github.com/kubernetes-sigs/kueue/releases/download/v0.18.3/manifests.yaml >>"$LOG" 2>&1 || die "kueue apply"
fi
log "waiting for kueue-controller-manager to become Available..."
k -n kueue-system wait --for=condition=Available deploy/kueue-controller-manager --timeout=300s >>"$LOG" 2>&1 || die "kueue not Available"
cap k -n kueue-system get pods

step "3. build and load operator + gpu-simulator images"
run make docker-build IMG=controller:latest || die "operator image build"
run make docker-build-gpu-simulator GPU_SIMULATOR_IMG=gpu-simulator:latest || die "simulator image build"
run kind load docker-image controller:latest --name "$CLUSTER" || die "kind load operator"
run kind load docker-image gpu-simulator:latest --name "$CLUSTER" || die "kind load simulator"

step "4. install CRDs, deploy operator and fake GPU device plugin"
# The committed CRDs, applied to THIS cluster.
#
# `make install` was here and sent them somewhere else: its kubectl carries no --context, so it installs into
# whatever the current context happens to be -- which in this repository is a torn-down EKS. The platform
# cluster was left without the WorkloadRun CRD, the operator died with "failed to wait for workloadrun caches
# to sync", and nothing in M6 could be reconciled. It also depends on `manifests`, which regenerates the files
# a run like this is supposed to be evidence about.
kustomize build config/crd | k apply --server-side -f - >>"$LOG" 2>&1 || die "install CRDs"
# --force-conflicts because the image override below owns .spec.template.spec.containers[name="manager"].image as the field manager "kubectl-set", and re-applying this manifest is then refused with a conflict on the second and every later run.
kustomize build config/operator | k apply --server-side --force-conflicts -f - >>"$LOG" 2>&1 || die "deploy operator"
DEP=$(k -n "$NS" get deploy -o name | grep controller-manager | head -1)
log "operator deployment: $DEP"

# config/manager pins the operator image to an ECR digest this cluster has no credentials for, so the side-loaded controller:latest is overridden onto the live Deployment here.
#
# This script did not need the line when its evidence log was captured on 2026-08-07: ci.yml began rewriting that pin on every publish in September, and re-running this script today fails in ImagePullBackOff.
k -n "$NS" set image "$DEP" manager=controller:latest >>"$LOG" 2>&1 || die "override operator image"
k -n "$NS" patch "$DEP" --type=json \
  -p '[{"op":"add","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"IfNotPresent"}]' >>"$LOG" 2>&1 || true

kustomize build config/device-plugin | k apply -f - >>"$LOG" 2>&1 || die "deploy device-plugin"
k -n "$NS" set env ds/gpu-simulator FAKE_GPU_COUNT=2 >>"$LOG" 2>&1 || die "set FAKE_GPU_COUNT"
k -n "$NS" patch ds gpu-simulator --type=json \
  -p '[{"op":"add","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"IfNotPresent"}]' >>"$LOG" 2>&1 || true

# Force both workloads to pick up the freshly loaded images.
#
# The images use the :latest tag, so re-applying an unchanged manifest would not restart the pods, and a rerun would keep the previous binary.
k -n "$NS" rollout restart "$DEP" >>"$LOG" 2>&1 || true
k -n "$NS" rollout restart ds/gpu-simulator >>"$LOG" 2>&1 || true

log "waiting for operator and device plugin rollouts..."
k -n "$NS" rollout status "$DEP" --timeout=180s >>"$LOG" 2>&1 || die "operator rollout"
k -n "$NS" rollout status ds/gpu-simulator --timeout=180s >>"$LOG" 2>&1 || die "device-plugin rollout"

log "waiting for a node to advertise nvidia.com/gpu..."
for i in $(seq 1 40); do
  cap_gpu=$(k get nodes -o jsonpath='{range .items[*]}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}' 2>/dev/null | grep -v '^$' | head -1)
  [ -n "$cap_gpu" ] && { log "  node advertises nvidia.com/gpu=$cap_gpu"; break; }
  sleep 3
done
cap k get nodes -o custom-columns=NODE:.metadata.name,GPU:.status.allocatable.nvidia\\.com/gpu

# Whether admission validation is in front of the submissions, recorded rather than required.
#
# config/operator deploys no webhook, and cmd/main.go serves one only when a certificate is supplied, so on a
# cluster built by this script there is no ValidatingWebhookConfiguration and MLTrainingJob is admitted
# unvalidated. That is the operator's documented fallback, not a fault -- and it means this run does NOT
# exercise the quota guard, which is worth a line in the evidence rather than a silent absence.
#
# An earlier version of this block waited for a webhook endpoint and killed the run when none appeared. It was
# generalised from the long-lived `platform` cluster, which carries a webhook installed by some other overlay
# 43 days ago; a submission there was once refused with "connection refused" because that stale configuration
# pointed at an operator that was crash-looping for want of the WorkloadRun CRD. Fixing the CRD fixed it.
# Asked of the rules, not of the object's name.
#
# `get validatingwebhookconfiguration` prints NAME and WEBHOOKS and nothing else, and the configuration this
# operator installs is called gpu-platform-control-plane-validating-webhook-configuration -- the word
# mltrainingjob appears only inside it, in .webhooks[].name and .rules[].resources. So the previous grep
# reported "no webhook" on the one cluster that has one, which is a false negative about the guard that
# decides whether this run demonstrates the quota boundary at all.
if k get validatingwebhookconfiguration \
     -o jsonpath='{range .items[*]}{range .webhooks[*]}{.rules[*].resources}{"\n"}{end}{end}' 2>/dev/null \
     | grep -qw mltrainingjobs; then
  log "admission: a MLTrainingJob validating webhook is installed on this cluster"
  cap k -n "$NS" get endpoints gpu-platform-control-plane-webhook-service
else
  log "admission: no MLTrainingJob validating webhook on this cluster -- submissions are not validated,"
  log "           so the GPU quota guard is not part of what this run demonstrates"
fi

step "5. apply gpu ResourceFlavor, tenant namespaces, and two GPUQuotaPolicy"
run k apply -f config/kueue/namespaces.yaml || die "namespaces"
run k apply -f config/kueue/resourceflavor.yaml || die "resourceflavor"
# The per-tenant ClusterQueues and LocalQueues are created by the operator from these policies.
#
# The ceiling is 1 GPU per tenant so the two ClusterQueues share one cohort with total nominal 2, which is the deterministic sizing the borrowing and reclaim demo needs.
apply_policy() {
  local tenant=$1
  cat <<EOF | k apply -f - >>"$LOG" 2>&1
apiVersion: platform.lkhun9311.github.io/v1
kind: GPUQuotaPolicy
metadata:
  name: ${tenant}-quota
spec:
  tenant: ${tenant}
  targetNamespace: ${tenant}
  gpuClass: l40s
  limits:
    gpuCount: 1
  trainingQuota: true
EOF
  log "+ applied GPUQuotaPolicy ${tenant}-quota (ceiling 1)"
}
apply_policy tenant-a || die "policy a"
apply_policy tenant-b || die "policy b"

log "waiting for the operator to create both ClusterQueues with nominal quota 1..."
for i in $(seq 1 40); do
  na=$(k get clusterqueue gpu-tenant-a -o jsonpath='{.spec.resourceGroups[0].flavors[0].resources[0].nominalQuota}' 2>/dev/null)
  nb=$(k get clusterqueue gpu-tenant-b -o jsonpath='{.spec.resourceGroups[0].flavors[0].resources[0].nominalQuota}' 2>/dev/null)
  [ "$na" = "1" ] && [ "$nb" = "1" ] && { log "  both ClusterQueues present, nominal quota 1 each, cohort total 2"; break; }
  sleep 3
done
cap k get clusterqueue -o custom-columns=NAME:.metadata.name,COHORT:.spec.cohortName,NOMINAL:.spec.resourceGroups[0].flavors[0].resources[0].nominalQuota,RECLAIM:.spec.preemption.reclaimWithinCohort
cap k get localqueue -A
# Captured rather than asserted in prose: with trainingQuota true the GPU ceiling must live only in the
# ClusterQueue, and a stale namespace ResourceQuota left by an earlier run is exactly what would silently
# double-count it, so the absence has to be in the evidence log.
cap k get resourcequota -A

step "6. FAIR SHARING: two tenant-a jobs while tenant-b is idle"
log "clearing any MLTrainingJobs from a previous run so the demo starts from an empty cohort..."
k -n tenant-a delete mltrainingjob --all >>"$LOG" 2>&1 || true
k -n tenant-b delete mltrainingjob --all >>"$LOG" 2>&1 || true
for i in $(seq 1 20); do
  n=$(k get workloads -A --no-headers 2>/dev/null | wc -l)
  [ "$n" = "0" ] && { log "  all Workloads cleared"; break; }
  sleep 3
done
log "a1 uses tenant-a's own nominal unit; a2 borrows tenant-b's idle unit from the cohort."
submit_job a1 tenant-a gpu-tenant-a
submit_job a2 tenant-a gpu-tenant-a
# The waits decide the heading. They used to be discarded with `|| true` while the line below asserted "a1 +
# a2 both Running" unconditionally, so a run in which no MLTrainingJob existed at all printed that claim over
# an empty table and exited 0.
wait_phase tenant-a a1 Running 120 || die "a1 never reached Running; fair sharing cannot be demonstrated"
wait_phase tenant-a a2 Running 120 || die "a2 never reached Running; the borrow did not happen"
log "\n[EVIDENCE] fair sharing: tenant-a borrows past its nominal (a1 + a2 both Running)"
phases

step "7. PREEMPTION: tenant-b reclaims its nominal unit"
log "b1 makes tenant-b claim its own unit; reclaimWithinCohort=Any preempts the borrowed tenant-a job."
submit_job b1 tenant-b gpu-tenant-b
wait_phase tenant-b b1 Running 120 || die "b1 never reached Running; there is no reclaim to observe"
# one of the tenant-a jobs must be pushed back out of Running by the reclaim
log "waiting for a borrowed tenant-a job to be preempted back to Pending..."
preempted=""
for ((i=0; i<120; i+=3)); do
  for j in a1 a2; do
    p=$(k -n tenant-a get mltrainingjob "$j" -o jsonpath='{.status.phase}' 2>/dev/null)
    if [ "$p" = "Pending" ]; then preempted="$j"; break; fi
  done
  [ -n "$preempted" ] && break
  sleep 3
done
if [ -n "$preempted" ]; then
  log "  [EVIDENCE] preemption: tenant-a/$preempted was reclaimed back to Pending after b1 admitted"
else
  log "  no tenant-a job returned to Pending within the window -- the evidence below is dumped anyway,"
  log "  and this run does NOT demonstrate reclaim"
fi
log "\n[EVIDENCE] preemption result"
phases
log "\n--- recent Kueue / preemption events ---"
cap k get events -A --field-selector reason=Preempted
cap k -n tenant-a get events --sort-by=.lastTimestamp

# The verdict, after the evidence rather than before it.
#
# This used to print a NOTE and walk on to DONE with exit 0, so a run in which nothing was ever preempted
# reported success for the one thing the second half of this script exists to show. b1 being admitted while
# tenant-a keeps both units is not reclaim: it is a cohort with room in it, which is the opposite reading.
# The dump above stays unconditional because a failure is exactly when its contents are wanted.
[ -n "$preempted" ] || die "no tenant-a job was reclaimed to Pending after b1 was admitted; reclaim is not demonstrated by this run"

step "DONE"
log "Cluster '$CLUSTER' left running for inspection. Tear down with: kind delete cluster --name $CLUSTER"
