# shellcheck shell=bash
# The distributed restart paid session (TRAIN=restart in hack/eks-gitops-session.sh): its refusals, the objects it
# renders, and the procedure of each registered case, as functions, so each can be tested with aws and kubectl replaced
# by stubs (hack/test/check-restart-session.sh).
#
# The registration is docs/superpowers/specs/2026-11-01-distributed-restart-design.md, "The paid session: apparatus";
# every constant below that is not derived there is one it names.
# experiments/distributed-restart/score_eks.py reads what this writes, and is run after every case, not only at the end,
# because a bad reference or two VOID cases in a row must stop the spending (the registration's abort conditions).
#
# Like hack/lib/train-session.sh, a refusal prints why and returns non-zero, and a query that fails is a refusal, never an
# empty answer. It never calls `set`, never `cd`s and installs no traps: those belong to the caller.
#
# WHAT THE CALLER PROVIDES for the case procedure: RESTART_CONTEXT, RESTART_REGION, RESTART_CLUSTER, RESTART_GROUP,
# RESTART_NS, RESTART_QUEUE, RESTART_OUT (the run directory), RESTART_SYS (the operator's and exporter's namespace),
# and hack/lib/train-session.sh, hack/lib/gpu-ttl.sh and hack/lib/gpu-fault.sh sourced.

# The image every EKS training session pins: torch 2.5.1+cu124, CUDA 12.4, NCCL 2.21.5.
RESTART_IMAGE=docker.io/pytorch/pytorch@sha256:c8268a92a69bd500f8be0e665b2630ee006dadaf7bfbc24249141b15ff622755
RESTART_TRAIN_PY=experiments/distributed-restart/train.py
RESTART_AZ=ap-northeast-2a
RESTART_STEPS=30
RESTART_STEP_SLEEP=2
RESTART_BALLAST_MB=16
# The controller restarts when the Job fails, and a surviving rank blocked in a collective keeps it running until this.
RESTART_COLLECTIVE_TIMEOUT=60
# One case from submission to its verdict; a case that has not succeeded by then is FAILED, censored at this budget.
RESTART_CASE_BUDGET=720
# The other shares of one case's slot, each a limit the runner enforces, so restart_gpu_budget is the sum of what can
# really run and not of what usually does.
# Before submission: reading the deadline, rendering, the credit read (20 s), the node read (20 s) and the create (20 s).
RESTART_SUBMIT_BUDGET=120
# After the run: the clock probes (an exporter list of 20 s and 10 s per node), two reads of 20 s, the credit read of
# 20 s, the 5 s pause and the collector's stop.
RESTART_EVIDENCE_BUDGET=120
# The case's job deleted and its Jobs, Pods and Workloads seen gone.
RESTART_RETIRE_BUDGET=300
# Copying the NCCL logs, listing and deleting the case's files, and scoring it: four calls of at most 30 s.
RESTART_FILES_BUDGET=120
# A dcgm case's baseline injection and the 120 s wait for the node to read clear, with 60 s for the calls around it.
RESTART_RESET_BUDGET=180
# The group seen at its count and qualified again when no node was lost.
RESTART_REQUALIFY_BUDGET=300
# A lost node's replacement launched, joined and qualified, or the group scaled in to two.
RESTART_REPLENISH_BUDGET=900
# Warming every unprepared node, in parallel under one deadline, because each pulls its own 3.3 GB copy of the image.
RESTART_WARM_BUDGET=900
# Every GPU node's exporter serving the fault fields and its NodeHealth reading a fresh, healthy signal.
RESTART_SIGNAL_BUDGET=180
# The longest a credential can be asked to cover: the SSO permission set's SessionDuration is PT12H (720 min, read in
# gpu-lab), and 20 min of it are left for the time between the login and this check.
RESTART_CREDENTIAL_MAX_MIN=700
# An external fault waits for a published checkpoint of at least this step, and is refused once this step has run.
RESTART_FAULT_MIN_STEP=10
RESTART_FAULT_MAX_STEP=25
RESTART_CLAIM=restart-shared
RESTART_MOUNT=/state
# The full stage's repetitions per kind, fixed here and not chosen at run time.
# The registration asked for 5, and 5 cannot run in one session: restart_gpu_budget is 6,840 + 9,900 x REPS seconds
# for the full stage, the session adds 1,200 s of syncs and a 3,600 s margin, and TTL_MINUTES plus the 40-minute
# destroy must stay within RESTART_CREDENTIAL_MAX_MIN, so 11,640 + 9,900 x REPS <= 660 x 60 = 39,600.
# REPS = 2 needs TTL_MINUTES 524 (564 with the destroy); REPS = 3 needs 689 (729), which no 720-minute credential covers.
RESTART_REPS=2
RESTART_POLL="${RESTART_POLL:-1}"
RESTART_FENCED_ANN=platform.lkhun9311.github.io/fenced-nodes
RESTART_FAULT_FLAGS=(--gpu-fault-source=dcgm --gpu-fault-evict-workloads)
# The commit whose fix the restart controller needs; a deployed revision without it is not the controller this tests.
RESTART_CONTROLLER_COMMIT=65874ddb

# restart_cases: the cases of RESTART_STAGE, in the registered order, one per line; fails for any other stage.
#
# smoke is the first paid stage, run and inspected before anything else is bought: the two cases every other one is
# compared with, and one of each external fault, the DCGM path and a termination that can only recover on a replacement.
# full is the registered kinds at RESTART_REPS each.
restart_cases() {
  local kind i
  case "${RESTART_STAGE:-}" in
    smoke) printf '%s\n' reference no-rng-control dcgm-1 terminate-wait-1 ;;
    full)
      echo reference
      echo no-rng-control
      for kind in rank-kill dcgm terminate-spare terminate-wait; do
        for ((i = 1; i <= RESTART_REPS; i++)); do echo "$kind-$i"; done
      done
      ;;
    *)
      echo "RESTART_STAGE is '${RESTART_STAGE:-}', not smoke or full" >&2
      return 1
      ;;
  esac
}

# restart_pre_seconds CASE PREVIOUS: the share of CASE's slot before its submission, which depends on what the
# previous case left: a lost node to replace and warm, a group to scale in to two, or only a group to qualify again.
restart_pre_seconds() {
  local kind="${1%-[0-9]*}" prev="${2%-[0-9]*}"
  if [[ "$prev" == terminate-* ]]; then
    echo $((RESTART_REPLENISH_BUDGET + RESTART_WARM_BUDGET))
  elif [[ "$kind" == terminate-wait ]]; then
    echo "$RESTART_REPLENISH_BUDGET"
  else
    echo "$RESTART_REQUALIFY_BUDGET"
  fi
}

# restart_slot_seconds CASE PREVIOUS: CASE's whole slot, from the group check before it to its verdict, every share an
# enforced limit; restart_run gives the slot one absolute deadline.
restart_slot_seconds() {
  local reset=0
  [[ "${1%-[0-9]*}" != dcgm ]] || reset="$RESTART_RESET_BUDGET"
  echo $(($(restart_pre_seconds "$1" "$2") + RESTART_SUBMIT_BUDGET + RESTART_CASE_BUDGET + RESTART_EVIDENCE_BUDGET +
    RESTART_RETIRE_BUDGET + RESTART_FILES_BUDGET + reset))
}

# restart_prep_seconds: from the purchase to the first case, each wait the session's own bound.
#
# T6 waits WAIT_GPU_NODE + WAIT_GPU_PLUGIN under one deadline, T7 waits WAIT_QUAL_RUN, the three nodes are warmed in
# parallel under RESTART_WARM_BUDGET, and the fault path's readiness is given RESTART_SIGNAL_BUDGET.
restart_prep_seconds() {
  echo $((WAIT_GPU_NODE + WAIT_GPU_PLUGIN + WAIT_QUAL_RUN + RESTART_WARM_BUDGET + RESTART_SIGNAL_BUDGET))
}

# restart_gpu_budget: the seconds from the GPU purchase to its verified end, the sum of the enforced limits of the
# preparation, every case's slot and the scale-down.
#
# WAIT_GPU_NODE, WAIT_GPU_PLUGIN, WAIT_QUAL_RUN and WAIT_GPU_GONE are the session's, read from its environment.
restart_gpu_budget() {
  local cases case prev="" total
  cases="$(restart_cases)" || return 1
  total="$(restart_prep_seconds)"
  for case in $cases; do
    total=$((total + $(restart_slot_seconds "$case" "$prev")))
    prev="$case"
  done
  # The scale-down's wait for every instance to end, and 300 s for the calls around it.
  echo $((total + WAIT_GPU_GONE + 300))
}

