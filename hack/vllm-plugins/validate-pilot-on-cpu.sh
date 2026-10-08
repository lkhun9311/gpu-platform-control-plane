#!/usr/bin/env bash
# Runs pilot_step_logger.py inside vLLM v0.27.1's CPU build, under the pilot's scheduler settings, and checks what the
# kind rehearsal's stub cannot: vLLM's own behaviour (design page, "Rehearsals before purchase", the CPU run).
#
#   bash hack/vllm-plugins/validate-pilot-on-cpu.sh            EVIDENCE_DIR=<dir> keeps what the PASS rests on
#
# WHAT IT ESTABLISHES, each from the real engine:
#   1. the plugin's sequence numbers, sentinel and terminal record (pilot_evidence.py terminal);
#   2. the request-ID join from the client's X-Request-Id to vLLM's scheduler, and
#   3. the scheduler-side priority, both by pilot_evidence.py priority, which matches every scheduled ID to exactly
#      one client row and compares the priority the scheduler received with the tenant's registered one;
#   4. the prefill and decode split: each request's prefill tokens, summed over its sched records by the report's
#      rule, equal its prompt, and its decode tokens equal its output less the one sampled in the prefill step;
#   5. the fence's alignment of plugin steps with the engine's own iteration lines (pilot_report.step_alignment).
#
# WHAT IT CANNOT SAY: anything about the A10G's timing. The model is the 0.5B, which the CPU build runs in minutes.
set -euo pipefail
cd "$(dirname "$0")" || exit 1
IMAGE="${IMAGE:-vllm/vllm-openai-cpu:v0.27.1-x86_64}"
MODEL="${MODEL:-Qwen/Qwen2.5-0.5B-Instruct}"
PORT="${PORT:-18001}"
NAME="vllm-pilot-validate"
WORK="$(mktemp -d)"
trap 'docker rm -f "$NAME" >/dev/null 2>&1 || true; rm -rf "$WORK"' EXIT

fail() { printf 'VALIDATION FAILED: %s\n' "$*" >&2; exit 1; }
command -v docker >/dev/null || fail "docker is not on PATH"

docker rm -f "$NAME" >/dev/null 2>&1 || true
# The pilot's scheduler settings (hack/lib/prospective-pilot.sh, pp_engine_args): the 512 budget, priority
# scheduling, synchronous scheduling and iteration logging, with the pilot's plugin.
docker run -d --name "$NAME" --cpus 8 --memory 16g --shm-size 2g -p "127.0.0.1:$PORT:8000" \
  -v "$HOME/.cache/huggingface:/root/.cache/huggingface" -v "$PWD:/plugins:ro" -v "$WORK:/out" \
  -e PYTHONPATH=/plugins -e STEP_LOG_PATH=/out/step.jsonl \
  "$IMAGE" "$MODEL" --no-async-scheduling --enable-logging-iteration-details \
  --scheduler-cls pilot_step_logger.PilotStepLoggingScheduler --scheduling-policy priority \
  --max-num-batched-tokens 512 --max-model-len 4096 --no-enable-prefix-caching \
  --max-num-seqs 16 --gpu-memory-utilization 0.5 >/dev/null || fail "docker run"
for _ in $(seq 1 120); do
  curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/health" 2>/dev/null | grep -q 200 && break
  docker ps -q -f "name=$NAME" | grep -q . || fail "the engine exited: $(docker logs "$NAME" 2>&1 | grep -E 'Error' | tail -2)"
  sleep 5
done
curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/health" 2>/dev/null | grep -q 200 \
  || fail "the engine never became healthy: $(docker logs "$NAME" 2>&1 | tail -5 | tr '\n' ' ' | cut -c1-600)"
docker logs "$NAME" 2>&1 | grep -q "Using custom scheduler class pilot_step_logger.PilotStepLoggingScheduler" \
  || fail "the engine did not load the pilot's plugin"

# The client: premium requests at priority 0 and contenders at 1, overlapping, so the scheduler holds both tiers at
# once, then the fence. Rows carry the client ID and tenant as the replay's raw rows do; usage is kept per ID.
PORT="$PORT" MODEL="$MODEL" python3 - "$WORK/rows.jsonl" "$WORK/usage.json" <<'EOF' || fail "the client could not complete its requests"
import json, os, sys, threading, time, urllib.request
url = f"http://127.0.0.1:{os.environ['PORT']}/v1/chat/completions"
rows, usage, lock = [], {}, threading.Lock()
def send(rid, tenant, prio, content, cap):
    body = {"model": os.environ["MODEL"], "messages": [{"role": "user", "content": content}], "max_tokens": cap,
            "min_tokens": cap, "priority": prio, "stream": True, "stream_options": {"include_usage": True}}
    req = urllib.request.Request(url, data=json.dumps(body).encode(), headers={"Content-Type": "application/json", "X-Request-Id": rid})
    with urllib.request.urlopen(req, timeout=900) as r:
        for line in r:
            if line.startswith(b"data: {") and b'"usage"' in line:
                u = json.loads(line[6:]).get("usage")
                if u:
                    with lock:
                        usage[rid] = u
    if tenant:
        with lock:
            rows.append({"requestId": rid, "tenant": tenant})
