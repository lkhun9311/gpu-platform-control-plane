#!/usr/bin/env bash
# Concurrency 128 behind agentgateway, with the no-EPP controls interleaved run by run.
# For each EPP image it runs RUNS rounds of: one 128-call run through the EPP, one through agw-plain, one direct.
# Control rows are labelled with the EPP image deployed at the time, so each EPP cell has controls from the same minutes.
# Usage: KUBECONFIG=<private kubeconfig> c128-interleaved.sh <rendered.yaml> <out dir> <image>...
set -euo pipefail
rendered=$1
out=$2
shift 2
RUNS=${RUNS:-10}
C=${C:-128}
mkdir -p "$out"

for image in "$@"; do
  tag=${image##*:}
  sed "s#image: ghcr.io/llm-d/llm-d-router-endpoint-picker:v1.0.0#image: ${image}#" "$rendered" | kubectl apply -f - >/dev/null
  kubectl rollout status deploy/epp-epp --timeout=180s >/dev/null
  while [ "$(kubectl get pods -o name | grep -c '^pod/epp-epp-')" != 1 ]; do sleep 2; done
  until kubectl exec client -- /usr/local/bin/client -target epp-epp:8081 -n 2 -interval 1ms >/dev/null 2>&1; do sleep 2; done
  for i in $(seq 1 "$RUNS"); do
    for spec in "agw/$tag=epp-epp:8081" "agw/agw-plain@$tag=agw-plain:8081" "agw/direct@$tag=grpcstream-direct:50051"; do
      kubectl exec client -- /usr/local/bin/client -target "${spec#*=}" -arm "${spec%%=*}" -run "$i" -c "$C" >>"$out/stream.jsonl"
    done
  done
done
echo "wrote $(wc -l <"$out/stream.jsonl") rows under $out"
