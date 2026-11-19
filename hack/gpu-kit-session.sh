#!/usr/bin/env bash
#
# Run one GPU kit directory, unmodified, on one g5 Spot instance (A10G 24 GB), and bring back what it wrote.
# A kit is a directory committed in some git repository with a run.sh at its top, which writes its results to $OUT.
#
#   SESSION_CONFIRM=yes AWS_PROFILE=gpu-lab OUT=hack/gpu-kit-runs/<name> [INSTANCE_TYPE=g5.2xlarge] bash hack/gpu-kit-session.sh <kit-dir>
#
# INSTANCE_TYPE is g5.xlarge (16 GiB RAM) unless set, and only the types in type_rates below are accepted.
# g5.2xlarge has the same A10G with 32 GiB RAM, for a kit whose single checkpoint file cannot be mapped in 16 GiB.
#
# WHAT RUNS WHERE.
# The kit is shipped as the kit repository's committed tree at HEAD, and the session refuses a kit with uncommitted or untracked files.
# The instance gets Python 3.12 from a pinned uv release (sha256-checked) as a standalone build under /opt/kit, so the AMI's own Python is untouched.
# It puts only `python` and `python3.12` for that build on PATH, and runs `bash run.sh` as root with HOME=/root and OUT=/opt/kit/run/results.
# The EC2 lifecycle is hack/lib/spot-run.sh's, and the clock, the sweeper checks and the evidence path follow hack/llmd-prefix-hunt-session.sh.
#
# THE CLOCK.
# Every deadline counts from EC2's LaunchTime, which the session writes to the run's S3 prefix for the instance to read.
#   bring-up: boot, the GPU preflight, uv and Python                 300 s
#   the kit's run.sh (the requester budgets about 2,700 s)           3,300 s
#   so the kit ends by 300 + 3,300                                 = 3,600 s
#   evidence upload                                                    60 s -> 3,660
# The launch carries the sweeper's study-deadline tag at the request plus 3,660 s, rewritten to LaunchTime plus 3,690 s once LaunchTime is known.
# The instance shuts itself down at 3,720 s, and the termination is to be confirmed by 4,020 s, the sweeper's five-minute period after its tag plus 30 s.
#
# THE COST.
# The worst case bills to the termination deadline, 4,020 s.
# It assumes EC2 confirms the termination by then; one that is not confirmed is reported as such, and billing past it is not bounded here.
# Ten minutes past it would still cost $0.9860, under $1.00.
# Each type has its own Spot cap, and every type adds $0.0683/h for 120 GB gp3 with 500 MiB/s and 6,000 IOPS and a public IPv4.
#   g5.xlarge:  the $0.70/h cap is $0.7683/h all in, and $0.8579.
#   g5.2xlarge: the $0.80/h cap is $0.8683/h all in, and $0.9696.
# Any cap of $0.8272/h or more would put the worst case at $1.00 or more.
# The script refuses to run if any listed type's constants stop giving a worst case under $1.00.
#
# NOTHING HERE IS A DEFAULT A CALLER CAN MOVE: a caller who sets one of the constants' names is refused rather than ignored.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

REGION=ap-northeast-2
INSTANCE_TYPE_FIXED=${INSTANCE_TYPE:-g5.xlarge}
# type_rates TYPE: the type's Spot cap, its all-in rate (the cap plus EBS_IP_RATE) and its vCPUs, or nothing for a type not listed.
# g5.xlarge Spot was $0.61-0.63/h in ap-northeast-2 on 2026-11-19, and g5.2xlarge $0.68-0.71/h the same evening.
# A zone above the cap is not used.
type_rates() {
  case "$1" in
    g5.xlarge) echo "0.70 0.7683 4" ;;
    g5.2xlarge) echo "0.80 0.8683 8" ;;
  esac
}
TYPES_LISTED="g5.xlarge g5.2xlarge"
# The Deep Learning Base OSS Nvidia Driver GPU AMI (Ubuntu 22.04) 20261016 that the earlier A10G sessions used.
AMI_ID_FIXED=ami-097edab977037f65f
AMI_NAME_FIXED="Deep Learning Base OSS Nvidia Driver GPU AMI (Ubuntu 22.04) 20261016"
# The AMI's root snapshot is 75 GB, and the kit adds a vLLM clone, a venv, uv's cache and 15.8 GiB of weights.
VOLUME_GB=120
EBS_THROUGHPUT_MIBPS=500
EBS_IOPS=6000
# 120 GB gp3 and a public IPv4 ($0.0214/h, at the per-GB rate the llm-d session used), plus the provisioned throughput and IOPS ($0.0468/h).
EBS_IP_RATE=0.0683
COST_CAP_USD=1.00
# uv and the Python it installs, pinned; the tarball's sha256 is the one its release publishes.
UV_VERSION=0.12.22
UV_SHA256=b9980552309f09c15172b8be828555e375097f16deb459795ce7bfd200380f0b
PYTHON_PIN=cpython-3.12.15-linux-x86_64-gnu
# The instance refuses to run the kit with less free space than this on /, in GB.
MIN_FREE_GB=60
STACK=gpukit
PURPOSE=gpu-kit-runner
BRINGUP_S=300
KIT_S=3300
EVIDENCE_UPLOAD_S=60
HARNESS_END_S=$(( BRINGUP_S + KIT_S ))
EVIDENCE_S=$(( HARNESS_END_S + EVIDENCE_UPLOAD_S ))
TAG_AT_LAUNCH_S=$EVIDENCE_S
TAG_FROM_LAUNCH_S=$(( EVIDENCE_S + 30 ))
STOP_FROM_LAUNCH_S=$(( EVIDENCE_S + 60 ))
TERMINATION_S=$(( TAG_FROM_LAUNCH_S + 330 ))
LAUNCHTIME_WAIT_S=180
# How often the instance copies its records to S3 while the kit runs, so a Spot reclaim leaves them behind.
PARTIAL_SYNC_S=60
WAIT_INTERVAL_S=20
WAIT_ATTEMPTS=$(( STOP_FROM_LAUNCH_S / WAIT_INTERVAL_S + 2 ))
SWEEPER_MIN_RUNS=4
CRED_MIN_MINUTES=$(( TERMINATION_S / 60 + 30 ))

