#!/bin/bash
exec > >(tee /var/log/mpscap.log) 2>&1
set -x
MPSCAP_START=$(date +%s)
# The first backstop, armed before anything can fail, counts from the instance's own start; LaunchTime precedes it,
# so the precise one below, armed once LaunchTime is read, always fires first.
( sleep 2100; shutdown -h now ) &
BUCKET="mpscap-gpu-007635145730"
PREFIX="mpscap-20261024-run1-b252f121"
SOURCE_SHA="eb51e6951592bf8cef0be82287a50746a803c6ce9ef4363ba86b1793d3df2c27"
GATEWAY_SHA="6b36f5cbde210784d42a874093a9f95fd30dd6088fcaedfda8595fa9e636a2b0"
HARNESS_SHA="a34c9326e4be14a7cb4e272eade41c0217c7df122d2af4a3a35b521f67a49157"
COMMIT="04fac8f345607aac1248664345a7147a50cde636"
upload() { aws s3 cp --only-show-errors "$1" "s3://$BUCKET/$PREFIX/$2" || true; }
trap 'upload /var/log/mpscap.log log.txt; shutdown -h now' EXIT
aws s3 cp --only-show-errors "s3://$BUCKET/$PREFIX/src/source.tgz" /tmp/source.tgz
[ "$(sha256sum /tmp/source.tgz | cut -d' ' -f1)" = "$SOURCE_SHA" ] || { echo "source checksum mismatch"; exit 1; }
mkdir -p /src && tar -xzf /tmp/source.tgz -C /src && cd /src || exit 1
mkdir -p /src/bin /src/m5c-run
for b in gateway benchharness; do aws s3 cp --only-show-errors "s3://$BUCKET/$PREFIX/bin/$b" "/src/bin/$b"; chmod +x "/src/bin/$b"; done
[ "$(sha256sum /src/bin/gateway | cut -d' ' -f1)" = "$GATEWAY_SHA" ] || { echo "gateway checksum mismatch"; exit 1; }
[ "$(sha256sum /src/bin/benchharness | cut -d' ' -f1)" = "$HARNESS_SHA" ] || { echo "benchharness checksum mismatch"; exit 1; }
. hack/lib/mps-journal.sh
. hack/lib/mps-capability.sh
export MPS_JOURNAL=/src/m5c-run/mps-journal.jsonl
# Uploaded after every line, so a session cut short has said how far it got.
export MPS_JOURNAL_ON_APPEND="aws s3 cp --only-show-errors $MPS_JOURNAL s3://$BUCKET/$PREFIX/journal.jsonl"
# LaunchTime, written by the session that launched this instance; nothing else is a valid clock for the phases.
L=""
while [ $(( $(date +%s) - MPSCAP_START )) -lt 180 ]; do
  if aws s3 cp --only-show-errors "s3://$BUCKET/$PREFIX/launch-time.txt" /tmp/launch-time.txt 2>/dev/null; then
    L=$(date -u -d "$(cat /tmp/launch-time.txt)" +%s 2>/dev/null || true)
    break
  fi
  sleep 5
done
NOW=$(date +%s)
if ! [[ "$L" =~ ^[0-9]+$ ]] || [ "$L" -gt "$NOW" ] || [ $(( NOW - L )) -gt 900 ]; then
  mj_fact launch_time_read false "LaunchTime was ${L:-not read} at $NOW, $(( NOW - MPSCAP_START )) s after this instance started"
  exit 1
