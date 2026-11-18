#!/bin/bash
# S3, #1572 on real NVML: ConsumableShares in memory mode, two claims of 4Gi each on one 24 GB GPU.
#
# #1572 is claimed by Thezone-1; this gathers evidence only.
# The mock-NVML bats test cannot show whether the second claim is blocked by the six capacities that carry no
# requestPolicy; a real ResourceSlice and a real scheduler can.
# A finding is the second claim unallocatable while the first's consumedCapacity holds the other six in full.
set -u
. "$(dirname "$0")/lib.sh"
T0=$(date +%s)
S3_NS=s3-shares

install_chart --set featureGates.ConsumableShares=true --set consumableShares=memory || { note "the chart did not install"; exit 2; }

manifest() {
  echo "apiVersion: v1
kind: Namespace
metadata:
  name: $S3_NS"
  for i in 0 1; do
    cat <<EOF
---
apiVersion: resource.k8s.io/v1
kind: ResourceClaim
metadata:
  namespace: $S3_NS
  name: mem-$i
spec:
  devices:
    requests:
    - name: gpu
      exactly:
        deviceClassName: gpu.nvidia.com
        capacity:
          requests:
            memory: 4Gi
---
apiVersion: v1
kind: Pod
metadata:
  namespace: $S3_NS
  name: pod-$i
spec:
  restartPolicy: Never
  containers:
  - name: ctr
    image: ubuntu:22.04
    command: ["bash", "-c"]
    args: ["nvidia-smi -L; trap 'exit 0' TERM; sleep 9999 & wait"]
    resources:
      claims:
      - name: gpu
  resourceClaims:
  - name: gpu
    resourceClaimName: mem-$i
  tolerations:
  - key: "nvidia.com/gpu"
    operator: "Exists"
    effect: "NoSchedule"
EOF
  done
}

ready() { kubectl wait -n "$S3_NS" --for=condition=Ready "pod/$1" --timeout="$(left "$2")s"; }

manifest >"$D/claims.yaml"
step apply kubectl apply -f "$D/claims.yaml" || { note "the claims were not applied"; collect; exit 2; }
step pod-0-ready ready pod-0 150 && r0=yes || r0=no
step pod-1-ready ready pod-1 90 && r1=yes || r1=no
kubectl get -n "$S3_NS" resourceclaims,pods -o yaml >"$D/objects.yaml" 2>&1
kubectl describe -n "$S3_NS" pod/pod-1 >"$D/pod-1.describe.txt" 2>&1
c0=$(kubectl get -n "$S3_NS" resourceclaim/mem-0 -o jsonpath='{.status.allocation.devices.results[0].consumedCapacity}' 2>/dev/null)
c1=$(kubectl get -n "$S3_NS" resourceclaim/mem-1 -o jsonpath='{.status.allocation.devices.results[0].consumedCapacity}' 2>/dev/null)
why=$(kubectl get events -n "$S3_NS" --field-selector involvedObject.name=pod-1,reason=FailedScheduling \
  -o jsonpath='{.items[-1:].message}' 2>/dev/null)
printf 'pod_0_ready\tpod_1_ready\tconsumed_0\tconsumed_1\tpod_1_failed_scheduling\n%s\t%s\t%s\t%s\t%s\n' \
  "$r0" "$r1" "${c0:-none}" "${c1:-none}" "${why:-none}" >"$D/result.tsv"
note "pod-0 ready=$r0, pod-1 ready=$r1; mem-0 consumed ${c0:-none}"
collect
step delete kubectl delete ns "$S3_NS" --wait=true --timeout="$(left 60)s"
exit 0
