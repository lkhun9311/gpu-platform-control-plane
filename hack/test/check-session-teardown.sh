#!/usr/bin/env bash
# Checks hack/lib/session-teardown.sh, the paid session's residue census and its kill switch's program, against stubs:
# the session itself only ever runs them against AWS.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

fails=0
ok() { echo "ok: $*"; }
bad() { echo "FAIL: $*"; fails=$((fails + 1)); }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# --- the residue census ---------------------------------------------------------------------------------------------
# A stub aws answers every census query empty, except EFS, which answers $EFS_OUT with status $EFS_RC.
mkdir -p "$work/bin"
cat >"$work/bin/aws" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "efs describe-file-systems") [[ " $* " == *" --creation-token gpu-platform-restart "* ]] || { echo "wrong creation token: $*" >&2; exit 9; }
    printf '%s' "${EFS_OUT:-}"; [[ "${EFS_RC:-0}" == 0 ]] || echo "AccessDeniedException" >&2; exit "${EFS_RC:-0}" ;;
esac
exit 0
EOF
chmod +x "$work/bin/aws"
census() {
  PATH="$work/bin:$PATH" bash -c '. hack/lib/session-teardown.sh; mkdir -p "$1"; teardown_residue ap-northeast-2 gpu-platform "$1"
    echo "left=[$billing_left] unasked=[$unasked]"' _ "$work/census-$1"
}
out="$(EFS_OUT="fs-0534b759b7494261a" census left)"
if [[ "$out" == *"left=[efs=fs-0534b759b7494261a; ]"*"unasked=[]"* ]]; then ok "a file system the destroy left behind is reported as still charging"; else bad "the EFS left behind: $out"; fi
out="$(EFS_RC=254 census refused)"
if [[ "$out" == *"left=[]"*"unasked=[efs(rc=254: AccessDeniedException"* ]]; then ok "an EFS query that was refused is unasked, not nothing left"; else bad "the refused EFS query: $out"; fi
out="$(census clean)"
if [[ "$out" == "left=[] unasked=[]" ]]; then ok "an account with nothing left reads as nothing left"; else bad "the clean account: $out"; fi

# --- the kill switch's program --------------------------------------------------------------------------------------
# A stub terraform that hangs until it is killed, or succeeds; its directory's name holds an apostrophe, as a checkout
# or evidence path may.
dir="$work/owner's evidence"
mkdir -p "$dir/bin"
cat >"$dir/bin/terraform" <<'EOF'
#!/usr/bin/env bash
echo "terraform $*"
[[ "${TF_HANGS:-}" == 1 ]] && exec sleep 300
# Ignores TERM as a terraform busy shutting down gracefully would, so only the KILL after the grace ends it.
[[ "${TF_HANGS:-}" == term ]] && { trap '' TERM; exec sleep 300; }
# Exits on TERM but leaves a provider behind that ignores it, as a plugin can outlive the terraform that started it;
# it records the provider's pid so a check can find exactly that process.
if [[ "${TF_HANGS:-}" == provider ]]; then
  (trap '' TERM; exec sleep 300) &
  [[ -n "${PROVIDER_PID_FILE:-}" ]] && echo $! >"$PROVIDER_PID_FILE"
  exec sleep 300
fi
# A destroy refused by a held state lock, in terraform's own words (captured from 1.16.0 with the holder's Who replaced),
# until a force-unlock is recorded; force-unlock records its arguments.
if [[ "${TF_HANGS:-}" == lock ]]; then
  case "$*" in
    *force-unlock*)
      echo "$*" >>"$TF_LOCK_DIR/unlocks"
      [[ -n "${TF_UNLOCK_HANGS:-}" ]] && exec sleep 300
      exit 0 ;;
    *destroy*)
      [[ -e "$TF_LOCK_DIR/unlocks" ]] && exit 0
      sed "s/lkhun9311@genesis/$TF_LOCK_WHO/" "$TF_LOCK_ERROR" >&2
      [[ -n "${TF_LOCK_SLOW:-}" ]] && sleep "$TF_LOCK_SLOW"
      exit 1 ;;
  esac
