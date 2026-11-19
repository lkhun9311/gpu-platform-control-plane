#!/usr/bin/env bash
#
# Offline checks for hack/vllm-gdn-68414-session.sh run 2, the runner and state scripts it ships, its three verdicts and its pytest summary, run before anything is bought.
# The EC2 lifecycle is hack/lib/spot-run.sh's, which the 58420 and 67811 tests cover; these checks cover what is new or changed here.
# That is the purchase option and its cost refusals, the schedule, the pins and their isolation proof, the five states in fresh containers, the import checks, the run commands, and that only the expected combination of each item is called "confirmed".
# The runner's whole path runs against a fake docker that executes the state scripts on a fake tree, a stub torch, a fake kernel_repro.py that answers from the index.py Python imports, and a fake pytest that answers per test file from the files Python imports.
#
#   bash hack/vllm-gdn-68414-session-test.sh                      # offline only
#   VLLM_SRC=~/workspace/oss/vllm bash hack/vllm-gdn-68414-session-test.sh   # also re-derives every pin from git
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
S="$ROOT/hack/vllm-gdn-68414-session.sh"
DIR="$ROOT/hack/vllm-gdn-68414"
R="$DIR/runner.sh"
LIBS="$DIR/lib.sh"
ST="$DIR/state.sh"
KST="$DIR/kda-state.sh"
SST="$DIR/stride-state.sh"
V="$DIR/verdict.py"
KV="$DIR/kda-verdict.py"
SV="$DIR/stride-verdict.py"
PS="$DIR/pytest-summary.py"
RR="$DIR/run_repro.py"
WORK=$(mktemp -d)
[ -n "${KEEP_WORK:-}" ] || trap 'rm -rf "$WORK"' EXIT
failures=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1" >&2; failures=$((failures + 1)); fi; }
REAL_PY=$(command -v python3)
STORAGE=/home/lkhun9311/workspace/storage/open-source/contributions/vllm
OPS=vllm/third_party/flash_linear_attention/ops
IDX=$OPS/index.py
GT=tests/kernels/fla/test_chunk_indices.py
KDA=$OPS/kda.py
KT=tests/kernels/fla/test_fused_recurrent_kda.py
FR=$OPS/fused_recurrent.py
FSG=$OPS/fused_sigmoid_gating.py
STT=tests/kernels/fla/test_state_index_stride.py
SEVEN="$IDX $GT $KDA $KT $FR $FSG $STT"
BASE_COMMIT=8700cc9ba0016bf14d8f2756f3b673e93fbcf2fd
FIXED='unwritten 0 o_err 0.0 state_err 0.0 empty_keeps_h0 True'
BUGGY='unwritten 70 o_err 1234.100830078125 state_err nan empty_keeps_h0 True'
sv() { grep -m1 "^$1=" "$S" | cut -d= -f2; }

check "the session, the runner and the state scripts parse, and the verdicts, the summary and the wrapper compile" \
  "bash -n '$S' && bash -n '$R' && bash -n '$LIBS' && bash -n '$ST' && bash -n '$KST' && bash -n '$SST' && bash -n '$DIR/derive-pins.sh' && python3 -m py_compile '$V' '$KV' '$SV' '$PS' '$RR'"

# ---------------------------------------------------------------- schedule and cost
same=1
for pair in PULL_BOUND_S:PULL_S IMAGE_ID_S:IMAGE_ID_S SETUP_S:SETUP_S REPRO_S:REPRO_S UNIT_S:UNIT_S PYTEST_S:PYTEST_S STOP_S:STOP_S; do
  a=$(sv "${pair%%:*}"); b=$(grep -m1 "^${pair#*:}=" "$R" | cut -d= -f2)
  [ -n "$a" ] && [ "$a" = "$b" ] || { echo "  ${pair%%:*}=$a in the session, ${pair#*:}=$b in the runner" >&2; same=0; }
done
check "every step bound in the session is the runner's own" "[ $same = 1 ]"
# The runner's container bounds are its step bounds' sums, the ones the session's schedule adds up.
check "the runner bounds #68414 AFTER by setup + repro + new test + stop, and each other state by setup + pytest + stop, four times" \
  "grep -qF 'contained state.sh gdn-after \$(( SETUP_S + REPRO_S + UNIT_S + STOP_S ))' '$R' && [ \"\$(grep -cF '\$(( SETUP_S + PYTEST_S + STOP_S ))' '$R')\" = 4 ] && grep -qxF 'STATES_S=\$(( (SETUP_S + REPRO_S + UNIT_S + STOP_S) + 4 * (SETUP_S + PYTEST_S + STOP_S) ))' '$S'"
# The container gets its bound less STOP_S, and the kill grace, the removal and its check each get a third of STOP_S, so a state ends within its bound.
check "a state that hits every limit still ends within its container bound, so it takes no time from the next item" \
  "grep -qF 'timeout --kill-after=\$(( STOP_S / 3 )) \"\$(left \$(( bound - STOP_S )))\" docker run' '$R' && grep -qF 'timeout \$(( STOP_S / 3 )) docker rm -f' '$R' && grep -qF 'left_over=\$(timeout \$(( STOP_S / 3 )) docker ps' '$R'"
sched=$(PURCHASE=spot bash "$S" --print-schedule 2>&1)
check "the schedule is the bounds' sum ($sched)" "[ '$sched' = 'harness_end_s=3420 evidence_s=3540 stop_s=3600 termination_s=3900' ]"
check "the schedule is the same for both purchase options" "[ \"\$(PURCHASE=on-demand bash '$S' --print-schedule 2>&1)\" = '$sched' ]"
spot_worst=$(python3 -c 'print(f"{3900 / 3600 * 0.7792:.4f}")')
od_worst=$(python3 -c 'print(f"{3900 / 3600 * (1.237 + 0.0792):.4f}")')
check "the spot worst case, 3,900 s at \$0.7792/h, is \$$spot_worst, and the on-demand one at the pinned \$1.237 + \$0.0792/h is \$$od_worst, both under \$1.50" \
  "[ \"\$(sv SPOT_ALL_IN_RATE)\" = 0.7792 ] && [ \"\$(sv ON_DEMAND_RATE_PINNED)\" = 1.237 ] && [ \"\$(sv EBS_IP_RATE)\" = 0.0792 ] && [ \"\$(sv COST_CAP_USD)\" = 1.50 ] && [ '$spot_worst' = 0.8441 ] && [ '$od_worst' = 1.4259 ]"
check "the session's header states both worst cases and the highest on-demand rate it accepts" \
  "grep -qF 'so \$0.7792/h all in, and \$0.8441.' '$S' && grep -qF 'it is \$1.3162/h all in, and \$1.4259;' '$S' && grep -qF 'any compute rate above \$1.3054/h' '$S'"
check "the instance is a g5.xlarge, and Spot tries the reclaimed zone last" \
  "grep -qx 'INSTANCE_TYPE_FIXED=g5.xlarge' '$S' && grep -qx '    RECLAIMED_ZONES=\"ap-northeast-2a\"' '$S'"
costly() { cp "$S" "$WORK/costly.sh"; sed -i "$1" "$WORK/costly.sh"; ! PURCHASE=$2 bash "$WORK/costly.sh" --print-schedule > "$WORK/costly.out" 2>&1 && grep -qF "$3" "$WORK/costly.out"; }
check "a Spot rate that puts the worst case at \$1.50 or more is refused, before the schedule prints" \
  "costly 's/^SPOT_ALL_IN_RATE=.*/SPOT_ALL_IN_RATE=1.40/' spot 'the spot worst case'"
check "a pinned on-demand rate over the cap is refused even for a Spot run, so neither option can drift over" \
  "costly 's/^ON_DEMAND_RATE_PINNED=.*/ON_DEMAND_RATE_PINNED=1.40/' spot 'the on-demand worst case'"
check "a bound that stretches the schedule past \$1.50 is refused too" \
  "costly 's/^REPRO_S=.*/REPRO_S=3000/' spot 'is not under \$1.50'"

# ---------------------------------------------------------------- the purchase option
# A fake aws that records every call and answers the read-only calls the purchase helpers make.
mkdir -p "$WORK/awsbin"
cat > "$WORK/awsbin/aws" <<'EOF'
#!/bin/bash
echo "aws $*" >> "$AWS_CALLS"
case "$1 $2" in
  "pricing get-products")
    [ -z "${FAKE_PRICING_FAIL:-}" ] || { echo "An error occurred (AccessDeniedException)" >&2; exit 254; }
    [ -z "${FAKE_PRICING_GARBAGE:-}" ] || { echo '["not json"]'; exit 0; }
    python3 -c '
import json, sys
items = [json.dumps({"terms": {"OnDemand": {"t%d" % i: {"priceDimensions": {"d": {"unit": "Hrs", "pricePerUnit": {"USD": p}}}}}}})
         for i, p in enumerate(sys.argv[1].split(","))]
print(json.dumps(items))' "$FAKE_OD_PRICE" ;;
  "ec2 describe-spot-price-history") printf 'ap-northeast-2a\t0.6178\nap-northeast-2c\t0.6311\nap-northeast-2d\t0.7500\n' ;;
  "ec2 describe-instance-type-offerings") printf 'ap-northeast-2d\tap-northeast-2a\tap-northeast-2c\n' ;;
  "sts get-caller-identity") echo 007635145730 ;;
  "ec2 run-instances") echo i-0fake ;;
esac
EOF
chmod +x "$WORK/awsbin/aws"
export AWS_CALLS="$WORK/aws-calls"
# fake_session OUTFILE ENV... ARGS...: the session with the fake aws first on PATH, and nothing of the caller's PURCHASE or confirmation.
fake_session() {
  local out=$1; shift
  : > "$AWS_CALLS"
  env -u SESSION_CONFIRM -u VLLMGDN_AMI_ID -u PURCHASE PATH="$WORK/awsbin:$PATH" OUT="$WORK/never" "$@" > "$out" 2>&1
}
fake_session "$WORK/p-unset" bash "$S" --print-schedule; rc=$?
check "without PURCHASE even the schedule is refused, before any AWS call" \
  "[ $rc != 0 ] && grep -qF 'PURCHASE is unset' '$WORK/p-unset' && [ ! -s '$AWS_CALLS' ] && [ ! -e '$WORK/never' ]"
fake_session "$WORK/p-unset2" env SESSION_CONFIRM=yes VLLMGDN_AMI_ID=ami-0123456789abcdef0 bash "$S"; rc=$?
check "without PURCHASE a confirmed session with an AMI is refused on PURCHASE first, before any AWS call" \
  "[ $rc != 0 ] && [ \"\$(head -1 '$WORK/p-unset2')\" = 'SESSION REFUSED: PURCHASE is unset; set PURCHASE=spot or PURCHASE=on-demand, since the session has no default purchase option' ] && [ ! -s '$AWS_CALLS' ]"
fake_session "$WORK/p-empty" env PURCHASE= bash "$S" --print-schedule; rc=$?
check "an empty PURCHASE is refused like an unset one" "[ $rc != 0 ] && grep -qF 'PURCHASE is unset' '$WORK/p-empty'"
fake_session "$WORK/p-bogus" env PURCHASE=reserved bash "$S" --print-schedule; rc=$?
check "a PURCHASE other than spot or on-demand is refused" "[ $rc != 0 ] && grep -qF \"PURCHASE is 'reserved', not spot or on-demand\" '$WORK/p-bogus'"
fake_session "$WORK/p-spot" env PURCHASE=spot bash "$S" --print-purchase; rc=$?
check "spot's rate is its cap and needs no AWS call" \
  "[ $rc = 0 ] && grep -qx 'purchase=spot compute_rate=0.70 all_in_rate=0.7792 worst_case_usd=0.8441' '$WORK/p-spot' && [ ! -s '$AWS_CALLS' ]"
