#!/bin/bash
# One-GPU reproduction of SGLang #51628, kit r2: does a Mamba2 Triton kernel compile after a NemotronH server reports ready?
# hack/gpu-kit-session.sh runs this unmodified on one A10G with OUT set, as root.
#
# Run 1 used Falcon-H1-0.5B, whose every layer has attention, so prefill CUDA graph capture compiled the Mamba2 kernels at startup.
# The reporter's NemotronH starts with prefill CUDA graph off, so nothing compiles them before serving.
# r2 serves nvidia/Nemotron-H-4B-Instruct-128K from the pinned SGLang main image, gates on the disabled-prefill-graph line,
# sends the reporter's traffic scaled to one GPU, and records every Triton compilation with its time (measure.sh).
# verdict.py then separates the Mamba2 kernels from every other kernel, which run 1's verdict did not.
#
# Every step's exit code goes to $OUT/status.txt and verdict.py writes $OUT/verdict.json and verdict.txt.
# The exit status is the verdict's: 0 decided, 3 INCOMPLETE, 4 GATE FAILED, 1 a stop before the verdict could be reached.
#
# Settings (KIT_ENV through the session): CONTROL (on or off, default on) and BUDGET_S (default 3150, at most 3250).
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${OUT:-$HERE/results}
# lmsysorg/sglang nightly-dev-20261120-03fde9cc, linux/amd64, pinned by its platform manifest's digest; run 1 pulled and checked the same.
IMG="lmsysorg/sglang@sha256:d7976d3a5963ea29eb34a3d94dd2304b3b9a8245da78add7ada9cb15bf77a641"
IMAGE_DIGEST=sha256:d7976d3a5963ea29eb34a3d94dd2304b3b9a8245da78add7ada9cb15bf77a641
# The image's org.opencontainers.image.revision label, a commit on SGLang main.
SGLANG_SHA=03fde9cc392a5f84a54a365635ffed0061cdf1b8
CONTROL=${CONTROL:-on}
# The session gives run.sh 3,300 s from its start; the rest is left for the verdict and the checksums.
BUDGET_S=${BUDGET_S:-3150}
PULL_S=1500
IMAGE_ID_S=60
STOP_S=30
HOST_ROOT=/opt/sgl51628
START=$(date +%s)
mkdir -p "$OUT" || exit 1
# A rerun into the same OUT would leave an earlier run's records for verdict.py to read, so only an empty OUT is used.
if [ -n "$(ls -A "$OUT")" ]; then echo "OUT=$OUT is not empty; each run writes a new directory" >&2; exit 1; fi
: > "$OUT/status.txt"

step() { # name, then the command; records the exit code and returns it
  local name=$1; shift
  "$@"; local rc=$?
  echo "$name exit=$rc t=$(( $(date +%s) - START ))" | tee -a "$OUT/status.txt"
  return $rc
}
VERDICT_RC=1
finish() {
  if command -v python > /dev/null; then
    python -I "$HERE/verdict.py" "$OUT" > "$OUT/verdict.txt" 2>&1
    VERDICT_RC=$?
    echo "verdict exit=$VERDICT_RC t=$(( $(date +%s) - START ))" | tee -a "$OUT/status.txt"
    cat "$OUT/verdict.txt"
  fi
  ( cd "$OUT" && find . -type f ! -name SHA256SUMS | LC_ALL=C sort | xargs -d '\n' sha256sum > SHA256SUMS )
}
stop() { # the reason; the run ends here and says why
  echo "$*" | tee "$OUT/STOPPED" >&2
  echo "STOPPED $*" >> "$OUT/status.txt"
  finish
  exit 1
}
left() { echo $(( BUDGET_S - ($(date +%s) - START) )); }
bound() { local l; l=$(left); [ "$l" -gt "$1" ] && echo "$1" || echo $(( l > 1 ? l : 1 )); }

# ---------------------------------------------------------------- settings, refused before anything is pulled
case "$CONTROL" in on | off) ;; *) stop "CONTROL=$CONTROL: it is on or off" ;; esac
[[ $BUDGET_S =~ ^[0-9]+$ ]] && [ "$BUDGET_S" -le 3250 ] || stop "BUDGET_S=$BUDGET_S: whole seconds, at most 3250, inside the session's 3,300 s"
# The image, the model and the traffic are the spec's, so a setting that would move one is refused rather than ignored.
for v in MODEL IMAGE SGLANG_IMAGE BURSTS THRESHOLD SGLANG_TRITON_SLOW_COMPILE_THRESHOLD_SECS; do
  [ -z "${!v:-}" ] || stop "$v is set; the image, model, traffic and compile threshold are fixed by the spec"
