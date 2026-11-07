#!/usr/bin/env bash
#
# The Slurm on EC2 session: one t3.medium head and two g5.xlarge workers, Spot, one zone, one attempt.
#
#   SESSION_CONFIRM=yes AWS_PROFILE=gpu-lab SLURMEC2_HEAD_AMI_ID=ami-... SLURMEC2_GPU_AMI_ID=ami-... bash hack/slurm-ec2-session.sh
#
# docs/superpowers/specs/2026-11-07-slurm-ec2-session-design.md is the registration; this is the runner it names.
# It follows hack/gpu-fault-session.sh: the EC2 lifecycle is hack/lib/spot-run.sh's, the user-data is
# hack/lib/slurm-ec2.sh's, and what runs on the instances is hack/slurm-ec2/.
#
# THE CLOCK. T0 is the latest of the three instances' EC2 LaunchTime. The runner writes it, with the three private
# addresses, to the run's S3 prefix as cluster.env; the instances read it and count every deadline from it.
# Each instance stops itself at T0 + 5,700 s, carries the sweeper's tag at T0 + 5,670 s, and the runner's wait for
# termination ends at T0 + 6,100 s.
#
# NOTHING HERE IS A DEFAULT A CALLER CAN MOVE: the registration fixes the instances, the caps and the deadlines, so
# each is a constant, and a caller who sets one is refused rather than ignored.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

REGION=ap-northeast-2
ACCOUNT_WANT=007635145730
HEAD_TYPE=t3.medium
GPU_TYPE=g5.xlarge
HEAD_CAP=0.06
GPU_CAP=0.80
HEAD_VOLUME_GB=30
GPU_VOLUME_GB=100
HEAD_AMI_NAME='ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*'
HEAD_AMI_OWNER=099720109477
GPU_AMI_NAME='Deep Learning Base OSS Nvidia Driver GPU AMI (Ubuntu 24.04) *'
# Amazon's own account for the Deep Learning AMIs in ap-northeast-2.
GPU_AMI_OWNER=898082745236
STUDY_ID=slurm-ec2-2026-11-07
STACK=slurmec2
PURPOSE=slurm-ec2
TAG_AT_REQUEST_S=5670
TAG_FROM_T0_S=5670
STOP_S=5700
TERMINATION_S=6100
# The longest T0 can follow an instance's own boot: the three launches, the read-back and handing cluster.env over.
LAUNCH_SKEW_S=900
DESCRIBE_TRIES=24
SWEEPER_MIN_RUNS=4
# The termination wait's end plus 30 minutes of headroom, and the build, in minutes.
CRED_MIN_MINUTES=135

OUT="${OUT:-hack/slurm-ec2-$(date -u +%Y%m%dT%H%M%SZ)}"
say() { echo "== $*" | { if [ -d "$OUT" ]; then tee -a "$OUT/session.log"; else cat; fi; }; }
fail() { echo "SESSION REFUSED: $*" | { if [ -d "$OUT" ]; then tee -a "$OUT/session.log"; else cat; fi; } >&2; exit 1; }
spot_say() { say "$@"; }
spot_fail() { fail "$@"; }

# ---------------------------------------------------------------- refusals, before anything is built or bought
for v in SLURMEC2_REHEARSAL SLURMEC2_OVERRIDE; do
  [ -z "${!v:-}" ] || fail "$v is set; the paid runner has no rehearsal or override mode"
done
[ "${SESSION_CONFIRM:-}" = yes ] || fail "SESSION_CONFIRM=yes is required: this buys GPU instances, and only the owner's approval starts them"
[[ "${SLURMEC2_HEAD_AMI_ID:-}" =~ ^ami-[0-9a-f]{8,17}$ ]] || fail "SLURMEC2_HEAD_AMI_ID is ${SLURMEC2_HEAD_AMI_ID:-unset}; the registration pins it by ID"
[[ "${SLURMEC2_GPU_AMI_ID:-}" =~ ^ami-[0-9a-f]{8,17}$ ]] || fail "SLURMEC2_GPU_AMI_ID is ${SLURMEC2_GPU_AMI_ID:-unset}; the registration pins it by ID"
for tool in aws python3 git tar sha256sum gzip; do command -v "$tool" >/dev/null || fail "$tool is not installed"; done
[ -z "$(git status --porcelain)" ] || fail "the working tree is dirty; the run's provenance is a commit, and the instances run this tree"
COMMIT=$(git rev-parse HEAD)
ACCOUNT=$(aws sts get-caller-identity --query Account --output text 2>&1) || fail "could not read the caller's account: $ACCOUNT"
[ "$ACCOUNT" = "$ACCOUNT_WANT" ] || fail "the credentials are for account $ACCOUNT; paid sessions run only in gpu-lab ($ACCOUNT_WANT)"
[ ! -e "$OUT" ] || fail "$OUT already exists; each session writes a new directory"
mkdir -p "$OUT" || fail "cannot create $OUT"
say "the Slurm on EC2 session, $STUDY_ID, from $COMMIT, into $OUT"

# shellcheck source=hack/lib/spot-run.sh
. hack/lib/spot-run.sh
# shellcheck source=hack/lib/slurm-ec2.sh
. hack/lib/slurm-ec2.sh

