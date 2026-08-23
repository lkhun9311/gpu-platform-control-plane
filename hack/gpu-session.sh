#!/usr/bin/env bash
# The runner's route to the exporter, which is the one part of a GPU session that existed only as prose.
#
# The runner is a process on somebody's laptop and dcgm-exporter is a DaemonSet Pod with a cluster IP, so
# -device-metrics needs a URL that resolves from outside the cluster. The Service in front of the exporter is
# HEADLESS on purpose -- a round-robin Service would answer alternate scrapes from a different node's
# exporter, producing an observation that interleaves two machines' cards -- which means it has no cluster IP
# to forward to either. So the forward has to target one POD, and specifically the pod on the worker under
# test.
#
# Getting that wrong is silent. A port-forward to the wrong node's exporter scrapes cleanly, parses cleanly,
# and reports that this run's Pod was never seen on any card -- which reads as a device fault. This script
# exists so that choice is made by a selector rather than by whoever runs it.
#
# It does not run the study. It brings up the route, runs the preflight through it, and tears the route down;
# what it leaves behind is a verified URL to pass to the runs.
set -euo pipefail

WORKER="${1:-}"
NS="${NS:-gpu-platform-control-plane-system}"
LOCAL_PORT="${LOCAL_PORT:-9400}"

if [[ -z "$WORKER" ]]; then
  echo "usage: $0 <worker-node> [second-worker-node]" >&2
  echo "  RUN_STUDY=1 runs the study through the verified route; without it the script verifies and stops" >&2
  echo "  env: NS=$NS LOCAL_PORT=$LOCAL_PORT" >&2
  exit 2
fi
shift || true
# A second worker is optional and is what makes the node axis runnable. Without it the study is eight runs
# and the node comparison is not delivered, which the preregistration says plainly.
SECOND_WORKER="${1:-}"

# The exporter's own image digest is what -device-observer declares, and it is read from the RUNNING Pod
# rather than from the manifest. The manifest says what should be deployed; this says what is, and a cluster
# running something else is exactly the case the declaration exists to make visible.
POD="$(kubectl get pods -n "$NS" \
  -l app.kubernetes.io/component=dcgm-exporter \
  --field-selector "spec.nodeName=$WORKER,status.phase=Running" \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [[ -z "$POD" ]]; then
  echo "no running dcgm-exporter pod on $WORKER in namespace $NS." >&2
  echo "  the exporter is not part of any default overlay; deploy it with:" >&2
  echo "    kubectl apply -k config/dcgm-exporter" >&2
  echo "  and check that $WORKER carries the label its nodeSelector requires." >&2
  exit 1
fi

