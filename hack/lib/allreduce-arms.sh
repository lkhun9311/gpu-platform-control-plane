# shellcheck shell=bash
# Experiment C's arms: one Pod of four GPUs against four Pods of one, on one node, run against a cluster the caller
# already built (TRAIN=allreduce in hack/eks-gitops-session.sh; docs/superpowers/specs/2026-10-27-four-gpu-nccl-design.md).
#
# Each function either prints what it was asked for and returns 0, or says why it could not and returns 1.
# hack/test/check-allreduce-arms-lib.sh tests what can be tested without a cluster: the arm list, the job order, the
# rendered jobs and the shell each rank runs. hack/test/rehearse-four-gpu.sh runs the rest on kind.
#
# The caller sets, before calling ar_run_job or ar_run_all:
#   AR_CONTEXT        kubectl context              AR_NS        namespace           AR_QUEUE     LocalQueue
#   AR_TORCH_IMAGE    the torch image, by digest   AR_NCCLTESTS_IMAGE  the nccl-tests image, by digest
#   AR_GPU_CLASS      the jobs' gpuClass           AR_OUT       evidence directory  AR_BUDGET    seconds per job
#   AR_BENCH_FILE     allreduce_bench.py           AR_STEP_FILE ddp_step_bench.py
#   AR_SCORER         the scorer, called per job for the stop rule, with its approved-hash arguments in AR_SCORER_ARGS
#   AR_REHEARSAL      1 on kind: the DDP arms run on CPU with gloo, which the scorer refuses as a measurement
# and defines log, which takes one message.

# The registered arms, in the registration's order, which is also the smoke jobs' order.
AR_ARMS="nccltests-1pod4gpu allreduce-1pod4gpu allreduce-4pod1gpu ddp-1pod4gpu ddp-4pod1gpu"
# The registered repetitions per arm, and the seed of the one random order they run in.
AR_REPS=5
AR_ORDER_SEED=20261027
# The registered message sizes in bytes: 1, 4, 16, 64 and 256 MiB.
AR_SIZES="1048576,4194304,16777216,67108864,268435456"
# Where each script lands inside the container.
AR_BENCH_TARGET=/tmp/allreduce_bench.py
AR_STEP_TARGET=/tmp/ddp_step_bench.py

ar_k() { kubectl --context "$AR_CONTEXT" --request-timeout=20s "$@"; }

AR_COLLECTORS=()

# ar_shape ARM: "PODS GPUS_PER_POD" for an arm; fails for an arm it does not know.
ar_shape() {
  case "$1" in
    nccltests-1pod4gpu | allreduce-1pod4gpu | ddp-1pod4gpu) echo "1 4" ;;
    allreduce-4pod1gpu | ddp-4pod1gpu) echo "4 1" ;;
    *) return 1 ;;
  esac
}

# ar_job_order SEED: the registered jobs, one "SEQUENCE ARM REPETITION" line each, in one random order.
#
# Completely random rather than blocked: under the sharp null of no arm effect, a random order makes every split of
# two arms' ten slots equally likely, which is what the verdict's 1 / C(10, 5) needs; a blocked or cyclic order does
# not supply it (the registration's review, finding 5). Python's Mersenne Twister with an integer seed is stable
# across Python 3 versions, and the test pins the order this seed gives.
ar_job_order() {
  python3 -c '
import random, sys
arms, reps, seed = sys.argv[1].split(), int(sys.argv[2]), int(sys.argv[3])
jobs = [(arm, rep) for rep in range(1, reps + 1) for arm in arms]
random.Random(seed).shuffle(jobs)
for i, (arm, rep) in enumerate(jobs, 1):
    print(i, arm, rep)
' "$AR_ARMS" "$AR_REPS" "${1:-$AR_ORDER_SEED}"
}

# ar_prelude_for FILE TARGET: shell lines that write the file into the container and refuse to run a different one.
#
# The file travels in the command, because an MLTrainingJob mounts no ConfigMap; the decoded copy is hashed before
# anything runs, and a mismatch exits 86.
ar_prelude_for() {
  local file="$1" target="$2" sha
  sha="$(sha256sum "$file" | cut -d' ' -f1)" || return 1
  printf '%s\n' \
    "echo $(base64 -w0 "$file") | base64 -d >$target" \
    "echo \"$sha  $target\" | sha256sum -c - >/dev/null || exit 86"
}

