#!/bin/bash
exec > >(tee /var/log/gpufault.log) 2>&1
set -x
GF_START=$(date +%s)
# The first backstop, armed before anything can fail, counts from the instance's own start; LaunchTime precedes it,
# so the precise one below, armed once LaunchTime is read, always fires first.
( sleep 7000; shutdown -h now ) &
BUCKET="gpufault-gpu-007635145730"
PREFIX="gpu-fault-20261026T193353Z-68b64c6e"
SOURCE_SHA="75fd6fb95e1e121033d44f6576a19eac08600ffa91ce90a16ab84558faf5a4ab"
IMAGES_SHA="a9444877aded1913246ff9f7e49e8597b134dbb56c9e7dba9b6840a01380e6b3"
COMMIT="6d9d087f65fbbe70968740ef8598d599fbf51b8b"
upload() { aws s3 cp --only-show-errors "$1" "s3://$BUCKET/$PREFIX/$2" || true; }
trap 'upload /var/log/gpufault.log log.txt; shutdown -h now' EXIT
aws s3 cp --only-show-errors "s3://$BUCKET/$PREFIX/src/source.tgz" /tmp/source.tgz
[ "$(sha256sum /tmp/source.tgz | cut -d' ' -f1)" = "$SOURCE_SHA" ] || { echo "source checksum mismatch"; exit 1; }
mkdir -p /src && tar -xzf /tmp/source.tgz -C /src && cd /src || exit 1
mkdir -p /src/images /src/gf-run
for n in controller gpu-simulator job; do aws s3 cp --only-show-errors "s3://$BUCKET/$PREFIX/images/$n.tar.gz" "/src/images/$n.tar.gz"; done
[ "$(cd /src/images && sha256sum controller.tar.gz gpu-simulator.tar.gz job.tar.gz | sha256sum | cut -d' ' -f1)" = "$IMAGES_SHA" ] ||
  { echo "image checksum mismatch"; exit 1; }
L=""
while [ $(( $(date +%s) - GF_START )) -lt 180 ]; do
  if aws s3 cp --only-show-errors "s3://$BUCKET/$PREFIX/launch-time.txt" /tmp/launch-time.txt; then
    L=$(date -u -d "$(cat /tmp/launch-time.txt)" +%s || true)
    break
  fi
  sleep 5
done
NOW=$(date +%s)
if ! [[ "$L" =~ ^[0-9]+$ ]] || [ "$L" -gt "$NOW" ] || [ $(( NOW - L )) -gt 900 ]; then
  echo "LaunchTime was ${L:-not read} at $NOW"; exit 1
fi
( sleep $(( L + 7000 - $(date +%s) > 0 ? L + 7000 - $(date +%s) : 1 )); shutdown -h now ) &
P1=$(( L + 720 )); P2=$(( L + 1320 )); P3=$(( L + 6520 )); P4=$(( L + 6820 )); EV=$(( L + 6940 ))
nvidia-smi --query-gpu=index,name,memory.total,driver_version --format=csv > /tmp/nvidia-smi.csv || exit 1
upload /tmp/nvidia-smi.csv preflight-nvidia-smi.csv
[ "$(tail -n +2 /tmp/nvidia-smi.csv | wc -l)" = 1 ] && tail -n +2 /tmp/nvidia-smi.csv | grep -q A10G || { echo "PREFLIGHT FAILED: not one A10G"; exit 1; }
cat > /tmp/bringup.sh <<'BRINGUP'
upload() { aws s3 cp --only-show-errors "$1" "s3://$BUCKET/$PREFIX/$2" || true; }
export DEBIAN_FRONTEND=noninteractive
if ! command -v nvidia-ctk >/dev/null; then
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

