#!/bin/bash
# One-GPU check of the vLLM HF3FS preemption finding, kit p5: the upstream PR's exact head against a control that has only its test.
# Kit p5 confirms vllm-project/vllm#69271 (issue #69269) before it leaves draft: its head 4ec2f316 on lkhun9311/vllm fix/hf3fs-preemption-save.
# It moves to a new base, main at 0e3c8dbdae, where kits p1 to p4 used 17323e0b1c; the fix hunks are byte for byte kit p4's.
# FIX's tree must be the PR head's tree, which the offline test checks against the fetched head; run.sh pins that tree and checks the applied fix against it.
# The test changed since p4, in the test only: its two CPU stand-in tests are gone, a polled condition replaces a fixed sleep,
# the save wrapper covers the whole test, and the file has a single GPU test, so the verdict expects no CPU tests.
# verdict.py otherwise keeps kit p4's rules: the held-save page errors decide, and a setup failure at the same line with the same error in both arms is NOT RUN.
# hack/vllm-hf3fs-preemption-p5-kit-test.sh runs vLLM's startup check, and the test's reset helper against vLLM's BlockPool, on CPU first, on the new base's code.
# hack/gpu-kit-session.sh runs this unmodified on one A10G, g5.xlarge or g5.2xlarge, with OUT set.
#
# THE FINDING, read statically on vLLM main 17323e0b1c, and at the same lines on 0e3c8dbdae.
# The scheduler's _preempt_request frees a request's blocks through _free_request_blocks (scheduler.py:1849) without request_finished.
# The base hook handle_preemptions (base.py:367) is there for connectors that save asynchronously, and the worker calls it in pre_forward (worker/gpu/kv_connector.py:97).
# HF3FSKVConnector does not implement it, so a save still queued for a preempted request can gather a block after another request reused it.
# The test tests/v1/kv_connector/unit/test_hf3fs_preemption.py holds the target's save, lets decoding preempt the target, and compares the stored pages with a reference.
#
# THE ARMS, on one instance, each in its own pytest process, CONTROL first and FIX second:
#   CONTROL, vllm-project/vllm 0e3c8dbdae plus tests-only.patch applied with git apply, so it has the test and not the fix;
#   FIX, the same commit plus fix-and-tests.patch applied with git am.
# Both patches come from the runtime session's ~/.cache/oss-runtime/patches/hf3fs-preemption-p5/, outside storage, which is frozen,
# so each is pinned by its full sha256.
# git am writes a new commit id, so FIX is pinned by its tree and its parent, and CONTROL by the tree of the base plus the new test.
# Both arms must run the same test file, whose blob is pinned.
# The command for each arm is the runtime session's, with no CUDA_LAUNCH_BLOCKING and no -x:
#   python -m pytest tests/v1/kv_connector/unit/test_hf3fs_preemption.py -q -s --tb=short
# Unlike kits p1 to p4 it keeps pytest's cache provider; the cache only records results, and vLLM's .gitignore covers it.
# -s keeps the test's print lines: the held, reused and hold_timed_out line, the held-save page errors and the end-of-run page errors.
# VLLM_ENABLE_V1_MULTIPROCESSING=0 is not set here, since the test's in_process_metadata fixture sets it itself.
# verdict.py says CONFIRMED only when CONTROL fails the page comparison with every precondition met and FIX passes.
# Every step's exit code goes to $OUT/status.txt, and verdict.py writes $OUT/verdict.json.
# This script exits with the verdict's status: 0 confirmed, 2 a finding, 3 incomplete, 4 not run, 5 inconclusive, 1 stopped.
#
# THE ENVIRONMENT.
# As in vllm-69058 kit r6: Python 3.12 from the session, vLLM installed with VLLM_USE_PRECOMPILED=1 and a wheel commit named explicitly,
# the test packages the base's CUDA test lock pins, and facebook/opt-125m at revision 27dcfa74d3 with its weights' sha256 pinned, after which the hub is offline.
# The base 0e3c8dbdae has no published wheel; on 2026-11-23 its first parent e2052f5c7a had one for cu132 and x86_64,
# and the two differ only in recipes/models/moonshotai/Kimi-K3.1-Pro.yaml, nothing under setup.py's blocking or warning paths.
# Naming the commit skips setup.py's own check of the compiled sources, so run.sh checks that the wheel commit is the base's first parent
# and that the two commits do not differ in setup.py's blocking paths, then that the install log names that commit.
# One install serves both arms, since the fix changes only Python files.
#
# THE PERFORMANCE RUN b1, in the same session after the two test arms, and apart from their verdict.
# bench_preempt.py (not part of the PR; from storage's open-source/contributions/vllm/hf3fs-preemption-save/bench/, pinned by sha256)
# times one in-process LLM with the HF3FS connector under load: 64 requests of 256 prompt tokens and 256 greedy tokens with ignore_eos.
# It runs on the same two trees: CONTROL, the base (the test file tests-only.patch adds does not matter to it), and FIX, the PR head's tree.
# Each run is its own process, from the tree's root with the tree on PYTHONPATH, interleaved:
#   --pool-blocks 128, which preempts: CONTROL, FIX, CONTROL, FIX, CONTROL, FIX;
#   --pool-blocks 2048, which should not: CONTROL, FIX.
# Each run's JSON reports has_fix, and a run whose has_fix is not false in CONTROL and true in FIX means a wrong tree: b1 stops, NOT RUN.
# b1_verdict.py prints every JSON verbatim and never changes a value; it calls b1 INVALID when a pool-128 run did not preempt,
# when a pool-2048 run did, or when a run's log shows the HF3FS metadata server short of pages, which drops saves the JSON does not count.
# As pinned, bench_preempt.py's 1 GiB file holds 1,820 OPT-125m pages for about 2,000 saved blocks, and pool 2048 less the null block
# leaves 2,047 blocks for 64 requests of 32, so those two rules may well fire; they report it, and b1's values stay as they were.
# The test arms are decided first: verdict.py writes the p5 verdict before b1 starts, and run.sh exits with it.
# A b1 that fails or runs out of budget stops only b1, writing b1/STOPPED, and leaves the p5 evidence as it was.
#
# THE BUDGET.
# The session gives bring-up 300 s and the evidence upload 60 s, and confirms termination 360 s after the upload's deadline.
# So with BUDGET_S seconds here the bill runs to 300 + BUDGET_S + 60 + 360 s, which is 2,520 s at the default 1,800 s:
# $0.5378 on g5.xlarge at $0.7683/h all in, and $0.6078 on g5.2xlarge at $0.8683/h, the same A10G with more memory.
# This script refuses BUDGET_S above 1,800.
# The test arms keep kit p4's 600 s, P5_BUDGET_S, so b1 can neither starve them nor reach their verdict; b1 has what is left of BUDGET_S.
# Without b1 the bill would be kit p4's, $0.2817 and $0.3184, so b1 adds at most $0.2561 and $0.2894.
# Run p4 (gpuaas 1088e55a), an earlier version of this test with its CPU tests, reached its tests at 125 s after a 97 s install,
# its CONTROL process took 187 s and its FIX 71 s, so run.sh ended at 383 s, and its session billed 803 s, $0.17 on g5.xlarge.
# b1 is estimated, not measured, since the CPU vLLM environment cannot run LLM(): in run p4 the FIX process's engine was up 5 s after its log began,
# after about 12 s of imports, so each b1 process pays about 20 s before its load; a pool-128 load preempts its way through 16,384 tokens
# with about four requests running, about 4,700 steps at 10 to 15 ms, so 50 to 70 s; a pool-2048 load runs all 64 at once in about 300 steps.
# So b1 should take about 6 x 90 + 2 x 30 = 600 s, with B1_CAP_S, 240 s, capping each process, and 1,140 s or more of BUDGET_S left for it.
# Expected in all, not measured: run.sh about 1,000 s and the session about 1,400 s, $0.30 on g5.xlarge and $0.34 on g5.2xlarge.
# Each process is capped at ARM_CAP_S, 240 s by default, or what the budget has left, so a hung arm cannot starve the other past the budget.
# Every command that can wait runs under a timeout for what is left of the budget less a reserve for the verdict, so run.sh ends inside BUDGET_S.
# The bill above assumes the session's evidence upload and termination go as planned.
# The session lets a stalled upload run to 3,660 s after launch and stops the instance at 3,720 s, so the true worst case stays the session's:
# $0.8579 on g5.xlarge and $0.9696 on g5.2xlarge.
#
# Settings (KIT_ENV through the session): BUDGET_S (default and maximum 1800), ARM_CAP_S (each test process's cap, default 240),
# B1 (1 to run b1, the default, or 0 to skip it) and B1_CAP_S (each b1 process's cap, default 240).
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${OUT:-$HERE/results}
UPSTREAM=https://github.com/vllm-project/vllm.git
BASE_SHA=0e3c8dbdae9d55149b0fba4e6c1014b4b08c9c73
BASE_TREE=e6819e279d40268d45eee2bfa134d5d04b05e53f
TESTS_PATCH="$HERE/tests-only.patch"
FIX_PATCH="$HERE/fix-and-tests.patch"
# The sha256 of ~/.cache/oss-runtime/patches/hf3fs-preemption-p5/tests-only.patch and fix-and-tests.patch, made from the PR head 4ec2f316 on 0e3c8dbdae.
TESTS_PATCH_SHA256=bcbb9fec95bed88a2f7d8f399e18f7a72fb3e618e6a9e27db575662f77b31b0c
FIX_PATCH_SHA256=8da42418ce7bcd85a85c19067a8c4da2dece1dbb485b765e0471759abed30eb6
# The tree git am gives the fix on the base, and the tree of the base plus the new test file.
FIX_TREE=441714150d9afe8fd27523f66f288568e8a8c1e8
# The upstream PR's head and its tree, which the fix's tree must be.
PR_HEAD=4ec2f316fb847673a5edb3ce337a0abae9263899
PR_HEAD_TREE=441714150d9afe8fd27523f66f288568e8a8c1e8
CONTROL_TREE=66cc798220693c7256072a87e1a8ab19952f37c5
TEST_FILE=tests/v1/kv_connector/unit/test_hf3fs_preemption.py
# The test file's blob, the same in both arms.
TEST_BLOB=9b1c0115b5ece0918d7a6b250c5f37b9fdf2b37f
CONNECTOR=vllm/distributed/kv_transfer/kv_connector/v1/hf3fs/hf3fs_connector.py
MODEL=facebook/opt-125m
MODEL_REV=27dcfa74d334bc871f3234de431e71c6eeba5dd6
# The hub's LFS sha256 for pytorch_model.bin at MODEL_REV.
MODEL_BIN_SHA256=2d74da6615135c58cf3cf9ad4cb11e7c613ff9e55fe658a47ab83b6c8d1174a9
# The files vLLM reads for this model; the repository's TensorFlow and Flax weights are left out.
MODEL_FILES=(config.json generation_config.json merges.txt vocab.json special_tokens_map.json tokenizer_config.json pytorch_model.bin)
BUDGET_S=${BUDGET_S:-1800}
BUDGET_MAX_S=1800
# The test arms' own budget, kit p4's; b1 runs only in what is left of BUDGET_S after them.
P5_BUDGET_S=600
B1=${B1:-1}
B1_CAP_S=${B1_CAP_S:-240}
BENCH="$HERE/bench_preempt.py"
# The sha256 of storage's open-source/contributions/vllm/hf3fs-preemption-save/bench/bench_preempt.py, read on 2026-11-23.
BENCH_SHA256=575d32cc8e33e1db827c8f37b35d47c3f167b0f1fe46b6807ce78b5346613f9a
# The b1 processes in order, as arm:pool:run.
B1_RUNS=(control:128:1 fix:128:1 control:128:2 fix:128:2 control:128:3 fix:128:3 control:2048:1 fix:2048:1)
ARM_CAP_S=${ARM_CAP_S:-240}
# The precompiled wheel's commit, the base's first parent, the nearest main commit with a published wheel.
WHEEL_COMMIT=e2052f5c7ad64564f00dd4592e77c27785c9333f
# setup.py's WHEEL_BLOCKING_PATHS at the base: a change under these makes an older wheel's extensions unusable.
WHEEL_BLOCKING_PATHS=(csrc cmake CMakeLists.txt pyproject.toml vllm/_custom_ops.py vllm/_cpu_ops.py)
# Left for verdict.py and the checksums after the last timed step.
RESERVE_S=60
# How long timeout waits after SIGTERM before SIGKILL, for every timed step.
KILL_GRACE_S=10
# The two processes in order.
RUNS=(control fix)
# cmd: the runtime session's command for one arm.
cmd() { echo python -m pytest "$TEST_FILE" -q -s --tb=short; }
START=$(date +%s)

