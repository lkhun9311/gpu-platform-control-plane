#!/usr/bin/env bash
#
# kubernetes-sigs/dra-driver-nvidia-gpu on one real GPU: one g6.xlarge (L4) Spot instance, g5.xlarge (A10G) if no zone
# has g6 capacity, one attempt, stopped by itself 5,400 s after launch.
#
#   SESSION_CONFIRM=yes AWS_PROFILE=gpu-lab DRA_GPU_AMI_ID=ami-... bash hack/dra-nvidia-gpu-session.sh
#
# The plan is storage/open-source/contributions/k8s-sigs/dra-driver-nvidia-gpu/gpu-plan.md.
# It answers on real NVML, with no NVLink or IMEX, what the CPU-only and mock-NVML runs could not:
#   S4  upstream's own single-GPU bats files (basic, robustness, sharing), so S1-S3 mean something; a failure stops the run
#   S1  #1278: a PrepareCompleted claim whose pod and claim are deleted while the plugin is down, three times
#   S2  #1639's trigger: SIGKILL while an MPS claim is in PrepareStarted, then what survives, three times
#   S3  #1572: two 4Gi claims under ConsumableShares memory mode on one GPU
# The instance runs only hack/dra-nvidia-gpu/runner.sh and its phases, against upstream at a pinned commit.
# It shares its EC2 lifecycle with the vLLM sessions (hack/lib/spot-run.sh) and is modelled on hack/vllm-67811-session.sh.
#
# THE CLOCK.
# Every deadline counts from EC2's LaunchTime, read right after the launch and written to the run's S3 prefix for the
# instance to read.
# The work is bounded phase by phase, and the deadlines are their sum:
#   boot, cloud-init, inputs, LaunchTime, GPU preflight                   420 s -> 420
#   cluster: upstream checkout, setup-nvkind-node.sh                      840 s
#   build: driver image, kind load                                        720 s
#   S4 bats baseline (runner image and three files)                     1,020 s
#   S1 three repetitions                                                  960 s
#   S2 three repetitions                                                  900 s
#   S3                                                                    360 s
#   so the runner ends by 420 + 840 + 720 + 1,020 + 960 + 900 + 360     = 5,220 s
#   evidence upload                                                       120 s -> 5,340
# The launch carries the termination sweeper's study-deadline tag at the request plus 5,340 s, rewritten to LaunchTime
# plus 5,370 s once LaunchTime is known; the instance shuts itself down at 5,400 s, the plan's 90-minute backstop; the
# termination is to be confirmed by 5,700 s, the plan's 95-minute laptop deadline, which is the sweeper's five-minute
# period after its tag plus 30 s.
#
# THE COST.
# The worst case bills to the termination deadline: 5,700 s = 1.5833 h.
# The Spot cap is each type's Seoul on-demand price (AWS Price List, 2026-11-18): g6.xlarge $0.9896/h, capped at $0.99;
# g5.xlarge $1.237/h, capped at $1.24.
# A 100 GB gp3 volume at Seoul's $0.0912 per GB-month over 730 h is $0.0125/h, and a public IPv4 is $0.005/h: $0.0175/h.
# The all-in rate is the higher cap plus that, $1.2575/h, whichever type launches, and the worst case is $1.9910.
# The script refuses to run if the constants below stop giving a worst case under $5, or if the all-in rate is under
# either cap plus the volume and the address.
# Expected, at 2026-11-18's g6.xlarge Spot of about $0.47/h: 1.5 h x ($0.4717 + $0.0175) = about $0.73.
#
# NOTHING HERE IS A DEFAULT A CALLER CAN MOVE: the instances, the commit, the phases, the bounds and the stop are
# constants, and a caller who sets one is refused rather than ignored.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

