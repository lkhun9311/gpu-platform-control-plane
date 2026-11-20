#!/usr/bin/env bash
# Runs the client N times per arm, interleaving arms so drift hits every arm alike.
# Usage: KUBECONFIG=<private kubeconfig> measure.sh <label> <runs> <out.jsonl>
set -euo pipefail
label=$1
runs=$2
out=$3
: >"$out"
for i in $(seq 1 "$runs"); do
  for arm in epp:epp-epp:8081 agw-plain:agw-plain:8081 direct:grpcstream-direct:50051; do
    name=${arm%%:*}
    target=${arm#*:}
    kubectl exec client -- /usr/local/bin/client -target "$target" -arm "$label/$name" -run "$i" >>"$out"
  done
done
echo "wrote $(wc -l <"$out") rows to $out"