# restart_ttl_refusal STAGE TTL_MINUTES GPU_BUDGET SESSION_SECONDS: TTL_MINUTES covers the session's waits, and it and
# the destroy after it fit in a credential the account can issue.
#
# The scale-down and the fencing are AWS calls, so a session that outlives every credential the account can issue
# would end with nothing able to stop its nodes but the deadlines; such a stage is refused whatever the credential now.
restart_ttl_refusal() {
  local stage="$1" ttl="$2" need
  need=$((($3 + $4 + 3600 + 59) / 60))
  if ((need + 40 > RESTART_CREDENTIAL_MAX_MIN)); then
    echo "RESTART_STAGE=$stage needs TTL_MINUTES of at least $need, and with the 40-minute destroy $((need + 40)) min of credential, more than the $RESTART_CREDENTIAL_MAX_MIN a fresh 720-minute credential covers; it cannot run as one session"
    return 1
  fi
  if ((ttl < need)); then
    echo "TRAIN=restart with RESTART_STAGE=$stage needs TTL_MINUTES of at least $need for its waits; it is $ttl"
    return 1
  fi
  if ((ttl + 40 > RESTART_CREDENTIAL_MAX_MIN)); then
    echo "TTL_MINUTES=$ttl and the 40-minute destroy need $((ttl + 40)) min of credential, more than the $RESTART_CREDENTIAL_MAX_MIN a fresh 720-minute credential covers; RESTART_STAGE=$stage needs only $need"
    return 1
  fi
  echo "RESTART_STAGE=$stage: TTL_MINUTES $ttl covers its $need, and with the destroy fits the $RESTART_CREDENTIAL_MAX_MIN-minute credential limit"
}

# restart_zone_refusal ZONE: the registered zone and no other, because every figure inherits it.
restart_zone_refusal() {
  if [[ "$1" != "$RESTART_AZ" ]]; then
    echo "TRAIN=restart is registered in $RESTART_AZ, and TRAIN_AZ is '${1}'; a capacity failure there voids the session rather than moving it"
    return 1
  fi
  echo "pinned to $RESTART_AZ"
}

# restart_clean_tree_refusal: the tree is a commit and nothing else, because the run's provenance is that commit.
restart_clean_tree_refusal() {
  local dirty
  dirty="$(git status --porcelain 2>&1)" || {
    echo "could not read the tree's status: ${dirty:0:200}"
    return 1
  }
  if [[ -n "$dirty" ]]; then
    echo "the working tree has $(wc -l <<<"$dirty") uncommitted change(s), and the run's provenance is a commit: $(head -3 <<<"$dirty" | paste -sd' ')"
    return 1
  fi
  echo "the working tree is clean at $(git rev-parse --short HEAD)"
}

# restart_credential_refusal MINUTES: the active credential outlives the session by its own expiry.
#
# The scale-down at the end and the fencing in the middle are AWS calls, so a credential that dies first leaves nodes
# billing with nothing able to stop them but the deadlines.
restart_credential_refusal() {
  local need="$1" raw exp left
  raw="$(aws configure export-credentials --format process 2>&1)" || {
    echo "the CLI could not export the active credential: ${raw:0:200}"
    return 1
  }
  exp="$(python3 -c 'import json, sys; print(json.loads(sys.argv[1]).get("Expiration", ""))' "$raw" 2>&1)" || {
    echo "the exported credential is not JSON"
    return 1
  }
  # A credential with no expiry cannot be shown to outlast anything.
  if [[ -z "$exp" ]]; then
    echo "the exported credential carries no expiry, so it cannot be shown to outlast the session"
    return 1
  fi
  left="$(python3 -c '
import datetime, sys
e = datetime.datetime.fromisoformat(sys.argv[1].replace("Z", "+00:00"))
print(int((e - datetime.datetime.now(datetime.timezone.utc)).total_seconds() // 60))' "$exp" 2>&1)" || {
    echo "the credential's expiry '$exp' is not a time"
    return 1
  }
  if ((left < need)); then
    echo "the credential expires in $left minutes and the session needs $need; authenticate again first"
    return 1
  fi
  echo "the credential expires in $left minutes, at least the $need the session needs"
}

# restart_render_volume FS_ID NS: the static PersistentVolume naming the file system and the claim bound to it.
#
# Static, so the volume is the file system's root and no access point, and no controller permission, sits between the
# ranks and the bytes; claimRef and volumeName pin the pair to each other, so no other claim can take the volume.
restart_render_volume() {
  local fs="$1" ns="$2"
  if [[ ! "$fs" =~ ^fs-[0-9a-f]{8,17}$ ]]; then
    echo "the EFS file system ID '$fs' is not one; terraform output efs_file_system_id is empty when efs_enabled is off" >&2
    return 1
  fi
  cat <<EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: $RESTART_CLAIM-$ns
spec:
  capacity:
    storage: 100Gi
  accessModes: ["ReadWriteMany"]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  csi:
    driver: efs.csi.aws.com
    volumeHandle: $fs
  claimRef:
    namespace: $ns
    name: $RESTART_CLAIM
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $RESTART_CLAIM
  namespace: $ns
spec:
  accessModes: ["ReadWriteMany"]
  storageClassName: ""
  volumeName: $RESTART_CLAIM-$ns
  resources:
    requests:
      storage: 100Gi
EOF
}

# restart_case_env CASE: the case's own trainer settings, one export line; fails for a case that is not registered.
restart_case_env() {
  case "${1%-[0-9]*}" in
    reference | dcgm | terminate-spare | terminate-wait) echo "" ;;
    # Rank 0 dies right after LATEST names step 12, and attempt 2 resumes from it without the RNG.
    no-rng-control) echo "export CKPT_FAULT=kill-after-latest:12 CKPT_LOAD=no-rng" ;;
    # Rank 1 is SIGKILLed with its shard of step 12 written and not synced, so attempt 2 resumes from step 11.
    rank-kill) echo "export CKPT_FAULT=kill-before-fsync:12:1" ;;
    *) return 1 ;;
  esac
}

# restart_render_job NAME NS QUEUE JOB_ID CASE: the case's MLTrainingJob as JSON.
#
# train.py travels in the command, checked by its sha256 inside the container, so the image is the pinned one and
# nothing is pushed.
# python is not exec'd: as the container's PID 1 the trainer refuses to fire a kill fault, and the kernel would drop
# the SIGKILL it sends itself anyway.
# NCCL writes to a file on the volume, so its lines cannot split the trainer's JSON records on stdout; the file is named
# by attempt and rank, because an Indexed Job's hostnames repeat across attempts and NCCL truncates a file it opens.
# NCCL does not create the directory and falls back to stdout without one, so the shell creates and checks it first.
restart_render_job() {
  local name="$1" ns="$2" queue="$3" job_id="$4" case="$5" extra sha body
  extra="$(restart_case_env "$case")" || {
    echo "$case is not a registered case" >&2
    return 1
  }
  [[ "$job_id" =~ ^[a-z0-9-]+$ ]] || {
    echo "job ID '$job_id' is not a plain name" >&2
    return 1
  }
  sha="$(sha256sum "$RESTART_TRAIN_PY" | cut -d' ' -f1)" || return 1
  body="$(printf '%s\n' \
    "echo $(base64 -w0 "$RESTART_TRAIN_PY") | base64 -d >/tmp/train.py" \
    "echo \"$sha  /tmp/train.py\" | sha256sum -c - >/dev/null || exit 86" \
    "nccl_dir=$RESTART_MOUNT/$job_id/nccl" \
    "mkdir -p \"\$nccl_dir\" && touch \"\$nccl_dir/.a\${TRAINING_ATTEMPT}-r\${RANK}\" || exit 87" \
    "export CKPT_BACKEND=nccl CKPT_RUN_ID=$name CKPT_DIR=$RESTART_MOUNT CKPT_JOB_ID=$job_id CKPT_STEPS=$RESTART_STEPS CKPT_STEP_SLEEP=$RESTART_STEP_SLEEP" \
    "export CKPT_BALLAST_MB=$RESTART_BALLAST_MB CKPT_COLLECTIVE_TIMEOUT=$RESTART_COLLECTIVE_TIMEOUT OMP_NUM_THREADS=1" \
    "export NCCL_DEBUG=INFO NCCL_DEBUG_SUBSYS=INIT,NET NCCL_DEBUG_FILE=\"\$nccl_dir/a\${TRAINING_ATTEMPT}-r\${RANK}-%h.%p.log\"" \
    "$extra" \
    "python /tmp/train.py")"
  python3 -c '
import json, sys
name, ns, queue, image, claim, mount, body = sys.argv[1:8]
print(json.dumps({
    "apiVersion": "platform.lkhun9311.github.io/v1", "kind": "MLTrainingJob",
    "metadata": {"name": name, "namespace": ns},
    "spec": {"queue": queue, "image": image, "gpuCount": 1, "gpuClass": "a10g",
             "distributed": {"worldSize": 2, "maxRestarts": 1},
             "stateVolume": {"claimName": claim, "mountPath": mount},
             "command": ["sh", "-c", body]},
}, indent=2))
' "$name" "$ns" "$queue" "$RESTART_IMAGE" "$RESTART_CLAIM" "$RESTART_MOUNT" "$body"
}

rk() { kubectl --context "$RESTART_CONTEXT" --request-timeout=20s "$@"; }

# rkd DEADLINE ARGS...: rk whose request cannot outlive DEADLINE (in SECONDS) by more than a second, so a poll that
# starts just before its phase's deadline does not carry the phase into the next one's share.
rkd() {
  local t=$(($1 - SECONDS))
  shift
  ((t <= 20)) || t=20
  ((t >= 1)) || t=1
  kubectl --context "$RESTART_CONTEXT" --request-timeout="${t}s" "$@"
}

