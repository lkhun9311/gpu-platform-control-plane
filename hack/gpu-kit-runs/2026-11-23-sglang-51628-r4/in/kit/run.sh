#!/bin/bash
# One-GPU A/B of the SGLang #51628 fix, kit r4: does prewarm.patch move the Mamba2 compiles of a NemotronH server before ready?
# hack/gpu-kit-session.sh runs this unmodified on one A10G with OUT set, as root.
#
# r2 served nvidia/Nemotron-H-4B-Instruct-128K from the 03fde9cc nightly image and saw 53 Mamba2 compiles after ready.
# The fix (prewarm.patch, local commit 40ca3cd5) is on SGLang main cb337923, which no published image is built from.
# So both arms run r2's image with a cb337923 tree installed over it (pip install --no-deps -e python), one fresh container each:
#   BASE: the cb337923 tree as fetched.
#   FIX:  the same tree with prewarm.patch applied.
# Before any container, each tree's commit, git tree hash and diff against cb337923 are recorded and checked against the pins below.
# A prep container installs the BASE tree once, downloads the model and builds SGLang's Rust TreeCore extension (see measure.sh).
#
# Every step's exit code goes to $OUT/status.txt and verdict.py writes $OUT/verdict.json and verdict.txt.
# The exit status is the verdict's: 0 decided (IMPROVED or NO CHANGE), 3 or 4 NOT RUN, 1 a stop before the verdict could be reached.
#
# Settings (KIT_ENV through the session): BUDGET_S (default 3250, at most 3250).
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${OUT:-$HERE/results}
# lmsysorg/sglang nightly-dev-20261120-03fde9cc, linux/amd64, pinned by its platform manifest's digest; r2 and r3 pulled and checked the same.
IMG="lmsysorg/sglang@sha256:d7976d3a5963ea29eb34a3d94dd2304b3b9a8245da78add7ada9cb15bf77a641"
IMAGE_DIGEST=sha256:d7976d3a5963ea29eb34a3d94dd2304b3b9a8245da78add7ada9cb15bf77a641
IMAGE_SHA=03fde9cc392a5f84a54a365635ffed0061cdf1b8
# The SGLang source both arms run: main at cb337923, fetched by commit id, and the git tree hashes of BASE and of FIX.
# FIX_TREE is the tree of local commit 40ca3cd5, which prewarm.patch was made from; the patch applied to cb337923 rebuilds it exactly.
SGLANG_REPO=https://github.com/sgl-project/sglang.git
SGLANG_SHA=cb337923d576f48a4accba439af9cfbc9b720a2c
BASE_TREE=55785ea97d04f50423b5297f78d2292fff321a53
FIX_TREE=dfdd29ffd25da3b19d3d4cfb6a366418d1ae9b0b
PATCH_SHA256=6aa4b47ca4aa314d0cae6d35e8894df0caa1e7565b403f028eda50a7d94624f9
# git diff --numstat cb337923 of the FIX tree: three source files and one test.
FIX_NUMSTAT=$(printf '%s\n' \
  $'43\t0\tpython/sglang/srt/layers/attention/hybrid_linear_attn_backend.py' \
  $'79\t0\tpython/sglang/srt/layers/attention/mamba/mamba.py' \
  $'8\t1\tpython/sglang/srt/model_executor/runner/base_runner.py' \
  $'158\t0\ttest/registered/unit/layers/test_mamba2_prefill_prewarm.py')
# The session gives run.sh 3,300 s from its start; the rest is left for the verdict and the checksums.
# r4 takes the whole 3,250 s that r2's rule allows: after a pull as slow as r2's (737 s), 3,150 s would leave the prep 460 s,
# about what the install, the download and the TreeCore build are expected to take, and a cut-short build changes the arms' TreeCore.
BUDGET_S=${BUDGET_S:-3250}
PULL_S=1500
FETCH_S=300
# The prep container: the install, the model download and the TreeCore build (bounded apart inside, at 600 s).
PREP_S=900
# One arm: install, probe, model check, startup, the warmup burst and three c16 runs, and FIX's tests.
# r2's arm, trimmed to these bursts, took about 560 s from launch to stop; r4 adds the install and FIX the tests and the prewarm.
ARM_S=900
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

# ---------------------------------------------------------------- settings and the patch, refused before anything is pulled
[[ $BUDGET_S =~ ^[0-9]+$ ]] && [ "$BUDGET_S" -le 3250 ] || stop "BUDGET_S=$BUDGET_S: whole seconds, at most 3250, inside the session's 3,300 s"
# The image, the source, the model and the traffic are the spec's, so a setting that would move one is refused rather than ignored.
# SGLANG_SHA and SGLANG_REPO are assigned above, so a caller's value never reaches the fetch.
for v in CONTROL MODEL IMAGE SGLANG_IMAGE BURSTS THRESHOLD SGLANG_TRITON_SLOW_COMPILE_THRESHOLD_SECS \
  SGLANG_UNIFIED_RADIX_TREE_CORE_BACKEND SGLANG_RUST_BUILD_MODE; do
  [ -z "${!v:-}" ] || stop "$v is set; the image, source, model, traffic and compile threshold are fixed by the spec"