fi
exit 0
EOF
chmod +x "$dir/bin/terraform"
# A stub aws for the watchdog's residue census after a destroy that succeeds: without it that census would ask the real
# account. Every service answers empty unless TTL_RESIDUE_* says otherwise; every call is recorded.
cat >"$dir/bin/aws" <<'EOF'
#!/usr/bin/env bash
echo "aws $*" >>"$(dirname "$0")/../aws.calls"
case "$1 $2" in
  "ec2 describe-instances") printf '%s' "${TTL_RESIDUE_EC2:-}" ;;
  "scheduler list-schedules") printf '%s' "${TTL_RESIDUE_SCHEDULE:-}" ;;
  "eks list-clusters") [[ -n "${TTL_RESIDUE_EKS_RC:-}" ]] && { echo "ExpiredTokenException" >&2; exit "$TTL_RESIDUE_EKS_RC"; } ;;
  # The session lease the watchdog reads when its TTL fires: LEASE_STATE is held, gone or unreadable.
  "ssm get-parameter")
    case "${LEASE_STATE:-held}" in
      held) echo "/gpu-platform/session-lease/s-1" ;;
      gone) echo "An error occurred (ParameterNotFound) when calling the GetParameter operation" >&2; exit 254 ;;
      *) echo "An error occurred (ExpiredTokenException)" >&2; exit 254 ;;
    esac ;;
esac
exit 0
EOF
chmod +x "$dir/bin/aws"
program() {
  bash -c '. hack/lib/session-teardown.sh; killswitch_program "$1/ttl.pid" "$1/kill.log" "$1" "${3:-0}" "$2" gpu-lab ap-northeast-2 infra/aws/cluster gpu-platform "-var=gpu_max_nodes=3 -var=efs_enabled=true" "$1" 1' _ "$dir" "$1" "${2:-0}"
}
if program 3 | bash -n; then ok "the program parses with an apostrophe in its paths"; else bad "the program does not parse with an apostrophe in its paths"; fi

# With the session's lease named, a lease gone when the TTL fires stops the watchdog before any terraform: the cloud side
# reaped this session, and the shared state may hold another's cluster (round 4 of the session cloud safety review).
# Mutations that turn it red: destroy whatever the lease reads, or stop on an unreadable lease.
leased() {
  bash -c '. hack/lib/session-teardown.sh; killswitch_program "$1/ttl.pid" "$1/kill.log" "$1" 0 3 gpu-lab ap-northeast-2 infra/aws/cluster gpu-platform "" "$1" 1 "" /gpu-platform/session-lease/s-1' _ "$dir"
}
for state in gone held unreadable; do
  : >"$dir/kill.log"
  LEASE_STATE=$state PATH="$dir/bin:$PATH" bash -c "$(leased)"
  destroyed=no
  grep -q '^terraform .*destroy' "$dir/kill.log" && destroyed=yes
  case "$state:$destroyed" in
    gone:no) ok "a watchdog whose lease is gone destroys nothing" ;;
    held:yes) ok "a watchdog whose lease is held destroys as before" ;;
    unreadable:yes) ok "a watchdog whose lease cannot be read still destroys" ;;
    *) bad "lease $state: destroyed=$destroyed: $(tail -3 "$dir/kill.log" | tr '\n' ' ')" ;;
  esac
done
if grep -q '"$(lease_name "$LEASE_KEY")")" >/dev/null 2>&1 &' hack/eks-gitops-session.sh; then ok "the session gives its watchdog its lease"; else
  bad "the session does not pass its lease to the watchdog"
