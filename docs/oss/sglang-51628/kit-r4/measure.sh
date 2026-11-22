#!/bin/bash
# The measurement of the SGLang #51628 kit r4, run inside a fresh container of the pinned SGLang image, once per mode.
#
#   measure.sh prep <in dir> <out dir> <models dir> <src dir> <prep dir> <deadline epoch>
#   measure.sh base|fix <in dir> <out dir> <models dir> <src dir> <prep dir> <deadline epoch> <treecore: rust|python>
#
# run.sh mounts the kit read-only as <in dir>, the arm's SGLang tree as <src dir>, and a host directory shared by the containers as <prep dir>.
# Every record goes to <out dir>; this script records and does not judge, and verdict.py reads what it leaves.
#
# Every mode first installs <src dir> over the image's SGLang (pip install --no-deps -e python) and shows that python imports it from there.
# prep: also downloads the model and builds SGLang's Rust TreeCore extension from <src dir> into <prep dir>.
#   r2's server ran the Rust TreeCore that the image bundles for 03fde9cc; a tree installed over the image has no bundled build,
#   and the image runs with SGLANG_RUST_BUILD_MODE=never, so the server would fall back to the Python TreeCore unless a build is cached.
#   The build runs here, before any arm, so it is in no arm's startup time.
#   If it fails, both arms run the Python TreeCore instead (treecore=python), and the verdict says so.
# base, fix: the positive control of the compile record, the model check, then one server on an empty Triton cache and a fresh HOME,
#   the gate, and the bursts. fix first runs the patch's unit tests, on a Triton cache of their own.
# SGLANG_TRITON_SLOW_COMPILE_THRESHOLD_SECS stays at its default, so SGLang's own warning lines are the reporter's.
set -u
MODE=${1:-}
case "$MODE" in
  prep) [ "$#" = 7 ] || { echo "usage: measure.sh prep <in> <out> <models> <src> <prep> <deadline epoch>" >&2; exit 2; } ;;
  base | fix) [ "$#" = 8 ] || { echo "usage: measure.sh base|fix <in> <out> <models> <src> <prep> <deadline epoch> <treecore: rust|python>" >&2; exit 2; } ;;
  *) echo "measure.sh: the mode '$MODE' is not prep, base or fix" >&2; exit 2 ;;
esac
IN=$2
OUT=$3
MODELS=$4
SRC=$5
PREP=$6
DEADLINE=$7
TREECORE=${8:-}
[[ $DEADLINE =~ ^[0-9]+$ ]] || { echo "measure.sh: the deadline '$DEADLINE' is not an epoch in whole seconds" >&2; exit 2; }
[ "$MODE" = prep ] || case "$TREECORE" in rust | python) ;; *) echo "measure.sh: treecore is '$TREECORE', not rust or python" >&2; exit 2 ;; esac
for d in "$IN" "$OUT" "$MODELS" "$SRC" "$PREP"; do [ -d "$d" ] || { echo "measure.sh: the directory $d must exist" >&2; exit 2; }; done
# The container's scratch root; the offline test moves it, since its fake container is the host.
ROOT=${SGL51628_ROOT:-/opt/sgl51628}
PY=python3
PORT=30000
GRACE_S=15
POLL_S=1
# The model: the smallest NemotronH checkpoint, pinned by revision and by the LFS sha256 of its weights and tokenizer.
MODEL_TAG=nemotron-h-4b-instruct-128k
MODEL_REPO=nvidia/Nemotron-H-4B-Instruct-128K
MODEL_REV=f3c0b6c3b7fcb39e132b6007386e33a586d6e6cb
MODEL_LFS="model-00001-of-00002.safetensors=77ec45e9fe138d04e0e89900ca952d673837984b66f7809c7ed5cb7eb742b611 model-00002-of-00002.safetensors=9377b88ee9b8007cd9b955b5d2d7820b7214799806d96984c1f3126f8b5db13e tokenizer.json=3277c00fe5fb3963b3cb7c07b7f183722d2af4d775a4aea7cfb3684d7cccbc2f"
MDIR=$MODELS/$MODEL_TAG
# The bounds of each step, in seconds.
INSTALL_S=300
SCM_S=120
MODEL_S=600
TREECORE_S=600
PYTEST_S=300
UP_S=900
PROBE_S=300
# The loader asks cargo and rustc for their versions to find a cached build, and falls back to the Python TreeCore when they do not answer.
# The servers run with a fresh HOME, so rustup and cargo are told where the image keeps them: prep reads that from its own environment.
RUST_ENV=(RUSTUP_HOME=/root/.rustup CARGO_HOME=/root/.cargo)
# The patch's unit tests: two CPU tests and one that needs CUDA, so a GPU container must report 3 passed.
TEST_FILE=test/registered/unit/layers/test_mamba2_prefill_prewarm.py
# The bursts: label, concurrency, prompts, seed.
# r2's warmup (64 prompts at concurrency 32) and its three c16 runs with the same seeds; r4 drops r2's c1 and c128 runs.
BURSTS="warmup:32:64:42 c16-r1:16:32:161 c16-r2:16:32:162 c16-r3:16:32:163"
# burst_bound CONCURRENCY: the burst's kill timeout.
burst_bound() { case "$1" in 32) echo 300 ;; *) echo 240 ;; esac; }

step() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) measure $MODE: $*" | tee -a "$OUT/measure-steps.log" >&2; }
kv() { echo "$1=$2" >> "$OUT/measure.txt"; }
now() { date +%s.%N; }
left() { echo $(( DEADLINE - $(date +%s) )); }
# bound N: N, or the time left before the deadline when that is shorter, and at least 1.
bound() { local l; l=$(left); [ "$l" -gt "$1" ] && echo "$1" || echo $(( l > 1 ? l : 1 )); }
: > "$OUT/measure.txt"
kv mode "$MODE"
kv started "$(date +%s)"
kv src "$SRC"
kv bursts "$BURSTS"
kv treecore_arg "${TREECORE:-none}"

{
  $PY -c 'import importlib.metadata as m; print("image_sglang=" + m.version("sglang"))'
  $PY -c 'import triton; print("triton=" + triton.__version__)'
  timeout 120 $PY -c 'import torch; print("torch=" + torch.__version__); print("cuda=" + str(torch.version.cuda)); print("gpu=" + torch.cuda.get_device_name(0))'
  $PY -m pip --version
  env | command grep -E '^(SGLANG_|CUDA_VERSION|TRITON)' | sort
} > "$OUT/versions.txt" 2>&1
kv image_build_commit "${SGLANG_BUILD_COMMIT:-unset}"
kv gpu_name "$(nvidia-smi --query-gpu=name --format=csv,noheader | head -n 1)"

# ---------------------------------------------------------------- the tree, installed over the image's SGLang
# setuptools-scm reads the version; with --no-build-isolation pip uses the image's own build tools rather than downloading torch for a build env.
if ! $PY -c 'import setuptools_scm' 2>>"$OUT/install.log"; then
  step "setuptools-scm is not in the image; installing the pinned one"
  timeout --kill-after=10 "$(bound $SCM_S)" $PY -m pip install --no-deps setuptools-scm==8.3.1 >> "$OUT/install.log" 2>&1
  kv scm_install_rc "$?"
fi
step "pip install --no-deps -e python from $SRC"
# SGLANG_BUILD_RUST_EXTS=none: the Rust extensions are not built by pip; the one the server needs is built by prep, below.
# The pretend version replaces git describe, which a depth-1 fetch cannot answer.
( cd "$SRC" && SGLANG_BUILD_RUST_EXTS=none SETUPTOOLS_SCM_PRETEND_VERSION_FOR_SGLANG=0.0.0.dev1+gcb337923 \
  timeout --kill-after=10 "$(bound $INSTALL_S)" $PY -m pip install --no-deps --no-build-isolation -e python ) >> "$OUT/install.log" 2>&1
kv install_rc "$?"
# Read from / so that the current directory cannot supply a package of the same name.
sglang_dir=$(cd / && $PY -c 'import os, sglang; print(os.path.realpath(os.path.dirname(sglang.__file__)))' 2>>"$OUT/install.log")
kv sglang_dir "${sglang_dir:-unread}"
kv sglang_version "$(cd / && $PY -c 'import importlib.metadata as m; print(m.version("sglang"))' 2>>"$OUT/install.log")"
want_dir=$(realpath "$SRC/python/sglang")
if [ "$sglang_dir" != "$want_dir" ]; then
  step "python imports sglang from '${sglang_dir:-nowhere}', not $want_dir; nothing runs on it"
  kv stopped install
  exit 3
fi
kv install ok