ami_check() {
  local id=$1 want=$2 owner=$3 got
  got=$(aws ec2 describe-images --region "$REGION" --image-ids "$id" --query 'Images[0].[Name,State,OwnerId]' --output text 2>&1) ||
    fail "could not describe $id: $got"
  # shellcheck disable=SC2254
  case "$(cut -f1 <<<"$got")" in $want) ;; *) fail "$id is '$got', not '$want'" ;; esac
  [ "$(cut -f2 <<<"$got")" = available ] || fail "$id is not available: $got"
  [ "$(cut -f3 <<<"$got")" = "$owner" ] || fail "$id is owned by $(cut -f3 <<<"$got"), not $owner"
  printf '%s' "$(cut -f1 <<<"$got")"
}
head_ami=$(ami_check "$SLURMEC2_HEAD_AMI_ID" "$HEAD_AMI_NAME" "$HEAD_AMI_OWNER") || exit 1
gpu_ami=$(ami_check "$SLURMEC2_GPU_AMI_ID" "$GPU_AMI_NAME" "$GPU_AMI_OWNER") || exit 1
# The launch replaces only /dev/sda1's mapping; any other EBS volume an image carries would be created with the image's
# own DeleteOnTermination and could outlive every instance. Only instance-store entries may sit beside the root.
for id in "$SLURMEC2_HEAD_AMI_ID" "$SLURMEC2_GPU_AMI_ID"; do
  maps=$(aws ec2 describe-images --region "$REGION" --image-ids "$id" --query 'Images[0].BlockDeviceMappings' --output json 2>&1) ||
    fail "could not read $id's block devices: $maps"
    want_gb=$GPU_VOLUME_GB; [ "$id" = "$SLURMEC2_HEAD_AMI_ID" ] && want_gb=$HEAD_VOLUME_GB
  python3 - "$maps" <<'PY' || fail "$id maps an EBS volume other than /dev/sda1: $maps"
import json, sys
m = json.loads(sys.argv[1])
sys.exit(0 if all(d.get("DeviceName") == "/dev/sda1" or "Ebs" not in d for d in m) else 1)
PY
  # EC2 refuses a root volume smaller than the image's snapshot, which would only show after the head is bought.
  python3 - "$maps" "$want_gb" <<'PY' || fail "$id's root snapshot is larger than the $want_gb GB the launch asks for: $maps"
import json, sys
root = [d for d in json.loads(sys.argv[1]) if d.get("DeviceName") == "/dev/sda1"]
sys.exit(0 if len(root) == 1 and 0 < root[0].get("Ebs", {}).get("VolumeSize", 10**9) <= int(sys.argv[2]) else 1)
PY
done
say "AMIs: head $SLURMEC2_HEAD_AMI_ID ($head_ami), workers $SLURMEC2_GPU_AMI_ID ($gpu_ami)"

prices=$(aws ec2 describe-spot-price-history --region "$REGION" --instance-types "$GPU_TYPE" "$HEAD_TYPE" \
  --product-descriptions "Linux/UNIX" --start-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --query 'SpotPriceHistory[].[InstanceType,AvailabilityZone,SpotPrice]' --output text 2>&1) || fail "could not read the Spot prices: $prices"
printf '%s\n' "$prices" >"$OUT/spot-prices.txt"
# A zone counts only when both types are offered there under their caps; one of the three in another zone is not this design.
ZONES=$(python3 - "$GPU_TYPE" "$GPU_CAP" "$HEAD_TYPE" "$HEAD_CAP" "$OUT/spot-prices.txt" <<'PY'
import sys
gpu, gcap, head, hcap, path = sys.argv[1], float(sys.argv[2]), sys.argv[3], float(sys.argv[4]), sys.argv[5]
ok = {gpu: set(), head: set()}
for line in open(path):
    f = line.split()
    if len(f) != 3:
        continue
    t, z, p = f[0], f[1], float(f[2])
    if t in ok and 0 < p <= {gpu: gcap, head: hcap}[t]:
        ok[t].add(z)
print(" ".join(sorted(ok[gpu] & ok[head])))
PY
) || fail "could not read the price table"
[ -n "$ZONES" ] || fail "no zone offers $GPU_TYPE at or under \$$GPU_CAP/h and $HEAD_TYPE at or under \$$HEAD_CAP/h: $(paste -sd' ' "$OUT/spot-prices.txt")"
say "zones with both types under their caps: $ZONES"
# A default subnet maps public addresses, which says nothing of whether its route table reaches the internet; the
# instances fetch packages, PyTorch and their inputs, so a zone whose subnet has no active 0.0.0.0/0 route to an
# internet gateway would buy three instances that can do nothing. Its own route table, or the VPC's main one.
routed=""
for z in $ZONES; do
  sn=$(spot_subnet_in_zone "$REGION" "$z") || { say "no default subnet in $z"; continue; }
  # The table that applies is the one associated with the subnet, and the main one only when there is none: a table
  # that is associated but has no internet route must not fall back to the main table.
  tid=$(aws ec2 describe-route-tables --region "$REGION" --filters "Name=association.subnet-id,Values=$sn" \
    --query 'RouteTables[0].RouteTableId' --output text 2>&1) || fail "the route table of $sn could not be read: $tid"
  if [ -z "$tid" ] || [ "$tid" = None ]; then
    vpc_of=$(aws ec2 describe-subnets --region "$REGION" --subnet-ids "$sn" --query 'Subnets[0].VpcId' --output text 2>&1) ||
      fail "the VPC of $sn could not be read: $vpc_of"
    tid=$(aws ec2 describe-route-tables --region "$REGION" --filters "Name=vpc-id,Values=$vpc_of" Name=association.main,Values=true \
      --query 'RouteTables[0].RouteTableId' --output text 2>&1) || fail "the main route table of $vpc_of could not be read: $tid"
  fi
  [[ "$tid" =~ ^rtb- ]] || fail "no route table applies to $sn ('$tid')"
  rt=$(aws ec2 describe-route-tables --region "$REGION" --route-table-ids "$tid" \
    --query 'RouteTables[0].Routes[?DestinationCidrBlock==`0.0.0.0/0` && State==`active`].GatewayId' --output text 2>&1) ||
    fail "the routes of $tid could not be read: $rt"
  if [[ "$rt" =~ ^igw-[0-9a-f]+$ ]]; then routed="$routed $z"; else say "$z's subnet $sn does not route 0.0.0.0/0 to an internet gateway ('$rt')"; fi