fake_session "$WORK/p-od" env PURCHASE=on-demand FAKE_OD_PRICE=1.2370000000 bash "$S" --print-purchase; rc=$?
check "on-demand reads the price with one read-only Price List call for g5.xlarge in ap-northeast-2, and its worst case is \$1.4259" \
  "[ $rc = 0 ] && grep -qx 'purchase=on-demand compute_rate=1.237 all_in_rate=1.3162 worst_case_usd=1.4259' '$WORK/p-od' && grep -q '^rate_source=AWS Price List API get-products, read ' '$WORK/p-od' && [ \"\$(wc -l < '$AWS_CALLS')\" = 1 ] && grep -q '^aws pricing get-products --region us-east-1 --service-code AmazonEC2 .*instanceType,Value=g5.xlarge.*regionCode,Value=ap-northeast-2' '$AWS_CALLS'"
fake_session "$WORK/p-odhigh" env PURCHASE=on-demand FAKE_OD_PRICE=1.40 bash "$S" --print-purchase; rc=$?
check "an on-demand price whose worst case is over \$1.50 is refused" \
  "[ $rc != 0 ] && grep -qF 'SESSION REFUSED: the on-demand worst case, 3900 s at \$1.4792/h all in' '$WORK/p-odhigh' && grep -qF 'is \$1.6025, not under \$1.50' '$WORK/p-odhigh' && ! grep -q '^purchase=' '$WORK/p-odhigh'"
fake_session "$WORK/p-odedge" env PURCHASE=on-demand FAKE_OD_PRICE=1.3054 bash "$S" --print-purchase; rc1=$?
fake_session "$WORK/p-odover" env PURCHASE=on-demand FAKE_OD_PRICE=1.3055 bash "$S" --print-purchase; rc2=$?
check "the on-demand cap falls between \$1.3054/h, accepted, and \$1.3055/h, refused" "[ $rc1 = 0 ] && [ $rc2 != 0 ]"
fake_session "$WORK/p-odtwo" env PURCHASE=on-demand FAKE_OD_PRICE=1.20,1.40 bash "$S" --print-purchase; rc=$?
check "an answer with two prices is judged at the higher one" "[ $rc != 0 ] && grep -qF '(\$1.4/h from AWS Price List API' '$WORK/p-odtwo'"
fake_session "$WORK/p-odfail" env PURCHASE=on-demand FAKE_PRICING_FAIL=1 bash "$S" --print-purchase; rc=$?
check "a failed price read falls back to the pinned \$1.237/h, says so with its source, and still checks the cap" \
  "[ $rc = 0 ] && grep -qx 'purchase=on-demand compute_rate=1.237 all_in_rate=1.3162 worst_case_usd=1.4259' '$WORK/p-odfail' && grep -qF 'rate_source=pinned: AWS Price List API APN2-BoxUsage:g5.xlarge OnDemand 1.2370000000 USD/Hrs, effective 2026-11-01, read 2026-11-19 (the live read failed: An error occurred (AccessDeniedException)' '$WORK/p-odfail'"
fake_session "$WORK/p-odjunk" env PURCHASE=on-demand FAKE_PRICING_GARBAGE=1 bash "$S" --print-purchase; rc=$?
check "an unreadable price answer falls back to the pinned rate too" "[ $rc = 0 ] && grep -q '^rate_source=pinned: ' '$WORK/p-odjunk'"
fake_session "$WORK/z-spot" env PURCHASE=spot bash "$S" --print-zones; rc=$?
check "spot tries only zones under its cap, from the Spot price, with the reclaimed zone last" \
  "[ $rc = 0 ] && grep -qx 'zones=ap-northeast-2c ap-northeast-2a' '$WORK/z-spot' && grep -q 'describe-spot-price-history' '$AWS_CALLS' && ! grep -q 'describe-instance-type-offerings' '$AWS_CALLS'"
fake_session "$WORK/z-od" env PURCHASE=on-demand bash "$S" --print-zones; rc=$?
check "on-demand tries every zone offering g5.xlarge, in order, and reads no Spot price" \
  "[ $rc = 0 ] && grep -qx 'zones=ap-northeast-2a ap-northeast-2c ap-northeast-2d' '$WORK/z-od' && grep -q 'describe-instance-type-offerings --region ap-northeast-2 --location-type availability-zone --filters Name=instance-type,Values=g5.xlarge' '$AWS_CALLS' && ! grep -q 'spot-price' '$AWS_CALLS'"
check "the purchase reads the rate, the zones and the quota for its own option, and launches with it" \
  "grep -qx 'purchase_rate' '$S' && grep -qx 'purchase_zones' '$S' && grep -qF 'then QUOTA_CODE=L-3819A6DF; QUOTA_NAME=\"G and VT Spot\"; else QUOTA_CODE=L-DB2E81BA;' '$S' && grep -qF '\"\$EBS_THROUGHPUT_MIBPS\" \"\$EBS_IOPS\" \"\$PURCHASE\" 2>\"\$OUT/launch-error-\$z.txt\")' '$S'"
check "the launch loop records each zone's error and goes on only for capacity, whichever the option" \
  "grep -qF 'cat \"\$OUT/launch-error-\$z.txt\" >>\"\$OUT/launch-errors.txt\"' '$S' && grep -qF \"if grep -qiE 'InsufficientInstanceCapacity|capacity-not-available' \\\"\\\$OUT/launch-error-\\\$z.txt\\\"; then LAUNCH_UNCERTAIN=\\\"\\\"; continue; fi\" '$S'"
check "the provenance records the option, the rate, its source and the worst case" \
  "grep -qF 'echo \"purchase=\$PURCHASE\"' '$S' && grep -qF 'echo \"compute_rate_source=\$RATE_SOURCE\"' '$S' && grep -qF 'echo \"worst_case_usd=\$(worst_usd \"\$ALL_IN_RATE\")\"' '$S'"

# spot_launch's purchase option, against the same fake aws: Spot keeps its market options, on-demand sends none.
deadline=$(date -u -d '+1 hour' +%Y-%m-%dT%H:%M:%SZ)
launch() {
  : > "$AWS_CALLS"
  env PATH="$WORK/awsbin:$PATH" bash -c '. "$1/hack/lib/spot-run.sh"; shift; spot_launch "$@"' _ "$ROOT" ap-northeast-2 ami-0123456789abcdef0 g5.xlarge subnet-x prof 0.70 200 /dev/null \
    "ResourceType=instance,Tags=[{Key=study-deadline,Value=$deadline}]" tok "" "" 500 6000 "$@" > "$WORK/launch.out" 2>&1
}
launch spot; rc=$?
check "spot_launch with spot sends the Spot market options with the cap" \
  "[ $rc = 0 ] && grep -qF -- '--instance-market-options {\"MarketType\":\"spot\",\"SpotOptions\":{\"MaxPrice\":\"0.70\",\"SpotInstanceType\":\"one-time\"}}' '$AWS_CALLS'"
cp "$AWS_CALLS" "$WORK/calls-spot"
launch; rc=$?
check "spot_launch without the option is exactly the Spot launch, so the other sessions are unchanged" "[ $rc = 0 ] && cmp -s '$AWS_CALLS' '$WORK/calls-spot'"
launch on-demand; rc=$?
check "spot_launch with on-demand sends no market options and keeps everything else" \
  "[ $rc = 0 ] && grep -q 'run-instances' '$AWS_CALLS' && ! grep -q 'market-options\|MaxPrice' '$AWS_CALLS' && [ \"\$(sed 's| --instance-market-options [^ ]*||' '$WORK/calls-spot')\" = \"\$(cat '$AWS_CALLS')\" ]"
launch reserved; rc=$?
check "spot_launch refuses any other option before calling EC2" "[ $rc != 0 ] && [ ! -s '$AWS_CALLS' ] && grep -q 'not spot or on-demand' '$WORK/launch.out'"

# ---------------------------------------------------------------- refusals
fake_session "$WORK/refusal.out" env PURCHASE=spot bash "$S"
check "without SESSION_CONFIRM=yes the session is refused and calls no AWS API" \
  "grep -q 'SESSION_CONFIRM=yes is required' '$WORK/refusal.out' && [ ! -s '$AWS_CALLS' ] && [ ! -e '$WORK/never' ]"
fake_session "$WORK/refusal.out" env PURCHASE=on-demand SESSION_CONFIRM=yes bash "$S"
check "without a pinned AMI ID the session is refused and calls no AWS API" \
  "grep -q 'VLLMGDN_AMI_ID is unset' '$WORK/refusal.out' && [ ! -s '$AWS_CALLS' ]"
fake_session "$WORK/refusal.out" env PURCHASE=spot SESSION_CONFIRM=yes VLLMGDN_AMI_ID=ami-0123456789abcdef0 VLLM_COMMIT=0000000 bash "$S"
check "a caller who sets one of the session's own values is refused" \
  "grep -q 'VLLM_COMMIT is set' '$WORK/refusal.out' && [ ! -s '$AWS_CALLS' ]"

# ---------------------------------------------------------------- the user-data
PURCHASE=spot bash "$S" --print-user-data > "$WORK/ud.sh" 2> "$WORK/ud.err"
first_cmd=$(grep -n -v -E '^(#|$)' "$WORK/ud.sh" | sed -n '4p')
first_aws=$(grep -n -m1 'aws ' "$WORK/ud.sh" | cut -d: -f1)
check "the user-data parses, is under 16 KB, and has no placeholder left" \
  "[ -s '$WORK/ud.sh' ] && bash -n '$WORK/ud.sh' && [ \$(wc -c < '$WORK/ud.sh') -lt 16384 ] && ! grep -q _PLACEHOLDER '$WORK/ud.sh'"
check "the user-data is the same for both purchase options" "cmp -s '$WORK/ud.sh' <(PURCHASE=on-demand bash '$S' --print-user-data 2>/dev/null)"
check "the instance refuses a driver older than 580 before the pull" \
  "grep -q 'PREFLIGHT FAILED: driver' '$WORK/ud.sh' && [ \"\$(grep -n 'PREFLIGHT FAILED: driver' '$WORK/ud.sh' | cut -d: -f1)\" -lt \"\$(grep -n 'runner.sh' '$WORK/ud.sh' | head -1 | cut -d: -f1)\" ]"
check "the instance arms its 3,600 s backstop before anything else can fail ($first_cmd)" \
  "[ '${first_cmd#*:}' = '( sleep 3600; shutdown -h now ) &' ] && [ '${first_cmd%%:*}' -lt '$first_aws' ]"
check "the precise backstop counts from LaunchTime, and the runner ends at LaunchTime + 3,420 s" \
  "grep -q '( sleep \$(( L + 3600 - ' '$WORK/ud.sh' && grep -q 'HE=\$(( L + 3420 ))' '$WORK/ud.sh' && grep -q 'EV=\$(( L + 3540 ))' '$WORK/ud.sh' && grep -q 'P1=\$(( L + 480 ))' '$WORK/ud.sh'"
check "the instance runs this session's runner and returns this session's records" \
  "grep -q 'bash /opt/gdn/in/runner.sh /opt/gdn/in /src/gdn-run/sweep' '$WORK/ud.sh' && ! grep -qE 'tp-run|/opt/tp/' '$WORK/ud.sh'"

# ---------------------------------------------------------------- the diffs and the pins
dsha() { sha256sum "$1" | cut -d' ' -f1; }
check "the session pins every diff and the repro at their own sha256, and the state script holds the same repro pin" \
  "[ \"\$(dsha '$DIR/fix.diff')\" = \"\$(sv FIX_DIFF_SHA256)\" ] && [ \"\$(dsha '$DIR/kda-fix.diff')\" = \"\$(sv KDA_FIX_DIFF_SHA256)\" ] && [ \"\$(dsha '$DIR/kda-test.diff')\" = \"\$(sv KDA_TEST_DIFF_SHA256)\" ] && [ \"\$(dsha '$DIR/stride-fix.diff')\" = \"\$(sv STRIDE_FIX_DIFF_SHA256)\" ] && [ \"\$(dsha '$DIR/stride-test.diff')\" = \"\$(sv STRIDE_TEST_DIFF_SHA256)\" ] && [ \"\$(dsha '$DIR/kernel_repro.py')\" = \"\$(sv REPRO_SHA256)\" ] && [ \"\$(grep -m1 '^REPRO_SHA256=' '$ST' | cut -d= -f2)\" = \"\$(sv REPRO_SHA256)\" ]"
