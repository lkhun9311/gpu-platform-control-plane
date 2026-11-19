#!/bin/bash
# One #68415 state of hack/vllm-gdn-68414-session.sh, run inside a fresh container of the pinned vLLM CI image.
#
#   kda-state.sh before <pytest seconds>
#   kda-state.sh after <pytest seconds>
#
# /in holds kda-test.diff, kda-fix.diff and kda-pins.txt, read-only; /out/kda-<state> receives the record.
# BEFORE adds only the new test and runs only its 64-32 case, which fails on the output's shape without writing out of bounds.
# The 32-64 case is never run BEFORE, because with V above K the unfixed kernel writes past the output it was given and can crash the process.
# AFTER applies the whole diff and runs all three cases.
# This script records and does not judge: hack/vllm-gdn-68414/kda-verdict.py reads what it leaves.
set -u
. "$(dirname "$0")/lib.sh"
S=$1
PYTEST_S=$2
TEST=tests/kernels/fla/test_fused_recurrent_kda.py
CASE=test_fused_recurrent_kda_output_has_value_shape
case $S in
  # The node id and -k each select the 64-32 case alone, so a mistake in either still cannot reach 32-64.
  before) DIFF=$IN/kda-test.diff; SELECT=("$TEST::$CASE[64-32]" -k "64-32") ;;
  after) DIFF=$IN/kda-fix.diff; SELECT=("$TEST") ;;
  *) echo "unknown state $S" >&2; exit 4 ;;
esac
KDA_MOD=vllm.third_party.flash_linear_attention.ops.kda
# Whole lines, since kda.py holds other torch.empty_like(k) calls that are not the bug.
FIX_LINE='    o = k.new_empty(v.shape)'
BUG_LINE='    o = torch.empty_like(k)'

begin "kda-$S"
prepare "$IN/kda-pins.txt" "$S" "$DIFF"

# The kda.py Python imports from the directory pytest runs in, and which of the two lines it holds.
KF=$(imported "$KDA_MOD" kda_file)
grep -nxF "$FIX_LINE" "$KF" > "$O/fix-grep.txt" 2>&1
kv fix_grep_rc "$?"
grep -nxF "$BUG_LINE" "$KF" > "$O/bug-grep.txt" 2>&1
kv bug_grep_rc "$?"
step "kda.py imported from ${KF:-unread}; fix line: $(head -c 200 "$O/fix-grep.txt" | tr '\n' ' '); bug line: $(head -c 200 "$O/bug-grep.txt" | tr '\n' ' ')"

kv pytest_args "${SELECT[*]}"
pytest_run test "$PYTEST_S" "${SELECT[@]}"
finish