# ---------------------------------------------------------------- refusals, before anything is built or bought
# Read before the constants below are assigned, since several share a name with what a caller might export.
for v in INSTANCE_TYPE INSTANCE_TYPES MAX_SPOT_PRICE MAX_PRICE_G6 MAX_PRICE_G5 ALL_IN_RATE HARD_STOP_SECONDS \
  BACKSTOP_SECONDS DRA_COMMIT DRA_REPO K8S_VERSION SCENARIOS PHASES BATS_FILES TEST_FILTER_TAGS; do
  if [ -n "${!v:-}" ]; then echo "SESSION REFUSED: $v is set, and this session's value for it is its registration's; unset it" >&2; exit 1; fi
done

REGION=ap-northeast-2
ACCOUNT_WANT=007635145730
# In the order tried: the L4 first, the A10G only if no zone has an L4 at or under its cap.
INSTANCE_TYPES="g6.xlarge g5.xlarge"
MAX_PRICE_G6=0.99
MAX_PRICE_G5=1.24
# 100 GB gp3 ($0.0125/h) and a public IPv4 ($0.005/h).
EXTRAS_RATE=0.0175
# The higher cap plus the extras.
ALL_IN_RATE=1.2575
COST_CAP_USD=5.00
VOLUME_GB=100
STUDY_ID=dra-nvidia-gpu-single-2026-11-18
STACK=dra-gpu
PURPOSE=dra-nvidia-gpu-single
# The upstream commit the runner checks out; hack/dra-nvidia-gpu-session-test.sh holds the two equal.
DRA_REPO=https://github.com/kubernetes-sigs/dra-driver-nvidia-gpu
DRA_COMMIT=e775fdb63e593a121b40fc1cc4c9a9c89955e635
# Every upstream file a phase runs or reads; each is checked to exist at the commit before anything is bought.
UPSTREAM_PATHS="hack/ci/gcp-nvkind/lib/setup-nvkind-node.sh
hack/ci/gcp-nvkind/lib/nvkind-config.yaml.tmpl
deployments/container/Makefile
deployments/helm/dra-driver-nvidia-gpu/Chart.yaml
tests/bats/Makefile
tests/bats/test_gpu_basic.bats
tests/bats/test_gpu_robustness.bats
tests/bats/test_gpu_sharing.bats
tests/bats/lib/lambda/nvmm
demo/specs/quickstart/v1/gpu-test-mps.yaml"
RUNNER_DIR=hack/dra-nvidia-gpu
PHASES="cluster build s4 s1 s2 s3"
# The phase bounds, each the runner's own; the offline test holds the two equal.
BOOT_S=420
CLUSTER_S=840
BUILD_S=720
S4_S=1020
S1_S=960
S2_S=900
S3_S=360
EVIDENCE_UPLOAD_S=120
HARNESS_END_S=$(( BOOT_S + CLUSTER_S + BUILD_S + S4_S + S1_S + S2_S + S3_S ))
EVIDENCE_S=$(( HARNESS_END_S + EVIDENCE_UPLOAD_S ))
TAG_AT_LAUNCH_S=$EVIDENCE_S
TAG_FROM_LAUNCH_S=$(( EVIDENCE_S + 30 ))
STOP_FROM_LAUNCH_S=$(( EVIDENCE_S + 60 ))
TERMINATION_S=$(( TAG_FROM_LAUNCH_S + 330 ))
LAUNCHTIME_WAIT_S=180
# The DONE wait polls every WAIT_INTERVAL_S, so this many attempts outlast the stop and the wall clock ends the wait.
WAIT_INTERVAL_S=20
WAIT_ATTEMPTS=$(( STOP_FROM_LAUNCH_S / WAIT_INTERVAL_S + 2 ))
SWEEPER_MIN_RUNS=4
# The session's end of the termination wait plus 30 minutes of headroom, in minutes.
CRED_MIN_MINUTES=$(( TERMINATION_S / 60 + 30 ))

OUT="${OUT:-hack/dra-nvidia-gpu-$(date -u +%Y%m%dT%H%M%SZ)}"
say() { echo "== $*" | { if [ -d "$OUT" ]; then tee -a "$OUT/session.log"; else cat; fi; }; }
fail() { echo "SESSION REFUSED: $*" | { if [ -d "$OUT" ]; then tee -a "$OUT/session.log"; else cat; fi; } >&2; exit 1; }
spot_say() { say "$@"; }
spot_fail() { fail "$@"; }
max_price() { case $1 in g6.xlarge) echo "$MAX_PRICE_G6" ;; g5.xlarge) echo "$MAX_PRICE_G5" ;; *) return 1 ;; esac; }

