#!/usr/bin/env bash
#
# Offline checks for hack/vllm-gdn-68414-session.sh run 3, the runner and state scripts it ships, its two verdicts and its pytest summary, run before anything is bought.
# The EC2 lifecycle is hack/lib/spot-run.sh's, which the 58420 and 67811 tests cover; these checks cover what is new or changed here.
# That is the purchase option and its cost refusals, the schedule, the image and its base proof, the pins and their isolation proof, the four states in fresh containers, the import checks and the collection probe, the run commands and their records, the summary's assertion lines, and that only the expected combination of each item is called "confirmed".
# The runner's whole path runs against a fake docker that executes the state scripts on a fake tree, a stub torch, and a fake pytest that selects cases as pytest does and answers from the files Python imports.
# #68414 is not part of run 3; what is left of it here checks that it stays out of the run.
#
#   bash hack/vllm-gdn-68414-session-test.sh                      # offline only
#   VLLM_SRC=~/workspace/oss/vllm bash hack/vllm-gdn-68414-session-test.sh   # also re-derives every pin and the base proof from git
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
S="$ROOT/hack/vllm-gdn-68414-session.sh"
DIR="$ROOT/hack/vllm-gdn-68414"
R="$DIR/runner.sh"
LIBS="$DIR/lib.sh"
KST="$DIR/kda-state.sh"
SST="$DIR/stride-state.sh"
KV="$DIR/kda-verdict.py"
SV="$DIR/stride-verdict.py"
PS="$DIR/pytest-summary.py"
PLUG="$DIR/fla_loaded_modules.py"
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
SGT=tests/kernels/fla/test_fused_sigmoid_gating_delta_rule.py
TU=vllm/utils/torch_utils.py
EIGHT="$IDX $GT $KDA $KT $FR $FSG $SGT $TU"
IMAGE_COMMIT=428c371b32c18a788def35abea1cb9f579278381
OLD_IMAGE_COMMIT=8700cc9ba0016bf14d8f2756f3b673e93fbcf2fd
DIGEST=sha256:9071b00dc36251a304e9099ed40b42a8260f8feb23432c8f312689e34c4d3f5f
KC=test_fused_recurrent_kda_output_has_value_shape
SC=test_state_index_table_stride_does_not_change_results
sv() { grep -m1 "^$1=" "$S" | cut -d= -f2; }

check "the session, the runner and the state scripts parse, and the verdicts, the summary, the plugin and the closure script compile" \
  "bash -n '$S' && bash -n '$R' && bash -n '$LIBS' && bash -n '$KST' && bash -n '$SST' && bash -n '$DIR/derive-pins.sh' && python3 -m py_compile '$KV' '$SV' '$PS' '$PLUG' '$DIR/import-closure.py' '$RR'"

# ---------------------------------------------------------------- schedule and cost
same=1
for pair in PULL_BOUND_S:PULL_S IMAGE_ID_S:IMAGE_ID_S SETUP_S:SETUP_S PROBE_S:PROBE_S PYTEST_S:PYTEST_S FILE_S:FILE_S STOP_S:STOP_S; do
  a=$(sv "${pair%%:*}"); b=$(grep -m1 "^${pair#*:}=" "$R" | cut -d= -f2)
  [ -n "$a" ] && [ "$a" = "$b" ] || { echo "  ${pair%%:*}=$a in the session, ${pair#*:}=$b in the runner" >&2; same=0; }
done
check "every step bound in the session is the runner's own" "[ $same = 1 ]"
# The runner's container bounds are its step bounds' sums, the ones the session's schedule adds up.
check "the runner bounds #68416 AFTER by setup + collection + pytest + whole file + stop, and each other state by setup + collection + pytest + stop" \
  "grep -qF 'contained stride-state.sh stride-after \$(( SETUP_S + PROBE_S + PYTEST_S + FILE_S + STOP_S ))' '$R' && [ \"\$(grep -cF '\$(( SETUP_S + PROBE_S + PYTEST_S + STOP_S ))' '$R')\" = 3 ] && grep -qxF 'STATES_S=\$(( 3 * (SETUP_S + PROBE_S + PYTEST_S + STOP_S) + (SETUP_S + PROBE_S + PYTEST_S + FILE_S + STOP_S) ))' '$S'"
check "a state that hits every limit still ends within its container bound, so it takes no time from the next item" \
  "grep -qF 'timeout --kill-after=\$(( STOP_S / 3 )) \"\$(left \$(( bound - STOP_S )))\" docker run' '$R' && grep -qF 'timeout \$(( STOP_S / 3 )) docker rm -f' '$R' && grep -qF 'left_over=\$(timeout \$(( STOP_S / 3 )) docker ps' '$R'"
check "the bounds are run 3's, tightened from run 2's timings" \
  "[ \"\$(for v in BRINGUP_S PULL_BOUND_S IMAGE_ID_S SETUP_S PROBE_S PYTEST_S FILE_S STOP_S EVIDENCE_UPLOAD_S; do sv \$v; done | paste -sd' ')\" = '300 1200 60 60 60 90 300 30 60' ]"
sched=$(PURCHASE=spot bash "$S" --print-schedule 2>&1)
check "the schedule is the bounds' sum ($sched)" "[ '$sched' = 'harness_end_s=2820 evidence_s=2880 stop_s=2940 termination_s=3240' ]"
check "the schedule is the same for both purchase options" "[ \"\$(PURCHASE=on-demand bash '$S' --print-schedule 2>&1)\" = '$sched' ]"
spot_worst=$(python3 -c 'print(f"{3240 / 3600 * 0.7792:.4f}")')
od_worst=$(python3 -c 'print(f"{3240 / 3600 * (1.237 + 0.0792):.4f}")')
check "the spot worst case, 3,240 s at \$0.7792/h, is \$$spot_worst, and the on-demand one at the pinned \$1.237 + \$0.0792/h is \$$od_worst, both under \$1.50" \
  "[ \"\$(sv SPOT_ALL_IN_RATE)\" = 0.7792 ] && [ \"\$(sv ON_DEMAND_RATE_PINNED)\" = 1.237 ] && [ \"\$(sv EBS_IP_RATE)\" = 0.0792 ] && [ \"\$(sv COST_CAP_USD)\" = 1.50 ] && [ '$spot_worst' = 0.7013 ] && [ '$od_worst' = 1.1846 ]"
check "the session's header states both worst cases and the highest on-demand rate it accepts" \
  "grep -qF 'so \$0.7792/h all in, and \$0.7013.' '$S' && grep -qF 'it is \$1.3162/h all in, and \$1.1846;' '$S' && grep -qF 'any compute rate above \$1.5874/h' '$S' && grep -qF 'stopped by itself 2,940 s after launch' '$S'"
check "the instance is a g5.xlarge, and Spot tries the reclaimed zone last" \
  "grep -qx 'INSTANCE_TYPE_FIXED=g5.xlarge' '$S' && grep -qx '    RECLAIMED_ZONES=\"ap-northeast-2a\"' '$S'"
costly() { cp "$S" "$WORK/costly.sh"; sed -i "$1" "$WORK/costly.sh"; ! PURCHASE=$2 bash "$WORK/costly.sh" --print-schedule > "$WORK/costly.out" 2>&1 && grep -qF "$3" "$WORK/costly.out"; }
check "a Spot rate that puts the worst case at \$1.50 or more is refused, before the schedule prints" \
  "costly 's/^SPOT_ALL_IN_RATE=.*/SPOT_ALL_IN_RATE=1.70/' spot 'the spot worst case'"
check "a pinned on-demand rate over the cap is refused even for a Spot run, so neither option can drift over" \
  "costly 's/^ON_DEMAND_RATE_PINNED=.*/ON_DEMAND_RATE_PINNED=1.70/' spot 'the on-demand worst case'"
check "a bound that stretches the schedule past \$1.50 is refused too" \
  "costly 's/^FILE_S=.*/FILE_S=3000/' spot 'is not under \$1.50'"

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
  "ec2 describe-spot-price-history") printf 'ap-northeast-2a\t0.6178\nap-northeast-2c\t0.6328\nap-northeast-2d\t0.7500\n' ;;
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
  "[ $rc = 0 ] && grep -qx 'purchase=spot compute_rate=0.70 all_in_rate=0.7792 worst_case_usd=0.7013' '$WORK/p-spot' && [ ! -s '$AWS_CALLS' ]"
fake_session "$WORK/p-od" env PURCHASE=on-demand FAKE_OD_PRICE=1.2370000000 bash "$S" --print-purchase; rc=$?
check "on-demand reads the price with one read-only Price List call for g5.xlarge in ap-northeast-2, and its worst case is \$1.1846" \
  "[ $rc = 0 ] && grep -qx 'purchase=on-demand compute_rate=1.237 all_in_rate=1.3162 worst_case_usd=1.1846' '$WORK/p-od' && grep -q '^rate_source=AWS Price List API get-products, read ' '$WORK/p-od' && [ \"\$(wc -l < '$AWS_CALLS')\" = 1 ] && grep -q '^aws pricing get-products --region us-east-1 --service-code AmazonEC2 .*instanceType,Value=g5.xlarge.*regionCode,Value=ap-northeast-2' '$AWS_CALLS'"
fake_session "$WORK/p-odhigh" env PURCHASE=on-demand FAKE_OD_PRICE=1.70 bash "$S" --print-purchase; rc=$?
check "an on-demand price whose worst case is over \$1.50 is refused" \
  "[ $rc != 0 ] && grep -qF 'SESSION REFUSED: the on-demand worst case, 3240 s at \$1.7792/h all in' '$WORK/p-odhigh' && grep -qF 'is \$1.6013, not under \$1.50' '$WORK/p-odhigh' && ! grep -q '^purchase=' '$WORK/p-odhigh'"
fake_session "$WORK/p-odedge" env PURCHASE=on-demand FAKE_OD_PRICE=1.5874 bash "$S" --print-purchase; rc1=$?
fake_session "$WORK/p-odover" env PURCHASE=on-demand FAKE_OD_PRICE=1.5875 bash "$S" --print-purchase; rc2=$?
check "the on-demand cap falls between \$1.5874/h, accepted, and \$1.5875/h, refused" "[ $rc1 = 0 ] && [ $rc2 != 0 ]"
fake_session "$WORK/p-odtwo" env PURCHASE=on-demand FAKE_OD_PRICE=1.20,1.70 bash "$S" --print-purchase; rc=$?
check "an answer with two prices is judged at the higher one" "[ $rc != 0 ] && grep -qF '(\$1.7/h from AWS Price List API' '$WORK/p-odtwo'"
fake_session "$WORK/p-odfail" env PURCHASE=on-demand FAKE_PRICING_FAIL=1 bash "$S" --print-purchase; rc=$?
check "a failed price read falls back to the pinned \$1.237/h, says so with its source, and still checks the cap" \
  "[ $rc = 0 ] && grep -qx 'purchase=on-demand compute_rate=1.237 all_in_rate=1.3162 worst_case_usd=1.1846' '$WORK/p-odfail' && grep -qF 'rate_source=pinned: AWS Price List API APN2-BoxUsage:g5.xlarge OnDemand 1.2370000000 USD/Hrs, effective 2026-11-01, read 2026-11-19 (the live read failed: An error occurred (AccessDeniedException)' '$WORK/p-odfail'"
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
# pinned_to NAME FIX TEST: the session with #68416's two pins set, run confirmed with an AMI against the fake aws.
pinned_to() {
  sed -e "s/^STRIDE_FIX_DIFF_SHA256=.*/STRIDE_FIX_DIFF_SHA256=$2/" -e "s/^STRIDE_TEST_DIFF_SHA256=.*/STRIDE_TEST_DIFF_SHA256=$3/" "$S" > "$WORK/$1.sh"
  : > "$AWS_CALLS"
  env -u PURCHASE PATH="$WORK/awsbin:$PATH" OUT="$WORK/never" PURCHASE=spot SESSION_CONFIRM=yes VLLMGDN_AMI_ID=ami-0123456789abcdef0 bash "$WORK/$1.sh" > "$WORK/$1.out" 2>&1
}
pinned_to unfitfix 6bf2352933b148465f6437098280bfba2c1e4ff7ca586ca3d5e9d87fc71a6fe9 "$(sv STRIDE_TEST_DIFF_SHA256)"
check "a session pinned to efdbec4e2d's unfit fix diff is refused before any AWS call" \
  "grep -qF 'SESSION REFUSED: the pinned diff 6bf2352933b148465f6437098280bfba2c1e4ff7ca586ca3d5e9d87fc71a6fe9 is not fit for a paid run' '$WORK/unfitfix.out' && [ ! -s '$AWS_CALLS' ] && [ ! -e '$WORK/never' ]"
