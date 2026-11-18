#!/usr/bin/env bash
#
# The vLLM #67811 adaptive-prefill measurement: one g5.xlarge Spot instance, one attempt, stopped by itself 13,140 s after
# launch.
#
#   SESSION_CONFIRM=yes AWS_PROFILE=gpu-lab VLLM67811_AMI_ID=ami-... bash hack/vllm-67811-session.sh
#
# PR #67811 (draft) adds an opt-in prefill time budget, --adaptive-prefill. Its author says the next required gate is a
# real GPU run of benchmarks/adaptive_prefill/serve.py, baseline against the flag, on identical hardware, model,
# budgets and arrival traces. The owner approved one paid session on 2026-11-18.
# On the instance it runs only hack/vllm-67811/runner.sh: the pull of vLLM CI's image of the PR's merge base, a check
# that the image ships the merge base's files, the model download, then six fresh engines in the order base, adaptive,
# t512, t512, adaptive, base. Each runs the PR's serve.py once as an unscored warm-up and five times scored, under
# the seeds 62574 to 62578 that every engine shares.
# t512 is the base engine with --long-prefill-token-threshold 512, to show what a smaller fixed chunk alone does.
# It shares its EC2 lifecycle with hack/vllm-58420-session.sh (hack/lib/spot-run.sh).
#
# THE BUILD.
# The PR changes seven Python files of the package and no compiled code. The engine is
# public.ecr.aws/q9t5s3a7/vllm-ci-postmerge-repo at the merge base 71c35414, pinned by digest, with the seven head files
# (4053e4e4) mounted read-only over the installed ones.
# This script fetches them, serve.py and compare.py from GitHub before anything is bought and refuses any whose hash is
# not the one pinned in hack/vllm-67811/runner.sh.
# Prefix caching is off in every engine: the scored runs repeat the same seeds, so a cache would serve the long prompts.
# hack/vllm-67811/probe/sitecustomize.py records what the controller is fed, since the PR logs nothing about it.
#
# THE CLOCK.
# Every deadline counts from EC2's LaunchTime, read right after the launch and written to the run's S3 prefix for the
# instance to read.
# The work is bounded step by step, and the deadlines are their sum:
#   bring-up (boot, cloud-init, downloads, toolkit)                       600 s -> 600
#   image pull                                                           2,400 s
#   base identity                                                          300 s
#   model download                                                         900 s
#   six engines, each ready 450 + identity 60 + metrics 2 x 10 + warm-up 150 + five runs 5 x 150 + stop 30 = 1,460 s
#                                                               6 x 1,460 = 8,760 s
#   so the runner ends by 600 + 2,400 + 300 + 900 + 8,760               = 12,960 s
#   evidence upload                                                        120 s -> 13,080
# The launch carries the termination sweeper's study-deadline tag at the request plus 13,080 s, rewritten to LaunchTime
# plus 13,110 s once LaunchTime is known; the instance shuts itself down at 13,140 s; the termination is to be
# confirmed by 13,440 s, the sweeper's five-minute period after its tag plus 30 s.
#
# THE COST.
# The worst case bills to the termination deadline: 13,440 s = 3.7333 h.
# At the $0.70/h Spot cap below that is $2.6133 of compute.
# The other sessions add $0.0324/h for 200 GB gp3 and a public IPv4 (hack/gpu-fault-session.sh).
# Like the #58420 session, this one provisions the volume to 500 MiB/s and 6,000 IOPS, which cut that study's pull from
# over 1,500 s to about 800 s; at Seoul's $0.0456 per MiB/s-month and $0.0057 per IOPS-month over 730 h that adds
# 375 x 0.0456 / 730 + 3,000 x 0.0057 / 730 = $0.0468/h.
# So it is $0.7792/h all in, and $2.909, under $3.
# The script refuses to run if the constants below stop giving a worst case under $3.
#
# NOTHING HERE IS A DEFAULT A CALLER CAN MOVE: the instance, the build, the arms, the bounds and the stop are constants,
# and a caller who sets one is refused rather than ignored.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