# The all-in rate is what the worst case is computed from, so a cap raised without it would understate the bill.
python3 -c 'import sys; r, x = float(sys.argv[1]), float(sys.argv[2]); sys.exit(0 if all(r >= float(c) + x - 1e-9 for c in sys.argv[3:]) else 1)' \
  "$ALL_IN_RATE" "$EXTRAS_RATE" "$MAX_PRICE_G6" "$MAX_PRICE_G5" ||
  fail "the all-in rate \$$ALL_IN_RATE/h is under a Spot cap (\$$MAX_PRICE_G6, \$$MAX_PRICE_G5) plus \$$EXTRAS_RATE/h"
python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) / 3600 * float(sys.argv[2]) < float(sys.argv[3]) else 1)' \
  "$TERMINATION_S" "$ALL_IN_RATE" "$COST_CAP_USD" ||
  fail "the worst case, $TERMINATION_S s at \$$ALL_IN_RATE/h, is not under \$$COST_CAP_USD"
WORST_USD=$(python3 -c 'import sys; print("%.4f" % (float(sys.argv[1]) / 3600 * float(sys.argv[2])))' "$TERMINATION_S" "$ALL_IN_RATE")
# The schedule alone, with nothing checked or bought, so the offline test can hold it to the runner's bounds.
if [ "${1:-}" = --print-schedule ]; then
  echo "harness_end_s=$HARNESS_END_S evidence_s=$EVIDENCE_S stop_s=$STOP_FROM_LAUNCH_S termination_s=$TERMINATION_S worst_usd=$WORST_USD"
  exit 0
fi
[ "${SESSION_CONFIRM:-}" = yes ] || fail "SESSION_CONFIRM=yes is required: this buys a GPU instance, and only the owner's approval starts one"
[[ "${DRA_GPU_AMI_ID:-}" =~ ^ami-[0-9a-f]{8,17}$ ]] ||
  fail "DRA_GPU_AMI_ID is ${DRA_GPU_AMI_ID:-unset}; the session pins the AMI by ID rather than resolving it from latest"
for tool in aws python3 git tar sha256sum jq; do command -v "$tool" >/dev/null || fail "$tool is not installed"; done
[ -z "$(git status --porcelain)" ] || fail "the working tree is dirty; the run's provenance is a commit, and the runner is shipped from this tree"
COMMIT=$(git rev-parse HEAD)
for p in runner.sh lib.sh s4.mk $(for ph in $PHASES; do echo "$ph.sh"; done); do
  [ -f "$RUNNER_DIR/$p" ] || fail "$RUNNER_DIR/$p is missing"
  case $p in *.sh) bash -n "$RUNNER_DIR/$p" 2>/dev/null || fail "$RUNNER_DIR/$p does not parse" ;; esac
done
[ "$(sed -n 's/^DRA_COMMIT=//p' "$RUNNER_DIR/runner.sh")" = "$DRA_COMMIT" ] || fail "the runner does not check out $DRA_COMMIT"
ACCOUNT=$(aws sts get-caller-identity --query Account --output text 2>&1) || fail "could not read the caller's account: $ACCOUNT"
[ "$ACCOUNT" = "$ACCOUNT_WANT" ] || fail "the credentials are for account $ACCOUNT; paid sessions run only in gpu-lab ($ACCOUNT_WANT)"
[ ! -e "$OUT" ] || fail "$OUT already exists; each session writes a new directory"
mkdir -p "$OUT" || fail "cannot create $OUT"
say "dra-driver-nvidia-gpu S4, S1, S2, S3 for $STUDY_ID, from $COMMIT, into $OUT"
say "hard stop $STOP_FROM_LAUNCH_S s after LaunchTime; worst case $TERMINATION_S s at \$$ALL_IN_RATE/h = \$$WORST_USD"

