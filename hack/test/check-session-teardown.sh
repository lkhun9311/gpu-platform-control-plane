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
exit 0
EOF
chmod +x "$dir/bin/terraform"
program() {
  bash -c '. hack/lib/session-teardown.sh; killswitch_program "$1/ttl.pid" "$1/kill.log" "$1" "${3:-0}" "$2" gpu-lab ap-northeast-2 infra/aws/cluster gpu-platform "-var=gpu_max_nodes=3 -var=efs_enabled=true" "$1" 1' _ "$dir" "$1" "${2:-0}"
}
if program 3 | bash -n; then ok "the program parses with an apostrophe in its paths"; else bad "the program does not parse with an apostrophe in its paths"; fi
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

# The session uses both, so a check of the library is a check of what the session runs.
for f in 'teardown_residue "$REGION" "$CLUSTER" "$EXDIR"' 'killswitch_program "$KILL_PIDFILE"' '$((TTL_MINUTES + KILL_DESTROY_MINUTES))'; do
  if grep -qF -- "$f" hack/eks-gitops-session.sh; then ok "the session calls $f"; else bad "the session does not call $f"; fi
done

if ((fails == 0)); then echo "check-session-teardown: all checks passed"; else echo "check-session-teardown: $fails check(s) failed"; exit 1; fi
