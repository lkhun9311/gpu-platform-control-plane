#!/usr/bin/env bash
#
# The MPS capability session: one g5.2xlarge Spot instance, one attempt at B0 to B5, at most 40 minutes.
#
#   SESSION_CONFIRM=yes AWS_PROFILE=gpu-lab MPSCAP_AMI_ID=ami-... bash hack/mps-capability-session.sh
#
# docs/superpowers/specs/2026-09-25-can-mps-engage-on-this-card-at-all.md, with its amendments of 2026-10-03 and
# 2026-10-24, is the registration; this script is the runner it asks for. It is separate from hack/m5c-gpu-session.sh
# so that the runner every other GPU study uses, and the user-data its lifecycle goldens pin, are untouched.
# What it shares with that runner it takes rather than copies: the EC2 lifecycle from hack/lib/spot-run.sh, the
# instance bring-up spliced from hack/m5c-gpu-session.sh between two anchor lines, and the cell from hack/m5c-matrix.sh.
#
# THE CLOCK. Every deadline counts from EC2's LaunchTime, which this script reads right after the launch and writes to
# the run's S3 prefix for the instance to read. The instance's phases end at 720, 1,200 and 1,920 s after it, its
# evidence at 2,040 s, and it shuts itself down by 2,100 s. The launch carries the termination sweeper's
# study-deadline tag at the request plus 2,040 s, and this script rewrites it to LaunchTime plus 2,070 s once it knows
# LaunchTime, so the sweeper, whose period is five minutes, cannot cut the evidence step and still asks for
# termination by 2,370 s.
#
# NOTHING HERE IS A DEFAULT A CALLER CAN MOVE. The registration fixes the instance type, the load, the stop and the
# price ceiling, so each is a constant, and a caller who sets one is refused rather than ignored.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

REGION=ap-northeast-2
ACCOUNT_WANT=007635145730
INSTANCE_TYPE_FIXED=g5.2xlarge
# The ceiling the paid-retry candidates page budgets with: at most about $0.8 for 40 minutes.
MAX_PRICE_FIXED=1.1324
STUDY_ID=mps-capability-2026-10-24
STACK=mpscap-gpu
PURPOSE=mps-capability
# Seconds from the launch request, and from LaunchTime, by the 2026-10-24 amendment.
TAG_AT_LAUNCH_S=2040
TAG_FROM_LAUNCH_S=2070
STOP_FROM_LAUNCH_S=2100
PHASE1_S=720
PHASE2_S=1200
PHASE3_S=1920
EVIDENCE_S=2040
# The registered end of the termination step, by which the shutdown is to be confirmed.
TERMINATION_S=2400
# The instance stops at once if it cannot read LaunchTime within this many seconds of its own start.
LAUNCHTIME_WAIT_S=180
# The sweeper is believed only if it ran this many times in the last half hour, with no error.
SWEEPER_MIN_RUNS=4

OUT="${OUT:-hack/mpscap-$(date -u +%Y%m%dT%H%M%SZ)}"
say() { echo "== $*" | { if [ -d "$OUT" ]; then tee -a "$OUT/session.log"; else cat; fi; }; }
fail() { echo "SESSION REFUSED: $*" | { if [ -d "$OUT" ]; then tee -a "$OUT/session.log"; else cat; fi; } >&2; exit 1; }
spot_say() { say "$@"; }
spot_fail() { fail "$@"; }

# ---------------------------------------------------------------- refusals, before anything is built or bought
for v in ARMS REPS RATE PREMIUM_WEIGHT NOISY_WEIGHT PROBE_WEIGHT DURATION_MS SEEDS LADDER SWEEP PILOT_STAGE STUDY \
  INSTANCE_TYPE MAX_SPOT_PRICE HARD_STOP_SECONDS BACKSTOP_SECONDS REQUIRE_CLEAN_TREE; do
  [ -z "${!v:-}" ] || fail "$v is set, and this session's value for it is its registration's; unset it"
done
[ "${SESSION_CONFIRM:-}" = yes ] || fail "SESSION_CONFIRM=yes is required: this buys a GPU instance, and only the owner's approval starts one"
[[ "${MPSCAP_AMI_ID:-}" =~ ^ami-[0-9a-f]{8,17}$ ]] ||
  fail "MPSCAP_AMI_ID is ${MPSCAP_AMI_ID:-unset}; the registration pins the AMI by ID rather than resolving it from latest"