OUT="${OUT:-hack/gpu-kit-runs/$(date -u +%Y%m%dT%H%M%SZ)}"
say() { echo "== $*" | { if [ -d "$OUT" ]; then tee -a "$OUT/session.log"; else cat; fi; }; }
fail() { echo "SESSION REFUSED: $*" | { if [ -d "$OUT" ]; then tee -a "$OUT/session.log"; else cat; fi; } >&2; exit 1; }
spot_say() { say "$@"; }
spot_fail() { fail "$@"; }

worst_usd() { python3 -c 'import sys; print(f"{float(sys.argv[1]) / 3600 * float(sys.argv[2]):.4f}")' "$TERMINATION_S" "$1"; }
under_cap() {
  python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) / 3600 * float(sys.argv[2]) < float(sys.argv[3]) else 1)' \
    "$TERMINATION_S" "$1" "$COST_CAP_USD"
}

# render_user_data FILE BUCKET RUN_ID INPUTS_SHA COMMIT RUN_NONCE: the instance's script, from the constants above.
# It is a function so the offline test renders the same text the purchase would send.
render_user_data() {
  local ud=$1
  cat >"$ud.template" <<'UD'
#!/bin/bash
exec > >(tee /var/log/gpukit.log) 2>&1
set -x
SR_START=$(date +%s)
# The first backstop counts from the instance's own start, which LaunchTime precedes, so the precise one below fires first.
( sleep STOP_FROM_LAUNCH_S_PLACEHOLDER; shutdown -h now ) &
BUCKET="BUCKET_PLACEHOLDER"
PREFIX="RUN_ID_PLACEHOLDER"
upload() { aws s3 cp --only-show-errors "$1" "s3://$BUCKET/$PREFIX/$2" || true; }
trap 'upload /var/log/gpukit.log log.txt; shutdown -h now' EXIT
R=/opt/kit/run
mkdir -p /opt/kit/in /opt/kit/bin /opt/kit/work "$R/results" || exit 1
aws s3 cp --only-show-errors "s3://$BUCKET/$PREFIX/inputs.tgz" /opt/kit/inputs.tgz || exit 1
[ "$(sha256sum /opt/kit/inputs.tgz | cut -d' ' -f1)" = "INPUTS_SHA_PLACEHOLDER" ] || { echo "checksum mismatch for inputs.tgz"; exit 1; }
tar -xzf /opt/kit/inputs.tgz -C /opt/kit/in || exit 1
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
nvidia-smi --query-gpu=index,name,memory.total,driver_version --format=csv > "$R/preflight-nvidia-smi.csv" || exit 1
upload "$R/preflight-nvidia-smi.csv" preflight-nvidia-smi.csv
[ "$(tail -n +2 "$R/preflight-nvidia-smi.csv" | wc -l)" = 1 ] && tail -n +2 "$R/preflight-nvidia-smi.csv" | grep -q A10G || { echo "PREFLIGHT FAILED: not one A10G"; exit 1; }
{ nvidia-smi; nvidia-smi -q; } > "$R/nvidia-smi.txt" 2>&1
df -BG / > "$R/df-before.txt"
free_gb=$(df -BG --output=avail / | tail -1 | tr -dc 0-9)
[ "${free_gb:-0}" -ge MIN_FREE_GB_PLACEHOLDER ] || { echo "PREFLIGHT FAILED: ${free_gb:-?} GB free on /"; exit 1; }
cat > /tmp/python.sh <<'PY'
set -euo pipefail
# What the AMI has, recorded before anything is installed.
{ command -v python3.12 || echo "no python3.12 on PATH"; command -v python || echo "no python on PATH"; python3 --version || true; command -v huggingface-cli hf || true; } > /opt/kit/run/ami-python.txt 2>&1
cd /opt/kit
curl -fsSL -o uv.tgz "https://github.com/astral-sh/uv/releases/download/UV_VERSION_PLACEHOLDER/uv-x86_64-unknown-linux-gnu.tar.gz"
echo "UV_SHA256_PLACEHOLDER  uv.tgz" | sha256sum -c -
tar -xzf uv.tgz
export UV_PYTHON_INSTALL_DIR=/opt/kit/python
./uv-x86_64-unknown-linux-gnu/uv python install PYTHON_PIN_PLACEHOLDER
py=$(./uv-x86_64-unknown-linux-gnu/uv python find --no-project --managed-python PYTHON_PIN_PLACEHOLDER)
ln -sf "$py" /opt/kit/bin/python
ln -sf "$py" /opt/kit/bin/python3.12
{ echo "uv=$(./uv-x86_64-unknown-linux-gnu/uv --version)"; echo "python=$py"; /opt/kit/bin/python --version; } > /opt/kit/run/python-provenance.txt 2>&1
PY
bringup_left=$(( P1 - $(date +%s) ))
bringup_rc=124
if [ "$bringup_left" -gt 0 ]; then
  timeout --kill-after=15 "$bringup_left" bash /tmp/python.sh
  bringup_rc=$?
fi
echo "bring-up exited $bringup_rc"
{ echo "commit=COMMIT_PLACEHOLDER"; echo "launch_time_epoch=$L"; echo "bringup_rc=$bringup_rc"; sha256sum /opt/kit/inputs.tgz; } > "$R/instance-provenance.txt"
if [ "$bringup_rc" = 0 ]; then
  # A Spot reclaim gives two minutes, so the records are copied out every cycle.
  # A cycle is the archive, an upload of up to 60 s and PARTIAL_SYNC_S of sleep, so a reclaim can lose up to one cycle's records.
  ( while :; do
      nice -n 19 tar --warning=no-file-changed -czf /tmp/partial.tgz -C /opt/kit run >>/var/log/gpukit-sync.log 2>&1
      [ $? -le 1 ] && timeout 60 aws s3 cp --only-show-errors /tmp/partial.tgz "s3://$BUCKET/$PREFIX/partial.tgz" >>/var/log/gpukit-sync.log 2>&1
      sleep PARTIAL_SYNC_S_PLACEHOLDER
    done ) &
  sync_pid=$!
  # Memory and the kernel's overcommit policy, since a load that maps one large checkpoint file depends on both.
  mem() { date -u +%Y-%m-%dT%H:%M:%SZ; free -m; swapon --show; echo "overcommit_memory=$(cat /proc/sys/vm/overcommit_memory) overcommit_ratio=$(cat /proc/sys/vm/overcommit_ratio)"; grep -E '^(MemTotal|MemAvailable|CommitLimit|Committed_AS):' /proc/meminfo; }
  mem > "$R/memory-before-kit.txt" 2>&1
  # run.sh cannot be touched, so the snapshot before its loads is taken when its status shows the last test step done.
  # The watcher polls every 2 s, and also samples memory every 30 s into memory.log.
  ( n=0; while :; do
      if [ ! -e "$R/memory-before-loads.txt" ] && grep -q '^test-files-fix ' "$R/results/status.txt" 2>/dev/null; then mem > "$R/memory-before-loads.txt" 2>&1; fi
      [ $(( n % 15 )) = 0 ] && { mem; echo; } >> "$R/memory.log" 2>&1
      n=$(( n + 1 )); sleep 2
    done ) &
  mem_pid=$!
  date -u +%Y-%m-%dT%H:%M:%SZ > "$R/kit-start.txt"
  cd /opt/kit/work
  # The kit runs unmodified; the timeout only stops one that overran its phase from eating the upload.
  env HOME=/root PATH="/opt/kit/bin:$PATH" OUT="$R/results" \
    timeout --kill-after=15 $(( HE - $(date +%s) > 5 ? HE - $(date +%s) : 5 )) bash /opt/kit/in/kit/run.sh > "$R/run-output.log" 2>&1
  kit_rc=$?
  date -u +%Y-%m-%dT%H:%M:%SZ > "$R/kit-end.txt"
  echo "kit_rc=$kit_rc" >> "$R/instance-provenance.txt"
  df -BG / > "$R/df-after.txt"
  kill "$sync_pid" "$mem_pid"
  cp /var/log/gpukit-sync.log "$R/sync.log"
  echo "run.sh exited $kit_rc"
else
  echo "the bring-up did not finish inside its phase (exit $bringup_rc); the kit did not run" | tee "$R/VOID"
fi
cp /var/log/gpukit.log "$R/instance.log"
# The archive and its upload share the evidence phase, and each step gets only the time still left in it.
left=$(( EV - $(date +%s) )); [ "$left" -gt 5 ] || left=5
timeout "$left" tar --warning=no-file-changed -czf /tmp/evidence.tgz -C /opt/kit run
tar_rc=$?
evidence=failed
# A failed upload is retried until the phase ends, since DONE ends the instance and its disk with it.
while [ "$tar_rc" -le 1 ]; do
  left=$(( EV - $(date +%s) )); [ "$left" -gt 0 ] || break
  timeout "$left" aws s3 cp --only-show-errors /tmp/evidence.tgz "s3://$BUCKET/$PREFIX/evidence.tgz" && { evidence=uploaded; break; }
  sleep 5
done
echo "evidence_upload=$evidence tar_rc=$tar_rc"
upload /var/log/gpukit.log log.txt
echo "RUN_NONCE_PLACEHOLDER evidence=$evidence" > /tmp/DONE
upload /tmp/DONE DONE
UD
  sed -e "s|BUCKET_PLACEHOLDER|$2|" -e "s|RUN_ID_PLACEHOLDER|$3|" -e "s|INPUTS_SHA_PLACEHOLDER|$4|" \
    -e "s|COMMIT_PLACEHOLDER|$5|" -e "s|RUN_NONCE_PLACEHOLDER|$6|" \
    -e "s|LAUNCHTIME_WAIT_S_PLACEHOLDER|$LAUNCHTIME_WAIT_S|" -e "s|STOP_FROM_LAUNCH_S_PLACEHOLDER|$STOP_FROM_LAUNCH_S|g" \
    -e "s|BRINGUP_S_PLACEHOLDER|$BRINGUP_S|" -e "s|HARNESS_END_S_PLACEHOLDER|$HARNESS_END_S|" -e "s|EVIDENCE_S_PLACEHOLDER|$EVIDENCE_S|" \
    -e "s|PARTIAL_SYNC_S_PLACEHOLDER|$PARTIAL_SYNC_S|" -e "s|MIN_FREE_GB_PLACEHOLDER|$MIN_FREE_GB|" \
    -e "s|UV_VERSION_PLACEHOLDER|$UV_VERSION|" -e "s|UV_SHA256_PLACEHOLDER|$UV_SHA256|" -e "s|PYTHON_PIN_PLACEHOLDER|$PYTHON_PIN|g" \
    "$ud.template" >"$ud" || fail "could not render the user-data"
  rm -f "$ud.template"
  ! command grep -q '_PLACEHOLDER' "$ud" || fail "the user-data still holds a placeholder"
  [ "$(head -c 2 "$ud")" = '#!' ] || fail "the user-data does not begin with a shebang, so cloud-init would not run it"
  bash -n "$ud" || fail "the user-data does not parse"
  [ "$(wc -c <"$ud")" -lt 16384 ] || fail "the user-data is $(wc -c <"$ud") bytes, over EC2's 16 KB limit"
}