# The upstream commit is fetched here first, so a commit GitHub does not serve, or a file it lacks, costs nothing.
UP="$OUT/upstream.git"
git init -q --bare "$UP" || fail "cannot create $UP"
git -C "$UP" fetch -q --depth 1 "$DRA_REPO" "$DRA_COMMIT" 2>"$OUT/upstream-fetch.err" ||
  fail "could not fetch $DRA_COMMIT from $DRA_REPO; see $OUT/upstream-fetch.err"
while read -r p; do
  blob=$(git -C "$UP" rev-parse -q --verify "$DRA_COMMIT:$p") || fail "$p is not in $DRA_COMMIT"
  echo "$blob  $p"
done <<<"$UPSTREAM_PATHS" >"$OUT/upstream-files.txt"
rm -rf "$UP"
say "upstream $DRA_COMMIT has the $(wc -l <"$OUT/upstream-files.txt") files the phases use"

mkdir -p "$OUT/in" || fail "cannot create $OUT/in"
cp "$RUNNER_DIR"/runner.sh "$RUNNER_DIR"/lib.sh "$RUNNER_DIR"/s4.mk "$OUT/in/" || fail "copy the runner"
for ph in $PHASES; do cp "$RUNNER_DIR/$ph.sh" "$OUT/in/" || fail "copy $ph.sh"; done
tar -czf "$OUT/inputs.tgz" -C "$OUT/in" . || fail "pack the inputs"

# shellcheck source=hack/lib/spot-run.sh
. hack/lib/spot-run.sh

ami_name=$(aws ec2 describe-images --region "$REGION" --image-ids "$DRA_GPU_AMI_ID" \
  --query 'Images[0].[Name,State]' --output text 2>&1) || fail "could not describe $DRA_GPU_AMI_ID: $ami_name"
case "$ami_name" in
  "Deep Learning Base OSS Nvidia Driver GPU AMI (Ubuntu 22.04)"*available) ;;
  *) fail "$DRA_GPU_AMI_ID is '$ami_name', not an available Deep Learning Base OSS Nvidia Driver GPU AMI (Ubuntu 22.04)" ;;
esac
say "AMI $DRA_GPU_AMI_ID: $ami_name"

# Type:zone pairs at or under each type's cap, the L4 first.
CANDIDATES=""
# A zone that reclaimed an earlier study is tried after the others of its type, and still tried.
RECLAIMED_ZONES="ap-northeast-2a"
for t in $INSTANCE_TYPES; do
  cap=$(max_price "$t")
  prices=$(aws ec2 describe-spot-price-history --region "$REGION" --instance-types "$t" \
    --product-descriptions "Linux/UNIX" --start-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --query 'SpotPriceHistory[].[AvailabilityZone,SpotPrice]' --output text 2>&1) || fail "could not read the $t Spot price: $prices"
  printf '%s %s\n' "$t" "$(paste -sd' ' <<<"$prices")" >>"$OUT/spot-prices.txt"
  zones=$(awk -v cap="$cap" 'NF == 2 && $2 + 0 > 0 && $2 + 0 <= cap + 0 {print $1}' <<<"$prices" | sort -u)
  for z in $zones; do case " $RECLAIMED_ZONES " in *" $z "*) ;; *) CANDIDATES="$CANDIDATES $t:$z" ;; esac; done
  for z in $zones; do case " $RECLAIMED_ZONES " in *" $z "*) CANDIDATES="$CANDIDATES $t:$z" ;; esac; done
done
CANDIDATES="${CANDIDATES# }"
[ -n "$CANDIDATES" ] || fail "no zone offers $INSTANCE_TYPES Spot at or under its cap: $(paste -sd';' "$OUT/spot-prices.txt")"
say "Spot candidates, in order: $CANDIDATES"

quota=$(aws service-quotas get-service-quota --region "$REGION" --service-code ec2 --quota-code L-3819A6DF \
  --query 'Quota.Value' --output text 2>&1) || fail "could not read the G and VT Spot quota: $quota"
