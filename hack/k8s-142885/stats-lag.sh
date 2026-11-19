#!/usr/bin/env bash
#
# How long after the allocator finishes the kubelet's stats provider takes to report the container's swap usage.
# Polls the kubelet's /stats/summary and the cgroup's memory.swap.current every 2 s for 40 s from the READY line.
#
#   sudo bash stats-lag.sh <out-file>
set -uo pipefail
OUT="$1"
export KUBECONFIG=/var/run/kubernetes/admin.kubeconfig
K=/src/kubernetes/_output/local/bin/linux/amd64/kubectl
$K delete pod swap-explicit --ignore-not-found --wait=true >/dev/null
$K apply -f pod-explicit.yaml >/dev/null
$K wait --for=condition=Ready pod/swap-explicit --timeout=180s >/dev/null
until $K logs swap-explicit 2>/dev/null | grep -q READY; do sleep 0.5; done
cid=$($K get pod swap-explicit -o jsonpath='{.status.containerStatuses[0].containerID}'); cid=${cid#containerd://}
CG=$(find /sys/fs/cgroup/kubepods* -maxdepth 4 -type d -name "*$cid*" | head -1)
t0=$(date +%s)
for _ in $(seq 1 20); do
  s=$(curl -sk --cert /var/run/kubernetes/client-admin.crt --key /var/run/kubernetes/client-admin.key https://127.0.0.1:10250/stats/summary |
    python3 -c 'import json,sys
for p in json.load(sys.stdin)["pods"]:
    if p["podRef"]["name"] == "swap-explicit":
        print(json.dumps(p["containers"][0].get("swap")))')
  echo "+$(( $(date +%s) - t0 ))s cgroup=$(cat "$CG/memory.swap.current") summary=$s"
  sleep 2
done > "$OUT"
$K delete pod swap-explicit --wait=false >/dev/null
