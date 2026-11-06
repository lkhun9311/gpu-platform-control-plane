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
# hack/lib/phase-supervisor.sh it sources itself when the caller has not, because restart_run's steps run in its phases,
# and a caller in a cgroup it does not own has every phase refused (status 125).

# shellcheck source=hack/lib/phase-supervisor.sh
declare -F paid_phase >/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/phase-supervisor.sh"

# The image every EKS training session pins: torch 2.5.1+cu124, CUDA 12.4, NCCL 2.21.5.
RESTART_IMAGE=docker.io/pytorch/pytorch@sha256:c8268a92a69bd500f8be0e665b2630ee006dadaf7bfbc24249141b15ff622755
RESTART_TRAIN_PY=experiments/distributed-restart/train.py
RESTART_AZ=ap-northeast-2a
RESTART_STEPS=30
RESTART_STEP_SLEEP=2
RESTART_BALLAST_MB=16
# The controller restarts when the Job fails, and a surviving rank blocked in a collective keeps it running until this.
RESTART_COLLECTIVE_TIMEOUT=60
# How long a rank waits for its peer to start, which train.py bounds apart from the collective timeout.
# A terminate-wait restart starts one rank on the survivor while its peer waits for a replacement node, its pull and its
# mount, and the 60 s join failed that case on kind (hack/restart-lifecycle-kind-20261101T143009Z, run-a).
# Below RESTART_CASE_BUDGET, so a peer that never comes fails the attempt and is not only censored.
RESTART_RENDEZVOUS_TIMEOUT=600
# One case from submission to its verdict; a case that has not succeeded by then is FAILED, censored at this budget.
RESTART_CASE_BUDGET=720
# The other shares of one case's slot, each a limit the runner enforces, so restart_gpu_budget is the sum of what can
# really run and not of what usually does.
# Before submission: reading the deadline, rendering, the credit read (20 s), the node read (20 s) and the create (20 s).
RESTART_SUBMIT_BUDGET=120
# After the run, counted from its deadline: the clock probes, ended RESTART_PROBE_SHARE past it; two reads of 20 s and
# the credit read of 20 s, ended where RESTART_STOP_RESERVE is left; then the pause and the collector's stop.
RESTART_EVIDENCE_BUDGET=120
RESTART_PROBE_SHARE=40
# The pause lets the collector's follows write what the job's end printed before it is stopped.
RESTART_EVIDENCE_PAUSE=5
# The pause and restart_stop_collector's ten TERMs a second apart, with a second for its KILL and its wait.
RESTART_STOP_RESERVE=16
# The case's job deleted and its Jobs, Pods and Workloads seen gone.
RESTART_RETIRE_BUDGET=300
# Copying the NCCL logs, listing and deleting the case's files, and scoring it: four calls of at most 30 s.
RESTART_FILES_BUDGET=120
# A dcgm case's baseline injection and the 120 s wait for the node to read clear, with 60 s for the calls around it, all
# under one deadline, the slot's end less RESTART_VERDICT_CALL.
RESTART_RESET_BUDGET=180
# The scorer's verdict on a case, the last share of its slot and part of RESTART_FILES_BUDGET.
RESTART_VERDICT_CALL=30
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
# The commit that records each rank node's UID (status.attempts[].nodeUIDs); a run that claims that protection needs it
# deployed, and the gate requires it and the CRD field that keeps it (codex review before the re-verification).
RESTART_NODE_UID_COMMIT=f7b8f9ca

# restart_cases: the cases of RESTART_STAGE, in the registered order, one per line; fails for any other stage.
#
# smoke is the first paid stage, run and inspected before anything else is bought: the two cases every other one is
# compared with, and one of each external fault, the DCGM path and a termination that can only recover on a replacement.
# full is the registered kinds at RESTART_REPS each.
# retarget re-runs, after the changes made since full, the two kinds whose retirement waited on the old Job's deletion,
# so their stop barrier can be read against full's; it buys no termination, whose path did not change
# (docs/superpowers/specs/2026-11-04-restart-retarget-design.md).
# corelimit asks why retarget's rank-kill stop still took 38 s: the surviving rank aborts on its peer's death, and three
# of six rank-kill cases run with core dumps off (RESTART_NOCORE_CASES), so the two arms can be read against each other
# (docs/superpowers/specs/2026-11-06-restart-corelimit-design.md).
restart_cases() {
  local kind i
  case "${RESTART_STAGE:-}" in
    smoke) printf '%s\n' reference no-rng-control dcgm-1 terminate-wait-1 ;;
    retarget) printf '%s\n' reference no-rng-control rank-kill-1 rank-kill-2 dcgm-1 dcgm-2 ;;
    corelimit) printf '%s\n' reference rank-kill-1 rank-kill-2 rank-kill-3 rank-kill-4 rank-kill-5 rank-kill-6 dcgm-1 dcgm-2 dcgm-3 ;;
    full)
      echo reference
      echo no-rng-control
      for kind in rank-kill dcgm terminate-spare terminate-wait; do
        for ((i = 1; i <= RESTART_REPS; i++)); do echo "$kind-$i"; done
      done
      ;;
    *)
      echo "RESTART_STAGE is '${RESTART_STAGE:-}', not smoke, full, retarget or corelimit" >&2
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
  local name="$1" ns="$2" queue="$3" job_id="$4" case="$5" extra sha body limit
  extra="$(restart_case_env "$case")" || {
    echo "$case is not a registered case" >&2
    return 1
  }
  [[ "$job_id" =~ ^[a-z0-9-]+$ ]] || {
    echo "job ID '$job_id' is not a plain name" >&2
    return 1
  }
  sha="$(sha256sum "$RESTART_TRAIN_PY" | cut -d' ' -f1)" || return 1
  # The limit is set by the shell before the trainer starts, so the trainer and nothing else inherits it; the line after
  # records what the rank ran with, read inside its container, because a node's core_pattern and containerd's LimitCORE
  # are nowhere else in the evidence (the corelimit registration).
  limit=""
  [[ "$(restart_core_limit "$case")" == 0 ]] && limit="ulimit -c 0 || exit 88"
  # The trainer is the shell's child, because as PID 1 it could not kill itself for a fault; and the shell, as PID 1,
  # would drop a TERM it had no handler for, so it hands TERM on to the trainer.
  # Without that every retired rank waited out the 30 s grace period: on kind the shell as rendered took 31.8 s to
  # delete and one that forwarded TERM 1.0 s, and the paid full stage's stop barrier held 30 to 39 s on the old Job's
  # deletion in every rank-kill and dcgm case (experiments/distributed-restart/README.md).
  # A TERM interrupts wait, so the shell waits again until the trainer itself has exited and leaves with its status:
  # leaving at the first wait ended the shell at 143 with the trainer still running, and the trainer then died only
  # because PID 1 had (codex review before the re-verification). A rank that killed itself for a fault still fails its
  # Job with 137.
  body="$(printf '%s\n' \
    "echo $(base64 -w0 "$RESTART_TRAIN_PY") | base64 -d >/tmp/train.py" \
    "echo \"$sha  /tmp/train.py\" | sha256sum -c - >/dev/null || exit 86" \
    "nccl_dir=$RESTART_MOUNT/$job_id/nccl" \
    "mkdir -p \"\$nccl_dir\" && touch \"\$nccl_dir/.a\${TRAINING_ATTEMPT}-r\${RANK}\" || exit 87" \
    "export CKPT_BACKEND=nccl CKPT_RUN_ID=$name CKPT_DIR=$RESTART_MOUNT CKPT_JOB_ID=$job_id CKPT_STEPS=$RESTART_STEPS CKPT_STEP_SLEEP=$RESTART_STEP_SLEEP" \
    "export CKPT_BALLAST_MB=$RESTART_BALLAST_MB CKPT_COLLECTIVE_TIMEOUT=$RESTART_COLLECTIVE_TIMEOUT CKPT_RENDEZVOUS_TIMEOUT=$RESTART_RENDEZVOUS_TIMEOUT OMP_NUM_THREADS=1" \
    "export NCCL_DEBUG=INFO NCCL_DEBUG_SUBSYS=INIT,NET NCCL_DEBUG_FILE=\"\$nccl_dir/a\${TRAINING_ATTEMPT}-r\${RANK}-%h.%p.log\"" \
    "$extra" \
    "$limit" \
    "echo \"rank-env: core_limit=\$(ulimit -c) core_pattern=\$(cat /proc/sys/kernel/core_pattern) torch_nccl_async_error_handling=\${TORCH_NCCL_ASYNC_ERROR_HANDLING:-unset}\"" \
    "python /tmp/train.py &" \
    "child=\$!" \
    "trap 'kill -TERM \$child' TERM" \
    "wait \$child" \
    "rc=\$?" \
    "while [ -d /proc/\$child ]; do wait \$child; rc=\$?; done" \
    "exit \$rc")"
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

