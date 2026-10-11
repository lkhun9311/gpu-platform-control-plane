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

# The load the REGISTRATION names for the next run, not the wrapper's defaults.
#
# This matters and the first version of this file got it wrong. `hack/m5c-gpu-session.sh` still defaults to
# RATE=9.85, NOISY_WEIGHT=0.054, DURATION_MS=420000, and the pre-registration calls that "the seventh
# pilot's load, the one reading 4b rejected" (docs/superpowers/specs/2026-09-10-does-splitting-the-card-buy-
# protection.md). A plan check that pins the rejected load as its passing case teaches the gate the wrong
# plan: it would go green on precisely the run the registration refuses, and red if someone passed the
# registered one.
#
# They are written out rather than defaulted because the matrix refuses to default them: RATE alone does not
# describe this load, and a mix picked by the harness puts the 40,000-character contender at 45% of arrivals.
RATE=9.4045
NOISY_WEIGHT=0.0260
FULL_DURATION=505000

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
printf '%s' "$LAST_PLAN_OUT" | grep -q 'R1: 4655 premium, 0 contender' \
  && ok "R1 offers 4655 premium and no contender" \
  || bad "R1's planned trace is not premium-only: $(printf '%s' "$LAST_PLAN_OUT" | grep -o 'R1: [0-9]* premium, [0-9]* contender' | head -1 || true)"
printf '%s' "$LAST_PLAN_OUT" | grep -q 'shared: 4655 premium, 139 contender' \
  && ok "and the control carries the contender at the same premium schedule" \
  || bad "the control's planned trace is not the two-tenant one: $(printf '%s' "$LAST_PLAN_OUT" | grep -o 'shared: [0-9]* premium, [0-9]* contender' | head -1 || true)"

say "3. is a cell too short for the readings' floor refused BEFORE anything is rented?"
# This is the deliberate failure the open defect asked for, and the floor is bracketed rather than cleared
# by a wide margin. At the registered load gen-trace offers 109 premium requests over 12000 ms and 99 over
# 11000 ms; MinTailSamples is 100. A pair one on each side of it is what shows the check reads THAT floor and
# not a rounder number nearby.
#
# RegisteredEstimandFor applies the floor to the SMALLEST repetition tail, not the pool, so fifteen cells of
# 99 would pool 1485 and still be refused. That is why the check is per cell.
plan_case "a cell just above the per-repetition tail floor" ok \
  ARMS="R1 shared timeSlicing" REPS=1 RATE="$RATE" NOISY_WEIGHT="$NOISY_WEIGHT" DURATION_MS=12000
printf '%s' "$LAST_PLAN_OUT" | grep -q '109 premium' \
  && ok "and 12000 ms is accepted at 109 premium offers" \
  || bad "12000 ms did not report 109 premium offers: $(printf '%s' "$LAST_PLAN_OUT" | grep -o '[0-9]* premium' | head -1 || true)"
plan_case "a cell below the per-repetition tail floor" "could not be scored even if every request succeeded" \
  ARMS="R1 shared timeSlicing" REPS=5 RATE="$RATE" NOISY_WEIGHT="$NOISY_WEIGHT" DURATION_MS=11000
printf '%s' "$LAST_PLAN_OUT" | grep -q 'offers 99 premium requests' \
  && ok "and the refusal names the count it measured, one below the floor" \
  || bad "the refusal does not name 99 premium offers, so it may not have generated the trace it judged"
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

say "9. does a run that CLAIMS to reproduce a prior run get refused when its load differs?"
# THE CHECK THAT WOULD HAVE STOPPED A PAID RUN.
#
# On 2026-10-02 a five-repetition matrix was registered as a reproduction of the 2026-09-13 pilot and offered a
# 294-token premium prompt against that pilot's 50, with a 60-second timeout against its 30. Every refusal
# above passed it, because they ask whether a cell is SCORABLE and not whether it is the same load as the run
# it names. $2.16 bought a measurement whose headline purpose was unmeasurable, and the mismatch was found
# while drafting the publication.
#
# The target here is SYNTHESISED rather than read from an archive. The two real archives are gitignored run
# outputs, so a CI checkout has neither, and a section that skipped there would be a section that never runs
# where it matters. gen-trace builds a target with the provenance fields filled, because a target missing them
# refuses for the UNKNOWN reason before the load is ever compared -- which is correct, and is case 9e below.
TGT="$WORK/target"
mkdir -p "$TGT"
gen_target() { # gen_target <dir> <timeout-ms> <premium-chars> [--no-provenance]   (ARM=R1 varies the arm)
  # ARM exists for the study-binding case below, which needs a cell whose manifest arm MATCHES --arm.
  #
  # The arm check runs before the study check, so a study fixture built on the shared manifest while passing
  # --arm R1 is refused for the arm and never reaches the study comparison. That is what the first version of
  # this fixture did, and the assertion went red naming the wrong refusal.
  local dir="$1" timeout="$2" chars="$3" prov=1 arm="${ARM:-shared}"
  [ "${4:-}" = "--no-provenance" ] && prov=0
  local extra=()
  [ "$prov" = 1 ] && extra=(--tokenizer-rev aa8e72537993ba99e69dfaafa59ed015b17504d1
                            --engine-image "${GT_ENGINE:-vllm/vllm-openai@sha256:$(printf '0%.0s' $(seq 64))}"
                            --gateway-sha 0123456789abcdef0123456789abcdef01234567)
  # The gateway's image ID, unless the case is a plan (which has none until the image is built), and its content
  # when GT_BINARY names a binary hash (docs/superpowers/specs/2026-10-07-gateway-identity-for-reproduction.md).
  [ "$prov" = 1 ] && [ -z "${GT_NO_IMAGE:-}" ] && extra+=(--gateway-image "gateway:t@sha256:${GT_IMAGE_HEX:-$(printf 'a%.0s' $(seq 64))}")
  [ "$prov" = 1 ] && [ -n "${GT_BINARY:-}" ] && extra+=(--gateway-binary-sha256 "$GT_BINARY" --gateway-base "$GT_BASE")
  mkdir -p "$dir"
  "$WORK/benchharness" gen-trace --seed 11 --duration-ms "$FULL_DURATION" --rate "$RATE" \
    --premium-weight 1 --noisy-weight "$NOISY_WEIGHT" --probe-weight 0 \
    --study sharing-matrix-2026-09-10 --arm "$arm" --model Qwen/Qwen2.5-3B-Instruct \
    --gateway-url http://127.0.0.1:18080 \
    --premium-prompt-chars "$chars" --noisy-prompt-chars 42579 \
    --premium-output-tokens 64 --noisy-output-tokens 16 --timeout-ms "$timeout" "${extra[@]}" \
    --trace-out "$dir/trace-$arm-1.jsonl" --manifest-out "$dir/manifest-$arm-1.yaml" >/dev/null
}
# The plan side, which every case below compares against one of the targets.
PLAN="$WORK/plan-rp"
gen_target "$PLAN" 60000 1174
# rp_case <what> <want|ok> <target dir> [extra args...]
rp_case() {
  local what="$1" want="$2" dir="$3"; shift 3
  local out code
  set +e
  out=$("$WORK/benchharness" matrix-plan-check --trace "$PLAN/trace-shared-1.jsonl" \
        --study sharing-matrix-2026-09-10 --arm shared --arms "R1 shared timeSlicing" \
        --manifest "$PLAN/manifest-shared-1.yaml" --reproduces "$dir" "$@" 2>&1)
  code=$?
  set -e
  if [ "$want" = ok ]; then
    [ "$code" = 0 ] && ok "$what is accepted" || bad "$what was refused: $(printf '%s' "$out" | head -1)"
    return
  fi
  if [ "$code" = 0 ]; then bad "$what was ACCEPTED as a reproduction"; return; fi
  printf '%s' "$out" | grep -q "$want" \
    && ok "$what is refused, naming it" \
    || bad "$what exited $code without saying ${want@Q}: $(printf '%s' "$out" | head -1)"
}

