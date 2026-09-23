#!/usr/bin/env bash
# Submit the two-rank gloo DDP job through MLTrainingJob and collect what it proves.
#
# See experiments/cpu-ddp/README.md for why this runs two ranks inside one Pod rather than two Pods.
#
# Usage:
#   hack/cpu-ddp.sh queue                 # create the namespace, ClusterQueue and LocalQueue
#   hack/cpu-ddp.sh run <name>            # submit one run and collect its evidence
#   hack/cpu-ddp.sh quota                 # two jobs against a one-GPU queue; the second must wait
#   hack/cpu-ddp.sh teardown              # remove the queue objects and the namespace
#
# Environment:
#   CONTEXT       kube context                         (default kind-platform)
#   EXDIR         where evidence is written            (default ex/cpu-ddp-<UTC timestamp>)
#   STEPS         training steps                       (default 3)
#   NO_SYNC       1 to disable gradient sync (control) (default unset)
#   DIE_AT_STEP   step at which rank 1 SIGKILLs itself (default 0, never)
#   HOLD_SECONDS  seconds the holder keeps the GPU in `quota`  (default 60)
#   WAIT_SECONDS  how long to wait for a terminal phase        (default 1500)

set -euo pipefail

# Job control, so a backgrounded pipeline can be killed as a group. Same reason as hack/argocd-selfheal.sh.
set -m

CONTEXT="${CONTEXT:-kind-platform}"
NS=cpu-ddp
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCKDIR="${LOCKDIR:-/tmp/cpu-ddp.lock}"
STEPS="${STEPS:-3}"
HOLD_SECONDS="${HOLD_SECONDS:-60}"
# Long enough to outlast a Job's own retry budget.
#
# The first version waited 600s. A run whose rank is SIGKILLed exhausts backoffLimit=6 over about 10m46s,
# so the runner gave up 42 seconds before Kubernetes attached the Failed condition -- and recorded the CR
# as stuck in Admitted with the quota apparently still held. Both readings were artefacts of the deadline:
# re-read afterwards, the CR was Failed and the ClusterQueue was back to zero. A timeout shorter than the
# system's own retry budget does not measure a hang, it manufactures one.
WAIT_SECONDS="${WAIT_SECONDS:-1500}"

k() { kubectl --context "$CONTEXT" "$@"; }

say() { printf '%s  %s\n' "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" "$*" | tee -a "$EXDIR/run.log"; }

# One runner at a time.
#
# Two runs sharing an evidence directory produced a duplicated row in the sibling experiment and it read as a
# measurement rather than as damage. mkdir is atomic; a check-then-create is not.
acquire_lock() {
  if mkdir "$LOCKDIR" 2>/dev/null; then
    echo $$ >"$LOCKDIR/pid"
    LOCK_HELD=1
    return 0
  fi
  local owner
  owner="$(cat "$LOCKDIR/pid" 2>/dev/null || true)"
  if [[ -n "$owner" ]] && kill -0 "$owner" 2>/dev/null; then
    echo "another run (pid $owner) holds $LOCKDIR" >&2
    exit 1
  fi
  echo "removing a stale lock left by pid ${owner:-unknown}" >&2
  rm -rf "$LOCKDIR"
  mkdir "$LOCKDIR" || { echo "could not take $LOCKDIR" >&2; exit 1; }
  echo $$ >"$LOCKDIR/pid"
  LOCK_HELD=1
}

release_lock() {
  [[ "${LOCK_HELD:-0}" == "1" ]] || return 0
  rm -rf "$LOCKDIR"
  LOCK_HELD=0
}

queue() {
  say "applying the namespace, ClusterQueue and LocalQueue"
  k apply -f "$ROOT/experiments/cpu-ddp/queue.yaml" >>"$EXDIR/run.log" 2>&1

  # A ClusterQueue that is not Active admits nothing, and a Workload parked behind an inactive queue looks
  # exactly like one waiting for capacity.
  local deadline=$((SECONDS + 120))
  while ((SECONDS < deadline)); do
    local active
    active="$(k get clusterqueue cpu-ddp -o jsonpath='{.status.conditions[?(@.type=="Active")].status}' 2>/dev/null || true)"
    if [[ "$active" == "True" ]]; then
      say "ClusterQueue cpu-ddp is Active"
      return 0
    fi
    sleep 3
  done
  echo "ClusterQueue cpu-ddp did not become Active within 120s" >&2
  k get clusterqueue cpu-ddp -o yaml >"$EXDIR/clusterqueue-stuck.yaml" 2>&1 || true
  exit 1
}

