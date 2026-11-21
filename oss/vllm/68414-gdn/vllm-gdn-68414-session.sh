#!/usr/bin/env bash
#
# vLLM run 4 of the FLA fixes: one g5.xlarge, one attempt, stopped by itself 2,520 s after launch.
# It runs one item: #68416 (state-index token stride) BEFORE and AFTER.
#
#   PURCHASE=spot SESSION_CONFIRM=yes AWS_PROFILE=gpu-lab VLLMGDN_AMI_ID=ami-... bash oss/vllm/68414-gdn/vllm-gdn-68414-session.sh
#   PURCHASE=on-demand SESSION_CONFIRM=yes AWS_PROFILE=gpu-lab VLLMGDN_AMI_ID=ami-... bash oss/vllm/68414-gdn/vllm-gdn-68414-session.sh
#
# PURCHASE has no default: Spot is cheaper, and run 1 lost its last records to a Spot reclaim 16 minutes in, so the owner picks one each time.
#
# WHY RUN 4.
# Run 3 (oss/vllm/68414-gdn/runs/2026-11-19-run3-kda-confirmed-stride-void) confirmed #68415 and voided #68416 on its import check.
# #68416's collection loaded vllm/v1/core/kv_cache_planning.py and vllm/v1/engine/detokenizer.py, which differ between run 3's image, 428c371b32, and #68416's diff base, 545ef08189.
# Its tests themselves gave the expected results there, but a run whose test process loaded files other than the diff base's cannot stand as the diff's evidence.
# Run 3's static import closure had missed both files, since the collection reaches them through imports the closure does not follow; the probe on the instance caught them.
# So run 4 runs #68416 alone on an image whose tree differs from 545ef08189 only in one recipe yaml.
# #68414 and #68415 are not part of run 4: state.sh, verdict.py, kda-state.sh, kda-verdict.py and their pins and diffs stay as runs 2 and 3 ran them, and none is shipped or judged.
#
# THE ITEM.
# The diffs are the runtime session's, in storage/open-source/contributions/vllm (its commit f11148fc), byte for byte and pinned below by sha256.
# stride-fix.diff is commit 541d8b9771 on 545ef08189, and stride-test.diff is its test-file part alone.
# The test is test_state_index_table_stride_does_not_change_results in tests/kernels/fla/test_fused_sigmoid_gating_delta_rule.py, with cases recurrent, sigmoid_gating and kda.
# BEFORE runs `-k stride` and all three must fail; AFTER runs `-k stride`, all three must pass, and then the whole file, all 21 of whose cases must pass.
#
# THE IMAGE.
# vLLM CI publishes a test image per main commit, tagged by the commit, in public.ecr.aws/q9t5s3a7/vllm-ci-postmerge-repo.
# Run 4 uses 3e469e9ffb's, pinned by digest in the runner, since CI published no image for 545ef08189, the commit after it.
# `git diff --name-only 3e469e9ffb 545ef08189` lists only recipes/models/deepseek-ai/DeepSeek-V4.1-Flash.yaml, which stride-differs.txt holds.
# The offline test checks that list against run 3's recorded collection and against the static closure, and each state checks it on the instance: a pytest collection with the run's own selection lists every vllm and tests file it loaded, and a run that loaded one of them is void.
# The collection shows what pytest imports before any test runs; a module a test imports only while it runs is not in it.
# It compares paths, not contents: the image is CI's build of its commit, whose label the runner checks and whose wheel hash it records without verifying, and only the eight files that matter are hashed against git by the pins.
# So what is established is that the image's declared revision has the diff base's tracked code but for the recipe, not that every installed file matches git.
# The image installs the wheel, copies the checkout's vllm/v1 over the installed package, and moves the checkout's vllm/ aside.
# So oss/vllm/68414-gdn/lib.sh applies each diff in two parts, vllm/* to the installed package and the rest to the checkout, and records each command and its targets.
#
# ISOLATION.
# Each state runs in its own fresh container, and the pins name the same eight files as run 3's: the three items' sources and tests, and torch_utils.py.
# So each state proves that neither #68414's nor #68415's fix or test reached it.
# The exit status is 0 only when the verdict is confirmed, and outcome.txt names it.
#
# It shares its EC2 lifecycle with the other paid sessions (hack/lib/spot-run.sh).
#
# THE CLOCK.
# Every deadline counts from EC2's LaunchTime, read right after the launch and written to the run's S3 prefix for the instance to read.
# Run 3 measured: bring-up 111 s, pull 1,051 s, image identity 7 s, and for #68416 setup 37 s cold and 11 s warm, collection 45 s cold and 16 s warm, pytest 20 and 18 s, the whole file 28 s.
# The bounds are those with room, and the deadlines are their sum:
#   bring-up (runs 1 to 3: 121, 116, 111 s)                                     240 s
#   image pull (592, 672, 745, 1,051 and 1,094 s so far)                       1,500 s
#   image identity (25, 19, 7 s)                                                 60 s
#   #68416 BEFORE: setup 60 + collection 90 + pytest 60 + stop 30              240 s
#   #68416 AFTER: setup 60 + collection 90 + pytest 60 + whole file 120 + stop 30   360 s
#   so the runner ends by 240 + 1,500 + 60 + 240 + 360                     = 2,400 s
#   evidence upload (run 2 2 to 4 s)                                            60 s -> 2,460
# The pull bound grows from 1,200 s, because run 3's 1,051 s came within 150 s of it; every other bound shrinks to about twice its slowest measurement.
# The launch carries the termination sweeper's study-deadline tag at the request plus 2,460 s, rewritten to LaunchTime plus 2,490 s once LaunchTime is known.
# The instance shuts itself down at 2,520 s, and the termination is to be confirmed by 2,820 s, the sweeper's five-minute period after its tag plus 30 s.
# Both purchase options use the same clock, tags and sweeper, which terminates by the tag alone, whatever the instance's market.
#
# THE COST.
# The worst case bills to the termination deadline: 2,820 s.
# It assumes EC2 confirms the termination by then; one that is not confirmed is reported as such, and billing past it is not bounded here.
# Both options add $0.0324/h for 200 GB gp3 and a public IPv4, and $0.0468/h for 500 MiB/s and 6,000 IOPS, as the TPOT session measured.
# spot: the $0.70/h Spot cap, so $0.7792/h all in, and $0.6104.
# on-demand: g5.xlarge in ap-northeast-2 is read from the AWS Price List API before anything is bought, and the pinned $1.237/h is used only when that read fails.
# At $1.237/h it is $1.3162/h all in, and $1.0310; any compute rate above $1.8356/h puts the worst case at $1.50 or more, and the session refuses it.
# The script refuses to run if the constants below stop giving a worst case under $1.50 for either option.
#
# REFUSED DIFFS.
# An adversarial pass on 2026-11-19 found #68416's first run-3 diffs, 6bf23529 and abbfbaf3 from commit efdbec4e2d, unfit for a paid run, and the session still refuses them by hash.
# Their kda case gives q and k one head and v two, and the unfixed kda.py both states keep allocates 1 x 6 x 1 x 64 = 384 output elements while the kernel writes 6 x 2 x 64 = 768.
# The same case draws gk inside the layout loop, so the two layouts get different gates, and AFTER cannot pass the exact comparison whatever the stride fix does.
# Commit 541d8b9771 replaced them: its kda case gives q2 and k2 two heads as v has, so H x K = HV x V = 128 and the unfixed allocation is the size the kernel writes.
# It also draws gk once, before the layout loop, so both layouts get the same inputs.
#
# NOTHING HERE IS A DEFAULT A CALLER CAN MOVE: the instance, the build, the diffs, the bounds and the stop are constants, and a caller who sets one is refused rather than ignored.
set -uo pipefail
cd "$(dirname "$0")/../../.." || exit 1

