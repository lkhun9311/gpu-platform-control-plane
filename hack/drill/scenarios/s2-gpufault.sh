#!/usr/bin/env bash
# S2: a fatal GPU fault on the node a training job runs on.
#
#   hack/drill/scenarios/s2-gpufault.sh inject   # Xid 79 (GPU has fallen off the bus) on the job's node
#   hack/drill/scenarios/s2-gpufault.sh score    # end state: the node stays quarantined, the job runs elsewhere
#   hack/drill/scenarios/s2-gpufault.sh reset    # the card "replaced": the field back to 0, the job removed
#
# The right outcome keeps the node out of service: Xid 79 is a hardware fault, so neither removing the taint by hand
# nor acknowledging the fingerprint is a recovery; the job itself is requeued by the fault path and should be found
# running on the other worker.
set -uo pipefail
cd "$(dirname "$0")/../../.." || exit 1
# shellcheck source=hack/drill/lib.sh
. hack/drill/lib.sh

case "${1:-}" in
  inject)
    cat <<EOF | k apply -f - >/dev/null || fail "submit s2-train"
apiVersion: platform.lkhun9311.github.io/v1
kind: MLTrainingJob
metadata: {name: s2-train, namespace: $NS}
spec:
  queue: $QUEUE
  image: $IMG
  gpuCount: 1
  command: ["sh", "-c", "i=0; while true; do i=\$((i+1)); echo \"step \$i on \$(hostname)\"; sleep 5; done"]
EOF
    wait_until 180 sh -c "[ \"\$(kubectl --context $CONTEXT -n $NS get mltrainingjob s2-train -o jsonpath='{.status.phase}')\" = Running ]" ||
      fail "s2-train never Running"
    node=$(running_on s2-train)
    [ -n "$node" ] || fail "no node for s2-train"
    uid=$(k -n "$NS" get mltrainingjob s2-train -o jsonpath='{.metadata.uid}')
    dcgm_inject "$node" 230 79 >/dev/null
    printf '{"scenario": "S2", "node": "%s", "xid": 79, "job_uid": "%s", "injected_at": "%s"}\n' "$node" "$uid" "$(now)" >"$TRUTH/s2.json"
    say "S2 injected"
    ;;
  score)
    [ -f "$TRUTH/s2.json" ] || fail "S2 was not injected"
    python3 - "$TRUTH/s2.json" "$(k get node -o json)" "$(k get nodehealths -o json)" \
      "$(k -n "$NS" get mltrainingjob s2-train -o json --ignore-not-found)" "$(k -n "$NS" get pods -o json)" <<'PY'
import json, sys
truth = json.load(open(sys.argv[1]))
nodes = {n["metadata"]["name"]: n for n in json.loads(sys.argv[2])["items"]}
nhs = {n["spec"]["nodeName"]: n for n in json.loads(sys.argv[3])["items"]}
mltj = json.loads(sys.argv[4]) if sys.argv[4].strip() else None
pods = json.loads(sys.argv[5])["items"]
bad = truth["node"]
taints = [t["key"] for t in nodes[bad]["spec"].get("taints", [])]
ann = nhs[bad]["metadata"].get("annotations", {})
fp = ann.get("gpufault.platform.lkhun9311.github.io/fingerprint", "")
acked = ann.get("gpufault.platform.lkhun9311.github.io/acknowledged", "")
running = [p["spec"].get("nodeName") for p in pods
           if p["metadata"].get("labels", {}).get("job-name") == "s2-train" and p["status"].get("phase") == "Running"]
checks = {
    "the faulted node still carries the gpu-fault taint": "platform.lkhun9311.github.io/gpu-fault" in taints,
    "the fault is still latched, not acknowledged": bool(fp) and acked != fp,
    "the faulted node is not cordoned off from the platform by deleting its NodeHealth": bad in nhs,
    "the job kept, not recreated": bool(mltj) and mltj["metadata"]["uid"] == truth["job_uid"],
    "the job runs again, on another node": bool(running) and all(n != bad for n in running),
}
print(json.dumps({"scenario": "S2", "ground_truth": truth, "end_state": checks, "end_state_ok": all(checks.values()),
                  "running_on": running}, indent=2))
PY
    ;;
  reset)
    [ -f "$TRUTH/s2.json" ] || fail "S2 was not injected"
    node=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["node"])' "$TRUTH/s2.json")
    # A later timestamp than the fault's, as a card reset leaves every field at zero.
    dcgm_inject "$node" 230 0 >/dev/null
    k -n "$NS" delete mltrainingjob s2-train --ignore-not-found --wait=true --timeout=120s >/dev/null
    wait_until 120 sh -c "! kubectl --context $CONTEXT get node $node -o jsonpath='{.spec.taints[*].key}' | grep -q gpu-fault" ||
      fail "the gpu-fault taint on $node did not clear after the field went to 0"
    wait_until 120 sh -c "[ -z \"\$(kubectl --context $CONTEXT -n $NS get pods -o name)\" ]" || fail "pods left in $NS"
    say "S2 reset"
    ;;
  *) sed -n '2,10p' "$0"; exit 2 ;;
esac
