#!/usr/bin/env bash
#
# vLLM #68414 (GDN prepare_chunk_indices), before and after the fix, then vLLM #68415 (KDA output shape) the same way: one g5.xlarge Spot instance, one attempt, stopped by itself 4,740 s after launch.
#
#   SESSION_CONFIRM=yes AWS_PROFILE=gpu-lab VLLMGDN_AMI_ID=ami-... bash hack/vllm-gdn-68414-session.sh
#
# The runtime session's fix (storage/open-source/contributions/vllm/gdn-chunk-indices-68414) numbers each chunk by its sequence, so a zero-length sequence keeps its id and the chunks after it stop reading its bounds.
# The reporter's kernel_repro.py shows the bug only on a GPU, and this session runs it twice.
# BEFORE: vLLM main 8700cc9ba0 unpatched, where kernel_repro.py must print 70 unwritten rows; the reporter's state error was NaN, and the verdict records whether it is.
# AFTER: the same commit with fix.diff, where it must print `unwritten 0 o_err 0.0 state_err 0.0 empty_keeps_h0 True`.
# AFTER then runs the diff's new test and the two existing GDN tests, which hack/vllm-gdn-68414/verdict.py expects to skip on sm_86 for their own stated reasons (SM10x only, ROCm only), and records those reasons.
# fix.diff and kernel_repro.py are copies of the runtime session's, pinned below by sha256.
#
# #68415, ON THE SAME INSTANCE.
# The runtime session's second fix (storage/open-source/contributions/vllm/kda-output-shape-68415) allocates fused_recurrent_kda's output from v rather than k.
# kda.py is the same blob (ff676ce) at the fix's base 428c371b32 and at 8700cc9ba0, so the image above serves it too; hack/vllm-gdn-68414/kda-pins.txt holds the hashes.
# The two commits differ only in vllm/utils/torch_utils.py, whose change takes effect only on torch 2.14 and touches LayerName, not the KDA kernel.
# Its two states run after #68414's AFTER, each in its own fresh container, through hack/vllm-gdn-68414/kda-state.sh.
# KDA BEFORE: only the new test file, and only its 64-32 case, which must fail on `out.shape == v.shape` ([1, 4, 1, 64] against [1, 4, 1, 32]).
# The 32-64 case is never run before the fix, because with V above K the unfixed kernel writes past the output and can crash the process.
# KDA AFTER: the whole kda-fix.diff, where all three cases must pass.
# hack/vllm-gdn-68414/kda-verdict.py judges them apart from verdict.py, so #68414's verdict and its exit status are what they were without #68415.
#
# It is hack/vllm-tpot-session.sh with another runner, and shares its EC2 lifecycle (hack/lib/spot-run.sh).
#
# THE BUILD.
# vLLM CI publishes a test image per main commit, and the one for 8700cc9ba0 is pinned by digest in the runner.
# Its labels name the commit, and it carries the wheel's sha256, both recorded on the instance.
# The image installs the wheel, copies the checkout's vllm/v1 over the installed package, and moves the checkout's vllm/ aside, so Python imports vllm from dist-packages and pytest runs the checkout's tests from /vllm-workspace.
# hack/vllm-gdn-68414/state.sh therefore applies fix.diff in two parts: vllm/* to the installed package, the rest to the checkout, and it records the index.py Python imports and which of the bug and fix lines that file holds.
# hack/vllm-gdn-68414/pins.txt holds the sha256 of every file the diff touches or the session runs, per state.
# Each state runs in its own fresh container, which is the `git checkout .` between them.
#
# THE REPRO.
# kernel_repro.py builds its tensors without .cuda(), and the Triton kernels it calls need CUDA tensors.
# Each state first runs it as-is; only if that prints no result does it run the same file through hack/vllm-gdn-68414/run_repro.py, which checks the file's sha256, sets CUDA as torch's default device and executes it.
# The state records which way gave the answer, and the verdict requires both states to have used the same way.
#
# THE CLOCK.
# Every deadline counts from EC2's LaunchTime, read right after the launch and written to the run's S3 prefix for the instance to read.
# The work is bounded step by step, and the deadlines are their sum:
#   bring-up (boot, cloud-init, downloads, toolkit)                         600 s -> 600
#   image pull (the TPOT run 1 pull took 745 s, the 67811 run 2 pull 1,094 s) 1,500 s
#   image identity                                                           300 s
#   BEFORE: setup 120 + as-is 120 + CUDA default 360 + stop 30                630 s
#   AFTER: setup, as-is and CUDA default 600 + new test 120 + 2 x 120 + 30  990 s
#   KDA BEFORE: setup 120 + pytest 120 + stop 30                              270 s
#   KDA AFTER: setup 120 + pytest 120 + stop 30                               270 s
#   so the runner ends by 600 + 1,500 + 300 + 630 + 990 + 270 + 270       = 4,560 s
#   evidence upload                                                          120 s -> 4,680
# The launch carries the termination sweeper's study-deadline tag at the request plus 4,680 s, rewritten to LaunchTime plus 4,710 s once LaunchTime is known; the instance shuts itself down at 4,740 s; the termination is to be confirmed by 5,040 s, the sweeper's five-minute period after its tag plus 30 s.
# The KDA states are expected to take about two minutes together, and their bounds are wider because each starts a fresh container and compiles its kernel.
# The CUDA-default bound is 360 s because the FLA kernels autotune on first use, compiling about a hundred Triton configs in a fresh container.
# The repro and pytest bounds therefore add up to 1,320 s, above the "about 15 minutes of run time" the request set, which is the expected time rather than the bound.
#
# THE COST.
# The worst case bills to the termination deadline: 5,040 s = 1.4 h.
# The rate is the TPOT session's, from the same instance, volume and provisioning: the $0.70/h Spot cap, $0.0324/h for 200 GB gp3 and a public IPv4, and $0.0468/h for 500 MiB/s and 6,000 IOPS.
# So it is $0.7792/h all in, and $1.0909, under $1.50.
# The script refuses to run if the constants below stop giving a worst case under $1.50.
#
# NOTHING HERE IS A DEFAULT A CALLER CAN MOVE: the instance, the build, the diff, the repro, the bounds and the stop are constants, and a caller who sets one is refused rather than ignored.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

