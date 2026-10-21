# shellcheck shell=bash
# The multi-Pod DDP arms, run against a cluster the caller already built, for the training session on EKS
# (TRAIN=ddp in hack/eks-gitops-session.sh; docs/superpowers/specs/2026-10-16-nccl-groundwork-design.md, section 5).
#
# It repeats hack/multi-pod-ddp.sh's collector rather than sourcing it, because that harness is registered and must
# stay byte-identical between a run and its reading (experiments/multi-pod-ddp/README.md).
# What the analyzer reads must still be written the same way by both, so hack/test/check-ddp-arms-lib.sh holds
# the record-writing Python here equal to the harness's.
#
# What differs from the kind harness, and why:
#   * train.py travels in the command as base64, because an MLTrainingJob mounts no ConfigMap and an image of our own
#     would need an ECR repository the bootstrap root does not create (design, section 3);
#   * DDP_BACKEND is set by the caller's prelude, so the arm's own environment is the kind harness's;
#   * each arm saves the node objects as nodes.json, which the analyzer's nccl profile reads for the node group.
#
# The caller sets, before calling ddp_run_arm:
#   DDP_CONTEXT  kubectl context          DDP_NS      namespace           DDP_QUEUE   LocalQueue
#   DDP_IMAGE    image, by digest         DDP_SCRIPT  path train.py runs from inside the container
#   DDP_PRELUDE  shell lines run first    DDP_OUT     evidence directory  DDP_BUDGET  seconds per arm
#   DDP_GPU_CLASS  the job's gpuClass, which the platform's admission policy requires of any job asking for a GPU
# and defines log, which takes one message.

ddp_k() { kubectl --context "$DDP_CONTEXT" "$@"; }

# Background collectors are tracked so the caller can stop them; an orphaned `kubectl logs -f` outlives the arm.
DDP_COLLECTORS=()

# ddp_arm_env ARM: the arm's own environment, the kind harness's exactly; fails for an arm it does not know.
ddp_arm_env() {
  case "$1" in
    pass) echo "" ;;
    no-sync) echo "export DDP_NO_SYNC=1" ;;
    bad-address) echo "export MASTER_ADDR=nowhere.invalid" ;;
    one-rank-fails) echo "export DDP_FAIL_RANK=1 DDP_FAIL_DELAY_SECONDS=10 DDP_HOLD_SECONDS=900" ;;
    *) return 1 ;;
  esac
}

# ddp_prelude_for SCRIPT_FILE TARGET BACKEND: shell lines that write the script into the container and pick the backend.
#
# The decoded file is hashed inside the container before it runs, and a mismatch exits 86 before train.py starts:
# train.py records its own hash too, but only once it reaches rendezvous, and a bad-address arm never does.
ddp_prelude_for() {
  local file="$1" target="$2" backend="$3" sha
  sha="$(sha256sum "$file" | cut -d' ' -f1)" || return 1
  printf '%s\n' \
    "echo $(base64 -w0 "$file") | base64 -d >$target" \
    "echo \"$sha  $target\" | sha256sum -c - >/dev/null || exit 86" \
    "export DDP_BACKEND=$backend"
}

# ddp_render_job NAME BODY: the MLTrainingJob, as JSON, whose one container runs BODY under sh -c.
#
# Built by Python, not by a heredoc: a prelude carrying 28 KB of base64 has to land in the command unchanged, and a
# YAML block scalar would need every one of its lines indented by hand.
#
# The class is required, not defaulted: config/policy/gpu-workload-static.yaml refuses a GPU job without one, and the
# kind harness never met that policy because it does not install it (found by hack/test/rehearse-train-session.sh).
ddp_render_job() {
  [[ -n "${DDP_GPU_CLASS:-}" ]] || { echo "DDP_GPU_CLASS is empty; the admission policy refuses a GPU job without a class" >&2; return 1; }
  python3 -c '
import json, sys
name, ns, queue, image, gpu_class, body = sys.argv[1:7]
print(json.dumps({
    "apiVersion": "platform.lkhun9311.github.io/v1", "kind": "MLTrainingJob",
    "metadata": {"name": name, "namespace": ns},
    "spec": {"queue": queue, "image": image, "gpuCount": 1, "gpuClass": gpu_class, "distributed": {"worldSize": 2},
             "command": ["sh", "-c", body]},
}, indent=2))
' "$1" "$DDP_NS" "$DDP_QUEUE" "$DDP_IMAGE" "$DDP_GPU_CLASS" "$2"
}

# ddp_arm_body NAME ARM: the shell the arm's ranks run, the kind harness's with the prelude ahead of the arm's env.
ddp_arm_body() {
  local name="$1" extra
  extra="$(ddp_arm_env "$2")" || return 1
  printf '%s\n' \
    "export DDP_RUN_ID=$name DDP_OUT_DIR=/tmp/evidence OMP_NUM_THREADS=1 DDP_RENDEZVOUS_TIMEOUT_SECONDS=60" \
    "$DDP_PRELUDE" \
    "$extra" \
    "exec python $DDP_SCRIPT"
}