pinned_to unfittest "$(sv STRIDE_FIX_DIFF_SHA256)" abbfbaf392a39a3083ab1ff285dd3f747ebde4fa07b157f20781503391ea3ec4
check "a session pinned to efdbec4e2d's unfit test diff is refused before any AWS call, and the header says why" \
  "grep -qF 'SESSION REFUSED: the pinned diff abbfbaf392a39a3083ab1ff285dd3f747ebde4fa07b157f20781503391ea3ec4 is not fit for a paid run' '$WORK/unfittest.out' && [ ! -s '$AWS_CALLS' ] && grep -qF 'so the output holds 1 x 6 x 1 x 64 = 384 elements while the kernel writes 6 x 2 x 64 = 768.' '$S'"
fake_session "$WORK/fit.out" env PURCHASE=spot SESSION_CONFIRM=yes VLLMGDN_AMI_ID=ami-0123456789abcdef0 bash "$S"
check "the session as pinned, 541d8b9771's diffs, goes past that refusal to its next check" "! grep -q 'not fit for a paid run' '$WORK/fit.out' && grep -q 'SESSION REFUSED' '$WORK/fit.out'"
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
check "the instance arms its 2,940 s backstop before anything else can fail ($first_cmd)" \
  "[ '${first_cmd#*:}' = '( sleep 2940; shutdown -h now ) &' ] && [ '${first_cmd%%:*}' -lt '$first_aws' ]"
check "the precise backstop counts from LaunchTime, and the runner ends at LaunchTime + 2,820 s" \
  "grep -q '( sleep \$(( L + 2940 - ' '$WORK/ud.sh' && grep -q 'HE=\$(( L + 2820 ))' '$WORK/ud.sh' && grep -q 'EV=\$(( L + 2880 ))' '$WORK/ud.sh' && grep -q 'P1=\$(( L + 300 ))' '$WORK/ud.sh'"
check "the instance runs this session's runner and returns this session's records" \
  "grep -q 'bash /opt/gdn/in/runner.sh /opt/gdn/in /src/gdn-run/sweep' '$WORK/ud.sh' && ! grep -qE 'tp-run|/opt/tp/' '$WORK/ud.sh'"

# ---------------------------------------------------------------- the image
check "the runner pins vLLM CI's image for 428c371b32 by digest, and checks that digest and that revision" \
  "grep -qx 'IMG=\"public.ecr.aws/q9t5s3a7/vllm-ci-postmerge-repo@$DIGEST\"' '$R' && grep -qx 'VLLM_COMMIT=$IMAGE_COMMIT' '$R' && [ \"\$(grep -cF '$DIGEST' '$R')\" = 2 ] && ! grep -q '45feec27226e1dc9\\|$OLD_IMAGE_COMMIT' '$R'"
check "the runner and the two verdicts name the same image digest and commit" \
  "[ \"\$(grep -lF 'IMAGE_DIGEST = \"$DIGEST\"' '$KV' '$SV' | wc -l)\" = 2 ] && [ \"\$(grep -lF 'VLLM_COMMIT = \"$IMAGE_COMMIT\"' '$KV' '$SV' | wc -l)\" = 2 ]"

# ---------------------------------------------------------------- the diffs and the pins
dsha() { sha256sum "$1" | cut -d' ' -f1; }
check "the session pins every diff at its own sha256" \
  "[ \"\$(dsha '$DIR/kda-fix.diff')\" = \"\$(sv KDA_FIX_DIFF_SHA256)\" ] && [ \"\$(dsha '$DIR/kda-test.diff')\" = \"\$(sv KDA_TEST_DIFF_SHA256)\" ] && [ \"\$(dsha '$DIR/stride-fix.diff')\" = \"\$(sv STRIDE_FIX_DIFF_SHA256)\" ] && [ \"\$(dsha '$DIR/stride-test.diff')\" = \"\$(sv STRIDE_TEST_DIFF_SHA256)\" ]"
check "the diffs are the ones storage pushed, #68415's in 4a38c4fb and #68416's in f11148fc, by their sha256" \
  "[ \"\$(sv KDA_FIX_DIFF_SHA256)\" = 5f98c5d6b71f8c299d1087697cd696ceca4b64ca2c38db469a86b474e86d1f84 ] && [ \"\$(sv KDA_TEST_DIFF_SHA256)\" = b56b698ca429b680cbd1526166ba40b60ff525506658238a64428e013724868a ] && [ \"\$(sv STRIDE_FIX_DIFF_SHA256)\" = 0eaef549b2b6919272666660626e70734fb3b07b25ec13d29f52e1d3c178b60a ] && [ \"\$(sv STRIDE_TEST_DIFF_SHA256)\" = 21d8bbecee8dae26df7b75630d3f059513dda2cf022787f8edea28cc04bc5e94 ]"
if [ -d "$STORAGE" ]; then
  check "each diff is the storage copy byte for byte" \
    "cmp -s '$STORAGE/kda-output-shape-68415/fix.diff' '$DIR/kda-fix.diff' && cmp -s '$STORAGE/kda-output-shape-68415/test-only.diff' '$DIR/kda-test.diff' && cmp -s '$STORAGE/state-index-stride-68416/fix.diff' '$DIR/stride-fix.diff' && cmp -s '$STORAGE/state-index-stride-68416/test-only.diff' '$DIR/stride-test.diff'"
else
  echo "skip the diffs against storage (not readable here)"
fi
# test_diff TEST FIX TESTPATH VLLMPATHS: the test diff is the fix diff's first part, the test file alone.
test_diff() {
  cmp -s <(head -c "$(wc -c < "$1")" "$2") "$1" && [ "$(grep '^diff --git' "$1")" = "diff --git a/$3 b/$3" ] &&
    [ "$(grep '^diff --git' "$2" | awk '{print substr($3, 3)}' | paste -sd' ')" = "$3 $4" ]
}
check "kda-test.diff is kda-fix.diff's first part, the new test file, and the fix changes kda.py alone besides" "test_diff '$DIR/kda-test.diff' '$DIR/kda-fix.diff' $KT $KDA"
check "stride-test.diff is stride-fix.diff's first part, the test file, and the fix changes the two kernels besides" "test_diff '$DIR/stride-test.diff' '$DIR/stride-fix.diff' $SGT '$FR $FSG'"
check "#68416's diff changes an existing test file, which BEFORE must therefore apply and not create" \
  "! grep -q '^new file mode' '$DIR/stride-test.diff' && grep -q '^new file mode' '$DIR/kda-test.diff'"
check "the session ships the shared lib, the plugin and each item's state script, pins, differs list and diffs" \
  "grep -qF 'cp \"\$RUNNER\" \"\$LIB\" \"\$PLUGIN\" \"\$OUT/in/\"' '$S' && grep -qF 'cp \"\$KDA_STATE\" \"\$KDA_PINS\" \"\$KDA_DIFFERS\" \"\$KDA_FIX_DIFF\" \"\$KDA_TEST_DIFF\" \"\$OUT/in/\"' '$S' && grep -qF 'cp \"\$STRIDE_STATE\" \"\$STRIDE_PINS\" \"\$STRIDE_DIFFERS\" \"\$STRIDE_FIX_DIFF\" \"\$STRIDE_TEST_DIFF\" \"\$OUT/in/\"' '$S'"
check "the session checks all four diffs against their pins before packing them" \
  "grep -qF 'for pair in \"\$KDA_FIX_DIFF:\$KDA_FIX_DIFF_SHA256\" \"\$KDA_TEST_DIFF:\$KDA_TEST_DIFF_SHA256\" \\' '$S' && grep -qF '  \"\$STRIDE_FIX_DIFF:\$STRIDE_FIX_DIFF_SHA256\" \"\$STRIDE_TEST_DIFF:\$STRIDE_TEST_DIFF_SHA256\"; do' '$S'"
# #68414 stays out of run 3: nothing of it is shipped, run or judged, and its pins cannot be re-derived on run 3's image.
check "#68414 is not shipped, run or judged, and derive-pins.sh refuses it" \
  "! grep -qE '^(STATE|PINS|VERDICT|FIX_DIFF|REPRO|RUN_REPRO)=' '$S' && ! grep -q ' state.sh \\|gdn-after\\|/in/state.sh' '$R' && grep -qxF 'all_confirmed() { [ \"\$VERDICTS\" = \"stride=confirmed kda=confirmed\" ]; }' '$S' && ! bash '$DIR/derive-pins.sh' gdn /nonexistent 2>/dev/null"

pinf() { echo "$DIR/$1-pins.txt"; }
# pin ITEM STATE PATH: the pinned value.
pin() { awk -v s="$2" -v p="$3" '$1 == s && $3 == p {print $2}' "$(pinf "$1")"; }
refs_of() { case $1 in kda) echo "diffbase-428c371b32 fixcommit-841cd50ff0" ;; stride) echo "diffbase-545ef08189 fixcommit-541d8b9771" ;; esac; }
own_of() { case $1 in kda) echo "$KDA $KT" ;; stride) echo "$FR $FSG $SGT" ;; esac; }
pins_shape() {
  local item st want
  want=$(tr ' ' '\n' <<<"$EIGHT" | sort | paste -sd' ')
  for item in kda stride; do
    [ "$(awk '{print $1}' "$(pinf "$item")" | sort -u | paste -sd' ')" = "$(tr ' ' '\n' <<<"base before after $(refs_of "$item")" | sort | paste -sd' ')" ] || return 1
    for st in base before after $(refs_of "$item"); do
      [ "$(awk -v s="$st" '$1 == s {print $3}' "$(pinf "$item")" | sort | paste -sd' ')" = "$want" ] || return 1
    done
  done
  grep -qx 'PINNED_PATHS=8' "$LIBS"
}
check "each pins file names all eight files once per state and once more at its diff base and its fix commit, and lib.sh checks eight" "pins_shape"
pins_isolation() {
  local item st p
  for item in kda stride; do
    for p in $EIGHT; do
      [ "$(pin "$item" base "$p")" = "$(pin kda base "$p")" ] || return 1
      case " $(own_of "$item") " in *" $p "*) continue ;; esac
      for st in before after; do [ "$(pin "$item" "$st" "$p")" = "$(pin kda base "$p")" ] || return 1; done
    done
  done
  [ "$(pin kda base "$GT")" = absent ] && [ "$(pin kda base "$KT")" = absent ] && [ "$(pin kda base "$SGT")" != absent ]
}
check "isolation: in every state of every item, the other items' files and torch_utils.py are the image's, and #68414's and #68415's tests are absent there" "pins_isolation"
pins_own() {
  [ "$(pin kda before "$KDA")" = "$(pin kda base "$KDA")" ] && [ "$(pin kda before "$KT")" != absent ] &&
    [ "$(pin kda after "$KDA")" != "$(pin kda base "$KDA")" ] && [ "$(pin kda after "$KT")" = "$(pin kda before "$KT")" ] &&
    [ "$(pin stride before "$FR")" = "$(pin stride base "$FR")" ] && [ "$(pin stride before "$FSG")" = "$(pin stride base "$FSG")" ] &&
    [ "$(pin stride before "$SGT")" != "$(pin stride base "$SGT")" ] && [ "$(pin stride after "$FR")" != "$(pin stride base "$FR")" ] &&
    [ "$(pin stride after "$FSG")" != "$(pin stride base "$FSG")" ] && [ "$(pin stride after "$SGT")" = "$(pin stride before "$SGT")" ]
}
check "each item's own files: BEFORE changes only the test, AFTER also changes the source" "pins_own"
pins_ref() {
  local item p r
  for item in kda stride; do
    set -- $(refs_of "$item")
    for p in $EIGHT; do
      [ "$(pin "$item" "$1" "$p")" = "$(pin "$item" base "$p")" ] || return 1
      [ "$(pin "$item" "$2" "$p")" = "$(pin "$item" after "$p")" ] || return 1
    done
  done
}
check "base proof: all eight files are the image's at both diff bases, 545ef08189 included, and each AFTER is its fix commit file for file" "pins_ref"
check "#68415's diff base is the image's own commit, so nothing can differ there, and #68416's lists the sixteen files 545ef08189 changed since" \
  "[ ! -s '$DIR/kda-differs.txt' ] && [ \"\$(wc -l < '$DIR/stride-differs.txt')\" = 16 ] && ! grep -qxF -f <(tr ' ' '\n' <<<'$EIGHT') '$DIR/stride-differs.txt'"