# A phase that restart_gpu_budget charges a fixed share for runs under restart_by, which sets RESTART_DL (on the phase_mono clock)
# for everything it calls, nested helpers included, because each call bounded on its own still added up past the share:
# the evidence's probes and reads could take about 300 s of a 120 s share, and the reset 720 s of a 180 s one.
# GF_DEADLINE is the same instant in epoch seconds, for gpu-fault.sh's gf_wait_until, which counts by date and not by phase_mono.
RESTART_DL=""

# restart_by DEADLINE CMD...: CMD with every call it makes bounded by DEADLINE (on the phase_mono clock), or by an earlier deadline
# already in force, since a phase nested in another may not outlast it.
restart_by() {
  local dl="$1"
  shift
  [[ -z "${RESTART_DL:-}" ]] || ((dl <= RESTART_DL)) || dl="$RESTART_DL"
  local RESTART_DL="$dl" GF_DEADLINE
  GF_DEADLINE="$(phase_epoch "$dl")"
  "$@"
}

# restart_cap VAR SECONDS: VAR set to SECONDS, or to what is left of RESTART_DL when that is less; fails, saying so, once
# RESTART_DL has passed, so a call is refused rather than started with no time to finish.
# It sets a variable rather than printing, because a command substitution forks for every call it bounds.
restart_cap() {
  local _cap="$2"
  if [[ -n "${RESTART_DL:-}" ]] && ((RESTART_DL - $(phase_mono) < _cap)); then _cap=$((RESTART_DL - $(phase_mono))); fi
  ((_cap >= 1)) || {
    echo "the deadline has passed ($(($(phase_mono) - RESTART_DL)) s ago); the call was not made" >&2
    return 1
  }
  printf -v "$1" '%s' "$_cap"
}

# How long a cut call is given to end on its TERM before it is killed, so a kubectl that ignores TERM cannot hold a phase.
# It and a second of the clock's rounding are the most a call cut by timeout(1) can outlast its deadline, and every call
# after the deadline is refused.
RESTART_KILL_AFTER=2

# rk ARGS...: kubectl on the session's context, ended after 20 s, or at what is left of RESTART_DL under restart_by,
# and refused once that has passed.
# Its request timeout bounds the request only: a credential helper that hangs held a GET with a 1 s request timeout for
# 3 s, so the whole process is cut by timeout(1) as well (codex gpt-6-astra attack of the retarget registration).
# That costs about 0.1 s a call here (uutils; 20 calls of `timeout 60 true` took 2.0 s, 2026-11-05).
rk() {
  local t=20
  restart_cap t 20 || return 1
  timeout -k "$RESTART_KILL_AFTER" "$t" kubectl --context "$RESTART_CONTEXT" --request-timeout="${t}s" "$@"
}

# restart_bounded_kubectl ARGS...: the kubectl binary, run with ARGS as given and cut at 20 s or at RESTART_DL, for the
# shared libraries' calls that name their own context and request timeout; refused once RESTART_DL has passed.
restart_bounded_kubectl() {
  local t=20 bin
  restart_cap t 20 || return 1
  bin="$(type -P kubectl)" || {
    echo "no kubectl on PATH" >&2
    return 127
  }
  timeout -k "$RESTART_KILL_AFTER" "$t" "$bin" "$@"
}

# rkd DEADLINE ARGS...: rk that cannot outlive DEADLINE (on the phase_mono clock), so a poll that starts just before its phase's
# deadline does not carry the phase into the next one's share.
# It is given a second when DEADLINE has just passed, so a poll's last look is still made, but never past an enclosing
# RESTART_DL, which it once ignored and called after (codex gpt-6-astra attack of the retarget registration).
rkd() {
  local t=$(($1 - $(phase_mono)))
  shift
  ((t <= 20)) || t=20
  ((t >= 1)) || t=1
  restart_cap t "$t" || return 1
  timeout -k "$RESTART_KILL_AFTER" "$t" kubectl --context "$RESTART_CONTEXT" --request-timeout="${t}s" "$@"
}

# rkt SECONDS ARGS...: rk ended after SECONDS, or at RESTART_DL if that comes first, whatever it is doing, for an exec or
# a stream a request timeout does not bound; 124 or 137 when it was cut, so a caller can tell a cut call from a refused one.
rkt() {
  local t
  restart_cap t "$1" || return 1
  shift
  timeout -k "$RESTART_KILL_AFTER" "$t" kubectl --context "$RESTART_CONTEXT" --request-timeout=20s "$@"
}

# Every gpu-fault.sh call the runner makes is cut at RESTART_GFK_CALL seconds, because --request-timeout does not bound an
# exec stream, and an injection, readback or reset into a host engine that connects and never answers would otherwise
# run past its case's slot (codex review before the full stage).
# Under restart_by it is cut at RESTART_DL as well, and refused after it, so a poll of several calls cannot outlast it.
# This file is sourced after gpu-fault.sh, so this gfk is the one its helpers call.
RESTART_GFK_CALL=60
gfk() {
  local t
  restart_cap t "$RESTART_GFK_CALL" || return 124
  timeout -k "$RESTART_KILL_AFTER" "$t" kubectl ${GF_CONTEXT:+--context "$GF_CONTEXT"} "$@"
}

# The longest a read of LATEST through a rank's mount may take, which is an exec stream too.
RESTART_LATEST_CALL=20

# restart_registered_stage: RESTART_STAGE is one whose registration names its operator and has the nightly destroy
# disabled for the session.
restart_registered_stage() {
  case "${RESTART_STAGE:-}" in retarget | corelimit) return 0 ;; esac
  return 1
}

# restart_core_limit CASE: 0 when CASE runs with core dumps off, inherited when it keeps the node's limit.
# The default list is corelimit's even rank-kill cases, interleaved with the odd ones so neither arm runs all early.
restart_core_limit() {
  local nocore=" ${RESTART_NOCORE_CASES-$([[ "${RESTART_STAGE:-}" == corelimit ]] && echo rank-kill-2 rank-kill-4 rank-kill-6)} "
  case "$nocore" in *" $1 "*) echo 0 ;; *) echo inherited ;; esac
}

# restart_launch_refusal OUT: why a session must not buy anything for this stage and evidence directory, or the reason it
# may on stdout.
# A registered stage's arms are its registration's, so an override is refused: an empty RESTART_NOCORE_CASES ran all six
# rank-kill cases untreated, the scorer accepted every one, and only H2 found it NOT ASSESSED, after the purchase
# (gpt-6-astra's attack before the corelimit run).
# The evidence directory must be new: a case's directory is made with mkdir -p and its records appended, so a reused one
# carries the last session's VOID marker and logs into the scorer, which would reject the new run after it was bought.
restart_launch_refusal() {
  if restart_registered_stage && [[ -n "${RESTART_NOCORE_CASES+set}" ]]; then
    echo "RESTART_STAGE=$RESTART_STAGE registers its own core-limit arms, and RESTART_NOCORE_CASES='$RESTART_NOCORE_CASES' would replace them; unset it"
    return 1
  fi
  if [[ -e "$1" ]]; then
    echo "$1 already exists, so its earlier records would be scored with this run's; use a new EXDIR"
    return 1
  fi
  echo "the core-limit arms are the stage's own and $1 is new"
}