done
ZONES=${routed# }
[ -n "$ZONES" ] || fail "no zone with both types under their caps has a default subnet routing 0.0.0.0/0 to an internet gateway"
say "zones whose subnet reaches the internet: $ZONES"

quota=$(aws service-quotas get-service-quota --region "$REGION" --service-code ec2 --quota-code L-3819A6DF \
  --query 'Quota.Value' --output text 2>&1) || fail "could not read the G and VT Spot quota: $quota"
# The limit is shared with every G and VT Spot instance in the Region, running or pending, whatever its purpose;
# two g5.xlarge need 8 of what is left, or the second would be refused after the head and the first were bought.
used=$(aws ec2 describe-instances --region "$REGION" \
  --filters Name=instance-lifecycle,Values=spot Name=instance-state-name,Values=pending,running \
  --query 'Reservations[].Instances[].[InstanceType,CpuOptions.CoreCount,CpuOptions.ThreadsPerCore]' --output text 2>&1) ||
  fail "the running Spot instances could not be listed: $used"
free=$(python3 - "$quota" "$used" <<'PY'
import sys
limit, used = float(sys.argv[1]), 0
for line in sys.argv[2].splitlines():
    f = line.split()
    # The G and VT quota covers the families named g* and vt*.
    if len(f) == 3 and f[0].startswith(("g", "vt")):
        used += int(f[1]) * int(f[2])
print(int(limit - used))
PY
) || fail "could not compute the free G and VT Spot vCPUs"
[ "$free" -ge 8 ] || fail "the G and VT Spot quota is $quota vCPU with $(( ${quota%.*} - free )) in use; two $GPU_TYPE need 8 and $free are free"
say "G and VT Spot vCPUs: $quota, $free free"

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
# Every datapoint in the window, summed: the first alone can be the clean one beside a bucket with errors.
sw_metric() {
  aws cloudwatch get-metric-statistics --region "$REGION" --namespace AWS/Lambda --metric-name "$1" \
    --dimensions Name=FunctionName,Value=gpu-platform-study-sweeper \
    --start-time "$(date -u -d '-30 min' +%Y-%m-%dT%H:%M:%SZ)" --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --period 300 --statistics Sum --query 'Datapoints[].Sum' --output text
}
sw_runs=$(sw_metric Invocations 2>&1) || fail "the sweeper's invocations could not be read: $sw_runs"
sw_errors=$(sw_metric Errors 2>&1) || fail "the sweeper's errors could not be read: $sw_errors"
python3 - "$sw_runs" "$sw_errors" "$SWEEPER_MIN_RUNS" <<'PY' || fail "the sweeper ran '$sw_runs' with errors '$sw_errors' in the last 30 minutes; at least $SWEEPER_MIN_RUNS clean runs are required"
import sys
def total(s):
    vals = [v for v in s.split() if v != "None"]
    return sum(float(v) for v in vals), len(vals)
runs, n = total(sys.argv[1])
errors, _ = total(sys.argv[2])
sys.exit(0 if n > 0 and runs >= int(sys.argv[3]) and errors == 0 else 1)
PY
# The sweeper's invocations succeed with nothing to sweep, which says nothing about whether it may terminate; its role is
# asked directly whether it may.
sw_role=$(aws lambda get-function-configuration --region "$REGION" --function-name gpu-platform-study-sweeper --query Role --output text 2>&1) ||
  fail "the sweeper's role could not be read: $sw_role"
# Its policy allows termination only of instances carrying a study-deadline tag, which is what this session's carry.
sw_can=$(aws iam simulate-principal-policy --policy-source-arn "$sw_role" --action-names ec2:TerminateInstances \
  --resource-arns "arn:aws:ec2:$REGION:$ACCOUNT_WANT:instance/i-0123456789abcdef0" \
  --context-entries "ContextKeyName=aws:ResourceTag/study-deadline,ContextKeyValues=2026-01-01T00:00:00Z,ContextKeyType=string" \
  --query 'EvaluationResults[0].EvalDecision' --output text 2>&1) || fail "the sweeper's permission could not be simulated: $sw_can"
[ "$sw_can" = allowed ] || fail "the sweeper's role $sw_role may not terminate instances ($sw_can)"
say "the termination sweeper: Active, ENABLED rate(5 minutes), runs [$sw_runs], errors [${sw_errors:-none}] in the last 30 minutes"

cred_left() {
  local j e
  j=$(aws configure export-credentials --format process 2>&1) || { echo "export failed: $j"; return 1; }
  e=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("Expiration",""))' "$j") || { echo "not JSON"; return 1; }
  [ -n "$e" ] || { echo "no expiry"; return 1; }
  python3 -c 'import datetime,sys; e=datetime.datetime.fromisoformat(sys.argv[1].replace("Z","+00:00")); print(int((e-datetime.datetime.now(datetime.timezone.utc)).total_seconds()//60))' "$e"
}
left_min=$(cred_left) || fail "the credential's expiry could not be read: $left_min"
[ "$left_min" -ge "$CRED_MIN_MINUTES" ] || fail "the credentials expire in $left_min minutes; the session needs $CRED_MIN_MINUTES. Re-authenticate first"
say "credentials expire in $left_min minutes"

