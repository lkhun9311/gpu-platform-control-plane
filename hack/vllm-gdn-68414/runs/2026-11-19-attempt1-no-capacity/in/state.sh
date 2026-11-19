#!/bin/bash
# One state of hack/vllm-gdn-68414-session.sh, run inside a fresh container of the pinned vLLM CI image.
#
#   state.sh before <as-is seconds> <cuda-default seconds>
#   state.sh after <as-is seconds> <cuda-default seconds> <new-test seconds> <existing-test seconds>
#
# /in holds fix.diff, kernel_repro.py, run_repro.py and pins.txt, read-only; /out/<state> receives the record.
# This script records and does not judge: hack/vllm-gdn-68414/verdict.py reads what it leaves.
# It stops before any run only when the tree it would run on is not the one pinned, since a run on any other tree is void.
set -u
S=$1
ASIS_S=$2
CUDA_S=$3
UNIT_S=${4:-0}
EXIST_S=${5:-0}
case $S in
  before) DIFF="" ;;
  after) DIFF=/in/fix.diff ;;
  *) echo "unknown state $S" >&2; exit 4 ;;
esac
# The reporter's script, byte for byte; hack/vllm-gdn-68414-session-test.sh holds this equal to the session's pin.
REPRO_SHA256=766ccd795b2e1f71ba9c48dc99e22deec8f17047467b70866acf7378310af3af
# The image installs the wheel here, then copies the checkout's vllm/v1 over it, and moves the checkout's vllm/ away.
# So Python imports the package from SITE, and the checkout keeps only tests, docs, examples and rust.
SITE=/usr/local/lib/python3.12/dist-packages
W=/vllm-workspace
O=/out/$S
INDEX_MOD=vllm.third_party.flash_linear_attention.ops.index
FIX_LINE='seq_ids = torch.repeat_interleave('
BUG_LINE='indices.eq(0).cumsum(0) - 1'
mkdir -p "$O"
# Progress goes to stderr, because hashes() is captured and its stdout is its answer.
step() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $S: $*" | tee -a "$O/steps.log" >&2; }
kv() { echo "$1=$2" >> "$O/state.txt"; }
: > "$O/state.txt"
kv started "$(date +%s)"