kfixl=$(grep -m1 "^FIX_LINE=" "$KST" | cut -d"'" -f2); kbugl=$(grep -m1 "^BUG_LINE=" "$KST" | cut -d"'" -f2)
check "kda-state.sh's fix line is the line kda-fix.diff adds and its bug line the one it removes, and stride-state.sh checks the same two" \
  "grep -qxF -- '+$kfixl' '$DIR/kda-fix.diff' && grep -qxF -- '-$kbugl' '$DIR/kda-fix.diff' && grep -qxF \"KDA_FIX_LINE='$kfixl'\" '$SST' && grep -qxF \"KDA_BUG_LINE='$kbugl'\" '$SST'"
sfix=$(grep -m1 "^FIX_TEXT=" "$SST" | cut -d"'" -f2)
check "stride-state.sh's term ($sfix) is added to four loads by stride-fix.diff, two per kernel, removed from none, and kda-state.sh checks for the same term" \
  "[ \"\$(grep '^+' '$DIR/stride-fix.diff' | grep -cF '$sfix')\" = 4 ] && ! grep '^-' '$DIR/stride-fix.diff' | grep -qF '$sfix' && grep -qx 'FIX_COUNT_AFTER = \"2\"' '$SV' && grep -qxF \"STRIDE_FIX_TEXT='$sfix'\" '$KST'"
check "the verdicts judge the files the state scripts import from the image's dist-packages and the checkout" \
  "grep -qx 'SITE=/usr/local/lib/python3.12/dist-packages' '$LIBS' && grep -qx 'W=/vllm-workspace' '$LIBS' && [ \"\$(grep -lF 'OPS = \"/usr/local/lib/python3.12/dist-packages/$OPS\"' '$KV' '$SV' | wc -l)\" = 2 ] && grep -qF 'TEST_FILE = \"/vllm-workspace/$KT\"' '$KV' && grep -qF 'TEST_FILE = \"/vllm-workspace/$SGT\"' '$SV'"
check "the stride verdict expects the whole file's 21 cases, as its parametrization gives (3 x 2 + 3 x 2 x 2 + 3)" "grep -qx 'FILE_CASES = 21' '$SV'"
# The pins and the base proof are re-derived from a vLLM clone when one is given, since only git proves them the commits'.
if [ -n "${VLLM_SRC:-}" ]; then
  g() { git -C "$VLLM_SRC" "$@"; }
  for item in kda stride; do
    check "$item-pins.txt and $item-differs.txt are what derive-pins.sh makes of $VLLM_SRC" \
      "diff <(bash '$DIR/derive-pins.sh' $item '$VLLM_SRC') '$(pinf $item)' > /dev/null && diff <(bash '$DIR/derive-pins.sh' $item-differs '$VLLM_SRC') '$DIR/$item-differs.txt' > /dev/null"
  done
  check "each fix diff is its commit's diff from its base byte for byte, and each test diff that commit's test-file part" \
    "[ \"\$(g rev-parse 841cd50ff0^)\" = $IMAGE_COMMIT ] && cmp -s <(g diff $IMAGE_COMMIT 841cd50ff0) '$DIR/kda-fix.diff' && cmp -s <(g diff $IMAGE_COMMIT 841cd50ff0 -- $KT) '$DIR/kda-test.diff' && [ \"\$(g rev-parse 541d8b9771^)\" = 545ef081895681ba4c2aa3c6699326e3a2f3cbf7 ] && cmp -s <(g diff 545ef08189 541d8b9771) '$DIR/stride-fix.diff' && cmp -s <(g diff 545ef08189 541d8b9771 -- $SGT) '$DIR/stride-test.diff'"
  # closure FIXCOMMIT TEST: the import-time closure of TEST at FIXCOMMIT with the conftest files pytest loads for it.
  closure() { python3 "$DIR/import-closure.py" "$VLLM_SRC" "$1" "$2" tests/conftest.py tests/kernels/conftest.py | LC_ALL=C sort; }
  closure 841cd50ff0 "$KT" > "$WORK/closure-kda"; closure 541d8b9771 "$SGT" > "$WORK/closure-stride"
  check "base proof, why run 3 left 8700cc9ba0: torch_utils.py differs between it and both diff bases, and both tests import it" \
    "[ \"\$(g diff --name-only $OLD_IMAGE_COMMIT $IMAGE_COMMIT)\" = $TU ] && g diff --name-only $OLD_IMAGE_COMMIT 545ef08189 | grep -qx $TU && grep -qx $TU '$WORK/closure-kda' && grep -qx $TU '$WORK/closure-stride' && grep -q '^from vllm.utils.torch_utils import set_random_seed\$' <(g show 541d8b9771:$SGT)"
  check "base proof: no file in either test's import-time closure, conftest files included, differs between the image's commit and its diff base" \
    "[ \"\$(wc -l < '$WORK/closure-kda')\" -gt 100 ] && [ -z \"\$(LC_ALL=C comm -12 '$WORK/closure-kda' <(g diff --name-only $IMAGE_COMMIT $IMAGE_COMMIT | LC_ALL=C sort))\" ] && [ -z \"\$(LC_ALL=C comm -12 '$WORK/closure-stride' <(g diff --name-only $IMAGE_COMMIT 545ef08189 | LC_ALL=C sort))\" ] && grep -qx $FR '$WORK/closure-stride' && grep -qx $KDA '$WORK/closure-stride'"
  check "base proof: every file each diff changes is the same at the image's commit and at its diff base" \
    "( for p in \$(g diff --name-only 545ef08189 541d8b9771) \$(g diff --name-only $IMAGE_COMMIT 841cd50ff0); do [ \"\$(g rev-parse --verify -q $IMAGE_COMMIT:\$p || echo absent)\" = \"\$(g rev-parse --verify -q 545ef08189:\$p || echo absent)\" ] || exit 1; done )"
else
  echo "skip the pins and the base proof against a vLLM clone (set VLLM_SRC to re-derive them)"
fi

check "the session's exit status is 1 without a confirmed termination or the whole evidence, and 2 unless the judge's two verdicts are both confirmed" \
  "[ \"\$(tail -n 3 '$S' | paste -sd'|')\" = '[ \"\$TERMINATION\" = confirmed ] || exit 1|[ \"\$EVIDENCE\" = returned ] || exit 1|all_confirmed || exit 2' ] && grep -qxF 'judge \"\$SWEEP\"' '$S' && grep -qF 'echo \"verdicts=\$VERDICTS\"' '$S'"

# ---------------------------------------------------------------- #68414's wrapper, dormant but unchanged, against a stub torch
# The stub records the default device, and answers the GPU name lib.sh reads.
mkdir -p "$WORK/stubs/torch"
cat > "$WORK/stubs/torch/__init__.py" <<'EOF'
__version__ = "0.0-stub"
_default = "cpu"
def set_default_device(d):
    global _default
    _default = d
class cuda:
    @staticmethod
    def get_device_name(i=0):
        return "NVIDIA A10G"
EOF
mkdir -p "$WORK/wr"
printf 'import sys, torch\nprint("device", torch._default, "name", __name__, "argv0", sys.argv[0])\n' > "$WORK/wr/repro.py"
wsha=$(sha256sum "$WORK/wr/repro.py" | cut -d' ' -f1)
PYTHONPATH="$WORK/stubs" "$REAL_PY" "$RR" "$WORK/wr/repro.py" "$wsha" > "$WORK/wr/out" 2>&1; wrc=$?
check "#68414's wrapper still checks the sha256, sets CUDA as the default before the file runs, and runs it as __main__" \
  "[ $wrc = 0 ] && grep -qx 'REPRO_SHA256=$wsha' '$WORK/wr/out' && grep -q '^device cuda name __main__ ' '$WORK/wr/out'"

# ---------------------------------------------------------------- the runner's whole path, against fakes
# A fake tree with the real shape: the package's sources with their real bug lines, kda.py launching fused_recurrent.py's kernel, and the checkout's tests.
P="$WORK/pristine"
mkdir -p "$P/site/$OPS" "$P/site/vllm/utils" "$P/w/tests/kernels/fla" "$WORK/mk"
for d in vllm vllm/third_party vllm/third_party/flash_linear_attention "$OPS" vllm/utils; do : > "$P/site/$d/__init__.py"; done
for d in tests tests/kernels tests/kernels/fla; do : > "$P/w/$d/__init__.py"; done
: > "$P/w/tests/conftest.py"
printf 'def prepare_chunk_indices(indices):\n    return indices\n' > "$P/site/$IDX"
printf 'from .fused_recurrent import fused_recurrent_gated_delta_rule_fwd_kernel\n\ndef fwd(k, v):\n%s\n    w = torch.empty_like(k)\n    return o\n' "$kbugl" > "$P/site/$KDA"
# The kernel is wrapped twice, as triton.heuristics over triton.jit wraps the real one, each keeping what it wraps in .fn.
for f in "$FR" "$FSG"; do
  printf 'class _Wrap:\n    def __init__(self, fn):\n        self.fn = fn\n\ndef _kernel(ssm_state_indices, i_n, stride_indices_seq, stride_indices_tok, i_t):\n    a = (ssm_state_indices + i_n * stride_indices_seq + i_t)\n    b = (ssm_state_indices + i_n * stride_indices_seq + i_t)\n\nfused_recurrent_gated_delta_rule_fwd_kernel = _Wrap(_Wrap(_kernel))\n' > "$P/site/$f"
done
printf 'def set_random_seed(seed):\n    return seed\n' > "$P/site/$TU"
printf 'def test_fused_sigmoid_gating_delta_rule_update_non_spec():\n    pass\n' > "$P/w/$SGT"
mkdiff() { # mkdiff OUT CMD...: the diff from the pristine files to what CMD leaves, made with git as the real ones are
  rm -rf "$WORK/mk/t"; mkdir -p "$WORK/mk/t"; cp -r "$P/site/vllm" "$P/w/tests" "$WORK/mk/t/"
  (cd "$WORK/mk/t" && git init -q && git add -A && git -c user.email=t@t -c user.name=t commit -qm base && "${@:2}" && git add -A && git diff --cached > "$1")
}
mkdir -p "$WORK/in"
addtest="printf '\ndef $SC():\n    pass\n' >> $SGT"
mkdiff "$WORK/in/kda-test.diff" sh -c "printf 'def test_x():\n    pass\n' > $KT"
mkdiff "$WORK/in/kda-fix.diff" sh -c "printf 'def test_x():\n    pass\n' > $KT && sed -i 's/^$kbugl\$/$kfixl/' $KDA"
mkdiff "$WORK/in/stride-test.diff" sh -c "$addtest"
mkdiff "$WORK/in/stride-fix.diff" sh -c "$addtest && sed -i 's/+ i_t)\$/+ i_t * stride_indices_tok)/' $FR $FSG"
# mkpins ITEM: the item's pins over the fake tree, made as derive-pins.sh makes the real ones.
mkpins() {
  local item=$1 st d p out="$WORK/in/$1-pins.txt"
  : > "$out"
  for st in base before after; do
    rm -rf "$WORK/mk/p"; mkdir -p "$WORK/mk/p"; cp -r "$P/site/vllm" "$P/w/tests" "$WORK/mk/p/"
    case $st in before) d=$item-test.diff ;; after) d=$item-fix.diff ;; *) d="" ;; esac
    # A pristine tree that already holds a fix cannot take it again, so that refusal goes to a log, not the screen.
    [ -z "$d" ] || (cd "$WORK/mk/p" && git apply "$WORK/in/$d") 2>>"$WORK/mkpins.err"
    for p in $EIGHT; do
      if [ -e "$WORK/mk/p/$p" ]; then echo "$st $(sha256sum "$WORK/mk/p/$p" | cut -d' ' -f1) $p"; else echo "$st absent $p"; fi
    done >> "$out"
  done
}
mkpins kda; mkpins stride
: > "$WORK/in/kda-differs.txt"
echo vllm/v1/engine/detokenizer.py > "$WORK/in/stride-differs.txt"
cp "$PLUG" "$WORK/in/"
# The shared lib with its four container paths moved onto the fake tree; the state scripts are shipped unchanged.
sed -e "s|^SITE=.*|SITE=$WORK/site|" -e "s|^W=.*|W=$WORK/w|" -e "s|^OUT_ROOT=.*|OUT_ROOT=$WORK/out|" \
  -e "s|^WHEEL_SHA_FILE=.*|WHEEL_SHA_FILE=$WORK/wheel.sha256|" "$LIBS" > "$WORK/in/lib.sh"
