#!/bin/bash
# The on-instance part of hack/vllm-gdn-68414-session.sh: pull, image identity, BEFORE, then AFTER.
#
#   runner.sh <dir with the fetched inputs> <out dir> <harness-end epoch>
#
# Each state runs in its own fresh container of the same pinned image.
# A fresh container is the run's `git checkout .`: nothing BEFORE did can reach AFTER, and state.sh proves it by hashing every pinned file before applying anything.
# The step bounds below are the session script's, which its offline test holds equal.
# The run stops at an error that voids what follows, since a later state on a broken setup measures nothing.
set -u
IN=$1
D=$2
HE=$3
IMG="public.ecr.aws/q9t5s3a7/vllm-ci-postmerge-repo@sha256:45feec27226e1dc9d10e14272a45bcd7344555c85102be9ccbc0fbe9df2d99ed"
VLLM_COMMIT=8700cc9ba0016bf14d8f2756f3b673e93fbcf2fd
PULL_S=1500
IMAGE_ID_S=300
SETUP_S=120
ASIS_S=120
CUDA_S=360
UNIT_S=120
EXIST_S=120
STOP_S=30

mkdir -p "$D"
step() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*" | tee -a "$D/steps.log"; }
left() { local l=$(( HE - $(date +%s) )); [ "$l" -gt "$1" ] && echo "$1" || echo $(( l > 1 ? l : 1 )); }

step "pull $IMG"
if ! timeout --kill-after=15 "$(left $PULL_S)" docker pull "$IMG" > "$D/pull.log" 2>&1; then
  step "PULL FAILED"; exit 2
fi
step "pulled"

# The image must say it was built from the commit, and its digest is the one pinned.
step "image identity"
docker image inspect "$IMG" --format '{{json .RepoDigests}} {{index .Config.Labels "org.opencontainers.image.revision"}}' \
  > "$D/image-identity.txt" 2>&1
grep -q "sha256:45feec27226e1dc9d10e14272a45bcd7344555c85102be9ccbc0fbe9df2d99ed" "$D/image-identity.txt" &&
  grep -q " $VLLM_COMMIT\$" "$D/image-identity.txt" || { step "IMAGE IDENTITY FAILED: $(cat "$D/image-identity.txt")"; exit 2; }
timeout --kill-after=15 "$(left $IMAGE_ID_S)" docker run --rm --entrypoint cat "$IMG" /tmp/vllm-wheel.sha256 \
  > "$D/wheel-sha256.txt" 2>&1 || { step "IMAGE IDENTITY FAILED: no wheel hash in the image"; exit 2; }
step "image identity ok"

# state NAME BOUND ARGS...: one state in a fresh container, bounded here and again inside by state.sh's own timeouts.
# No model or network is needed, so the container gets neither a cache mount nor a token.
state() {
  local name=$1 bound=$2 rc; shift 2
  step "state $name: start"
  timeout --kill-after=15 "$(left "$bound")" docker run --rm --name "gdn-$name" --gpus all --ipc host \
    -v "$IN:/in:ro" -v "$D:/out" --entrypoint bash "$IMG" /in/state.sh "$name" "$@" > "$D/$name.container.log" 2>&1
  rc=$?
  # A host-side timeout kills only the docker client, so the container is removed and its removal checked.
  # Absence is read from a listing that succeeded, because a failed inspect would look the same as a removed container.
  timeout "$STOP_S" docker rm -f "gdn-$name" > /dev/null 2>&1
  local left_over
  if ! left_over=$(timeout "$STOP_S" docker ps -aq --filter "name=^gdn-$name\$") || [ -n "$left_over" ]; then
    step "state $name: container was not shown removed; stopping the run"; exit 2
  fi
  step "state $name: exited $rc"
  return "$rc"
}
state before $(( SETUP_S + ASIS_S + CUDA_S + STOP_S )) "$ASIS_S" "$CUDA_S" ||
  { step "BEFORE did not complete; AFTER is not run"; exit 2; }
# A BEFORE that completed without showing the bug still goes on, because the AFTER tests answer the PR's question either way.
# The verdict names that outcome; it never calls such a run confirmed.
grep -q '^repro_line=unwritten ' "$D/before/state.txt" ||
  step "BEFORE printed no repro result ($(grep '^repro_mode=' "$D/before/state.txt" || echo 'mode unread')); AFTER runs for its tests"
state after $(( SETUP_S + ASIS_S + CUDA_S + UNIT_S + 2 * EXIST_S + STOP_S )) "$ASIS_S" "$CUDA_S" "$UNIT_S" "$EXIST_S" ||
  { step "AFTER did not complete"; exit 2; }
step "both states done"
