#!/usr/bin/env bash
# Runs the hold-cap conformance session on one Spot A10G in gpu-lab, and checks what it brings back.
#
# What it shows: the engine the controller renders for config/samples/platform_v1_inferencedeployment_holdcap.yaml,
# started for real, reports the non-default arguments the admission study measured (less its two instrumentation
# entries, plus the served name); status reports HoldCap only after that engine is ready; turning HoldCap off moves
# status to Off and rolls the engine by Recreate to one without the cap.
# What it does not show: any latency, the gateway (its HoldCap path is covered by internal/gateway's tests), or node
# selection on EKS (the kind worker is labelled by hand).
#
# Paid. Run only with the owner's approval, as AWS_PROFILE=gpu-lab. DRY_RUN=1 stops before anything is launched.
set -euo pipefail

say()  { printf '== %s\n' "$*" >&2; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
spot_say()  { say "$@"; }
spot_fail() { fail "$@"; }

ROOT=$(git rev-parse --show-toplevel)
cd "$ROOT"
# shellcheck source=hack/lib/spot-run.sh
. hack/lib/spot-run.sh

[ "${AWS_PROFILE:-}" = gpu-lab ] || fail "AWS_PROFILE is ${AWS_PROFILE:-unset}; paid sessions run in gpu-lab"
# The source shipped is HEAD, so a change not committed would be absent from the instance and present in the claim.
[ -z "$(git status --porcelain -- api cmd internal config hack)" ] || fail "uncommitted changes under api, cmd, internal, config or hack"

REGION=ap-northeast-2
INSTANCE_TYPE=g5.2xlarge
MAX_SPOT_PRICE=1.10
# The image pull and two engine starts fit in about 25 minutes; the hard stop leaves room, the backstop is the instance's own.
HARD_STOP_SECONDS=2700
BACKSTOP_SECONDS=3000
# The bucket and instance role of the admission sessions, reused rather than created again.
STACK=m5c-gpu

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
NONCE=$(openssl rand -hex 6)
RUN_ID="holdcap-conformance/$STAMP-$NONCE"
OUT="${OUT:-$ROOT/../holdcap-conformance-$STAMP}"
# A fresh directory only, so files a previous run left there can never stand in for this run's evidence.
[ ! -e "$OUT" ] || fail "$OUT already exists; give each run its own OUT"
mkdir -p "$OUT"
COMMIT=$(git rev-parse HEAD)
say "commit $COMMIT, run $RUN_ID, evidence in $OUT"

say "building the manager and the source archive"
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 GOFLAGS=-buildvcs=false go build -o "$OUT/manager" ./cmd
git archive --format=tar.gz -o "$OUT/source.tgz" HEAD
SOURCE_SHA=$(sha256sum "$OUT/source.tgz" | cut -d' ' -f1)
MANAGER_SHA=$(sha256sum "$OUT/manager" | cut -d' ' -f1)
echo "$COMMIT" > "$OUT/commit.txt"

ACCOUNT=$(spot_account) || fail "not authenticated; aws sso login --profile gpu-lab"
BUCKET="$STACK-$ACCOUNT"
spot_ensure_bucket "$BUCKET" "$REGION" 30 || fail "could not prepare the results bucket $BUCKET"
spot_ensure_profile "$STACK" \
  "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"s3:PutObject\",\"s3:GetObject\"],\"Resource\":\"arn:aws:s3:::$BUCKET/*\"}]}" \
  20 || fail "could not prepare the instance profile $STACK"

UD="$OUT/user-data.sh"
sed -e "s|BACKSTOP_SECONDS_PLACEHOLDER|$BACKSTOP_SECONDS|" -e "s|BUCKET_PLACEHOLDER|$BUCKET|" \
    -e "s|RUN_ID_PLACEHOLDER|$RUN_ID|" -e "s|SOURCE_SHA_PLACEHOLDER|$SOURCE_SHA|" \
    -e "s|MANAGER_SHA_PLACEHOLDER|$MANAGER_SHA|" -e "s|COMMIT_PLACEHOLDER|$COMMIT|" \
    hack/holdcap-conformance/instance.sh > "$UD"
! grep -n PLACEHOLDER "$UD" || fail "a placeholder survived in the user-data"
[ "$(head -c 11 "$UD")" = '#!/bin/bash' ] || fail "the user-data does not start with its shebang"
[ "$(wc -c < "$UD")" -lt 16000 ] || fail "the user-data is over EC2's 16 KB limit"

AMI=$(spot_resolve_ami "$REGION" /aws/service/deeplearning/ami/x86_64/base-oss-nvidia-driver-gpu-ubuntu-22.04/latest/ami-id) \
  || fail "could not resolve a GPU AMI"
ZONES=$(spot_zones_offering "$REGION" "$INSTANCE_TYPE")
[ -n "$ZONES" ] || fail "$INSTANCE_TYPE is offered in no zone of $REGION"
T0=$(date +%s)
HARD_STOP=$(( T0 + HARD_STOP_SECONDS ))
# The sweeper (infra/aws/bootstrap/sweeper.tf) ends the instance at this tag even if this shell and the backstop both fail.
STUDY_DEADLINE=$(date -u -d "@$(( T0 + HARD_STOP_SECONDS + 1200 ))" +%Y-%m-%dT%H:%M:%SZ)
TAGS="ResourceType=instance,Tags=[{Key=Name,Value=$STACK},{Key=purpose,Value=holdcap-conformance},{Key=run,Value=$STAMP-$NONCE},{Key=study-deadline,Value=$STUDY_DEADLINE}]"
say "AMI $AMI, zones $ZONES, sweeper deadline $STUDY_DEADLINE"

if [ -n "${DRY_RUN:-}" ]; then
  say "DRY_RUN: nothing uploaded or launched; user-data at $UD"
  exit 0
fi

aws s3 cp "$OUT/source.tgz" "s3://$BUCKET/$RUN_ID/src/source.tgz" >/dev/null || fail "upload the source"
aws s3 cp "$OUT/manager" "s3://$BUCKET/$RUN_ID/bin/manager" >/dev/null || fail "upload the manager"

IID=""
UNCERTAIN=""
UNCERTAIN_SUBNET=""
cleanup() {
  # An instance whose launch answer was lost is found by its token and ended, so a lost answer never leaves one billing.
  if [ -n "$UNCERTAIN" ]; then spot_reconcile_token "$REGION" "$UNCERTAIN" "$UNCERTAIN_SUBNET" 6 || true; fi
  if [ -n "$IID" ]; then spot_terminate "$REGION" "$IID"; fi
}
trap cleanup EXIT

for z in $ZONES; do
  SUBNET=$(spot_subnet_in_zone "$REGION" "$z") || continue
  TOKEN="hcc-$NONCE-$z"
  err="$OUT/launch-errors-$z.txt"
  UNCERTAIN="$TOKEN"; UNCERTAIN_SUBNET="$SUBNET"
  IID=$(spot_launch "$REGION" "$AMI" "$INSTANCE_TYPE" "$SUBNET" "$STACK" "$MAX_SPOT_PRICE" 200 "$UD" "$TAGS" "$TOKEN" 2>"$err") || IID=""
  if [ -n "$IID" ] && [ "$IID" != None ]; then UNCERTAIN=""; break; fi
  IID=""
  # Only a capacity refusal says nothing was created and another zone may answer differently.
  if grep -qiE 'InsufficientInstanceCapacity|capacity-not-available' "$err"; then UNCERTAIN=""; say "no capacity in $z"; continue; fi
  fail "the launch in $z was refused or lost: $(head -c 400 "$err"); any instance under token $TOKEN is ended on exit"
done
[ -n "$IID" ] || fail "no zone had capacity"
say "launched $IID; waiting for the session to end (hard stop in $HARD_STOP_SECONDS s)"
echo "$IID" > "$OUT/instance-id.txt"

set +e
state=$(spot_wait_for_marker_until "$REGION" "$BUCKET" "$RUN_ID/ENDED" "$IID" "$HARD_STOP" 30 1000)
rc=$?
set -e
case "$rc" in
  0) say "the session ended and wrote its evidence" ;;
  2) say "the instance is $state without its ENDED marker; collecting what it uploaded" ;;
  *) say "the hard stop came first; collecting what it uploaded" ;;