check "the fix diffs are the re-saved ones storage pushed in 70ebfea0, by their sha256" \
  "[ \"\$(sv FIX_DIFF_SHA256)\" = 761dc3ef1b95c451463fd5eb017e8e98123ef6f3e274c72891dca9cbefe58dc1 ] && [ \"\$(sv KDA_FIX_DIFF_SHA256)\" = f896c4800c2494e1c0bd9ab0be44d56709886568599d664e5fb81909290d0ada ] && [ \"\$(sv STRIDE_FIX_DIFF_SHA256)\" = 7f872cff76664724bd2767ede70490f05bda0a65d475ceb5fdcd4bc6a141488d ]"
if [ -d "$STORAGE" ]; then
  check "each fix diff is the storage copy byte for byte" \
    "cmp -s '$STORAGE/gdn-chunk-indices-68414/fix.diff' '$DIR/fix.diff' && cmp -s '$STORAGE/kda-output-shape-68415/fix.diff' '$DIR/kda-fix.diff' && cmp -s '$STORAGE/state-index-stride-68416/fix.diff' '$DIR/stride-fix.diff'"
else
  echo "skip the fix diffs against storage (not readable here)"
fi
check "#68414's diff is the final one, with output_size, and not run 1's" \
  "grep -qxF '+        output_size=indices.numel(),' '$DIR/fix.diff' && [ \"\$(dsha '$DIR/fix.diff')\" != c75343ff6066abb233398110147cb3410de75e39d034633bf409ea1233f6756c ]"
# test_diff TEST FIX TESTPATH VLLMPATHS: the test diff is the fix diff's first part, the new test file alone.
test_diff() {
  cmp -s <(head -c "$(wc -c < "$1")" "$2") "$1" && [ "$(grep '^diff --git' "$1")" = "diff --git a/$3 b/$3" ] &&
    [ "$(grep '^diff --git' "$2" | awk '{print substr($3, 3)}' | paste -sd' ')" = "$3 $4" ]
}
check "kda-test.diff is kda-fix.diff's first part, the new test file and nothing under vllm/" "test_diff '$DIR/kda-test.diff' '$DIR/kda-fix.diff' $KT $KDA"
check "stride-test.diff is stride-fix.diff's first part, the new test file and nothing under vllm/" "test_diff '$DIR/stride-test.diff' '$DIR/stride-fix.diff' $STT '$FR $FSG'"
check "fix.diff adds the new test and changes index.py alone" \
  "[ \"\$(grep '^diff --git' '$DIR/fix.diff' | awk '{print substr(\$3, 3)}' | paste -sd' ')\" = '$GT $IDX' ]"
check "the session ships every state script, its pins, its diffs, the shared lib and the repro in its inputs" \
  "grep -qF 'cp \"\$RUNNER\" \"\$LIB\" \"\$STATE\" \"\$PINS\" \"\$FIX_DIFF\" \"\$REPRO\" \"\$RUN_REPRO\" \"\$OUT/in/\"' '$S' && grep -qF 'cp \"\$KDA_STATE\" \"\$KDA_PINS\" \"\$KDA_FIX_DIFF\" \"\$KDA_TEST_DIFF\" \"\$OUT/in/\"' '$S' && grep -qF 'cp \"\$STRIDE_STATE\" \"\$STRIDE_PINS\" \"\$STRIDE_FIX_DIFF\" \"\$STRIDE_TEST_DIFF\" \"\$OUT/in/\"' '$S'"
check "the session checks all five diffs and the repro against their pins before packing them" \
  "[ \"\$(grep -c '_DIFF:\\\$[A-Z_]*_DIFF_SHA256\\|REPRO:\\\$REPRO_SHA256' '$S')\" = 2 ] && grep -qF '\"\$STRIDE_FIX_DIFF:\$STRIDE_FIX_DIFF_SHA256\" \"\$STRIDE_TEST_DIFF:\$STRIDE_TEST_DIFF_SHA256\"' '$S' && grep -qF '\"\$KDA_FIX_DIFF:\$KDA_FIX_DIFF_SHA256\" \"\$KDA_TEST_DIFF:\$KDA_TEST_DIFF_SHA256\"' '$S'"

pinf() { case $1 in gdn) echo "$DIR/pins.txt" ;; *) echo "$DIR/$1-pins.txt" ;; esac; }
# pin ITEM STATE PATH: the pinned value.
pin() { awk -v s="$2" -v p="$3" '$1 == s && $3 == p {print $2}' "$(pinf "$1")"; }
states_of() { case $1 in gdn) echo "base after" ;; *) echo "base before after" ;; esac; }
ref_of() { case $1 in gdn) echo fixcommit-d713349e52 ;; kda) echo diffbase-428c371b32 ;; stride) echo diffbase-545ef08189 ;; esac; }
own_of() { case $1 in gdn) echo "$IDX $GT" ;; kda) echo "$KDA $KT" ;; stride) echo "$FR $FSG $STT" ;; esac; }
pins_shape() {
  local item st want
  want=$(tr ' ' '\n' <<<"$SEVEN" | sort | paste -sd' ')
  for item in gdn kda stride; do
    [ "$(awk '{print $1}' "$(pinf "$item")" | sort -u | paste -sd' ')" = "$(tr ' ' '\n' <<<"$(states_of "$item") $(ref_of "$item")" | sort | paste -sd' ')" ] || return 1
    for st in $(states_of "$item") $(ref_of "$item"); do
      [ "$(awk -v s="$st" '$1 == s {print $3}' "$(pinf "$item")" | sort | paste -sd' ')" = "$want" ] || return 1
    done
  done
}
check "each pins file names all seven files of the three items once per state, and once more at its diff's own commit" "pins_shape"
pins_isolation() {
  local item st p
  for item in gdn kda stride; do
    for p in $SEVEN; do
      [ "$(pin "$item" base "$p")" = "$(pin gdn base "$p")" ] || return 1
      case " $(own_of "$item") " in *" $p "*) continue ;; esac
      for st in $(states_of "$item"); do [ "$(pin "$item" "$st" "$p")" = "$(pin gdn base "$p")" ] || return 1; done
    done
  done
  for p in $GT $KT $STT; do [ "$(pin gdn base "$p")" = absent ] || return 1; done
}
check "isolation: in every state of every item, the other two items' files are 8700cc9ba0's, and the three new tests are absent there" "pins_isolation"
pins_own() {
  [ "$(pin gdn after "$IDX")" != "$(pin gdn base "$IDX")" ] && [ "$(pin gdn after "$GT")" != absent ] &&
    [ "$(pin kda before "$KDA")" = "$(pin kda base "$KDA")" ] && [ "$(pin kda before "$KT")" != absent ] &&
    [ "$(pin kda after "$KDA")" != "$(pin kda base "$KDA")" ] && [ "$(pin kda after "$KT")" = "$(pin kda before "$KT")" ] &&
    [ "$(pin stride before "$FR")" = "$(pin stride base "$FR")" ] && [ "$(pin stride before "$FSG")" = "$(pin stride base "$FSG")" ] &&
    [ "$(pin stride before "$STT")" != absent ] && [ "$(pin stride after "$FR")" != "$(pin stride base "$FR")" ] &&
    [ "$(pin stride after "$FSG")" != "$(pin stride base "$FSG")" ] && [ "$(pin stride after "$STT")" = "$(pin stride before "$STT")" ]
}
check "each item's own files: BEFORE adds only the test, AFTER also changes the source" "pins_own"
pins_ref() {
  local p
  for p in $SEVEN; do
    [ "$(pin gdn fixcommit-d713349e52 "$p")" = "$(pin gdn after "$p")" ] || return 1
    [ "$(pin kda diffbase-428c371b32 "$p")" = "$(pin kda base "$p")" ] || return 1
    [ "$(pin stride diffbase-545ef08189 "$p")" = "$(pin stride base "$p")" ] || return 1
  done
}
check "#68414's AFTER is commit d713349e52 file for file, and #68415's and #68416's diff bases are 8700cc9ba0 for all seven files, fused_recurrent.py and fused_sigmoid_gating.py among them" "pins_ref"
fixl=$(grep -m1 "^FIX_LINE=" "$ST" | cut -d"'" -f2); outl=$(grep -m1 "^OUTSIZE_LINE=" "$ST" | cut -d"'" -f2); bugl=$(grep -m1 "^BUG_LINE=" "$ST" | cut -d"'" -f2)
check "state.sh's fix and output_size lines are what fix.diff adds, and its bug line what it removes" \
  "[ -n '$fixl' ] && grep -qF -- '+    $fixl' '$DIR/fix.diff' && grep -qxF -- '+        $outl' '$DIR/fix.diff' && grep -qF -- '-    chunk_indices = torch.stack([$bugl' '$DIR/fix.diff'"
kfixl=$(grep -m1 "^FIX_LINE=" "$KST" | cut -d"'" -f2); kbugl=$(grep -m1 "^BUG_LINE=" "$KST" | cut -d"'" -f2)
check "kda-state.sh's fix line is the line kda-fix.diff adds and its bug line the one it removes" \
  "grep -qxF -- '+$kfixl' '$DIR/kda-fix.diff' && grep -qxF -- '-$kbugl' '$DIR/kda-fix.diff'"
sfix=$(grep -m1 "^FIX_TEXT=" "$SST" | cut -d"'" -f2)
check "stride-state.sh's term ($sfix) is added to four loads by stride-fix.diff, two per kernel, and removed from none" \
  "[ \"\$(grep '^+' '$DIR/stride-fix.diff' | grep -cF '$sfix')\" = 4 ] && ! grep '^-' '$DIR/stride-fix.diff' | grep -qF '$sfix' && grep -qx 'FIX_COUNT_AFTER = \"2\"' '$SV'"
check "the verdicts judge the files the state scripts import from the image's dist-packages" \
  "grep -qx 'SITE=/usr/local/lib/python3.12/dist-packages' '$LIBS' && grep -qF 'INDEX = \"/usr/local/lib/python3.12/dist-packages/$IDX\"' '$V' && grep -qF 'KDA = \"/usr/local/lib/python3.12/dist-packages/$KDA\"' '$KV' && grep -qF 'OPS = \"/usr/local/lib/python3.12/dist-packages/$OPS\"' '$SV'"
check "the runner and the three verdicts name the same image digest and commit" \
  "[ \"\$(grep -lF 'sha256:45feec27226e1dc9d10e14272a45bcd7344555c85102be9ccbc0fbe9df2d99ed' '$R' '$V' '$KV' '$SV' | wc -l)\" = 4 ] && grep -qx 'VLLM_COMMIT=$BASE_COMMIT' '$R' && [ \"\$(grep -lF 'VLLM_COMMIT = \"$BASE_COMMIT\"' '$V' '$KV' '$SV' | wc -l)\" = 3 ]"
check "#68414's verdict quotes run 1's BEFORE line as recorded" \
  "grep -qx 'before_line=$BUGGY' '$DIR/runs/2026-11-19-run1-spot-reclaimed/verdict.txt' && grep -qF '\"unwritten 70 o_err 1234.100830078125 state_err nan empty_keeps_h0 True\")' '$V'"
