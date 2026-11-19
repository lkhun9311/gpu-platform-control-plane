#!/bin/bash
# Shared by the state scripts, which source it inside a fresh container of the pinned vLLM CI image.
# Run 4 ships only stride-state.sh; state.sh (#68414, run 2) and kda-state.sh (#68415, run 3) stay as they ran and are not shipped.
# It records and does not judge: kda-verdict.py and stride-verdict.py read what it leaves.
# The image installs the wheel at SITE, copies the checkout's vllm/v1 over it, and moves the checkout's vllm/ away.
# So Python imports the package from SITE, and pytest runs the checkout's tests from W.
# These four paths are the only container paths here, so the offline test moves the scripts onto a fake tree by rewriting them alone.
SITE=/usr/local/lib/python3.12/dist-packages
W=/vllm-workspace
OUT_ROOT=/out
WHEEL_SHA_FILE=/tmp/vllm-wheel.sha256
# The inputs sit beside this file, read-only.
IN=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# Progress goes to stderr, because hashes() is captured and its stdout is its answer.
step() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $NAME: $*" | tee -a "$O/steps.log" >&2; }
kv() { echo "$1=$2" >> "$O/state.txt"; }
# refuse WHY: stop before running anything, since a run on a tree other than the pinned one is void.
refuse() { step "$1"; kv ended "$(date +%s)"; exit 3; }
finish() { kv ended "$(date +%s)"; exit 0; }

# q ARG...: the arguments as one line a reader can paste into a shell, quoting only those that need it.
q() {
  local a out=""
  for a in "$@"; do
    if [[ $a =~ ^[A-Za-z0-9_./:=@%+,-]+$ ]]; then out+="$a "; else out+="'${a//\'/\'\\\'\'}' "; fi
  done
  echo "${out% }"
}

# begin NAME: a fresh record directory /out/NAME, with what the image is and what runs the tests.
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
  # The PRs quote which interpreter and GPU ran the tests, so each is read from the process that runs them.
  kv python3_path "$(command -v python3 || echo unread)"
  kv python_executable "$(python3 -c 'import sys; print(sys.executable)' 2>> "$O/versions.txt" || echo unread)"
  kv python_version "$(python3 -c 'import sys; print(sys.version.split()[0])' 2>> "$O/versions.txt" || echo unread)"
  kv pytest_version "$(python3 -m pytest --version 2>&1 | grep -m1 -oE 'pytest [0-9][^ ]*' || echo unread)"
  kv gpu_name "$(python3 -c 'import torch; print(torch.cuda.get_device_name(0))' 2>> "$O/versions.txt" | tail -n 1 || echo unread)"
}

