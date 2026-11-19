#!/bin/bash
# Shared by state.sh, kda-state.sh and stride-state.sh, which source it inside a fresh container of the pinned vLLM CI image.
# It records and does not judge: verdict.py, kda-verdict.py and stride-verdict.py read what it leaves.
# The image installs the wheel at SITE, copies the checkout's vllm/v1 over it, and moves the checkout's vllm/ away.
# So Python imports the package from SITE, and pytest runs the checkout's tests from W.
# These four paths are the only container paths here, so the offline test moves the scripts onto a fake tree by rewriting them alone.
SITE=/usr/local/lib/python3.12/dist-packages
W=/vllm-workspace
OUT_ROOT=/out
WHEEL_SHA_FILE=/tmp/vllm-wheel.sha256
# The inputs sit beside this file, read-only.
IN=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# Progress goes to stderr, because hashes() and imported() are captured and their stdout is their answer.
step() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $NAME: $*" | tee -a "$O/steps.log" >&2; }
kv() { echo "$1=$2" >> "$O/state.txt"; }
# refuse WHY: stop before running anything, since a run on a tree other than the pinned one is void.
refuse() { step "$1"; kv ended "$(date +%s)"; exit 3; }
finish() { kv ended "$(date +%s)"; exit 0; }

# begin NAME: a fresh record directory /out/NAME, with what the image is.
begin() {
  NAME=$1
  O=$OUT_ROOT/$NAME
  mkdir -p "$O"
  : > "$O/state.txt"
  kv started "$(date +%s)"
  # The image's checkout keeps its .git, whose HEAD names the commit the tests come from.
  kv checkout_head "$(git -c safe.directory='*' -C "$W" rev-parse HEAD 2>/dev/null || echo unread)"
  {
    python3 -c 'import importlib.metadata as m; print("vllm_version=" + m.version("vllm"))'
    python3 -c 'import torch, triton; print("torch=" + torch.__version__); print("triton=" + triton.__version__); print("capability=%d.%d" % torch.cuda.get_device_capability())'
    echo "wheel_sha256_file=$(tr -s '[:space:]' ' ' < "$WHEEL_SHA_FILE" 2>/dev/null)"
    env | grep -E '^(VLLM_|CUDA_VERSION|HF_)' | sort
  } > "$O/versions.txt" 2>&1
}

# A path under vllm/ is the installed package's; every other path is the checkout's.
root_of() { case $1 in vllm/*) echo "$SITE" ;; *) echo "$W" ;; esac; }
# hashes STATE PINS OUTFILE: hash every pinned path where Python and pytest read it, and compare with the pins for STATE.
# A pin of "absent" holds only while the file does not exist, which is how a new test is pinned where it is not yet added.
# Every state pins the same seven files, so a pins file that is missing, unreadable or short for STATE is refused rather than checking fewer.
PINNED_PATHS=7
hashes() {
  local want=$1 pins=$2 out=$3 ok=ok st sum p have n
  : > "$out"
  n=$(awk -v s="$want" '$1 == s {print $3}' "$pins" 2>/dev/null | sort -u | wc -l)
  [ -r "$pins" ] && [ "$n" = "$PINNED_PATHS" ] || { step "$pins names $n file(s) for $want, not $PINNED_PATHS"; ok=bad; }
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
  done < "$pins"
  echo "$ok"
}

# prepare PINS STATE DIFF: the commit's tree checked, DIFF applied, and the result checked against STATE's pins.
# A fresh container is the reset, and the pins name all three items' files, so neither another state's edits nor another item's fix can be here.
prepare() {
  local pins=$1 st=$2 diff=$3 base applied apply=ok
  sha256sum "$diff" > "$O/diff.sha256"
  kv diff_sha256 "$(cut -d' ' -f1 "$O/diff.sha256")"
  base=$(hashes base "$pins" "$O/base-sha256.txt")
  kv base_identity "$base"
  [ "$base" = ok ] || refuse "the image's files are not the commit's; nothing applied"
  # The checkout part goes to the checkout and the package part to the installed package.
  # The image's checkout is a git repository, and safe.directory keeps git from refusing it over ownership.
  (cd "$W" && git -c safe.directory='*' apply --exclude='vllm/*' "$diff") > "$O/apply.log" 2>&1 || apply=failed
  if grep -q '^diff --git a/vllm/' "$diff"; then
    (cd "$SITE" && git -c safe.directory='*' apply --include='vllm/*' "$diff") >> "$O/apply.log" 2>&1 || apply=failed
  fi
  kv apply "$apply"
  applied=$(hashes "$st" "$pins" "$O/applied-sha256.txt")
  kv applied_identity "$applied"
  [ "$apply" = ok ] && [ "$applied" = ok ] || refuse "the tree is not the pinned $st tree"
}

# imported MOD KEY: the file Python imports MOD from, run from the directory pytest runs in, recorded as KEY and printed.
imported() {
  local f
  (cd "$W" && python3 -c "import $1 as m; print(m.__file__)") > "$O/$2.txt" 2> "$O/$2.err"
  f=$(tail -n 1 "$O/$2.txt")
  kv "$2" "${f:-unread}"
  echo "$f"
}

# q ARG...: the arguments as one line a reader can paste into a shell, quoting only those that need it.
q() {
  local a out=""
  for a in "$@"; do
    if [[ $a =~ ^[A-Za-z0-9_./:=@%+,-]+$ ]]; then out+="$a "; else out+="'${a//\'/\'\\\'\'}' "; fi
  done
  echo "${out% }"
}

# pytest_run KEY BOUND ARGS...: one pytest call, bounded inside the container, under the runner's bound on the container itself.
# The PRs quote these records, so the exact command, the exit, the summary line and the junit are each kept under KEY.
pytest_run() {
  local key=$1 bound=$2 rc summary
  shift 2
  local cmd=(timeout --kill-after=10 "$bound" python3 -m pytest "$@" -rA -p no:cacheprovider --junitxml="$O/$key.xml")
  kv "${key}_cmd" "cd $W && $(q "${cmd[@]}")"
  step "pytest $key: $(q "$@")"
  (cd "$W" && "${cmd[@]}" > "$O/$key.log" 2>&1)
  rc=$?
  kv "${key}_rc" "$rc"
  # pytest's last line, e.g. `==== 2 failed in 3.21s ====`, which a long run follows with its h:mm:ss.
  summary=$(grep -E '^=+ .* in [0-9.]+s( \([0-9:]+\))? =+$' "$O/$key.log" | tail -n 1)
  kv "${key}_summary" "$summary"
  grep -E '^(PASSED|FAILED|ERROR|SKIPPED|XFAIL|XPASS) ' "$O/$key.log" > "$O/$key-lines.txt"
  step "pytest $key exited $rc: ${summary:-no summary line}"
}
