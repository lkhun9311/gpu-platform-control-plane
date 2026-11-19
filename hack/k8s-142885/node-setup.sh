#!/usr/bin/env bash
#
# Runs on the instance as root: a single-node cluster from kubernetes/kubernetes#142885's head via hack/local-up-cluster.sh.
# The kubelet runs directly on the host (no kind, no nested container), on cgroup v2 with a 4 GiB swapfile and LimitedSwap.
#
#   sudo bash node-setup.sh <pr-sha> /root/bins.tgz
set -euo pipefail
SHA="${1:?pr sha}"
BINS="${2:?bins.tgz}"
until [ -e /var/run/k8s-142885-boot-done ]; do sleep 5; done
stat -fc %T /sys/fs/cgroup | grep -qx cgroup2fs
swapon --show --noheadings | grep -q /swapfile
# The second instance's apt mirror was unreachable at boot, and the kubelet then died on a missing CRI socket.
# containerd-from-github.sh installed the same containerd and runc versions there; this check makes that failure loud.
systemctl is-active --quiet containerd || { echo "containerd is not running; run containerd-from-github.sh first" >&2; exit 1; }

mkdir -p /src && cd /src
if [ ! -d kubernetes ]; then
  git init -q kubernetes
  git -C kubernetes fetch -q --depth 1 https://github.com/kubernetes/kubernetes.git "pull/142885/head"
  git -C kubernetes checkout -q FETCH_HEAD
fi
[ "$(git -C kubernetes rev-parse HEAD)" = "$SHA" ]
cd kubernetes
mkdir -p _output/local/bin/linux/amd64
tar -xzf "$BINS" -C _output/local/bin/linux/amd64
_output/local/bin/linux/amd64/kubelet --version
hack/install-etcd.sh >/dev/null
export PATH="/src/kubernetes/third_party/etcd:$PATH"

mkdir -p /var/log/k8s
# The gate must be on in the apiserver too, or limits.swap is not an accepted resource name.
export FEATURE_GATES="WorkloadControlledSwap=true"
export LIMITED_SWAP=true FAIL_SWAP_ON=false LOG_DIR=/var/log/k8s ENABLE_DAEMON=true
export CONTAINER_RUNTIME_ENDPOINT=unix:///run/containerd/containerd.sock
hack/local-up-cluster.sh -O > /var/log/k8s/local-up.log 2>&1
