#!/usr/bin/env bash
#
# M7 end to end: inject a failure, and let the trail record what it saw.
#
# The point is not that a controller compiles. It is that the evidence for a chaos scenario is ASSEMBLED
# from the cluster rather than written by hand afterwards -- which is how the pages this repository has had
# to retract came to be wrong.
#
# It builds its OWN kind cluster and deletes it. That is not politeness: driving a WorkloadRun needs a
# reconciler running against the apiserver, and pointing one at a cluster that already has an operator puts
# two reconcilers on the same objects. A throwaway cluster is the only way to run this without touching
# whatever else is deployed.
#
# The target is an ordinary web server rather than a GPU workload, and deliberately so: M7 is about the
# recorder, and using a card here would make an evidence-trail test depend on hardware it does not need.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
export GOTOOLCHAIN=go1.26.0

CLUSTER="${CLUSTER:-m7-evidence}"
KCTX="kind-$CLUSTER"
NS=m7
LOG=hack/m7-evidence-trail.log
WORK="$(mktemp -d)"

k() { kubectl --context "$KCTX" "$@"; }
say() { echo "== $*" | tee -a "$LOG"; }
note() { echo "$*" | tee -a "$LOG"; }
fail() { echo "M7 FAILED: $*" | tee -a "$LOG" >&2; exit 1; }