# end_instance: terminates IID and sets TERMINATION to confirmed or unconfirmed, with the record in OUT.
# It is a function, and --end-instance runs it alone, so the offline test drives the same path the purchase ends with.
end_instance() {
  if spot_terminate "$REGION" "$IID"; then
    TERMINATION=confirmed
    echo "terminated $IID, confirmed at $(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$OUT/termination.txt"
  else
    TERMINATION=unconfirmed
    echo "TERMINATION UNCONFIRMED for $IID -- terminate it by hand now" | tee "$OUT/termination.txt" >&2
  fi
  aws ec2 describe-instances --region "$REGION" --instance-ids "$IID" \
    --query 'Reservations[0].Instances[0].[State.Name,StateTransitionReason,StateReason.Code,LaunchTime,Placement.AvailabilityZone]' \
    --output text >"$OUT/termination-describe.txt" 2>&1 || true
}

# ---------------------------------------------------------------- refusals, before anything is checked or bought
for v in MAX_SPOT_PRICE HARD_STOP_SECONDS AMI_ID VOLUME KIT_SECONDS PURCHASE; do
  [ -z "${!v:-}" ] || fail "$v is set, and this session's value for it is a constant; unset it"
done
# Every listed type is held under the cap, whichever one this run buys, so no type sits in the table unchecked.
for t in $TYPES_LISTED; do
  read -r cap all_in _ <<<"$(type_rates "$t")"
  [ -n "${all_in:-}" ] || fail "the listed type $t has no rates"
  under_cap "$all_in" || fail "the $t worst case, $TERMINATION_S s at \$$all_in/h, is \$$(worst_usd "$all_in"), not under \$$COST_CAP_USD"
  [ "$(python3 -c 'import sys; print(round(float(sys.argv[1]) + float(sys.argv[2]), 6))' "$cap" "$EBS_IP_RATE")" = "$all_in" ] ||
    fail "the $t all-in rate $all_in is not its Spot cap $cap plus EBS_IP_RATE $EBS_IP_RATE"
