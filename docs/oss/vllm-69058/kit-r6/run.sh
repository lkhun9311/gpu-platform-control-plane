#!/bin/bash
# One-GPU confirmation for vLLM #69058, kit r6: our additions to PR #69095 with the runtime session's shutdown fix.
# hack/gpu-kit-session.sh runs this unmodified on one A10G, g5.xlarge or g5.2xlarge, with OUT set.
#
# Run r5 placed the fault in a shutdown race: after request 7 failed, the test's finally block shut the engine down before closing the connectors,
# and a save still queued on the save worker gathered from the freed KV cache.
# The runtime session's fix, commit c41f7726 on review/69095-additions, makes HF3FSKVConnector.shutdown() call close()
# and has the test close the connectors before the engine shuts down.
# That commit is not pushed, so this kit applies it with git am, from the patch pinned below, on review/69095-additions at 9ee44f04.
# git am writes a new commit id, so the result is pinned by its tree, the same tree c41f7726 has, and by its parent.
# The one command, as the spec gives it, both cases in one process, no -x, no CUDA_LAUNCH_BLOCKING:
#   VLLM_ENABLE_V1_MULTIPROCESSING=0 python -m pytest "tests/v1/kv_connector/unit/test_hf3fs_load_failure.py::TestHF3FSLoadFailureEndToEnd" -q -p no:cacheprovider --tb=long
# Expected: 2 passed and no illegal memory access; anything else is a FINDING, unless it is a harness cause such as the KV cache memory error.
# Every step's exit code goes to $OUT/status.txt, and verdict.py writes $OUT/verdict.json.
# This script exits with the verdict's status: 0 as expected, 2 a finding, 3 incomplete, 4 not run for a harness cause, 1 stopped.
#
# THE ENVIRONMENT.
# As in kit r5: Python 3.12 from the session, vLLM installed with VLLM_USE_PRECOMPILED=1 and the wheel of dd8c1578 named explicitly,
# the test packages the arm's CUDA test lock pins, and facebook/opt-125m at revision 27dcfa74d3 with its weights' sha256 pinned, after which the hub is offline.
#
# THE BUDGET.
# The session gives bring-up 300 s and the evidence upload 60 s, and confirms termination 360 s after the upload's deadline.
# So with BUDGET_S seconds here the bill runs to 300 + BUDGET_S + 60 + 360 s, which is 1,170 s at the default 450 s:
# $0.2497 on g5.xlarge at $0.7683/h all in, and $0.2822 on g5.2xlarge at $0.8683/h, the same A10G with more memory, for when g5.xlarge Spot is scarce.
# This script refuses BUDGET_S above 450.
# Run r5 reached its tests at 65 s, so the one test step gets what is left, at most E2E_CAP_S, 330 s by default.
# Every command that can wait runs under a timeout for what is left of the budget less a reserve for the verdict, so run.sh ends inside BUDGET_S.
# The bill above assumes the session's evidence upload and termination go as planned.
# The session lets a stalled upload run to 3,660 s after launch and stops the instance at 3,720 s, so the true worst case stays the session's:
# $0.8579 on g5.xlarge and $0.9696 on g5.2xlarge.
#
# Settings (KIT_ENV through the session): BUDGET_S (default and maximum 450) and E2E_CAP_S (the test step's cap, default 330).
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${OUT:-$HERE/results}
UPSTREAM=https://github.com/vllm-project/vllm.git
FORK=https://github.com/lkhun9311/vllm.git
BASE_SHA=9ee44f044e6f3bbc49b96facb4cfda659cd783a5
BASE_TREE=5cdf5ed74707a1e5fb0509a058c1d86aba70d3cb
PATCH="$HERE/c41f7726-shutdown.patch"
# The sha256 of storage's review-69095/c41f7726-shutdown.patch at commit 0b20acb2 on origin/main.
PATCH_SHA256=21adc4fcca8da477b23cebd447082679b231d33f18070fd75378e0e7b73bd42c
# The commit the patch was made from, and its tree, which the applied result must have.
FIX_SHA=c41f7726f65880039674767691073d52ce502ef9
FIX_TREE=fb3683d3d688b435cdb2d18070aa1f8692bc598f
MODEL=facebook/opt-125m
MODEL_REV=27dcfa74d334bc871f3234de431e71c6eeba5dd6
# The hub's LFS sha256 for pytorch_model.bin at MODEL_REV.
MODEL_BIN_SHA256=2d74da6615135c58cf3cf9ad4cb11e7c613ff9e55fe658a47ab83b6c8d1174a9
# The files vLLM reads for this model; the repository's TensorFlow and Flax weights are left out.
MODEL_FILES=(config.json generation_config.json merges.txt vocab.json special_tokens_map.json tokenizer_config.json pytorch_model.bin)
BUDGET_S=${BUDGET_S:-450}
BUDGET_MAX_S=450
E2E_CAP_S=${E2E_CAP_S:-330}
# The precompiled wheel's commit, the arm's merge-base with main, whose published wheels runs r4 and r5 installed.
WHEEL_COMMIT=dd8c157895f01875bc5f44c51003bbe330647330
# Left for verdict.py and the checksums after the last timed step.
RESERVE_S=60
TEST_FILE=tests/v1/kv_connector/unit/test_hf3fs_load_failure.py
CMD=(python -m pytest "$TEST_FILE::TestHF3FSLoadFailureEndToEnd" -q -p no:cacheprovider --tb=long)
ENV=(VLLM_ENABLE_V1_MULTIPROCESSING=0)
START=$(date +%s)

