#!/bin/bash
# Phase "cluster": the upstream checkout at the pinned commit, then upstream's own nvkind bring-up for a GPU VM.
#
# hack/ci/gcp-nvkind/lib/setup-nvkind-node.sh is what upstream's GPU CI runs on a GCE Deep Learning VM: Docker, the
# toolkit's CDI and volume-mount settings, Go, kubectl, helm, kind, nvkind, and a DRA-enabled cluster with one worker.
# Running theirs rather than a copy means a failure here is one their CI would also see.
set -u
. "$(dirname "$0")/lib.sh"
T0=$(date +%s)

note "fetch $DRA_REPO at $DRA_COMMIT"
rm -rf "$SRC" && git init -q "$SRC" || exit 1
timeout "$(left 300)" git -C "$SRC" fetch -q --depth 1 "$DRA_REPO" "$DRA_COMMIT" >"$D/fetch.log" 2>&1 || { note "FETCH FAILED"; exit 2; }
git -C "$SRC" checkout -q FETCH_HEAD || exit 2
[ "$(git -C "$SRC" rev-parse HEAD)" = "$DRA_COMMIT" ] || { note "the checkout is not $DRA_COMMIT"; exit 2; }
note "checked out $(git -C "$SRC" rev-parse HEAD)"

# S3 needs Kubernetes' DRAConsumableCapacity, alpha and off in 1.34; upstream's docs at the pinned commit require it on the
# API server, controller manager, scheduler and kubelet, which are exactly the five places upstream's template sets
# DynamicResourceAllocation, plus the cluster-wide list.
# Without it the API server drops the slice's requestPolicy and S3 would measure ordinary exclusive allocation.
TPL="$D/nvkind-config.yaml.tmpl"
sed -e 's/feature-gates: "DynamicResourceAllocation=true"/feature-gates: "DynamicResourceAllocation=true,DRAConsumableCapacity=true"/' \
  -e 's/^  DynamicResourceAllocation: true$/  DynamicResourceAllocation: true\n  DRAConsumableCapacity: true/' \
  "$SRC/hack/ci/gcp-nvkind/lib/nvkind-config.yaml.tmpl" >"$TPL" || exit 2
[ "$(grep -c 'feature-gates: "DynamicResourceAllocation=true,DRAConsumableCapacity=true"' "$TPL")" = 5 ] &&
  [ "$(grep -cx '  DRAConsumableCapacity: true' "$TPL")" = 1 ] || { note "upstream's nvkind template is not the shape this phase edits"; exit 2; }

note "setup-nvkind-node.sh, cluster $CLUSTER, Kubernetes $K8S_VERSION"
NVKIND_CLUSTER_NAME="$CLUSTER" NVKIND_K8S_VERSION="$K8S_VERSION" \
  NVKIND_CONFIG_PATH="$TPL" NVKIND_DELETE_EXISTING=true \
  bash "$SRC/hack/ci/gcp-nvkind/lib/setup-nvkind-node.sh" >"$D/setup-nvkind-node.log" 2>&1
rc=$?
note "setup-nvkind-node.sh exited $rc"
[ "$rc" = 0 ] || exit 2
{ kind version; nvkind --help 2>&1 | head -1; kubectl version --client; helm version; docker version; nvidia-ctk --version; } >"$D/versions.txt" 2>&1
kubectl get nodes -o wide --show-labels >"$D/nodes.txt" 2>&1
