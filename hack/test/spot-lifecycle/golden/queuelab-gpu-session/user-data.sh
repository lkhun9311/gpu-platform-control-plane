#!/bin/bash
exec > >(tee /var/log/qlgpu.log) 2>&1
set -x
( sleep 8400; shutdown -h now ) &

BUCKET="stub-bucket"
PREFIX="run"
SOURCE_SHA="<SHA256>"
COMMIT="<COMMIT>"
REPS="4"
DOSES="grace-bounded"

upload() { aws s3 cp "$1" "s3://$BUCKET/$PREFIX/$2" || true; }
trap 'upload /var/log/qlgpu.log log.txt; shutdown -h now' EXIT

# The source is verified before it is trusted, for the reason the harness binary is in the other runner: a
# truncated download that still extracts produces a build, and a build produces numbers.
aws s3 cp "s3://$BUCKET/$PREFIX/src/source.tgz" /tmp/source.tgz
got=$(sha256sum /tmp/source.tgz | cut -d' ' -f1)
if [ "$got" != "$SOURCE_SHA" ]; then
  echo "source checksum mismatch: expected $SOURCE_SHA, got $got"
  exit 1
fi
mkdir -p /src && tar -xzf /tmp/source.tgz -C /src
cd /src

# ---------------------------------------------------------------- the cards, before anything else
#
# Preflight check 1 of 4. A machine that does not report four cards is not the machine this session was
# costed for, and finding that out after twenty minutes of cluster bring-up is finding it out too late.
nvidia-smi --query-gpu=index,name,memory.total --format=csv > /tmp/nvidia-smi.csv || exit 1
upload /tmp/nvidia-smi.csv preflight-nvidia-smi.csv
cards=$(tail -n +2 /tmp/nvidia-smi.csv | wc -l)
if [ "$cards" -lt 4 ]; then
  echo "PREFLIGHT FAILED: $cards cards, the protocol needs 4 (2 for the trace, 2 held by the occupier)"
  exit 1
fi

# ---------------------------------------------------------------- kind, with the host's cards visible
#
# kind nodes are containers, so the GPUs reach them only if the container runtime passes them through by
# default. The toolkit is on the deep-learning AMI already; what it needs is to be the DEFAULT runtime and
# to accept the visible-devices variable as a volume mount, which is how the device plugin inside kind
# claims a card.
# Installed rather than assumed. The deep-learning AMI has shipped the toolkit for a while, and a session
# that discovers otherwise twenty minutes in has paid for the discovery.
if ! command -v nvidia-ctk >/dev/null 2>&1; then
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
    > /etc/apt/sources.list.d/nvidia-container-toolkit.list
  apt-get update && apt-get install -y nvidia-container-toolkit || exit 1
fi
nvidia-ctk runtime configure --runtime=docker --set-as-default
sed -i 's/^#accept-nvidia-visible-devices-as-volume-mounts.*/accept-nvidia-visible-devices-as-volume-mounts = true/' \
  /etc/nvidia-container-runtime/config.toml || true
grep -q 'accept-nvidia-visible-devices-as-volume-mounts = true' /etc/nvidia-container-runtime/config.toml \
  || echo 'accept-nvidia-visible-devices-as-volume-mounts = true' >> /etc/nvidia-container-runtime/config.toml
systemctl restart docker
sleep 5

curl -fsSLo /usr/local/bin/kind https://kind.sigs.k8s.io/dl/v0.24.0/kind-linux-amd64
chmod +x /usr/local/bin/kind
curl -fsSLo /usr/local/bin/kubectl "https://dl.k8s.io/release/v1.31.0/bin/linux/amd64/kubectl"
chmod +x /usr/local/bin/kubectl

# One worker, because the protocol measures one worker and a second would only add a factor this session is
# not buying. The control plane stays separate so stopping anything on the worker cannot take the apiserver.
cat > /tmp/kind.yaml <<'KINDEOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: qlgpu
nodes:
  - role: control-plane
  - role: worker
KINDEOF
kind create cluster --config /tmp/kind.yaml --wait 300s || exit 1
export KUBECONFIG=/root/.kube/config
kubectl cluster-info

# ---------------------------------------------------------------- the platform under test
kubectl apply --server-side -f https://github.com/kubernetes-sigs/kueue/releases/download/v0.18.3/manifests.yaml
kubectl -n kueue-system wait --for=condition=Available deploy/kueue-controller-manager --timeout=300s || exit 1

# docker build inside a container, so no Go is needed on this host.
make docker-build IMG=controller:latest || exit 1
kind load docker-image controller:latest --name qlgpu || exit 1

# The CRDs are applied from the committed files rather than through `make install`.
#
# That target depends on manifests, which depends on controller-gen, which the Makefile installs with Go --
# absent from this AMI -- and which would REGENERATE the CRDs before applying them. Regenerating on a rented
# box means the cluster gets whatever this machine's controller-gen produces rather than what the commit
# says, which is the opposite of the provenance this session is trying to record. `make manifests` is a
# no-op on this tree, so the committed files already are the generated ones.
kubectl apply --server-side -f config/crd/bases/ || exit 1
kubectl kustomize config/operator | kubectl apply --server-side -f - || exit 1