# restart_operator_pin <rev> <digest>: a stage that registers one operator runs only on it.
# The gate below accepts any revision descended from the commits it needs, so a promotion between the registration and
# the launch would otherwise run a different operator unseen (codex gpt-6-astra attack of the retarget registration).
# A registered stage (restart_registered_stage) requires RESTART_OPERATOR_REV and RESTART_OPERATOR_DIGEST; other stages
# check them when given.
restart_operator_pin() {
  local rev="$1" digest="$2"
  if restart_registered_stage && [[ -z "${RESTART_OPERATOR_REV:-}" || -z "${RESTART_OPERATOR_DIGEST:-}" ]]; then
    echo "the $RESTART_STAGE stage registers its operator, so RESTART_OPERATOR_REV and RESTART_OPERATOR_DIGEST must be given"
    return 1
  fi
  if [[ -n "${RESTART_OPERATOR_REV:-}" && "$rev" != "$RESTART_OPERATOR_REV" ]]; then
    echo "the deployed revision is $rev, not the registered $RESTART_OPERATOR_REV"
    return 1
  fi
  if [[ -n "${RESTART_OPERATOR_DIGEST:-}" && "$digest" != "$RESTART_OPERATOR_DIGEST" ]]; then
    echo "the deployed revision pins $digest, not the registered $RESTART_OPERATOR_DIGEST"
    return 1
  fi
  echo "the deployed revision $rev pins $digest${RESTART_OPERATOR_REV:+, the registered operator}"
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
  if ! git merge-base --is-ancestor "$RESTART_NODE_UID_COMMIT" "$rev" 2>&1; then
    echo "the deployed revision $rev does not contain the node UID record ($RESTART_NODE_UID_COMMIT); promote it to main first"
    return 1
  fi
  expected="$(git show "$rev:config/manager/kustomization.yaml" 2>&1 | sed -n 's/^- digest: \(sha256:[0-9a-f]\{64\}\)$/\1/p' | head -1)"
  [[ -n "$expected" ]] || {
    echo "no operator digest in config/manager/kustomization.yaml at $rev"
    return 1
  }
  out="$(restart_operator_pin "$rev" "$expected")" || {
    echo "$out"
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
  out="$(restart_crd_check "$crd")" || {
    echo "$out"
    return 1
  }
  out="$(restart_render_job restart-gate-missing "$RESTART_NS" "$RESTART_QUEUE" restart-gate reference |
    python3 -c 'import json, sys; j = json.load(sys.stdin); j["spec"]["stateVolume"]["claimName"] = "no-such-claim"; print(json.dumps(j))' |
    rk apply --dry-run=server -f - 2>&1)" && {
    echo "a job naming a claim that does not exist was accepted, so the webhook that checks the claim did not run"
    return 1
  }
  restart_webhook_refused_claim "$out" || return 1
  out="$(restart_render_job restart-gate "$RESTART_NS" "$RESTART_QUEUE" restart-gate reference | rk apply --dry-run=server -f - 2>&1)" || {
    echo "a registered case's job was refused by the API server: ${out:0:300}"
    return 1
  }
  echo "operator at $rev runs $expected, the CRD has maxRestarts and nodeUIDs, and the webhook refuses a missing claim and accepts a case"
}

# restart_webhook_refused_claim OUT: OUT, a refused dry run of a job naming a missing claim, is the webhook's refusal of
# that claim; prints why not.
# Any failure of the request passed for one before, so a throttled or dropped call credited the webhook with a refusal
# it never made (gpt-6-astra's defect review of #505); the words are internal/webhook/v1/mltrainingjob_webhook.go's.
restart_webhook_refused_claim() {
  [[ "$1" == *"denied the request"* && "$1" == *"spec.stateVolume.claimName"* && "$1" == *"claim not found"* ]] && return 0
  echo "a job naming a claim that does not exist failed, but not by the webhook's refusal of the claim: ${1:0:300}"
  return 1
}

# restart_crd_check CRD_JSON: fails, naming the field, unless the deployed MLTrainingJob CRD's storage version declares
# both spec.distributed.maxRestarts and status.attempts[].nodeUIDs.
#
# A field the schema lacks is pruned from what the operator writes, so a status without nodeUIDs would leave the barrier
# on the name-only check while the run reported the UID protection as tested (codex review before the re-verification).
restart_crd_check() {
  python3 -c '
import json, sys
try:
    v = [v for v in json.loads(sys.argv[1])["spec"]["versions"] if v.get("storage")][0]
    props = v["schema"]["openAPIV3Schema"]["properties"]
except (ValueError, KeyError, IndexError, TypeError) as exc:
    sys.exit(f"the deployed MLTrainingJob CRD could not be read: {type(exc).__name__}")
spec = props.get("spec", {}).get("properties", {}).get("distributed", {}).get("properties", {})
attempt = props.get("status", {}).get("properties", {}).get("attempts", {}).get("items", {}).get("properties", {})
if "maxRestarts" not in spec:
    sys.exit("the deployed MLTrainingJob CRD has no spec.distributed.maxRestarts")
if "nodeUIDs" not in attempt:
    sys.exit("the deployed MLTrainingJob CRD has no status.attempts[].nodeUIDs, so the operator could not keep them")
' "$1" 2>&1
}

# The widest bracket a clock probe may have, score_eks.py's CLOCK_BRACKET_S: a probe wider than this is retried here,
# because the scorer would void the case whose fault it was taken for.
RESTART_CLOCK_BRACKET=0.5
RESTART_CLOCK_TRIES=3

# restart_probe_config FILE: the session's kubeconfig for RESTART_CONTEXT alone, written to FILE, with an exec
# credential plugin replaced by the token it gives now.
#
# On EKS the plugin is `aws eks get-token`, which took 0.30 to 0.32 s on the session's machine (2026-11-02) and runs
# again inside every kubectl process, so it sat inside every probe's bracket and left the 0.5 s little room.
# A token lasts 15 minutes, so one is minted for each round of probes and the file is removed after it.
restart_probe_config() {
  local file="$1" view t
  view="$(rk config view --raw --minify -o json 2>&1)" || {
    echo "could not read the kubeconfig of $RESTART_CONTEXT: ${view:0:200}" >&2
    return 1
  }
  # The plugin's own limit is cut to the deadline too, since it runs outside every kubectl the deadline bounds.
  # It is taken after the read above, which once spent the whole allowance and left the plugin a stale one (codex
  # gpt-6-astra attack of the retarget registration).
  restart_cap t 60 || return 1
  python3 -c '
import json, os, subprocess, sys
c = json.loads(sys.stdin.read())
user = c["users"][0]["user"]
plugin = user.pop("exec", None)
if plugin:
    env = dict(os.environ, **{e["name"]: e["value"] for e in plugin.get("env") or []})
    out = subprocess.run([plugin["command"], *(plugin.get("args") or [])], capture_output=True, text=True, env=env,
                         timeout=int(sys.argv[2]))
    if out.returncode != 0:
        command = plugin["command"]
        sys.exit(f"the credential plugin {command} failed: {out.stderr.strip()[:200]}")
    user["token"] = json.loads(out.stdout)["status"]["token"]
with open(sys.argv[1], "w") as f:
    json.dump(c, f)
' "$file" "$t" <<<"$view"
}

# restart_clock_probe POD NODE: one JSON line of the node's clock against this machine's.
#
# The node's time is read inside a Pod on it, between two readings of this machine's clock, so the offset is known to
# within the bracket; the scorer refuses a wide bracket or a large offset rather than subtract a clock it cannot trust.
# A probe wider than RESTART_CLOCK_BRACKET is taken again, up to RESTART_CLOCK_TRIES times, and the probe fails rather
# than return one the scorer would refuse after the fault it was taken for had been paid for.
# RESTART_PROBE_KUBECONFIG, when restart_probe_all sets it, keeps the credential plugin out of the bracket.
restart_clock_probe() {
  local pod="$1" node="$2" before after t try cap wide=""
  for ((try = 1; try <= RESTART_CLOCK_TRIES; try++)); do
    restart_cap cap 10 || {
      echo "the clock of $node was not read before the deadline" >&2
      return 1
    }
    before="$(date +%s.%N)"
    t="$(timeout -k "$RESTART_KILL_AFTER" "$cap" kubectl ${RESTART_PROBE_KUBECONFIG:+--kubeconfig "$RESTART_PROBE_KUBECONFIG"} \
      --context "$RESTART_CONTEXT" --request-timeout="${cap}s" -n "$RESTART_SYS" exec "$pod" -c exporter -- date +%s.%N 2>&1)" || {
      echo "could not read the clock of $node through $pod: ${t:0:200}" >&2
      return 1
    }
    after="$(date +%s.%N)"
    [[ "$t" =~ ^[0-9]+\.[0-9]+$ ]] || {
      echo "the clock of $node read as '${t:0:80}', not seconds" >&2
      return 1
    }
    if python3 -c 'import sys; sys.exit(0 if float(sys.argv[2]) - float(sys.argv[1]) <= float(sys.argv[3]) else 1)' \
      "$before" "$after" "$RESTART_CLOCK_BRACKET"; then
      printf '{"node": "%s", "pod": "%s", "before": %s, "node_time": %s, "after": %s}\n' "$node" "$pod" "$before" "$t" "$after"
      return 0
    fi
    wide+=" $(python3 -c 'import sys; print(f"{float(sys.argv[2]) - float(sys.argv[1]):.3f}")' "$before" "$after")"
  done
  echo "every probe of the clock of $node was wider than ${RESTART_CLOCK_BRACKET} s:${wide} s" >&2
  return 1
}

