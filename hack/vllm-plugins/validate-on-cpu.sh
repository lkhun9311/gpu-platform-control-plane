#!/usr/bin/env bash
# Runs step_logging_scheduler.py inside vLLM v0.27.1's CPU build and checks its log with check_step_log.py.
#
# WHY THIS EXISTS
#
# The instrument changes how the engine's scheduler is called, and the only way to know it records what it claims
# is to run the real engine code. The pinned GPU image needs a card; v0.27.1's CPU build runs the same scheduler and
# engine core on this machine for free. So this is the gate before any card time is bought for the instrument.
#
# WHAT IT SENDS
#
# A small staggered episode -- two decoders, then a late prefill once they are decoding -- with X-Request-Id on
# every request, the shape the instrument exists to explain, plus two lone requests.
#
# WHAT IT CANNOT SAY
#
# Anything about the A10G: overhead, CUDA completion and timing do not transfer from a CPU build. It establishes that
# the plugin loads, records every step the engine logs, joins requests by id and reconciles every token.
set -euo pipefail
cd "$(dirname "$0")" || exit 1
IMAGE="${IMAGE:-vllm/vllm-openai-cpu:v0.27.1-x86_64}"
MODEL="${MODEL:-Qwen/Qwen2.5-0.5B-Instruct}"
PORT="${PORT:-18000}"
NAME="vllm-step-log-validate"
WORK="$(mktemp -d)"
trap 'docker rm -f "$NAME" >/dev/null 2>&1 || true; rm -rf "$WORK"' EXIT

fail() { printf 'VALIDATION FAILED: %s\n' "$*" >&2; exit 1; }
command -v docker >/dev/null || fail "docker is not on PATH"

docker rm -f "$NAME" >/dev/null 2>&1 || true
# Prefix caching is off as in config/vllm/deployment.yaml: with it on, the second identical decoder reused 512
# cached tokens and its scheduled total fell short of prompt + output - 1, which the checker refused.
# /dev/shm and memory utilisation are the CPU build's: its default 64 MiB shm refuses to start, and on CPU the
# utilisation flag is a share of the container's memory.
docker run -d --name "$NAME" --cpus 8 --memory 16g --shm-size 2g -p "127.0.0.1:$PORT:8000" \
  -v "$HOME/.cache/huggingface:/root/.cache/huggingface" -v "$PWD:/plugins:ro" -v "$WORK:/out" \
  -e PYTHONPATH=/plugins -e STEP_LOG_PATH=/out/step.jsonl \
  "$IMAGE" "$MODEL" --no-async-scheduling --enable-logging-iteration-details \
  --scheduler-cls step_logging_scheduler.StepLoggingScheduler --max-num-batched-tokens 512 --max-model-len 4096 \
  --no-enable-prefix-caching \
  --max-num-seqs 16 --gpu-memory-utilization 0.5 >/dev/null || fail "docker run"
for _ in $(seq 1 120); do
  curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/health" 2>/dev/null | grep -q 200 && break
  docker ps -q -f "name=$NAME" | grep -q . || fail "the engine exited: $(docker logs "$NAME" 2>&1 | grep -E 'Error' | tail -2)"
  sleep 5
done
docker logs "$NAME" 2>&1 | grep -q "Using custom scheduler class step_logging_scheduler.StepLoggingScheduler" \
  || fail "the engine did not load the instrument"

PORT="$PORT" python3 - "$WORK/outputs.json" <<'EOF' || fail "the client could not complete its requests"
import json, os, sys, threading, time, urllib.request
url = f"http://127.0.0.1:{os.environ['PORT']}/v1/chat/completions"
outputs = {}
def send(rid, content, max_tokens, min_tokens=None):
    body = {"model": os.environ.get("MODEL", "Qwen/Qwen2.5-0.5B-Instruct"), "messages": [{"role": "user", "content": content}],
            "max_tokens": max_tokens, "stream": True, "stream_options": {"include_usage": True}}
    if min_tokens:
        body["min_tokens"] = min_tokens
    req = urllib.request.Request(url, data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json", "X-Request-Id": rid})
    with urllib.request.urlopen(req, timeout=600) as r:
        for line in r:
            if line.startswith(b"data: {") and b'"usage"' in line:
                usage = json.loads(line[6:]).get("usage")
                if usage:
                    outputs[rid] = usage["completion_tokens"]
send("lone-0", "hello " * 50, 8)
decoders = [threading.Thread(target=send, args=(f"dec-{i}", "word " * 600, 48, 48)) for i in range(2)]
for t in decoders: t.start()
time.sleep(20)
late = threading.Thread(target=send, args=("late-0", "hello " * 300, 4)); late.start()
for t in decoders + [late]: t.join()
send("lone-1", "hello " * 50, 8)
json.dump(outputs, open(sys.argv[1], "w"))
if len(outputs) != 5:
    sys.exit(f"usage was reported for {len(outputs)} of 5 requests")
EOF
docker logs "$NAME" > "$WORK/engine.log" 2>&1
# The instrument writes when the engine drains, on a thread, so wait until the batch holding the last request has
# been written: its add record is present and the file ends on a flush. Any earlier flush does not count.
ok=0
for _ in $(seq 1 30); do
  if grep -q '"id":"chatcmpl-lone-1-' "$WORK/step.jsonl" 2>/dev/null && tail -1 "$WORK/step.jsonl" | grep -q '"ev":"flush"'; then
    ok=1; break
  fi
  sleep 1
done
[ "$ok" = 1 ] || fail "the batch holding the last request was not written within 30 s"
python3 check_step_log.py "$WORK/step.jsonl" "$WORK/engine.log" "$WORK/outputs.json" || fail "the step log does not reconcile"
printf 'flushes: %s\n' "$(grep -c '"ev":"flush"' "$WORK/step.jsonl")"
echo "PASS: the instrument records the engine's steps on v0.27.1"
