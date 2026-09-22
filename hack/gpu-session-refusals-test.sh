#!/usr/bin/env bash
# What gpu-session.sh refuses before it spends anything.
#
# These three checks were added on 2026-09-22 and nothing guarded them. Deleting all three left `bash -n`
# green, `make shell-check` green, and the script running on to the cluster gate as though nothing had
# changed -- which is the shape this repository keeps being bitten by: a judgment that no test would notice
# losing.
#
# Only the refusals are exercised, and only the ones that fire BEFORE the TTL gate and before prepare().
# Everything past that point needs a cluster and a rented card, so it cannot be asserted here at any price.
set -uo pipefail

SCRIPT="$(dirname "$0")/gpu-session.sh"
failures=0

# Run the session script with the given workers and environment, and assert it exits non-zero with `want`
# in its output.
#
# The worker list is a per-case argument and not a constant. The first draft of this file passed two workers
# to every case, so the storage-class case tripped the worker-count refusal instead and reported a pass for
# a guard it never reached -- a test that was green about the wrong thing, which is the failure this file
# exists to catch in the script it tests.
#
# The node names are deliberately ones no cluster has. Every case here must refuse before anything looks a
# node up, so a name that cannot resolve is the correct input: if a case ever starts depending on the node
# existing, it fails here rather than silently becoming a test of the cluster.
refuses() {
  local name="$1" want="$2" workers="$3"
  shift 3
  local out status
  # shellcheck disable=SC2086
  out="$(env "$@" bash "$SCRIPT" $workers 2>&1)"
  status=$?
  if [[ $status -eq 0 ]]; then
    echo "FAIL $name: exited 0; it must refuse" >&2
    failures=$((failures + 1))
    return
  fi
  if [[ "$out" != *"$want"* ]]; then
    echo "FAIL $name: refused, but not for this reason" >&2
    echo "  wanted to find: $want" >&2
    echo "  got: ${out:0:300}" >&2
    failures=$((failures + 1))
    return
  fi
  echo "ok   $name"
}

# A study name the script does not implement. Without this the name falls through to the reclaim block and
# buys twelve runs of the wrong experiment.
refuses "an unknown study is refused" \
  "STUDY must be reclaim, idling or resume" \
  "no-such-node-a" \
  STUDY=bogus

# The resume block names one worker four times. A second would be prepared, routed and billed without ever
# appearing in the sequence -- the defect the argument-count check exists to stop, reintroduced by a study
# that uses fewer workers than the script prepares.
refuses "the resume study refuses a second worker" \
  "takes exactly one worker" \
  "no-such-node-a no-such-node-b" \
  STUDY=resume STATE_CLASS=queuelab-gp3

# queuelabrun refuses a checkpointing arm with no storage class, but that refusal arrives on the meter.
refuses "the resume study refuses a missing storage class" \
  "needs STATE_CLASS" \
  "no-such-node-a" \
  STUDY=resume

# The refusals must not fire for the studies that were already working. This one is the control: with one
# worker and a class, the script must get PAST them and fail later, at the cluster gate.
out="$(env STUDY=resume STATE_CLASS=queuelab-gp3 bash "$SCRIPT" no-such-node-a 2>&1)"
if [[ "$out" == *"takes exactly one worker"* || "$out" == *"needs STATE_CLASS"* || "$out" == *"STUDY must be"* ]]; then
  echo "FAIL a valid resume invocation is refused by one of the new checks" >&2
  failures=$((failures + 1))
else
  echo "ok   a valid resume invocation passes the new checks"
fi

if [[ $failures -ne 0 ]]; then
  echo "$failures refusal(s) did not behave as registered" >&2
  exit 1
fi
echo "every refusal fires, and none of them fires on a valid invocation"