esac
aws s3 cp --recursive "s3://$BUCKET/$RUN_ID/" "$OUT/evidence/" --exclude 'src/*' --exclude 'bin/*' >/dev/null || say "the download was incomplete"
spot_terminate "$REGION" "$IID"
IID=""

E="$OUT/evidence/out"
[ -f "$OUT/evidence/failed.txt" ] && fail "the instance reported: $(cat "$OUT/evidence/failed.txt"); read $OUT/evidence/log.txt"
[ -f "$E/DONE" ] || fail "the session did not reach DONE; read $OUT/evidence/log.txt"
[ "$(cat "$E/commit.txt" 2>/dev/null)" = "$COMMIT" ] || fail "the evidence names commit $(cat "$E/commit.txt" 2>/dev/null), not $COMMIT"

# Every part of the claim is a check here, so a run that printed the wrong status cannot end in success.
ok=0
check() { if eval "$2"; then say "PASS $1"; else say "FAIL $1"; ok=1; fi; }
mode_gen() { jq -r '"\(.status.admission.mode // "none") \(.status.admission.observedGeneration // -1) \(.metadata.generation)"' "$1"; }
in_force() { read -r m g gen <<<"$(mode_gen "$1")"; [ "$m" = "$2" ] && [ "$g" = "$gen" ]; }
check "the capped engine runs the measured arguments with the cap" \
  'python3 hack/holdcap-conformance/check-engine-args.py "$E/args-holdcap.txt" 384 Qwen/Qwen2.5-3B-Instruct'
check "the engine after turning off runs the measured arguments without it" \
  'python3 hack/holdcap-conformance/check-engine-args.py "$E/args-off.txt" 0 Qwen/Qwen2.5-3B-Instruct'
check "status was not HoldCap before the engine was ready ($(mode_gen "$E/at-create-infd.json"))" \
  '! in_force "$E/at-create-infd.json" HoldCap'
check "status reported HoldCap for the current generation once the capped engine was ready ($(mode_gen "$E/holdcap-infd.json"))" \
  'in_force "$E/holdcap-infd.json" HoldCap'
check "status reported Off for the new generation right after turning off ($(cat "$E/off-status-latency.txt"))" \
  'in_force "$E/off-immediate-infd.json" Off'
check "status stayed Off after the uncapped rollout ($(mode_gen "$E/off-infd.json"))" \
  'in_force "$E/off-infd.json" Off'
check "the Deployment kept Recreate and its template says Off" \
  '[ "$(jq -r ".spec.strategy.type" "$E/off-deployment.json")" = Recreate ] && [ "$(jq -r ".spec.template.metadata.annotations[\"platform.lkhun9311.github.io/admission\"]" "$E/off-deployment.json")" = Off ]'
for p in 0 1; do
  check "a streaming request at priority $p was answered 200 and completed" \
    '[ "$(cat "$E/request-priority-$p.code")" = 200 ] && grep -q "data: \[DONE\]" "$E/request-priority-$p.txt"'
done
[ "$ok" = 0 ] && say "CONFORMANCE: every check passed" || say "CONFORMANCE: at least one check failed"
exit "$ok"
