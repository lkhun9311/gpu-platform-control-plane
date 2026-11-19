#!/usr/bin/env bash
#
# The llm-d-router precise prefix-cache hunt: one g5.xlarge, one attempt, stopped by itself 3,840 s after launch.
# Two vLLM v0.34.0 replicas of Qwen2-VL-2B-Instruct share the A10G, and a probe built from llm-d-router 7fc31fd133 runs the router's own token producer and precise-prefix-cache-producer against their KV events.
# Before each request the probe records what each router predicts each replica holds; after it, what vLLM served from its cache.
#
#   PURCHASE=spot SESSION_CONFIRM=yes AWS_PROFILE=gpu-lab LLMDHUNT_AMI_ID=ami-... bash hack/llmd-prefix-hunt-session.sh
#   PURCHASE=on-demand SESSION_CONFIRM=yes AWS_PROFILE=gpu-lab LLMDHUNT_AMI_ID=ami-... bash hack/llmd-prefix-hunt-session.sh
#
# PURCHASE has no default: Spot is cheaper and can be reclaimed, so the owner picks one each time.
#
# WHAT IT MEASURES.
# hack/llmd-prefix-hunt/HYPOTHESES.md holds the hypotheses, their duplicate checks and why each workload is what it is.
# H1: the router credits prefix tokens the engine cannot serve, a prefix that ends inside one of vLLM's 64-token blocks and the last block of a whole-prompt hit.
# H2: reused-block reports (kv_cache_report_mode=full) raise the router's dedup reference count, so vLLM's one BlockRemoved per evicted block is suppressed and the index keeps the evicted prefix.
# Calibration (an aligned shared prefix) gates both, and the known llm-d-router #3788 (salted and multimodal prompts under router block 16) is a control that the harness must reproduce.
# The verdict reads the probe's per-request rows and the replicas' raw events; hack/llmd-prefix-hunt/verdict.py says what makes each verdict.
#
# WHAT RUNS WHERE.
# The probe is built here from the committed tree, a static linux/amd64 binary, and only after its offline tests pass against a fake vLLM.
# The instance pulls vllm/vllm-openai by digest, checks its revision label is v0.34.0's commit, starts replica A (which downloads the model at its pinned revision), then B, sizes the eviction flood from A's logged KV capacity, and runs the probe.
# It shares its EC2 lifecycle with the other paid sessions (hack/lib/spot-run.sh) and its user-data with hack/vllm-gdn-68414-session.sh.
#
# THE CLOCK.
# Every deadline counts from EC2's LaunchTime, read right after the launch and written to the run's S3 prefix for the instance to read.
# No run has measured this stack yet, so the bounds are estimates with room, and the probe's records say how far a cut run got:
#   bring-up (the vLLM FLA runs 1 to 3: 121, 116, 111 s)                       240 s
#   image pull (10.0 GB compressed; the FLA runs' 11 GB pulls took 592 to 1,094 s)   1,500 s
#   image identity                                                               60 s
#   replica A start, with the 4.4 GB model download                             600 s
#   replica B start, model cached                                               300 s
#   probe (about 2 x (30 + flood) requests, at most 400 flood prompts each)     900 s
#   metrics, logs and the on-instance verdict                                    90 s
#   replica removal                                                              30 s
#   so the runner ends by 240 + 1,500 + 60 + 600 + 300 + 900 + 90 + 30      = 3,720 s
#   evidence upload                                                              60 s -> 3,780
# The launch carries the termination sweeper's study-deadline tag at the request plus 3,780 s, rewritten to LaunchTime plus 3,810 s once LaunchTime is known.
# The instance shuts itself down at 3,840 s, and the termination is to be confirmed by 4,140 s, the sweeper's five-minute period after its tag plus 30 s.
#
# THE COST.
# The worst case bills to the termination deadline: 4,140 s.
# It assumes EC2 confirms the termination by then; one that is not confirmed is reported as such, and billing past it is not bounded here.
# Both options add $0.0324/h for 200 GB gp3 and a public IPv4, and $0.0468/h for 500 MiB/s and 6,000 IOPS, as the TPOT session measured.
# spot: the $0.70/h Spot cap, so $0.7792/h all in, and $0.8961.
# on-demand: g5.xlarge in ap-northeast-2 is read from the AWS Price List API before anything is bought, and the pinned $1.237/h is used only when that read fails.
# At $1.237/h it is $1.3162/h all in, and $1.5136; any compute rate of $2.5295/h or more puts the worst case at $3.00 or more, and the session refuses it.
# The script refuses to run if the constants below stop giving a worst case under $3.00 for either option.
#
# NOTHING HERE IS A DEFAULT A CALLER CAN MOVE: the instance, the image, the model, the bounds and the stop are constants, and a caller who sets one is refused rather than ignored.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

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
COST_CAP_USD=3.00
STUDY_ID=llmd-precise-prefix-hunt-2026-11-19
STACK=llmd-hunt
PURPOSE=llmd-precise-prefix-hunt
D=hack/llmd-prefix-hunt
RUNNER=$D/runner.sh
VERDICT=$D/verdict.py
PROBE_SRC=$D/probe
# The router commit the probe links, which go.mod pins as a pseudo-version.
ROUTER_COMMIT=7fc31fd1334883a1da45c4059fa7faea11b269b1
ROUTER_MODULE_VERSION=v1.0.0-rc.1.0.20261119120236-7fc31fd13348
# The step bounds, each the runner's own; hack/llmd-prefix-hunt-session-test.sh holds the two equal.
BRINGUP_S=240
PULL_BOUND_S=1500
IMAGE_ID_S=60
START_A_S=600
START_B_S=300
PROBE_S=900
COLLECT_S=90
STOP_S=30
EVIDENCE_UPLOAD_S=60
STATES_S=$(( START_A_S + START_B_S + PROBE_S + COLLECT_S + STOP_S ))
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

