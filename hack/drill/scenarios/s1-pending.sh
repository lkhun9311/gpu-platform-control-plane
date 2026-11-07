#!/usr/bin/env bash
# S1: a training job that does not start, for one of two reasons the engineer must name.
#
#   hack/drill/scenarios/s1-pending.sh inject   # picks fragmentation or quota (DRILL_S1_VARIANT to fix it)
#   hack/drill/scenarios/s1-pending.sh score    # end state only: nothing of anyone else's was taken away
#   hack/drill/scenarios/s1-pending.sh reset
#
# fragmentation: one holder on each worker, so two GPUs are free, one per node, and the two-GPU job is admitted by
#   Kueue (the quota covers it) but no node can take its Pod.
# quota: the tenant's quota lowered to 3, both holders on one worker, so the other worker has two free GPUs and the
#   job's Workload is never admitted.
# The ground truth goes to the drill's state directory, outside the repository.
set -uo pipefail
cd "$(dirname "$0")/../../.." || exit 1
# shellcheck source=hack/drill/lib.sh
. hack/drill/lib.sh
W1=$CLUSTER-worker
W2=$CLUSTER-worker2

case "${1:-}" in
  inject)
    variant=${DRILL_S1_VARIANT:-$(shuf -n1 -e fragmentation quota)}
    case "$variant" in
      fragmentation)
        holder s1-holder-a "$W1"
        holder s1-holder-b "$W2"
        quota=4
        reason="fragmentation: two GPUs are free, one on each worker; the job asks for two in one Pod, which no single node can give"
        ;;
      quota)
        k patch gpuquotapolicy "$NS-quota" --type=merge -p '{"spec":{"limits":{"gpuCount":3}}}' >/dev/null || fail "lower quota"
        holder s1-holder-a "$W1"
        holder s1-holder-b "$W1"
        quota=3
        reason="quota: the tenant's ClusterQueue allows 3 GPUs, the two holders use 2, and the job asks for 2 more, though $W2 has 2 free"
        ;;
      *) fail "unknown variant $variant" ;;
    esac
    wait_until 120 sh -c "[ \"\$(kubectl --context $CONTEXT -n $NS get pods -l drill.lkhun9311.github.io/role=holder -o jsonpath='{range .items[*]}{.status.phase}{\" \"}{end}')\" = 'Running Running ' ]" ||
      fail "holders not Running"
    cat <<EOF | k apply -f - >/dev/null || fail "submit s1-train"
apiVersion: platform.lkhun9311.github.io/v1
kind: MLTrainingJob
metadata: {name: s1-train, namespace: $NS}
spec:
  queue: $QUEUE
  image: $IMG
  gpuCount: 2
  command: ["sleep", "600"]
EOF
    sleep 20
    python3 - "$TRUTH/s1.json" "$variant" "$reason" "$quota" \
      "$(k -n "$NS" get jobs -l drill.lkhun9311.github.io/role=holder -o jsonpath='{range .items[*]}{.metadata.name}={.metadata.uid}{" "}{end}')" \
      "$(k -n "$NS" get mltrainingjob s1-train -o jsonpath='{.metadata.uid}')" <<'PY'
import json, sys
path, variant, reason, quota, holders, uid = sys.argv[1:]
json.dump({"scenario": "S1", "variant": variant, "reason": reason, "quota": int(quota),
           "holders": dict(h.split("=") for h in holders.split()), "job_uid": uid}, open(path, "w"), indent=2)
PY
    say "S1 injected: MLTrainingJob $NS/s1-train does not start"
    ;;
  score)
    [ -f "$TRUTH/s1.json" ] || fail "S1 was not injected"
    python3 - "$TRUTH/s1.json" \
      "$(k -n "$NS" get jobs -l drill.lkhun9311.github.io/role=holder -o json)" \
      "$(k -n "$NS" get mltrainingjob s1-train -o json --ignore-not-found)" \
      "$(k get gpuquotapolicy "$NS-quota" -o jsonpath='{.spec.limits.gpuCount}')" <<'PY'
import json, sys
truth = json.load(open(sys.argv[1]))
jobs = {j["metadata"]["name"]: j for j in json.loads(sys.argv[2])["items"]}
mltj = json.loads(sys.argv[3]) if sys.argv[3].strip() else None
quota = int(sys.argv[4] or 0)
checks = {
    "holders untouched": all(n in jobs and jobs[n]["metadata"]["uid"] == u for n, u in truth["holders"].items()),
    "the job kept, not recreated": bool(mltj) and mltj["metadata"]["uid"] == truth["job_uid"],
    "the tenant's quota unchanged": quota == truth["quota"],
}
out = {"scenario": "S1", "variant": truth["variant"], "ground_truth_reason": truth["reason"],
       "end_state": checks, "end_state_ok": all(checks.values()),
       "note": "the diagnosis itself is scored from the engineer's report against ground_truth_reason"}
print(json.dumps(out, indent=2))
PY
    ;;
  reset)
    k -n "$NS" delete mltrainingjob s1-train --ignore-not-found --wait=true --timeout=120s >/dev/null
    k -n "$NS" delete jobs -l drill.lkhun9311.github.io/role=holder --ignore-not-found --wait=true --timeout=120s >/dev/null
    k patch gpuquotapolicy "$NS-quota" --type=merge -p '{"spec":{"limits":{"gpuCount":4}}}' >/dev/null || fail "restore quota"
    wait_until 120 sh -c "[ -z \"\$(kubectl --context $CONTEXT -n $NS get pods -o name)\" ]" || fail "pods left in $NS"
    say "S1 reset"
    ;;
  *) sed -n '2,8p' "$0"; exit 2 ;;
esac
