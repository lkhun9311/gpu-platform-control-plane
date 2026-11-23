#!/bin/bash
# One-GPU check of the vLLM HF3FS preemption fix, kit p6: the PR's next head, which waits only for the gathers of preempted requests.
# vllm-project/vllm#69271 (issue #69269) moves from 4ec2f316, confirmed by kit p5, to the runtime session's commit 23884c5eb2 on it:
# handle_preemptions now calls AsyncOperationManager.wait_for_gathers, which waits until each queued save of a preempted request
# has copied its blocks into device buffers, rather than wait_for_saves, which waited for the whole save to 3FS.
# The patch is gathers.patch, git am'd onto the PR head, which is itself kit p5's fix-and-tests.patch git am'd onto the base.
# Both are pinned by sha256, and FIX by the trees after each step: the PR head's, then 23884c5eb2's.
# The test file changes by one line, the save task's unpacking, so the patched file's blob is pinned too.
# hack/gpu-kit-session.sh runs this unmodified on one A10G, g5.xlarge or g5.2xlarge, with OUT set.
#
# THE TEST ARM, FIX alone: CONTROL is kit p5's, unchanged by this patch, and kit p5 ran it, so no control arm runs here.
#   python -m pytest tests/v1/kv_connector/unit/test_hf3fs_preemption.py -q -s --tb=short
# verdict.py expects 1 passed, every held-save page error 0.0, every precondition met and hold_timed_out=True,
# and prints the pytest summary line verbatim, for the PR.
# The test still holds the target's save before _handle_save_task, so its gather waits for the release and the hold times out with the fix.
#
# THE BENCH ARM b2, on the same FIX tree after the test arm: bench_preempt_v2.py, pinned by sha256, the runtime session's,
# which times wait_for_gathers or wait_for_saves, whichever the tree has, and names it as fix_wait in its JSON.
# Each run is its own process, from the tree's root with the tree on PYTHONPATH and its own TMPDIR, deleted after it:
#   --pool-blocks 128 three times, which preempts, then --pool-blocks 2304 once, which must not.
# A run whose has_fix is not true means a wrong tree: b2 stops, NOT RUN; b2_verdict.py also wants fix_wait to be wait_for_gathers.
# b2_verdict.py prints every JSON verbatim and never changes a value. Its validity rules are the runtime session's of 2026-11-23:
#   no save failure in a run's log, and no "only allocated" line;
#   each run's stored_keys within 1% of b1's at the same pool (gpuaas 28845963: pool 128 stored 1,882 to 1,883, pool 2304 2,003), both printed;
#   the pool-2304 run's stored_keys exactly 2,003; a pool-128 run preempting, and the pool-2304 run not.
# The test arm is decided first and run.sh exits with its verdict; b2 stops only itself, writing b2/STOPPED, and never touches the test's evidence.
# With P6=0 the test arm is skipped for a b2-only session, and run.sh exits with b2's status.
#
# THE ENVIRONMENT, as in kit p5: the same base 0e3c8dbdae and its first parent e2052f5c7a's precompiled wheel, checked the same way,
# the base's CUDA test lock pins, and facebook/opt-125m at revision 27dcfa74d3 with its weights' sha256 pinned, after which the hub is offline.
#
# THE BUDGET.
# The session gives bring-up 300 s and the evidence upload 60 s, and confirms termination 360 s after the upload's deadline.
# So with BUDGET_S seconds here the bill runs to 300 + BUDGET_S + 60 + 360 s, which is 1,920 s at the default 1,200 s:
# $0.4098 on g5.xlarge at $0.7683/h all in, and $0.4631 on g5.2xlarge at $0.8683/h. This script refuses BUDGET_S above 1,200.
# The test arm keeps 600 s, P6_BUDGET_S, and b2 has what is left; the test process is capped at ARM_CAP_S and each b2 run at B2_CAP_S.
# Measured in b1 (gpuaas 28845963): setup took 62 s, the first process 190 s while it warmed the caches, each later pool-128 run about 50 s
# and each pool-2304 run about 23 s, and the session billed 939 s.
# Expected here, not measured: setup 62 s, the test about 190 s as the first process, b2 about 3 x 50 + 23 = 175 s,
# so run.sh about 430 s and the session about 850 s, $0.18 on g5.xlarge and $0.21 on g5.2xlarge.
# Every command that can wait runs under a timeout for what is left of the budget less a reserve, so run.sh ends inside BUDGET_S.
# The session lets a stalled upload run to 3,660 s after launch and stops the instance at 3,720 s, so the true worst case stays the session's:
# $0.8579 on g5.xlarge and $0.9696 on g5.2xlarge.
#
# Settings (KIT_ENV through the session): BUDGET_S (default and maximum 1200), ARM_CAP_S (the test process's cap, default 300),
# B2 (1 to run b2, the default, or 0 to skip it), B2_CAP_S (each b2 run's cap, default 240),
# and P6 (1 to run the test arm, the default, or 0 to skip it for a b2-only session; P6=0 needs B2=1).
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${OUT:-$HERE/results}
UPSTREAM=https://github.com/vllm-project/vllm.git
BASE_SHA=0e3c8dbdae9d55149b0fba4e6c1014b4b08c9c73
BASE_TREE=e6819e279d40268d45eee2bfa134d5d04b05e53f
FIX_PATCH="$HERE/fix-and-tests.patch"
GATHERS_PATCH="$HERE/gathers.patch"
# The sha256 of kit p5's fix-and-tests.patch, which git am makes the PR head 4ec2f316 from on 0e3c8dbdae.
FIX_PATCH_SHA256=8da42418ce7bcd85a85c19067a8c4da2dece1dbb485b765e0471759abed30eb6
# The sha256 of storage's open-source/contributions/vllm/hf3fs-preemption-save/p6/0001-Bugfix-KV-Connector-Wait-only-for-HF3FS-gathers-of-p.patch,
# read on 2026-11-23, the runtime session's commit 23884c5eb2 on the PR head.
GATHERS_PATCH_SHA256=ae802dc58d3eda026d09b1f5ec201f74dde9bd4e871dcd8c918554dd1029b1cd
# The PR head and its tree, which the first git am must give.
PR_HEAD=4ec2f316fb847673a5edb3ce337a0abae9263899
PR_HEAD_TREE=441714150d9afe8fd27523f66f288568e8a8c1e8
# The runtime session's commit and its tree, which the second git am must give: this is FIX.
P6_COMMIT=23884c5eb20699e463f177d06d0ecde297fb3e46
FIX_TREE=e7475ec46141b6764a1cf9874bcd7efa1e7003db
TEST_FILE=tests/v1/kv_connector/unit/test_hf3fs_preemption.py
# The patched test file's blob.
TEST_BLOB=b5edb870ccf6d8e90634ee652b275cb6d7ed58e8
CONNECTOR=vllm/distributed/kv_transfer/kv_connector/v1/hf3fs/hf3fs_connector.py
MODEL=facebook/opt-125m
MODEL_REV=27dcfa74d334bc871f3234de431e71c6eeba5dd6
# The hub's LFS sha256 for pytorch_model.bin at MODEL_REV.
MODEL_BIN_SHA256=2d74da6615135c58cf3cf9ad4cb11e7c613ff9e55fe658a47ab83b6c8d1174a9
# The files vLLM reads for this model; the repository's TensorFlow and Flax weights are left out.
MODEL_FILES=(config.json generation_config.json merges.txt vocab.json special_tokens_map.json tokenizer_config.json pytorch_model.bin)
BUDGET_S=${BUDGET_S:-1200}
BUDGET_MAX_S=1200
# The test arm's own budget; b2 runs only in what is left of BUDGET_S after it.
P6_BUDGET_S=600
B2=${B2:-1}
P6=${P6:-1}
# b2 stops rather than start a run with less than this free, in GB, where its storage goes.
B2_MIN_FREE_GB=10
B2_CAP_S=${B2_CAP_S:-240}
BENCH="$HERE/bench_preempt_v2.py"
# The sha256 of storage's open-source/contributions/vllm/hf3fs-preemption-save/bench/bench_preempt_v2.py, read on 2026-11-23.
BENCH_SHA256=7dee7790119fd3ee5db8b59116d1fe4266fea639847286f7dce8daa1085907f3
# The b2 processes in order, as arm:pool:run.
B2_RUNS=(fix:128:1 fix:128:2 fix:128:3 fix:2304:1)
ARM_CAP_S=${ARM_CAP_S:-300}
# The precompiled wheel's commit, the base's first parent, the nearest main commit with a published wheel.
WHEEL_COMMIT=e2052f5c7ad64564f00dd4592e77c27785c9333f
# setup.py's WHEEL_BLOCKING_PATHS at the base: a change under these makes an older wheel's extensions unusable.
WHEEL_BLOCKING_PATHS=(csrc cmake CMakeLists.txt pyproject.toml vllm/_custom_ops.py vllm/_cpu_ops.py)
# Left for verdict.py and the checksums after the last timed step.
RESERVE_S=60
# How long timeout waits after SIGTERM before SIGKILL, for every timed step.
KILL_GRACE_S=10
# The one test process: FIX alone.
RUNS=(fix)
# cmd: the runtime session's command for one arm.
cmd() { echo python -m pytest "$TEST_FILE" -q -s --tb=short; }
START=$(date +%s)

