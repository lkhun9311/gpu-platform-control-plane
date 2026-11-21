#!/bin/bash
# #68414's one state in run 2, run by hack/vllm-gdn-68414/runner.sh inside a fresh container of the pinned vLLM CI image.
# Run 3 neither ships nor runs it, and it stays as run 2 ran it.
# lib.sh now pins eight files on run 3's image, so this state would refuse its seven-file pins.txt rather than run on a tree it was not pinned for.
#
#   state.sh after <repro seconds> <unit-test seconds>
#
# Run 1 (hack/vllm-gdn-68414/runs/2026-11-19-run1-spot-reclaimed) recorded BEFORE on this image: 70 unwritten rows and a NaN state error.
# So run 2 runs AFTER only, with the final diff, whose repeat_interleave now takes output_size.
# /in holds fix.diff, kernel_repro.py, run_repro.py and pins.txt, read-only; /out/gdn-after receives the record.
# This script records and does not judge: hack/vllm-gdn-68414/verdict.py reads what it leaves.
set -u
. "$(dirname "$0")/lib.sh"
S=$1
REPRO_S=$2
UNIT_S=$3
[ "$S" = after ] || { echo "unknown state $S; #68414 runs AFTER only" >&2; exit 4; }
# The reporter's script, byte for byte; hack/vllm-gdn-68414-session-test.sh holds this equal to the session's pin.
REPRO_SHA256=766ccd795b2e1f71ba9c48dc99e22deec8f17047467b70866acf7378310af3af
INDEX_MOD=vllm.third_party.flash_linear_attention.ops.index
FIX_LINE='seq_ids = torch.repeat_interleave('
# The line the final diff adds over the one run 1 tested, so an index.py from the earlier diff fails the import check.
OUTSIZE_LINE='output_size=indices.numel(),'
BUG_LINE='indices.eq(0).cumsum(0) - 1'
UNIT_TEST=tests/kernels/fla/test_chunk_indices.py

begin gdn-after
kv repro_sha256 "$(sha256sum "$IN/kernel_repro.py" | cut -d' ' -f1)"
[ "$(grep '^repro_sha256=' "$O/state.txt" | cut -d= -f2)" = "$REPRO_SHA256" ] ||
  refuse "kernel_repro.py is not the pinned $REPRO_SHA256; nothing runs"
prepare "$IN/pins.txt" after "$IN/fix.diff"

# The file Python imports from the directory everything runs in, and which of the three lines it holds.
IF=$(imported "$INDEX_MOD" index_file)
grep -nF "$FIX_LINE" "$IF" > "$O/fix-grep.txt" 2>&1
kv fix_grep_rc "$?"
grep -nF "$OUTSIZE_LINE" "$IF" > "$O/outsize-grep.txt" 2>&1
kv outsize_grep_rc "$?"
grep -nF "$BUG_LINE" "$IF" > "$O/bug-grep.txt" 2>&1
kv bug_grep_rc "$?"
step "index.py imported from ${IF:-unread}; fix line: $(head -c 200 "$O/fix-grep.txt" | tr '\n' ' '); output_size: $(head -c 200 "$O/outsize-grep.txt" | tr '\n' ' '); bug line: $(head -c 200 "$O/bug-grep.txt" | tr '\n' ' ')"

# Run 1 answered through the wrapper in both states, because kernel_repro.py's CPU tensors cannot reach Triton as-is.
# So run 2 goes to the wrapper directly, which checks the file's sha256, sets CUDA as torch's default device and executes it unchanged.
step "kernel_repro.py through run_repro.py, with CUDA as the default device"
(cd "$W" && timeout --kill-after=10 "$REPRO_S" python3 "$IN/run_repro.py" "$IN/kernel_repro.py" "$REPRO_SHA256") > "$O/repro-cuda.log" 2>&1
kv repro_cuda_rc "$?"
kv repro_mode cuda-default
kv repro_index_file "$(grep '^REPRO_INDEX_FILE=' "$O/repro-cuda.log" | tail -n 1 | cut -d= -f2-)"
# The repro's answer is its one printed line, and a run that printed none has no answer.
line=$(grep -E '^unwritten ' "$O/repro-cuda.log" | tail -n 1)
kv repro_line "$line"
step "kernel_repro.py: ${line:-no result}"

# The new test is CPU-only, so its result is recorded beside the repro's and never decides it.
kv pytest_args "$UNIT_TEST"
pytest_run unit "$UNIT_S" "$UNIT_TEST"
finish
