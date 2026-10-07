#!/bin/bash
exec > >(tee /var/log/m5c.log) 2>&1
set -x
( sleep 17400; shutdown -h now ) &
BUCKET="stub-bucket"
PREFIX="run-<NONCE>"
SOURCE_SHA="<SHA256>"
GATEWAY_SHA="<SHA>"
HARNESS_SHA="<SHA>"
COMMIT="<COMMIT>"
REPS="1"
ARMS="R1 shared timeSlicing mps"
RATE="9.85"
PREMIUM_WEIGHT="1"
NOISY_WEIGHT="0.054"
PROBE_WEIGHT="0"
DURATION_MS="420000"
LADDER=""
LADDER_STUDY=""
SWEEP=""
PREMIUM_RATE=""
PREMIUM_PROMPT_CHARS=""
NOISY_PROMPT_CHARS=""
REQUEST_TIMEOUT_MS=""
PREMIUM_OUTPUT_TOKENS=""
NOISY_OUTPUT_TOKENS=""
MODEL_REVISION=""
STUDY=""
STUDY_FROM_CR=""
SEEDS=""
BENCHMARK_CR_SHA256=""
BENCHMARK_CR_TOKENIZER_REV=""
DEADLINE_EPOCH=$(( $(date +%s) + 16800 ))
upload() { aws s3 cp "$1" "s3://$BUCKET/$PREFIX/$2" || true; }
trap 'upload /var/log/m5c.log log.txt; shutdown -h now' EXIT
aws s3 cp "s3://$BUCKET/$PREFIX/src/source.tgz" /tmp/source.tgz
got=$(sha256sum /tmp/source.tgz | cut -d' ' -f1)
if [ "$got" != "$SOURCE_SHA" ]; then echo "source checksum mismatch: $SOURCE_SHA vs $got"; exit 1; fi
mkdir -p /src && tar -xzf /tmp/source.tgz -C /src
cd /src
echo "$COMMIT" > /tmp/commit.txt && upload /tmp/commit.txt commit.txt
mkdir -p /src/bin
for b in gateway benchharness; do
  aws s3 cp "s3://$BUCKET/$PREFIX/bin/$b" "/src/bin/$b"
  chmod +x "/src/bin/$b"
done
got=$(sha256sum /src/bin/gateway | cut -d' ' -f1)
if [ "$got" != "$GATEWAY_SHA" ]; then echo "gateway checksum mismatch"; exit 1; fi
got=$(sha256sum /src/bin/benchharness | cut -d' ' -f1)
if [ "$got" != "$HARNESS_SHA" ]; then echo "benchharness checksum mismatch"; exit 1; fi
nvidia-smi --query-gpu=index,name,memory.total,driver_version --format=csv > /tmp/nvidia-smi.csv || exit 1
upload /tmp/nvidia-smi.csv preflight-nvidia-smi.csv
cards=$(tail -n +2 /tmp/nvidia-smi.csv | wc -l)
if [ "$cards" -ne 1 ]; then
  echo "PREFLIGHT FAILED: $cards cards; this matrix splits ONE card and two engines on two cards are not sharing"
  exit 1
fi
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
curl -fsSLo /usr/local/bin/kind https://kind.sigs.k8s.io/dl/v0.24.0/kind-linux-amd64
chmod +x /usr/local/bin/kind
curl -fsSLo /usr/local/bin/kubectl "https://dl.k8s.io/release/v1.31.0/bin/linux/amd64/kubectl"
chmod +x /usr/local/bin/kubectl
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
export KUBECONFIG=/tmp/kubeconfig
kind create cluster --config /tmp/kind.yaml --kubeconfig "$KUBECONFIG" --wait 300s || exit 1
kubectl cluster-info || { echo "PREFLIGHT FAILED: the cluster is up but unreachable through $KUBECONFIG"; exit 1; }
kubectl kustomize config/crd | kubectl apply -f - || exit 1
kubectl create ns gpu-platform-control-plane-system --dry-run=client -o yaml | kubectl apply -f -
kubectl kustomize config/gateway > /tmp/gateway-all.yaml || exit 1
awk 'BEGIN{RS="\n---\n"} /(^|\n)kind: (ClusterRole|ClusterRoleBinding|Role|RoleBinding|ServiceAccount)(\n|$)/ {print "---"; print $0}' \
  /tmp/gateway-all.yaml > /tmp/gateway-rbac.yaml
grep -q "name: gateway-role" /tmp/gateway-rbac.yaml || { echo "PREFLIGHT FAILED: no gateway-role in the rendered overlay"; exit 1; }
kubectl apply -f /tmp/gateway-rbac.yaml || exit 1
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
docker exec m5cgpu-worker systemctl restart containerd || exit 1
kubectl wait --for=condition=Ready node/m5cgpu-worker --timeout=300s \
  || { echo "PREFLIGHT FAILED: m5cgpu-worker did not come back Ready after its containerd was restarted"; exit 1; }