REGION=ap-northeast-2
ACCOUNT_WANT=007635145730
INSTANCE_TYPE_FIXED=g5.xlarge
# g5.xlarge Spot was $0.61-0.63/h in ap-northeast-2 on 2026-11-19, and a zone above the cap is not used.
MAX_PRICE_FIXED=0.70
# The cap, plus 200 GB gp3 and a public IPv4 ($0.0324/h), plus the provisioned throughput and IOPS ($0.0468/h).
ALL_IN_RATE=0.7792
EBS_THROUGHPUT_MIBPS=500
EBS_IOPS=6000
COST_CAP_USD=1.50
STUDY_ID=vllm-gdn-chunk-indices-68414-2026-11-19
STACK=gdn-gpu
PURPOSE=vllm-gdn-68414-before-after
RUNNER=hack/vllm-gdn-68414/runner.sh
STATE=hack/vllm-gdn-68414/state.sh
PINS=hack/vllm-gdn-68414/pins.txt
VERDICT=hack/vllm-gdn-68414/verdict.py
RUN_REPRO=hack/vllm-gdn-68414/run_repro.py
FIX_DIFF=hack/vllm-gdn-68414/fix.diff
FIX_DIFF_SHA256=c75343ff6066abb233398110147cb3410de75e39d034633bf409ea1233f6756c
REPRO=hack/vllm-gdn-68414/kernel_repro.py
REPRO_SHA256=766ccd795b2e1f71ba9c48dc99e22deec8f17047467b70866acf7378310af3af
KDA_STATE=hack/vllm-gdn-68414/kda-state.sh
KDA_PINS=hack/vllm-gdn-68414/kda-pins.txt
KDA_VERDICT=hack/vllm-gdn-68414/kda-verdict.py
# kda-fix.diff is the runtime session's #68415 diff byte for byte, and kda-test.diff is its first part, the new test file alone.
KDA_FIX_DIFF=hack/vllm-gdn-68414/kda-fix.diff
KDA_FIX_DIFF_SHA256=b2d388ec7d5139889f37374b77e42f69bf82a0d969fb7f9a7752852da79e9bfd
KDA_TEST_DIFF=hack/vllm-gdn-68414/kda-test.diff
KDA_TEST_DIFF_SHA256=107e102ce35b8cbbebc09a9a3dfffc661a2c0eebe423f903d815f5a8944d359f
# The step bounds, each the runner's own; hack/vllm-gdn-68414-session-test.sh holds the two equal.
BRINGUP_S=600
PULL_BOUND_S=1500
IMAGE_ID_S=300
SETUP_S=120
ASIS_S=120
CUDA_S=360
UNIT_S=120
EXIST_S=120
KDA_S=120
STOP_S=30
EVIDENCE_UPLOAD_S=120
STATES_S=$(( (SETUP_S + ASIS_S + CUDA_S + STOP_S) + (SETUP_S + ASIS_S + CUDA_S + UNIT_S + 2 * EXIST_S + STOP_S) + 2 * (SETUP_S + KDA_S + STOP_S) ))
HARNESS_END_S=$(( BRINGUP_S + PULL_BOUND_S + IMAGE_ID_S + STATES_S ))
EVIDENCE_S=$(( HARNESS_END_S + EVIDENCE_UPLOAD_S ))
TAG_AT_LAUNCH_S=$EVIDENCE_S
TAG_FROM_LAUNCH_S=$(( EVIDENCE_S + 30 ))
STOP_FROM_LAUNCH_S=$(( EVIDENCE_S + 60 ))
TERMINATION_S=$(( TAG_FROM_LAUNCH_S + 330 ))
LAUNCHTIME_WAIT_S=180
# How often the instance copies the records to S3 while the runner runs.
PARTIAL_SYNC_S=30
# The DONE wait polls every WAIT_INTERVAL_S and every poll sleeps that long, so this many attempts outlast the stop and the wall-clock deadline, not the count, ends the wait.
WAIT_INTERVAL_S=20
WAIT_ATTEMPTS=$(( STOP_FROM_LAUNCH_S / WAIT_INTERVAL_S + 2 ))
SWEEPER_MIN_RUNS=4
# The session's end of the termination wait plus 30 minutes of headroom, in minutes.
CRED_MIN_MINUTES=$(( TERMINATION_S / 60 + 30 ))
VOLUME_GB=200

