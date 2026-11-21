#!/bin/bash
# One-GPU check of vLLM #69058, the HF3FS connector reporting a failed load as finished with no load errors.
# hack/gpu-kit-session.sh runs this unmodified on one A10G with OUT set; it can also run by hand on one CUDA GPU with uv on PATH.
#
# The runtime session's spec, on vLLM 2f170a0fed with the fix in local-fix.diff (sha256 pinned below):
#   (a) pytest tests/v1/kv_connector/unit/test_hf3fs_connector.py -k "TestHF3FSLoadErrors or TestHF3FSSchedulerLoadFailure" -rA
#   (c) cd tests && pytest -v -s v1/kv_connector/unit/test_hf3fs_connector.py -k TestHF3FSLoadFailureEndToEnd -rA, with VLLM_ENABLE_V1_MULTIPROCESSING=0
#   (b) pytest tests/v1/kv_connector/unit/test_hf3fs_connector.py -rA
# each run once on base and once on base plus the diff, with the identical command, in the order a, c, b.
# The tests are part of the diff, so "base" is the base commit with only the diff's tests/ part applied, and "fix" is the whole diff.
# (a): the eight tests fail on base and pass with the fix; one of them is skipped without CUDA and has never run on a GPU.
# (c): through `LLM` with facebook/opt-125m, [fail] fails on base at its finish_reason check and both pass with the fix.
# A (c) failure outside the test's deciding assertions is a harness failure, which the verdict reports as NOT RUN with its cause.
# (b): every test outside those ten must pass on both sides, and one whose outcome the fix changes is reported as a finding.
# A skip, an error, a missing summary or a run without CUDA makes a verdict INCOMPLETE, never a pass.
# Every step's exit code goes to $OUT/status.txt, and verdict.py writes $OUT/verdict.json.
# This script exits with the verdict's status: 0 as expected, 2 not, 3 incomplete, 4 (c) not run, 1 stopped.
#
# THE MODEL.
# facebook/opt-125m at revision 27dcfa74d3, its main branch since 2023-09-15, with pytorch_model.bin's sha256 pinned below.
# The weights are downloaded once, checked, and every pytest run after that has the hub offline.
# A failed download or a different revision or weight leaves (c) NOT RUN with the cause, and (a) and (b) still run.
#
# THE BUDGET.
# g5.xlarge bills $0.7683/h all in under the session's caps.
# The session gives bring-up 300 s and the evidence upload 60 s, and confirms termination 360 s after the upload's deadline.
# So with BUDGET_S seconds here the bill runs to 300 + BUDGET_S + 60 + 360 s, which is 3,920 s and $0.8366 at the default 3,200 s.
# The runtime session approved up to about $1, which is reached at 4,686 s, but the session cuts run.sh at 3,300 s, so 3,200 s is the maximum.
# Every long step runs under a timeout for what is left of the budget less a reserve for the verdict, so run.sh ends inside BUDGET_S.
# The session's own hard stop, 3,720 s after launch, is the backstop if this script's budget did not hold, and that worst case is the session's $0.8579.
#
# Settings (KIT_ENV through the session): BUDGET_S (default and maximum 3200), PYTEST_CAP_S (one (a) run's cap, default 300)
# and LLM_CAP_S (one (b) or (c) run's cap, default 900, since (c) is estimated at 5 to 8 minutes a side).
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${OUT:-$HERE/results}
VLLM_SHA=2f170a0fed20fd84dfcf6da2a3a8188a32f67e4e
DIFF="$HERE/local-fix.diff"
# The sha256 of local-fix.diff at storage commit b7dc8449, the runtime session's round-4 draft.
DIFF_SHA256=210caa5fa2f391720dabba5445d297bc414c31ebf650358b8325009644ecf11d
VLLM_REPO=https://github.com/vllm-project/vllm.git
MODEL=facebook/opt-125m
MODEL_REV=27dcfa74d334bc871f3234de431e71c6eeba5dd6
# The hub's LFS sha256 for pytorch_model.bin at MODEL_REV.
MODEL_BIN_SHA256=2d74da6615135c58cf3cf9ad4cb11e7c613ff9e55fe658a47ab83b6c8d1174a9
# The files vLLM reads for this model; the repository's TensorFlow and Flax weights are left out.
MODEL_FILES=(config.json generation_config.json merges.txt vocab.json special_tokens_map.json tokenizer_config.json pytorch_model.bin)
BUDGET_S=${BUDGET_S:-3200}
BUDGET_MAX_S=3200
PYTEST_CAP_S=${PYTEST_CAP_S:-300}
LLM_CAP_S=${LLM_CAP_S:-900}
# Left for verdict.py and the checksums after the last timed step.
RESERVE_S=60
TEST_FILE=tests/v1/kv_connector/unit/test_hf3fs_connector.py
CONNECTOR=vllm/distributed/kv_transfer/kv_connector/v1/hf3fs/hf3fs_connector.py
COMMON=vllm/distributed/kv_transfer/kv_connector/v1/hf3fs/utils/common.py
CMD_A=(pytest "$TEST_FILE" -k "TestHF3FSLoadErrors or TestHF3FSSchedulerLoadFailure" -rA)
CMD_B=(pytest "$TEST_FILE" -rA)
# Command (c) runs in vllm/tests, so its path is relative to that directory.
CMD_C=(pytest -v -s v1/kv_connector/unit/test_hf3fs_connector.py -k TestHF3FSLoadFailureEndToEnd -rA)
START=$(date +%s)

