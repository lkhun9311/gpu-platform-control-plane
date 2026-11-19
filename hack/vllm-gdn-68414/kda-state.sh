#!/bin/bash
# One #68415 state of hack/vllm-gdn-68414-session.sh, run inside a fresh container of the same pinned vLLM CI image.
#
#   kda-state.sh before <pytest seconds>
#   kda-state.sh after <pytest seconds>
#
# /in holds kda-test.diff, kda-fix.diff and kda-pins.txt, read-only; /out/kda-<state> receives the record.
# BEFORE adds only the new test and runs only its 64-32 case, which fails on the output's shape without writing out of bounds.
# The 32-64 case is never run BEFORE, because with V above K the unfixed kernel writes past the output it was given and can crash the process.
# AFTER applies the whole diff and runs all three cases.
# This script records and does not judge: hack/vllm-gdn-68414/kda-verdict.py reads what it leaves.
# It is separate from state.sh so that #68414's state script stays byte for byte the one that was tested.
set -u
S=$1
PYTEST_S=$2
TEST=tests/kernels/mamba/test_fla_fused_recurrent_kda.py
CASE=test_fused_recurrent_kda_output_has_value_shape
case $S in
  # The node id and -k each select the 64-32 case alone, so a mistake in either still cannot reach 32-64.
  before) DIFF=/in/kda-test.diff; SELECT=("$TEST::$CASE[64-32]" -k "64-32") ;;
  after) DIFF=/in/kda-fix.diff; SELECT=("$TEST") ;;
  *) echo "unknown state $S" >&2; exit 4 ;;
esac
# The image installs the wheel here and moves the checkout's vllm/ away, as hack/vllm-gdn-68414/state.sh records.
SITE=/usr/local/lib/python3.12/dist-packages
W=/vllm-workspace
O=/out/kda-$S
KDA_MOD=vllm.third_party.flash_linear_attention.ops.kda
# Whole lines, since kda.py holds other torch.empty_like(k) calls that are not the bug.
FIX_LINE='    o = k.new_empty(v.shape)'
BUG_LINE='    o = torch.empty_like(k)'
mkdir -p "$O"
step() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) kda-$S: $*" | tee -a "$O/steps.log" >&2; }
kv() { echo "$1=$2" >> "$O/state.txt"; }
: > "$O/state.txt"
kv started "$(date +%s)"

root_of() { case $1 in vllm/*) echo "$SITE" ;; *) echo "$W" ;; esac; }
# hashes STATE OUTFILE: as in state.sh, every pinned path where Python and pytest read it, against the pins for STATE.
hashes() {
  local want=$1 out=$2 ok=ok st sum p have
  : > "$out"
  while read -r st sum p; do
    [ "$st" = "$want" ] || continue
    if [ -e "$(root_of "$p")/$p" ]; then
      have=$(sha256sum "$(root_of "$p")/$p" 2>/dev/null | cut -d' ' -f1)
      have=${have:-unreadable}
    else
      have=absent
    fi
    echo "$have  $(root_of "$p")/$p" >> "$out"
    [ "$have" = "$sum" ] || { step "$p is $have, not the pinned $want $sum"; ok=bad; }
  done < /in/kda-pins.txt
  echo "$ok"
}

kv checkout_head "$(git -c safe.directory='*' -C "$W" rev-parse HEAD 2>/dev/null || echo unread)"
sha256sum "$DIFF" > "$O/diff.sha256"
kv diff_sha256 "$(cut -d' ' -f1 "$O/diff.sha256")"

# The pins include #68414's index.py and new test at the commit's, so neither fix can have reached this container.
base=$(hashes base "$O/base-sha256.txt")
kv base_identity "$base"
[ "$base" = ok ] || { step "the image's files are not the commit's; nothing applied"; kv ended "$(date +%s)"; exit 3; }

apply=ok
(cd "$W" && git -c safe.directory='*' apply --exclude='vllm/*' "$DIFF") > "$O/apply.log" 2>&1 || apply=failed
if grep -q '^diff --git a/vllm/' "$DIFF"; then
  (cd "$SITE" && git -c safe.directory='*' apply --include='vllm/*' "$DIFF") >> "$O/apply.log" 2>&1 || apply=failed
fi
kv apply "$apply"
applied=$(hashes "$S" "$O/applied-sha256.txt")
kv applied_identity "$applied"
[ "$apply" != failed ] && [ "$applied" = ok ] || { step "the tree is not the pinned $S tree"; kv ended "$(date +%s)"; exit 3; }

# The kda.py Python imports from the directory pytest runs in, and which of the two lines it holds.
(cd "$W" && python3 -c "import $KDA_MOD as m; print(m.__file__)") > "$O/kda-file.txt" 2> "$O/kda-file.err"
KF=$(tail -n 1 "$O/kda-file.txt")
kv kda_file "${KF:-unread}"
grep -nxF "$FIX_LINE" "$KF" > "$O/fix-grep.txt" 2>&1
kv fix_grep_rc "$?"
grep -nxF "$BUG_LINE" "$KF" > "$O/bug-grep.txt" 2>&1
kv bug_grep_rc "$?"
step "kda.py imported from ${KF:-unread}; fix line: $(head -c 200 "$O/fix-grep.txt" | tr '\n' ' '); bug line: $(head -c 200 "$O/bug-grep.txt" | tr '\n' ' ')"

kv pytest_args "${SELECT[*]}"
step "pytest: ${SELECT[*]}"
(cd "$W" && timeout --kill-after=10 "$PYTEST_S" python3 -m pytest "${SELECT[@]}" -rA -p no:cacheprovider \
  --junitxml="$O/test.xml" > "$O/test.log" 2>&1)
kv test_rc "$?"
grep -E '^(PASSED|FAILED|ERROR|SKIPPED|XFAIL|XPASS) |^=+ .*(passed|failed|error|skipped|deselected).* =+$' "$O/test.log" > "$O/test-lines.txt"
step "pytest exited $(grep '^test_rc=' "$O/state.txt" | cut -d= -f2): $(tail -n 1 "$O/test-lines.txt")"
kv ended "$(date +%s)"
exit 0
