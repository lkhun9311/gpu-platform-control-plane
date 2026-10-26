#!/usr/bin/env bash
#
# The GPU fault-reaction session: one g5.2xlarge Spot instance, one attempt, stopped by itself 7,000 s after launch.
#
#   SESSION_CONFIRM=yes AWS_PROFILE=gpu-lab GPU_FAULT_AMI_ID=ami-... bash hack/gpu-fault-session.sh
#
# docs/superpowers/specs/2026-10-27-gpu-fault-reaction-design.md is the registration; this script is the runner it
# names. It is modelled line for line on hack/mps-capability-session.sh and shares what that runner shares: the EC2
# lifecycle from hack/lib/spot-run.sh, and the instance bring-up spliced from hack/m5c-gpu-session.sh between its two
# anchor lines. The cell procedure is hack/lib/gpu-fault.sh, the file the free rehearsal runs, driven on the instance
# by hack/gpu-fault-instance.sh.
#
# THE CLOCK. Every deadline counts from EC2's LaunchTime, read right after the launch and written to the run's S3
# prefix for the instance to read. The instance's phases end at 720, 1,320, 6,520 and 6,820 s after it, its evidence
# at 6,940 s, and it shuts itself down at 7,000 s. The launch carries the termination sweeper's study-deadline tag
# at the request plus 6,940 s, rewritten to LaunchTime plus 6,970 s once LaunchTime is known, so the sweeper cannot
# cut the evidence step.
#
# NOTHING HERE IS A DEFAULT A CALLER CAN MOVE: the registration fixes the instance, the arms and the stop, so each is
# a constant, and a caller who sets one is refused rather than ignored.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

REGION=ap-northeast-2
ACCOUNT_WANT=007635145730
INSTANCE_TYPE_FIXED=g5.2xlarge
# The repository's worst-case rate for this instance: Spot cap $1.10, 200 GB gp3, a public IPv4
# (docs/superpowers/specs/2026-10-08-measuring-prospective-admission-design.md).
MAX_PRICE_FIXED=1.1324
STUDY_ID=gpu-fault-2026-10-27
STACK=gpufault-gpu
PURPOSE=gpu-fault
TAG_AT_LAUNCH_S=6940
TAG_FROM_LAUNCH_S=6970
STOP_FROM_LAUNCH_S=7000
PHASE_BRINGUP_S=720
PHASE_PLATFORM_S=1320
PHASE_ARMS_S=6520
PHASE_CHECKS_S=6820
EVIDENCE_S=6940
TERMINATION_S=7300
LAUNCHTIME_WAIT_S=180
SWEEPER_MIN_RUNS=4
# The session's end of the termination wait plus 30 minutes of headroom, in minutes.
CRED_MIN_MINUTES=155
TAG=gpufault
# A single-platform local rebuild of busybox:1.36, because kind's image import refuses the multi-platform original.
JOB_BASE=busybox:1.36
JOB_IMAGE=gpufault-job:busybox

OUT="${OUT:-hack/gpu-fault-$(date -u +%Y%m%dT%H%M%SZ)}"
say() { echo "== $*" | { if [ -d "$OUT" ]; then tee -a "$OUT/session.log"; else cat; fi; }; }
fail() { echo "SESSION REFUSED: $*" | { if [ -d "$OUT" ]; then tee -a "$OUT/session.log"; else cat; fi; } >&2; exit 1; }
spot_say() { say "$@"; }
spot_fail() { fail "$@"; }

# ---------------------------------------------------------------- refusals, before anything is built or bought
for v in GF_BLOCKS GF_ARMS_END GF_MODE INSTANCE_TYPE MAX_SPOT_PRICE HARD_STOP_SECONDS REPS ARMS; do
  [ -z "${!v:-}" ] || fail "$v is set, and this session's value for it is its registration's; unset it"