live=$(aws ec2 describe-instances --region "$REGION" --filters "Name=tag:purpose,Values=$PURPOSE" \
  "Name=instance-state-name,Values=pending,running,shutting-down,stopping,stopped" \
  --query 'Reservations[].Instances[].InstanceId' --output text 2>&1) || fail "could not list earlier instances: $live"
[ -z "$live" ] || fail "an earlier Slurm on EC2 instance is still live ($live); one attempt is registered"

# ---------------------------------------------------------------- what the instances run
git archive --format=tar.gz -o "$OUT/source.tgz" HEAD || fail "git archive"
SOURCE_SHA=$(sha256sum "$OUT/source.tgz" | cut -d' ' -f1)
RUN_NONCE=$(python3 -c 'import secrets; print(secrets.token_hex(4))')
RUN_ID="$(basename "$OUT")-$RUN_NONCE"
[[ "$RUN_ID" =~ ^[A-Za-z0-9._-]+$ ]] || fail "the run id '$RUN_ID', made from OUT, is not one S3 key segment of letters, digits, '.', '_' and '-'"
BUCKET="$STACK-$ACCOUNT"
# The munge key is the cluster's shared secret: made here, kept outside the run directory, which is committed.
SECRETS=$(mktemp -d)
dd if=/dev/urandom of="$SECRETS/munge.key" bs=1024 count=1 status=none || fail "could not make the munge key"
{
  echo "commit=$COMMIT"
  echo "study=$STUDY_ID"
  echo "head_ami=$SLURMEC2_HEAD_AMI_ID $head_ami"
  echo "gpu_ami=$SLURMEC2_GPU_AMI_ID $gpu_ami"
  echo "head_type=$HEAD_TYPE cap=$HEAD_CAP"
  echo "gpu_type=$GPU_TYPE cap=$GPU_CAP"
  echo "source_sha256=$SOURCE_SHA"
  echo "run_id=$RUN_ID"
} >"$OUT/session-provenance.txt"

for role in head gpu1 gpu2; do
  # The boot-relative backstop is the precise T0 one plus the launch skew, so it never fires first on an instance that
  # booted before T0; an instance that never learns T0 stops itself within 900 s of boot anyway (instance.sh).
  slurmec2_render_userdata "$role" "$OUT/user-data-$role.sh" "$BUCKET" "$RUN_ID" "$SOURCE_SHA" "$STOP_S" $(( STOP_S + LAUNCH_SKEW_S )) || fail "render $role"
  bash -n "$OUT/user-data-$role.sh" || fail "the $role user-data does not parse"
  [ "$(head -c 2 "$OUT/user-data-$role.sh")" = '#!' ] || fail "the $role user-data has no shebang"
  [ "$(wc -c <"$OUT/user-data-$role.sh")" -lt 16384 ] || fail "the $role user-data is over EC2's 16 KB"
done

