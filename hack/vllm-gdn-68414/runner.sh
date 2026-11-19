#!/bin/bash
# The on-instance part of hack/vllm-gdn-68414-session.sh: pull, image identity, then #68414 AFTER, #68416 BEFORE and AFTER, and #68415 BEFORE and AFTER.
#
#   runner.sh <dir with the fetched inputs> <out dir> <harness-end epoch>
#
# Each state runs in its own fresh container of the same pinned image.
# A fresh container is the run's `git checkout .`: nothing an earlier state did can reach a later one, and each state script proves it by hashing all three items' files before applying anything.
# One state's failure does not stop the next, because each item is judged on its own records and one item's failure must not cost another its run.
# Only a failure that voids everything after it stops the run: a failed pull, an image that is not the pinned one, or a container whose removal cannot be shown.
# The step bounds below are the session script's, which its offline test holds equal.
set -u
IN=$1
D=$2
HE=$3
IMG="public.ecr.aws/q9t5s3a7/vllm-ci-postmerge-repo@sha256:45feec27226e1dc9d10e14272a45bcd7344555c85102be9ccbc0fbe9df2d99ed"
VLLM_COMMIT=8700cc9ba0016bf14d8f2756f3b673e93fbcf2fd
PULL_S=1200
IMAGE_ID_S=120
SETUP_S=90
REPRO_S=300
UNIT_S=120
PYTEST_S=150
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

# contained SCRIPT NAME BOUND ARGS...: one state in a fresh container named fla-NAME, bounded here and again inside by the script's own timeouts.
# NAME is ITEM-STATE, and the script is given STATE; no model or network is needed, so the container gets neither a cache mount nor a token.
failed=0
contained() {
  local script=$1 name=$2 bound=$3 rc
  shift 3
  step "state $name: start"
  # BOUND ends with STOP_S, which the kill grace, the removal and its check share, so a state that hits every limit still ends within BOUND and takes no time from the next item.
  timeout --kill-after=$(( STOP_S / 3 )) "$(left $(( bound - STOP_S )))" docker run --rm --name "fla-$name" --gpus all --ipc host \
    -v "$IN:/in:ro" -v "$D:/out" --entrypoint bash "$IMG" "/in/$script" "${name#*-}" "$@" > "$D/$name.container.log" 2>&1
  rc=$?
  # A host-side timeout kills only the docker client, so the container is removed and its removal checked.
  # Absence is read from a listing that succeeded, because a failed inspect would look the same as a removed container.
  timeout $(( STOP_S / 3 )) docker rm -f "fla-$name" > /dev/null 2>&1
  local left_over
  if ! left_over=$(timeout $(( STOP_S / 3 )) docker ps -aq --filter "name=^fla-$name\$") || [ -n "$left_over" ]; then
    step "state $name: container was not shown removed; stopping the run"; exit 2
  fi
  step "state $name: exited $rc"
  [ "$rc" = 0 ] || failed=$(( failed + 1 ))
}
# #68414 first: one container, and the result run 1 lost to the Spot reclaim.
contained state.sh gdn-after $(( SETUP_S + REPRO_S + UNIT_S + STOP_S )) "$REPRO_S" "$UNIT_S"
step "gdn states done"
# #68416 next, then #68415, whose BEFORE is the only state that runs an unfixed kernel near an out-of-bounds write, guarded to its safe case.
contained stride-state.sh stride-before $(( SETUP_S + PYTEST_S + STOP_S )) "$PYTEST_S"
contained stride-state.sh stride-after $(( SETUP_S + PYTEST_S + STOP_S )) "$PYTEST_S"
step "stride states done"
contained kda-state.sh kda-before $(( SETUP_S + PYTEST_S + STOP_S )) "$PYTEST_S"
contained kda-state.sh kda-after $(( SETUP_S + PYTEST_S + STOP_S )) "$PYTEST_S"
step "kda states done"
step "all items done, $failed state(s) exited non-zero"
[ "$failed" = 0 ] || exit 3