# >>> REHEARSABLE -- everything to the matching marker needs no GPU and no root.
#
# hack/test/rehearse-bringup.sh extracts exactly this span and runs it on a development machine, driven with
# RUNNER=hack/m5c-gpu-session.sh. It exists because the first thing ever to execute these lines would
# otherwise be a rented instance, which is how a kubeconfig path this repository had asserted without
# checking cost a whole session.
#
# The span begins here rather than at the toolkit install above, which needs root and a card. It ends where
# the recipe starts reaching into the node container for the same toolkit -- the first thing that genuinely
# needs hardware, and the only part the instance should be discovering.
curl -fsSLo /usr/local/bin/kind https://kind.sigs.k8s.io/dl/v0.24.0/kind-linux-amd64
chmod +x /usr/local/bin/kind
curl -fsSLo /usr/local/bin/kubectl "https://dl.k8s.io/release/v1.31.0/bin/linux/amd64/kubectl"
chmod +x /usr/local/bin/kubectl

# One worker, and the cards reach it through the mount rather than through any GPU environment.
#
# accept-nvidia-visible-devices-as-volume-mounts tells the container runtime to read a mount under
# /var/run/nvidia-container-devices/ as if it were NVIDIA_VISIBLE_DEVICES. A kind node is an ordinary
# container that nobody passes that variable to, so the mount is how it ends up with the card. The first
# session to get this far had the setting and not the mount, which is half a recipe: the node saw no devices
# and the plugin advertised zero.
# The kubelet's container-log rotation is raised from its 10 MiB default, because an engine log longer than that
# was rotated and `kubectl logs` returns only the newest file: the S1 confirmation's staggered cells wrote about
# 11.4 MiB and lost their first 38,000 iterations (docs/superpowers/specs/2026-10-07-confirming-s1-on-unseen-settings.md).
cat > /tmp/kind.yaml <<'KINDEOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: m5cgpu
kubeadmConfigPatches:
  - |
    kind: KubeletConfiguration
    containerLogMaxSize: 200Mi
    containerLogMaxFiles: 2
nodes:
  - role: control-plane
  - role: worker
    extraMounts:
      - hostPath: /dev/null
        containerPath: /var/run/nvidia-container-devices/all
KINDEOF
# Told to kind rather than guessed from it: cloud-init runs user-data with HOME unset, and kind with no HOME
# writes .kube/config RELATIVE TO THE WORKING DIRECTORY. A session died three minutes in that way, with kind
# reporting success while the next kubectl talked to localhost:8080.
export KUBECONFIG=/tmp/kubeconfig
kind create cluster --config /tmp/kind.yaml --kubeconfig "$KUBECONFIG" --wait 300s || exit 1
kubectl cluster-info || { echo "PREFLIGHT FAILED: the cluster is up but unreachable through $KUBECONFIG"; exit 1; }

# The CRDs, with kustomize rather than `make install`: that target depends on `manifests`, which runs
# controller-gen and rewrites generated files. The CRDs are committed; building them is all that is needed.
kubectl kustomize config/crd | kubectl apply -f - || exit 1

# The gateway's ClusterRole, through the OVERLAY and not the bare file.
#
# config/gateway/rbac.yaml says `namespace: system`, which is kubebuilder's placeholder; the overlay is what
# rewrites it. Applying the file directly is refused with `namespaces "system" not found`, and
# hack/m5c-matrix.sh refuses to start without the ClusterRole because a binding to a missing one is accepted
# by Kubernetes and then fails authorization on every request, with nothing looking wrong until the first
# replay. Only the RBAC kinds: the overlay also carries a gateway Deployment pinned to an ECR digest, and the
# matrix deploys its own gateway from the binary shipped above.
kubectl create ns gpu-platform-control-plane-system --dry-run=client -o yaml | kubectl apply -f -
kubectl kustomize config/gateway > /tmp/gateway-all.yaml || exit 1
awk 'BEGIN{RS="\n---\n"} /(^|\n)kind: (ClusterRole|ClusterRoleBinding|Role|RoleBinding|ServiceAccount)(\n|$)/ {print "---"; print $0}' \
  /tmp/gateway-all.yaml > /tmp/gateway-rbac.yaml
