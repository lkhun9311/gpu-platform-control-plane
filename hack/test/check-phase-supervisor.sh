#!/usr/bin/env bash
# Checks hack/lib/phase-supervisor.sh: a paid phase ends at its deadline with everything it started, and nothing it
# left behind holds the caller.
#
# Each case is one the per-call wrappers lost: a credential helper that ignored TERM and kept the caller's pipe (sixth
# attack of the retarget registration), a descendant that called setsid, and a phase started with its budget spent.
# It runs under a delegated scope, entering one if it was not started in one, because that is what the bound needs.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
# shellcheck source=hack/lib/phase-supervisor.sh
. hack/lib/phase-supervisor.sh
phase_supervisor_enter bash "$(readlink -f "$0")" "$@" || exit 1

fails=0
oks=0
ok() {
  echo "ok: $*"
  oks=$((oks + 1))
}
fail() {
  echo "FAIL: $*"
  fails=$((fails + 1))
}
# survivors MARK: the processes whose arguments carry MARK, a sleep length no other process here uses.
survivors() { pgrep -f "slee[p] $1" | paste -sd' '; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# A client that returns at once and leaves a TERM-ignoring helper holding its stderr, as kubectl's exec plugin did.
leaves_helper() {
  (
    trap '' TERM
    exec sleep 3601
  ) &
  echo "client done"
}
# A phase that hangs, with a descendant that left its session and group.
hangs_with_escapee() {
  setsid sleep 3602 &
  sleep 3603
}
# A phase that, if started, leaves a mark.
marks() { : >"$work/started"; }

why="$(phase_supervisor_ready)" && ok "ready: $why" || fail "not ready: $why"

start=$SECONDS
out="$(paid_phase helper $((SECONDS + 20)) leaves_helper 2>&1)"
rc=$?
took=$((SECONDS - start))
[[ $rc == 0 && "$out" == "client done" && $took -le 3 ]] &&
  ok "a helper left holding stderr neither held the caller nor changed the status: rc=$rc took=${took}s" ||
  fail "a helper left holding stderr: rc=$rc took=${took}s out=${out:0:200}"
s="$(survivors 3601)"
[[ -z "$s" ]] && ok "the helper was killed with its phase" || fail "the helper outlived its phase: $s"

start=$SECONDS
out="$(paid_phase hang $((SECONDS + 2)) hangs_with_escapee 2>&1)"
rc=$?
took=$((SECONDS - start))
[[ $rc == 124 && $took -le 4 && "$out" == *"passed its deadline"* ]] &&
  ok "a hanging phase ended at its 2 s deadline: rc=$rc took=${took}s" ||
  fail "a hanging phase: rc=$rc took=${took}s out=${out:0:200}"
s="$(survivors '360[23]')"
[[ -z "$s" ]] && ok "the setsid descendant was killed with its phase" || fail "outlived the phase: $s"

out="$(paid_phase spent "$SECONDS" marks 2>&1)"
rc=$?
[[ $rc == 124 && ! -e "$work/started" && "$out" == *"not started"* ]] &&
  ok "a phase whose deadline had passed was not started: rc=$rc" ||
  fail "a phase whose deadline had passed: rc=$rc started=$([[ -e "$work/started" ]] && echo yes || echo no) out=${out:0:200}"

out="$(paid_phase status $((SECONDS + 10)) bash -c 'echo to-out; echo to-err >&2; exit 7' 2>"$work/err")"
rc=$?
[[ $rc == 7 && "$out" == to-out && "$(cat "$work/err")" == to-err ]] &&
  ok "the phase's status, stdout and stderr reach the caller as they were" ||
  fail "status/streams: rc=$rc out=$out err=$(cat "$work/err")"

# An exit that left a phase running: the poller is killed, as a signal to the session would, and phase_kill_all ends it.
paid_phase orphan $((SECONDS + 60)) sleep 3604 >/dev/null 2>"$work/orphan.err" &
poller=$!
sleep 1
kill "$poller"
wait "$poller"
parent="$(phase_cgroup)"
left="$(find "$parent" -maxdepth 1 -name "phase-$PHASE_SESSION-orphan-*" | wc -l)"
phase_kill_all
s="$(survivors 3604)"
gone="$(find "$parent" -maxdepth 1 -name 'phase-*' | wc -l)"
[[ $left == 1 && -z "$s" && $gone == 0 ]] &&
  ok "phase_kill_all ended a phase its poller left running and removed its cgroup" ||
  fail "phase_kill_all: cgroups before=$left after=$gone survivors=$s"

# A backward step of the wall clock between a deadline's computation and its phase, simulated as gpt-6-astra did by
# setting SECONDS back: the phase still ends at the deadline as computed, not 6 s after it.
start=$SECONDS
dl=$((SECONDS + 2))
SECONDS=$((SECONDS - 6))
out="$(paid_phase stepped "$dl" sleep 3605 2>&1)"
rc=$?
took=$((SECONDS - start + 6))
s="$(survivors 3605)"
[[ $rc == 124 && $took -le 4 && -z "$s" ]] &&
  ok "a deadline computed before the clock stepped back 6 s still ended its phase in ${took} s for 2 s" ||
  fail "a backward clock step: rc=$rc took=${took}s survivors=$s out=${out:0:200}"

# Another session's phase in the same cgroup is not this session's to end.
PHASE_SESSION=other paid_phase theirs $((SECONDS + 60)) sleep 3606 >/dev/null 2>"$work/theirs.err" &
theirs=$!
sleep 1
phase_kill_all
s="$(survivors 3606)"
[[ -n "$s" ]] && ok "phase_kill_all left another session's phase running" || fail "phase_kill_all ended another session's phase"
PHASE_SESSION=other phase_kill_all
wait "$theirs"

echo "phase supervisor: $oks ok, $fails failed"
((fails == 0 && oks == 10))