python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) >= 4 else 1)' "$quota" ||
  fail "the G and VT Spot quota is $quota vCPU and one xlarge needs 4"

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

# Run twice: here, and again just before the purchase.
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
  echo "ami_id=$DRA_GPU_AMI_ID"
  echo "ami_name=$ami_name"
  echo "candidates=$CANDIDATES"
  echo "max_spot_price_g6=$MAX_PRICE_G6"
  echo "max_spot_price_g5=$MAX_PRICE_G5"
  echo "all_in_rate=$ALL_IN_RATE"
  echo "worst_case_usd=$WORST_USD"
  echo "inputs_sha256=$INPUTS_SHA"
  echo "dra_commit=$DRA_COMMIT"
  echo "harness_end_from_launch_s=$HARNESS_END_S"
  echo "stop_from_launch_s=$STOP_FROM_LAUNCH_S"
  echo "termination_from_launch_s=$TERMINATION_S"
  echo "run_id=$RUN_ID"
} >"$OUT/session-provenance.txt"

UD="$OUT/user-data.sh"
cat >"$UD.template" <<'UD'
#!/bin/bash
( sleep STOP_FROM_LAUNCH_S_PLACEHOLDER; shutdown -h now ) >/dev/null 2>&1 &
# The line above is the first thing the instance runs, so no failure below can leave it running past the stop.
# It counts from the instance's own start; LaunchTime precedes that, so the precise backstop armed below fires first.
exec > >(tee /var/log/dra.log) 2>&1
set -x
SR_START=$(date +%s)
BUCKET="BUCKET_PLACEHOLDER"
PREFIX="RUN_ID_PLACEHOLDER"
upload() { timeout 60 aws s3 cp --only-show-errors "$1" "s3://$BUCKET/$PREFIX/$2" || true; }
trap 'upload /var/log/dra.log log.txt; shutdown -h now' EXIT
mkdir -p /opt/dra/in /src/dra-run || exit 1
aws s3 cp --only-show-errors "s3://$BUCKET/$PREFIX/inputs.tgz" /opt/dra/inputs.tgz || exit 1
[ "$(sha256sum /opt/dra/inputs.tgz | cut -d' ' -f1)" = "INPUTS_SHA_PLACEHOLDER" ] || { echo "checksum mismatch for inputs.tgz"; exit 1; }
tar -xzf /opt/dra/inputs.tgz -C /opt/dra/in || exit 1
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
( sleep $(( L + STOP_FROM_LAUNCH_S_PLACEHOLDER - $(date +%s) > 0 ? L + STOP_FROM_LAUNCH_S_PLACEHOLDER - $(date +%s) : 1 )); shutdown -h now ) >/dev/null 2>&1 &
BOOT_END=$(( L + BOOT_S_PLACEHOLDER )); HE=$(( L + HARNESS_END_S_PLACEHOLDER )); EV=$(( L + EVIDENCE_S_PLACEHOLDER ))
nvidia-smi --query-gpu=index,name,memory.total,driver_version,compute_mode --format=csv > /tmp/nvidia-smi.csv || exit 1
upload /tmp/nvidia-smi.csv preflight-nvidia-smi.csv
[ "$(tail -n +2 /tmp/nvidia-smi.csv | wc -l)" = 1 ] && tail -n +2 /tmp/nvidia-smi.csv | grep -qE 'NVIDIA (L4|A10G),' ||
  { echo "PREFLIGHT FAILED: not one L4 or A10G"; exit 1; }
cp /tmp/nvidia-smi.csv /src/dra-run/nvidia-smi.csv
{ echo "launch_time_epoch=$L"; sha256sum /opt/dra/inputs.tgz; } > /src/dra-run/instance-provenance.txt
if [ "$(date +%s)" -lt "$BOOT_END" ]; then
  # The phases' bounds sum to HE; this timeout only stops a runner that overran them from eating the upload.
  UPLOAD_PREFIX="s3://$BUCKET/$PREFIX" timeout --kill-after=15 $(( HE - $(date +%s) > 5 ? HE - $(date +%s) : 5 )) \
    bash /opt/dra/in/runner.sh /opt/dra/in /src/dra-run/run "$HE" > /src/dra-run/summary.txt 2>&1
  echo "harness_rc=$?" >> /src/dra-run/instance-provenance.txt
  cat /src/dra-run/summary.txt