# rkt SECONDS ARGS...: rk ended after SECONDS whatever it is doing, for an exec or a stream a request timeout does not
# bound.
rkt() {
  local t="$1"
  shift
  timeout "$t" kubectl --context "$RESTART_CONTEXT" --request-timeout=20s "$@"
}

# restart_operator_gate: the operator running on the cluster is the restart controller, before any GPU is bought.
#
# Argo deploys the operator from main, whatever this checkout holds, so the deployed revision is read from Argo, its
# image digest from that revision's own config/manager/kustomization.yaml, and every Ready operator Pod must run it.
# The webhook is shown to be invoked, not only installed: a job naming a claim that does not exist must be refused.
restart_operator_gate() {
  local rev crd expected pods bad out
  rev="$(rk -n argocd get application gpu-platform-operator -o jsonpath='{.status.sync.revision}' 2>&1)" || {
    echo "could not read the operator Application's deployed revision: ${rev:0:200}"
    return 1
  }
  [[ "$rev" =~ ^[0-9a-f]{40}$ ]] || {
    echo "the operator Application's deployed revision is '${rev:0:80}', not a commit"
    return 1
  }
  out="$(git fetch -q origin "$rev" 2>&1)" || {
    echo "could not fetch the deployed revision $rev: ${out:0:200}"
    return 1
  }
  if ! git merge-base --is-ancestor "$RESTART_CONTROLLER_COMMIT" "$rev" 2>&1; then
    echo "the deployed revision $rev does not contain the restart controller ($RESTART_CONTROLLER_COMMIT); promote it to main first"
    return 1
  fi
  expected="$(git show "$rev:config/manager/kustomization.yaml" 2>&1 | sed -n 's/^- digest: \(sha256:[0-9a-f]\{64\}\)$/\1/p' | head -1)"
  [[ -n "$expected" ]] || {
    echo "no operator digest in config/manager/kustomization.yaml at $rev"
    return 1
  }
  pods="$(rk -n "$RESTART_SYS" get pods -l control-plane=controller-manager -o json 2>&1)" || {
    echo "could not read the operator Pods: ${pods:0:200}"
    return 1
  }
  bad="$(python3 -c '
import json, sys
want, pods = sys.argv[1], json.loads(sys.argv[2]).get("items", [])
ready = [p for p in pods if any(c.get("type") == "Ready" and c.get("status") == "True" for c in p.get("status", {}).get("conditions", []))]
if not ready:
    print("no Ready operator Pod")
for p in ready:
    for c in p["status"].get("containerStatuses", []):
        if c["name"] == "manager" and not c.get("imageID", "").endswith(want):
            print(p["metadata"]["name"] + " runs " + c.get("imageID", "?"))' "$expected" "$pods" 2>&1)"
  if [[ -n "$bad" ]]; then
    echo "the operator is not the deployed revision's image $expected: $bad"
    return 1
  fi
  crd="$(rk get crd mltrainingjobs.platform.lkhun9311.github.io -o json 2>&1)" || {
    echo "could not read the MLTrainingJob CRD: ${crd:0:200}"
    return 1
  }
  python3 -c '
import json, sys
v = [v for v in json.loads(sys.argv[1])["spec"]["versions"] if v.get("storage")][0]
d = v["schema"]["openAPIV3Schema"]["properties"]["spec"]["properties"]["distributed"]["properties"]
sys.exit(0 if "maxRestarts" in d else 1)' "$crd" 2>&1 || {
    echo "the deployed MLTrainingJob CRD has no spec.distributed.maxRestarts"
    return 1
  }
  out="$(restart_render_job restart-gate-missing "$RESTART_NS" "$RESTART_QUEUE" restart-gate reference |
    python3 -c 'import json, sys; j = json.load(sys.stdin); j["spec"]["stateVolume"]["claimName"] = "no-such-claim"; print(json.dumps(j))' |
    rk apply --dry-run=server -f - 2>&1)" && {
    echo "a job naming a claim that does not exist was accepted, so the webhook that checks the claim did not run"
    return 1
  }
  out="$(restart_render_job restart-gate "$RESTART_NS" "$RESTART_QUEUE" restart-gate reference | rk apply --dry-run=server -f - 2>&1)" || {
    echo "a registered case's job was refused by the API server: ${out:0:300}"
    return 1
  }
  echo "operator at $rev runs $expected, the CRD has maxRestarts, and the webhook refuses a missing claim and accepts a case"
}

# restart_clock_probe POD NODE: one JSON line of the node's clock against this machine's.
#
# The node's time is read inside a Pod on it, between two readings of this machine's clock, so the offset is known to
# within the bracket; the scorer refuses a wide bracket or a large offset rather than subtract a clock it cannot trust.
restart_clock_probe() {
  local pod="$1" node="$2" before after t
  before="$(date +%s.%N)"
  t="$(timeout 10 kubectl --context "$RESTART_CONTEXT" --request-timeout=10s -n "$RESTART_SYS" exec "$pod" -c exporter -- date +%s.%N 2>&1)" || {
    echo "could not read the clock of $node through $pod: ${t:0:200}" >&2
    return 1
  }
  after="$(date +%s.%N)"
  [[ "$t" =~ ^[0-9]+\.[0-9]+$ ]] || {
    echo "the clock of $node read as '${t:0:80}', not seconds" >&2
    return 1
  }
  printf '{"node": "%s", "pod": "%s", "before": %s, "node_time": %s, "after": %s}\n' "$node" "$pod" "$before" "$t" "$after"
}

# restart_exporters: "node pod" for every Running exporter Pod, the clock and fault path's way onto each GPU node.
restart_exporters() {
  rk -n "$RESTART_SYS" get pods -l app.kubernetes.io/component=dcgm-exporter --field-selector status.phase=Running \
    -o jsonpath='{range .items[*]}{.spec.nodeName}{" "}{.metadata.name}{"\n"}{end}'
}

# restart_probe_all DIR LABEL: a probe of every GPU node's clock, appended to DIR/clock.jsonl; fails if any cannot be read.
restart_probe_all() {
  local dir="$1" label="$2" rows node pod line fails=0 probed=0
  rows="$(restart_exporters 2>&1)" || {
    echo "could not list the exporters: ${rows:0:200}" >&2
    return 1
  }
  while read -r node pod; do
    [[ -n "$node" ]] || continue
    probed=$((probed + 1))
    if line="$(restart_clock_probe "$pod" "$node")"; then
      python3 -c 'import json, sys; r = json.loads(sys.argv[1]); r["when"] = sys.argv[2]; print(json.dumps(r))' "$line" "$label" >>"$dir/clock.jsonl"
    else
      fails=$((fails + 1))
    fi
  done <<<"$rows"
  # No exporter listed is no clock read, not every clock read.
  if ((probed == 0)); then
    echo "no exporter Pod was Running, so no node's clock was read" >&2
    return 1
  fi
  ((fails == 0))
}

# restart_records DIR: every trainer record in DIR's rank logs as one JSON line each, wherever in a line it starts.
restart_records() {
  local logs=("$1"/log-*.txt)
  [[ -e "${logs[0]}" ]] || return 0
  cat "${logs[@]}" | python3 -c '
import json, re, sys
text, dec = sys.stdin.read(), json.JSONDecoder()
for m in re.finditer(r"\{\"ts\": ", text):
    try:
        r, _ = dec.raw_decode(text, m.start())
    except ValueError:
        continue
    print(json.dumps(r))'
}

# restart_read_latest POD JOB_ID: the step LATEST names on the volume, read through a rank's own mount.
restart_read_latest() {
  local latest
  latest="$(rk -n "$RESTART_NS" exec "$1" -- cat "$RESTART_MOUNT/$2/LATEST" 2>&1)" || {
    echo "could not read LATEST through $1: ${latest:0:200}" >&2
    return 1
  }
  if [[ ! "$latest" =~ ^a[0-9]+/([0-9]{8})-[0-9a-f]{32}$ ]]; then
    echo "LATEST reads '${latest:0:80}', not a checkpoint" >&2
    return 1
  fi
  echo "$((10#${BASH_REMATCH[1]})) $latest"
}