# ar_common_lines NAME: what every job's Pod runs first, the same in every arm.
#
# NCCL reads /etc/nccl.conf and ~/.nccl.conf as well as the environment, and Python's os.environ cannot see what a
# file set, so each Pod prints whether either exists and every NCCL_ variable it was started with (review, finding 9).
# OMP_NUM_THREADS is set in every arm because torchrun sets it to 1 for the processes it starts and a Pod per rank
# would otherwise not (review, finding 8).
ar_common_lines() {
  printf '%s\n' \
    "export NCCL_DEBUG=INFO NCCL_DEBUG_SUBSYS=INIT,GRAPH,ENV OMP_NUM_THREADS=1" \
    "echo \"AR_RUN_ID $1 \$(hostname)\"" \
    "for f in /etc/nccl.conf \"\$HOME/.nccl.conf\"; do if [ -e \"\$f\" ]; then echo \"AR_NCCL_CONF present \$f\"; sed 's/^/AR_NCCL_CONF_LINE /' \"\$f\"; else echo \"AR_NCCL_CONF absent \$f\"; fi; done" \
    "env | grep '^NCCL_' | sed 's/^/AR_NCCL_ENV /'" \
    "echo \"AR_SHM_KB \$(df -kP /dev/shm | awk 'NR == 2 {print \$2}')\""
}

# ar_arm_body NAME ARM: the shell the arm's Pods run.
ar_arm_body() {
  local name="$1" arm="$2" common
  common="$(ar_common_lines "$name")"
  case "$arm" in
    nccltests-1pod4gpu)
      printf '%s\n' "$common" \
        "nvidia-smi --query-gpu=index,uuid,pci.bus_id,driver_version --format=csv,noheader | sed 's/^/AR_GPU /'" \
        "exec mpirun --allow-run-as-root -np 4 --bind-to none --mca btl self,vader -x NCCL_DEBUG -x NCCL_DEBUG_SUBSYS -x OMP_NUM_THREADS all_reduce_perf -b 1M -e 256M -f 4 -g 1 -c 1 -n 100 -w 20 -a 3"
      ;;
    allreduce-1pod4gpu | allreduce-4pod1gpu)
      printf '%s\n' "$common" "$(ar_prelude_for "$AR_BENCH_FILE" "$AR_BENCH_TARGET")" \
        "export BENCH_RUN_ID=$name BENCH_WARMUP=20 BENCH_ITERS=100 BENCH_SIZES=$AR_SIZES"
      if [[ "$arm" == allreduce-1pod4gpu ]]; then
        echo "exec torchrun --standalone --nproc-per-node=4 $AR_BENCH_TARGET"
      else
        echo "exec python $AR_BENCH_TARGET"
      fi
      ;;
    ddp-1pod4gpu | ddp-4pod1gpu)
      printf '%s\n' "$common" "$(ar_prelude_for "$AR_STEP_FILE" "$AR_STEP_TARGET")" \
        "export STEP_RUN_ID=$name STEP_LAYERS=4 STEP_WIDTH=4096 STEP_BATCH=64 STEP_WARMUP=20 STEP_PAIRS=50"
      [[ "${AR_REHEARSAL:-}" == 1 ]] && echo "export STEP_REHEARSAL_CPU=1 STEP_WIDTH=256"
      if [[ "$arm" == ddp-1pod4gpu ]]; then
        echo "exec torchrun --standalone --nproc-per-node=4 $AR_STEP_TARGET"
      else
        echo "exec python $AR_STEP_TARGET"
      fi
      ;;
    *) return 1 ;;
  esac
}

# ar_qualification_body: what the qualification Pod (one Pod of four GPUs, the nccl-tests image) prints for Q.
#
# The card list, each card's UUID, PCI bus ID and driver, the PCIe topology, which pairs can read each other's memory
# directly, the full device query, and /dev/shm; it exits 3 unless it sees four distinct cards.
# It stays up sixty seconds after a pass, for the reason the ddp qualification does: the operator records Running
# only while it sees the Pod Ready, and T7 requires that stamp.
ar_qualification_body() {
  printf '%s\n' \
    "echo '== nvidia-smi -L'; nvidia-smi -L" \
    "nvidia-smi --query-gpu=index,uuid,pci.bus_id,driver_version --format=csv,noheader | sed 's/^/AR_GPU /'" \
    "echo '== nvidia-smi topo -m'; nvidia-smi topo -m" \
    "echo '== nvidia-smi topo -p2p r'; nvidia-smi topo -p2p r || echo \"AR_P2P_QUERY_FAILED \$?\"" \
    "echo '== nvidia-smi -q'; nvidia-smi -q" \
    "echo \"AR_SHM_KB \$(df -kP /dev/shm | awk 'NR == 2 {print \$2}')\"" \
    "n=\$(nvidia-smi -L | grep -o 'UUID: GPU-[0-9a-f-]*' | sort -u | wc -l)" \
    "[ \"\$n\" = 4 ] || { echo \"AR_QUALIFY_REFUSED \$n distinct GPU(s)\"; exit 3; }" \
    "sleep 60"
}