# The pins are re-derived from a vLLM clone when one is given, since only git proves them the commits'.
if [ -n "${VLLM_SRC:-}" ]; then
  for item in gdn kda stride; do
    check "$(basename "$(pinf $item)") is what derive-pins.sh makes of $VLLM_SRC" \
      "diff <(bash '$DIR/derive-pins.sh' $item '$VLLM_SRC') '$(pinf $item)' > /dev/null"
  done
  g() { git -C "$VLLM_SRC" "$@"; }
  check "fused_recurrent.py and fused_sigmoid_gating.py are the same blobs at 545ef08189 and 8700cc9ba0, and nothing under ops/, platforms/ or tests/kernels/fla differs between them" \
    "[ \"\$(g rev-parse 545ef08189:$FR 545ef08189:$FSG)\" = \"\$(g rev-parse $BASE_COMMIT:$FR $BASE_COMMIT:$FSG)\" ] && [ -z \"\$(g diff --name-only $BASE_COMMIT 545ef08189 -- vllm/third_party vllm/platforms tests/kernels/fla tests/kernels/conftest.py tests/conftest.py)\" ]"
  check "kda.py is the same blob at 428c371b32 and 8700cc9ba0, and the two differ only in vllm/utils/torch_utils.py" \
    "[ \"\$(g rev-parse 428c371b32:$KDA)\" = \"\$(g rev-parse $BASE_COMMIT:$KDA)\" ] && [ \"\$(g diff --name-only $BASE_COMMIT 428c371b32)\" = vllm/utils/torch_utils.py ]"
  check "d713349e52's parent is 8700cc9ba0 and its diff is fix.diff byte for byte" \
    "[ \"\$(g rev-parse d713349e52^)\" = $BASE_COMMIT ] && cmp -s <(g diff $BASE_COMMIT d713349e52) '$DIR/fix.diff'"
else
  echo "skip the pins against a vLLM clone (set VLLM_SRC to re-derive them)"
fi

check "the session's exit status is 1 without a confirmed termination or the whole evidence, and 2 unless the judge's three verdicts are all confirmed" \
  "[ \"\$(tail -n 3 '$S' | paste -sd'|')\" = '[ \"\$TERMINATION\" = confirmed ] || exit 1|[ \"\$EVIDENCE\" = returned ] || exit 1|all_confirmed || exit 2' ] && grep -qxF 'judge \"\$SWEEP\"' '$S' && grep -qxF 'all_confirmed() { [ \"\$VERDICTS\" = \"gdn=confirmed stride=confirmed kda=confirmed\" ]; }' '$S' && grep -qF 'echo \"verdicts=\$VERDICTS\"' '$S'"

# ---------------------------------------------------------------- the wrapper on its own, against a stub torch
# The stub records the default device, and the fake repro reports the device it saw, so the order of the two is shown.
mkdir -p "$WORK/stubs/torch"
cat > "$WORK/stubs/torch/__init__.py" <<'EOF'
_default = "cpu"
def set_default_device(d):
    global _default
    _default = d
EOF
mkdir -p "$WORK/wr"
printf 'import sys, torch\nprint("device", torch._default, "name", __name__, "argv0", sys.argv[0])\n' > "$WORK/wr/repro.py"
wsha=$(sha256sum "$WORK/wr/repro.py" | cut -d' ' -f1)
PYTHONPATH="$WORK/stubs" "$REAL_PY" "$RR" "$WORK/wr/repro.py" "$wsha" > "$WORK/wr/out" 2>&1; wrc=$?
check "the wrapper checks the sha256, sets CUDA as the default before the file runs, and runs it as __main__" \
  "[ $wrc = 0 ] && grep -qx 'REPRO_SHA256=$wsha' '$WORK/wr/out' && grep -q '^device cuda name __main__ ' '$WORK/wr/out' && grep -qx 'REPRO_INDEX_FILE=not-imported' '$WORK/wr/out'"
PYTHONPATH="$WORK/stubs" "$REAL_PY" "$RR" "$WORK/wr/repro.py" "0000" > "$WORK/wr/bad" 2>&1; wrc=$?
check "the wrapper refuses a file that is not the pinned one, before running it" \
  "[ $wrc = 3 ] && grep -q '^REPRO_SHA_MISMATCH ' '$WORK/wr/bad' && ! grep -q '^device' '$WORK/wr/bad'"

# ---------------------------------------------------------------- the runner's whole path, against fakes
# A fake tree with the real shape: the package's four sources with their real bug lines, and the checkout's tests/kernels/fla.
P="$WORK/pristine"
mkdir -p "$P/site/$OPS" "$P/w/tests/kernels/fla" "$WORK/mk"
for d in vllm vllm/third_party vllm/third_party/flash_linear_attention "$OPS"; do : > "$P/site/$d/__init__.py"; done
: > "$P/w/tests/kernels/fla/__init__.py"
printf 'def prepare_chunk_indices(indices):\n    chunk_indices = torch.stack([%s, indices], 1)\n' "$bugl" > "$P/site/$IDX"
printf 'def fwd(k, v):\n%s\n    w = torch.empty_like(k)\n    return o\n' "$kbugl" > "$P/site/$KDA"
for f in "$FR" "$FSG"; do
  printf 'def kernel(ssm_state_indices, i_n, stride_indices_seq, stride_indices_tok, i_t):\n    a = (ssm_state_indices + i_n * stride_indices_seq + i_t)\n    b = (ssm_state_indices + i_n * stride_indices_seq + i_t)\n' > "$P/site/$f"
done
mkdiff() { # mkdiff OUT CMD...: the diff from the pristine files to what CMD leaves, made with git as the real ones are
  rm -rf "$WORK/mk/t"; mkdir -p "$WORK/mk/t"; cp -r "$P/site/vllm" "$P/w/tests" "$WORK/mk/t/"
  (cd "$WORK/mk/t" && git init -q && git add -A && git -c user.email=t@t -c user.name=t commit -qm base && "${@:2}" && git add -A && git diff --cached > "$1")
}
mkdir -p "$WORK/in"
mkdiff "$WORK/in/fix.diff" sh -c "printf 'def test_x():\n    pass\n' > $GT && sed -i 's/    chunk_indices = torch.stack.*/    $fixl\n        $outl\n    )\n    chunk_indices = torch.stack([seq_ids, indices], 1)/' $IDX"
# Run 1's diff, without output_size, for the run that ships the wrong #68414 diff.
mkdiff "$WORK/old-fix.diff" sh -c "printf 'def test_x():\n    pass\n' > $GT && sed -i 's/    chunk_indices = torch.stack.*/    $fixl\n    )\n    chunk_indices = torch.stack([seq_ids, indices], 1)/' $IDX"
mkdiff "$WORK/in/kda-test.diff" sh -c "printf 'def test_x():\n    pass\n' > $KT"
mkdiff "$WORK/in/kda-fix.diff" sh -c "printf 'def test_x():\n    pass\n' > $KT && sed -i 's/^$kbugl\$/$kfixl/' $KDA"
mkdiff "$WORK/in/stride-test.diff" sh -c "printf 'def test_y():\n    pass\n' > $STT"
mkdiff "$WORK/in/stride-fix.diff" sh -c "printf 'def test_y():\n    pass\n' > $STT && sed -i 's/+ i_t)\$/+ i_t * stride_indices_tok)/' $FR $FSG"
# mkpins ITEM: the item's pins over the fake tree, made as derive-pins.sh makes the real ones.
mkpins() {
  local item=$1 st d p out
  case $item in gdn) out="$WORK/in/pins.txt" ;; *) out="$WORK/in/$item-pins.txt" ;; esac
  : > "$out"
  for st in $(states_of "$item"); do
    rm -rf "$WORK/mk/p"; mkdir -p "$WORK/mk/p"; cp -r "$P/site/vllm" "$P/w/tests" "$WORK/mk/p/"
    case $item:$st in gdn:after) d=fix.diff ;; *:before) d=$item-test.diff ;; *:after) d=$item-fix.diff ;; *) d="" ;; esac
    # A pristine tree that already holds a fix cannot take it again, so that refusal goes to a log, not the screen.
    [ -z "$d" ] || (cd "$WORK/mk/p" && git apply "$WORK/in/$d") 2>>"$WORK/mkpins.err"
    for p in $SEVEN; do
      if [ -e "$WORK/mk/p/$p" ]; then echo "$st $(sha256sum "$WORK/mk/p/$p" | cut -d' ' -f1) $p"; else echo "$st absent $p"; fi
    done >> "$out"
  done
}
mkallpins() { mkpins gdn; mkpins kda; mkpins stride; }
mkallpins
cp "$RR" "$WORK/in/run_repro.py"
# The fake repro answers from the index.py Python imports, and fails as Triton does when the default device is the CPU.
cat > "$WORK/in/kernel_repro.py" <<EOF
import os, torch
import vllm.third_party.flash_linear_attention.ops.index as m
if torch._default != "cuda":
    raise ValueError("Pointer argument (at 0) cannot be accessed from Triton (cpu tensor?)")
if os.environ.get("FAKE_REPRO_CRASH"):
    raise SystemExit(139)
print("$FIXED" if "$fixl" in open(m.__file__).read() else "$BUGGY")
EOF
FAKE_REPRO_SHA=$(sha256sum "$WORK/in/kernel_repro.py" | cut -d' ' -f1)
# The shared lib with its four container paths moved onto the fake tree; the state scripts are shipped unchanged but for the repro pin.
sed -e "s|^SITE=.*|SITE=$WORK/site|" -e "s|^W=.*|W=$WORK/w|" -e "s|^OUT_ROOT=.*|OUT_ROOT=$WORK/out|" \
  -e "s|^WHEEL_SHA_FILE=.*|WHEEL_SHA_FILE=$WORK/wheel.sha256|" "$LIBS" > "$WORK/in/lib.sh"
sed "s|^REPRO_SHA256=.*|REPRO_SHA256=$FAKE_REPRO_SHA|" "$ST" > "$WORK/in/state.sh"
cp "$KST" "$SST" "$WORK/in/"
echo "sha256:abc  vllm-0.0.0-cp38-abi3-linux_x86_64.whl" > "$WORK/wheel.sha256"
check "the state scripts hold no container path of their own, so moving the lib's four moves them all" \
  "! grep -nE '/usr/local/lib|/vllm-workspace|/out/|/tmp/' '$ST' '$KST' '$SST' | grep -v ':[0-9]*:#' && [ \"\$(grep -cE '^(SITE|W|OUT_ROOT|WHEEL_SHA_FILE)=' '$LIBS')\" = 4 ] && ! grep -nE '/usr/local/lib|/vllm-workspace|=/out\$|/tmp/vllm-wheel' '$WORK/in/lib.sh'"

# The fake pytest selects cases as pytest does, by node id and then by -k substring, and answers from the files Python imports.
# Run unfixed, #68415's 32-64 case writes past its output, so the fake records the breach and dies as a crashed process would.
cat > "$WORK/fake_pytest.py" <<'EOF'
import importlib, os, sys
args = sys.argv[1:]
xml = next(a.split("=", 1)[1] for a in args if a.startswith("--junitxml="))
calls = open(os.environ["WORK"] + "/calls", "a")
calls.write("pytest %s\n" % " ".join(a for a in args if not a.startswith("--junitxml=")))
src = lambda mod: open(importlib.import_module("vllm.third_party.flash_linear_attention.ops." + mod).__file__).read()
test = next(a.split("::")[0] for a in args if a.startswith("tests/"))
if os.environ.get("FAKE_TIMEOUT") and os.environ["FAKE_TIMEOUT"] in test:
    sys.exit(124)
named = [a.split("[", 1)[1].rstrip("]") for a in args if "::" in a and "[" in a]
def select(ids):
    sel = [i for i in ids if not named or i in named]
    if "-k" in args:
        sel = [i for i in sel if args[args.index("-k") + 1] in i]
    return sel
