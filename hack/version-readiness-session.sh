#!/usr/bin/env bash
#
# The engine-readiness preflight (#594): one g5.xlarge Spot instance, one attempt, stopped by itself 8,130 s after launch.
#
#   SESSION_CONFIRM=yes AWS_PROFILE=gpu-lab VERSION_READINESS_AMI_ID=ami-... bash hack/version-readiness-session.sh
#
# docs/superpowers/specs/2026-11-15-vllm-version-async-study-design.md registers the version study, whose worst case
# is mostly engine readiness that no session has measured; this session measures it so the bounds can be amended.
# On the instance it runs only `benchharness version-readiness`: two image pulls, the model download, then three
# starts of each treatment A, B and C with the study's own containers (bench.DockerEngine) and readiness rule.
# Every ready engine's identity endpoints (/version, /v1/models, /server_info, /metrics, /tokenize) and every
# container's own log are saved raw, for the identity check the study still has to write against them.
# It is modelled on hack/gpu-fault-session.sh and shares what that runner shares: the EC2 lifecycle from
# hack/lib/spot-run.sh, and the NVIDIA container toolkit set-up spliced from hack/m5c-gpu-session.sh between two anchors.
#
# THE CLOCK. Every deadline counts from EC2's LaunchTime, read right after the launch and written to the run's S3
# prefix for the instance to read. The work is bounded step by step, and the deadlines are their sum:
#   bring-up (boot, cloud-init, harness download, toolkit)        600 s  -> 600
#   two image pulls, ReadinessPullBound each         2 x 1,500 = 3,000 s
#   model download, ReadinessModelBound                            300 s
#   nine starts: readiness bound, ReadinessCaptureBound, ReadinessStopBound
#                                               9 x (600 + 20 + 30) = 5,850 s
#   so the harness ends by 600 + 3,000 + 300 + 5,850             = 9,750 s
#   evidence upload                                                120 s  -> 9,870
# The launch carries the termination sweeper's study-deadline tag at the request plus 9,870 s, rewritten to LaunchTime
# plus 9,900 s once LaunchTime is known; the instance shuts itself down at 9,930 s; the termination is to be
# confirmed by 10,230 s, the sweeper's five-minute period after its tag plus 30 s.
#
# THE COST. The worst case bills to the termination deadline: 10,230 s = 2.8417 h.
# At the $0.90/h Spot cap below that is $2.558 of compute; with the $0.0324/h of 200 GB gp3 and a public IPv4 the other
# sessions add (hack/gpu-fault-session.sh), $0.9324/h all in, it is $2.650, under $3.
# The script refuses to run if the constants below stop giving a worst case under $3.
#
# NOTHING HERE IS A DEFAULT A CALLER CAN MOVE: the instance, the bounds and the stop are constants, and a caller who
# sets one is refused rather than ignored.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

