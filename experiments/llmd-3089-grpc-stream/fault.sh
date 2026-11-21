#!/usr/bin/env bash
# Fault injection for llm-d#3089 behind agentgateway, per EPP image, on the cluster from setup-cmp.sh.
# The backend and a second client pod run the llmd3089-grpcstream:fault image (stream padding, slow reads, timed cancels).
# Phases per image, in order:
#   alone:      a normal consumer, NORMAL_RUNS runs of 4 calls, nothing else running;
#   slow:       100 slow consumers (40 messages of 128 KiB, 1 s sleep before each read) with the normal consumer looping beside them;
#   disconnect: DISCONNECT_RUNS runs of 8 calls, each cancelled 400 ms after it starts;
#   kill:       16 calls of 40 messages, backend process killed with SIGKILL 1.5 s in;
#   recovered:  the normal consumer again after the backend is back.
# The first and last samples are repeated after a forced garbage collection, to compare the live heap before and after the faults.
# After each phase it waits SETTLE seconds and records EPP goroutines, running requests, request and outcome counters, and RSS.
# Usage: KUBECONFIG=<private kubeconfig> fault.sh <rendered.yaml> <out dir> <image>...
set -euo pipefail
rendered=$1
out=$2
shift 2
node=${NODE:-llm-d-3089-cmp-control-plane}
fault_image=${FAULT_IMAGE:-llmd3089-grpcstream:fault}
NORMAL_RUNS=${NORMAL_RUNS:-20}
DISCONNECT_RUNS=${DISCONNECT_RUNS:-25}
SETTLE=${SETTLE:-10}
here=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$out"

kubectl set image deploy/grpcstream backend="$fault_image" >/dev/null
kubectl rollout status deploy/grpcstream --timeout=120s >/dev/null
kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: client-fault
spec:
  containers:
  - name: client
    image: ${fault_image}
    imagePullPolicy: Never
    command: ["/usr/local/bin/backend", "-addr", "127.0.0.1:1"]
EOF
kubectl wait --for=condition=Ready pod/client-fault --timeout=120s >/dev/null

client() {
  kubectl exec client-fault -- /usr/local/bin/client -target epp-epp:8081 "$@"
}

rss_kb() {
  docker exec "$node" sh -c 'for d in /proc/[0-9]*; do case "$(tr "\0" " " < $d/cmdline 2>/dev/null)" in "/app/epp "*) awk "/^VmRSS/{print \$2}" $d/status;; esac; done'
}

# The EPP authenticates /metrics with TokenReview, so the scrape carries a service account token.
kubectl create serviceaccount metrics-reader --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl create clusterrolebinding metrics-reader --clusterrole=cluster-admin --serviceaccount=default:metrics-reader \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# snapshot appends one row of EPP state read from the EPP's own /metrics.
# With a third argument "gc" it first forces a garbage collection through pprof, so heap in use is the live heap.
snapshot() {
  local label=$1 phase=$2 gc=${3:-} pod pf scrape
  pod=$(kubectl get pods -o name | grep '^pod/epp-epp-' | head -1)
  scrape=$(mktemp)
  pflog=$(mktemp)
  # A random local port, so a leftover or concurrent forward cannot collide with this one.
  kubectl port-forward "$pod" :9090 >"$pflog" &
  pf=$!
  until port=$(grep -oP '127\.0\.0\.1:\K[0-9]+' "$pflog"); do sleep 0.2; done
  token=$(kubectl create token metrics-reader)
  if [ "$gc" = gc ]; then
    curl -sf -H "Authorization: Bearer $token" "http://127.0.0.1:${port}/debug/pprof/heap?gc=1" -o /dev/null
  fi
  curl -sf -H "Authorization: Bearer $token" "http://127.0.0.1:${port}/metrics" -o "$scrape"
  kill "$pf"
  wait "$pf" 2>/dev/null || true
  rm -f "$pflog"
  python3 "$here/metrics_row.py" "$label" "$phase" "$(rss_kb)" <"$scrape" >>"$out/epp.jsonl"
  rm -f "$scrape"
}

ready() {
  for _ in $(seq 1 60); do
    if client -n 2 -interval 1ms >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  echo "FAIL: no successful call through the EPP" >&2
  return 1
}

normal() {
  local label=$1 phase=$2 runs=$3
  for i in $(seq 1 "$runs"); do
    client -arm "$label" -run "$i" -c 4 | sed "s/^{/{\"phase\":\"$phase\",/" >>"$out/stream.jsonl" || true
  done
}

for image in "$@"; do
  label="agw/${image##*:}"
  sed "s#image: ghcr.io/llm-d/llm-d-router-endpoint-picker:v1.0.0#image: ${image}#" "$rendered" | kubectl apply -f - >/dev/null
  kubectl rollout status deploy/epp-epp --timeout=180s >/dev/null
  # A rollout leaves the old pod terminating for a while; the snapshot must read the new one only.
  while [ "$(kubectl get pods -o name | grep -c '^pod/epp-epp-')" != 1 ]; do sleep 2; done
  ready
  sleep "$SETTLE"
  snapshot "$label" base
  snapshot "$label" base-gc gc

  normal "$label" alone "$NORMAL_RUNS"
  sleep "$SETTLE"
  snapshot "$label" alone

  client -arm "$label" -c 100 -n 40 -msg-size 131072 -recv-delay 1s \
    | sed 's/^{/{"phase":"slow-consumer",/' >>"$out/stream.jsonl" &
  slow=$!
  sleep 2
  snapshot "$label" slow-start
  # A second sample midway through the slow readers' 40 s, when the most response bytes are outstanding.
  (sleep 18 && snapshot "$label" slow-mid) &
  mid=$!
  i=0
  while kill -0 "$slow" 2>/dev/null; do
    i=$((i + 1))
    client -arm "$label" -run "$i" -c 4 | sed 's/^{/{"phase":"beside-slow",/' >>"$out/stream.jsonl" || true
  done
  wait "$slow" || true
  wait "$mid"
  sleep "$SETTLE"
  snapshot "$label" slow

  for i in $(seq 1 "$DISCONNECT_RUNS"); do
    client -arm "$label" -run "$i" -c 8 -cancel-after 400ms | sed 's/^{/{"phase":"disconnect",/' >>"$out/stream.jsonl" || true
  done
  sleep "$SETTLE"
  snapshot "$label" disconnect

  client -arm "$label" -c 16 -n 40 | sed 's/^{/{"phase":"kill",/' >>"$out/stream.jsonl" &
  victims=$!
  sleep 1.5
  # The client pods idle on the same binary with another address, so the pattern names the serving backend only.
  docker exec "$node" pkill -9 -f '^/usr/local/bin/backend -addr :50051'
  wait "$victims" || true
  kubectl rollout status deploy/grpcstream --timeout=120s >/dev/null
  ready
  sleep "$SETTLE"
  snapshot "$label" kill

  normal "$label" recovered 10
  sleep "$SETTLE"
  snapshot "$label" recovered
  snapshot "$label" recovered-gc gc
done
kubectl delete pod client-fault --wait=false >/dev/null
echo "wrote $(cat "$out"/*.jsonl | wc -l) rows under $out"