OUT="${OUT:-hack/vllm-gdn-68414-$(date -u +%Y%m%dT%H%M%SZ)}"
say() { echo "== $*" | { if [ -d "$OUT" ]; then tee -a "$OUT/session.log"; else cat; fi; }; }
fail() { echo "SESSION REFUSED: $*" | { if [ -d "$OUT" ]; then tee -a "$OUT/session.log"; else cat; fi; } >&2; exit 1; }
spot_say() { say "$@"; }
spot_fail() { fail "$@"; }

# render_user_data FILE BUCKET RUN_ID INPUTS_SHA COMMIT RUN_NONCE: the instance's script, from the constants above.
# It is a function so the offline test renders the same text the purchase would send.
render_user_data() {
  local ud=$1 from to
  # The NVIDIA container toolkit set-up, from hack/m5c-gpu-session.sh between two anchors that must each occur once.
  from=$(grep -nx 'export DEBIAN_FRONTEND=noninteractive' hack/m5c-gpu-session.sh | cut -d: -f1 | paste -sd' ')
  to=$(grep -nx 'systemctl restart docker' hack/m5c-gpu-session.sh | cut -d: -f1 | paste -sd' ')
  [[ "$from" =~ ^[0-9]+$ && "$to" =~ ^[0-9]+$ && "$from" -lt "$to" ]] ||
    fail "the toolkit anchors in hack/m5c-gpu-session.sh are not each found once, in order (from '$from', to '$to')"
  {
    cat <<'HEAD'
#!/bin/bash
exec > >(tee /var/log/gdn.log) 2>&1
set -x
SR_START=$(date +%s)
# The first backstop, armed before anything can fail, counts from the instance's own start; LaunchTime precedes it, so the precise one below, armed once LaunchTime is read, always fires first.
( sleep STOP_FROM_LAUNCH_S_PLACEHOLDER; shutdown -h now ) &
BUCKET="BUCKET_PLACEHOLDER"
PREFIX="RUN_ID_PLACEHOLDER"
COMMIT="COMMIT_PLACEHOLDER"
upload() { aws s3 cp --only-show-errors "$1" "s3://$BUCKET/$PREFIX/$2" || true; }
trap 'upload /var/log/gdn.log log.txt; shutdown -h now' EXIT
mkdir -p /src/gdn-run /opt/gdn || exit 1
# The input is fetched and checked against the hash this session computed, so the instance runs only what was built here.
aws s3 cp --only-show-errors "s3://$BUCKET/$PREFIX/inputs.tgz" /opt/gdn/inputs.tgz || exit 1
[ "$(sha256sum /opt/gdn/inputs.tgz | cut -d' ' -f1)" = "INPUTS_SHA_PLACEHOLDER" ] || { echo "checksum mismatch for inputs.tgz"; exit 1; }
mkdir -p /opt/gdn/in && tar -xzf /opt/gdn/inputs.tgz -C /opt/gdn/in || exit 1
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
# The pinned image is CUDA 13.2 with vLLM's compatibility mode off, which needs a 580 or newer driver; an older one would only show after the 11 GB pull.
drv=$(tail -n +2 /tmp/nvidia-smi.csv | awk -F', ' '{print $4}' | cut -d. -f1)
[[ "$drv" =~ ^[0-9]+$ ]] && [ "$drv" -ge 580 ] || { echo "PREFLIGHT FAILED: driver ${drv:-unread} is older than 580"; exit 1; }
HEAD
    echo "cat > /tmp/bringup.sh <<'BRINGUP'"
    sed -n "${from},${to}p" hack/m5c-gpu-session.sh
    echo "sleep 5"
    # The spliced steps do not stop on a failed command, so the bring-up is judged by its outcome before anything runs.
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
  sha256sum /opt/gdn/inputs.tgz
} > /src/gdn-run/instance-provenance.txt
cp /tmp/nvidia-smi.csv /src/gdn-run/nvidia-smi.csv
{ nvidia-smi; nvidia-smi -q; } > /src/gdn-run/nvidia-smi.txt 2>&1
{ docker version; docker info; nvidia-ctk --version; } > /src/gdn-run/versions.txt 2>&1
if [ "$bringup_rc" = 0 ]; then
  # An authenticated pull gets ECR Public's higher limits; a failed login is recorded and the pull goes on anonymously.
  { aws ecr-public get-login-password --region us-east-1 | docker login --username AWS --password-stdin public.ecr.aws; } \
    > /src/gdn-run/ecr-login.txt 2>&1 || echo "ECR Public login failed; the pull runs anonymously" >> /src/gdn-run/ecr-login.txt
  mkdir -p /src/gdn-run/sweep
  # A Spot reclaim gives two minutes, so the records leave the instance within PARTIAL_SYNC_S of being written.
  # One archive overwritten in place needs only the role's s3:PutObject; a sync would also need s3:ListBucket.
  # GNU tar exits 1 when a file grew while it was read, which a running pytest log does, so 1 still uploads.
  ( while :; do
      nice -n 19 ionice -c3 tar --warning=no-file-changed -czf /tmp/partial.tgz -C /src/gdn-run sweep >>/var/log/gdn-sync.log 2>&1
      [ $? -le 1 ] && timeout 60 nice -n 19 aws s3 cp --only-show-errors /tmp/partial.tgz "s3://$BUCKET/$PREFIX/partial.tgz" >>/var/log/gdn-sync.log 2>&1
      sleep PARTIAL_SYNC_S_PLACEHOLDER
    done ) &
  sync_pid=$!
  # The runner's own bounds sum to HE; this timeout only stops a runner that overran them from eating the upload.
  timeout --kill-after=15 $(( HE - $(date +%s) > 5 ? HE - $(date +%s) : 5 )) bash /opt/gdn/in/runner.sh /opt/gdn/in /src/gdn-run/sweep "$HE" \
    > /src/gdn-run/summary.txt 2>&1
  harness_rc=$?
  kill "$sync_pid" 2>>/var/log/gdn-sync.log
  cp /var/log/gdn-sync.log /src/gdn-run/sync.log
  cat /src/gdn-run/summary.txt
  echo "harness_rc=$harness_rc" >> /src/gdn-run/instance-provenance.txt
  echo "the runner exited $harness_rc"
else
  echo "the bring-up did not finish inside its phase (exit $bringup_rc); nothing else runs" | tee /src/gdn-run/VOID
fi
cp /var/log/gdn.log /src/gdn-run/instance.log
left=$(( EV - $(date +%s) )); [ "$left" -gt 5 ] || left=5
tar --warning=no-file-changed -czf /tmp/evidence.tgz -C /src gdn-run
[ $? -le 1 ] && timeout "$left" aws s3 cp --only-show-errors /tmp/evidence.tgz "s3://$BUCKET/$PREFIX/evidence.tgz"
upload /var/log/gdn.log log.txt
echo "RUN_NONCE_PLACEHOLDER" > /tmp/DONE
upload /tmp/DONE DONE
TAIL
  } >"$ud.template"
  sed -e "s|BUCKET_PLACEHOLDER|$2|" -e "s|RUN_ID_PLACEHOLDER|$3|" -e "s|INPUTS_SHA_PLACEHOLDER|$4|" \
    -e "s|COMMIT_PLACEHOLDER|$5|" -e "s|RUN_NONCE_PLACEHOLDER|$6|" \
    -e "s|LAUNCHTIME_WAIT_S_PLACEHOLDER|$LAUNCHTIME_WAIT_S|" -e "s|STOP_FROM_LAUNCH_S_PLACEHOLDER|$STOP_FROM_LAUNCH_S|g" \
    -e "s|BRINGUP_S_PLACEHOLDER|$BRINGUP_S|" -e "s|HARNESS_END_S_PLACEHOLDER|$HARNESS_END_S|" -e "s|PARTIAL_SYNC_S_PLACEHOLDER|$PARTIAL_SYNC_S|" \
    -e "s|EVIDENCE_S_PLACEHOLDER|$EVIDENCE_S|" "$ud.template" >"$ud" || fail "could not render the user-data"
  rm -f "$ud.template"
  ! grep -q '_PLACEHOLDER' "$ud" || fail "the user-data still holds a placeholder: $(grep -o '[A-Z_]*_PLACEHOLDER' "$ud" | sort -u | paste -sd' ')"
  [ "$(head -c 2 "$ud")" = '#!' ] || fail "the user-data does not begin with a shebang, so cloud-init would not run it"
  bash -n "$ud" || fail "the user-data does not parse"
  [ "$(wc -c <"$ud")" -lt 16384 ] || fail "the user-data is $(wc -c <"$ud") bytes, over EC2's 16 KB limit"
}