fi
# The allowance is counted on CLOCK_BOOTTIME, never on bash's SECONDS, which follows the wall clock: a step back once let
# a destroy run 100 minutes against its 40 (gpt-6-astra's third attack before the corelimit run).
wall="$(program 3 | grep -nP '(?<![A-Z_])SECONDS\b')"
if [[ -z "$wall" ]] && program 3 | grep -q '^until=\$((\$(mono) + DESTROY_SECONDS))$' && program 3 | grep -q '</proc/uptime'; then
  ok "the destroy allowance is counted on /proc/uptime, not the wall clock"
else
  bad "the destroy allowance's clock: ${wall:-no mono deadline}"
fi

start=$SECONDS
TF_HANGS=1 PATH="$dir/bin:$PATH" bash -c "$(program 3)"
took=$((SECONDS - start))
if ((took < 10)) && grep -q 'force-destroy FAILED' "$dir/kill.log" && grep -q 'allowance ran out' "$dir/kill.log"; then
  ok "a destroy that hangs is cut at its allowance and reported FAILED, in $took s"
else
  bad "the hanging destroy took $took s: $(tail -3 "$dir/kill.log" | tr '\n' ' ')"
fi
if grep -q -- '-var=cluster_name=gpu-platform -var=gpu_max_nodes=3 -var=efs_enabled=true' "$dir/kill.log"; then
  ok "the destroy is given the session's terraform variables one by one"
else
  bad "the destroy's arguments: $(grep '^terraform' "$dir/kill.log" | head -1)"
fi

# A destroy that ignores TERM is still ended inside the allowance, by the KILL after the one-second grace.
: >"$dir/kill.log"
start=$SECONDS
TF_HANGS=term PATH="$dir/bin:$PATH" bash -c "$(program 4)"
took=$((SECONDS - start))
if ((took < 10)) && grep -q 'force-destroy FAILED' "$dir/kill.log"; then
  ok "a destroy that ignores TERM is killed inside its allowance, in $took s"
else
  bad "the TERM-proof destroy took $took s: $(tail -2 "$dir/kill.log" | tr '\n' ' ')"
fi

# A destroy cut at its allowance whose terraform exits on TERM leaves no provider behind: timeout exits with its child and
# never sends the KILL, so whatever of the group outlives it must be killed by the watchdog (codex review before the
# re-verification).
: >"$dir/kill.log"
: >"$dir/provider.pid"
TF_HANGS=provider PROVIDER_PID_FILE="$dir/provider.pid" PATH="$dir/bin:$PATH" bash -c "$(program 3)"
sleep 1
provider="$(cat "$dir/provider.pid")"
if [[ "$provider" =~ ^[0-9]+$ ]] && ! ps -o stat= -p "$provider" | grep -qv '^Z'; then
  ok "a provider that outlives terraform at the allowance is killed with its group"
else
  bad "the provider ${provider:-never recorded} outlived its destroy's allowance"
  [[ "$provider" =~ ^[0-9]+$ ]] && kill -9 "$provider"
fi

# Disarming while a destroy runs stops the destroy too, though timeout put it in a process group of its own, and a
# provider in that group that ignores TERM is killed as well. Groups are read with pgrep -g; ps -g reads sessions, and
# the destroy's group is inside the watchdog's session, which once let this check see nothing to find.
for kind in 1 provider; do
  : >"$dir/kill.log"
  : >"$dir/ttl.pid"
  : >"$dir/ttl.pid.destroy"
  TF_HANGS=$kind PATH="$dir/bin:$PATH" setsid bash -c "$(program 600)" &
  for _ in $(seq 50); do [[ -s "$dir/ttl.pid.destroy" ]] && break; sleep 0.2; done
  sleep 0.5
  watchdog="$(cat "$dir/ttl.pid")" destroy="$(cat "$dir/ttl.pid.destroy")"
  before="$(pgrep -g "$destroy" | wc -l)"
  out="$(bash -c '. hack/lib/session-teardown.sh; killswitch_disarm "$1" "$2"; echo "rc=$?"' _ "$watchdog" "$dir/ttl.pid")"
  left=0
  for p in $(pgrep -g "$watchdog,$destroy"); do [[ "$(ps -o stat= -p "$p")" == Z* ]] || left=$((left + 1)); done
  if [[ "$destroy" =~ ^[0-9]+$ && "$before" -ge 2 && "$out" == *"rc=0" && "$left" == 0 ]]; then
    ok "disarming stops the watchdog and the destroy it started ($kind: $before process(es) in the destroy's group)"
  else
    bad "disarming during a destroy ($kind): destroy '$destroy' with $before process(es), $out, $left left"
    [[ "$destroy" =~ ^[0-9]+$ ]] && kill -9 -- "-$destroy"
    [[ "$watchdog" =~ ^[0-9]+$ ]] && kill -9 -- "-$watchdog"
  fi