# A path under vllm/ is the installed package's; every other path is the checkout's.
root_of() { case $1 in vllm/*) echo "$SITE" ;; *) echo "$W" ;; esac; }
# hashes STATE OUTFILE: hash every pinned path where Python and pytest read it, and compare with the pins for STATE.
# A pin of "absent" holds only while the file does not exist, which is how the new test is pinned at the commit.
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
  done < /in/pins.txt
  echo "$ok"
}

# The image's checkout keeps its .git, whose HEAD names the commit the tests come from.
kv checkout_head "$(git -c safe.directory='*' -C "$W" rev-parse HEAD 2>/dev/null || echo unread)"
if [ -n "$DIFF" ]; then
  sha256sum "$DIFF" > "$O/diff.sha256"
  kv diff_sha256 "$(cut -d' ' -f1 "$O/diff.sha256")"
else
  kv diff_sha256 none
fi
kv repro_sha256 "$(sha256sum /in/kernel_repro.py | cut -d' ' -f1)"
{
  python3 -c 'import importlib.metadata as m; print("vllm_version=" + m.version("vllm"))'
  python3 -c 'import torch, triton; print("torch=" + torch.__version__); print("triton=" + triton.__version__); print("capability=%d.%d" % torch.cuda.get_device_capability())'
  echo "wheel_sha256_file=$(tr -s '[:space:]' ' ' < /tmp/vllm-wheel.sha256 2>/dev/null)"
  env | grep -E '^(VLLM_|CUDA_VERSION|HF_)' | sort
} > "$O/versions.txt" 2>&1

# A fresh container is the reset: every pinned file must be the commit's before anything is applied.
base=$(hashes base "$O/base-sha256.txt")
kv base_identity "$base"
[ "$base" = ok ] || { step "the image's files are not the commit's; nothing applied"; kv ended "$(date +%s)"; exit 3; }
[ "$(grep '^repro_sha256=' "$O/state.txt" | cut -d= -f2)" = "$REPRO_SHA256" ] ||
  { step "kernel_repro.py is not the pinned $REPRO_SHA256; nothing runs"; kv ended "$(date +%s)"; exit 3; }

# BEFORE applies nothing; AFTER sends the checkout part to the checkout and the package part to the installed package.
# The image's checkout is a git repository, and safe.directory keeps git from refusing it over ownership.
if [ -z "$DIFF" ]; then
  apply=none
else
  apply=ok
  (cd "$W" && git -c safe.directory='*' apply --exclude='vllm/*' "$DIFF") > "$O/apply.log" 2>&1 || apply=failed
  if grep -q '^diff --git a/vllm/' "$DIFF"; then
    (cd "$SITE" && git -c safe.directory='*' apply --include='vllm/*' "$DIFF") >> "$O/apply.log" 2>&1 || apply=failed
  fi
fi
kv apply "$apply"
applied=$(hashes "$S" "$O/applied-sha256.txt")
kv applied_identity "$applied"
[ "$apply" != failed ] && [ "$applied" = ok ] || { step "the tree is not the pinned $S tree"; kv ended "$(date +%s)"; exit 3; }

# The file Python imports from the directory everything runs in, and which of the two lines it holds.
(cd "$W" && python3 -c "import $INDEX_MOD as m; print(m.__file__)") > "$O/index-file.txt" 2> "$O/index-file.err"
IF=$(tail -n 1 "$O/index-file.txt")
kv index_file "${IF:-unread}"
grep -nF "$FIX_LINE" "$IF" > "$O/fix-grep.txt" 2>&1
kv fix_grep_rc "$?"
grep -nF "$BUG_LINE" "$IF" > "$O/bug-grep.txt" 2>&1
kv bug_grep_rc "$?"
step "index.py imported from ${IF:-unread}; fix line: $(head -c 200 "$O/fix-grep.txt" | tr '\n' ' '); bug line: $(head -c 200 "$O/bug-grep.txt" | tr '\n' ' ')"

# The repro's answer is its one printed line, and a run that printed none has no answer.
result_line() { grep -E '^unwritten ' "$1" | tail -n 1; }
# First as the reporter wrote it; its tensors are on the CPU, so on a GPU image this is expected to print nothing.
step "kernel_repro.py as-is"
(cd "$W" && timeout --kill-after=10 "$ASIS_S" python3 /in/kernel_repro.py) > "$O/repro-asis.log" 2>&1
kv repro_asis_rc "$?"
line=$(result_line "$O/repro-asis.log")
if [ -n "$line" ]; then
  kv repro_mode asis
else
  # Then unchanged, with CUDA as the default device, through the wrapper that checks its sha256 first.
  step "kernel_repro.py printed no result as-is ($(tail -n 1 "$O/repro-asis.log" | head -c 200)); running it with CUDA as the default device"
  (cd "$W" && timeout --kill-after=10 "$CUDA_S" python3 /in/run_repro.py /in/kernel_repro.py "$REPRO_SHA256") > "$O/repro-cuda.log" 2>&1
  kv repro_cuda_rc "$?"
  line=$(result_line "$O/repro-cuda.log")
  kv repro_mode cuda-default
  kv repro_index_file "$(grep '^REPRO_INDEX_FILE=' "$O/repro-cuda.log" | tail -n 1 | cut -d= -f2-)"
fi
kv repro_line "$line"
step "kernel_repro.py: ${line:-no result}"

# pytest's own bound sits inside the container, under the runner's bound on the container itself.
runpy() {
  local name=$1 bound=$2; shift 2
  step "pytest $name: $*"
  (cd "$W" && timeout --kill-after=10 "$bound" python3 -m pytest "$@" -rA -p no:cacheprovider \
    --junitxml="$O/$name.xml" > "$O/$name.log" 2>&1)
  local rc=$?
  kv "${name}_rc" "$rc"
  grep -E '^(PASSED|FAILED|ERROR|SKIPPED|XFAIL|XPASS) |^=+ .*(passed|failed|error|skipped).* =+$' "$O/$name.log" > "$O/$name-lines.txt"
  step "pytest $name exited $rc: $(tail -n 1 "$O/$name-lines.txt")"
}
if [ "$S" = after ]; then
  runpy unit "$UNIT_S" tests/kernels/mamba/test_fla_chunk_indices.py
  # Each existing test runs on its own, so a skip's reason is recorded per file.
  for t in core_split:test_gdn_forward_core_split.py rocm_layout:test_gdn_rocm_layout_dispatch.py; do
    if [ -e "$W/tests/kernels/mamba/${t#*:}" ]; then
      runpy "${t%%:*}" "$EXIST_S" "tests/kernels/mamba/${t#*:}"
    else
      kv "${t%%:*}_rc" absent
    fi
  done
fi
kv ended "$(date +%s)"
exit 0
