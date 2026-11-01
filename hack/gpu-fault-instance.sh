#!/usr/bin/env bash
# The GPU fault-reaction study's instance side: run by the user-data hack/gpu-fault-session.sh renders, on the kind
# cluster `m5cgpu` the spliced bring-up created, from the unpacked source tree.
#
# Inputs, from the user-data: KUBECONFIG; GF_OUT; and the phase deadlines GF_PLATFORM_END, GF_ARMS_END and
# GF_CHECKS_END, epoch seconds counted from EC2's LaunchTime. Images come from /src/images, checksummed by the
# user-data before this runs.
#
# The procedure is hack/lib/gpu-fault.sh's, the one the rehearsal runs; what differs is only the exporter (the study
# overlay with a real host engine), the healthy node (the control-plane with a simulated device) and the deadlines.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

: "${GF_OUT:?}" "${GF_PLATFORM_END:?}" "${GF_ARMS_END:?}" "${GF_CHECKS_END:?}"
mkdir -p "$GF_OUT/reps" "$GF_OUT/checks" || exit 1
export GF_MODE=dcgm GF_TARGET=m5cgpu-worker GF_HEALTHY=m5cgpu-control-plane GF_CONTEXT=""
export GF_SYS=gpu-platform-control-plane-system GF_NS=gpufault GF_EXPORTER=app.kubernetes.io/component=dcgm-exporter
export GF_JOB_IMAGE=gpufault-job:busybox GF_LOG=$GF_OUT/log.txt GF_EMPTY_BODY=$GF_OUT/empty-body.json
# Run 3's recovery check runs NVIDIA's vectorAdd sample, pinned by the index digest the amendment records.
export GF_RECOVERY_IMAGE=nvcr.io/nvidia/k8s/cuda-sample:vectoradd-cuda12.5.0@sha256:7c7540bdf1f942d4fb6db97069fd6c289471b54ac29e3c7fcdf914cf77af7d41
echo '{}' >"$GF_EMPTY_BODY"
# shellcheck source=hack/lib/gpu-fault.sh
. hack/lib/gpu-fault.sh

phase() { echo "$1=$2" >>"$GF_OUT/phases.env"; gf_log "phase $1: $2"; }
stop() { phase "$1" "stopped: $2"; exit 1; }
before() { [ "$(date +%s)" -lt "$1" ]; }

{
  echo "mode=$GF_MODE"
  echo "kubectl=$(kubectl version --client -o json | python3 -c 'import json,sys; print(json.load(sys.stdin)["clientVersion"]["gitVersion"])')"
  echo "node_image=$(docker inspect m5cgpu-worker --format '{{.Config.Image}}')"
  echo "kueue=$(grep '^version=' config/kueue-controller/RELEASE | cut -d= -f2)"
  echo "exporter_image=$(grep -m1 -oE 'image: *[^ ]+' config/dcgm-exporter/daemonset.yaml | sed 's/image: *//')"
  echo "device_plugin_image=$(grep -m1 -oE 'image: *[^ ]+' config/nvidia-device-plugin/daemonset.yaml | sed 's/image: *//')"
} >>"$GF_OUT/provenance.txt"

# ---------------------------------------------------------------- platform
# The archives go straight into the nodes, as the rehearsal loads them, rather than through this host's docker.
for n in controller gpu-simulator job; do
  gunzip -c "/src/images/$n.tar.gz" >"/tmp/$n.tar" || stop platform "unpack $n"
  kind load image-archive "/tmp/$n.tar" --name m5cgpu >>"$GF_LOG" 2>&1 || stop platform "kind load $n"
  echo "image_archive $n=$(sha256sum "/src/images/$n.tar.gz" | cut -d' ' -f1)" >>"$GF_OUT/provenance.txt"
done
gfk label node "$GF_TARGET" platform.lkhun9311.github.io/gpu=true --overwrite >>"$GF_LOG" 2>&1 || stop platform "label $GF_TARGET"
gfk taint node "$GF_HEALTHY" node-role.kubernetes.io/control-plane:NoSchedule- >>"$GF_LOG" 2>&1 || stop platform "untaint $GF_HEALTHY"
gf_install_queueing || stop platform "queueing"

# The real card on T, through NVIDIA's device plugin.
gfk create ns "$GF_SYS" --dry-run=client -o yaml | gfk apply -f - >>"$GF_LOG" 2>&1
gfk kustomize config/nvidia-device-plugin | gfk apply -f - >>"$GF_LOG" 2>&1 || stop platform "nvidia device plugin"
# One simulated device on H, and only on H: two plugins registering nvidia.com/gpu on T would replace each other.
gfk kustomize config/device-plugin >"$GF_OUT/device-plugin.yaml" || stop platform "render gpu-simulator"
gfk apply -f "$GF_OUT/device-plugin.yaml" >>"$GF_LOG" 2>&1 || stop platform "gpu-simulator"
gfk -n "$GF_SYS" patch ds/gpu-simulator --type=json -p "[
  {\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/image\",\"value\":\"gpu-simulator:gpufault\"},
  {\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/imagePullPolicy\",\"value\":\"IfNotPresent\"},
  {\"op\":\"add\",\"path\":\"/spec/template/spec/nodeSelector\",\"value\":{\"kubernetes.io/hostname\":\"$GF_HEALTHY\"}}
]" >>"$GF_LOG" 2>&1 || stop platform "pin gpu-simulator to $GF_HEALTHY"
for n in "$GF_TARGET" "$GF_HEALTHY"; do
  gf_wait_until 180 sh -c "[ \"\$(kubectl get node $n -o jsonpath='{.status.allocatable.nvidia\\.com/gpu}')\" = 1 ]" ||
    stop platform "$n does not advertise one nvidia.com/gpu"
done
# Pulled onto T now, so that the recovery check's time is the platform's and the card's, never the registry's.
docker exec m5cgpu-worker crictl pull "$GF_RECOVERY_IMAGE" >>"$GF_LOG" 2>&1 || stop platform "pull the recovery image onto $GF_TARGET"
echo "recovery_image=$GF_RECOVERY_IMAGE" >>"$GF_OUT/provenance.txt"
gfk kustomize config/dcgm-exporter-fault >"$GF_OUT/exporter.yaml" || stop platform "render the study exporter"
gfk apply -f "$GF_OUT/exporter.yaml" >>"$GF_LOG" 2>&1 || stop platform "the study exporter"

before "$GF_PLATFORM_END" || stop platform "out of time before the smoke cell"
gf_smoke || stop smoke "$(grep '^stop=' "$GF_OUT/smoke.env")"
phase smoke done
before "$GF_PLATFORM_END" || stop platform "out of time before the operator"
gf_deploy_operator controller:gpufault || stop platform "operator"
gf_tenant || stop platform "tenant"
phase platform done

# ---------------------------------------------------------------- arms and checks
gf_arms
phase arms done
if [ $(( $(date +%s) + 240 )) -le "$GF_CHECKS_END" ]; then
  gf_stale_checks || gf_log "the stale checks did not complete"
  # The recovery job is given GF_RECOVERY_S, and its bookkeeping a little more, inside the checks phase.
  if [ $(( $(date +%s) + GF_RECOVERY_S + 30 )) -le "$GF_CHECKS_END" ]; then
    gf_recovery_check || gf_log "the recovery check did not complete"
  else
    mkdir -p "$GF_OUT/checks/recovery" && printf 'reached=false\nreason=deadline\n' >"$GF_OUT/checks/recovery/check.env"
  fi
  phase checks done
else
  phase checks "not run: fewer than 240 s left before $GF_CHECKS_END"
fi