# Settings are checked before OUT is touched, so a refused run leaves nothing behind.
[ $# = 0 ] || { echo "run.sh takes no arguments, and got: $*; settings come from the environment" >&2; exit 1; }
# A leading zero is refused, since bash arithmetic would read it as octal and change or break the budget.
[[ $BUDGET_S =~ ^[1-9][0-9]*$ ]] && [ "$BUDGET_S" -gt "$RESERVE_S" ] && [ "$BUDGET_S" -le "$BUDGET_MAX_S" ] ||
  { echo "BUDGET_S=$BUDGET_S: it must be whole seconds above $RESERVE_S and at most $BUDGET_MAX_S" >&2; exit 1; }
[[ $ARM_CAP_S =~ ^[1-9][0-9]*$ ]] && [ "$ARM_CAP_S" -ge 30 ] || { echo "ARM_CAP_S=$ARM_CAP_S: it must be whole seconds without a leading zero, at least 30" >&2; exit 1; }
[[ $B1 =~ ^[01]$ ]] || { echo "B1=$B1: it must be 1 to run b1 or 0 to skip it" >&2; exit 1; }
[[ $B1_CAP_S =~ ^[1-9][0-9]*$ ]] && [ "$B1_CAP_S" -ge 30 ] || { echo "B1_CAP_S=$B1_CAP_S: it must be whole seconds without a leading zero, at least 30" >&2; exit 1; }
# The test arms plan against the smaller of their own budget and the whole one.
[ "$BUDGET_S" -lt "$P5_BUDGET_S" ] && P5_BUDGET_S=$BUDGET_S
# Until the test arms are done, every step plans against their budget; b1 then plans against BUDGET_S.
STEP_BUDGET_S=$P5_BUDGET_S
PHASE=p5
# CUDA_LAUNCH_BLOCKING would serialise the launches and change the timing this run depends on, so it is refused rather than passed through.
[ -z "${CUDA_LAUNCH_BLOCKING:-}" ] || { echo "CUDA_LAUNCH_BLOCKING is set; this check runs without it" >&2; exit 1; }
for v in CASE_CAP_S PYTEST_CAP_S LLM_CAP_S UNIT_CAP_S E2E_CAP_S; do [ -z "${!v:-}" ] || { echo "$v is set; kit p5 caps each process with ARM_CAP_S" >&2; exit 1; }; done
mkdir -p "$OUT" || exit 1
# A rerun into the same OUT would leave the earlier logs for verdict.py to read, so only an empty OUT is used.
if [ -n "$(ls -A "$OUT")" ]; then echo "OUT=$OUT is not empty; each run writes a new directory" >&2; exit 1; fi
: > "$OUT/status.txt"

# Each phase's end runs two timed commands, which with their kill graces take at most 25 + 5 + 20 + 5 = 55 s, inside RESERVE_S:
# the test arms' verdict and then, after b1, b1's verdict, each followed in the end by the checksums.
# py: the python on PATH when called, which is the venv's once it is active.
py() { command -v python || command -v python3; }
p5_verdict() {
  timeout --kill-after=5 25 "$(py)" "$HERE/verdict.py" "$OUT" > "$OUT/verdict.txt" 2>&1
  VERDICT_RC=$?
  echo "verdict exit=$VERDICT_RC t=$(( $(date +%s) - START ))" >> "$OUT/status.txt"
  cat "$OUT/verdict.txt"
}
checksums() {
  ( cd "$OUT" && find . -type f ! -name SHA256SUMS | LC_ALL=C sort | timeout --kill-after=5 20 xargs -d '\n' sha256sum > SHA256SUMS )
}
finish() {
  p5_verdict
  checksums
}
VERDICT_RC=1
stop() { # the reason; the run ends here and says why
  # In b1 the caller runs in a subshell, so this ends b1 alone and leaves the test arms' STOPPED, verdict and logs as they are.
  if [ "$PHASE" = b1 ]; then
    echo "$*" | tee "$OUT/b1/STOPPED" >&2
    echo "b1 STOPPED $*" >> "$OUT/status.txt"
    exit 1
  fi
  echo "$*" | tee "$OUT/STOPPED" >&2
  echo "STOPPED $*" >> "$OUT/status.txt"
  [ "${KIT_OFFLINE_TEST:-}" = 1 ] && [ -d "${OFFLINE_VLLM_SRC:-}" ] && [ -e "$PWD/vllm" ] && git -C "$OFFLINE_VLLM_SRC" worktree remove --force "$PWD/vllm" 2>> "$OUT/pins.log"
  finish
  exit 1
}
# step NAME CAP [--log FILE] COMMAND...: runs COMMAND under a timeout of CAP or what the budget has left, records its exit code and returns it.
step() {
  local name=$1 cap=$2 log=/dev/stdout; shift 2
  if [ "${1:-}" = --log ]; then log=$2; shift 2; fi
  # A command that ignores SIGTERM runs KILL_GRACE_S past its cap, so the grace comes out of what is left.
  local left=$(( STEP_BUDGET_S - RESERVE_S - KILL_GRACE_S - ($(date +%s) - START) ))
  [ "$left" -gt 0 ] || stop "the budget ran out before $name"
  [ "$cap" -le "$left" ] || cap=$left
  timeout --kill-after="$KILL_GRACE_S" "$cap" "$@" > "$log" 2>&1
  local rc=$?
  echo "$name exit=$rc t=$(( $(date +%s) - START ))" | tee -a "$OUT/status.txt"
  return $rc
}

{
  echo "kit=p5"; echo "upstream=$UPSTREAM"
  echo "base=$BASE_SHA tree $BASE_TREE"
  echo "control=base plus tests-only.patch (sha256 $TESTS_PATCH_SHA256) by git apply, pinned by tree $CONTROL_TREE"
  echo "fix=base plus fix-and-tests.patch (sha256 $FIX_PATCH_SHA256) by git am, pinned by tree $FIX_TREE"
  echo "pr=vllm-project/vllm#69271 head $PR_HEAD tree $PR_HEAD_TREE"
  echo "test_file=$TEST_FILE blob $TEST_BLOB"
  echo "model=$MODEL"; echo "model_rev_pin=$MODEL_REV"; echo "model_bin_sha256_pin=$MODEL_BIN_SHA256"
  echo "budget_s=$BUDGET_S"; echo "arm_cap_s=$ARM_CAP_S"; echo "wheel_commit=$WHEEL_COMMIT (the base's first parent)"
  echo "order=${RUNS[*]}, each in its own process"
  echo "command=$(cmd)"
  echo "p5_budget_s=$P5_BUDGET_S"; echo "b1=$B1"; echo "b1_cap_s=$B1_CAP_S"; echo "bench_sha256_pin=$BENCH_SHA256"
  echo "b1_order=${B1_RUNS[*]}, each in its own process: python bench_preempt.py --pool-blocks POOL --out ARM-POOL-RUN.json"
} > "$OUT/settings.txt"
[ "${KIT_DRY_RUN:-}" = 1 ] && { echo "dry run: settings accepted"; cat "$OUT/settings.txt"; exit 0; }

# ---------------------------------------------------------------- the patches and the base, pinned
got_tests=$(sha256sum "$TESTS_PATCH" | cut -d' ' -f1)
got_fix=$(sha256sum "$FIX_PATCH" | cut -d' ' -f1)
{ echo "tests_patch_sha256=$got_tests"; echo "fix_patch_sha256=$got_fix"; } > "$OUT/versions.txt"
[ "$got_tests" = "$TESTS_PATCH_SHA256" ] || stop "tests-only.patch has sha256 $got_tests, not the pinned $TESTS_PATCH_SHA256"
[ "$got_fix" = "$FIX_PATCH_SHA256" ] || stop "fix-and-tests.patch has sha256 $got_fix, not the pinned $FIX_PATCH_SHA256"
# A driver in a bad state can hang nvidia-smi, so it gets a timeout like every other command that can wait.
step nvidia-smi 60 --log "$OUT/gpu.txt" bash -c 'nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv && nvidia-smi -L' || stop "nvidia-smi failed; see gpu.txt"
if [ "${KIT_OFFLINE_TEST:-}" = 1 ]; then
  # The offline test has no network, so the checkout is a detached worktree of a local vLLM repository that holds the base commit.
  [ -d "${OFFLINE_VLLM_SRC:-}" ] || stop "KIT_OFFLINE_TEST=1 needs OFFLINE_VLLM_SRC, a local vLLM repository"
  step worktree-vllm 120 --log "$OUT/clone.log" git -C "$OFFLINE_VLLM_SRC" worktree add -q --detach "$PWD/vllm" "$BASE_SHA" ||
    stop "could not check out the base from $OFFLINE_VLLM_SRC; see clone.log"
else
  # VLLM_USE_PRECOMPILED reads the commit's history, so the clone keeps its history and drops only blobs.
  # The base is a main commit, so the clone of main holds it and its first parent.
  step clone-vllm 300 --log "$OUT/clone.log" git clone -q --filter=blob:none "$UPSTREAM" vllm || stop "could not clone vLLM from $UPSTREAM; see clone.log"
fi
git -C vllm cat-file -e "$BASE_SHA^{commit}" 2>> "$OUT/pins.log" || stop "commit $BASE_SHA is not in the fetched repository"
tree=$(git -C vllm rev-parse "$BASE_SHA^{tree}")
echo "base commit=$BASE_SHA tree=$tree" >> "$OUT/versions.txt"
[ "$tree" = "$BASE_TREE" ] || stop "the base $BASE_SHA has tree $tree, not the pinned $BASE_TREE"
# The wheel's commit must be the base's first parent, with no change under the blocking paths, since naming it skips setup.py's own check.
parent=$(git -C vllm rev-parse "$BASE_SHA^1")
echo "base_first_parent=$parent wheel_commit=$WHEEL_COMMIT" >> "$OUT/versions.txt"
[ "$parent" = "$WHEEL_COMMIT" ] || stop "the base's first parent is $parent, not the wheel commit $WHEEL_COMMIT"
# --no-renames keeps the diff to tree entries, which a blobless clone holds.
git -C vllm diff --no-renames --name-only "$WHEEL_COMMIT" "$BASE_SHA" -- "${WHEEL_BLOCKING_PATHS[@]}" > "$OUT/wheel-blocking-diff.txt" 2>> "$OUT/pins.log" ||
  stop "could not diff the wheel commit against the base; see pins.log"
[ ! -s "$OUT/wheel-blocking-diff.txt" ] || stop "the base changes compiled sources since the wheel commit; see wheel-blocking-diff.txt"
# The clone has no blobs, so the checkout that fetches them runs as a timed step.
step materialize-base 300 --log "$OUT/materialize-base.log" git -C vllm checkout -q --detach -f "$BASE_SHA" || stop "could not check out the base; see materialize-base.log"

# ---------------------------------------------------------------- the fix commit, pinned by its tree
# git am needs an identity for the commit it writes; the result is checked by its tree, which the identity does not touch.
step git-am 60 --log "$OUT/git-am.log" git -C vllm -c user.name=kit -c user.email=kit@localhost -c commit.gpgsign=false am -q "$FIX_PATCH" ||
  stop "fix-and-tests.patch did not apply with git am; see git-am.log"
FIX_HEAD=$(git -C vllm rev-parse HEAD)
tree=$(git -C vllm rev-parse "$FIX_HEAD^{tree}")
parent=$(git -C vllm rev-parse "$FIX_HEAD^")
echo "fix commit=$FIX_HEAD tree=$tree parent=$parent" >> "$OUT/versions.txt"
[ "$parent" = "$BASE_SHA" ] || stop "the fix commit's parent is $parent, not $BASE_SHA"
[ "$tree" = "$FIX_TREE" ] || stop "the fix commit has tree $tree, not the pinned $FIX_TREE"
# The run confirms the PR as it stands, so the pinned fix tree must be the PR head's; the offline test checks the head itself.
[ "$FIX_TREE" = "$PR_HEAD_TREE" ] || stop "the pinned fix tree $FIX_TREE is not the PR head $PR_HEAD's tree $PR_HEAD_TREE"
# The control must not carry the hook the fix adds, and the fix must add exactly one.
n_control=$(git -C vllm show "$BASE_SHA:$CONNECTOR" | command grep -c '^    def handle_preemptions(')
n_fix=$(git -C vllm show "$FIX_HEAD:$CONNECTOR" | command grep -c '^    def handle_preemptions(')
echo "handle_preemptions_defs control=$n_control fix=$n_fix" >> "$OUT/versions.txt"
[ "$n_control" = 0 ] && [ "$n_fix" = 1 ] || stop "the connector defines handle_preemptions() $n_control times in the control and $n_fix in the fix; want 0 and 1"

# arm NAME: puts the checkout on the control (the base plus the test, untracked) or the fix commit, and refuses anything else.
arm() {
  # The control's test file is untracked, so it is removed before either checkout, which would otherwise keep or refuse it.
  rm -f "vllm/$TEST_FILE"
  if [ "$1" = control ]; then
    git -C vllm checkout -q --detach -f "$BASE_SHA" || stop "could not check out the base for the control"
    git -C vllm apply "$TESTS_PATCH" 2>> "$OUT/pins.log" || stop "tests-only.patch did not apply with git apply; see pins.log"
    [ "$(git -C vllm rev-parse HEAD)" = "$BASE_SHA" ] || stop "the control is not at $BASE_SHA"
    ! git -C vllm ls-files --error-unmatch "$TEST_FILE" > /dev/null 2>&1 || stop "the control's test file is tracked, so the control is not the base plus the test"
    # The control's tree is what the checkout holds, its tracked files as they are plus the test file, written through a throwaway index.
    # add -u takes in any change to a tracked file, so a control patched beyond the test cannot match the pin.
    local idx="$PWD/.control-index" t
    rm -f "$idx"
    t=$(GIT_INDEX_FILE="$idx" git -C vllm read-tree "$BASE_SHA" && GIT_INDEX_FILE="$idx" git -C vllm add -u && GIT_INDEX_FILE="$idx" git -C vllm add -f "$TEST_FILE" &&
      GIT_INDEX_FILE="$idx" git -C vllm write-tree)
    rm -f "$idx"
    echo "control tree=$t" >> "$OUT/versions.txt"
    [ "$t" = "$CONTROL_TREE" ] || stop "the control has tree $t, not the pinned $CONTROL_TREE"
  else
    git -C vllm checkout -q --detach -f "$FIX_HEAD" || stop "could not check out the fix"
    [ "$(git -C vllm rev-parse HEAD)" = "$FIX_HEAD" ] || stop "the fix arm is not at $FIX_HEAD"
  fi
  [ -z "$(git -C vllm status --porcelain --untracked-files=no)" ] || stop "the $1 arm has tracked changes"
  local blob
  blob=$(git -C vllm hash-object "$TEST_FILE")
  echo "$1 test_blob=$blob" >> "$OUT/versions.txt"
  [ "$blob" = "$TEST_BLOB" ] || stop "the $1 arm's test file is blob $blob, not the pinned $TEST_BLOB"
}

# ---------------------------------------------------------------- install, with precompiled kernels, at the control
arm control
# KIT_OFFLINE_TEST=1 skips the install for hack/vllm-hf3fs-preemption-p5-kit-test.sh, which puts fake python, hf and nvidia-smi on PATH; settings.txt says so.
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
  command grep -m1 -o "Using precompiled wheel commit $WHEEL_COMMIT with variant [a-z0-9]*" "$OUT/install-vllm.log" >> "$OUT/versions.txt"
  # The test-only packages vLLM's tests/conftest.py imports, at the versions the base's CUDA test lock pins.
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
# From here the tests read only the checked snapshot, so a hub change mid-run cannot reach them.
export HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1
echo "hub_offline=1 for the test runs" >> "$OUT/settings.txt"

# ---------------------------------------------------------------- the two processes
read -r -a words <<< "$(cmd)"
for a in "${RUNS[@]}"; do
  arm "$a"
  step "test-$a" "$ARM_CAP_S" --log "$OUT/e2e-$a.log" env -C vllm "${words[@]}"
done
# The test arms are decided here, before b1, which cannot change or delay their verdict.
p5_verdict

# ---------------------------------------------------------------- b1, the performance run, apart from the verdict above
# b1_json_has_fix FILE: the run's has_fix as Python prints it, or nothing when the JSON is missing or unreadable.
b1_json_has_fix() { "$(py)" -c 'import json, sys; print(json.load(open(sys.argv[1]))["has_fix"])' "$1" 2>> "$OUT/b1/preflight.log"; }
b1() {
  local r a pool i want got
  mkdir -p "$OUT/b1" || return 0
  got=$(sha256sum "$BENCH" | cut -d' ' -f1)
  echo "bench_sha256=$got" > "$OUT/b1/versions.txt"
  [ "$got" = "$BENCH_SHA256" ] || { ( stop "bench_preempt.py has sha256 $got, not the pinned $BENCH_SHA256" ); return 0; }
  for r in "${B1_RUNS[@]}"; do
    a=${r%%:*} pool=${r#*:} i=${pool#*:} pool=${pool%%:*}
    # Each checkout and each process runs in a subshell, so a stop inside them ends b1 and nothing else.
    ( arm "$a" ) || return 0
    ( step "b1-$a-$pool-$i" "$B1_CAP_S" --log "$OUT/b1/$a-$pool-$i.log" env -C vllm PYTHONPATH="$PWD/vllm" \
        python "$BENCH" --pool-blocks "$pool" --out "$OUT/b1/$a-$pool-$i.json" )
    [ -e "$OUT/b1/STOPPED" ] && return 0
    # The preflight: a CONTROL run must report has_fix false and a FIX run true, or the tree is not the one b1 means to time.
    if [ "$a" = control ]; then want=False; else want=True; fi
    got=$(b1_json_has_fix "$OUT/b1/$a-$pool-$i.json")
    if [ -n "$got" ] && [ "$got" != "$want" ]; then
      echo "b1-$a-$pool-$i reported has_fix=$got, where the $a tree must report $want" > "$OUT/b1/NOT_RUN"
      echo "b1 NOT_RUN $(cat "$OUT/b1/NOT_RUN")" >> "$OUT/status.txt"
      return 0
    fi
  done
}
if [ "$B1" = 1 ]; then
  PHASE=b1
  STEP_BUDGET_S=$BUDGET_S
  b1
  timeout --kill-after=5 25 "$(py)" "$HERE/b1_verdict.py" "$OUT" > "$OUT/b1/b1-verdict.txt" 2>&1
  echo "b1-verdict exit=$? t=$(( $(date +%s) - START ))" >> "$OUT/status.txt"
  cat "$OUT/b1/b1-verdict.txt"
else
  echo "b1 skipped (B1=0)" >> "$OUT/status.txt"
fi
[ "${KIT_OFFLINE_TEST:-}" = 1 ] && git -C "$OFFLINE_VLLM_SRC" worktree remove --force "$PWD/vllm"
checksums
# b1 never sets the exit status: it is the test arms' verdict.
exit "$VERDICT_RC"
