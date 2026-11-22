#!/bin/bash
# One-GPU diagnostic for vLLM #69058 on PR #69095's head, kit r5.
# hack/gpu-kit-session.sh runs this unmodified on one A10G with OUT set; it can also run by hand on one CUDA GPU with uv on PATH.
#
# Run r4 showed both arms crash the same way: request 7's read fails, the scheduler fails it,
# and then "Task execution error: Triton Error [CUDA]: an illegal memory access" follows for saved request 6.
# The fault is in #69095's own failure path, so this kit runs one arm, #69095's head, with the runtime session's diagnostic patch.
# The patch (diag-r5-on-bb14b997.diff, pinned below) only adds logging and torch.cuda.synchronize() in the HF3FS connector.
# The test file is arm B's from run r4, copied in from 9ee44f04 with the same sha256.
# The one command, with no -x so both the fail and recompute cases run:
#   CUDA_LAUNCH_BLOCKING=1 VLLM_ENABLE_V1_MULTIPROCESSING=0 python -m pytest "tests/v1/kv_connector/unit/test_hf3fs_load_failure.py::TestHF3FSLoadFailureEndToEnd" -q -p no:cacheprovider --tb=long
# The verdict keeps, for each case, the lines matching DIAG, illegal, Failing or Read operation failed,
# the last "DIAG ... sync ok" before the first illegal memory access, and any "DIAG save ... out of range" line.
# pytest prints a case's captured output only when the case fails or errors, so a passing case has no lines to extract, and the verdict says so.
# Every step's exit code goes to $OUT/status.txt, and verdict.py writes $OUT/verdict.json.
# This script exits with the verdict's status: 0 the diagnostic is complete, 3 incomplete, 1 stopped.
#
# THE ENVIRONMENT.
# As in kit r4: Python 3.12 from the session, vLLM installed with VLLM_USE_PRECOMPILED=1 (the wheel of the arm's base on main, dd8c1578),
# the test packages its CUDA test lock pins, and facebook/opt-125m at revision 27dcfa74d3 with its weights' sha256 pinned, after which the hub is offline.
#
# THE BUDGET.
# g5.xlarge bills $0.7683/h all in under the session's caps.
# The session gives bring-up 300 s and the evidence upload 60 s, and confirms termination 360 s after the upload's deadline.
# So with BUDGET_S seconds here the bill runs to 300 + BUDGET_S + 60 + 360 s, which is 1,170 s and $0.2497 at the default 450 s.
# The runtime session asked for about $0.25 or less, which is reached at 1,171 s, so this script refuses BUDGET_S above 450.
# Run r4 reached its tests at 67 s and its end-to-end step took 134 s with -x; both cases here may take about twice that.
# Every long step runs under a timeout for what is left of the budget less a reserve for the verdict, so run.sh ends inside BUDGET_S.
# The session's own hard stop, 3,720 s after launch, is the backstop if this script's budget did not hold, and that worst case is the session's $0.8579.
#
# Settings (KIT_ENV through the session): BUDGET_S (default and maximum 450) and E2E_CAP_S (the test step's cap, default 360).
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${OUT:-$HERE/results}
UPSTREAM=https://github.com/vllm-project/vllm.git
FORK=https://github.com/lkhun9311/vllm.git
ARM_REF=refs/pull/69095/head
ARM_SHA=bb14b99792981d8dcebcce5fe7eacfb46e4258fb
ARM_TREE=8256f29750a8035f563029cfd6c7e1bb40558b0b
# The commit the test file comes from, run r4's arm B, pinned by commit and tree as in kit r4.
TEST_SRC_SHA=9ee44f044e6f3bbc49b96facb4cfda659cd783a5
TEST_SRC_TREE=5cdf5ed74707a1e5fb0509a058c1d86aba70d3cb
TEST_FILE=tests/v1/kv_connector/unit/test_hf3fs_load_failure.py
TEST_FILE_SHA256=af58d2b74ba20c35ec547e70648e0a9de04736edbd5cf6e63c3e3780d2574217
DIFF="$HERE/diag-r5-on-bb14b997.diff"
# The sha256 of storage's review-69095/diag-r5-on-bb14b997.diff at commit 93038508 on origin/main.
DIFF_SHA256=8950a5701a0669507eea07d7ed5e2f8cf63a845f6893dce079590e000530cb9a
MODEL=facebook/opt-125m
MODEL_REV=27dcfa74d334bc871f3234de431e71c6eeba5dd6
# The hub's LFS sha256 for pytorch_model.bin at MODEL_REV.
MODEL_BIN_SHA256=2d74da6615135c58cf3cf9ad4cb11e7c613ff9e55fe658a47ab83b6c8d1174a9
# The files vLLM reads for this model; the repository's TensorFlow and Flax weights are left out.
MODEL_FILES=(config.json generation_config.json merges.txt vocab.json special_tokens_map.json tokenizer_config.json pytorch_model.bin)
BUDGET_S=${BUDGET_S:-450}
BUDGET_MAX_S=450
E2E_CAP_S=${E2E_CAP_S:-360}
# Left for verdict.py and the checksums after the last timed step.
RESERVE_S=60
CMD=(python -m pytest "$TEST_FILE::TestHF3FSLoadFailureEndToEnd" -q -p no:cacheprovider --tb=long)
# The engine runs in the test's process, and a CUDA fault is reported at the launch that caused it.
ENV=(CUDA_LAUNCH_BLOCKING=1 VLLM_ENABLE_V1_MULTIPROCESSING=0)
START=$(date +%s)

