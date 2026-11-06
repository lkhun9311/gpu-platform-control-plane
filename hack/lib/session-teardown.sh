#!/usr/bin/env bash
# The paid session's teardown checks, kept apart from hack/eks-gitops-session.sh so they can be run against stubs:
# the session itself only ever runs against AWS, where a check that cannot fire is found out by a bill.
#
#   teardown_residue REGION CLUSTER EXDIR   asks each service that charges what is left, into billing_left and unasked
#   killswitch_program ...                  prints the detached watchdog's program, with every value quoted
#   killswitch_others                       lists the watchdogs of this user still armed on this host

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
# The allowance is counted on /proc/uptime, CLOCK_BOOTTIME, as the phase supervisor counts its deadlines: bash's SECONDS
# follows the wall clock, so a step forward ended the destroys early and a step back let one run past the 40 minutes
# (gpt-6-astra's third attack before the corelimit run).
# SESSION_PID, the session that armed it, is overdue once the TTL fires, so it is stopped first with everything it runs:
# a foreground terraform hung on the state lock defeated every destroy attempt, whose lock waits cannot evict a holder
# (gpt-6-astra's second attack before the corelimit run, accepted for that run and fixed after it).
# A destroy refused by a lock whose holder is this host's user, with that session stopped, releases the lock once with
# force-unlock; a lock held by anyone else, the nightly destroy's runner included, is left to its holder.
# The holder is read from terraform's own error, which carries ANSI colour codes even into a file and a box-drawing
# border before each line, never inside the ID or Who value, so each is read from where its label ends (captured from
# terraform 1.16.0, hack/test/session-teardown/terraform-lock-error.txt).
#
# A destroy that returned zero is checked with teardown_residue, as the foreground teardown is, before it is called
# SUCCEEDED and the GPU deadline removed: a resource a killed apply had created but not yet written to the state is
# one a destroy that succeeds never sees (gpt-6-astra's review of 116092ef, r5 finding 6).
killswitch_program() {
  printf 'KILL_PIDFILE=%q\nKILL_LOG=%q\nWORKDIR=%q\nTTL_SECONDS=%q\nDESTROY_SECONDS=%q\nPROFILE=%q\nREGION=%q\n' \
    "$1" "$2" "$3" "$4" "$5" "$6" "$7"
  printf 'CLUSTER_DIR=%q\nCLUSTER=%q\nTF_VARS=%q\nEXDIR=%q\nGRACE_SECONDS=%q\nSESSION_PID=%q\n' "$8" "$9" "${10}" "${11}" \
    "${12:-30}" "${13:-}"
  declare -f teardown_residue
  cat <<'PROGRAM'
# gpu-platform-killswitch-watchdog: killswitch_others finds an armed watchdog by this line.
echo $$ >"$KILL_PIDFILE"
sleep "$TTL_SECONDS"
echo "[ttl] $(date -u +%H:%M:%SZ) TTL reached; force-destroying" >>"$KILL_LOG" 2>&1
cd "$WORKDIR" || { echo "[ttl] could not enter $WORKDIR" >>"$KILL_LOG"; exit 1; }
mono() { local up rest; read -r up rest </proc/uptime; echo "${up%.*}"; }
until=$(($(mono) + DESTROY_SECONDS))
read -ra tfvars <<<"$TF_VARS"
running() { local s; s="$(ps -o stat= -p "$1")" && [ -n "$s" ] && [ "${s#Z}" = "$s" ]; }
# The session and its descendants, never this watchdog, which the session started and so is one of its children.
tree() { local c; for c in $(ps -o pid= --ppid "$1"); do [ "$c" = "$$" ] || tree "$c"; done; echo "$1"; }
if [ -n "$SESSION_PID" ] && running "$SESSION_PID"; then
  pids=" $(tree "$SESSION_PID" | paste -sd' ') "
  echo "[ttl] stopping the overdue session $SESSION_PID and what it runs:$pids" >>"$KILL_LOG"
  # shellcheck disable=SC2086  # the pid list is split on purpose
  kill -TERM $pids >>"$KILL_LOG" 2>&1
  stop=$(($(mono) + GRACE_SECONDS))
  alive="$pids"
  while (($(mono) < stop)); do
    # What the session's own TERM and EXIT handlers start while it shuts down is gathered too, while it can still be
    # found as the session's descendant, and killed with the rest if it outlives the grace (codex review of 3e3896cb).
    if running "$SESSION_PID"; then
      for p in $(tree "$SESSION_PID"); do case "$pids" in *" $p "*) ;; *) pids="$pids$p " ;; esac; done
    fi
    alive=""
    for p in $pids; do running "$p" && alive="$alive $p"; done
    [ -z "$alive" ] && break
    sleep 1
  done
  if [ -n "$alive" ]; then
    echo "[ttl] killing what outlived the TERM:$alive" >>"$KILL_LOG"
    # shellcheck disable=SC2086
    kill -KILL $alive >>"$KILL_LOG" 2>&1
  fi