REGION=ap-northeast-2
ACCOUNT_WANT=007635145730
INSTANCE_TYPE_FIXED=g5.xlarge
# g5.xlarge Spot was $0.61-0.63/h in ap-northeast-2 on 2026-11-19, and a zone above the cap is not used.
MAX_PRICE_FIXED=0.70
# 200 GB gp3 and a public IPv4 ($0.0324/h), plus the provisioned throughput and IOPS ($0.0468/h), the same under both options.
EBS_IP_RATE=0.0792
# The Spot cap plus EBS_IP_RATE.
SPOT_ALL_IN_RATE=0.7792
# AWS Price List API, read 2026-11-19: get-products for AmazonEC2, instanceType g5.xlarge, regionCode ap-northeast-2, Linux, Shared, preInstalledSw NA, capacitystatus Used.
# It answered usagetype APN2-BoxUsage:g5.xlarge, OnDemand 1.2370000000 USD per Hrs, effective 2026-11-01, published 2026-11-18T22:02:54Z.
ON_DEMAND_RATE_PINNED=1.237
ON_DEMAND_RATE_SOURCE_PINNED="pinned: AWS Price List API APN2-BoxUsage:g5.xlarge OnDemand 1.2370000000 USD/Hrs, effective 2026-11-01, read 2026-11-19"
EBS_THROUGHPUT_MIBPS=500
EBS_IOPS=6000
COST_CAP_USD=1.50
STUDY_ID=vllm-fla-68416-run4-2026-11-19
STACK=gdn-gpu
PURPOSE=vllm-fla-68416-run4
RUNNER=oss/vllm/68414-gdn/runner.sh
LIB=oss/vllm/68414-gdn/lib.sh
PLUGIN=oss/vllm/68414-gdn/fla_loaded_modules.py
PYTEST_SUMMARY=oss/vllm/68414-gdn/pytest-summary.py
# Each fix diff is the storage copy byte for byte, and each test diff is the storage test-only.diff, which is its fix diff's first part.
STRIDE_STATE=oss/vllm/68414-gdn/stride-state.sh
STRIDE_PINS=oss/vllm/68414-gdn/stride-pins.txt
STRIDE_DIFFERS=oss/vllm/68414-gdn/stride-differs.txt
STRIDE_VERDICT=oss/vllm/68414-gdn/stride-verdict.py
STRIDE_FIX_DIFF=oss/vllm/68414-gdn/stride-fix.diff
STRIDE_FIX_DIFF_SHA256=0eaef549b2b6919272666660626e70734fb3b07b25ec13d29f52e1d3c178b60a
STRIDE_TEST_DIFF=oss/vllm/68414-gdn/stride-test.diff
STRIDE_TEST_DIFF_SHA256=21d8bbecee8dae26df7b75630d3f059513dda2cf022787f8edea28cc04bc5e94
# The step bounds, each the runner's own; oss/vllm/68414-gdn/vllm-gdn-68414-session-test.sh holds the two equal.
BRINGUP_S=240
PULL_BOUND_S=1500
IMAGE_ID_S=60
SETUP_S=60
PROBE_S=90
PYTEST_S=60
FILE_S=120
STOP_S=30
EVIDENCE_UPLOAD_S=60
STATES_S=$(( (SETUP_S + PROBE_S + PYTEST_S + STOP_S) + (SETUP_S + PROBE_S + PYTEST_S + FILE_S + STOP_S) ))
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

