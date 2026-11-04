#!/usr/bin/env bash
# The paid session's teardown checks, kept apart from hack/eks-gitops-session.sh so they can be run against stubs:
# the session itself only ever runs against AWS, where a check that cannot fire is found out by a bill.
#
#   teardown_residue REGION CLUSTER EXDIR   asks each service that charges what is left, into billing_left and unasked
#   killswitch_program ...                  prints the detached watchdog's program, with every value quoted

# The watchdog's destroy is given this long once the TTL fires; the session refuses a credential that cannot outlive it.
KILL_DESTROY_MINUTES=40

# teardown_residue REGION CLUSTER EXDIR: billing_left names what still charges and unasked what could not be asked.
#
# Three answers, not two: none, some, and COULD NOT ASK.
# This discarded stderr and forced rc=0 once, so a query refused on expired credentials or a denied policy came back
# empty and read as "nothing left" -- and the kill switch was disarmed on the strength of it.
# EFS is asked for by its creation token: it was missing from this census, so a file system the destroy left behind
# would have read as nothing left (codex census before the full stage).
teardown_residue() {
  local region="$1" cluster="$2" exdir="$3"
  billing_left=""
  unasked=""
  _residue_still() {
    local label="$1"
    shift
    # The status has to be collected in the same list as the command that produced it.
    #
    # `rc=$?` on its own line never ran: under `set -e` a plain assignment whose command substitution fails takes that
    # status and ends the shell right there, so an expired token was never once classified.
    local out rc=0
    out="$("$@" 2>"$exdir/aws-$label.err")" || rc=$?
    out="$(printf '%s' "$out" | tr '\t' ' ')"
    if ((rc != 0)); then
      unasked="$unasked$label(rc=$rc: $(tr '\n' ' ' <"$exdir/aws-$label.err" | cut -c1-110)); "
    elif [[ -n "${out// /}" ]]; then
      billing_left="$billing_left$label=$out; "
    fi
    return 0
  }
  _residue_still eks aws eks list-clusters --region "$region" --query 'clusters' --output text
  _residue_still ec2 aws ec2 describe-instances --region "$region" \
    --filters "Name=instance-state-name,Values=running,pending,stopping,shutting-down" \
    --query 'Reservations[].Instances[].InstanceId' --output text
  _residue_still nat aws ec2 describe-nat-gateways --region "$region" \
    --filter "Name=state,Values=available,pending" --query 'NatGateways[].NatGatewayId' --output text
  _residue_still eip aws ec2 describe-addresses --region "$region" --query 'Addresses[].PublicIp' --output text
  _residue_still ebs aws ec2 describe-volumes --region "$region" --query 'Volumes[].VolumeId' --output text
  _residue_still asg aws autoscaling describe-auto-scaling-groups --region "$region" \
    --query 'AutoScalingGroups[].AutoScalingGroupName' --output text
  _residue_still elb aws elbv2 describe-load-balancers --region "$region" \
    --query 'LoadBalancers[].LoadBalancerName' --output text
  _residue_still schedule aws scheduler list-schedules --region "$region" --name-prefix "gpu-ttl-$cluster-" \
    --query 'Schedules[].Name' --output text
  _residue_still logs aws logs describe-log-groups --region "$region" --log-group-name-prefix "/aws/eks/$cluster/" \
    --query 'logGroups[].logGroupName' --output text
  _residue_still efs aws efs describe-file-systems --region "$region" --creation-token "$cluster-restart" \
    --query 'FileSystems[].FileSystemId' --output text
  unset -f _residue_still
}

