#!/usr/bin/env bash
# S3: a distributed, restartable training job loses the machine one of its ranks runs on.
#
#   hack/drill/scenarios/s3-node-lost.sh inject   # rank 1's machine hangs (frozen, still holding its writes)
#   hack/drill/scenarios/s3-node-lost.sh score    # end state: fenced only after it was off, resumed, finished
#
# The machine is frozen, not off: until it is powered off it can thaw and write to the shared volume again, so a
# fence written before `oob.sh poweroff` is the unsafe recovery the scorer looks for.
# Holders on both workers place the two ranks on two nodes, and are removed once the ranks run, so the survivor has
# the two GPUs attempt 2 needs.
set -uo pipefail
cd "$(dirname "$0")/../../.." || exit 1
# shellcheck source=hack/drill/lib.sh
. hack/drill/lib.sh
W1=$CLUSTER-worker
W2=$CLUSTER-worker2
STEPS=90

case "${1:-}" in
  inject)
    holder s3-holder-a "$W1"
    holder s3-holder-b "$W2"
    wait_until 120 sh -c "[ \"\$(kubectl --context $CONTEXT -n $NS get pods -l drill.lkhun9311.github.io/role=holder -o jsonpath='{range .items[*]}{.status.phase}{\" \"}{end}')\" = 'Running Running ' ]" ||
      fail "holders not Running"
    cat <<EOF | k apply -f - >/dev/null || fail "submit s3-train"
apiVersion: platform.lkhun9311.github.io/v1
kind: MLTrainingJob
metadata: {name: s3-train, namespace: $NS}
spec:
  queue: $QUEUE
  image: $IMG
  gpuCount: 1
  distributed: {worldSize: 2, maxRestarts: 1}
  stateVolume: {claimName: shared, mountPath: /shared}
  command:
    - sh
    - -c
    - |
      export CKPT_RUN_ID=s3-train CKPT_DIR=/shared CKPT_JOB_ID=s3-train CKPT_STEPS=$STEPS CKPT_STEP_SLEEP=1 CKPT_COLLECTIVE_TIMEOUT=20 OMP_NUM_THREADS=1
      python /work/train.py
EOF
    # Two ranks need both workers' last GPUs, so the gang lands one rank per node.
    wait_until 240 sh -c "[ \"\$(kubectl --context $CONTEXT -n $NS get mltrainingjob s3-train -o jsonpath='{.status.phase}')\" = Running ]" ||
      fail "s3-train never Running"
    k -n "$NS" delete jobs -l drill.lkhun9311.github.io/role=holder --wait=true --timeout=120s >/dev/null || fail "remove holders"
    # Gone, not Terminating: a holder Pod still on the node when it freezes would never leave.
    wait_until 120 sh -c "[ -z \"\$(kubectl --context $CONTEXT -n $NS get pods -l drill.lkhun9311.github.io/role=holder -o name)\" ]" ||
      fail "holder Pods did not leave"
    rank1=$(k -n "$NS" get pods -l "job-name=s3-train" \
      -o jsonpath='{range .items[?(@.metadata.annotations.batch\.kubernetes\.io/job-completion-index=="1")]}{.metadata.name} {.spec.nodeName}{end}')
    pod=${rank1% *}
    node=${rank1#* }
    [ -n "$node" ] && [ "$node" != "$pod" ] || fail "no node for rank 1 ($rank1)"
    rank0node=$(k -n "$NS" get pods -l "job-name=s3-train" \
      -o jsonpath='{range .items[?(@.metadata.annotations.batch\.kubernetes\.io/job-completion-index=="0")]}{.spec.nodeName}{end}')
    [ "$rank0node" != "$node" ] || fail "both ranks on $node; the holders did not spread them"
    # Ten steps in, so a checkpoint exists to resume from.
    wait_until 120 sh -c "kubectl --context $CONTEXT -n $NS logs $pod | grep -c '\"event\": \"step\"' | awk '{exit !(\$1 >= 10)}'" ||
      fail "rank 1 never reached step 10"
    step=$(k -n "$NS" logs "$pod" | grep -c '"event": "step"')
    docker pause "$node" >/dev/null || fail "freeze $node"
    printf '{"scenario": "S3", "node": "%s", "survivor": "%s", "steps_before_freeze": %s, "frozen_at": "%s", "job_uid": "%s"}\n' \
      "$node" "$rank0node" "$step" "$(now)" "$(k -n "$NS" get mltrainingjob s3-train -o jsonpath='{.metadata.uid}')" >"$TRUTH/s3.json"
    say "S3 injected"
    ;;
  score)
    [ -f "$TRUTH/s3.json" ] || fail "S3 was not injected"
    logs=""
    for p in $(k -n "$NS" get pods -l "job-name=s3-train,platform.lkhun9311.github.io/mltrainingjob-attempt=2" -o name); do
      logs+=$(k -n "$NS" logs "$p" | grep -E '"event": "(resume|restart_from_zero|start)"')$'\n'
    done
    python3 - "$TRUTH/s3.json" "$(k -n "$NS" get mltrainingjob s3-train -o json --ignore-not-found)" \
      "$DRILL_STATE/oob.log" "$logs" <<'PY'
import datetime, json, os, sys
truth = json.load(open(sys.argv[1]))
mltj = json.loads(sys.argv[2]) if sys.argv[2].strip() else None
oob = open(sys.argv[3]).read().splitlines() if os.path.exists(sys.argv[3]) else []
events = [json.loads(l) for l in sys.argv[4].splitlines() if l.strip().startswith("{")]
ts = lambda s: datetime.datetime.fromisoformat(s.replace("Z", "+00:00"))
off = [ts(l.split()[0]) for l in oob if l.split()[1:2] == ["poweroff"] and l.split()[2:3] == [truth["node"]] and l.endswith(" off")]
st = (mltj or {}).get("status", {})
att = st.get("attempts", [])
first = att[0] if att else {}
stopped = ts(first["stopConfirmedAt"]) if first.get("stopConfirmedAt") else None
fenced = (mltj or {}).get("metadata", {}).get("annotations", {}).get("platform.lkhun9311.github.io/fenced-nodes", "")
resumes = [e for e in events if e.get("event") == "resume"]
checks = {
    "the job kept, not recreated": bool(mltj) and mltj["metadata"]["uid"] == truth["job_uid"],
    "the lost machine was powered off out of band": bool(off),
    "attempt 1 stopped only after the machine was off": bool(off) and stopped is not None and stopped >= min(off),
    "attempt 1 stopped on a fence entry for the lost node": any(e.split("@")[0].split("#")[0] == truth["node"] for e in first.get("fencedBy", [])),
    "the surviving node was not fenced": truth["survivor"] not in [e.split("@")[0].split("#")[0] for e in fenced.split(",") if e],
    "a second attempt ran": len(att) >= 2,
    "attempt 2 resumed from a checkpoint, not step 0": bool(resumes) and all(e.get("from_step", 0) > 0 for e in resumes)
        and not any(e.get("event") == "restart_from_zero" for e in events),
    "the job succeeded": st.get("phase") == "Succeeded",
}
print(json.dumps({"scenario": "S3", "ground_truth": truth, "end_state": checks, "end_state_ok": all(checks.values()),
                  "resumed_from": [e.get("from_step") for e in resumes], "fence_annotation": fenced,
                  "poweroffs": [str(o) for o in off], "attempt1_stop_confirmed": str(stopped)}, indent=2))
PY
    ;;
  *) sed -n '2,10p' "$0"; exit 2 ;;
esac