# under_cap RATE: whether the worst case, TERMINATION_S at RATE all in, is under COST_CAP_USD.
under_cap() {
  python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) / 3600 * float(sys.argv[2]) < float(sys.argv[3]) else 1)' \
    "$TERMINATION_S" "$1" "$COST_CAP_USD"
}
worst_usd() { python3 -c 'import sys; print(f"{float(sys.argv[1]) / 3600 * float(sys.argv[2]):.4f}")' "$TERMINATION_S" "$1"; }

# purchase_rate: sets COMPUTE_RATE, RATE_SOURCE and ALL_IN_RATE for PURCHASE, and refuses a worst case at or over the cap.
# For on-demand it reads the price with one read-only Price List call, which is served from us-east-1 for every Region.
# A failed or unreadable answer falls back to the pinned rate, and RATE_SOURCE says which was used.
purchase_rate() {
  local answer rate
  if [ "$PURCHASE" = spot ]; then
    COMPUTE_RATE=$MAX_PRICE_FIXED
    RATE_SOURCE="the Spot cap MAX_PRICE_FIXED"
    ALL_IN_RATE=$SPOT_ALL_IN_RATE
  else
    if answer=$(aws pricing get-products --region us-east-1 --service-code AmazonEC2 \
      --filters "Type=TERM_MATCH,Field=instanceType,Value=$INSTANCE_TYPE_FIXED" "Type=TERM_MATCH,Field=regionCode,Value=$REGION" \
      Type=TERM_MATCH,Field=operatingSystem,Value=Linux Type=TERM_MATCH,Field=tenancy,Value=Shared \
      Type=TERM_MATCH,Field=preInstalledSw,Value=NA Type=TERM_MATCH,Field=capacitystatus,Value=Used \
      --query PriceList --output json 2>&1) &&
      # The highest hourly USD price among the answers, so an answer listing more than one cannot lower the worst case.
      rate=$(python3 -c '
import json, sys
prices = [float(d["pricePerUnit"]["USD"])
          for p in json.loads(sys.argv[1]) for t in json.loads(p)["terms"]["OnDemand"].values()
          for d in t["priceDimensions"].values() if d["unit"] == "Hrs"]
assert prices and all(x > 0 for x in prices)
print(max(prices))' "$answer" 2>/dev/null); then
      COMPUTE_RATE=$rate
      RATE_SOURCE="AWS Price List API get-products, read $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    else
      COMPUTE_RATE=$ON_DEMAND_RATE_PINNED
      RATE_SOURCE="$ON_DEMAND_RATE_SOURCE_PINNED (the live read failed: $(printf '%s' "$answer" | head -c 200 | tr '\n' ' '))"
    fi
    ALL_IN_RATE=$(python3 -c 'import sys; print(round(float(sys.argv[1]) + float(sys.argv[2]), 6))' "$COMPUTE_RATE" "$EBS_IP_RATE")
  fi
  under_cap "$ALL_IN_RATE" ||
    fail "the $PURCHASE worst case, $TERMINATION_S s at \$$ALL_IN_RATE/h all in (\$$COMPUTE_RATE/h from $RATE_SOURCE), is \$$(worst_usd "$ALL_IN_RATE"), not under \$$COST_CAP_USD"
}

# purchase_zones: sets ZONES, the zones to try in order, from read-only calls only.
purchase_zones() {
  local prices offers
  if [ "$PURCHASE" = spot ]; then
    prices=$(aws ec2 describe-spot-price-history --region "$REGION" --instance-types "$INSTANCE_TYPE_FIXED" \
      --product-descriptions "Linux/UNIX" --start-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --query 'SpotPriceHistory[].[AvailabilityZone,SpotPrice]' --output text 2>&1) || fail "could not read the Spot price: $prices"
    [ ! -d "$OUT" ] || printf '%s\n' "$prices" >"$OUT/spot-prices.txt"
    ZONES=$(awk -v cap="$MAX_PRICE_FIXED" 'NF == 2 && $2 + 0 > 0 && $2 + 0 <= cap + 0 {print $1}' <<<"$prices" | sort -u | paste -sd' ')
    [ -n "$ZONES" ] || fail "no zone offers $INSTANCE_TYPE_FIXED Spot at or under \$$MAX_PRICE_FIXED/h: $(paste -sd' ' <<<"$prices")"
    # The #58420 study's run 7 was reclaimed in ap-northeast-2a for want of Spot capacity, 15 minutes in.
    # A zone that reclaimed a study is tried after the others, and still tried if they have no capacity.
    RECLAIMED_ZONES="ap-northeast-2a"
    ZONES=$(for z in $ZONES; do case " $RECLAIMED_ZONES " in *" $z "*) ;; *) echo "$z" ;; esac; done
      for z in $ZONES; do case " $RECLAIMED_ZONES " in *" $z "*) echo "$z" ;; esac; done)
    ZONES=$(paste -sd' ' <<<"$ZONES")
    ZONES_WHY="Spot $INSTANCE_TYPE_FIXED under \$$MAX_PRICE_FIXED/h in: $ZONES ($(paste -sd' ' <<<"$prices"))"
  else
    # On-demand has no market price to filter by, so every zone that offers the type is tried, in name order.
    offers=$(aws ec2 describe-instance-type-offerings --region "$REGION" --location-type availability-zone \
      --filters "Name=instance-type,Values=$INSTANCE_TYPE_FIXED" --query 'InstanceTypeOfferings[].Location' --output text 2>&1) ||
      fail "could not read the zones offering $INSTANCE_TYPE_FIXED: $offers"
    ZONES=$(tr -s '[:space:]' '\n' <<<"$offers" | grep -E "^$REGION[a-z]\$" | sort -u | paste -sd' ')
    [ -n "$ZONES" ] || fail "no zone in $REGION offers $INSTANCE_TYPE_FIXED: $offers"
    ZONES_WHY="on-demand $INSTANCE_TYPE_FIXED offered in: $ZONES"
  fi
}

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