# killswitch_program PIDFILE LOG WORKDIR TTL_SECONDS DESTROY_SECONDS PROFILE REGION CLUSTER_DIR CLUSTER TF_VARS EXDIR
# [GRACE_SECONDS]: the detached watchdog's program.
#
# Every value is assigned with printf %q and the body is a quoted heredoc, so a path holding an apostrophe no longer
# ends a single-quoted string inside the generated code and breaks the watchdog (codex census before the full stage).
# Each destroy attempt is cut at what is left of DESTROY_SECONDS from when the TTL fired: three lock waits of ten
# minutes and the retries' sleeps once made the 40 minutes the credential check allows for it a hope, not a bound.
# The cut is TERM and then, GRACE_SECONDS later, KILL, both inside the allowance: terraform shuts down gracefully on
# TERM and can take as long as it likes doing it (codex review of 73c3e3e1).
# timeout leads a process group of its own, so the watchdog writes that group's id beside its own pid, and
# killswitch_disarm stops it too: stopping the watchdog's group alone once left a running destroy behind
# (codex review of 73c3e3e1).
killswitch_program() {
  printf 'KILL_PIDFILE=%q\nKILL_LOG=%q\nWORKDIR=%q\nTTL_SECONDS=%q\nDESTROY_SECONDS=%q\nPROFILE=%q\nREGION=%q\n' \
    "$1" "$2" "$3" "$4" "$5" "$6" "$7"
  printf 'CLUSTER_DIR=%q\nCLUSTER=%q\nTF_VARS=%q\nEXDIR=%q\nGRACE_SECONDS=%q\n' "$8" "$9" "${10}" "${11}" "${12:-30}"
  cat <<'PROGRAM'
echo $$ >"$KILL_PIDFILE"
sleep "$TTL_SECONDS"
echo "[ttl] $(date -u +%H:%M:%SZ) TTL reached; force-destroying" >>"$KILL_LOG" 2>&1
cd "$WORKDIR" || { echo "[ttl] could not enter $WORKDIR" >>"$KILL_LOG"; exit 1; }
until=$((SECONDS + DESTROY_SECONDS))
read -ra tfvars <<<"$TF_VARS"
ttl_rc=1
# The cluster first, and only the cluster. It is what bills; the Helm release bills nothing and its destroy needs a
# reachable API endpoint that, by the time this fires, may well be gone.
# Waits on the state lock and tries three times: its one attempt used to be spent on a lock the foreground destroy, or
# the nightly one, still held.
for attempt in 1 2 3; do
  left=$((until - SECONDS - GRACE_SECONDS))
  if ((left < 1)); then
    echo "[ttl] the ${DESTROY_SECONDS}s destroy allowance ran out before attempt $attempt" >>"$KILL_LOG"
    break
  fi
  AWS_PROFILE="$PROFILE" AWS_REGION="$REGION" timeout -k "$GRACE_SECONDS" "$left" terraform -chdir="$CLUSTER_DIR" \
    destroy -auto-approve -lock-timeout=10m -var="region=$REGION" -var="cluster_name=$CLUSTER" "${tfvars[@]}" \
    >>"$KILL_LOG" 2>&1 &
  destroy=$!
  echo "$destroy" >"$KILL_PIDFILE.destroy"
  wait "$destroy"
  ttl_rc=$?
  : >"$KILL_PIDFILE.destroy"
  [ "$ttl_rc" = 0 ] && break
  echo "[ttl] attempt $attempt failed rc=$ttl_rc" >>"$KILL_LOG" 2>&1
  if ((until - SECONDS > 60)); then sleep 60; fi
done
if [ "$ttl_rc" = 0 ]; then
  echo "[ttl] $(date -u +%H:%M:%SZ) force-destroy SUCCEEDED" >>"$KILL_LOG" 2>&1
  # The GPU deadline is removed only after a destroy that succeeded: with the cluster gone it can only fire against
  # nothing, and left in place it makes the next session refuse to arm its own.
  gpu_ttl=""
  [ -f "$EXDIR/gpu-ttl-schedule.txt" ] && gpu_ttl=$(cat "$EXDIR/gpu-ttl-schedule.txt")
  [ -n "$gpu_ttl" ] && AWS_PROFILE="$PROFILE" AWS_REGION="$REGION" aws scheduler delete-schedule --name "$gpu_ttl" >>"$KILL_LOG" 2>&1
else
  echo "[ttl] $(date -u +%H:%M:%SZ) force-destroy FAILED rc=$ttl_rc -- the cluster may still be billing" >>"$KILL_LOG" 2>&1
fi
PROGRAM
}

# killswitch_alive PID: the process runs; a zombie does not, though kill -0 succeeds on one that has exited and not been
# reaped, and asking that right after the kill reported a gone watchdog as one that survived (2026-10-12).
killswitch_alive() {
  local stat
  stat="$(ps -o stat= -p "$1")" && [[ -n "$stat" && "$stat" != Z* ]]
}

# killswitch_gone PID: waits up to five seconds for PID to leave.
killswitch_gone() {
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    killswitch_alive "$1" || return 0
    sleep 0.5
  done
  return 1
}

# killswitch_disarm PID PIDFILE: the watchdog and any destroy it has started stopped; fails if either survived.
#
# The watchdog leads its own session, so its group holds its sleep; a destroy it started leads another group, timeout's,
# whose id it wrote to PIDFILE.destroy.
killswitch_disarm() {
  local pid="$1" pidfile="$2" destroy="" survived=""
  [[ -s "$pidfile.destroy" ]] && destroy="$(cat "$pidfile.destroy")"
  [[ "$destroy" =~ ^[0-9]+$ ]] || destroy=""
  for group in "$pid" $destroy; do
    kill -- "-$group" 2>&1 | grep -v 'No such process'
    if ! killswitch_gone "$group"; then
      kill -9 -- "-$group" 2>&1 | grep -v 'No such process'
      killswitch_gone "$group" || survived="$survived $group"
    fi
  done
  [[ -z "$survived" ]] || { echo "survived disarming:$survived"; return 1; }
}