fail = lambda msg: '<failure message="%s">E</failure>' % msg
cases = []
if test.endswith("test_chunk_indices.py"):
    ok = os.environ["FIXL"] in src("index") and not os.environ.get("FAKE_UNIT_FAIL")
    for s in range(6):
        for d in range(2):
            cases.append(("test_chunk_indices_keep_ids_of_empty_sequences[seq_lens%d-dtype%d]" % (s, d), None if ok else fail("assert [[0, 0], [1, 0]] == [[0, 0], [2, 0]]")))
elif test.endswith("test_fused_recurrent_kda.py"):
    fixed = any(l.rstrip("\n") == os.environ["KFIXL"] for l in src("kda").splitlines())
    sel = select(["64-32", "64-64", "32-64"])
    calls.write("kda-selected %s fixed=%s\n" % (",".join(sel), fixed))
    if "32-64" in sel and not fixed:
        calls.write("KDA 32-64 RAN UNFIXED\n")
        sys.exit(139)
    for i in sel:
        k, v = map(int, i.split("-"))
        bad = (not fixed and k != v) or (fixed and i == "32-64" and os.environ.get("FAKE_KDA_AFTER_FAIL"))
        cases.append(("test_fused_recurrent_kda_output_has_value_shape[%s]" % i,
                      fail("AssertionError: assert torch.Size([1, 4, 1, %d]) == torch.Size([1, 4, 1, %d])&#10;&gt;       assert out.shape == v.shape" % (k, v)) if bad else None))
elif test.endswith("test_state_index_stride.py"):
    if os.environ.get("FAKE_STRIDE_CRASH"):
        sys.exit(139)
    sel = select(["recurrent", "sigmoid_gating"])
    calls.write("stride-selected %s\n" % ",".join(sel))
    for i, mod in (("recurrent", "fused_recurrent"), ("sigmoid_gating", "fused_sigmoid_gating")):
        if i in sel:
            fixed = "i_t * stride_indices_tok" in src(mod)
            cases.append(("test_state_index_table_stride_does_not_change_results[%s]" % i,
                          None if fixed else fail("AssertionError: Tensor-likes are not equal!&#10;&#10;Mismatched elements: 3 / 128 (2.3%)")))
else:
    sys.exit(4)
body = "".join('<testcase classname="t" name="%s">%s</testcase>' % (n, f or "") for n, f in cases)
open(xml, "w").write("<testsuites><testsuite>%s</testsuite></testsuites>" % body)
bad = sum(1 for _, f in cases if f)
parts = (["%d failed" % bad] if bad else []) + (["%d passed" % (len(cases) - bad)] if len(cases) - bad else [])
print("========================= %s in 1.23s =========================" % ", ".join(parts or ["no tests ran"]))
sys.exit(1 if bad else (5 if not cases else 0))
EOF

cp "$R" "$WORK/runner.sh"
mkfakes() {
  local bin="$WORK/bin"
  rm -rf "$bin" "$WORK/calls" "$WORK/site" "$WORK/w"; mkdir -p "$bin"
  cat > "$bin/docker" <<'EOF'
#!/bin/bash
echo "docker $*" >> "$WORK/calls"
case "$1" in
  pull) exit 0 ;;
  image) echo "[\"public.ecr.aws/q9t5s3a7/vllm-ci-postmerge-repo@sha256:45feec27226e1dc9d10e14272a45bcd7344555c85102be9ccbc0fbe9df2d99ed\"] ${FAKE_REVISION:-8700cc9ba0016bf14d8f2756f3b673e93fbcf2fd}" ;;
  run)
    script=$(printf '%s\n' "$@" | grep -xE '/in/(state|kda-state|stride-state)\.sh')
    if [ -n "$script" ]; then
      # A fresh container: the image's tree as built, unless the fake is told to leave the last state's edits.
      if [ -z "${FAKE_STALE:-}" ] || [ ! -d "$WORK/site" ]; then
        rm -rf "$WORK/site" "$WORK/w"; cp -r "$WORK/pristine/site" "$WORK/site"; cp -r "$WORK/pristine/w" "$WORK/w"
      fi
      args=$(printf '%s\n' "$@" | sed -n "\|^$script\$|,\$p" | tail -n +2)
      PYTHONPATH="$WORK/site:$WORK/stubs" bash "$WORK/in/${script#/in/}" $args; exit $?
    fi
    printf '%s\n' "$@" | grep -qx cat && { cat "$WORK/wheel.sha256"; exit 0; }
    exit 1 ;;
  ps) [ -z "${FAKE_PS_FAIL:-}" ] || exit 1 ;;
  rm) exit 0 ;;
esac
EOF
  # python3 -m pytest goes to the fake pytest, and the wrapper and the repro are logged; anything else is the real interpreter.
  cat > "$bin/python3" <<EOF
