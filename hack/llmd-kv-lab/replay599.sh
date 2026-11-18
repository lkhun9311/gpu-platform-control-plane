#!/usr/bin/env bash
# Issue #599: replays experiment A's shared-942 trace, its prompts a tenth as long, through llm-d-router's endpoint
# picker under each arm, and writes per request where it went and what the serving simulator had cached, beside each
# simulator's queue and cache gauges sampled every second.
#
# The lab must be up with two simulators and the replay's simulator shape; the command that does it is printed by
# "replay599.sh env", so the shape is written once here rather than remembered.
# Every arm starts from an EPP running its config and freshly started simulators (hack/llmd-kv-lab.sh mode), so each
# begins with empty caches and an empty index, as experiment A's cells did.
#
# Usage: hack/llmd-kv-lab/replay599.sh env | run [ARM ...]
#   REPLAY_LIMIT=N sends only the first N requests, for a smoke test of the apparatus; such a run is not a result.
#   default arms: rr approx approx-load precise precise-load
set -euo pipefail

# The simulator shape, derived in docs/14_LLMD_KV_ROUTING_LAB.md ("#599"):
# - two simulators, experiment A's backend count;
# - 2,769 blocks of 16 tokens, 51.1 shared prefixes of 867 tokens, the 1.5:1 ratio of 77 prompts to one engine's cache
#   that experiment A chose so that routing decides which prefixes each engine keeps;
# - one request at a time, a miss's prefill about 0.95 s and a hit's about 0.09 s, the A10G's 1.0 against 0.09 s,
#   so a queue forms where a miss-heavy burst lands, the effect the shared-942 tail came from.
REPLAY_ENV=(LAB_SIM_REPLICAS=2 LAB_SIM_KV_BLOCKS=2769
  "LAB_SIM_ARGS=--max-num-seqs=1 --prefill-overhead=60ms --prefill-time-per-token=1ms --inter-token-latency=5ms")
SCALE=10

if [ "${1:-}" = env ]; then
  printf 'export %q\n' "${REPLAY_ENV[@]}"
  exit 0
fi
[ "${1:-}" = run ] || { echo "usage: $0 env | run [ARM ...]" >&2; exit 2; }
shift
# The lab script reads these when it brings the simulators up, so a shell without them would have built another shape.
for kv in "${REPLAY_ENV[@]}"; do
  name=${kv%%=*}
  [ "${!name:-}" = "${kv#*=}" ] || { echo "replay599: $name is '${!name:-}', want '${kv#*=}'; run: eval \"\$($0 env)\" and bring the lab up again" >&2; exit 1; }
done

SAY_AS=replay599
# shellcheck source=hack/llmd-kv-lab/lib.sh
source "$(dirname "$0")/lib.sh"

ARMS=("$@")
[ ${#ARMS[@]} -gt 0 ] || ARMS=(rr approx approx-load precise precise-load)

lab_init
REPLAY=$LAB_HOME/replay
go build -o "$REPLAY" "$REPO/hack/llmd-kv-lab/replay"
# The running simulators must carry the shape above: an arm measured on another shape would be a different experiment.
args=$(k get deployment vllm-d -o jsonpath='{.spec.template.spec.containers[0].args}')
for want in "--kv-cache-size=$LAB_SIM_KV_BLOCKS" $LAB_SIM_ARGS; do
  grep -qF -- "\"$want\"" <<<"$args" || { say "simulator args lack $want: $args"; exit 1; }
done
echo "$args" >"$RUN/sim-args.json"
"$REPLAY" -print-trace -scale "$SCALE" | tee "$RUN/trace-shape.txt"

for arm in "${ARMS[@]}"; do
  fresh_arm "$arm"
  snap before
  targets=
  for p in $(sim_pods); do targets+="$p=$(pod_url "$p")/metrics,"; done
  say "[$arm] replaying shared-942 at 1/$SCALE prompt length"
  # The EPP's log is followed while the replay runs, because at --v 4 kubelet rotates it at 10 MiB within minutes and
  # "kubectl logs" afterwards returned only the last fifth of run 20261118-replay599-1's score lines.
  k logs -f "$(epp_pod)" >"$RUN/$arm/epp-follow.log" 2>&1 &
  follow=$!
  "$REPLAY" -arm "$arm" -scale "$SCALE" -out "$RUN/$arm/replay.jsonl" -samples "$RUN/$arm/samples.jsonl" \
    -metrics "${targets%,}" ${REPLAY_LIMIT:+-limit "$REPLAY_LIMIT"} || say "[$arm] replay reported failed requests"
  sleep 2
  kill "$follow" 2>/dev/null || true
  wait "$follow" 2>/dev/null || true
  snap after
  gzip -f "$RUN/$arm"/epp-*.log
  for p in $(sim_pods); do k logs "$p" -c vllm >"$RUN/$arm/sim-$p.log" 2>&1 || true; done
  gzip -f "$RUN/$arm"/sim-*.log
done
python3 -I "$REPO/hack/llmd-kv-lab/replay599.py" "$RUN" | tee "$RUN/summary.txt"
say "replay written to $RUN"
