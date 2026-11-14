#!/usr/bin/env bash
# Build llm-d-inference-sim at a given commit, run abort.py against it and keep the rows.
# Usage: experiments/s2-engine-abort/run.sh SIM_COMMIT OUT_JSONL [REPS]
set -euo pipefail

commit=${1:?simulator commit}
out=${2:?output jsonl}
reps=${3:-3}
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
log="$work/sim.log"
port=18000

cleanup() {
  if [[ -n "${sim_pid:-}" ]]; then kill "$sim_pid" 2>/dev/null || true; wait "$sim_pid" 2>/dev/null || true; fi
  rm -rf "$work"
}
trap cleanup EXIT

git clone -q https://github.com/llm-d/llm-d-inference-sim.git "$work/sim"
git -C "$work/sim" checkout -q "$commit"
resolved=$(git -C "$work/sim" rev-parse HEAD)
(cd "$work/sim" && CGO_ENABLED=0 go build -o "$work/llm-d-inference-sim" ./cmd/llm-d-inference-sim)

"$work/llm-d-inference-sim" --port "$port" --model m --max-num-seqs 1 \
  --inter-token-latency 100ms --time-to-first-token 100ms --max-model-len 4096 >"$log" 2>&1 &
sim_pid=$!
for _ in $(seq 1 100); do
  curl -sf "localhost:$port/metrics" >/dev/null && break
  sleep 0.1
done
curl -sf "localhost:$port/metrics" >/dev/null || { echo "simulator did not start"; tail -20 "$log"; exit 1; }

# The commit goes into every row so a result is never read against a different simulator.
python3 -I "$here/abort.py" "$port" "$reps" | while read -r row; do
  printf '%s\n' "${row%\}}, \"sim_commit\": \"$resolved\"}"
done >"$out"
status=${PIPESTATUS[0]}
cat "$out"
exit "$status"
