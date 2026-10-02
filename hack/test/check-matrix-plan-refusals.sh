#!/usr/bin/env bash
# Pins the FROZEN MATRIX's pre-purchase plan check: the refusals that must arrive before run-instances.
#
# WHY THIS EXISTS
#
# PLAN_ONLY was implemented for the capacity ladder and refused anything else -- "PLAN_ONLY is only
# implemented for a ladder" -- and the session wrapper ran it only when LADDER was set. So a frozen
# three-arm matrix reached run-instances with nothing having asked whether its cells could be scored, and
# DRY_RUN's success was the only thing that looked like such a check. DRY_RUN validates the user-data
# (shebang, parse, surviving placeholder, device mount, encoded size) and never generates a trace.
#
# The refusals below are not new. Each one already existed and each one fired ON THE RENTED CARD: `replay`
# validates the arm against its study after the engines are up, and the cell floors are applied by the
# readings after the replay has finished. The same questions asked here cost nothing.
#
# WHAT IT CANNOT DO
#
# Everything that depends on results: whether an engine starts, whether the card fits two of them, what any
# latency will be, and whether a cell that COULD be scored will be. A green run here says the plan is
# scorable as specified, not that the run will succeed.
#
# It is in `make harness-check` because it is genuinely self-contained: no cluster, no card, no credentials,
# no third-party Python. It does build cmd/benchharness, which the other two harnesses in that target do
# not, so it is the slow one there -- about a Go build plus thirty seconds of trace generation.
set -euo pipefail

cd "$(dirname "$0")/../.."

failures=0
say() { echo "== $*"; }
ok()  { echo "   ok: $*"; }
bad() { echo "   FAIL: $*" >&2; failures=$(( failures + 1 )); }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# TMPDIR is a directory of its own, and it is CREATED.
#
# The matrix opens its own `mktemp -d` under TMPDIR. Pointing TMPDIR at a path that does not exist makes
# that mktemp fail, WORK becomes the empty string, and the script dies with "could not take the shipped
# benchharness binary" -- which is NOT any of the refusals below. Every case would then exit non-zero and a
# test that only read the exit code would call all of them refused. It cost one round of exactly that.
mkdir -p "$WORK/tmp"

if [ -n "${BENCHHARNESS_BIN:-}" ]; then
  [ -x "$BENCHHARNESS_BIN" ] || { echo "BENCHHARNESS_BIN=$BENCHHARNESS_BIN is not executable" >&2; exit 1; }
  cp "$BENCHHARNESS_BIN" "$WORK/benchharness"
else
  go build -o "$WORK/benchharness" ./cmd/benchharness || { echo "could not build benchharness" >&2; exit 1; }
fi

# The load the frozen matrix was registered with, measured by hack/m5b-price-of-protection.sh.
#
# They are here rather than defaulted by the matrix because the matrix refuses to default them: RATE alone
# does not describe this load, and a mix picked by the harness puts the 40,000-character contender at 45% of
# arrivals. Changing them here changes what this file checks, so they are written out.
RATE=9.85
NOISY_WEIGHT=0.054
FULL_DURATION=420000

