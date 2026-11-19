#!/bin/bash
# One #68416 state of hack/vllm-gdn-68414-session.sh run 4, run inside a fresh container of the pinned vLLM CI image.
#
#   stride-state.sh before <pytest seconds> <probe seconds>
#   stride-state.sh after <pytest seconds> <probe seconds> <whole-file seconds>
#
# /in holds stride-test.diff, stride-fix.diff, stride-pins.txt and stride-differs.txt, read-only; /out/stride-<state> receives the record.
# The test is test_state_index_table_stride_does_not_change_results in the existing test_fused_sigmoid_gating_delta_rule.py, with cases recurrent, sigmoid_gating and kda.
# BEFORE adds only the test and runs `-k stride`, whose three cases must all fail on assert_close.
# Running them unfixed is safe: the unfixed kernels read the index table with a token stride of one, which stays inside the table.
# AFTER applies the whole diff and runs `-k stride`, whose three cases must pass, and then the whole file, which must pass too.
# The diff changes fused_recurrent.py, fused_sigmoid_gating.py and the test file, and its kda case launches fused_recurrent.py's kernel through kda.py.
# So the import checks cover all four files, kda.py holding #68415's bug line and not its fix in both states.
# This script records and does not judge: hack/vllm-gdn-68414/stride-verdict.py reads what it leaves.
set -u
. "$(dirname "$0")/lib.sh"
S=$1
PYTEST_S=$2
PROBE_S=$3
TEST=tests/kernels/fla/test_fused_sigmoid_gating_delta_rule.py
SELECT=("$TEST" -k stride)
case $S in
  before) DIFF=$IN/stride-test.diff ;;
  after) DIFF=$IN/stride-fix.diff; FILE_S=$4 ;;
  *) echo "unknown state $S" >&2; exit 4 ;;
esac
OPS=vllm.third_party.flash_linear_attention.ops
# The diff adds this term to two loads in each kernel, and the unfixed files hold it nowhere.
FIX_TEXT='i_t * stride_indices_tok'
# #68415's lines, so its fix cannot reach this item's kda case unseen.
KDA_FIX_LINE='    o = k.new_empty(v.shape)'
KDA_BUG_LINE='    o = torch.empty_like(k)'
PROBE_DIFFERS=$IN/stride-differs.txt

begin "stride-$S"
prepare "$IN/stride-pins.txt" "$S" "$DIFF"

# The files Python imports from the directory pytest runs in, and the kernel kda.py launches.
imports fused_recurrent_file=$OPS.fused_recurrent fused_sigmoid_gating_file=$OPS.fused_sigmoid_gating kda_file=$OPS.kda \
  kda_kernel_file=$OPS.kda:fused_recurrent_gated_delta_rule_fwd_kernel test_file=tests.kernels.fla.test_fused_sigmoid_gating_delta_rule
for m in fused_recurrent fused_sigmoid_gating; do
  f=$(file_of "${m}_file")
  c=$(grep -cF -- "$FIX_TEXT" "$f" 2>> "$O/fix-grep.err")
  kv "${m}_fix_count" "${c:-unread}"
  step "$m.py imported from ${f:-unread}; '$FIX_TEXT' occurs ${c:-unread} time(s)"
done
KF=$(file_of kda_file)
grep -nxF "$KDA_FIX_LINE" "$KF" > "$O/kda-fix-grep.txt" 2>&1
kv kda_fix_grep_rc "$?"
grep -nxF "$KDA_BUG_LINE" "$KF" > "$O/kda-bug-grep.txt" 2>&1
kv kda_bug_grep_rc "$?"
step "kda.py imported from ${KF:-unread}, launching the kernel in $(file_of kda_kernel_file)"

probe "$PROBE_S" "${SELECT[@]}"
kv pytest_args "${SELECT[*]}"
pytest_run test "$PYTEST_S" "${SELECT[@]}"
if [ "$S" = after ]; then
  kv file_args "$TEST"
  pytest_run file "$FILE_S" "$TEST"
fi
finish