fi
mj_fact launch_time_read true "LaunchTime $(cat /tmp/launch-time.txt), epoch $L"
( sleep $(( L + 2100 - $(date +%s) > 0 ? L + 2100 - $(date +%s) : 1 )); shutdown -h now ) &
P1=$(( L + 720 )); P2=$(( L + 1200 )); P3=$(( L + 1920 )); EV=$(( L + 2040 ))
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
# The run record, before B0: what the registration says a capability answer is worth nothing without.
imds=$(curl -s -X PUT -H "X-aws-ec2-metadata-token-ttl-seconds: 300" http://169.254.169.254/latest/api/token)
md() { curl -s -H "X-aws-ec2-metadata-token: $imds" "http://169.254.169.254/latest/meta-data/$1"; }
{
  echo "commit=$COMMIT"
  echo "launch_time_epoch=$L"
  echo "instance_id=$(md instance-id)"
  echo "ami_id=$(md ami-id)"
  echo "driver=$(tail -n +2 /tmp/nvidia-smi.csv | cut -d, -f4 | tr -d ' ')"
  echo "toolkit_host=$(nvidia-ctk --version 2>/dev/null | head -1)"
  echo "toolkit_node=$(docker exec m5cgpu-worker nvidia-ctk --version 2>/dev/null | head -1)"
  echo "engine_a_image=$(grep -m1 -oE 'image: *[^ ]+' config/vllm-shared/engine-a.yaml | sed 's/image: *//')"
  echo "engine_b_image=$(grep -m1 -oE 'image: *[^ ]+' config/vllm-shared/engine-b.yaml | sed 's/image: *//')"
  echo "plugin_image=$(grep -m1 -oE 'image: *[^ ]+' config/nvidia-device-plugin-mps/daemonset.yaml | sed 's/image: *//')"
  echo "pin_overlay=$(mpscap_pin_hash config/nvidia-device-plugin-mps/configmap.yaml config/nvidia-device-plugin-mps/daemonset.yaml config/nvidia-device-plugin-mps/kustomization.yaml)"
  echo "pin_engines=$(mpscap_pin_hash config/vllm-shared/engine-a.yaml config/vllm-shared/engine-b.yaml)"
} > /tmp/provenance.txt
upload /tmp/provenance.txt provenance.txt
if awk -F= 'NF < 2 || $2 == "" {bad = 1} END {exit bad}' /tmp/provenance.txt; then
  mj_fact provenance_complete true
else
  mj_fact provenance_complete false "a field of the run record is empty: $(awk -F= 'NF < 2 || $2 == ""' /tmp/provenance.txt | paste -sd' ')"
fi
export KUBECONFIG=/tmp/kubeconfig PLATFORM=kind KCTX=kind-m5cgpu GPU_NODE=m5cgpu-worker DEADLINE_EPOCH="$EV"
export GATEWAY_BIN=/src/bin/gateway BENCHHARNESS_BIN=/src/bin/benchharness OUT=/src/m5c-run SOURCE_COMMIT="$COMMIT"
export STUDY=mps-capability-2026-10-24 ARMS=mps REPS=1 RATE=2 PREMIUM_WEIGHT=1 NOISY_WEIGHT=0.054 PROBE_WEIGHT=0 DURATION_MS=120000
export MPSCAP_PHASE1_END="$P1" MPSCAP_PHASE2_END="$P2" MPSCAP_PHASE3_END="$P3"
export MPSCAP_PIN_OVERLAY=a9022421b9dd77e749936441cc52fc9c6bd02f6dde10e15617f2842320ad00a1 MPSCAP_PIN_ENGINES=0cd4e054c59ef6f2013896d4e699d422771756f80b99963f6b6f3d429514707e
# The phases are enforced from outside the matrix; its TERM runs its cleanup, and with it the diagnostics.
if [ "$bringup_rc" = 0 ]; then
  mpscap_supervise "$P1" "$P2" "$P3" 90 -- bash hack/m5c-matrix.sh
  matrix_rc=$?
else
  # No cluster, so no bar is started; the run goes straight to its evidence and reads INCONCLUSIVE or INVALID.
  echo "the bring-up did not finish inside phase 1 (exit $bringup_rc); the matrix is not run"
  matrix_rc=$bringup_rc
fi
echo "matrix exited $matrix_rc"
evidence_rc=0
left=$(( EV - $(date +%s) )); [ "$left" -gt 5 ] || left=5
tar -czf /tmp/evidence.tgz -C /src m5c-run || evidence_rc=$?
[ "$evidence_rc" != 0 ] || timeout "$left" aws s3 cp --only-show-errors /tmp/evidence.tgz "s3://$BUCKET/$PREFIX/evidence.tgz" || evidence_rc=$?
# The diagnostics are uploaded when the evidence is, and complete when every required one ran.
inv=/src/m5c-run/mpscap/diag/inventory.tsv
if [ "$evidence_rc" = 0 ] && grep -qx 'required_failed=0' /src/m5c-run/mpscap/diag/complete 2>/dev/null && [ -s "$inv" ] &&
  awk -F'\t' 'NR > 1 && $5 == "yes" && $2 != 0 {bad = 1} END {exit bad}' "$inv"; then
  mj_fact diagnostics_uploaded true
else
  mj_fact diagnostics_uploaded false "evidence upload exit $evidence_rc; inventory $( [ -s "$inv" ] && awk -F'\t' 'NR > 1 && $5 == "yes" && $2 != 0 {print $1}' "$inv" | paste -sd' ' || echo missing)"
fi
upload /var/log/mpscap.log log.txt
echo "b252f121" > /tmp/DONE
upload /tmp/DONE DONE