fi
me="$(id -un)@$(uname -n)"
unlocked=""
# This user's terraform processes still working on a cluster root: a lock whose Who is this host's user is only shown
# stale when none is left, since another operation by the same user on the same host carries the same Who (codex review
# of 3e3896cb).
# Each process's directory is resolved as terraform resolves it, its -chdir taken against its own working directory, and
# any directory ending in CLUSTER_DIR counts, in whatever checkout: every checkout of this repository has the same
# backend and so the same state. Matching this checkout's path, or a -chdir spelled relative to it, missed a terraform
# started from inside another checkout's cluster root or given an absolute -chdir into one (gpt-6-astra's review of
# 116092ef, r5 finding 2). Leaving a lock to a holder that turns out unrelated costs a manual unlock, where releasing a
# live one could corrupt the state.
# A copy of the root under another name, or one run on another host as the same user@host, is still not seen.
live_holders() {
  local p cwd dir arg
  for p in $(pgrep -u "$(id -u)" -x terraform); do
    # A process that exited since pgrep listed it holds nothing.
    cwd="$(readlink "/proc/$p/cwd")" || continue
    dir="$cwd"
    while IFS= read -r -d '' arg; do
      case "$arg" in
        -chdir=/*) dir="${arg#-chdir=}" ;;
        -chdir=*) dir="$cwd/${arg#-chdir=}" ;;
      esac
    done <"/proc/$p/cmdline"
    case "$(realpath -m "$dir")/" in */"$CLUSTER_DIR"/) echo "$p" ;; esac
  done
}
# A disarm that stops this watchdog stops the destroy it started too: $! is set the moment the destroy is launched, so
# no TERM can fall between the launch and the record of it, and wait returns to run this at once (codex review).
trap 'if [ -n "$!" ]; then kill -TERM -- "-$!"; sleep 1; kill -KILL -- "-$!"; fi; exit 143' TERM
ttl_rc=1
# The cluster first, and only the cluster. It is what bills; the Helm release bills nothing and its destroy needs a
# reachable API endpoint that, by the time this fires, may well be gone.
# Waits on the state lock and tries three times: its one attempt used to be spent on a lock the foreground destroy, or
# the nightly one, still held.
for attempt in 1 2 3; do
  left=$((until - $(mono) - GRACE_SECONDS))
  if ((left < 1)); then
    echo "[ttl] the ${DESTROY_SECONDS}s destroy allowance ran out before attempt $attempt" >>"$KILL_LOG"
    break
  fi
  AWS_PROFILE="$PROFILE" AWS_REGION="$REGION" timeout -k "$GRACE_SECONDS" "$left" terraform -chdir="$CLUSTER_DIR" \
    destroy -auto-approve -lock-timeout=10m -var="region=$REGION" -var="cluster_name=$CLUSTER" "${tfvars[@]}" \
    >"$KILL_LOG.attempt" 2>&1 &
  destroy=$!
  echo "$destroy" >"$KILL_PIDFILE.destroy"
  wait "$destroy"
  ttl_rc=$?
  cat "$KILL_LOG.attempt" >>"$KILL_LOG"
  if [ "$ttl_rc" != 0 ] && [ -z "$unlocked" ] && grep -q 'Error acquiring the state lock' "$KILL_LOG.attempt"; then
    lock_id="$(sed -n 's/.*ID:[[:space:]]*\([0-9a-f-]\{36\}\).*/\1/p' "$KILL_LOG.attempt" | tail -n 1)"
    lock_who="$(sed -n 's/.*Who:[[:space:]]*\([^[:space:]]*\).*/\1/p' "$KILL_LOG.attempt" | tail -n 1)"
    holders="$(live_holders | paste -sd' ')"
    left=$((until - $(mono) - GRACE_SECONDS))
    ((left > 120)) && left=120
    if [ -z "$lock_id" ] || [ "$lock_who" != "$me" ] || { [ -n "$SESSION_PID" ] && running "$SESSION_PID"; }; then
      echo "[ttl] the state lock ${lock_id:-unread} is held by ${lock_who:-unread}, not this host's stopped session; left to its holder" >>"$KILL_LOG"
    elif [ -n "$holders" ]; then
      echo "[ttl] the state lock $lock_id is this host's user's, and terraform $holders of that user still works on $CLUSTER_DIR; left to it" >>"$KILL_LOG"
    elif ((left < 1)); then
      echo "[ttl] the state lock $lock_id is stale, but the ${DESTROY_SECONDS}s allowance has no time left to release it" >>"$KILL_LOG"
    else
      echo "[ttl] the state lock $lock_id is held by $lock_who, this host's user, with the session stopped and no terraform of that user left on $CLUSTER_DIR; releasing it" >>"$KILL_LOG"
      # Inside what is left of the allowance, and recorded as the destroy is, so a disarm stops it too (codex review of
      # 3e3896cb).
      AWS_PROFILE="$PROFILE" AWS_REGION="$REGION" timeout -k "$GRACE_SECONDS" "$left" terraform -chdir="$CLUSTER_DIR" \
        force-unlock -force "$lock_id" >>"$KILL_LOG" 2>&1 &
      unlock=$!
      echo "$unlock" >"$KILL_PIDFILE.destroy"
      wait "$unlock" && unlocked=1
      [ -n "$(pgrep -g "$unlock")" ] && kill -KILL -- "-$unlock"
      : >"$KILL_PIDFILE.destroy"
    fi
  fi
  # timeout exits with its child and sends no KILL to a provider that ignored TERM, which stays in its group, so the
  # group is emptied here and its record cleared only after (codex review before the re-verification).
  if [ -n "$(pgrep -g "$destroy")" ]; then
    kill -KILL -- "-$destroy"
    echo "[ttl] killed what outlived attempt $attempt in its group $destroy" >>"$KILL_LOG"
  fi
  : >"$KILL_PIDFILE.destroy"
  [ "$ttl_rc" = 0 ] && break
  echo "[ttl] attempt $attempt failed rc=$ttl_rc" >>"$KILL_LOG" 2>&1
  if ((until - $(mono) > 60)); then sleep 60; fi