done

# A destroy group whose leader exits on TERM while a member ignores it, with no watchdog left to clean up after it, as
# when the watchdog was killed outright: disarming must read the group, not its leader, and kill what is left.
: >"$dir/ttl.pid.destroy"
# The fixture reports its own pid, never found by a pattern, which could name another process group to kill (codex
# review of 72761da6); as a session leader its pid is its process group.
: >"$dir/fixture.pid"
setsid bash -c 'echo $$ >"$1"; (trap "" TERM; exec sleep 300) & exec sleep 300' _ "$dir/fixture.pid" &
for _ in $(seq 25); do [[ -s "$dir/fixture.pid" ]] && break; sleep 0.2; done
group="$(cat "$dir/fixture.pid")"
sleep 0.3
echo "$group" >"$dir/ttl.pid.destroy"
gone_watchdog=999999
out="$(bash -c '. hack/lib/session-teardown.sh; killswitch_disarm "$1" "$2"; echo "rc=$?"' _ "$gone_watchdog" "$dir/ttl.pid")"
left=0
for p in $(pgrep -g "$group"); do [[ "$(ps -o stat= -p "$p")" == Z* ]] || left=$((left + 1)); done
if [[ "$group" =~ ^[0-9]+$ && "$out" == *"rc=0" && "$left" == 0 ]]; then
  ok "disarming kills a destroy group's member that outlived its leader"
else
  bad "the orphaned destroy member: group '$group', $out, $left left"
  [[ "$group" =~ ^[0-9]+$ ]] && kill -9 -- "-$group"
fi

: >"$dir/kill.log"
PATH="$dir/bin:$PATH" bash -c "$(program 30)"
if grep -q 'force-destroy SUCCEEDED' "$dir/kill.log" && [[ "$(cat "$dir/ttl.pid")" =~ ^[0-9]+$ ]]; then
  ok "a destroy that succeeds is reported SUCCEEDED, and the watchdog wrote its pid"
else
  bad "the succeeding destroy: $(tail -3 "$dir/kill.log" | tr '\n' ' ')"
fi

# A destroy that returns zero is SUCCEEDED only once the residue census is clean, as the foreground teardown requires; the
# GPU deadline is removed only then, and the session's own deadline is not counted as residue (gpt-6-astra's review of
# 116092ef, r5 finding 6).
echo "gpu-ttl-gpu-platform-gpu-20261107000000" >"$dir/gpu-ttl-schedule.txt"
for residue in left unasked clean; do
  : >"$dir/kill.log"
  : >"$dir/aws.calls"
  case "$residue" in
    left) TTL_RESIDUE_EC2="i-0abc" PATH="$dir/bin:$PATH" bash -c "$(program 30)" ;;
    unasked) TTL_RESIDUE_EKS_RC=254 PATH="$dir/bin:$PATH" bash -c "$(program 30)" ;;
    clean) TTL_RESIDUE_SCHEDULE="gpu-ttl-gpu-platform-gpu-20261107000000" PATH="$dir/bin:$PATH" bash -c "$(program 30)" ;;
  esac
  deleted="$(grep -c 'scheduler delete-schedule --name gpu-ttl-gpu-platform-gpu-20261107000000' "$dir/aws.calls")"
  if [[ "$residue" == clean ]]; then
    if grep -q 'force-destroy SUCCEEDED' "$dir/kill.log" && [[ "$deleted" == 1 ]] && grep -q 'eks list-clusters' "$dir/aws.calls"; then
      ok "a destroy followed by a clean census is SUCCEEDED and removes the GPU deadline"
    else
      bad "the clean census: deleted=$deleted, $(grep '\[ttl\]' "$dir/kill.log" | tail -1)"
    fi
  elif grep -q 'force-destroy INCOMPLETE' "$dir/kill.log" && ! grep -q 'force-destroy SUCCEEDED' "$dir/kill.log" && [[ "$deleted" == 0 ]]; then
    ok "a destroy that returned zero with the census $residue is INCOMPLETE and keeps the GPU deadline"
  else
    bad "the census $residue: deleted=$deleted, $(grep '\[ttl\]' "$dir/kill.log" | tail -1)"
  fi