REGION=ap-northeast-2
ACCOUNT_WANT=007635145730
# The study's instance type (spec, "The question").
INSTANCE_TYPE_FIXED=g5.xlarge
# The Spot cap is below the $1.237/h on-demand price, so the longer pulls still fit $3; g5.xlarge Spot was $0.61/h in
# ap-northeast-2 on 2026-11-16, and a zone above the cap is not used.
MAX_PRICE_FIXED=0.90
# The cap plus 200 GB gp3 and a public IPv4, the $0.0324/h hack/gpu-fault-session.sh adds to its own cap.
ALL_IN_RATE=0.9324
COST_CAP_USD=3.00
STUDY_ID=vllm-version-async-2026-11-15
STACK=verready-gpu
PURPOSE=version-readiness
# The step bounds, each the harness's own constant (internal/bench/version_readiness.go and the design's readiness bound).
# hack/version-readiness-session-test.sh holds these equal to the Go source, so the stop cannot drift from the work.
BRINGUP_S=600
PULL_BOUND_S=1500
PULLS=2
MODEL_BOUND_S=300
READINESS_BOUND_S=600
CAPTURE_BOUND_S=20
STOP_BOUND_S=30
STARTS=9
EVIDENCE_UPLOAD_S=120
HARNESS_END_S=$(( BRINGUP_S + PULLS * PULL_BOUND_S + MODEL_BOUND_S + STARTS * (READINESS_BOUND_S + CAPTURE_BOUND_S + STOP_BOUND_S) ))
EVIDENCE_S=$(( HARNESS_END_S + EVIDENCE_UPLOAD_S ))
TAG_AT_LAUNCH_S=$EVIDENCE_S
TAG_FROM_LAUNCH_S=$(( EVIDENCE_S + 30 ))
STOP_FROM_LAUNCH_S=$(( EVIDENCE_S + 60 ))
TERMINATION_S=$(( TAG_FROM_LAUNCH_S + 330 ))
LAUNCHTIME_WAIT_S=180
# The DONE wait polls every WAIT_INTERVAL_S and every poll sleeps that long, so this many attempts outlast the stop and
# the wall-clock deadline, not the count, ends the wait.
WAIT_INTERVAL_S=20
WAIT_ATTEMPTS=$(( STOP_FROM_LAUNCH_S / WAIT_INTERVAL_S + 2 ))
SWEEPER_MIN_RUNS=4
# The session's end of the termination wait plus 30 minutes of headroom, in minutes.
CRED_MIN_MINUTES=$(( TERMINATION_S / 60 + 30 ))
VOLUME_GB=200

OUT="${OUT:-hack/version-readiness-$(date -u +%Y%m%dT%H%M%SZ)}"
say() { echo "== $*" | { if [ -d "$OUT" ]; then tee -a "$OUT/session.log"; else cat; fi; }; }
fail() { echo "SESSION REFUSED: $*" | { if [ -d "$OUT" ]; then tee -a "$OUT/session.log"; else cat; fi; } >&2; exit 1; }
spot_say() { say "$@"; }
spot_fail() { fail "$@"; }

# ---------------------------------------------------------------- refusals, before anything is built or bought
for v in INSTANCE_TYPE MAX_SPOT_PRICE HARD_STOP_SECONDS BACKSTOP_SECONDS READINESS_SECONDS WARM_STARTS TREATMENTS \
  STUDY IMAGES PULL_BOUND MODEL_BOUND; do
  [ -z "${!v:-}" ] || fail "$v is set, and this session's value for it is its registration's; unset it"
done
python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) / 3600 * float(sys.argv[2]) < float(sys.argv[3]) else 1)' \
  "$TERMINATION_S" "$ALL_IN_RATE" "$COST_CAP_USD" ||
  fail "the worst case, $TERMINATION_S s at \$$ALL_IN_RATE/h, is not under \$$COST_CAP_USD"
# The schedule alone, with nothing checked or bought, so the refusals test can hold it to the harness's bounds.
if [ "${1:-}" = --print-schedule ]; then
  echo "harness_end_s=$HARNESS_END_S evidence_s=$EVIDENCE_S stop_s=$STOP_FROM_LAUNCH_S termination_s=$TERMINATION_S"
  exit 0
fi
[ "${SESSION_CONFIRM:-}" = yes ] || fail "SESSION_CONFIRM=yes is required: this buys a GPU instance, and only the owner's approval starts one"
[[ "${VERSION_READINESS_AMI_ID:-}" =~ ^ami-[0-9a-f]{8,17}$ ]] ||
  fail "VERSION_READINESS_AMI_ID is ${VERSION_READINESS_AMI_ID:-unset}; the session pins the AMI by ID rather than resolving it from latest"
for tool in aws go python3 git tar sha256sum; do command -v "$tool" >/dev/null || fail "$tool is not installed"; done
[ -z "$(git status --porcelain)" ] || fail "the working tree is dirty; the run's provenance is a commit, and the harness is built from this tree"
COMMIT=$(git rev-parse HEAD)
ACCOUNT=$(aws sts get-caller-identity --query Account --output text 2>&1) || fail "could not read the caller's account: $ACCOUNT"
[ "$ACCOUNT" = "$ACCOUNT_WANT" ] || fail "the credentials are for account $ACCOUNT; paid sessions run only in gpu-lab ($ACCOUNT_WANT)"
[ ! -e "$OUT" ] || fail "$OUT already exists; each session writes a new directory"
mkdir -p "$OUT" || fail "cannot create $OUT"
say "the engine-readiness preflight for $STUDY_ID, from $COMMIT, into $OUT"
say "hard stop $STOP_FROM_LAUNCH_S s after LaunchTime; worst case $TERMINATION_S s at \$$ALL_IN_RATE/h"

