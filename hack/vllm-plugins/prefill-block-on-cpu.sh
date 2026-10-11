#!/usr/bin/env bash
# Measures, on vLLM v0.27.1's CPU build, how long a priority-0 request waits when it arrives while a priority-1
# request's long prefill runs, under --long-prefill-token-threshold 0, 384 and 256, with the engine light and with its
# sequence slots nearly full.
#
#   bash hack/vllm-plugins/prefill-block-on-cpu.sh            EVIDENCE_DIR=<dir> keeps the logs and the summary
#
# WHY. The pilot's step logs show a premium request waiting through a whole contender prefill, because the V1
# scheduler serves running requests first; the scheduler replay (hack/prospective-pilot/simulate.py) predicts a cap on
# a prefill's tokens per step lets the waiting request in. Both are claims about the real scheduler, checked here for
# free. The first version of this check measured only first allocation, with 16 slots and 4-token outputs; astra's
# review of v23 (finding 5) showed allocation is not completion and that the 64-slot regime went untested.
#
# HOW. For each threshold and regime, a fresh engine with the pilot's scheduler settings and 64 slots, warmed. In the
# "full" regime, 60 long-running priority-0 decoders are started first, so only a few slots are free. Then one
# contender with a prompt of about 3,000 tokens, and twelve 64-token-output premium requests 150 ms apart. Each premium
# request whose scheduler add came while the contender was still short of its prompt is judged by the steps from its
# add to the step that completes its prompt, and by the client's time from send to first content.
#
# WHAT IT CANNOT SAY: anything about A10G step times. The CPU's steps are slower and differently shaped.
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
  local threshold="$1" regime="$2" out="$WORK/t$1-$2"
  mkdir -p "$out"
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  docker run -d --name "$NAME" --cpus 8 --memory 16g --shm-size 2g -p "127.0.0.1:$PORT:8000" \
    -v "$HOME/.cache/huggingface:/root/.cache/huggingface" -v "$PWD:/plugins:ro" -v "$out:/out" \
    -e PYTHONPATH=/plugins -e STEP_LOG_PATH=/out/step.jsonl \
    "$IMAGE" "$MODEL" --no-async-scheduling --enable-logging-iteration-details \
    --scheduler-cls pilot_step_logger.PilotStepLoggingScheduler --scheduling-policy priority \
    --max-num-batched-tokens 512 --max-model-len 4096 --no-enable-prefix-caching \
    --long-prefill-token-threshold "$threshold" \
    --max-num-seqs 64 --gpu-memory-utilization 0.5 >/dev/null || fail "docker run ($threshold $regime)"
  for _ in $(seq 1 120); do
    curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/health" 2>/dev/null | grep -q 200 && break
    docker ps -q -f "name=$NAME" | grep -q . || fail "the engine exited: $(docker logs "$NAME" 2>&1 | tail -3 | tr '\n' ' ')"
    sleep 5
  done
  PORT="$PORT" MODEL="$MODEL" REGIME="$regime" python3 - "$out" <<'EOF' || fail "the client failed at $threshold $regime"
import json, os, sys, threading, time, urllib.request
out = sys.argv[1]
url = f"http://127.0.0.1:{os.environ['PORT']}/v1/chat/completions"
firsts, lock = {}, threading.Lock()
def send(rid, prio, content, cap):
    body = {"model": os.environ["MODEL"], "messages": [{"role": "user", "content": content}], "max_tokens": cap,
            "min_tokens": cap, "priority": prio, "stream": True}
    req = urllib.request.Request(url, data=json.dumps(body).encode(), headers={"Content-Type": "application/json", "X-Request-Id": rid})
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=1800) as r:
        for line in r:
            if line.startswith(b"data: {") and b'"content":"' in line and b'"content":""' not in line and rid not in firsts:
                with lock:
                    firsts[rid] = (time.time() - t0) * 1000