done
{
  echo "image=$IMG"; echo "sglang_sha=$SGLANG_SHA"; echo "model=nvidia/Nemotron-H-4B-Instruct-128K@f3c0b6c3b7fcb39e132b6007386e33a586d6e6cb"
  echo "server=python -m sglang.launch_server --model-path <model> --trust-remote-code"
  echo "traffic=sglang.benchmark.serving random-ids 1024 in, 512 out, range ratio 1.0; warmup 64 at c32, then 3 runs each at c1 (4), c16 (32), c128 (128)"
  echo "control=$CONTROL (--warmups prefill_shapes)"; echo "budget_s=$BUDGET_S"
} > "$OUT/settings.txt"
[ "${KIT_DRY_RUN:-}" = 1 ] && { echo "dry run: settings accepted"; cat "$OUT/settings.txt"; exit 0; }
if [ "${KIT_OFFLINE_TEST:-}" = 1 ]; then
  echo "offline_test=1 (fake docker, fake server and client)" >> "$OUT/settings.txt"
  # The offline test runs as a user who cannot write /opt, so its host directory moves, and only there.
  HOST_ROOT=${SGL51628_HOST_ROOT:?the offline test sets SGL51628_HOST_ROOT}
fi

# ---------------------------------------------------------------- the GPU and docker
step gpu bash -c "nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv > '$OUT/gpu.txt' 2>&1" || stop "nvidia-smi failed"
# The pinned image is CUDA 13.0, which needs a 580 or newer driver; an older one would only show after the pull.
drv=$(tail -n +2 "$OUT/gpu.txt" | awk -F', ' '{print $3}' | cut -d. -f1)
[[ "$drv" =~ ^[0-9]+$ ]] && [ "$drv" -ge 580 ] || stop "driver ${drv:-unread} is older than 580, which the CUDA 13.0 image needs"
if [ "${KIT_OFFLINE_TEST:-}" != 1 ] && ! docker info --format '{{json .Runtimes}}' 2>>"$OUT/docker-setup.log" | command grep -q nvidia; then
  # Run 1's bring-up, for an AMI whose docker does not yet know the NVIDIA runtime.
  command -v nvidia-ctk > /dev/null || stop "docker has no nvidia runtime and nvidia-ctk is not installed"
  step docker-nvidia bash -c "nvidia-ctk runtime configure --runtime=docker --set-as-default && systemctl restart docker && sleep 5" >> "$OUT/docker-setup.log" 2>&1 \
    || stop "could not give docker the nvidia runtime; see docker-setup.log"
fi
docker info --format '{{json .Runtimes}}' > "$OUT/docker-runtimes.txt" 2>&1
command grep -q nvidia "$OUT/docker-runtimes.txt" || stop "docker has no nvidia runtime: $(cat "$OUT/docker-runtimes.txt")"

# ---------------------------------------------------------------- the image, by digest and by its commit label
step pull timeout --kill-after=15 "$(bound $PULL_S)" docker pull "$IMG" > "$OUT/pull.log" 2>&1 || stop "the pull failed; see pull.log"
docker image inspect "$IMG" --format '{{json .RepoDigests}}' > "$OUT/image-identity.txt" 2>&1
docker image inspect "$IMG" --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' > "$OUT/image-revision.txt" 2>&1
command grep -qF "$IMAGE_DIGEST" "$OUT/image-identity.txt" || stop "the pulled image is not $IMAGE_DIGEST: $(cat "$OUT/image-identity.txt")"
[ "$(head -n 1 "$OUT/image-revision.txt")" = "$SGLANG_SHA" ] || stop "the image's revision label is '$(head -n 1 "$OUT/image-revision.txt")', not $SGLANG_SHA"
echo "image-identity exit=0 t=$(( $(date +%s) - START ))" >> "$OUT/status.txt"

# ---------------------------------------------------------------- the measurement, in one fresh container
mkdir -p "$OUT/c" "$HOST_ROOT/models" || stop "cannot create the measurement directories"
deadline=$(( START + BUDGET_S - STOP_S - 60 ))
step measure timeout --kill-after=10 $(( deadline - $(date +%s) + STOP_S )) docker run --rm --name sgl51628 --gpus all --ipc host --network host \
  -v "$HERE:/in:ro" -v "$OUT/c:/out" -v "$HOST_ROOT/models:/models" --entrypoint bash "$IMG" \
  /in/measure.sh /in /out /models "$deadline" "$CONTROL" > "$OUT/measure.container.log" 2>&1
# A host-side timeout kills only the docker client, so the container is removed and its removal is read from a listing that succeeded.
timeout "$STOP_S" docker rm -f sgl51628 >> "$OUT/docker-rm.log" 2>&1
if ! left_over=$(timeout "$STOP_S" docker ps -aq --filter "name=^sgl51628\$") || [ -n "$left_over" ]; then
  echo "container-removed exit=1" >> "$OUT/status.txt"
fi
finish
exit "$VERDICT_RC"