for tool in aws go python3 git tar sha256sum; do command -v "$tool" >/dev/null || fail "$tool is not installed"; done
[ -z "$(git status --porcelain)" ] || fail "the working tree is dirty; the run's provenance is a commit, and the pins are taken from this tree"
COMMIT=$(git rev-parse HEAD)
ACCOUNT=$(aws sts get-caller-identity --query Account --output text 2>&1) || fail "could not read the caller's account: $ACCOUNT"
[ "$ACCOUNT" = "$ACCOUNT_WANT" ] || fail "the credentials are for account $ACCOUNT; paid sessions run only in gpu-lab ($ACCOUNT_WANT)"
# A fresh directory only: a journal or verdict left from another run would otherwise be read as this one's when a
# download fails (codex, review of 96bb69fd).
[ ! -e "$OUT" ] || fail "$OUT already exists; each session writes a new directory"
mkdir -p "$OUT" || fail "cannot create $OUT"
say "the MPS capability session, $STUDY_ID, from $COMMIT, into $OUT"

# shellcheck source=hack/lib/spot-run.sh
. hack/lib/spot-run.sh
# shellcheck source=hack/lib/mps-journal.sh
. hack/lib/mps-journal.sh
# shellcheck source=hack/lib/mps-capability.sh
. hack/lib/mps-capability.sh

# The AMI the ID names must be the GPU base image the matrix's bring-up expects.
ami_name=$(aws ec2 describe-images --region "$REGION" --image-ids "$MPSCAP_AMI_ID" \
  --query 'Images[0].[Name,State]' --output text 2>&1) || fail "could not describe $MPSCAP_AMI_ID: $ami_name"
case "$ami_name" in
  "Deep Learning Base OSS Nvidia Driver GPU AMI (Ubuntu 22.04)"*available) ;;
  *) fail "$MPSCAP_AMI_ID is '$ami_name', not an available Deep Learning Base OSS Nvidia Driver GPU AMI (Ubuntu 22.04)" ;;
esac
say "AMI $MPSCAP_AMI_ID: $ami_name"

# The live Spot price, per zone; only zones under the ceiling are tried.
prices=$(aws ec2 describe-spot-price-history --region "$REGION" --instance-types "$INSTANCE_TYPE_FIXED" \
  --product-descriptions "Linux/UNIX" --start-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --query 'SpotPriceHistory[].[AvailabilityZone,SpotPrice]' --output text 2>&1) || fail "could not read the Spot price: $prices"
printf '%s\n' "$prices" >"$OUT/spot-prices.txt"
ZONES=$(awk -v cap="$MAX_PRICE_FIXED" 'NF == 2 && $2 + 0 > 0 && $2 + 0 <= cap + 0 {print $1}' <<<"$prices" | sort -u | paste -sd' ')
[ -n "$ZONES" ] || fail "no zone offers $INSTANCE_TYPE_FIXED Spot at or under \$$MAX_PRICE_FIXED/h: $(paste -sd' ' <<<"$prices")"
say "Spot $INSTANCE_TYPE_FIXED under \$$MAX_PRICE_FIXED/h in: $ZONES ($(paste -sd' ' <<<"$prices"))"

quota=$(aws service-quotas get-service-quota --region "$REGION" --service-code ec2 --quota-code L-3819A6DF \
  --query 'Quota.Value' --output text 2>&1) || fail "could not read the G and VT Spot quota: $quota"
python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) >= 8 else 1)' "$quota" 2>/dev/null ||
  fail "the G and VT Spot quota is $quota vCPU and one $INSTANCE_TYPE_FIXED needs 8"

# The sweeper is the kill that needs neither the instance nor this laptop, so it is read before anything is bought:
# deployed, enabled on its five-minute rule, aimed at itself, and seen running without error in the last half hour.
sw_state=$(aws lambda get-function --region "$REGION" --function-name gpu-platform-study-sweeper \
  --query 'Configuration.State' --output text 2>&1) || fail "the termination sweeper could not be read: $sw_state"
[ "$sw_state" = Active ] || fail "the termination sweeper is $sw_state, not Active"
sw_rule=$(aws events describe-rule --region "$REGION" --name gpu-platform-study-sweeper \
  --query '[State,ScheduleExpression]' --output text 2>&1) || fail "the sweeper's rule could not be read: $sw_rule"
[ "$(tr -s '[:space:]' ' ' <<<"$sw_rule" | sed 's/ $//')" = "ENABLED rate(5 minutes)" ] || fail "the sweeper's rule is '$sw_rule', not ENABLED rate(5 minutes)"
sw_target=$(aws events list-targets-by-rule --region "$REGION" --rule gpu-platform-study-sweeper \
  --query 'Targets[].Arn' --output text 2>&1) || fail "the sweeper's targets could not be read: $sw_target"
