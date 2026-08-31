#!/usr/bin/env bash
# A deadline that does not run on this laptop.
#
# Every other teardown in this repository is a trap in the operator's shell, and a trap does not run after
# the machine sleeps, loses power, or has its shell SIGKILLed. It also does not run usefully once the SSO
# session expires, because the scale-down is itself an AWS call: the credential that stops the billing dies
# at the same moment the session does.
#
# So the deadline is registered with AWS before the GPU starts, and AWS enforces it whatever happens here.
# EventBridge Scheduler calls eks:UpdateNodegroupConfig through a universal target -- no Lambda, nothing to
# package, and no second copy of the teardown logic to drift from the first.
#
# The order is the point: arm, verify, THEN scale up. A session that cannot register its deadline does not
# get a GPU, because the alternative is a GPU with no deadline.

TTL_SCHEDULE_NAME=""

# ttl_arm CLUSTER NODEGROUP MINUTES
#
# Registers a one-shot schedule that forces the node group to desiredSize=0 after MINUTES.
# Returns non-zero if the schedule could not be created, and the caller must treat that as fatal.
ttl_arm() {
  local cluster="$1" nodegroup="$2" minutes="$3"
  local role name at

  # Two ways to learn the role, because the first one has a failure mode that stops a paid session for a
  # reason that has nothing to do with the session.
  #
  # The callers read TTL_ROLE_ARN from `terraform output`, which needs a working backend and live
  # credentials for the state bucket's KMS key. It fails with InvalidGrantException on an expired SSO token
  # -- observed on 2026-08-31 while the role itself was perfectly readable through the IAM API a second
  # later. Refusing to start was the safe direction, but refusing because a state file could not be opened,
  # when the thing being looked up is a role name that has not changed, is a bad trade.
  #
  # IAM is the fallback and the name is a constant here for the same reason the node group names are: it is
  # set in infra/aws/bootstrap/ttl.tf and does not vary per session.
  role="${TTL_ROLE_ARN:-}"
  if [ -z "$role" ]; then
    role=$(aws iam get-role --role-name "${TTL_ROLE_NAME:-gpu-platform-ttl-scaledown}" \
             --query 'Role.Arn' --output text 2>/dev/null)
  fi
  if [ -z "$role" ] || [ "$role" = "None" ]; then
    echo "could not determine the TTL scale-down role. Apply infra/aws/bootstrap, or pass TTL_ROLE_ARN." >&2
    return 1
  fi

  # UTC, because Scheduler's at() expressions are not timezone-aware unless one is passed, and a session that
  # armed its deadline nine hours late would be worse than one that never armed it at all.
  at=$(date -u -d "+${minutes} minutes" '+%Y-%m-%dT%H:%M:%S')
  name="gpu-ttl-${cluster}-${nodegroup}-$(date -u '+%Y%m%d%H%M%S')"

  # ActionAfterCompletion=DELETE so a finished deadline does not accumulate. A session that ends cleanly
  # deletes its own schedule; this covers the one that does not.
  if ! aws scheduler create-schedule \
        --name "$name" \
        --schedule-expression "at($at)" \
        --schedule-expression-timezone UTC \
        --flexible-time-window '{"Mode":"OFF"}' \
        --action-after-completion DELETE \
        --description "Force $cluster/$nodegroup to desiredSize=0 if the session that armed this never finished." \
        --target "{
            \"Arn\": \"arn:aws:scheduler:::aws-sdk:eks:updateNodegroupConfig\",
            \"RoleArn\": \"$role\",
            \"Input\": \"{\\\"ClusterName\\\":\\\"$cluster\\\",\\\"NodegroupName\\\":\\\"$nodegroup\\\",\\\"ScalingConfig\\\":{\\\"MinSize\\\":0,\\\"DesiredSize\\\":0}}\"
          }" >/dev/null; then
    echo "could not register the TTL scale-down for $cluster/$nodegroup" >&2
    return 1
  fi

  # Read it back. An accepted create that produced no schedule is the failure this whole file exists to make
  # impossible, and it is silent unless something looks.
  if ! aws scheduler get-schedule --name "$name" >/dev/null 2>&1; then
    echo "the TTL schedule $name was accepted but cannot be read back" >&2
    return 1
  fi

  TTL_SCHEDULE_NAME="$name"
  echo "TTL armed: $cluster/$nodegroup goes to desiredSize=0 at ${at}Z (in ${minutes}m), schedule $name" >&2
  return 0
}

# ttl_disarm
#
# Deletes the schedule this session armed. Safe to call when nothing was armed.
#
# Failure here is reported and not fatal: the schedule firing later is harmless -- it sets a node group that
# is already at zero to zero -- whereas failing the session over a leftover deadline would be the tail
# wagging the dog.
ttl_disarm() {
  [ -n "$TTL_SCHEDULE_NAME" ] || return 0
  if aws scheduler delete-schedule --name "$TTL_SCHEDULE_NAME" >/dev/null 2>&1; then
    echo "TTL disarmed: $TTL_SCHEDULE_NAME" >&2
  else
    echo "WARNING: could not delete the TTL schedule $TTL_SCHEDULE_NAME. It will fire and set an already-zero node group to zero, which is harmless." >&2
  fi
  TTL_SCHEDULE_NAME=""
}
