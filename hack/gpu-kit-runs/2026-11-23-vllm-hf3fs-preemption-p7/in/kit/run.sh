#!/bin/bash
# One-GPU check of the vLLM HF3FS preemption fix, kit p7: the PR head that fences partial gathers, and a mutation check of its new test.
# Reviewer bzsuni found that a save failing after some per-block gathers were launched left gather.cuda_event None,
# so wait_for_gathers returned before those gathers were done.
# vllm-project/vllm#69271's head 7528cc07 (lkhun9311/vllm fix/hf3fs-preemption-save), on 23884c5eb2, which kit p6 confirmed, fixes it:
# the save worker's finally records an event on _save_stream when cuda_event is None, before setting enqueued,
# and the except path synchronizes _save_stream before free_buffer; the test file gains test_failed_gather_still_fences_its_reads.
# FIX is the base with kit p5's fix-and-tests.patch, kit p6's gathers.patch and fence.patch, each by git am,
# pinned by the tree after each step: the PR's first head 4ec2f316, 23884c5eb2, and 7528cc07, whose tree the offline test checks against the fetched head.
# CONTROL is 23884c5eb2's code with only 7528cc07's test file, so the new test must fail on it: it is the check that the test catches the bug.
# hack/gpu-kit-session.sh runs this unmodified on one A10G, g5.xlarge or g5.2xlarge, with OUT set.
#
# THE ARMS, CONTROL first and FIX second, each in its own process, with the runtime session's command:
#   python -m pytest tests/v1/kv_connector/unit/test_hf3fs_preemption.py -q -s --tb=short --durations=0
# The file holds two GPU tests, test_preempted_request_saves_its_own_kv and test_failed_gather_still_fences_its_reads.
# verdict.py says CONFIRMED when FIX passes both, the first with every held-save page error 0.0, every precondition met and its hold timed out,
# and CONTROL passes the first and fails exactly the new one; anything else is classified as kits p5 and p6 do.
# It prints each arm's pytest summary line verbatim, CONTROL's failing E lines verbatim, the held and page-error lines and each test's durations.
# There is no bench arm in this kit.
#
# THE ENVIRONMENT, as in kits p5 and p6: base 0e3c8dbdae and its first parent e2052f5c7a's precompiled wheel, checked the same way,
# the base's CUDA test lock pins, and facebook/opt-125m at revision 27dcfa74d3 with its weights' sha256 pinned, after which the hub is offline.
# One install serves both arms, since the fix and the test change only Python files.
#
# THE BUDGET.
# The session gives bring-up 300 s and the evidence upload 60 s, and confirms termination 360 s after the upload's deadline.
# So with BUDGET_S seconds here the bill runs to 300 + BUDGET_S + 60 + 360 s, which is 1,620 s at the default 900 s:
# $0.3457 on g5.xlarge at $0.7683/h all in, and $0.3907 on g5.2xlarge at $0.8683/h. This script refuses BUDGET_S above 900.
# Measured in kits p4 to b1: setup took 62 to 125 s, the first test process about 190 s while it warmed the caches, a later one about 70 s.
# Expected here, not measured: setup 62 s, CONTROL about 220 s with its second test, FIX about 100 s, so run.sh about 400 s
# and the session about 800 s, $0.17 on g5.xlarge and $0.19 on g5.2xlarge. Each test process is capped at ARM_CAP_S, 360 s by default.
# Every command that can wait runs under a timeout for what is left of the budget less a reserve, so run.sh ends inside BUDGET_S.
# The session lets a stalled upload run to 3,660 s after launch and stops the instance at 3,720 s, so the true worst case stays the session's:
# $0.8579 on g5.xlarge and $0.9696 on g5.2xlarge.
#
# Settings (KIT_ENV through the session): BUDGET_S (default and maximum 900) and ARM_CAP_S (each test process's cap, default 360).
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${OUT:-$HERE/results}
UPSTREAM=https://github.com/vllm-project/vllm.git
BASE_SHA=0e3c8dbdae9d55149b0fba4e6c1014b4b08c9c73
BASE_TREE=e6819e279d40268d45eee2bfa134d5d04b05e53f
FIX_PATCH="$HERE/fix-and-tests.patch"
GATHERS_PATCH="$HERE/gathers.patch"
FENCE_PATCH="$HERE/fence.patch"
# The sha256 of kit p5's fix-and-tests.patch, which git am makes the PR head 4ec2f316 from on 0e3c8dbdae.
FIX_PATCH_SHA256=8da42418ce7bcd85a85c19067a8c4da2dece1dbb485b765e0471759abed30eb6
# The sha256 of storage's open-source/contributions/vllm/hf3fs-preemption-save/p6/0001-Bugfix-KV-Connector-Wait-only-for-HF3FS-gathers-of-p.patch,
# read on 2026-11-23, the runtime session's commit 23884c5eb2 on the PR head.
GATHERS_PATCH_SHA256=ae802dc58d3eda026d09b1f5ec201f74dde9bd4e871dcd8c918554dd1029b1cd
# The sha256 of storage's open-source/contributions/vllm/hf3fs-preemption-save/p7/0001-Bugfix-KV-Connector-Fence-partial-HF3FS-gathers-befo.patch,
# read on 2026-11-23, the PR head 7528cc07 on 23884c5eb2.
FENCE_PATCH_SHA256=62aee4be428e28801471d6d2e92a02ae2004dc4b426a23bb5ebf533d2966af5f
# The PR head and its tree, which the first git am must give.
PR_HEAD=4ec2f316fb847673a5edb3ce337a0abae9263899
PR_HEAD_TREE=441714150d9afe8fd27523f66f288568e8a8c1e8
# Kit p6's head and its tree, which the second git am must give: CONTROL's code.
P6_COMMIT=23884c5eb20699e463f177d06d0ecde297fb3e46
P6_TREE=e7475ec46141b6764a1cf9874bcd7efa1e7003db
# The PR head and its tree, which the third git am must give: this is FIX.
P7_HEAD=7528cc07f44ca7f864118fad29e08ea36abf19ef
FIX_TREE=49fd5c2fdd30efa118592a9d243ba9adf884e639
# CONTROL: P6_TREE with only P7_HEAD's test file.
CONTROL_TREE=f0db55b74fe67706789aac52722e8a3390fecf52
TEST_FILE=tests/v1/kv_connector/unit/test_hf3fs_preemption.py
# P7_HEAD's test file's blob, the same in both arms.
TEST_BLOB=912b5f88eaaeba37b2b4b16f2091b6c99fd2aeb4
CONNECTOR=vllm/distributed/kv_transfer/kv_connector/v1/hf3fs/hf3fs_connector.py
MODEL=facebook/opt-125m
MODEL_REV=27dcfa74d334bc871f3234de431e71c6eeba5dd6
# The hub's LFS sha256 for pytorch_model.bin at MODEL_REV.
MODEL_BIN_SHA256=2d74da6615135c58cf3cf9ad4cb11e7c613ff9e55fe658a47ab83b6c8d1174a9
# The files vLLM reads for this model; the repository's TensorFlow and Flax weights are left out.
MODEL_FILES=(config.json generation_config.json merges.txt vocab.json special_tokens_map.json tokenizer_config.json pytorch_model.bin)
BUDGET_S=${BUDGET_S:-900}
BUDGET_MAX_S=900
ARM_CAP_S=${ARM_CAP_S:-360}
# The precompiled wheel's commit, the base's first parent, the nearest main commit with a published wheel.
WHEEL_COMMIT=e2052f5c7ad64564f00dd4592e77c27785c9333f
# setup.py's WHEEL_BLOCKING_PATHS at the base: a change under these makes an older wheel's extensions unusable.
WHEEL_BLOCKING_PATHS=(csrc cmake CMakeLists.txt pyproject.toml vllm/_custom_ops.py vllm/_cpu_ops.py)
# Left for verdict.py and the checksums after the last timed step.
RESERVE_S=60
# How long timeout waits after SIGTERM before SIGKILL, for every timed step.
KILL_GRACE_S=10
# The two test processes in order.
RUNS=(control fix)
# cmd: the runtime session's command for one arm.
cmd() { echo python -m pytest "$TEST_FILE" -q -s --tb=short --durations=0; }
START=$(date +%s)