# plan_case <what> <want> [VAR=value ...]. `want` is `ok`, or a string the refusal must contain.
#
# Everything after `want` is passed to the matrix, so a case states only what it changes.
plan_case() {
  local what="$1" want="$2"; shift 2
  local out code
  set +e
  out=$(env TMPDIR="$WORK/tmp" PLAN_ONLY=1 PLATFORM=kind KCTX=none BENCHHARNESS_BIN="$WORK/benchharness" \
        PREMIUM_WEIGHT=1 PROBE_WEIGHT=0 OUT="$WORK/out-$RANDOM" "$@" \
        bash hack/m5c-matrix.sh 2>&1)
  code=$?
  set -e
  LAST_PLAN_OUT="$out"
  if [ "$want" = ok ]; then
    if [ "$code" = 0 ]; then ok "$what is accepted"; else
      bad "$what was refused: $(printf '%s' "$out" | grep -E 'PLAN REFUSED|MATRIX FAILED' | head -1)"
    fi
    return
  fi
  if [ "$code" = 0 ]; then
    bad "$what was ACCEPTED and would have been refused after the card was rented"
    return
  fi
  # The exit code alone is not the assertion.
  #
  # A plan case can exit non-zero for a reason that is not the refusal under test -- a missing TMPDIR, an
  # unbuilt binary, an unset load variable -- and reading only the code calls every one of those a pass.
  if printf '%s' "$out" | grep -q "$want"; then
    ok "$what is refused before launch, naming it"
  else
    bad "$what exited $code without saying ${want@Q}: $(printf '%s' "$out" | tail -2 | tr '\n' ' ')"
  fi
}

say "1. does the registered three-arm plan pass, and does it show fifteen cells?"
plan_case "the three-arm five-repetition matrix" ok \
  ARMS="R1 shared timeSlicing" REPS=5 RATE="$RATE" NOISY_WEIGHT="$NOISY_WEIGHT" DURATION_MS="$FULL_DURATION"
# The COUNT is asserted, because "the plan is scorable" and "the plan is the one that was ordered" are
# different claims and only the second one catches ARMS or REPS left at their four-arm, four-repetition
# defaults. 3 x 5 = 15, and a default run would say 16.
printf '%s' "$LAST_PLAN_OUT" | grep -q 'plan: 15 cell(s)' \
  && ok "the plan says fifteen cells" \
  || bad "the plan does not say fifteen cells: $(printf '%s' "$LAST_PLAN_OUT" | grep -o 'plan: [0-9]* cell(s)' | head -1)"
# `|| true` for the same reason as section 8's: a plan that reported NO scorable cell would make grep -c
# print 0 and exit 1, pipefail would end the script here, and the assertion written for that case would not
# run. The worst outcome must be the one it reports, not the one it cannot reach.
scorable=$(printf '%s' "$LAST_PLAN_OUT" | grep -c 'scorable' || true)
[ "$scorable" = 15 ] \
  && ok "all fifteen cells were individually checked" \
  || bad "$scorable cells reported scorable, not 15; a plan check that silently skips cells is worse than none"

say "2. is the isolated baseline's trace free of the contender, as the readings require?"
# R1 is the SAME two-tenant trace with the contender filtered out, not a premium-only trace at the full
# rate. gen-trace does that filtering itself, so this asserts the artefact rather than the intention.
printf '%s' "$LAST_PLAN_OUT" | grep -q 'R1: 3882 premium, 0 contender' \
  && ok "R1 offers 3882 premium and no contender" \
  || bad "R1's planned trace is not premium-only: $(printf '%s' "$LAST_PLAN_OUT" | grep -o 'R1: [0-9]* premium, [0-9]* contender' | head -1)"
printf '%s' "$LAST_PLAN_OUT" | grep -q 'shared: 3882 premium, 238 contender' \
  && ok "and the control carries the contender at the same premium schedule" \
  || bad "the control's planned trace is not the two-tenant one: $(printf '%s' "$LAST_PLAN_OUT" | grep -o 'shared: [0-9]* premium, [0-9]* contender' | head -1)"

say "3. is a cell too short for the readings' floor refused BEFORE anything is rented?"
# This is the deliberate failure the open defect asked for. At this load 10000 ms offers 94 premium
# requests; MinTailSamples is 100 and RegisteredEstimandFor applies it to the SMALLEST repetition tail, so
# fifteen such cells pooling 1410 would still be refused.
plan_case "a cell below the per-repetition tail floor" "could not be scored even if every request succeeded" \
  ARMS="R1 shared timeSlicing" REPS=5 RATE="$RATE" NOISY_WEIGHT="$NOISY_WEIGHT" DURATION_MS=10000