done
have_patch=$(sha256sum "$HERE/prewarm.patch" 2>/dev/null | cut -d' ' -f1)
echo "patch_sha256=${have_patch:-absent}" > "$OUT/patch.txt"
[ "$have_patch" = "$PATCH_SHA256" ] || stop "prewarm.patch is ${have_patch:-absent}, not $PATCH_SHA256"
{
  echo "image=$IMG"; echo "image_sha=$IMAGE_SHA"; echo "sglang_sha=$SGLANG_SHA"; echo "base_tree=$BASE_TREE"; echo "fix_tree=$FIX_TREE"
  echo "patch_sha256=$PATCH_SHA256"; echo "model=nvidia/Nemotron-H-4B-Instruct-128K@f3c0b6c3b7fcb39e132b6007386e33a586d6e6cb"
  echo "server=python -m sglang.launch_server --model-path <model> --trust-remote-code"
  echo "traffic=sglang.benchmark.serving random-ids 1024 in, 512 out, range ratio 1.0; warmup 64 at c32, then 3 runs at c16 (32)"
  echo "arms=base then fix, one fresh container each"; echo "budget_s=$BUDGET_S"
} > "$OUT/settings.txt"
[ "${KIT_DRY_RUN:-}" = 1 ] && { echo "dry run: settings accepted"; cat "$OUT/settings.txt"; exit 0; }
if [ "${KIT_OFFLINE_TEST:-}" = 1 ]; then
  # The offline test runs as a user who cannot write /opt, and serves a fake SGLang tree from a local repository.
  # Its commit and trees cannot be cb337923's, so it supplies its own and the records say so; the patch and its numstat stay the real ones.
  HOST_ROOT=${SGL51628_HOST_ROOT:?the offline test sets SGL51628_HOST_ROOT}
  SGLANG_REPO=${SGL51628_TEST_REPO:?}; SGLANG_SHA=${SGL51628_TEST_SHA:?}; BASE_TREE=${SGL51628_TEST_BASE_TREE:?}; FIX_TREE=${SGL51628_TEST_FIX_TREE:?}
  { echo "offline_test=1 (fake docker, fake SGLang tree, fake server and client)"; echo "offline_sglang_sha=$SGLANG_SHA"
    echo "offline_base_tree=$BASE_TREE"; echo "offline_fix_tree=$FIX_TREE"; } >> "$OUT/settings.txt"
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
[ "$(head -n 1 "$OUT/image-revision.txt")" = "$IMAGE_SHA" ] || stop "the image's revision label is '$(head -n 1 "$OUT/image-revision.txt")', not $IMAGE_SHA"
echo "image-identity exit=0 t=$(( $(date +%s) - START ))" >> "$OUT/status.txt"

# ---------------------------------------------------------------- the two source trees, pinned before any container runs
command -v git > /dev/null || stop "git is not installed on the host"
SRC=$HOST_ROOT/src
rm -rf "$SRC" && mkdir -p "$SRC/base" || stop "cannot create $SRC"
fetch() {
  git -C "$SRC/base" init -q && git -C "$SRC/base" fetch -q --depth 1 "$SGLANG_REPO" "$SGLANG_SHA" && git -C "$SRC/base" checkout -q --detach FETCH_HEAD
}
step fetch timeout --kill-after=10 "$(bound $FETCH_S)" bash -c "$(declare -f fetch); SRC='$SRC' SGLANG_REPO='$SGLANG_REPO' SGLANG_SHA='$SGLANG_SHA' fetch" \
  > "$OUT/fetch.log" 2>&1 || stop "fetching SGLang $SGLANG_SHA failed; see fetch.log"
cp -a "$SRC/base" "$SRC/fix" || stop "cannot copy the BASE tree for FIX"
# The copy's files have new inodes, so the index's stat data no longer vouches for them and git apply --index would refuse every file.
git -C "$SRC/fix" update-index -q --refresh > "$OUT/patch-apply.log" 2>&1 || stop "cannot refresh the FIX tree's index; see patch-apply.log"
# --index puts the new test file in the index, so the tree hash and the numstat below cover all four files.
step patch git -C "$SRC/fix" apply --index "$HERE/prewarm.patch" >> "$OUT/patch-apply.log" 2>&1 || stop "prewarm.patch does not apply to $SGLANG_SHA; see patch-apply.log"