[ "$sw_target" = "arn:aws:lambda:$REGION:$ACCOUNT_WANT:function:gpu-platform-study-sweeper" ] ||
  fail "the sweeper's rule targets '$sw_target', not the sweeper"
sw_metric() {
  aws cloudwatch get-metric-statistics --region "$REGION" --namespace AWS/Lambda --metric-name "$1" \
    --dimensions Name=FunctionName,Value=gpu-platform-study-sweeper \
    --start-time "$(date -u -d '-30 min' +%Y-%m-%dT%H:%M:%SZ)" --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --period 1800 --statistics Sum --query 'Datapoints[0].Sum' --output text
}
sw_runs=$(sw_metric Invocations 2>&1) || fail "the sweeper's invocations could not be read: $sw_runs"
sw_errors=$(sw_metric Errors 2>&1) || fail "the sweeper's errors could not be read: $sw_errors"
python3 -c 'import sys; r, e, least = sys.argv[1:4]; sys.exit(0 if r != "None" and float(r) >= int(least) and e in ("None", "0.0", "0") else 1)' \
  "$sw_runs" "$sw_errors" "$SWEEPER_MIN_RUNS" 2>/dev/null ||
  fail "the sweeper ran $sw_runs time(s) with $sw_errors error(s) in the last 30 minutes; at least $SWEEPER_MIN_RUNS clean runs are required"
say "the termination sweeper: Active, ENABLED rate(5 minutes), $sw_runs run(s) and ${sw_errors/None/0} error(s) in the last 30 minutes"

# The credentials must outlast the whole session and its teardown: 40 minutes, the wait for LaunchTime, and the
# downloads and termination after it, with half an hour of headroom.
cred_exp=$(aws configure export-credentials --format process 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("Expiration",""))' 2>/dev/null || true)
[ -n "$cred_exp" ] || fail "the CLI could not export the active credential's expiry, so it cannot be shown to outlast the session"
cred_left=$(python3 -c 'import datetime,sys; e=datetime.datetime.fromisoformat(sys.argv[1].replace("Z","+00:00")); print(int((e-datetime.datetime.now(datetime.timezone.utc)).total_seconds()//60))' "$cred_exp")
[ "$cred_left" -ge 80 ] || fail "the credentials expire in $cred_left minutes; the session needs 50 and 30 of headroom. Re-authenticate first"
say "credentials expire in $cred_left minutes"

live=$(aws ec2 describe-instances --region "$REGION" --filters "Name=tag:purpose,Values=$PURPOSE" \
  "Name=instance-state-name,Values=pending,running,shutting-down,stopping,stopped" \
  --query 'Reservations[].Instances[].InstanceId' --output text 2>&1) || fail "could not list earlier capability instances: $live"
[ -z "$live" ] || fail "an earlier capability instance is still live ($live); one attempt is registered"

# ---------------------------------------------------------------- what the instance runs
say "building the gateway and the harness for the instance"
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o "$OUT/gateway" ./cmd/gateway || fail "build gateway"
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o "$OUT/benchharness" ./cmd/benchharness || fail "build benchharness"
go build -o "$OUT/benchharness-local" ./cmd/benchharness || fail "build the local benchharness"
git archive --format=tar.gz -o "$OUT/source.tgz" HEAD || fail "git archive"
SOURCE_SHA=$(sha256sum "$OUT/source.tgz" | cut -d' ' -f1)
GATEWAY_SHA=$(sha256sum "$OUT/gateway" | cut -d' ' -f1)
HARNESS_SHA=$(sha256sum "$OUT/benchharness" | cut -d' ' -f1)
# The pins the instance compares the tree it unpacked against; this tree is clean, so they are the commit's.
PIN_OVERLAY=$(mpscap_pin_hash "${MPSCAP_OVERLAY_FILES[@]}")
PIN_ENGINES=$(mpscap_pin_hash "${MPSCAP_ENGINE_FILES[@]}")
RUN_NONCE=$(python3 -c 'import secrets; print(secrets.token_hex(4))')
RUN_ID="$(basename "$OUT")-$RUN_NONCE"
BUCKET="$STACK-$ACCOUNT"
{
  echo "commit=$COMMIT"
  echo "study=$STUDY_ID"
  echo "ami_id=$MPSCAP_AMI_ID"
  echo "ami_name=$ami_name"
  echo "instance_type=$INSTANCE_TYPE_FIXED"
  echo "max_spot_price=$MAX_PRICE_FIXED"
  echo "source_sha256=$SOURCE_SHA"
  echo "gateway_sha256=$GATEWAY_SHA"
  echo "benchharness_sha256=$HARNESS_SHA"
  echo "pin_overlay=$PIN_OVERLAY"
  echo "pin_engines=$PIN_ENGINES"
  echo "run_id=$RUN_ID"
} >"$OUT/session-provenance.txt"