# ---------------------------------------------------------------- refusals, before anything is built or bought
# None of these names is one of the script's own variables, which the loop would otherwise read back as a caller's.
for v in INSTANCE_TYPE MAX_SPOT_PRICE HARD_STOP_SECONDS BACKSTOP_SECONDS IMAGE VLLM_IMAGE VLLM_COMMIT \
  DIFF PATCH PULL_BOUND REPRO_SCRIPT DEFAULT_DEVICE PYTEST_ARGS; do
  [ -z "${!v:-}" ] || fail "$v is set, and this session's value for it is its registration's; unset it"
done
python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) / 3600 * float(sys.argv[2]) < float(sys.argv[3]) else 1)' \
  "$TERMINATION_S" "$ALL_IN_RATE" "$COST_CAP_USD" ||
  fail "the worst case, $TERMINATION_S s at \$$ALL_IN_RATE/h, is not under \$$COST_CAP_USD"
# The schedule alone, with nothing checked or bought, so the offline test can hold it to the runner's bounds.
if [ "${1:-}" = --print-schedule ]; then
  echo "harness_end_s=$HARNESS_END_S evidence_s=$EVIDENCE_S stop_s=$STOP_FROM_LAUNCH_S termination_s=$TERMINATION_S"
  exit 0
fi
# The user-data alone, rendered with stand-in values, so the offline test reads what a purchase would send.
if [ "${1:-}" = --print-user-data ]; then
  ud=$(mktemp) || exit 1
  render_user_data "$ud" bucket-x run-x 0000 commit-x nonce-x
  cat "$ud"; rm -f "$ud"
  exit 0
