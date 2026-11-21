#!/usr/bin/env bash
# Compares EPP builds behind one gateway on an existing kind cluster.
# For each image it re-applies the rendered chart, then records:
#   stream rows: concurrency 1, 8 and 32, RUNS_C1 / RUNS_C8 / RUNS_C32 runs each, or the CELLS given;
#   runs rows: wall time and host load1 per client run;
#   unary rows: UNARY_RUNS UnaryCall digests;
#   epp rows: EPP process CPU seconds and RSS before and after the stream phase.
# With JSON=1 it instead switches the backend to its JSON mode and records the JSON control and EPP CPU/RSS.
# Usage: KUBECONFIG=<private kubeconfig> compare.sh <gateway label> <rendered.yaml> <out dir> <image>...
set -euo pipefail
gw=$1
rendered=$2
out=$3
shift 3
node=${NODE:-llm-d-3089-cmp-control-plane}
RUNS_C1=${RUNS_C1:-10}
RUNS_C8=${RUNS_C8:-5}
RUNS_C32=${RUNS_C32:-5}
UNARY_RUNS=${UNARY_RUNS:-3}
# CELLS lists "concurrency:runs" pairs for the stream phase; the default is the original three levels.
CELLS=${CELLS:-"1:$RUNS_C1 8:$RUNS_C8 32:$RUNS_C32"}
JSON_C=${JSON_C:-8}
JSON_REQUESTS=${JSON_REQUESTS:-250}
mkdir -p "$out"

# epp_proc prints "<pid> <utime+stime ticks> <VmHWM kB> <VmRSS kB>" for the single running EPP process.
epp_proc() {
  docker exec "$node" sh -c '
    for d in /proc/[0-9]*; do
      c=$(tr "\0" " " < "$d/cmdline" 2>/dev/null) || continue
      case "$c" in "/app/epp "*)
        t=$(awk "{print \$14+\$15}" "$d/stat")
        m=$(awk "/^VmHWM|^VmRSS/{printf \"%s \", \$2}" "$d/status")
        echo "${d#/proc/} $t $m";;
      esac
    done'
}

wait_single_epp() {
  for _ in $(seq 1 60); do
    if [ "$(epp_proc | wc -l)" = 1 ]; then
      return 0
    fi
    sleep 2
  done
  echo "FAIL: more or fewer than one EPP process on $node" >&2
  epp_proc >&2
  return 1
}

record_epp() {
  local label=$1 phase=$2
  read -r pid ticks hwm rss < <(epp_proc)
  printf '{"arm":"%s","phase":"%s","pid":%s,"cpu_ticks":%s,"hwm_kb":%s,"rss_kb":%s,"clk_tck":%s}\n' \
    "$label" "$phase" "$pid" "$ticks" "$hwm" "$rss" "$(docker exec "$node" getconf CLK_TCK)" >>"$out/epp.jsonl"
}

ready_check() {
  local mode=$1
  for _ in $(seq 1 30); do
    if [ "$mode" = json ]; then
      if kubectl exec client -- /usr/local/bin/client -mode json -target epp-epp:8081 -c 1 -requests 2 >/dev/null; then
        return 0
      fi
    elif kubectl exec client -- /usr/local/bin/client -target epp-epp:8081 -n 2 -interval 1ms >/dev/null; then
      return 0
    fi
    sleep 2
  done
  echo "FAIL: no successful call through the EPP" >&2
  return 1
}

swap() {
  local image=$1 mode=$2
  sed "s#image: ghcr.io/llm-d/llm-d-router-endpoint-picker:v1.0.0#image: ${image}#" "$rendered" | kubectl apply -f - >/dev/null
  kubectl rollout status deploy/epp-epp --timeout=180s >/dev/null
  got=$(kubectl get deploy epp-epp -o jsonpath='{.spec.template.spec.containers[?(@.name=="epp")].image}')
  if [ "$got" != "$image" ]; then
    echo "FAIL: epp image is $got, want $image" >&2
    return 1
  fi
  wait_single_epp
  ready_check "$mode"
}

stream_cells() {
  local label=$1 target=$2
  for spec in $CELLS; do
    c=${spec%%:*}
    runs=${spec#*:}
    for i in $(seq 1 "$runs"); do
      start=$(date +%s.%N)
      kubectl exec client -- /usr/local/bin/client -target "$target" -arm "$label" -run "$i" -c "$c" >>"$out/stream.jsonl"
      # Wall time includes kubectl exec start-up, so calls/s from it is a lower bound.
      printf '{"arm":"%s","run":%s,"c":%s,"start":%s,"end":%s,"load1":"%s"}\n' \
        "$label" "$i" "$c" "$start" "$(date +%s.%N)" "$(cut -d' ' -f1 /proc/loadavg)" >>"$out/runs.jsonl"
    done
  done
}

if [ "${JSON:-0}" = 1 ]; then
  kubectl patch deploy grpcstream --type=json \
    -p '[{"op":"replace","path":"/spec/template/spec/containers/0/args","value":["-addr",":50051","-mode","json"]}]' >/dev/null
  kubectl rollout status deploy/grpcstream --timeout=120s >/dev/null
  for image in "$@"; do
    label="$gw/${image##*:}"
    swap "$image" json
    record_epp "$label" json-before
    kubectl exec client -- /usr/local/bin/client -mode json -target epp-epp:8081 -arm "$label" -c "$JSON_C" -requests "$JSON_REQUESTS" >>"$out/json.jsonl"
    record_epp "$label" json-after
  done
  kubectl patch deploy grpcstream --type=json \
    -p '[{"op":"replace","path":"/spec/template/spec/containers/0/args","value":["-addr",":50051"]}]' >/dev/null
  kubectl rollout status deploy/grpcstream --timeout=120s >/dev/null
  exit 0
fi

for image in "$@"; do
  label="$gw/${image##*:}"
  swap "$image" grpc
  record_epp "$label" stream-before
  stream_cells "$label" epp-epp:8081
  record_epp "$label" stream-after
  for i in $(seq 1 "$UNARY_RUNS"); do
    kubectl exec client -- /usr/local/bin/client -mode unary -target epp-epp:8081 -arm "$label" -run "$i" >>"$out/unary.jsonl"
  done
done
if [ "${CONTROLS:-0}" = 1 ]; then
  stream_cells "$gw/direct" grpcstream-direct:50051
  stream_cells "$gw/agw-plain" agw-plain:8081
  for i in $(seq 1 "$UNARY_RUNS"); do
    kubectl exec client -- /usr/local/bin/client -mode unary -target grpcstream-direct:50051 -arm "$gw/direct" -run "$i" >>"$out/unary.jsonl"
  done
fi
echo "wrote $(cat "$out"/*.jsonl | wc -l) rows under $out"