cp "$KST" "$SST" "$WORK/in/"
echo "sha256:abc  vllm-0.0.0-cp38-abi3-linux_x86_64.whl" > "$WORK/wheel.sha256"
check "the state scripts hold no container path of their own, so moving the lib's four moves them all" \
  "! grep -nE '/usr/local/lib|/vllm-workspace|/out/|/tmp/' '$KST' '$SST' | grep -v ':[0-9]*:#' && [ \"\$(grep -cE '^(SITE|W|OUT_ROOT|WHEEL_SHA_FILE)=' '$LIBS')\" = 4 ] && ! grep -nE '/usr/local/lib|/vllm-workspace|=/out\$|/tmp/vllm-wheel' '$WORK/in/lib.sh'"

# The fake pytest selects cases as pytest does, by node id and then by -k, and answers from the files Python imports.
# Its failure texts are what --tb=short writes into the junit: the file and line, the statement, and the E lines.
# Run unfixed, #68415's k32-v64 case writes past its output, so the fake records the breach and dies as a crashed process would.
cat > "$WORK/fake_pytest.py" <<'EOF'
import importlib, os, sys
from xml.sax.saxutils import escape, quoteattr
args = sys.argv[1:]
if args[:1] == ["--version"]:
    print("pytest 8.3.5")
    sys.exit(0)
# python3 -m puts the working directory first on the path, which running this file does not.
sys.path.insert(0, os.getcwd())
collect = "--collect-only" in args
calls = open(os.environ["WORK"] + "/calls", "a")
calls.write("%s %s\n" % ("collect" if collect else "pytest", " ".join(a for a in args if not a.startswith("--junitxml="))))
OPS = "vllm.third_party.flash_linear_attention.ops."
src = lambda mod: open(importlib.import_module(OPS + mod).__file__).read()
test = next(a.split("::")[0] for a in args if a.startswith("tests/"))
named = [a.split("[", 1)[1][:-1] for a in args if "::" in a and "[" in a]
kexpr = args[args.index("-k") + 1] if "-k" in args else None
def select(names):
    sel = [n for n in names if not named or n.split("[", 1)[1][:-1] in named]
    if kexpr is not None and kexpr.startswith("not "):
        sel = [n for n in sel if kexpr[4:] not in n]
    elif kexpr is not None:
        sel = [n for n in sel if kexpr in n]
    return sel
if collect:
    if os.environ.get("FAKE_PROBE_FAIL"):
        sys.exit(2)
    importlib.import_module("tests.conftest")
    importlib.import_module(test[:-3].replace("/", "."))
    importlib.import_module("vllm.utils.torch_utils")
    importlib.import_module(OPS + "kda")
    importlib.import_module(args[args.index("-p") + 1]).pytest_collection_finish(None)
    print("collected")
    sys.exit(0)
KC = "test_fused_recurrent_kda_output_has_value_shape"
SC = "test_state_index_table_stride_does_not_change_results"
cases = []
if test.endswith("test_fused_recurrent_kda.py"):
    fixed = any(l == os.environ["KFIXL"] for l in src("kda").splitlines())
    sel = select(["%s[%s]" % (KC, i) for i in ("k64-v32", "k64-v64", "k32-v64", "k64-v32-hv2", "v-bf16")])
    calls.write("kda-selected %s fixed=%s\n" % (",".join(n.split("[")[1][:-1] for n in sel), fixed))
    if any("k32-v64" in n for n in sel) and not fixed:
        calls.write("KDA k32-v64 RAN UNFIXED\n")
        sys.exit(139)
    shape = {"k64-v32": ("[1, 4, 1, 32]", "3 diff: 64 != 32"), "k64-v32-hv2": ("[1, 4, 2, 32]", "2 diff: 1 != 2")}
    for n in sel:
        i = n.split("[")[1][:-1]
        head = "tests/kernels/fla/test_fused_recurrent_kda.py:63: in %s\n" % KC
        if not fixed and i in shape and os.environ.get("FAKE_KDA_WRONG_FAIL"):
            cases.append((n, "AssertionError: assert torch.float16 == torch.bfloat16", head + "    assert out.dtype == k.dtype\nE   AssertionError: assert torch.float16 == torch.bfloat16"))
        elif not fixed and i in shape:
            v, at = shape[i]
            line = "assert torch.Size([1, 4, 1, 64]) == torch.Size(%s)" % v
            cases.append((n, line, head + "    assert out.shape == v.shape\nE   %s\nE     \nE     At index %s\nE     Use -v to get more diff" % (line, at)))
        elif fixed and i == "k32-v64" and os.environ.get("FAKE_KDA_AFTER_FAIL"):
            cases.append((n, "assert 3 == 0", head + "    assert torch.count_nonzero(out) == 0\nE   assert 3 == 0"))
        else:
            cases.append((n, None, None))
elif test.endswith("test_fused_sigmoid_gating_delta_rule.py"):
    if os.environ.get("FAKE_STRIDE_CRASH"):
        sys.exit(139)
    whole = ["test_fused_sigmoid_gating_delta_rule_update_non_spec[%s-%d]" % (d, r) for r in (1, 2, 4) for d in ("float32", "bfloat16")]
    whole += ["test_fused_sigmoid_gating_delta_rule_update_spec[%s-%d-%d]" % (d, s, r) for r in (1, 2, 4) for s in (1, 3) for d in ("float32", "bfloat16")]
    whole += ["%s[%s]" % (SC, k) for k in ("recurrent", "sigmoid_gating", "kda")]
    sel = select(whole)
    calls.write("stride-selected %s\n" % ",".join(n.split("[")[1][:-1] for n in sel if n.startswith(SC)))
    kernel = {"recurrent": "fused_recurrent", "sigmoid_gating": "fused_sigmoid_gating", "kda": "fused_recurrent"}
    for n in sel:
        bad = None
        if n.startswith(SC) and "i_t * stride_indices_tok" not in src(kernel[n.split("[")[1][:-1]]):
            bad = "tests/kernels/fla/test_fused_sigmoid_gating_delta_rule.py:266: in %s\n    torch.testing.assert_close(results[0][0], results[1][0], rtol=0, atol=0)\nE   AssertionError: Tensor-likes are not equal!\nE   \nE   Mismatched elements: 3 / 768 (0.4%%)\nE   Greatest absolute difference: 0.25 at index (0, 4, 1, 7)" % SC
        elif not n.startswith(SC) and n == whole[0] and os.environ.get("FAKE_FILE_FAIL"):
            bad = "tests/kernels/fla/test_fused_sigmoid_gating_delta_rule.py:90: in x\n    torch.testing.assert_close(o, o_ref)\nE   AssertionError: Tensor-likes are not close!"
        cases.append((n, bad and bad.split("\n")[2][4:], bad))
else:
    sys.exit(4)
xml = next(a.split("=", 1)[1] for a in args if a.startswith("--junitxml="))
body = "".join('<testcase classname="t" name=%s>%s</testcase>' % (quoteattr(n), "<failure message=%s>%s</failure>" % (quoteattr(m), escape(t)) if t else "") for n, m, t in cases)
open(xml, "w").write("<testsuites><testsuite>%s</testsuite></testsuites>" % body)
bad = sum(1 for _, _, t in cases if t)
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
  image) echo "[\"public.ecr.aws/q9t5s3a7/vllm-ci-postmerge-repo@sha256:9071b00dc36251a304e9099ed40b42a8260f8feb23432c8f312689e34c4d3f5f\"] ${FAKE_REVISION:-428c371b32c18a788def35abea1cb9f579278381}" ;;
  run)
    script=$(printf '%s\n' "$@" | grep -xE '/in/(kda-state|stride-state)\.sh')
    if [ -n "$script" ]; then
      # A fresh container: the image's tree as built, unless the fake is told to leave the last state's edits.
      if [ -z "${FAKE_STALE:-}" ] || [ ! -d "$WORK/site" ]; then
        rm -rf "$WORK/site" "$WORK/w"; cp -r "$WORK/pristine/site" "$WORK/site"; cp -r "$WORK/pristine/w" "$WORK/w"
      fi
      # #68415's fix leaking into #68416's containers, as an image or a reused container could carry it.
      if [ -n "${FAKE_LEAK_KDA:-}" ] && [ "$script" = /in/stride-state.sh ]; then
        (cd "$WORK/site" && git apply --include='vllm/*' "$WORK/in/kda-fix.diff")
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
  # python3 -m pytest goes to the fake pytest; anything else is the real interpreter.
  cat > "$bin/python3" <<EOF