else
  echo "the boot ran past its phase; nothing else runs" | tee /src/dra-run/VOID
fi
cp /var/log/dra.log /src/dra-run/instance.log
left=$(( EV - $(date +%s) )); [ "$left" -gt 5 ] || left=5
tar --warning=no-file-changed -czf /tmp/evidence.tgz -C /src dra-run
[ $? -le 1 ] && timeout "$left" aws s3 cp --only-show-errors /tmp/evidence.tgz "s3://$BUCKET/$PREFIX/evidence.tgz"
upload /var/log/dra.log log.txt
echo "RUN_NONCE_PLACEHOLDER" > /tmp/DONE
upload /tmp/DONE DONE
UD
sed -e "s|BUCKET_PLACEHOLDER|$BUCKET|" -e "s|RUN_ID_PLACEHOLDER|$RUN_ID|" -e "s|INPUTS_SHA_PLACEHOLDER|$INPUTS_SHA|" \
  -e "s|RUN_NONCE_PLACEHOLDER|$RUN_NONCE|" -e "s|LAUNCHTIME_WAIT_S_PLACEHOLDER|$LAUNCHTIME_WAIT_S|" \
  -e "s|STOP_FROM_LAUNCH_S_PLACEHOLDER|$STOP_FROM_LAUNCH_S|g" -e "s|BOOT_S_PLACEHOLDER|$BOOT_S|" \
  -e "s|HARNESS_END_S_PLACEHOLDER|$HARNESS_END_S|" -e "s|EVIDENCE_S_PLACEHOLDER|$EVIDENCE_S|" \
  "$UD.template" >"$UD" || fail "could not render the user-data"
rm -f "$UD.template"
! grep -q '_PLACEHOLDER' "$UD" || fail "the user-data still holds a placeholder: $(grep -o '[A-Z_]*_PLACEHOLDER' "$UD" | sort -u | paste -sd' ')"
[ "$(head -c 2 "$UD")" = '#!' ] || fail "the user-data does not begin with a shebang, so cloud-init would not run it"
[ "$(sed -n 2p "$UD")" = "( sleep $STOP_FROM_LAUNCH_S; shutdown -h now ) >/dev/null 2>&1 &" ] ||
  fail "the user-data's first command is not the shutdown backstop"
bash -n "$UD" || fail "the user-data does not parse"
[ "$(wc -c <"$UD")" -lt 16384 ] || fail "the user-data is $(wc -c <"$UD") bytes, over EC2's 16 KB limit"

