#!/usr/bin/env bash
# Checks whether the first 128-call run after an EPP pod starts is slower, and whether that depends on the image.
# It alternates the images given REPS times; each switch starts a new EPP pod.
# After one single-call readiness check it runs RUNS runs of 128 concurrent calls, so run 1 is the first burst the pod sees.
# Usage: KUBECONFIG=<private kubeconfig> c128-cold.sh <rendered.yaml> <out dir> <image>...
set -euo pipefail
rendered=$1
out=$2
shift 2
REPS=${REPS:-6}
RUNS=${RUNS:-3}
mkdir -p "$out"

for rep in $(seq 1 "$REPS"); do
  for image in "$@"; do
    tag=${image##*:}
    sed "s#image: ghcr.io/llm-d/llm-d-router-endpoint-picker:v1.0.0#image: ${image}#" "$rendered" | kubectl apply -f - >/dev/null
    kubectl rollout status deploy/epp-epp --timeout=180s >/dev/null
    while [ "$(kubectl get pods -o name | grep -c '^pod/epp-epp-')" != 1 ]; do sleep 2; done
    until kubectl exec client -- /usr/local/bin/client -target epp-epp:8081 -c 1 -n 2 -interval 1ms >/dev/null 2>&1; do sleep 2; done
    for i in $(seq 1 "$RUNS"); do
      kubectl exec client -- /usr/local/bin/client -target epp-epp:8081 -arm "agw/$tag" -run "$((rep * 100 + i))" -c 128 >>"$out/stream.jsonl"
    done
  done
done
echo "wrote $(wc -l <"$out/stream.jsonl") rows under $out"