cleanup() {
  [ -n "${DRIVER_PID:-}" ] && kill "$DRIVER_PID" 2>/dev/null
  if [ -z "${KEEP:-}" ]; then
    say "delete the throwaway cluster"
    kind delete cluster --name "$CLUSTER" >/dev/null 2>&1
  else
    say "KEEP set: leaving cluster $CLUSTER"
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

: > "$LOG"

# Refuse to run against anything that already exists. Reusing a cluster by that name would make this
# script's isolation a claim rather than a fact.
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  fail "a cluster named $CLUSTER already exists; this script owns its cluster and will not adopt one"
fi

# The failure this catches is real, was hit here, and its message names neither inotify nor a limit.
#
# A second kind cluster on a host whose fs.inotify.max_user_instances is the default 128 dies during node
# preparation with "could not find a log line that matches ... Multi-User System", and the cause is only
# visible inside the node that kind has already deleted: systemd reporting "Failed to create control group
# inotify object: Too many open files". Every kind node consumes instances, so an existing cluster plus an
# editor and a docker daemon is enough to exhaust them.
instances=$(sysctl -n fs.inotify.max_user_instances 2>/dev/null || echo 0)
running=$(docker ps --filter label=io.x-k8s.kind.cluster --format '{{.Names}}' 2>/dev/null | wc -l)
if [ "${instances:-0}" -lt 256 ] && [ "${running:-0}" -gt 0 ]; then
  cat <<EOF

fs.inotify.max_user_instances is $instances and $running kind node(s) are already running. Creating another
cluster will fail during node preparation with a message about a missing log line, which is not what went
wrong. Raise the limit first:

    sudo sysctl fs.inotify.max_user_instances=512

To make it survive a reboot:

    echo 'fs.inotify.max_user_instances=512' | sudo tee /etc/sysctl.d/99-kind.conf

EOF
  fail "not enough inotify instances for another kind cluster"
fi

say "create the throwaway cluster"
kind create cluster --name "$CLUSTER" --wait 120s >/dev/null 2>&1 || fail "create cluster"

say "install the CRDs"
k apply -k config/crd >/dev/null || fail "apply CRDs"
k wait --for=condition=Established crd/workloadruns.platform.lkhun9311.github.io --timeout=60s >/dev/null \
  || fail "the WorkloadRun CRD never established"

say "create the target"
k create ns "$NS" >/dev/null || fail "create namespace"
# A Deployment and Service the operator would have made, made directly: this cluster runs no operator, on
# purpose, and the recorder reads the InferenceDeployment's phase rather than the Deployment's.
k apply -n "$NS" -f - >/dev/null <<EOF || fail "apply the target workload"
apiVersion: apps/v1
kind: Deployment
metadata: {name: m7-target, labels: {app: m7-target}}
spec:
  replicas: 1
  selector: {matchLabels: {app: m7-target}}
  template:
    metadata: {labels: {app: m7-target}}
    spec:
      containers:
        - name: server
          image: registry.k8s.io/e2e-test-images/agnhost:2.47
          args: ["netexec", "--http-port=8080"]
          ports: [{containerPort: 8080}]
          readinessProbe:
            httpGet: {path: /, port: 8080}
            periodSeconds: 2
EOF
k rollout status deploy/m7-target -n "$NS" --timeout=180s >/dev/null || fail "the target never became ready"

# The InferenceDeployment is the object the run watches, and this script drives its phase directly because
# no operator is running here. That is honest rather than convenient: the recorder's contract is with the
# target's REPORTED phase, and the test of the recorder is whether it captures transitions in that phase.
k apply -n "$NS" -f - >/dev/null <<EOF || fail "apply the InferenceDeployment"
apiVersion: platform.lkhun9311.github.io/v1
kind: InferenceDeployment
metadata: {name: m7-target}
spec:
  model: {name: demo, storageUri: "hf://demo"}
  image: registry.k8s.io/e2e-test-images/agnhost:2.47
  gpuCount: 0
  replicas: 1
  port: 8080
EOF

# phaseOf mirrors what an operator would publish, derived from the Deployment's own readiness rather than
# asserted: a script that simply wrote "Ready" would be testing the recorder against a constant.
publish_phase() {
  local ready
  ready=$(k get deploy m7-target -n "$NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  local phase=Degraded
  [ "${ready:-0}" -ge 1 ] 2>/dev/null && phase=Ready
  k patch inferencedeployment m7-target -n "$NS" --subresource=status --type=merge \
    -p "{\"status\":{\"phase\":\"$phase\"}}" >/dev/null 2>&1
  echo "$phase"
}
publish_phase >/dev/null

say "create the WorkloadRun"
k apply -n "$NS" -f - >/dev/null <<EOF || fail "apply the WorkloadRun"
apiVersion: platform.lkhun9311.github.io/v1
kind: WorkloadRun
metadata: {name: fr002}
spec:
  scenario: ServingPodKilled
  target: {kind: InferenceDeployment, name: m7-target, namespace: $NS}
  observationWindowSeconds: 60
  recoversWithinSeconds: 45
EOF

say "build and start the recorder"
go build -o "$WORK/workloadrunctl" ./cmd/workloadrunctl || fail "build workloadrunctl"
KUBECONFIG_CTX="$KCTX" kubectl config use-context "$KCTX" >/dev/null 2>&1
"$WORK/workloadrunctl" -name fr002 -namespace "$NS" -timeout 4m > "$WORK/driver.out" 2>"$WORK/driver.err" &
DRIVER_PID=$!

# Keep the target's published phase honest while the window is open. Without this the run would watch a
# field nobody updates and record a platform that never changed -- which is the shape of the hand-written
# page this milestone replaces.
publisher() {
  while kill -0 "$DRIVER_PID" 2>/dev/null; do
    publish_phase >/dev/null
    sleep 2
  done
}
publisher &
PUB_PID=$!

sleep 8
say "inject: delete the serving Pod"
victim=$(k get pod -n "$NS" -l app=m7-target -o jsonpath='{.items[0].metadata.name}')
[ -n "$victim" ] || fail "no serving Pod to delete"
note "deleting $victim"
k delete pod "$victim" -n "$NS" --wait=false >/dev/null || fail "delete the serving Pod"

wait "$DRIVER_PID"
kill "$PUB_PID" 2>/dev/null
cat "$WORK/driver.out" | tee -a "$LOG"

say "the trail"
k get workloadrun fr002 -n "$NS" -o jsonpath='{.status.phase} verdict={.status.verdict} recoveredAt={.status.recoveredAtSeconds}s{"\n"}' | tee -a "$LOG"
k get workloadrun fr002 -n "$NS" -o jsonpath='{range .status.observations[*]}  {.elapsedSeconds}s {.state} healthy={.healthy}{"\n"}{end}' | tee -a "$LOG"

phase=$(k get workloadrun fr002 -n "$NS" -o jsonpath='{.status.phase}')
obs=$(k get workloadrun fr002 -n "$NS" -o jsonpath='{.status.observations[*].state}' | wc -w)
[ "$phase" = Complete ] || fail "the run ended in phase $phase rather than Complete; a trail that refuses is correct behaviour but is not the end-to-end evidence this script exists to produce"
# More than one state, or the recorder watched something that never moved and this proves only that it can
# poll. The injected failure is here precisely so the trail has a transition to carry.
[ "$obs" -ge 2 ] || fail "the trail carries $obs state(s); the injected failure produced no observed transition, so this run is evidence about a constant"

say "M7 OK: a real Pod deletion produced a real transition in a trail nobody wrote by hand."
