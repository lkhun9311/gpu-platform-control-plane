#!/usr/bin/env bash
#
# One on-demand t3.large for the kubernetes/kubernetes#142885 swap-drain repro, reachable over SSH from this machine only.
# The local machine runs with swap off and no root, so a swap-enabled kind cluster is not possible there.
#
#   SESSION_CONFIRM=yes AWS_PROFILE=gpu-lab bash hack/k8s-142885/ec2-up.sh <outdir>
#
# THE STOP.
# The user-data's first command shuts the instance down 7,200 s after boot, and shutdown terminates it.
# The launch carries the termination sweeper's study-deadline tag at the request plus 7,800 s.
# hack/k8s-142885/ec2-down.sh terminates it, waits for "terminated", and deletes the key pair and the security group.
#
# THE COST.
# t3.large in Seoul is $0.104/h on demand (AWS Price List, 2026-11-19).
# CPU credits are "standard", so no surplus-credit charge is possible.
# A 30 GB gp3 volume is $0.0037/h and a public IPv4 is $0.005/h.
# The worst case bills to the sweeper's deadline plus its five-minute period: 8,100 s x $0.1127/h = $0.26.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

REGION=ap-northeast-2
ACCOUNT_WANT=007635145730
TYPE=t3.large
VOLUME_GB=30
STOP_S=7200
TAG_S=7800
PURPOSE=k8s-142885-swap-drain
AMI_PARAM=/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id

OUT="${1:?usage: ec2-up.sh <outdir>}"
fail() { echo "SESSION REFUSED: $*" >&2; exit 1; }
[ "${SESSION_CONFIRM:-}" = yes ] || fail "SESSION_CONFIRM=yes is required"
for tool in aws ssh-keygen curl python3; do command -v "$tool" >/dev/null || fail "$tool is not installed"; done
ACCOUNT=$(aws sts get-caller-identity --query Account --output text 2>&1) || fail "no caller identity: $ACCOUNT"
[ "$ACCOUNT" = "$ACCOUNT_WANT" ] || fail "account $ACCOUNT is not gpu-lab"
[ ! -e "$OUT/instance-id" ] || fail "$OUT already holds an instance"
mkdir -p "$OUT" || fail "cannot create $OUT"

# The sweeper is the second line behind the in-instance shutdown, so it must be alive.
sw=$(aws lambda get-function --region "$REGION" --function-name gpu-platform-study-sweeper --query Configuration.State --output text 2>&1)
[ "$sw" = Active ] || fail "the termination sweeper is '$sw', not Active"
live=$(aws ec2 describe-instances --region "$REGION" --filters "Name=tag:purpose,Values=$PURPOSE" \
  "Name=instance-state-name,Values=pending,running,shutting-down,stopping,stopped" \
  --query 'Reservations[].Instances[].InstanceId' --output text 2>&1) || fail "cannot list instances: $live"
[ -z "$live" ] || fail "an instance of this session is still live: $live"

AMI=$(aws ssm get-parameter --region "$REGION" --name "$AMI_PARAM" --query Parameter.Value --output text 2>&1) || fail "AMI: $AMI"
MYIP=$(curl -sf https://checkip.amazonaws.com) || fail "cannot read this machine's public IP"
NONCE=$(python3 -c 'import secrets; print(secrets.token_hex(4))')
NAME="$PURPOSE-$NONCE"
VPC=$(aws ec2 describe-vpcs --region "$REGION" --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text) || fail "no default VPC"

# A key pair and a security group of this session alone, deleted by ec2-down.sh.
ssh-keygen -q -t ed25519 -N '' -f "$OUT/id_ed25519" -C "$NAME" || fail "ssh-keygen"
aws ec2 import-key-pair --region "$REGION" --key-name "$NAME" --public-key-material "fileb://$OUT/id_ed25519.pub" >/dev/null || fail "import-key-pair"
echo "$NAME" >"$OUT/key-name"
SG=$(aws ec2 create-security-group --region "$REGION" --group-name "$NAME" --description "$PURPOSE ssh" --vpc-id "$VPC" --query GroupId --output text) || fail "create-security-group"
echo "$SG" >"$OUT/sg-id"
aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$SG" --protocol tcp --port 22 --cidr "$MYIP/32" >/dev/null || fail "authorize ssh"

UD="$OUT/user-data.sh"
cat >"$UD" <<EOF
#!/bin/bash
( sleep $STOP_S; shutdown -h now ) >/dev/null 2>&1 &
# The line above runs first, so no failure below can keep the instance past the stop.
exec > /var/log/k8s-142885-boot.log 2>&1
set -x
fallocate -l 4G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
export DEBIAN_FRONTEND=noninteractive
apt-get update -q && apt-get install -yq containerd git make jq gcc
mkdir -p /etc/containerd && containerd config default > /etc/containerd/config.toml && systemctl restart containerd
touch /var/run/k8s-142885-boot-done
EOF
DEADLINE=$(date -u -d "@$(( $(date +%s) + TAG_S ))" +%Y-%m-%dT%H:%M:%SZ)
TAGS="ResourceType=instance,Tags=[{Key=Name,Value=$NAME},{Key=purpose,Value=$PURPOSE},{Key=study-deadline,Value=$DEADLINE}]"
IID=$(aws ec2 run-instances --region "$REGION" --image-id "$AMI" --instance-type "$TYPE" \
  --key-name "$NAME" --security-group-ids "$SG" \
  --instance-initiated-shutdown-behavior terminate \
  --credit-specification CpuCredits=standard \
  --block-device-mappings "[{\"DeviceName\":\"/dev/sda1\",\"Ebs\":{\"VolumeSize\":$VOLUME_GB,\"VolumeType\":\"gp3\",\"DeleteOnTermination\":true}}]" \
  --user-data "file://$UD" --tag-specifications "$TAGS" \
  --query 'Instances[0].InstanceId' --output text 2>"$OUT/launch-error.txt") || fail "run-instances: $(cat "$OUT/launch-error.txt")"
echo "$IID" >"$OUT/instance-id"
echo "launched $IID ($TYPE, $AMI) study-deadline $DEADLINE"
aws ec2 wait instance-running --region "$REGION" --instance-ids "$IID" || fail "$IID did not reach running; run ec2-down.sh"
IP=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$IID" --query 'Reservations[0].Instances[0].[PublicIpAddress,LaunchTime]' --output text)
echo "$IP" | awk '{print $1}' >"$OUT/ip"
echo "$IP" | awk '{print $2}' >"$OUT/launch-time"
echo "running at $(cat "$OUT/ip"), LaunchTime $(cat "$OUT/launch-time")"