fi
[ "${SESSION_CONFIRM:-}" = yes ] || fail "SESSION_CONFIRM=yes is required: this buys a GPU instance, and only the owner's approval starts one"
[[ "${VLLMGDN_AMI_ID:-}" =~ ^ami-[0-9a-f]{8,17}$ ]] ||
  fail "VLLMGDN_AMI_ID is ${VLLMGDN_AMI_ID:-unset}; the session pins the AMI by ID rather than resolving it from latest"
for tool in aws python3 git tar sha256sum; do command -v "$tool" >/dev/null || fail "$tool is not installed"; done
[ -z "$(git status --porcelain)" ] || fail "the working tree is dirty; the run's provenance is a commit, and the runner is shipped from this tree"
COMMIT=$(git rev-parse HEAD)
ACCOUNT=$(aws sts get-caller-identity --query Account --output text 2>&1) || fail "could not read the caller's account: $ACCOUNT"
[ "$ACCOUNT" = "$ACCOUNT_WANT" ] || fail "the credentials are for account $ACCOUNT; paid sessions run only in gpu-lab ($ACCOUNT_WANT)"
[ ! -e "$OUT" ] || fail "$OUT already exists; each session writes a new directory"
mkdir -p "$OUT" || fail "cannot create $OUT"
say "vLLM #68414 and #68415 before and after for $STUDY_ID, from $COMMIT, into $OUT"
say "hard stop $STOP_FROM_LAUNCH_S s after LaunchTime; worst case $TERMINATION_S s at \$$ALL_IN_RATE/h"

