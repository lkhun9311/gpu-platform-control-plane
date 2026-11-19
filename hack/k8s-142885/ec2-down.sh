#!/usr/bin/env bash
#
# Terminates the ec2-up.sh instance, waits for EC2 to report it terminated, then deletes its key pair and security group.
#
#   AWS_PROFILE=gpu-lab bash hack/k8s-142885/ec2-down.sh <outdir>
set -uo pipefail
REGION=ap-northeast-2
OUT="${1:?usage: ec2-down.sh <outdir>}"
rc=0
if [ -s "$OUT/instance-id" ]; then
  IID=$(cat "$OUT/instance-id")
  aws ec2 terminate-instances --region "$REGION" --instance-ids "$IID" >/dev/null || echo "terminate-instances failed for $IID" >&2
  # The waiter gives up after 40 tries of 15 s.
  if aws ec2 wait instance-terminated --region "$REGION" --instance-ids "$IID"; then
    state=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$IID" --query 'Reservations[0].Instances[0].State.Name' --output text)
    echo "$IID $state" | tee "$OUT/termination.txt"
    [ "$state" = terminated ] || rc=1
  else
    echo "TERMINATION UNCONFIRMED for $IID -- terminate it by hand now" | tee "$OUT/termination.txt" >&2
    rc=1
  fi
fi
if [ -s "$OUT/sg-id" ]; then
  aws ec2 delete-security-group --region "$REGION" --group-id "$(cat "$OUT/sg-id")" && echo "deleted $(cat "$OUT/sg-id")" || { echo "security group not deleted" >&2; rc=1; }
fi
if [ -s "$OUT/key-name" ]; then
  aws ec2 delete-key-pair --region "$REGION" --key-name "$(cat "$OUT/key-name")" && echo "deleted key pair $(cat "$OUT/key-name")" || { echo "key pair not deleted" >&2; rc=1; }
fi
exit $rc