# shellcheck source=hack/lib/spot-run.sh
. hack/lib/spot-run.sh

ami_name=$(aws ec2 describe-images --region "$REGION" --image-ids "$VERSION_READINESS_AMI_ID" \
  --query 'Images[0].[Name,State]' --output text 2>&1) || fail "could not describe $VERSION_READINESS_AMI_ID: $ami_name"
case "$ami_name" in
  "Deep Learning Base OSS Nvidia Driver GPU AMI (Ubuntu 22.04)"*available) ;;
  *) fail "$VERSION_READINESS_AMI_ID is '$ami_name', not an available Deep Learning Base OSS Nvidia Driver GPU AMI (Ubuntu 22.04)" ;;
esac
say "AMI $VERSION_READINESS_AMI_ID: $ami_name"

prices=$(aws ec2 describe-spot-price-history --region "$REGION" --instance-types "$INSTANCE_TYPE_FIXED" \
  --product-descriptions "Linux/UNIX" --start-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --query 'SpotPriceHistory[].[AvailabilityZone,SpotPrice]' --output text 2>&1) || fail "could not read the Spot price: $prices"
printf '%s\n' "$prices" >"$OUT/spot-prices.txt"
ZONES=$(awk -v cap="$MAX_PRICE_FIXED" 'NF == 2 && $2 + 0 > 0 && $2 + 0 <= cap + 0 {print $1}' <<<"$prices" | sort -u | paste -sd' ')
[ -n "$ZONES" ] || fail "no zone offers $INSTANCE_TYPE_FIXED Spot at or under \$$MAX_PRICE_FIXED/h: $(paste -sd' ' <<<"$prices")"
say "Spot $INSTANCE_TYPE_FIXED under \$$MAX_PRICE_FIXED/h in: $ZONES ($(paste -sd' ' <<<"$prices"))"

quota=$(aws service-quotas get-service-quota --region "$REGION" --service-code ec2 --quota-code L-3819A6DF \
  --query 'Quota.Value' --output text 2>&1) || fail "could not read the G and VT Spot quota: $quota"
python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) >= 4 else 1)' "$quota" ||
  fail "the G and VT Spot quota is $quota vCPU and one $INSTANCE_TYPE_FIXED needs 4"

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
    --period 1800 --statistics Sum --query 'Datapoints[].Sum' --output json
}
# Every datapoint is summed: a 30-minute window need not fall in one 1,800 s bucket.
sw_sum() {
  python3 -c 'import json,sys; v=json.loads(sys.argv[1]); assert isinstance(v, list) and all(isinstance(x, (int, float)) for x in v); print(int(sum(v)))' "$1"
}
sw_runs_json=$(sw_metric Invocations 2>&1) || fail "the sweeper's invocations could not be read: $sw_runs_json"
sw_errors_json=$(sw_metric Errors 2>&1) || fail "the sweeper's errors could not be read: $sw_errors_json"
sw_runs=$(sw_sum "$sw_runs_json") || fail "the sweeper's invocations are not a list of sums: $sw_runs_json"
sw_errors=$(sw_sum "$sw_errors_json") || fail "the sweeper's errors are not a list of sums: $sw_errors_json"
[ "$sw_runs" -ge "$SWEEPER_MIN_RUNS" ] && [ "$sw_errors" = 0 ] ||
  fail "the sweeper ran $sw_runs time(s) with $sw_errors error(s) in the last 30 minutes; at least $SWEEPER_MIN_RUNS clean runs are required"
say "the termination sweeper: Active, ENABLED rate(5 minutes), $sw_runs run(s) and $sw_errors error(s) in the last 30 minutes"