gen_target "$TGT/same" 60000 1174
rp_case "a plan matching its target" ok "$TGT/same"

gen_target "$TGT/timeout" 30000 1174
rp_case "a plan whose timeout differs" "timeoutMs is 30000 in the target run and 60000 in this plan" "$TGT/timeout"

# The 2026-10-02 defect itself: 50 tokens against 294, which is 200 characters against 1,174.
#
# It must be refused by NAME, not by the checksum. A different prompt length always changes the trace bytes,
# so a checksum comparison placed first would refuse this with "not byte-identical" -- true, and useless to
# an operator who has to decide what to change. The first version of this file asserted the wrong one and
# caught it: the refusal said traceChecksum and the assertion wanted promptLenChars.
gen_target "$TGT/prompt" 60000 200
rp_case "the prompt length that was missed for real money" "promptLenChars" "$TGT/prompt"
printf '%s' "$($WORK/benchharness matrix-plan-check --trace "$PLAN/trace-shared-1.jsonl" \
  --study sharing-matrix-2026-09-10 --arm shared --arms "R1 shared timeSlicing" \
  --manifest "$PLAN/manifest-shared-1.yaml" --reproduces "$TGT/prompt" 2>&1 || true)" \
  | grep -q 'premium-1 was 200 characters and is now 1174' \
  && ok "and it names the tenant and both lengths" \
  || bad "the prompt-length refusal does not name premium-1 with 200 and 1174, so it does not say what to change"

gen_target "$TGT/bare" 60000 1174 --no-provenance
rp_case "a target that recorded no provenance" "cannot be certified" "$TGT/bare"
printf '%s' "$($WORK/benchharness matrix-plan-check --trace "$PLAN/trace-shared-1.jsonl" \
  --study sharing-matrix-2026-09-10 --arm shared --arms "R1 shared timeSlicing" \
  --manifest "$PLAN/manifest-shared-1.yaml" --reproduces "$TGT/bare" 2>&1 || true)" \
  | grep -q 'UNKNOWN' \
  && ok "and it says UNKNOWN rather than reporting no difference" \
  || bad "the refusal for an unrecorded field does not say UNKNOWN, so it reads as 'nothing differs'"

# The manifest has to describe the trace these counts came from, and nothing tied the two.
#
# --trace was read for the sample floors and --manifest was loaded separately for the reproduction
# comparison, so one cell's trace beside another cell's manifest passed while the two described different
# things -- including a hand-written manifest naming a load nobody generated. An external review found it on
# 2026-10-02, after the reproduction comparison itself had been reviewed twice.
set +e
out=$("$WORK/benchharness" matrix-plan-check --trace "$PLAN/trace-shared-1.jsonl" \
      --study sharing-matrix-2026-09-10 --arm shared --arms "R1 shared timeSlicing" \
      --manifest "$TGT/prompt/manifest-shared-1.yaml" --reproduces "$TGT/same" 2>&1)
code=$?
set -e
[ "$code" != 0 ] && printf '%s' "$out" | grep -q 'does not describe the trace this check counted' \
  && ok "a manifest describing a different trace than --trace is refused" \
  || bad "another cell's manifest was accepted beside this --trace (exit $code): $(printf '%s' "$out" | head -1)"

# And the manifest's arm has to be the cell being checked.
#
# The refusal names both, because "they disagree" leaves an operator to work out which of the two they
# mistyped at the end of a plan check that is otherwise green.
set +e
out=$("$WORK/benchharness" matrix-plan-check --trace "$PLAN/trace-shared-1.jsonl" \
      --study sharing-matrix-2026-09-10 --arm R1 --arms "R1 shared timeSlicing" \
      --manifest "$PLAN/manifest-shared-1.yaml" --reproduces "$TGT/same" 2>&1)
code=$?
set -e
[ "$code" != 0 ] && printf '%s' "$out" | grep -q 'records arm shared' \
  && ok "a manifest recording another arm is refused, naming both" \
  || bad "--arm R1 beside a shared manifest was accepted (exit $code): $(printf '%s' "$out" | head -1)"

# And the manifest's study has to be the registration scoring this cell.
#
# Three things had to line up for this fixture to reach the refusal it is about, and two of them cost a red
# run to find.
#
#   1. The study passed must be REGISTERED. The first probe used throughput-ladder-2026-09-15, which does not
#      exist, and was refused by "study is not registered" -- which looks like this check failing to fire.
#   2. The study must admit the arm. throughput-ladder-2026-09-13's arms are rung-prefixed, so --arm R1 is
#      refused before reaching here. price-of-protection-2026-09-05 and m5b-gateway-v1 both admit R1.
#   3. The manifest's arm must MATCH --arm, because the arm check runs first. The shared manifest with
#      --arm R1 is refused for the arm, so this case needs its own R1 cell.
ARM=R1 gen_target "$TGT/r1arm" 60000 1174
set +e
out=$("$WORK/benchharness" matrix-plan-check --trace "$TGT/r1arm/trace-R1-1.jsonl" \
      --study price-of-protection-2026-09-05 --arm R1 --arms "R1 shared timeSlicing" \
      --manifest "$TGT/r1arm/manifest-R1-1.yaml" --reproduces "$TGT/same" 2>&1)
code=$?
set -e
[ "$code" != 0 ] && printf '%s' "$out" | grep -q 'records study sharing-matrix-2026-09-10' \
  && ok "a manifest recording another study is refused, naming both" \
  || bad "--study beside a sharing-matrix manifest was accepted (exit $code): $(printf '%s' "$out" | head -1)"

# --manifest is required WITH --reproduces, because the claim is about the load this plan would offer.
set +e
out=$("$WORK/benchharness" matrix-plan-check --trace "$PLAN/trace-shared-1.jsonl" \
      --study sharing-matrix-2026-09-10 --arm shared --arms "R1 shared timeSlicing" \
      --reproduces "$TGT/same" 2>&1)
code=$?
set -e
[ "$code" != 0 ] && printf '%s' "$out" | grep -q 'needs --manifest' \
  && ok "--reproduces without --manifest is refused rather than skipped" \
  || bad "--reproduces without --manifest did not refuse (exit $code): $(printf '%s' "$out" | head -1)"

# An explicitly empty --reproduces is a caller's mistake and must not read as "claims nothing".
#
# A mutation made the matrix pass `--reproduces "${REPRODUCES:-}"` unconditionally and no test noticed, which
# means a shell that interpolated an unset variable would have claimed nothing and passed.
set +e
out=$("$WORK/benchharness" matrix-plan-check --trace "$PLAN/trace-shared-1.jsonl" \
      --study sharing-matrix-2026-09-10 --arm shared --arms "R1 shared timeSlicing" \
      --manifest "$PLAN/manifest-shared-1.yaml" --reproduces "" 2>&1)
code=$?
set -e
[ "$code" != 0 ] && printf '%s' "$out" | grep -q 'empty value' \
  && ok "an explicitly empty --reproduces is refused, not read as claiming nothing" \
  || bad "--reproduces \"\" behaved like omitting the flag (exit $code): $(printf '%s' "$out" | head -1)"

