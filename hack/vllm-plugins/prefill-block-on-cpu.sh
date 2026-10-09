#!/usr/bin/env bash
# Measures, on vLLM v0.27.1's CPU build, how many steps a priority-0 request waits when it arrives while a
# priority-1 request's long prefill is running, with and without --long-prefill-token-threshold.
#
#   bash hack/vllm-plugins/prefill-block-on-cpu.sh            EVIDENCE_DIR=<dir> keeps the logs and the summary
#
# WHY. The pilot's step logs show a premium request waiting through a whole contender prefill, 16 to 18 steps, because
# the V1 scheduler serves running requests first; the scheduler replay (hack/prospective-pilot/simulate.py) predicts
# that capping a prefill's tokens per step lets the waiting request in at the next step. Both are claims about the
# real scheduler, and this checks them on it, for free, before any card time.
#
# HOW. For each threshold, a fresh engine with the pilot's scheduler settings and a warm-up request (the CPU build's
# first step compiles for about 40 s); then one contender with a prompt of about 3,000 tokens, and twelve short premium
# requests 150 ms apart. Each premium request whose add record came while the contender was still short of its prompt
# is judged: the steps between its add and its first sched record, and whether that first step still held prefill.
#
# WHAT IT CANNOT SAY: anything about A10G step times, or about a load of many requests.
set -euo pipefail
cd "$(dirname "$0")" || exit 1
IMAGE="${IMAGE:-vllm/vllm-openai-cpu:v0.27.1-x86_64}"
MODEL="${MODEL:-Qwen/Qwen2.5-0.5B-Instruct}"
PORT="${PORT:-18002}"
NAME="vllm-prefill-block"
WORK="$(mktemp -d)"
trap 'docker rm -f "$NAME" >/dev/null 2>&1 || true; rm -rf "$WORK"' EXIT
fail() { printf 'EXPERIMENT FAILED: %s\n' "$*" >&2; exit 1; }

run() {
  local threshold="$1" out="$WORK/t$1"
  mkdir -p "$out"
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  docker run -d --name "$NAME" --cpus 8 --memory 16g --shm-size 2g -p "127.0.0.1:$PORT:8000" \
    -v "$HOME/.cache/huggingface:/root/.cache/huggingface" -v "$PWD:/plugins:ro" -v "$out:/out" \
    -e PYTHONPATH=/plugins -e STEP_LOG_PATH=/out/step.jsonl \
    "$IMAGE" "$MODEL" --no-async-scheduling --enable-logging-iteration-details \
    --scheduler-cls pilot_step_logger.PilotStepLoggingScheduler --scheduling-policy priority \
    --max-num-batched-tokens 512 --max-model-len 4096 --no-enable-prefix-caching \
    --long-prefill-token-threshold "$threshold" \
    --max-num-seqs 16 --gpu-memory-utilization 0.5 >/dev/null || fail "docker run (threshold $threshold)"
  for _ in $(seq 1 120); do
    curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/health" 2>/dev/null | grep -q 200 && break
    docker ps -q -f "name=$NAME" | grep -q . || fail "the engine exited: $(docker logs "$NAME" 2>&1 | tail -3 | tr '\n' ' ')"
    sleep 5
  done
  PORT="$PORT" MODEL="$MODEL" python3 - "$out" <<'EOF' || fail "the client failed at threshold $1"
import json, os, sys, threading, time, urllib.request
out = sys.argv[1]
url = f"http://127.0.0.1:{os.environ['PORT']}/v1/chat/completions"
def send(rid, prio, content, cap):
    body = {"model": os.environ["MODEL"], "messages": [{"role": "user", "content": content}], "max_tokens": cap,
            "min_tokens": cap, "priority": prio, "stream": True}
    req = urllib.request.Request(url, data=json.dumps(body).encode(), headers={"Content-Type": "application/json", "X-Request-Id": rid})
    with urllib.request.urlopen(req, timeout=900) as r:
        for _ in r:
            pass
# A warm-up first: the CPU build's first step compiles for about 40 s, and a contender sent into it would finish its
# prefill before anything could arrive during it.
send("warmup", 0, "hello", 1)
c = threading.Thread(target=send, args=("contender", 1, "word " * 3000, 4)); c.start()
# Premium requests every 150 ms from just after the contender, so several arrive while its prefill runs (CPU prefill
# steps take about 300 ms); the summary judges each by the step log, not by when it was sent.
ps = []
for i in range(12):
    time.sleep(0.15)
    t = threading.Thread(target=send, args=("premium-%d" % i, 0, "hello " * 30, 4)); t.start(); ps.append(t)
for t in ps:
    t.join()
c.join()
EOF
  for _ in $(seq 1 20); do
    touch "$out/step.jsonl.sentinel"; sleep 1
    python3 ../prospective-pilot/pilot_evidence.py terminal "$out/step.jsonl" >/dev/null 2>&1 && break
  done
  docker logs "$NAME" > "$out/engine.log" 2>&1
  python3 - "$out/step.jsonl" "$threshold" <<'EOF' | tee -a "$WORK/summary.txt"
import json, sys
recs = [json.loads(l) for l in open(sys.argv[1])]
adds = {r["id"]: r for r in recs if r.get("ev") == "add"}
sched = [r for r in recs if r.get("ev") == "sched"]
c = next(e for e in adds if "contender" in e)
prompt = adds[c]["prompt"]
chunks = [s["tokens"].get(c, 0) for s in sched if c in s["tokens"] and s["computed"].get(c, 0) < prompt]
mid = []
for p in sorted((e for e in adds if "premium" in e), key=lambda e: adds[e]["seq"]):
    first = next(s for s in sched if p in s["tokens"])
    # Arrived mid-prefill: a sched record after its add still had the contender short of its prompt.
    during = [s for s in sched if s["seq"] > adds[p]["seq"] and c in s["tokens"] and s["computed"].get(c, 0) < prompt]
    if not during:
        continue
    waited = [s for s in sched if adds[p]["seq"] < s["seq"] < first["seq"]]
    mid.append((p, len(waited), first["tokens"].get(c, 0), first["computed"].get(c, 0) < prompt))
print("threshold %s: contender prompt %d in %d chunks %s" % (sys.argv[2], prompt, len(chunks), chunks))
for p, w, ct, still in mid:
    print("   %s arrived mid-prefill: waited %d step(s); first scheduled beside %d contender tokens%s" % (p, w, ct, " (prefill still running)" if still else " (prefill done)"))
print("   %d premium request(s) arrived mid-prefill" % len(mid))
EOF
}

run 0
run 256
if [ -n "${EVIDENCE_DIR:-}" ]; then
  mkdir -p "$EVIDENCE_DIR"
  cp "$WORK/summary.txt" "$EVIDENCE_DIR/"
  for t in 0 256; do cp "$WORK/t$t/step.jsonl" "$EVIDENCE_DIR/step-t$t.jsonl"; grep -E "Iteration\(|non-default args" "$WORK/t$t/engine.log" > "$EVIDENCE_DIR/engine-t$t.txt" || true; done
fi
