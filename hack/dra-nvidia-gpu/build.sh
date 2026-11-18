#!/bin/bash
# Phase "build": the driver image from the pinned checkout, loaded into the kind cluster, as upstream's
# hack/ci/gcp-nvkind/install-dra-driver.sh and hack/ci/lambda/e2e-test.sh build it.
set -u
. "$(dirname "$0")/lib.sh"
T0=$(date +%s)
cd "$SRC" || exit 2

# Both upstream builds call `docker buildx`; the AMI's Docker is not known to ship the plugin, so it is installed if absent.
if ! docker buildx version >"$D/buildx.txt" 2>&1; then
  note "docker buildx is missing; installing docker-buildx-plugin"
  timeout "$(left 240)" apt-get install -y -q docker-buildx-plugin >>"$D/buildx.txt" 2>&1 || { note "BUILDX INSTALL FAILED"; exit 2; }
fi
docker buildx use default >>"$D/buildx.txt" 2>&1
IMG=$(make -f deployments/container/Makefile -s print-IMAGE GIT_COMMIT_SHORT="${DRA_COMMIT:0:8}" GIT_COMMIT="$DRA_COMMIT")
[ -n "$IMG" ] || { note "print-IMAGE gave nothing"; exit 2; }
note "build $IMG"
make -f deployments/container/Makefile build DOCKER_BUILD_OPTIONS=--load CI=true \
  GIT_COMMIT_SHORT="${DRA_COMMIT:0:8}" GIT_COMMIT="$DRA_COMMIT" >"$D/build.log" 2>&1 || { note "BUILD FAILED"; exit 2; }
kind load docker-image "$IMG" --name "$CLUSTER" >"$D/kind-load.log" 2>&1 || { note "KIND LOAD FAILED"; exit 2; }
echo "$IMG" >"$D/image.txt"
docker image inspect "$IMG" --format '{{.Id}}' >>"$D/image.txt" 2>&1
note "loaded $IMG"