# Run twice: here, and again just before the purchase, so a credential that expires during the build is caught first.
cred_check() {
  local cred_json cred_exp cred_left
  cred_json=$(aws configure export-credentials --format process 2>&1) || fail "the CLI could not export the active credential: $cred_json"
  cred_exp=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("Expiration",""))' "$cred_json") ||
    fail "the exported credential is not JSON"
  [ -n "$cred_exp" ] || fail "the exported credential carries no expiry, so it cannot be shown to outlast the session"
  cred_left=$(python3 -c 'import datetime,sys; e=datetime.datetime.fromisoformat(sys.argv[1].replace("Z","+00:00")); print(int((e-datetime.datetime.now(datetime.timezone.utc)).total_seconds()//60))' "$cred_exp")
  [ "$cred_left" -ge "$CRED_MIN_MINUTES" ] ||
    fail "$1: the credentials expire in $cred_left minutes; the session needs $CRED_MIN_MINUTES. Re-authenticate first"
  say "$1: credentials expire in $cred_left minutes"
}
cred_check "before the build"

live=$(aws ec2 describe-instances --region "$REGION" --filters "Name=tag:purpose,Values=$PURPOSE" \
  "Name=instance-state-name,Values=pending,running,shutting-down,stopping,stopped" \
  --query 'Reservations[].Instances[].InstanceId' --output text 2>&1) || fail "could not list earlier instances: $live"
[ -z "$live" ] || fail "an earlier readiness instance is still live ($live); one attempt at a time"

# ---------------------------------------------------------------- what the instance runs
say "building the harness from $COMMIT"
# A static binary, so the instance runs exactly this commit's harness without installing Go.
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o "$OUT/benchharness" ./cmd/benchharness >"$OUT/build.log" 2>&1 ||
  fail "build the harness; see $OUT/build.log"
HARNESS_SHA=$(sha256sum "$OUT/benchharness" | cut -d' ' -f1)
RUN_NONCE=$(python3 -c 'import secrets; print(secrets.token_hex(4))')
RUN_ID="$(basename "$OUT")-$RUN_NONCE"
BUCKET="$STACK-$ACCOUNT"
{
  echo "commit=$COMMIT"
  echo "study=$STUDY_ID"
  echo "ami_id=$VERSION_READINESS_AMI_ID"
  echo "ami_name=$ami_name"
  echo "instance_type=$INSTANCE_TYPE_FIXED"
  echo "max_spot_price=$MAX_PRICE_FIXED"
  echo "all_in_rate=$ALL_IN_RATE"
  echo "harness_sha256=$HARNESS_SHA"
  echo "harness_end_from_launch_s=$HARNESS_END_S"
  echo "stop_from_launch_s=$STOP_FROM_LAUNCH_S"
  echo "termination_from_launch_s=$TERMINATION_S"
  echo "run_id=$RUN_ID"
} >"$OUT/session-provenance.txt"

# The NVIDIA container toolkit set-up, from hack/m5c-gpu-session.sh between two anchors that must each occur once.
bringup_from=$(grep -nx 'export DEBIAN_FRONTEND=noninteractive' hack/m5c-gpu-session.sh | cut -d: -f1 | paste -sd' ')
bringup_to=$(grep -nx 'systemctl restart docker' hack/m5c-gpu-session.sh | cut -d: -f1 | paste -sd' ')
[[ "$bringup_from" =~ ^[0-9]+$ && "$bringup_to" =~ ^[0-9]+$ && "$bringup_from" -lt "$bringup_to" ]] ||
  fail "the toolkit anchors in hack/m5c-gpu-session.sh are not each found once, in order (from '$bringup_from', to '$bringup_to')"
sed -n "${bringup_from},${bringup_to}p" hack/m5c-gpu-session.sh >"$OUT/bringup.sh"

