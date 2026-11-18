#!/bin/bash
# S4, the baseline: upstream's own bats files for one GPU (test_gpu_basic, test_gpu_robustness, test_gpu_sharing), run
# the way upstream's mock-NVML kind CI runs bats against a kind cluster, with the Lambda single-GPU CI's settings.
# A rig that fails these cannot support a claim about S1-S3, so the runner stops when this exits non-zero.
set -u
. "$(dirname "$0")/lib.sh"
T0=$(date +%s)
cd "$SRC" || exit 2
snap s4.before

# The bats runner is a container on the kind network, so it needs the kubeconfig that names the API server by its
# in-network address (hack/ci/mock-nvml/e2e-test.sh).
# Every pod in the three files runs ubuntu:24.04, and test_gpu_basic gives its first pod 8 s to become ready; a cold
# pull lost that race on the mock-NVML kind run of 2026-11-18 (7.999 s), and a failed S4 stops the run.
# S1 and S3 use ubuntu:22.04. Both are pulled into the GPU node first.
for img in docker.io/library/ubuntu:24.04 docker.io/library/ubuntu:22.04; do
  timeout "$(left 180)" docker exec "$WORKER" crictl pull "$img" >>"$D/prepull.log" 2>&1 || note "could not pre-pull $img"
done
kind get kubeconfig --internal --name "$CLUSTER" >"$D/kind-internal-kubeconfig" || { note "no internal kubeconfig"; exit 2; }
# multi-gpu needs two GPUs and version-specific pins another release's attributes; both filters are the Lambda CI's.
# CI=true keeps RUN_BATS from asking docker for a terminal, which cloud-init does not have.
note "bats: test_gpu_basic test_gpu_robustness test_gpu_sharing"
env CI=true USER=root KUBECONFIG="$D/kind-internal-kubeconfig" DOCKER_NETWORK=kind SKIP_CLEANUP=true \
  TEST_CHART_LOCAL=true TEST_NVIDIA_DRIVER_ROOT=/ DISABLE_COMPUTE_DOMAINS=true \
  TEST_FILTER_TAGS='!version-specific,!multi-gpu' NVMM_PATH=/cwd/tests/bats/lib/lambda \
  make -f tests/bats/Makefile -f "$IN/s4.mk" tests-session-s4 \
  GIT_COMMIT_SHORT="${DRA_COMMIT:0:8}" GIT_COMMIT="$DRA_COMMIT" TMPDIR=/tmp >"$D/bats.log" 2>&1
rc=$?
note "bats exited $rc"
cp -r /tmp/k8s-dra-driver-gpu-tests-out-root "$D/bats-rundir" 2>/dev/null
snap s4.after
collect
grep -E '^(ok|not ok) ' "$D/bats.log" >"$D/result.txt"
exit "$rc"