# The container is named "exporter" (the DAEMONSET is named dcgm-exporter). This queried the daemonset's
# name for its container's, matched nothing, and exited one line later -- on every real deployment, as the
# first command of the session. It passed a stand-in check only because the stand-in was written to match
# this script instead of the manifest, which is the failure of building the fixture to fit the code.
#
# The name is taken from the manifest rather than hardcoded again, so the two cannot drift apart silently.
CONTAINER="$(kubectl get pod -n "$NS" "$POD" -o jsonpath='{.spec.containers[0].name}')"
OBSERVER="$(kubectl get pod -n "$NS" "$POD" \
  -o jsonpath="{.status.containerStatuses[?(@.name==\"$CONTAINER\")].imageID}")"
if [[ -z "$OBSERVER" ]]; then
  echo "the exporter pod $POD reports no imageID, so nothing can name what produced its numbers." >&2
  exit 1
fi

# Hold the surplus devices before anything measures on this node.
#
# The arm contrast is physical card scarcity, so a node advertising more devices than the protocol needs
# destroys it silently -- and no rentable instance carries exactly two well-supported cards. The run's
# qualification refuses a node whose SCHEDULABLE device count is not exactly the requirement, so the surplus
# has to be held by something the gate recognises.
#
# The occupier is deployed for the whole session rather than per run: devices appearing and disappearing
# around each measurement is the state the study is trying not to be in.
REQUIRED="${REQUIRED:-2}"
ALLOCATABLE="$(kubectl get node "$WORKER" -o jsonpath='{.status.allocatable.nvidia\.com/gpu}')"
: "${ALLOCATABLE:=0}"
if [[ "$ALLOCATABLE" -gt "$REQUIRED" ]]; then
  SURPLUS=$((ALLOCATABLE - REQUIRED))
  # The workload's own pinned image, read from the source rather than restated. An unpinned tag here would
  # be the drift this repository refuses everywhere else, and a silent fallback to one would be worse than
  # failing: the occupier would still hold the cards, so nothing downstream would notice.
  OCCUPIER_IMAGE="$(grep -oE '"python:[^"]+"' internal/queuelab/submit.go | head -1 | tr -d '"')"
  if [[ -z "$OCCUPIER_IMAGE" ]]; then
    echo "cannot read the pinned workload image from internal/queuelab/submit.go" >&2
    exit 1
  fi
  echo "surplus      : $WORKER advertises $ALLOCATABLE devices and the protocol needs $REQUIRED;"
  echo "               holding $SURPLUS so the owner's Pod has to wait for the victim's card"
  kubectl apply -f - <<EOF >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: queuelab-surplus-occupier
  namespace: $NS
  labels:
    # The key is the marker; the value is not read by the gate. Label values cannot carry prose -- the API
    # server rejects anything outside alphanumerics, dashes, dots and underscores -- so the explanation is
    # an annotation.
    queuelab.gpu-platform/surplus-occupier: "session"
  annotations:
    queuelab.gpu-platform/why: >-
      Holds the devices the protocol must not have. The arm contrast is physical card scarcity, so a node
      advertising more devices than the run needs would let the owner's Pod bind at admission in both arms
      and collapse the difference below the floor.
spec:
  restartPolicy: Never
  nodeName: $WORKER
  tolerations:
    - key: nvidia.com/gpu
      operator: Exists
      effect: NoSchedule
  containers:
    - name: hold
      image: $OCCUPIER_IMAGE
      command: ["python3", "-c", "import signal,sys,time; signal.signal(signal.SIGTERM, lambda *_: sys.exit(0)); time.sleep(10**9)"]
      resources:
        limits:
          nvidia.com/gpu: "$SURPLUS"
EOF
  echo -n "               waiting for it to hold them"
  for _ in $(seq 1 60); do
    [[ "$(kubectl get pod -n "$NS" queuelab-surplus-occupier -o jsonpath='{.status.phase}' 2>/dev/null)" == "Running" ]] && break
    echo -n "."; sleep 2
  done
  echo
  if [[ "$(kubectl get pod -n "$NS" queuelab-surplus-occupier -o jsonpath='{.status.phase}' 2>/dev/null)" != "Running" ]]; then
    echo "the surplus occupier did not start; without it the run's qualification will refuse this node," >&2
    echo "which is the correct outcome and not one to work around by removing the requirement." >&2
    exit 1
  fi
elif [[ "$ALLOCATABLE" -lt "$REQUIRED" ]]; then
  echo "$WORKER advertises $ALLOCATABLE devices and the protocol needs $REQUIRED" >&2
  exit 1
fi

echo "exporter pod : $POD (on $WORKER)"
echo "observer id  : $OBSERVER"

kubectl port-forward -n "$NS" "pod/$POD" "$LOCAL_PORT:9400" >/tmp/queuelab-portforward.log 2>&1 &
PF=$!
# The forward is torn down on every exit path, including a failed preflight. A leaked port-forward is not
# dangerous but it is confusing: the next session finds port 9400 answering and never learns which pod is
# behind it.
trap 'kill "$PF" 2>/dev/null || true' EXIT

URL="http://127.0.0.1:${LOCAL_PORT}/metrics"
for _ in $(seq 1 30); do
  curl -sf -m 2 "$URL" >/dev/null 2>&1 && break
  sleep 1
done
if ! curl -sf -m 2 "$URL" >/dev/null 2>&1; then
  echo "the port-forward did not come up; see /tmp/queuelab-portforward.log" >&2
  exit 1
fi

# Refuse a route that answers with nothing. An exporter serving an empty series set is reachable, parses, and
# attributes nothing -- and a preflight run through it would report a device fault for a metrics-collection
# problem. Checking here separates the two while the fix is still cheap.
if ! curl -sf -m 5 "$URL" | grep -q '^DCGM_FI_DEV_GPU_UTIL{'; then
  echo "the exporter at $URL serves no DCGM_FI_DEV_GPU_UTIL samples." >&2
  echo "  that is a metrics-collection problem, not a device one: check the -f csv argument in" >&2
  echo "  config/dcgm-exporter/daemonset.yaml against the series internal/queuelab/dcgm.go reads." >&2
  exit 1
fi

echo "route up     : $URL"
echo

# NOT exec. exec replaces this shell, which destroys the EXIT trap above -- so the comment promising the
# forward is torn down on every path described the opposite of what the code did, and the forward was left
# either orphaned or dying with the runner.
#
# The exit status is carried through deliberately: a caller scripting the session reads it, and the whole
# point of this mode is that its status decides whether the protocol runs.
set +e
./queuelabrun -device-preflight -worker "$WORKER" \
  -device-metrics "$URL" -device-observer "$OBSERVER"
STATUS=$?
set -e
if [[ $STATUS -ne 0 ]]; then
  exit $STATUS
fi

# Everything above verified the node. What follows RUNS THE STUDY through the same forward, and that is the
# point of the mode rather than a convenience.
#
# The script used to stop here, print the flags, and tear the verified route down -- leaving the operator to
# open another forward and add two flags to twelve invocations by hand. A review ranked the resulting loss
# the most likely avoidable one of the whole session: miss either flag, or have the second forward die
# quietly, and the runs complete, write well-formed records, and say device-not-observed. -require-device
# makes each such run fail loudly, which is a mitigation; not needing a second forward at all is the fix.
if [[ "${RUN_STUDY:-}" != "1" ]]; then
  echo
  echo "the node is verified. To run the study through this same route:"
  echo "  RUN_STUDY=1 $0 $WORKER${SECOND_WORKER:+ $SECOND_WORKER}"
  echo
  echo "and if you would rather drive the runs yourself, hold a forward open in another shell:"
  echo "  kubectl port-forward -n $NS pod/$POD ${LOCAL_PORT}:9400"
  echo "giving every run BOTH the observer and -require-device:"
  echo "  -require-device -device-metrics $URL -device-observer $OBSERVER"
  echo "  (-require-device refuses up front without an observer, and invalidates a run that returns no"
  echo "   device evidence; without it such a run completes and quietly records device-not-observed)"
  echo
  echo "run the protocol AFTER this, not before: the node is warm now, and a run taken cold pulls inside"
  echo "its own observation window and can censor its own waste figure."
  exit 0
fi

# The order is the one the study's comparisons need, and it is checked rather than trusted: every
# comparison this lab publishes requires its factor to alternate in time, so the sequence alternates arm on
# every run and alternates dose and node within each pair of runs a comparison reads. A blocked sequence
# produces the CONFOUNDED warnings the harness prints and the study then cannot use.
#
# With one node the node axis is not delivered at all -- `-compare -mode node` refuses a set in which
# nothing varies -- so the eight-run form is the honest whole of what a one-node session returns.
mkdir -p ex
if [[ -n "${SECOND_WORKER:-}" ]]; then
  SEQUENCE=(
    "self-completing A-honor  sh1 $WORKER"        "grace-bounded A-ignore wi1 $SECOND_WORKER"
    "grace-bounded   A-honor  wh1 $SECOND_WORKER" "grace-bounded A-ignore gi1 $WORKER"
    "grace-bounded   A-honor  gh1 $WORKER"        "self-completing A-ignore si1 $WORKER"
    "self-completing A-honor  sh2 $WORKER"        "grace-bounded A-ignore wi2 $SECOND_WORKER"
    "grace-bounded   A-honor  wh2 $SECOND_WORKER" "grace-bounded A-ignore gi2 $WORKER"
    "grace-bounded   A-honor  gh2 $WORKER"        "self-completing A-ignore si2 $WORKER"
  )
else
  SEQUENCE=(
    "self-completing A-honor  sh1 $WORKER" "grace-bounded   A-ignore gi1 $WORKER"
    "grace-bounded   A-honor  gh1 $WORKER" "self-completing A-ignore si1 $WORKER"
    "self-completing A-honor  sh2 $WORKER" "grace-bounded   A-ignore gi2 $WORKER"
    "grace-bounded   A-honor  gh2 $WORKER" "self-completing A-ignore si2 $WORKER"
  )
fi

echo "running ${#SEQUENCE[@]} runs through the verified route"
echo
N=0
for SPEC in "${SEQUENCE[@]}"; do
  # shellcheck disable=SC2086
  set -- $SPEC
  DOSE=$1 ARM=$2 ID=$3 ON=$4
  N=$((N + 1))
  OUT="ex/gpu-$DOSE-$ARM-$ID.json"
  echo "[$N/${#SEQUENCE[@]}] $ID  $DOSE  $ARM  on $ON"
  # No `|| true`. A run that fails has lost the thing the session is buying, and the ones after it would
  # spend node time on a route or a node that has already stopped working. Stopping here is what makes the
  # remaining budget recoverable.
  ./queuelabrun -require-device -dose "$DOSE" -arm "$ARM" -runid "$ID" -worker "$ON" \
    -device-metrics "$URL" -device-observer "$OBSERVER" -out "$OUT"
done

echo
echo "all ${#SEQUENCE[@]} runs completed. Compare them:"
echo "  ./queuelabrun -compare 'ex/gpu-*.json'"
echo "  ./queuelabrun -compare 'ex/gpu-*.json' -mode model"
if [[ -n "${SECOND_WORKER:-}" ]]; then
  echo "  ./queuelabrun -compare 'ex/gpu-grace-bounded-A-honor-*.json' -mode node"
fi