done
rm -f "$dir/gpu-ttl-schedule.txt"

# A watchdog armed by an earlier session is found, so the next session refuses to build into the state it would destroy,
# and a disarmed one is no longer found (gpt-6-astra's review of 116092ef, r5 finding 1).
: >"$dir/ttl.pid"
PATH="$dir/bin:$PATH" setsid bash -c "$(program 600 600)" &
for _ in $(seq 25); do [[ -s "$dir/ttl.pid" ]] && break; sleep 0.2; done
armed="$(cat "$dir/ttl.pid")"
found="$(bash -c '. hack/lib/session-teardown.sh; killswitch_others')"
bash -c '. hack/lib/session-teardown.sh; killswitch_disarm "$1" "$2"' _ "$armed" "$dir/ttl.pid" >/dev/null
after="$(bash -c '. hack/lib/session-teardown.sh; killswitch_others')"
if [[ "$armed" =~ ^[0-9]+$ ]] && grep -qx "$armed" <<<"$found" && ! grep -qx "$armed" <<<"$after"; then
  ok "an armed watchdog is found by killswitch_others, and is gone from it once disarmed"
else
  bad "killswitch_others: armed '$armed', found [$found], after disarming [$after]"
  [[ "$armed" =~ ^[0-9]+$ ]] && kill -9 -- "-$armed"