threads = []
for i in range(3):
    threads.append(threading.Thread(target=send, args=("pp-A-off-1-%d" % (2 * i), "standard-noisy", 1, "word " * 1200, 16)))
    threads.append(threading.Thread(target=send, args=("pp-A-off-1-%d" % (2 * i + 1), "premium-1", 0, "hello " * 40, 8)))
for t in threads:
    t.start(); time.sleep(0.5)
for t in threads:
    t.join()
send("fence-off-1", None, 0, "x", 1)
json.dump(usage, open(sys.argv[2], "w"))
with open(sys.argv[1], "w") as f:
    for r in rows:
        f.write(json.dumps(r) + "\n")
if len(usage) != 7:
    sys.exit(f"usage was reported for {len(usage)} of 7 requests")
EOF

# The sentinel, until the plugin's writer answers with a complete terminal record, as capture does.
for _ in $(seq 1 30); do
  touch "$WORK/step.jsonl.sentinel"; sleep 2
  python3 ../prospective-pilot/pilot_evidence.py terminal "$WORK/step.jsonl" >/dev/null && break
done
python3 ../prospective-pilot/pilot_evidence.py terminal "$WORK/step.jsonl" || fail "no complete terminal record after the sentinel"
docker logs "$NAME" > "$WORK/engine.log" 2>&1
python3 ../prospective-pilot/pilot_evidence.py priority "$WORK/step.jsonl" "$WORK/rows.jsonl" \
  || fail "the scheduler's IDs or priorities do not match the client's"

python3 - "$WORK/step.jsonl" "$WORK/engine.log" "$WORK/rows.jsonl" "$WORK/usage.json" <<'EOF' | tee "$WORK/summary.txt" || fail "the split or the alignment does not hold"
import json, sys
sys.path.insert(0, "../prospective-pilot")
import pilot_report as pr
steps = pr.jsonl(sys.argv[1])
ok, why = pr.step_alignment(steps, pr.iteration_totals(sys.argv[2]))
if not ok:
    sys.exit("alignment: " + why)
usage = json.load(open(sys.argv[4]))
ids = [r["requestId"] for r in pr.jsonl(sys.argv[3])] + ["fence-off-1"]
adds = {r["id"]: r for r in steps if r.get("ev") == "add"}
split = {}
for s in steps:
    if s.get("ev") != "sched":
        continue
    for eid, n in s["tokens"].items():
        cid = pr.match_client(eid, ids)
        if cid is None:
            sys.exit("scheduled %s matches no client ID" % eid)
        prompt = adds[eid]["prompt"]
        pf = min(n, max(prompt - s["computed"].get(eid, 0), 0))
        p, d = split.get(cid, (0, 0))
        split[cid] = (p + pf, d + n - pf)
bad = []
for cid, (p, d) in sorted(split.items()):
    u = usage[cid]
    if p != u["prompt_tokens"] or d != u["completion_tokens"] - 1:
        bad.append("%s: prefill %d decode %d, usage prompt %d output %d" % (cid, p, d, u["prompt_tokens"], u["completion_tokens"]))
    print("%s prefill=%d decode=%d prompt=%d output=%d" % (cid, p, d, u["prompt_tokens"], u["completion_tokens"]))
if bad or len(split) != 7:
    sys.exit("split: %s (%d requests scheduled)" % (bad, len(split)))
print("aligned through the fence; every request's prefill is its prompt and its decode its output less one")
EOF
if [ -n "${EVIDENCE_DIR:-}" ]; then
  mkdir -p "$EVIDENCE_DIR"
  cp "$WORK/step.jsonl" "$WORK/rows.jsonl" "$WORK/usage.json" "$WORK/summary.txt" "$EVIDENCE_DIR/"
  grep -E "Iteration\(|non-default args|custom scheduler" "$WORK/engine.log" > "$EVIDENCE_DIR/engine-log-excerpt.txt"
  sha256sum pilot_step_logger.py ../prospective-pilot/pilot_evidence.py ../prospective-pilot/pilot_report.py > "$EVIDENCE_DIR/sha256.txt"
  printf '%s\n' "$IMAGE" "$MODEL" > "$EVIDENCE_DIR/engine.txt"
fi
echo "PASS: the pilot's plugin, ID join, priority and split hold on vLLM v0.27.1"
