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
# The chart puts the component label on the plugin's pod template and the DaemonSet's selector only.
# The DaemonSet's own metadata carries the standard labels, so a label query for the component finds pods and never the
# DaemonSet; that is why attempt 4's S1-S3 found "no kubelet-plugin DaemonSet" right after a successful install.
PLUGIN_KEY=dra-driver-nvidia-gpu-component
PLUGIN_SEL=$PLUGIN_KEY=kubelet-plugin
# S1-S3 install their own release, so the bats suite's release (dra-driver-nvidia-gpu-batssuite) is removed first.
RELEASE=dra-gpu-session
# The plugin pods of this session's release only, so S2 never kills or watches a pod of the removed bats release.
OWN_PLUGIN_SEL=$PLUGIN_SEL,app.kubernetes.io/instance=$RELEASE
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

# plugin_ds echoes the name of this release's kubelet-plugin DaemonSet, found by the selector the chart gives it.
# It fails unless exactly one matches, so a second release's DaemonSet cannot be patched by mistake.
plugin_ds() {
  kubectl get ds -n "$NS" -l "app.kubernetes.io/instance=$RELEASE" -o json |
    jq -er --arg k "$PLUGIN_KEY" '[.items[] | select(.spec.selector.matchLabels[$k] == "kubelet-plugin") | .metadata.name] |
      if length == 1 then .[0] else error("\(length) kubelet-plugin DaemonSets in the release, not one") end'
}
plugin_pod() { kubectl get pods -n "$NS" -l "$OWN_PLUGIN_SEL" --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}'; }
# Any release's plugin pod counts, because every release registers the same driver and writes the same checkpoint.
no_plugin_pod() { [ -z "$(kubectl get pods -n "$NS" -l "$PLUGIN_SEL" -o name 2>/dev/null)" ]; }
slices_published() { [ -n "$(kubectl get resourceslices -o name 2>/dev/null)" ]; }
# foreign_plugin_gone is true once no plugin pod of any other release is left, terminating or not.
foreign_plugin_gone() {
  local o
  o=$(kubectl get pods -n "$NS" -l "$PLUGIN_SEL,app.kubernetes.io/instance!=$RELEASE" -o name) && [ -z "$o" ]
}

# found_plugin_ds sets PLUGIN_DS, so poll can retry it without a subshell losing the name.
found_plugin_ds() { PLUGIN_DS=$(plugin_ds) && [ -n "$PLUGIN_DS" ]; }

# plugin_ready waits for the DaemonSet's rollout and for the node's ResourceSlice, so a claim made next can allocate.
# The DaemonSet is looked up for a while rather than once, so a read that races the API is not taken for its absence.
plugin_ready() {
  PLUGIN_DS=
  poll 30 3 found_plugin_ds || { note "no kubelet-plugin DaemonSet of release $RELEASE"; return 1; }
  kubectl rollout status -n "$NS" "ds/$PLUGIN_DS" --timeout="$(left "$1")s" || return 1
  poll "$1" 5 slices_published
}

# install_chart ARGS... installs the chart from the pinned checkout with the settings every scenario shares, plus ARGS.
# nvidiaDriverRoot=/ and gpuResourcesEnabledOverride=true are upstream's nvkind CI values (hack/ci/gcp-nvkind).
# Compute domains are off because ComputeDomain needs IMEX, which a single L4 or A10G does not have.
install_chart() {
  install_chart_once "$@" && return 0
  note "the chart did not install; the cluster's state is in install-failure/"
  install_failure_state
  return 1
}

install_chart_once() {
  local r rels
  # A failed list must not read as no release, or the bats release would stay and collide with this one.
  # -a includes releases stuck pending or uninstalling, which the default listing hides.
  rels=$(helm list -n "$NS" -a -q) || { note "helm list failed"; return 1; }
  for r in $rels; do
    [ "$r" != "$RELEASE" ] || continue
    helm uninstall -n "$NS" "$r" --wait --timeout "$(left 120)s" || return 1
  done
  # Uninstall deletes the DaemonSet in the background, so its pods can outlive it.
  # A plugin of another release would serve the same driver and checkpoint as ours, so the install stops if one stays.
  # This is checked at every install, not only after an uninstall, so a straggler an earlier phase left is caught too.
  # 90 s covers the pod's default 30 s grace period with room to spare.
  poll 90 3 foreign_plugin_gone || { note "a plugin pod of another release was still present after 90 s"; return 1; }
  helm upgrade -i "$RELEASE" "$SRC/deployments/helm/dra-driver-nvidia-gpu" -n "$NS" --create-namespace \
    --set nvidiaDriverRoot=/ --set gpuResourcesEnabledOverride=true --set resources.computeDomains.enabled=false \
    --set logVerbosity=6 "$@" --wait --timeout "$(left 180)s" || return 1
  plugin_ready 120
}

# install_failure_state writes what attempt 4 lacked when its installs failed: the releases, what helm applied, what the
# cluster holds, and which cluster and kubeconfig the scripts were talking to.
# Each command's stderr goes into its own file, so a failed read is visible rather than empty.
install_failure_state() {
  local f="$D/install-failure"
  mkdir -p "$f"
  {
    echo "KUBECONFIG=${KUBECONFIG:-<unset>}"
    timeout "$(left 20)" kubectl config current-context
    timeout "$(left 20)" kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}'; echo
  } >"$f/context.txt" 2>&1
  timeout "$(left 20)" helm list -A -a >"$f/helm-list.txt" 2>&1
  timeout "$(left 20)" helm status -n "$NS" "$RELEASE" >"$f/helm-status.txt" 2>&1
  timeout "$(left 20)" helm get manifest -n "$NS" "$RELEASE" >"$f/helm-manifest.yaml" 2>&1
  timeout "$(left 20)" kubectl get ds,pods -A --show-labels -o wide >"$f/ds-pods.txt" 2>&1
  timeout "$(left 20)" kubectl get ds -n "$NS" -o yaml >"$f/ds.yaml" 2>&1
  timeout "$(left 20)" kubectl get ns >"$f/ns.txt" 2>&1
  timeout "$(left 20)" kubectl get events -n "$NS" --sort-by=.lastTimestamp >"$f/events.txt" 2>&1
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
