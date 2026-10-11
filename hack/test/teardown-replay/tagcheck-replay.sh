#!/usr/bin/env bash
#
# Replay the tagged-resource comparison in hack/eks-gitops-session.sh against recorded aws responses.
#
# WHY THIS EXISTS, and why it is separate from replay.sh. That script replays still(), the per-service
# residue classifier. This one replays the OTHER half of the same teardown verdict: the comparison of the
# project's tagged resources before and after the destroy. The two halves failed in the same way on the same
# paid run and were fixed in the same commit (82dd4b4, 2026-09-25), and only one of them got a replay.
#
# THE BUG THIS PINS. The before-side read was `>file 2>&1 || true`, so when the tag query failed its ERROR
# TEXT landed in the baseline file. The comparison after the destroy then treated that text as the set of
# resources that had existed beforehand, and reported every surviving ARN as one that had newly APPEARED --
# a loud failure invented out of an unreadable query. The after-side already had an UNKNOWN sentinel; the
# before-side had none. Same "unreadable is not empty" confusion, other half.
#
# WHAT THIS ESTABLISHES, exactly. Offline replay validates the appeared-since decision for specified AWS CLI
# responses: whether the comparison runs at all, and whether it reports appeared resources. It does NOT
# establish that a live teardown was validated, that AWS confirmed nothing still bills, or that the tag API's
# eventual consistency behaves as the fixtures assume -- that last one is precisely what the paid run got
# wrong, and no offline fixture can settle it.
#
# The fixtures are SYNTHETIC. No response here was recorded from AWS.
#
# HOW IT AVOIDS DRIFT. Both blocks are extracted from the session script at run time, not copied, and each
# extraction is asserted to be the expected length before anything runs. A copy would go stale silently and
# the replay would then be of something else.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../../.." || exit 1
SRC=hack/eks-gitops-session.sh
HERE=hack/test/teardown-replay
# The two spans this replay drives, by their own anchors rather than by line number: line numbers move with
# every edit above them, and a span that silently slid would replay the wrong code.
BEFORE_LINES=7
AFTER_LINES=12

pass=0; fail=0
ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  BAD   %s\n' "$1"; fail=$((fail+1)); }

# 1. Extract the before-side read: the `if ! aws resourcegroupstaggingapi ...` guard through its `fi`.
before_src="$(sed -n '/^if ! aws resourcegroupstaggingapi get-resources/,/^fi$/p' "$SRC")"
# An empty extraction is named as empty, not counted.
#
# `printf '%s\n' ""` is one newline, so `wc -l` reports an extraction that matched NOTHING as "1 lines".
# Reverting the fix under test made the start anchor stop matching, and this message duly said "extracted as
# 1 lines" -- which invites the next reader to set the constant to 1 and get a green replay of nothing at all.
# That is this repository's most common defect class, committed by the tool built to guard against it.
[ -n "$before_src" ] || {
  printf 'tagcheck-replay: the before-side read extracted NOTHING -- the anchor matched no line in %s.\n' "$SRC" >&2
  printf 'The block was renamed, reshaped or removed. Do NOT set BEFORE_LINES to 1 to make this pass:\n' >&2
  printf 'that would replay an empty string and report every scenario green.\n' >&2
  exit 1
}
n="$(printf '%s\n' "$before_src" | wc -l)"
if [ "$n" -ne "$BEFORE_LINES" ]; then
  printf 'tagcheck-replay: the before-side read extracted as %s lines, expected %s.\n' "$n" "$BEFORE_LINES" >&2
  printf 'Read it in %s, decide whether these scenarios still describe it, and update BEFORE_LINES --\n' "$SRC" >&2
  printf 'do not widen the extraction to make this pass.\n' >&2
  exit 1
fi
ok "the before-side read extracted from $SRC ($n lines)"

# 2. Extract the after-side comparison: `tag_now=` through the closing `fi` of the appeared-since block.
after_src="$(sed -n '/^tag_now="\$(aws resourcegroupstaggingapi get-resources/,/^fi$/p' "$SRC")"
[ -n "$after_src" ] || {
  printf 'tagcheck-replay: the after-side comparison extracted NOTHING -- the anchor matched no line in %s.\n' "$SRC" >&2
  printf 'Do NOT set AFTER_LINES to 1 to make this pass; see the note on the before-side above.\n' >&2
  exit 1
}
n="$(printf '%s\n' "$after_src" | wc -l)"
if [ "$n" -ne "$AFTER_LINES" ]; then
  printf 'tagcheck-replay: the after-side comparison extracted as %s lines, expected %s.\n' "$n" "$AFTER_LINES" >&2
  printf 'Read it in %s, decide whether these scenarios still describe it, and update AFTER_LINES --\n' "$SRC" >&2
  printf 'do not widen the extraction to make this pass.\n' >&2
  exit 1
fi
ok "the after-side comparison extracted from $SRC ($n lines)"

# 3. The stub must answer the tag query. An unknown subcommand falls through to an empty response, which the
#    comparison reads as "no tagged resources" -- and an empty baseline plus an empty after-set compares
#    equal, so the check would pass for a run that could not ask anything. That is the false pass this whole
#    file exists to refuse, so the branch is asserted rather than assumed.
if grep -q 'svc=tags' "$HERE/bin/aws"; then
  ok "the stub has a branch for the resourcegroupstaggingapi query"
else
  bad "the stub has no svc=tags branch; every scenario below would replay an empty response"
fi

# 4. Replay each scenario and compare against expectations fixed before the first run.
#
#    The verdict is two facts, not one: whether the comparison RAN (`cmp` / `skip`), and whether it reported
#    appeared resources (`appeared` / `clean`). Collapsing them would hide the bug -- the old code's failure
#    was that the comparison ran when it should have been skipped, and a single pass/fail verdict cannot say
#    that. `failures` is carried out too, because that is what the session's own exit status is built from.
while read -r name want; do
  [ -n "$name" ] || continue
  d="$HERE/tag-scenarios/$name"
  [ -d "$d" ] || { bad "$name: no scenario directory"; continue; }
  ex="$(mktemp -d)"
  got="$(
    PATH="$PWD/$HERE/bin:$PATH" SCENARIO_DIR="$PWD/$d" EXDIR="$ex" REGION=ap-northeast-2 bash -c '
      set -uo pipefail
      failures=0
      ran=skip
      log() { :; }
      bad() { printf "APPEARED:%s\n" "$*" >>"$EXDIR/verdict"; failures=$((failures + 1)); }
      '"$before_src"'
      # The marker is set inside the replay rather than inferred afterwards, because "the file holds no
      # UNKNOWN" is not the same fact as "the comparison ran": a baseline could be readable and the
      # after-side unreadable, and only the code itself knows which branch it took.
      grep -qx UNKNOWN "$EXDIR/tagged-before-destroy.txt" || ran=maybe
      '"$after_src"'
      appeared_seen=clean
      [ -s "$EXDIR/verdict" ] && appeared_seen=appeared
      # The comparison ran iff it could have produced a verdict: both sides readable.
      if [ "$ran" = maybe ] && ! grep -qx UNKNOWN "$EXDIR/tagged-after-destroy.txt"; then ran=cmp; else ran=skip; fi
      printf "%s|%s|%s\n" "$ran" "$appeared_seen" "$failures"
    '
  )"
  rm -rf "$ex"
  if [ "$got" = "$want" ]; then ok "$name -> $got"; else bad "$name -> got $got, want $want"; fi
done < "$HERE/tag-expect.txt"

printf '\ntagcheck-replay: %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