# The diff and the repro are the runtime session's, byte for byte, so a changed copy costs nothing.
[ "$(sha256sum "$FIX_DIFF" | cut -d' ' -f1)" = "$FIX_DIFF_SHA256" ] || fail "$FIX_DIFF is not the pinned $FIX_DIFF_SHA256"
[ "$(sha256sum "$REPRO" | cut -d' ' -f1)" = "$REPRO_SHA256" ] || fail "$REPRO is not the pinned $REPRO_SHA256"
mkdir -p "$OUT/in" || fail "cannot create $OUT/in"
cp "$RUNNER" "$STATE" "$PINS" "$FIX_DIFF" "$REPRO" "$RUN_REPRO" "$OUT/in/" || fail "copy the inputs"
[ "$(sha256sum "$KDA_FIX_DIFF" | cut -d' ' -f1)" = "$KDA_FIX_DIFF_SHA256" ] || fail "$KDA_FIX_DIFF is not the pinned $KDA_FIX_DIFF_SHA256"
[ "$(sha256sum "$KDA_TEST_DIFF" | cut -d' ' -f1)" = "$KDA_TEST_DIFF_SHA256" ] || fail "$KDA_TEST_DIFF is not the pinned $KDA_TEST_DIFF_SHA256"
cp "$KDA_STATE" "$KDA_PINS" "$KDA_FIX_DIFF" "$KDA_TEST_DIFF" "$OUT/in/" || fail "copy the #68415 inputs"
tar -czf "$OUT/inputs.tgz" -C "$OUT/in" . || fail "pack the inputs"
say "fix.diff $FIX_DIFF_SHA256 and kernel_repro.py $REPRO_SHA256 match their pins"

