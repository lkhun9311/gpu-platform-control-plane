#!/bin/bash
# The measurement of the SGLang #51628 kit r3, run once inside a fresh container of the pinned SGLang image.
#
#   measure.sh <in dir> <out dir> <models dir> <deadline epoch>
#
# run.sh mounts the kit read-only as <in dir>, and every record goes to <out dir>.
# This script records and does not judge: verdict.py reads what it leaves.
#
# r3 runs only r2's CONTROL arm, which r2 skipped for its budget: a server on an empty Triton cache and a fresh HOME, then the gate, then r2's bursts.
#   CONTROL: python -m sglang.launch_server --model-path <model> --trust-remote-code --warmups prefill_shapes
# --warmups prefill_shapes is SGLang's own prefill warmup, run before the server listens, so its compiles land before ready.
# Every Triton compilation in the server is recorded by sgl51628_compile_hook.py with its wall-clock time.
# SGLANG_TRITON_SLOW_COMPILE_THRESHOLD_SECS stays at its default, so SGLang's own warning lines are the reporter's.
set -u
if [ "$#" != 4 ]; then echo "usage: measure.sh <in dir> <out dir> <models dir> <deadline epoch>" >&2; exit 2; fi
IN=$1
OUT=$2
MODELS=$3
DEADLINE=$4
[[ $DEADLINE =~ ^[0-9]+$ ]] || { echo "measure.sh: the deadline '$DEADLINE' is not an epoch in whole seconds" >&2; exit 2; }
[ -d "$IN" ] && [ -d "$OUT" ] && [ -d "$MODELS" ] || { echo "measure.sh: the in, out and models directories must exist" >&2; exit 2; }
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
# The bounds of each step, in seconds.
MODEL_S=600
# r2's MAIN arm was ready 154 s after launch; the prefill warmup's 17 prefills and their autotunes come on top.
CONTROL_UP_S=1200
PROBE_S=300
# The bursts: label, concurrency, prompts, seed.
# The first is the reporter's warmup (64 prompts at concurrency 32); then three runs each at concurrency 1, 16 and 128.
# Each burst has its own seed, so no burst repeats another's prompts and hits the radix cache instead of prefilling.
BURSTS="warmup:32:64:42 c1-r1:1:4:101 c1-r2:1:4:102 c1-r3:1:4:103 c16-r1:16:32:161 c16-r2:16:32:162 c16-r3:16:32:163 c128-r1:128:128:1281 c128-r2:128:128:1282 c128-r3:128:128:1283"
# burst_bound CONCURRENCY: the burst's kill timeout.
burst_bound() { case "$1" in 1) echo 240 ;; 16) echo 240 ;; 32) echo 300 ;; *) echo 420 ;; esac; }

step() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) measure: $*" | tee -a "$OUT/measure-steps.log" >&2; }
kv() { echo "$1=$2" >> "$OUT/measure.txt"; }
now() { date +%s.%N; }
left() { echo $(( DEADLINE - $(date +%s) )); }
# bound N: N, or the time left before the deadline when that is shorter, and at least 1.
bound() { local l; l=$(left); [ "$l" -gt "$1" ] && echo "$1" || echo $(( l > 1 ? l : 1 )); }
: > "$OUT/measure.txt"
kv started "$(date +%s)"
kv bursts "$BURSTS"

# ---------------------------------------------------------------- what runs
{
  $PY -c 'import importlib.metadata as m; print("sglang=" + m.version("sglang"))'
  $PY -c 'import sglang, os; print("sglang_dir=" + os.path.dirname(sglang.__file__))'
  $PY -c 'import triton; print("triton=" + triton.__version__)'
  timeout 120 $PY -c 'import torch; print("torch=" + torch.__version__); print("cuda=" + str(torch.version.cuda)); print("gpu=" + torch.cuda.get_device_name(0))'
  env | command grep -E '^(SGLANG_|CUDA_VERSION|TRITON)' | sort
} > "$OUT/versions.txt" 2>&1
kv sglang_build_commit "${SGLANG_BUILD_COMMIT:-unset}"
kv gpu_name "$(nvidia-smi --query-gpu=name --format=csv,noheader | head -n 1)"