done
if [ "$ttl_rc" = 0 ]; then
  gpu_ttl=""
  [ -f "$EXDIR/gpu-ttl-schedule.txt" ] && gpu_ttl=$(cat "$EXDIR/gpu-ttl-schedule.txt")
  # Asked as the foreground teardown asks, into a directory of its own so the session's census evidence is kept.
  export AWS_PROFILE="$PROFILE" AWS_REGION="$REGION"
  mkdir -p "$EXDIR/ttl-residue"
  teardown_residue "$REGION" "$CLUSTER" "$EXDIR/ttl-residue"
  # The session's own GPU deadline is still registered at this point, and is removed below only once the rest is clean.
  [ -n "$gpu_ttl" ] && billing_left="${billing_left/"schedule=$gpu_ttl; "/}"
  if [ -n "${unasked// /}" ] || [ -n "${billing_left// /}" ]; then
    echo "[ttl] $(date -u +%H:%M:%SZ) force-destroy INCOMPLETE: the destroy returned zero, but left=[${billing_left}] unasked=[${unasked}]; the GPU deadline is kept -- the account may still be billing" >>"$KILL_LOG" 2>&1
  else
    echo "[ttl] $(date -u +%H:%M:%SZ) force-destroy SUCCEEDED: the destroy returned zero and every residue query was answered empty" >>"$KILL_LOG" 2>&1
    # The GPU deadline is removed only after a verified teardown: with the cluster gone it can only fire against
    # nothing, and left in place it makes the next session refuse to arm its own.
    [ -n "$gpu_ttl" ] && aws scheduler delete-schedule --name "$gpu_ttl" >>"$KILL_LOG" 2>&1
  fi
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

