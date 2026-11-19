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

# Upstream's build stage installs its compilers from archive.ubuntu.com.
# That host was mid-sync in attempt 3 and served 0.3-0.5 MB/s in attempt 6, which ran the phase out of its bound.
# dockerfile-mirror.sed inserts one RUN that points apt at EC2's Seoul mirror of the same archive, with retries.
# The Makefile's DOCKERFILE is a plain assignment, so the build reads the rewritten copy and the checkout stays as fetched.
# Both hashes are fixed here, so an upstream file of another shape, or a rewrite that reaches further, stops the phase.
# The session checks the same two hashes against the fetched commit before anything is bought.
DOCKERFILE_SHA256=7fd0f172203376d7352bd7c772a32067aa5e44d26e7afb3d1a06eb49b38e9d05
DOCKERFILE_MIRROR_SHA256=30fdcc8b92d8bba86974317c31d22ff61f9a43e3f98b41b7d5267ef74e3d1575
DF="$D/Dockerfile"
SED_FILE="$(dirname "$0")/dockerfile-mirror.sed"
df_before=$(sha256sum <deployments/container/Dockerfile | cut -d' ' -f1)
sed -f "$SED_FILE" deployments/container/Dockerfile >"$DF" || { note "the Dockerfile rewrite failed"; exit 2; }
df_after=$(sha256sum <"$DF" | cut -d' ' -f1)
[ "$df_before" = "$DOCKERFILE_SHA256" ] || { note "upstream's Dockerfile is $df_before, not the $DOCKERFILE_SHA256 the rewrite was made for"; exit 2; }
[ "$df_after" = "$DOCKERFILE_MIRROR_SHA256" ] || { note "the rewritten Dockerfile is $df_after, not $DOCKERFILE_MIRROR_SHA256"; exit 2; }
cp "$SED_FILE" "$D/dockerfile-mirror.sed"
echo "dockerfile_rewrite sed=\"sed -f dockerfile-mirror.sed deployments/container/Dockerfile\" sed_sha256=$(sha256sum <"$SED_FILE" | cut -d' ' -f1) before_sha256=$df_before after_sha256=$df_after note=\"one RUN inserted before the build stage's apt step; it changes only the apt source host archive.ubuntu.com to ap-northeast-2.ec2.archive.ubuntu.com and adds apt retries; every upstream line is unchanged\"" >"$D/provenance.txt"
note "$(cat "$D/provenance.txt")"
IMG=$(make -f deployments/container/Makefile -s print-IMAGE GIT_COMMIT_SHORT="${DRA_COMMIT:0:8}" GIT_COMMIT="$DRA_COMMIT")
[ -n "$IMG" ] || { note "print-IMAGE gave nothing"; exit 2; }
note "build $IMG"
make -f deployments/container/Makefile build DOCKER_BUILD_OPTIONS=--load CI=true DOCKERFILE="$DF" \
  GIT_COMMIT_SHORT="${DRA_COMMIT:0:8}" GIT_COMMIT="$DRA_COMMIT" >"$D/build.log" 2>&1 || { note "BUILD FAILED"; exit 2; }
# The fetches by host, so the record shows which archive the compilers came from.
note "apt fetches: $(grep -c 'Get:[0-9]* http://ap-northeast-2.ec2.archive.ubuntu.com/' "$D/build.log") from the EC2 mirror, $(grep -c 'Get:[0-9]* http://archive.ubuntu.com/' "$D/build.log") from archive.ubuntu.com"
kind load docker-image "$IMG" --name "$CLUSTER" >"$D/kind-load.log" 2>&1 || { note "KIND LOAD FAILED"; exit 2; }
echo "$IMG" >"$D/image.txt"
docker image inspect "$IMG" --format '{{.Id}}' >>"$D/image.txt" 2>&1
note "loaded $IMG"

# S4 used to pull the scenarios' images into the GPU node; without S4 the build does, so no readiness wait is a cold pull.
# S1 runs ubuntu:22.04, and S5 runs the issue's registry.k8s.io/pause:3.10.
for img in docker.io/library/ubuntu:22.04 registry.k8s.io/pause:3.10; do
  timeout "$(left 180)" docker exec "$WORKER" crictl pull "$img" >>"$D/prepull.log" 2>&1 || note "could not pre-pull $img"
done
