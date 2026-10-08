#!/usr/bin/env bash
#
# Exercises the study sweeper (infra/aws/bootstrap/sweeper.tf) before any paid session relies on it.
#
#   AWS_PROFILE=gpu-lab SWEEPER_ACCOUNT=<the lab account id> bash hack/sweeper-exercise.sh
#
# The design (docs/superpowers/specs/2026-10-08-measuring-prospective-admission-design.md, "The termination
# sweeper, which exists before launch") requires: a t3.nano launched with a study-deadline two minutes ahead, and
# its terminated state within 12 minutes of that deadline, the measured lag recorded.
#
# It passes only when the sweeper's own log names the instance, so a termination by anything else -- this script's
# safety trap, the console, a person -- cannot read as the sweeper working.
# It costs a few cents: one on-demand t3.nano for at most about 25 minutes.
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1

REGION="${REGION:-ap-northeast-2}"
FUNCTION=gpu-platform-study-sweeper
LEAD_S=120
PASS_LAG_S=720
GIVE_UP_S=1200
OUT="hack/sweeper-exercise-$(date -u +%Y%m%dT%H%M%SZ)"

say() { printf '== %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

[ -n "${AWS_PROFILE:-}" ] || fail "set AWS_PROFILE to the account the paid sessions launch in"
[ -n "${SWEEPER_ACCOUNT:-}" ] || fail "set SWEEPER_ACCOUNT to the account id you expect, so the exercise cannot run in another"
account=$(aws sts get-caller-identity --query Account --output text) || fail "not authenticated; aws sso login --profile $AWS_PROFILE"
[ "$account" = "$SWEEPER_ACCOUNT" ] || fail "AWS_PROFILE=$AWS_PROFILE is account $account, not $SWEEPER_ACCOUNT"
aws lambda get-function --region "$REGION" --function-name "$FUNCTION" >/dev/null 2>&1 \
  || fail "no $FUNCTION in $account/$REGION; apply infra/aws/bootstrap first"
mkdir -p "$OUT"

ami=$(aws ssm get-parameter --region "$REGION" --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --query Parameter.Value --output text) || fail "could not resolve the Amazon Linux AMI"
subnet=$(aws ec2 describe-subnets --region "$REGION" --filters Name=default-for-az,Values=true \
  --query 'Subnets[0].SubnetId' --output text) || fail "no default subnet"
[ -n "$subnet" ] && [ "$subnet" != None ] || fail "no default subnet in $REGION"

deadline_epoch=$(( $(date +%s) + LEAD_S ))
deadline=$(date -u -d "@$deadline_epoch" +%Y-%m-%dT%H:%M:%SZ)
token="sweeper-exercise-$(date +%s)"
IID=""
# Terminated here only if the sweeper has not, so a failed exercise does not leave the instance billing.
# A launch whose answer was lost has no id here, so the client token is asked for one first (review of 3fb6af5).
cleanup() {
  if [ -z "$IID" ]; then
    IID=$(aws ec2 describe-instances --region "$REGION" --filters "Name=client-token,Values=$token" \
      "Name=instance-state-name,Values=pending,running,stopping,stopped" \
      --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null || echo UNKNOWN)
    [ "$IID" = UNKNOWN ] && { printf 'COULD NOT ASK whether the launch under token %s exists; check the console\n' "$token" >&2; return 0; }
    [ -n "$IID" ] && [ "$IID" != None ] || return 0
    say "the launch under token $token did exist: $IID"
  fi
  state=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$IID" --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null || echo unknown)
  case "$state" in
    terminated|shutting-down) ;;
    *) say "terminating $IID ($state) because the sweeper did not"
       aws ec2 terminate-instances --region "$REGION" --instance-ids "$IID" >/dev/null || printf 'TERMINATE FAILED for %s\n' "$IID" >&2 ;;
  esac
}
trap cleanup EXIT
trap 'exit 130' INT TERM

IID=$(aws ec2 run-instances --region "$REGION" --image-id "$ami" --instance-type t3.nano --subnet-id "$subnet" \
  --instance-initiated-shutdown-behavior terminate --client-token "$token" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=sweeper-exercise},{Key=study-deadline,Value=$deadline}]" \
  --query 'Instances[0].InstanceId' --output text) || fail "the launch was refused"
say "launched $IID with study-deadline $deadline"
printf 'instance\t%s\ndeadline\t%s\n' "$IID" "$deadline" > "$OUT/result.tsv"

ended=""
while [ "$(date +%s)" -lt $(( deadline_epoch + GIVE_UP_S )) ]; do
  state=$(timeout 30 aws ec2 describe-instances --region "$REGION" --instance-ids "$IID" \
    --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null || echo unknown)
  # terminated, not shutting-down: the design asks for the terminated state, and an instance shutting down is
  # still on the bill (review of 3fb6af5).
  [ "$state" = terminated ] && { ended=$(date +%s); break; }
  sleep 15
done
[ -n "$ended" ] || fail "$IID was not terminated within $(( GIVE_UP_S / 60 )) minutes of its deadline; the trap terminates it now"
lag=$(( ended - deadline_epoch ))
printf 'ended_seen\t%s\nlag_s\t%s\n' "$(date -u -d "@$ended" +%Y-%m-%dT%H:%M:%SZ)" "$lag" >> "$OUT/result.tsv"

# The sweeper's own record of it, which is what distinguishes its termination from any other. CloudWatch ingests
# asynchronously, so it is asked for up to 5 minutes; that wait is not part of the measured lag.
for _ in $(seq 1 20); do
  aws logs filter-log-events --region "$REGION" --log-group-name "/aws/lambda/$FUNCTION" \
    --start-time $(( (deadline_epoch - LEAD_S) * 1000 )) --filter-pattern "\"$IID\"" \
    --query 'events[].message' --output text > "$OUT/sweeper-log.txt" 2>&1 || true
  grep -q "\"terminated\": \"$IID\"" "$OUT/sweeper-log.txt" && break
  sleep 15
done
grep -q "\"terminated\": \"$IID\"" "$OUT/sweeper-log.txt" \
  || fail "$IID ended $lag s after its deadline, but the sweeper's log does not name it; see $OUT/sweeper-log.txt"
[ "$lag" -le "$PASS_LAG_S" ] || fail "the sweeper terminated $IID $lag s after its deadline, past the $PASS_LAG_S s the design allows"
say "PASS: the sweeper terminated $IID $lag s after its deadline. Recorded in $OUT"