# And a plan that claims NOTHING must behave exactly as it did before this existed.
set +e
out=$("$WORK/benchharness" matrix-plan-check --trace "$PLAN/trace-shared-1.jsonl" \
      --study sharing-matrix-2026-09-10 --arm shared --arms "R1 shared timeSlicing" 2>&1)
code=$?
set -e
[ "$code" = 0 ] && printf '%s' "$out" | grep -q 'scorable' && ! printf '%s' "$out" | grep -q 'matches' \
  && ok "a plan claiming no reproduction is unaffected" \
  || bad "a plan with no --reproduces changed behaviour (exit $code): $(printf '%s' "$out" | head -1)"

say "9g. is the gateway compared by content when both runs recorded it, and by image ID when the target did not?"
# Issue 323: one binary on one pinned base, built twice, gives two image IDs, and a plan has no image ID at all
# because the image is built after purchase. Measured on 2026-10-07; the rule is the 2026-10-07 registration.
GT_BASE="gcr.io/distroless/static@sha256:e2e927ec666bae08560abb3c55d0659eceabb657f56b6782ab500a9fc7f555e3"
BIN_A=$(printf 'a%.0s' $(seq 64)); BIN_B=$(printf 'b%.0s' $(seq 64))
export GT_BASE
# rp_with <what> <want|ok> <plan dir> <target dir>
rp_with() {
  local what="$1" want="$2" plan="$3" dir="$4" out code
  set +e
  out=$("$WORK/benchharness" matrix-plan-check --trace "$plan/trace-shared-1.jsonl" \
        --study sharing-matrix-2026-09-10 --arm shared --arms "R1 shared timeSlicing" \
        --manifest "$plan/manifest-shared-1.yaml" --reproduces "$dir" 2>&1)
  code=$?
  set -e
  if [ "$want" = ok ]; then
    [ "$code" = 0 ] && ok "$what is accepted" || bad "$what was refused: $(printf '%s' "$out" | head -1)"
  elif [ "$code" != 0 ] && printf '%s' "$out" | grep -q "$want"; then
    ok "$what is refused, naming it"
  else
    bad "$what exited $code without saying ${want@Q}: $(printf '%s' "$out" | head -1)"
  fi
}
GT_BINARY="$BIN_A" gen_target "$TGT/content" 60000 1174
GT_BINARY="$BIN_A" GT_IMAGE_HEX=$(printf 'c%.0s' $(seq 64)) gen_target "$WORK/plan-rebuilt" 60000 1174
rp_with "a rebuild of the same binary on the same base (a second image ID)" ok "$WORK/plan-rebuilt" "$TGT/content"
GT_BINARY="$BIN_A" GT_NO_IMAGE=1 gen_target "$WORK/plan-noimage" 60000 1174
rp_with "a plan with the content and no image ID, as every plan has" ok "$WORK/plan-noimage" "$TGT/content"
GT_BINARY="$BIN_B" GT_NO_IMAGE=1 gen_target "$WORK/plan-otherbin" 60000 1174
rp_with "a different gateway binary under the same commit" "gatewayBinarySHA256" "$WORK/plan-otherbin" "$TGT/content"
rp_with "a plan with the content against a target that recorded only the image ID" "imageDigests differ -- gateway" \
  "$WORK/plan-noimage" "$TGT/same"
rp_with "a plan with no content against a target that recorded it" "this plan records neither" "$PLAN" "$TGT/content"

# And the matrix's own plan path, which is what a reproduction purchase actually runs.
#
# The target is made with the matrix's engine image and the plan's defaults, so the only fact left to differ
# is the gateway binary the plan is given.
GW_FAKE_A="$WORK/gw-a"; GW_FAKE_B="$WORK/gw-b"
printf 'gateway a' > "$GW_FAKE_A"; printf 'gateway b' > "$GW_FAKE_B"; chmod +x "$GW_FAKE_A" "$GW_FAKE_B"
matrix_engine=$(sed -n 's/^ *image: *\(vllm[^ ]*@sha256:[0-9a-f]\{64\}\).*/\1/p' config/vllm/deployment.yaml | head -1)
for arm in R1 shared; do
  ARM=$arm GT_ENGINE="$matrix_engine" GT_BINARY=$(sha256sum "$GW_FAKE_A" | cut -c1-64) \
    gen_target "$TGT/matrix" 60000 1174
done
rp_env=(ARMS="R1 shared" REPS=1 RATE="$RATE" NOISY_WEIGHT="$NOISY_WEIGHT" DURATION_MS="$FULL_DURATION"
        PREMIUM_PROMPT_CHARS=1174 NOISY_PROMPT_CHARS=42579 SOURCE_COMMIT=0123456789abcdef0123456789abcdef01234567
        REPRODUCES="$TGT/matrix")
plan_case "a reproduction plan with no gateway binary to name" "REPRODUCES needs GATEWAY_BIN" "${rp_env[@]}"
plan_case "a reproduction plan shipping the target's gateway binary" ok "${rp_env[@]}" GATEWAY_BIN="$GW_FAKE_A"
plan_case "a reproduction plan shipping another gateway binary" "gatewayBinarySHA256" "${rp_env[@]}" GATEWAY_BIN="$GW_FAKE_B"

say "9h. does the S1 confirmation's registered plan generate and score, nine cells at seed 47?"
# Its trace lengths in hack/lib/instrument-validation.sh were read off the generator's spans; a span that outgrew them
# is a gen-trace refusal here, before purchase, rather than on the card.
# An episode study takes no load variables, so this calls the matrix without plan_case's PREMIUM_WEIGHT.
set +e
confirm_out=$(env TMPDIR="$WORK/tmp" PLAN_ONLY=1 PLATFORM=kind KCTX=none BENCHHARNESS_BIN="$WORK/benchharness" \
  OUT="$WORK/out-confirm" STUDY=step-confirm-2026-10-07 ARMS="serial-step burst-step stagger-step" REPS=3 SEEDS=47 \
  bash hack/m5c-matrix.sh 2>&1)
confirm_code=$?
set -e
[ "$confirm_code" = 0 ] && printf '%s' "$confirm_out" | grep -q 'PLAN OK under study step-confirm-2026-10-07' \
  && ok "the confirmation's nine cells generate and score" \
  || bad "the confirmation's plan was refused (exit $confirm_code): $(printf '%s' "$confirm_out" | grep -E 'REFUSED|FAILED' | head -1)"
printf '%s' "$confirm_out" | grep -q 'plan: 9 cell(s): stagger-step' \
  && ok "and its first cell is a staggered one, the longest, as the step-boundary session's was" \
  || bad "the confirmation's plan does not start with its staggered cell: $(printf '%s' "$confirm_out" | grep 'plan:')"

say "10b. does the run record WHERE each load value came from?"
# The refusal compares the EFFECTIVE value, so a wrong default is caught. What it cannot tell a later reader
# is whether the value was declared or inherited -- and that is the question the 2026-10-02 archive could not
# answer: its user-data set all five to empty, the wrapper exports only non-empty values, so the matrix used
# its own defaults and the manifest recorded 1174 with nothing saying 1174 was a default.
#
# Asserted on the artefact rather than on the intention, the way section 7 checks what was left behind.
ls_out="$WORK/ls-$RANDOM"
set +e
env TMPDIR="$WORK/tmp" PLAN_ONLY=1 PLATFORM=kind KCTX=none BENCHHARNESS_BIN="$WORK/benchharness" \
    OUT="$ls_out" ARMS="R1 shared" REPS=1 RATE="$RATE" PREMIUM_WEIGHT=1 \
    NOISY_WEIGHT="$NOISY_WEIGHT" PROBE_WEIGHT=0 DURATION_MS="$FULL_DURATION" \
    PREMIUM_PROMPT_CHARS=1174 bash hack/m5c-matrix.sh >/dev/null 2>&1