#!/bin/bash
if [ "\$1 \$2" = "-m pytest" ]; then shift 2; exec $REAL_PY "$WORK/fake_pytest.py" "\$@"; fi
case "\$1" in *kernel_repro.py|*run_repro.py) echo "python3 \$*" >> "$WORK/calls" ;; esac
exec $REAL_PY "\$@"
EOF
  chmod +x "$bin"/*
}
# Each verdict reads the fake tree's paths, so it is judged with those paths standing in.
sed "s|^INDEX = .*|INDEX = \"$WORK/site/$IDX\"|" "$V" > "$WORK/verdict-local.py"
sed "s|^KDA = .*|KDA = \"$WORK/site/$KDA\"|" "$KV" > "$WORK/kda-verdict-local.py"
sed "s|^OPS = .*|OPS = \"$WORK/site/$OPS\"|" "$SV" > "$WORK/stride-verdict-local.py"
isha() { sha256sum "$WORK/in/$1" | cut -d' ' -f1; }
# Each prints the verdict whatever its exit status, which pipefail would otherwise turn into the pipeline's.
gv() { python3 "$WORK/verdict-local.py" "$WORK/out-$1" "$(isha fix.diff)" "$FAKE_REPRO_SHA"; true; }
kvd_() { python3 "$WORK/kda-verdict-local.py" "$WORK/out-$1" "$(isha kda-test.diff)" "$(isha kda-fix.diff)"; true; }
svd_() { python3 "$WORK/stride-verdict-local.py" "$WORK/out-$1" "$(isha stride-test.diff)" "$(isha stride-fix.diff)"; true; }
# verdicts RUN: the three verdicts of one fake run, in the session's order.
verdicts() { echo "gdn=$(gv "$1" | sed -n 's/^gdn_verdict=//p') stride=$(svd_ "$1" | sed -n 's/^stride_verdict=//p') kda=$(kvd_ "$1" | sed -n 's/^kda_verdict=//p')"; }
runfake() {
  mkfakes; rm -rf "$WORK/out"; mkdir -p "$WORK/out"
  env WORK="$WORK" FIXL="$fixl" KFIXL="$kfixl" PATH="$WORK/bin:$PATH" "${@:2}" \
    timeout 120 bash "$WORK/runner.sh" "$WORK/in" "$WORK/out" $(( $(date +%s) + 100000 )) > "$WORK/runner-$1.out" 2>&1
  echo $? > "$WORK/rc-$1"
  rm -rf "$WORK/out-$1"; cp -r "$WORK/out" "$WORK/out-$1"; cp "$WORK/calls" "$WORK/out-$1/calls"
}
ALL_OK='gdn=confirmed stride=confirmed kda=confirmed'

runfake good env
check "the runner pulls, checks the image, then runs #68414 AFTER, #68416 BEFORE and AFTER, and #68415 BEFORE and AFTER, and ends" \
  "[ \"\$(cat '$WORK/rc-good')\" = 0 ] && [ \"\$(grep -o 'state [a-z-]*: start\\|[a-z]* states done\\|all items done' '$WORK/out-good/steps.log' | paste -sd'|')\" = 'state gdn-after: start|gdn states done|state stride-before: start|state stride-after: start|stride states done|state kda-before: start|state kda-after: start|kda states done|all items done' ]"
check "each state runs in its own named container, with the GPU" \
  "[ \"\$(grep -o 'run --rm --name fla-[a-z-]* --gpus all' '$WORK/calls' | awk '{print \$4}' | paste -sd' ')\" = 'fla-gdn-after fla-stride-before fla-stride-after fla-kda-before fla-kda-after' ]"
applied_ok() { local d; for d in gdn-after stride-before stride-after kda-before kda-after; do [ "$(grep -c '^base_identity=ok$\|^apply=ok$\|^applied_identity=ok$' "$WORK/out-good/$d/state.txt")" = 3 ] || return 1; done; }
check "every state's tree held its pins before and after its diff" "applied_ok"
check "each state applied its own diff: the final fix for #68414, the test alone for each BEFORE, the whole diff for each AFTER" \
  "grep -qx \"diff_sha256=\$(isha fix.diff)\" '$WORK/out-good/gdn-after/state.txt' && grep -qx \"diff_sha256=\$(isha stride-test.diff)\" '$WORK/out-good/stride-before/state.txt' && grep -qx \"diff_sha256=\$(isha stride-fix.diff)\" '$WORK/out-good/stride-after/state.txt' && grep -qx \"diff_sha256=\$(isha kda-test.diff)\" '$WORK/out-good/kda-before/state.txt' && grep -qx \"diff_sha256=\$(isha kda-fix.diff)\" '$WORK/out-good/kda-after/state.txt'"
check "#68414 runs the repro only through the wrapper, with its pinned sha256, once" \
  "[ \"\$(grep '^python3 ' '$WORK/calls' | paste -sd'|')\" = \"python3 $WORK/in/run_repro.py $WORK/in/kernel_repro.py $FAKE_REPRO_SHA\" ] && grep -qx 'repro_mode=cuda-default' '$WORK/out-good/gdn-after/state.txt' && grep -qx 'repro_line=$FIXED' '$WORK/out-good/gdn-after/state.txt'"
check "#68414's import check records the imported index.py, with the fix and output_size lines and no bug line" \
  "grep -qx 'index_file=$WORK/site/$IDX' '$WORK/out-good/gdn-after/state.txt' && grep -qx 'fix_grep_rc=0' '$WORK/out-good/gdn-after/state.txt' && grep -qx 'outsize_grep_rc=0' '$WORK/out-good/gdn-after/state.txt' && grep -qx 'bug_grep_rc=1' '$WORK/out-good/gdn-after/state.txt' && grep -qx 'repro_index_file=$WORK/site/$IDX' '$WORK/out-good/gdn-after/state.txt'"
check "the pytest calls are #68414's new test, #68416's file twice, and #68415's 64-32 case and then its file" \
  "[ \"\$(grep '^pytest ' '$WORK/calls' | sed 's/ -rA -p no:cacheprovider\$//' | paste -sd'|')\" = 'pytest $GT|pytest $STT|pytest $STT|pytest $KT::test_fused_recurrent_kda_output_has_value_shape[64-32] -k 64-32|pytest $KT' ]"
check "#68415 BEFORE selects only 64-32, by node id and by -k, and the unfixed 32-64 case never ran" \
  "[ \"\$(grep '^kda-selected' '$WORK/calls' | paste -sd'|')\" = 'kda-selected 64-32 fixed=False|kda-selected 64-32,64-64,32-64 fixed=True' ] && ! grep -q 'RAN UNFIXED' '$WORK/calls' && grep -qx 'pytest_args=$KT::test_fused_recurrent_kda_output_has_value_shape\\[64-32\\] -k 64-32' '$WORK/out-good/kda-before/state.txt'"
# The command line itself, read from the script: no 32-64 anywhere on BEFORE's line, and both selectors present.
kb=$(grep -E '^ *before\) DIFF=' "$KST")
check "kda-state.sh's BEFORE line names 64-32 by node id and -k and cannot name 32-64 ($kb)" \
  "[ \"\$(grep -cE '^ *before\\) DIFF=' '$KST')\" = 1 ] && [[ \"\$kb\" != *32-64* ]] && [[ \"\$kb\" == *'SELECT=(\"\$TEST::\$CASE[64-32]\" -k \"64-32\")'* ]] && grep -qx 'TEST=$KT' '$KST'"
check "#68416 BEFORE applies the test diff alone and runs both cases, which fail on the unfixed kernels; AFTER passes both" \
  "grep -qx \"apply=ok\" '$WORK/out-good/stride-before/state.txt' && [ \"\$(grep '^stride-selected' '$WORK/calls' | paste -sd'|')\" = 'stride-selected recurrent,sigmoid_gating|stride-selected recurrent,sigmoid_gating' ] && grep -qx 'test_summary========================== 2 failed in 1.23s =========================' '$WORK/out-good/stride-before/state.txt' && grep -qx 'test_summary========================== 2 passed in 1.23s =========================' '$WORK/out-good/stride-after/state.txt'"
check "#68416's import check counts the token-stride term in both imported kernels: none BEFORE, two each AFTER" \
  "[ \"\$(grep -h '^fused_[a-z_]*_fix_count=' '$WORK/out-good/stride-before/state.txt' '$WORK/out-good/stride-after/state.txt' | paste -sd' ')\" = 'fused_recurrent_fix_count=0 fused_sigmoid_gating_fix_count=0 fused_recurrent_fix_count=2 fused_sigmoid_gating_fix_count=2' ] && grep -qx 'fused_recurrent_file=$WORK/site/$FR' '$WORK/out-good/stride-before/state.txt' && grep -qx 'fused_sigmoid_gating_file=$WORK/site/$FSG' '$WORK/out-good/stride-after/state.txt'"
check "#68415's import check records the imported kda.py, with the bug line BEFORE and the fix AFTER" \
  "grep -qx 'kda_file=$WORK/site/$KDA' '$WORK/out-good/kda-before/state.txt' && grep -qx 'fix_grep_rc=1' '$WORK/out-good/kda-before/state.txt' && grep -qx 'bug_grep_rc=0' '$WORK/out-good/kda-before/state.txt' && grep -qx 'fix_grep_rc=0' '$WORK/out-good/kda-after/state.txt' && grep -qx 'bug_grep_rc=1' '$WORK/out-good/kda-after/state.txt'"
check "every pytest call records its exact command, its exit and pytest's summary line" \
  "grep -qx \"unit_cmd=cd $WORK/w && timeout --kill-after=10 120 python3 -m pytest $GT -rA -p no:cacheprovider --junitxml=$WORK/out/gdn-after/unit.xml\" '$WORK/out-good/gdn-after/state.txt' && grep -qxF \"test_cmd=cd $WORK/w && timeout --kill-after=10 150 python3 -m pytest '$KT::test_fused_recurrent_kda_output_has_value_shape[64-32]' -k 64-32 -rA -p no:cacheprovider --junitxml=$WORK/out/kda-before/test.xml\" '$WORK/out-good/kda-before/state.txt' && grep -qx 'unit_rc=0' '$WORK/out-good/gdn-after/state.txt' && grep -qx 'unit_summary========================== 12 passed in 1.23s =========================' '$WORK/out-good/gdn-after/state.txt'"
check "the fake run confirms all three items" "[ \"\$(verdicts good)\" = '$ALL_OK' ] && gv good | grep -qx 'gdn_unit=passed'"
check "the real verdicts refuse the fake run on the import check alone, since its files are not the image's paths" \
  "{ python3 '$V' '$WORK/out-good' \$(isha fix.diff) $FAKE_REPRO_SHA; python3 '$KV' '$WORK/out-good' \$(isha kda-test.diff) \$(isha kda-fix.diff); python3 '$SV' '$WORK/out-good' \$(isha stride-test.diff) \$(isha stride-fix.diff); true; } | grep -c '^[a-z]*_verdict=void-import-check\$' | grep -qx 3"

# The pytest summary the PRs quote, from the fake run.
python3 "$PS" "$WORK/out-good" "$(isha fix.diff)" "$(isha kda-test.diff)" "$(isha kda-fix.diff)" "$(isha stride-test.diff)" "$(isha stride-fix.diff)" > "$WORK/ps-good.txt"
check "pytest-summary.txt names all five calls with command, diff and its sha256, exit, summary line and every case" \
  "[ \"\$(grep -c '^== ' '$WORK/ps-good.txt')\" = 5 ] && [ \"\$(grep -c '^   command: cd ' '$WORK/ps-good.txt')\" = 5 ] && [ \"\$(grep -c '(the pinned one)\$' '$WORK/ps-good.txt')\" = 5 ] && grep -qx '   summary: ========================= 2 failed in 1.23s =========================' '$WORK/ps-good.txt' && grep -qx '     failed   test_state_index_table_stride_does_not_change_results\\[sigmoid_gating\\]' '$WORK/ps-good.txt' && grep -qx '   cases:   12 in junit' '$WORK/ps-good.txt' && grep -qx \"   diff:    kda-test.diff sha256 \$(isha kda-test.diff) (the pinned one)\" '$WORK/ps-good.txt'"
python3 "$PS" "$WORK/out-good" "$(isha fix.diff)" "$(isha kda-test.diff)" 0000 "$(isha stride-test.diff)" "$(isha stride-fix.diff)" > "$WORK/ps-other.txt"
check "pytest-summary.txt says when a state applied a diff other than the pinned one" "grep -q 'kda-fix.diff sha256 .* (NOT the pinned 0000)' '$WORK/ps-other.txt'"

# Isolation: a container that kept the last state's edits carries #68414's fix into #68416's BEFORE.
runfake stale env FAKE_STALE=1
check "a container that kept another item's fix is refused before anything is applied, and #68414 stays confirmed beside it" \
  "grep -qx 'base_identity=bad' '$WORK/out-stale/stride-before/state.txt' && grep -q '$IDX is .*, not the pinned base' '$WORK/out-stale/stride-before/steps.log' && ! grep -q '^test_cmd=' '$WORK/out-stale/stride-before/state.txt' && [ \"\$(verdicts stale)\" = 'gdn=confirmed stride=void-identity kda=void-identity' ] && grep -q 'all items done' '$WORK/out-stale/steps.log' && [ \"\$(cat '$WORK/rc-stale')\" = 3 ]"
runfake stridecrash env FAKE_STRIDE_CRASH=1
check "#68416 crashing does not stop #68415, and neither other verdict changes" \
  "grep -qx 'test_rc=139' '$WORK/out-stridecrash/stride-before/state.txt' && [ \"\$(verdicts stridecrash)\" = 'gdn=confirmed stride=before-did-not-reproduce kda=confirmed' ] && grep -q 'state kda-after: exited 0' '$WORK/out-stridecrash/steps.log'"
runfake reprocrash env FAKE_REPRO_CRASH=1
check "#68414's repro crashing does not stop or change the other two" \
  "[ \"\$(verdicts reprocrash)\" = 'gdn=after-not-fixed stride=confirmed kda=confirmed' ] && gv reprocrash | grep -qx 'gdn_after_repro=no-result(rc=139)'"
runfake kdaafter env FAKE_KDA_AFTER_FAIL=1
check "a #68415 AFTER with one case failed is named, and the other two stay confirmed" \
  "kvd_ kdaafter | grep -q '^kda_after_test=not-passed(rc=1,cases=3,' && [ \"\$(verdicts kdaafter)\" = 'gdn=confirmed stride=confirmed kda=after-not-passed' ]"
runfake kdatimeout env FAKE_TIMEOUT=test_fused_recurrent_kda
check "a #68415 pytest that timed out is not confirmed, and the other two stay confirmed" \
  "grep -qx 'test_rc=124' '$WORK/out-kdatimeout/kda-before/state.txt' && grep -qx 'test_summary=' '$WORK/out-kdatimeout/kda-before/state.txt' && [ \"\$(verdicts kdatimeout)\" = 'gdn=confirmed stride=confirmed kda=before-did-not-reproduce' ]"
runfake unitfail env FAKE_UNIT_FAIL=1
check "#68414's CPU-only test failing is recorded and does not void its repro verdict" \
  "grep -qx 'unit_rc=1' '$WORK/out-unitfail/gdn-after/state.txt' && gv unitfail | grep -q '^gdn_unit=not-passed(rc=1,cases=12,' && [ \"\$(verdicts unitfail)\" = '$ALL_OK' ]"
runfake unittimeout env FAKE_TIMEOUT=test_chunk_indices
check "#68414's new test timing out is recorded with its 124, and the repro verdict stands" \
  "grep -qx 'unit_rc=124' '$WORK/out-unittimeout/gdn-after/state.txt' && gv unittimeout | grep -qx 'gdn_unit=no-junit(rc=124)' && [ \"\$(verdicts unittimeout)\" = '$ALL_OK' ]"
# A BEFORE that selected the whole file: the fake shows the out-of-bounds run, and the verdict voids the selection.
cp "$WORK/in/kda-state.sh" "$WORK/kda-state.keep"
sed -i 's|^  before) DIFF=\(.*\); SELECT=.*|  before) DIFF=\1; SELECT=("$TEST") ;;|' "$WORK/in/kda-state.sh"
runfake kdawide env
check "a #68415 BEFORE that selects 32-64 is caught by the fake and voided by the verdict" \
  "grep -q 'KDA 32-64 RAN UNFIXED' '$WORK/out-kdawide/calls' && kvd_ kdawide | grep -qx 'kda_verdict=void-before-selection' && [ \"\$(verdicts kdawide)\" = 'gdn=confirmed stride=confirmed kda=void-before-selection' ]"
cp "$WORK/kda-state.keep" "$WORK/in/kda-state.sh"
# The wrong #68414 diff: run 1's, without output_size, against the final pins.
cp "$WORK/in/fix.diff" "$WORK/fix.keep"; cp "$WORK/old-fix.diff" "$WORK/in/fix.diff"
runfake olddiff env
check "#68414 AFTER with run 1's diff is refused before the repro, and voided" \
  "grep -qx 'applied_identity=bad' '$WORK/out-olddiff/gdn-after/state.txt' && ! grep -q '^repro_line=' '$WORK/out-olddiff/gdn-after/state.txt' && { python3 '$WORK/verdict-local.py' '$WORK/out-olddiff' \$(sha256sum '$WORK/fix.keep' | cut -d' ' -f1) $FAKE_REPRO_SHA; true; } | grep -qx 'gdn_verdict=void-identity'"
# With pins made for it, run 1's diff passes identity, and the import check alone must catch it.
mkpins gdn; runfake olddiffpinned env
check "#68414 AFTER whose index.py lacks output_size fails the import check even when its tree matches its own pins" \
  "grep -qx 'outsize_grep_rc=1' '$WORK/out-olddiffpinned/gdn-after/state.txt' && gv olddiffpinned | grep -qx 'gdn_import_check=lines(fix_grep_rc=0,outsize_grep_rc=1,bug_grep_rc=1)' && gv olddiffpinned | grep -qx 'gdn_verdict=void-import-check'"
cp "$WORK/fix.keep" "$WORK/in/fix.diff"; mkpins gdn
# A #68416 BEFORE that applies the whole fix: its pins refuse the tree.
sed -i 's|^  before) DIFF=\$IN/stride-test.diff ;;|  before) DIFF=$IN/stride-fix.diff ;;|' "$WORK/in/stride-state.sh"
runfake stridefix env
check "a #68416 BEFORE that applies the fix is refused by its pins before pytest, and voided" \
  "grep -qx 'applied_identity=bad' '$WORK/out-stridefix/stride-before/state.txt' && ! grep -q '^test_cmd=' '$WORK/out-stridefix/stride-before/state.txt' && svd_ stridefix | grep -qx 'stride_verdict=void-identity' && [ \"\$(verdicts stridefix | cut -d' ' -f1,3)\" = 'gdn=confirmed kda=confirmed' ]"
cp "$SST" "$WORK/in/stride-state.sh"
runfake badrev env FAKE_REVISION=deadbeef
check "an image whose label is not 8700cc9ba0 is refused before any state runs" \
  "grep -q 'IMAGE IDENTITY FAILED' '$WORK/out-badrev/steps.log' && ! grep -q 'fla-' '$WORK/out-badrev/calls'"
runfake psfail env FAKE_PS_FAIL=1
check "a container whose removal cannot be shown stops the run" \
  "grep -q 'state gdn-after: container was not shown removed' '$WORK/out-psfail/steps.log' && ! grep -q 'fla-stride' '$WORK/out-psfail/calls'"
# A repro other than the pinned one: the state script refuses it before applying anything or running it.
cp "$WORK/in/kernel_repro.py" "$WORK/kernel_repro.keep"; echo "# edited" >> "$WORK/in/kernel_repro.py"
runfake edited env
check "a kernel_repro.py that is not the pinned one is refused before it runs, and the other items are untouched" \
  "grep -q 'kernel_repro.py is not the pinned' '$WORK/out-edited/gdn-after/steps.log' && ! grep -q '^python3 .*kernel_repro.py' '$WORK/out-edited/calls' && [ \"\$(verdicts edited)\" = 'gdn=void-identity stride=confirmed kda=confirmed' ]"
cp "$WORK/kernel_repro.keep" "$WORK/in/kernel_repro.py"
# The #68416 fix already in the image: its BEFORE has no bug, and the base pins say why first.
cp -r "$P" "$WORK/pristine.keep"
sed -i 's/+ i_t)$/+ i_t * stride_indices_tok)/' "$P/site/$FR"
runfake fixedimage env
check "an image that already holds a fix is refused at its base pins, in every item, since all three pin all seven files" \
  "[ \"\$(grep -l '^base_identity=bad' '$WORK'/out-fixedimage/*/state.txt | wc -l)\" = 5 ] && [ \"\$(verdicts fixedimage)\" = 'gdn=void-identity stride=void-identity kda=void-identity' ]"
