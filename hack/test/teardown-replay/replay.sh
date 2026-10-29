#!/usr/bin/env bash
#
# Replay the teardown residue classifier in hack/eks-gitops-session.sh against recorded aws responses.
#
# WHY THIS EXISTS. That script destroys an EKS cluster and then asks seven AWS services whether anything still
# bills, separating "something still bills" (billing_left) from "I could not ask" (unasked) and failing on
# either. It disarms the TTL kill switch only when both are empty. The check is the fix for a real mistake: a
# 2026-09-25 session reported FAIL on a teardown that had completed, because it compared a tag listing that
# still named resources the EC2 API had already dropped. **The check has never run against a live teardown**,
# and the harness classifier refuses to let the model run the paid script at all.
#
# The disarm decision is extracted from the same script, so the replay runs the shipped decision and not a copy.
#
# WHAT THIS ESTABLISHES, exactly. Offline replay validates teardown classification and watchdog-disarm
# decisions for specified AWS CLI responses. It does NOT establish that a live teardown was validated, that
# AWS confirmed nothing still bills, that the checks cover every billable resource, or that the TTL kill
# switch works in AWS. It cannot speak to actual deletion, IAM access, query and filter correctness,
# eventual consistency, or billing cessation. Those wordings came from an external review that was asked what
# it would refuse to let this repository claim on the strength of a replay.
#
# The fixtures are SYNTHETIC. No response here was recorded from AWS; each was written to exercise one branch.
#
# HOW IT AVOIDS DRIFT. still() is extracted from the session script at run time, not copied. A copy would go
# stale silently and the replay would then be of something else. The extraction is asserted to be the
# expected length before anything runs, because an extraction that grabbed the wrong span is how a replay
# reports on code nobody shipped.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../../.." || exit 1
SRC=hack/eks-gitops-session.sh
HERE=hack/test/teardown-replay
STILL_LINES=18
DISARM_LINES=6

pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  BAD   %s\n' "$1"; fail=$((fail+1)); }

# 1. Extract still() from the session script and refuse if it is not the shape this replay was written for.
still_src="$(sed -n '/^still() {/,/^}/p' "$SRC")"
n="$(printf '%s\n' "$still_src" | wc -l)"
if [ "$n" -ne "$STILL_LINES" ]; then
  printf 'teardown-replay: still() extracted as %s lines, expected %s.\n' "$n" "$STILL_LINES" >&2
  printf 'The function in %s changed shape. Read it, decide whether these scenarios still describe it,\n' "$SRC" >&2
  printf 'and update STILL_LINES with the new count -- do not widen the extraction to make this pass.\n' >&2
  exit 1
fi
ok "still() extracted from $SRC ($n lines)"

# 1b. Extract the disarm decision the same way. It used to be rewritten here as `[ "$v" = ok ]`, so changing the
#     production script to disarm unconditionally left every scenario below green.
#     The block taken is the if-statement that calls disarm, from its `if` to its closing `fi`.
disarm_src="$(awk '/^if \[\[ .*unasked.*billing_left.* \]\]; then$/ { buf=$0 "\n"; inblk=1; next }
  inblk { buf=buf $0 "\n"; if ($0 ~ /^fi$/) { if (buf ~ /\n  disarm\n/) printf "%s", buf; inblk=0 } }' "$SRC")"
n="$(printf '%s\n' "$disarm_src" | wc -l)"
if [ "$n" -ne "$DISARM_LINES" ]; then
  printf 'teardown-replay: the disarm decision extracted as %s lines, expected %s.\n' "$n" "$DISARM_LINES" >&2
  printf 'Read the decision in %s, decide whether these scenarios still describe it, and update DISARM_LINES.\n' "$SRC" >&2
  exit 1
fi
ok "the disarm decision extracted from $SRC ($n lines)"

# 2. The stub must answer for every label the script actually asks about. A label the stub does not know
#    falls through to an empty response, which reads as "nothing left" -- a false pass on the exact question
#    this replay exists to answer. One mismatch was found this way: the script calls the volume check `ebs`
#    and the first version of this replay called it `vol`, so twelve green scenarios were replaying a label
#    the script never uses, and the evidence filename (aws-ebs.err) was wrong with it.
missing=""
while read -r label cmd; do
  [ -n "$label" ] || continue
  svc="$(SCENARIO_DIR=/nonexistent bash -c 'set -- '"$cmd"'; . '"$HERE"'/bin/aws 2>/dev/null; echo "${svc:-unknown}"' 2>/dev/null || echo unknown)"
  grep -q "svc=$label" "$HERE/bin/aws" || missing="$missing $label"
done < <(sed -n 's/^still \([a-z0-9]*\) aws \(.*\)$/\1 \2/p' "$SRC")
if [ -n "$missing" ]; then
  bad "the stub has no branch for:$missing"
else
  ok "the stub has a branch for every label the script asks about"
fi

# 3. Replay each scenario and compare against expectations fixed before the first run.
while read -r name want; do
  [ -n "$name" ] || continue
  d="$HERE/scenarios/$name"
  [ -d "$d" ] || { bad "$name: no scenario directory"; continue; }
  ex="$(mktemp -d)"
  got="$(
    PATH="$PWD/$HERE/bin:$PATH" SCENARIO_DIR="$PWD/$d" EXDIR="$ex" bash -c '
      set -uo pipefail
      unasked=""; billing_left=""
      '"$still_src"'
      R="--region ap-northeast-2"
      still eks aws eks list-clusters $R --query "clusters" --output text
      still ec2 aws ec2 describe-instances $R --filters "Name=instance-state-name,Values=running" --query "x" --output text
      still nat aws ec2 describe-nat-gateways $R --filter "Name=state,Values=available" --query "x" --output text
      still eip aws ec2 describe-addresses $R --query "x" --output text
      still ebs aws ec2 describe-volumes $R --query "x" --output text
      still asg aws autoscaling describe-auto-scaling-groups $R --query "x" --output text
      still elb aws elbv2 describe-load-balancers $R --query "x" --output text
      still schedule aws scheduler list-schedules $R --name-prefix "gpu-ttl-x-" --query "x" --output text
      still logs aws logs describe-log-groups $R --log-group-name-prefix "/aws/eks/x/" --query "x" --output text
      v=ok
      [ -n "${unasked// /}" ] && v=unasked
      [ -n "${billing_left// /}" ] && v="${v}+left"
      disarmed=no; KILL_PID=0
      disarm() { disarmed=yes; }
      log() { :; }
      '"$disarm_src"'
      printf "%s|%s\n" "$v" "$disarmed"
    '
  )"
  rm -rf "$ex"
  if [ "$got" = "$want" ]; then ok "$name -> $got"; else bad "$name -> got $got, want $want"; fi
done < "$HERE/expect.txt"

printf '\nteardown-replay: %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