grep -q "name: gateway-role" /tmp/gateway-rbac.yaml || { echo "PREFLIGHT FAILED: no gateway-role in the rendered overlay"; exit 1; }
kubectl apply -f /tmp/gateway-rbac.yaml || exit 1

# The toolkit is needed INSIDE the node as well, and that is a second configuration rather than the same one.
#
# Everything above configures the HOST's docker, which is what puts the card into the node container. Pods do
# not run on the host's docker; they run on the containerd inside that node, which knows nothing about any of
# it -- so the device plugin starts with no NVML and dies, and DCGM agrees that NVML does not exist. The node
# image ships neither nvidia-ctk nor /sbin/ldconfig.real, so both are put there.
docker exec m5cgpu-worker ln -sf /sbin/ldconfig /sbin/ldconfig.real || exit 1
docker exec m5cgpu-worker bash -c '
  set -e
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq curl gnupg ca-certificates
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed "s#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g" \
    > /etc/apt/sources.list.d/nvidia-container-toolkit.list
  apt-get update -qq
  apt-get install -y -qq nvidia-container-toolkit
  nvidia-ctk runtime configure --runtime=containerd --set-as-default
' || { echo "PREFLIGHT FAILED: could not configure the container runtime inside m5cgpu-worker"; exit 1; }

# Restarting containerd takes the kubelet's runtime out from under it, so the node is waited for rather than
# assumed back. Anything applied before it is Ready would land on a NotReady node.
docker exec m5cgpu-worker systemctl restart containerd || exit 1
kubectl wait --for=condition=Ready node/m5cgpu-worker --timeout=300s \
  || { echo "PREFLIGHT FAILED: m5cgpu-worker did not come back Ready after its containerd was restarted"; exit 1; }
# <<< REHEARSABLE
#
# The span ends HERE and not at the RBAC above, because everything between the two needs no card: installing
# the toolkit inside the node container and pointing its containerd at it are apt-get and a config rewrite,
# and both fail the same way on a laptop as on a rented machine. The first line past this marker asks the
# node for its cards, which is the first thing that genuinely needs one.
docker exec m5cgpu-worker nvidia-smi -L > /tmp/node-cards.txt 2>&1 || echo "(nvidia-smi failed inside the node)" >> /tmp/node-cards.txt
upload /tmp/node-cards.txt preflight-node-cards.txt
BRINGUP
export BUCKET PREFIX
bringup_left=$(( P1 - $(date +%s) ))
bringup_rc=124
if [ "$bringup_left" -gt 0 ]; then
  timeout --kill-after=15 "$bringup_left" bash /tmp/bringup.sh
  bringup_rc=$?
fi
echo "bring-up exited $bringup_rc"
{
  echo "commit=$COMMIT"
  echo "launch_time_epoch=$L"
  echo "driver=$(tail -n +2 /tmp/nvidia-smi.csv | cut -d, -f4 | tr -d ' ')"
  echo "bringup_rc=$bringup_rc"
} > /src/gf-run/instance-provenance.txt
if [ "$bringup_rc" = 0 ]; then
  export KUBECONFIG=/tmp/kubeconfig GF_PLATFORM_END="$P2" GF_ARMS_END="$P3" GF_CHECKS_END="$P4" GF_OUT=/src/gf-run
  timeout --kill-after=15 $(( EV - $(date +%s) > 5 ? EV - $(date +%s) : 5 )) bash hack/gpu-fault-instance.sh
  echo "the instance procedure exited $?"
else
  echo "the bring-up did not finish inside its phase (exit $bringup_rc); nothing else runs" | tee /src/gf-run/VOID
fi
left=$(( EV + 50 - $(date +%s) )); [ "$left" -gt 5 ] || left=5
tar -czf /tmp/evidence.tgz -C /src gf-run && timeout "$left" aws s3 cp --only-show-errors /tmp/evidence.tgz "s3://$BUCKET/$PREFIX/evidence.tgz"
upload /var/log/gpufault.log log.txt
echo "68b64c6e" > /tmp/DONE
upload /tmp/DONE DONE