# ---------------------------------------------------------------- the model
verify_model() {
  local model=ok w f s have
  ( cd "$MDIR" && find . -type f -not -path './.cache/*' -printf '%s %p\n' | sort -k2 ) > "$OUT/model-files.txt" 2>&1
  for w in $MODEL_LFS; do
    f=${w%%=*}; s=${w#*=}
    have=$(sha256sum "$MDIR/$f" 2>>"$OUT/model.log" | cut -d' ' -f1)
    kv "sha256_$f" "${have:-absent}"
    # The offline test's fake checkpoint cannot carry the real hashes, so it records the check as skipped.
    if [ "${SGL51628_OFFLINE_TEST:-}" = 1 ]; then [ -n "$have" ] || model=bad; continue; fi
    [ "$have" = "$s" ] || { model=bad; step "$f is ${have:-absent}, not $s"; }
  done
  [ "${SGL51628_OFFLINE_TEST:-}" = 1 ] && kv model_hash_check "skipped (offline test)"
  kv model_repo "$MODEL_REPO"
  kv model_revision "$MODEL_REV"
  kv model "$model"
  [ "$model" = ok ]
}

if [ "$MODE" = prep ]; then
  step "download $MODEL_REPO at $MODEL_REV"
  mkdir -p "$MDIR"
  pats="'*.json', '*.py', '*.safetensors', '*.jinja'"
  timeout --kill-after=10 "$(bound $MODEL_S)" $PY -c "
from huggingface_hub import snapshot_download
print(snapshot_download('$MODEL_REPO', revision='$MODEL_REV', local_dir='$MDIR', allow_patterns=[$pats]))
" > "$OUT/model.log" 2>&1
  kv download_rc "$?"
  verify_model || { kv stopped model; exit 3; }
  # The TreeCore build, with the loader's own source build (mode auto) into a cache the arms copy from.
  step "build the Rust TreeCore extension from $SRC"
  rm -rf "$PREP/sglang-cache"
  RUST_ENV=("RUSTUP_HOME=${RUSTUP_HOME:-$(rustup show home 2>/dev/null || echo "$HOME/.rustup")}" "CARGO_HOME=${CARGO_HOME:-$HOME/.cargo}")
  printf '%s\n' "${RUST_ENV[@]}" > "$PREP/rust-env.txt"
  kv rust_env "${RUST_ENV[*]}"
  ( cd / && env "${RUST_ENV[@]}" SGLANG_RUST_BUILD_MODE=auto SGLANG_CACHE_DIR="$PREP/sglang-cache" \
    timeout --kill-after=10 "$(bound $TREECORE_S)" $PY -c 'import sglang.srt.mem_cache.rust_tree_core.extension as e; print("treecore_build=ok", e.bindings)' ) \
    > "$OUT/treecore-build.log" 2>&1
  rc=$?
  kv treecore_build_rc "$rc"
  built=$(find "$PREP/sglang-cache/rust_extensions/artifacts" -type f -name 'mem_cache*' 2>/dev/null | head -n 1)
  if [ "$rc" = 0 ] && [ -n "$built" ]; then
    kv treecore rust
    kv treecore_artifact "$built"
  else
    # Both arms then run the Python TreeCore; the verdict reports it as a departure from r2, which ran the Rust one.
    kv treecore python
    kv treecore_fallback "the build exited $rc$([ -n "$built" ] || echo ' and left no artifact'); see treecore-build.log"
  fi
  kv pytest_in_image "$($PY -m pytest --version 2>&1 | head -n 1)"
  kv prep ok
  kv ended "$(date +%s)"
  exit 0
fi

# ---------------------------------------------------------------- an arm: the compile record, installed and shown to fire
# The same rustup and cargo the prep built with, so the loader's fingerprint of the toolchain matches the cached build.
[ -f "$PREP/rust-env.txt" ] && mapfile -t RUST_ENV < "$PREP/rust-env.txt"
kv rust_env "${RUST_ENV[*]}"
# A .pth line that starts with "import" runs at every interpreter start, so the hook is in the scheduler before SGLang installs its own watch.
SITE=$($PY -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')
mkdir -p "$ROOT/hook" || { step "cannot create $ROOT/hook"; exit 3; }
cp "$IN/sgl51628_compile_hook.py" "$ROOT/hook/" || { step "cannot copy the hook"; exit 3; }
echo "import sys; sys.path.append('$ROOT/hook'); import sgl51628_compile_hook" > "$SITE/sgl51628_compile_hook.pth" || { step "cannot write the .pth into $SITE"; exit 3; }
kv hook_pth "$SITE/sgl51628_compile_hook.pth"
rm -rf "$ROOT/probe-triton"; mkdir -p "$ROOT/probe-triton"
step "probe: two fresh kernels must each leave a compile record"
( cd / && SGL51628_COMPILE_LOG="$OUT/probe-compiles.jsonl" TRITON_CACHE_DIR="$ROOT/probe-triton" SGLANG_TRITON_SLOW_COMPILE_THRESHOLD_SECS=0 \
  timeout "$(bound $PROBE_S)" $PY "$IN/probe_hook.py" "$OUT/probe-compiles.jsonl" ) > "$OUT/probe-hook.log" 2>&1
kv probe_rc "$?"
probe=ok
command grep -qx 'probe_hook=ok' "$OUT/probe-hook.log" || probe=bad
command grep -qE "Triton kernel '_sgl51628_probe_b' took [0-9.]+ s to compile after serving started" "$OUT/probe-hook.log" || probe=bad
kv probe_hook "$probe"
if [ "$probe" != ok ]; then
  step "the compile record was not shown to fire; no server is started, since silence could not be told from nothing compiled"
  kv stopped probe
  exit 3
fi
verify_model || { kv stopped model; exit 3; }

# ---------------------------------------------------------------- FIX only: the patch's unit tests, before the server
if [ "$MODE" = fix ]; then
  if ! $PY -m pytest --version > "$OUT/pytest-version.txt" 2>&1; then
    step "pytest is not in the image; installing the pinned one"
    timeout --kill-after=10 "$(bound $SCM_S)" $PY -m pip install pytest==8.3.5 >> "$OUT/pytest-install.log" 2>&1
    kv pytest_install_rc "$?"
    $PY -m pytest --version > "$OUT/pytest-version.txt" 2>&1
  fi
  # The tests autotune on the GPU, so they get their own Triton cache and HOME, and the server's cache stays empty.
  rm -rf "$ROOT/pytest-triton" "$ROOT/pytest-home"; mkdir -p "$ROOT/pytest-triton" "$ROOT/pytest-home"
  step "python -m pytest $TEST_FILE -q"
  ( cd "$SRC" && HOME="$ROOT/pytest-home" TRITON_CACHE_DIR="$ROOT/pytest-triton" timeout --kill-after=10 "$(bound $PYTEST_S)" \
    $PY -m pytest "$TEST_FILE" -q ) > "$OUT/pytest.log" 2>&1
  kv pytest_rc "$?"
  kv pytest_summary "$(command grep -E '^[0-9]+ (passed|failed)|^=+ .*(passed|failed|error)|no tests ran' "$OUT/pytest.log" | tail -n 1)"
  rm -rf "$ROOT/pytest-triton" "$ROOT/pytest-home"
fi

# ---------------------------------------------------------------- the server
A=$OUT
SERVER_PID=""
stop_server() {
  [ -n "$SERVER_PID" ] || return 0
  kill -TERM -- "-$SERVER_PID" 2>>"$A/stop.log"
  local end=$(( $(date +%s) + GRACE_S ))
  while kill -0 "$SERVER_PID" 2>>"$A/stop.log" && [ "$(date +%s)" -lt "$end" ]; do sleep 1; done
  kill -KILL -- "-$SERVER_PID" 2>>"$A/stop.log"
  sleep 3
  SERVER_PID=""
  nvidia-smi --query-gpu=memory.used --format=csv,noheader >> "$A/gpu-after-stop.txt" 2>&1
}
trap stop_server EXIT
akv() { echo "$1=$2" >> "$A/arm.txt"; }

# wait_ready BOUND: whether /health answered 200 and the ready line was logged within BOUND seconds.
wait_ready() {
  local end=$(( $(date +%s) + $1 )) h="" r=""
  while [ "$(date +%s)" -lt "$end" ]; do
    kill -0 "$SERVER_PID" 2>>"$A/poll-errors.log" || { akv exited_before_ready yes; return 1; }
    if [ -z "$h" ] && $PY -c 'import sys, urllib.request; sys.exit(0 if urllib.request.urlopen(sys.argv[1], timeout=2).status == 200 else 1)' \
      "http://127.0.0.1:$PORT/health" 2>>"$A/poll-errors.log"; then
      h=$(now); akv health_epoch "$h"
    fi
    if [ -z "$r" ] && command grep -qF "The server is fired up and ready to roll" "$A/server.log"; then
      r=$(now); akv ready_line_epoch "$r"
    fi
    [ -n "$h" ] && [ -n "$r" ] && { akv ready_epoch "$(now)"; return 0; }
    sleep "$POLL_S"
  done
  return 1
}

# burst LABEL CONCURRENCY PROMPTS SEED: one run of SGLang's own benchmark client, timed from outside.
burst() {
  local label=$1 conc=$2 n=$3 seed=$4 b t0 t1 rc
  b=$(burst_bound "$conc")
  if [ "$(left)" -lt "$b" ]; then
    printf '%s\t%s\t%s\t%s\t-\t-\tskipped-time\n' "$label" "$conc" "$n" "$seed" >> "$A/bursts.tsv"
    step "$label skipped, $(left) s left and the burst is bounded at $b s"
    return 1
  fi
  step "$label (concurrency $conc, $n prompts, seed $seed)"
  local cmd=($PY -m sglang.benchmark.serving --backend sglang --host 127.0.0.1 --port "$PORT" --model "$MDIR" --tokenizer "$MDIR"
    --dataset-name random-ids --random-input-len 1024 --random-output-len 512 --random-range-ratio 1.0
    --num-prompts "$n" --max-concurrency "$conc" --seed "$seed" --output-file "$A/bursts/$label.jsonl" --output-details --disable-tqdm)
  echo "$(printf '%q ' "${cmd[@]}")" >> "$A/commands.txt"
  t0=$(now)
  ( cd / && HF_HUB_OFFLINE=1 timeout --kill-after=10 "$b" "${cmd[@]}" ) > "$A/bursts/$label.log" 2>&1
  rc=$?
  t1=$(now)
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$label" "$conc" "$n" "$seed" "$t0" "$t1" "$rc" >> "$A/bursts.tsv"
  return 0
}

mkdir -p "$A/bursts" "$A/home"
: > "$A/arm.txt"
printf 'label\tconcurrency\tprompts\tseed\tstart\tend\trc\n' > "$A/bursts.tsv"
tc_env=()
if [ "$TREECORE" = rust ]; then
  # The server's SGLANG_CACHE_DIR is its HOME's ~/.cache/sglang, so prep's build is copied there; only the built artifacts, not cargo's target tree.
  mkdir -p "$A/home/.cache/sglang/rust_extensions"
  cp -a "$PREP/sglang-cache/rust_extensions/artifacts" "$A/home/.cache/sglang/rust_extensions/" 2>>"$A/treecore-copy.log" \
    || { step "cannot copy the TreeCore build from prep"; kv stopped treecore; exit 3; }
else
  tc_env=(SGLANG_UNIFIED_RADIX_TREE_CORE_BACKEND=python)
fi
cache=$ROOT/triton-$MODE
rm -rf "$cache"; mkdir -p "$cache"
akv triton_cache_entries_at_start "$(find "$cache" -mindepth 1 | wc -l)"
# A fresh HOME keeps the image's JIT caches under ~/.cache out of the arm, as in r2; PYTHONUNBUFFERED keeps log lines whole, as in r3.
cmd=(env HOME="$A/home" TRITON_CACHE_DIR="$cache" TRITON_PRINT_AUTOTUNING=1 PYTHONUNBUFFERED=1 SGL51628_COMPILE_LOG="$A/compiles.jsonl" HF_HUB_OFFLINE=1
  "${RUST_ENV[@]}" "${tc_env[@]}" $PY -m sglang.launch_server --model-path "$MDIR" --trust-remote-code)
echo "$(printf '%q ' "${cmd[@]}")" >> "$A/commands.txt"
step "server on an empty Triton cache"
akv launch_epoch "$(now)"
( cd / && exec setsid "${cmd[@]}" ) > "$A/server.log" 2>&1 &
SERVER_PID=$!
if ! wait_ready "$(bound "$UP_S")"; then
  akv failed not-ready
  stop_server
  kv arm_rc 1
  kv ended "$(date +%s)"
  exit 0
fi
# The gate: on this SHA, a NemotronH with separate Mamba layers must start with prefill CUDA graph off, and FIX must have prewarmed.
gate_line=$(command grep -m1 -F 'Disable prefill CUDA graph because some layers do not apply Standard GQA' "$A/server.log")
capture_line=$(command grep -m1 -E 'Capture .*prefill CUDA graph begin' "$A/server.log")
prewarm_line=$(command grep -m1 -E 'Prewarmed the Mamba2 prefill scan for [0-9]+ layer geometries in [0-9.]+ s\.' "$A/server.log")
akv gate_line "${gate_line:-none}"
akv capture_line "${capture_line:-none}"
akv prewarm_line "${prewarm_line:-none}"
gate=pass
[ -n "$gate_line" ] && [ -z "$capture_line" ] || gate=fail
[ "$MODE" = fix ] && [ -z "$prewarm_line" ] && gate=fail
akv gate "$gate"
if [ "$gate" = fail ]; then
  step "GATE FAILED; no traffic is sent"
  stop_server
  kv arm_rc 2
  kv ended "$(date +%s)"
  exit 4
fi
for spec in $BURSTS; do
  IFS=: read -r label conc n seed <<<"$spec"
  burst "$label" "$conc" "$n" "$seed"
done
stop_server
akv stopped_epoch "$(now)"
trap - EXIT
kv arm_rc 0
kv ended "$(date +%s)"
step "done"
exit 0