# ar_warm_body: T7b, in the torch image: torch must see four devices, and the image is pulled before any measured job.
ar_warm_body() {
  echo "exec python -c 'import sys, time, torch; n = torch.cuda.device_count(); v = \".\".join(map(str, torch.cuda.nccl.version())) if n else \"none\"; print(\"AR_WARM devices\", n, \"nccl\", v, flush=True); n == 4 and time.sleep(30); sys.exit(0 if n == 4 else 3)'"
}

# ar_render_job NAME ARM BODY: the MLTrainingJob, as JSON.
#
# One Pod of four renders without distributed, so the platform starts one container that may launch four processes;
# four Pods of one render with distributed.worldSize 4, one process each, as the API's contract requires.
ar_render_job() {
  local shape image
  shape="$(ar_shape "$2")" || { echo "unknown arm $2" >&2; return 1; }
  [[ -n "${AR_GPU_CLASS:-}" ]] || { echo "AR_GPU_CLASS is empty; the admission policy refuses a GPU job without a class" >&2; return 1; }
  image="$AR_TORCH_IMAGE"
  [[ "$2" == nccltests-* ]] && image="$AR_NCCLTESTS_IMAGE"
  python3 -c '
import json, sys
name, ns, queue, image, gpu_class, pods, gpus, body = sys.argv[1:9]
spec = {"queue": queue, "image": image, "gpuCount": int(gpus), "gpuClass": gpu_class, "command": ["sh", "-c", body]}
if int(pods) > 1:
    spec["distributed"] = {"worldSize": int(pods)}
print(json.dumps({"apiVersion": "platform.lkhun9311.github.io/v1", "kind": "MLTrainingJob",
                  "metadata": {"name": name, "namespace": ns}, "spec": spec}, indent=2))
' "$1" "$AR_NS" "$AR_QUEUE" "$image" "$AR_GPU_CLASS" ${shape} "$3"
}

# ar_collect_pods NAME DIR: every Pod of the job sampled once a second, and each Pod's log streamed from its start.
#
# Selected by the Job controller's own job-name label, which every Pod of a Job carries; the platform's mltrainingjob
# label is added only to distributed jobs, so selecting on it would miss a one-Pod job entirely (review, finding 1).
ar_collect_pods() {
  local name=$1 dir=$2 started=" "
  # shellcheck disable=SC2046  # word splitting of the pid list is intended
  trap 'kill $(jobs -p) 2>>"$AR_OUT/log.txt"; exit 0' TERM
  while :; do
    ar_k -n "$AR_NS" get pods -l "batch.kubernetes.io/job-name=$name" -o json >"$dir/.pods.json" 2>>"$AR_OUT/log.txt" || { sleep 1; continue; }
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
      # No request timeout here: it would end the stream after twenty seconds, mid-job.
      kubectl --context "$AR_CONTEXT" -n "$AR_NS" logs -f "${pair%%:*}" >"$dir/log-${pair##*:}.txt" 2>>"$AR_OUT/log.txt" &
    done
    sleep 1
  done
}

