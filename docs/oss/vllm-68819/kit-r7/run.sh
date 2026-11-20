#!/bin/bash
# GPU A/B for the GPTQ MoE Marlin conversion fix on one NVIDIA GPU with >= 24 GB.
# Python-only change, so vLLM is installed once with precompiled kernels from the base commit.
# Every step's exit code goes to results/status.txt; a zero exit of this script alone proves nothing.
#
# Phases:
#   1. regression tests on base (expected to fail) and with the fix;
#   2. a full-memory A/B load, two rounds, with torch allocated/reserved and device-wide peaks;
#   3. an OOM sweep: filler.py holds GPU memory in another process so only F GiB stays free,
#      and each side loads and generates with the same small serving settings.
set -uo pipefail
BASE=a3b845e226
REV=9b534e4318b7ebc3c961a839f13eb18b1833f441
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${OUT:-$HERE/results}
SWEEP_FREE_GIB=${SWEEP_FREE_GIB:-"16.4 16.6 16.8 17.0 17.2 17.4"}
# Which phases to run, e.g. PHASES=3 for the OOM sweep only.
PHASES=${PHASES:-"1 2 3"}
# The sweep leaves gpu_memory_utilization unset by default, as a user would; set SWEEP_UTIL=auto to cap it.
SWEEP_UTIL=${SWEEP_UTIL:-unset}
has_phase() { case " $PHASES " in *" $1 "*) return 0 ;; esac; return 1; }
mkdir -p "$OUT"
: > "$OUT/status.txt"
step() { # name, then the command; records the exit code and keeps going
  local name=$1; shift
  "$@"; local rc=$?
  echo "$name exit=$rc" | tee -a "$OUT/status.txt"
  return $rc
}
FILLER_PID=""
stop_filler() { [ -n "$FILLER_PID" ] && kill "$FILLER_PID" 2>/dev/null && wait "$FILLER_PID" 2>/dev/null; FILLER_PID=""; }
trap stop_filler EXIT
use_side() { # base or fix
  git checkout -q $BASE -- vllm/
  if [ "$1" = fix ]; then git apply --include='vllm/*' "$HERE/fix.patch" || exit 1; fi
}

git clone -q https://github.com/vllm-project/vllm.git vllm-ab && cd vllm-ab || exit 1
git checkout -q $BASE || exit 1
command -v uv > /dev/null || { echo "uv is required (https://docs.astral.sh/uv/)"; exit 1; }
uv venv -q --python 3.12 .venv && . .venv/bin/activate || exit 1
step install-vllm env VLLM_USE_PRECOMPILED=1 uv pip install -q -e . || exit 1
# Test-only packages that vLLM's tests/conftest.py imports; versions follow requirements/test.
step install-test uv pip install -q "pytest>=9.2.0" pytest-asyncio tblib httpx || exit 1
# huggingface_hub >= 2 ships the `hf` command only.
step download hf download Qwen/Qwen3-30B-A3B-GPTQ-Int4 --revision $REV > /dev/null || exit 1
uv pip freeze > "$OUT/pip-freeze.txt"
nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv | tee "$OUT/gpu.txt"

if has_phase 1; then
# 1. Regression tests.
# On base, the three method-level cases (int4, int8, int4-padded) must fail on the memory bound.
# The Batched Marlin case calls the conversion with views directly, so it passes on base too.
T=tests/quantization/test_auto_gptq.py
K="skips_layout_copies or batched_marlin_converts"
git apply "$HERE/fix.patch" && git checkout -q $BASE -- vllm/ || exit 1
step test-base-expect-3-fail bash -c "python -m pytest -q -p no:cacheprovider $T -k '$K' -rA > '$OUT/test-base.log' 2>&1"
git apply --include='vllm/*' "$HERE/fix.patch" || exit 1
step test-fix bash -c "python -m pytest -q -p no:cacheprovider $T -k '$K' -rA > '$OUT/test-fix.log' 2>&1"
step test-files-fix bash -c "python -m pytest -q -p no:cacheprovider $T tests/quantization/test_moe_wna16.py > '$OUT/test-files-fix.log' 2>&1"
git checkout -q $BASE -- vllm/ tests/
fi

if has_phase 2; then
# 2. Full-memory A/B, two rounds, order swapped, so warm caches do not favour one side.
for round in 1 2; do
  for side in $([ $round = 1 ] && echo "base fix" || echo "fix base"); do
    use_side $side
    step load-$side-r$round bash -c "python '$HERE/measure.py' --label $side-r$round --out '$OUT/$side-r$round.json' > '$OUT/$side-r$round.log' 2>&1"
  done
done
fi

if has_phase 3; then
# 3. OOM sweep: same small serving settings on both sides, only F GiB free on the device.
SMALL="--max-model-len 512 --max-num-batched-tokens 512 --max-num-seqs 4 --gpu-memory-utilization $SWEEP_UTIL"
i=0
for free in $SWEEP_FREE_GIB; do
  i=$((i + 1))
  for side in $([ $((i % 2)) = 1 ] && echo "base fix" || echo "fix base"); do
    use_side $side
    python "$HERE/filler.py" --leave-free-gib "$free" > "$OUT/filler-$free-$side.log" 2>&1 &
    FILLER_PID=$!
    for _ in $(seq 1 120); do grep -q '^READY' "$OUT/filler-$free-$side.log" && break; sleep 1; done
    if ! grep -q '^READY' "$OUT/filler-$free-$side.log"; then
      echo "oom-$free-$side filler-not-ready" | tee -a "$OUT/status.txt"; stop_filler; continue
    fi
    step oom-$free-$side bash -c "python '$HERE/measure.py' --label oom-$free-$side $SMALL --out '$OUT/oom-$free-$side.json' > '$OUT/oom-$free-$side.log' 2>&1"
    stop_filler
  done
done
fi
git checkout -q $BASE -- vllm/

python - "$OUT" <<'PY'
import glob, json, sys
out = sys.argv[1]
def load(p):
    return json.load(open(p))
print("--- full-memory A/B")
keys = ("extra_peak_gib", "reserved_before_gib", "reserved_peak_during_gib", "device_used_before_gib",
        "device_used_peak_during_gib", "device_used_peak_gib", "convert_seconds")
rows = {p.rsplit("/", 1)[1][:-5]: load(p) for p in sorted(glob.glob(out + "/*-r[12].json"))}
for k, r in rows.items():
    print(k, r.get("status"), {x: round(r[x], 3) for x in keys if x in r}, r.get("processed_sha256") or r.get("hash_error"))
hashes = {r.get("processed_sha256") for r in rows.values()}
print("processed weights identical across A/B runs:", bool(rows) and None not in hashes and len(hashes) == 1)
print("--- OOM sweep (free GiB at start, side, status, stage reached, OOM)")
for p in sorted(glob.glob(out + "/oom-*.json")):
    r = load(p)
    print(r["label"], round(r["device_free_at_start_gib"], 3), r.get("status"), r.get("stage"),
          r.get("out_of_memory"), r.get("error_type"), round(r.get("device_used_peak_gib", 0), 3))
PY
echo "--- status"; cat "$OUT/status.txt"