REGION=ap-northeast-2
ACCOUNT_WANT=007635145730
INSTANCE_TYPE_FIXED=g5.xlarge
# g5.xlarge Spot was $0.61/h in ap-northeast-2 on 2026-11-16, and a zone above the cap is not used.
MAX_PRICE_FIXED=0.70
# The cap, plus 200 GB gp3 and a public IPv4 ($0.0324/h), plus the provisioned throughput and IOPS ($0.0468/h).
ALL_IN_RATE=0.7792
EBS_THROUGHPUT_MIBPS=500
EBS_IOPS=6000
COST_CAP_USD=3.00
STUDY_ID=vllm-67811-adaptive-prefill-2026-11-18
STACK=ap67811-gpu
PURPOSE=vllm-67811-adaptive-prefill
# The PR head; every file fetched from it is checked against the hashes pinned in the runner.
PR_COMMIT=4053e4e4c2f83b7f431c40ac38ad769e928b1595
RAW="https://raw.githubusercontent.com/vllm-project/vllm/$PR_COMMIT"
RUNNER=hack/vllm-67811/runner.sh
PROBE=hack/vllm-67811/probe/sitecustomize.py
BENCH_FILES="benchmarks/adaptive_prefill/serve.py fac101e873a45938085d6c491d04a19adc8d3c0d69e0ac54d66ddbe923046cf1
benchmarks/adaptive_prefill/compare.py 2c9db66ae0b6589794163ca0a62299b5229d502439a27cf3cdf521d58911c9fd"
# The step bounds, each the runner's own; hack/vllm-67811-session-test.sh holds the two equal.
BRINGUP_S=600
PULL_BOUND_S=2400
BASE_ID_S=300
MODEL_BOUND_S=900
READY_S=450
ID_S=60
METRICS_S=10
WARMUP_S=150
RUN_S=150
RUNS=5
STOP_S=30
ENGINES=6
EVIDENCE_UPLOAD_S=120
ENGINE_S=$(( READY_S + ID_S + 2 * METRICS_S + WARMUP_S + RUNS * RUN_S + STOP_S ))
HARNESS_END_S=$(( BRINGUP_S + PULL_BOUND_S + BASE_ID_S + MODEL_BOUND_S + ENGINES * ENGINE_S ))
EVIDENCE_S=$(( HARNESS_END_S + EVIDENCE_UPLOAD_S ))
TAG_AT_LAUNCH_S=$EVIDENCE_S
TAG_FROM_LAUNCH_S=$(( EVIDENCE_S + 30 ))
STOP_FROM_LAUNCH_S=$(( EVIDENCE_S + 60 ))
TERMINATION_S=$(( TAG_FROM_LAUNCH_S + 330 ))
LAUNCHTIME_WAIT_S=180
# How often the instance copies the sweep's records to S3 while the harness runs.
PARTIAL_SYNC_S=30
# The DONE wait polls every WAIT_INTERVAL_S and every poll sleeps that long, so this many attempts outlast the stop and
# the wall-clock deadline, not the count, ends the wait.
WAIT_INTERVAL_S=20
WAIT_ATTEMPTS=$(( STOP_FROM_LAUNCH_S / WAIT_INTERVAL_S + 2 ))
SWEEPER_MIN_RUNS=4
# The session's end of the termination wait plus 30 minutes of headroom, in minutes.
CRED_MIN_MINUTES=$(( TERMINATION_S / 60 + 30 ))
VOLUME_GB=200

OUT="${OUT:-hack/vllm-67811-$(date -u +%Y%m%dT%H%M%SZ)}"
say() { echo "== $*" | { if [ -d "$OUT" ]; then tee -a "$OUT/session.log"; else cat; fi; }; }
fail() { echo "SESSION REFUSED: $*" | { if [ -d "$OUT" ]; then tee -a "$OUT/session.log"; else cat; fi; } >&2; exit 1; }
spot_say() { say "$@"; }
spot_fail() { fail "$@"; }