# restart_fault_window POD JOB_ID DIR WAIT: 0 once LATEST names a step of at least RESTART_FAULT_MIN_STEP and no rank has
# recorded RESTART_FAULT_MAX_STEP; 1 if a rank got there first, so the fault would land too late; 2 when the wait ran out.
#
# The maximum is checked after the minimum, so a slow log stream cannot hide a late window; the window can still close
# while the caller resolves its targets, so restart_external_fault reads it again with restart_fault_recheck last.
restart_fault_window() {
  local pod="$1" job_id="$2" dir="$3" wait="$4" deadline=$((SECONDS + $4)) latest="" high
  while ((SECONDS < deadline)); do
    if latest="$(restart_read_latest "$pod" "$job_id")" && ((${latest%% *} >= RESTART_FAULT_MIN_STEP)); then
      high="$(restart_records "$dir" | python3 -c '
import json, sys
print(max([json.loads(l)["step"] for l in sys.stdin if json.loads(l).get("event") == "step"], default=0))')"
      if ((high >= RESTART_FAULT_MAX_STEP)); then
        echo "a rank recorded step $high, at or past $RESTART_FAULT_MAX_STEP, before the fault"
        return 1
      fi
      # The volume is ahead of a lagging log stream, so the published step is held to the maximum too (codex review
      # of 830f64af).
      if ((${latest%% *} >= RESTART_FAULT_MAX_STEP)); then
        echo "LATEST names step ${latest%% *}, at or past $RESTART_FAULT_MAX_STEP, before the fault"
        return 1
      fi
      echo "$latest"
      return 0
    fi
    sleep "$RESTART_POLL"
  done
  echo "LATEST named no step of $RESTART_FAULT_MIN_STEP or later within ${wait}s (last: ${latest:-unread})"
  return 2
}

# restart_fault_recheck POD JOB_ID DIR NAME: the last read before an external fault: the job not ended, no rank's
# record and not LATEST at or past RESTART_FAULT_MAX_STEP; prints LATEST's "STEP NAME", or why the fault is refused.
#
# LATEST is read last, because the volume is ahead of the logs and the step it names is the one the fault lands after.
restart_fault_recheck() {
  local pod="$1" job_id="$2" dir="$3" name="$4" phase high latest
  phase="$(rk -n "$RESTART_NS" get mltrainingjob "$name" -o jsonpath='{.status.phase}' 2>&1)" || {
    echo "could not read the job's phase: ${phase:0:200}"
    return 1
  }
  case "$phase" in
    Succeeded | Failed)
      echo "the job had already ended $phase"
      return 1
      ;;
  esac
  high="$(restart_records "$dir" | python3 -c '
import json, sys
print(max([json.loads(l)["step"] for l in sys.stdin if json.loads(l).get("event") == "step"], default=0))')"
  if ((high >= RESTART_FAULT_MAX_STEP)); then
    echo "a rank recorded step $high, at or past $RESTART_FAULT_MAX_STEP"
    return 1
  fi
  latest="$(restart_read_latest "$pod" "$job_id" 2>&1)" || {
    echo "${latest:0:200}"
    return 1
  }
  if ((${latest%% *} >= RESTART_FAULT_MAX_STEP)); then
    echo "LATEST names step ${latest%% *}, at or past $RESTART_FAULT_MAX_STEP"
    return 1
  fi
  echo "$latest"
}

# restart_external_fault KIND DIR NAME JOB_ID POD0 NODE1 WINDOW RUN_DEADLINE SLOT_DEADLINE: the dcgm or termination
# fault on rank 1's node, delivered only if the last read before it still finds the window open.
#
# Every target is resolved first, the instance, the exporter Pod and the GPU deadline, so the read that decides the
# fault is the last call before it; once the window had been seen open, a node read, an exporter lookup and two
# scheduler calls had run before the injection, and the trainer steps every two seconds.
# The step that last read saw is written to case.json after the fault, so the write is not between the read and it.
restart_external_fault() {
  local kind="$1" dir="$2" name="$3" job_id="$4" pod0="$5" node1="$6" window="$7" run_dl="$8" slot_dl="$9" instance last out rc=0
  rk get nodes -o json >"$dir/nodes-before.json" 2>>"$dir/case.log"
  instance="$(python3 -c '
import json, sys
n = [n for n in json.load(open(sys.argv[1]))["items"] if n["metadata"]["name"] == sys.argv[2]]
print(n[0]["spec"]["providerID"].rsplit("/", 1)[-1] if n else "")' "$dir/nodes-before.json" "$node1" 2>>"$dir/case.log")"
  if [[ "$kind" == dcgm ]]; then
    restart_gf_env "$node1" "$dir" || return 1
  else
    # The replacement the termination starts is joined and warmed in the next slot's share, so the deadline must
    # cover this slot's rest and that share.
    out="$(restart_deadline_ok $((slot_dl - SECONDS + RESTART_REPLENISH_BUDGET + RESTART_WARM_BUDGET)))" || {
      echo "$out"
      return 1
    }
  fi
  if last="$(restart_fault_recheck "$pod0" "$job_id" "$dir" "$name")"; then
    if [[ "$kind" == dcgm ]]; then
      restart_dcgm_fault "$node1" "$dir"
    else
      restart_terminate_and_fence "$instance" "$node1" "$name" "$dir" $((run_dl - SECONDS))
    fi
    rc=$?
  else
    restart_mark "$dir" "fault-refused"
    echo "refused at the last read before the fault: $last"
    rc=1
  fi
  python3 -c '
import json, re, sys
c = json.load(open(sys.argv[1]))
c["target"] = {"rank": 1, "node": sys.argv[2], "instance": sys.argv[3]}
c["published_at_window"] = sys.argv[4]
c["last_read_before_fault"] = sys.argv[5]
m = re.match(r"(\d+) a\d+/", sys.argv[5]) or re.match(r"LATEST names step (\d+)", sys.argv[5])
c["step_before_fault"] = int(m.group(1)) if m else None
if sys.argv[6] == "0":
    c["published_at_fault"] = sys.argv[5]
json.dump(c, open(sys.argv[1], "w"))' "$dir/case.json" "$node1" "$instance" "$window" "$last" "$rc" 2>>"$dir/case.log"
  return "$rc"
}

# restart_mark DIR MARK: a line of marks.jsonl, at this machine's clock.
restart_mark() {
  printf '{"at": "%s", "mark": "%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%S.%6NZ)" "$2" >>"$1/marks.jsonl"
}

# restart_terminate_and_fence INSTANCE NODE MLTJ DIR WAIT_SECONDS: ends the instance and, only once EC2 says it is
# terminated, acknowledges the fencing of its node on the job.
#
# The acknowledgement is what lets the controller start the next attempt on a volume the old rank could still write to,
# so it is written only on EC2's own word that the machine is off: shutting-down is not off, and an answer that cannot
# be read says nothing.
# The fault's time is the mark before the call, so the recovery the scorer computes includes the call's own latency.
restart_terminate_and_fence() {
  local instance="$1" node="$2" mltj="$3" dir="$4" wait="$5" deadline out state
  deadline=$((SECONDS + wait))
  [[ "$instance" =~ ^i-[0-9a-f]+$ ]] || {
    echo "'$instance' is not an instance ID"
    return 1
  }
  restart_mark "$dir" "fault-start"
  out="$(timeout 60 aws ec2 terminate-instances --region "$RESTART_REGION" --instance-ids "$instance" --output text 2>&1)" || {
    restart_mark "$dir" "fault-refused"
    echo "terminate-instances on $instance failed: ${out:0:200}"
    return 1
  }
  restart_mark "$dir" "fault-end"
  while :; do
    state="$(timeout 30 aws ec2 describe-instances --region "$RESTART_REGION" --instance-ids "$instance" \
      --query 'Reservations[].Instances[].State.Name' --output text 2>&1)" || state="unreadable: ${state:0:120}"
    if [[ "$state" == terminated ]]; then
      restart_mark "$dir" "terminated-read"
      break
    fi
    if ((SECONDS >= deadline)); then
      echo "$instance was not reported terminated within ${wait}s (last: $state); its node is not fenced"
      return 1
    fi
    sleep "$RESTART_POLL"
  done
  # Marked before the call too, because the controller can see the annotation and start attempt 2 before the call
  # returns, so the barrier is judged against this mark and not against "fenced".
  restart_mark "$dir" "fence-request"
  out="$(rk -n "$RESTART_NS" annotate mltrainingjob "$mltj" "$RESTART_FENCED_ANN=$node" --overwrite 2>&1)" || {
    echo "$instance is terminated, and the fencing of $node could not be written: ${out:0:200}"
    return 1
  }
  restart_mark "$dir" "fenced"
  # Sampled at once, because the case loop does not sample while the fencing is waited for.
  restart_sample "$mltj" "$dir"
  echo "$instance terminated and $node fenced"
}

# restart_dcgm_fault NODE DIR: XID 79 into the host engine on NODE, with the node's own time in the same exec, then the
# readback, the latch and the taint, all written to DIR/dcgm.json before anything resets them.
#
# The exporter Pod is resolved by the caller, with restart_gf_env, before its last read of the published step, so no
# lookup sits between that read and the injection.
restart_dcgm_fault() {
  local node="$1" dir="$2" out t rb latched=false tainted=false
  [[ "${GF_TARGET:-}" == "$node" && -n "${GF_POD:-}" ]] || {
    echo "the fault path is not pointed at $node; restart_gf_env comes first"
    return 1
  }
  restart_mark "$dir" "fault-start"
  out="$(rk -n "$RESTART_SYS" exec "$GF_POD" -c hostengine -- sh -c \
    "date +%s.%N; dcgmi test --inject --gpuid 0 -f 230 -v 79 --offset $GF_OFFSET_S" 2>&1)" || {
    restart_mark "$dir" "fault-refused"
    echo "the injection on $node failed: ${out:0:300}"
    return 1
  }
  restart_mark "$dir" "fault-end"
  t="$(head -1 <<<"$out")"
  rb="$(gf_readback 230 2>&1)" || rb="unread: ${rb:0:80}"
  if gf_wait_until 60 gf_nh_latched; then latched=true; fi
  if gf_tainted "$node"; then tainted=true; fi
  python3 -c '
import datetime, json, sys
node, t, rb, latched, tainted = sys.argv[1:6]
at = datetime.datetime.fromtimestamp(float(t), datetime.timezone.utc).isoformat()
print(json.dumps({"node": node, "injected_at": at, "readback": rb, "latched": latched == "true", "tainted": tainted == "true"}))
' "$node" "$t" "$rb" "$latched" "$tainted" >"$dir/dcgm.json" || {
    echo "the injection's node time '${t:0:60}' is not seconds"
    return 1
  }
  echo "XID 79 on $node, read back as $rb, latched $latched, tainted $tainted"
}