set -e
if [ -f "$ls_out/load-source.txt" ]; then
  ok "the run writes load-source.txt beside its evidence"
  grep -q 'PREMIUM_PROMPT_CHARS: 1174 (declared)' "$ls_out/load-source.txt" \
    && ok "and it marks a value the caller passed as declared" \
    || bad "a declared premium length was not recorded as declared: $(grep PREMIUM_PROMPT_CHARS "$ls_out/load-source.txt" | head -1)"
  grep -q 'NOISY_OUTPUT_TOKENS: 16 (default of' "$ls_out/load-source.txt" \
    && ok "and it marks an inherited value as this script's default" \
    || bad "an inherited output cap was not recorded as a default: $(grep NOISY_OUTPUT_TOKENS "$ls_out/load-source.txt" | head -1)"
  # Five load fields plus the tokenizer revision, because a count is what catches a field quietly dropped.
  ls_lines=$(grep -cE '^(PREMIUM_PROMPT_CHARS|NOISY_PROMPT_CHARS|REQUEST_TIMEOUT_MS|PREMIUM_OUTPUT_TOKENS|NOISY_OUTPUT_TOKENS|MODEL_REVISION): ' "$ls_out/load-source.txt" || true)
  [ "$ls_lines" = 6 ] \
    && ok "all five frozen fields and the tokenizer revision carry a source" \
    || bad "load-source.txt names $ls_lines of the 6 expected fields"
else
  bad "the run left no load-source.txt, so the archive cannot say whether a load value was declared or defaulted"
fi

say "10. is a load that differs from the study's FROZEN TUPLE refused before anything is rented?"
# THE FIVE QUANTITIES THE REGISTRATION FROZE AND NOTHING COMPARED.
#
# The seventh amendment froze premium and contender prompt characters, the request timeout, and both output
# caps on 2026-10-01. Measured on 2026-10-02: every one of them could be overridden on the command line and
# this very plan check passed unchanged. The CR path enforced only the two lengths -- compile-plan resolves
# those from the measured table -- while the timeout and both caps came straight from the CR with no
# comparison at all. So four of the five had no enforcement on any path, and the fifth only on one.
#
# FIVE, not four: the output caps are two fields. Counting them as one is how a check gets written for four.
#
# These cases run the matrix script itself rather than benchharness, because the thing under test is the
# shell's comparison. They are cheap: a refused run exits before generating any trace, so only the control
# below pays for trace generation, and it buys two cells rather than fifteen.
fz_env=(PLAN_ONLY=1 BENCHHARNESS_BIN="$WORK/benchharness" ARMS="R1 shared" REPS=1
        RATE="$RATE" PREMIUM_WEIGHT=1 NOISY_WEIGHT="$NOISY_WEIGHT" PROBE_WEIGHT=0
        DURATION_MS="$FULL_DURATION" REGISTRY=stub.local/x)
# fz_case <what> <want-in-output|ok> [extra env...]
fz_case() {
  local what="$1" want="$2"; shift 2
  local out code
  set +e
  out=$(env "${fz_env[@]}" "$@" bash hack/m5c-matrix.sh 2>&1)
  code=$?
  set -e
  if [ "$want" = ok ]; then
    printf '%s' "$out" | grep -q "load matches study" \
      && ok "$what reaches the plan with its load accepted" \
      || bad "$what did not report a matching load (exit $code): $(printf '%s' "$out" | grep -iE 'mismatch|FAILED' | head -1)"
    return
  fi
  if [ "$code" = 0 ]; then bad "$what was ACCEPTED"; return; fi
  printf '%s' "$out" | grep -q "$want" \
    && ok "$what is refused, naming it" \
    || bad "$what exited $code without saying ${want@Q}: $(printf '%s' "$out" | grep -iE 'mismatch|FAILED' | head -1)"
}

fz_case "the frozen load" ok
fz_case "a premium prompt length that is not frozen"   "premium prompt characters"  PREMIUM_PROMPT_CHARS=200
fz_case "a contender prompt length that is not frozen" "contender prompt characters" NOISY_PROMPT_CHARS=40000
fz_case "a timeout that is not frozen"                 "request timeout in ms"      REQUEST_TIMEOUT_MS=30000
fz_case "a premium output cap that is not frozen"      "premium output cap"         PREMIUM_OUTPUT_TOKENS=8
fz_case "a contender output cap that is not frozen"    "contender output cap"       NOISY_OUTPUT_TOKENS=4
# The caps SWAPPED, which is the case a single combined check would pass: both values are still frozen
# values, just assigned to the wrong tenants.
fz_case "the two output caps swapped" "output cap" PREMIUM_OUTPUT_TOKENS=16 NOISY_OUTPUT_TOKENS=64

# THE PLAN RAN UNDER THE STUDY THAT WAS ASKED FOR, which every check above is blind to.
#
# `fz_case ... ok` greps for "load matches study" and does not read WHICH study followed those words. That is
# exactly the shape of the defect this section exists for. Measured on 2026-10-04 against the previous
# revision: `STUDY=tail-crossing-lc256-2026-10-04` with the frozen five printed
# "PLAN OK: every planned cell generates a trace the readings can score", the requested id appeared NOWHERE
# in the output, and the plan stood under sharing-matrix-2026-09-10 -- because the matrix branch assigned
# that id unconditionally. The two tail-crossing studies freeze the same five quantities as the sharing
# matrix at the short level, so the frozen-tuple comparison above passed as well: two checks green, and the
# experiment the operator asked for was never planned.
#
# So the assertion is on the IDENTITY in the output, not on the exit code. A run that cannot name the study
# it planned cannot be audited afterwards either -- the archive's load-source.txt carries the same value.
# The tail-crossing studies register independent arrivals and one arm per BE level since 2026-10-04, so they
# are planned as a SWEEP -- PREMIUM_RATE held, the BE rate stepped -- and never with the matrix's weighted
# RATE, NOISY_WEIGHT and ARMS, which the runner refuses beside a sweep.
sweep_env=(PLAN_ONLY=1 BENCHHARNESS_BIN="$WORK/benchharness" REPS=1
           PREMIUM_WEIGHT=1 PROBE_WEIGHT=0 PREMIUM_RATE=0.2864 SWEEP=0.0286
           DURATION_MS="$FULL_DURATION" REGISTRY=stub.local/x)