# The instance bring-up, taken from hack/m5c-gpu-session.sh between two anchors that must each occur once: the
# toolkit, kind, the node's toolkit and the gateway's RBAC, exactly as every sharing cell had them.
bringup_from=$(grep -nx 'export DEBIAN_FRONTEND=noninteractive' hack/m5c-gpu-session.sh | cut -d: -f1 | paste -sd' ')
bringup_to=$(grep -nx 'upload /tmp/node-cards.txt preflight-node-cards.txt' hack/m5c-gpu-session.sh | cut -d: -f1 | paste -sd' ')
[[ "$bringup_from" =~ ^[0-9]+$ && "$bringup_to" =~ ^[0-9]+$ && "$bringup_from" -lt "$bringup_to" ]] ||
  fail "the bring-up anchors in hack/m5c-gpu-session.sh are not each found once, in order (from '$bringup_from', to '$bringup_to')"
sed -n "${bringup_from},${bringup_to}p" hack/m5c-gpu-session.sh >"$OUT/bringup.sh"

UD="$OUT/user-data.sh"
{
  cat <<'HEAD'
#!/bin/bash
exec > >(tee /var/log/mpscap.log) 2>&1
set -x
MPSCAP_START=$(date +%s)
# The first backstop, armed before anything can fail, counts from the instance's own start; LaunchTime precedes it,
# so the precise one below, armed once LaunchTime is read, always fires first.
( sleep STOP_FROM_LAUNCH_S_PLACEHOLDER; shutdown -h now ) &
BUCKET="BUCKET_PLACEHOLDER"
PREFIX="RUN_ID_PLACEHOLDER"
SOURCE_SHA="SOURCE_SHA_PLACEHOLDER"
GATEWAY_SHA="GATEWAY_SHA_PLACEHOLDER"
HARNESS_SHA="HARNESS_SHA_PLACEHOLDER"
COMMIT="COMMIT_PLACEHOLDER"
upload() { aws s3 cp --only-show-errors "$1" "s3://$BUCKET/$PREFIX/$2" || true; }
trap 'upload /var/log/mpscap.log log.txt; shutdown -h now' EXIT
aws s3 cp --only-show-errors "s3://$BUCKET/$PREFIX/src/source.tgz" /tmp/source.tgz
[ "$(sha256sum /tmp/source.tgz | cut -d' ' -f1)" = "$SOURCE_SHA" ] || { echo "source checksum mismatch"; exit 1; }
mkdir -p /src && tar -xzf /tmp/source.tgz -C /src && cd /src || exit 1
mkdir -p /src/bin /src/m5c-run
for b in gateway benchharness; do aws s3 cp --only-show-errors "s3://$BUCKET/$PREFIX/bin/$b" "/src/bin/$b"; chmod +x "/src/bin/$b"; done
[ "$(sha256sum /src/bin/gateway | cut -d' ' -f1)" = "$GATEWAY_SHA" ] || { echo "gateway checksum mismatch"; exit 1; }
[ "$(sha256sum /src/bin/benchharness | cut -d' ' -f1)" = "$HARNESS_SHA" ] || { echo "benchharness checksum mismatch"; exit 1; }
. hack/lib/mps-journal.sh
. hack/lib/mps-capability.sh
export MPS_JOURNAL=/src/m5c-run/mps-journal.jsonl
# Uploaded after every line, so a session cut short has said how far it got.
export MPS_JOURNAL_ON_APPEND="aws s3 cp --only-show-errors $MPS_JOURNAL s3://$BUCKET/$PREFIX/journal.jsonl"
# LaunchTime, written by the session that launched this instance; nothing else is a valid clock for the phases.
L=""
while [ $(( $(date +%s) - MPSCAP_START )) -lt LAUNCHTIME_WAIT_S_PLACEHOLDER ]; do
  if aws s3 cp --only-show-errors "s3://$BUCKET/$PREFIX/launch-time.txt" /tmp/launch-time.txt 2>/dev/null; then
    L=$(date -u -d "$(cat /tmp/launch-time.txt)" +%s 2>/dev/null || true)
    break
  fi
  sleep 5
done
NOW=$(date +%s)
if ! [[ "$L" =~ ^[0-9]+$ ]] || [ "$L" -gt "$NOW" ] || [ $(( NOW - L )) -gt 900 ]; then
  mj_fact launch_time_read false "LaunchTime was ${L:-not read} at $NOW, $(( NOW - MPSCAP_START )) s after this instance started"
  exit 1
fi
mj_fact launch_time_read true "LaunchTime $(cat /tmp/launch-time.txt), epoch $L"
( sleep $(( L + STOP_FROM_LAUNCH_S_PLACEHOLDER - $(date +%s) > 0 ? L + STOP_FROM_LAUNCH_S_PLACEHOLDER - $(date +%s) : 1 )); shutdown -h now ) &
P1=$(( L + PHASE1_S_PLACEHOLDER )); P2=$(( L + PHASE2_S_PLACEHOLDER )); P3=$(( L + PHASE3_S_PLACEHOLDER )); EV=$(( L + EVIDENCE_S_PLACEHOLDER ))
nvidia-smi --query-gpu=index,name,memory.total,driver_version --format=csv > /tmp/nvidia-smi.csv || exit 1
upload /tmp/nvidia-smi.csv preflight-nvidia-smi.csv
[ "$(tail -n +2 /tmp/nvidia-smi.csv | wc -l)" = 1 ] && tail -n +2 /tmp/nvidia-smi.csv | grep -q A10G || { echo "PREFLIGHT FAILED: not one A10G"; exit 1; }
HEAD
  # The bring-up runs as its own script under a timeout that ends with phase 1, because phase 1 is registered to include
  # it, and a hung install with no clock on it would never reach the evidence step (codex, review of 96bb69fd).
  # The bring-up's own upload, single-quoted so it reaches the instance unexpanded.
  # shellcheck disable=SC2016
  echo "cat > /tmp/bringup.sh <<'BRINGUP'"
  # shellcheck disable=SC2016
  echo 'upload() { aws s3 cp --only-show-errors "$1" "s3://$BUCKET/$PREFIX/$2" || true; }'
  cat "$OUT/bringup.sh"
  echo "BRINGUP"
  cat <<'TAIL'
export BUCKET PREFIX
bringup_left=$(( P1 - $(date +%s) ))
bringup_rc=124
if [ "$bringup_left" -gt 0 ]; then
  timeout --kill-after=15 "$bringup_left" bash /tmp/bringup.sh
  bringup_rc=$?
fi
echo "bring-up exited $bringup_rc"
# The run record, before B0: what the registration says a capability answer is worth nothing without.
imds=$(curl -s -X PUT -H "X-aws-ec2-metadata-token-ttl-seconds: 300" http://169.254.169.254/latest/api/token)
md() { curl -s -H "X-aws-ec2-metadata-token: $imds" "http://169.254.169.254/latest/meta-data/$1"; }
{
  echo "commit=$COMMIT"
  echo "launch_time_epoch=$L"
  echo "instance_id=$(md instance-id)"
  echo "ami_id=$(md ami-id)"
  echo "driver=$(tail -n +2 /tmp/nvidia-smi.csv | cut -d, -f4 | tr -d ' ')"
  echo "toolkit_host=$(nvidia-ctk --version 2>/dev/null | head -1)"
  echo "toolkit_node=$(docker exec m5cgpu-worker nvidia-ctk --version 2>/dev/null | head -1)"
  echo "engine_a_image=$(grep -m1 -oE 'image: *[^ ]+' config/vllm-shared/engine-a.yaml | sed 's/image: *//')"
  echo "engine_b_image=$(grep -m1 -oE 'image: *[^ ]+' config/vllm-shared/engine-b.yaml | sed 's/image: *//')"
  echo "plugin_image=$(grep -m1 -oE 'image: *[^ ]+' config/nvidia-device-plugin-mps/daemonset.yaml | sed 's/image: *//')"
  echo "pin_overlay=$(mpscap_pin_hash "${MPSCAP_OVERLAY_FILES[@]}")"
  echo "pin_engines=$(mpscap_pin_hash "${MPSCAP_ENGINE_FILES[@]}")"
} > /tmp/provenance.txt
upload /tmp/provenance.txt provenance.txt
if awk -F= 'NF < 2 || $2 == "" {bad = 1} END {exit bad}' /tmp/provenance.txt; then
  mj_fact provenance_complete true
else
  mj_fact provenance_complete false "a field of the run record is empty: $(awk -F= 'NF < 2 || $2 == ""' /tmp/provenance.txt | paste -sd' ')"
fi
export KUBECONFIG=/tmp/kubeconfig PLATFORM=kind KCTX=kind-m5cgpu GPU_NODE=m5cgpu-worker DEADLINE_EPOCH="$EV"
export GATEWAY_BIN=/src/bin/gateway BENCHHARNESS_BIN=/src/bin/benchharness OUT=/src/m5c-run SOURCE_COMMIT="$COMMIT"
export STUDY=STUDY_PLACEHOLDER ARMS=mps REPS=1 RATE=2 PREMIUM_WEIGHT=1 NOISY_WEIGHT=0.054 PROBE_WEIGHT=0 DURATION_MS=120000
export MPSCAP_PHASE1_END="$P1" MPSCAP_PHASE2_END="$P2" MPSCAP_PHASE3_END="$P3"
export MPSCAP_PIN_OVERLAY=PIN_OVERLAY_PLACEHOLDER MPSCAP_PIN_ENGINES=PIN_ENGINES_PLACEHOLDER
# The phases are enforced from outside the matrix; its TERM runs its cleanup, and with it the diagnostics.
if [ "$bringup_rc" = 0 ]; then
  mpscap_supervise "$P1" "$P2" "$P3" 90 -- bash hack/m5c-matrix.sh
  matrix_rc=$?
else
  # No cluster, so no bar is started; the run goes straight to its evidence and reads INCONCLUSIVE or INVALID.
  echo "the bring-up did not finish inside phase 1 (exit $bringup_rc); the matrix is not run"
  matrix_rc=$bringup_rc
fi
echo "matrix exited $matrix_rc"
evidence_rc=0
left=$(( EV - $(date +%s) )); [ "$left" -gt 5 ] || left=5
tar -czf /tmp/evidence.tgz -C /src m5c-run || evidence_rc=$?
[ "$evidence_rc" != 0 ] || timeout "$left" aws s3 cp --only-show-errors /tmp/evidence.tgz "s3://$BUCKET/$PREFIX/evidence.tgz" || evidence_rc=$?
# The diagnostics are uploaded when the evidence is, and complete when every required one ran.
inv=/src/m5c-run/mpscap/diag/inventory.tsv
if [ "$evidence_rc" = 0 ] && grep -qx 'required_failed=0' /src/m5c-run/mpscap/diag/complete 2>/dev/null && [ -s "$inv" ] &&
  awk -F'\t' 'NR > 1 && $5 == "yes" && $2 != 0 {bad = 1} END {exit bad}' "$inv"; then
  mj_fact diagnostics_uploaded true
else
  mj_fact diagnostics_uploaded false "evidence upload exit $evidence_rc; inventory $( [ -s "$inv" ] && awk -F'\t' 'NR > 1 && $5 == "yes" && $2 != 0 {print $1}' "$inv" | paste -sd' ' || echo missing)"
fi
upload /var/log/mpscap.log log.txt
echo "RUN_NONCE_PLACEHOLDER" > /tmp/DONE
upload /tmp/DONE DONE
TAIL
} >"$UD.template"
sed -e "s|BUCKET_PLACEHOLDER|$BUCKET|" -e "s|RUN_ID_PLACEHOLDER|$RUN_ID|" -e "s|SOURCE_SHA_PLACEHOLDER|$SOURCE_SHA|" \
  -e "s|GATEWAY_SHA_PLACEHOLDER|$GATEWAY_SHA|" -e "s|HARNESS_SHA_PLACEHOLDER|$HARNESS_SHA|" -e "s|COMMIT_PLACEHOLDER|$COMMIT|" \
  -e "s|STUDY_PLACEHOLDER|$STUDY_ID|" -e "s|PIN_OVERLAY_PLACEHOLDER|$PIN_OVERLAY|" -e "s|PIN_ENGINES_PLACEHOLDER|$PIN_ENGINES|" \
  -e "s|RUN_NONCE_PLACEHOLDER|$RUN_NONCE|" -e "s|LAUNCHTIME_WAIT_S_PLACEHOLDER|$LAUNCHTIME_WAIT_S|" \
  -e "s|STOP_FROM_LAUNCH_S_PLACEHOLDER|$STOP_FROM_LAUNCH_S|g" -e "s|PHASE1_S_PLACEHOLDER|$PHASE1_S|" \
  -e "s|PHASE2_S_PLACEHOLDER|$PHASE2_S|" -e "s|PHASE3_S_PLACEHOLDER|$PHASE3_S|" -e "s|EVIDENCE_S_PLACEHOLDER|$EVIDENCE_S|" \
  "$UD.template" >"$UD" || fail "could not render the user-data"
rm -f "$UD.template"
! grep -q '_PLACEHOLDER' "$UD" || fail "the user-data still holds a placeholder: $(grep -o '[A-Z_]*_PLACEHOLDER' "$UD" | sort -u | paste -sd' ')"
[ "$(head -c 2 "$UD")" = '#!' ] || fail "the user-data does not begin with a shebang, so cloud-init would not run it"
bash -n "$UD" || fail "the user-data does not parse"
# EC2 limits user-data to 16 KB before encoding, and spot_launch passes it as text, so it is sent uncompressed.
[ "$(wc -c <"$UD")" -lt 16384 ] || fail "the user-data is $(wc -c <"$UD") bytes, over EC2's 16 KB limit"

# ---------------------------------------------------------------- the purchase
spot_ensure_bucket "$BUCKET" "$REGION" 30 || fail "could not prepare the results bucket $BUCKET"
spot_ensure_profile "$STACK" \
  "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"s3:PutObject\",\"s3:GetObject\"],\"Resource\":\"arn:aws:s3:::$BUCKET/*\"}]}" \
  20 || fail "could not prepare the instance profile $STACK"
for f in source.tgz:src/source.tgz gateway:bin/gateway benchharness:bin/benchharness; do
  aws s3 cp --only-show-errors "$OUT/${f%%:*}" "s3://$BUCKET/$RUN_ID/${f#*:}" || fail "upload ${f%%:*}"
done

IID=""
LAUNCH_UNCERTAIN=""
LAUNCH_UNCERTAIN_SUBNET=""
TERMINATION=""
cleanup_ran=0
cleanup() {
  [ "$cleanup_ran" = 1 ] && return 0
  cleanup_ran=1
  if [ -n "$LAUNCH_UNCERTAIN" ]; then
    spot_reconcile_token "$REGION" "$LAUNCH_UNCERTAIN" "$LAUNCH_UNCERTAIN_SUBNET" 6 ||
      { echo "TERMINATION UNCONFIRMED for the launch under token $LAUNCH_UNCERTAIN" | tee "$OUT/termination.txt" >&2; exit 1; }
  fi
  [ -z "$TERMINATION" ] || return 0
  if [ -z "$IID" ]; then
    echo "no instance was launched by this session" >"$OUT/termination.txt"
  elif spot_terminate "$REGION" "$IID"; then
    echo "terminated $IID" >"$OUT/termination.txt"
  else
    echo "TERMINATION UNCONFIRMED for $IID -- check the console now" | tee "$OUT/termination.txt" >&2
    exit 1
  fi
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

request_epoch=$(date +%s)
TAG_DEADLINE=$(date -u -d "@$(( request_epoch + TAG_AT_LAUNCH_S ))" +%Y-%m-%dT%H:%M:%SZ)
TAGS="ResourceType=instance,Tags=[{Key=Name,Value=$STACK},{Key=purpose,Value=$PURPOSE},{Key=run,Value=$RUN_NONCE},{Key=study-deadline,Value=$TAG_DEADLINE}]"
say "launching $INSTANCE_TYPE_FIXED Spot (max \$$MAX_PRICE_FIXED/h), study-deadline $TAG_DEADLINE -- the instance bills from here"
for z in $ZONES; do
  SUBNET=$(spot_subnet_in_zone "$REGION" "$z") || continue
  token="mpscap-$RUN_NONCE-$z"
  LAUNCH_UNCERTAIN="$token"; LAUNCH_UNCERTAIN_SUBNET="$SUBNET"
  # This attempt's own errors, so one zone's capacity answer cannot excuse another zone's real refusal.
  IID=$(spot_launch "$REGION" "$MPSCAP_AMI_ID" "$INSTANCE_TYPE_FIXED" "$SUBNET" "$STACK" "$MAX_PRICE_FIXED" 200 \
    "$UD" "$TAGS" "$token" 2>"$OUT/launch-error-$z.txt") || IID=""
  cat "$OUT/launch-error-$z.txt" >>"$OUT/launch-errors.txt"
  if [ -n "$IID" ] && [ "$IID" != None ]; then LAUNCH_UNCERTAIN=""; break; fi
  IID=""
  if grep -qiE 'InsufficientInstanceCapacity|capacity-not-available' "$OUT/launch-error-$z.txt"; then LAUNCH_UNCERTAIN=""; continue; fi
  fail "the launch in $z was refused for a reason that is not capacity; see $OUT/launch-errors.txt"
done
[ -n "$IID" ] || fail "no zone had $INSTANCE_TYPE_FIXED Spot capacity; nothing was launched"
echo "$IID" >"$OUT/instance-id"
say "launched $IID in $z"

# LaunchTime and the image, read from EC2 at once; the instance waits for the first, and the run is void without both.
launch=""
for _ in $(seq 1 12); do
  launch=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$IID" \
    --query 'Reservations[0].Instances[0].[LaunchTime,ImageId]' --output text 2>&1) && [ -n "${launch%%[[:space:]]*}" ] && break
  sleep 5
done
LAUNCH_TIME=$(awk '{print $1}' <<<"$launch")
IMAGE_ID=$(awk '{print $2}' <<<"$launch")
L=$(date -u -d "$LAUNCH_TIME" +%s 2>/dev/null) || fail "could not read $IID's LaunchTime: $launch"
[ "$IMAGE_ID" = "$MPSCAP_AMI_ID" ] || fail "$IID runs $IMAGE_ID, not the pinned $MPSCAP_AMI_ID"
printf '%s\n' "$LAUNCH_TIME" >"$OUT/launch-time.txt"
aws s3 cp --only-show-errors "$OUT/launch-time.txt" "s3://$BUCKET/$RUN_ID/launch-time.txt" ||
  fail "could not hand LaunchTime to the instance; it will stop itself, and this session terminates it"
TAG_FROM_LAUNCH=$(date -u -d "@$(( L + TAG_FROM_LAUNCH_S ))" +%Y-%m-%dT%H:%M:%SZ)
if aws ec2 create-tags --region "$REGION" --resources "$IID" --tags "Key=study-deadline,Value=$TAG_FROM_LAUNCH" 2>>"$OUT/launch-errors.txt"; then
  say "LaunchTime $LAUNCH_TIME; the sweeper's deadline moved to $TAG_FROM_LAUNCH"
else
  say "LaunchTime $LAUNCH_TIME; the sweeper's deadline could not be moved and stays at $TAG_DEADLINE, which may cut the evidence step"
fi

# ---------------------------------------------------------------- the wait, and the end
spot_wait_for_marker_until "$REGION" "$BUCKET" "$RUN_ID/DONE" "$IID" $(( L + STOP_FROM_LAUNCH_S )) 20 400 >"$OUT/wait.txt"
wait_rc=$?
say "the wait ended with status $wait_rc ($(cat "$OUT/wait.txt"))"
# The confirmation may take until TERMINATION_S from LaunchTime, as registered, and never less than the library's five
# minutes. Run 2 of 2026-10-24 had every bar pass and was INVALID because a fixed 300 s ended with the instance still
# shutting-down; it read terminated by hand seconds later. Billing had stopped at shutting-down, so the
# longer wait costs nothing; the tries are scaled with it so that a count does not end the wait before the clock does.
SPOT_TERMINATE_WAIT=$(( L + TERMINATION_S - $(date +%s) ))
[ "$SPOT_TERMINATE_WAIT" -ge 300 ] || SPOT_TERMINATE_WAIT=300
SPOT_TERMINATE_TRIES=$(( SPOT_TERMINATE_WAIT / 5 + 1 ))
say "waiting up to ${SPOT_TERMINATE_WAIT}s for EC2 to report the instance terminated"
if spot_terminate "$REGION" "$IID"; then
  TERMINATION=confirmed
  echo "terminated $IID" >"$OUT/termination.txt"
else
  TERMINATION=unconfirmed
  echo "TERMINATION UNCONFIRMED for $IID -- check the console now" | tee "$OUT/termination.txt" >&2
fi
for k in journal.jsonl evidence.tgz log.txt provenance.txt preflight-nvidia-smi.csv DONE; do
  aws s3 cp --only-show-errors "s3://$BUCKET/$RUN_ID/$k" "$OUT/$k" 2>>"$OUT/download-errors.txt" || echo "not downloaded: $k" >>"$OUT/download-errors.txt"
done
[ ! -s "$OUT/evidence.tgz" ] || tar -xzf "$OUT/evidence.tgz" -C "$OUT" || echo "the evidence archive did not unpack" >>"$OUT/download-errors.txt"

# The instance cannot know it was terminated; this session does, and records it in its copy of the journal.
export MPS_JOURNAL="$OUT/journal.jsonl"
[ -s "$MPS_JOURNAL" ] || : >"$MPS_JOURNAL"
if [ "$TERMINATION" = confirmed ]; then
  mj_fact termination_confirmed true "$IID terminated" || fail "the journal already held a termination fact, so it is not this session's"
else
  mj_fact termination_confirmed false "$IID was not seen terminated" || fail "the journal already held a termination fact, so it is not this session's"
fi
"$OUT/benchharness-local" mps-capability-verdict --journal "$MPS_JOURNAL" | tee "$OUT/verdict.txt"
say "the verdict is in $OUT/verdict.txt and the evidence in $OUT/m5c-run"
[ "$TERMINATION" = confirmed ] || exit 1