OUT="${OUT:-$D/runs/$(date -u +%Y%m%dT%H%M%SZ)}"
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
exec > >(tee /var/log/hunt.log) 2>&1
set -x
SR_START=$(date +%s)
# The first backstop, armed before anything can fail, counts from the instance's own start; LaunchTime precedes it, so the precise one below, armed once LaunchTime is read, always fires first.
( sleep STOP_FROM_LAUNCH_S_PLACEHOLDER; shutdown -h now ) &
BUCKET="BUCKET_PLACEHOLDER"
PREFIX="RUN_ID_PLACEHOLDER"
COMMIT="COMMIT_PLACEHOLDER"
upload() { aws s3 cp --only-show-errors "$1" "s3://$BUCKET/$PREFIX/$2" || true; }
trap 'upload /var/log/hunt.log log.txt; shutdown -h now' EXIT
mkdir -p /src/hunt-run /opt/hunt || exit 1
# The input is fetched and checked against the hash this session computed, so the instance runs only what was built here.
aws s3 cp --only-show-errors "s3://$BUCKET/$PREFIX/inputs.tgz" /opt/hunt/inputs.tgz || exit 1
[ "$(sha256sum /opt/hunt/inputs.tgz | cut -d' ' -f1)" = "INPUTS_SHA_PLACEHOLDER" ] || { echo "checksum mismatch for inputs.tgz"; exit 1; }
mkdir -p /opt/hunt/in && tar -xzf /opt/hunt/inputs.tgz -C /opt/hunt/in || exit 1
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
# The pinned image is CUDA 13.0 with vLLM's compatibility mode off (VLLM_ENABLE_CUDA_COMPATIBILITY=0 in its config), which needs a 580 or newer driver; an older one would only show after the 10 GB pull.
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
  sha256sum /opt/hunt/inputs.tgz
} > /src/hunt-run/instance-provenance.txt
cp /tmp/nvidia-smi.csv /src/hunt-run/nvidia-smi.csv
{ nvidia-smi; nvidia-smi -q; } > /src/hunt-run/nvidia-smi.txt 2>&1
{ docker version; docker info; nvidia-ctk --version; } > /src/hunt-run/versions.txt 2>&1
if [ "$bringup_rc" = 0 ]; then
  mkdir -p /src/hunt-run/sweep
  # A Spot reclaim gives two minutes, so the records leave the instance within PARTIAL_SYNC_S of being written.
  # One archive overwritten in place needs only the role's s3:PutObject; a sync would also need s3:ListBucket.
  # GNU tar exits 1 when a file grew while it was read, which the probe's running records do, so 1 still uploads.
  ( while :; do
      nice -n 19 ionice -c3 tar --warning=no-file-changed -czf /tmp/partial.tgz -C /src/hunt-run sweep >>/var/log/hunt-sync.log 2>&1
      [ $? -le 1 ] && timeout 60 nice -n 19 aws s3 cp --only-show-errors /tmp/partial.tgz "s3://$BUCKET/$PREFIX/partial.tgz" >>/var/log/hunt-sync.log 2>&1
      sleep PARTIAL_SYNC_S_PLACEHOLDER
    done ) &
  sync_pid=$!
  # The runner's own bounds sum to HE; this timeout only stops a runner that overran them from eating the upload.
  timeout --kill-after=15 $(( HE - $(date +%s) > 5 ? HE - $(date +%s) : 5 )) bash /opt/hunt/in/runner.sh /opt/hunt/in /src/hunt-run/sweep "$HE" \
    > /src/hunt-run/summary.txt 2>&1
  harness_rc=$?
  kill "$sync_pid" 2>>/var/log/hunt-sync.log
  cp /var/log/hunt-sync.log /src/hunt-run/sync.log
  cat /src/hunt-run/summary.txt
  echo "harness_rc=$harness_rc" >> /src/hunt-run/instance-provenance.txt
  echo "the runner exited $harness_rc"