env_for() { # <study> -> the base environment that study is planned with, in BASE_ENV
  case "$1" in
    tail-crossing-*) BASE_ENV=("${sweep_env[@]}") ;;
    *) BASE_ENV=("${fz_env[@]}") ;;
  esac
}
study_case() { # <what> <study> <premium-chars> <noisy-chars>
  local what="$1" study="$2" pchars="$3" nchars="$4" out code
  env_for "$study"
  set +e
  # One seed: a per-repetition study needs one per repetition and this plan has one repetition, and a study
  # replaying one trace accepts a single seed. The seed rules themselves are the cases below.
  out=$(env "${BASE_ENV[@]}" STUDY="$study" PREMIUM_PROMPT_CHARS="$pchars" NOISY_PROMPT_CHARS="$nchars" SEEDS=7 \
        bash hack/m5c-matrix.sh 2>&1)
  code=$?
  set -e
  if [ "$code" != 0 ]; then
    bad "$what exited $code instead of planning: $(printf '%s' "$out" | grep -iE 'mismatch|FAILED' | head -1)"
    return
  fi
  # Both places the id has to appear: the frozen-load line proves the comparison used it, and the verdict
  # proves a reader of the last line can tell which experiment passed.
  printf '%s' "$out" | grep -q "load matches study $study" \
    || { bad "$what planned, but the frozen-load line does not name $study: $(printf '%s' "$out" | grep -i 'load matches' | head -1)"; return; }
  printf '%s' "$out" | grep -q "PLAN OK under study $study" \
    || { bad "$what planned, but the verdict does not name $study: $(printf '%s' "$out" | grep -i 'PLAN OK' | head -1)"; return; }
  ok "$what plans under $study and both the comparison and the verdict say so"
}

# Each registered level, at ITS OWN frozen load. The short level shares the sharing matrix's five values,
# which is why naming it is the only way to tell the two apart.
study_case "the sharing matrix"          sharing-matrix-2026-09-10      1174  42579
study_case "the short latency-sensitive level" tail-crossing-lc256-2026-10-04 1174  42579
study_case "the long latency-sensitive level"  tail-crossing-lc8192-2026-10-04 42579 42579
study_case "the 2,048-token level"             tail-crossing-lc2048-2026-10-05 10532 42579

# The seed list against the study's trace policy, refused before anything is rented.
#
# Every archive before 2026-10-04 replayed seed 11 in every repetition. The tail-crossing studies now
# register a trace per repetition and the report refuses an arm whose repetitions share one -- after the
# cells are bought. These are the refusals that move that judgement ahead of the purchase.
seed_case() { # <what> <want: ok or a phrase> <VAR=value ...>
  local what="$1" want="$2" out code a; shift 2
  BASE_ENV=("${fz_env[@]}")
  for a in "$@"; do case "$a" in STUDY=*) env_for "${a#STUDY=}" ;; esac; done
  set +e
  out=$(env "${BASE_ENV[@]}" PREMIUM_PROMPT_CHARS=1174 NOISY_PROMPT_CHARS=42579 "$@" bash hack/m5c-matrix.sh 2>&1)
  code=$?
  set -e
  if [ "$want" = ok ]; then
    [ "$code" = 0 ] && ok "$what is planned" || bad "$what was refused: $(printf '%s' "$out" | grep -E 'FAILED|REFUSED' | head -1)"
  elif [ "$code" != 0 ] && printf '%s' "$out" | grep -q "$want"; then
    ok "$what is refused, naming it"
  else
    bad "$what exited $code without saying ${want@Q}: $(printf '%s' "$out" | tail -2 | tr '\n' ' ')"
  fi
}
seed_case "a per-repetition study with no seeds" "registers a trace per repetition" STUDY=tail-crossing-lc256-2026-10-04 REPS=2
seed_case "a per-repetition study with one seed twice" "repeats a seed" STUDY=tail-crossing-lc256-2026-10-04 REPS=2 SEEDS="7 7"
seed_case "a per-repetition study with fewer seeds than repetitions" "names 1 seed(s) and REPS is 2" STUDY=tail-crossing-lc256-2026-10-04 REPS=2 SEEDS=7
seed_case "a seed that is not a number" "not a non-negative integer" STUDY=tail-crossing-lc256-2026-10-04 REPS=1 SEEDS=x
seed_case "one seed spelled two ways" "leading zero" STUDY=tail-crossing-lc256-2026-10-04 REPS=2 SEEDS="7 07"
seed_case "a seed of zero" ok STUDY=tail-crossing-lc256-2026-10-04 REPS=2 SEEDS="0 7"
seed_case "a one-trace study given two seeds" "names 2 different seeds" STUDY=sharing-matrix-2026-09-10 REPS=2 SEEDS="7 8"
seed_case "a per-repetition study with a distinct seed per repetition" ok STUDY=tail-crossing-lc256-2026-10-04 REPS=2 SEEDS="7 8"
seed_case "the sharing matrix with no seeds, as every archive ran" ok STUDY=sharing-matrix-2026-09-10 REPS=2
# The sweep itself: what it is refused beside, and what it builds.
sweep_case() { # <what> <want: ok or a phrase> <VAR=value ...>; starts from the sweep environment
  local what="$1" want="$2" out code; shift 2
  set +e
  out=$(env "${sweep_env[@]}" STUDY=tail-crossing-lc256-2026-10-04 SEEDS=7 PREMIUM_PROMPT_CHARS=1174 NOISY_PROMPT_CHARS=42579 "$@" bash hack/m5c-matrix.sh 2>&1)
  code=$?
  set -e
  LAST_SWEEP_OUT="$out"
  if [ "$want" = ok ]; then
    [ "$code" = 0 ] && ok "$what is planned" || bad "$what was refused: $(printf '%s' "$out" | grep -E 'FAILED|REFUSED' | head -1)"
  elif [ "$code" != 0 ] && printf '%s' "$out" | grep -q "$want"; then
    ok "$what is refused, naming it"
  else
    bad "$what exited $code without saying ${want@Q}: $(printf '%s' "$out" | tail -2 | tr '\n' ' ')"
  fi
}
sweep_case "a three-level sweep" ok SWEEP="0.0286 0.0716 0.1432"
for want_arm in R1 be01-shared be02-shared be03-shared; do
  printf '%s' "$LAST_SWEEP_OUT" | grep -q "  $want_arm:" \
    || bad "the three-level sweep did not plan $want_arm"
done
# Each level's contender count rises with its rate while the latency-critical count stays where it is: the
# property the report's pairing rests on, read from the plan's own lines.
sweep_lc=$(printf '%s\n' "$LAST_SWEEP_OUT" | awk '/^==   (R1|be0[1-3]-shared): / {print $3}' | sort -u | awk 'END {print NR}')
# Sorted by level, because the plan lists a repetition's cells in its randomised order.
sweep_be=$(printf '%s\n' "$LAST_SWEEP_OUT" | awk '/^==   be0[1-3]-shared: / {print $2, $5}' | LC_ALL=C sort | awk '{print $2}' | tr '\n' ' ')
if [ "$sweep_lc" = 1 ] && printf '%s' "$sweep_be" | awk '{exit !(NF == 3 && $1 < $2 && $2 < $3)}'; then
  ok "one latency-critical count across the baseline and all three levels, and contender counts rising ($sweep_be)"
else
  bad "the sweep planned $sweep_lc distinct premium count(s) and contender counts ${sweep_be@Q}; want 1 and three rising"
fi
# The order within each repetition is randomised, reproducibly from the block's seed, and the blocks still
# each hold the baseline and every level once. A fixed order would put one level in one slot every block.
sweep_case "a three-repetition sweep" ok REPS=3 SEEDS="7 8 9" SWEEP="0.0286 0.0716 0.1432"
order1=$(printf '%s' "$LAST_SWEEP_OUT" | sed -n 's/^== plan: [0-9]* cell(s): //p')
sweep_case "the same sweep again" ok REPS=3 SEEDS="7 8 9" SWEEP="0.0286 0.0716 0.1432"
order2=$(printf '%s' "$LAST_SWEEP_OUT" | sed -n 's/^== plan: [0-9]* cell(s): //p')
blocks_ok=$(printf '%s\n' $order1 | awk '{b[int((NR-1)/4)] = b[int((NR-1)/4)] " " $1} END {
  ok = (NR == 12); for (i = 0; i < 3; i++) { n = split(b[i], a, " "); delete seen
    for (j = 1; j <= n; j++) seen[a[j]]++
    if (n != 4 || !seen["R1"] || !seen["be01-shared"] || !seen["be02-shared"] || !seen["be03-shared"]) ok = 0 }
  print ok }')