# judge SWEEP: #68416's verdict and the pytest summary into OUT, and VERDICTS naming it.
# The verdict reads the item's records, whatever came back, so a stopped run still says how far it got and why it is not confirmed.
# A verdict that crashed or printed nothing names the item empty, which is not "confirmed", so it fails the exit status like any other.
# It is a function, and --judge runs it alone, so the offline test drives the same aggregation and exit status the purchase ends with.
judge() {
  local sweep=$1
  python3 "$STRIDE_VERDICT" "$sweep" "$STRIDE_TEST_DIFF_SHA256" "$STRIDE_FIX_DIFF_SHA256" >"$OUT/stride-verdict.txt" 2>>"$OUT/download-errors.txt"
  # What the PRs quote, from the same records.
  python3 "$PYTEST_SUMMARY" "$sweep" "$STRIDE_TEST_DIFF_SHA256" "$STRIDE_FIX_DIFF_SHA256" >"$OUT/pytest-summary.txt" 2>>"$OUT/download-errors.txt"
  # The summary is what the PR quotes, so a summary that failed or wrote nothing keeps the session from succeeding.
  SUMMARY_RC=$?
  [ -s "$OUT/pytest-summary.txt" ] || SUMMARY_RC=empty
  VERDICTS="stride=$(verdict_of stride)"
}
verdict_of() { grep -m1 "^$1_verdict=" "$OUT/$1-verdict.txt" 2>/dev/null | cut -d= -f2; }
all_confirmed() { [ "$VERDICTS" = "stride=confirmed" ] && [ "$SUMMARY_RC" = 0 ]; }