printf '%s' "$LAST_PLAN_OUT" | grep -q 'offers 94 premium requests' \
  && ok "and the refusal names the count it measured" \
  || bad "the refusal does not name 94 premium offers, so it may not have generated the trace it judged"
printf '%s' "$LAST_PLAN_OUT" | grep -q 'run-instances' \
  && bad "the output mentions run-instances; this path must not reach a launch" \
  || ok "nothing in that path reaches run-instances"

say "4. is an arm list the readings would call INVALID refused?"
plan_case "a plan with no isolated baseline" "do not include R1" \
  ARMS="shared timeSlicing" REPS=5 RATE="$RATE" NOISY_WEIGHT="$NOISY_WEIGHT" DURATION_MS="$FULL_DURATION"
plan_case "a plan with no control" "do not include shared" \
  ARMS="R1 timeSlicing" REPS=5 RATE="$RATE" NOISY_WEIGHT="$NOISY_WEIGHT" DURATION_MS="$FULL_DURATION"
plan_case "an arm the sharing study does not admit" "is not one of study" \
  ARMS="R1 shared rung01-shared" REPS=1 RATE="$RATE" NOISY_WEIGHT="$NOISY_WEIGHT" DURATION_MS="$FULL_DURATION"

say "5. does the LADDER still pass, with its own question and its own floor?"
# The two experiments ask different things of the same artefact: the ladder holds the contender at a fixed
# count across rungs and needs 500 premium offers. Lifting PLAN_ONLY's ladder requirement must not have
# pointed the frozen question at a rung, nor the ladder's question at a frozen cell.
plan_case "the registered downward ladder" ok \
  LADDER="1.431979:0.23386882 2.564749:0.11403366 4.847585:0.05746316" \
  LADDER_STUDY=throughput-ladder-down-2026-09-13 DURATION_MS=505000
printf '%s' "$LAST_PLAN_OUT" | grep -q 'rung03-R1' \
  && ok "and the ladder's synthesised baseline is still checked" \
  || bad "the ladder's isolated baseline was not in the plan; it is bought at the top rung and no CELLS entry carries it"
plan_case "a ladder rung below ITS floor of 500" "below 500 completed" \
  LADDER="1.431979:0.23386882" LADDER_STUDY=throughput-ladder-down-2026-09-13 DURATION_MS=420000

say "6. does the SESSION WRAPPER run the check on every run, not only for a ladder?"
# Asserted on the source rather than by launching, because the wrapper's next step is run-instances.
#
# The behavioural cover for this is hack/test/spot-lifecycle: its twenty recorded m5c-gpu-session
# transcripts are frozen-matrix runs, and they show the plan check running. What is asserted here is the one
# thing a transcript cannot show -- that no `if` stands between the wrapper and the check.
plan_line=$(grep -n 'env "${plan_env\[@\]}" bash hack/m5c-matrix.sh' hack/m5c-gpu-session.sh | head -1 || true)
[ -n "$plan_line" ] || bad "the wrapper no longer invokes the matrix in PLAN_ONLY mode by that name; this check cannot see it"
if [ -n "$plan_line" ]; then
  # Column 0 means top level. A line indented by anything is inside a block, and the block this used to sit
  # in was `if [ -n "$LADDER" ]`.
  printf '%s' "$plan_line" | grep -qE '^[0-9]+:if ! env' \
    && ok "the plan check is invoked at top level, so every run reaches it" \
    || bad "the plan check is indented, so something gates it: ${plan_line}"
fi
grep -q 'if \[ -n "\$LADDER" \]; then' hack/m5c-gpu-session.sh \
  && say "   (note: the wrapper still has other LADDER-conditional blocks, which is expected)" || true

