#!/bin/bash
# One state of oss/vllm/68548-tpot/vllm-tpot-session.sh, run inside a fresh container of the pinned vLLM CI image.
#
#   state.sh <before|after> <tpot pytest seconds> [<whole-file pytest seconds>]
#
# /in holds the two diffs and pins.txt, read-only; /out/<state> receives the record.
# This script records and does not judge: oss/vllm/68548-tpot/verdict.py reads what it leaves.
# It stops before pytest only when the tree it would test is not the one pinned, since a run on any other tree is void.
set -u
S=$1
TPOT_S=$2
FILE_S=${3:-0}
case $S in
  before) DIFF=/in/serving-test-only.diff ;;
  after) DIFF=/in/fix.diff ;;
  *) echo "unknown state $S" >&2; exit 4 ;;
esac
# The image installs the wheel here, then copies the checkout's vllm/v1 over it, and moves the checkout's vllm/ away.
# So Python imports the package from SITE, and the checkout keeps only tests, docs, examples and rust.
SITE=/usr/local/lib/python3.12/dist-packages
W=/vllm-workspace
O=/out/$S
mkdir -p "$O"
# Progress goes to stderr, because hashes() is captured and its stdout is its answer.
step() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $S: $*" | tee -a "$O/steps.log" >&2; }
kv() { echo "$1=$2" >> "$O/state.txt"; }
: > "$O/state.txt"
kv started "$(date +%s)"

# A path under vllm/ is the installed package's; every other path is the checkout's.
root_of() { case $1 in vllm/*) echo "$SITE" ;; *) echo "$W" ;; esac; }
# hashes STATE OUTFILE: hash every pinned path where Python and pytest read it, and compare with the pins for STATE.
hashes() {
  local want=$1 out=$2 ok=ok st sum p have
  : > "$out"
  while read -r st sum p; do
    [ "$st" = "$want" ] || continue
    have=$(sha256sum "$(root_of "$p")/$p" 2>/dev/null | cut -d' ' -f1)
    echo "${have:-missing}  $(root_of "$p")/$p" >> "$out"
    [ "$have" = "$sum" ] || { step "$p is ${have:-missing}, not the pinned $want $sum"; ok=bad; }
  done < /in/pins.txt
  echo "$ok"
}

sha256sum "$DIFF" > "$O/diff.sha256"
# The image's checkout keeps its .git, whose HEAD names the commit the tests come from.
kv checkout_head "$(git -c safe.directory='*' -C "$W" rev-parse HEAD 2>/dev/null || echo unread)"
kv diff_sha256 "$(cut -d' ' -f1 "$O/diff.sha256")"
{
  python3 -c 'import importlib.metadata as m; print("vllm_version=" + m.version("vllm"))'
  echo "wheel_sha256_file=$(tr -s '[:space:]' ' ' < /tmp/vllm-wheel.sha256 2>/dev/null)"
  env | grep -E '^(VLLM_|CUDA_VERSION|HF_)' | sort
} > "$O/versions.txt" 2>&1

# A fresh container is the reset: every file either diff touches must be the commit's before anything is applied.
base=$(hashes base "$O/base-sha256.txt")
kv base_identity "$base"
[ "$base" = ok ] || { step "the image's files are not the commit's; nothing applied"; kv ended "$(date +%s)"; exit 3; }

# The checkout part goes to the checkout and the package part to the installed package Python imports.
# The image's checkout is a git repository, and safe.directory keeps git from refusing it over ownership.
apply=ok
(cd "$W" && git -c safe.directory='*' apply --exclude='vllm/*' "$DIFF") > "$O/apply.log" 2>&1 || apply=failed
if grep -q '^diff --git a/vllm/' "$DIFF"; then
  (cd "$SITE" && git -c safe.directory='*' apply --include='vllm/*' "$DIFF") >> "$O/apply.log" 2>&1 || apply=failed
fi
kv apply "$apply"
applied=$(hashes "$S" "$O/applied-sha256.txt")
kv applied_identity "$applied"
[ "$apply" = ok ] && [ "$applied" = ok ] || { step "the diff did not apply to the pinned result"; kv ended "$(date +%s)"; exit 3; }

# The file Python imports from the directory pytest runs in, and whether it carries the fix.
(cd "$W" && python3 -c "import vllm.v1.metrics.loggers as l; print(l.__file__)") > "$O/loggers-file.txt" 2> "$O/loggers-file.err"
LF=$(tail -n 1 "$O/loggers-file.txt")
kv loggers_file "${LF:-unread}"
grep -n 'num_generation_tokens > 1' "$LF" > "$O/grep.txt" 2>&1
kv grep_rc "$?"
step "loggers imported from ${LF:-unread}; fix line: $(head -c 200 "$O/grep.txt" | tr '\n' ' ')"

# pytest's own bound sits inside the container, under the runner's bound on the container itself.
runpy() {
  local name=$1 bound=$2; shift 2
  step "pytest $name: $*"
  (cd "$W" && timeout --kill-after=10 "$bound" python3 -m pytest "$@" -rA -p no:cacheprovider \
    --junitxml="$O/$name.xml" > "$O/$name.log" 2>&1)
  local rc=$?
  kv "${name}_rc" "$rc"
  grep -E '^(PASSED|FAILED|ERROR|SKIPPED|XFAIL|XPASS) |^=+ .*(passed|failed|error).* =+$' "$O/$name.log" > "$O/$name-lines.txt"
  step "pytest $name exited $rc: $(tail -n 1 "$O/$name-lines.txt")"
}
runpy tpot "$TPOT_S" -x tests/entrypoints/serve/instrumentator/test_metrics.py -k "tpot_skips and text"
# The whole file is run only once the fix has passed its own test, since it cannot change a failed answer.
[ "$S" = after ] && grep -qx 'tpot_rc=0' "$O/state.txt" && runpy file "$FILE_S" tests/entrypoints/serve/instrumentator/test_metrics.py -k text
kv ended "$(date +%s)"
exit 0
