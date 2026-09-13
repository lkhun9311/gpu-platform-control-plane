#!/usr/bin/env bash
#
# Pins the capacity ladder's refusals and its stopping rule, with no cluster and no card.
#
# WHY THIS EXISTS
#
# hack/test/rehearse-m5c-matrix.sh drives the ladder down the path a stub can reach: every rung meets the
# target, so the ladder climbs, buys its baseline and answers L6. Two things it CANNOT reach are the two a
# paid run will:
#
#   the STOP path        no stub is ever slow enough to breach a 139 ms target, so the rung where both
#                        topologies breach -- the one the whole ladder is climbing to find -- never happens
#                        on a free cluster.
#   the INVALID path     a cell the evaluator cannot score must stop the ladder for a different reason than
#                        a breach does, and a runner that confused the two would either climb past a hole or
#                        report a bracket it never established.
#
# Both are decided in internal/bench and both are reachable from a file, so they are pinned here from the
# ninth pilot's own rows rather than left to the day a card is paying.
#
# WHAT IT SUBSTITUTES, AND WHY THAT IS HONEST
#
# The fixtures are real paid rows with their first-token timestamps rewritten, which makes them a TEST
# INPUT and not a measurement. Nothing here reports a latency. What is being checked is which branch the
# instrument takes for a given tail, and a tail that was manufactured is the only way to ask that question
# without buying one.
set -euo pipefail

cd "$(dirname "$0")/../.." || exit 1
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
failures=0
say() { echo "== $*"; }
ok()  { echo "   ok: $*"; }
bad() { echo "   FAIL: $*" >&2; failures=$(( failures + 1 )); }

SRC_ROWS=hack/m5c-20260913-011031/m5c-run/raw-shared-1.jsonl
if [ ! -s "$SRC_ROWS" ]; then
  echo "skipping: $SRC_ROWS is not in this tree (the paid evidence is gitignored)." >&2
  echo "The refusals below are also covered by TestLadder* in internal/bench, which needs no evidence." >&2
  exit 0
fi

go build -o "$WORK/benchharness" ./cmd/benchharness

# fixture <out> <arm> <divisor> rewrites every premium first-token wait to 1/divisor of what it was.
#
# Dividing rather than assigning keeps the SHAPE of the distribution, so the p99 the evaluator computes is
# still a p99 over 9,310 different numbers and not over one repeated.
fixture() {
  python3 - "$SRC_ROWS" "$1" "$2" "$3" <<'PY'
import json,sys
src,out,arm,div=sys.argv[1],sys.argv[2],sys.argv[3],float(sys.argv[4])
with open(out,"w") as w:
    for line in open(src):
        r=json.loads(line)
        r["arm"]=arm
        r["study"]="throughput-ladder-2026-09-13"
        ft,st=r.get("firstTokenUnixNanos"),r.get("sendUnixNanos")
        if ft and st and not r.get("isNoisy"):
            r["firstTokenUnixNanos"]=int(st+(ft-st)/div)
        w.write(json.dumps(r)+"\n")
PY
}

say "1. both topologies breach -- does the verdict say STOP, and with the code the runner acts on?"
fixture "$WORK/raw-rung01-shared-1.jsonl"      rung01-shared      1
fixture "$WORK/raw-rung01-timeSlicing-1.jsonl" rung01-timeSlicing 1
set +e
out=$("$WORK/benchharness" ladder-verdict --raw "$WORK/raw-rung01-shared-1.jsonl" --raw "$WORK/raw-rung01-timeSlicing-1.jsonl" --rung 1 2>"$WORK/err1")
code=$?
set -e
[ "$code" = "10" ] && ok "exit 10, which is the stop the runner breaks on" || bad "exit $code, want 10 -- the runner would have climbed past the bracket"
[ "$out" = "LADDER: STOP" ] && ok "and it says STOP" || bad "it printed ${out@Q}"
grep -q "registered stopping point" "$WORK/err1" && ok "and names the rule it applied" || bad "the reason does not name the registered rule: $(cat "$WORK/err1")"

say "2. one topology still meets the target -- does it CONTINUE?"
fixture "$WORK/raw-rung02-shared-1.jsonl"      rung02-shared      1
fixture "$WORK/raw-rung02-timeSlicing-1.jsonl" rung02-timeSlicing 40
set +e
out=$("$WORK/benchharness" ladder-verdict --raw "$WORK/raw-rung02-shared-1.jsonl" --raw "$WORK/raw-rung02-timeSlicing-1.jsonl" --rung 2 2>"$WORK/err2")
code=$?
set -e
[ "$code" = "0" ] && ok "exit 0" || bad "exit $code, want 0 -- a bracket that is still open was reported closed"
[ "$out" = "LADDER: CONTINUE" ] && ok "and it says CONTINUE" || bad "it printed ${out@Q}"