else
  echo "the bring-up did not finish inside its phase (exit $bringup_rc); nothing else runs" | tee /src/hunt-run/VOID
fi
cp /var/log/hunt.log /src/hunt-run/instance.log
left=$(( EV - $(date +%s) )); [ "$left" -gt 5 ] || left=5
tar --warning=no-file-changed -czf /tmp/evidence.tgz -C /src hunt-run
[ $? -le 1 ] && timeout "$left" aws s3 cp --only-show-errors /tmp/evidence.tgz "s3://$BUCKET/$PREFIX/evidence.tgz"
upload /var/log/hunt.log log.txt
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

# judge SWEEP: the verdict on the probe's records into OUT, and VERDICTS naming each hypothesis's.
# The verdict reads whatever came back, so a stopped run still says how far it got.
# A verdict that crashed or printed nothing names every hypothesis empty, which fails the exit status like a void.
# It is a function, and --judge runs it alone, so the offline test drives the same aggregation and exit status the purchase ends with.
judge() {
  local sweep=$1
  python3 "$VERDICT" "$sweep/probe" >"$OUT/verdict.txt" 2>>"$OUT/download-errors.txt"
  VERDICT_RC=$?
  VERDICTS="calib=$(verdict_of calib) bias=$(verdict_of bias) dedup=$(verdict_of dedup) salt=$(verdict_of salt) mm=$(verdict_of mm)"
}
verdict_of() { grep -m1 "^$1_verdict=" "$OUT/verdict.txt" 2>/dev/null | cut -d= -f2; }
# The session succeeds when both hypotheses got a verdict the records support and the harness reproduced the known #3788 on salted prompts.
# Confirmed and refuted are both results; void, partial, mixed or empty is not.
# The multimodal control is reported but does not gate, since it also depends on the renderer, which neither hypothesis uses.
# A calibration that failed needs no check of its own here, because the verdict then calls every hypothesis void.
judged() {
  [ "$VERDICT_RC" = 0 ] || return 1
  [ "$(verdict_of salt)" = reproduced ] || return 1
  for h in bias dedup; do
    case "$(verdict_of "$h")" in confirmed | refuted) ;; *) return 1 ;; esac
  done
}

# ---------------------------------------------------------------- refusals, before anything is built or bought
# The purchase option comes first, because every cost figure below depends on it.
case "${PURCHASE:-}" in
  spot | on-demand) ;;
  "") fail "PURCHASE is unset; set PURCHASE=spot or PURCHASE=on-demand, since the session has no default purchase option" ;;
  *) fail "PURCHASE is '$PURCHASE', not spot or on-demand" ;;
esac
# None of these names is one of the script's own variables, which the loop would otherwise read back as a caller's.
for v in INSTANCE_TYPE MAX_SPOT_PRICE HARD_STOP_SECONDS BACKSTOP_SECONDS IMAGE VLLM_IMAGE MODEL MODEL_REV \
  PULL_BOUND REPS SEED FLOOD BLOCK_SIZE ROUTER_REF ON_DEMAND_RATE; do
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
  echo "verdict_rc=$VERDICT_RC"
  judged || exit 2
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
[[ "${LLMDHUNT_AMI_ID:-}" =~ ^ami-[0-9a-f]{8,17}$ ]] ||
  fail "LLMDHUNT_AMI_ID is ${LLMDHUNT_AMI_ID:-unset}; the session pins the AMI by ID rather than resolving it from latest"