done
[ "${SESSION_CONFIRM:-}" = yes ] || fail "SESSION_CONFIRM=yes is required: this buys a GPU instance, and only the owner's approval starts one"
[[ "${GPU_FAULT_AMI_ID:-}" =~ ^ami-[0-9a-f]{8,17}$ ]] ||
  fail "GPU_FAULT_AMI_ID is ${GPU_FAULT_AMI_ID:-unset}; the registration pins the AMI by ID rather than resolving it from latest"
for tool in aws go python3 git tar sha256sum docker make gzip; do command -v "$tool" >/dev/null || fail "$tool is not installed"; done
[ -z "$(git status --porcelain)" ] || fail "the working tree is dirty; the run's provenance is a commit, and the images are built from this tree"
COMMIT=$(git rev-parse HEAD)
ACCOUNT=$(aws sts get-caller-identity --query Account --output text 2>&1) || fail "could not read the caller's account: $ACCOUNT"
[ "$ACCOUNT" = "$ACCOUNT_WANT" ] || fail "the credentials are for account $ACCOUNT; paid sessions run only in gpu-lab ($ACCOUNT_WANT)"
[ ! -e "$OUT" ] || fail "$OUT already exists; each session writes a new directory"
mkdir -p "$OUT" || fail "cannot create $OUT"
say "the GPU fault-reaction session, $STUDY_ID, from $COMMIT, into $OUT"

# shellcheck source=hack/lib/spot-run.sh
. hack/lib/spot-run.sh

ami_name=$(aws ec2 describe-images --region "$REGION" --image-ids "$GPU_FAULT_AMI_ID" \
  --query 'Images[0].[Name,State]' --output text 2>&1) || fail "could not describe $GPU_FAULT_AMI_ID: $ami_name"
case "$ami_name" in
  "Deep Learning Base OSS Nvidia Driver GPU AMI (Ubuntu 22.04)"*available) ;;
  *) fail "$GPU_FAULT_AMI_ID is '$ami_name', not an available Deep Learning Base OSS Nvidia Driver GPU AMI (Ubuntu 22.04)" ;;
esac
say "AMI $GPU_FAULT_AMI_ID: $ami_name"

prices=$(aws ec2 describe-spot-price-history --region "$REGION" --instance-types "$INSTANCE_TYPE_FIXED" \
  --product-descriptions "Linux/UNIX" --start-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --query 'SpotPriceHistory[].[AvailabilityZone,SpotPrice]' --output text 2>&1) || fail "could not read the Spot price: $prices"
printf '%s\n' "$prices" >"$OUT/spot-prices.txt"
ZONES=$(awk -v cap="$MAX_PRICE_FIXED" 'NF == 2 && $2 + 0 > 0 && $2 + 0 <= cap + 0 {print $1}' <<<"$prices" | sort -u | paste -sd' ')
[ -n "$ZONES" ] || fail "no zone offers $INSTANCE_TYPE_FIXED Spot at or under \$$MAX_PRICE_FIXED/h: $(paste -sd' ' <<<"$prices")"
say "Spot $INSTANCE_TYPE_FIXED under \$$MAX_PRICE_FIXED/h in: $ZONES ($(paste -sd' ' <<<"$prices"))"

quota=$(aws service-quotas get-service-quota --region "$REGION" --service-code ec2 --quota-code L-3819A6DF \
  --query 'Quota.Value' --output text 2>&1) || fail "could not read the G and VT Spot quota: $quota"
python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) >= 8 else 1)' "$quota" ||
  fail "the G and VT Spot quota is $quota vCPU and one $INSTANCE_TYPE_FIXED needs 8"

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
  "$sw_runs" "$sw_errors" "$SWEEPER_MIN_RUNS" ||
  fail "the sweeper ran $sw_runs time(s) with $sw_errors error(s) in the last 30 minutes; at least $SWEEPER_MIN_RUNS clean runs are required"
say "the termination sweeper: Active, ENABLED rate(5 minutes), $sw_runs run(s) and ${sw_errors/None/0} error(s) in the last 30 minutes"

cred_json=$(aws configure export-credentials --format process 2>&1) || fail "the CLI could not export the active credential: $cred_json"
cred_exp=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("Expiration",""))' "$cred_json") ||
  fail "the exported credential is not JSON"