done
case " $TYPES_LISTED " in
  *" $INSTANCE_TYPE_FIXED "*) ;;
  *) fail "INSTANCE_TYPE '$INSTANCE_TYPE_FIXED' is not one of the listed types ($TYPES_LISTED)" ;;
esac
read -r MAX_PRICE_FIXED SPOT_ALL_IN_RATE TYPE_VCPUS <<<"$(type_rates "$INSTANCE_TYPE_FIXED")"
[ -n "${TYPE_VCPUS:-}" ] || fail "INSTANCE_TYPE '$INSTANCE_TYPE_FIXED' has no rates"
if [ "${1:-}" = --print-schedule ]; then
  echo "instance_type=$INSTANCE_TYPE_FIXED harness_end_s=$HARNESS_END_S evidence_s=$EVIDENCE_S stop_s=$STOP_FROM_LAUNCH_S termination_s=$TERMINATION_S worst_case_usd=$(worst_usd "$SPOT_ALL_IN_RATE")"
  exit 0
fi
if [ "${1:-}" = --print-user-data ]; then
  mkdir -p "${SCRATCH:-$HOME/.cache/gpu-kit}" || exit 1
  ud=$(mktemp -p "${SCRATCH:-$HOME/.cache/gpu-kit}") || exit 1
  render_user_data "$ud" bucket-x run-x 0000 commit-x nonce-x
  cat "$ud"; rm -f "$ud"
  exit 0