for tool in aws python3 git tar sha256sum go; do command -v "$tool" >/dev/null || fail "$tool is not installed"; done
[ -z "$(git status --porcelain)" ] || fail "the working tree is dirty; the run's provenance is a commit, and the runner is shipped from this tree"
COMMIT=$(git rev-parse HEAD)
ACCOUNT=$(aws sts get-caller-identity --query Account --output text 2>&1) || fail "could not read the caller's account: $ACCOUNT"
[ "$ACCOUNT" = "$ACCOUNT_WANT" ] || fail "the credentials are for account $ACCOUNT; paid sessions run only in gpu-lab ($ACCOUNT_WANT)"
[ ! -e "$OUT" ] || fail "$OUT already exists; each session writes a new directory"
mkdir -p "$OUT" || fail "cannot create $OUT"
say "llm-d-router precise prefix hunt $STUDY_ID, from $COMMIT, into $OUT, bought $PURCHASE"
purchase_rate
say "$PURCHASE: \$$COMPUTE_RATE/h compute from $RATE_SOURCE, \$$ALL_IN_RATE/h all in"
say "hard stop $STOP_FROM_LAUNCH_S s after LaunchTime; worst case $TERMINATION_S s at \$$ALL_IN_RATE/h, \$$(worst_usd "$ALL_IN_RATE") under \$$COST_CAP_USD"

mkdir -p "$OUT/in" "$OUT/gocache" || fail "cannot create $OUT/in"
# The probe links the pinned router commit, and go.mod is what pins it.
grep -qxF "	github.com/llm-d/llm-d-router $ROUTER_MODULE_VERSION" "$PROBE_SRC/go.mod" ||
  fail "$PROBE_SRC/go.mod does not require llm-d-router $ROUTER_MODULE_VERSION (commit $ROUTER_COMMIT)"
# The offline tests run the same probe against a fake vLLM; a probe that fails them is not worth an instance.
( cd "$PROBE_SRC" && GOFLAGS=-mod=readonly GOTMPDIR="$(cd "$OLDPWD" && pwd)/$OUT/gocache" go test -count=1 ./... ) >"$OUT/probe-test.log" 2>&1 ||
  fail "the probe's offline tests failed; see $OUT/probe-test.log"
( cd "$PROBE_SRC" && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 GOFLAGS=-mod=readonly go build -trimpath -o "$(cd "$OLDPWD" && pwd)/$OUT/in/probe" . ) >"$OUT/probe-build.log" 2>&1 ||
  fail "the probe did not build; see $OUT/probe-build.log"
rm -rf "$OUT/gocache"
cp "$RUNNER" "$VERDICT" "$OUT/in/" || fail "copy the runner and the verdict"
PROBE_SHA=$(sha256sum "$OUT/in/probe" | cut -d' ' -f1)
tar -czf "$OUT/inputs.tgz" -C "$OUT/in" . || fail "pack the inputs"
say "the probe passed its offline tests and was built, sha256 $PROBE_SHA"

# shellcheck source=hack/lib/spot-run.sh
. hack/lib/spot-run.sh

ami_name=$(aws ec2 describe-images --region "$REGION" --image-ids "$LLMDHUNT_AMI_ID" \
  --query 'Images[0].[Name,State]' --output text 2>&1) || fail "could not describe $LLMDHUNT_AMI_ID: $ami_name"
case "$ami_name" in
  "Deep Learning Base OSS Nvidia Driver GPU AMI (Ubuntu 22.04)"*available) ;;
  *) fail "$LLMDHUNT_AMI_ID is '$ami_name', not an available Deep Learning Base OSS Nvidia Driver GPU AMI (Ubuntu 22.04)" ;;