# restart_exporters: "node pod" for every Running exporter Pod on a Node the GPU group has now, the clock and fault
# path's way onto each GPU node; fails when either list cannot be read.
#
# A Pod stays listed Running for a while after its Node is deleted, so a node the group just scaled in or lost would
# otherwise be probed, fail, and void the next case before its fault, as terminate-wait-1 was on the kind rehearsal.
#
# A Pod already being deleted is left out as well, because its probe can fail for that alone (codex review before the
# full stage).
restart_exporters() {
  local nodes pods
  nodes="$(restart_gpu_nodes)" || return 1
  pods="$(rk -n "$RESTART_SYS" get pods -l app.kubernetes.io/component=dcgm-exporter --field-selector status.phase=Running \
    -o jsonpath='{range .items[*]}{.spec.nodeName}{" "}{.metadata.name}{" "}{.metadata.deletionTimestamp}{"\n"}{end}' 2>&1)" || {
    echo "could not list the exporters: ${pods:0:200}" >&2
    return 1
  }
  awk 'NR == FNR {if (NF) up[$1] = 1; next} NF == 2 && ($1 in up) {print}' <(printf '%s\n' "$nodes") <(printf '%s\n' "$pods")
}

# restart_gpu_nodes: the names of the Nodes the GPU group has now, one a line; fails when they cannot be read.
restart_gpu_nodes() {
  local nodes
  nodes="$(rk get nodes -l "eks.amazonaws.com/nodegroup=$RESTART_GROUP" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>&1)" || {
    echo "could not list the GPU nodes: ${nodes:0:200}" >&2
    return 1
  }
  printf '%s\n' "$nodes" | sed '/^$/d'
}