# shellcheck source=hack/lib/spot-run.sh
. hack/lib/spot-run.sh

ami_name=$(aws ec2 describe-images --region "$REGION" --image-ids "$VLLMGDN_AMI_ID" \
  --query 'Images[0].[Name,State]' --output text 2>&1) || fail "could not describe $VLLMGDN_AMI_ID: $ami_name"
case "$ami_name" in
  "Deep Learning Base OSS Nvidia Driver GPU AMI (Ubuntu 22.04)"*available) ;;
  *) fail "$VLLMGDN_AMI_ID is '$ami_name', not an available Deep Learning Base OSS Nvidia Driver GPU AMI (Ubuntu 22.04)" ;;
esac
say "AMI $VLLMGDN_AMI_ID: $ami_name"

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
  echo "ami_id=$VLLMGDN_AMI_ID"
  echo "ami_name=$ami_name"
  echo "instance_type=$INSTANCE_TYPE_FIXED"
  echo "max_spot_price=$MAX_PRICE_FIXED"
  echo "all_in_rate=$ALL_IN_RATE"
  echo "inputs_sha256=$INPUTS_SHA"
  echo "fix_diff_sha256=$FIX_DIFF_SHA256"
  echo "kernel_repro_sha256=$REPRO_SHA256"
  echo "kda_fix_diff_sha256=$KDA_FIX_DIFF_SHA256"
  echo "kda_test_diff_sha256=$KDA_TEST_DIFF_SHA256"
  echo "image=$(grep -m1 '^IMG=' "$RUNNER" | cut -d'"' -f2)"
  echo "vllm_commit=$(grep -m1 '^VLLM_COMMIT=' "$RUNNER" | cut -d= -f2)"
  echo "harness_end_from_launch_s=$HARNESS_END_S"
  echo "stop_from_launch_s=$STOP_FROM_LAUNCH_S"
  echo "termination_from_launch_s=$TERMINATION_S"
  echo "run_id=$RUN_ID"
} >"$OUT/session-provenance.txt"
UD="$OUT/user-data.sh"
render_user_data "$UD" "$BUCKET" "$RUN_ID" "$INPUTS_SHA" "$COMMIT" "$RUN_NONCE"

# ---------------------------------------------------------------- the purchase
spot_ensure_bucket "$BUCKET" "$REGION" 30 || fail "could not prepare the results bucket $BUCKET"
# ECR Public limits anonymous pulls, so the role may also log in to ECR Public; signing in needs both actions.
ROLE_POLICY="{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"s3:PutObject\",\"s3:GetObject\"],\"Resource\":\"arn:aws:s3:::$BUCKET/*\"},{\"Effect\":\"Allow\",\"Action\":[\"ecr-public:GetAuthorizationToken\",\"sts:GetServiceBearerToken\"],\"Resource\":\"*\"}]}"
spot_ensure_profile "$STACK" "$ROLE_POLICY" 20 || fail "could not prepare the instance profile $STACK"
# spot_ensure_profile leaves an existing role's policy as it was, so the current one is written every time.
aws iam put-role-policy --role-name "$STACK" --policy-name write-results --policy-document "$ROLE_POLICY" ||
  fail "could not update the instance role's policy"