#!/bin/bash
if [ "\$1 \$2" = "-m pytest" ]; then shift 2; exec $REAL_PY "$WORK/fake_pytest.py" "\$@"; fi
exec $REAL_PY "\$@"
EOF
  chmod +x "$bin"/*
}
# Each verdict reads the fake tree's paths, so it is judged with those paths standing in.
sed -e "s|^OPS = .*|OPS = \"$WORK/site/$OPS\"|" -e "s|^TEST_FILE = .*|TEST_FILE = \"$WORK/w/$KT\"|" "$KV" > "$WORK/kda-verdict-local.py"
sed -e "s|^OPS = .*|OPS = \"$WORK/site/$OPS\"|" -e "s|^TEST_FILE = .*|TEST_FILE = \"$WORK/w/$SGT\"|" "$SV" > "$WORK/stride-verdict-local.py"
isha() { sha256sum "$WORK/in/$1" | cut -d' ' -f1; }
# Each prints the verdict whatever its exit status, which pipefail would otherwise turn into the pipeline's.
kvd_() { python3 "$WORK/kda-verdict-local.py" "$WORK/out-$1" "$(isha kda-test.diff)" "$(isha kda-fix.diff)"; true; }
svd_() { python3 "$WORK/stride-verdict-local.py" "$WORK/out-$1" "$(isha stride-test.diff)" "$(isha stride-fix.diff)"; true; }
# verdicts RUN: the two verdicts of one fake run, in the session's order.
verdicts() { echo "stride=$(svd_ "$1" | sed -n 's/^stride_verdict=//p') kda=$(kvd_ "$1" | sed -n 's/^kda_verdict=//p')"; }
runfake() {
  mkfakes; rm -rf "$WORK/out"; mkdir -p "$WORK/out"
  env WORK="$WORK" KFIXL="$kfixl" PATH="$WORK/bin:$PATH" "${@:2}" \
    timeout 120 bash "$WORK/runner.sh" "$WORK/in" "$WORK/out" $(( $(date +%s) + 100000 )) > "$WORK/runner-$1.out" 2>&1
  echo $? > "$WORK/rc-$1"
  rm -rf "$WORK/out-$1"; cp -r "$WORK/out" "$WORK/out-$1"; cp "$WORK/calls" "$WORK/out-$1/calls"
}
ALL_OK='stride=confirmed kda=confirmed'
KB="$WORK/out-good/kda-before/state.txt"

runfake good env
check "the runner pulls, checks the image, then runs #68416 BEFORE and AFTER and #68415 BEFORE and AFTER, and ends" \
  "[ \"\$(cat '$WORK/rc-good')\" = 0 ] && [ \"\$(grep -o 'state [a-z-]*: start\\|[a-z]* states done\\|all items done' '$WORK/out-good/steps.log' | paste -sd'|')\" = 'state stride-before: start|state stride-after: start|stride states done|state kda-before: start|state kda-after: start|kda states done|all items done' ]"
check "each state runs in its own named container, with the GPU" \
  "[ \"\$(grep -o 'run --rm --name fla-[a-z-]* --gpus all' '$WORK/calls' | awk '{print \$4}' | paste -sd' ')\" = 'fla-stride-before fla-stride-after fla-kda-before fla-kda-after' ]"
applied_ok() { local d; for d in stride-before stride-after kda-before kda-after; do [ "$(grep -c '^base_identity=ok$\|^apply=ok$\|^applied_identity=ok$' "$WORK/out-good/$d/state.txt")" = 3 ] || return 1; done; }
check "every state's tree held its pins before and after its diff" "applied_ok"
check "each state applied its own diff: the test alone for each BEFORE, the whole diff for each AFTER" \
  "grep -qx \"diff_sha256=\$(isha stride-test.diff)\" '$WORK/out-good/stride-before/state.txt' && grep -qx \"diff_sha256=\$(isha stride-fix.diff)\" '$WORK/out-good/stride-after/state.txt' && grep -qx \"diff_sha256=\$(isha kda-test.diff)\" '$KB' && grep -qx \"diff_sha256=\$(isha kda-fix.diff)\" '$WORK/out-good/kda-after/state.txt'"
check "each git apply is recorded as its exact command and the paths it changed, and a diff with nothing under vllm/ says so" \
  "grep -qxF \"apply_checkout_cmd=cd $WORK/w && git -c 'safe.directory=*' apply '--exclude=vllm/*' $WORK/in/kda-test.diff\" '$KB' && grep -qx 'apply_checkout_files=$WORK/w/$KT' '$KB' && grep -qx 'apply_site_cmd=none: the diff changes nothing under vllm/' '$KB' && grep -qxF \"apply_site_cmd=cd $WORK/site && git -c 'safe.directory=*' apply '--include=vllm/*' $WORK/in/stride-fix.diff\" '$WORK/out-good/stride-after/state.txt' && grep -qx 'apply_site_files=$WORK/site/$FR,$WORK/site/$FSG' '$WORK/out-good/stride-after/state.txt' && grep -qx 'apply_checkout_files=$WORK/w/$SGT' '$WORK/out-good/stride-before/state.txt'"
check "each state records the python that runs the tests, its version, pytest's, and the GPU" \
  "( for d in stride-before stride-after kda-before kda-after; do grep -qx 'gpu_name=NVIDIA A10G' '$WORK/out-good/'\$d/state.txt && grep -qx 'python_executable=$REAL_PY' '$WORK/out-good/'\$d/state.txt && grep -q '^python_version=3\\.' '$WORK/out-good/'\$d/state.txt && grep -qx 'pytest_version=pytest 8.3.5' '$WORK/out-good/'\$d/state.txt || exit 1; done )"
check "the pytest calls are #68416's -k stride twice and its whole file, then #68415's four safe cases and its file, each with -rA --tb=short" \
  "[ \"\$(grep '^pytest ' '$WORK/calls' | paste -sd'|')\" = 'pytest $SGT -k stride -rA --tb=short -p no:cacheprovider|pytest $SGT -k stride -rA --tb=short -p no:cacheprovider|pytest $SGT -rA --tb=short -p no:cacheprovider|pytest $KT::$KC[k64-v32] $KT::$KC[k64-v64] $KT::$KC[k64-v32-hv2] $KT::$KC[v-bf16] -k not k32-v64 -rA --tb=short -p no:cacheprovider|pytest $KT -rA --tb=short -p no:cacheprovider' ]"
check "each state's collection probe uses the run's own selection, through the plugin" \
  "[ \"\$(grep '^collect ' '$WORK/calls' | paste -sd'|')\" = 'collect --collect-only -q -p fla_loaded_modules -p no:cacheprovider $SGT -k stride|collect --collect-only -q -p fla_loaded_modules -p no:cacheprovider $SGT -k stride|collect --collect-only -q -p fla_loaded_modules -p no:cacheprovider $KT::$KC[k64-v32] $KT::$KC[k64-v64] $KT::$KC[k64-v32-hv2] $KT::$KC[v-bf16] -k not k32-v64|collect --collect-only -q -p fla_loaded_modules -p no:cacheprovider $KT' ]"
check "the probe lists what the collection loaded, with each file's sha256, and none of it differs from the diff base" \
  "( for d in stride-before stride-after kda-before kda-after; do grep -qx 'probe_rc=0' '$WORK/out-good/'\$d/state.txt && grep -qx 'loaded_differs=none' '$WORK/out-good/'\$d/state.txt || exit 1; done ) && grep -qE '^[0-9a-f]{64}  $TU  $WORK/site/$TU\$' '$WORK/out-good/stride-before/loaded-modules.txt' && grep -qE '^[0-9a-f]{64}  $SGT  $WORK/w/$SGT\$' '$WORK/out-good/stride-before/loaded-modules.txt'"
check "#68415 BEFORE selects its four safe cases, by node id and by -k, and the unfixed k32-v64 case never ran" \
  "[ \"\$(grep '^kda-selected' '$WORK/calls' | paste -sd'|')\" = 'kda-selected k64-v32,k64-v64,k64-v32-hv2,v-bf16 fixed=False|kda-selected k64-v32,k64-v64,k32-v64,k64-v32-hv2,v-bf16 fixed=True' ] && ! grep -q 'RAN UNFIXED' '$WORK/calls' && grep -qx 'before_selection_guard=yes' '$KB' && ! grep -q k32-v64 '$WORK/out-good/kda-before/test.xml'"
# The command line itself, read from the script: no k32-v64 on BEFORE's line but the -k that excludes it, and the four safe ids named.
kb=$(grep -E '^ *before\) DIFF=' "$KST")
check "kda-state.sh's BEFORE line names the four safe cases by node id and excludes k32-v64 by -k" \
  "[ \"\$(grep -cE '^ *before\\) DIFF=' '$KST')\" = 1 ] && [ \"\$(grep -o 'k32-v64' <<<\"\$kb\" | wc -l)\" = 1 ] && [[ \"\$kb\" == *'SELECT=(\"\$TEST::\$CASE[k64-v32]\" \"\$TEST::\$CASE[k64-v64]\" \"\$TEST::\$CASE[k64-v32-hv2]\" \"\$TEST::\$CASE[v-bf16]\" -k \"not k32-v64\")'* ]] && grep -qx 'TEST=$KT' '$KST'"
check "#68416 BEFORE applies the test diff alone and its three cases fail; AFTER passes them and the whole file" \
  "[ \"\$(grep '^stride-selected' '$WORK/calls' | paste -sd'|')\" = 'stride-selected recurrent,sigmoid_gating,kda|stride-selected recurrent,sigmoid_gating,kda|stride-selected recurrent,sigmoid_gating,kda' ] && grep -qx 'test_summary========================== 3 failed in 1.23s =========================' '$WORK/out-good/stride-before/state.txt' && grep -qx 'test_summary========================== 3 passed in 1.23s =========================' '$WORK/out-good/stride-after/state.txt' && grep -qx 'file_summary========================== 21 passed in 1.23s =========================' '$WORK/out-good/stride-after/state.txt'"
check "#68416's import checks: the token-stride term in both imported kernels, none BEFORE and two each AFTER, kda.py unfixed, and kda.py's kernel from fused_recurrent.py" \
  "[ \"\$(grep -h '^fused_[a-z_]*_fix_count=' '$WORK/out-good/stride-before/state.txt' '$WORK/out-good/stride-after/state.txt' | paste -sd' ')\" = 'fused_recurrent_fix_count=0 fused_sigmoid_gating_fix_count=0 fused_recurrent_fix_count=2 fused_sigmoid_gating_fix_count=2' ] && grep -qx 'kda_kernel_file=$WORK/site/$FR' '$WORK/out-good/stride-after/state.txt' && grep -qx 'kda_fix_grep_rc=1' '$WORK/out-good/stride-after/state.txt' && grep -qx 'test_file=$WORK/w/$SGT' '$WORK/out-good/stride-before/state.txt'"
check "#68415's import checks: kda.py with the bug line BEFORE and the fix AFTER, its kernel without #68416's term, and the test from the checkout" \
  "grep -qx 'kda_file=$WORK/site/$KDA' '$KB' && grep -qx 'fix_grep_rc=1' '$KB' && grep -qx 'bug_grep_rc=0' '$KB' && grep -qx 'fix_grep_rc=0' '$WORK/out-good/kda-after/state.txt' && grep -qx 'bug_grep_rc=1' '$WORK/out-good/kda-after/state.txt' && grep -qx 'kernel_file=$WORK/site/$FR' '$KB' && grep -qx 'kernel_stride_fix_count=0' '$WORK/out-good/kda-after/state.txt' && grep -qx 'test_file=$WORK/w/$KT' '$KB'"
check "every pytest call records its exact command, its exit and pytest's summary line" \
  "grep -qxF \"test_cmd=cd $WORK/w && timeout --kill-after=10 90 python3 -m pytest '$KT::$KC[k64-v32]' '$KT::$KC[k64-v64]' '$KT::$KC[k64-v32-hv2]' '$KT::$KC[v-bf16]' -k 'not k32-v64' -rA --tb=short -p no:cacheprovider --junitxml=$WORK/out/kda-before/test.xml\" '$KB' && grep -qxF \"file_cmd=cd $WORK/w && timeout --kill-after=10 300 python3 -m pytest $SGT -rA --tb=short -p no:cacheprovider --junitxml=$WORK/out/stride-after/file.xml\" '$WORK/out-good/stride-after/state.txt' && grep -qx 'test_rc=1' '$KB'"
check "the fake run confirms both items, and the BEFORE junit is shown without k32-v64" "[ \"\$(verdicts good)\" = '$ALL_OK' ] && kvd_ good | grep -qx 'kda_before_junit_k32-v64=absent'"
check "the real verdicts refuse the fake run on the import check alone, since its files are not the image's paths" \
  "{ python3 '$KV' '$WORK/out-good' \$(isha kda-test.diff) \$(isha kda-fix.diff); python3 '$SV' '$WORK/out-good' \$(isha stride-test.diff) \$(isha stride-fix.diff); true; } | grep -c '^[a-z]*_verdict=void-import-check\$' | grep -qx 2"

# The pytest summary the PRs quote, from the fake run.
python3 "$PS" "$WORK/out-good" "$(isha kda-test.diff)" "$(isha kda-fix.diff)" "$(isha stride-test.diff)" "$(isha stride-fix.diff)" > "$WORK/ps-good.txt"
check "pytest-summary.txt opens with the image digest and revision, and names all five calls with command, GPU, python, diff, apply commands, exit, summary and cases" \
  "grep -qxF '   image:  [\"public.ecr.aws/q9t5s3a7/vllm-ci-postmerge-repo@$DIGEST\"] $IMAGE_COMMIT' '$WORK/ps-good.txt' && [ \"\$(grep -c '^== #684' '$WORK/ps-good.txt')\" = 5 ] && [ \"\$(grep -c '^   command: cd ' '$WORK/ps-good.txt')\" = 5 ] && [ \"\$(grep -c '(the pinned one)\$' '$WORK/ps-good.txt')\" = 5 ] && [ \"\$(grep -cx '   gpu:     NVIDIA A10G' '$WORK/ps-good.txt')\" = 5 ] && [ \"\$(grep -c '^   python:  $REAL_PY 3\\.' '$WORK/ps-good.txt')\" = 5 ] && [ \"\$(grep -c '^   applied: cd ' '$WORK/ps-good.txt')\" = 8 ] && grep -qx '   cases:   21 in junit' '$WORK/ps-good.txt'"
# assertion_block CASE LINE...: the lines printed under CASE's outcome line, until the next case.
assertion_block() { awk -v c="     failed   $1" '$0 == c {on = 1; next} on && /^     [a-z]/ {exit} on && /^$/ {exit} on {print}' "$WORK/ps-good.txt"; }
check "pytest-summary.txt prints each failed case's statement and E lines under it, per case" \
  "[ \"\$(assertion_block '$KC[k64-v32]' | sed 's/^ *//' | paste -sd'|')\" = '> assert out.shape == v.shape|E   assert torch.Size([1, 4, 1, 64]) == torch.Size([1, 4, 1, 32])|E     At index 3 diff: 64 != 32|E     Use -v to get more diff' ] && assertion_block '$KC[k64-v32-hv2]' | grep -qF 'E   assert torch.Size([1, 4, 1, 64]) == torch.Size([1, 4, 2, 32])' && ( for k in recurrent sigmoid_gating kda; do assertion_block \"$SC[\$k]\" | grep -qxF '              E   AssertionError: Tensor-likes are not equal!' && assertion_block \"$SC[\$k]\" | grep -q 'E   Mismatched elements: ' || exit 1; done )"