fi
first_others="$(grep -n 'killswitch_others' hack/eks-gitops-session.sh | head -1 | cut -d: -f1)"
first_arm="$(grep -n 'setsid nohup bash -c "$(killswitch_program' hack/eks-gitops-session.sh | head -1 | cut -d: -f1)"
if [[ -n "$first_others" && -n "$first_arm" ]] && ((first_others < first_arm)) &&
  grep -q 'die "a kill switch watchdog from an earlier session is still armed' hack/eks-gitops-session.sh; then
  ok "the session refuses to arm while another watchdog is armed, before it arms its own"
else
  bad "the session's refusal of another armed watchdog: killswitch_others at line ${first_others:-none}, arming at ${first_arm:-none}"
fi

# A session still running when the TTL fires is stopped with everything it runs before the destroy, and the watchdog,
# which the session started and so is one of its children, survives that to destroy: a hung foreground terraform holding
# the state lock once defeated every destroy attempt (gpt-6-astra's second attack before the corelimit run).
: >"$dir/kill.log"
: >"$dir/session.pid"
# Its TERM handler starts a cleanup process while it shuts down, as train_down does; that is stopped with the rest.
PATH="$dir/bin:$PATH" setsid bash -c '. hack/lib/session-teardown.sh; echo $$ >"$1/session.pid"
  trap "sleep 300 & echo \$! >\"$1/cleanup.pid\"; sleep 10; exit 143" TERM
  sleep 300 & echo $! >"$1/session-child.pid"
  bash -c "$(killswitch_program "$1/ttl.pid" "$1/kill.log" "$1" 1 30 gpu-lab ap-northeast-2 infra/aws/cluster gpu-platform "" "$1" 4 $$)" &
  wait' _ "$dir" &
# The verdict line, not the TTL line, which says force-destroying too and once ended this wait at once.
for _ in $(seq 50); do grep -qE 'force-destroy (SUCCEEDED|FAILED)' "$dir/kill.log" && break; sleep 0.2; done
session="$(cat "$dir/session.pid")" child="$(cat "$dir/session-child.pid")" cleanup="$(cat "$dir/cleanup.pid" 2>&1)"
if grep -q "stopping the overdue session $session and what it runs:" "$dir/kill.log" && grep -q 'force-destroy SUCCEEDED' "$dir/kill.log" &&
  [[ "$cleanup" =~ ^[0-9]+$ ]] && ! ps -o stat= -p "$session" | grep -qv '^Z' && ! ps -o stat= -p "$child" | grep -qv '^Z' &&
  ! ps -o stat= -p "$cleanup" | grep -qv '^Z'; then
  ok "an overdue session, its children and what its TERM handler starts are stopped, and the watchdog it started still destroys"
else
  bad "the overdue session: $(tr '\n' ' ' <"$dir/kill.log" | cut -c1-300)"
  for p in "$session" "$child" "$cleanup"; do [[ "$p" =~ ^[0-9]+$ ]] && kill -9 "$p"; done
fi

# A destroy refused by a lock this host's user holds, with its session stopped, releases that lock once and destroys;
# a lock anyone else holds is left to its holder. The holder is read through terraform's ANSI colour and border.
me="$(id -un)@$(uname -n)"
for who in "$me" "runner@fv-az123-456"; do
  : >"$dir/kill.log"
  rm -rf "$dir/lock" && mkdir -p "$dir/lock"
  TF_HANGS=lock TF_LOCK_DIR="$dir/lock" TF_LOCK_WHO="$who" TF_LOCK_ERROR="$PWD/hack/test/session-teardown/terraform-lock-error.txt" \
    PATH="$dir/bin:$PATH" bash -c "$(program 30)"
  unlocks="$(cat "$dir/lock/unlocks" 2>&1)"
  if [[ "$who" == "$me" ]]; then
    if [[ "$unlocks" == *"force-unlock -force 0449cea0-ffd7-fbe2-19a7-a323ada5c4ec" ]] && grep -q 'force-destroy SUCCEEDED' "$dir/kill.log" &&
      grep -q "held by $me, this host's user" "$dir/kill.log"; then
      ok "a lock held by this host's stopped session is released once and the destroy succeeds"
    else
      bad "the lock held by this host: unlocks '$unlocks', $(grep '\[ttl\]' "$dir/kill.log" | tr '\n' ' ' | cut -c1-300)"
    fi
  elif [[ ! -e "$dir/lock/unlocks" ]] && grep -q 'force-destroy FAILED' "$dir/kill.log" &&
    grep -q "held by $who, not this host's stopped session; left to its holder" "$dir/kill.log"; then
    ok "a lock another holder has is left to it, and the destroy is reported FAILED"
  else
    bad "the lock held by another: unlocks '$unlocks', $(grep '\[ttl\]' "$dir/kill.log" | tr '\n' ' ' | cut -c1-300)"
  fi
done

# A terraform of this user still working on the cluster root carries the same Who, so its lock is not released while it
# runs (codex review of 3e3896cb). The stand-in is a script named terraform, so it is found by name as the real one is.
mkdir -p "$dir/holder"
# Like terraform, it changes into its -chdir before anything else (terraform's own process was seen to: started from
# infra/aws with -chdir=cluster, its cwd is infra/aws/cluster), so the holder is found where terraform would be.
cat >"$dir/holder/terraform" <<'EOF'
#!/bin/bash
for a in "$@"; do case "$a" in -chdir=*) cd "${a#-chdir=}" || exit 1 ;; esac; done
while :; do sleep 1; done
EOF
chmod +x "$dir/holder/terraform"
(cd "$PWD" && exec "$dir/holder/terraform" -chdir=infra/aws/cluster plan) &
holder=$!
sleep 0.5
: >"$dir/kill.log"
rm -rf "$dir/lock" && mkdir -p "$dir/lock"
TF_HANGS=lock TF_LOCK_DIR="$dir/lock" TF_LOCK_WHO="$me" TF_LOCK_ERROR="$PWD/hack/test/session-teardown/terraform-lock-error.txt" \
  PATH="$dir/bin:$PATH" bash -c "$(program 30)"