# ---------------------------------------------------------------- the purchase
spot_ensure_bucket "$BUCKET" "$REGION" 30 || fail "could not prepare the results bucket $BUCKET"
ROLE_POLICY="{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"s3:PutObject\",\"s3:GetObject\"],\"Resource\":\"arn:aws:s3:::$BUCKET/*\"}]}"
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
say "launching one of $CANDIDATES (\$$ALL_IN_RATE/h all in at worst), study-deadline $TAG_DEADLINE -- the instance bills from here"
TYPE=""
for c in $CANDIDATES; do
  t=${c%%:*} z=${c#*:}
  SUBNET=$(spot_subnet_in_zone "$REGION" "$z") || continue
  token="dragpu-$RUN_NONCE-$t-$z"
  LAUNCH_UNCERTAIN="$token"; LAUNCH_UNCERTAIN_SUBNET="$SUBNET"
  IID=$(spot_launch "$REGION" "$DRA_GPU_AMI_ID" "$t" "$SUBNET" "$STACK" "$(max_price "$t")" "$VOLUME_GB" \
    "$UD" "$TAGS" "$token" 2>"$OUT/launch-error-$t-$z.txt") || IID=""
  cat "$OUT/launch-error-$t-$z.txt" >>"$OUT/launch-errors.txt"
  if [ -n "$IID" ] && [ "$IID" != None ]; then LAUNCH_UNCERTAIN=""; TYPE=$t; break; fi
  IID=""
  if grep -qiE 'InsufficientInstanceCapacity|capacity-not-available' "$OUT/launch-error-$t-$z.txt"; then LAUNCH_UNCERTAIN=""; continue; fi
  fail "the $t launch in $z was refused for a reason that is not capacity; see $OUT/launch-errors.txt"
done
[ -n "$IID" ] || fail "no candidate had Spot capacity; nothing was launched"
echo "$IID" >"$OUT/instance-id"
echo "instance_type=$TYPE" >>"$OUT/session-provenance.txt"
say "launched $IID, $TYPE in $z"

launch=""
for _ in $(seq 1 12); do
  launch=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$IID" \
    --query 'Reservations[0].Instances[0].[LaunchTime,ImageId]' --output text 2>&1) && [ -n "${launch%%[[:space:]]*}" ] && break
  sleep 5
done
LAUNCH_TIME=$(awk '{print $1}' <<<"$launch")
IMAGE_ID=$(awk '{print $2}' <<<"$launch")
L=$(date -u -d "$LAUNCH_TIME" +%s) || fail "could not read $IID's LaunchTime: $launch"
[ "$IMAGE_ID" = "$DRA_GPU_AMI_ID" ] || fail "$IID runs $IMAGE_ID, not the pinned $DRA_GPU_AMI_ID"
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
for k in evidence.tgz log.txt preflight-nvidia-smi.csv DONE $(for ph in $PHASES; do echo "phase-$ph.tgz"; done); do
  aws s3 cp --only-show-errors "s3://$BUCKET/$RUN_ID/$k" "$OUT/$k" 2>>"$OUT/download-errors.txt" || echo "not downloaded: $k" >>"$OUT/download-errors.txt"
done
EVIDENCE=missing
RUN="$OUT/dra-run/run"
if [ -s "$OUT/evidence.tgz" ] && tar -xzf "$OUT/evidence.tgz" -C "$OUT" && [ -s "$RUN/summary.tsv" ]; then
  EVIDENCE=returned
else
  # Without the final archive, the per-phase copies are what a reclaim or a crash left; they are reported as partial.
  echo "the evidence archive was not returned or did not unpack" >>"$OUT/download-errors.txt"
  RUN="$OUT/dra-run-partial"
  mkdir -p "$RUN"
  for ph in $PHASES; do
    [ -s "$OUT/phase-$ph.tgz" ] && tar -xzf "$OUT/phase-$ph.tgz" -C "$RUN" 2>>"$OUT/download-errors.txt" && EVIDENCE=partial
  done
fi
phase_rc() { awk -F'\t' -v p="$1" '$1 == p {print $2}' "$RUN/summary.tsv" 2>/dev/null | tail -1; }
S4_RC=$(phase_rc s4)
{
  echo "evidence=$EVIDENCE"
  echo "termination=$TERMINATION"
  for ph in $PHASES; do echo "$ph=$(phase_rc "$ph")"; done
} >"$OUT/outcome.txt"
[ ! -s "$OUT/dra-run/summary.txt" ] || cat "$OUT/dra-run/summary.txt"
say "evidence $EVIDENCE in $RUN; termination $TERMINATION; phases: $(grep -E '^(cluster|build|s[1-4])=' "$OUT/outcome.txt" | paste -sd' ')"
[ "$TERMINATION" = confirmed ] || exit 1
# A paid session whose summary never came back has not delivered what it bought.
[ "$EVIDENCE" = returned ] || exit 1
# A rig that failed upstream's own baseline ran nothing else, and says so by its status.
[ "$S4_RC" = 0 ] || exit 3
for ph in s1 s2 s3; do [ "$(phase_rc "$ph")" = 0 ] || exit 2; done
exit 0
