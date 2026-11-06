#!/usr/bin/env bash
# Reproduces the cases of docs/superpowers/specs/2026-11-07-linux-diagnosis-cases-design.md on two throwaway kind clusters.
# Usage: hack/linux-diag/run.sh [OUT_DIR]; REPS (default 3) and KEEP_CLUSTERS=1 are honoured.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
NODE_IMAGE='kindest/node:v1.37.0@sha256:a1ed56cfb0e7b93589bdf97c8cd566405a265939e3620fc4f5de89adff580ae5'
PY_IMAGE='python@sha256:2f17fc044b579bab302c2e8054d3a686e2cb9a83de48e70534b94cd8ebbe06a9'
REPS="${REPS:-3}"
OUT="${1:-$REPO/hack/linux-diag-$(date -u +%Y%m%dT%H%M%SZ)}"
# Only clusters with this prefix are ever created or deleted here; the shared clusters are never touched.
PREFIX=lddiag
CASES=(c1 c2a c2b c3 c4)

mkdir -p "$OUT"
exec > >(tee -a "$OUT/run.log") 2>&1

cluster_for() {
  case "$1" in
    c2b) echo "$PREFIX-single" ;;
    *) echo "$PREFIX-group" ;;
  esac
}

create_cluster() {
  local name=$1 single=$2 cfg="$OUT/kind-$1.yaml"
  cat > "$cfg" <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: KubeletConfiguration
    singleProcessOOMKill: $single
EOF
  if kind get clusters | grep -qx "$name"; then
    echo "refuse: cluster $name already exists; delete it first so its state is this run's" >&2
    exit 1
  fi
  kind create cluster --name "$name" --image "$NODE_IMAGE" --config "$cfg" --wait 180s
}

delete_clusters() {
  [ "${KEEP_CLUSTERS:-0}" = 1 ] && return 0
  local c
  for c in "$PREFIX-group" "$PREFIX-single"; do
    if kind get clusters | grep -qx "$c"; then kind delete cluster --name "$c"; fi
  done
}
trap delete_clusters EXIT

# The kubelet's effective value, read back rather than trusted from the config file we wrote.
effective_single() {
  local ctx=$1 node=$2
  kubectl --context "$ctx" get --raw "/api/v1/nodes/$node/proxy/configz" |
    python3 -c 'import json,sys; print(str(json.load(sys.stdin)["kubeletconfig"].get("singleProcessOOMKill", False)).lower())'
}

record_versions() {
  local name=$1 node="$1-control-plane" f="$OUT/versions-$1.txt"
  {
    echo "kernel $(uname -r)"
    echo "containerd $(docker exec "$node" containerd --version)"
    echo "kubelet $(docker exec "$node" kubelet --version)"
    echo "single_process_oom_kill $(effective_single "kind-$name" "$node")"
  } > "$f"
}

# A shell function the workloads paste in; it prints the cgroup files the checker reads, between markers.
DUMP='dump() { echo "--- cgroup begin"; for f in memory.max memory.current memory.peak memory.oom.group; do echo "$f $(cat /sys/fs/cgroup/$f)"; done; sed "s/^/memory.events /" /sys/fs/cgroup/memory.events; sed "s/^/memory.stat /" /sys/fs/cgroup/memory.stat; echo "--- cgroup end"; }'

workload() {
  case "$1" in
    c1) printf '%s' 'echo begin; exec python3 -c "b = bytearray(256 << 20); print(\"survived\")"' ;;
    c2a|c2b) printf '%s' "$DUMP"'; echo begin; python3 -c "b = bytearray(256 << 20); print(\"survived\")"; echo child-exit=$?; dump; echo parent-done; sleep 5' ;;
    c3) printf '%s' "$DUMP"'; echo begin; df -k /shm; dd if=/dev/zero of=/shm/f bs=1M count=192; echo dd-exit=$?; dump' ;;
    c4) printf '%s' "$DUMP"'; echo begin; dd if=/dev/zero of=/d/f bs=1M count=512; echo write-exit=$?; dd if=/d/f of=/dev/null bs=1M; echo read-exit=$?; echo read-done $(date +%s); dump; sleep 40' ;;
  esac
}