# ddp_collect_pods streams every Pod's log from the moment its container starts, so a Pod the Job controller deletes keeps its records.
ddp_collect_pods() {
  local name=$1 dir=$2 started=" "
  # This runs in a subshell, so the log streams it starts are its own children and are stopped with it.
  # shellcheck disable=SC2046  # word splitting of the pid list is intended
  trap 'kill $(jobs -p) 2>>"$DDP_OUT/log.txt"; exit 0' TERM
  while :; do
    ddp_k -n "$DDP_NS" get pods -l "platform.lkhun9311.github.io/mltrainingjob=$name" -o json >"$dir/.pods.json" 2>>"$DDP_OUT/log.txt" || { sleep 1; continue; }
    python3 - "$dir/.pods.json" "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" >>"$dir/pods.jsonl" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
for p in doc["items"]:
    cs = (p.get("status", {}).get("containerStatuses") or [{}])[0]
    print(json.dumps({
        "observed": sys.argv[2], "uid": p["metadata"]["uid"], "name": p["metadata"]["name"],
        "index": p["metadata"].get("annotations", {}).get("batch.kubernetes.io/job-completion-index"),
        "node": p["spec"].get("nodeName"), "phase": p.get("status", {}).get("phase"),
        "deletionTimestamp": p["metadata"].get("deletionTimestamp"), "state": cs.get("state"),
    }, sort_keys=True))
PY
    for pair in $(python3 -c 'import json,sys
for p in json.load(open(sys.argv[1]))["items"]:
    cs=(p.get("status",{}).get("containerStatuses") or [{}])[0]
    if cs.get("state",{}).get("running") or cs.get("state",{}).get("terminated"):
        print(p["metadata"]["name"]+":"+p["metadata"]["uid"])' "$dir/.pods.json"); do
      case "$started" in *" $pair "*) continue ;; esac
      started="$started$pair "
      ddp_k -n "$DDP_NS" logs -f "${pair%%:*}" >"$dir/log-${pair##*:}.txt" 2>>"$DDP_OUT/log.txt" &
    done
    sleep 1
  done
}

# ddp_run_arm ARM submits one fresh job and samples it once a second until it is terminal or the budget is spent.
#
# Returns 1 only when the arm could not be run at all, with the reason in the arm's VOID, which the analyzer reports.
ddp_run_arm() {
  # Errexit is off inside: a status query that fails while the Job is still being created is a sample to retry, and
  # under a caller's set -e it would otherwise end the arm before any of its evidence was collected.
  local -
  set +e
  local arm=$1 name dir t0 phase jobdone body observed
  name="ddp-$arm-$(date -u +%H%M%S)"
  dir=$DDP_OUT/$arm
  mkdir -p "$dir"
  body="$(ddp_arm_body "$name" "$arm")" || { echo "unknown arm $arm" >"$dir/VOID"; return 1; }
  log "== arm $arm as $name"
  ddp_render_job "$name" "$body" >"$dir/mltrainingjob.yaml" || { echo "could not render the job" >"$dir/VOID"; return 1; }
  ddp_k apply -f "$dir/mltrainingjob.yaml" >>"$DDP_OUT/log.txt" 2>&1 || { log "arm $arm: create refused"; echo "create refused" >"$dir/VOID"; return 1; }
  t0=$(date +%s)
  ddp_collect_pods "$name" "$dir" &
  local collector=$!
  DDP_COLLECTORS+=("$collector")
  phase=""
  while [ $(($(date +%s) - t0)) -le "$DDP_BUDGET" ]; do
    # Assembled by python from whole objects, one line per sample.
    # The first version spliced jsonpath output into a printf, and a stray newline and an empty status split or
    # emptied records, so a scorer that skipped unparsable lines saw no readyRanks at all.
    observed=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)
    ddp_k -n "$DDP_NS" get mltrainingjob "$name" -o json >"$dir/.mltj.json" 2>>"$DDP_OUT/log.txt" || echo null >"$dir/.mltj.json"
    ddp_k -n "$DDP_NS" get job "$name" -o json >"$dir/.job.json" 2>>"$DDP_OUT/log.txt" || echo null >"$dir/.job.json"
    python3 - "$observed" "$dir/.mltj.json" "$dir/.job.json" >>"$dir/timeline.jsonl" <<'PY'
import json, sys
mltj = json.load(open(sys.argv[2]))
job = json.load(open(sys.argv[3]))
print(json.dumps({
    "observed": sys.argv[1],
    "mltj": (mltj or {}).get("status"),
    "jobConditions": ((job or {}).get("status") or {}).get("conditions"),
}, sort_keys=True))
PY
    phase=$(ddp_k -n "$DDP_NS" get mltrainingjob "$name" -o jsonpath='{.status.phase}' 2>>"$DDP_OUT/log.txt")
    jobdone=$(ddp_k -n "$DDP_NS" get job "$name" -o jsonpath='{.status.conditions[?(@.status=="True")].type}' 2>>"$DDP_OUT/log.txt")
    if [[ "$phase" =~ ^(Succeeded|Failed)$ ]] && [[ "$jobdone" =~ (Complete|Failed) ]]; then break; fi
    sleep 1
  done
  log "arm $arm: phase '$phase' after $(($(date +%s) - t0)) s"
  # A few more seconds for the last log lines and the last Pod sample.
  sleep 5
  kill "$collector" 2>>"$DDP_OUT/log.txt"
  wait "$collector" 2>>"$DDP_OUT/log.txt"
  ddp_k -n "$DDP_NS" get mltrainingjob "$name" -o json >"$dir/final-mltj.json" 2>>"$DDP_OUT/log.txt"
  ddp_k -n "$DDP_NS" get service "$name-ddp" -o json >"$dir/final-service.json" 2>>"$DDP_OUT/log.txt"
  ddp_k -n "$DDP_NS" get job "$name" -o json >"$dir/final-job.json" 2>>"$DDP_OUT/log.txt"
  ddp_k -n "$DDP_NS" get workloads -o json >"$dir/final-workloads.json" 2>>"$DDP_OUT/log.txt"
  # The nodes the ranks ran on, with their labels, for the nccl profile's node-group criterion.
  # Saved while they still exist: the session scales the group down after the last arm.
  ddp_k get nodes -o json >"$dir/nodes.json" 2>>"$DDP_OUT/log.txt"
  echo "$name" >"$dir/name"
}