UD="$OUT/user-data.sh"
{
  cat <<'HEAD'
#!/bin/bash
exec > >(tee /var/log/verready.log) 2>&1
set -x
VR_START=$(date +%s)
# The first backstop, armed before anything can fail, counts from the instance's own start; LaunchTime precedes it,
# so the precise one below, armed once LaunchTime is read, always fires first.
( sleep STOP_FROM_LAUNCH_S_PLACEHOLDER; shutdown -h now ) &
BUCKET="BUCKET_PLACEHOLDER"
PREFIX="RUN_ID_PLACEHOLDER"
HARNESS_SHA="HARNESS_SHA_PLACEHOLDER"
COMMIT="COMMIT_PLACEHOLDER"
upload() { aws s3 cp --only-show-errors "$1" "s3://$BUCKET/$PREFIX/$2" || true; }
trap 'upload /var/log/verready.log log.txt; shutdown -h now' EXIT
mkdir -p /src/vr-run /opt/vr || exit 1
aws s3 cp --only-show-errors "s3://$BUCKET/$PREFIX/benchharness" /opt/vr/benchharness || exit 1
[ "$(sha256sum /opt/vr/benchharness | cut -d' ' -f1)" = "$HARNESS_SHA" ] || { echo "harness checksum mismatch"; exit 1; }
chmod +x /opt/vr/benchharness
L=""
while [ $(( $(date +%s) - VR_START )) -lt LAUNCHTIME_WAIT_S_PLACEHOLDER ]; do
  if aws s3 cp --only-show-errors "s3://$BUCKET/$PREFIX/launch-time.txt" /tmp/launch-time.txt; then
    L=$(date -u -d "$(cat /tmp/launch-time.txt)" +%s || true)
    break
  fi
  sleep 5
done
NOW=$(date +%s)
if ! [[ "$L" =~ ^[0-9]+$ ]] || [ "$L" -gt "$NOW" ] || [ $(( NOW - L )) -gt 900 ]; then
  echo "LaunchTime was ${L:-not read} at $NOW"; exit 1
fi
( sleep $(( L + STOP_FROM_LAUNCH_S_PLACEHOLDER - $(date +%s) > 0 ? L + STOP_FROM_LAUNCH_S_PLACEHOLDER - $(date +%s) : 1 )); shutdown -h now ) &
P1=$(( L + BRINGUP_S_PLACEHOLDER )); HE=$(( L + HARNESS_END_S_PLACEHOLDER )); EV=$(( L + EVIDENCE_S_PLACEHOLDER ))
nvidia-smi --query-gpu=index,name,memory.total,driver_version --format=csv > /tmp/nvidia-smi.csv || exit 1
upload /tmp/nvidia-smi.csv preflight-nvidia-smi.csv
[ "$(tail -n +2 /tmp/nvidia-smi.csv | wc -l)" = 1 ] && tail -n +2 /tmp/nvidia-smi.csv | grep -q A10G || { echo "PREFLIGHT FAILED: not one A10G"; exit 1; }
HEAD
  echo "cat > /tmp/bringup.sh <<'BRINGUP'"
  cat "$OUT/bringup.sh"
  echo "sleep 5"
  # The spliced steps do not stop on a failed command, so the bring-up is judged by its outcome before anything is paid for.
  echo 'systemctl is-active --quiet docker || { echo "BRINGUP FAILED: docker is not running"; exit 1; }'
  echo 'docker info --format "{{json .Runtimes}}" | grep -q nvidia || { echo "BRINGUP FAILED: docker has no nvidia runtime"; exit 1; }'
  echo "BRINGUP"
  cat <<'TAIL'
bringup_left=$(( P1 - $(date +%s) ))
bringup_rc=124
if [ "$bringup_left" -gt 0 ]; then
  timeout --kill-after=15 "$bringup_left" bash /tmp/bringup.sh
  bringup_rc=$?
fi
echo "bring-up exited $bringup_rc"
{
  echo "commit=$COMMIT"
  echo "launch_time_epoch=$L"
  echo "bringup_rc=$bringup_rc"
  echo "harness_sha256=$HARNESS_SHA"
} > /src/vr-run/instance-provenance.txt
cp /tmp/nvidia-smi.csv /src/vr-run/nvidia-smi.csv
{ nvidia-smi; nvidia-smi -q; } > /src/vr-run/nvidia-smi.txt 2>&1
{ docker version; docker info; nvidia-ctk --version; } > /src/vr-run/versions.txt 2>&1
if [ "$bringup_rc" = 0 ]; then
  mkdir -p /src/vr-run/readiness
  # The harness's own bounds sum to HE; this timeout only stops a harness that overran them from eating the upload.
  timeout --kill-after=15 $(( HE - $(date +%s) > 5 ? HE - $(date +%s) : 5 )) /opt/vr/benchharness version-readiness \
    -dir /src/vr-run/readiness -hf-cache /opt/vr/hf -compile-cache /opt/vr/compile > /src/vr-run/summary.txt
  harness_rc=$?
  cat /src/vr-run/summary.txt
  echo "harness_rc=$harness_rc" >> /src/vr-run/instance-provenance.txt
  echo "the readiness harness exited $harness_rc"
else
  echo "the bring-up did not finish inside its phase (exit $bringup_rc); nothing else runs" | tee /src/vr-run/VOID
fi
cp /var/log/verready.log /src/vr-run/instance.log
left=$(( EV - $(date +%s) )); [ "$left" -gt 5 ] || left=5
tar -czf /tmp/evidence.tgz -C /src vr-run && timeout "$left" aws s3 cp --only-show-errors /tmp/evidence.tgz "s3://$BUCKET/$PREFIX/evidence.tgz"
upload /var/log/verready.log log.txt
echo "RUN_NONCE_PLACEHOLDER" > /tmp/DONE
upload /tmp/DONE DONE
TAIL
} >"$UD.template"
sed -e "s|BUCKET_PLACEHOLDER|$BUCKET|" -e "s|RUN_ID_PLACEHOLDER|$RUN_ID|" -e "s|HARNESS_SHA_PLACEHOLDER|$HARNESS_SHA|" \
  -e "s|COMMIT_PLACEHOLDER|$COMMIT|" -e "s|RUN_NONCE_PLACEHOLDER|$RUN_NONCE|" \
  -e "s|LAUNCHTIME_WAIT_S_PLACEHOLDER|$LAUNCHTIME_WAIT_S|" -e "s|STOP_FROM_LAUNCH_S_PLACEHOLDER|$STOP_FROM_LAUNCH_S|g" \
  -e "s|BRINGUP_S_PLACEHOLDER|$BRINGUP_S|" -e "s|HARNESS_END_S_PLACEHOLDER|$HARNESS_END_S|" \
  -e "s|EVIDENCE_S_PLACEHOLDER|$EVIDENCE_S|" "$UD.template" >"$UD" || fail "could not render the user-data"
