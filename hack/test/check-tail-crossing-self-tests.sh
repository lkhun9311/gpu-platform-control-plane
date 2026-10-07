#!/usr/bin/env bash
# Runs the self-tests of the Python evaluators under hack/tail-crossing-model.
#
# WHY THIS EXISTS
#
# They were run by hand and by nothing else. On 2026-10-06 a change to instrument_gates.py that refused an
# unregistered study broke timing_fit.py's self-test, whose session-1 fixture carried no study, and every
# check that was run stayed green; an independent review of the diff found it. A self-test nothing runs is a
# self-test that can be red for a week.
#
# WHAT IT REFUSES
#
#   - a module whose self-test exits non-zero
#   - a module whose self-test exits zero having printed no "ok:" line -- a run that reached no check is not
#     a passing one
#
# A module is listed here by name rather than found by grepping for "--self-test", so a module that loses its
# self-test fails here instead of dropping out of the list.
set -uo pipefail

cd "$(dirname "$0")/../tail-crossing-model" || exit 1
fail=0
log=$(mktemp)
bin=$(mktemp -d)
trap 'rm -f "$log"; rm -rf "$bin"' EXIT
# step_boundary's seed check regenerates traces with the real generator, so its self-test needs a built harness.
( cd ../.. && go build -o "$bin/benchharness" ./cmd/benchharness ) || { echo "FAIL: could not build benchharness" >&2; exit 1; }
export BENCHHARNESS="$bin/benchharness"
for m in iterlog instrument_gates timing_fit step_boundary step_family_dev step_diagnostics step_family_waves step_family_operator operator_residuals; do
	if ! python3 "$m.py" --self-test >"$log" 2>&1; then
		echo "FAIL: $m.py --self-test exited non-zero:" >&2
		tail -5 "$log" >&2
		fail=1
		continue
	fi
	n=$(grep -c '^ok' "$log")
	if [ "$n" -eq 0 ]; then
		echo "FAIL: $m.py --self-test exited 0 and printed no ok: line" >&2
		fail=1
		continue
	fi
	echo "ok: $m.py --self-test, $n checks"
done
if [ "$fail" != "0" ]; then
	echo "check-tail-crossing-self-tests: FAILED" >&2
	exit 1
fi
# The step-log checker lives beside the instrument it checks, and it gates every number built on that log.
if python3 ../vllm-plugins/check_step_log.py --self-test >"$log" 2>&1 && grep -q '^ok' "$log"; then
	echo "ok: vllm-plugins/check_step_log.py --self-test, $(grep -c '^ok' "$log") checks"
else
	echo "FAIL: vllm-plugins/check_step_log.py --self-test:" >&2
	tail -5 "$log" >&2
	echo "check-tail-crossing-self-tests: FAILED" >&2
	exit 1
fi
echo "check-tail-crossing-self-tests: every self-test passed"