# Render job.yaml for this run. A placeholder left unsubstituted must break the run, not be tolerated.
render_job() {
  local name="$1" out="$2"
  local extra=""
  extra="export DDP_STEPS=$STEPS"
  [[ -n "${NO_SYNC:-}" ]] && extra="$extra; export DDP_NO_SYNC=$NO_SYNC"
  [[ -n "${DIE_AT_STEP:-}" ]] && extra="$extra; export DDP_DIE_AT_STEP=$DIE_AT_STEP"
  [[ -n "${HOLD:-}" ]] && extra="$extra; export DDP_HOLD_SECONDS=$HOLD"

  sed -e "s|RUN_ID_PLACEHOLDER|$name|g" -e "s|EXTRA_EXPORTS_PLACEHOLDER|$extra|" \
    "$ROOT/experiments/cpu-ddp/job.yaml" >"$out"

  if grep -q "PLACEHOLDER" "$out"; then
    echo "a placeholder survived substitution in $out" >&2
    grep -n "PLACEHOLDER" "$out" >&2
    exit 1
  fi
}

# The admission story, taken from the objects rather than from timing the script.
record_admission() {
  local name="$1"
  {
    echo "=== MLTrainingJob status ==="
    k -n "$NS" get mltrainingjob "cpu-ddp-$name" -o jsonpath='{.status}' 2>/dev/null
    echo
    echo "=== Job suspend and conditions ==="
    k -n "$NS" get job "cpu-ddp-$name" -o jsonpath='suspend={.spec.suspend} conditions={.status.conditions}' 2>/dev/null
    echo
    echo "=== Kueue Workload ==="
    k -n "$NS" get workload -o jsonpath='{range .items[*]}{.metadata.name}{" conditions="}{.status.conditions}{"\n"}{end}' 2>/dev/null
    echo
    echo "=== ClusterQueue usage ==="
    k get clusterqueue cpu-ddp -o jsonpath='{.status}' 2>/dev/null
    echo
  } >"$EXDIR/admission-$name.txt" 2>&1
}

run() {
  local name="${1:-}"
  if [[ -z "$name" ]]; then
    echo "usage: $0 run <name>" >&2
    exit 1
  fi

  local manifest="$EXDIR/job-$name.yaml"
  render_job "$name" "$manifest"
  say "submitting cpu-ddp-$name (STEPS=$STEPS NO_SYNC=${NO_SYNC:-0} DIE_AT_STEP=${DIE_AT_STEP:-0})"
  k apply -f "$manifest" >>"$EXDIR/run.log" 2>&1

  # Wait for a terminal phase. The CR's Running means a Pod is active, which is not the same as the ranks
  # having found each other -- that claim comes from the rendezvous records, not from here.
  local deadline=$((SECONDS + WAIT_SECONDS)) phase=""
  while ((SECONDS < deadline)); do
    phase="$(k -n "$NS" get mltrainingjob "cpu-ddp-$name" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    case "$phase" in
      Succeeded | Failed)
        say "phase=$phase"
        break
        ;;
    esac
    sleep 5
  done
  if [[ "$phase" != "Succeeded" && "$phase" != "Failed" ]]; then
    say "WARNING: no terminal phase within ${WAIT_SECONDS}s (last=$phase)"
    # What Kubernetes thought at the moment of giving up, so the next reader can tell a hang from a deadline.
    k -n "$NS" get job "cpu-ddp-$name" -o jsonpath='{.status.conditions}' >"$EXDIR/job-conditions-$name.json" 2>&1 || true
  fi

  record_admission "$name"

  # The evidence is the Pod's log: the CRD has no field for a ConfigMap or an emptyDir, so the script prints
  # its JSONL as well as writing it.
  local pod
  pod="$(k -n "$NS" get pod -l "job-name=cpu-ddp-$name" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -n "$pod" ]]; then
    k -n "$NS" logs "$pod" >"$EXDIR/pod-$name.log" 2>&1 || true
    grep '^{' "$EXDIR/pod-$name.log" >"$EXDIR/records-$name.jsonl" 2>/dev/null || true
    say "collected $(wc -l <"$EXDIR/records-$name.jsonl" 2>/dev/null || echo 0) records from $pod"
  else
    say "WARNING: no Pod found for cpu-ddp-$name"
  fi

  # The verdict the script itself reached, surfaced so a reader does not have to parse JSONL by hand.
  if [[ -s "$EXDIR/records-$name.jsonl" ]]; then
    python3 - "$EXDIR/records-$name.jsonl" <<'PY' | tee -a "$EXDIR/run.log"
import json
import sys

# raw_decode in a loop, not json.loads per line.
#
# Two ranks share one stdout. The writer now emits each record in a single atomic write, but a record larger
# than PIPE_BUF can still be split, and an evidence file that cannot be read at all is a worse outcome than
# one read leniently -- the first cluster run died here on "Extra data" while the job itself had succeeded.
decoder = json.JSONDecoder()
records = []
for line in open(sys.argv[1]):
    position = 0
    text = line.strip()
    while position < len(text):
        try:
            value, position = decoder.raw_decode(text, position)
        except ValueError:
            break
        records.append(value)
        while position < len(text) and text[position] in " \t":
            position += 1