esac
say "AMI $LLMDHUNT_AMI_ID: $ami_name"

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
  echo "ami_id=$LLMDHUNT_AMI_ID"
  echo "ami_name=$ami_name"
  echo "instance_type=$INSTANCE_TYPE_FIXED"
  echo "purchase=$PURCHASE"
  [ "$PURCHASE" = spot ] && echo "max_spot_price=$MAX_PRICE_FIXED"
  echo "compute_rate=$COMPUTE_RATE"
  echo "compute_rate_source=$RATE_SOURCE"
  echo "all_in_rate=$ALL_IN_RATE"
  echo "worst_case_usd=$(worst_usd "$ALL_IN_RATE")"
  echo "inputs_sha256=$INPUTS_SHA"
  echo "probe_sha256=$PROBE_SHA"
  echo "router_commit=$ROUTER_COMMIT"
  echo "image=$(grep -m1 '^IMG=' "$RUNNER" | cut -d'"' -f2)"
  echo "vllm_commit=$(grep -m1 '^VLLM_COMMIT=' "$RUNNER" | cut -d= -f2)"
  echo "model=$(grep -m1 '^MODEL=' "$RUNNER" | cut -d= -f2)@$(grep -m1 '^MODEL_REV=' "$RUNNER" | cut -d= -f2)"
  echo "harness_end_from_launch_s=$HARNESS_END_S"
  echo "stop_from_launch_s=$STOP_FROM_LAUNCH_S"
  echo "termination_from_launch_s=$TERMINATION_S"
  echo "run_id=$RUN_ID"
} >"$OUT/session-provenance.txt"
UD="$OUT/user-data.sh"
render_user_data "$UD" "$BUCKET" "$RUN_ID" "$INPUTS_SHA" "$COMMIT" "$RUN_NONCE"

# ---------------------------------------------------------------- the purchase
spot_ensure_bucket "$BUCKET" "$REGION" 30 || fail "could not prepare the results bucket $BUCKET"
# The image comes from Docker Hub anonymously, so the role needs only the results bucket.
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
  token="hunt-$RUN_NONCE-$z"
  LAUNCH_UNCERTAIN="$token"; LAUNCH_UNCERTAIN_SUBNET="$SUBNET"
  IID=$(spot_launch "$REGION" "$LLMDHUNT_AMI_ID" "$INSTANCE_TYPE_FIXED" "$SUBNET" "$STACK" "$MAX_PRICE_FIXED" "$VOLUME_GB" \
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
[ "$IMAGE_ID" = "$LLMDHUNT_AMI_ID" ] || fail "$IID runs $IMAGE_ID, not the pinned $LLMDHUNT_AMI_ID"
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
SWEEP="$OUT/hunt-run/sweep"
EVIDENCE=returned
# An archive that broke after its last step is not the whole record, so it counts as returned only if it unpacked whole.
if [ "$unpacked" != yes ] || ! grep -q "all items done" "$SWEEP/steps.log" 2>/dev/null; then
  # Without the final archive, the periodic copy is what a reclaim or a crash left; it is reported as partial.
  mkdir -p "$OUT/hunt-run-partial"
  { aws s3 cp --only-show-errors "s3://$BUCKET/$RUN_ID/partial.tgz" "$OUT/partial.tgz" &&
    tar -xzf "$OUT/partial.tgz" -C "$OUT/hunt-run-partial"; } 2>>"$OUT/download-errors.txt" ||
    echo "the partial evidence did not download or unpack" >>"$OUT/download-errors.txt"
  if [ "$unpacked" = yes ] && [ -s "$SWEEP/steps.log" ]; then
    EVIDENCE=partial
  elif [ -s "$OUT/hunt-run-partial/sweep/steps.log" ]; then
    EVIDENCE=partial
    SWEEP="$OUT/hunt-run-partial/sweep"
  else
    EVIDENCE=missing
  fi
fi
judge "$SWEEP"
# The probe's records are whole once the runner logged that the probe exited, which the periodic copy can hold even when the run was cut later.
records() { grep -q "probe: exited" "$SWEEP/steps.log" 2>/dev/null && echo complete || echo incomplete; }
{
  echo "evidence=$EVIDENCE"
  echo "termination=$TERMINATION"
  echo "purchase=$PURCHASE"
  echo "verdicts=$VERDICTS"
  echo "verdict_rc=$VERDICT_RC"
  echo "probe_records=$(records)"
  grep -v '^#' "$OUT/verdict.txt"
} >"$OUT/outcome.txt"
[ ! -s "$OUT/hunt-run/summary.txt" ] || cat "$OUT/hunt-run/summary.txt"
cat "$OUT/outcome.txt"
say "evidence $EVIDENCE; termination $TERMINATION; $VERDICTS"
[ "$TERMINATION" = confirmed ] || exit 1
[ "$EVIDENCE" = returned ] || exit 1
judged || exit 2
