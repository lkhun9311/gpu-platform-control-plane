#!/usr/bin/env bash
#
# One resize case on the local-up-cluster node, run as root.
# A Burstable pod allocates ALLOC_MI of anonymous memory once, above its memory limit, so the excess goes to swap and stays cold.
# Then the resize PATCH is sent, and the pod status, the kubelet log and the cgroup files are sampled for DURATION_S.
#
#   sudo bash run-case.sh <case-name> <out-dir> <pod-yaml> <resize-patch-json>
set -uo pipefail
NAME="$1"; OUT="$2"; POD_YAML="$3"; PATCH="$4"
DURATION_S="${DURATION_S:-300}"
INTERVAL_S="${INTERVAL_S:-20}"
export KUBECONFIG=/var/run/kubernetes/admin.kubeconfig
K=/src/kubernetes/_output/local/bin/linux/amd64/kubectl
KLOG=/var/log/k8s/kubelet.log
mkdir -p "$OUT"
POD=$(awk '/^  name:/{print $2; exit}' "$POD_YAML")

$K delete pod "$POD" --ignore-not-found --wait=true >/dev/null
$K apply -f "$POD_YAML" >/dev/null
$K wait --for=condition=Ready "pod/$POD" --timeout=180s >/dev/null || { echo "pod not ready"; exit 1; }
# The allocator prints READY once every page has been written once.
for _ in $(seq 1 60); do $K logs "$POD" 2>/dev/null | grep -q READY && break; sleep 2; done
cid=$($K get pod "$POD" -o jsonpath='{.status.containerStatuses[0].containerID}'); cid=${cid#containerd://}
uid=$($K get pod "$POD" -o jsonpath='{.metadata.uid}')
CG=$(find /sys/fs/cgroup/kubepods* -maxdepth 4 -type d -name "*$cid*" | head -1)
PCG=$(dirname "$CG")
echo "pod=$POD uid=$uid container_cgroup=$CG pod_cgroup=$PCG" > "$OUT/ids.txt"
# Let the swapped-out pages settle before the baseline.
# The S cases set SETTLE_S=0 to PATCH while the kubelet's stats may still predate the allocation.
sleep "${SETTLE_S:-10}"

sample() {
  local t="$1"
  local pj
  pj=$($K get pod "$POD" -o json)
  python3 - "$t" "$pj" "$CG" "$PCG" <<'PY'
import json, sys
t, pj, cg, pcg = sys.argv[1], json.loads(sys.argv[2]), sys.argv[3], sys.argv[4]
def rd(p):
    try:
        return open(p).read().strip()
    except OSError as e:
        return "ERR:" + e.strerror
st = pj["status"]
cs = st["containerStatuses"][0]
conds = {c["type"]: c for c in st.get("conditions", []) if c["type"].startswith("PodResize")}
row = {
    "t": t,
    "phase": st["phase"],
    "restarts": cs.get("restartCount"),
    "spec_limits": pj["spec"]["containers"][0]["resources"].get("limits"),
    "spec_requests": pj["spec"]["containers"][0]["resources"].get("requests"),
    "allocatedResources": cs.get("allocatedResources"),
    "containerStatuses.resources": cs.get("resources"),
    "status.resources": st.get("resources"),
    "observedGeneration": st.get("observedGeneration"),
    "generation": pj["metadata"].get("generation"),
    "resize_conditions": {k: {f: v.get(f) for f in ("status", "reason", "message", "observedGeneration")} for k, v in conds.items()},
    "ctr.memory.max": rd(cg + "/memory.max"),
    "ctr.memory.current": rd(cg + "/memory.current"),
    "ctr.memory.swap.max": rd(cg + "/memory.swap.max"),
    "ctr.memory.swap.current": rd(cg + "/memory.swap.current"),
    "pod.memory.max": rd(pcg + "/memory.max"),
    "pod.memory.swap.max": rd(pcg + "/memory.swap.max"),
    "pod.memory.swap.current": rd(pcg + "/memory.swap.current"),
    "ctr.oom_kill": [l for l in rd(cg + "/memory.events").splitlines() if l.startswith("oom_kill")],
}
print(json.dumps(row, sort_keys=True))
PY
}

kl_start=$(wc -l < "$KLOG")
sample before > "$OUT/samples.jsonl"
# The swap usage the kubelet's stats provider reports, and when it sampled it, as close to the PATCH as possible.
# The apiserver refuses to proxy to a 127.0.0.1 node, so the kubelet is asked directly with the admin client certificate.
curl -sk --cert /var/run/kubernetes/client-admin.crt --key /var/run/kubernetes/client-admin.key https://127.0.0.1:10250/stats/summary | python3 -c '
import json, sys
pod = sys.argv[1]
for p in json.load(sys.stdin)["pods"]:
    if p["podRef"]["name"] == pod:
        for c in p["containers"]:
            print(json.dumps({"container": c["name"], "swap": c.get("swap"), "memory_time": c.get("memory", {}).get("time")}))
' "$POD" > "$OUT/stats-summary-before-patch.jsonl" 2>&1
echo "{\"cgroup_swap_current_at_patch\": $(cat "$CG/memory.swap.current"), \"at\": \"$(date -u +%FT%T.%NZ)\"}" >> "$OUT/stats-summary-before-patch.jsonl"
start=$(date +%s)
$K patch pod "$POD" --subresource resize --type strategic -p "$PATCH" > "$OUT/patch.txt" 2>&1
prc=$?
echo "patch_rc=$prc at $(date -u +%FT%TZ)" >> "$OUT/patch.txt"
# A refused PATCH means the case never ran, so it must not produce samples that look like one.
[ "$prc" = 0 ] || { echo "PATCH REFUSED: $(head -3 "$OUT/patch.txt")"; exit 1; }
sent2=0
while [ $(( $(date +%s) - start )) -lt "$DURATION_S" ]; do
  sleep "$INTERVAL_S"
  # An optional second PATCH, for the case that raises the limit back after the first one stuck.
  if [ -n "${PATCH2:-}" ] && [ "$sent2" = 0 ] && [ $(( $(date +%s) - start )) -ge "${PATCH2_AT_S:-0}" ]; then
    $K patch pod "$POD" --subresource resize --type strategic -p "$PATCH2" >> "$OUT/patch.txt" 2>&1
    echo "patch2_rc=$? at $(date -u +%FT%TZ) +$(( $(date +%s) - start ))s" >> "$OUT/patch.txt"
    sent2=1
  fi
  sample "+$(( $(date +%s) - start ))s" >> "$OUT/samples.jsonl"
done
# Kubelet lines for this pod or for any resize, from the PATCH on.
tail -n +"$kl_start" "$KLOG" | grep -E "$POD|$uid" | grep -iE 'resize|swap|feasible' > "$OUT/kubelet.log"
$K get events --field-selector "involvedObject.name=$POD" -o wide > "$OUT/events.txt" 2>&1
$K get pod "$POD" -o yaml > "$OUT/pod-final.yaml"
$K logs "$POD" > "$OUT/container.log" 2>&1
$K delete pod "$POD" --wait=false >/dev/null
echo "done $NAME"