# ---------------------------------------------------------------- refusals, before anything is built or bought
for v in INSTANCE_TYPE MAX_SPOT_PRICE HARD_STOP_SECONDS BACKSTOP_SECONDS IMAGE VLLM_IMAGE ARMS_OVERRIDE ARM_ORDER \
  ADAPTIVE_PREFILL LONG_PREFILL_TOKEN_THRESHOLD SEED SEEDS PULL_BOUND MODEL_BOUND PR_COMMIT_OVERRIDE; do
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
[[ "${VLLM67811_AMI_ID:-}" =~ ^ami-[0-9a-f]{8,17}$ ]] ||
  fail "VLLM67811_AMI_ID is ${VLLM67811_AMI_ID:-unset}; the session pins the AMI by ID rather than resolving it from latest"
for tool in aws python3 git tar sha256sum curl; do command -v "$tool" >/dev/null || fail "$tool is not installed"; done
[ -z "$(git status --porcelain)" ] || fail "the working tree is dirty; the run's provenance is a commit, and the runner is shipped from this tree"
COMMIT=$(git rev-parse HEAD)
ACCOUNT=$(aws sts get-caller-identity --query Account --output text 2>&1) || fail "could not read the caller's account: $ACCOUNT"
[ "$ACCOUNT" = "$ACCOUNT_WANT" ] || fail "the credentials are for account $ACCOUNT; paid sessions run only in gpu-lab ($ACCOUNT_WANT)"
[ ! -e "$OUT" ] || fail "$OUT already exists; each session writes a new directory"
mkdir -p "$OUT" || fail "cannot create $OUT"
say "the vLLM #67811 adaptive-prefill measurement for $STUDY_ID, from $COMMIT, into $OUT"
say "hard stop $STOP_FROM_LAUNCH_S s after LaunchTime; worst case $TERMINATION_S s at \$$ALL_IN_RATE/h"