# A path under vllm/ is the installed package's; every other path is the checkout's.
root_of() { case $1 in vllm/*) echo "$SITE" ;; *) echo "$W" ;; esac; }
# hashes STATE PINS OUTFILE: hash every pinned path where Python and pytest read it, and compare with the pins for STATE.
# A pin of "absent" holds only while the file does not exist, which is how a new test is pinned where it is not yet added.
# Every state pins the same eight files, so a pins file that is missing, unreadable or short for STATE is refused rather than checking fewer.
PINNED_PATHS=8
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

# apply_part KEY DIR FILTER DIFF: one git apply in DIR limited by FILTER, recorded as the exact command and the files it changed.
# The image's checkout is a git repository, and safe.directory keeps git from refusing it over ownership.
apply_part() {
  local key=$1 dir=$2 filter=$3 diff=$4
  local cmd=(git -c safe.directory='*' apply "$filter" "$diff")
  kv "${key}_cmd" "cd $dir && $(q "${cmd[@]}")"
  # --numstat lists what the same filter selects without applying it, so the record names every target path.
  kv "${key}_files" "$(cd "$dir" && git -c safe.directory='*' apply --numstat "$filter" "$diff" 2>/dev/null | awk -v d="$dir" '{printf "%s%s/%s", (n++ ? "," : ""), d, $3}')"
  (cd "$dir" && "${cmd[@]}") >> "$O/apply.log" 2>&1
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
  : > "$O/apply.log"
  # The checkout part goes to the checkout and the package part to the installed package.
  apply_part apply_checkout "$W" --exclude='vllm/*' "$diff" || apply=failed
  if grep -q '^diff --git a/vllm/' "$diff"; then
    apply_part apply_site "$SITE" --include='vllm/*' "$diff" || apply=failed
  else
    kv apply_site_cmd "none: the diff changes nothing under vllm/"
  fi
  kv apply "$apply"
  applied=$(hashes "$st" "$pins" "$O/applied-sha256.txt")
  kv applied_identity "$applied"
  [ "$apply" = ok ] && [ "$applied" = ok ] || refuse "the tree is not the pinned $st tree"
}

# imports KEY=MOD[:ATTR]...: the file Python imports each MOD from, run from the directory pytest runs in, recorded as KEY.
# With :ATTR it is the file ATTR's source is in, which for a Triton kernel is its innermost wrapped function's.
# One process imports them all, because each vLLM import costs seconds.
imports() {
  local spec key f
  (cd "$W" && python3 - "$@" <<'PY'
import importlib, inspect, sys
for spec in sys.argv[1:]:
    key, mod = spec.split("=", 1)
    try:
        mod, _, attr = mod.partition(":")
        m = importlib.import_module(mod)
        if attr:
            obj = getattr(m, attr)
            # triton.heuristics wraps triton.jit, which wraps the function, and each keeps what it wraps in .fn.
            while hasattr(obj, "fn"):
                obj = obj.fn
            f = inspect.getsourcefile(obj)
        else:
            f = m.__file__
    except Exception as e:
        print(f"{key}: {type(e).__name__}: {e}", file=sys.stderr)
        f = "unread"
    # vLLM may log to stdout, so the answer carries a prefix that a log line will not.
    print(f"IMPORTED {key}={f}")
PY
  ) > "$O/imports.txt" 2> "$O/imports.err"
  for spec in "$@"; do
    key=${spec%%=*}
    f=$(sed -n "s/^IMPORTED $key=//p" "$O/imports.txt" | tail -n 1)
    kv "$key" "${f:-unread}"
  done
}
# file_of KEY: a path imports() recorded.
file_of() { sed -n "s/^$1=//p" "$O/state.txt" | tail -n 1; }

# probe BOUND ARGS...: every vllm and tests file a pytest collection of ARGS loads, and which of them differ from the item's diff base.
# The collection imports what the run imports at import time, conftest files included, with the selection the run uses.
# PROBE_DIFFERS lists the files that differ between the image's commit and the item's diff base, derived from git by derive-pins.sh.
probe() {
  local bound=$1 hits
  shift
  (cd "$W" && PYTHONPATH="$IN${PYTHONPATH:+:$PYTHONPATH}" FLA_LOADED_OUT="$O/loaded-modules.txt" FLA_LOADED_ROOTS="$SITE:$W" \
    timeout --kill-after=10 "$bound" python3 -m pytest --collect-only -q -p fla_loaded_modules -p no:cacheprovider "$@" > "$O/probe.log" 2>&1)
  kv probe_rc "$?"
  kv loaded_count "$(wc -l < "$O/loaded-modules.txt" 2>/dev/null || echo 0)"
  if [ ! -r "$PROBE_DIFFERS" ]; then
    kv loaded_differs "unread: $PROBE_DIFFERS"
    return
  fi
  hits=$(awk '{print $2}' "$O/loaded-modules.txt" 2>/dev/null | grep -Fxf "$PROBE_DIFFERS" | paste -sd, -)
  kv loaded_differs "${hits:-none}"
  step "the collection loaded $(wc -l < "$O/loaded-modules.txt" 2>/dev/null || echo 0) vllm and tests file(s); of those that differ from the diff base: ${hits:-none}"
}

# pytest_run KEY BOUND ARGS...: one pytest call, bounded inside the container, under the runner's bound on the container itself.
# The PRs quote these records, so the exact command, the exit, the summary line and the junit are each kept under KEY.
# --tb=short puts each failure's source line and its E lines in the junit, which is where the summary reads them per case.
pytest_run() {
  local key=$1 bound=$2 rc summary
  shift 2
  local cmd=(timeout --kill-after=10 "$bound" python3 -m pytest "$@" -rA --tb=short -p no:cacheprovider --junitxml="$O/$key.xml")
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
