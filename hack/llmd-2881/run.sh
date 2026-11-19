#!/usr/bin/env bash
# One measured run: a fresh EPP and simulators on MODE's config, one seeded load, and the EPP's full log and metrics.
#
# Usage: hack/llmd-2881/run.sh MODE LABEL SEED [loadgen flags...]
set -euo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd)
LAB=$REPO/hack/llmd-2881/lab.sh
LAB_HOME=${LAB_HOME:-/home/lkhun9311/.cache/llmd-2881}
export KUBECONFIG=$LAB_HOME/kubeconfig
CTX=kind-gpuaas-llmd-2881
EPP=tinyllama-1-1b-chat-v1-0-endpoint-picker
GATEWAY=http://127.0.0.1:${GATEWAY_HOST_PORT:-30611}
METRICS_PORT=${METRICS_PORT:-19611}

MODE=${1:?mode}
LABEL=${2:?label}
SEED=${3:?seed}
shift 3
RUN=$REPO/hack/llmd-2881/runs/$(date -u +%Y%m%dT%H%M%SZ)-$MODE-$LABEL-s$SEED
# A run's evidence is written once.
[ ! -e "$RUN" ] || { echo "run: $RUN exists" >&2; exit 1; }
mkdir -p "$RUN"
k() { kubectl --context "$CTX" --request-timeout=30s "$@"; }

"$LAB" pins >"$RUN/pins.txt"
"$LAB" mode "$MODE" | tee "$RUN/mode.log"
cp "$LAB_HOME/epp-config-$MODE.yaml" "$RUN/epp-config.yaml"
k get pods -o wide >"$RUN/pods.txt"
EPP_POD=$(k get pods -l app=$EPP -o jsonpath='{.items[0].metadata.name}')

# The EPP serves only after it has listed the pool's endpoints.
for _ in $(seq 1 60); do
  curl -sf -o /dev/null "$GATEWAY/v1/models" && break
  sleep 2
done
# The full log is streamed from the start, because kubelet rotates a container log at 10 MiB and kubectl logs would then
# return only the newest file.
# The stream bypasses k, whose 30 s request timeout cut the first pilot's stream off mid-run.
kubectl --context "$CTX" logs -f "$EPP_POD" >"$RUN/epp.log" 2>"$RUN/epp-log-stream.err" &
LOG_PID=$!
kubectl --context "$CTX" port-forward "pod/$EPP_POD" "$METRICS_PORT:9090" >"$RUN/port-forward.log" 2>&1 &
PF_PID=$!
trap 'kill $LOG_PID $PF_PID 2>/dev/null || true' EXIT
for _ in $(seq 1 30); do
  curl -sf -o /dev/null "http://127.0.0.1:$METRICS_PORT/metrics" && break
  sleep 1
done

# Three sequential requests warm the tokenizer path; they are recorded apart from the measured load.
"$LAB_HOME/loadgen" -url "$GATEWAY" -seed 999 -bursts 3 -burst-size 1 -mean-gap 1s -window 0 -tag "warm" \
  -out "$RUN/warmup.jsonl" 2>>"$RUN/loadgen.log"
sleep 3
curl -sf "http://127.0.0.1:$METRICS_PORT/metrics" >"$RUN/metrics-before.txt"
date -u +%FT%T.%NZ >"$RUN/load-start.txt"
"$LAB_HOME/loadgen" -url "$GATEWAY" -seed "$SEED" -tag "$MODE-$LABEL-s$SEED" -out "$RUN/requests.jsonl" "$@" 2>>"$RUN/loadgen.log"
date -u +%FT%T.%NZ >"$RUN/load-end.txt"
sleep 3
curl -sf "http://127.0.0.1:$METRICS_PORT/metrics" >"$RUN/metrics-after.txt"
echo "$*" >"$RUN/loadgen-args.txt"
# Each planned prompt's token count, from the render server the EPP's token-producer calls, sent after the load so it
# cannot disturb it.
kubectl --context "$CTX" port-forward svc/vllm-render "${RENDER_PORT:-18082}:8082" >"$RUN/port-forward-render.log" 2>&1 &
RPF_PID=$!
sleep 2
"$LAB_HOME/loadgen" -render-url "http://127.0.0.1:${RENDER_PORT:-18082}" -seed "$SEED" -tag "$MODE-$LABEL-s$SEED" \
  -out "$RUN/tokens.jsonl" "$@" 2>>"$RUN/loadgen.log"
kill $RPF_PID 2>/dev/null || true
k logs "$EPP_POD" --previous >/dev/null 2>&1 && echo "EPP restarted during the run" >>"$RUN/WARNING.txt"
k get pods -o wide >"$RUN/pods-after.txt"
sleep 1
echo "$RUN"
