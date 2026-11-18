#!/bin/bash
# Helpers shared by the phases of hack/dra-nvidia-gpu-session.sh, sourced on the instance.
#
# The runner exports D (the phase's evidence directory), DL (the phase's deadline, epoch seconds), SRC (the upstream
# checkout at the pinned commit), CLUSTER and WORKER (the kind cluster and its one GPU node container) before each phase.
# Nothing here calls `set`: each phase runs under `set -u` and checks failures itself, as hack/lib/spot-run.sh does.

NS=dra-driver-nvidia-gpu
# The plugin's checkpoint inside the kind node: kubeletPluginsDirectoryPath (/var/lib/kubelet/plugins) plus the driver
# name, cmd/gpu-kubelet-plugin/main.go at the pinned commit.
CP=/var/lib/kubelet/plugins/gpu.nvidia.com/checkpoint.json
PLUGIN_SEL=dra-driver-nvidia-gpu-component=kubelet-plugin
# S1-S3 install their own release, so the bats suite's release (dra-driver-nvidia-gpu-batssuite) is removed first.
RELEASE=dra-gpu-session
SNAP_N=0

note() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*" | tee -a "$D/steps.log"; }

# left N echoes N, or the seconds left before the phase's deadline if fewer, and never less than 1.
# GNU timeout reads 0 as no limit, so a bound computed at the deadline must not reach it.
left() { local l=$(( DL - $(date +%s) )); if [ "$l" -gt "$1" ]; then echo "$1"; else echo $(( l > 1 ? l : 1 )); fi; }

# enough N is true when at least N seconds remain, so a repetition that cannot finish is not started.
enough() { [ $(( DL - $(date +%s) )) -ge "$1" ]; }

# snap LABEL writes the checkpoint, the pods and claims, and the GPU's compute mode, numbered in the order taken.
snap() {
  local f
  mkdir -p "$D/snap"
  f="$D/snap/$(printf '%03d' "$SNAP_N")-$1"
  SNAP_N=$(( SNAP_N + 1 ))
  timeout 20 docker exec "$WORKER" cat "$CP" >"$f.checkpoint.json" 2>"$f.checkpoint.err" || echo "the checkpoint could not be read" >>"$f.checkpoint.err"
  timeout 20 kubectl get pods,resourceclaims -A -o wide >"$f.kubectl.txt" 2>&1
  timeout 20 nvidia-smi --query-gpu=index,name,compute_mode,memory.used --format=csv >"$f.nvidia-smi.csv" 2>&1
}

# step NAME CMD... runs CMD with the checkpoint snapped before and after it, and returns CMD's status.
step() {
  local name=$1 rc
  shift
  snap "$name.before"
  note "step $name: $*"
  "$@"
  rc=$?
  snap "$name.after"
  note "step $name: exit $rc"
  return "$rc"
}

# cp_state UID echoes the claim's checkpointState in the live checkpoint, "absent" when it has no entry, or "unread".
cp_state() {
  local j
  j=$(timeout 20 docker exec "$WORKER" cat "$CP" 2>/dev/null) || { echo unread; return 0; }
  jq -r --arg u "$1" '.v2.preparedClaims[$u].checkpointState // "absent"' <<<"$j" 2>/dev/null || echo unread
}

# poll SECONDS INTERVAL CMD... runs CMD until it succeeds or SECONDS (capped by the deadline) pass.
poll() {
  local until=$(( $(date +%s) + $(left "$1") )) interval=$2
  shift 2
  while :; do
    "$@" && return 0
    [ "$(date +%s)" -lt "$until" ] || return 1
    sleep "$interval"
  done
}

plugin_ds() { kubectl get ds -n "$NS" -l "$PLUGIN_SEL" -o jsonpath='{.items[0].metadata.name}'; }
plugin_pod() { kubectl get pods -n "$NS" -l "$PLUGIN_SEL" --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}'; }
no_plugin_pod() { [ -z "$(kubectl get pods -n "$NS" -l "$PLUGIN_SEL" -o name 2>/dev/null)" ]; }
slices_published() { [ -n "$(kubectl get resourceslices -o name 2>/dev/null)" ]; }

# plugin_ready waits for the DaemonSet's rollout and for the node's ResourceSlice, so a claim made next can allocate.
plugin_ready() {
  local ds
  ds=$(plugin_ds) && [ -n "$ds" ] || { note "no kubelet-plugin DaemonSet"; return 1; }
  kubectl rollout status -n "$NS" "ds/$ds" --timeout="$(left "$1")s" || return 1
  poll "$1" 5 slices_published
}

# install_chart ARGS... installs the chart from the pinned checkout with the settings every scenario shares, plus ARGS.
# nvidiaDriverRoot=/ and gpuResourcesEnabledOverride=true are upstream's nvkind CI values (hack/ci/gcp-nvkind).
# Compute domains are off because ComputeDomain needs IMEX, which a single L4 or A10G does not have.
install_chart() {
  local r
  for r in $(helm list -n "$NS" -q 2>/dev/null); do
    [ "$r" = "$RELEASE" ] || helm uninstall -n "$NS" "$r" --wait --timeout "$(left 120)s" || return 1
  done
  helm upgrade -i "$RELEASE" "$SRC/deployments/helm/dra-driver-nvidia-gpu" -n "$NS" --create-namespace \
    --set nvidiaDriverRoot=/ --set gpuResourcesEnabledOverride=true --set resources.computeDomains.enabled=false \
    --set logVerbosity=6 "$@" --wait --timeout "$(left 180)s" || return 1
  plugin_ready 120
}

# collect writes what a reader of the phase needs that the snapshots do not hold: the API objects, both sides' logs,
# and the GPU's full state.
collect() {
  timeout 30 kubectl get resourceclaims,resourceslices -A -o yaml >"$D/resources.yaml" 2>&1
  timeout 30 kubectl get events -A --sort-by=.lastTimestamp >"$D/events.txt" 2>&1
  timeout 30 kubectl logs -n "$NS" -l "$PLUGIN_SEL" -c gpus --tail=-1 --prefix >"$D/plugin.log" 2>&1
  # A plugin container that was killed or restarted left its log in the previous instance only.
  timeout 30 kubectl logs -n "$NS" -l "$PLUGIN_SEL" -c gpus --tail=-1 --prefix --previous >"$D/plugin-previous.log" 2>&1
  timeout 30 docker exec "$WORKER" journalctl -u kubelet --no-pager --since "@$T0" >"$D/kubelet.log" 2>&1
  timeout 30 nvidia-smi -q >"$D/nvidia-smi-q.txt" 2>&1
}