fi
# shellcheck source=hack/lib/spot-run.sh
. hack/lib/spot-run.sh
if [ "${1:-}" = --end-instance ]; then
  IID=${2:-}; [ -n "$IID" ] && [ -d "$OUT" ] || fail "--end-instance needs an instance id and an existing OUT"
  end_instance
  echo "termination=$TERMINATION"
  [ "$TERMINATION" = confirmed ] || exit 1
  exit 0
fi
[ "${SESSION_CONFIRM:-}" = yes ] || fail "SESSION_CONFIRM=yes is required: this buys a GPU instance, and it needs an explicit approval"
KIT=${1:-}
[ -n "$KIT" ] && [ -f "$KIT/run.sh" ] || fail "the kit directory '${KIT}' has no run.sh"
for tool in aws python3 git tar sha256sum; do command -v "$tool" >/dev/null || fail "$tool is not installed"; done

# ---------------------------------------------------------------- provenance: this tree and the kit's
[ -z "$(git status --porcelain)" ] || fail "the working tree is dirty; the run's provenance is a commit"
COMMIT=$(git rev-parse HEAD)
KIT_ABS=$(cd "$KIT" && pwd)
KIT_TOP=$(git -C "$KIT_ABS" rev-parse --show-toplevel 2>/dev/null) || fail "the kit $KIT_ABS is not in a git repository"
KIT_REL=$(realpath --relative-to="$KIT_TOP" "$KIT_ABS")
[ -z "$(git -C "$KIT_TOP" status --porcelain --untracked-files=all -- "$KIT_REL")" ] ||
  fail "the kit has uncommitted or untracked files; it is shipped as its repository's commit"
KIT_COMMIT=$(git -C "$KIT_TOP" rev-parse HEAD)
ACCOUNT=$(spot_account 2>&1) || fail "the account check failed: $ACCOUNT"
[ ! -e "$OUT" ] || fail "$OUT already exists; each session writes a new directory"
mkdir -p "$OUT/in/kit" || fail "cannot create $OUT"
git -C "$KIT_TOP" archive --format=tar "HEAD:$KIT_REL" | tar -x -C "$OUT/in/kit" || fail "could not export the kit from $KIT_COMMIT"
( cd "$OUT/in/kit" && find . -type f | LC_ALL=C sort | xargs -d '\n' sha256sum ) >"$OUT/kit-manifest.sha256" || fail "could not hash the kit"
tar -czf "$OUT/inputs.tgz" -C "$OUT/in" kit || fail "pack the inputs"
INPUTS_SHA=$(sha256sum "$OUT/inputs.tgz" | cut -d' ' -f1)
say "gpu kit $KIT_REL at $KIT_COMMIT, from $COMMIT, into $OUT"
say "hard stop $STOP_FROM_LAUNCH_S s after LaunchTime; worst case $TERMINATION_S s at \$$SPOT_ALL_IN_RATE/h all in, \$$(worst_usd "$SPOT_ALL_IN_RATE"), under \$$COST_CAP_USD"

# ---------------------------------------------------------------- what AWS says, read-only
ami=$(aws ec2 describe-images --region "$REGION" --image-ids "$AMI_ID_FIXED" --query 'Images[0].[Name,State]' --output text 2>&1) ||
  fail "could not describe $AMI_ID_FIXED: $ami"
[ "$ami" = "$AMI_NAME_FIXED	available" ] || fail "$AMI_ID_FIXED is '$ami', not an available '$AMI_NAME_FIXED'"
prices=$(aws ec2 describe-spot-price-history --region "$REGION" --instance-types "$INSTANCE_TYPE_FIXED" \
  --product-descriptions "Linux/UNIX" --start-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --query 'SpotPriceHistory[].[AvailabilityZone,SpotPrice]' --output text 2>&1) || fail "could not read the Spot price: $prices"
