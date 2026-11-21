#!/bin/bash
# GPU A/B for the GPTQ MoE Marlin conversion fix on one NVIDIA GPU with >= 24 GB.
# Python-only change, so vLLM is installed once with precompiled kernels from the base commit.
# Every step's exit code goes to results/status.txt; a zero exit of this script alone proves nothing.
set -uo pipefail
BASE=a3b845e226
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${OUT:-$HERE/results}
mkdir -p "$OUT"
: > "$OUT/status.txt"
step() { # name, then the command; records the exit code and keeps going
  local name=$1; shift
  "$@"; local rc=$?
  echo "$name exit=$rc" | tee -a "$OUT/status.txt"
  return $rc
}

git clone -q https://github.com/vllm-project/vllm.git vllm-ab && cd vllm-ab || exit 1
git checkout -q $BASE || exit 1
command -v uv > /dev/null || { echo "uv is required (https://docs.astral.sh/uv/)"; exit 1; }
uv venv -q --python 3.12 .venv && . .venv/bin/activate || exit 1
step install-vllm env VLLM_USE_PRECOMPILED=1 uv pip install -q -e . || exit 1
# Test-only packages that vLLM's tests/conftest.py imports; versions follow requirements/test.
step install-test uv pip install -q "pytest>=9.2.0" pytest-asyncio tblib httpx || exit 1
# huggingface_hub >= 2 ships the `hf` command only.
step download hf download Qwen/Qwen3-30B-A3B-GPTQ-Int4 --revision 9b534e4318b7ebc3c961a839f13eb18b1833f441 > /dev/null || exit 1
pip_freeze=$(uv pip freeze) && echo "$pip_freeze" > "$OUT/pip-freeze.txt"
nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv | tee "$OUT/gpu.txt"

# The regression test must fail on the base code and pass with the fix, for 4-bit and 8-bit.
T=tests/quantization/test_auto_gptq.py::test_auto_gptq_moe_marlin_prep_skips_layout_copies
git apply "$HERE/fix.patch" && git checkout -q $BASE -- vllm/ || exit 1
step test-base-expect-fail bash -c "python -m pytest -q -p no:cacheprovider $T > '$OUT/test-base.log' 2>&1"
git apply --include='vllm/*' "$HERE/fix.patch" || exit 1
step test-fix bash -c "python -m pytest -q -p no:cacheprovider $T > '$OUT/test-fix.log' 2>&1"
step test-files-fix bash -c "python -m pytest -q -p no:cacheprovider tests/quantization/test_auto_gptq.py tests/quantization/test_moe_wna16.py > '$OUT/test-files-fix.log' 2>&1"
git checkout -q $BASE -- vllm/ tests/

# Two rounds, order swapped, so warm caches do not favour one side.
for round in 1 2; do
  for side in $([ $round = 1 ] && echo "base fix" || echo "fix base"); do
    git checkout -q $BASE -- vllm/
    if [ $side = fix ]; then git apply --include='vllm/*' "$HERE/fix.patch" || exit 1; fi
    step load-$side-r$round bash -c "python '$HERE/measure.py' --label $side-r$round --out '$OUT/$side-r$round.json' > '$OUT/$side-r$round.log' 2>&1"
  done
done
git checkout -q $BASE -- vllm/

python - "$OUT" <<'PY'
import glob, json, sys
rows = {}
for p in sorted(glob.glob(sys.argv[1] + "/*-r[12].json")):
    rows[p.rsplit("/", 1)[1][:-5]] = json.load(open(p))
for k, r in rows.items():
    keys = ("allocated_before_gib", "peak_during_gib", "allocated_after_gib", "extra_peak_gib", "convert_seconds", "engine_init_seconds")
    print(k, {x: round(r[x], 3) for x in keys}, r.get("processed_tensors"), r.get("processed_sha256") or r.get("hash_error"))
print("load runs with results:", len(rows), "of 4")
if rows:
    hashes = {r.get("processed_sha256") for r in rows.values()}
    print("processed weights identical across runs:", None not in hashes and len(hashes) == 1)
    print("greedy token ids identical across runs (not batch invariant, informational):", len({json.dumps(r["token_ids"]) for r in rows.values()}) == 1)
PY
echo "--- status"; cat "$OUT/status.txt"