# Settings are checked before OUT is touched, so a refused run leaves nothing behind.
[ $# = 0 ] || { echo "run.sh takes no arguments, and got: $*; settings come from the environment" >&2; exit 1; }
# A leading zero is refused, since bash arithmetic would read it as octal and change or break the budget.
[[ $BUDGET_S =~ ^[1-9][0-9]*$ ]] && [ "$BUDGET_S" -gt "$RESERVE_S" ] && [ "$BUDGET_S" -le "$BUDGET_MAX_S" ] ||
  { echo "BUDGET_S=$BUDGET_S: it must be whole seconds above $RESERVE_S and at most $BUDGET_MAX_S" >&2; exit 1; }
[[ $ARM_CAP_S =~ ^[1-9][0-9]*$ ]] && [ "$ARM_CAP_S" -ge 30 ] || { echo "ARM_CAP_S=$ARM_CAP_S: it must be whole seconds without a leading zero, at least 30" >&2; exit 1; }
STEP_BUDGET_S=$BUDGET_S
# CUDA_LAUNCH_BLOCKING would serialise the launches and change the timing this run depends on, so it is refused rather than passed through.
[ -z "${CUDA_LAUNCH_BLOCKING:-}" ] || { echo "CUDA_LAUNCH_BLOCKING is set; this check runs without it" >&2; exit 1; }
for v in CASE_CAP_S PYTEST_CAP_S LLM_CAP_S UNIT_CAP_S E2E_CAP_S; do [ -z "${!v:-}" ] || { echo "$v is set; kit p7 caps each process with ARM_CAP_S" >&2; exit 1; }; done
mkdir -p "$OUT" || exit 1
# A rerun into the same OUT would leave the earlier logs for verdict.py to read, so only an empty OUT is used.
if [ -n "$(ls -A "$OUT")" ]; then echo "OUT=$OUT is not empty; each run writes a new directory" >&2; exit 1; fi
: > "$OUT/status.txt"

# Each phase's end runs two timed commands, which with their kill graces take at most 25 + 5 + 20 + 5 = 55 s, inside RESERVE_S:
# the verdict and the checksums.
# py: the python on PATH when called, which is the venv's once it is active.
py() { command -v python || command -v python3; }
verdict_now() {
  timeout --kill-after=5 25 "$(py)" "$HERE/verdict.py" "$OUT" > "$OUT/verdict.txt" 2>&1
  VERDICT_RC=$?
  echo "verdict exit=$VERDICT_RC t=$(( $(date +%s) - START ))" >> "$OUT/status.txt"
  cat "$OUT/verdict.txt"
}
checksums() {
  ( cd "$OUT" && find . -type f ! -name SHA256SUMS | LC_ALL=C sort | timeout --kill-after=5 20 xargs -d '\n' sha256sum > SHA256SUMS )
}
finish() {
  verdict_now
  checksums
}
VERDICT_RC=1
stop() { # the reason; the run ends here and says why
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
  echo "kit=p7"; echo "upstream=$UPSTREAM"
  echo "base=$BASE_SHA tree $BASE_TREE"
  echo "pr_head=base plus fix-and-tests.patch (sha256 $FIX_PATCH_SHA256) by git am, tree $PR_HEAD_TREE, the tree of $PR_HEAD"
  echo "p6=pr_head plus gathers.patch (sha256 $GATHERS_PATCH_SHA256) by git am, tree $P6_TREE, the tree of $P6_COMMIT"
  echo "fix=p6 plus fence.patch (sha256 $FENCE_PATCH_SHA256) by git am, pinned by tree $FIX_TREE, the tree of $P7_HEAD"
  echo "control=p6's code with only $P7_HEAD's test file, pinned by tree $CONTROL_TREE"
  echo "test_file=$TEST_FILE blob $TEST_BLOB"
  echo "model=$MODEL"; echo "model_rev_pin=$MODEL_REV"; echo "model_bin_sha256_pin=$MODEL_BIN_SHA256"
  echo "budget_s=$BUDGET_S"; echo "arm_cap_s=$ARM_CAP_S"; echo "wheel_commit=$WHEEL_COMMIT (the base's first parent)"
  echo "order=${RUNS[*]}, each in its own process"
  echo "command=$(cmd)"
} > "$OUT/settings.txt"
[ "${KIT_DRY_RUN:-}" = 1 ] && { echo "dry run: settings accepted"; cat "$OUT/settings.txt"; exit 0; }

# ---------------------------------------------------------------- the patches and the base, pinned
got_fix=$(sha256sum "$FIX_PATCH" | cut -d' ' -f1)
got_gathers=$(sha256sum "$GATHERS_PATCH" | cut -d' ' -f1)
got_fence=$(sha256sum "$FENCE_PATCH" | cut -d' ' -f1)
{ echo "fix_patch_sha256=$got_fix"; echo "gathers_patch_sha256=$got_gathers"; echo "fence_patch_sha256=$got_fence"; } > "$OUT/versions.txt"
[ "$got_fix" = "$FIX_PATCH_SHA256" ] || stop "fix-and-tests.patch has sha256 $got_fix, not the pinned $FIX_PATCH_SHA256"
[ "$got_gathers" = "$GATHERS_PATCH_SHA256" ] || stop "gathers.patch has sha256 $got_gathers, not the pinned $GATHERS_PATCH_SHA256"
[ "$got_fence" = "$FENCE_PATCH_SHA256" ] || stop "fence.patch has sha256 $got_fence, not the pinned $FENCE_PATCH_SHA256"
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
P6_HEAD=$(git -C vllm rev-parse HEAD)
tree=$(git -C vllm rev-parse "$P6_HEAD^{tree}")
parent=$(git -C vllm rev-parse "$P6_HEAD^")
echo "p6 commit=$P6_HEAD tree=$tree parent=$parent" >> "$OUT/versions.txt"
[ "$parent" = "$HEAD1" ] || stop "the p6 commit's parent is $parent, not the PR's first head commit $HEAD1"
[ "$tree" = "$P6_TREE" ] || stop "the second git am has tree $tree, not the tree of $P6_COMMIT, $P6_TREE"
step git-am-fence 60 --log "$OUT/git-am-fence.log" git -C vllm -c user.name=kit -c user.email=kit@localhost -c commit.gpgsign=false am -q "$FENCE_PATCH" ||
  stop "fence.patch did not apply with git am on $P6_COMMIT's tree; see git-am-fence.log"
FIX_HEAD=$(git -C vllm rev-parse HEAD)
tree=$(git -C vllm rev-parse "$FIX_HEAD^{tree}")
parent=$(git -C vllm rev-parse "$FIX_HEAD^")
echo "fix commit=$FIX_HEAD tree=$tree parent=$parent" >> "$OUT/versions.txt"
[ "$parent" = "$P6_HEAD" ] || stop "the fix commit's parent is $parent, not the p6 commit $P6_HEAD"
[ "$tree" = "$FIX_TREE" ] || stop "the fix commit has tree $tree, not the pinned $FIX_TREE, the tree of $P7_HEAD"
# The fence is in FIX's connector and not in CONTROL's: its fail-closed error is the marker.
n_fix=$(git -C vllm show "$FIX_HEAD:$CONNECTOR" | command grep -c 'could not fence')
n_control=$(git -C vllm show "$P6_HEAD:$CONNECTOR" | command grep -c 'could not fence')
n_gathers=$(git -C vllm show "$P6_HEAD:$CONNECTOR" | command grep -c '^    def wait_for_gathers(')
echo "fence_marker control=$n_control fix=$n_fix control_wait_for_gathers=$n_gathers" >> "$OUT/versions.txt"
[ "$n_control" = 0 ] && [ "$n_fix" -ge 1 ] && [ "$n_gathers" = 1 ] ||
  stop "the fence marker is in the control $n_control times and the fix $n_fix, and the control has wait_for_gathers $n_gathers times; want 0, at least 1, and 1"

# arm NAME: puts the checkout on CONTROL (the p6 commit with the fix's test file) or the fix commit, and refuses anything else.
arm() {
  if [ "$1" = control ]; then
    git -C vllm checkout -q --detach -f "$P6_HEAD" || stop "could not check out the p6 commit for the control"
    # Only the test file comes from the fix, so the control runs the new test against the code without the fence.
    git -C vllm checkout -q "$FIX_HEAD" -- "$TEST_FILE" || stop "could not take the fix's test file into the control"
    [ "$(git -C vllm rev-parse HEAD)" = "$P6_HEAD" ] || stop "the control is not at $P6_HEAD"
    # The control's tree is what the checkout holds, written through a throwaway index; add -u takes in any tracked change.
    local idx="$PWD/.control-index" t
    rm -f "$idx"
    t=$(GIT_INDEX_FILE="$idx" git -C vllm read-tree "$P6_HEAD" && GIT_INDEX_FILE="$idx" git -C vllm add -u && GIT_INDEX_FILE="$idx" git -C vllm write-tree)
    rm -f "$idx"
    echo "control tree=$t" >> "$OUT/versions.txt"
    [ "$t" = "$CONTROL_TREE" ] || stop "the control has tree $t, not the pinned $CONTROL_TREE"
    [ "$(git -C vllm status --porcelain --untracked-files=no)" = " M $TEST_FILE" ] || [ "$(git -C vllm status --porcelain --untracked-files=no)" = "M  $TEST_FILE" ] ||
      stop "the control changes more than the test file"
  elif [ "$1" = fix ]; then
    git -C vllm checkout -q --detach -f "$FIX_HEAD" || stop "could not check out the fix"
    [ "$(git -C vllm rev-parse HEAD)" = "$FIX_HEAD" ] || stop "the fix arm is not at $FIX_HEAD"
    [ -z "$(git -C vllm status --porcelain --untracked-files=no)" ] || stop "the fix arm has tracked changes"
  else
    stop "kit p7 has the arms control and fix, and got $1"
  fi
  local blob
  blob=$(git -C vllm hash-object "$TEST_FILE")
  echo "$1 test_blob=$blob" >> "$OUT/versions.txt"
  [ "$blob" = "$TEST_BLOB" ] || stop "the $1 arm's test file is blob $blob, not the pinned $TEST_BLOB"
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

# ---------------------------------------------------------------- the two test processes
read -r -a words <<< "$(cmd)"
for a in "${RUNS[@]}"; do
  arm "$a"
  step "test-$a" "$ARM_CAP_S" --log "$OUT/e2e-$a.log" env -C vllm "${words[@]}"
done
[ "${KIT_OFFLINE_TEST:-}" = 1 ] && git -C "$OFFLINE_VLLM_SRC" worktree remove --force "$PWD/vllm"
finish
exit "$VERDICT_RC"