# Warm-up: the CPU build's first steps compile, and a mixed prefill-and-decode step is warmed too.
w = [threading.Thread(target=send, args=("warmup-%d" % i, 0, "hello " * (300 if i == 0 else 20), 8)) for i in range(4)]
[t.start() for t in w]; [t.join() for t in w]
bg = []
if os.environ["REGIME"] == "full":
    # 60 decoders with long outputs occupy 60 of the 64 slots for the whole measurement.
    for i in range(60):
        t = threading.Thread(target=send, args=("bg-%d" % i, 0, "hi", 400)); t.start(); bg.append(t)
    time.sleep(3)
c = threading.Thread(target=send, args=("contender", 1, "word " * 3000, 4)); c.start()
ps = []
for i in range(12):
    time.sleep(0.15)
    t = threading.Thread(target=send, args=("premium-%d" % i, 0, "hello " * 30, 64)); t.start(); ps.append(t)
for t in ps:
    t.join()
c.join()
json.dump(firsts, open(os.path.join(out, "client-first.json"), "w"))
for t in bg:
    t.join()
EOF
  for _ in $(seq 1 30); do
    touch "$out/step.jsonl.sentinel"; sleep 1
    python3 ../prospective-pilot/pilot_evidence.py terminal "$out/step.jsonl" >/dev/null 2>&1 && break
  done
  docker logs "$NAME" > "$out/engine.log" 2>&1
  python3 - "$out" "$threshold" "$regime" <<'EOF' | tee -a "$WORK/summary.txt"
import json, os, sys
out, threshold, regime = sys.argv[1:]
recs = [json.loads(l) for l in open(os.path.join(out, "step.jsonl"))]
firsts = json.load(open(os.path.join(out, "client-first.json")))
adds = {r["id"]: r for r in recs if r.get("ev") == "add"}
sched = [r for r in recs if r.get("ev") == "sched"]
c = next(e for e in adds if "contender" in e)
prompt = adds[c]["prompt"]
chunks = [s["tokens"].get(c, 0) for s in sched if c in s["tokens"] and s["computed"].get(c, 0) < prompt]
rows = []
for p in sorted((e for e in adds if "premium" in e), key=lambda e: adds[e]["seq"]):
    if not any(s["seq"] > adds[p]["seq"] and c in s["tokens"] and s["computed"].get(c, 0) < prompt for s in sched):
        continue
    mine = [s for s in sched if p in s["tokens"]]
    done = next(s for s in mine if s["computed"].get(p, 0) + s["tokens"][p] >= adds[p]["prompt"])
    steps = [s for s in sched if adds[p]["seq"] < s["seq"] <= done["seq"]]
    rid = p[len("chatcmpl-"):].rsplit("-", 1)[0]
    rows.append((len(steps), firsts.get(rid), max(len(s["tokens"]) for s in steps)))
busiest = max(len(s["tokens"]) for s in sched)
print("threshold %s, %s: contender %d tokens in %d chunks; busiest step %d requests; %d premium request(s) arrived mid-prefill"
      % (threshold, regime, prompt, len(chunks), busiest, len(rows)))
for n, f, occ in rows:
    print("   steps from add to prompt completion %2d   client send to first content %s ms   most requests in a step %d"
          % (n, "?" if f is None else "%.0f" % f, occ))
EOF
}

for regime in light full; do
  for t in 0 384 256; do run "$t" "$regime"; done
done
if [ -n "${EVIDENCE_DIR:-}" ]; then
  mkdir -p "$EVIDENCE_DIR"
  cp "$WORK/summary.txt" "$EVIDENCE_DIR/"
  for d in "$WORK"/t*; do
    b=$(basename "$d")
    cp "$d/step.jsonl" "$EVIDENCE_DIR/step-$b.jsonl"; cp "$d/client-first.json" "$EVIDENCE_DIR/client-first-$b.json"
    grep -E "Iteration\(|non-default args" "$d/engine.log" > "$EVIDENCE_DIR/engine-$b.txt" || true
  done
fi