kill "$holder"
if [[ ! -e "$dir/lock/unlocks" ]] && grep -q "terraform $holder of that user still works on infra/aws/cluster; left to it" "$dir/kill.log"; then
  ok "a lock whose holder, this host's user, still runs terraform on the cluster root is left to it"
else
  bad "the live holder: $(grep '\[ttl\]' "$dir/kill.log" | tr '\n' ' ' | cut -c1-300)"
fi

# A terraform in another checkout's cluster root holds the same state, however it was pointed there: started from inside
# it, given an absolute -chdir, or a -chdir relative to somewhere else (gpt-6-astra's review of 116092ef, r5 finding 2).
# A terraform on another root is not a holder, and the stale lock is still released.
other="$work/other checkout"
mkdir -p "$other/infra/aws/cluster" "$other/infra/aws/bootstrap"
for how in inside absolute relative parent unrelated; do
  case "$how" in
    parent) (cd "$other/infra/aws" && exec "$dir/holder/terraform" -chdir=cluster plan) & ;;
    inside) (cd "$other/infra/aws/cluster" && exec "$dir/holder/terraform" plan) & ;;
    absolute) (cd / && exec "$dir/holder/terraform" "-chdir=$other/infra/aws/cluster" plan) & ;;
    relative) (cd "$other/infra/aws/bootstrap" && exec "$dir/holder/terraform" -chdir=../cluster plan) & ;;
    unrelated) (cd "$other/infra/aws/bootstrap" && exec "$dir/holder/terraform" plan) & ;;
  esac
  holder=$!
  sleep 0.5
  : >"$dir/kill.log"
  rm -rf "$dir/lock" && mkdir -p "$dir/lock"
  TF_HANGS=lock TF_LOCK_DIR="$dir/lock" TF_LOCK_WHO="$me" TF_LOCK_ERROR="$PWD/hack/test/session-teardown/terraform-lock-error.txt" \
    PATH="$dir/bin:$PATH" bash -c "$(program 30)"
  kill "$holder"
  if [[ "$how" == unrelated ]]; then
    if [[ -e "$dir/lock/unlocks" ]] && grep -q 'force-destroy SUCCEEDED' "$dir/kill.log"; then
      ok "a terraform on another root is not taken for the lock's holder, and the stale lock is released"
    else
      bad "the unrelated terraform: $(grep '\[ttl\]' "$dir/kill.log" | tr '\n' ' ' | cut -c1-300)"
    fi
  elif [[ ! -e "$dir/lock/unlocks" ]] && grep -q "terraform $holder of that user still works on infra/aws/cluster; left to it" "$dir/kill.log"; then
    ok "a terraform on another checkout's cluster root ($how) holds the lock, which is left to it"
  else
    bad "the holder in another checkout ($how): $(grep '\[ttl\]' "$dir/kill.log" | tr '\n' ' ' | cut -c1-300)"
  fi
done

# The release is cut to what is left of the allowance: a refusal reported at its end is not followed by a force-unlock
# that would run past the deadline the credential covers (codex review of 3e3896cb).
: >"$dir/kill.log"
rm -rf "$dir/lock" && mkdir -p "$dir/lock"
TF_HANGS=lock TF_LOCK_SLOW=5 TF_LOCK_DIR="$dir/lock" TF_LOCK_WHO="$me" TF_LOCK_ERROR="$PWD/hack/test/session-teardown/terraform-lock-error.txt" \
  PATH="$dir/bin:$PATH" bash -c "$(program 3)"