# source_record ARM WHEN: what the tree holds, from git, into source-ARM-WHEN.txt; the --stat goes beside it for a person.
source_record() {
  local d=$SRC/$1 f=$OUT/source-$1-$2.txt
  {
    echo "commit=$(git -C "$d" rev-parse HEAD 2>&1)"
    echo "tree=$(git -C "$d" write-tree 2>&1)"
    git -C "$d" diff --quiet && echo "worktree_matches_index=yes" || echo "worktree_matches_index=no"
    echo "untracked=$(git -C "$d" status --porcelain --untracked-files=all | command grep -c '^??')"
    echo "numstat_begin"
    git -C "$d" diff --numstat HEAD
    echo "numstat_end"
  } > "$f" 2>&1
  git -C "$d" diff --stat HEAD > "$OUT/source-$1-$2.stat" 2>&1
}
# source_ok ARM WHEN TREE NUMSTAT: whether the record is the pinned commit and tree with the pinned diff; "after" allows untracked build files.
source_ok() {
  local f=$OUT/source-$1-$2.txt
  command grep -qx "commit=$SGLANG_SHA" "$f" && command grep -qx "tree=$3" "$f" && command grep -qx "worktree_matches_index=yes" "$f" \
    && { [ "$2" = after ] || command grep -qx "untracked=0" "$f"; } \
    && [ "$(sed -n '/^numstat_begin$/,/^numstat_end$/p' "$f" | sed '1d;$d')" = "$4" ]
}
source_record base before
source_record fix before
source_ok base before "$BASE_TREE" "" || stop "the BASE tree is not $SGLANG_SHA as fetched: $(tr '\n' ' ' < "$OUT/source-base-before.txt")"
source_ok fix before "$FIX_TREE" "$FIX_NUMSTAT" || stop "the FIX tree is not $SGLANG_SHA plus prewarm.patch: $(tr '\n' ' ' < "$OUT/source-fix-before.txt")"
echo "source-pins exit=0 t=$(( $(date +%s) - START ))" >> "$OUT/status.txt"

# ---------------------------------------------------------------- the containers
mkdir -p "$OUT/c/prep" "$OUT/c/base" "$OUT/c/fix" "$HOST_ROOT/models" "$HOST_ROOT/prep" || stop "cannot create the measurement directories"
# container NAME TREE DEADLINE [EXTRA ARGS]: measure.sh in a fresh container of the image, with TREE mounted at /src/sglang.
container() {
  local name=$1 tree=$2 dl=$3; shift 3
  step "$name" timeout --kill-after=10 $(( dl - $(date +%s) + STOP_S )) docker run --rm --name "sgl51628-$name" --gpus all --ipc host --network host \
    -v "$HERE:/in:ro" -v "$OUT/c/$name:/out" -v "$HOST_ROOT/models:/models" -v "$tree:/src/sglang" -v "$HOST_ROOT/prep:/prep" --entrypoint bash "$IMG" \
    /in/measure.sh "$name" /in /out /models /src/sglang /prep "$dl" "$@" > "$OUT/c/$name.container.log" 2>&1
  local rc=$?
  # A host-side timeout kills only the docker client, so the container is removed and its removal is read from a listing that succeeded.
  timeout "$STOP_S" docker rm -f "sgl51628-$name" >> "$OUT/docker-rm.log" 2>&1
  if ! left_over=$(timeout "$STOP_S" docker ps -aq --filter "name=^sgl51628-$name\$") || [ -n "$left_over" ]; then
    echo "container-removed-$name exit=1" >> "$OUT/status.txt"
  fi
  return $rc
}
final=$(( START + BUDGET_S - STOP_S - 60 ))
# Both arms or none: a run that cannot hold two arms after the prep stops here, before the GPU is used for a half comparison.
[ $(( final - $(date +%s) )) -ge $(( 2 * ARM_S + 120 )) ] || stop "$(( final - $(date +%s) )) s left before the prep; two arms need $(( 2 * ARM_S )) s"
prep_dl=$(( $(date +%s) + PREP_S ))
[ "$prep_dl" -le $(( final - 2 * ARM_S )) ] || prep_dl=$(( final - 2 * ARM_S ))
container prep "$SRC/base" "$prep_dl"
treecore=$(sed -n 's/^treecore=//p' "$OUT/c/prep/measure.txt" 2>/dev/null)
command grep -qx 'prep=ok' "$OUT/c/prep/measure.txt" 2>/dev/null || stop "the prep container did not finish; see c/prep"
case "$treecore" in rust | python) ;; *) stop "the prep container chose no TreeCore ('$treecore')" ;; esac
[ $(( final - $(date +%s) )) -ge $(( 2 * ARM_S )) ] || stop "$(( final - $(date +%s) )) s left after the prep; two arms need $(( 2 * ARM_S )) s"
# BASE may not eat into FIX's time: its deadline leaves FIX a whole arm.
container base "$SRC/base" $(( final - ARM_S )) "$treecore"
source_record base after
# Without a BASE arm that sent its traffic there is nothing to compare FIX with, so its twelve minutes are not bought.
if command grep -qx 'arm_rc=0' "$OUT/c/base/measure.txt" 2>/dev/null; then
  container fix "$SRC/fix" "$final" "$treecore"
else
  echo "fix-skipped: BASE did not reach traffic ($(command grep '^arm_rc=\|^stopped=' "$OUT/c/base/measure.txt" 2>/dev/null | tr '\n' ' '))" >> "$OUT/status.txt"
fi
source_record fix after
finish
exit "$VERDICT_RC"