# gf_nh_latched: the target's NodeHealth carries a fault fingerprint, which is the latch the fault path keeps.
gf_nh_latched() { [[ -n "$(gf_nh_field "$GF_TARGET" ann:fingerprint)" ]]; }

# restart_gf_env NODE DIR: hack/lib/gpu-fault.sh pointed at NODE on this cluster, so its helpers act on the session's
# context and never on whatever kubectl's current context happens to be.
restart_gf_env() {
  GF_CONTEXT="$RESTART_CONTEXT" GF_SYS="$RESTART_SYS" GF_MODE=dcgm GF_OUT="$2" GF_TARGET="$1"
  GF_EXPORTER=app.kubernetes.io/component=dcgm-exporter GF_LOG="$2/dcgm.log"
  export GF_CONTEXT GF_SYS GF_MODE GF_OUT GF_TARGET GF_EXPORTER GF_LOG
  GF_POD="$(gf_exporter_pod "$1" 2>&1)" || {
    echo "no single exporter Pod on $1: $GF_POD"
    return 1
  }
  export GF_POD
}

# restart_dcgm_reset NODE DIR: the baseline injected and the node seen clear and untainted, as gf_reset does.
restart_dcgm_reset() {
  local node="$1"
  restart_gf_env "$node" "$2" || return 1
  gf_inject 230 0 >>"$RESTART_OUT/dcgm-reset.log" 2>&1 || {
    echo "injecting the baseline into $node failed"
    return 1
  }
  gf_wait_until 120 gf_is_clear || {
    echo "$node did not read clear and untainted within 120 s of the baseline"
    return 1
  }
  echo "$node is clear"
}

# restart_enable_fault_path: the operator watching DCGM on every GPU node, kept that way for the session.
#
# The fault path is off unless the operator's flags say otherwise, and Argo self-heals the operator back to main's
# flags, so both Applications that would do it lose their automated sync first; it is a recorded deviation from main.
restart_enable_fault_path() {
  local app phase dep out
  for app in gpu-platform-root gpu-platform-operator; do
    phase="$(rk -n argocd get application "$app" -o jsonpath='{.status.operationState.phase}' 2>&1)" || {
      echo "could not read $app: ${phase:0:200}"
      return 1
    }
    [[ "$phase" != Running ]] || {
      echo "$app has a sync running; its automated sync is not removed under it"
      return 1
    }
    out="$(rk -n argocd patch application "$app" --type json -p '[{"op":"remove","path":"/spec/syncPolicy/automated"}]' 2>&1)" || {
      echo "could not turn off $app's automated sync: ${out:0:200}"
      return 1
    }
  done
  dep="$(rk -n "$RESTART_SYS" get deploy -l control-plane=controller-manager -o name 2>&1)" || {
    echo "could not find the operator Deployment: ${dep:0:200}"
    return 1
  }
  [[ "$(wc -w <<<"$dep")" == 1 ]] || {
    echo "not exactly one operator Deployment: $dep"
    return 1
  }
  out="$(rk -n "$RESTART_SYS" patch "$dep" --type json -p \
    "[{\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/args/-\",\"value\":\"${RESTART_FAULT_FLAGS[0]}\"},{\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/args/-\",\"value\":\"${RESTART_FAULT_FLAGS[1]}\"}]" 2>&1)" || {
    echo "could not add the fault flags: ${out:0:200}"
    return 1
  }
  out="$(rk -n "$RESTART_SYS" rollout status "$dep" --timeout=300s 2>&1)" || {
    echo "the operator did not roll out with the fault flags: ${out:0:200}"
    return 1
  }
  # kubectl's own kustomize, because the session requires kubectl and not the standalone binary.
  out="$(kubectl kustomize config/dcgm-exporter-fault | rk apply -f - 2>&1)" || {
    echo "could not apply the fault exporter: ${out:0:200}"
    return 1
  }
  sleep 90
  out="$(restart_operator_flags_ok)" || {
    echo "90 s later: $out"
    return 1
  }
  echo "the operator runs with ${RESTART_FAULT_FLAGS[*]} 90 s after the change, and Argo's automated sync is off"
}

# restart_operator_flags_ok: every operator Pod runs its manager with both RESTART_FAULT_FLAGS; prints why not.
#
# Each flag is checked on its own, as a whole argument: the check this replaced looked for the second flag only, so an
# operator watching DCGM without evicting, or evicting with no source, passed it.
restart_operator_flags_ok() {
  local args line flag
  args="$(rk -n "$RESTART_SYS" get pods -l control-plane=controller-manager -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.containers[0].args}{"\n"}{end}' 2>&1)" || {
    echo "could not read the operator Pods' args: ${args:0:200}"
    return 1
  }
  [[ -n "$args" ]] || {
    echo "no operator Pod to read the fault flags from"
    return 1
  }
  while read -r line; do
    [[ -n "$line" ]] || continue
    for flag in "${RESTART_FAULT_FLAGS[@]}"; do
      [[ "$line" == *"\"$flag\""* ]] || {
        echo "${line%% *} runs without $flag: ${line#* }"
        return 1
      }
    done
  done <<<"$args"
}

# restart_fault_path_ready WAIT: before the first case, the operator still runs with both fault flags, and on every GPU
# node the exporter serves the three fields the fault path classifies and the node's NodeHealth reads a fresh, healthy,
# untainted signal within WAIT seconds.
#
# GPUSignal True is the operator's own word that it scraped that node, so this shows the path end to end except the
# fault itself.
# What it cannot show without a fault: that an XID written into the host engine reaches the exporter, and that the
# operator latches, taints and evicts on it; the first dcgm case shows that, and the scorer voids it when it does not.
restart_fault_path_ready() {
  local deadline=$((SECONDS + $1)) nodes node metrics f missing out left
  out="$(restart_operator_flags_ok)" || {
    echo "$out"
    return 1
  }
  nodes="$(rk get nodes -l "eks.amazonaws.com/nodegroup=$RESTART_GROUP" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>&1)" || {
    echo "could not list the GPU nodes: ${nodes:0:200}"
    return 1
  }
  [[ -n "$nodes" ]] || {
    echo "no GPU node to check the fault path on"
    return 1
  }
  while read -r node; do
    [[ -n "$node" ]] || continue
    restart_gf_env "$node" "$RESTART_OUT" || return 1
    metrics="$(gf_metrics 2>&1)" || {
      echo "the exporter on $node could not be scraped: ${metrics:0:200}"
      return 1
    }
    missing=""
    for f in 230 311 310; do
      grep -q "^${GF_FIELD_NAME[$f]}{" <<<"$metrics" || missing="$missing ${GF_FIELD_NAME[$f]}"
    done
    [[ -z "$missing" ]] || {
      echo "the exporter on $node serves no$missing"
      return 1
    }
    left=$((deadline - SECONDS))
    ((left >= 1)) || left=1
    gf_wait_until "$left" gf_is_clear || {
      echo "the NodeHealth of $node did not read a fresh, healthy GPU signal on an untainted node by the deadline"
      return 1
    }
  done <<<"$nodes"
  echo "the operator runs with ${RESTART_FAULT_FLAGS[*]}, and every GPU node's exporter serves the fault fields and its NodeHealth reads a fresh, healthy signal"
}