say "3. a rung with one cell -- refused, and NOT mistaken for a breach?"
set +e
out=$("$WORK/benchharness" ladder-verdict --raw "$WORK/raw-rung01-shared-1.jsonl" --rung 1 2>"$WORK/err3")
code=$?
set -e
[ "$code" = "1" ] && ok "exit 1, which the runner tells apart from the stop's 10" || bad "exit $code, want 1"
[ "$out" = "LADDER: INVALID" ] && ok "and it says INVALID rather than STOP" || bad "it printed ${out@Q}"
grep -q "no timeSlicing cell" "$WORK/err3" && ok "and names the missing cell" || bad "the refusal does not name what is missing: $(cat "$WORK/err3")"

say "4. does the runner refuse a load described twice?"
check_refusal() {
  local what="$1" want="$2"; shift 2
  set +e
  out=$(env "$@" PLATFORM=kind LADDER="1:1" bash hack/m5c-matrix.sh 2>&1)
  code=$?
  set -e
  [ "$code" != "0" ] || { bad "$what was accepted"; return; }
  printf '%s' "$out" | grep -q "$want" && ok "$what is refused, naming $want" || bad "$what: the refusal does not say why: $(printf '%s' "$out" | head -3)"
}
check_refusal "LADDER beside RATE"         "RATE and LADDER are both set"         RATE=9
check_refusal "LADDER beside REPS"         "REPS and LADDER are both set"         REPS=2
check_refusal "LADDER beside ARMS"         "ARMS and LADDER are both set"         ARMS=R1
check_refusal "LADDER beside NOISY_WEIGHT" "NOISY_WEIGHT and LADDER are both set" NOISY_WEIGHT=0.02

say "5. does the SESSION WRAPPER refuse a load described twice, before it rents anything?"
check_session_refusal() {
  local what="$1" want="$2"; shift 2
  set +e
  out=$(env "$@" LADDER="1:1" OUT="$WORK/sess" bash hack/m5c-gpu-session.sh 2>&1)
  code=$?
  set -e
  [ "$code" != "0" ] || { bad "$what was accepted by the session wrapper"; return; }
  printf '%s' "$out" | grep -q "$want" && ok "$what is refused before anything is rented" || bad "$what: $(printf '%s' "$out" | head -3)"
}
# The wrapper carries its own copy of these refusals on purpose: it EXPORTS into the matrix, so when the two
# disagree the wrapper wins and the matrix's refusal is dead text. A run that reached the instance with both
# a ladder and a single load would be refused on the card, after the bring-up was paid for.
check_session_refusal "LADDER beside RATE"         "RATE and LADDER are both set"         RATE=9
check_session_refusal "LADDER beside REPS"         "REPS and LADDER are both set"         REPS=2
check_session_refusal "LADDER beside ARMS"         "ARMS and LADDER are both set"         ARMS=R1
check_session_refusal "LADDER beside NOISY_WEIGHT" "NOISY_WEIGHT and LADDER are both set" NOISY_WEIGHT=0.02

say "6. does a skipped rung hold its position rather than renumbering the ones below it?"
# The whole point of `skip`: a repetition of rungs 2 and 3 must write rung02-* and rung03-*. If skip merely
# dropped the entry, those cells would be named rung01-* and rung02-* and would pool with the first run's
# cells at completely different offered loads.
# The plan is printed before the card is touched, so this needs no cluster and no money.
out=$(env PLATFORM=kind LADDER="skip 2:0.1 3:0.05" PREMIUM_WEIGHT=1 PROBE_WEIGHT=0 DURATION_MS=1000 \
      OUT="$WORK/skiprun" KCTX=no-such-context bash hack/m5c-matrix.sh 2>&1 || true)
plan=$(printf '%s' "$out" | grep '^== plan:' || true)
[ -n "$plan" ] || bad "the runner did not print a plan before acquiring a card"
printf '%s' "$plan" | grep -q "rung01-" \
  && bad "a skipped rung 1 still produced rung01 cells, which would pool with the previous run's 1.16 req/s under that name: $plan"
printf '%s' "$plan" | grep -q "rung02-shared" && printf '%s' "$plan" | grep -q "rung03-shared" \
  && ok "the plan is rung02 and rung03, so skip held the positions" \
  || bad "the plan does not carry rung02 and rung03: $plan"
printf '%s' "$plan" | grep -q "5 cell" \
  && ok "and it is 5 cells: two rungs times two topologies plus the baseline" \
  || bad "the plan is not five cells: $plan"

echo
if [ "$failures" = "0" ]; then
  say "LADDER REFUSALS PINNED: the stop, the continue, the unscorable rung, and the double-described load in BOTH scripts."
else
  echo "FAILED: $failures assertion(s) above." >&2
  exit 1
fi