# Settings are checked before OUT is touched, so a refused run leaves nothing behind.
[ $# = 0 ] || { echo "run.sh takes no arguments, and got: $*; settings come from the environment" >&2; exit 1; }
# A leading zero is refused, since bash arithmetic would read it as octal and change or break the budget.
[[ $BUDGET_S =~ ^[1-9][0-9]*$ ]] && [ "$BUDGET_S" -gt "$RESERVE_S" ] && [ "$BUDGET_S" -le "$BUDGET_MAX_S" ] ||
  { echo "BUDGET_S=$BUDGET_S: it must be whole seconds above $RESERVE_S and at most $BUDGET_MAX_S" >&2; exit 1; }
[[ $ARM_CAP_S =~ ^[1-9][0-9]*$ ]] && [ "$ARM_CAP_S" -ge 30 ] || { echo "ARM_CAP_S=$ARM_CAP_S: it must be whole seconds without a leading zero, at least 30" >&2; exit 1; }
[[ $B2 =~ ^[01]$ ]] || { echo "B2=$B2: it must be 1 to run b2 or 0 to skip it" >&2; exit 1; }
[[ $P6 =~ ^[01]$ ]] || { echo "P6=$P6: it must be 1 to run the test arm or 0 to skip it" >&2; exit 1; }
[ "$P6" = 1 ] || [ "$B2" = 1 ] || { echo "P6=0 and B2=0 leave nothing to run" >&2; exit 1; }
[[ $B2_CAP_S =~ ^[1-9][0-9]*$ ]] && [ "$B2_CAP_S" -ge 30 ] || { echo "B2_CAP_S=$B2_CAP_S: it must be whole seconds without a leading zero, at least 30" >&2; exit 1; }
# The test arm plans against the smaller of its own budget and the whole one.
[ "$BUDGET_S" -lt "$P6_BUDGET_S" ] && P6_BUDGET_S=$BUDGET_S
# Until the test arm is done, every step plans against its budget; b2 then plans against BUDGET_S.
STEP_BUDGET_S=$P6_BUDGET_S
PHASE=p6
# CUDA_LAUNCH_BLOCKING would serialise the launches and change the timing this run depends on, so it is refused rather than passed through.
[ -z "${CUDA_LAUNCH_BLOCKING:-}" ] || { echo "CUDA_LAUNCH_BLOCKING is set; this check runs without it" >&2; exit 1; }
for v in CASE_CAP_S PYTEST_CAP_S LLM_CAP_S UNIT_CAP_S E2E_CAP_S; do [ -z "${!v:-}" ] || { echo "$v is set; kit p6 caps each process with ARM_CAP_S" >&2; exit 1; }; done
mkdir -p "$OUT" || exit 1
# A rerun into the same OUT would leave the earlier logs for verdict.py to read, so only an empty OUT is used.
if [ -n "$(ls -A "$OUT")" ]; then echo "OUT=$OUT is not empty; each run writes a new directory" >&2; exit 1; fi
: > "$OUT/status.txt"

# Each phase's end runs two timed commands, which with their kill graces take at most 25 + 5 + 20 + 5 = 55 s, inside RESERVE_S:
# the test arm's verdict and then, after b2, b2's verdict, each followed in the end by the checksums.
# py: the python on PATH when called, which is the venv's once it is active.
py() { command -v python || command -v python3; }
p6_verdict() {
  timeout --kill-after=5 25 "$(py)" "$HERE/verdict.py" "$OUT" > "$OUT/verdict.txt" 2>&1
  VERDICT_RC=$?
  echo "verdict exit=$VERDICT_RC t=$(( $(date +%s) - START ))" >> "$OUT/status.txt"
  cat "$OUT/verdict.txt"
}
checksums() {
  ( cd "$OUT" && find . -type f ! -name SHA256SUMS | LC_ALL=C sort | timeout --kill-after=5 20 xargs -d '\n' sha256sum > SHA256SUMS )
}
finish() {
  p6_verdict
  checksums
}
VERDICT_RC=1
stop() { # the reason; the run ends here and says why
  # In b2 the caller runs in a subshell, so this ends b2 alone and leaves the test arm's STOPPED, verdict and logs as they are.
  if [ "$PHASE" = b2 ]; then
    echo "$*" | tee "$OUT/b2/STOPPED" >&2
    echo "b2 STOPPED $*" >> "$OUT/status.txt"
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
  echo "kit=p6"; echo "upstream=$UPSTREAM"
  echo "base=$BASE_SHA tree $BASE_TREE"
  echo "pr_head=base plus fix-and-tests.patch (sha256 $FIX_PATCH_SHA256) by git am, tree $PR_HEAD_TREE, the tree of $PR_HEAD"
  echo "fix=pr_head plus gathers.patch (sha256 $GATHERS_PATCH_SHA256) by git am, pinned by tree $FIX_TREE, the tree of $P6_COMMIT"
  echo "control=none: kit p5's, unchanged by gathers.patch"
  echo "test_file=$TEST_FILE blob $TEST_BLOB"
  echo "model=$MODEL"; echo "model_rev_pin=$MODEL_REV"; echo "model_bin_sha256_pin=$MODEL_BIN_SHA256"
  echo "budget_s=$BUDGET_S"; echo "arm_cap_s=$ARM_CAP_S"; echo "wheel_commit=$WHEEL_COMMIT (the base's first parent)"
  echo "order=${RUNS[*]}, each in its own process"
  echo "command=$(cmd)"
  echo "p6=$P6"; echo "p6_budget_s=$P6_BUDGET_S"; echo "b2=$B2"; echo "b2_cap_s=$B2_CAP_S"; echo "bench_sha256_pin=$BENCH_SHA256"
  echo "b2_order=${B2_RUNS[*]}, each in its own process: python bench_preempt.py --pool-blocks POOL --out ARM-POOL-RUN.json"
} > "$OUT/settings.txt"
[ "${KIT_DRY_RUN:-}" = 1 ] && { echo "dry run: settings accepted"; cat "$OUT/settings.txt"; exit 0; }

# ---------------------------------------------------------------- the patches and the base, pinned
got_fix=$(sha256sum "$FIX_PATCH" | cut -d' ' -f1)
got_gathers=$(sha256sum "$GATHERS_PATCH" | cut -d' ' -f1)
{ echo "fix_patch_sha256=$got_fix"; echo "gathers_patch_sha256=$got_gathers"; } > "$OUT/versions.txt"
[ "$got_fix" = "$FIX_PATCH_SHA256" ] || stop "fix-and-tests.patch has sha256 $got_fix, not the pinned $FIX_PATCH_SHA256"
[ "$got_gathers" = "$GATHERS_PATCH_SHA256" ] || stop "gathers.patch has sha256 $got_gathers, not the pinned $GATHERS_PATCH_SHA256"
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
HEAD1=$(git -C vllm rev-parse HEAD)
tree=$(git -C vllm rev-parse "$HEAD1^{tree}")
parent=$(git -C vllm rev-parse "$HEAD1^")
echo "pr_head commit=$HEAD1 tree=$tree parent=$parent" >> "$OUT/versions.txt"
[ "$parent" = "$BASE_SHA" ] || stop "the PR head's parent is $parent, not $BASE_SHA"
[ "$tree" = "$PR_HEAD_TREE" ] || stop "the first git am has tree $tree, not the PR head $PR_HEAD's tree $PR_HEAD_TREE"
step git-am-gathers 60 --log "$OUT/git-am-gathers.log" git -C vllm -c user.name=kit -c user.email=kit@localhost -c commit.gpgsign=false am -q "$GATHERS_PATCH" ||
  stop "gathers.patch did not apply with git am on the PR head; see git-am-gathers.log"
FIX_HEAD=$(git -C vllm rev-parse HEAD)
tree=$(git -C vllm rev-parse "$FIX_HEAD^{tree}")
parent=$(git -C vllm rev-parse "$FIX_HEAD^")
echo "fix commit=$FIX_HEAD tree=$tree parent=$parent" >> "$OUT/versions.txt"
[ "$parent" = "$HEAD1" ] || stop "the fix commit's parent is $parent, not the PR head commit $HEAD1"
[ "$tree" = "$FIX_TREE" ] || stop "the fix commit has tree $tree, not the pinned $FIX_TREE, the tree of $P6_COMMIT"
# FIX must have the hook, calling wait_for_gathers, and no wait_for_saves, which the gather-only head replaces.
n_hook=$(git -C vllm show "$FIX_HEAD:$CONNECTOR" | command grep -c '^    def handle_preemptions(')
n_gathers=$(git -C vllm show "$FIX_HEAD:$CONNECTOR" | command grep -c '^    def wait_for_gathers(')
n_saves=$(git -C vllm show "$FIX_HEAD:$CONNECTOR" | command grep -c '^    def wait_for_saves(')
n_calls=$(git -C vllm show "$FIX_HEAD:$CONNECTOR" | command grep -c 'manager.wait_for_gathers(kv_connector_metadata.preempted_req_ids)')
echo "fix_defs handle_preemptions=$n_hook wait_for_gathers=$n_gathers wait_for_saves=$n_saves hook_calls_gathers=$n_calls" >> "$OUT/versions.txt"
[ "$n_hook" = 1 ] && [ "$n_gathers" = 1 ] && [ "$n_saves" = 0 ] && [ "$n_calls" = 1 ] ||
  stop "the fix's connector has handle_preemptions $n_hook, wait_for_gathers $n_gathers, wait_for_saves $n_saves and $n_calls hook calls; want 1, 1, 0 and 1"

# arm NAME: puts the checkout on the fix commit, the only arm kit p6 has, and refuses anything else.
arm() {
  [ "$1" = fix ] || stop "kit p6 runs FIX alone, and got the arm $1"
  git -C vllm checkout -q --detach -f "$FIX_HEAD" || stop "could not check out the fix"
  [ "$(git -C vllm rev-parse HEAD)" = "$FIX_HEAD" ] || stop "the fix arm is not at $FIX_HEAD"
  [ -z "$(git -C vllm status --porcelain --untracked-files=no)" ] || stop "the fix arm has tracked changes"
  local blob
  blob=$(git -C vllm hash-object "$TEST_FILE")
  echo "fix test_blob=$blob" >> "$OUT/versions.txt"
  [ "$blob" = "$TEST_BLOB" ] || stop "the fix arm's test file is blob $blob, not the pinned $TEST_BLOB"
}

# ---------------------------------------------------------------- install, with precompiled kernels, at the fix
arm fix
# KIT_OFFLINE_TEST=1 skips the install for hack/vllm-hf3fs-preemption-p6-kit-test.sh, which puts fake python, hf and nvidia-smi on PATH; settings.txt says so.
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

# ---------------------------------------------------------------- the test process
read -r -a words <<< "$(cmd)"
if [ "$P6" = 1 ]; then
  for a in "${RUNS[@]}"; do
    arm "$a"
    step "test-$a" "$ARM_CAP_S" --log "$OUT/e2e-$a.log" env -C vllm "${words[@]}"
  done
  # The test arm is decided here, before b2, which cannot change or delay its verdict.
  p6_verdict
else
  echo "test arm skipped (P6=0)" >> "$OUT/status.txt"
fi

# ---------------------------------------------------------------- b2, the performance run, apart from the verdict above
# b2_json_has_fix FILE: the run's has_fix as Python prints it, or nothing when the JSON is missing or unreadable.
b2_json_has_fix() { "$(py)" -c 'import json, sys; print(json.load(open(sys.argv[1]))["has_fix"])' "$1" 2>> "$OUT/b2/preflight.log"; }
b2() {
  local r a pool i want got tmp free_gb
  mkdir -p "$OUT/b2" || return 0
  got=$(sha256sum "$BENCH" | cut -d' ' -f1)
  echo "bench_sha256=$got" > "$OUT/b2/versions.txt"
  [ "$got" = "$BENCH_SHA256" ] || { ( stop "bench_preempt_v2.py has sha256 $got, not the pinned $BENCH_SHA256" ); return 0; }
  # b2 deletes only the directory it made, so a b2-tmp that is already there is refused rather than written into or deleted.
  [ ! -e "$PWD/b2-tmp" ] || { ( stop "$PWD/b2-tmp already exists, and b2 neither writes into nor deletes what it did not make" ); return 0; }
  mkdir "$PWD/b2-tmp" || { ( stop "could not make $PWD/b2-tmp" ); return 0; }
  B2_TMP_MADE=1
  for r in "${B2_RUNS[@]}"; do
    a=${r%%:*} pool=${r#*:} i=${pool#*:} pool=${pool%%:*}
    # Each checkout and each process runs in a subshell, so a stop inside them ends b2 and nothing else.
    ( arm "$a" ) || return 0
    # The bench keeps its 8 GiB sparse storage file, so each run writes it under its own TMPDIR, deleted after the run.
    tmp="$PWD/b2-tmp/$a-$pool-$i"
    mkdir -p "$tmp" || { ( stop "could not make $tmp" ); return 0; }
    free_gb=$(df -BG --output=avail "$tmp" | tail -n 1 | tr -dc 0-9)
    echo "b2-$a-$pool-$i free_gb=$free_gb" >> "$OUT/b2/disk.txt"
    [ "${free_gb:-0}" -ge "$B2_MIN_FREE_GB" ] || { ( stop "only ${free_gb:-?} GB free before b2-$a-$pool-$i, under $B2_MIN_FREE_GB" ); return 0; }
    ( step "b2-$a-$pool-$i" "$B2_CAP_S" --log "$OUT/b2/$a-$pool-$i.log" env -C vllm PYTHONPATH="$PWD/vllm" TMPDIR="$tmp" \
        python "$BENCH" --pool-blocks "$pool" --out "$OUT/b2/$a-$pool-$i.json" )
    rm -rf "$tmp"
    [ -e "$OUT/b2/STOPPED" ] && return 0
    # The preflight: every b2 run is on FIX and must report has_fix true, or the tree is not the one b2 means to time.
    want=True
    got=$(b2_json_has_fix "$OUT/b2/$a-$pool-$i.json")
    if [ -n "$got" ] && [ "$got" != "$want" ]; then
      echo "b2-$a-$pool-$i reported has_fix=$got, where the $a tree must report $want" > "$OUT/b2/NOT_RUN"
      echo "b2 NOT_RUN $(cat "$OUT/b2/NOT_RUN")" >> "$OUT/status.txt"
      return 0
    fi
  done
}
if [ "$B2" = 1 ]; then
  PHASE=b2
  STEP_BUDGET_S=$BUDGET_S
  B2_TMP_MADE=0
  b2
  [ "$B2_TMP_MADE" = 1 ] && rm -rf "$PWD/b2-tmp"
  timeout --kill-after=5 25 "$(py)" "$HERE/b2_verdict.py" "$OUT" > "$OUT/b2/b2-verdict.txt" 2>&1
  B2_RC=$?
  echo "b2-verdict exit=$B2_RC t=$(( $(date +%s) - START ))" >> "$OUT/status.txt"
  cat "$OUT/b2/b2-verdict.txt"
else
  echo "b2 skipped (B2=0)" >> "$OUT/status.txt"
fi
[ "${KIT_OFFLINE_TEST:-}" = 1 ] && git -C "$OFFLINE_VLLM_SRC" worktree remove --force "$PWD/vllm"
checksums
# With the test arm run, b2 never sets the exit status: it is its verdict.
# A b2-only session, P6=0, exits with b2's status: 0 VALID, 3 INCOMPLETE, 4 NOT RUN, 6 INVALID.
if [ "$P6" = 1 ]; then exit "$VERDICT_RC"; else exit "${B2_RC:-3}"; fi