rm -f "$UD.template"
! grep -q '_PLACEHOLDER' "$UD" || fail "the user-data still holds a placeholder: $(grep -o '[A-Z_]*_PLACEHOLDER' "$UD" | sort -u | paste -sd' ')"
[ "$(head -c 2 "$UD")" = '#!' ] || fail "the user-data does not begin with a shebang, so cloud-init would not run it"
bash -n "$UD" || fail "the user-data does not parse"
[ "$(wc -c <"$UD")" -lt 16384 ] || fail "the user-data is $(wc -c <"$UD") bytes, over EC2's 16 KB limit"

# ---------------------------------------------------------------- the purchase
spot_ensure_bucket "$BUCKET" "$REGION" 30 || fail "could not prepare the results bucket $BUCKET"
spot_ensure_profile "$STACK" \
  "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"s3:PutObject\",\"s3:GetObject\"],\"Resource\":\"arn:aws:s3:::$BUCKET/*\"}]}" \
  20 || fail "could not prepare the instance profile $STACK"
aws s3 cp --only-show-errors "$OUT/benchharness" "s3://$BUCKET/$RUN_ID/benchharness" || fail "upload the harness"

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

cred_check "before the purchase"
request_epoch=$(date +%s)
TAG_DEADLINE=$(date -u -d "@$(( request_epoch + TAG_AT_LAUNCH_S ))" +%Y-%m-%dT%H:%M:%SZ)
TAGS="ResourceType=instance,Tags=[{Key=Name,Value=$STACK},{Key=purpose,Value=$PURPOSE},{Key=run,Value=$RUN_NONCE},{Key=study-deadline,Value=$TAG_DEADLINE}]"
say "launching $INSTANCE_TYPE_FIXED Spot (max \$$MAX_PRICE_FIXED/h compute, \$$ALL_IN_RATE/h all in), study-deadline $TAG_DEADLINE -- the instance bills from here"
for z in $ZONES; do
  SUBNET=$(spot_subnet_in_zone "$REGION" "$z") || continue
  token="verready-$RUN_NONCE-$z"
  LAUNCH_UNCERTAIN="$token"; LAUNCH_UNCERTAIN_SUBNET="$SUBNET"
  IID=$(spot_launch "$REGION" "$VERSION_READINESS_AMI_ID" "$INSTANCE_TYPE_FIXED" "$SUBNET" "$STACK" "$MAX_PRICE_FIXED" "$VOLUME_GB" \
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

launch=""
for _ in $(seq 1 12); do
  launch=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$IID" \
    --query 'Reservations[0].Instances[0].[LaunchTime,ImageId]' --output text 2>&1) && [ -n "${launch%%[[:space:]]*}" ] && break
  sleep 5
done
LAUNCH_TIME=$(awk '{print $1}' <<<"$launch")
IMAGE_ID=$(awk '{print $2}' <<<"$launch")
L=$(date -u -d "$LAUNCH_TIME" +%s) || fail "could not read $IID's LaunchTime: $launch"
[ "$IMAGE_ID" = "$VERSION_READINESS_AMI_ID" ] || fail "$IID runs $IMAGE_ID, not the pinned $VERSION_READINESS_AMI_ID"
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
spot_wait_for_marker_until "$REGION" "$BUCKET" "$RUN_ID/DONE" "$IID" $(( L + STOP_FROM_LAUNCH_S )) "$WAIT_INTERVAL_S" "$WAIT_ATTEMPTS" >"$OUT/wait.txt"
wait_rc=$?
say "the wait ended with status $wait_rc ($(cat "$OUT/wait.txt"))"
# The termination wait runs to LaunchTime + TERMINATION_S and no further; one not confirmed by then is reported unconfirmed.
SPOT_TERMINATE_WAIT=$(( L + TERMINATION_S - $(date +%s) ))
[ "$SPOT_TERMINATE_WAIT" -ge 0 ] || SPOT_TERMINATE_WAIT=0
SPOT_TERMINATE_TRIES=$(( SPOT_TERMINATE_WAIT / 5 + 1 ))
export SPOT_TERMINATE_WAIT SPOT_TERMINATE_TRIES
say "waiting up to ${SPOT_TERMINATE_WAIT}s for EC2 to report the instance terminated"
if spot_terminate "$REGION" "$IID"; then
  TERMINATION=confirmed
  echo "terminated $IID" >"$OUT/termination.txt"
else
  TERMINATION=unconfirmed
  echo "TERMINATION UNCONFIRMED for $IID -- terminate it by hand now" | tee "$OUT/termination.txt" >&2
fi
for k in evidence.tgz log.txt preflight-nvidia-smi.csv DONE; do
  aws s3 cp --only-show-errors "s3://$BUCKET/$RUN_ID/$k" "$OUT/$k" 2>>"$OUT/download-errors.txt" || echo "not downloaded: $k" >>"$OUT/download-errors.txt"
done
[ ! -s "$OUT/evidence.tgz" ] || tar -xzf "$OUT/evidence.tgz" -C "$OUT" || echo "the evidence archive did not unpack" >>"$OUT/download-errors.txt"
EVIDENCE=returned
[ -s "$OUT/vr-run/readiness/summary.json" ] || EVIDENCE=missing
{
  echo "evidence=$EVIDENCE"
  echo "termination=$TERMINATION"
} >"$OUT/outcome.txt"
[ ! -s "$OUT/vr-run/summary.txt" ] || cat "$OUT/vr-run/summary.txt"
say "evidence $EVIDENCE (summary at $OUT/vr-run/readiness/summary.json); termination $TERMINATION"
[ "$TERMINATION" = confirmed ] || exit 1
# A paid session whose summary never came back has not delivered what it bought.
[ "$EVIDENCE" = returned ] || exit 1