# ar_run_job NAME ARM DIR [BODY]: one fresh job, sampled until terminal or the budget is spent, and its final objects
# saved. BODY replaces the arm's own shell for the warm job, which has the arm's shape and not its work.
#
# Returns 1 only when the job could not be submitted, with the reason in DIR/VOID, which the scorer reports.
ar_run_job() {
  local -
  set +e
  local name="$1" arm="$2" dir="$3" body="${4:-}" t0 phase jobdone collector
  mkdir -p "$dir"
  echo "$name" >"$dir/name"
  echo "$arm" >"$dir/arm"
  [[ -n "$body" ]] || body="$(ar_arm_body "$name" "$arm")" || { echo "unknown arm $arm" >"$dir/VOID"; return 1; }
  ar_render_job "$name" "$arm" "$body" >"$dir/mltrainingjob.json" || { echo "could not render the job" >"$dir/VOID"; return 1; }
  log "== $arm as $name"
  ar_k apply -f "$dir/mltrainingjob.json" >>"$AR_OUT/log.txt" 2>&1 || { echo "create refused" >"$dir/VOID"; return 1; }
  t0=$(date +%s)
  ar_collect_pods "$name" "$dir" &
  collector=$!
  AR_COLLECTORS+=("$collector")
  phase=""
  while (($(date +%s) - t0 <= AR_BUDGET)); do
    phase=$(ar_k -n "$AR_NS" get mltrainingjob "$name" -o jsonpath='{.status.phase}' 2>>"$AR_OUT/log.txt")
    jobdone=$(ar_k -n "$AR_NS" get job "$name" -o jsonpath='{.status.conditions[?(@.status=="True")].type}' 2>>"$AR_OUT/log.txt")
    if [[ "$phase" =~ ^(Succeeded|Failed)$ ]] && [[ "$jobdone" =~ (Complete|Failed) ]]; then break; fi
    sleep 2
  done
  local elapsed=$(($(date +%s) - t0))
  echo "$elapsed" >"$dir/elapsed-seconds"
  log "$arm: phase '$phase' after $elapsed s"
  # Judged after the last answer arrived, not when the last poll began: a query can take twenty seconds, and a
  # terminal phase read after the budget is not one within it (codex review of the uncommitted diff).
  if [[ ! "$phase" =~ ^(Succeeded|Failed)$ ]] || ((elapsed > AR_BUDGET)); then
    echo "not terminal within the ${AR_BUDGET}s budget (phase '$phase' after ${elapsed}s)" >"$dir/TIMEOUT"
  fi
  # A few more seconds for the last log lines and the last Pod sample.
  sleep 5
  kill "$collector" 2>>"$AR_OUT/log.txt"
  wait "$collector" 2>>"$AR_OUT/log.txt"
  # Each Pod that still exists has its whole log read once more, without following, and that copy replaces the
  # stream's: a follow can end early and silently, as one did on kind when the host ran out of inotify instances
  # ("failed to create fsnotify watcher") and left a log holding only the ranks' start records. A Pod already gone
  # keeps the streamed copy, which is all there is of it.
  local uid pod
  while read -r uid pod; do
    if kubectl --context "$AR_CONTEXT" --request-timeout=60s -n "$AR_NS" logs "$pod" >"$dir/.log-$uid.final" 2>>"$AR_OUT/log.txt"; then
      mv "$dir/.log-$uid.final" "$dir/log-$uid.txt"
    else
      rm -f "$dir/.log-$uid.final"
      echo "the final read of $pod's log failed; the streamed copy is kept" >>"$dir/log-notes.txt"
    fi
  done < <(python3 -c 'import json,sys
seen = {}
for line in open(sys.argv[1]):
    s = json.loads(line)
    seen[s["uid"]] = s["name"]
for uid, name in seen.items():
    print(uid, name)' "$dir/pods.jsonl" 2>>"$AR_OUT/log.txt")
  ar_k -n "$AR_NS" get mltrainingjob "$name" -o json >"$dir/final-mltj.json" 2>>"$AR_OUT/log.txt"
  ar_k -n "$AR_NS" get job "$name" -o json >"$dir/final-job.json" 2>>"$AR_OUT/log.txt"
  ar_k -n "$AR_NS" get workloads -o json >"$dir/final-workloads.json" 2>>"$AR_OUT/log.txt"
  ar_k get nodes -o json >"$dir/nodes.json" 2>>"$AR_OUT/log.txt"
  # The job is deleted once its evidence is saved, so its Pods release their cards before the next job asks for them.
  ar_k -n "$AR_NS" delete mltrainingjob "$name" --wait=true --timeout=120s >>"$AR_OUT/log.txt" 2>&1 ||
    log "$arm: delete of $name did not finish within 120 s"
  return 0
}

# ar_run_all: the smoke jobs, one per arm in the registered order, then the registered jobs in their random order.
#
# The stop rule: if any smoke job is not valid under the scorer, nothing more runs, so a defect that would void every
# job costs five jobs and not thirty. Prints STOPPED and returns 1 when it stops.
ar_run_all() {
  local arm seq rep name dir why
  mkdir -p "$AR_OUT/jobs"
  ar_job_order >"$AR_OUT/order.txt" || { echo "could not compute the job order" >"$AR_OUT/STOPPED"; return 1; }
  for arm in $AR_ARMS; do
    name="c-smoke-${arm%%-*}-${arm##*-}-$(date -u +%H%M%S)"
    dir="$AR_OUT/jobs/00-smoke-$arm"
    ar_run_job "$name" "$arm" "$dir"
    if ! why="$(python3 "$AR_SCORER" --job "$dir" $AR_SCORER_ARGS 2>&1)"; then
      printf 'smoke job %s is not valid: %s\n' "$arm" "$(tr '\n' ' ' <<<"$why" | cut -c1-600)" >"$AR_OUT/STOPPED"
      log "STOPPED: $(cat "$AR_OUT/STOPPED")"
      return 1
    fi
  done
  while read -r seq arm rep; do
    name="c-$(printf '%02d' "$seq")-${arm%%-*}-${arm##*-}-$(date -u +%H%M%S)"
    dir="$AR_OUT/jobs/$(printf '%02d' "$seq")-$arm-$rep"
    ar_run_job "$name" "$arm" "$dir"
  done <"$AR_OUT/order.txt"
}