say "7. did the plan checks leave anything behind?"
# PLAN_ONLY exits before the matrix's full cleanup trap is armed, and each of its work directories holds a
# 34 MB benchharness copy. /tmp is tmpfs here, so an unremoved one is memory: 18 GB of them had accumulated
# by 2026-09-15.
leftover=$(find "$WORK/tmp" -mindepth 1 -maxdepth 1 | wc -l)
[ "$leftover" = 0 ] \
  && ok "the plan checks left no work directory behind" \
  || bad "the plan checks left $leftover work director(ies) behind; each holds a benchharness copy, and /tmp is tmpfs"

say "8. does the instance's own backstop still fire BEFORE the deadline this shell waits for?"
# THE ORDERING IS THE WHOLE POINT, and nothing asserted it.
#
# BACKSTOP_SECONDS is 17400 and HARD_STOP_SECONDS is 16800, and the ten-minute lead exists so that a shell
# which dies -- a closed laptop, a killed terminal -- still leaves a timer inside the instance to stop the
# billing. The wrapper's comment says the ordering "was VERIFIED rather than assumed on 2026-10-01", and
# that verification was a person reading two line numbers. Nothing re-ran it, and in the meantime a comment
# added to that file moved every line below it by sixteen.
#
# So it is measured here, on the user-data golden, which is the artefact an instance actually receives.
UD=hack/test/spot-lifecycle/golden/m5c-gpu-session/user-data.sh
if [ ! -f "$UD" ]; then
  bad "the user-data golden is missing, so the backstop ordering cannot be measured"
else
  # `|| true` is not decoration: this script runs under `set -o pipefail`.
  #
  # grep exits 1 when it matches nothing, pipefail raises that to the pipeline, and the assignment then
  # aborts the script at this line. The checks below -- including the one written for exactly the case where
  # the number is gone -- never run, and a harness reading only "did section 8 print a FAIL" calls that a
  # pass. Changing 17400 to 9000 was silently accepted the first time for this reason.
  b_line=$(grep -n 'sleep 17400' "$UD" | head -1 | cut -d: -f1 || true)
  d_line=$(grep -n 'DEADLINE_EPOCH=\$((' "$UD" | head -1 | cut -d: -f1 || true)
  if [ -z "$b_line" ] || [ -z "$d_line" ]; then
    bad "the user-data no longer arms a 17400s backstop and a 16800s deadline by those numbers; found backstop=${b_line:-none} deadline=${d_line:-none}"
  elif [ "$b_line" -ge "$d_line" ]; then
    bad "the backstop is armed at line $b_line and the deadline at $d_line: the shell's timer is no longer the one that fires first, so a dead shell would leave the card billing until the backstop"
  else
    ok "the backstop is armed at line $b_line, ahead of the deadline at $d_line"
    # Between the two there must be nothing that can fail, return or exit.
    #
    # A ten-minute lead measured in seconds is only a lead if both timers START. Anything between them that
    # can abort leaves the instance with the backstop armed and no deadline, or -- if the order ever flips --
    # a deadline and no backstop.
    # Zero is the PASSING value here, and `grep -c` prints it and then exits 1 -- which under pipefail ends
    # the script before the comparison. The healthy case was the one that aborted.
    between=$(sed -n "$((b_line+1)),$((d_line-1))p" "$UD" \
              | grep -vE '^\s*$|^\s*#' | grep -cvE '^[A-Za-z_][A-Za-z0-9_]*=' || true)
    [ "$between" = 0 ] \
      && ok "and nothing but variable assignment stands between them, so the lead survives intact" \
      || bad "$between line(s) between the backstop and the deadline are not plain assignments; one of them failing would arm only one timer"
  fi
fi

echo
if [ "$failures" = "0" ]; then
  say "MATRIX PLAN REFUSALS PINNED: fifteen cells, the per-repetition tail floor, the missing denominator, the ladder unchanged, and the backstop still ahead of the deadline."
else
  echo "FAILED: $failures assertion(s) above." >&2
  exit 1
fi