rm -rf "$P"; mv "$WORK/pristine.keep" "$P"
# A pins file that names fewer files, or none, or is missing, must not pass as an identity check that checked nothing.
cp "$WORK/in/stride-pins.txt" "$WORK/stride-pins.keep"; : > "$WORK/in/stride-pins.txt"
runfake emptypins env
check "an empty pins file refuses its item's states, and the other items stay confirmed" \
  "grep -qx 'base_identity=bad' '$WORK/out-emptypins/stride-before/state.txt' && grep -q 'names 0 file(s) for base, not 7' '$WORK/out-emptypins/stride-before/steps.log' && [ \"\$(verdicts emptypins)\" = 'gdn=confirmed stride=void-identity kda=confirmed' ]"
grep -v "$FSG\$" "$WORK/stride-pins.keep" > "$WORK/in/stride-pins.txt"
runfake shortpins env
check "a pins file missing one of the seven files is refused" "grep -q 'names 6 file(s) for base, not 7' '$WORK/out-shortpins/stride-before/steps.log' && svd_ shortpins | grep -qx 'stride_verdict=void-identity'"
rm "$WORK/in/stride-pins.txt"
runfake nopins env
check "a missing pins file is refused" "grep -qx 'base_identity=bad' '$WORK/out-nopins/stride-before/state.txt' && svd_ nopins | grep -qx 'stride_verdict=void-identity'"
cp "$WORK/stride-pins.keep" "$WORK/in/stride-pins.txt"

# ---------------------------------------------------------------- the verdicts, case by case
IX=/usr/local/lib/python3.12/dist-packages/$IDX
KX=/usr/local/lib/python3.12/dist-packages/$KDA
OX=/usr/local/lib/python3.12/dist-packages/$OPS
KC=test_fused_recurrent_kda_output_has_value_shape
SC=test_state_index_table_stride_does_not_change_results
junit() { # junit NAME:OUTCOME...: one junit file, OUTCOME passed, failure or error
  local c; echo '<testsuites><testsuite>'
  for c in "$@"; do
    case ${c##*:} in
      passed) echo "<testcase classname=\"t\" name=\"${c%:*}\"/>" ;;
      *) echo "<testcase classname=\"t\" name=\"${c%:*}\"><${c##*:} message=\"$MSG\">x</${c##*:}></testcase>" ;;
    esac
  done
  echo '</testsuite></testsuites>'
}
unit_cases() { local s d; for s in 0 1 2 3 4 5; do for d in 0 1; do echo "test_chunk_indices_keep_ids_of_empty_sequences[seq_lens$s-dtype$d]:${1:-passed}"; done; done; }
case_dir() { # case_dir NAME: a sweep where all three items are confirmed, which each case then mutates
  local d="$WORK/vc/$1"; rm -rf "$d"; mkdir -p "$d/gdn-after" "$d/stride-before" "$d/stride-after" "$d/kda-before" "$d/kda-after"
  printf 'started=100\ncheckout_head=%s\nrepro_sha256=REPRO\ndiff_sha256=FIX\nbase_identity=ok\napply=ok\napplied_identity=ok\nindex_file=%s\nfix_grep_rc=0\noutsize_grep_rc=0\nbug_grep_rc=1\nrepro_cuda_rc=0\nrepro_mode=cuda-default\nrepro_index_file=%s\nrepro_line=%s\nunit_rc=0\nended=300\n' "$BASE_COMMIT" "$IX" "$IX" "$FIXED" > "$d/gdn-after/state.txt"
  MSG=x junit $(unit_cases) > "$d/gdn-after/unit.xml"
  printf 'started=400\ndiff_sha256=STEST\nbase_identity=ok\napply=ok\napplied_identity=ok\nfused_recurrent_file=%s/fused_recurrent.py\nfused_recurrent_fix_count=0\nfused_sigmoid_gating_file=%s/fused_sigmoid_gating.py\nfused_sigmoid_gating_fix_count=0\npytest_args=%s\ntest_rc=1\nended=500\n' "$OX" "$OX" "$STT" > "$d/stride-before/state.txt"
  MSG='AssertionError: Tensor-likes are not equal!' junit "$SC[recurrent]:failure" "$SC[sigmoid_gating]:failure" > "$d/stride-before/test.xml"
  sed -e 's/^started=400/started=600/; s/^ended=500/ended=700/; s/STEST/SFIX/; s/_fix_count=0/_fix_count=2/; s/^test_rc=1/test_rc=0/' "$d/stride-before/state.txt" > "$d/stride-after/state.txt"
  junit "$SC[recurrent]:passed" "$SC[sigmoid_gating]:passed" > "$d/stride-after/test.xml"
  printf 'started=1000\ndiff_sha256=KTEST\nbase_identity=ok\napply=ok\napplied_identity=ok\nkda_file=%s\nfix_grep_rc=1\nbug_grep_rc=0\npytest_args=%s::%s[64-32] -k 64-32\ntest_rc=1\nended=1100\n' "$KX" "$KT" "$KC" > "$d/kda-before/state.txt"
  printf 'started=1200\ndiff_sha256=KFIX\nbase_identity=ok\napply=ok\napplied_identity=ok\nkda_file=%s\nfix_grep_rc=0\nbug_grep_rc=1\npytest_args=%s\ntest_rc=0\nended=1300\n' "$KX" "$KT" > "$d/kda-after/state.txt"
  MSG='AssertionError: assert torch.Size([1, 4, 1, 64]) == torch.Size([1, 4, 1, 32])&#10;&gt;       assert out.shape == v.shape' junit "$KC[64-32]:failure" > "$d/kda-before/test.xml"
  junit "$KC[64-32]:passed" "$KC[64-64]:passed" "$KC[32-64]:passed" > "$d/kda-after/test.xml"
  echo "[\"public.ecr.aws/q9t5s3a7/vllm-ci-postmerge-repo@sha256:45feec27226e1dc9d10e14272a45bcd7344555c85102be9ccbc0fbe9df2d99ed\"] $BASE_COMMIT" > "$d/image-identity.txt"
  echo "abc123  vllm.whl" > "$d/wheel-sha256.txt"
  # Each pytest call's command record, which only the pytest summary reads.
  echo "unit_cmd=cd /vllm-workspace && python3 -m pytest $GT" >> "$d/gdn-after/state.txt"
  for x in stride-before stride-after kda-before kda-after; do echo "test_cmd=cd /vllm-workspace && python3 -m pytest x" >> "$d/$x/state.txt"; done
  echo "$d"
}
v3() { echo "gdn=$(python3 "$V" "$1" FIX REPRO | sed -n 's/^gdn_verdict=//p') stride=$(python3 "$SV" "$1" STEST SFIX | sed -n 's/^stride_verdict=//p') kda=$(python3 "$KV" "$1" KTEST KFIX | sed -n 's/^kda_verdict=//p')"; }
vrc() { case $1 in gdn) python3 "$V" "$2" FIX REPRO ;; stride) python3 "$SV" "$2" STEST SFIX ;; kda) python3 "$KV" "$2" KTEST KFIX ;; esac > /dev/null; }
d=$(case_dir good)
check "the case sweep confirms all three items, each verdict exiting 0, with each import check first" \
  "[ \"\$(v3 '$d')\" = '$ALL_OK' ] && vrc gdn '$d' && vrc stride '$d' && vrc kda '$d' && [ \"\$(python3 '$V' '$d' FIX REPRO | head -1)\" = 'gdn_import_check=ok' ] && [ \"\$(python3 '$SV' '$d' STEST SFIX | head -1)\" = 'stride_import_check=ok' ]"
check "#68414's verdict prints run 1's BEFORE as a reference and the unit test's result" \
  "python3 '$V' '$d' FIX REPRO | grep -qx 'gdn_before_reference=hack/vllm-gdn-68414/runs/2026-11-19-run1-spot-reclaimed/verdict.txt: $BUGGY' && python3 '$V' '$d' FIX REPRO | grep -qx 'gdn_unit=passed'"
# named ITEM VERDICT DESCRIPTION EDIT: a confirmed sweep with EDIT applied gives ITEM that VERDICT, exits non-zero for it, and leaves the other two confirmed.
named() {
  local d want; d=$(case_dir "x$RANDOM$RANDOM"); (cd "$d" && eval "$4")
  want=$(sed "s/$1=confirmed/$1=$2/" <<<"$ALL_OK")
  check "#$(case $1 in gdn) echo 68414 ;; stride) echo 68416 ;; kda) echo 68415 ;; esac): $3 -> $2" "[ \"\$(v3 '$d')\" = '$want' ] && ! vrc $1 '$d'"
}
named gdn after-not-fixed "AFTER still left rows unwritten" "sed -i 's/^repro_line=.*/repro_line=$BUGGY/' gdn-after/state.txt"
named gdn after-not-fixed "AFTER printed no result" "sed -i 's/^repro_line=.*/repro_line=/' gdn-after/state.txt"
named gdn after-not-fixed "AFTER overwrote the empty sequence's state" "sed -i 's/empty_keeps_h0 True/empty_keeps_h0 False/' gdn-after/state.txt"
named gdn after-not-fixed "AFTER's wrapper printed the fixed line and then exited 1" "sed -i 's/^repro_cuda_rc=0/repro_cuda_rc=1/' gdn-after/state.txt"
named gdn after-fixed-inexact "AFTER was off by a rounding error" "sed -i 's/o_err 0.0 /o_err 0.0009765625 /' gdn-after/state.txt"
named gdn void-identity "AFTER is missing" "rm -r gdn-after"
named gdn void-identity "AFTER applied another diff, such as run 1's" "sed -i 's/^diff_sha256=FIX/diff_sha256=OLD/' gdn-after/state.txt"
named gdn void-identity "the repro was another file" "sed -i 's/^repro_sha256=REPRO/repro_sha256=OTHER/' gdn-after/state.txt"
named gdn void-identity "the image's files were not the commit's" "sed -i 's/^base_identity=ok/base_identity=bad/' gdn-after/state.txt"
named gdn void-identity "the fix did not apply to the pinned result" "sed -i 's/^applied_identity=ok/applied_identity=bad/' gdn-after/state.txt"
named gdn void-import-check "AFTER imported index.py from somewhere else" "sed -i 's|^index_file=.*|index_file=/vllm-workspace/vllm/x.py|' gdn-after/state.txt"
named gdn void-import-check "the wrapper's own process imported another index.py" "sed -i 's|^repro_index_file=.*|repro_index_file=not-imported|' gdn-after/state.txt"
named gdn void-import-check "index.py lacked output_size" "sed -i 's/^outsize_grep_rc=0/outsize_grep_rc=1/' gdn-after/state.txt"
named gdn void-import-check "the bug line was still in index.py" "sed -i 's/^bug_grep_rc=1/bug_grep_rc=0/' gdn-after/state.txt"
named gdn void-import-check "the grep could not read index.py" "sed -i 's/^fix_grep_rc=0/fix_grep_rc=2/' gdn-after/state.txt"
d=$(case_dir unitbad); (cd "$d" && MSG=x junit $(unit_cases failure) > gdn-after/unit.xml && sed -i 's/^unit_rc=0/unit_rc=1/' gdn-after/state.txt)
check "#68414's failed unit test is named and leaves every verdict confirmed" \
  "python3 '$V' '$d' FIX REPRO | grep -q '^gdn_unit=not-passed(rc=1,cases=12,' && [ \"\$(v3 '$d')\" = '$ALL_OK' ]"
