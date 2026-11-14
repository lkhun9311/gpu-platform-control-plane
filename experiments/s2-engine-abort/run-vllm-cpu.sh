#!/usr/bin/env bash
# Run abort.py against vLLM v0.27.1 on CPU, the engine version the gateway is pinned to, and keep the rows.
# Usage: experiments/s2-engine-abort/run-vllm-cpu.sh OUT_JSONL [REPS]
# Needs Qwen/Qwen2.5-0.5B-Instruct in ~/.cache/huggingface; the container runs offline.
set -euo pipefail

out=${1:?output jsonl}
reps=${2:-3}
here=$(cd "$(dirname "$0")" && pwd)
# Pinned by digest: the tag can move, and a row must name the engine it measured.
image=vllm/vllm-openai-cpu@sha256:0314b8a7594a3fc54e8a0c3ca1ba0c9257302bfb546abfb49a2d6107d2d0767f
model=Qwen/Qwen2.5-0.5B-Instruct
name=s2-abort-vllm-$$
port=$(python3 -I -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')

cleanup() { docker rm -f "$name" >/dev/null 2>&1 || true; }
trap cleanup EXIT

# Capped so it cannot starve other work on a shared machine; /dev/shm is raised because vLLM's default
# 64 MiB is below what its engine core asks for.
docker run -d --name "$name" --memory 12g --cpus 8 --shm-size 1g -p "127.0.0.1:$port:8000" \
  -v "$HOME/.cache/huggingface:/root/.cache/huggingface" -e HF_HUB_OFFLINE=1 -e VLLM_CPU_KVCACHE_SPACE=2 \
  "$image" --model "$model" --served-model-name m --max-num-seqs 1 --max-model-len 2048 --dtype bfloat16 >/dev/null

for _ in $(seq 1 120); do
  curl -sf -m 2 "localhost:$port/v1/models" >/dev/null && break
  docker ps -q -f "name=^$name$" | grep -q . || { echo "vLLM exited"; docker logs "$name" 2>&1 | tail -20; exit 1; }
  sleep 2
done
curl -sf -m 2 "localhost:$port/v1/models" >/dev/null || { echo "vLLM did not start"; docker logs "$name" 2>&1 | tail -20; exit 1; }
# The port was free a moment ago, but only the container's published port proves who answers now.
[[ "$(docker port "$name" 8000/tcp)" == "127.0.0.1:$port" ]] || { echo "port $port is not this container's"; exit 1; }

# The first requests after start are several times slower on CPU; warm up so the control is not the warm-up.
for _ in 1 2 3; do
  curl -sf -m 120 "localhost:$port/v1/chat/completions" -H 'content-type: application/json' \
    -d '{"model":"m","messages":[{"role":"user","content":"warm"}],"max_tokens":32,"ignore_eos":true}' >/dev/null
done

# A row has to be re-checkable without this machine, so the run states what produced it.
revision=$(cat "$HOME/.cache/huggingface/hub/models--Qwen--Qwen2.5-0.5B-Instruct/refs/main" 2>/dev/null || echo unknown)
python3 -I - "$out.manifest.json" <<PY
import json, subprocess, sys
rev = subprocess.run(["git", "-C", "$here", "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
dirty = bool(subprocess.run(["git", "-C", "$here", "status", "--porcelain", "."], capture_output=True, text=True).stdout.strip())
json.dump({"engine": "vllm-cpu v0.27.1", "image": "$image", "model": "$model", "model_revision": "$revision",
           "engine_args": "--max-num-seqs 1 --max-model-len 2048 --dtype bfloat16, VLLM_CPU_KVCACHE_SPACE=2, 8 cpus, 12g",
           "harness_commit": rev, "harness_dirty": dirty}, open(sys.argv[1], "w"), indent=1)
PY

# About 0.04 s per token here (control rows record request_duration_s), so 300 tokens last about 12 s.
# Release is judged as excess over the idle probe baseline that abort.py measures first.
python3 -I "$here/abort.py" --port "$port" --reps "$reps" \
  --cases control,busy_control,stream_cut,plain_cut,prefill_baseline,prefill_cut,queued_cut \
  --max-tokens 300 --token-seconds 0.05 --release-threshold 2.0 \
  --cut-after 1.0 --long-prompt-words 1500 | while read -r row; do
  printf '%s\n' "${row%\}}, \"engine\": \"vllm-cpu v0.27.1\", \"image\": \"$image\", \"model\": \"$model\"}"
done >"$out"
status=${PIPESTATUS[0]}
cat "$out"
exit "$status"