# ---------------------------------------------------------------- the purchase
IIDS=()
UNCERTAIN=()
SG=""
# Instances whose termination EC2 confirmed; the cleanup acts on every launched one not in it, whatever ran before.
declare -A GONE=()
cleanup_ran=0
cleanup() {
  [ "$cleanup_ran" = 1 ] && return 0
  cleanup_ran=1
  local bad=0 u iid i
  rm -rf "$SECRETS"
  aws s3 rm --only-show-errors "s3://$BUCKET/$RUN_ID/munge.key" >>"$OUT/cleanup.txt" 2>&1 || echo "the munge key could not be removed from S3" >>"$OUT/cleanup.txt"
  # Uploads this session started and never finished bill until aborted; the lifecycle aborts them after a day anyway.
  local up
  for up in $(aws s3api list-multipart-uploads --bucket "$BUCKET" --prefix "$RUN_ID/" --query 'Uploads[].[Key,UploadId]' --output text 2>>"$OUT/cleanup.txt" | tr '\t' '|'); do
    [ "$up" != None ] || continue
    aws s3api abort-multipart-upload --bucket "$BUCKET" --key "${up%%|*}" --upload-id "${up##*|}" >>"$OUT/cleanup.txt" 2>&1 ||
      echo "an upload of ${up%%|*} could not be aborted; the bucket's lifecycle aborts it within a day" >>"$OUT/cleanup.txt"
  done
  for u in ${UNCERTAIN[@]+"${UNCERTAIN[@]}"}; do
    spot_reconcile_token "$REGION" "${u%% *}" "${u##* }" 6 || { echo "TERMINATION UNCONFIRMED for the launch under token ${u%% *}" | tee -a "$OUT/termination.txt" >&2; bad=1; }
  done
  [ ${#IIDS[@]} -gt 0 ] || echo "no instance was launched by this session" >>"$OUT/termination.txt"
  # One deadline for all the waits below, so an interrupted session's teardown is bounded however many are left.
  local cleanup_deadline=$(( $(date +%s) + 600 ))
  for iid in ${IIDS[@]+"${IIDS[@]}"}; do
    [ -z "${GONE[$iid]:-}" ] || continue
    SPOT_TERMINATE_WAIT=$(( cleanup_deadline - $(date +%s) ))
    [ "$SPOT_TERMINATE_WAIT" -ge 5 ] || SPOT_TERMINATE_WAIT=5
    SPOT_TERMINATE_TRIES=$(( SPOT_TERMINATE_WAIT / 5 + 1 ))
    if spot_terminate "$REGION" "$iid"; then GONE[$iid]=1; echo "terminated $iid" >>"$OUT/termination.txt"
    else echo "TERMINATION UNCONFIRMED for $iid -- check the console now" | tee -a "$OUT/termination.txt" >&2; bad=1; fi
  done
  # The group goes once nothing uses it; an instance still shutting down holds it for a while.
  if [ -n "$SG" ]; then
    for i in 1 2 3 4 5 6; do
      aws ec2 delete-security-group --region "$REGION" --group-id "$SG" >>"$OUT/cleanup.txt" 2>&1 && { SG=""; break; }
      sleep 10
    done
    [ -z "$SG" ] || { echo "the security group $SG could not be deleted (it costs nothing; delete it by hand)" | tee -a "$OUT/termination.txt" >&2; }
  fi
  [ "$bad" = 0 ] || exit 1
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

spot_ensure_bucket "$BUCKET" "$REGION" 30 || fail "could not prepare the results bucket $BUCKET"
# The bucket is this session's own (named for it), so its lifecycle is written on every run rather than trusted:
# objects expire after 30 days and an interrupted multipart upload is aborted after 1, which expiry alone does not do.
# It is then read back, and only an unfiltered rule carrying both counts.
aws s3api put-bucket-lifecycle-configuration --bucket "$BUCKET" --lifecycle-configuration \
  '{"Rules":[{"ID":"expire","Status":"Enabled","Filter":{"Prefix":""},"Expiration":{"Days":30},"AbortIncompleteMultipartUpload":{"DaysAfterInitiation":1}}]}' \
  >>"$OUT/launch-errors.txt" 2>&1 || fail "could not write the bucket's lifecycle"
lc=$(aws s3api get-bucket-lifecycle-configuration --bucket "$BUCKET" --output json 2>&1) || fail "the bucket's lifecycle could not be read: $lc"
python3 - "$lc" <<'PY' || fail "the bucket $BUCKET has no unfiltered rule expiring objects within 30 days and aborting uploads: $lc"
import json, sys
rules = json.loads(sys.argv[1]).get("Rules", [])
def unfiltered(r):
    f = r.get("Filter")
    if f is None:
        return r.get("Prefix", None) == ""
    return f in ({}, {"Prefix": ""})
ok = any(r.get("Status") == "Enabled" and unfiltered(r)
         and 0 < r.get("Expiration", {}).get("Days", 0) <= 30
         and 0 < r.get("AbortIncompleteMultipartUpload", {}).get("DaysAfterInitiation", 0) <= 7 for r in rules)
sys.exit(0 if ok else 1)
PY
ver=$(aws s3api get-bucket-versioning --bucket "$BUCKET" --query Status --output text 2>&1) || fail "the bucket's versioning could not be read: $ver"
case "$ver" in None|"") ;; *) fail "the bucket $BUCKET has versioning $ver, so its objects can outlive the expiry" ;; esac
# The instance role has S3 permissions and no KMS ones, so only S3-managed encryption lets the instances read their
# inputs, and a bucket policy could deny what the role allows; either would show only after the purchase.
enc=$(aws s3api get-bucket-encryption --bucket "$BUCKET" \
  --query 'ServerSideEncryptionConfiguration.Rules[].ApplyServerSideEncryptionByDefault.SSEAlgorithm' --output text 2>&1) ||
  fail "the bucket's encryption could not be read: $enc"
[ "$enc" = AES256 ] || fail "the bucket $BUCKET encrypts with '$enc', not S3-managed AES256, which the instance role cannot decrypt"
if bp=$(aws s3api get-bucket-policy --bucket "$BUCKET" --output text 2>&1); then
  fail "the bucket $BUCKET has a bucket policy this session did not write: $bp"
fi
grep -q NoSuchBucketPolicy <<<"$bp" || fail "the bucket's policy could not be read: $bp"
# A Recycle Bin rule for EBS volumes would keep the three root volumes billed after their instances terminate.
rb=$(aws rbin list-rules --region "$REGION" --resource-type EBS_VOLUME --query 'length(Rules)' --output text 2>&1) ||
  fail "the Recycle Bin rules for EBS volumes could not be read: $rb"
[ "$rb" = 0 ] || fail "$rb Recycle Bin rule(s) retain EBS volumes in $REGION, so the root volumes would outlive the instances"
spot_ensure_profile "$STACK" \
  "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"s3:PutObject\",\"s3:GetObject\"],\"Resource\":\"arn:aws:s3:::$BUCKET/*\"},{\"Effect\":\"Allow\",\"Action\":\"s3:ListBucket\",\"Resource\":\"arn:aws:s3:::$BUCKET\"}]}" \
  20 || fail "could not prepare the instance profile $STACK"
# An existing profile is not trusted: its role must be this one, trust EC2, and carry this run's policy, written again.
prof_role=$(aws iam get-instance-profile --instance-profile-name "$STACK" --query 'InstanceProfile.Roles[].RoleName' --output text 2>&1) ||
  fail "the instance profile $STACK could not be read: $prof_role"
[ "$prof_role" = "$STACK" ] || fail "the instance profile $STACK carries role(s) '$prof_role', not $STACK"
role_json=$(aws iam get-role --role-name "$STACK" --output json 2>&1) || fail "the role $STACK could not be read: $role_json"
# The whole trust document and no permissions boundary: a condition or a boundary could deny what the policy allows.
python3 - "$role_json" <<'PY' || fail "the role $STACK's trust or boundary is not this session's: $role_json"
import json, sys
role = json.loads(sys.argv[1])["Role"]
doc = role["AssumeRolePolicyDocument"]
want = [{"Effect": "Allow", "Principal": {"Service": "ec2.amazonaws.com"}, "Action": "sts:AssumeRole"}]
sys.exit(0 if doc.get("Statement") == want and "PermissionsBoundary" not in role else 1)
PY
inline=$(aws iam list-role-policies --role-name "$STACK" --query 'PolicyNames' --output text 2>&1) || fail "the role's inline policies could not be read: $inline"
[ "$inline" = write-results ] || [ "$inline" = "" ] || fail "the role $STACK carries inline policies '$inline' besides this session's"
aws iam put-role-policy --role-name "$STACK" --policy-name write-results --policy-document \
  "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"s3:PutObject\",\"s3:GetObject\"],\"Resource\":\"arn:aws:s3:::$BUCKET/*\"},{\"Effect\":\"Allow\",\"Action\":\"s3:ListBucket\",\"Resource\":\"arn:aws:s3:::$BUCKET\"}]}" \
  >>"$OUT/launch-errors.txt" 2>&1 || fail "could not write the role's policy"
extra=$(aws iam list-attached-role-policies --role-name "$STACK" --query 'AttachedPolicies[].PolicyArn' --output text 2>&1) ||
  fail "the role's attached policies could not be read: $extra"
[ -z "$extra" ] || fail "the role $STACK has attached policies ($extra) this session did not grant"
# The session's own security group: the three instances reach each other and nothing reaches them from outside.
# The default group in gpu-lab admits all TCP from anywhere, which would put slurmctld and the NFS export on the internet.
VPC=$(aws ec2 describe-vpcs --region "$REGION" --filters Name=is-default,Values=true --query 'Vpcs[0].VpcId' --output text 2>&1)
[[ "$VPC" =~ ^vpc- ]] || fail "could not find the default VPC: $VPC"
SG=$(aws ec2 create-security-group --region "$REGION" --vpc-id "$VPC" --group-name "$STACK-$RUN_NONCE" \
  --description "slurm on ec2 session $RUN_NONCE" \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=purpose,Value=$PURPOSE},{Key=run,Value=$RUN_NONCE}]" \
  --query GroupId --output text 2>&1) || { SG=""; fail "could not create the session's security group"; }
