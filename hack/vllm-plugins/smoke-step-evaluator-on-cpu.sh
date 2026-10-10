#!/usr/bin/env bash
# Runs the step-boundary evaluator's join, decomposition and feature code on REAL engine output, for free.
#
# WHY THIS EXISTS
#
# step_boundary.py's self-tests feed it hand-built records. Whether a real archive's pieces -- the replay's raw
# rows with their request ids, vLLM's engine ids, the instrument's step log and the engine's own log -- fit
# together the way the evaluator assumes can only be seen on real output. v0.27.1's CPU build produces it here.
#
# WHAT IT RUNS
#
# Three small cells, each on a fresh CPU engine with the instrument loaded and requests sent by the real
# benchharness replay with --request-id-prefix: a serial cell, a burst cell and a staggered cell (two decoders,
# then a late prefill while they decode). Then, on that archive: check_step_log per cell with the client's
# output counts (the instrument gate), step_boundary.decompose on the staggered cell, and
# step_boundary.episodes_of_cell on all three.
#
# WHAT IT CANNOT SAY
#
# Anything about the A10G, and nothing about the registered matrix: the traces are hand-made and short, so the
# design check, the overhead gate and the fit are not run. It shows that the parts join.
set -euo pipefail
cd "$(dirname "$0")/../.." || exit 1
ROOT=$(pwd)
IMAGE="${IMAGE:-vllm/vllm-openai-cpu:v0.27.1-x86_64}"
MODEL="${MODEL:-Qwen/Qwen2.5-0.5B-Instruct}"
PORT="${PORT:-18000}"
NAME="vllm-step-evaluator-smoke"
WORK="$(mktemp -d)"
RUN="$WORK/run"
mkdir -p "$RUN"
trap 'docker rm -f "$NAME" >/dev/null 2>&1 || true; [ "${KEEP:-0}" = 1 ] && echo "kept $WORK" || rm -rf "$WORK"' EXIT
fail() { printf 'SMOKE FAILED: %s\n' "$*" >&2; exit 1; }

go build -o "$WORK/bh" ./cmd/benchharness || fail "build benchharness"
"$WORK/bh" gen-trace --seed 31 --duration-ms 3000000 --study step-boundary-2026-10-06 --arm serial-step \
  --model "$MODEL" --gateway-url "http://127.0.0.1:$PORT" --timeout-ms 600000 \
  --trace-out "$WORK/template.jsonl" --manifest-out "$WORK/template.yaml" >/dev/null || fail "gen-trace for the manifest template"

# Hand-made traces: 256 tokens is 1,174 characters (internal/bench/inputlengths.go), 512 is 2,506.
python3 - "$RUN" <<'EOF'
import json, os, sys
run = sys.argv[1]
def row(i, off, chars, cap, mn=0):
    r = {"index": i, "offsetMs": off, "tenant": "premium-1", "promptLenChars": chars, "maxOutputTokens": cap, "isNoisy": False}
    if mn:
        r["minOutputTokens"] = mn
    return r
cells = {
    "serial-step": [row(i, 4000 * i, 1174 if i < 3 else 2506, 16) for i in range(6)],
    "burst-step": [row(4 * e + r, 10000 * e, 1174, 16) for e in range(2) for r in range(4)],
    "stagger-step": [r for e in range(2) for r in (row(3 * e, 20000 * e, 1174, 128, 128), row(3 * e + 1, 20000 * e, 1174, 128, 128),
                                                     row(3 * e + 2, 20000 * e + 2000, 1174, 16))],
}
for arm, rows in cells.items():
    with open(os.path.join(run, f"trace-{arm}-1.jsonl"), "w") as f:
        f.writelines(json.dumps(r) + "\n" for r in rows)
EOF