distinct_blocks=$(printf '%s\n' $order1 | awk '{b[int((NR-1)/4)] = b[int((NR-1)/4)] " " $1} END {for (i in b) print b[i]}' | sort -u | awk 'END {print NR}')
if [ -n "$order1" ] && [ "$order1" = "$order2" ] && [ "$blocks_ok" = 1 ] && [ "$distinct_blocks" -ge 2 ]; then
  ok "each repetition holds the baseline and all three levels once, in an order that differs between blocks ($distinct_blocks distinct) and repeats exactly from the same seeds: $order1"
else
  bad "sweep order ${order1@Q} then ${order2@Q}: blocks complete=$blocks_ok, distinct block orders=$distinct_blocks; want complete blocks, at least two orders, and the same plan twice"
fi
# And the frozen sharing matrix keeps the order it registered: repetition-major, arms as listed.
sweep_case "the sharing matrix's order" ok STUDY=sharing-matrix-2026-09-10 SWEEP= PREMIUM_RATE= SEEDS= RATE="$RATE" NOISY_WEIGHT="$NOISY_WEIGHT" ARMS="R1 shared" REPS=2
matrix_order=$(printf '%s' "$LAST_SWEEP_OUT" | sed -n 's/^== plan: [0-9]* cell(s): //p' | tr -s ' ' | sed 's/ $//')
[ "$matrix_order" = "R1 shared R1 shared" ] \
  && ok "the sharing matrix still runs R1 then shared in every repetition" \
  || bad "the sharing matrix's order became ${matrix_order@Q}; its registration fixed R1 then shared"
sweep_case "an independent-arrival study planned without a sweep" "run as a SWEEP" SWEEP= PREMIUM_RATE= RATE="$RATE" NOISY_WEIGHT="$NOISY_WEIGHT"
sweep_case "a sweep of the weighted sharing matrix" "a sweep needs a study registered with independent arrivals" STUDY=sharing-matrix-2026-09-10 SEEDS=
sweep_case "a sweep beside a total RATE" "RATE and SWEEP are both set" RATE=0.3
sweep_case "a sweep beside an arm list" "ARMS and SWEEP are both set" ARMS="R1 shared"
sweep_case "a held rate with no sweep" "PREMIUM_RATE is set without SWEEP" SWEEP= RATE="$RATE" NOISY_WEIGHT="$NOISY_WEIGHT"
sweep_case "a sweep with no held rate" "PREMIUM_RATE is not" PREMIUM_RATE=
sweep_case "seven levels" "admit six levels" SWEEP="0.01 0.02 0.03 0.04 0.05 0.06 0.07"
sweep_case "one rate twice" "repeats a rate" SWEEP="0.0286 0.0286"
sweep_case "one rate spelled two ways" "repeats a rate" SWEEP="0.0286 0.02860"
# The banner the REAL path prints, run under `set -u` with each mode's variables and nothing else.
#
# PLAN_ONLY exits before it, so every plan case above passes whether or not it works, and the sweep's first
# version died on it with "RATE: unbound variable" -- after the cluster and the images were built, on the
# path a paid run takes. The ladder had already died there once for the same reason.
lb=$(awk '/^load_banner\(\) \{/ {i=1} i {print} i && /^\}/ {exit}' hack/m5c-matrix.sh)
lb_run() { # <mode> -> exit status of the banner under set -u with only that mode's variables
  env -i PATH="$PATH" bash -c 'set -u; say() { echo "$*"; }; '"$lb"'
    DURATION_MS=600000 PREMIUM_WEIGHT=1 PROBE_WEIGHT=0 REPS=2 PLATFORM=eks OUT=/x STUDY=s
    case "$1" in
      sweep)  LADDER=""; SWEEP="0.0286 0.0716"; PREMIUM_RATE=0.2864; SEEDS="7 8"; ARMS="R1 be01-shared be02-shared" ;;
      ladder) LADDER="1:0.5 2:0.5"; SWEEP="" ;;
      matrix) LADDER=""; SWEEP=""; RATE=9.4; NOISY_WEIGHT=0.026; ARMS="R1 shared" ;;
    esac
    load_banner' _ "$1" 2>&1
}
for mode in sweep ladder matrix; do
  if out=$(lb_run "$mode"); then
    ok "the real path's load banner runs under set -u for a $mode: $(printf '%s' "$out" | head -1 | cut -c1-90)"
  else
    bad "the real path's load banner dies for a $mode: $out"
  fi
done
sweep_case "a rate that is not a number" "not a plain positive decimal" SWEEP="0.02x"
sweep_case "a rate of zero" "is not positive" SWEEP="0"

# The shell's options are the script's, not any one function's.
#
# refuse_unfrozen_load once read `set +e; ...; set -e` and so switched ON an errexit the matrix never had
# (line 33 is `set -uo pipefail`). Nothing PLAN_ONLY runs afterwards fails a command it tolerates, so every
# case above stayed green; on the real path the second cell's `kill; wait` of the previous gateway forward
# returned non-zero and the matrix ended with no message -- on the kind rehearsal since 2026-10-03, and on
# the 2026-10-04 calibration bought on a rented card, which stopped after one cell of four.
ruf=$(awk '/^refuse_unfrozen_load\(\) \{/ {i=1} i {print} i && /^\}/ {exit}' hack/m5c-matrix.sh)
printf '#!/bin/sh\ncase "$1" in study-frozen-tuple) echo FROZEN_PREMIUM_PROMPT_CHARS=1; echo FROZEN_NOISY_PROMPT_CHARS=2; echo FROZEN_REQUEST_TIMEOUT_MS=3; echo FROZEN_PREMIUM_OUTPUT_TOKENS=4; echo FROZEN_NOISY_OUTPUT_TOKENS=5 ;; esac\n' > "$WORK/ruf-bh"
chmod +x "$WORK/ruf-bh"
mkdir -p "$WORK/ruf"; cp "$WORK/ruf-bh" "$WORK/ruf/benchharness"
ruf_opts=$(env -i PATH="$PATH" WORK="$WORK/ruf" bash -c 'set -uo pipefail; say() { :; }; fail() { echo "FAILED: $*"; exit 1; }; '"$ruf"'
  STUDY=s PREMIUM_PROMPT_CHARS=1 NOISY_PROMPT_CHARS=2 REQUEST_TIMEOUT_MS=3 PREMIUM_OUTPUT_TOKENS=4 NOISY_OUTPUT_TOKENS=5
  before=$-; refuse_unfrozen_load; echo "$before $-"' 2>&1)
case "$ruf_opts" in
  *e*" "* | *" "*e*) bad "refuse_unfrozen_load changed the caller's options (before, after): ${ruf_opts@Q}; an errexit switched on here ends the second cell of every real run" ;;
  *" "*) [ "${ruf_opts% *}" = "${ruf_opts#* }" ] \
           && ok "refuse_unfrozen_load returns with the caller's shell options unchanged (${ruf_opts% *})" \
           || bad "refuse_unfrozen_load changed the caller's options (before, after): ${ruf_opts@Q}" ;;
  *) bad "refuse_unfrozen_load did not return normally: ${ruf_opts@Q}" ;;