d=$(case_dir unitfew); (cd "$d" && MSG=x junit $(unit_cases | head -11) > gdn-after/unit.xml)
check "#68414's unit test with eleven cases is not called passed" "python3 '$V' '$d' FIX REPRO | grep -q '^gdn_unit=not-passed(rc=0,cases=11,'"
named stride before-did-not-reproduce "BEFORE passed both cases" "junit '$SC[recurrent]:passed' '$SC[sigmoid_gating]:passed' > stride-before/test.xml; sed -i 's/^test_rc=1/test_rc=0/' stride-before/state.txt"
named stride before-did-not-reproduce "BEFORE failed only one case" "MSG='AssertionError: Tensor-likes are not equal!' junit '$SC[recurrent]:failure' '$SC[sigmoid_gating]:passed' > stride-before/test.xml"
named stride before-did-not-reproduce "BEFORE failed on something other than unequal tensors" "MSG='RuntimeError: CUDA error' junit '$SC[recurrent]:failure' '$SC[sigmoid_gating]:failure' > stride-before/test.xml"
named stride before-did-not-reproduce "BEFORE errored rather than failed" "MSG='Tensor-likes are not equal!' junit '$SC[recurrent]:error' '$SC[sigmoid_gating]:error' > stride-before/test.xml"
named stride before-did-not-reproduce "BEFORE crashed with no junit" "rm stride-before/test.xml; sed -i 's/^test_rc=1/test_rc=139/' stride-before/state.txt"
named stride before-did-not-reproduce "BEFORE ran one case" "MSG='Tensor-likes are not equal!' junit '$SC[recurrent]:failure' > stride-before/test.xml"
named stride after-not-passed "AFTER passed one case of two" "MSG=x junit '$SC[recurrent]:passed' '$SC[sigmoid_gating]:failure' > stride-after/test.xml; sed -i 's/^test_rc=0/test_rc=1/' stride-after/state.txt"
named stride after-not-passed "AFTER's two cases are one name repeated" "junit '$SC[recurrent]:passed' '$SC[recurrent]:passed' > stride-after/test.xml"
named stride after-not-passed "AFTER exited 1 with two passes recorded" "sed -i 's/^test_rc=0/test_rc=1/' stride-after/state.txt"
named stride void-identity "BEFORE applied the whole fix" "sed -i 's/^diff_sha256=STEST/diff_sha256=SFIX/' stride-before/state.txt"
named stride void-identity "BEFORE's tree was not its pinned one, as another item's fix would make it" "sed -i 's/^base_identity=ok/base_identity=bad/' stride-before/state.txt"
named stride void-identity "AFTER started before BEFORE ended" "sed -i 's/^started=600/started=450/' stride-after/state.txt"
named stride void-identity "#68416 never ran" "rm -r stride-before stride-after"
named stride void-import-check "BEFORE's fused_recurrent.py already stepped by the token stride" "sed -i 's/^fused_recurrent_fix_count=0/fused_recurrent_fix_count=2/' stride-before/state.txt"
named stride void-import-check "AFTER's fused_sigmoid_gating.py stepped by it in one load only" "sed -i 's/^fused_sigmoid_gating_fix_count=2/fused_sigmoid_gating_fix_count=1/' stride-after/state.txt"
named stride void-import-check "AFTER imported fused_recurrent.py from the checkout" "sed -i 's|^fused_recurrent_file=.*|fused_recurrent_file=/vllm-workspace/vllm/x.py|' stride-after/state.txt"
named kda after-not-passed "AFTER passed two cases" "junit '$KC[64-32]:passed' '$KC[64-64]:passed' > kda-after/test.xml"
named kda after-not-passed "AFTER's three cases are one name repeated" "junit '$KC[64-32]:passed' '$KC[64-32]:passed' '$KC[64-32]:passed' > kda-after/test.xml"
named kda after-not-passed "AFTER exited 1 with three passes recorded" "sed -i 's/^test_rc=0/test_rc=1/' kda-after/state.txt"
named kda after-not-passed "AFTER's junit is missing" "rm kda-after/test.xml"
named kda void-before-selection "BEFORE ran 32-64 too" "junit '$KC[64-32]:passed' '$KC[32-64]:passed' > kda-before/test.xml"
named kda void-before-selection "BEFORE's command line was the whole file" "sed -i 's|^pytest_args=.*|pytest_args=$KT|' kda-before/state.txt"
named kda void-before-selection "BEFORE's command line was the old mamba path" "sed -i 's|tests/kernels/fla/test_fused_recurrent_kda.py|tests/kernels/mamba/test_fla_fused_recurrent_kda.py|' kda-before/state.txt"
named kda void-before-selection "BEFORE crashed with no junit after a widened selection" "rm kda-before/test.xml; sed -i 's/^pytest_args=.*/pytest_args=x -k 32-64/; s/^test_rc=1/test_rc=139/' kda-before/state.txt"
named kda before-did-not-reproduce "BEFORE's 64-32 case passed" "junit '$KC[64-32]:passed' > kda-before/test.xml; sed -i 's/^test_rc=1/test_rc=0/' kda-before/state.txt"
named kda before-did-not-reproduce "BEFORE failed on something other than the shape" "sed -i 's/out.shape == v.shape/out.dtype == k.dtype/' kda-before/test.xml"
named kda before-did-not-reproduce "BEFORE timed out" "rm kda-before/test.xml; sed -i 's/^test_rc=1/test_rc=124/' kda-before/state.txt"
named kda void-import-check "BEFORE imported kda.py from elsewhere" "sed -i 's|^kda_file=.*|kda_file=/vllm-workspace/vllm/kda.py|' kda-before/state.txt"
named kda void-import-check "the fix line was in kda.py BEFORE" "sed -i 's/^fix_grep_rc=1/fix_grep_rc=0/' kda-before/state.txt"
named kda void-import-check "the bug line was still in kda.py AFTER" "sed -i 's/^bug_grep_rc=1/bug_grep_rc=0/' kda-after/state.txt"
named kda void-identity "BEFORE applied the whole fix" "sed -i 's/^diff_sha256=KTEST/diff_sha256=KFIX/' kda-before/state.txt"
named kda void-identity "AFTER applied the test alone" "sed -i 's/^diff_sha256=KFIX/diff_sha256=KTEST/' kda-after/state.txt"
named kda void-identity "the #68415 container was not the commit's" "sed -i 's/^base_identity=ok/base_identity=bad/' kda-before/state.txt"
named kda void-identity "#68415 AFTER started before its BEFORE ended" "sed -i 's/^started=1200/started=1050/' kda-after/state.txt"
named kda void-identity "#68415 never ran" "rm -r kda-before kda-after"
# The image is every item's, so it alone voids all three.
for edit in "rm image-identity.txt" "sed -i 's/ $BASE_COMMIT\$/ 0000000000000000000000000000000000000000/' image-identity.txt" ": > wheel-sha256.txt"; do
  d=$(case_dir "img$RANDOM"); (cd "$d" && eval "$edit")
  check "an image record that fails ($edit) voids all three items" "[ \"\$(v3 '$d')\" = 'gdn=void-identity stride=void-identity kda=void-identity' ]"
done

# ---------------------------------------------------------------- the session's own judge and exit status
# real_case_dir NAME: a confirmed case sweep carrying the session's real pins, so the session's --judge reads it as it would a returned run.
real_case_dir() {
  local d; d=$(case_dir "$1")
  sed -i "s/^diff_sha256=FIX\$/diff_sha256=$(sv FIX_DIFF_SHA256)/; s/^repro_sha256=REPRO/repro_sha256=$(sv REPRO_SHA256)/" "$d/gdn-after/state.txt"
  sed -i "s/^diff_sha256=STEST/diff_sha256=$(sv STRIDE_TEST_DIFF_SHA256)/" "$d/stride-before/state.txt"
  sed -i "s/^diff_sha256=SFIX/diff_sha256=$(sv STRIDE_FIX_DIFF_SHA256)/" "$d/stride-after/state.txt"
  sed -i "s/^diff_sha256=KTEST/diff_sha256=$(sv KDA_TEST_DIFF_SHA256)/" "$d/kda-before/state.txt"
  sed -i "s/^diff_sha256=KFIX/diff_sha256=$(sv KDA_FIX_DIFF_SHA256)/" "$d/kda-after/state.txt"
  echo "$d"
}
# judged NAME EDIT: the session's --judge on a confirmed sweep with EDIT applied; prints its output and leaves its status in $WORK/judge-rc.
judged() {
  local d o="$WORK/judge-out-$1"; d=$(real_case_dir "j$1"); (cd "$d" && eval "$2")
  rm -rf "$o"; mkdir -p "$o"
  env -u SESSION_CONFIRM PURCHASE=spot OUT="$o" bash "$S" --judge "$d" > "$o/stdout" 2>&1; echo $? > "$WORK/judge-rc"
  cat "$o/stdout"
}
check "the session's judge exits 0 on three confirmed items and writes each verdict and the pytest summary" \
  "judged ok : | grep -qx 'verdicts=$ALL_OK' && [ \"\$(cat '$WORK/judge-rc')\" = 0 ] && grep -qx 'stride_verdict=confirmed' '$WORK/judge-out-ok/stride-verdict.txt' && [ \"\$(grep -c '(the pinned one)\$' '$WORK/judge-out-ok/pytest-summary.txt')\" = 5 ]"
check "the session's judge exits 2 when one item is not confirmed, and names it" \
  "judged onefail \"sed -i 's/^test_rc=0/test_rc=1/' kda-after/state.txt\" | grep -qx 'verdicts=gdn=confirmed stride=confirmed kda=after-not-passed' && [ \"\$(cat '$WORK/judge-rc')\" = 2 ]"
check "the session's judge exits 2 when an item's records are missing" \
  "judged missing 'rm -r stride-before stride-after' | grep -qx 'verdicts=gdn=confirmed stride=void-identity kda=confirmed' && [ \"\$(cat '$WORK/judge-rc')\" = 2 ]"
check "the session's judge exits 2 when a verdict script crashes, and the other two still stand" \
  "judged crash \"printf 'started=\\\\377\\\\n' > gdn-after/state.txt\" | grep -qx 'verdicts=gdn= stride=confirmed kda=confirmed' && [ \"\$(cat '$WORK/judge-rc')\" = 2 ] && grep -q 'UnicodeDecodeError' '$WORK/judge-out-crash/download-errors.txt'"

if [[ $failures -ne 0 ]]; then
  echo "$failures check(s) failed" >&2
  exit 1
fi
echo "all checks passed"