# restart_prepare_nodes WARMED_FILE DEADLINE: a NodeHealth and a warm-up for every GPU node not yet prepared, all
# finished by DEADLINE (in SECONDS).
#
# Run between cases, never inside one, so a replacement's first pull and first mount are part of the recovery it is
# measured in, and are done before it can be some later case's spare.
# The warm-ups run in parallel, because each node pulls its own copy of the image and the budget is one deadline for all
# of them; warming the three first nodes one after another, each under its own 900 s, had summed to 2,700 s, not 900.
restart_prepare_nodes() {
  local warmed="$1" deadline="$2" nodes node uid pod out left entry failed="" warming=()
  # A node is known by name and UID, because a replacement can come back under a name an earlier node had.
  nodes="$(rk get nodes -l "eks.amazonaws.com/nodegroup=$RESTART_GROUP" -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.uid}{"\n"}{end}' 2>&1)" || {
    echo "could not list the GPU nodes: ${nodes:0:200}"
    return 1
  }
  while read -r node uid; do
    [[ -n "$node" ]] || continue
    [[ -n "$uid" ]] || {
      failed="the GPU node $node was listed with no UID"
      break
    }
    grep -qx "$node $uid" "$warmed" && continue
    out="$(rk apply -f - 2>&1 <<EOF
apiVersion: platform.lkhun9311.github.io/v1
kind: NodeHealth
metadata:
  name: rst-$node
spec:
  nodeName: $node
EOF
)" || {
      failed="could not create the NodeHealth of $node: ${out:0:200}"
      break
    }
    pod="$(restart_warm_start "$node")" || {
      failed="$pod"
      break
    }
    warming+=("$node $uid $pod")
  done <<<"$nodes"
  for entry in "${warming[@]}"; do
    read -r node uid pod <<<"$entry"
    if [[ -z "$failed" ]]; then
      left=$((deadline - SECONDS))
      ((left >= 1)) || left=1
      if out="$(rk -n "$RESTART_NS" wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$pod" --timeout="${left}s" 2>&1)"; then
        echo "$node $uid" >>"$warmed"
        printf '{"node": "%s", "uid": "%s", "prepared_at": "%s"}\n' "$node" "$uid" "$(date -u +%Y-%m-%dT%H:%M:%S.%6NZ)" >>"$RESTART_OUT/nodes-prepared.jsonl"
      else
        failed="the warm-up on $node did not succeed by the warm deadline (${left}s left): ${out:0:200}"
      fi
    fi
    # Every warm-up Pod started is deleted, the ones after a failure included.
    rk -n "$RESTART_NS" delete pod "$pod" --wait=false >>"$RESTART_OUT/warm.log" 2>&1
  done
  [[ -z "$failed" ]] || {
    echo "$failed"
    return 1
  }
  echo "every GPU node has a NodeHealth and has pulled the image and mounted the volume"
}

# restart_warm_start NODE: a Pod on NODE, with no GPU, that imports torch from the pinned image and writes and reads the
# shared volume, so that node's first pull and first mount are not inside a measured recovery; prints the Pod's name.
restart_warm_start() {
  local node="$1" pod out
  pod="rst-warm-$(tr -dc 'a-z0-9' <<<"$node" | tail -c 20)"
  out="$(rk -n "$RESTART_NS" apply -f - 2>&1 <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $pod
spec:
  nodeName: $node
  restartPolicy: Never
  tolerations:
    - key: nvidia.com/gpu
      operator: Exists
      effect: NoSchedule
  containers:
    - name: warm
      image: $RESTART_IMAGE
      command: ["sh", "-c", "python -c 'import torch' && echo $node >$RESTART_MOUNT/.warm-$node && cat $RESTART_MOUNT/.warm-$node && rm $RESTART_MOUNT/.warm-$node"]
      volumeMounts:
        - name: shared
          mountPath: $RESTART_MOUNT
  volumes:
    - name: shared
      persistentVolumeClaim:
        claimName: $RESTART_CLAIM
EOF
)" || {
    echo "could not create the warm-up Pod on $node: ${out:0:200}"
    return 1
  }
  echo "$pod"
}

# restart_deadline_ok SECONDS: the GPU deadline leaves at least SECONDS, or nothing more may start.
#
# The EventBridge deadline fires once; a case, or a replacement the group launches on its own, started after it would
# run with no deadline of AWS's at all, so what may not finish before it is not started.
restart_deadline_ok() {
  local need="$1" left
  left="$(ttl_remaining_minutes "$RESTART_CLUSTER" "$RESTART_GROUP" 2>&1)" || {
    echo "could not read the GPU deadline: ${left:0:200}"
    return 1
  }
  [[ "$left" =~ ^-?[0-9]+$ ]] || {
    echo "the GPU deadline read as '${left:0:80}'"
    return 1
  }
  if ((left * 60 < need)); then
    echo "the GPU deadline is $left min away and the next step needs $((need / 60)) min; nothing more starts"
    return 1
  fi
  echo "the GPU deadline is $left min away"
}

# restart_collect DIR NAME: every Pod's log streamed from its container's start into its own file, restarted when a
# stream ends while the Pod still runs; duplicates are removed by the scorer, and every stream's end is recorded.
restart_collect() {
  local dir="$1" name="$2" started=" " rows uid pod node index
  # shellcheck disable=SC2046  # word splitting of the pid list is intended
  trap 'kill $(jobs -p) 2>>"$dir/collector.log"; exit 0' TERM
  while :; do
    rows="$(rk -n "$RESTART_NS" get pods -l "platform.lkhun9311.github.io/mltrainingjob=$name" -o json 2>>"$dir/collector.log" | python3 -c '
import json, sys
for p in json.load(sys.stdin)["items"]:
    cs = (p.get("status", {}).get("containerStatuses") or [{}])[0]
    if cs.get("state", {}).get("running") or cs.get("state", {}).get("terminated"):
        ann = p["metadata"].get("annotations", {})
        token = (p["metadata"].get("labels") or {}).get("platform.lkhun9311.github.io/mltrainingjob-attempt") or "-"
        print(p["metadata"]["uid"], p["metadata"]["name"], p["spec"].get("nodeName") or "-", ann.get("batch.kubernetes.io/job-completion-index", "-"), token)
' 2>>"$dir/collector.log")"
    while read -r uid pod node index token; do
      [[ -n "$uid" ]] || continue
      case "$started" in *" $uid "*) continue ;; esac
      started="$started$uid "
      # The attempt label is the controller's own (mltjAttemptLabel in internal/controller/mltrainingjob_distributed.go),
      # so which attempt a Pod ran is read from the controller and not inferred from the order Pods were seen in.
      printf '{"uid": "%s", "pod": "%s", "node": "%s", "index": "%s", "attempt_token": "%s", "observed": "%s"}\n' \
        "$uid" "$pod" "$node" "$index" "$token" "$(date -u +%Y-%m-%dT%H:%M:%S.%6NZ)" >>"$dir/pods.jsonl"
      (
        local n=0
        while :; do
          n=$((n + 1))
          rk -n "$RESTART_NS" logs -f "$pod" >"$dir/log-$uid.$n.txt" 2>>"$dir/collector.log"
          printf '{"uid": "%s", "stream": %d, "exit": %d, "at": "%s"}\n' "$uid" "$n" "$?" "$(date -u +%Y-%m-%dT%H:%M:%S.%6NZ)" >>"$dir/streams.jsonl"
          # A stream that ended with its container is complete; one that ended while it runs is read again in full.
          [[ "$(rk -n "$RESTART_NS" get pod "$pod" -o jsonpath='{.status.containerStatuses[0].state.running}' 2>>"$dir/collector.log")" != "" ]] || break
          ((n < 20)) || break
        done
      ) &
    done <<<"$rows"
    sleep "$RESTART_POLL"
  done
}

# restart_retire NAME WAIT: the case's job deleted, and its Jobs, Pods and Workloads gone, before anything else starts.
#
# A case censored at its budget may still be running or restarting; its writers stop before its state is deleted, and
# the next case does not share the queue or the nodes with it.
restart_retire() {
  local name="$1" wait="$2" deadline=$((SECONDS + $2)) left="not polled before the deadline" mltj jobs pods
  rkd "$deadline" -n "$RESTART_NS" delete mltrainingjob "$name" --ignore-not-found --wait=false >>"$RESTART_OUT/retire.log" 2>&1
  while ((SECONDS < deadline)); do
    # Each read must succeed: a read that failed says nothing about what is left, and is not taken as nothing.
    if mltj="$(rkd "$deadline" -n "$RESTART_NS" get mltrainingjob "$name" --ignore-not-found -o name 2>&1)" &&
      jobs="$(rkd "$deadline" -n "$RESTART_NS" get jobs.batch,workloads.kueue.x-k8s.io -o name 2>&1)" &&
      pods="$(rkd "$deadline" -n "$RESTART_NS" get pods -l "platform.lkhun9311.github.io/mltrainingjob=$name" -o name 2>&1)"; then
      left="$(printf '%s\n%s\n%s\n' "$mltj" "$(grep -F "$name" <<<"$jobs")" "$pods" | sed '/^$/d' | paste -sd' ')"
      if [[ -z "$left" ]]; then
        echo "$name retired"
        return 0
      fi
    else
      left="unreadable: ${mltj:0:80} ${jobs:0:80} ${pods:0:80}"
    fi
    sleep "$RESTART_POLL"
  done
  echo "$name was not retired within ${wait}s: $left"
  return 1
}

# The reader Pod runs on the CPU node, which is in the registered zone too, so copying evidence off the volume never
# depends on a GPU node a case may have just terminated; busybox 1.36.1's amd64 manifest, read 2026-11-01.
RESTART_READER_IMAGE=docker.io/library/busybox@sha256:b7f3d86d6e84fc17718c48bcde1450807faa2d56704205c697b4bd5df7b9e29f