esac
# And no line of the matrix switches errexit on, which is the invariant its own comments state.
errexit_lines=$(awk '/^[^#]*(^|[;&| ])set -e([ ;]|$)/ {print NR}' hack/m5c-matrix.sh | tr '\n' ' ')
[ -z "$errexit_lines" ] \
  && ok "no line of the matrix runs set -e" \
  || bad "the matrix runs set -e at line(s) $errexit_lines; it is written for set -uo pipefail and a kill; wait is fatal under errexit"

# And the seed each repetition is generated from, driven directly: a plan that passes says nothing about
# WHICH seed went into each trace, and a seed_for_rep returning 11 for every repetition would plan cleanly.
sfr=$(awk '/^seed_for_rep\(\) \{/ {i=1} i {print} i && /^\}/ {exit}' hack/m5c-matrix.sh)
sfr_got=$(bash -c "$sfr"'
  SEEDS="7 8 9"; TRACE_POLICY=per-repetition; printf "%s," "$(seed_for_rep 1)" "$(seed_for_rep 2)" "$(seed_for_rep 3)"
  SEEDS=""; TRACE_POLICY=one; printf "%s," "$(seed_for_rep 2)"
  SEEDS="5"; TRACE_POLICY=one; printf "%s" "$(seed_for_rep 3)"')
[ "$sfr_got" = "7,8,9,11,5" ] \
  && ok "repetitions 1-3 draw seeds 7, 8, 9; an empty list keeps 11; a one-trace study uses its single seed for every repetition" \
  || bad "seed_for_rep gave ${sfr_got@Q}; want '7,8,9,11,5'"
# The run path resolves the seeds too, and ahead of the frozen-load refusal that must stay next to the spend.
sd_call=$(grep -n '^resolve_seeds$' hack/m5c-matrix.sh | tail -1 | cut -d: -f1 || true)
fz_call2=$(grep -n '^refuse_unfrozen_load$' hack/m5c-matrix.sh | tail -1 | cut -d: -f1 || true)
if [ -n "$sd_call" ] && [ -n "$fz_call2" ] && [ "$sd_call" -lt "$fz_call2" ]; then
  ok "the real path resolves the seeds at line $sd_call, before the frozen-load refusal at $fz_call2"
else
  bad "the real path does not resolve the seeds before its last pre-spend refusal (seeds ${sd_call:-none}, refusal ${fz_call2:-none})"
fi
# And the generated traces use them: both gen-trace call sites read the per-repetition seed, none the literal.
# awk, because zero matches is the PASSING answer here and `grep | wc -l` under pipefail and `set -e` ends
# the harness on it -- which is what the first version of this check did, silently.
gt_literal=$(awk '/^[^#]*gen-trace --seed 11/ {c++} END {print c+0}' hack/m5c-matrix.sh)
gt_seeded=$(awk '/^[^#]*gen-trace --seed "\$/ {c++} END {print c+0}' hack/m5c-matrix.sh)
[ "$gt_literal" = 0 ] && [ "$gt_seeded" = 2 ] \
  && ok "both gen-trace call sites take the repetition's seed" \
  || bad "gen-trace call sites: $gt_literal with the literal seed 11 and $gt_seeded reading a seed; want 0 and 2"

# A study this path does not file evidence under is refused BEFORE a trace is generated.
#
# Each of these is registered -- they are not typos -- and each would be caught eventually by a later guard
# for a different reason: the ladder studies reach the per-cell scoring floor, and price-of-protection has no
# frozen tuple. Measured: removing the allow-list leaves both red, with messages about cells that cannot be
# scored and a tuple that cannot be read. So this is pinned as a question about WHEN and WITH WHAT WORDS the
# refusal arrives, which is what an operator reads, and not as the only thing standing between them and a
# mis-filed run.
study_refused() { # <what> <study>
  local what="$1" study="$2" out code
  set +e
  out=$(env "${fz_env[@]}" STUDY="$study" PREMIUM_PROMPT_CHARS=1174 NOISY_PROMPT_CHARS=42579 \
        bash hack/m5c-matrix.sh 2>&1)
  code=$?
  set -e
  [ "$code" != 0 ] || { bad "$what was ACCEPTED by the non-ladder matrix"; return; }
  printf '%s' "$out" | grep -q "STUDY is .$study." \
    && ok "$what is refused by name, ahead of trace generation" \
    || bad "$what exited $code without the allow-list naming it: $(printf '%s' "$out" | grep -iE 'FAILED' | head -1)"
}
study_refused "a ladder study on the matrix path" throughput-ladder-2026-09-13
study_refused "the price-of-protection study"     price-of-protection-2026-08-07
study_refused "an unregistered id"                not-a-study-2026

# AND THE ALLOW-LIST STANDS AHEAD OF THE FROZEN COMPARISON, asserted by ORDER rather than by running it.
#
# This is the half of the defect the identity checks above cannot reach. The short level freezes the same
# five quantities as the sharing matrix, so when the study was overwritten the frozen comparison passed --
# it was comparing the right load against the wrong study's tuple and could not tell. Ordering is what makes
# that unreachable: by the time `refuse_unfrozen_load` runs, $STUDY is already either one of the three this
# path admits or the run is over.
#
# Checked as a fact about the FILE, the way section 8 checks the backstop's lead, because no run can observe
# it: a run that reaches the comparison has already passed the allow-list, so the two can never both be seen
# failing. What this must exclude is a future edit that moves the allow-list after either point.
# The CR block's own line is the reference point, not the two consumers.
#
# A first version compared the allow-list only against `gen-trace` and `refuse_unfrozen_load`, and a
# mutation that moved the assignment to line 605 PASSED it: the trace generation it was supposed to precede
# had been pushed to 606 by the move itself, so "605 < 606" was true and the assertion reported the
# allow-list as ahead of a line it was now adjacent to. A relative comparison against a line the edit can
# displace is not an ordering claim. Pinning it against the compiled-CR block instead gives a fixed
# reference: that block is where the run's load guards begin, it cannot move without the assertion below
# noticing, and anything ahead of it is ahead of every spend.
al_line=$(grep -n 'STUDY="\${STUDY:-sharing-matrix-2026-09-10}"' hack/m5c-matrix.sh | head -1 | cut -d: -f1 || true)
fz_line=$(grep -n '^refuse_unfrozen_load$' hack/m5c-matrix.sh | head -1 | cut -d: -f1 || true)
gt_line=$(grep -n 'gen-trace --seed' hack/m5c-matrix.sh | head -1 | cut -d: -f1 || true)
cr_line=$(grep -n '^if \[ -n "\${BENCHMARK_CR_SHA256:-}" \]; then$' hack/m5c-matrix.sh | head -1 | cut -d: -f1 || true)
if [ -n "$al_line" ] && [ -n "$fz_line" ] && [ -n "$gt_line" ] && [ -n "$cr_line" ] \
   && [ "$al_line" -lt "$cr_line" ] && [ "$cr_line" -lt "$gt_line" ] && [ "$cr_line" -lt "$fz_line" ]; then
  ok "the study allow-list is at line $al_line, ahead of the compiled-CR block at $cr_line, which is itself ahead of the first trace generation at $gt_line and the frozen comparison at $fz_line"
else
  bad "could not establish that the study allow-list precedes the CR block and that the CR block precedes trace generation and the frozen-load comparison (allow-list ${al_line:-none}, CR block ${cr_line:-none}, trace ${gt_line:-none}, frozen ${fz_line:-none})"
fi
# The allow-list is also OUTSIDE the compiled-CR block, which is what the original defect depended on: the
# STUDY_FROM_CR guard sat inside `if [ -n "${BENCHMARK_CR_SHA256:-}" ]`, so a run without a compiled CR
# reached the unconditional assignment with nothing having looked at $STUDY at all.
cr_line=$(grep -n '^if \[ -n "\${BENCHMARK_CR_SHA256:-}" \]; then$' hack/m5c-matrix.sh | head -1 | cut -d: -f1 || true)
if [ -n "$al_line" ] && [ -n "$cr_line" ] && [ "$al_line" -lt "$cr_line" ]; then
  ok "and it is outside the compiled-CR block, which begins at line $cr_line, so a run with no CR is judged too"
else
  bad "the study allow-list is not ahead of the compiled-CR block (allow-list ${al_line:-none}, block ${cr_line:-none}); a run without BENCHMARK_CR_SHA256 would reach the cell builder unjudged"
fi

# A failing, silent or short lookup must refuse rather than fall back to the script's defaults.
#
# Falling back is precisely how an unchecked load reached a rented card: hack/m5c-matrix.sh declares all five
# as `${VAR:-default}`, so a comparison that gave up would leave the defaults in place and call them frozen.
printf '#!/bin/sh\nexit 3\n' > "$WORK/fz-fail"; chmod +x "$WORK/fz-fail"
fz_case "a frozen-tuple lookup that fails" "could not read study" BENCHHARNESS_BIN="$WORK/fz-fail"
printf '#!/bin/sh\nexit 0\n' > "$WORK/fz-empty"; chmod +x "$WORK/fz-empty"
fz_case "a frozen-tuple lookup that prints nothing" "did not carry the" BENCHHARNESS_BIN="$WORK/fz-empty"
cat > "$WORK/fz-short" <<'SHORT'
#!/bin/sh
case "$1" in
  study-frozen-tuple)
    echo FROZEN_PREMIUM_PROMPT_CHARS=1174
    echo FROZEN_NOISY_PROMPT_CHARS=42579
    echo FROZEN_REQUEST_TIMEOUT_MS=60000
    echo FROZEN_PREMIUM_OUTPUT_TOKENS=64
    exit 0 ;;
  study-arrivals) echo weighted; exit 0 ;;
  *) exit 0 ;;