[[ "$SG" =~ ^sg- ]] || { SG=""; fail "the security group's id is '$SG'"; }
echo "$SG" >"$OUT/security-group.txt"
aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$SG" \
  --ip-permissions "IpProtocol=-1,UserIdGroupPairs=[{GroupId=$SG}]" >>"$OUT/launch-errors.txt" 2>&1 ||
  fail "could not let the session's instances reach each other"
aws s3 cp --only-show-errors "$OUT/source.tgz" "s3://$BUCKET/$RUN_ID/src/source.tgz" || fail "upload source"
aws s3 cp --only-show-errors "$SECRETS/munge.key" "s3://$BUCKET/$RUN_ID/munge.key" || fail "upload the munge key"

# The credential is read again here: the build and uploads above took time from it.
left_min=$(cred_left) || fail "the credential's expiry could not be read before the purchase: $left_min"
[ "$left_min" -ge $(( TERMINATION_S / 60 + 10 )) ] || fail "the credentials now expire in $left_min minutes, too few for the session and its teardown"

request_epoch=$(date +%s)
# The launch tag allows for the skew between this request and T0, the last LaunchTime; a tag counted from the request
# alone would let the sweeper cut the session short if the rewrite to T0 failed. Later means bounded extra cost, not loss.
TAG_DEADLINE=$(date -u -d "@$(( request_epoch + TAG_AT_REQUEST_S + LAUNCH_SKEW_S ))" +%Y-%m-%dT%H:%M:%SZ)
# launch_one ZONE SUBNET ROLE: sets LAUNCHED to the instance id and returns 0, or returns 1 with the error in
# $OUT/launch-error-ROLE-ZONE.txt. Called directly, never in $(...): IIDS and UNCERTAIN must change in this shell.
launch_one() {
  local z=$1 subnet=$2 role=$3 type ami cap vol token tags iid
  LAUNCHED=""
  if [ "$role" = head ]; then type=$HEAD_TYPE ami=$SLURMEC2_HEAD_AMI_ID cap=$HEAD_CAP vol=$HEAD_VOLUME_GB
  else type=$GPU_TYPE ami=$SLURMEC2_GPU_AMI_ID cap=$GPU_CAP vol=$GPU_VOLUME_GB; fi
  token="slurmec2-$RUN_NONCE-$role-$z"
  tags="ResourceType=instance,Tags=[{Key=Name,Value=$STACK-$role},{Key=purpose,Value=$PURPOSE},{Key=role,Value=$role},{Key=run,Value=$RUN_NONCE},{Key=study-deadline,Value=$TAG_DEADLINE}]"
  UNCERTAIN+=("$token $subnet")
  iid=$(spot_launch "$REGION" "$ami" "$type" "$subnet" "$STACK" "$cap" "$vol" "$OUT/user-data-$role.sh" "$tags" "$token" "$SG" \
    2>"$OUT/launch-error-$role-$z.txt") || iid=""
  cat "$OUT/launch-error-$role-$z.txt" >>"$OUT/launch-errors.txt"
  if [ -n "$iid" ] && [ "$iid" != None ]; then
    IIDS+=("$iid")
    unset 'UNCERTAIN[-1]'
    LAUNCHED=$iid
    return 0
  fi
  # A refusal for capacity created nothing, so the token needs no reconciling; anything else may have.
  grep -qiE 'InsufficientInstanceCapacity|capacity-not-available' "$OUT/launch-error-$role-$z.txt" && unset 'UNCERTAIN[-1]'
  return 1
}
say "launching $HEAD_TYPE (max \$$HEAD_CAP/h) and two $GPU_TYPE (max \$$GPU_CAP/h) Spot, study-deadline $TAG_DEADLINE -- they bill from here"
declare -A IID_OF=()
for z in $ZONES; do
  SUBNET=$(spot_subnet_in_zone "$REGION" "$z") || continue
  ok=1
  for role in head gpu1 gpu2; do
    if launch_one "$z" "$SUBNET" "$role"; then IID_OF[$role]=$LAUNCHED; continue; fi
    ok=0
    grep -qiE 'InsufficientInstanceCapacity|capacity-not-available' "$OUT/launch-error-$role-$z.txt" ||
      fail "the $role launch in $z was refused for a reason that is not capacity; see $OUT/launch-errors.txt"
    break
  done
  [ "$ok" = 1 ] && break
  # Part of the trio in one zone is not the design: what was launched there is terminated before the next zone.
  for role in head gpu1 gpu2; do
    [ -n "${IID_OF[$role]:-}" ] || continue
    spot_terminate "$REGION" "${IID_OF[$role]}" || fail "could not confirm terminating ${IID_OF[$role]} in $z before trying another zone"
    GONE[${IID_OF[$role]}]=1
    echo "terminated ${IID_OF[$role]} ($role, $z: the trio did not fit)" >>"$OUT/termination.txt"
    unset "IID_OF[$role]"
  done
