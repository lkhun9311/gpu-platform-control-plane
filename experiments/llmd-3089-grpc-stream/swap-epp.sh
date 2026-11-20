#!/usr/bin/env bash
# Re-applies the rendered v1.0.0 chart with a different EPP image and waits for the pod to serve.
# Usage: KUBECONFIG=<private kubeconfig> swap-epp.sh <rendered.yaml> <image>
set -euo pipefail
rendered=$1
image=$2
sed "s#image: ghcr.io/llm-d/llm-d-router-endpoint-picker:v1.0.0#image: ${image}#" "$rendered" | kubectl apply -f - >/dev/null
kubectl rollout status deploy/epp-epp --timeout=180s
got=$(kubectl get deploy epp-epp -o jsonpath='{.spec.template.spec.containers[?(@.name=="epp")].image}')
if [ "$got" != "$image" ]; then
  echo "FAIL: epp image is $got, want $image" >&2
  exit 1
fi
# The proxy accepts connections before EPP has synced the endpoint, so wait for one good call.
for _ in $(seq 1 30); do
  if kubectl exec client -- /usr/local/bin/client -target epp-epp:8081 -arm warmup -n 2 -interval 1ms >/dev/null; then
    echo "epp ready with $image"
    exit 0
  fi
  sleep 2
done
echo "FAIL: no successful call through epp with $image" >&2
exit 1
