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
# HOW IT AVOIDS DRIFT. The census is teardown_residue, sourced from hack/lib/session-teardown.sh where the session and the
# kill switch's watchdog both take it, and the disarm decision is extracted from the session at run time, not copied.
# This replay once extracted a still() the session no longer had, stopped at its first step, and was run by nothing,
# so it had replayed no shipped code since the census moved into the library (gpt-6-astra's review of 116092ef, r5
# finding 12). It is now part of `make harness-check`.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../../.." || exit 1
SRC=hack/eks-gitops-session.sh
LIB=hack/lib/session-teardown.sh
HERE=hack/test/teardown-replay
DISARM_LINES=10

pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  BAD   %s\n' "$1"; fail=$((fail+1)); }

# 1. The census must be the library's function, and the session must call it.
if ! bash -c '. "$1"; declare -F teardown_residue >/dev/null' _ "$LIB"; then
  printf 'teardown-replay: %s defines no teardown_residue; nothing here would be replayed.\n' "$LIB" >&2
  exit 1
fi
grep -qF 'teardown_residue "$REGION" "$CLUSTER" "$EXDIR"' "$SRC" || { printf 'teardown-replay: %s does not call teardown_residue.\n' "$SRC" >&2; exit 1; }
ok "teardown_residue is the library's, and the session calls it"

# 1b. The disarm decision: the if-statement on the census whose body calls disarm, from its `if` to its closing `fi`.
#     It used to be rewritten here as `[ "$v" = ok ]`, so changing the session to disarm unconditionally left every
#     scenario green. An extraction that matched nothing is named as such: `printf '%s\n' ""` counts as one line.
disarm_src="$(awk '/^if \[\[ .*unasked.*billing_left.* \]\]; then$/ { buf=$0 "\n"; inblk=1; next }
  inblk { buf=buf $0 "\n"; if ($0 ~ /^fi$/) { if (buf ~ /\n  if disarm; then\n/) printf "%s", buf; inblk=0 } }' "$SRC")"
[ -n "$disarm_src" ] || { printf 'teardown-replay: the disarm decision extracted NOTHING from %s.\n' "$SRC" >&2; exit 1; }
n="$(printf '%s\n' "$disarm_src" | wc -l)"
if [ "$n" -ne "$DISARM_LINES" ]; then
  printf 'teardown-replay: the disarm decision extracted as %s lines, expected %s.\n' "$n" "$DISARM_LINES" >&2
  printf 'Read the decision in %s, decide whether these scenarios still describe it, and update DISARM_LINES.\n' "$SRC" >&2
  exit 1
fi
ok "the disarm decision extracted from $SRC ($n lines)"

# 2. The stub must answer for every label the census asks about. A label the stub does not know falls through to an
#    empty response, which reads as "nothing left" -- a false pass on the exact question this replay answers.
labels="$(sed -n 's/^  _residue_still \([a-z0-9]*\) aws .*/\1/p' "$LIB")"
[ -n "$labels" ] || { printf 'teardown-replay: no census label found in %s.\n' "$LIB" >&2; exit 1; }
missing=""
for label in $labels; do
  grep -q "svc=$label ;;" "$HERE/bin/aws" || missing="$missing $label"
done
if [ -n "$missing" ]; then
  bad "the stub has no branch for:$missing"
else
  ok "the stub has a branch for every label the census asks about ($(echo $labels))"
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
      . "$1"
      teardown_residue ap-northeast-2 x "$EXDIR"
      v=ok
      [ -n "${unasked// /}" ] && v=unasked
      [ -n "${billing_left// /}" ] && v="${v}+left"
      disarmed=no; KILL_PID=0
      disarm() { disarmed=yes; }
      log() { :; }
      '"$disarm_src"'
      printf "%s|%s\n" "$v" "$disarmed"
    ' _ "$LIB"
  )"
  rm -rf "$ex"
  if [ "$got" = "$want" ]; then ok "$name -> $got"; else bad "$name -> got $got, want $want"; fi
done < "$HERE/expect.txt"

printf '\nteardown-replay: %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