aws s3 cp --only-show-errors "$OUT/inputs.tgz" "s3://$BUCKET/$RUN_ID/inputs.tgz" || fail "upload inputs.tgz"

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
  # Only a confirmed termination ends the cleanup; an unconfirmed one is tried once more on the way out.
  [ "$TERMINATION" = confirmed ] && return 0
  # The retry gets a minute of its own, since the main wait may have used up the schedule's.
  if [ "$TERMINATION" = unconfirmed ]; then SPOT_TERMINATE_WAIT=60; SPOT_TERMINATE_TRIES=13; fi
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
  token="gdn-$RUN_NONCE-$z"
  LAUNCH_UNCERTAIN="$token"; LAUNCH_UNCERTAIN_SUBNET="$SUBNET"
  IID=$(spot_launch "$REGION" "$VLLMGDN_AMI_ID" "$INSTANCE_TYPE_FIXED" "$SUBNET" "$STACK" "$MAX_PRICE_FIXED" "$VOLUME_GB" \
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
[ "$IMAGE_ID" = "$VLLMGDN_AMI_ID" ] || fail "$IID runs $IMAGE_ID, not the pinned $VLLMGDN_AMI_ID"
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
SWEEP="$OUT/gdn-run/sweep"
EVIDENCE=returned
# An archive that broke after its last step is not the whole record, so it counts as returned only if it unpacked whole.
if [ "$unpacked" != yes ] || ! grep -q "both states done" "$SWEEP/steps.log" 2>/dev/null; then
  # Without the final archive, the periodic copy is what a reclaim or a crash left; it is reported as partial.
  mkdir -p "$OUT/gdn-run-partial"
  { aws s3 cp --only-show-errors "s3://$BUCKET/$RUN_ID/partial.tgz" "$OUT/partial.tgz" &&
    tar -xzf "$OUT/partial.tgz" -C "$OUT/gdn-run-partial"; } 2>>"$OUT/download-errors.txt" ||
    echo "the partial evidence did not download or unpack" >>"$OUT/download-errors.txt"
  if [ "$unpacked" = yes ] && [ -s "$SWEEP/steps.log" ]; then
    EVIDENCE=partial
  elif [ -s "$OUT/gdn-run-partial/sweep/steps.log" ]; then
    EVIDENCE=partial
    SWEEP="$OUT/gdn-run-partial/sweep"
  else
    EVIDENCE=missing
  fi
fi
# The verdict reads whatever records came back, so a stopped run still says how far it got and why it is not confirmed.
python3 "$VERDICT" "$SWEEP" "$FIX_DIFF_SHA256" "$REPRO_SHA256" >"$OUT/verdict.txt" 2>>"$OUT/download-errors.txt"
# #68415's verdict is its own file and its own lines, and nothing below gates on it, so it cannot change #68414's outcome.
python3 "$KDA_VERDICT" "$SWEEP" "$KDA_TEST_DIFF_SHA256" "$KDA_FIX_DIFF_SHA256" >"$OUT/kda-verdict.txt" 2>>"$OUT/download-errors.txt"
# The #68415 records come after #68414's in the run, so a run that stopped between them returns #68414 whole and #68415 not.
kda_evidence=missing
[ "$EVIDENCE" = returned ] && grep -q "kda states done" "$SWEEP/steps.log" 2>/dev/null && kda_evidence=returned
{
  echo "evidence=$EVIDENCE"
  echo "termination=$TERMINATION"
  cat "$OUT/verdict.txt"
  echo "kda_evidence=$kda_evidence"
  cat "$OUT/kda-verdict.txt"
} >"$OUT/outcome.txt"
[ ! -s "$OUT/gdn-run/summary.txt" ] || cat "$OUT/gdn-run/summary.txt"
cat "$OUT/outcome.txt"
say "evidence $EVIDENCE; termination $TERMINATION; $(grep '^verdict=' "$OUT/verdict.txt" || echo 'verdict=unread'); #68415 evidence $kda_evidence, $(grep '^kda_verdict=' "$OUT/kda-verdict.txt" || echo 'kda_verdict=unread')"
[ "$TERMINATION" = confirmed ] || exit 1
[ "$EVIDENCE" = returned ] || exit 1
grep -qx 'verdict=confirmed' "$OUT/verdict.txt" || exit 2