check "pytest-summary.txt prints no assertion lines under a passed case" "[ -z \"\$(awk '/^     passed   / {getline; print}' '$WORK/ps-good.txt' | grep '^              ')\" ]"
python3 "$PS" "$WORK/out-good" "$(isha kda-test.diff)" 0000 "$(isha stride-test.diff)" "$(isha stride-fix.diff)" > "$WORK/ps-other.txt"
check "pytest-summary.txt says when a state applied a diff other than the pinned one" "grep -q 'kda-fix.diff sha256 .* (NOT the pinned 0000)' '$WORK/ps-other.txt'"
cp -r "$WORK/out-good" "$WORK/out-noe"; sed -i 's/E   [^&<]*//g' "$WORK/out-noe/kda-before/test.xml"
python3 "$PS" "$WORK/out-noe" "$(isha kda-test.diff)" "$(isha kda-fix.diff)" "$(isha stride-test.diff)" "$(isha stride-fix.diff)" > "$WORK/ps-noe.txt"
check "pytest-summary.txt says so when a failed case's junit holds no E line" "[ \"\$(grep -c 'no E line in the junit for this case' '$WORK/ps-noe.txt')\" = 2 ]"

# Isolation: a container that kept the last state's edits carries #68416's test into its own AFTER and into #68415's BEFORE.
runfake stale env FAKE_STALE=1
check "a container that kept another state's edits is refused before anything is applied, in this item and the other" \
  "grep -qx 'base_identity=bad' '$WORK/out-stale/kda-before/state.txt' && ! grep -q '^apply' '$WORK/out-stale/kda-before/state.txt' && [ ! -s '$WORK/out-stale/kda-before/apply.log' ] && grep -q '$SGT is .*, not the pinned base' '$WORK/out-stale/kda-before/steps.log' && ! grep -q '^test_cmd=' '$WORK/out-stale/kda-before/state.txt' && grep -qx 'base_identity=bad' '$WORK/out-stale/stride-after/state.txt' && [ \"\$(verdicts stale)\" = 'stride=void-identity kda=void-identity' ] && grep -q 'all items done' '$WORK/out-stale/steps.log' && [ \"\$(cat '$WORK/rc-stale')\" = 3 ]"
runfake leak env FAKE_LEAK_KDA=1
check "#68415's fix leaking into #68416's containers is refused at their base pins, and #68415 stays confirmed" \
  "grep -qx 'base_identity=bad' '$WORK/out-leak/stride-before/state.txt' && ! grep -q '^apply' '$WORK/out-leak/stride-before/state.txt' && grep -q '$KDA is .*, not the pinned base' '$WORK/out-leak/stride-before/steps.log' && ! grep -q '^test_cmd=' '$WORK/out-leak/stride-before/state.txt' && [ \"\$(verdicts leak)\" = 'stride=void-identity kda=confirmed' ]"
runfake stridecrash env FAKE_STRIDE_CRASH=1
check "#68416 crashing does not stop #68415, and the other verdict does not change" \
  "grep -qx 'test_rc=139' '$WORK/out-stridecrash/stride-before/state.txt' && [ \"\$(verdicts stridecrash)\" = 'stride=before-did-not-reproduce kda=confirmed' ] && grep -q 'state kda-after: exited 0' '$WORK/out-stridecrash/steps.log'"
runfake filefail env FAKE_FILE_FAIL=1
check "#68416 AFTER whose whole file has a failure is named, and #68415 stays confirmed" \
  "svd_ filefail | grep -q '^stride_after_file=not-passed(rc=1,cases=21,.*not-passed=test_fused_sigmoid_gating_delta_rule_update_non_spec' && [ \"\$(verdicts filefail)\" = 'stride=after-file-not-passed kda=confirmed' ]"
runfake kdaafter env FAKE_KDA_AFTER_FAIL=1
check "a #68415 AFTER with one case failed is named, and #68416 stays confirmed" \
  "kvd_ kdaafter | grep -q '^kda_after_test=not-passed(rc=1,cases=5,' && [ \"\$(verdicts kdaafter)\" = 'stride=confirmed kda=after-not-passed' ]"
runfake kdawrong env FAKE_KDA_WRONG_FAIL=1
check "a #68415 BEFORE whose two cases failed on something other than the shape assert is named, not confirmed" \
  "kvd_ kdawrong | grep -qx 'kda_before_test=other-failure(k64-v32:failure-not-the-shape-assert,k64-v32-hv2:failure-not-the-shape-assert)' && [ \"\$(verdicts kdawrong)\" = 'stride=confirmed kda=before-failed-otherwise' ]"
runfake again env
check "a second run with no fault set stays confirmed, so the fakes fail only where told" "[ \"\$(verdicts again)\" = '$ALL_OK' ]"
runfake probefail env FAKE_PROBE_FAIL=1
check "a collection probe that failed voids both items' import checks, since what the tests loaded is then unshown" \
  "grep -qx 'probe_rc=2' '$WORK/out-probefail/kda-after/state.txt' && [ \"\$(verdicts probefail)\" = 'stride=void-import-check kda=void-import-check' ] && kvd_ probefail | grep -q '^kda_import_check=probe-before(rc=2,'"
cp "$WORK/in/stride-differs.txt" "$WORK/stride-differs.keep"; echo "$TU" >> "$WORK/in/stride-differs.txt"
runfake loadsdiffers env
check "a test process that loaded a file differing from the diff base voids its item, by name" \
  "grep -qx 'loaded_differs=$TU' '$WORK/out-loadsdiffers/stride-before/state.txt' && svd_ loadsdiffers | grep -qx 'stride_import_check=loaded-differs-before($TU)' && [ \"\$(verdicts loadsdiffers)\" = 'stride=void-import-check kda=confirmed' ]"
cp "$WORK/stride-differs.keep" "$WORK/in/stride-differs.txt"
# A BEFORE that selected the whole file: the guard refuses it before pytest, and the verdict names the selection.
cp "$WORK/in/kda-state.sh" "$WORK/kda-state.keep"
sed -i 's|^  before) DIFF=\(.*\); SELECT=.*|  before) DIFF=\1; SELECT=("$TEST") ;;|' "$WORK/in/kda-state.sh"
runfake kdawide env
check "a #68415 BEFORE that could select k32-v64 is refused by its guard before pytest, and voided by the verdict" \
  "grep -qx 'before_selection_guard=no' '$WORK/out-kdawide/kda-before/state.txt' && ! grep -q 'RAN UNFIXED\\|kda-selected .*k32-v64.* fixed=False' '$WORK/out-kdawide/calls' && ! grep -q '^test_cmd=' '$WORK/out-kdawide/kda-before/state.txt' && [ \"\$(verdicts kdawide)\" = 'stride=confirmed kda=void-before-selection' ]"
# Without the guard, the same selection reaches the unfixed k32-v64, which the fake shows and the verdict voids.
sed -i 's|^  \[ "\$sel_ok" = yes \] .*|  :|' "$WORK/in/kda-state.sh"
runfake kdaunguarded env
check "a #68415 BEFORE whose guard is gone runs k32-v64 unfixed, and the verdict voids it by its command line" \
  "grep -q 'KDA k32-v64 RAN UNFIXED' '$WORK/out-kdaunguarded/calls' && kvd_ kdaunguarded | grep -qx 'kda_verdict=void-before-selection'"
cp "$WORK/kda-state.keep" "$WORK/in/kda-state.sh"
# A #68416 BEFORE that applies the whole fix: its pins refuse the tree.
sed -i 's|^  before) DIFF=\$IN/stride-test.diff ;;|  before) DIFF=$IN/stride-fix.diff ;;|' "$WORK/in/stride-state.sh"
runfake stridefix env
check "a #68416 BEFORE that applies the fix is refused by its pins before pytest, and voided" \
  "grep -qx 'applied_identity=bad' '$WORK/out-stridefix/stride-before/state.txt' && ! grep -q '^test_cmd=' '$WORK/out-stridefix/stride-before/state.txt' && svd_ stridefix | grep -qx 'stride_verdict=void-identity' && [ \"\$(verdicts stridefix | cut -d' ' -f2)\" = 'kda=confirmed' ]"
cp "$SST" "$WORK/in/stride-state.sh"
runfake badrev env FAKE_REVISION=$OLD_IMAGE_COMMIT
check "an image whose label is 8700cc9ba0, run 2's, is refused before any state runs" \
  "grep -q 'IMAGE IDENTITY FAILED' '$WORK/out-badrev/steps.log' && ! grep -q 'fla-' '$WORK/out-badrev/calls'"
runfake psfail env FAKE_PS_FAIL=1
check "a container whose removal cannot be shown stops the run" \
  "grep -q 'state stride-before: container was not shown removed' '$WORK/out-psfail/steps.log' && ! grep -q 'fla-kda' '$WORK/out-psfail/calls'"
# The #68416 fix already in the image: the base pins say so first, in both items.
cp -r "$P" "$WORK/pristine.keep"
sed -i 's/+ i_t)$/+ i_t * stride_indices_tok)/' "$P/site/$FR"
runfake fixedimage env
check "an image that already holds a fix is refused at its base pins, in every state, since both items pin all eight files" \
  "[ \"\$(grep -l '^base_identity=bad' '$WORK'/out-fixedimage/*/state.txt | wc -l)\" = 4 ] && [ \"\$(verdicts fixedimage)\" = 'stride=void-identity kda=void-identity' ]"
rm -rf "$P"; mv "$WORK/pristine.keep" "$P"
# torch_utils.py as 8700cc9ba0's, an image other than the one the pins were made for.
cp -r "$P" "$WORK/pristine.keep"; echo "# 8700cc9ba0" >> "$P/site/$TU"
runfake oldtorchutils env
check "an image whose torch_utils.py is not the pinned one is refused at the base pins in every state" \
  "[ \"\$(grep -l '^base_identity=bad' '$WORK'/out-oldtorchutils/*/state.txt | wc -l)\" = 4 ] && grep -q '$TU is .*, not the pinned base' '$WORK/out-oldtorchutils/kda-before/steps.log'"
rm -rf "$P"; mv "$WORK/pristine.keep" "$P"
# A pins file that names fewer files, or none, or is missing, must not pass as an identity check that checked nothing.
cp "$WORK/in/stride-pins.txt" "$WORK/stride-pins.keep"; : > "$WORK/in/stride-pins.txt"
runfake emptypins env
check "an empty pins file refuses its item's states, and the other item stays confirmed" \
  "grep -qx 'base_identity=bad' '$WORK/out-emptypins/stride-before/state.txt' && grep -q 'names 0 file(s) for base, not 8' '$WORK/out-emptypins/stride-before/steps.log' && [ \"\$(verdicts emptypins)\" = 'stride=void-identity kda=confirmed' ]"
grep -v "$TU\$" "$WORK/stride-pins.keep" > "$WORK/in/stride-pins.txt"
runfake shortpins env
check "a pins file missing one of the eight files is refused" "grep -q 'names 7 file(s) for base, not 8' '$WORK/out-shortpins/stride-before/steps.log' && svd_ shortpins | grep -qx 'stride_verdict=void-identity'"
rm "$WORK/in/stride-pins.txt"
runfake nopins env
check "a missing pins file is refused" "grep -qx 'base_identity=bad' '$WORK/out-nopins/stride-before/state.txt' && svd_ nopins | grep -qx 'stride_verdict=void-identity'"
cp "$WORK/stride-pins.keep" "$WORK/in/stride-pins.txt"