esac
SHORT
chmod +x "$WORK/fz-short"
fz_case "a frozen-tuple lookup missing one field" "contender output cap" BENCHHARNESS_BIN="$WORK/fz-short"

# The CR path is not exempt. A compiled plan carries the five values as exports like any other caller, so
# the same mismatch has to be refused there -- otherwise "it came from a CR" becomes a way around the tuple.
fz_cr=(BENCHMARK_CR_SHA256=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
       BENCHMARK_CR_TOKENIZER_REV=aa8e72537993ba99e69dfaafa59ed015b17504d1
       MODEL_REVISION=aa8e72537993ba99e69dfaafa59ed015b17504d1
       PREMIUM_PROMPT_CHARS=1174 NOISY_PROMPT_CHARS=42579 REQUEST_TIMEOUT_MS=60000
       PREMIUM_OUTPUT_TOKENS=64 NOISY_OUTPUT_TOKENS=16)
fz_case "a compiled CR plan at the frozen load" ok "${fz_cr[@]}"
fz_case "a compiled CR plan at an unfrozen premium length" "premium prompt characters" \
  "${fz_cr[@]}" PREMIUM_PROMPT_CHARS=200

# The LADDER registers its own lengths and must not be judged by the matrix's tuple.
#
# The down ladder's contender is 40,000 characters against the matrix's 42,579, and the ladder studies freeze
# no tuple at all. A refusal keyed on the common gen-trace path would block a run that has never been bought.
set +e
out=$(env PLAN_ONLY=1 BENCHHARNESS_BIN="$WORK/benchharness" LADDER="1.16:0.3" \
      PREMIUM_WEIGHT=1 PROBE_WEIGHT=0 DURATION_MS="$FULL_DURATION" REGISTRY=stub.local/x \
      PREMIUM_PROMPT_CHARS=200 NOISY_PROMPT_CHARS=40000 bash hack/m5c-matrix.sh 2>&1)
set -e
printf '%s' "$out" | grep -q 'froze no load tuple' && ! printf '%s' "$out" | grep -q 'FROZEN LOAD MISMATCH' \
  && ok "a ladder at its own lengths is not judged by the matrix's frozen tuple" \
  || bad "the ladder was judged by the matrix tuple: $(printf '%s' "$out" | grep -iE 'mismatch|froze no' | head -1)"

# AND THE REFUSAL IS AHEAD OF THE FIRST BILLABLE ACTION, asserted by ORDER rather than by running it.
#
# Reaching that line for real needs a cluster: between it and the matrix's own entry sit the node-join,
# node-group, sharing-node, label, DEADLINE_EPOCH and ClusterRole guards. So the property is checked the way
# section 8 checks the backstop's lead -- as a fact about the file -- and the thing it must exclude is a
# future edit that moves the refusal after the build.
fz_call=$(grep -n '^refuse_unfrozen_load$' hack/m5c-matrix.sh | tail -1 | cut -d: -f1 || true)
# The EXECUTABLE line, not the comment that describes it.
#
# `grep -n 'docker build -q'` matched the explanatory comment twelve lines above the call and the
# assertion then reported a build at 1076 that is a comment. The ordering conclusion survived -- the
# refusal is ahead of both -- but the line it named was not the spend, and the gap it measured stopped
# short of it.
fz_build=$(grep -nE '^[^#]*docker build -q' hack/m5c-matrix.sh | head -1 | cut -d: -f1 || true)
if [ -n "$fz_call" ] && [ -n "$fz_build" ] && [ "$fz_call" -lt "$fz_build" ]; then
  ok "the real path's frozen-load refusal is at line $fz_call, ahead of the first docker build at $fz_build"
else
  bad "could not establish that the frozen-load refusal precedes the first billable action (refusal ${fz_call:-none}, build ${fz_build:-none})"
fi
# Nothing but a file write between them, so the refusal is not merely earlier -- it is immediately earlier.
fz_between=$(awk -v a="${fz_call:-0}" -v b="${fz_build:-0}" \
  'NR>a && NR<b && !/^[[:space:]]*#/ && NF && !/Dockerfile/' hack/m5c-matrix.sh | wc -l)
[ "$fz_between" = 0 ] \
  && ok "and nothing but the Dockerfile write stands between them" \
  || bad "$fz_between executable line(s) appeared between the refusal and the image build; the refusal is no longer immediately ahead of the spend"
# Both entry points call it, because a check on one path approves a plan the other would reject.
fz_calls=$(grep -c 'refuse_unfrozen_load' hack/m5c-matrix.sh || true)
[ "$fz_calls" -ge 3 ] \
  && ok "both the plan-only and the real path call the refusal (${fz_calls} references including the definition)" \
  || bad "refuse_unfrozen_load is referenced ${fz_calls} time(s); it must be defined and called on both paths"

echo
if [ "$failures" = "0" ]; then
  say "MATRIX PLAN REFUSALS PINNED: fifteen cells, the per-repetition tail floor, the missing denominator, the ladder unchanged, the backstop still ahead of the deadline, and a reproduction claim checked against the load it names, and a load that differs from the study's frozen tuple refused on both paths ahead of the first spend, and the plan standing under the study that was asked for -- named in the comparison and in the verdict, because the three registered levels share enough of their frozen tuples that an exit code cannot tell them apart."
else
  echo "FAILED: $failures assertion(s) above." >&2
  exit 1
fi