# Settings are checked before OUT is touched, so a refused run leaves nothing behind.
[ $# = 0 ] || { echo "run.sh takes no arguments, and got: $*; settings come from the environment" >&2; exit 1; }
# A leading zero is refused, since bash arithmetic would read it as octal and change or break the budget.
[[ $BUDGET_S =~ ^[1-9][0-9]*$ ]] && [ "$BUDGET_S" -gt "$RESERVE_S" ] && [ "$BUDGET_S" -le "$BUDGET_MAX_S" ] ||
  { echo "BUDGET_S=$BUDGET_S: it must be whole seconds above $RESERVE_S and at most $BUDGET_MAX_S, which keeps g5.xlarge near \$0.84 and inside the session's 3,300 s" >&2; exit 1; }
for v in PYTEST_CAP_S LLM_CAP_S; do
  [[ ${!v} =~ ^[1-9][0-9]*$ ]] && [ "${!v}" -ge 30 ] || { echo "$v=${!v}: it must be whole seconds without a leading zero, at least 30" >&2; exit 1; }
done
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
# c_not_run CAUSE: (c) cannot run in this session; the verdict reads the cause and reports (c) as NOT RUN.
c_not_run() { echo "$*" | tee -a "$OUT/c-not-run.txt" >&2; }

{
  echo "vllm_sha=$VLLM_SHA"; echo "vllm_repo=$VLLM_REPO"; echo "diff_sha256_pin=$DIFF_SHA256"
  echo "model=$MODEL"; echo "model_rev_pin=$MODEL_REV"; echo "model_bin_sha256_pin=$MODEL_BIN_SHA256"
  echo "budget_s=$BUDGET_S"; echo "pytest_cap_s=$PYTEST_CAP_S"; echo "llm_cap_s=$LLM_CAP_S"
  echo "command_a=${CMD_A[*]}"; echo "command_c=cd tests && ${CMD_C[*]}"; echo "command_b=${CMD_B[*]}"
  echo "command_c_env=VLLM_ENABLE_V1_MULTIPROCESSING=0"
  echo "base=the base commit with only the diff's tests/ part applied; fix=the base commit with the whole diff"
} > "$OUT/settings.txt"
[ "${KIT_DRY_RUN:-}" = 1 ] && { echo "dry run: settings accepted"; cat "$OUT/settings.txt"; exit 0; }

# ---------------------------------------------------------------- the diff and the checkout, pinned
got=$(sha256sum "$DIFF" | cut -d' ' -f1)
echo "diff_sha256=$got" > "$OUT/versions.txt"
[ "$got" = "$DIFF_SHA256" ] || stop "local-fix.diff has sha256 $got, not the pinned $DIFF_SHA256"
command -v nvidia-smi > /dev/null || stop "nvidia-smi is not on PATH"
{ nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv; nvidia-smi -L; } > "$OUT/gpu.txt" 2>&1 || stop "nvidia-smi failed; see gpu.txt"
if [ "${KIT_OFFLINE_TEST:-}" = 1 ]; then
  # The offline test has no network, so the checkout is a detached worktree of a local vLLM repository that holds the commit.
  [ -d "${OFFLINE_VLLM_SRC:-}" ] || stop "KIT_OFFLINE_TEST=1 needs OFFLINE_VLLM_SRC, a local vLLM repository"
  step worktree-vllm 120 --log "$OUT/clone.log" git -C "$OFFLINE_VLLM_SRC" worktree add -q --detach "$PWD/vllm" "$VLLM_SHA" || stop "could not check out $VLLM_SHA from $OFFLINE_VLLM_SRC; see clone.log"
else
  # VLLM_USE_PRECOMPILED looks up the wheel from the commit's history, so the clone keeps its history and drops only blobs.
  step clone-vllm 300 --log "$OUT/clone.log" git clone -q --filter=blob:none "$VLLM_REPO" vllm || stop "could not clone vLLM from $VLLM_REPO; see clone.log"
  step checkout-vllm 120 --log "$OUT/checkout.log" git -C vllm checkout -q --detach "$VLLM_SHA" || stop "vLLM has no commit $VLLM_SHA; see checkout.log"
fi
head=$(git -C vllm rev-parse HEAD)
echo "vllm_head=$head" >> "$OUT/versions.txt"
[ "$head" = "$VLLM_SHA" ] || stop "the checkout is at $head, not $VLLM_SHA"
step apply-check 60 --log "$OUT/apply-check.log" git -C vllm apply --check "$DIFF" || stop "the diff does not apply to $VLLM_SHA; see apply-check.log"

# ---------------------------------------------------------------- install, with precompiled kernels
# KIT_OFFLINE_TEST=1 skips the install for hack/vllm-69058-kit-test.sh, which puts fake pytest, python, hf and nvidia-smi on PATH; settings.txt says so.
if [ "${KIT_OFFLINE_TEST:-}" = 1 ]; then
  echo "offline_test=1 (fake pytest, python, hf and nvidia-smi; nothing installed)" >> "$OUT/settings.txt"
  # The fake hf cannot write the real weights, so the offline test names the sha256 its fake weights have.
  MODEL_BIN_SHA256=${OFFLINE_MODEL_BIN_SHA256:-$MODEL_BIN_SHA256}
  echo "offline_model_bin_sha256=$MODEL_BIN_SHA256" >> "$OUT/settings.txt"
else
  command -v uv > /dev/null || stop "uv is required"
  uv venv -q --python 3.12 .venv && . .venv/bin/activate || stop "could not make the venv"
  # The diff changes Python only and the CUDA-only test scatters with a Triton kernel, so vLLM's compiled ops come from the published wheel.
  # -v keeps setup.py's lines naming the wheel commit it chose.
  step install-vllm 600 --log "$OUT/install-vllm.log" env -C vllm VLLM_USE_PRECOMPILED=1 uv pip install -v -e . || stop "vLLM did not install; see install-vllm.log"
  # The test-only packages vLLM's tests/conftest.py imports, at the versions the checkout's CUDA test lock pins.
  pins=()
  for p in pytest pytest-asyncio tblib httpx; do
    pin=$(command grep -m1 -oE "^$p==[^ ]+" vllm/requirements/test/cuda.txt) || stop "vllm/requirements/test/cuda.txt pins no $p"
    pins+=("$pin")
  done
  echo "test_pins=${pins[*]}" >> "$OUT/versions.txt"
  step install-test 300 --log "$OUT/install-test.log" uv pip install "${pins[@]}" || stop "the test packages did not install; see install-test.log"
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
if step download-model 300 --log "$OUT/download.log" hf download "$MODEL" --revision main "${includes[@]}"; then
  # hf prints the snapshot as "path=..." or "  path: ..." depending on its output format, so the path is matched by its shape.
  snap=$(command grep -oE '/[^ ]*/snapshots/[0-9a-f]{40}' "$OUT/download.log" | tail -n 1)
  rev=$(basename "${snap:-none}")
  echo "model_rev=$rev" >> "$OUT/versions.txt"
  if [ -z "$snap" ]; then
    c_not_run "model download failure: download.log names no snapshot"
  elif [ "$rev" != "$MODEL_REV" ]; then
    c_not_run "model download failure: $MODEL main is at revision $rev, not the pinned $MODEL_REV"
  elif ! ( cd "$snap" && sha256sum "${MODEL_FILES[@]}" ) > "$OUT/model-files.sha256" 2>&1; then
    c_not_run "model download failure: the snapshot $snap lacks a file; see model-files.sha256"
  elif ! command grep -qx "$MODEL_BIN_SHA256  pytorch_model.bin" "$OUT/model-files.sha256"; then
    c_not_run "model download failure: pytorch_model.bin is not the pinned sha256 $MODEL_BIN_SHA256; see model-files.sha256"
  else
    # From here the tests read only the checked snapshot, so a hub change mid-run cannot reach them.
    export HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1
    echo "hub_offline=1 from the first test run on" >> "$OUT/settings.txt"
  fi
else
  c_not_run "model download failure: hf download $MODEL exited non-zero; see download.log"
fi

# ---------------------------------------------------------------- base, then fix, the same commands on each
# side SIDE: resets the checkout to the base commit and applies the diff's tests/ part (base) or the whole diff (fix).
side() {
  git -C vllm reset -q --hard "$VLLM_SHA" || stop "could not reset the checkout for $1"
  git -C vllm diff --quiet HEAD || stop "the checkout is not clean before $1"
  if [ "$1" = base ]; then
    git -C vllm apply --include='tests/*' "$DIFF" || stop "the diff's tests/ part did not apply"
    # The diff also touches utils/common.py, so the base side checks that no file under vllm/ changed, not only the connector.
    git -C vllm diff --quiet HEAD -- vllm/ || stop "the base side changed code under vllm/"
  else
    git -C vllm apply "$DIFF" || stop "the diff did not apply"
    ! git -C vllm diff --quiet HEAD -- "$CONNECTOR" || stop "the fix side left the connector unchanged"
  fi
  ! git -C vllm diff --quiet HEAD -- "$TEST_FILE" || stop "the $1 side lacks the diff's tests"
  { git -C vllm status --short --untracked-files=no; ( cd vllm && sha256sum "$TEST_FILE" "$CONNECTOR" "$COMMON" ); git -C vllm diff --stat HEAD; } > "$OUT/tree-$1.txt" 2>&1
}
# When (c) cannot run, the whole file must not run its end-to-end class either.
# A failed download would leave it waiting on the hub, and a wrong revision or weight would run it on an unchecked model with the hub online.
if [ -e "$OUT/c-not-run.txt" ]; then
  CMD_B=(pytest "$TEST_FILE" -k "not TestHF3FSLoadFailureEndToEnd" -rA)
  echo "command_b_run=${CMD_B[*]} (the end-to-end class deselected, since (c) is not run)" >> "$OUT/settings.txt"
fi
# Command (a) runs on both sides first and (c) next, so a run the budget cuts short loses the whole-file runs, which repeat both.
for cmd in a c b; do
  [ "$cmd" = c ] && [ -e "$OUT/c-not-run.txt" ] && { echo "test-c skipped: $(cat "$OUT/c-not-run.txt")" >> "$OUT/status.txt"; continue; }
  for s in base fix; do
    side "$s"
    case $cmd in
      a) step "test-$s-a" "$PYTEST_CAP_S" --log "$OUT/$s-a.log" env -C vllm "${CMD_A[@]}" ;;
      c) step "test-$s-c" "$LLM_CAP_S" --log "$OUT/$s-c.log" env -C vllm/tests VLLM_ENABLE_V1_MULTIPROCESSING=0 "${CMD_C[@]}" ;;
      b) step "test-$s-b" "$LLM_CAP_S" --log "$OUT/$s-b.log" env -C vllm "${CMD_B[@]}" ;;
    esac
  done
done
git -C vllm reset -q --hard "$VLLM_SHA"
[ "${KIT_OFFLINE_TEST:-}" = 1 ] && git -C "$OFFLINE_VLLM_SRC" worktree remove --force "$PWD/vllm"
finish
exit "$VERDICT_RC"