# ---------------------------------------------------------------- the verdicts, case by case
OX=/usr/local/lib/python3.12/dist-packages/$OPS
WX=/vllm-workspace
# jx OUT NAME OUTCOME TEXT ...: one junit file; OUTCOME is passed, failure or error, and TEXT holds what --tb=short would write.
cat > "$WORK/jx.py" <<'EOF'
import sys
from xml.sax.saxutils import escape, quoteattr
a = sys.argv[2:]
body = ""
for n, o, t in zip(a[0::3], a[1::3], a[2::3]):
    inner = "" if o == "passed" else "<%s message=%s>%s</%s>" % (o, quoteattr(t.split("\n")[-1]), escape(t), o)
    body += "<testcase classname=\"t\" name=%s>%s</testcase>" % (quoteattr(n), inner)
open(sys.argv[1], "w").write("<testsuites><testsuite>%s</testsuite></testsuites>" % body)
EOF
jx() { python3 "$WORK/jx.py" "$@"; }
KH="$KT:63: in $KC"$'\n'"    assert out.shape == v.shape"$'\n'
K32="${KH}E   assert torch.Size([1, 4, 1, 64]) == torch.Size([1, 4, 1, 32])"$'\nE     \nE     At index 3 diff: 64 != 32'
KHV="${KH}E   assert torch.Size([1, 4, 1, 64]) == torch.Size([1, 4, 2, 32])"$'\nE     \nE     At index 2 diff: 1 != 2'
STX="$SGT:266: in $SC"$'\n    torch.testing.assert_close(results[0][0], results[1][0], rtol=0, atol=0)\nE   AssertionError: Tensor-likes are not equal!\nE   \nE   Mismatched elements: 3 / 768 (0.4%)'
file_cases() { local o=$1 d r s; for r in 1 2 4; do for d in float32 bfloat16; do printf '%s\n' "test_fused_sigmoid_gating_delta_rule_update_non_spec[$d-$r]" "$o" ""; for s in 1 3; do printf '%s\n' "test_fused_sigmoid_gating_delta_rule_update_spec[$d-$s-$r]" "$o" ""; done; done; done; for k in recurrent sigmoid_gating kda; do printf '%s\n' "$SC[$k]" passed ""; done; }
imports_ok() { # imports_ok STATE COUNT KDAFIX KDABUG: one state's import records, as the state scripts write them
  printf 'fused_recurrent_file=%s/fused_recurrent.py\nfused_sigmoid_gating_file=%s/fused_sigmoid_gating.py\nkda_file=%s/kda.py\nkda_kernel_file=%s/fused_recurrent.py\ntest_file=%s/%s\nfused_recurrent_fix_count=%s\nfused_sigmoid_gating_fix_count=%s\nkda_fix_grep_rc=1\nkda_bug_grep_rc=0\nprobe_rc=0\nloaded_count=230\nloaded_differs=none\n' "$OX" "$OX" "$OX" "$OX" "$WX" "$SGT" "$2" "$2"
}
case_dir() { # case_dir NAME: a sweep where both items are confirmed, which each case then mutates
  local d="$WORK/vc/$1"; rm -rf "$d"; mkdir -p "$d/stride-before" "$d/stride-after" "$d/kda-before" "$d/kda-after"
  { printf 'started=400\ndiff_sha256=STEST\nbase_identity=ok\napply=ok\napplied_identity=ok\npytest_args=%s -k stride\ntest_rc=1\nended=500\n' "$SGT"; imports_ok before 0; } > "$d/stride-before/state.txt"
  jx "$d/stride-before/test.xml" "$SC[recurrent]" failure "$STX" "$SC[sigmoid_gating]" failure "$STX" "$SC[kda]" failure "$STX"
  { printf 'started=600\ndiff_sha256=SFIX\nbase_identity=ok\napply=ok\napplied_identity=ok\npytest_args=%s -k stride\ntest_rc=0\nfile_args=%s\nfile_rc=0\nended=700\n' "$SGT" "$SGT"; imports_ok after 2; } > "$d/stride-after/state.txt"
  jx "$d/stride-after/test.xml" "$SC[recurrent]" passed "" "$SC[sigmoid_gating]" passed "" "$SC[kda]" passed ""
  mapfile -t fc < <(file_cases passed); jx "$d/stride-after/file.xml" "${fc[@]}"
  local ka="$KT::$KC[k64-v32] $KT::$KC[k64-v64] $KT::$KC[k64-v32-hv2] $KT::$KC[v-bf16] -k not k32-v64"
  printf 'started=1000\nbefore_selection_guard=yes\ndiff_sha256=KTEST\nbase_identity=ok\napply=ok\napplied_identity=ok\nkda_file=%s/kda.py\nkernel_file=%s/fused_recurrent.py\ntest_file=%s/%s\nfix_grep_rc=1\nbug_grep_rc=0\nkernel_stride_fix_count=0\nprobe_rc=0\nloaded_count=230\nloaded_differs=none\npytest_args=%s\ntest_rc=1\nended=1100\n' "$OX" "$OX" "$WX" "$KT" "$ka" > "$d/kda-before/state.txt"
  jx "$d/kda-before/test.xml" "$KC[k64-v32]" failure "$K32" "$KC[k64-v64]" passed "" "$KC[k64-v32-hv2]" failure "$KHV" "$KC[v-bf16]" passed ""
  printf 'started=1200\ndiff_sha256=KFIX\nbase_identity=ok\napply=ok\napplied_identity=ok\nkda_file=%s/kda.py\nkernel_file=%s/fused_recurrent.py\ntest_file=%s/%s\nfix_grep_rc=0\nbug_grep_rc=1\nkernel_stride_fix_count=0\nprobe_rc=0\nloaded_count=230\nloaded_differs=none\npytest_args=%s\ntest_rc=0\nended=1300\n' "$OX" "$OX" "$WX" "$KT" "$KT" > "$d/kda-after/state.txt"
  jx "$d/kda-after/test.xml" "$KC[k64-v32]" passed "" "$KC[k64-v64]" passed "" "$KC[k32-v64]" passed "" "$KC[k64-v32-hv2]" passed "" "$KC[v-bf16]" passed ""
  echo "[\"public.ecr.aws/q9t5s3a7/vllm-ci-postmerge-repo@$DIGEST\"] $IMAGE_COMMIT" > "$d/image-identity.txt"
  echo "abc123  vllm.whl" > "$d/wheel-sha256.txt"
  # Each pytest call's command and the provenance the summary quotes, as lib.sh records them.
  local x args
  for x in stride-before stride-after kda-before kda-after; do
    args=$(sed -n 's/^pytest_args=//p' "$d/$x/state.txt" | sed "s|\(tests/[^ ]*\[[^ ]*\]\)|'\1'|g; s|-k not k32-v64|-k 'not k32-v64'|")
    printf 'test_cmd=cd /vllm-workspace && timeout --kill-after=10 90 python3 -m pytest %s -rA --tb=short -p no:cacheprovider --junitxml=/out/%s/test.xml\ngpu_name=NVIDIA A10G\npython_executable=/usr/bin/python3\npython_version=3.12.3\napply_checkout_cmd=cd /vllm-workspace && git apply x\n' "$args" "$x" >> "$d/$x/state.txt"
  done
  echo "file_cmd=cd /vllm-workspace && timeout --kill-after=10 300 python3 -m pytest $SGT -rA --tb=short -p no:cacheprovider --junitxml=/out/stride-after/file.xml" >> "$d/stride-after/state.txt"
  echo "$d"
}
v2() { echo "stride=$(python3 "$SV" "$1" STEST SFIX | sed -n 's/^stride_verdict=//p') kda=$(python3 "$KV" "$1" KTEST KFIX | sed -n 's/^kda_verdict=//p')"; }
vrc() { case $1 in stride) python3 "$SV" "$2" STEST SFIX ;; kda) python3 "$KV" "$2" KTEST KFIX ;; esac > /dev/null; }
d=$(case_dir good)
check "the case sweep confirms both items, each verdict exiting 0, with each import check first" \
  "[ \"\$(v2 '$d')\" = '$ALL_OK' ] && vrc stride '$d' && vrc kda '$d' && [ \"\$(python3 '$SV' '$d' STEST SFIX | head -1)\" = 'stride_import_check=ok' ] && [ \"\$(python3 '$KV' '$d' KTEST KFIX | head -1)\" = 'kda_import_check=ok' ]"