printf '%s\n' "$prices" >"$OUT/spot-prices.txt"
# The cheapest zone under the cap first.
ZONES=$(awk -v cap="$MAX_PRICE_FIXED" 'NF == 2 && $2 + 0 > 0 && $2 + 0 <= cap + 0 {print $2, $1}' <<<"$prices" | sort -n | awk '{print $2}' | paste -sd' ')
[ -n "$ZONES" ] || fail "no zone offers $INSTANCE_TYPE_FIXED Spot at or under \$$MAX_PRICE_FIXED/h: $(paste -sd' ' <<<"$prices")"
say "Spot $INSTANCE_TYPE_FIXED under \$$MAX_PRICE_FIXED/h, cheapest first: $ZONES ($(paste -sd' ' <<<"$prices"))"
quota=$(aws service-quotas get-service-quota --region "$REGION" --service-code ec2 --quota-code L-3819A6DF \
  --query 'Quota.Value' --output text 2>&1) || fail "could not read the G and VT Spot quota: $quota"
python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) >= float(sys.argv[2]) else 1)' "$quota" "$TYPE_VCPUS" ||
  fail "the G and VT Spot quota is $quota vCPU and one $INSTANCE_TYPE_FIXED needs $TYPE_VCPUS"
sw_state=$(aws lambda get-function --region "$REGION" --function-name gpu-platform-study-sweeper \
  --query 'Configuration.State' --output text 2>&1) || fail "the termination sweeper could not be read: $sw_state"
[ "$sw_state" = Active ] || fail "the termination sweeper is $sw_state, not Active"
sw_rule=$(aws events describe-rule --region "$REGION" --name gpu-platform-study-sweeper \
  --query '[State,ScheduleExpression]' --output text 2>&1) || fail "the sweeper's rule could not be read: $sw_rule"
[ "$(tr -s '[:space:]' ' ' <<<"$sw_rule" | sed 's/ $//')" = "ENABLED rate(5 minutes)" ] || fail "the sweeper's rule is '$sw_rule', not ENABLED rate(5 minutes)"
sw_target=$(aws events list-targets-by-rule --region "$REGION" --rule gpu-platform-study-sweeper \
  --query 'Targets[].Arn' --output text 2>&1) || fail "the sweeper's targets could not be read: $sw_target"
[ "$sw_target" = "arn:aws:lambda:$REGION:$ACCOUNT:function:gpu-platform-study-sweeper" ] || fail "the sweeper's rule targets '$sw_target', not the sweeper"
sw_sum() {
  local j
  j=$(aws cloudwatch get-metric-statistics --region "$REGION" --namespace AWS/Lambda --metric-name "$1" \
    --dimensions Name=FunctionName,Value=gpu-platform-study-sweeper \
    --start-time "$(date -u -d '-30 min' +%Y-%m-%dT%H:%M:%SZ)" --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --period 1800 --statistics Sum --query 'Datapoints[].Sum' --output json 2>&1) || return 1
  python3 -c 'import json,sys; v=json.loads(sys.argv[1]); assert isinstance(v, list) and all(isinstance(x, (int, float)) for x in v); print(int(sum(v)))' "$j"
}
sw_runs=$(sw_sum Invocations) || fail "the sweeper's invocations could not be read"
sw_errors=$(sw_sum Errors) || fail "the sweeper's errors could not be read"
[ "$sw_runs" -ge "$SWEEPER_MIN_RUNS" ] && [ "$sw_errors" = 0 ] ||
  fail "the sweeper ran $sw_runs time(s) with $sw_errors error(s) in the last 30 minutes; at least $SWEEPER_MIN_RUNS clean runs are required"
say "the termination sweeper: Active, ENABLED rate(5 minutes), $sw_runs run(s) and $sw_errors error(s) in the last 30 minutes"
cred_check() {
  local j exp left
  j=$(aws configure export-credentials --format process 2>&1) || fail "the CLI could not export the active credential: $j"
  exp=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("Expiration",""))' "$j") || fail "the exported credential is not JSON"
  [ -n "$exp" ] || fail "the exported credential carries no expiry, so it cannot be shown to outlast the session"
  left=$(python3 -c 'import datetime,sys; e=datetime.datetime.fromisoformat(sys.argv[1].replace("Z","+00:00")); print(int((e-datetime.datetime.now(datetime.timezone.utc)).total_seconds()//60))' "$exp")
  [ "$left" -ge "$CRED_MIN_MINUTES" ] || fail "$1: the credentials expire in $left minutes; the session needs $CRED_MIN_MINUTES"
  say "$1: credentials expire in $left minutes"
}
cred_check "before the purchase checks"
live=$(aws ec2 describe-instances --region "$REGION" --filters "Name=tag:purpose,Values=$PURPOSE" \
  "Name=instance-state-name,Values=pending,running,shutting-down,stopping,stopped" \
  --query 'Reservations[].Instances[].InstanceId' --output text 2>&1) || fail "could not list earlier instances: $live"