# Settings are checked before OUT is touched, so a refused run leaves nothing behind.
[ $# = 0 ] || { echo "run.sh takes no arguments, and got: $*; settings come from the environment" >&2; exit 1; }
# A leading zero is refused, since bash arithmetic would read it as octal and change or break the budget.
[[ $BUDGET_S =~ ^[1-9][0-9]*$ ]] && [ "$BUDGET_S" -gt "$RESERVE_S" ] && [ "$BUDGET_S" -le "$BUDGET_MAX_S" ] ||
  { echo "BUDGET_S=$BUDGET_S: it must be whole seconds above $RESERVE_S and at most $BUDGET_MAX_S" >&2; exit 1; }
[[ $E2E_CAP_S =~ ^[1-9][0-9]*$ ]] && [ "$E2E_CAP_S" -ge 30 ] || { echo "E2E_CAP_S=$E2E_CAP_S: it must be whole seconds without a leading zero, at least 30" >&2; exit 1; }
# CUDA_LAUNCH_BLOCKING would serialise the launches and could hide the race this run confirms gone, so it is refused rather than passed through.
[ -z "${CUDA_LAUNCH_BLOCKING:-}" ] || { echo "CUDA_LAUNCH_BLOCKING is set; this confirmation runs without it" >&2; exit 1; }
for v in PYTEST_CAP_S LLM_CAP_S UNIT_CAP_S; do [ -z "${!v:-}" ] || { echo "$v is set; kit r6 caps its one step with E2E_CAP_S" >&2; exit 1; }; done
mkdir -p "$OUT" || exit 1
# A rerun into the same OUT would leave the earlier logs for verdict.py to read, so only an empty OUT is used.
if [ -n "$(ls -A "$OUT")" ]; then echo "OUT=$OUT is not empty; each run writes a new directory" >&2; exit 1; fi
: > "$OUT/status.txt"

finish() {
  local py=python
  command -v python > /dev/null || py=python3
  timeout --kill-after=5 30 "$py" "$HERE/verdict.py" "$OUT" > "$OUT/verdict.txt" 2>&1
  VERDICT_RC=$?
  echo "verdict exit=$VERDICT_RC t=$(( $(date +%s) - START ))" >> "$OUT/status.txt"
  cat "$OUT/verdict.txt"
  ( cd "$OUT" && find . -type f ! -name SHA256SUMS | LC_ALL=C sort | timeout --kill-after=5 30 xargs -d '\n' sha256sum > SHA256SUMS )
}
VERDICT_RC=1
stop() { # the reason; the run ends here and says why
  echo "$*" | tee "$OUT/STOPPED" >&2
  echo "STOPPED $*" >> "$OUT/status.txt"
  finish
  exit 1
}
# step NAME CAP [--log FILE] COMMAND...: runs COMMAND under a timeout of CAP or what the budget has left, records its exit code and returns it.
step() {
  local name=$1 cap=$2 log=/dev/stdout; shift 2
  if [ "${1:-}" = --log ]; then log=$2; shift 2; fi
  local left=$(( BUDGET_S - RESERVE_S - ($(date +%s) - START) ))
  [ "$left" -gt 0 ] || stop "the budget ran out before $name"
  [ "$cap" -le "$left" ] || cap=$left
  timeout --kill-after=10 "$cap" "$@" > "$log" 2>&1
  local rc=$?
  echo "$name exit=$rc t=$(( $(date +%s) - START ))" | tee -a "$OUT/status.txt"
  return $rc
}

{
  echo "kit=r6"; echo "upstream=$UPSTREAM"; echo "fork=$FORK"
  echo "base=review/69095-additions $BASE_SHA tree $BASE_TREE"
  echo "patch=c41f7726-shutdown.patch sha256 $PATCH_SHA256, storage commit 0b20acb2, applied with git am"
  echo "pin=the applied commit's tree $FIX_TREE (that of $FIX_SHA) and its parent $BASE_SHA; git am writes a new commit id"
  echo "model=$MODEL"; echo "model_rev_pin=$MODEL_REV"; echo "model_bin_sha256_pin=$MODEL_BIN_SHA256"
  echo "budget_s=$BUDGET_S"; echo "e2e_cap_s=$E2E_CAP_S"; echo "wheel_commit=$WHEEL_COMMIT"
  echo "command=${ENV[*]} ${CMD[*]}"
} > "$OUT/settings.txt"
[ "${KIT_DRY_RUN:-}" = 1 ] && { echo "dry run: settings accepted"; cat "$OUT/settings.txt"; exit 0; }

# ---------------------------------------------------------------- the patch and the base, pinned
got=$(sha256sum "$PATCH" | cut -d' ' -f1)
echo "patch_sha256=$got" > "$OUT/versions.txt"
[ "$got" = "$PATCH_SHA256" ] || stop "the shutdown patch has sha256 $got, not the pinned $PATCH_SHA256"
# A driver in a bad state can hang nvidia-smi, so it gets a timeout like every other command that can wait.
step nvidia-smi 60 --log "$OUT/gpu.txt" bash -c 'nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv && nvidia-smi -L' || stop "nvidia-smi failed; see gpu.txt"
if [ "${KIT_OFFLINE_TEST:-}" = 1 ]; then
  # The offline test has no network, so the checkout is a detached worktree of a local vLLM repository that holds the base commit.
  [ -d "${OFFLINE_VLLM_SRC:-}" ] || stop "KIT_OFFLINE_TEST=1 needs OFFLINE_VLLM_SRC, a local vLLM repository"
  step worktree-vllm 120 --log "$OUT/clone.log" git -C "$OFFLINE_VLLM_SRC" worktree add -q --detach "$PWD/vllm" "$BASE_SHA" ||
    stop "could not check out the base from $OFFLINE_VLLM_SRC; see clone.log"
else
  # VLLM_USE_PRECOMPILED reads the commit's history, so the clone keeps its history and drops only blobs.
  step clone-vllm 300 --log "$OUT/clone.log" git clone -q --filter=blob:none "$UPSTREAM" vllm || stop "could not clone vLLM from $UPSTREAM; see clone.log"
  # The fork branch may move, so the base is fetched by its commit, which GitHub serves while it is reachable.
  step fetch-base 120 --log "$OUT/fetch-base.log" git -C vllm fetch -q --filter=blob:none "$FORK" "$BASE_SHA" || stop "could not fetch $BASE_SHA from $FORK; see fetch-base.log"
fi
git -C vllm cat-file -e "$BASE_SHA^{commit}" 2>> "$OUT/pins.log" || stop "commit $BASE_SHA is not in the fetched repository"
tree=$(git -C vllm rev-parse "$BASE_SHA^{tree}")
echo "base commit=$BASE_SHA tree=$tree" >> "$OUT/versions.txt"
[ "$tree" = "$BASE_TREE" ] || stop "the base $BASE_SHA has tree $tree, not the pinned $BASE_TREE"
# The clone has no blobs, so the checkout that fetches them runs as a timed step.
step materialize-base 300 --log "$OUT/materialize-base.log" git -C vllm checkout -q --detach -f "$BASE_SHA" || stop "could not check out the base; see materialize-base.log"
# git am needs an identity for the commit it writes; the result is checked by its tree, which the identity does not touch.
step git-am 60 --log "$OUT/git-am.log" git -C vllm -c user.name=kit -c user.email=kit@localhost -c commit.gpgsign=false am -q "$PATCH" ||
  stop "the shutdown patch did not apply with git am; see git-am.log"
head=$(git -C vllm rev-parse HEAD)
tree=$(git -C vllm rev-parse HEAD^{tree})
parent=$(git -C vllm rev-parse HEAD^)
echo "applied commit=$head tree=$tree parent=$parent (the source commit is $FIX_SHA)" >> "$OUT/versions.txt"
[ "$parent" = "$BASE_SHA" ] || stop "the applied commit's parent is $parent, not $BASE_SHA"
[ "$tree" = "$FIX_TREE" ] || stop "the applied commit has tree $tree, not $FIX_TREE, the tree of $FIX_SHA"
[ -z "$(git -C vllm status --porcelain --untracked-files=no)" ] || stop "the checkout has changes besides the applied commit"
{ git -C vllm log -1 --format='%H %T %P %s'; git -C vllm diff --stat HEAD^ HEAD; } > "$OUT/tree.txt" 2>&1

# ---------------------------------------------------------------- install, with precompiled kernels
# KIT_OFFLINE_TEST=1 skips the install for hack/vllm-69058-kit-test.sh, which puts fake python, hf and nvidia-smi on PATH; settings.txt says so.
if [ "${KIT_OFFLINE_TEST:-}" = 1 ]; then
  echo "offline_test=1 (fake python, pytest, hf and nvidia-smi; nothing installed)" >> "$OUT/settings.txt"
  # The fake hf cannot write the real weights, so the offline test names the sha256 its fake weights have.
  MODEL_BIN_SHA256=${OFFLINE_MODEL_BIN_SHA256:-$MODEL_BIN_SHA256}
  echo "offline_model_bin_sha256=$MODEL_BIN_SHA256" >> "$OUT/settings.txt"
else
  command -v uv > /dev/null || stop "uv is required"
  step venv 60 --log "$OUT/venv.log" uv venv -q --python 3.12 .venv || stop "could not make the venv; see venv.log"
  . .venv/bin/activate || stop "could not activate the venv"
  # -v keeps setup.py's lines naming the wheel commit it used, which must be the pinned one.
  step install-vllm 300 --log "$OUT/install-vllm.log" env -C vllm VLLM_USE_PRECOMPILED=1 VLLM_PRECOMPILED_WHEEL_COMMIT="$WHEEL_COMMIT" uv pip install -v -e . ||
    stop "vLLM did not install; see install-vllm.log"
  command grep -q "Using precompiled wheel commit $WHEEL_COMMIT" "$OUT/install-vllm.log" || stop "the install did not use the precompiled wheel of $WHEEL_COMMIT; see install-vllm.log"
  # The test-only packages vLLM's tests/conftest.py imports, at the versions the arm's CUDA test lock pins.
  pins=()
  for p in pytest pytest-asyncio tblib httpx; do
    pin=$(command grep -m1 -oE "^$p==[^ ]+" vllm/requirements/test/cuda.txt) || stop "vllm/requirements/test/cuda.txt pins no $p"
    pins+=("$pin")
  done
  echo "test_pins=${pins[*]}" >> "$OUT/versions.txt"
  step install-test 120 --log "$OUT/install-test.log" uv pip install "${pins[@]}" || stop "the test packages did not install; see install-test.log"
  step pip-freeze 60 --log "$OUT/pip-freeze.txt" uv pip freeze || stop "uv pip freeze failed; see pip-freeze.txt"
fi
step envprobe 120 --log "$OUT/envprobe.log" python "$HERE/envprobe.py" || stop "torch or triton does not import; see envprobe.log"
# A warning on stderr shares the log, so env.json takes only the probe's last line, which is its JSON.
tail -n 1 "$OUT/envprobe.log" > "$OUT/env.json"
cat "$OUT/env.json" >> "$OUT/versions.txt"

# ---------------------------------------------------------------- the model, pinned, then the hub offline
includes=()
for f in "${MODEL_FILES[@]}"; do includes+=(--include "$f"); done
step download-model 120 --log "$OUT/download.log" hf download "$MODEL" --revision main "${includes[@]}" || stop "hf download $MODEL failed; see download.log"
# hf prints the snapshot as "path=..." or "  path: ..." depending on its output format, so the path is matched by its shape.
snap=$(command grep -oE '/[^ ]*/snapshots/[0-9a-f]{40}' "$OUT/download.log" | tail -n 1)
[ -n "$snap" ] || stop "download.log names no snapshot"
echo "model_rev=$(basename "$snap")" >> "$OUT/versions.txt"
[ "$(basename "$snap")" = "$MODEL_REV" ] || stop "$MODEL main is at revision $(basename "$snap"), not the pinned $MODEL_REV"
( cd "$snap" && sha256sum "${MODEL_FILES[@]}" ) > "$OUT/model-files.sha256" 2>&1 || stop "the snapshot $snap lacks a file; see model-files.sha256"
command grep -qx "$MODEL_BIN_SHA256  pytorch_model.bin" "$OUT/model-files.sha256" || stop "pytorch_model.bin is not the pinned sha256 $MODEL_BIN_SHA256"
# From here the test reads only the checked snapshot, so a hub change mid-run cannot reach it.
export HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1
echo "hub_offline=1 for the test run" >> "$OUT/settings.txt"

# ---------------------------------------------------------------- the one step
step test-e2e "$E2E_CAP_S" --log "$OUT/e2e.log" env -C vllm "${ENV[@]}" "${CMD[@]}"
[ "${KIT_OFFLINE_TEST:-}" = 1 ] && git -C "$OFFLINE_VLLM_SRC" worktree remove --force "$PWD/vllm"
finish
exit "$VERDICT_RC"