# named ITEM VERDICT DESCRIPTION EDIT: a confirmed sweep with EDIT applied gives ITEM that VERDICT, exits non-zero for it, and leaves the other confirmed.
named() {
  local d want; d=$(case_dir "x$RANDOM$RANDOM"); (cd "$d" && eval "$4")
  want=$(sed "s/$1=confirmed/$1=$2/" <<<"$ALL_OK")
  check "#$(case $1 in stride) echo 68416 ;; kda) echo 68415 ;; esac): $3 -> $2" "[ \"\$(v2 '$d')\" = '$want' ] && ! vrc $1 '$d'"
}
named stride before-did-not-reproduce "BEFORE passed all three cases" "jx stride-before/test.xml '$SC[recurrent]' passed '' '$SC[sigmoid_gating]' passed '' '$SC[kda]' passed ''; sed -i 's/^test_rc=1/test_rc=0/' stride-before/state.txt"
named stride before-did-not-reproduce "BEFORE failed only two cases" "jx stride-before/test.xml '$SC[recurrent]' failure \"\$STX\" '$SC[sigmoid_gating]' failure \"\$STX\" '$SC[kda]' passed ''"
named stride before-failed-otherwise "BEFORE failed on something other than unequal tensors" "jx stride-before/test.xml '$SC[recurrent]' failure 'E   RuntimeError: CUDA error' '$SC[sigmoid_gating]' failure \"\$STX\" '$SC[kda]' failure \"\$STX\""
named stride before-failed-otherwise "BEFORE's failures lack assert_close's mismatch count" "sed -i 's/E   Mismatched elements: [^&<\"]*//g' stride-before/test.xml"
named stride before-did-not-reproduce "BEFORE errored rather than failed" "jx stride-before/test.xml '$SC[recurrent]' error \"\$STX\" '$SC[sigmoid_gating]' error \"\$STX\" '$SC[kda]' error \"\$STX\""
named stride before-did-not-reproduce "BEFORE crashed with no junit" "rm stride-before/test.xml; sed -i 's/^test_rc=1/test_rc=139/' stride-before/state.txt"
named stride void-before-selection "BEFORE ran two cases, the kda case missing" "jx stride-before/test.xml '$SC[recurrent]' failure \"\$STX\" '$SC[sigmoid_gating]' failure \"\$STX\""
named stride void-before-selection "BEFORE ran the whole file" "sed -i 's|^pytest_args=.*|pytest_args=$SGT|' stride-before/state.txt"
named stride after-not-passed "AFTER passed two cases of three" "jx stride-after/test.xml '$SC[recurrent]' passed '' '$SC[sigmoid_gating]' passed '' '$SC[kda]' failure \"\$STX\"; sed -i 's/^test_rc=0/test_rc=1/' stride-after/state.txt"
named stride after-not-passed "AFTER's three cases are one name repeated" "jx stride-after/test.xml '$SC[recurrent]' passed '' '$SC[recurrent]' passed '' '$SC[recurrent]' passed ''"
named stride after-not-passed "AFTER exited 1 with three passes recorded" "sed -i 's/^test_rc=0/test_rc=1/' stride-after/state.txt"
named stride after-file-not-passed "AFTER's whole file had one failure" "mapfile -t fc < <(file_cases passed); fc[1]=failure; jx stride-after/file.xml \"\${fc[@]}\"; sed -i 's/^file_rc=0/file_rc=1/' stride-after/state.txt"
named stride after-file-not-passed "AFTER's whole file ran 20 cases" "mapfile -t fc < <(file_cases passed); jx stride-after/file.xml \"\${fc[@]:3}\""
named stride after-file-not-passed "AFTER's whole file had a skip" "mapfile -t fc < <(file_cases passed); fc[1]=skipped; jx stride-after/file.xml \"\${fc[@]}\""
named stride after-file-not-passed "AFTER's whole file never ran" "rm stride-after/file.xml; sed -i '/^file_/d' stride-after/state.txt"
named stride void-identity "BEFORE applied the whole fix" "sed -i 's/^diff_sha256=STEST/diff_sha256=SFIX/' stride-before/state.txt"
named stride void-identity "BEFORE's tree was not its pinned one, as another item's fix would make it" "sed -i 's/^base_identity=ok/base_identity=bad/' stride-before/state.txt"
named stride void-identity "AFTER started before BEFORE ended" "sed -i 's/^started=600/started=450/' stride-after/state.txt"
named stride void-identity "#68416 never ran" "rm -r stride-before stride-after"
named stride void-import-check "BEFORE's fused_recurrent.py already stepped by the token stride" "sed -i 's/^fused_recurrent_fix_count=0/fused_recurrent_fix_count=2/' stride-before/state.txt"
named stride void-import-check "AFTER's fused_sigmoid_gating.py stepped by it in one load only" "sed -i 's/^fused_sigmoid_gating_fix_count=2/fused_sigmoid_gating_fix_count=1/' stride-after/state.txt"
named stride void-import-check "AFTER imported fused_recurrent.py from the checkout" "sed -i 's|^fused_recurrent_file=.*|fused_recurrent_file=/vllm-workspace/vllm/x.py|' stride-after/state.txt"
named stride void-import-check "BEFORE's kda.py held #68415's fix" "sed -i 's/^kda_fix_grep_rc=1/kda_fix_grep_rc=0/' stride-before/state.txt"
named stride void-import-check "kda.py launched a kernel from another file" "sed -i 's|^kda_kernel_file=.*|kda_kernel_file=/tmp/k.py|' stride-after/state.txt"
named stride void-import-check "the test came from somewhere other than the checkout" "sed -i 's|^test_file=.*|test_file=/tmp/t.py|' stride-before/state.txt"
named stride void-import-check "the collection loaded a file that differs from 545ef08189" "sed -i 's|^loaded_differs=none|loaded_differs=vllm/v1/engine/detokenizer.py|' stride-after/state.txt"
named stride void-import-check "the collection probe failed" "sed -i 's/^probe_rc=0/probe_rc=2/' stride-before/state.txt"
named kda after-not-passed "AFTER passed four cases" "jx kda-after/test.xml '$KC[k64-v32]' passed '' '$KC[k64-v64]' passed '' '$KC[k64-v32-hv2]' passed '' '$KC[v-bf16]' passed ''"
named kda after-not-passed "AFTER's five cases are one name repeated" "jx kda-after/test.xml '$KC[k64-v32]' passed '' '$KC[k64-v32]' passed '' '$KC[k64-v32]' passed '' '$KC[k64-v32]' passed '' '$KC[k64-v32]' passed ''"
named kda after-not-passed "AFTER exited 1 with five passes recorded" "sed -i 's/^test_rc=0/test_rc=1/' kda-after/state.txt"
named kda after-not-passed "AFTER's junit is missing" "rm kda-after/test.xml"
named kda void-before-selection "BEFORE's junit holds k32-v64" "jx kda-before/test.xml '$KC[k64-v32]' failure \"\$K32\" '$KC[k64-v64]' passed '' '$KC[k32-v64]' passed '' '$KC[k64-v32-hv2]' failure \"\$KHV\""
named kda void-before-selection "BEFORE's junit holds k32-v64 as a fifth case" "jx kda-before/test.xml '$KC[k64-v32]' failure \"\$K32\" '$KC[k64-v64]' passed '' '$KC[k32-v64]' passed '' '$KC[k64-v32-hv2]' failure \"\$KHV\" '$KC[v-bf16]' passed ''"
named kda void-before-selection "BEFORE's command line was the whole file" "sed -i 's|^pytest_args=.*|pytest_args=$KT|' kda-before/state.txt"
named kda void-before-selection "BEFORE's command line had no -k" "sed -i 's| -k not k32-v64\$||' kda-before/state.txt"
named kda void-before-selection "BEFORE's guard refused its selection" "sed -i 's/^before_selection_guard=yes/before_selection_guard=no/; /^test_rc=/d; /^pytest_args=/d' kda-before/state.txt; rm kda-before/test.xml"
named kda void-before-selection "BEFORE crashed with no junit after a widened selection" "rm kda-before/test.xml; sed -i 's/^pytest_args=.*/pytest_args=x -k k32-v64/; s/^test_rc=1/test_rc=139/' kda-before/state.txt"
named kda void-before-selection "BEFORE ran three cases" "jx kda-before/test.xml '$KC[k64-v32]' failure \"\$K32\" '$KC[k64-v64]' passed '' '$KC[k64-v32-hv2]' failure \"\$KHV\""
named kda before-did-not-reproduce "BEFORE's k64-v32 case passed" "jx kda-before/test.xml '$KC[k64-v32]' passed '' '$KC[k64-v64]' passed '' '$KC[k64-v32-hv2]' failure \"\$KHV\" '$KC[v-bf16]' passed ''"
named kda before-did-not-reproduce "BEFORE's v-bf16 case failed too" "jx kda-before/test.xml '$KC[k64-v32]' failure \"\$K32\" '$KC[k64-v64]' passed '' '$KC[k64-v32-hv2]' failure \"\$KHV\" '$KC[v-bf16]' failure \"\$K32\""
named kda before-failed-otherwise "BEFORE failed on the dtype assert, not the shape" "sed -i 's/out.shape == v.shape/out.dtype == k.dtype/' kda-before/test.xml"
named kda before-failed-otherwise "BEFORE's hv2 case failed with k64-v32's sizes" "jx kda-before/test.xml '$KC[k64-v32]' failure \"\$K32\" '$KC[k64-v64]' passed '' '$KC[k64-v32-hv2]' failure \"\$K32\" '$KC[v-bf16]' passed ''"
named kda before-did-not-reproduce "BEFORE's shape failure was an error, not a failure" "jx kda-before/test.xml '$KC[k64-v32]' error \"\$K32\" '$KC[k64-v64]' passed '' '$KC[k64-v32-hv2]' failure \"\$KHV\" '$KC[v-bf16]' passed ''"
named kda before-did-not-reproduce "BEFORE timed out" "rm kda-before/test.xml; sed -i 's/^test_rc=1/test_rc=124/' kda-before/state.txt"
named kda void-import-check "BEFORE imported kda.py from elsewhere" "sed -i 's|^kda_file=.*|kda_file=/vllm-workspace/vllm/kda.py|' kda-before/state.txt"
named kda void-import-check "the fix line was in kda.py BEFORE" "sed -i 's/^fix_grep_rc=1/fix_grep_rc=0/' kda-before/state.txt"
named kda void-import-check "the bug line was still in kda.py AFTER" "sed -i 's/^bug_grep_rc=1/bug_grep_rc=0/' kda-after/state.txt"
named kda void-import-check "#68416's fix was in the kernel kda.py launched BEFORE" "sed -i 's/^kernel_stride_fix_count=0/kernel_stride_fix_count=2/' kda-before/state.txt"
named kda void-import-check "the collection loaded a file that differs from the base" "sed -i 's|^loaded_differs=none|loaded_differs=vllm/utils/torch_utils.py|' kda-before/state.txt"
named kda void-import-check "the collection loaded nothing" "sed -i 's/^loaded_count=230/loaded_count=0/' kda-after/state.txt"
named kda void-identity "BEFORE applied the whole fix" "sed -i 's/^diff_sha256=KTEST/diff_sha256=KFIX/' kda-before/state.txt"
named kda void-identity "AFTER applied the test alone" "sed -i 's/^diff_sha256=KFIX/diff_sha256=KTEST/' kda-after/state.txt"
named kda void-identity "the #68415 container was not the commit's" "sed -i 's/^base_identity=ok/base_identity=bad/' kda-before/state.txt"
named kda void-identity "#68415 AFTER started before its BEFORE ended" "sed -i 's/^started=1200/started=1050/' kda-after/state.txt"
named kda void-identity "#68415 AFTER never ran" "rm -r kda-after"
named stride void-evidence "the summary would quote no GPU" "sed -i '/^gpu_name=/d' stride-before/state.txt"
named stride void-evidence "the whole-file command was not recorded" "sed -i '/^file_cmd=/d' stride-after/state.txt"
named stride void-evidence "BEFORE's command ran without --tb=short" "sed -i 's/ -rA --tb=short / -rA /' stride-before/state.txt"
named stride void-evidence "BEFORE's command selected something other than its recorded selection" "sed -i 's/ -k stride / -k recurrent /' stride-before/state.txt"
named stride after-file-not-passed "AFTER's whole file was 18 unrelated names and the three new ones" "mapfile -t fc < <(file_cases passed); for i in \$(seq 0 3 51); do fc[i]=\"unrelated_\$i\"; done; jx stride-after/file.xml \"\${fc[@]}\""
named kda void-evidence "the python was not recorded" "sed -i 's/^python_executable=.*/python_executable=unread/' kda-after/state.txt"
named kda void-evidence "the GPU was not an A10G" "sed -i 's/^gpu_name=.*/gpu_name=NVIDIA T4/' kda-before/state.txt"
named kda void-evidence "BEFORE's apply command was not recorded" "sed -i '/^apply_checkout_cmd=/d' kda-before/state.txt"
named kda void-evidence "BEFORE's junit path was another state's" "sed -i 's|--junitxml=/out/kda-before/test.xml|--junitxml=/out/kda-after/test.xml|' kda-before/state.txt"
d=$(case_dir k32); (cd "$d" && jx kda-before/test.xml "$KC[k64-v32]" failure "$K32" "$KC[k64-v64]" passed "" "$KC[k32-v64]" passed "" "$KC[k64-v32-hv2]" failure "$KHV")
python3 "$KV" "$d" KTEST KFIX > "$WORK/k32.out"
check "a BEFORE junit holding k32-v64 is stated as present" "grep -qx 'kda_before_junit_k32-v64=present' '$WORK/k32.out'"
# The image is every item's, so it alone voids both.
for edit in "rm image-identity.txt" "sed -i 's/ $IMAGE_COMMIT\$/ $OLD_IMAGE_COMMIT/' image-identity.txt" "sed -i 's/9071b00d/45feec27/' image-identity.txt" ": > wheel-sha256.txt"; do
  d=$(case_dir "img$RANDOM"); (cd "$d" && eval "$edit")
  check "an image record that fails ($edit) voids both items" "[ \"\$(v2 '$d')\" = 'stride=void-identity kda=void-identity' ]"
done

# ---------------------------------------------------------------- the session's own judge and exit status
# real_case_dir NAME: a confirmed case sweep carrying the session's real pins, so the session's --judge reads it as it would a returned run.
real_case_dir() {
  local d; d=$(case_dir "$1")
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
check "the session's judge exits 0 on both items confirmed and writes each verdict and the pytest summary with the assertion lines" \
  "judged ok : | grep -qx 'verdicts=$ALL_OK' && [ \"\$(cat '$WORK/judge-rc')\" = 0 ] && grep -qx 'stride_verdict=confirmed' '$WORK/judge-out-ok/stride-verdict.txt' && [ \"\$(grep -c '(the pinned one)\$' '$WORK/judge-out-ok/pytest-summary.txt')\" = 5 ] && [ \"\$(grep -c 'E   AssertionError: Tensor-likes are not equal!' '$WORK/judge-out-ok/pytest-summary.txt')\" = 3 ] && grep -qF 'E   assert torch.Size([1, 4, 1, 64]) == torch.Size([1, 4, 2, 32])' '$WORK/judge-out-ok/pytest-summary.txt'"
check "the session's judge exits 2 when one item is not confirmed, and names it" \
  "judged onefail \"sed -i 's/^test_rc=0/test_rc=1/' kda-after/state.txt\" | grep -qx 'verdicts=stride=confirmed kda=after-not-passed' && [ \"\$(cat '$WORK/judge-rc')\" = 2 ]"
check "the session's judge exits 2 when an item's records are missing" \
  "judged missing 'rm -r stride-before stride-after' | grep -qx 'verdicts=stride=void-identity kda=confirmed' && [ \"\$(cat '$WORK/judge-rc')\" = 2 ]"
check "the session's judge exits 2 when a verdict script crashes, and the other still stands" \
  "judged crash \"printf 'started=\\\\377\\\\n' > kda-after/state.txt\" | grep -qx 'verdicts=stride=confirmed kda=' && [ \"\$(cat '$WORK/judge-rc')\" = 2 ] && grep -q 'UnicodeDecodeError' '$WORK/judge-out-crash/download-errors.txt'"

if [[ $failures -ne 0 ]]; then
  echo "$failures check(s) failed" >&2
  exit 1
fi
echo "all checks passed"