# ---------------------------------------------------------------- refusals, before anything is built or bought
# The purchase option comes first, because every cost figure below depends on it.
case "${PURCHASE:-}" in
  spot | on-demand) ;;
  "") fail "PURCHASE is unset; set PURCHASE=spot or PURCHASE=on-demand, since the session has no default purchase option" ;;
  *) fail "PURCHASE is '$PURCHASE', not spot or on-demand" ;;
esac
# None of these names is one of the script's own variables, which the loop would otherwise read back as a caller's.
for v in INSTANCE_TYPE MAX_SPOT_PRICE HARD_STOP_SECONDS BACKSTOP_SECONDS IMAGE VLLM_IMAGE VLLM_COMMIT \
  DIFF PATCH PULL_BOUND REPRO_SCRIPT DEFAULT_DEVICE PYTEST_ARGS ON_DEMAND_RATE; do
  [ -z "${!v:-}" ] || fail "$v is set, and this session's value for it is its registration's; unset it"
done
# Both options are held under the cap at their constants, whichever one this run buys.
under_cap "$SPOT_ALL_IN_RATE" ||
  fail "the spot worst case, $TERMINATION_S s at \$$SPOT_ALL_IN_RATE/h, is not under \$$COST_CAP_USD"
OD_PINNED_ALL_IN=$(python3 -c 'import sys; print(round(float(sys.argv[1]) + float(sys.argv[2]), 6))' "$ON_DEMAND_RATE_PINNED" "$EBS_IP_RATE")
under_cap "$OD_PINNED_ALL_IN" ||
  fail "the on-demand worst case, $TERMINATION_S s at the pinned \$$OD_PINNED_ALL_IN/h, is not under \$$COST_CAP_USD"
# The schedule alone, with nothing checked or bought, so the offline test can hold it to the runner's bounds.
if [ "${1:-}" = --print-schedule ]; then
  echo "harness_end_s=$HARNESS_END_S evidence_s=$EVIDENCE_S stop_s=$STOP_FROM_LAUNCH_S termination_s=$TERMINATION_S"
  exit 0
fi
# The rate and its refusal alone, from the same function the purchase uses, so the offline test can drive them with a fake aws.
if [ "${1:-}" = --print-purchase ]; then
  purchase_rate
  echo "purchase=$PURCHASE compute_rate=$COMPUTE_RATE all_in_rate=$ALL_IN_RATE worst_case_usd=$(worst_usd "$ALL_IN_RATE")"
  echo "rate_source=$RATE_SOURCE"
  exit 0
fi
# The zones in the order the launch tries them, from read-only calls, for the same reason.
if [ "${1:-}" = --print-zones ]; then
  purchase_zones
  echo "zones=$ZONES"
  exit 0