# killswitch_others: the pids of every watchdog of this user still armed on this host, one per line.
#
# Every session shares the one state of the cluster root, and a watchdog destroys whatever that state holds when its TTL
# fires, so a watchdog left by a failed session would tear down the next session built into the same state; the
# session refuses to arm while one is alive (gpt-6-astra's review of 116092ef, r5 finding 1).
# Found by the marker line the program carries, which a bash -c watchdog shows in its command line; the bracket keeps
# the pattern from matching a command that merely names it.
killswitch_others() {
  local p
  for p in $(pgrep -u "$(id -u)" -f 'gpu-platform-killswitch-watchdo[g]'); do
    killswitch_alive "$p" && echo "$p"
  done
  return 0
}

# killswitch_group_alive PGID: some member of the process group runs. pgrep -g selects by process group, where ps -g
# selects by session, and a destroy's group lives inside the watchdog's session.
# The whole group, not its leader: a provider that outlived terraform kept a destroy running after timeout exited
# (codex review).
killswitch_group_alive() {
  local p
  for p in $(pgrep -g "$1"); do
    killswitch_alive "$p" && return 0
  done
  return 1
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

# killswitch_group_gone PGID: waits up to five seconds for every member of the process group to leave.
killswitch_group_gone() {
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    killswitch_group_alive "$1" || return 0
    sleep 0.5
  done
  return 1
}

# killswitch_disarm PID PIDFILE: the watchdog and any destroy it has started stopped; fails if either survived.
#
# The watchdog leads its own session, so its group holds its sleep; a destroy it started leads another group, timeout's,
# whose id it wrote to PIDFILE.destroy.
#
# The watchdog goes first, so it can launch no destroy after the record of one is read; its TERM trap stops a destroy it
# started. Then whatever the record names is checked as a whole group, and killed if any member is left.
killswitch_disarm() {
  local pid="$1" pidfile="$2" destroy="" survived="" group
  _killswitch_stop() {
    kill -- "-$1" 2>&1 | grep -v 'No such process'
    if ! killswitch_group_gone "$1"; then
      kill -9 -- "-$1" 2>&1 | grep -v 'No such process'
      killswitch_group_gone "$1" || survived="$survived $1"
    fi
  }
  _killswitch_stop "$pid"
  [[ -s "$pidfile.destroy" ]] && destroy="$(cat "$pidfile.destroy")"
  if [[ "$destroy" =~ ^[0-9]+$ ]]; then
    for group in $destroy; do
      _killswitch_stop "$group"
    done
  fi
  unset -f _killswitch_stop
  [[ -z "$survived" ]] || { echo "survived disarming:$survived"; return 1; }
}