done
[ "${#IID_OF[@]}" = 3 ] || fail "no zone had capacity for all three instances; nothing is left running"
printf '%s %s\n' head "${IID_OF[head]}" gpu1 "${IID_OF[gpu1]}" gpu2 "${IID_OF[gpu2]}" >"$OUT/instance-ids.txt"
say "launched head ${IID_OF[head]}, gpu1 ${IID_OF[gpu1]}, gpu2 ${IID_OF[gpu2]} in $z"

# LaunchTime, image and private address of each, read back; an instance on another image ends the session.
T0=0
declare -A IP_OF=()
for role in head gpu1 gpu2; do
  desc=""
  for _ in $(seq 1 "$DESCRIBE_TRIES"); do
    desc=$(aws ec2 describe-instances --region "$REGION" --instance-ids "${IID_OF[$role]}" \
      --query 'Reservations[0].Instances[0].[LaunchTime,ImageId,PrivateIpAddress,BlockDeviceMappings[0].Ebs.VolumeId]' --output text 2>&1) &&
      [ "$(wc -w <<<"$desc")" = 4 ] && [ "$(awk '{print $3}' <<<"$desc")" != None ] && [ "$(awk '{print $4}' <<<"$desc")" != None ] && break
    desc=""
    sleep 5
  done
  [ -n "$desc" ] || fail "could not read $role's LaunchTime, image and address"
  read -r lt img ip vol <<<"$desc"
  echo "$vol" >>"$OUT/volumes.txt"
  want=$SLURMEC2_GPU_AMI_ID; [ "$role" = head ] && want=$SLURMEC2_HEAD_AMI_ID
  [ "$img" = "$want" ] || fail "$role runs $img, not the pinned $want"
  e=$(date -u -d "$lt" +%s) || fail "$role's LaunchTime '$lt'"
  [ "$e" -gt "$T0" ] && T0=$e
  IP_OF[$role]=$ip
  echo "$role ${IID_OF[$role]} $lt $img $ip" >>"$OUT/instances.txt"
done
printf 'T0=%s\nHEAD_IP=%s\nGPU1_IP=%s\nGPU2_IP=%s\n' "$T0" "${IP_OF[head]}" "${IP_OF[gpu1]}" "${IP_OF[gpu2]}" >"$OUT/cluster.env"
aws s3 cp --only-show-errors "$OUT/cluster.env" "s3://$BUCKET/$RUN_ID/cluster.env" ||
  fail "could not hand cluster.env to the instances; they will stop themselves, and this session terminates them"
TAG_T0=$(date -u -d "@$(( T0 + TAG_FROM_T0_S ))" +%Y-%m-%dT%H:%M:%SZ)
if aws ec2 create-tags --region "$REGION" --resources "${IID_OF[head]}" "${IID_OF[gpu1]}" "${IID_OF[gpu2]}" \
  --tags "Key=study-deadline,Value=$TAG_T0" 2>>"$OUT/launch-errors.txt"; then
  say "T0 $(date -u -d "@$T0" +%FT%TZ); the sweeper's deadline moved to $TAG_T0"
else
  say "T0 $(date -u -d "@$T0" +%FT%TZ); the sweeper's deadline could not be moved and stays at $TAG_DEADLINE"
fi

# ---------------------------------------------------------------- the wait, and the end
spot_wait_for_marker_until "$REGION" "$BUCKET" "$RUN_ID/DONE" "${IID_OF[head]}" $(( T0 + STOP_S )) 20 400 >"$OUT/wait.txt"
wait_rc=$?
say "the wait ended with status $wait_rc ($(cat "$OUT/wait.txt"))"
# All three asked at once, then each waited for against one absolute deadline, so the waits do not add up.
aws ec2 terminate-instances --region "$REGION" --instance-ids "${IID_OF[head]}" "${IID_OF[gpu1]}" "${IID_OF[gpu2]}" \
  >>"$OUT/termination.txt" 2>&1 || echo "the joint terminate call failed; each is asked again below" >>"$OUT/termination.txt"
TERM_DEADLINE=$(( T0 + TERMINATION_S ))
[ "$TERM_DEADLINE" -ge $(( $(date +%s) + 60 )) ] || TERM_DEADLINE=$(( $(date +%s) + 60 ))
TERMINATION=confirmed
for role in head gpu1 gpu2; do
  SPOT_TERMINATE_WAIT=$(( TERM_DEADLINE - $(date +%s) ))
  [ "$SPOT_TERMINATE_WAIT" -ge 5 ] || SPOT_TERMINATE_WAIT=5
  SPOT_TERMINATE_TRIES=$(( SPOT_TERMINATE_WAIT / 5 + 1 ))
  if spot_terminate "$REGION" "${IID_OF[$role]}"; then
    GONE[${IID_OF[$role]}]=1
    echo "terminated ${IID_OF[$role]} ($role)" >>"$OUT/termination.txt"
  else
    TERMINATION=unconfirmed
    echo "TERMINATION UNCONFIRMED for ${IID_OF[$role]} ($role) -- terminate it by hand now" | tee -a "$OUT/termination.txt" >&2
  fi
