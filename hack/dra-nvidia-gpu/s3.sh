#!/bin/bash
# S3, #1572 on real NVML: ConsumableShares in memory mode, two claims of 4Gi each on one 24 GB GPU.
#
# #1572 is claimed by Thezone-1; this gathers evidence only.
# The mock-NVML bats test cannot show whether the second claim is blocked by the six capacities that carry no
# requestPolicy; a real ResourceSlice and a real scheduler can.
# A finding is the second claim unallocatable while the first's consumedCapacity holds the other six in full.
#
# The experiment is valid only if the first claim allocated before the second was submitted, and the published slice
# carries memory's requestPolicy, which the API server drops when DRAConsumableCapacity is off (it is alpha in 1.34).
# An invalid experiment exits 4, so it cannot pass for a result; a valid one exits 0 whichever way the second claim went.
set -u
. "$(dirname "$0")/lib.sh"
T0=$(date +%s)
S3_NS=s3-shares

install_chart --set featureGates.ConsumableShares=true --set consumableShares=memory || { note "the chart did not install"; exit 2; }

# manifest I prints claim mem-I of memory 4Gi and the pod that uses it; I = 0 also prints the namespace.
manifest() {
  [ "$1" != 0 ] || printf 'apiVersion: v1\nkind: Namespace\nmetadata:\n  name: %s\n---\n' "$S3_NS"
  cat <<EOF
apiVersion: resource.k8s.io/v1
kind: ResourceClaim
metadata:
  namespace: $S3_NS
  name: mem-$1
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
  name: pod-$1
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
    resourceClaimName: mem-$1
  tolerations:
  - key: "nvidia.com/gpu"
    operator: "Exists"
    effect: "NoSchedule"
EOF
}

ready() { kubectl wait -n "$S3_NS" --for=condition=Ready "pod/$1" --timeout="$(left "$2")s"; }
consumed() { kubectl get -n "$S3_NS" "resourceclaim/$1" -o jsonpath='{.status.allocation.devices.results[0].consumedCapacity}' 2>/dev/null; }

timeout 30 kubectl get resourceslices -o json >"$D/slices-before.json" 2>&1
policy=$(jq -r '[.items[].spec.devices[]? | .capacity.memory.requestPolicy // empty] | if length > 0 then "yes" else "no" end' \
  "$D/slices-before.json" 2>/dev/null || echo unread)
manifest 0 >"$D/claim-0.yaml"
manifest 1 >"$D/claim-1.yaml"
step apply-0 kubectl apply -f "$D/claim-0.yaml" || { note "the first claim was not applied"; collect; exit 4; }
step pod-0-ready ready pod-0 150 && r0=yes || r0=no
c0=$(consumed mem-0)
# The second claim is submitted only after the first holds its allocation, so the order is the experiment's, not the scheduler's.
r1=not-submitted
if [ "$r0" = yes ]; then
  step apply-1 kubectl apply -f "$D/claim-1.yaml" || { note "the second claim was not applied"; collect; exit 4; }
  step pod-1-ready ready pod-1 90 && r1=yes || r1=no
fi
kubectl get -n "$S3_NS" resourceclaims,pods -o yaml >"$D/objects.yaml" 2>&1
kubectl describe -n "$S3_NS" pod/pod-1 >"$D/pod-1.describe.txt" 2>&1
c1=$(consumed mem-1)
why=$(kubectl get events -n "$S3_NS" --field-selector involvedObject.name=pod-1,reason=FailedScheduling \
  -o jsonpath='{.items[-1:].message}' 2>/dev/null)
valid=no
[ "$policy" = yes ] && [ "$r0" = yes ] && [ -n "$c0" ] && [ "$r1" != not-submitted ] && valid=yes
printf 'valid\tslice_memory_request_policy\tpod_0_ready\tpod_1_ready\tconsumed_0\tconsumed_1\tpod_1_failed_scheduling\n%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  "$valid" "$policy" "$r0" "$r1" "${c0:-none}" "${c1:-none}" "${why:-none}" >"$D/result.tsv"
note "valid=$valid (requestPolicy $policy); pod-0 ready=$r0, pod-1 ready=$r1; mem-0 consumed ${c0:-none}"
collect
step delete kubectl delete ns "$S3_NS" --wait=true --timeout="$(left 60)s"
[ "$valid" = yes ] || exit 4
exit 0