# restart_probe_all DIR LABEL: a probe of every GPU node's clock, appended to DIR/clock.jsonl; fails if any cannot be read,
# or if a node the group has now has no exporter to read it through.
#
# A node with no exporter listed was once simply not probed and the round passed, and the scorer then voided the case
# whose recovery used that node's clock, after its fault had been paid for (codex review before the full stage).
restart_probe_all() {
  local dir="$1" label="$2" rows node pod line fails=0 probed=0 config nodes missing
  rows="$(restart_exporters 2>&1)" || {
    echo "could not list the exporters: ${rows:0:200}" >&2
    return 1
  }
  nodes="$(restart_gpu_nodes 2>&1)" || {
    echo "could not list the GPU nodes: ${nodes:0:200}" >&2
    return 1
  }
  config="$(mktemp)" || return 1
  restart_probe_config "$config" || {
    rm -f "$config"
    return 1
  }
  local RESTART_PROBE_KUBECONFIG="$config"
  while read -r node pod; do
    [[ -n "$node" ]] || continue
    probed=$((probed + 1))
    if line="$(restart_clock_probe "$pod" "$node")"; then
      python3 -c 'import json, sys; r = json.loads(sys.argv[1]); r["when"] = sys.argv[2]; print(json.dumps(r))' "$line" "$label" >>"$dir/clock.jsonl"
    else
      fails=$((fails + 1))
    fi
  done <<<"$rows"
  rm -f "$config"
  # No exporter listed is no clock read, not every clock read.
  if ((probed == 0)); then
    echo "no exporter Pod was Running, so no node's clock was read" >&2
    return 1
  fi
  missing="$(awk 'NR == FNR {if (NF) seen[$1] = 1; next} NF && !($1 in seen) {print $1}' <(printf '%s\n' "$rows") <(printf '%s\n' "$nodes") | paste -sd' ')"
  if [[ -n "$missing" ]]; then
    echo "no exporter Pod to read the clock of $missing" >&2
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

# restart_scale_group DESIRED DEADLINE: the GPU group's desired size set to DESIRED, asked again until EKS accepts it or
# DEADLINE (on the phase_mono clock) passes.
#
# EKS refuses an update while another of the group's is still in progress (ResourceInUseException), and one refusal once
# ended the run before terminate-wait; the stubs that rehearsed it accepted every request (codex review before the full
# stage).
RESTART_SCALE_RETRY=15
restart_scale_group() {
  local desired="$1" deadline="$2" out left
  while :; do
    left=$((deadline - $(phase_mono)))
    ((left >= 1)) || {
      echo "the group was not scaled to $desired before its deadline: ${out:-not asked}"
      return 1
    }
    ((left <= 60)) || left=60
    out="$(timeout "$left" aws eks update-nodegroup-config --region "$RESTART_REGION" --cluster-name "$RESTART_CLUSTER" \
      --nodegroup-name "$RESTART_GROUP" --scaling-config "minSize=0,maxSize=3,desiredSize=$desired" 2>&1)" && return 0
    ((deadline - $(phase_mono) > RESTART_SCALE_RETRY)) || {
      echo "the group was not scaled to $desired before its deadline: ${out:0:200}"
      return 1
    }
    sleep "$RESTART_SCALE_RETRY"
  done
}

# restart_alive PID: the process exists and is not a zombie; a zombie has exited and only waits to be reaped.
restart_alive() {
  local stat
  stat="$(ps -o stat= -p "$1")" && [[ -n "$stat" && "$stat" != Z* ]]
}

# restart_descendants PID: every process below PID, one a line.
restart_descendants() {
  local child
  for child in $(ps -o pid= --ppid "$1"); do
    echo "$child"
    restart_descendants "$child"
  done
}

# restart_stop_collector PID DIR: a case's collector stopped with its log follows, and waited for, in bounded time.
#
# One TERM, then a wait, was the whole stop, and a TERM can be lost: in the check suite a collector looping through its
# command substitutions outlived its TERM for 94 minutes and exited at once on a second one, which in a paid run would
# have held the session with its GPUs until the deadline (2026-11-03, bash 5.3.9).
# So TERM is sent again each second, and after ten the collector and everything below it is killed outright.
RESTART_STOP_TRIES=10
restart_stop_collector() {
  local pid="$1" log="$2/case.log" tree try p
  tree="$(restart_descendants "$pid")"
  for ((try = 1; try <= RESTART_STOP_TRIES; try++)); do
    restart_alive "$pid" || break
    kill -TERM "$pid" 2>>"$log"
    sleep 1
  done
  if restart_alive "$pid"; then
    echo "the collector $pid outlived $RESTART_STOP_TRIES TERMs and was killed" >>"$log"
    tree="$tree $(restart_descendants "$pid")"
    kill -KILL "$pid" 2>>"$log"
  fi
  wait "$pid" 2>>"$log"
  for p in $tree; do
    if restart_alive "$p"; then kill -KILL "$p" 2>>"$log"; fi
  done
  return 0
}

# restart_ranks_stepped DIR [ATTEMPT]: how many distinct ranks have recorded a step, in ATTEMPT when it is given.
#
# Ranks, not records: a log stream read again from its start repeats its records, and two of one rank's once read as
# both ranks having stepped (codex review before the full stage).
restart_ranks_stepped() {
  restart_records "$1" | python3 -c '
import json, sys
want = sys.argv[1] if len(sys.argv) > 1 else None
ranks = set()
for line in sys.stdin:
    r = json.loads(line)
    if r.get("event") == "step" and (want is None or str(r.get("attempt")) == want):
        ranks.add(r.get("rank"))
print(len(ranks))' ${2:+"$2"}
}

# restart_read_latest POD JOB_ID: the step LATEST names on the volume, read through a rank's own mount.
restart_read_latest() {
  local latest
  latest="$(rkt "$RESTART_LATEST_CALL" -n "$RESTART_NS" exec "$1" -- cat "$RESTART_MOUNT/$2/LATEST" 2>&1)" || {
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
  local pod="$1" job_id="$2" dir="$3" wait="$4" deadline=$(($(phase_mono) + $4)) latest="" high
  while (($(phase_mono) < deadline)); do
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
# fault on rank 1's node, delivered only if the last read before it still finds the window open; 0 when it was
# delivered, 3 when whether it was is unknown, and 1 otherwise.
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
    out="$(restart_deadline_ok $((slot_dl - $(phase_mono) + RESTART_REPLENISH_BUDGET + RESTART_WARM_BUDGET)))" || {
      echo "$out"
      return 1
    }
  fi
  if last="$(restart_fault_recheck "$pod0" "$job_id" "$dir" "$name")"; then
    if [[ "$kind" == dcgm ]]; then
      restart_by "$run_dl" restart_dcgm_fault "$node1" "$dir"
    else
      restart_terminate_and_fence "$instance" "$node1" "$name" "$dir" $((run_dl - $(phase_mono)))
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
#
# Every timestamp here asks date for %N, never %6N: uutils date 0.8.0, the date of the machine the paid session runs from,
# prints %6N as the whole nanosecond count without its leading zeros, which read a mark at .078 s as .78 s.
restart_mark() {
  printf '{"at": "%s", "mark": "%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)" "$2" >>"$1/marks.jsonl"
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
  deadline=$(($(phase_mono) + wait))
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
    if (($(phase_mono) >= deadline)); then
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
# The caller runs it under restart_by with the case's deadline, which bounds the injection's exec as well as the reads
# after it, because a request timeout does not end an exec stream and a host engine that never answers held the plain
# rk exec this replaced until the session's teardown.
# A cut injection may or may not have reached the host engine, so it is never taken for either: the case is marked
# fault-unknown, returns 3 for its caller to void, and the node is reset at once so nothing after it runs on a card that
# might be latched.
restart_dcgm_fault() {
  local node="$1" dir="$2" out t rb rc latched=false tainted=false
  [[ "${GF_TARGET:-}" == "$node" && -n "${GF_POD:-}" ]] || {
    echo "the fault path is not pointed at $node; restart_gf_env comes first"
    return 1
  }
  restart_mark "$dir" "fault-start"
  out="$(rkt "$RESTART_GFK_CALL" -n "$RESTART_SYS" exec "$GF_POD" -c hostengine -- sh -c \
    "date +%s.%N; dcgmi test --inject --gpuid 0 -f 230 -v 79 --offset $GF_OFFSET_S" 2>&1)" || {
    rc=$?
    if ((rc == 124 || rc == 137)); then
      restart_mark "$dir" "fault-unknown"
      echo "the injection on $node was cut (exit $rc), so whether XID 79 reached its host engine is unknown: ${out:0:200}"
      if restart_dcgm_reset "$node" "$dir" "${RESTART_DL:-$(($(phase_mono) + RESTART_RESET_BUDGET))}" >>"$dir/case.log" 2>&1; then
        echo "$node was reset after the cut injection"
      else
        echo "$node could not be reset after the cut injection; the reset after the case tries again"
      fi
      return 3
    fi
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

# restart_dcgm_reset NODE DIR DEADLINE: the baseline injected and the node seen clear and untainted, as gf_reset does,
# all of it by DEADLINE (on the phase_mono clock).
#
# The lookup, the injection and the 120 s wait were each bounded on their own, and the wait's check makes up to four
# calls and runs once more after the wait ends, so the reset could take far past the RESTART_RESET_BUDGET it is charged.
restart_dcgm_reset() {
  restart_by "$3" restart_dcgm_reset_by "$1" "$2"
}

restart_dcgm_reset_by() {
  local node="$1"
  restart_gf_env "$node" "$2" || return 1
  gf_inject 230 0 >>"$RESTART_OUT/dcgm-reset.log" 2>&1 || {
    echo "injecting the baseline into $node failed"
    return 1
  }
  gf_wait_until 120 gf_is_clear || {
    echo "$node did not read clear and untainted within 120 s of the baseline or by the reset's deadline"
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
  # A wait that outlasts one request goes through rkt with its own duration; rk is cut at 20 s.
  out="$(rkt 310 -n "$RESTART_SYS" rollout status "$dep" --timeout=300s 2>&1)" || {
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
  # gpu-fault.sh's kubectl calls carry no timeout of their own, and a polling deadline only bounds the gaps between
  # them, so for this gate each call is cut at what is left of WAIT and the gate cannot eat into the cases' time.
  restart_by $(($(phase_mono) + $1)) restart_fault_path_check "$1"
}

# restart_fault_path_check WAIT: restart_fault_path_ready's checks, with gfk already bounded.
restart_fault_path_check() {
  local deadline=$(($(phase_mono) + $1)) nodes node metrics f missing out left err last=""
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
    # An exporter is waited for within the budget, not read once: on a node that has just joined its Pod can still be
    # starting, or its host engine not yet answering, and one read would end a session whose GPUs were already bought.
    while :; do
      err=""
      # In this shell and not a command substitution, which would lose the GF_POD it exports and scrape the last node's.
      if ! restart_gf_env "$node" "$RESTART_OUT" >>"$RESTART_OUT/fault-path.log"; then
        err="no single exporter Pod on $node: $GF_POD"
      elif ! metrics="$(gf_metrics 2>&1)"; then
        err="the exporter on $node could not be scraped: ${metrics:0:200}"
      else
        missing=""
        for f in 230 311 310; do
          grep -q "^${GF_FIELD_NAME[$f]}{" <<<"$metrics" || missing="$missing ${GF_FIELD_NAME[$f]}"
        done
        [[ -z "$missing" ]] || err="the exporter on $node serves no$missing"
      fi
      [[ -n "$err" ]] || break
      # The read that meets the deadline only says so, and the reason the exporter was not ready is the one before it.
      [[ "$err" == *"deadline has passed"* ]] || last="$err"
      ((deadline - $(phase_mono) > RESTART_POLL)) || {
        echo "${last:-$err}"
        return 1
      }
      sleep "$RESTART_POLL"
    done
    left=$((deadline - $(phase_mono)))
    # A floor of one second here once let a gate whose budget was gone still pass, a second at a time per node.
    ((left >= 1)) || {
      echo "the fault path check ran out of its ${1} s before the NodeHealth of $node was read"
      return 1
    }
    gf_wait_until "$left" gf_is_clear || {
      echo "the NodeHealth of $node did not read a fresh, healthy GPU signal on an untainted node by the deadline"
      return 1
    }
  done <<<"$nodes"
  echo "the operator runs with ${RESTART_FAULT_FLAGS[*]}, and every GPU node's exporter serves the fault fields and its NodeHealth reads a fresh, healthy signal"
}

# restart_prepare_nodes WARMED_FILE DEADLINE: a NodeHealth and a warm-up for every GPU node not yet prepared, all
# finished by DEADLINE (on the phase_mono clock).
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
    pod="$(restart_warm_start "$node" "$uid")" || {
      failed="$pod"
      break
    }
    warming+=("$node $uid $pod")
  done <<<"$nodes"
  for entry in "${warming[@]}"; do
    read -r node uid pod <<<"$entry"
    if [[ -z "$failed" ]]; then
      left=$((deadline - $(phase_mono)))
      ((left >= 1)) || left=1
      if out="$(rkt $((left + 10)) -n "$RESTART_NS" wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$pod" --timeout="${left}s" 2>&1)"; then
        echo "$node $uid" >>"$warmed"
        printf '{"node": "%s", "uid": "%s", "prepared_at": "%s"}\n' "$node" "$uid" "$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)" >>"$RESTART_OUT/nodes-prepared.jsonl"
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

# restart_warm_start NODE UID: a Pod on NODE, with no GPU, that imports torch from the pinned image and writes and reads
# the shared volume, so that node's first pull and first mount are not inside a measured recovery; prints the Pod's name.
#
# The name is a hash of the node's name and UID, not a piece of the name: EKS names every node
# ip-<address>.<region>.compute.internal, and the last 20 characters were the same for all three nodes of the first paid
# smoke session, whose second warm-up was then refused as an update of the first's Pod.
# The UID makes a replacement that reuses a name a new Pod, not the old one still terminating.
restart_warm_start() {
  local node="$1" uid="$2" pod out
  pod="rst-warm-$(printf '%s %s' "$node" "$uid" | sha256sum | cut -c1-16)"
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
  # Running jobs only: every case's collector.log held one "No such process" from a follow already ended, an error line
  # nothing was wrong behind (gpt-6-astra's defect review of #505).
  # shellcheck disable=SC2046  # word splitting of the pid list is intended
  trap 'set -- $(jobs -pr); (($# == 0)) || kill "$@" 2>>"$dir/collector.log"; exit 0' TERM
  # Every change to the case's Pods as the API server sent it, apart from the log streams: a container's status was read
  # only when its stream ended, and a Pod deleted before that read left no exit code or finish time, which is the
  # surviving rank's end H2 reads beside its verdict (gpt-6-astra's attack before the corelimit run, kind run f).
  # A watch also carries deletionGracePeriodSeconds, without which deletionTimestamp, the request plus the grace, reads
  # as the request.
  # The watch is opened again when the API server ends it, with no request timeout, as the follows are.
  # A new watch lists afresh and nothing carries over, so each one is marked where it begins: a change between two
  # watches is lost, and h2_corelimit.py reads a deletion request only where one watch saw the Pod before and after it
  # (gpt-6-astra's second attack before the corelimit run).
  (
    trap 'set -- $(jobs -pr); (($# == 0)) || kill "$@" 2>>"$dir/collector.log"; exit 0' TERM
    while :; do
      # On a line of its own, so a watch cut mid-object cannot swallow the mark that ends it (gpt-6-astra's third attack).
      printf '\n{"type": "WATCH-OPENED", "at": "%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)" >>"$dir/pod-watch.json"
      kubectl --context "$RESTART_CONTEXT" -n "$RESTART_NS" get pods -l "platform.lkhun9311.github.io/mltrainingjob=$name" \
        --watch --output-watch-events -o json >>"$dir/pod-watch.json" 2>>"$dir/collector.log" &
      wait $!
      sleep 1
    done
  ) &
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
        "$uid" "$pod" "$node" "$index" "$token" "$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)" >>"$dir/pods.jsonl"
      (
        local n=0 follow="" rc began ended podj row
        # The follow runs in the background and is waited for, so stopping this reader stops it too: with no request
        # timeout a follow of a Pod on a dead node would otherwise outlive the case (codex review of bf0ea420).
        trap 'set -- $(jobs -pr); (($# == 0)) || kill "$@" 2>>"$dir/collector.log"; exit 0' TERM
        while :; do
          n=$((n + 1))
          # No request timeout, unlike rk: kubectl's 20 s cut every follow, so each Pod's log was read again from its start
          # every 20 s and the 20 reads allowed below ended at about 400 s of the Pod's life (the kind rehearsal).
          began=$(phase_mono)
          kubectl --context "$RESTART_CONTEXT" -n "$RESTART_NS" logs -f "$pod" >"$dir/log-$uid.$n.txt" 2>>"$dir/collector.log" &
          follow=$!
          wait "$follow"
          rc=$?
          ended="$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)"
          # The container as the stream ended, recorded with it: one still running can have outlived its stream's end, so
          # score_eks.py counts no lost steps from that log; one that ended keeps its exit and its times, and a Pod being
          # deleted its deletion's, which nothing else collected (gpt-6-astra's defect review of #505).
          # A Pod that is gone reads as empty, not as an error; a read that failed is recorded as unread.
          podj="$(rk -n "$RESTART_NS" get pod "$pod" --ignore-not-found -o json 2>>"$dir/collector.log")" || podj=unread
          row="$(python3 -c '
import json, sys
uid, n, rc, at, raw = sys.argv[1:6]
row = {"uid": uid, "stream": int(n), "exit": int(rc), "at": at}
if raw == "unread":
    row["container"] = "unread"
elif not raw.strip():
    row["container"] = "gone"
else:
    p = json.loads(raw)
    st = ((p.get("status") or {}).get("containerStatuses") or [{}])[0].get("state") or {}
    t = st.get("terminated")
    row["container"] = "running" if "running" in st else "terminated" if t else "waiting" if "waiting" in st else "unknown"
    if t:
        row.update(exit_code=t.get("exitCode"), reason=t.get("reason"), started_at=t.get("startedAt"), finished_at=t.get("finishedAt"))
    # deletionTimestamp is the request plus the grace the API server gave it, so the grace is kept beside it.
    if (p.get("metadata") or {}).get("deletionTimestamp"):
        row["deletion"] = p["metadata"]["deletionTimestamp"]
        row["deletion_grace_s"] = p["metadata"].get("deletionGracePeriodSeconds")
print(row["container"], json.dumps(row))' "$uid" "$n" "$rc" "$ended" "$podj" 2>>"$dir/collector.log")" ||
            row="unread {\"uid\": \"$uid\", \"stream\": $n, \"exit\": $rc, \"at\": \"$ended\", \"container\": \"unread\"}"
          printf '%s\n' "${row#* }" >>"$dir/streams.jsonl"
          # A stream that ended at once is paused after, so twenty that fail in a row span more than a second of the case
          # (codex review before the full stage).
          (($(phase_mono) - began >= 2)) || sleep 2
          ((n < 20)) || break
          # A stream that ended with its container is complete; one that ended while it runs is read again in full.
          # A read of the container that failed says neither, so the log is read again after a pause: taking it for the
          # end once stopped a Pod's records for good after one API error (codex review before the full stage).
          case "${row%% *}" in
            running) ;;
            unread) sleep 2 ;;
            *) break ;;
          esac
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
  local name="$1" wait="$2" deadline=$(($(phase_mono) + $2)) left="not polled before the deadline" mltj jobs pods
  rkd "$deadline" -n "$RESTART_NS" delete mltrainingjob "$name" --ignore-not-found --wait=false >>"$RESTART_OUT/retire.log" 2>&1
  while (($(phase_mono) < deadline)); do
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
  out="$(rkt 610 -n "$RESTART_NS" wait --for=condition=Ready pod/rst-reader --timeout=600s 2>&1)" || {
    echo "the reader Pod was not Ready within 600 s: ${out:0:200}"
    return 1
  }
  echo "the reader Pod mounts the volume on the CPU node"
}

# restart_wait_group WANT WAIT: exactly WANT nodes in the group, every one qualified, none tainted by the fault path.
#
# train_qualify_nodes refuses a group holding more nodes than asked for, which is right at purchase and wrong while a
# scale-in is still removing one, so the count is waited for first.
#
# The count can move again between that read and the qualification: before terminate-wait-1 the scale-in to two starts
# while terminate-spare-2's replacement may still be joining, and the qualification then saw three and ended the run with
# most of its wait unspent (codex review before the full stage); a count above the one asked for is waited out again.
restart_wait_group() {
  local want="$1" wait="$2" deadline=$(($(phase_mono) + $2)) n="" ids tainted
  while :; do
    while (($(phase_mono) < deadline)); do
      n="$(rkd "$deadline" get nodes -l "eks.amazonaws.com/nodegroup=$RESTART_GROUP" -o name 2>&1 | grep -c '^node/')"
      ((n == want)) && break
      sleep "$RESTART_POLL"
    done
    ((n == want)) || {
      echo "the group held $n node(s), not $want, within ${wait}s"
      return 1
    }
    # What is left of the deadline and no more: a floor here would let the qualification run past the share it was given.
    # train-session.sh's own kubectl calls carry only a request timeout, which a hanging credential helper outlasts, so
    # inside this substitution kubectl is the same deadline-cut call as rk (codex gpt-6-astra attack of the retarget
    # registration, which held a qualification past its deadline with a sleeping kubectl).
    ids="$(
      kubectl() { restart_bounded_kubectl "$@"; }
      restart_by "$deadline" train_qualify_nodes "$RESTART_CONTEXT" "$RESTART_GROUP" "$want" $((deadline - $(phase_mono) > 1 ? deadline - $(phase_mono) : 1)) 1
    )" && break
    [[ "$ids" == *"nodes in the group, want $want"* ]] && ((deadline - $(phase_mono) > RESTART_POLL)) || {
      echo "$ids"
      return 1
    }
    echo "the group moved past $want during its qualification ($ids); waiting for it again" >>"$RESTART_OUT/run.log"
    sleep "$RESTART_POLL"
  done
  awk '{print $2}' <<<"$ids" >>"$RESTART_INSTANCES_FILE"
  # Read first and filtered after, because a failed read piped into the filter came out as "no node tainted".
  tainted="$(rkd $(($(phase_mono) + 20)) get nodes -l "eks.amazonaws.com/nodegroup=$RESTART_GROUP" -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.taints[*].key}{"\n"}{end}' 2>&1)" || {
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

# restart_sampling NAME DIR DEADLINE: restart_sample every RESTART_POLL, in the background, until DIR/sampling.stop
# exists or DEADLINE (on the phase_mono clock) passes.
#
# The probes before a fault, the wait for its window and the injection each hold the case's own loop for seconds, and
# the DCGM cases' samples jumped 25 s across their triggers, so the collector's bracket of a 2 s stop was 31 s wide
# (gpt-6-astra's defect review of #505).
restart_sampling() {
  while [[ ! -e "$2/sampling.stop" ]] && (($(phase_mono) < $3)); do
    restart_by "$3" restart_sample "$1" "$2"
    sleep "$RESTART_POLL"
  done
}

# restart_sampling_stop DIR: the sampler restart_run_case started, if one runs, asked to stop and waited for; it ends
# after its current sample, which restart_by bounds by the case's deadline.
restart_sampling_stop() {
  [[ -n "${RESTART_SAMPLER:-}" ]] || return 0
  : >"$1/sampling.stop"
  wait "$RESTART_SAMPLER" || :
  RESTART_SAMPLER=""
  rm -f "$1/sampling.stop"
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
# Each line is LABEL, when it was asked, then the datapoint's own minute and its value: CloudWatch publishes late, and
# with the minute dropped, two reads of one stale datapoint passed for a balance before and after a case (gpt-6-astra's
# defect review of #505).
restart_efs_credits() {
  local v t
  if restart_cap t 20; then
    v="$(timeout -k "$RESTART_KILL_AFTER" "$t" aws cloudwatch get-metric-statistics --region "$RESTART_REGION" --namespace AWS/EFS --metric-name BurstCreditBalance \
      --dimensions "Name=FileSystemId,Value=$RESTART_FS_ID" --start-time "$(date -u -d '-15 min' +%Y-%m-%dT%H:%M:%SZ)" \
      --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --period 60 --statistics Minimum \
      --query 'sort_by(Datapoints, &Timestamp)[-1].[Timestamp, Minimum]' --output text 2>&1)" && v="$(tr '\t' ' ' <<<"$v")" ||
      v="unread: ${v:0:120}"
  else
    v="unread: the deadline had passed"
  fi
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
  restart_sampling_stop "$dir"
  echo "$6" >"$dir/VOID"
  restart_sample "$name" "$dir"
  rk -n "$RESTART_NS" get mltrainingjob "$name" -o json >"$dir/final-mltj.json" 2>>"$dir/case.log"
  rk get nodes -o json >"$dir/nodes-after.json" 2>>"$dir/case.log"
  [[ -z "$collector" ]] || restart_stop_collector "$collector" "$dir"
  restart_retire "$name" $((retire_dl - $(phase_mono))) >>"$dir/case.log" || {
    echo "retirement of the VOID case $name was not confirmed; its files are left on the volume and nothing more may start" >>"$dir/case.log"
    restart_read_shared "$dir" "$job_id"
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

# restart_read_shared DIR JOB_ID: the case's NCCL logs copied into DIR/nccl and its files listed, both read-only.
#
# An unretired case is read this way too: its logs were once left on the volume with it, and score_eks.py then voided a
# case that had recovered for having no NCCL log, a reason that named the transport when only the copy was missing
# (the kind rehearsal).
#
# Fails when either end of the copy or the listing failed, so the caller can tell a read from an attempt at one.
restart_read_shared() {
  local dir="$1" job_id="$2" copied
  mkdir -p "$dir/nccl"
  rkt 30 -n "$RESTART_NS" exec rst-reader -- tar -C "$RESTART_MOUNT/$job_id" -cf - nccl 2>>"$dir/case.log" | tar -C "$dir" -xf - 2>>"$dir/case.log"
  copied=("${PIPESTATUS[@]}")
  if [[ "${copied[0]}" != 0 || "${copied[1]}" != 0 ]]; then
    echo "the NCCL logs of $job_id were not copied (exec ${copied[0]}, untar ${copied[1]})" >>"$dir/case.log"
    restart_list_shared "$dir" "$job_id"
    return 1
  fi
  restart_list_shared "$dir" "$job_id" || {
    echo "the files of $job_id were not listed" >>"$dir/case.log"
    return 1
  }
}

# restart_case_files DIR JOB_ID: a retired case's NCCL logs copied, its files listed, and its directory deleted only
# when both were read.
#
# A copy that failed and was followed by the delete left the scorer nothing to read and the volume nothing to read again
# (codex review before the full stage), so a failed read leaves the files on the volume, which the next case never
# touches, since every case has its own job ID.
# Three calls of at most 30 s, and the verdict's 30 s after the reset, are RESTART_FILES_BUDGET.
restart_case_files() {
  restart_read_shared "$1" "$2" || {
    echo "the files of $2 are left on the volume because they were not read" >>"$1/case.log"
    return 1
  }
  rkt 30 -n "$RESTART_NS" exec rst-reader -- rm -rf "$RESTART_MOUNT/$2" >>"$1/case.log" 2>&1
}

# restart_evidence DIR NAME COLLECTOR RUN_DEADLINE PROBED: a case's evidence after its run, inside the
# RESTART_EVIDENCE_BUDGET past RUN_DEADLINE (on the phase_mono clock) that restart_gpu_budget charges for it; the clocks are probed
# unless PROBED says they were.
#
# Every call was bounded on its own, and three nodes of three 10 s probes each, a 60 s credential plugin and the reads
# added up to more than twice the share, so the probes end RESTART_PROBE_SHARE past the run's deadline, the reads end
# where only the pause and the collector's stop are left, and every call inside either is bounded by its end or refused.
restart_evidence() {
  local dir="$1" name="$2" collector="$3" run_dl="$4"
  local reads_dl=$((run_dl + RESTART_EVIDENCE_BUDGET - RESTART_STOP_RESERVE))
  [[ -n "$5" ]] || restart_by $((run_dl + RESTART_PROBE_SHARE)) restart_probe_all "$dir" after ||
    echo "a clock probe at the end failed" >>"$dir/case.log"
  restart_by "$reads_dl" rk -n "$RESTART_NS" get mltrainingjob "$name" -o json >"$dir/final-mltj.json" 2>>"$dir/case.log"
  restart_by "$reads_dl" rk get nodes -o json >"$dir/nodes-after.json" 2>>"$dir/case.log"
  restart_by "$reads_dl" restart_efs_credits "$dir" after
  sleep "$RESTART_EVIDENCE_PAUSE"
  restart_stop_collector "$collector" "$dir"
}

# restart_run_case CASE SLOT_DEADLINE: one registered case, from submission to its retirement, inside the slot
# restart_run gave it, which ends at SLOT_DEADLINE (on the phase_mono clock); 0 when it ran (whatever its verdict), 1 when it could
# not be run and is VOID, 2 when its retirement or its DCGM reset was not confirmed and nothing more may start.
#
# The retirement's deadline is counted back from the slot's end, past the files and the reset, so a run or an evidence
# read that ran long takes from the retirement's share and never pushes the files or the reset past the slot.
restart_run_case() {
  local case="$1" slot_dl="$2" kind="${1%-[0-9]*}" name dir job_id deadline collector rank0 rank1 node1 pod0 rc window out probed="" held
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
  deadline=$(($(phase_mono) + RESTART_CASE_BUDGET))
  restart_collect "$dir" "$name" &
  collector=$!
  printf '{"kind": "%s", "name": "%s", "job_id": "%s", "core_limit": "%s", "target": {}}\n' "$kind" "$name" "$job_id" "$(restart_core_limit "$case")" >"$dir/case.json"

  # Both ranks have recorded a step before any clock is probed or any fault is injected.
  while (($(phase_mono) < deadline)); do
    restart_sample "$name" "$dir"
    [[ "$(restart_ranks_stepped "$dir")" -ge 2 ]] && break
    sleep "$RESTART_POLL"
  done
  # From here to the loop after the fault, the status is sampled in the background, since nothing between samples here.
  restart_sampling "$name" "$dir" "$deadline" &
  RESTART_SAMPLER=$!
  # A fault whose nodes' clocks were not read before it cannot be placed on the runner's clock, and the scorer would void
  # the case after the fault had cost a node, so the case is VOID before its fault and retired instead.
  # The reference has no fault and no recovery to time, so for it a failed probe is only logged.
  # Under the case's deadline, which the sampling above may already have spent: a probe started after it once got a
  # fresh allowance of its own (codex gpt-6-astra attack of the retarget registration).
  if ! out="$(restart_by "$deadline" restart_probe_all "$dir" before 2>&1)"; then
    if [[ "$kind" != reference ]]; then
      # Only an external fault is held back by this: a rank-kill's trainer kills itself at its own step, and may already
      # have, so the reason says which (codex gpt-6-astra attack of the retarget registration).
      case "$kind" in
        dcgm | terminate-*) held="so nothing was injected" ;;
        *) held="and the trainer's own fault is not held back by that, so it may have fired" ;;
      esac
      restart_void_case "$dir" "$name" "$job_id" "$collector" "$retire_dl" "VOID-before-fault: a clock probe before the fault failed, $held: ${out:0:200}"
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
    window="$(restart_fault_window "$pod0" "$job_id" "$dir" $((deadline - $(phase_mono))))" || {
      restart_void_case "$dir" "$name" "$job_id" "$collector" "$retire_dl" "no fault window: $window"
      return
    }
    out="$(restart_external_fault "$kind" "$dir" "$name" "$job_id" "$pod0" "$node1" "$window" "$deadline" "$slot_dl")"
    rc=$?
    echo "$out" >>"$dir/case.log"
    # A cut injection is VOID in its own words, since "not delivered" would claim what nothing showed.
    if ((rc == 3)); then
      echo "the fault's delivery is unknown: $out" >"$dir/VOID"
    elif ((rc != 0)); then
      echo "the fault was not delivered: $out" >"$dir/VOID"
    fi
  fi
  restart_sampling_stop "$dir"

  # Until the job ends or the budget does; the clocks are probed again once both ranks of attempt 2 have stepped.
  # Each read here is bounded by the run's deadline, and the probe by the probes' share past it, so a read that starts
  # just before the deadline cannot carry the run into the evidence's share.
  while (($(phase_mono) < deadline)); do
    restart_by "$deadline" restart_sample "$name" "$dir"
    if [[ -z "$probed" ]] && [[ "$(restart_ranks_stepped "$dir" 2)" -ge 2 ]]; then
      restart_by $((deadline + RESTART_PROBE_SHARE)) restart_probe_all "$dir" after ||
        echo "a clock probe after the recovery failed" >>"$dir/case.log"
      probed=1
    fi
    case "$(restart_by "$deadline" restart_status "$name" "s.get('phase')")" in Succeeded | Failed) break ;; esac
    sleep "$RESTART_POLL"
  done
  restart_evidence "$dir" "$name" "$collector" "$deadline" "$probed"

  # The writers are stopped before their files are copied and deleted.
  # A case whose retirement cannot be confirmed may still be writing and still hold GPUs and quota, so its files stay on
  # the volume and the run stops (codex review of 830f64af).
  # Their NCCL logs and listing are still read, read-only, so the scorer is not left without them.
  restart_retire "$name" $((retire_dl - $(phase_mono))) >>"$dir/case.log" || {
    echo "retirement of $name was not confirmed; its files are left on the volume" >>"$dir/case.log"
    restart_read_shared "$dir" "$job_id"
    return 2
  }
  restart_case_files "$dir" "$job_id"
  if [[ "$kind" == dcgm && -n "${node1:-}" ]]; then
    # A node left latched is a node the next case cannot use, so the run stops rather than measure accumulated damage.
    # Its deadline is the slot's end less the verdict's call, the one share of the slot that comes after it.
    restart_dcgm_reset "$node1" "$dir" $((slot_dl - RESTART_VERDICT_CALL)) >>"$dir/case.log" 2>&1 || {
      echo "the DCGM reset of $node1 failed" >>"$dir/case.log"
      return 2
    }
  fi
  return 0
}

# restart_verdict CASE: the scorer's verdict on one case of the run so far: ACCEPTED, FAILED, VOID or NOTRUN.
# It succeeds when the scorer named the case, whatever the scorer's status: the scorer exits 1 once any case of the run
# is not ACCEPTED, and under pipefail that status discarded a verdict already printed (bare codex review of #505).
# A scorer cut by its timeout or refusing the run names no case, and that is still a failure.
restart_verdict() {
  local v
  v="$(timeout "$RESTART_VERDICT_CALL" python3 experiments/distributed-restart/score_eks.py --partial "$RESTART_OUT" 2>>"$RESTART_OUT/score.log" |
    awk -v c="$1" '$2 == c || $2 == c ":" {print $1; exit}')" || :
  [[ -n "$v" ]] || return 1
  echo "$v"
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
    slot_dl=$(($(phase_mono) + slot))
    pre_dl=$(($(phase_mono) + $(restart_pre_seconds "$case" "$prev")))
    # After a termination the warm-up of the replacement has its own share, which the group's wait may not take.
    reserve=0
    [[ "${prev%-[0-9]*}" != terminate-* ]] || reserve="$RESTART_WARM_BUDGET"
    prev="$case"
    # No slot starts that the GPU deadline cannot cover whole: the deadline fires once, and a replacement the group
    # launches on its own after it would run with none (A20, B7).
    # Each step of the loop runs in a paid phase, a cgroup killed whole at its deadline, so no call, credential helper or
    # descendant inside it can hold the slot past it (docs/superpowers/specs/2026-11-05-paid-phase-supervisor-design.md).
    out="$(paid_phase deadline-ok "$pre_dl" restart_deadline_ok "$slot")" || {
      stop="$out"
      restart_notrun "$case" "$stop"
      continue
    }
    # terminate-wait runs with no spare: the group at two, so attempt 2 can only start on a replacement.
    # The slot's deadline check above comes first: after the one-shot deadline has fired, any desired size above zero is
    # a purchase with no deadline behind it (codex review of 830f64af).
    if [[ "$kind" == terminate-wait && "$want" == 3 ]]; then
      want=2
      out="$(paid_phase scale-two "$pre_dl" restart_scale_group 2 "$pre_dl")" || {
        stop="the group could not be scaled to two for terminate-wait: ${out:0:200}"
        restart_notrun "$case" "$stop"
        continue
      }
    fi
    # Each under its deadline as a whole, so a create or delete inside it is refused once the deadline has passed and
    # not only the waits that are given it (codex gpt-6-astra attack of the retarget registration).
    out="$(paid_phase wait-group $((pre_dl - reserve)) restart_by $((pre_dl - reserve)) restart_wait_group "$want" $((pre_dl - reserve - $(phase_mono))))" &&
      out="$(paid_phase prepare "$pre_dl" restart_by "$pre_dl" restart_prepare_nodes "$warmed" "$pre_dl")" || {
      stop="before $case: $out"
      restart_notrun "$case" "$stop"
      continue
    }
    paid_phase "case-$case" "$slot_dl" restart_run_case "$case" "$slot_dl"
    rc=$?
    if ((rc == 124 || rc == 125)); then
      # Killed at its slot's end, or never started in its cgroup: what it wrote may be partial and its job may still run,
      # so it is VOID, never scored from what it left, and nothing more starts.
      mkdir -p "$RESTART_OUT/$case"
      echo "the case's phase ended with status $rc before the case did; its evidence is incomplete and its retirement unconfirmed" >>"$RESTART_OUT/$case/VOID"
      stop="$case did not finish inside its slot, so its job may still hold GPUs; see $RESTART_OUT/$case/case.log"
      verdict=VOID
    else
      # Its own call's share, as before the phase: a case may end at its slot's end and still be scored.
      verdict="$(paid_phase "verdict-$case" $(($(phase_mono) + RESTART_VERDICT_CALL + 5)) restart_verdict "$case")" || verdict=""
    fi
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