for arm in serial-step burst-step stagger-step; do
  trace="$RUN/trace-$arm-1.jsonl"
  sum=$(sha256sum "$trace" | cut -c1-64)
  sed -e "s|^arm: .*|arm: $arm|" -e "s|^traceChecksum: .*|traceChecksum: $sum|" -e "s|^tracePath: .*|tracePath: $trace|" \
    "$WORK/template.yaml" > "$RUN/manifest-$arm-1.yaml"
  mkdir -p "$WORK/out-$arm"
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  docker run -d --name "$NAME" --cpus 8 --memory 16g --shm-size 2g -p "127.0.0.1:$PORT:8000" \
    -v "$HOME/.cache/huggingface:/root/.cache/huggingface" -v "$ROOT/hack/vllm-plugins:/plugins:ro" -v "$WORK/out-$arm:/out" \
    -e PYTHONPATH=/plugins -e STEP_LOG_PATH=/out/step.jsonl \
    "$IMAGE" "$MODEL" --no-async-scheduling --enable-logging-iteration-details --no-enable-prefix-caching \
    --scheduler-cls step_logging_scheduler.StepLoggingScheduler --max-num-batched-tokens 512 --max-model-len 4096 \
    --max-num-seqs 16 --gpu-memory-utilization 0.5 >/dev/null || fail "docker run for $arm"
  for _ in $(seq 1 120); do
    curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/health" 2>/dev/null | grep -q 200 && break
    sleep 5
  done
  # One warm-up request first, as every registered cell has: the CPU build's first step takes tens of seconds,
  # and without it the serial cell's requests overlapped and no episode was drained. Its id and output count go
  # to raw-warmup, so the instrument's one-to-one join holds as it does in a real cell.
  PORT="$PORT" MODEL="$MODEL" python3 - "$RUN/raw-warmup-$arm-1.jsonl" "$arm-1-warmup-0" <<'PYEOF' || fail "warm-up for $arm"
import json, os, sys, urllib.request
body = {"model": os.environ["MODEL"], "messages": [{"role": "user", "content": "hello " * 200}], "max_tokens": 8,
        "stream": True, "stream_options": {"include_usage": True}}
req = urllib.request.Request(f"http://127.0.0.1:{os.environ['PORT']}/v1/chat/completions", data=json.dumps(body).encode(),
                             headers={"Content-Type": "application/json", "X-Request-Id": sys.argv[2]})
out = None
with urllib.request.urlopen(req, timeout=600) as r:
    for line in r:
        if line.startswith(b"data: {") and b'"usage"' in line:
            u = json.loads(line[6:]).get("usage")
            out = u["completion_tokens"] if u else out
json.dump({"index": 0, "requestId": sys.argv[2], "engineOutputTokens": out}, open(sys.argv[1], "w"))
open(sys.argv[1], "a").write("\n")
PYEOF
  "$WORK/bh" replay --manifest "$RUN/manifest-$arm-1.yaml" --target "http://127.0.0.1:$PORT" \
    --request-id-prefix "$arm-1-measured" --raw-out "$RUN/raw-$arm-1.jsonl" >/dev/null || fail "replay $arm"
  last=$(python3 -c "import json,sys;print(max(json.loads(l)['index'] for l in open(sys.argv[1])))" "$trace")
  ok=0
  for _ in $(seq 1 30); do
    if grep -q "\"id\":\"chatcmpl-$arm-1-measured-$last-" "$WORK/out-$arm/step.jsonl" 2>/dev/null \
       && tail -1 "$WORK/out-$arm/step.jsonl" | grep -q '"ev":"flush"'; then ok=1; break; fi
    sleep 1
  done
  [ "$ok" = 1 ] || fail "$arm: the instrument's last batch was not written"
  cp "$WORK/out-$arm/step.jsonl" "$RUN/step-log-$arm-1.jsonl"
  docker logs "$NAME" > "$RUN/engine-log-$arm-1.txt" 2>&1
  docker rm -f "$NAME" >/dev/null
  echo "cell $arm: $(wc -l < "$RUN/raw-$arm-1.jsonl") rows, $(grep -c '"ev":"sched"' "$RUN/step-log-$arm-1.jsonl") steps"
done

python3 - "$RUN" <<'EOF'
import json, os, sys
sys.path.insert(0, "hack/tail-crossing-model")
import step_boundary as sb, check_step_log
run = sys.argv[1]
for arm in ("serial-step", "burst-step", "stagger-step"):
    outputs = {r["requestId"]: r["engineOutputTokens"] for r in sb.raw_rows(run, arm, 1)}
    lines = check_step_log.check(open(f"{run}/step-log-{arm}-1.jsonl").read().splitlines(),
                                 open(f"{run}/engine-log-{arm}-1.txt").read().splitlines(), outputs)
    print(f"instrument {arm}: " + "; ".join(lines))
    eps = sb.episodes_of_cell(run, arm, 1, arm.split("-")[0])
    assert eps and all(e["steps"] for e in eps), f"{arm}: an episode with no steps"
    late = sum(st["late"] for e in eps for st in e["steps"])
    print(f"episodes {arm}: {len(eps)}, steps {sum(len(e['steps']) for e in eps)}, late-prefill steps {late}")
for d in sb.decompose(run, "stagger-step", 1):
    print("decompose", d["setting"], {k: round(v, 3) for k, v in d["ms"].items()})
print("PASS: the evaluator's joins hold on real engine output")
EOF