# ---------------------------------------------------------------- the compile record, installed and shown to fire
# A .pth line that starts with "import" runs at every interpreter start, so the hook is in the scheduler before SGLang installs its own watch.
SITE=$($PY -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')
mkdir -p "$ROOT/hook" || { step "cannot create $ROOT/hook"; exit 3; }
cp "$IN/sgl51628_compile_hook.py" "$ROOT/hook/" || { step "cannot copy the hook"; exit 3; }
echo "import sys; sys.path.append('$ROOT/hook'); import sgl51628_compile_hook" > "$SITE/sgl51628_compile_hook.pth" || { step "cannot write the .pth into $SITE"; exit 3; }
kv hook_pth "$SITE/sgl51628_compile_hook.pth"
rm -rf "$ROOT/probe-triton"; mkdir -p "$ROOT/probe-triton"
step "probe: two fresh kernels must each leave a compile record"
SGL51628_COMPILE_LOG="$OUT/probe-compiles.jsonl" TRITON_CACHE_DIR="$ROOT/probe-triton" SGLANG_TRITON_SLOW_COMPILE_THRESHOLD_SECS=0 \
  timeout "$(bound $PROBE_S)" $PY "$IN/probe_hook.py" "$OUT/probe-compiles.jsonl" > "$OUT/probe-hook.log" 2>&1
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

# ---------------------------------------------------------------- the model
step "download $MODEL_REPO at $MODEL_REV"
MDIR=$MODELS/$MODEL_TAG
mkdir -p "$MDIR"
pats="'*.json', '*.py', '*.safetensors', '*.jinja'"
timeout --kill-after=10 "$(bound $MODEL_S)" $PY -c "
from huggingface_hub import snapshot_download
print(snapshot_download('$MODEL_REPO', revision='$MODEL_REV', local_dir='$MDIR', allow_patterns=[$pats]))
" > "$OUT/download.log" 2>&1
kv download_rc "$?"
( cd "$MDIR" && find . -type f -not -path './.cache/*' -printf '%s %p\n' | sort -k2 ) > "$OUT/model-files.txt"
kv model_repo "$MODEL_REPO"
kv model_revision "$MODEL_REV"
model=ok
for w in $MODEL_LFS; do
  f=${w%%=*}; s=${w#*=}
  have=$(sha256sum "$MDIR/$f" 2>>"$OUT/download.log" | cut -d' ' -f1)
  kv "sha256_$f" "${have:-absent}"
  # The offline test's fake checkpoint cannot carry the real hashes, so it records the check as skipped.
  if [ "${SGL51628_OFFLINE_TEST:-}" = 1 ]; then [ -n "$have" ] || model=bad; continue; fi
  [ "$have" = "$s" ] || { model=bad; step "$f is ${have:-absent}, not $s"; }
done
[ "${SGL51628_OFFLINE_TEST:-}" = 1 ] && kv model_hash_check "skipped (offline test)"
kv model "$model"
[ "$model" = ok ] || { kv stopped model; exit 3; }

# ---------------------------------------------------------------- one arm
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
    step "$ARM: $label skipped, $(left) s left and the burst is bounded at $b s"
    return 1
  fi
  step "$ARM: $label (concurrency $conc, $n prompts, seed $seed)"
  local cmd=($PY -m sglang.benchmark.serving --backend sglang --host 127.0.0.1 --port "$PORT" --model "$MDIR" --tokenizer "$MDIR"
    --dataset-name random-ids --random-input-len 1024 --random-output-len 512 --random-range-ratio 1.0
    --num-prompts "$n" --max-concurrency "$conc" --seed "$seed" --output-file "$A/bursts/$label.jsonl" --output-details --disable-tqdm)
  echo "$(printf '%q ' "${cmd[@]}")" >> "$A/commands.txt"
  t0=$(now)
  HF_HUB_OFFLINE=1 timeout --kill-after=10 "$b" "${cmd[@]}" > "$A/bursts/$label.log" 2>&1
  rc=$?
  t1=$(now)
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$label" "$conc" "$n" "$seed" "$t0" "$t1" "$rc" >> "$A/bursts.tsv"
  return 0
}

# arm NAME UP_BOUND [EXTRA FLAGS...]: one server and every burst; it returns 0 when the gate passed.
arm() {
  ARM=$1
  local up=$2
  shift 2
  A=$OUT/$ARM
  mkdir -p "$A/bursts" "$A/home"
  : > "$A/arm.txt"
  printf 'label\tconcurrency\tprompts\tseed\tstart\tend\trc\n' > "$A/bursts.tsv"
  local cache=$ROOT/triton-$ARM
  rm -rf "$cache"; mkdir -p "$cache"
  akv triton_cache_entries_at_start "$(find "$cache" -mindepth 1 | wc -l)"
  # A fresh HOME per arm keeps one arm's JIT caches under ~/.cache from reaching the other.
  # PYTHONUNBUFFERED keeps Triton's autotune report whole: in r2, buffered stdout spliced a log line into the middle of one.
  local cmd=(env HOME="$A/home" TRITON_CACHE_DIR="$cache" TRITON_PRINT_AUTOTUNING=1 PYTHONUNBUFFERED=1 SGL51628_COMPILE_LOG="$A/compiles.jsonl" HF_HUB_OFFLINE=1
    $PY -m sglang.launch_server --model-path "$MDIR" --trust-remote-code "$@")
  echo "$(printf '%q ' "${cmd[@]}")" >> "$A/commands.txt"
  step "$ARM: server on an empty Triton cache"
  akv launch_epoch "$(now)"
  setsid "${cmd[@]}" > "$A/server.log" 2>&1 &
  SERVER_PID=$!
  if ! wait_ready "$(bound "$up")"; then
    akv failed not-ready
    stop_server
    return 1
  fi
  # The gate: on this SHA, a NemotronH with separate Mamba layers must start with prefill CUDA graph off.
  local gate_line capture_line
  gate_line=$(command grep -m1 -E 'Disable (target |draft )?prefill CUDA graph' "$A/server.log")
  capture_line=$(command grep -m1 -E 'Capture .*prefill CUDA graph begin' "$A/server.log")
  akv gate_line "${gate_line:-none}"
  akv capture_line "${capture_line:-none}"
  if [ -z "$gate_line" ] || [ -n "$capture_line" ]; then
    akv gate fail
    step "$ARM: GATE FAILED, prefill CUDA graph was not shown disabled; no traffic is sent"
    stop_server
    return 2
  fi
  akv gate pass
  local spec label conc n seed
  for spec in $BURSTS; do
    IFS=: read -r label conc n seed <<<"$spec"
    burst "$label" "$conc" "$n" "$seed"
  done
  stop_server
  akv stopped_epoch "$(now)"
  return 0
}

arm control "$CONTROL_UP_S" --warmups prefill_shapes
control_rc=$?
kv control_rc "$control_rc"
if [ "$control_rc" = 2 ]; then
  kv ended "$(date +%s)"
  exit 4
fi
trap - EXIT
kv ended "$(date +%s)"
step "done"
exit 0