# The PR head's files, fetched and checked before anything is bought, so a moved or rewritten file costs nothing.
# The seven overlays' hashes are the runner's own, so the instance checks exactly what was checked here.
mkdir -p "$OUT/in/ovl" "$OUT/in/bench" "$OUT/in/probe" || fail "cannot create $OUT/in"
while read -r path sum _; do
  dest="$OUT/in/ovl/$path"; case $path in benchmarks/*) dest="$OUT/in/bench/$(basename "$path")" ;; esac
  mkdir -p "$(dirname "$dest")"
  curl -fsSL --max-time 60 -o "$dest" "$RAW/$path" 2>>"$OUT/fetch.err" || fail "could not fetch $path from the PR head; see $OUT/fetch.err"
  [ "$(sha256sum "$dest" | cut -d' ' -f1)" = "$sum" ] || fail "$path at the PR head is not the pinned $sum"
done < <(sed -n '/^OVERLAYS="/,/"$/p' "$RUNNER" | sed 's/^OVERLAYS="//; s/"$//'; printf '%s\n' "$BENCH_FILES")
[ "$(find "$OUT/in/ovl" -type f | wc -l)" = 7 ] && [ "$(find "$OUT/in/bench" -type f | wc -l)" = 2 ] ||
  fail "expected seven overlay files and two benchmark files"
cp "$RUNNER" "$OUT/in/runner.sh" && cp "$PROBE" "$OUT/in/probe/sitecustomize.py" || fail "copy the runner and the probe"
tar -czf "$OUT/inputs.tgz" -C "$OUT/in" . || fail "pack the inputs"
say "the PR head's seven files, serve.py and compare.py match their pinned hashes"

# shellcheck source=hack/lib/spot-run.sh
. hack/lib/spot-run.sh

ami_name=$(aws ec2 describe-images --region "$REGION" --image-ids "$VLLM67811_AMI_ID" \
  --query 'Images[0].[Name,State]' --output text 2>&1) || fail "could not describe $VLLM67811_AMI_ID: $ami_name"
case "$ami_name" in
  "Deep Learning Base OSS Nvidia Driver GPU AMI (Ubuntu 22.04)"*available) ;;
  *) fail "$VLLM67811_AMI_ID is '$ami_name', not an available Deep Learning Base OSS Nvidia Driver GPU AMI (Ubuntu 22.04)" ;;
esac
say "AMI $VLLM67811_AMI_ID: $ami_name"

prices=$(aws ec2 describe-spot-price-history --region "$REGION" --instance-types "$INSTANCE_TYPE_FIXED" \
  --product-descriptions "Linux/UNIX" --start-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --query 'SpotPriceHistory[].[AvailabilityZone,SpotPrice]' --output text 2>&1) || fail "could not read the Spot price: $prices"
printf '%s\n' "$prices" >"$OUT/spot-prices.txt"
ZONES=$(awk -v cap="$MAX_PRICE_FIXED" 'NF == 2 && $2 + 0 > 0 && $2 + 0 <= cap + 0 {print $1}' <<<"$prices" | sort -u | paste -sd' ')
[ -n "$ZONES" ] || fail "no zone offers $INSTANCE_TYPE_FIXED Spot at or under \$$MAX_PRICE_FIXED/h: $(paste -sd' ' <<<"$prices")"
# The #58420 study's run 7 was reclaimed in ap-northeast-2a for want of Spot capacity, 15 minutes in.
# A zone that reclaimed a study is tried after the others, and still tried if they have no capacity.
RECLAIMED_ZONES="ap-northeast-2a"
ZONES=$(for z in $ZONES; do case " $RECLAIMED_ZONES " in *" $z "*) ;; *) echo "$z" ;; esac; done
  for z in $ZONES; do case " $RECLAIMED_ZONES " in *" $z "*) echo "$z" ;; esac; done)
ZONES=$(paste -sd' ' <<<"$ZONES")
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
[ -z "$live" ] || fail "an earlier instance of this session is still live ($live); one attempt at a time"

# ---------------------------------------------------------------- what the instance runs
INPUTS_SHA=$(sha256sum "$OUT/inputs.tgz" | cut -d' ' -f1)
RUN_NONCE=$(python3 -c 'import secrets; print(secrets.token_hex(4))')
RUN_ID="$(basename "$OUT")-$RUN_NONCE"
BUCKET="$STACK-$ACCOUNT"
{
  echo "commit=$COMMIT"
  echo "study=$STUDY_ID"
  echo "ami_id=$VLLM67811_AMI_ID"
  echo "ami_name=$ami_name"
  echo "instance_type=$INSTANCE_TYPE_FIXED"
  echo "max_spot_price=$MAX_PRICE_FIXED"
  echo "all_in_rate=$ALL_IN_RATE"
  echo "inputs_sha256=$INPUTS_SHA"
  echo "pr_commit=$PR_COMMIT"
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
exec > >(tee /var/log/ap.log) 2>&1
set -x
SR_START=$(date +%s)
# The first backstop, armed before anything can fail, counts from the instance's own start; LaunchTime precedes it,
# so the precise one below, armed once LaunchTime is read, always fires first.
( sleep STOP_FROM_LAUNCH_S_PLACEHOLDER; shutdown -h now ) &
BUCKET="BUCKET_PLACEHOLDER"
PREFIX="RUN_ID_PLACEHOLDER"
COMMIT="COMMIT_PLACEHOLDER"
upload() { aws s3 cp --only-show-errors "$1" "s3://$BUCKET/$PREFIX/$2" || true; }
trap 'upload /var/log/ap.log log.txt; shutdown -h now' EXIT
mkdir -p /src/ap-run /opt/ap || exit 1
# Each input is fetched and checked against the hash this session computed, so the instance runs only what was built and fetched here.
fetch() {
  aws s3 cp --only-show-errors "s3://$BUCKET/$PREFIX/$1" "/opt/ap/$1" || exit 1
  [ "$(sha256sum "/opt/ap/$1" | cut -d' ' -f1)" = "$2" ] || { echo "checksum mismatch for $1"; exit 1; }
}
fetch inputs.tgz INPUTS_SHA_PLACEHOLDER
mkdir -p /opt/ap/in && tar -xzf /opt/ap/inputs.tgz -C /opt/ap/in || exit 1
L=""
while [ $(( $(date +%s) - SR_START )) -lt LAUNCHTIME_WAIT_S_PLACEHOLDER ]; do
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
  sha256sum /opt/ap/inputs.tgz
} > /src/ap-run/instance-provenance.txt
cp /tmp/nvidia-smi.csv /src/ap-run/nvidia-smi.csv
{ nvidia-smi; nvidia-smi -q; } > /src/ap-run/nvidia-smi.txt 2>&1
{ docker version; docker info; nvidia-ctk --version; } > /src/ap-run/versions.txt 2>&1
if [ "$bringup_rc" = 0 ]; then
  # An authenticated pull gets ECR Public's higher limits; a failed login is recorded and the pull goes on anonymously.
  { aws ecr-public get-login-password --region us-east-1 | docker login --username AWS --password-stdin public.ecr.aws; } \
    > /src/ap-run/ecr-login.txt 2>&1 || echo "ECR Public login failed; the pull runs anonymously" >> /src/ap-run/ecr-login.txt
  mkdir -p /src/ap-run/sweep
  # A Spot reclaim gives two minutes, so each arm's records leave the instance within PARTIAL_SYNC_S of being written.
  # One archive overwritten in place needs only the role's s3:PutObject; a sync would also need s3:ListBucket.
  # GNU tar exits 1 when a file grew while it was read, which the live replay rows always do, so 1 still uploads.
  # The copy runs at the lowest CPU and I/O priority, beside the replay client it shares the host with.
  # Each upload is bounded, so a stalled one cannot stop every later copy.
  ( while :; do
      nice -n 19 ionice -c3 tar --warning=no-file-changed -czf /tmp/partial.tgz -C /src/ap-run sweep >>/var/log/ap-sync.log 2>&1
      [ $? -le 1 ] && timeout 60 nice -n 19 aws s3 cp --only-show-errors /tmp/partial.tgz "s3://$BUCKET/$PREFIX/partial.tgz" >>/var/log/ap-sync.log 2>&1
      sleep PARTIAL_SYNC_S_PLACEHOLDER
    done ) &
  sync_pid=$!
  # The runner's own bounds sum to HE; this timeout only stops a runner that overran them from eating the upload.
  timeout --kill-after=15 $(( HE - $(date +%s) > 5 ? HE - $(date +%s) : 5 )) bash /opt/ap/in/runner.sh /opt/ap/in /src/ap-run/sweep "$HE" \
    > /src/ap-run/summary.txt 2>&1
  harness_rc=$?
  kill "$sync_pid" 2>>/var/log/ap-sync.log
  cp /var/log/ap-sync.log /src/ap-run/sync.log
  cat /src/ap-run/summary.txt
  echo "harness_rc=$harness_rc" >> /src/ap-run/instance-provenance.txt
  echo "the runner exited $harness_rc"
else
  echo "the bring-up did not finish inside its phase (exit $bringup_rc); nothing else runs" | tee /src/ap-run/VOID
fi
cp /var/log/ap.log /src/ap-run/instance.log
left=$(( EV - $(date +%s) )); [ "$left" -gt 5 ] || left=5
# A benchmark the runner's timeout orphaned can still be writing, which makes tar exit 1 with a usable archive.
tar --warning=no-file-changed -czf /tmp/evidence.tgz -C /src ap-run
[ $? -le 1 ] && timeout "$left" aws s3 cp --only-show-errors /tmp/evidence.tgz "s3://$BUCKET/$PREFIX/evidence.tgz"
upload /var/log/ap.log log.txt
echo "RUN_NONCE_PLACEHOLDER" > /tmp/DONE
upload /tmp/DONE DONE
TAIL
} >"$UD.template"
sed -e "s|BUCKET_PLACEHOLDER|$BUCKET|" -e "s|RUN_ID_PLACEHOLDER|$RUN_ID|" -e "s|INPUTS_SHA_PLACEHOLDER|$INPUTS_SHA|" \
  -e "s|COMMIT_PLACEHOLDER|$COMMIT|" -e "s|RUN_NONCE_PLACEHOLDER|$RUN_NONCE|" \
  -e "s|LAUNCHTIME_WAIT_S_PLACEHOLDER|$LAUNCHTIME_WAIT_S|" -e "s|STOP_FROM_LAUNCH_S_PLACEHOLDER|$STOP_FROM_LAUNCH_S|g" \
  -e "s|BRINGUP_S_PLACEHOLDER|$BRINGUP_S|" -e "s|HARNESS_END_S_PLACEHOLDER|$HARNESS_END_S|" -e "s|PARTIAL_SYNC_S_PLACEHOLDER|$PARTIAL_SYNC_S|" \
  -e "s|EVIDENCE_S_PLACEHOLDER|$EVIDENCE_S|" "$UD.template" >"$UD" || fail "could not render the user-data"
rm -f "$UD.template"
! grep -q '_PLACEHOLDER' "$UD" || fail "the user-data still holds a placeholder: $(grep -o '[A-Z_]*_PLACEHOLDER' "$UD" | sort -u | paste -sd' ')"
[ "$(head -c 2 "$UD")" = '#!' ] || fail "the user-data does not begin with a shebang, so cloud-init would not run it"
bash -n "$UD" || fail "the user-data does not parse"
[ "$(wc -c <"$UD")" -lt 16384 ] || fail "the user-data is $(wc -c <"$UD") bytes, over EC2's 16 KB limit"

# ---------------------------------------------------------------- the purchase
spot_ensure_bucket "$BUCKET" "$REGION" 30 || fail "could not prepare the results bucket $BUCKET"
# ECR Public limits anonymous pulls, and run 3 on 2026-11-16 ran past the 1,500 s pull bound anonymously, so the role
# may also log in to ECR Public; signing in to ECR Public needs both actions.
ROLE_POLICY="{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"s3:PutObject\",\"s3:GetObject\"],\"Resource\":\"arn:aws:s3:::$BUCKET/*\"},{\"Effect\":\"Allow\",\"Action\":[\"ecr-public:GetAuthorizationToken\",\"sts:GetServiceBearerToken\"],\"Resource\":\"*\"}]}"
spot_ensure_profile "$STACK" "$ROLE_POLICY" 20 || fail "could not prepare the instance profile $STACK"
# spot_ensure_profile leaves an existing role's policy as it was, so the current one is written every time.
aws iam put-role-policy --role-name "$STACK" --policy-name write-results --policy-document "$ROLE_POLICY" ||
  fail "could not update the instance role's policy"
for f in "$OUT/inputs.tgz"; do
  aws s3 cp --only-show-errors "$f" "s3://$BUCKET/$RUN_ID/$(basename "$f")" || fail "upload $(basename "$f")"
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

cred_check "before the purchase"
request_epoch=$(date +%s)
TAG_DEADLINE=$(date -u -d "@$(( request_epoch + TAG_AT_LAUNCH_S ))" +%Y-%m-%dT%H:%M:%SZ)
TAGS="ResourceType=instance,Tags=[{Key=Name,Value=$STACK},{Key=purpose,Value=$PURPOSE},{Key=run,Value=$RUN_NONCE},{Key=study-deadline,Value=$TAG_DEADLINE}]"
say "launching $INSTANCE_TYPE_FIXED Spot (max \$$MAX_PRICE_FIXED/h compute, \$$ALL_IN_RATE/h all in), study-deadline $TAG_DEADLINE -- the instance bills from here"
for z in $ZONES; do
  SUBNET=$(spot_subnet_in_zone "$REGION" "$z") || continue
  token="ap67811-$RUN_NONCE-$z"
  LAUNCH_UNCERTAIN="$token"; LAUNCH_UNCERTAIN_SUBNET="$SUBNET"
  IID=$(spot_launch "$REGION" "$VLLM67811_AMI_ID" "$INSTANCE_TYPE_FIXED" "$SUBNET" "$STACK" "$MAX_PRICE_FIXED" "$VOLUME_GB" \
    "$UD" "$TAGS" "$token" "" "" "$EBS_THROUGHPUT_MIBPS" "$EBS_IOPS" 2>"$OUT/launch-error-$z.txt") || IID=""
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
[ "$IMAGE_ID" = "$VLLM67811_AMI_ID" ] || fail "$IID runs $IMAGE_ID, not the pinned $VLLM67811_AMI_ID"
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
unpacked=no
if [ -s "$OUT/evidence.tgz" ] && tar -xzf "$OUT/evidence.tgz" -C "$OUT"; then
  unpacked=yes
else
  echo "the evidence archive was not returned or did not unpack" >>"$OUT/download-errors.txt"
fi
EVIDENCE=returned
# An archive that broke after its summary is not the whole record, so it counts as returned only if it unpacked whole.
if [ "$unpacked" != yes ] || ! grep -q "all engines done" "$OUT/ap-run/sweep/steps.log" 2>/dev/null; then
  # Without the final archive, the per-arm copies are what a reclaim or a crash left; they are reported as partial.
  mkdir -p "$OUT/ap-run-partial"
  { aws s3 cp --only-show-errors "s3://$BUCKET/$RUN_ID/partial.tgz" "$OUT/partial.tgz" &&
    tar -xzf "$OUT/partial.tgz" -C "$OUT/ap-run-partial"; } 2>>"$OUT/download-errors.txt" ||
    echo "the partial evidence did not download or unpack" >>"$OUT/download-errors.txt"
  # Completed scored runs in either archive make the evidence partial rather than missing.
  if compgen -G "$OUT/ap-run-partial/sweep/*.r[0-4].json" >/dev/null || compgen -G "$OUT/ap-run/sweep/*.r[0-4].json" >/dev/null; then
    EVIDENCE=partial
  else
    EVIDENCE=missing
  fi
fi
# Returned evidence is not a measurement, so the count of engines that ran every scored run is read from the summary.
MEASURED=none
if [ "$EVIDENCE" = returned ]; then
  # An engine counts only if it warmed up and ran every scored run, and an adaptive one only if its controller was
  # fed finite, positive GPU timings.
  MEASURED=$(awk -F'\t' 'NR > 1 { n++; if ($3 == "yes" && $4 == "yes" && $5 == "yes" && $6 == $7 && ($2 != "adaptive" || $8 > 0)) m++ } END { printf "%d of %d", m, n }' \
    "$OUT/ap-run/sweep/summary.tsv" 2>>"$OUT/download-errors.txt") || MEASURED=unread
fi
{
  echo "evidence=$EVIDENCE"
  echo "measured=$MEASURED"
  echo "termination=$TERMINATION"
} >"$OUT/outcome.txt"
[ ! -s "$OUT/ap-run/summary.txt" ] || cat "$OUT/ap-run/summary.txt"
say "evidence $EVIDENCE (summary at $OUT/ap-run/sweep/summary.tsv); engines fully measured: $MEASURED; termination $TERMINATION"
[ "$TERMINATION" = confirmed ] || exit 1
# A paid session whose summary never came back has not delivered what it bought.
[ "$EVIDENCE" = returned ] || exit 1
# Evidence of a run in which an engine was not fully measured is kept, and the session still says so.
[ "$MEASURED" = "6 of 6" ] || exit 2