fi
# The verdicts, the summary and the exit status alone, on a sweep already on disk, written into an existing OUT.
if [ "${1:-}" = --judge ]; then
  [ -d "${2:-}" ] && [ -d "$OUT" ] || fail "--judge needs a sweep directory and an existing OUT"
  judge "$2"
  echo "verdicts=$VERDICTS"
  echo "summary_rc=$SUMMARY_RC"
  all_confirmed || exit 2
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
# A diff known unfit for a run is refused before any AWS call, since running it would buy a result that cannot be used, and the header says why.
for unfit in 6bf2352933b148465f6437098280bfba2c1e4ff7ca586ca3d5e9d87fc71a6fe9 abbfbaf392a39a3083ab1ff285dd3f747ebde4fa07b157f20781503391ea3ec4; do
  case " $STRIDE_FIX_DIFF_SHA256 $STRIDE_TEST_DIFF_SHA256 " in
    *" $unfit "*) fail "the pinned diff $unfit is not fit for a paid run: #68416's kda case writes 768 output elements into 384 and draws a new gk per layout (see REFUSED DIFFS); replace the diff and its pins first" ;;
  esac
done
for tool in aws python3 git tar sha256sum; do command -v "$tool" >/dev/null || fail "$tool is not installed"; done
[ -z "$(git status --porcelain)" ] || fail "the working tree is dirty; the run's provenance is a commit, and the runner is shipped from this tree"
COMMIT=$(git rev-parse HEAD)
ACCOUNT=$(aws sts get-caller-identity --query Account --output text 2>&1) || fail "could not read the caller's account: $ACCOUNT"
[ "$ACCOUNT" = "$ACCOUNT_WANT" ] || fail "the credentials are for account $ACCOUNT; paid sessions run only in gpu-lab ($ACCOUNT_WANT)"
[ ! -e "$OUT" ] || fail "$OUT already exists; each session writes a new directory"
mkdir -p "$OUT" || fail "cannot create $OUT"
say "vLLM #68416 before and after for $STUDY_ID, from $COMMIT, into $OUT, bought $PURCHASE"
purchase_rate
say "$PURCHASE: \$$COMPUTE_RATE/h compute from $RATE_SOURCE, \$$ALL_IN_RATE/h all in"
say "hard stop $STOP_FROM_LAUNCH_S s after LaunchTime; worst case $TERMINATION_S s at \$$ALL_IN_RATE/h, \$$(worst_usd "$ALL_IN_RATE") under \$$COST_CAP_USD"

# The diffs are the storage copies, byte for byte, so a changed copy costs nothing.
for pair in "$STRIDE_FIX_DIFF:$STRIDE_FIX_DIFF_SHA256" "$STRIDE_TEST_DIFF:$STRIDE_TEST_DIFF_SHA256"; do
  [ "$(sha256sum "${pair%%:*}" | cut -d' ' -f1)" = "${pair#*:}" ] || fail "${pair%%:*} is not the pinned ${pair#*:}"
done
mkdir -p "$OUT/in" || fail "cannot create $OUT/in"
# #68414's and #68415's files are not shipped, so no state of either can run on the instance.
cp "$RUNNER" "$LIB" "$PLUGIN" "$OUT/in/" || fail "copy the shared inputs"
cp "$STRIDE_STATE" "$STRIDE_PINS" "$STRIDE_DIFFERS" "$STRIDE_FIX_DIFF" "$STRIDE_TEST_DIFF" "$OUT/in/" || fail "copy the #68416 inputs"
tar -czf "$OUT/inputs.tgz" -C "$OUT/in" . || fail "pack the inputs"
say "the two diffs match their pins"

# shellcheck source=hack/lib/spot-run.sh
. hack/lib/spot-run.sh

ami_name=$(aws ec2 describe-images --region "$REGION" --image-ids "$VLLMGDN_AMI_ID" \
  --query 'Images[0].[Name,State]' --output text 2>&1) || fail "could not describe $VLLMGDN_AMI_ID: $ami_name"
case "$ami_name" in
  "Deep Learning Base OSS Nvidia Driver GPU AMI (Ubuntu 22.04)"*available) ;;
  *) fail "$VLLMGDN_AMI_ID is '$ami_name', not an available Deep Learning Base OSS Nvidia Driver GPU AMI (Ubuntu 22.04)" ;;
esac
say "AMI $VLLMGDN_AMI_ID: $ami_name"

