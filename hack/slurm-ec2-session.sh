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

quota=$(aws service-quotas get-service-quota --region "$REGION" --service-code ec2 --quota-code L-3819A6DF \
  --query 'Quota.Value' --output text 2>&1) || fail "could not read the G and VT Spot quota: $quota"
python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) >= 8 else 1)' "$quota" ||
  fail "the G and VT Spot quota is $quota vCPU and two $GPU_TYPE need 8"

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
  slurmec2_render_userdata "$role" "$OUT/user-data-$role.sh" "$BUCKET" "$RUN_ID" "$SOURCE_SHA" "$STOP_S" || fail "render $role"
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
  for iid in ${IIDS[@]+"${IIDS[@]}"}; do
    [ -z "${GONE[$iid]:-}" ] || continue
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
spot_ensure_profile "$STACK" \
  "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"s3:PutObject\",\"s3:GetObject\"],\"Resource\":\"arn:aws:s3:::$BUCKET/*\"},{\"Effect\":\"Allow\",\"Action\":\"s3:ListBucket\",\"Resource\":\"arn:aws:s3:::$BUCKET\"}]}" \
  20 || fail "could not prepare the instance profile $STACK"
# An existing profile is not trusted: its role must be this one, trust EC2, and carry this run's policy, written again.
prof_role=$(aws iam get-instance-profile --instance-profile-name "$STACK" --query 'InstanceProfile.Roles[].RoleName' --output text 2>&1) ||
  fail "the instance profile $STACK could not be read: $prof_role"
[ "$prof_role" = "$STACK" ] || fail "the instance profile $STACK carries role(s) '$prof_role', not $STACK"
trust=$(aws iam get-role --role-name "$STACK" --query 'Role.AssumeRolePolicyDocument.Statement[].Principal.Service' --output text 2>&1) ||
  fail "the role $STACK could not be read: $trust"
[ "$trust" = ec2.amazonaws.com ] || fail "the role $STACK trusts '$trust', not ec2.amazonaws.com alone"
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
TAG_DEADLINE=$(date -u -d "@$(( request_epoch + TAG_AT_REQUEST_S ))" +%Y-%m-%dT%H:%M:%SZ)
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
      --query 'Reservations[0].Instances[0].[LaunchTime,ImageId,PrivateIpAddress]' --output text 2>&1) &&
      [ "$(wc -w <<<"$desc")" = 3 ] && [ "$(awk '{print $3}' <<<"$desc")" != None ] && break
    desc=""
    sleep 5
  done
  [ -n "$desc" ] || fail "could not read $role's LaunchTime, image and address"
  read -r lt img ip <<<"$desc"
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
SPOT_TERMINATE_WAIT=$(( T0 + TERMINATION_S - $(date +%s) ))
[ "$SPOT_TERMINATE_WAIT" -ge 60 ] || SPOT_TERMINATE_WAIT=60
SPOT_TERMINATE_TRIES=$(( SPOT_TERMINATE_WAIT / 5 + 1 ))
TERMINATION=confirmed
for role in head gpu1 gpu2; do
  if spot_terminate "$REGION" "${IID_OF[$role]}"; then
    GONE[${IID_OF[$role]}]=1
    echo "terminated ${IID_OF[$role]} ($role)" >>"$OUT/termination.txt"
  else
    TERMINATION=unconfirmed
    echo "TERMINATION UNCONFIRMED for ${IID_OF[$role]} ($role) -- terminate it by hand now" | tee -a "$OUT/termination.txt" >&2
  fi
done
for k in evidence.tgz DONE log-head.txt log-gpu1.txt log-gpu2.txt stopped-gpu1 stopped-gpu2; do
  aws s3 cp --only-show-errors "s3://$BUCKET/$RUN_ID/$k" "$OUT/$k" 2>>"$OUT/download-errors.txt" || echo "not downloaded: $k" >>"$OUT/download-errors.txt"
done
[ ! -s "$OUT/evidence.tgz" ] || tar -xzf "$OUT/evidence.tgz" -C "$OUT" || echo "the evidence archive did not unpack" >>"$OUT/download-errors.txt"
# The measurement's status apart from the teardown's: 0 every check observed (rules may still not have held),
# 4 scored but some check INVALID or NOTRUN, or an archive that is not the last one head verified, 3 VOID, no evidence
# or a failed scorer.
MEASURED=3
if [ -d "$OUT/evidence" ]; then
  python3 hack/slurm-ec2/score.py "$OUT/evidence" "$OUT/verdict.json" | tee "$OUT/verdict.txt"
  score_rc=${PIPESTATUS[0]}
  if [ "$score_rc" != 0 ]; then echo "SCORER FAILED with status $score_rc" | tee -a "$OUT/verdict.txt"
  elif grep -q '^SLURM ON EC2: VOID' "$OUT/verdict.txt"; then MEASURED=3
  elif python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))["complete"] else 1)' "$OUT/verdict.json"; then MEASURED=0
  else MEASURED=4; fi
  # DONE names the digest of the archive head last verified in S3; anything else is an earlier or a broken one.
  want=$(sed -n 's/^evidence_sha256=//p' "$OUT/DONE" 2>>"$OUT/download-errors.txt")
  if [ -z "$want" ] || [ "$want" != "$(sha256sum "$OUT/evidence.tgz" | cut -d' ' -f1)" ]; then
    echo "the downloaded archive is not the one head last verified (DONE names '${want:-none}'); it may be an earlier one" | tee -a "$OUT/verdict.txt"
    [ "$MEASURED" = 0 ] && MEASURED=4
  fi
  # Downloaded and unpacked, so the run's prefix is no longer the only copy; it would otherwise wait 30 days to expire.
  aws s3 rm --only-show-errors --recursive "s3://$BUCKET/$RUN_ID/" >>"$OUT/cleanup.txt" 2>&1 || echo "the run's S3 prefix could not be removed; it expires in 30 days" >>"$OUT/cleanup.txt"
else
  echo "SLURM ON EC2: NO-EVIDENCE (the evidence archive did not come back)" | tee "$OUT/verdict.txt"
fi
echo "termination=$TERMINATION" >>"$OUT/verdict.txt"
echo "measured=$(case "$MEASURED" in 0) echo complete ;; 4) echo incomplete ;; *) echo no ;; esac)" >>"$OUT/verdict.txt"
say "the verdict is in $OUT/verdict.txt"
[ "$TERMINATION" = confirmed ] || exit 1
exit "$MEASURED"