[ -z "$live" ] || fail "an earlier instance of this session is still live ($live); one attempt at a time"

RUN_NONCE=$(python3 -c 'import secrets; print(secrets.token_hex(4))')
RUN_ID="$(basename "$OUT")-$RUN_NONCE"
BUCKET="$STACK-$ACCOUNT"
{
  echo "commit=$COMMIT"
  echo "kit_repo=$KIT_TOP"
  echo "kit_path=$KIT_REL"
  echo "kit_commit=$KIT_COMMIT"
  echo "ami_id=$AMI_ID_FIXED"
  echo "ami_name=$AMI_NAME_FIXED"
  echo "region=$REGION"
  echo "instance_type=$INSTANCE_TYPE_FIXED"
  echo "max_spot_price=$MAX_PRICE_FIXED"
  echo "volume=${VOLUME_GB} GB gp3, ${EBS_THROUGHPUT_MIBPS} MiB/s, ${EBS_IOPS} IOPS"
  echo "all_in_rate=$SPOT_ALL_IN_RATE"
  echo "worst_case_usd=$(worst_usd "$SPOT_ALL_IN_RATE")"
  echo "uv=$UV_VERSION sha256 $UV_SHA256"
  echo "python=$PYTHON_PIN"
  echo "inputs_sha256=$INPUTS_SHA"
  echo "harness_end_from_launch_s=$HARNESS_END_S"
  echo "stop_from_launch_s=$STOP_FROM_LAUNCH_S"
  echo "termination_from_launch_s=$TERMINATION_S"
  echo "run_id=$RUN_ID"
} >"$OUT/session-provenance.txt"
UD="$OUT/user-data.sh"
render_user_data "$UD" "$BUCKET" "$RUN_ID" "$INPUTS_SHA" "$COMMIT" "$RUN_NONCE"

# ---------------------------------------------------------------- the purchase
spot_ensure_bucket "$BUCKET" "$REGION" 30 || fail "could not prepare the results bucket $BUCKET"
ROLE_POLICY="{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"s3:PutObject\",\"s3:GetObject\"],\"Resource\":\"arn:aws:s3:::$BUCKET/*\"}]}"
spot_ensure_profile "$STACK" "$ROLE_POLICY" 20 || fail "could not prepare the instance profile $STACK"
aws iam put-role-policy --role-name "$STACK" --policy-name write-results --policy-document "$ROLE_POLICY" || fail "could not update the instance role's policy"
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
    spot_reconcile_token "$REGION" "$LAUNCH_UNCERTAIN" "$LAUNCH_UNCERTAIN_SUBNET" 6 2>>"$OUT/termination.txt" ||
      { echo "TERMINATION UNCONFIRMED for the launch under token $LAUNCH_UNCERTAIN" | tee -a "$OUT/termination.txt" >&2; exit 1; }
    # The lost launch's own instance, if any, was found by its token and terminated, which is not "nothing was launched".
    echo "the launch under token $LAUNCH_UNCERTAIN lost its answer; every instance under that token was terminated and confirmed" >>"$OUT/termination.txt"
    return 0
  fi
  [ "$TERMINATION" = confirmed ] && return 0
  if [ "$TERMINATION" = unconfirmed ]; then SPOT_TERMINATE_WAIT=60; SPOT_TERMINATE_TRIES=13; fi
  if [ -z "$IID" ]; then
    echo "no instance was launched by this session" >"$OUT/termination.txt"
  else
    end_instance
    # The outcome was written before this retry, so it is brought up to date with the retry's answer.
    [ ! -f "$OUT/outcome.txt" ] || sed -i "s/^termination=.*/termination=$TERMINATION (after the cleanup retry)/" "$OUT/outcome.txt"
    [ "$TERMINATION" = confirmed ] || exit 1
  fi
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