[ -n "$cred_exp" ] || fail "the exported credential carries no expiry, so it cannot be shown to outlast the session"
cred_left=$(python3 -c 'import datetime,sys; e=datetime.datetime.fromisoformat(sys.argv[1].replace("Z","+00:00")); print(int((e-datetime.datetime.now(datetime.timezone.utc)).total_seconds()//60))' "$cred_exp")
[ "$cred_left" -ge "$CRED_MIN_MINUTES" ] ||
  fail "the credentials expire in $cred_left minutes; the session needs $CRED_MIN_MINUTES. Re-authenticate first"
say "credentials expire in $cred_left minutes"

live=$(aws ec2 describe-instances --region "$REGION" --filters "Name=tag:purpose,Values=$PURPOSE" \
  "Name=instance-state-name,Values=pending,running,shutting-down,stopping,stopped" \
  --query 'Reservations[].Instances[].InstanceId' --output text 2>&1) || fail "could not list earlier instances: $live"
[ -z "$live" ] || fail "an earlier fault-reaction instance is still live ($live); one attempt is registered"

# ---------------------------------------------------------------- what the instance runs
say "building the operator, the simulator and the scorer from $COMMIT"
make docker-build IMG=controller:$TAG >"$OUT/build.log" 2>&1 || fail "operator image; see $OUT/build.log"
make docker-build-gpu-simulator GPU_SIMULATOR_IMG=gpu-simulator:$TAG >>"$OUT/build.log" 2>&1 || fail "simulator image; see $OUT/build.log"
docker pull "$JOB_BASE" >>"$OUT/build.log" 2>&1 || fail "could not pull $JOB_BASE"
printf 'FROM %s\n' "$JOB_BASE" | docker build -q -t "$JOB_IMAGE" - >>"$OUT/build.log" 2>&1 || fail "could not build $JOB_IMAGE"
mkdir -p "$OUT/images" || fail "mkdir images"
for pair in controller:$TAG:controller gpu-simulator:$TAG:gpu-simulator "$JOB_IMAGE:job"; do
  img=${pair%:*} name=${pair##*:}
  # Single-platform: a multi-platform index in the archive makes the kind node's import fail (rehearsal, 2026-10-26).
  docker save --platform linux/amd64 "$img" | gzip -1 >"$OUT/images/$name.tar.gz" || fail "could not save $img"
done
go build -o "$OUT/benchharness-local" ./cmd/benchharness || fail "build the local scorer"
git archive --format=tar.gz -o "$OUT/source.tgz" HEAD || fail "git archive"
SOURCE_SHA=$(sha256sum "$OUT/source.tgz" | cut -d' ' -f1)
IMAGES_SHA=$(cd "$OUT/images" && sha256sum controller.tar.gz gpu-simulator.tar.gz job.tar.gz | sha256sum | cut -d' ' -f1)
RUN_NONCE=$(python3 -c 'import secrets; print(secrets.token_hex(4))')
RUN_ID="$(basename "$OUT")-$RUN_NONCE"
BUCKET="$STACK-$ACCOUNT"
{
  echo "commit=$COMMIT"
  echo "study=$STUDY_ID"
  echo "ami_id=$GPU_FAULT_AMI_ID"
  echo "ami_name=$ami_name"
  echo "instance_type=$INSTANCE_TYPE_FIXED"
  echo "max_spot_price=$MAX_PRICE_FIXED"
  echo "source_sha256=$SOURCE_SHA"
  echo "images_sha256=$IMAGES_SHA"
  for name in controller gpu-simulator job; do echo "image_$name=$(sha256sum "$OUT/images/$name.tar.gz" | cut -d' ' -f1)"; done
  echo "run_id=$RUN_ID"
} >"$OUT/session-provenance.txt"

bringup_from=$(grep -nx 'export DEBIAN_FRONTEND=noninteractive' hack/m5c-gpu-session.sh | cut -d: -f1 | paste -sd' ')
bringup_to=$(grep -nx 'upload /tmp/node-cards.txt preflight-node-cards.txt' hack/m5c-gpu-session.sh | cut -d: -f1 | paste -sd' ')
[[ "$bringup_from" =~ ^[0-9]+$ && "$bringup_to" =~ ^[0-9]+$ && "$bringup_from" -lt "$bringup_to" ]] ||
  fail "the bring-up anchors in hack/m5c-gpu-session.sh are not each found once, in order (from '$bringup_from', to '$bringup_to')"
sed -n "${bringup_from},${bringup_to}p" hack/m5c-gpu-session.sh >"$OUT/bringup.sh"

UD="$OUT/user-data.sh"
{
  cat <<'HEAD'
#!/bin/bash
exec > >(tee /var/log/gpufault.log) 2>&1
set -x
GF_START=$(date +%s)
# The first backstop, armed before anything can fail, counts from the instance's own start; LaunchTime precedes it,
# so the precise one below, armed once LaunchTime is read, always fires first.
( sleep STOP_FROM_LAUNCH_S_PLACEHOLDER; shutdown -h now ) &
BUCKET="BUCKET_PLACEHOLDER"
PREFIX="RUN_ID_PLACEHOLDER"
SOURCE_SHA="SOURCE_SHA_PLACEHOLDER"
IMAGES_SHA="IMAGES_SHA_PLACEHOLDER"
COMMIT="COMMIT_PLACEHOLDER"
upload() { aws s3 cp --only-show-errors "$1" "s3://$BUCKET/$PREFIX/$2" || true; }
trap 'upload /var/log/gpufault.log log.txt; shutdown -h now' EXIT
aws s3 cp --only-show-errors "s3://$BUCKET/$PREFIX/src/source.tgz" /tmp/source.tgz
[ "$(sha256sum /tmp/source.tgz | cut -d' ' -f1)" = "$SOURCE_SHA" ] || { echo "source checksum mismatch"; exit 1; }
mkdir -p /src && tar -xzf /tmp/source.tgz -C /src && cd /src || exit 1
mkdir -p /src/images /src/gf-run
for n in controller gpu-simulator job; do aws s3 cp --only-show-errors "s3://$BUCKET/$PREFIX/images/$n.tar.gz" "/src/images/$n.tar.gz"; done
[ "$(cd /src/images && sha256sum controller.tar.gz gpu-simulator.tar.gz job.tar.gz | sha256sum | cut -d' ' -f1)" = "$IMAGES_SHA" ] ||
  { echo "image checksum mismatch"; exit 1; }
L=""
while [ $(( $(date +%s) - GF_START )) -lt LAUNCHTIME_WAIT_S_PLACEHOLDER ]; do
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
P1=$(( L + PHASE_BRINGUP_S_PLACEHOLDER )); P2=$(( L + PHASE_PLATFORM_S_PLACEHOLDER )); P3=$(( L + PHASE_ARMS_S_PLACEHOLDER )); P4=$(( L + PHASE_CHECKS_S_PLACEHOLDER )); EV=$(( L + EVIDENCE_S_PLACEHOLDER ))
nvidia-smi --query-gpu=index,name,memory.total,driver_version --format=csv > /tmp/nvidia-smi.csv || exit 1
upload /tmp/nvidia-smi.csv preflight-nvidia-smi.csv
[ "$(tail -n +2 /tmp/nvidia-smi.csv | wc -l)" = 1 ] && tail -n +2 /tmp/nvidia-smi.csv | grep -q A10G || { echo "PREFLIGHT FAILED: not one A10G"; exit 1; }
HEAD
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
{
  echo "commit=$COMMIT"
  echo "launch_time_epoch=$L"
  echo "driver=$(tail -n +2 /tmp/nvidia-smi.csv | cut -d, -f4 | tr -d ' ')"
  echo "bringup_rc=$bringup_rc"
} > /src/gf-run/instance-provenance.txt
if [ "$bringup_rc" = 0 ]; then
  export KUBECONFIG=/tmp/kubeconfig GF_PLATFORM_END="$P2" GF_ARMS_END="$P3" GF_CHECKS_END="$P4" GF_OUT=/src/gf-run
  timeout --kill-after=15 $(( EV - $(date +%s) > 5 ? EV - $(date +%s) : 5 )) bash hack/gpu-fault-instance.sh
  echo "the instance procedure exited $?"
else
  echo "the bring-up did not finish inside its phase (exit $bringup_rc); nothing else runs" | tee /src/gf-run/VOID
fi
left=$(( EV + 50 - $(date +%s) )); [ "$left" -gt 5 ] || left=5
tar -czf /tmp/evidence.tgz -C /src gf-run && timeout "$left" aws s3 cp --only-show-errors /tmp/evidence.tgz "s3://$BUCKET/$PREFIX/evidence.tgz"
upload /var/log/gpufault.log log.txt
echo "RUN_NONCE_PLACEHOLDER" > /tmp/DONE
upload /tmp/DONE DONE
TAIL
} >"$UD.template"
sed -e "s|BUCKET_PLACEHOLDER|$BUCKET|" -e "s|RUN_ID_PLACEHOLDER|$RUN_ID|" -e "s|SOURCE_SHA_PLACEHOLDER|$SOURCE_SHA|" \
  -e "s|IMAGES_SHA_PLACEHOLDER|$IMAGES_SHA|" -e "s|COMMIT_PLACEHOLDER|$COMMIT|" -e "s|RUN_NONCE_PLACEHOLDER|$RUN_NONCE|" \
  -e "s|LAUNCHTIME_WAIT_S_PLACEHOLDER|$LAUNCHTIME_WAIT_S|" -e "s|STOP_FROM_LAUNCH_S_PLACEHOLDER|$STOP_FROM_LAUNCH_S|g" \
  -e "s|PHASE_BRINGUP_S_PLACEHOLDER|$PHASE_BRINGUP_S|" -e "s|PHASE_PLATFORM_S_PLACEHOLDER|$PHASE_PLATFORM_S|" \
  -e "s|PHASE_ARMS_S_PLACEHOLDER|$PHASE_ARMS_S|" -e "s|PHASE_CHECKS_S_PLACEHOLDER|$PHASE_CHECKS_S|" \
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
aws s3 cp --only-show-errors "$OUT/source.tgz" "s3://$BUCKET/$RUN_ID/src/source.tgz" || fail "upload source"
for name in controller gpu-simulator job; do
  aws s3 cp --only-show-errors "$OUT/images/$name.tar.gz" "s3://$BUCKET/$RUN_ID/images/$name.tar.gz" || fail "upload $name image"
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
  token="gpufault-$RUN_NONCE-$z"
  LAUNCH_UNCERTAIN="$token"; LAUNCH_UNCERTAIN_SUBNET="$SUBNET"
  IID=$(spot_launch "$REGION" "$GPU_FAULT_AMI_ID" "$INSTANCE_TYPE_FIXED" "$SUBNET" "$STACK" "$MAX_PRICE_FIXED" 200 \
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
[ "$IMAGE_ID" = "$GPU_FAULT_AMI_ID" ] || fail "$IID runs $IMAGE_ID, not the pinned $GPU_FAULT_AMI_ID"
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
SPOT_TERMINATE_WAIT=$(( L + TERMINATION_S - $(date +%s) ))
[ "$SPOT_TERMINATE_WAIT" -ge 300 ] || SPOT_TERMINATE_WAIT=300
SPOT_TERMINATE_TRIES=$(( SPOT_TERMINATE_WAIT / 5 + 1 ))
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
if [ -d "$OUT/gf-run" ]; then
  "$OUT/benchharness-local" gpu-fault-verdict --dir "$OUT/gf-run" --json "$OUT/verdict.json" | tee "$OUT/verdict.txt"
else
  echo "GPU FAULT REACTION: NO-EVIDENCE (the evidence archive did not come back)" | tee "$OUT/verdict.txt"
fi
echo "termination=$TERMINATION" >>"$OUT/verdict.txt"
say "the verdict is in $OUT/verdict.txt and the evidence in $OUT/gf-run"
[ "$TERMINATION" = confirmed ] || exit 1