if [[ ! -e "$dir/lock/unlocks" ]] && grep -q 'is stale, but the 3s allowance has no time left to release it' "$dir/kill.log"; then
  ok "a stale lock found with no allowance left is not released past the deadline"
else
  bad "the late release: $(grep '\[ttl\]' "$dir/kill.log" | tr '\n' ' ' | cut -c1-300)"
fi

# A disarm during the release stops it too: it is recorded as the destroy is (codex review of 3e3896cb).
: >"$dir/kill.log"
: >"$dir/ttl.pid"
: >"$dir/ttl.pid.destroy"
rm -rf "$dir/lock" && mkdir -p "$dir/lock"
TF_HANGS=lock TF_UNLOCK_HANGS=1 TF_LOCK_DIR="$dir/lock" TF_LOCK_WHO="$me" TF_LOCK_ERROR="$PWD/hack/test/session-teardown/terraform-lock-error.txt" \
  PATH="$dir/bin:$PATH" setsid bash -c "$(program 600)" &
for _ in $(seq 50); do [[ -s "$dir/lock/unlocks" && -s "$dir/ttl.pid.destroy" ]] && break; sleep 0.2; done
sleep 0.3
watchdog="$(cat "$dir/ttl.pid")" unlock="$(cat "$dir/ttl.pid.destroy")"
before="$(pgrep -g "$unlock" | wc -l)"
out="$(bash -c '. hack/lib/session-teardown.sh; killswitch_disarm "$1" "$2"; echo "rc=$?"' _ "$watchdog" "$dir/ttl.pid")"
left=0
for p in $(pgrep -g "$watchdog,$unlock"); do [[ "$(ps -o stat= -p "$p")" == Z* ]] || left=$((left + 1)); done
if [[ "$unlock" =~ ^[0-9]+$ && "$before" -ge 1 && "$out" == *"rc=0" && "$left" == 0 ]] && grep -q 'releasing it' "$dir/kill.log"; then
  ok "disarming during the release stops the force-unlock it started ($before process(es) in its group)"
else
  bad "disarming during the release: unlock '$unlock' with $before process(es), $out, $left left"
  [[ "$unlock" =~ ^[0-9]+$ ]] && kill -9 -- "-$unlock"
  [[ "$watchdog" =~ ^[0-9]+$ ]] && kill -9 -- "-$watchdog"
fi

# The session uses both, so a check of the library is a check of what the session runs.
for f in 'teardown_residue "$REGION" "$CLUSTER" "$EXDIR"' 'killswitch_program "$KILL_PIDFILE"' '$((TTL_MINUTES + KILL_DESTROY_MINUTES))' \
  '"$TF_TRAIN_VARS" "$EXDIR" "" $$ \'; do
  if grep -qF -- "$f" hack/eks-gitops-session.sh; then ok "the session calls $f"; else bad "the session does not call $f"; fi
done

# Argo's root authenticates for var.cluster_name, so its apply and its destroy are both given the session's name and
# region; with the default name a session under another CLUSTER installed nothing (gpt-6-astra's review of 116092ef, r5
# finding 10).
argo_named="$(grep -F -A1 -e 'terraform -chdir="$ARGO_DIR" apply' -e 'terraform -chdir="$ARGO_DIR" destroy' hack/eks-gitops-session.sh |
  grep -cF -- '-var="cluster_name=$CLUSTER" -var="region=$REGION"')"
if [[ "$argo_named" == 2 ]]; then
  ok "the Argo root's apply and destroy are both given the session's cluster name and region"
else
  bad "the Argo root is given the session's cluster name and region in $argo_named of its apply and destroy"
fi

if ((fails == 0)); then echo "check-session-teardown: all checks passed"; else echo "check-session-teardown: $fails check(s) failed"; exit 1; fi
