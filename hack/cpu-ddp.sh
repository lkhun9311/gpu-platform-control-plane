#!/usr/bin/env bash
# Submit the two-rank gloo DDP job through MLTrainingJob and collect what it proves.
#
# See experiments/cpu-ddp/README.md for why this runs two ranks inside one Pod rather than two Pods.
#
# Usage:
#   hack/cpu-ddp.sh queue                 # create the namespace, ClusterQueue and LocalQueue
#   hack/cpu-ddp.sh run <name>            # submit one run and collect its evidence
#   hack/cpu-ddp.sh teardown              # remove the queue objects and the namespace
#
# Environment:
#   CONTEXT       kube context                         (default kind-platform)
#   EXDIR         where evidence is written            (default ex/cpu-ddp-<UTC timestamp>)
#   STEPS         training steps                       (default 3)
#   NO_SYNC       1 to disable gradient sync (control) (default unset)
#   DIE_AT_STEP   step at which rank 1 SIGKILLs itself (default 0, never)

set -euo pipefail

# Job control, so a backgrounded pipeline can be killed as a group. Same reason as hack/argocd-selfheal.sh.
set -m

CONTEXT="${CONTEXT:-kind-platform}"
NS=cpu-ddp
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCKDIR="${LOCKDIR:-/tmp/cpu-ddp.lock}"
STEPS="${STEPS:-3}"

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
  local deadline=$((SECONDS + 600)) phase=""
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
  [[ "$phase" == "Succeeded" || "$phase" == "Failed" ]] || say "WARNING: no terminal phase within 600s (last=$phase)"

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

for line in open(sys.argv[1]):
    record = json.loads(line)
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
    queue | run | teardown) ;;
    *)
      echo "usage: $0 {queue|run <name>|teardown}" >&2
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