# restart_reader: one long-lived Pod with the claim mounted, for copying each case's NCCL logs and listing its files.
restart_reader() {
  local out
  out="$(rk -n "$RESTART_NS" apply -f - 2>&1 <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: rst-reader
spec:
  nodeSelector:
    eks.amazonaws.com/nodegroup: cpu
  containers:
    - name: reader
      image: $RESTART_READER_IMAGE
      command: ["sleep", "86400"]
      volumeMounts:
        - name: shared
          mountPath: $RESTART_MOUNT
  volumes:
    - name: shared
      persistentVolumeClaim:
        claimName: $RESTART_CLAIM
EOF
)" || {
    echo "could not create the reader Pod: ${out:0:200}"
    return 1
  }
  out="$(rk -n "$RESTART_NS" wait --for=condition=Ready pod/rst-reader --timeout=600s 2>&1)" || {
    echo "the reader Pod was not Ready within 600 s: ${out:0:200}"
    return 1
  }
  echo "the reader Pod mounts the volume on the CPU node"
}

# restart_wait_group WANT WAIT: exactly WANT nodes in the group, every one qualified, none tainted by the fault path.
#
# train_qualify_nodes refuses a group holding more nodes than asked for, which is right at purchase and wrong while a
# scale-in is still removing one, so the count is waited for first.
restart_wait_group() {
  local want="$1" wait="$2" deadline=$((SECONDS + $2)) n="" ids tainted
  while ((SECONDS < deadline)); do
    n="$(rkd "$deadline" get nodes -l "eks.amazonaws.com/nodegroup=$RESTART_GROUP" -o name 2>&1 | grep -c '^node/')"
    ((n == want)) && break
    sleep "$RESTART_POLL"
  done
  ((n == want)) || {
    echo "the group held $n node(s), not $want, within ${wait}s"
    return 1
  }
  # What is left of the deadline and no more: a floor here would let the qualification run past the share it was given.
  ids="$(train_qualify_nodes "$RESTART_CONTEXT" "$RESTART_GROUP" "$want" $((deadline - SECONDS > 1 ? deadline - SECONDS : 1)) 1)" || {
    echo "$ids"
    return 1
  }
  awk '{print $2}' <<<"$ids" >>"$RESTART_INSTANCES_FILE"
  # Read first and filtered after, because a failed read piped into the filter came out as "no node tainted".
  tainted="$(rkd $((SECONDS + 20)) get nodes -l "eks.amazonaws.com/nodegroup=$RESTART_GROUP" -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.taints[*].key}{"\n"}{end}' 2>&1)" || {
    echo "could not read the GPU nodes' taints: ${tainted:0:200}"
    return 1
  }
  tainted="$(grep -F 'platform.lkhun9311.github.io/gpu-fault' <<<"$tainted")"
  [[ -z "$tainted" ]] || {
    echo "a node still carries the fault taint: $tainted"
    return 1
  }
  echo "$want qualified node(s): $(paste -sd';' <<<"$ids")"
}

# restart_sample NAME DIR: one line of what the case is waiting on, as the kind harness samples it.
restart_sample() {
  local name="$1" dir="$2" mltj
  mltj="$(rk -n "$RESTART_NS" get mltrainingjob "$name" -o json 2>&1)" || mltj=null
  python3 -c '
import datetime, json, sys
try:
    m = json.loads(sys.argv[1]) or {}
except ValueError:
    m = {}
print(json.dumps({"observed": datetime.datetime.now(datetime.timezone.utc).isoformat(), "status": m.get("status"),
                  "annotations": (m.get("metadata") or {}).get("annotations")}, sort_keys=True))
' "$mltj" >>"$dir/timeline.jsonl"
}

# restart_status NAME EXPR: one value of the job's status, from a Python expression over `s` and `a` (its attempts).
restart_status() {
  rk -n "$RESTART_NS" get mltrainingjob "$1" -o json 2>>"$RESTART_OUT/status.log" | python3 -c "
import json, sys
try:
    s = json.load(sys.stdin).get('status') or {}
    a = s.get('attempts') or []
    v = $2
    print('' if v is None else v)
except Exception:
    pass"
}

# restart_rank_pod DIR INDEX: the first Pod of that rank the collector saw, as "uid pod node".
restart_rank_pod() {
  [[ -s "$1/pods.jsonl" ]] || return 1
  python3 -c '
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
rows = [r for r in rows if r["index"] == sys.argv[2]]
if not rows:
    sys.exit(1)
r = rows[0]
print(r["uid"], r["pod"], r["node"])' "$1/pods.jsonl" "$2"
}

# restart_efs_credits DIR LABEL: the file system's burst credit balance, read-only, since bursting throughput depends on it.
restart_efs_credits() {
  local v
  v="$(timeout 20 aws cloudwatch get-metric-statistics --region "$RESTART_REGION" --namespace AWS/EFS --metric-name BurstCreditBalance \
    --dimensions "Name=FileSystemId,Value=$RESTART_FS_ID" --start-time "$(date -u -d '-15 min' +%Y-%m-%dT%H:%M:%SZ)" \
    --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --period 60 --statistics Minimum --query 'sort_by(Datapoints, &Timestamp)[-1].Minimum' \
    --output text 2>&1)" || v="unread: ${v:0:120}"
  printf '%s %s %s\n' "$2" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$v" >>"$1/efs-credits.txt"
}

# restart_void_case DIR NAME JOB_ID COLLECTOR RETIRE_DEADLINE REASON: the case VOID for REASON, its evidence read, its
# collector stopped and its job retired; 1 once the retirement is confirmed, 2 when it is not.
#
# A VOID case that may still hold Pods, Workloads and GPUs shares the queue and the nodes with whatever starts next,
# exactly as a censored one does, so its unconfirmed retirement stops every later submission the same way.
# The job, the nodes and a timeline sample are read before the retirement deletes the job, so a VOID case leaves the
# same evidence files as one that ran.
restart_void_case() {
  local dir="$1" name="$2" job_id="$3" collector="$4" retire_dl="$5"
  echo "$6" >"$dir/VOID"
  restart_sample "$name" "$dir"
  rk -n "$RESTART_NS" get mltrainingjob "$name" -o json >"$dir/final-mltj.json" 2>>"$dir/case.log"
  rk get nodes -o json >"$dir/nodes-after.json" 2>>"$dir/case.log"
  if [[ -n "$collector" ]]; then
    kill "$collector" 2>>"$dir/case.log"
    wait "$collector" 2>>"$dir/case.log"
  fi
  restart_retire "$name" $((retire_dl - SECONDS)) >>"$dir/case.log" || {
    echo "retirement of the VOID case $name was not confirmed; its files are left on the volume and nothing more may start" >>"$dir/case.log"
    restart_list_shared "$dir" "$job_id"
    return 2
  }
  restart_case_files "$dir" "$job_id"
  return 1
}

# restart_list_shared DIR JOB_ID: the case's files on the volume listed into DIR/shared-files.txt, read-only, so a case
# whose writers may still run is listed without touching what they write.
restart_list_shared() {
  rkt 30 -n "$RESTART_NS" exec rst-reader -- find "$RESTART_MOUNT/$2" -type f >"$1/shared-files.txt" 2>>"$1/case.log"
}

# restart_case_files DIR JOB_ID: a retired case's NCCL logs copied, its files listed, and its directory deleted.
#
# Three calls of at most 30 s, and the verdict's 30 s after the reset, are RESTART_FILES_BUDGET.
restart_case_files() {
  local dir="$1" job_id="$2"
  mkdir -p "$dir/nccl"
  rkt 30 -n "$RESTART_NS" exec rst-reader -- tar -C "$RESTART_MOUNT/$job_id" -cf - nccl 2>>"$dir/case.log" | tar -C "$dir" -xf - 2>>"$dir/case.log"
  restart_list_shared "$dir" "$job_id"
  rkt 30 -n "$RESTART_NS" exec rst-reader -- rm -rf "$RESTART_MOUNT/$job_id" >>"$dir/case.log" 2>&1
}

