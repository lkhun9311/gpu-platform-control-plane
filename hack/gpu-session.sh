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
  echo "usage: $0 <worker-node> [-- <extra queuelabrun flags>]" >&2
  echo "  env: NS=$NS LOCAL_PORT=$LOCAL_PORT" >&2
  exit 2
fi
shift || true
[[ "${1:-}" == "--" ]] && shift || true

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
  -device-metrics "$URL" -device-observer "$OBSERVER" "$@"
STATUS=$?
set -e
if [[ $STATUS -eq 0 ]]; then
  echo
  echo "the route is torn down with this script. For the runs, hold it open in another shell:"
  echo "  kubectl port-forward -n $NS pod/$POD ${LOCAL_PORT}:9400"
  echo "and pass to each run:"
  echo "  -device-metrics $URL -device-observer $OBSERVER"
  echo
  # The ordering is not a convenience. This preflight has just pulled the workload image onto the node, so
  # every run after it starts warm; a run taken before it would pull inside its own observation window,
  # pushing container stops later and possibly past the horizon, which turns its waste figure into a floor.
  # The estimand this lab publishes is warm-node reclaim, and this is what makes it true.
  echo "run the protocol AFTER this, not before: the node is warm now, and a run taken cold pulls inside"
  echo "its own observation window and can censor its own waste figure."
fi
exit $STATUS