done
# Terminated instances should leave no volume: any left (detached, or kept by a rule made since the check) still bills.
if [ "$TERMINATION" = confirmed ] && [ -s "$OUT/volumes.txt" ]; then
  left_vols=$(aws ec2 describe-volumes --region "$REGION" --filters "Name=volume-id,Values=$(paste -sd, "$OUT/volumes.txt")" \
    --query 'Volumes[].VolumeId' --output text 2>&1) || left_vols="unreadable: $left_vols"
  if [ -n "$left_vols" ]; then
    TERMINATION=unconfirmed
    echo "VOLUMES STILL PRESENT after termination: $left_vols -- delete them by hand" | tee -a "$OUT/termination.txt" >&2
  fi
fi
for k in evidence.latest DONE log-head.txt log-gpu1.txt log-gpu2.txt stopped-gpu1 stopped-gpu2; do
  aws s3 cp --only-show-errors "s3://$BUCKET/$RUN_ID/$k" "$OUT/$k" 2>>"$OUT/download-errors.txt" || echo "not downloaded: $k" >>"$OUT/download-errors.txt"
done
# evidence.latest names the last archive head verified in S3, and is there even when head died before DONE.
n=$(sed -n 's/^n=\([0-9]*\) .*/\1/p' "$OUT/evidence.latest" 2>>"$OUT/download-errors.txt")
want=$(sed -n 's/.*sha256=\([0-9a-f]*\).*/\1/p' "$OUT/evidence.latest" 2>>"$OUT/download-errors.txt")
if [ -n "$n" ]; then
  aws s3 cp --only-show-errors "s3://$BUCKET/$RUN_ID/evidence-$n.tgz" "$OUT/evidence.tgz" 2>>"$OUT/download-errors.txt" ||
    echo "not downloaded: evidence-$n.tgz" >>"$OUT/download-errors.txt"
fi
# The archive is checked against the digest DONE names before anything relies on it, unpacked into a staging directory,
# and moved into place only whole; the S3 copy is removed only after that.
UNPACKED=no
if [ -s "$OUT/evidence.tgz" ]; then
  if [ -z "$want" ] || [ "$want" != "$(sha256sum "$OUT/evidence.tgz" | cut -d' ' -f1)" ]; then
    echo "the downloaded archive is not the one head last verified (evidence.latest names '${want:-none}')" | tee -a "$OUT/download-errors.txt"
  elif mkdir "$OUT/.staging" && tar -xzf "$OUT/evidence.tgz" -C "$OUT/.staging" && [ -d "$OUT/.staging/evidence" ] && mv "$OUT/.staging/evidence" "$OUT/evidence"; then
    UNPACKED=yes
  else
    echo "the evidence archive did not unpack" >>"$OUT/download-errors.txt"
  fi
  rm -rf "$OUT/.staging"
fi
# The measurement's status apart from the teardown's: 0 every check observed (rules may still not have held),
# 4 scored but some check INVALID or NOTRUN, or an archive that is not the last one head verified, 3 VOID, no evidence
# or a failed scorer.
MEASURED=3
if [ -d "$OUT/evidence" ] && [ "$UNPACKED" = yes ]; then
  python3 hack/slurm-ec2/score.py "$OUT/evidence" "$OUT/verdict.json" | tee "$OUT/verdict.txt"
  score_rc=${PIPESTATUS[0]}
  if [ "$score_rc" != 0 ]; then echo "SCORER FAILED with status $score_rc" | tee -a "$OUT/verdict.txt"
  elif grep -q '^SLURM ON EC2: VOID' "$OUT/verdict.txt"; then MEASURED=3
  elif python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))["complete"] else 1)' "$OUT/verdict.json"; then MEASURED=0
  else MEASURED=4; fi
  # An earlier archive than the final one is verified but lacks the later checks or diagnostics.
  grep -qx 'evidence_final=yes' "$OUT/DONE" 2>>"$OUT/download-errors.txt" ||
    { echo "head did not report its final archive verified (or never wrote DONE); this may be an earlier one" | tee -a "$OUT/verdict.txt"; [ "$MEASURED" = 0 ] && MEASURED=4; }
  # Downloaded and unpacked, so the run's prefix is no longer the only copy; it would otherwise wait 30 days to expire.
  # Only when head reported its final archive verified: otherwise a newer archive may sit there unreferenced.
  grep -qx 'evidence_final=yes' "$OUT/DONE" 2>>"$OUT/download-errors.txt" && aws s3 rm --only-show-errors --recursive "s3://$BUCKET/$RUN_ID/" >>"$OUT/cleanup.txt" 2>&1 || echo "the run's S3 prefix could not be removed; it expires in 30 days" >>"$OUT/cleanup.txt"
else
  echo "SLURM ON EC2: NO-EVIDENCE (the evidence archive did not come back whole; the run's S3 prefix is kept, and expires in 30 days)" | tee "$OUT/verdict.txt"
fi
echo "termination=$TERMINATION" >>"$OUT/verdict.txt"
echo "measured=$(case "$MEASURED" in 0) echo complete ;; 4) echo incomplete ;; *) echo no ;; esac)" >>"$OUT/verdict.txt"
say "the verdict is in $OUT/verdict.txt"
[ "$TERMINATION" = confirmed ] || exit 1
exit "$MEASURED"