# restart_run_case CASE SLOT_DEADLINE: one registered case, from submission to its retirement, inside the slot
# restart_run gave it, which ends at SLOT_DEADLINE (in SECONDS); 0 when it ran (whatever its verdict), 1 when it could
# not be run and is VOID, 2 when its retirement or its DCGM reset was not confirmed and nothing more may start.
#
# The retirement's deadline is counted back from the slot's end, past the files and the reset, so a run or an evidence
# read that ran long takes from the retirement's share and never pushes the files or the reset past the slot.
restart_run_case() {
  local case="$1" slot_dl="$2" kind="${1%-[0-9]*}" name dir job_id deadline collector rank0 rank1 node1 pod0 rc window out probed=""
  local retire_dl=$(($2 - RESTART_FILES_BUDGET))
  [[ "${1%-[0-9]*}" != dcgm ]] || retire_dl=$((retire_dl - RESTART_RESET_BUDGET))
  name="rst-$case-$(date -u +%H%M%S)"
  job_id="$name-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
  dir="$RESTART_OUT/$case"
  mkdir -p "$dir"
  restart_render_job "$name" "$RESTART_NS" "$RESTART_QUEUE" "$job_id" "$case" >"$dir/mltrainingjob.json" || {
    echo "the job could not be rendered" >"$dir/VOID"
    return 1
  }
  restart_efs_credits "$dir" before
  rk get nodes -o json >"$dir/nodes-before.json" 2>>"$dir/case.log"
  # The case's own budget starts at the create and is the registered censoring bound, so it is never shortened to fit.
  # A create whose answer was lost may still have made the job, so a refused create is retired like any other VOID.
  out="$(rk apply -f "$dir/mltrainingjob.json" 2>&1)" || {
    restart_void_case "$dir" "$name" "$job_id" "" "$retire_dl" "create refused: ${out:0:300}"
    return
  }
  deadline=$((SECONDS + RESTART_CASE_BUDGET))
  restart_collect "$dir" "$name" &
  collector=$!
  printf '{"kind": "%s", "name": "%s", "job_id": "%s", "target": {}}\n' "$kind" "$name" "$job_id" >"$dir/case.json"

  # Both ranks have recorded a step before any clock is probed or any fault is injected.
  while ((SECONDS < deadline)); do
    restart_sample "$name" "$dir"
    [[ "$(restart_records "$dir" | grep -c '"event": "step"')" -ge 2 ]] && break
    sleep "$RESTART_POLL"
  done
  # A fault whose nodes' clocks were not read before it cannot be placed on the runner's clock, and the scorer would void
  # the case after the fault had cost a node, so the case is VOID before its fault and retired instead.
  # The reference has no fault and no recovery to time, so for it a failed probe is only logged.
  if ! out="$(restart_probe_all "$dir" before 2>&1)"; then
    if [[ "$kind" != reference ]]; then
      restart_void_case "$dir" "$name" "$job_id" "$collector" "$retire_dl" "VOID-before-fault: a clock probe before the fault failed, so nothing was injected: ${out:0:200}"
      return
    fi
    echo "a clock probe before the fault failed: $out" >>"$dir/case.log"
  fi

  if [[ "$kind" == dcgm || "$kind" == terminate-* ]]; then
    rank0="$(restart_rank_pod "$dir" 0)" && rank1="$(restart_rank_pod "$dir" 1)" || {
      restart_void_case "$dir" "$name" "$job_id" "$collector" "$retire_dl" "the ranks' Pods were never seen"
      return
    }
    pod0="$(awk '{print $2}' <<<"$rank0")"
    node1="$(awk '{print $3}' <<<"$rank1")"
    window="$(restart_fault_window "$pod0" "$job_id" "$dir" $((deadline - SECONDS)))" || {
      restart_void_case "$dir" "$name" "$job_id" "$collector" "$retire_dl" "no fault window: $window"
      return
    }
    out="$(restart_external_fault "$kind" "$dir" "$name" "$job_id" "$pod0" "$node1" "$window" "$deadline" "$slot_dl")"
    rc=$?
    echo "$out" >>"$dir/case.log"
    if ((rc != 0)); then
      echo "the fault was not delivered: $out" >"$dir/VOID"
    fi
  fi

  # Until the job ends or the budget does; the clocks are probed again once both ranks of attempt 2 have stepped.
  while ((SECONDS < deadline)); do
    restart_sample "$name" "$dir"
    if [[ -z "$probed" ]] && [[ "$(restart_records "$dir" | grep '"attempt": 2' | grep -c '"event": "step"')" -ge 2 ]]; then
      restart_probe_all "$dir" after || echo "a clock probe after the recovery failed" >>"$dir/case.log"
      probed=1
    fi
    case "$(restart_status "$name" "s.get('phase')")" in Succeeded | Failed) break ;; esac
    sleep "$RESTART_POLL"
  done
  [[ -n "$probed" ]] || restart_probe_all "$dir" after || echo "a clock probe at the end failed" >>"$dir/case.log"
  rk -n "$RESTART_NS" get mltrainingjob "$name" -o json >"$dir/final-mltj.json" 2>>"$dir/case.log"
  rk get nodes -o json >"$dir/nodes-after.json" 2>>"$dir/case.log"
  restart_efs_credits "$dir" after
  sleep 5
  kill "$collector" 2>>"$dir/case.log"
  wait "$collector" 2>>"$dir/case.log"

  # The writers are stopped before their files are copied and deleted.
  # A case whose retirement cannot be confirmed may still be writing and still hold GPUs and quota, so its files stay on
  # the volume and the run stops (codex review of 830f64af).
  # Their listing is still written, read-only, so the scorer is not left without it.
  restart_retire "$name" $((retire_dl - SECONDS)) >>"$dir/case.log" || {
    echo "retirement of $name was not confirmed; its files are left on the volume" >>"$dir/case.log"
    restart_list_shared "$dir" "$job_id"
    return 2
  }
  restart_case_files "$dir" "$job_id"
  if [[ "$kind" == dcgm && -n "${node1:-}" ]]; then
    # A node left latched is a node the next case cannot use, so the run stops rather than measure accumulated damage.
    restart_dcgm_reset "$node1" "$dir" >>"$dir/case.log" 2>&1 || {
      echo "the DCGM reset of $node1 failed" >>"$dir/case.log"
      return 2
    }
  fi
  return 0
}

# restart_verdict CASE: the scorer's verdict on one case of the run so far: ACCEPTED, FAILED, VOID or NOTRUN.
restart_verdict() {
  timeout 30 python3 experiments/distributed-restart/score_eks.py --partial "$RESTART_OUT" 2>>"$RESTART_OUT/score.log" |
    awk -v c="$1" '$2 == c || $2 == c ":" {print $1; exit}'
}

# restart_notrun CASE REASON: the case recorded as not started, with why.
restart_notrun() {
  mkdir -p "$RESTART_OUT/$1"
  echo "$2" >"$RESTART_OUT/$1/NOTRUN"
}

# restart_run WARMED_FILE: every case of the stage in order, scored as it ends, stopping the spending on the
# registration's abort conditions; a case not run is recorded as such, never left absent.
#
# Each case runs in a slot with one absolute deadline, and the share before its submission has one too, both the
# shares restart_gpu_budget adds up, so the session's deadline was sized for what can run and not for what usually does.
restart_run() {
  local warmed="$1" cases case kind verdict void_run=0 stop="" want=3 out prev="" slot slot_dl pre_dl reserve rc
  cases="$(restart_cases 2>&1)" || {
    echo "stopped early: $cases"
    return 1
  }
  for case in $cases; do
    kind="${case%-[0-9]*}"
    if [[ -n "$stop" ]]; then
      restart_notrun "$case" "$stop"
      continue
    fi
    slot="$(restart_slot_seconds "$case" "$prev")"
    slot_dl=$((SECONDS + slot))
    pre_dl=$((SECONDS + $(restart_pre_seconds "$case" "$prev")))
    # After a termination the warm-up of the replacement has its own share, which the group's wait may not take.
    reserve=0
    [[ "${prev%-[0-9]*}" != terminate-* ]] || reserve="$RESTART_WARM_BUDGET"
    prev="$case"
    # No slot starts that the GPU deadline cannot cover whole: the deadline fires once, and a replacement the group
    # launches on its own after it would run with none (A20, B7).
    out="$(restart_deadline_ok "$slot")" || {
      stop="$out"
      restart_notrun "$case" "$stop"
      continue
    }
    # terminate-wait runs with no spare: the group at two, so attempt 2 can only start on a replacement.
    # The slot's deadline check above comes first: after the one-shot deadline has fired, any desired size above zero is
    # a purchase with no deadline behind it (codex review of 830f64af).
    if [[ "$kind" == terminate-wait && "$want" == 3 ]]; then
      want=2
      out="$(timeout 60 aws eks update-nodegroup-config --region "$RESTART_REGION" --cluster-name "$RESTART_CLUSTER" --nodegroup-name "$RESTART_GROUP" \
        --scaling-config minSize=0,maxSize=3,desiredSize=2 2>&1)" || {
        stop="the group could not be scaled to two for terminate-wait: ${out:0:200}"
        restart_notrun "$case" "$stop"
        continue
      }
    fi
    out="$(restart_wait_group "$want" $((pre_dl - reserve - SECONDS)))" &&
      out="$(restart_prepare_nodes "$warmed" "$pre_dl")" || {
      stop="before $case: $out"
      restart_notrun "$case" "$stop"
      continue
    }
    restart_run_case "$case" "$slot_dl"
    rc=$?
    verdict="$(restart_verdict "$case")"
    echo "$case: ${verdict:-no verdict}"
    ((rc != 2)) || stop="$case could not be retired or its DCGM fault reset; see $RESTART_OUT/$case/case.log"
    if [[ "$verdict" == VOID || -z "$verdict" ]]; then void_run=$((void_run + 1)); else void_run=0; fi
    if [[ -n "$stop" ]]; then
      :
    elif [[ "$case" == reference || "$case" == no-rng-control ]] && [[ "$verdict" != ACCEPTED ]]; then
      stop="$case was ${verdict:-unscored}, and every measured case is compared with it"
    elif ((void_run >= 2)); then
      stop="two cases in a row were VOID"
    elif [[ "$verdict" == NOTRUN ]]; then
      stop="$case was not started: $(cat "$RESTART_OUT/$case/NOTRUN")"
    fi
  done
  [[ -z "$stop" ]] || echo "stopped early: $stop"
}
