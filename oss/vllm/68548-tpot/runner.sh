#!/bin/bash
# The on-instance part of oss/vllm/68548-tpot/vllm-tpot-session.sh: pull, image identity, model download, BEFORE, then AFTER.
#
#   runner.sh <dir with the fetched inputs> <out dir> <harness-end epoch>
#
# Each state runs in its own fresh container of the same pinned image.
# A fresh container is the run's `git checkout .`: nothing BEFORE applied can reach AFTER, and state.sh proves it by
# hashing every file either diff touches before applying anything.
# The step bounds below are the session script's, which its offline test holds equal.
# The run stops at the first error, since a later state on a broken setup measures nothing.
set -u
IN=$1
D=$2
HE=$3
IMG="public.ecr.aws/q9t5s3a7/vllm-ci-postmerge-repo@sha256:9f77cb6501aa29d5bfa70d0819c153ecebd604d41fc77a9e8cc097cb0e4145bb"
VLLM_COMMIT=3a1c6c43df5eb5344a3f853c34fac93c274a372f
MODEL=TinyLlama/TinyLlama-1.1B-Chat-v1.0
# The Hub's main for the model on 2026-11-18; the test names the model without a revision, so main is pinned by checking
# that it resolves here, and both states then run offline against that one cached snapshot.
MODEL_REV=fe8a4ea1ffedaf415f4da2f062534de366a451e6
PULL_S=1500
IMAGE_ID_S=300
MODEL_S=300
SETUP_S=120
BEFORE_TEST_S=300
AFTER_TEST_S=420
FILE_TEST_S=600
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
grep -q "sha256:9f77cb6501aa29d5bfa70d0819c153ecebd604d41fc77a9e8cc097cb0e4145bb" "$D/image-identity.txt" &&
  grep -q " $VLLM_COMMIT\$" "$D/image-identity.txt" || { step "IMAGE IDENTITY FAILED: $(cat "$D/image-identity.txt")"; exit 2; }
timeout --kill-after=15 "$(left $IMAGE_ID_S)" docker run --rm --entrypoint cat "$IMG" /tmp/vllm-wheel.sha256 \
  > "$D/wheel-sha256.txt" 2>&1 || { step "IMAGE IDENTITY FAILED: no wheel hash in the image"; exit 2; }
step "image identity ok"

step "model download"
mkdir -p /opt/tp/hf || { step "MODEL DOWNLOAD FAILED: no cache directory"; exit 2; }
if ! timeout --kill-after=15 "$(left $MODEL_S)" docker run --rm -v /opt/tp/hf:/root/.cache/huggingface --entrypoint python3 "$IMG" \
  -c "from huggingface_hub import snapshot_download; print(snapshot_download('$MODEL', revision='main'))" > "$D/model-download.log" 2>&1; then
  step "MODEL DOWNLOAD FAILED"; exit 2
fi
case "$(tail -n 1 "$D/model-download.log")" in
  */snapshots/"$MODEL_REV") ;;
  *) step "MODEL REVISION FAILED: main is not $MODEL_REV"; exit 2 ;;
esac
step "model downloaded: $(tail -n 1 "$D/model-download.log")"

# state NAME BOUND ARGS...: one state in a fresh container, bounded here and again inside by state.sh's own timeouts.
state() {
  local name=$1 bound=$2 rc; shift 2
  step "state $name: start"
  timeout --kill-after=15 "$(left "$bound")" docker run --rm --name "tp-$name" --gpus all --ipc host \
    -v /opt/tp/hf:/root/.cache/huggingface -v "$IN:/in:ro" -v "$D:/out" -e HF_HUB_OFFLINE=1 \
    --entrypoint bash "$IMG" /in/state.sh "$name" "$@" > "$D/$name.container.log" 2>&1
  rc=$?
  # A host-side timeout kills only the docker client, so the container is removed and its removal checked.
  # Absence is read from a listing that succeeded, because a failed inspect would look the same as a removed container.
  timeout "$STOP_S" docker rm -f "tp-$name" > /dev/null 2>&1
  local left_over
  if ! left_over=$(timeout "$STOP_S" docker ps -aq --filter "name=^tp-$name\$") || [ -n "$left_over" ]; then
    step "state $name: container was not shown removed; stopping the run"; exit 2
  fi
  step "state $name: exited $rc"
  return "$rc"
}
state before $(( SETUP_S + BEFORE_TEST_S + STOP_S )) "$BEFORE_TEST_S" ||
  { step "BEFORE did not complete; AFTER is not run"; exit 2; }
# Only a BEFORE whose pytest failed can be the first half of the answer, so any other BEFORE ends the run here.
# pytest exits 1 for a failed test and for a server that never started alike; the verdict tells the two apart.
grep -qx 'tpot_rc=1' "$D/before/state.txt" ||
  { step "BEFORE did not fail ($(grep '^tpot_rc=' "$D/before/state.txt" || echo 'tpot_rc unread')); AFTER is not run"; exit 2; }
state after $(( SETUP_S + AFTER_TEST_S + FILE_TEST_S + STOP_S )) "$AFTER_TEST_S" "$FILE_TEST_S" ||
  { step "AFTER did not complete"; exit 2; }
step "both states done"
