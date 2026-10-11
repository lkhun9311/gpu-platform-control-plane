#!/bin/bash
# User-data for the hold-cap conformance session (hack/holdcap-conformance/session.sh fills the placeholders).
#
# It answers the one question no test in the repository can: does a real vLLM engine, started from the template
# the controller renders for a HoldCap InferenceDeployment, run with the scheduler settings the admission study
# measured, and does the controller report HoldCap only once that engine is the only one serving?
# It then turns HoldCap off and records how status and the Recreate rollout move.
# It measures nothing about latency; the evidence is the engine's own "non-default args" line and the object's status.
exec > >(tee /var/log/holdcap.log) 2>&1
set -x
# The instance's own end, independent of the wrapper and of the sweeper's tag.
( sleep BACKSTOP_SECONDS_PLACEHOLDER; shutdown -h now ) &

BUCKET="BUCKET_PLACEHOLDER"
PREFIX="RUN_ID_PLACEHOLDER"
SOURCE_SHA="SOURCE_SHA_PLACEHOLDER"
MANAGER_SHA="MANAGER_SHA_PLACEHOLDER"
COMMIT="COMMIT_PLACEHOLDER"
NS=default
NAME=qwen25-3b-holdcap

mkdir -p /tmp/out
upload() { aws s3 cp "$1" "s3://$BUCKET/$PREFIX/$2" || true; }
step() { echo "$(date -u +%FT%TZ) $*" | tee -a /tmp/out/steps.txt; }
# A failure writes its reason where the wrapper looks first, so a dead session says why rather than timing out.
fail() {
  step "FAILED: $*"
  echo "$*" > /tmp/out/failed.txt
  upload /tmp/out/failed.txt failed.txt
  exit 1
}
# ENDED is written last, after every other upload, so the wrapper never downloads a session that is still writing.
finish() {
  for f in /tmp/out/*; do upload "$f" "out/$(basename "$f")"; done
  upload /tmp/manager.log out/manager.log
  upload /var/log/holdcap.log log.txt
  date -u +%FT%TZ > /tmp/ended.txt
  upload /tmp/ended.txt ENDED
  shutdown -h now
}
trap finish EXIT

step "fetch the source and the manager"
aws s3 cp "s3://$BUCKET/$PREFIX/src/source.tgz" /tmp/source.tgz || fail "download the source"
[ "$(sha256sum /tmp/source.tgz | cut -d' ' -f1)" = "$SOURCE_SHA" ] || fail "source checksum mismatch"
mkdir -p /src && tar -xzf /tmp/source.tgz -C /src || fail "extract the source"
cd /src || fail "cd /src"
echo "$COMMIT" > /tmp/out/commit.txt
# The first write is the proof the role can write evidence at all, before anything is spent on bring-up.
aws s3 cp /tmp/out/commit.txt "s3://$BUCKET/$PREFIX/commit.txt" || fail "cannot write evidence to s3://$BUCKET/$PREFIX"
mkdir -p /src/bin
aws s3 cp "s3://$BUCKET/$PREFIX/bin/manager" /src/bin/manager || fail "download the manager"
chmod +x /src/bin/manager
[ "$(sha256sum /src/bin/manager | cut -d' ' -f1)" = "$MANAGER_SHA" ] || fail "manager checksum mismatch"

step "check the card"
# The profile is named for one A10G; another card would test a rendering the profile does not claim.
nvidia-smi --query-gpu=index,name,memory.total,driver_version --format=csv > /tmp/out/nvidia-smi.csv || fail "nvidia-smi"
[ "$(tail -n +2 /tmp/out/nvidia-smi.csv | wc -l)" -eq 1 ] || fail "not exactly one card"
tail -n +2 /tmp/out/nvidia-smi.csv | grep -q A10G || fail "the card is not an A10G"

step "host container toolkit"
export DEBIAN_FRONTEND=noninteractive
if ! command -v nvidia-ctk >/dev/null; then
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
    > /etc/apt/sources.list.d/nvidia-container-toolkit.list
  apt-get update && apt-get install -y nvidia-container-toolkit || fail "install nvidia-container-toolkit"
fi
nvidia-ctk runtime configure --runtime=docker --set-as-default
sed -i 's/^#accept-nvidia-visible-devices-as-volume-mounts.*/accept-nvidia-visible-devices-as-volume-mounts = true/' \
  /etc/nvidia-container-runtime/config.toml || true
grep -q 'accept-nvidia-visible-devices-as-volume-mounts = true' /etc/nvidia-container-runtime/config.toml \
  || echo 'accept-nvidia-visible-devices-as-volume-mounts = true' >> /etc/nvidia-container-runtime/config.toml
systemctl restart docker
sleep 5

step "kind bring-up, from the span the paid admission sessions ran"
# Extracted rather than copied, so this session's cluster is built by the same lines as the measured ones.
sed -n '/^# >>> REHEARSABLE/,/^# <<< REHEARSABLE/p' hack/m5c-gpu-session.sh > /tmp/bringup.sh
[ -s /tmp/bringup.sh ] || fail "the bring-up span is empty"
bash /tmp/bringup.sh || fail "the bring-up span failed"
export KUBECONFIG=/tmp/kubeconfig
k() { kubectl "$@"; }

step "kueue CRDs, node labels and the exclusive device plugin"
# The manager's informers include Kueue Workloads, so their CRDs must exist before it starts.
# Server-side, because the Workload CRD is larger than the last-applied annotation a client-side apply writes.
k apply --server-side -f config/kueue-crds/ || fail "apply the Kueue CRDs"
# The manager resolves these kinds once at start and exits if one is not yet served (rehearsed 2026-10-11).
k wait --for condition=established --timeout=120s crd/workloads.kueue.x-k8s.io crd/inferencedeployments.platform.lkhun9311.github.io \
  || fail "the CRDs were not established"
# kind sets neither label; EKS sets the first and infra/aws/cluster/eks.tf the second on the exclusive GPU groups.
# Set by hand here, so this session says nothing about node selection on EKS, only that the engine runs once selected.
k label node m5cgpu-worker node.kubernetes.io/instance-type=g5.2xlarge platform.lkhun9311.github.io/gpu=true --overwrite \
  || fail "label the worker"
k kustomize config/nvidia-device-plugin | k apply -f - || fail "apply the device plugin"
for _ in $(seq 1 60); do
  gpus=$(k get node m5cgpu-worker -o jsonpath='{.status.allocatable.nvidia\.com/gpu}')
  [ "$gpus" = 1 ] && break
  sleep 5
done
[ "$gpus" = 1 ] || fail "the worker advertises ${gpus:-no} nvidia.com/gpu"

step "start the manager"
# No webhook certificate, so the manager runs without webhooks, as its own log says; none concern InferenceDeployment.
/src/bin/manager --health-probe-bind-address=:18081 --metrics-bind-address=0 > /tmp/manager.log 2>&1 &
for _ in $(seq 1 30); do curl -fs localhost:18081/healthz >/dev/null && break; sleep 2; done
curl -fs localhost:18081/healthz >/dev/null || fail "the manager is not healthy"

snapshot() {
  k -n "$NS" get inferencedeployment "$NAME" -o json > "/tmp/out/$1-infd.json"
  k -n "$NS" get deploy "$NAME" -o json > "/tmp/out/$1-deployment.json" 2>/dev/null || true
  k -n "$NS" get pods -l "app.kubernetes.io/instance=$NAME" -o wide > "/tmp/out/$1-pods.txt" 2>&1 || true
}
admission_mode() { k -n "$NS" get inferencedeployment "$NAME" -o jsonpath='{.status.admission.mode}/{.status.admission.observedGeneration}/{.metadata.generation}'; }
args_line() { k -n "$NS" logs "deploy/$NAME" --tail=-1 | grep -o "non-default args: {.*}" | tail -1; }

step "apply the HoldCap sample"
k apply -n "$NS" -f config/samples/platform_v1_inferencedeployment_holdcap.yaml || fail "apply the sample"
sleep 5
snapshot at-create
step "status at create: $(admission_mode)"

step "wait for the capped engine"
# The first pull of the 15.6 GB image and the weights dominate; earlier sessions took about eight minutes.
k -n "$NS" rollout status "deploy/$NAME" --timeout=1500s || { snapshot rollout-failed; fail "the capped engine did not become ready"; }
for _ in $(seq 1 60); do
  case "$(admission_mode)" in HoldCap/*) break ;; esac
  sleep 2
done
snapshot holdcap
step "status after the rollout: $(admission_mode)"
args_line > /tmp/out/args-holdcap.txt
[ -s /tmp/out/args-holdcap.txt ] || fail "no non-default args line in the capped engine's log"

step "one streaming request per tier priority, straight to the engine"
k -n "$NS" port-forward "svc/$NAME" 18000:8000 > /tmp/out/port-forward.txt 2>&1 &
PF=$!
sleep 3
for p in 0 1; do
  curl -sS -o "/tmp/out/request-priority-$p.txt" -w '%{http_code}\n' localhost:18000/v1/chat/completions \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"Qwen/Qwen2.5-3B-Instruct\",\"messages\":[{\"role\":\"user\",\"content\":\"Say hello.\"}],\"stream\":true,\"max_tokens\":16,\"priority\":$p}" \
    > "/tmp/out/request-priority-$p.code" 2>&1
done
kill "$PF" 2>/dev/null

step "turn HoldCap off"
t0=$(date +%s.%N)
k -n "$NS" patch inferencedeployment "$NAME" --type=merge -p '{"spec":{"admission":{"mode":"Off","maxHold":null}}}' || fail "patch HoldCap off"
# Status must leave HoldCap before the uncapped engine serves, so the time it takes is recorded beside the Pods of that moment.
for _ in $(seq 1 120); do
  m=$(admission_mode)
  case "$m" in Off/*) g=${m#Off/}; [ "${g%%/*}" = "${g#*/}" ] && break ;; esac
  sleep 0.5
done
echo "$(awk -v a="$(date +%s.%N)" -v b="$t0" 'BEGIN{printf "%.1f", a-b}')s $(admission_mode)" > /tmp/out/off-status-latency.txt
snapshot off-immediate
step "status after turning off: $(cat /tmp/out/off-status-latency.txt)"
k -n "$NS" rollout status "deploy/$NAME" --timeout=900s || { snapshot off-rollout-failed; fail "the uncapped engine did not become ready"; }
sleep 5
snapshot off
args_line > /tmp/out/args-off.txt
[ -s /tmp/out/args-off.txt ] || fail "no non-default args line in the uncapped engine's log"

step "DONE"
echo done > /tmp/out/DONE
