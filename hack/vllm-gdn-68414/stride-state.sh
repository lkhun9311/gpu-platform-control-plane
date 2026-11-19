#!/bin/bash
# One #68416 state of hack/vllm-gdn-68414-session.sh, run inside a fresh container of the pinned vLLM CI image.
#
#   stride-state.sh before <pytest seconds>
#   stride-state.sh after <pytest seconds>
#
# /in holds stride-test.diff, stride-fix.diff and stride-pins.txt, read-only; /out/stride-<state> receives the record.
# BEFORE adds only the new test and runs both its cases, recurrent and sigmoid_gating, which must both fail.
# Running both unfixed is safe: the unfixed kernels read the index table with a token stride of one, which stays inside the table, so nothing is written out of bounds.
# AFTER applies the whole diff and runs the same two cases, which must both pass.
# This script records and does not judge: hack/vllm-gdn-68414/stride-verdict.py reads what it leaves.
set -u
. "$(dirname "$0")/lib.sh"
S=$1
PYTEST_S=$2
TEST=tests/kernels/fla/test_state_index_stride.py
case $S in
  before) DIFF=$IN/stride-test.diff ;;
  after) DIFF=$IN/stride-fix.diff ;;
  *) echo "unknown state $S" >&2; exit 4 ;;
esac
OPS=vllm.third_party.flash_linear_attention.ops
# The diff adds this term to two loads in each kernel, and the unfixed files hold it nowhere.
FIX_TEXT='i_t * stride_indices_tok'

begin "stride-$S"
prepare "$IN/stride-pins.txt" "$S" "$DIFF"

# Each kernel file Python imports from the directory pytest runs in, and how many loads in it step by the token stride.
for m in fused_recurrent fused_sigmoid_gating; do
  f=$(imported "$OPS.$m" "${m}_file")
  c=$(grep -cF -- "$FIX_TEXT" "$f" 2>> "$O/fix-grep.err")
  kv "${m}_fix_count" "${c:-unread}"
  step "$m.py imported from ${f:-unread}; '$FIX_TEXT' occurs ${c:-unread} time(s)"
done

kv pytest_args "$TEST"
pytest_run test "$PYTEST_S" "$TEST"
finish