manifest() {
  local case=$1 pod=$2 vol='' mount=''
  case "$case" in
    c3) vol='  volumes: [{name: v, emptyDir: {medium: Memory}}]'; mount='    volumeMounts: [{name: v, mountPath: /shm}]' ;;
    c4) vol='  volumes: [{name: v, emptyDir: {}}]'; mount='    volumeMounts: [{name: v, mountPath: /d}]' ;;
  esac
  local script
  script="$(workload "$case" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"
  cat <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $pod
  labels: {app: lddiag, case: $case}
spec:
  restartPolicy: Never
  terminationGracePeriodSeconds: 1
$vol
  containers:
  - name: w
    image: $PY_IMAGE
    imagePullPolicy: IfNotPresent
    resources: {limits: {memory: 128Mi, cpu: 500m}}
$mount
    command: ["sh", "-c"]
    args: [$script]
EOF
}

run_case() {
  local case=$1 rep=$2 cluster ctx node pod dir
  cluster="$(cluster_for "$case")"
  ctx="kind-$cluster"
  node="$cluster-control-plane"
  pod="$case-r$rep"
  dir="$OUT/$pod"
  mkdir -p "$dir"
  local want=false
  [ "$case" = c2b ] && want=true
  local have
  have="$(effective_single "$ctx" "$node")"
  manifest "$case" "$pod" > "$dir/pod.yaml"
  local t0 t_end='' phase='' i
  t0=$(date +%s)
  kubectl --context "$ctx" apply -f "$dir/pod.yaml" > /dev/null
  # Poll for up to 180 s, then 10 s more after the end so a late reason is seen.
  local tail_left=10
  for i in $(seq 1 240); do
    kubectl --context "$ctx" get pod "$pod" -o json > "$dir/status-$(printf %03d "$i").json"
    phase="$(jq -r .status.phase "$dir/status-$(printf %03d "$i").json")"
    if [ "$case" = c4 ] && [ "$phase" = Running ] && [ $((i % 2)) = 0 ]; then
      kubectl --context "$ctx" get --raw "/api/v1/nodes/$node/proxy/stats/summary" |
        jq -c --arg p "$pod" '.pods[] | select(.podRef.name == $p) | .containers[] | select(.name == "w") | .memory' >> "$dir/summary.jsonl"
    fi
    if [ "$phase" = Succeeded ] || [ "$phase" = Failed ]; then
      [ -z "$t_end" ] && t_end=$(date +%s)
      tail_left=$((tail_left - 1))
      [ "$tail_left" -le 0 ] && break
    fi
    sleep 1
  done
  kubectl --context "$ctx" logs "$pod" > "$dir/log.txt" 2>&1 || echo "logs-exit=$?" >> "$dir/log.txt"
  local until=$(( ${t_end:-$(date +%s)} + 10 )) jrc=0
  journalctl -k -o short-monotonic --no-pager --since "@$((t0 - 1))" --until "@$until" > "$dir/journal.txt" || jrc=$?
  jq -n --arg case "$case" --argjson rep "$rep" --arg cluster "$cluster" --arg want "$want" --arg have "$have" \
    --argjson t0 "$t0" --arg t_end "${t_end:-}" --argjson jrc "$jrc" --arg phase "$phase" \
    '{case: $case, rep: $rep, cluster: $cluster, single_process_oom_kill_wanted: $want, single_process_oom_kill_effective: $have, t_start: $t0, t_end: (if $t_end == "" then null else ($t_end | tonumber) end), journal_exit: $jrc, last_phase: $phase}' > "$dir/case.json"
  kubectl --context "$ctx" delete pod "$pod" --wait=true > /dev/null
  echo "case $pod: phase=$phase journal_exit=$jrc"
}

create_cluster "$PREFIX-group" false
create_cluster "$PREFIX-single" true
record_versions "$PREFIX-group"
record_versions "$PREFIX-single"
docker exec "$PREFIX-group-control-plane" crictl pull "$PY_IMAGE" > /dev/null
docker exec "$PREFIX-single-control-plane" crictl pull "$PY_IMAGE" > /dev/null
docker exec "$PREFIX-group-control-plane" crictl inspecti "$PY_IMAGE" > "$OUT/image-inspect.json"

# Repetitions are interleaved across cases so no case runs all early or all late.
for rep in $(seq 1 "$REPS"); do
  for case in "${CASES[@]}"; do
    run_case "$case" "$rep"
  done
done

python3 "$HERE/check.py" "$OUT"