purchase_zones
say "$ZONES_WHY"

# Spot and on-demand draw on different vCPU quotas.
if [ "$PURCHASE" = spot ]; then QUOTA_CODE=L-3819A6DF; QUOTA_NAME="G and VT Spot"; else QUOTA_CODE=L-DB2E81BA; QUOTA_NAME="Running On-Demand G and VT"; fi
quota=$(aws service-quotas get-service-quota --region "$REGION" --service-code ec2 --quota-code "$QUOTA_CODE" \
  --query 'Quota.Value' --output text 2>&1) || fail "could not read the $QUOTA_NAME quota: $quota"
python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) >= 4 else 1)' "$quota" ||
  fail "the $QUOTA_NAME quota is $quota vCPU and one $INSTANCE_TYPE_FIXED needs 4"

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
  echo "purchase=$PURCHASE"
  [ "$PURCHASE" = spot ] && echo "max_spot_price=$MAX_PRICE_FIXED"
  echo "compute_rate=$COMPUTE_RATE"
  echo "compute_rate_source=$RATE_SOURCE"
  echo "all_in_rate=$ALL_IN_RATE"
  echo "worst_case_usd=$(worst_usd "$ALL_IN_RATE")"
  echo "inputs_sha256=$INPUTS_SHA"
  echo "stride_fix_diff_sha256=$STRIDE_FIX_DIFF_SHA256"
  echo "stride_test_diff_sha256=$STRIDE_TEST_DIFF_SHA256"
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
say "launching $INSTANCE_TYPE_FIXED $PURCHASE (\$$COMPUTE_RATE/h compute, \$$ALL_IN_RATE/h all in), study-deadline $TAG_DEADLINE -- the instance bills from here"
for z in $ZONES; do
  SUBNET=$(spot_subnet_in_zone "$REGION" "$z") || continue
  token="gdn-$RUN_NONCE-$z"
  LAUNCH_UNCERTAIN="$token"; LAUNCH_UNCERTAIN_SUBNET="$SUBNET"
  IID=$(spot_launch "$REGION" "$VLLMGDN_AMI_ID" "$INSTANCE_TYPE_FIXED" "$SUBNET" "$STACK" "$MAX_PRICE_FIXED" "$VOLUME_GB" \
    "$UD" "$TAGS" "$token" "" "" "$EBS_THROUGHPUT_MIBPS" "$EBS_IOPS" "$PURCHASE" 2>"$OUT/launch-error-$z.txt") || IID=""
  cat "$OUT/launch-error-$z.txt" >>"$OUT/launch-errors.txt"
  if [ -n "$IID" ] && [ "$IID" != None ]; then LAUNCH_UNCERTAIN=""; break; fi
  IID=""
  if grep -qiE 'InsufficientInstanceCapacity|capacity-not-available' "$OUT/launch-error-$z.txt"; then LAUNCH_UNCERTAIN=""; continue; fi
  fail "the launch in $z was refused for a reason that is not capacity; see $OUT/launch-errors.txt"
done
[ -n "$IID" ] || fail "no zone had $INSTANCE_TYPE_FIXED $PURCHASE capacity; nothing was launched"
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
if [ "$unpacked" != yes ] || ! grep -q "all items done" "$SWEEP/steps.log" 2>/dev/null; then
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
judge "$SWEEP"
# An item's records are whole once the runner logged its last state, which the periodic copy can hold even when the run was cut later.
records() { grep -q "$1 states done" "$SWEEP/steps.log" 2>/dev/null && echo complete || echo incomplete; }
{
  echo "evidence=$EVIDENCE"
  echo "termination=$TERMINATION"
  echo "purchase=$PURCHASE"
  echo "verdicts=$VERDICTS"
  echo "summary_rc=$SUMMARY_RC"
  echo "stride_records=$(records stride)"
  cat "$OUT/stride-verdict.txt"
} >"$OUT/outcome.txt"
[ ! -s "$OUT/gdn-run/summary.txt" ] || cat "$OUT/gdn-run/summary.txt"
cat "$OUT/outcome.txt"
cat "$OUT/pytest-summary.txt"
say "evidence $EVIDENCE; termination $TERMINATION; $VERDICTS"
[ "$TERMINATION" = confirmed ] || exit 1
[ "$EVIDENCE" = returned ] || exit 1
all_confirmed || exit 2