for record in records:
    if record.get("event") == "verdict":
        print(
            "  rank %s verdict: grad_matches=%s w_matches=%s all_ranks_agree=%s observed_w=%s"
            % (
                record.get("rank"),
                record.get("grad_matches"),
                record.get("w_matches"),
                record.get("all_ranks_agree"),
                record.get("observed_w_after_one_step"),
            )
        )
PY
  fi
}

# Two jobs against a queue whose nominal quota is one GPU.
#
# The point is the second job's wait. Every run so far was admitted in the same second it was submitted,
# because nothing else held the quota -- which demonstrates that Kueue is in the path, not that it ever
# withheld anything. Here the holder keeps the single GPU for HOLD_SECONDS and the waiter must queue behind
# it, so the transition from pending to admitted is observable rather than instantaneous.
quota() {
  local holder="hold" waiter="wait"

  HOLD="$HOLD_SECONDS" STEPS=1 render_job "$holder" "$EXDIR/job-$holder.yaml"
  say "submitting the holder, which keeps the only GPU for ${HOLD_SECONDS}s"
  k apply -f "$EXDIR/job-$holder.yaml" >>"$EXDIR/run.log" 2>&1

  # The waiter must not be submitted until the holder actually owns the quota, or the two race and the
  # experiment proves nothing about ordering.
  local deadline=$((SECONDS + 120))
  while ((SECONDS < deadline)); do
    [[ "$(k get clusterqueue cpu-ddp -o jsonpath='{.status.admittedWorkloads}' 2>/dev/null)" == "1" ]] && break
    sleep 2
  done
  say "holder admitted; clusterqueue admitted=$(k get clusterqueue cpu-ddp -o jsonpath='{.status.admittedWorkloads}' 2>/dev/null)"

  STEPS=1 render_job "$waiter" "$EXDIR/job-$waiter.yaml"
  local t0
  t0="$(date -u +%s.%N)"
  say "submitting the waiter"
  k apply -f "$EXDIR/job-$waiter.yaml" >>"$EXDIR/run.log" 2>&1

  # Observed pending, not assumed pending.
  local pending="" seen_pending=0
  deadline=$((SECONDS + 60))
  while ((SECONDS < deadline)); do
    pending="$(k get clusterqueue cpu-ddp -o jsonpath='{.status.pendingWorkloads}' 2>/dev/null || true)"
    if [[ -n "$pending" && "$pending" != "0" ]]; then
      seen_pending=1
      say "waiter is pending (clusterqueue pendingWorkloads=$pending)"
      k -n "$NS" get workload -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.conditions}{"\n"}{end}' >"$EXDIR/workloads-while-pending.txt" 2>&1 || true
      break
    fi
    sleep 1
  done
  ((seen_pending == 1)) || say "WARNING: never observed a pending workload; the holder may have finished first"

  # Admission of the waiter, timed from its submission.
  deadline=$((SECONDS + WAIT_SECONDS))
  local admitted=""
  while ((SECONDS < deadline)); do
    admitted="$(k -n "$NS" get workload -o jsonpath="{range .items[?(@.metadata.ownerReferences[0].name=='cpu-ddp-$waiter')]}{.status.conditions[?(@.type=='Admitted')].status}{end}" 2>/dev/null || true)"
    if [[ "$admitted" == "True" ]]; then
      say "waiter admitted after $(python3 -c "print(f'{$(date -u +%s.%N) - $t0:.1f}')")s"
      break
    fi
    sleep 1
  done
  [[ "$admitted" == "True" ]] || say "WARNING: the waiter was never admitted"

  record_admission "$waiter"
  say "final clusterqueue: $(k get clusterqueue cpu-ddp -o jsonpath='pending={.status.pendingWorkloads} admitted={.status.admittedWorkloads}' 2>/dev/null)"
}

teardown() {
  say "deleting MLTrainingJobs in $NS"
  k -n "$NS" delete mltrainingjob --all --ignore-not-found >>"$EXDIR/run.log" 2>&1 || true
  say "deleting LocalQueue, ClusterQueue and namespace"
  k -n "$NS" delete localqueue cpu-ddp --ignore-not-found >>"$EXDIR/run.log" 2>&1 || true
  k delete clusterqueue cpu-ddp --ignore-not-found >>"$EXDIR/run.log" 2>&1 || true
  k delete namespace "$NS" --ignore-not-found >>"$EXDIR/run.log" 2>&1 || true
  say "teardown complete"
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    queue | run | quota | teardown) ;;
    *)
      echo "usage: $0 {queue|run <name>|quota|teardown}" >&2
      exit 1
      ;;
  esac
  shift

  acquire_lock
  EXDIR="${EXDIR:-ex/cpu-ddp-$(date -u +%Y%m%dT%H%M%SZ)}"
  mkdir -p "$EXDIR"
  trap release_lock EXIT

  "$cmd" "$@"
}

main "$@"