# The node label both DaemonSets select on, which nothing in this repository applies.
#
# config/nvidia-device-plugin and config/dcgm-exporter both carry
# `nodeSelector: platform.lkhun9311.github.io/gpu: "true"`, and every other reference to that label in the
# tree READS it -- m5b-arms.sh and m5b-gpu-session.sh look up the node group by it. In production it comes
# from the EKS node group. On a kind cluster nobody applies it, so both DaemonSets would sit Pending, the
# node would advertise nothing, and preflight check 2 would fail after the instance, the driver, the
# cluster and the operator had all been paid for.
#
# The plugin's own comment explains why this label and not nvidia.com/gpu.present: GPU Feature Discovery is
# not deployed here, and selecting on that one would leave the plugin unschedulable while the node reads
# downstream as "no GPU nodes" rather than as "the plugin never ran".
kubectl label node qlgpu-worker platform.lkhun9311.github.io/gpu=true --overwrite || exit 1

# The worker is deliberately NOT tainted nvidia.com/gpu=present:NoSchedule the way the production node
# group is. This cluster has one worker and kind's control plane carries its own NoSchedule taint, so
# tainting it would leave Kueue and the operator with nowhere to run.

# The REAL device plugin, not config/device-plugin, which is the fake one that makes every GPU-second a
# reservation. This is the line the whole session is about.
kubectl kustomize config/nvidia-device-plugin | kubectl apply -f - || exit 1
kubectl kustomize config/dcgm-exporter | kubectl apply -f - || exit 1

# ---------------------------------------------------------------- preflight, checks 2 to 4
#
# Charged before any measurement because it is the failure that wastes the session, and it costs minutes.
# Check 4 is the one that matters: the first three can all pass on a machine where attribution is still
# impossible, and attribution is the deliverable.
for _ in $(seq 1 60); do
  adv=$(kubectl get node qlgpu-worker -o jsonpath='{.status.allocatable.nvidia\.com/gpu}' 2>/dev/null || echo 0)
  [ "${adv:-0}" -ge 4 ] && break
  sleep 5
done
echo "worker advertises ${adv:-0} nvidia.com/gpu"
kubectl get nodes -o wide > /tmp/preflight-nodes.txt
upload /tmp/preflight-nodes.txt preflight-nodes.txt
if [ "${adv:-0}" -lt 4 ]; then
  echo "PREFLIGHT FAILED: the real device plugin advertises ${adv:-0} of 4 cards"
  exit 1
fi

# Preflight checks 3 and 4 are NOT written here. hack/gpu-session.sh takes the termination canary and then
# runs `queuelabrun -device-preflight`, which applies a GPU-holding Pod with the same template, placement,
# toleration and finalizer a real run gets, and reports which of the driver calls answered. A second
# preflight written into this file would be a probe invented for the occasion, which is the thing that mode
# exists to avoid being.

# ---------------------------------------------------------------- the study, shipping records as they land
#
# gpu-session.sh runs the whole study itself -- surplus occupancy, canary, per-worker exporter route,
# preflight, then the runs -- so this does not reimplement its loop. What it adds is the one thing a
# low placement score demands: an uploader watching the session directory, so a record reaches S3 within
# seconds of being written rather than at the end. An interruption after six of eight runs must cost the
# seventh and the eighth, not all of them.
export EXDIR=/tmp/session
mkdir -p "$EXDIR"

(
  # Ships anything new every ten seconds, and keeps shipping until the study exits. Records are small and
  # S3 puts are idempotent by key, so re-uploading an unchanged file costs nothing worth optimising.
  while :; do
    for f in "$EXDIR"/*.json; do
      [ -e "$f" ] && aws s3 cp "$f" "s3://$BUCKET/$PREFIX/runs/$(basename "$f")" >/dev/null 2>&1
    done
    sleep 10
  done
) &
UPLOADER=$!

rc=0
# The worker is a POSITIONAL argument. gpu-session.sh takes WORKERS=("$@"), and calling it with none used
# to reach `WORKERS[0]: unbound variable` after everything above had already been paid for.
REPS="$REPS" EXDIR="$EXDIR" DOSES="$DOSES" \
  bash hack/gpu-session.sh qlgpu-worker >/tmp/study.log 2>&1 || rc=$?
kill "$UPLOADER" 2>/dev/null || true

upload /tmp/study.log study.log
tar -czf /tmp/session.tgz -C /tmp session
upload /tmp/session.tgz session.tgz
echo "$COMMIT" > /tmp/commit.txt && upload /tmp/commit.txt commit.txt
# A final sweep, because the watcher may have been killed between a write and its tick.
for f in "$EXDIR"/*.json; do
  [ -e "$f" ] && upload "$f" "runs/$(basename "$f")"
done

# DONE means records exist, not that the study exited zero. A study that produced six good records and
# then failed is worth collecting -- and a study that exited zero having written none is not.
#
# Counted with a glob into an array rather than `ls ... | wc -l`. Under errexit and pipefail, ls exits 2
# when its glob matches nothing, the pipeline inherits it, and the script dies at the count -- taking with
# it the message that was about to explain the empty case. The characterization suite caught exactly that
# on the host side of this script, where the operator was left with no refusal at all in the one run that
# most needed one.
shopt -s nullglob
records=("$EXDIR"/*.json)
accepted=${#records[@]}
shopt -u nullglob
echo "records written: $accepted, study rc=$rc"
if [ "$accepted" -gt 0 ]; then
  touch /tmp/DONE && upload /tmp/DONE DONE
else
  echo "no record was written; DONE withheld"
fi