docker exec m5cgpu-worker nvidia-smi -L > /tmp/node-cards.txt 2>&1 || echo "(nvidia-smi failed inside the node)" >> /tmp/node-cards.txt
upload /tmp/node-cards.txt preflight-node-cards.txt
export KUBECONFIG=/tmp/kubeconfig
export PLATFORM=kind
export KCTX=kind-m5cgpu
export GPU_NODE=m5cgpu-worker
export DEADLINE_EPOCH
export GATEWAY_BIN=/src/bin/gateway
export BENCHHARNESS_BIN=/src/bin/benchharness
if [ -n "$LADDER" ]; then
  unset RATE NOISY_WEIGHT ARMS REPS
  export PREMIUM_WEIGHT PROBE_WEIGHT DURATION_MS LADDER LADDER_STUDY
elif [ -n "$SWEEP" ]; then
  # The matrix builds a sweep's arms from SWEEP and refuses an ARMS beside it, for the reason given above.
  unset RATE NOISY_WEIGHT ARMS
  export PREMIUM_WEIGHT PROBE_WEIGHT DURATION_MS REPS SWEEP PREMIUM_RATE
else
  export RATE PREMIUM_WEIGHT NOISY_WEIGHT PROBE_WEIGHT DURATION_MS REPS ARMS
fi
for v in PREMIUM_PROMPT_CHARS NOISY_PROMPT_CHARS REQUEST_TIMEOUT_MS MODEL_REVISION \
         PREMIUM_OUTPUT_TOKENS NOISY_OUTPUT_TOKENS \
         BENCHMARK_CR_SHA256 BENCHMARK_CR_TOKENIZER_REV STUDY STUDY_FROM_CR SEEDS; do
  if [ -n "${!v}" ]; then export "${v?}"; fi
done
export OUT=/src/m5c-run
cat > /usr/local/bin/m5c-cell-done <<'CELLHOOK'
set -u
raw="$1"; arm="$2"; rep="$3"
out="${OUT:-$(dirname "$raw")}"
base="s3://__BUCKET__/__PREFIX__/cells"
missing=""
send() { # <path> <s3 name>; records the name when it does not go up
  [ -f "$1" ] || return 0
  aws s3 cp "$1" "$base/$2" >/dev/null 2>&1 || missing="$missing $2"
}
for kind in raw trace manifest; do
  case "$kind" in
    raw|trace) ext=jsonl ;;
    manifest)  ext=yaml ;;
  esac
  send "$out/$kind-$arm-$rep.$ext" "$kind-$arm-$rep.$ext"
done
send "$out/port-forward-$arm-$rep.log" "port-forward-$arm-$rep.log"
for f in "$out"/engine-metrics-"$arm"-"$rep"-*.prom "$out"/engine-metrics-"$arm"-"$rep"-*.err; do
  [ -f "$f" ] || continue
  send "$f" "$(basename "$f")"
done
send "$out/engine-log-$arm-$rep.txt" "engine-log-$arm-$rep.txt"
send "$out/step-log-$arm-$rep.jsonl" "step-log-$arm-$rep.jsonl"
send "$out/step-plugin-$arm-$rep.sha256" "step-plugin-$arm-$rep.sha256"
send "$out/raw-warmup-$arm-$rep.jsonl" "raw-warmup-$arm-$rep.jsonl"
send "$out/warmup-boundary-$arm-$rep.txt" "warmup-boundary-$arm-$rep.txt"
send "$out/warmup-trace-$arm-$rep.jsonl" "warmup-trace-$arm-$rep.jsonl"
send "$out/warmup-manifest-$arm-$rep.yaml" "warmup-manifest-$arm-$rep.yaml"
for f in cell-environment.tsv cell-timings.tsv cell-judgements.tsv applied-values.tsv load-source.txt; do
  send "$out/$f" "$f"
done
for f in "$out"/refused-*.txt "$out"/invalid-*.txt "$out"/cell-refused-*.txt; do
  [ -f "$f" ] || continue
  send "$f" "$(basename "$f")"
done
if [ -n "$missing" ]; then
  # Named, not counted. "3 files failed" sends an operator to look at all of them.
  echo "  cell $arm rep $rep: these did NOT reach the bucket:$missing"
  exit 1
fi
echo "  cell $arm rep $rep uploaded as it completed, with its manifest, trace, port-forward log and the run records"
CELLHOOK
sed -i "s|__BUCKET__|$BUCKET|; s|__PREFIX__|$PREFIX|" /usr/local/bin/m5c-cell-done
chmod +x /usr/local/bin/m5c-cell-done
export CELL_DONE_HOOK=/usr/local/bin/m5c-cell-done
export SOURCE_COMMIT="$COMMIT"
bash hack/m5c-matrix.sh; matrix_rc=$?
echo "matrix exited $matrix_rc"
if [ -d /src/m5c-run ]; then
  tar -czf /tmp/m5c-evidence.tgz -C /src m5c-run
  upload /tmp/m5c-evidence.tgz evidence.tgz
fi
kubectl get nodes -o wide > /tmp/nodes.txt 2>&1 || true
upload /tmp/nodes.txt nodes.txt
if [ "$matrix_rc" = "0" ]; then
  echo "<NONCE>" > /tmp/DONE
  aws s3 cp /tmp/DONE "s3://$BUCKET/$PREFIX/DONE"
fi