# Settings are checked before OUT is touched, so a refused run leaves nothing behind.
[ $# = 0 ] || { echo "run.sh takes no arguments, and got: $*; settings come from the environment" >&2; exit 1; }
# A leading zero is refused, since bash arithmetic would read it as octal and change or break the budget.
[[ $BUDGET_S =~ ^[1-9][0-9]*$ ]] && [ "$BUDGET_S" -gt "$RESERVE_S" ] && [ "$BUDGET_S" -le "$BUDGET_MAX_S" ] ||
  { echo "BUDGET_S=$BUDGET_S: it must be whole seconds above $RESERVE_S and at most $BUDGET_MAX_S, which keeps g5.xlarge under \$0.25" >&2; exit 1; }
[[ $E2E_CAP_S =~ ^[1-9][0-9]*$ ]] && [ "$E2E_CAP_S" -ge 30 ] || { echo "E2E_CAP_S=$E2E_CAP_S: it must be whole seconds without a leading zero, at least 30" >&2; exit 1; }
# Earlier kits' settings are refused rather than ignored, since nothing here reads them.
for v in PYTEST_CAP_S LLM_CAP_S UNIT_CAP_S; do [ -z "${!v:-}" ] || { echo "$v is set; kit r5 runs one step, capped by E2E_CAP_S" >&2; exit 1; }; done
mkdir -p "$OUT" || exit 1
# A rerun into the same OUT would leave the earlier logs for verdict.py to read, so only an empty OUT is used.
if [ -n "$(ls -A "$OUT")" ]; then echo "OUT=$OUT is not empty; each run writes a new directory" >&2; exit 1; fi
: > "$OUT/status.txt"

finish() {
  local py=python
  command -v python > /dev/null || py=python3
  timeout 30 "$py" "$HERE/verdict.py" "$OUT" > "$OUT/verdict.txt" 2>&1
  VERDICT_RC=$?
  echo "verdict exit=$VERDICT_RC t=$(( $(date +%s) - START ))" >> "$OUT/status.txt"
  cat "$OUT/verdict.txt"
  ( cd "$OUT" && find . -type f ! -name SHA256SUMS | LC_ALL=C sort | xargs -d '\n' sha256sum > SHA256SUMS )
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
  echo "kit=r5"; echo "upstream=$UPSTREAM"; echo "fork=$FORK"
  echo "arm=$ARM_REF $ARM_SHA tree $ARM_TREE, plus $TEST_FILE from $TEST_SRC_SHA and the diagnostic patch"
  echo "diff=diag-r5-on-bb14b997.diff sha256 $DIFF_SHA256, storage commit 93038508"
  echo "test_file_sha256_pin=$TEST_FILE_SHA256"
  echo "model=$MODEL"; echo "model_rev_pin=$MODEL_REV"; echo "model_bin_sha256_pin=$MODEL_BIN_SHA256"
  echo "budget_s=$BUDGET_S"; echo "e2e_cap_s=$E2E_CAP_S"
  echo "command=${ENV[*]} ${CMD[*]}"
} > "$OUT/settings.txt"
[ "${KIT_DRY_RUN:-}" = 1 ] && { echo "dry run: settings accepted"; cat "$OUT/settings.txt"; exit 0; }

# ---------------------------------------------------------------- the patch, the arm and the test file's source, pinned
got=$(sha256sum "$DIFF" | cut -d' ' -f1)
echo "diff_sha256=$got" > "$OUT/versions.txt"
[ "$got" = "$DIFF_SHA256" ] || stop "the diagnostic patch has sha256 $got, not the pinned $DIFF_SHA256"
# The patch must touch only Python files under vllm/, so the test file and everything else stay as pinned.
command grep '^diff --git ' "$DIFF" > "$OUT/diff-files.txt"
[ -s "$OUT/diff-files.txt" ] || stop "the diagnostic patch names no file"
! command grep -vE '^diff --git a/(vllm/[^ ]*\.py) b/\1$' "$OUT/diff-files.txt" > "$OUT/diff-files-outside.txt" ||
  stop "the diagnostic patch touches a file other than Python under vllm/; see diff-files-outside.txt"
command -v nvidia-smi > /dev/null || stop "nvidia-smi is not on PATH"
{ nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv; nvidia-smi -L; } > "$OUT/gpu.txt" 2>&1 || stop "nvidia-smi failed; see gpu.txt"
if [ "${KIT_OFFLINE_TEST:-}" = 1 ]; then
  # The offline test has no network, so the checkout is a detached worktree of a local vLLM repository that holds both commits.
  [ -d "${OFFLINE_VLLM_SRC:-}" ] || stop "KIT_OFFLINE_TEST=1 needs OFFLINE_VLLM_SRC, a local vLLM repository"
  step worktree-vllm 120 --log "$OUT/clone.log" git -C "$OFFLINE_VLLM_SRC" worktree add -q --detach "$PWD/vllm" "$ARM_SHA" ||
    stop "could not check out the arm from $OFFLINE_VLLM_SRC; see clone.log"
else
  # VLLM_USE_PRECOMPILED looks up the wheel from the commit's history, so the clone keeps its history and drops only blobs.
  step clone-vllm 300 --log "$OUT/clone.log" git clone -q --filter=blob:none "$UPSTREAM" vllm || stop "could not clone vLLM from $UPSTREAM; see clone.log"
  step fetch-arm 120 --log "$OUT/fetch-arm.log" git -C vllm fetch -q --filter=blob:none origin "$ARM_REF" || stop "could not fetch $ARM_REF; see fetch-arm.log"
  # The fork branch may move, so the test file's commit is fetched by its id, which GitHub serves while it is reachable.
  step fetch-test-src 120 --log "$OUT/fetch-test-src.log" git -C vllm fetch -q --filter=blob:none "$FORK" "$TEST_SRC_SHA" ||
    stop "could not fetch $TEST_SRC_SHA from $FORK; see fetch-test-src.log"
fi
# pinned NAME SHA TREE: refuses a commit that is missing or whose tree is not the pinned one.
pinned() {
  git -C vllm cat-file -e "$2^{commit}" 2>> "$OUT/pins.log" || stop "$1: commit $2 is not in the fetched repository"
  local tree
  tree=$(git -C vllm rev-parse "$2^{tree}")
  echo "$1 commit=$2 tree=$tree" >> "$OUT/versions.txt"
  [ "$tree" = "$3" ] || stop "$1: commit $2 has tree $tree, not the pinned $3"
}
pinned arm "$ARM_SHA" "$ARM_TREE"
pinned test_src "$TEST_SRC_SHA" "$TEST_SRC_TREE"
# The clone has no blobs, so the checkouts that fetch them run as timed steps, and every later read of a file is local.
step materialize-test-src 300 --log "$OUT/materialize-test-src.log" git -C vllm checkout -q --detach -f "$TEST_SRC_SHA" || stop "could not check out $TEST_SRC_SHA; see materialize-test-src.log"
step materialize-arm 300 --log "$OUT/materialize-arm.log" git -C vllm checkout -q --detach -f "$ARM_SHA" || stop "could not check out the arm; see materialize-arm.log"
! git -C vllm cat-file -e "$ARM_SHA:$TEST_FILE" 2>> "$OUT/pins.log" || stop "the arm already has $TEST_FILE, so the copy would not be the only test change"
git -C vllm show "$TEST_SRC_SHA:$TEST_FILE" > "vllm/$TEST_FILE" || stop "could not copy $TEST_FILE from $TEST_SRC_SHA"
got=$(cd vllm && sha256sum "$TEST_FILE" | cut -d' ' -f1)
echo "test_file_sha256=$got" >> "$OUT/versions.txt"
[ "$got" = "$TEST_FILE_SHA256" ] || stop "$TEST_FILE has sha256 $got, not the pinned $TEST_FILE_SHA256"
step apply-check 60 --log "$OUT/apply-check.log" git -C vllm apply --check "$DIFF" || stop "the diagnostic patch does not apply to $ARM_SHA; see apply-check.log"
git -C vllm apply "$DIFF" || stop "the diagnostic patch did not apply"
# The tracked changes must be exactly the patch's files, and the only other change the untracked test file.
git -C vllm diff --name-only HEAD | LC_ALL=C sort > "$OUT/changed.txt"
sed -E 's|^diff --git a/([^ ]*) b/.*$|\1|' "$OUT/diff-files.txt" | LC_ALL=C sort > "$OUT/diff-names.txt"
cmp -s "$OUT/changed.txt" "$OUT/diff-names.txt" || stop "the checkout's tracked changes are not exactly the patch's files; see changed.txt"
! git -C vllm ls-files --error-unmatch "$TEST_FILE" > "$OUT/ls-files.log" 2>&1 || stop "$TEST_FILE is tracked, so the copy would not be untracked"
{ git -C vllm rev-parse HEAD; git -C vllm status --porcelain; ( cd vllm && sha256sum "$TEST_FILE" ); git -C vllm diff --stat HEAD; } > "$OUT/tree.txt" 2>&1

# ---------------------------------------------------------------- install, with precompiled kernels
# KIT_OFFLINE_TEST=1 skips the install for hack/vllm-69058-kit-test.sh, which puts fake python, hf and nvidia-smi on PATH; settings.txt says so.
if [ "${KIT_OFFLINE_TEST:-}" = 1 ]; then
  echo "offline_test=1 (fake python, pytest, hf and nvidia-smi; nothing installed)" >> "$OUT/settings.txt"
  # The fake hf cannot write the real weights, so the offline test names the sha256 its fake weights have.
  MODEL_BIN_SHA256=${OFFLINE_MODEL_BIN_SHA256:-$MODEL_BIN_SHA256}
  echo "offline_model_bin_sha256=$MODEL_BIN_SHA256" >> "$OUT/settings.txt"
else
  command -v uv > /dev/null || stop "uv is required"
  uv venv -q --python 3.12 .venv && . .venv/bin/activate || stop "could not make the venv"
  # -v keeps setup.py's lines naming the wheel commit it chose.
  step install-vllm 300 --log "$OUT/install-vllm.log" env -C vllm VLLM_USE_PRECOMPILED=1 uv pip install -v -e . || stop "vLLM did not install; see install-vllm.log"
  # The test-only packages vLLM's tests/conftest.py imports, at the versions the arm's CUDA test lock pins.
  pins=()
  for p in pytest pytest-asyncio tblib httpx; do
    pin=$(command grep -m1 -oE "^$p==[^ ]+" vllm/requirements/test/cuda.txt) || stop "vllm/requirements/test/cuda.txt pins no $p"
    pins+=("$pin")
  done
  echo "test_pins=${pins[*]}" >> "$OUT/versions.txt"
  step install-test 120 --log "$OUT/install-test.log" uv pip install "${pins[@]}" || stop "the test packages did not install; see install-test.log"
  echo "precompiled_wheel: $(command grep -m4 -E 'Using precompiled wheel|precompiled wheel is published|Found precompiled wheel|Downloading wheel from' "$OUT/install-vllm.log" | tr '\n' ' ')" >> "$OUT/versions.txt"
  uv pip freeze > "$OUT/pip-freeze.txt"
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
rm -f "vllm/$TEST_FILE"
git -C vllm checkout -q --detach -f "$ARM_SHA"
[ "${KIT_OFFLINE_TEST:-}" = 1 ] && git -C "$OFFLINE_VLLM_SRC" worktree remove --force "$PWD/vllm"
finish
exit "$VERDICT_RC"