cred_check "before the purchase"
request_epoch=$(date +%s)
TAG_DEADLINE=$(date -u -d "@$(( request_epoch + TAG_AT_LAUNCH_S ))" +%Y-%m-%dT%H:%M:%SZ)
TAGS="ResourceType=instance,Tags=[{Key=Name,Value=$STACK},{Key=purpose,Value=$PURPOSE},{Key=run,Value=$RUN_NONCE},{Key=study-deadline,Value=$TAG_DEADLINE}]"
say "launching $INSTANCE_TYPE_FIXED Spot (cap \$$MAX_PRICE_FIXED/h, \$$SPOT_ALL_IN_RATE/h all in), study-deadline $TAG_DEADLINE -- the instance bills from here"
for z in $ZONES; do
  SUBNET=$(spot_subnet_in_zone "$REGION" "$z") || continue
  token="gpukit-$RUN_NONCE-$z"
  LAUNCH_UNCERTAIN="$token"; LAUNCH_UNCERTAIN_SUBNET="$SUBNET"
  IID=$(spot_launch "$REGION" "$AMI_ID_FIXED" "$INSTANCE_TYPE_FIXED" "$SUBNET" "$STACK" "$MAX_PRICE_FIXED" "$VOLUME_GB" \
    "$UD" "$TAGS" "$token" "" "" "$EBS_THROUGHPUT_MIBPS" "$EBS_IOPS" spot 2>"$OUT/launch-error-$z.txt") || IID=""
  cat "$OUT/launch-error-$z.txt" >>"$OUT/launch-errors.txt"
  if [ -n "$IID" ] && [ "$IID" != None ]; then LAUNCH_UNCERTAIN=""; break; fi
  IID=""
  if command grep -qiE 'InsufficientInstanceCapacity|capacity-not-available' "$OUT/launch-error-$z.txt"; then LAUNCH_UNCERTAIN=""; continue; fi
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
L=$(date -u -d "$LAUNCH_TIME" +%s) || fail "could not read $IID's LaunchTime: $launch"
[ "$(awk '{print $2}' <<<"$launch")" = "$AMI_ID_FIXED" ] || fail "$IID does not run the pinned $AMI_ID_FIXED: $launch"
printf '%s\n' "$LAUNCH_TIME" >"$OUT/launch-time.txt"
printf '%s\n' "$z" >"$OUT/zone.txt"
aws s3 cp --only-show-errors "$OUT/launch-time.txt" "s3://$BUCKET/$RUN_ID/launch-time.txt" ||
  fail "could not hand LaunchTime to the instance; it will stop itself, and this session terminates it"
TAG_FROM_LAUNCH=$(date -u -d "@$(( L + TAG_FROM_LAUNCH_S ))" +%Y-%m-%dT%H:%M:%SZ)
if aws ec2 create-tags --region "$REGION" --resources "$IID" --tags "Key=study-deadline,Value=$TAG_FROM_LAUNCH" 2>>"$OUT/launch-errors.txt"; then
  say "LaunchTime $LAUNCH_TIME; the sweeper's deadline moved to $TAG_FROM_LAUNCH"
else
  say "LaunchTime $LAUNCH_TIME; the sweeper's deadline could not be moved and stays at $TAG_DEADLINE"
fi

# ---------------------------------------------------------------- the wait, and the end
spot_wait_for_marker_until "$REGION" "$BUCKET" "$RUN_ID/DONE" "$IID" $(( L + STOP_FROM_LAUNCH_S )) "$WAIT_INTERVAL_S" "$WAIT_ATTEMPTS" >"$OUT/wait.txt"
wait_rc=$?
say "the wait ended with status $wait_rc ($(cat "$OUT/wait.txt"))"
SPOT_TERMINATE_WAIT=$(( L + TERMINATION_S - $(date +%s) ))
[ "$SPOT_TERMINATE_WAIT" -ge 0 ] || SPOT_TERMINATE_WAIT=0
SPOT_TERMINATE_TRIES=$(( SPOT_TERMINATE_WAIT / 5 + 1 ))
export SPOT_TERMINATE_WAIT SPOT_TERMINATE_TRIES
say "waiting up to ${SPOT_TERMINATE_WAIT}s for EC2 to report the instance terminated"
end_instance
for k in evidence.tgz partial.tgz log.txt preflight-nvidia-smi.csv DONE; do
  aws s3 cp --only-show-errors "s3://$BUCKET/$RUN_ID/$k" "$OUT/$k" 2>>"$OUT/download-errors.txt" || echo "not downloaded: $k" >>"$OUT/download-errors.txt"
done
EVIDENCE=missing
if [ -s "$OUT/evidence.tgz" ] && tar -xzf "$OUT/evidence.tgz" -C "$OUT"; then
  EVIDENCE=returned
elif [ -s "$OUT/partial.tgz" ] && tar -xzf "$OUT/partial.tgz" -C "$OUT"; then
  EVIDENCE=partial
fi
KIT_RC=$(command grep -m1 '^kit_rc=' "$OUT/run/instance-provenance.txt" 2>/dev/null | cut -d= -f2)
{
  echo "evidence=$EVIDENCE"
  echo "termination=$TERMINATION"
  echo "kit_rc=${KIT_RC:-none}"
  echo "instance=$IID zone=$z launch_time=$LAUNCH_TIME"
} >"$OUT/outcome.txt"
[ ! -s "$OUT/run/run-output.log" ] || { echo "-- the last 40 lines of run.sh's output"; tail -n 40 "$OUT/run/run-output.log"; }
cat "$OUT/outcome.txt"
say "evidence $EVIDENCE; termination $TERMINATION; run.sh exit ${KIT_RC:-none}"
[ "$TERMINATION" = confirmed ] || exit 1
[ "$EVIDENCE" = returned ] || exit 1
# Exit 0 says run.sh exited 0, not that the kit's experiment succeeded; a kit that swallows its own failures is read from its results.
[ "${KIT_RC:-}" = 0 ] || exit 2
exit 0
