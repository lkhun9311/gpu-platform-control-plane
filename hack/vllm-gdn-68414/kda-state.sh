#!/bin/bash
# One #68415 state of hack/vllm-gdn-68414-session.sh run 3, run inside a fresh container of the pinned vLLM CI image.
#
#   kda-state.sh before <pytest seconds> <probe seconds>
#   kda-state.sh after <pytest seconds> <probe seconds>
#
# /in holds kda-test.diff, kda-fix.diff, kda-pins.txt and kda-differs.txt, read-only; /out/kda-<state> receives the record.
# The test has five cases: k64-v32, k64-v64, k32-v64, k64-v32-hv2 and v-bf16.
# BEFORE adds only the new test and runs every case but k32-v64.
# With V above K the unfixed kernel writes past the output it was given, so k32-v64 is never run before the fix.
# k64-v32 and k64-v32-hv2 must fail on the shape assert, and k64-v64 and v-bf16 must pass.
# AFTER applies the whole diff and runs all five cases, which must all pass.
# This script records and does not judge: hack/vllm-gdn-68414/kda-verdict.py reads what it leaves.
set -u
. "$(dirname "$0")/lib.sh"
S=$1
PYTEST_S=$2
PROBE_S=$3
TEST=tests/kernels/fla/test_fused_recurrent_kda.py
CASE=test_fused_recurrent_kda_output_has_value_shape
case $S in
  # The node ids and -k each leave k32-v64 out, so a mistake in either still cannot reach it.
  before) DIFF=$IN/kda-test.diff; SELECT=("$TEST::$CASE[k64-v32]" "$TEST::$CASE[k64-v64]" "$TEST::$CASE[k64-v32-hv2]" "$TEST::$CASE[v-bf16]" -k "not k32-v64") ;;
  after) DIFF=$IN/kda-fix.diff; SELECT=("$TEST") ;;
  *) echo "unknown state $S" >&2; exit 4 ;;
esac
OPS=vllm.third_party.flash_linear_attention.ops
# Whole lines, since kda.py holds other torch.empty_like(k) calls that are not the bug.
FIX_LINE='    o = k.new_empty(v.shape)'
BUG_LINE='    o = torch.empty_like(k)'
# #68416's term, which must be in neither state's kernel, since its fix is another item's.
STRIDE_FIX_TEXT='i_t * stride_indices_tok'
PROBE_DIFFERS=$IN/kda-differs.txt

begin "kda-$S"
# A BEFORE whose selection could reach k32-v64 stops here, before anything runs.
if [ "$S" = before ]; then
  sel_ok=yes
  for ((i = 0; i < ${#SELECT[@]}; i++)); do
    a=${SELECT[i]}
    if [ "$a" = -k ]; then
      i=$((i + 1))
      [ "${SELECT[i]:-}" = "not k32-v64" ] || sel_ok=no
    else
      # Quoted whole, so the brackets are literal and not a pattern.
      case $a in "$TEST::$CASE[k64-v32]" | "$TEST::$CASE[k64-v64]" | "$TEST::$CASE[k64-v32-hv2]" | "$TEST::$CASE[v-bf16]") ;; *) sel_ok=no ;; esac
    fi
  done
  [[ " ${SELECT[*]} " == *" -k not k32-v64 "* ]] || sel_ok=no
  kv before_selection_guard "$sel_ok"
  [ "$sel_ok" = yes ] || refuse "BEFORE's selection ($(q "${SELECT[@]}")) could reach k32-v64; nothing runs"
fi
prepare "$IN/kda-pins.txt" "$S" "$DIFF"

# The files Python imports from the directory pytest runs in: kda.py, the kernel it launches, and the new test.
imports kda_file=$OPS.kda kernel_file=$OPS.kda:fused_recurrent_gated_delta_rule_fwd_kernel test_file=tests.kernels.fla.test_fused_recurrent_kda
KF=$(file_of kda_file)
grep -nxF "$FIX_LINE" "$KF" > "$O/fix-grep.txt" 2>&1
kv fix_grep_rc "$?"
grep -nxF "$BUG_LINE" "$KF" > "$O/bug-grep.txt" 2>&1
kv bug_grep_rc "$?"
c=$(grep -cF -- "$STRIDE_FIX_TEXT" "$(file_of kernel_file)" 2>> "$O/fix-grep.err")
kv kernel_stride_fix_count "${c:-unread}"
step "kda.py imported from ${KF:-unread}; fix line: $(head -c 200 "$O/fix-grep.txt" | tr '\n' ' '); bug line: $(head -c 200 "$O/bug-grep.txt" | tr '\n' ' '); kernel from $(file_of kernel_file) with #68416's term ${c:-unread} time(s)"

probe "$PROBE_S" "${SELECT[@]}"
kv pytest_args "${SELECT[*]}"
pytest_run test "$PYTEST_S" "${SELECT[@]}"
finish
