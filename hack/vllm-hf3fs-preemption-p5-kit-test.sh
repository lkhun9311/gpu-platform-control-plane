#!/usr/bin/env bash
#
# Offline checks for the vLLM HF3FS preemption kit p5 in docs/oss/vllm-hf3fs-preemption/kit-p5, run before any GPU is bought.
# Kit p5 runs the upstream PR vllm-project/vllm#69271 at its head 4ec2f316 on a new base, main at 0e3c8dbdae.
# This is kit p4's test with p5's pins, plus:
#   the fix commit git am makes has the PR head's tree, checked against the head fetched from lkhun9311/vllm into VLLM_SRC;
#   the fix hunks are byte for byte kit p4's, and both patches carry the PR head's test file;
#   the wheel commit is the new base's first parent, with no change under setup.py's blocking paths;
#   kits p1 to p4 are left as committed;
#   vLLM's startup check and the reset check pass on the new base's code;
#   the verdict expects one GPU test and no CPU tests, prints each arm's pytest summary verbatim, and still judges "held-save page errors";
#   the performance run b1 after the test arms, on a fake bench, runs in its order, reports apart from the verdict,
#   stops on a wrong has_fix, calls a pool-128 run without preemption INVALID, and leaves the verdict alone when it fails or runs out of time.
# No GPU, no network and no AWS: python (with pytest) is the fake in hack/vllm-hf3fs-preemption-fake,
# hf and nvidia-smi are the fakes in hack/vllm-69058-fake, and aws is a fake that records its calls.
# The vLLM checkout is real, a detached worktree of a local vLLM repository (VLLM_SRC) at the base, with tests-only.patch applied by a real git apply
# and fix-and-tests.patch by a real git am.
# Each verdict rule and each run.sh guard is also run against a mutant that breaks it, and the mutant must be caught.
# The runner checks need the kit committed, since the session ships a commit; they clone this tree's HEAD.
#
#   VLLM_SRC=/path/to/vllm [CPU_VLLM_PY=/path/to/cpu-venv/bin/python] bash hack/vllm-hf3fs-preemption-p5-kit-test.sh
set -uo pipefail
unset INSTANCE_TYPE KIT_ENV SESSION_CONFIRM AWS_PROFILE
# The checks assert the kit's and the fakes' defaults, so a caller's settings must not reach them.
unset P5 B1 B1_CAP_S FAKE_B1 FAKE_B1_LOG BUDGET_S ARM_CAP_S CASE_CAP_S E2E_CAP_S UNIT_CAP_S PYTEST_CAP_S LLM_CAP_S KIT_DRY_RUN KIT_OFFLINE_TEST OFFLINE_VLLM_SRC OFFLINE_MODEL_BIN_SHA256 \
  FAKE_MODE FAKE_CUDA FAKE_HF FAKE_HF_DIR FAKE_NVSMI FAKE_ORDER_LOG FAKE_EXPECT_OFFLINE HF_HUB_OFFLINE TRANSFORMERS_OFFLINE VLLM_ENABLE_V1_MULTIPROCESSING CUDA_LAUNCH_BLOCKING
# Python must not leave bytecode beside a mutant, where a same-size edit restored within a second could reuse it.
export PYTHONDONTWRITEBYTECODE=1
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KIT="$ROOT/docs/oss/vllm-hf3fs-preemption/kit-p5"
KITREL=docs/oss/vllm-hf3fs-preemption/kit-p5
KIT1REL=docs/oss/vllm-hf3fs-preemption/kit-p1
KIT2REL=docs/oss/vllm-hf3fs-preemption/kit-p2
KIT3REL=docs/oss/vllm-hf3fs-preemption/kit-p3
KIT4REL=docs/oss/vllm-hf3fs-preemption/kit-p4
STARTUP="$ROOT/hack/vllm-hf3fs-preemption-startup-check.py"
# A CPU vLLM environment: torch, transformers and vLLM's Python dependencies, with the checkout's vLLM put first on PYTHONPATH.
CPU_VLLM_PY="${CPU_VLLM_PY:-$HOME/workspace/oss/vllm/.venv-cpu/bin/python}"
FAKES="$ROOT/hack/vllm-hf3fs-preemption-fake"
TOOLFAKES="$ROOT/hack/vllm-69058-fake"
CHECK="$ROOT/hack/vllm-hf3fs-preemption-p5-kit-check.py"
SRC="${VLLM_SRC:-$HOME/workspace/oss/vllm}"
BASE=0e3c8dbdae9d55149b0fba4e6c1014b4b08c9c73
BASE_TREE=e6819e279d40268d45eee2bfa134d5d04b05e53f
FIX_TREE=441714150d9afe8fd27523f66f288568e8a8c1e8
CONTROL_TREE=66cc798220693c7256072a87e1a8ab19952f37c5
TEST_BLOB=9b1c0115b5ece0918d7a6b250c5f37b9fdf2b37f
WHEEL=e2052f5c7ad64564f00dd4592e77c27785c9333f
# The upstream PR's head on lkhun9311/vllm fix/hf3fs-preemption-save, and its tree.
PR_HEAD=4ec2f316fb847673a5edb3ce337a0abae9263899
PR_HEAD_TREE=441714150d9afe8fd27523f66f288568e8a8c1e8
TF=tests/v1/kv_connector/unit/test_hf3fs_preemption.py
TESTS_SHA256=bcbb9fec95bed88a2f7d8f399e18f7a72fb3e618e6a9e27db575662f77b31b0c
BENCH_SHA256=09fc49a76aa382da96313c5c51087897a0ba9b43ea3ac6b676f723abb44748c2
# The first bench, which b1 must no longer run.
BENCH1_SHA256=575d32cc8e33e1db827c8f37b35d47c3f167b0f1fe46b6807ce78b5346613f9a
BENCH_SRC="$HOME/workspace/storage/open-source/contributions/vllm/hf3fs-preemption-save/bench/bench_preempt.py"
B1_ORDER_WANT="control-128 fix-128 control-128 fix-128 control-128 fix-128 control-2304 fix-2304"
FIX_SHA256=8da42418ce7bcd85a85c19067a8c4da2dece1dbb485b765e0471759abed30eb6
# Kit p4's pins, which p5 must not carry.
P4_TESTS_SHA256=c21daf3b2e477c75860bec4bc5534742b6a496c7e9a08d875901cddaa0aed575
P4_FIX_SHA256=101a1347da431fc9150c7e209537891ab03bc3100fec2681202d24570cfddb7e
P4_FIX_TREE=bb4629e9852055ab410d831a1da1ff8fd9a700eb
P4_CONTROL_TREE=f59e0dbfde720ce280e32a0fa4547676225528a1
P4_TEST_BLOB=773483a28e691362d6565c1c5b6b5cbfd55bac1a
# The runtime session's copies, outside storage, which is frozen.
PATCH_SRC="$HOME/.cache/oss-runtime/patches/hf3fs-preemption-p5"
ORDER_WANT="control fix"
# The fake hf writes "fake pytorch_model.bin" plus a newline as the weights, and this is its sha256.
FAKE_BIN_SHA256=702621c64b6d1269dfb348b9109f388ab469b74f394201717a1b1cd9cd1a5d8b
# Scratch space lives on disk, since /tmp is RAM-backed on the development machine.
SCRATCH="${SCRATCH:-$HOME/.cache/vllm-hf3fs-preemption}"
mkdir -p "$SCRATCH" || exit 1
# An empty WORK would turn every "$WORK/..." below, the cleanup's removals included, into a path at the root.
WORK=$(mktemp -d -p "$SCRATCH") && [ -n "$WORK" ] && [ -d "$WORK" ] || { echo "could not make a scratch directory under $SCRATCH" >&2; exit 1; }
# Everything this test and its tools write goes under WORK, which the cleanup removes, so nothing is left in /tmp.
export TMPDIR="$WORK/tmp"
mkdir -p "$TMPDIR" || exit 1
cleanup() {
  # Worktrees added to the local vLLM repository are removed even when a run stopped before its own cleanup.
  for w in "$WORK"/e2e-*/cwd/vllm "$WORK/apply"; do
    [ -e "$w" ] && git -C "$SRC" worktree remove --force "$w" >>"$WORK/cleanup.log" 2>&1
  done
  git -C "$SRC" worktree prune >>"$WORK/cleanup.log" 2>&1
  [ -n "${KEEP_WORK:-}" ] || rm -rf "$WORK"
}
trap cleanup EXIT
failures=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1" >&2; failures=$((failures + 1)); fi; }
mcheck() { if [ -n "$m" ]; then check "$@"; else echo "FAIL $1 (the mutant was not made)" >&2; failures=$((failures + 1)); fi; }

# mutant NAME FILE SED: a copy of the kit with SED applied to FILE, and its directory; a SED that changes nothing is an error.
mutant() {
  local d
  d="$WORK/m-$(printf '%s' "$1" | tr -c 'A-Za-z0-9' '-')"
  # A copy or edit that failed would leave no mutant, and a check that cannot load it would read as caught.
  cp -r "$KIT" "$d" || return 1
  sed -i "$3" "$d/$2" || return 1
  cmp -s "$KIT/$2" "$d/$2" && { echo "the mutant $1 changed nothing" >&2; return 1; }
  echo "$d"
}

# ---------------------------------------------------------------- parse and compile
check "run.sh, this test and the fake python parse" "bash -n '$KIT/run.sh' && bash -n '$0' && bash -n '$FAKES/python'"
check "the kit's Python, the fake pytest and the checker compile" \
  "python3 -I -X pycache_prefix='$WORK/pyc' -m py_compile '$KIT/verdict.py' '$KIT/b1_verdict.py' '$KIT/bench_preempt.py' '$KIT/envprobe.py' '$FAKES/pytest_p1.py' '$FAKES/bench_b1.py' '$CHECK'"
if command -v shellcheck >/dev/null; then
  check "shellcheck finds no error in run.sh" "shellcheck -S error '$KIT/run.sh'"
else
  echo "skip shellcheck is not installed here"
fi

# ---------------------------------------------------------------- the pins
check "the kit holds both patches with the pinned sha256s, which start bcbb9fec95bed88a and 8da42418ce7bcd85" \
  "[ \"\$(ls '$KIT' | paste -sd' ')\" = 'b1_verdict.py bench_preempt.py envprobe.py fix-and-tests.patch run.sh tests-only.patch verdict.py' ] \
   && [ \"\$(sha256sum '$KIT/tests-only.patch' | cut -d' ' -f1)\" = $TESTS_SHA256 ] && [ \${TESTS_SHA256:0:16} = bcbb9fec95bed88a ] \
   && [ \"\$(sha256sum '$KIT/fix-and-tests.patch' | cut -d' ' -f1)\" = $FIX_SHA256 ] && [ \${FIX_SHA256:0:16} = 8da42418ce7bcd85 ]"
check "the kit's bench_preempt.py has the pinned sha256, which run.sh pins too" \
  "[ \"\$(sha256sum '$KIT/bench_preempt.py' | cut -d' ' -f1)\" = $BENCH_SHA256 ] && command grep -qx 'BENCH_SHA256=$BENCH_SHA256' '$KIT/run.sh'"
if [ -f "$BENCH_SRC" ]; then
  check "the kit's bench_preempt.py is byte for byte storage's $BENCH_SRC" "cmp -s '$KIT/bench_preempt.py' '$BENCH_SRC'"
else
  echo "skip $BENCH_SRC is gone; the sha256 pin stands"
fi
check "run.sh pins both patches, the base by commit and tree, the fix's and the control's trees, the test blob and the wheel commit" \
  "command grep -qx 'TESTS_PATCH_SHA256=$TESTS_SHA256' '$KIT/run.sh' && command grep -qx 'FIX_PATCH_SHA256=$FIX_SHA256' '$KIT/run.sh' \
   && command grep -qx 'BASE_SHA=$BASE' '$KIT/run.sh' && command grep -qx 'BASE_TREE=$BASE_TREE' '$KIT/run.sh' \
   && command grep -qx 'FIX_TREE=$FIX_TREE' '$KIT/run.sh' && command grep -qx 'CONTROL_TREE=$CONTROL_TREE' '$KIT/run.sh' \
   && command grep -qx 'TEST_BLOB=$TEST_BLOB' '$KIT/run.sh' && command grep -qx 'WHEEL_COMMIT=$WHEEL' '$KIT/run.sh' \
   && command grep -qx 'PR_HEAD=$PR_HEAD' '$KIT/run.sh' && command grep -qx 'PR_HEAD_TREE=$PR_HEAD_TREE' '$KIT/run.sh' && [ $FIX_TREE = $PR_HEAD_TREE ]"
for p in tests-only.patch fix-and-tests.patch; do
  if [ -f "$PATCH_SRC/$p" ]; then
    check "the kit's $p is byte for byte the runtime session's $PATCH_SRC/$p" "cmp -s '$KIT/$p' '$PATCH_SRC/$p'"
  else
    echo "skip $PATCH_SRC/$p is gone; the sha256 pin stands"
  fi
done
# The fix itself must be p4's, byte for byte: everything from the first non-test file's diff on.
fixpart() { sed -n '/^diff --git a\/vllm\//,$p' "$1"; }
check "fix-and-tests.patch's fix hunks, from its first vllm/ file on, are byte for byte kit p4's" \
  "[ -n \"\$(fixpart '$KIT/fix-and-tests.patch')\" ] && cmp -s <(fixpart '$ROOT/$KIT4REL/fix-and-tests.patch') <(fixpart '$KIT/fix-and-tests.patch')"
check "kits p1 to p4 are left as committed" "git -C '$ROOT' diff --quiet HEAD -- '$KIT1REL' '$KIT2REL' '$KIT3REL' '$KIT4REL' && [ -z \"\$(git -C '$ROOT' status --porcelain --untracked-files=all --ignored -- '$KIT1REL' '$KIT2REL' '$KIT3REL' '$KIT4REL')\" ]"
# The PR head, fetched from lkhun9311/vllm into the local repository: its parent is the base, and the fix applied by git am is it, tree for tree.
if git -C "$SRC" cat-file -e "$PR_HEAD^{commit}" 2>"$WORK/pr.err"; then
  check "the PR head $PR_HEAD has the base as its parent and the pinned tree $PR_HEAD_TREE" \
    "[ \"\$(git -C '$SRC' rev-parse $PR_HEAD^)\" = $BASE ] && [ \"\$(git -C '$SRC' rev-parse $PR_HEAD^{tree})\" = $PR_HEAD_TREE ]"
  git -C "$SRC" worktree add -q --detach "$WORK/apply" "$BASE" >"$WORK/pr-apply.log" 2>&1 \
    && git -C "$WORK/apply" -c user.name=kit -c user.email=kit@localhost -c commit.gpgsign=false am -q "$KIT/fix-and-tests.patch" >>"$WORK/pr-apply.log" 2>&1
  check "git am of fix-and-tests.patch on the base gives the PR head's tree: git diff --quiet against $PR_HEAD is clean" \
    "git -C '$WORK/apply' diff --quiet HEAD $PR_HEAD && [ \"\$(git -C '$WORK/apply' rev-parse HEAD^{tree})\" = $PR_HEAD_TREE ]"
  check "both patches carry the PR head's test file, the pinned blob $TEST_BLOB" \
    "[ \"\$(git -C '$SRC' rev-parse $PR_HEAD:$TF)\" = $TEST_BLOB ] && [ \"\$(git -C '$WORK/apply' rev-parse HEAD:$TF)\" = $TEST_BLOB ]"
  git -C "$SRC" worktree remove --force "$WORK/apply" >>"$WORK/pr-apply.log" 2>&1
else
  check "the local repository holds the PR head $PR_HEAD; fetch lkhun9311/vllm fix/hf3fs-preemption-save ($(cat "$WORK/pr.err"))" "false"
fi
# run.sh now differs from kit p4's in b1's phase, budget and stop as well, which the end-to-end runs and mutants below check.
check "envprobe.py is kit p4's" "cmp -s '$ROOT/$KIT4REL/envprobe.py' '$KIT/envprobe.py'"
if git -C "$SRC" cat-file -e "$BASE^{commit}" 2>"$WORK/src.err"; then
  check "the local base has the pinned tree, and its first parent is the wheel commit with no blocking-path change" \
    "[ \"\$(git -C '$SRC' rev-parse $BASE^{tree})\" = $BASE_TREE ] && [ \"\$(git -C '$SRC' rev-parse $BASE^1)\" = $WHEEL ] \
     && [ -z \"\$(git -C '$SRC' diff --no-renames --name-only $WHEEL $BASE -- csrc cmake CMakeLists.txt pyproject.toml vllm/_custom_ops.py vllm/_cpu_ops.py)\" ]"
else
  check "the local repository holds the base 0e3c8dbdae ($(cat "$WORK/src.err"))" "false"
fi

# ---------------------------------------------------------------- vLLM's startup check on CPU, with the test's own constants
# startup NAME [SED]: the base with tests-only.patch applied, the test file edited by SED if given, then the startup check in the CPU vLLM environment.
# Its output goes to startup-NAME.log, and it returns the check's status, or 9 when the checkout or the edit could not be made.
startup() {
  local n=$1 sedexpr=${2:-} a="$WORK/apply"
  [ -e "$a" ] && git -C "$SRC" worktree remove --force "$a" >>"$WORK/apply.log" 2>&1
  git -C "$SRC" worktree add -q --detach "$a" "$BASE" >>"$WORK/apply.log" 2>&1 && git -C "$a" apply "$KIT/tests-only.patch" >>"$WORK/apply.log" 2>&1 || return 9
  if [ -n "$sedexpr" ]; then
    cp "$a/$TF" "$WORK/startup-orig.py" && sed -i "$sedexpr" "$a/$TF" || return 9
    # An edit that changes nothing would leave the pinned test, and its pass would read as a mutant that was not caught.
    cmp -s "$WORK/startup-orig.py" "$a/$TF" && { echo "the startup mutant $n changed nothing" >"$WORK/startup-$n.log"; return 9; }
  fi
  # The hub stays offline, so the tokenizer and the model config come from the local cache of the pinned snapshot.
  ( cd "$a" && env -i PATH="$PATH" HOME="$HOME" TMPDIR="$TMPDIR" HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 PYTHONPATH="$a" PYTHONDONTWRITEBYTECODE=1 \
    timeout --kill-after=5 300 "$CPU_VLLM_PY" -B "$STARTUP" "$a" "${STARTUP_REV:-$MODEL_REV}" --reset ) >"$WORK/startup-$n.log" 2>"$WORK/startup-$n.err"
}
sl() { command grep -qF -- "$2" "$WORK/startup-$1.log"; }
# The tokenizer and the model config are loaded at the revision the kit pins, not at whatever the local refs/main names.
MODEL_REV=$(sed -n 's/^MODEL_REV=\([0-9a-f]\{40\}\)$/\1/p' "$KIT/run.sh")
if [ -x "$CPU_VLLM_PY" ] && [ -n "$MODEL_REV" ]; then
  startup pinned; rc=$?
  check "startup: vLLM's get_kv_cache_configs accepts the pinned test's max_model_len 736 with 48 blocks of 16, and each request's 253 + 480 = 733 tokens fit" \
    "[ $rc = 0 ] && sl pinned 'ok   vLLM'\"'\"'s get_kv_cache_configs accepts max_model_len 736 with num_gpu_blocks_override=48' \
     && sl pinned 'ok   max_model_len 736 fits the pool'\"'\"'s usable 47 blocks x 16 = 752 tokens' \
     && [ \"\$(command grep -c '253 prompt tokens plus 480 decoded = 733, fits max_model_len 736' '$WORK/startup-pinned.log')\" = 2 ] \
     && sl pinned 'ok   LLM() is built with model=E2E_MODEL' && sl pinned 'ok   the preempting generate uses max_tokens=DECODE_TOKENS'"
  [ $rc = 0 ] || tail -n 5 "$WORK/startup-pinned.log" "$WORK/startup-pinned.err" >&2
  check "reset: the test's _reset_prefix_cache replaced the bare assert, is bounded at 50 steps, and against vLLM's BlockPool resets once the blocks free and fails when they never do" \
    "[ $rc = 0 ] && sl pinned 'ok   no bare assert on llm.reset_prefix_cache() is left in the test' && sl pinned 'ok   the GPU test calls _reset_prefix_cache(llm) once' \
     && sl pinned 'ok   _reset_prefix_cache is bounded: for over range(max_steps), max_steps=50' \
     && sl pinned 'ok   with 16 blocks freed on the 3rd engine step, the helper resets the prefix cache after 3 steps (took 3)' \
     && sl pinned 'ok   with blocks never freed, the helper fails after its 50 steps rather than waiting on (took 50)'"
  startup mbare 's/^            _reset_prefix_cache(llm)$/            assert llm.reset_prefix_cache()/'; rc=$?
  check "reset mutant: the bare assert, as in run p3, is caught" \
    "[ $rc = 1 ] && sl mbare 'FAIL no bare assert on llm.reset_prefix_cache() is left in the test' && sl mbare 'FAIL the GPU test calls _reset_prefix_cache(llm) once'"
  startup munbounded 's/^    for _ in range(max_steps):$/    while True:/'; rc=$?
  check "reset mutant: a helper that loops without bound is caught" "[ $rc = 1 ] && sl munbounded 'FAIL _reset_prefix_cache is bounded'"
  startup mhuge 's/^def _reset_prefix_cache(llm, max_steps: int = 50) -> None:$/def _reset_prefix_cache(llm, max_steps: int = 5000) -> None:/'; rc=$?
  check "reset mutant: a bound of 5000 steps, over the gate's 100, is caught" "[ $rc = 1 ] && sl mhuge 'FAIL _reset_prefix_cache is bounded'"
  startup mnostep 's/^        llm.llm_engine.step()$/        pass/'; rc=$?
  check "reset mutant: a helper that retries without stepping the engine never frees the blocks, and the BlockPool run catches it" \
    "[ $rc = 1 ] && sl mnostep 'FAIL with 16 blocks freed on the 3rd engine step'"
  startup m1024 's/^MAX_MODEL_LEN = 736$/MAX_MODEL_LEN = 1024/'; rc=$?
  check "startup mutant: MAX_MODEL_LEN 1024, runs p1 and p2's value, is refused by vLLM's own check with their message and by the arithmetic" \
    "[ $rc = 1 ] && sl m1024 'FAIL vLLM'\"'\"'s get_kv_cache_configs accepts max_model_len 1024' && sl m1024 'max seq len (1024), (0.04 GiB KV cache is needed' \
     && sl m1024 'estimated maximum model length is 752' && sl m1024 'FAIL max_model_len 1024 fits the pool'"
  startup m768 's/^MAX_MODEL_LEN = 736$/MAX_MODEL_LEN = 768/'; rc=$?
  check "startup mutant: MAX_MODEL_LEN 768, which 48 x 16 would allow, is refused, since the pool's null block is never handed out" \
    "[ $rc = 1 ] && sl m768 'FAIL vLLM'\"'\"'s get_kv_cache_configs accepts max_model_len 768' && sl m768 'FAIL max_model_len 768 fits the pool'"
  startup m752 's/^MAX_MODEL_LEN = 736$/MAX_MODEL_LEN = 752/'; rc=$?
  check "startup boundary: MAX_MODEL_LEN 752, exactly 47 x 16, is accepted, so the gate is vLLM's rule and not a stricter one" \
    "[ $rc = 0 ] && sl m752 'ok   vLLM'\"'\"'s get_kv_cache_configs accepts max_model_len 752'"
  startup mdecode 's/^DECODE_TOKENS = 480$/DECODE_TOKENS = 484/'; rc=$?
  check "startup mutant: DECODE_TOKENS 484 makes each request 737 tokens, over max_model_len 736, and is refused" \
    "[ $rc = 1 ] && sl mdecode 'FAIL the Target request, 253 prompt tokens plus 484 decoded = 737' && sl mdecode 'FAIL the Other request'"
  startup mblocks 's/^NUM_GPU_BLOCKS = 48$/NUM_GPU_BLOCKS = 46/'; rc=$?
  check "startup mutant: a 46-block pool holds 720 tokens, under 736, and vLLM's own check refuses it" \
    "[ $rc = 1 ] && sl mblocks 'FAIL vLLM'\"'\"'s get_kv_cache_configs accepts max_model_len 736 with num_gpu_blocks_override=46'"
  startup mwiring 's/max_model_len=MAX_MODEL_LEN,/max_model_len=1024,/'; rc=$?
  check "startup mutant: an LLM() that takes a literal 1024 instead of MAX_MODEL_LEN is caught by the wiring check" \
    "[ $rc = 1 ] && sl mwiring 'FAIL LLM() is built with model=E2E_MODEL'"
  STARTUP_REV=0000000000000000000000000000000000000000 startup otherrev; rc=$?
  check "startup: a model revision the local cache does not hold fails, so the check loads the pinned revision rather than main" \
    "[ $rc = 1 ] && sl otherrev 'FAIL the startup check ran to the end'"
  CPU_VLLM_PY_SAVED=$CPU_VLLM_PY; CPU_VLLM_PY=/bin/false
  startup nocpu; rc=$?; CPU_VLLM_PY=$CPU_VLLM_PY_SAVED
  check "startup: an environment that cannot run the check fails rather than passes" "[ $rc != 0 ]"
  git -C "$SRC" worktree remove --force "$WORK/apply" >>"$WORK/apply.log" 2>&1
else
  check "the CPU vLLM environment $CPU_VLLM_PY is there and run.sh pins MODEL_REV (got "$MODEL_REV"), so vLLM's startup check can run before any GPU is bought" "false"
fi

# ---------------------------------------------------------------- the Python units
python3 -I "$CHECK" "$KIT" "$FAKES" >"$WORK/units.log" 2>&1; rc=$?
check "the unit checks pass ($(command grep -c '^ok' "$WORK/units.log") ok, $(command grep -c '^FAIL' "$WORK/units.log") failed)" "[ $rc = 0 ]"
command grep '^FAIL' "$WORK/units.log" >&2
tail -n 3 "$WORK/units.log" | command grep -q 'Traceback\|Error' && tail -n 5 "$WORK/units.log" >&2

# ---------------------------------------------------------------- run.sh's arguments and settings
dry() {
  local k=$1; shift
  local args=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do args+=("$1"); shift; done
  [ "${1:-}" = -- ] && shift
  rm -rf "$WORK/dry"
  env -i PATH="$PATH" HOME="$HOME" KIT_DRY_RUN=1 OUT="$WORK/dry" "$@" bash "$k/run.sh" "${args[@]}" >"$WORK/dry.out" 2>&1
}
check "the default settings are accepted and record the order and the runtime session's command with -s, and no CUDA_LAUNCH_BLOCKING, -x or multiprocessing setting" \
  "dry '$KIT' && command grep -qx 'budget_s=1800' '$WORK/dry/settings.txt' && command grep -qx 'p5=1' '$WORK/dry/settings.txt' && command grep -qx 'p5_budget_s=600' '$WORK/dry/settings.txt' && command grep -qx 'b1=1' '$WORK/dry/settings.txt' && command grep -qx 'b1_cap_s=240' '$WORK/dry/settings.txt' && command grep -qx 'arm_cap_s=240' '$WORK/dry/settings.txt' \
   && command grep -qxF 'order=control fix, each in its own process' '$WORK/dry/settings.txt' \
   && command grep -qxF 'command=python -m pytest $TF -q -s --tb=short' '$WORK/dry/settings.txt'"
check "CUDA_LAUNCH_BLOCKING set by a caller is refused rather than passed to the tests" "! dry '$KIT' -- CUDA_LAUNCH_BLOCKING=1 && command grep -qF 'runs without it' '$WORK/dry.out'"
check "a positional argument is refused, and nothing is written" "! dry '$KIT' extra && command grep -qF 'takes no arguments' '$WORK/dry.out' && [ ! -e '$WORK/dry' ]"
check "BUDGET_S above 1800, not whole seconds, at or below the reserve, or with a leading zero is refused, as are a bad B1 or B1_CAP_S" \
  "! dry '$KIT' -- P5=2 && ! dry '$KIT' -- P5=0 B1=0 && dry '$KIT' -- P5=0 && ! dry '$KIT' -- B1=2 && ! dry '$KIT' -- B1_CAP_S=10 && ! dry '$KIT' -- B1_CAP_S=0240 && ! dry '$KIT' -- BUDGET_S=1801 && ! dry '$KIT' -- BUDGET_S=10m && ! dry '$KIT' -- BUDGET_S=60 && ! dry '$KIT' -- BUDGET_S=0300"
check "ARM_CAP_S with a leading zero or under 30, and earlier kits' cap settings, are refused" \
  "! dry '$KIT' -- ARM_CAP_S=0240 && ! dry '$KIT' -- ARM_CAP_S=5 && ! dry '$KIT' -- CASE_CAP_S=180"
m=$(mutant budgetcap run.sh 's/^BUDGET_MAX_S=1800$/BUDGET_MAX_S=2400/')
mcheck "mutant: a run.sh that takes BUDGET_S=1801 is caught" "! { ! dry '$m' -- BUDGET_S=1801; }"
m=$(mutant blockingok run.sh 's/^\[ -z "\${CUDA_LAUNCH_BLOCKING:-}" \] ||/true ||/')
mcheck "mutant: a run.sh that lets CUDA_LAUNCH_BLOCKING through is caught" "! { ! dry '$m' -- CUDA_LAUNCH_BLOCKING=1; }"

# ---------------------------------------------------------------- the budget against the runner's rates, on both instance types
S="$ROOT/hack/gpu-kit-session.sh"
bring=$(sed -n 's/^BRINGUP_S=\([0-9]*\)$/\1/p' "$S")
upl=$(sed -n 's/^EVIDENCE_UPLOAD_S=\([0-9]*\)$/\1/p' "$S")
kitmax=$(sed -n 's/^BUDGET_MAX_S=\([0-9]*\)$/\1/p' "$KIT/run.sh")
for t in g5.xlarge:0.5378:0.8579 g5.2xlarge:0.6078:0.9696; do
  type=${t%%:*} want=$(echo "$t" | cut -d: -f2) backstop=${t##*:}
  rate=$(sed -n "s/^    $type) echo \"[0-9.]* \([0-9.]*\) [0-9]*\" ;;\$/\1/p" "$S")
  sched=$(INSTANCE_TYPE=$type bash "$S" --print-schedule 2>&1)
  tail_s=$(python3 -I -c 'import re,sys; d=dict(re.findall(r"(\w+)=([\w.]+)", sys.argv[1])); print(int(d["termination_s"]) - int(d["evidence_s"]))' "$sched")
  worst=$(python3 -I -c 'import sys; b,k,u,t,r = map(float, sys.argv[1:]); print(f"{(b + k + u + t) / 3600 * r:.4f} {int(b + k + u + t)}")' "${bring:-x}" "${kitmax:-x}" "${upl:-x}" "${tail_s:-x}" "${rate:-x}")
  check "$type: BUDGET_S at its maximum, $kitmax s, bills ${worst#* } s at \$$rate/h, \$${worst% *}, as run.sh's header says" \
    "[ '$worst' = '$want 2520' ] && command grep -qF '\$$want on $type' '$KIT/run.sh'"
  check "$type: the runner's own backstop stays \$$backstop, as run.sh's header says" \
    "[[ '$sched' == *worst_case_usd=$backstop ]] && command grep -qF '\$$backstop on $type' '$KIT/run.sh'"
done
check "b1 adds at most \$0.2561 on g5.xlarge to kit p4's \$0.2817, within the approved \$0.30 or so, as run.sh's header says" \
  "python3 -I -c 'import sys; sys.exit(0 if round(0.5378 - 0.2817, 4) == 0.2561 and 0.2561 <= 0.30 else 1)' && command grep -qF 'b1 adds at most \$0.2561 and \$0.2894' '$KIT/run.sh'"

# ---------------------------------------------------------------- end to end on the fakes, with the real checkout, git apply and git am
e2e() {
  local k=$1 n=$2; shift 2
  local d="$WORK/e2e-$n"
  mkdir -p "$d/cwd" "$d/hf"
  ( cd "$d/cwd" && timeout --kill-after=5 "${E2E_OUTER_S:-120}" env PATH="$FAKES:$TOOLFAKES:$PATH" KIT_OFFLINE_TEST=1 OFFLINE_VLLM_SRC="$SRC" \
    FAKE_HF_DIR="$d/hf" OFFLINE_MODEL_BIN_SHA256="$FAKE_BIN_SHA256" FAKE_ORDER_LOG="$d/order" FAKE_B1_LOG="$d/b1order" OUT="$d/out" "$@" bash "$k/run.sh" >"$d/run.log" 2>&1 )
}
v() { command grep -qx "VERDICT: $2" "$WORK/e2e-$1/out/verdict.txt"; }
vt() { command grep -qF -- "$2" "$WORK/e2e-$1/out/verdict.txt"; }
order() { [ -f "$WORK/e2e-$1/order" ] && paste -sd' ' "$WORK/e2e-$1/order"; }
stopped() { [ -f "$WORK/e2e-$1/out/STOPPED" ] && command grep -qF -- "$2" "$WORK/e2e-$1/out/STOPPED"; }
b1() { command grep -qx "B1: $2" "$WORK/e2e-$1/out/b1/b1-verdict.txt"; }
b1t() { command grep -qF -- "$2" "$WORK/e2e-$1/out/b1/b1-verdict.txt"; }
b1order() { [ -f "$WORK/e2e-$1/b1order" ] && paste -sd' ' "$WORK/e2e-$1/b1order"; }
# p5kept NAME: the test arms' verdict is CONFIRMED with exit 0, no run-wide STOPPED, and verdict.txt as verdict.py wrote it before b1.
p5kept() { [ ! -e "$WORK/e2e-$1/out/STOPPED" ] && v "$1" CONFIRMED && command grep -qx 'verdict exit=0 t=[0-9]*' "$WORK/e2e-$1/out/status.txt" \
  && [ "$(command grep -c '^verdict exit=' "$WORK/e2e-$1/out/status.txt")" = 1 ]; }

e2e "$KIT" pass FAKE_EXPECT_OFFLINE=1; rc=$?
check "pass: CONTROL fails the comparison with preconditions met, FIX passes, and the run is CONFIRMED, exit 0" "[ $rc = 0 ] && v pass CONFIRMED"
check "pass: the two processes ran CONTROL then FIX, on the right code" \
  "[ \"\$(order pass)\" = '$ORDER_WANT' ] && [ \"\$(command grep -oE '^test-[a-z]+' '$WORK/e2e-pass/out/status.txt' | paste -sd' ')\" = 'test-control test-fix' ]"
check "pass: the fix commit has the pinned tree and the base as its parent, the control the pinned tree, both the pinned test blob, and the hook only in the fix" \
  "command grep -q '^fix commit=[0-9a-f]\{40\} tree=$FIX_TREE parent=$BASE\$' '$WORK/e2e-pass/out/versions.txt' \
   && command grep -qx 'base commit=$BASE tree=$BASE_TREE' '$WORK/e2e-pass/out/versions.txt' \
   && [ \"\$(command grep -c '^control tree=' '$WORK/e2e-pass/out/versions.txt')\" = 6 ] && [ \"\$(command grep -c '^control tree=$CONTROL_TREE\$' '$WORK/e2e-pass/out/versions.txt')\" = 6 ] \
   && command grep -qx 'control test_blob=$TEST_BLOB' '$WORK/e2e-pass/out/versions.txt' && command grep -qx 'fix test_blob=$TEST_BLOB' '$WORK/e2e-pass/out/versions.txt' \
   && command grep -qx 'handle_preemptions_defs control=0 fix=1' '$WORK/e2e-pass/out/versions.txt' \
   && command grep -qx 'base_first_parent=$WHEEL wheel_commit=$WHEEL' '$WORK/e2e-pass/out/versions.txt' && [ ! -s '$WORK/e2e-pass/out/wheel-blocking-diff.txt' ]"
check "pass: the verdict prints each arm's summary, held line, page errors and CONTROL's traceback" \
  "vt pass 'CONTROL: GPU test mismatch (exit 1): 1 failed, 20 warnings' && vt pass 'FIX: GPU test passed (exit 0): 1 passed, 20 warnings' \
   && vt pass '  pytest summary (verbatim): 1 failed, 20 warnings in 61.20s (0:01:01)' && vt pass '  pytest summary (verbatim): 1 passed, 20 warnings in 61.20s (0:01:01)' \
   && vt pass 'held line: held=[20, 21, 22, 23] reused=[21, 22] hold_timed_out=False' && vt pass 'held line: held=[20, 21, 22, 23] reused=[21, 22] hold_timed_out=True' \
   && vt pass 'held-save page errors: [0.9731, 1.0214]' && vt pass 'E   AssertionError: [0.9731, 1.0214]' && ! vt pass 'CPU'"
check "pass: the hub was offline, and the run left checksums and no worktree" \
  "command grep -qx 'hub_offline=1 for the test runs' '$WORK/e2e-pass/out/settings.txt' && ( cd '$WORK/e2e-pass/out' && sha256sum -c --quiet SHA256SUMS ) \
   && ! git -C '$SRC' worktree list | command grep -qF '$WORK/e2e-pass/'"
check "b1: after the test arms, eight processes ran in order C, F, C, F, C, F at pool 128 and C, F at 2304, and b1 is VALID apart from the verdict" \
  "[ \"\$(b1order pass)\" = '$B1_ORDER_WANT' ] && b1 pass VALID && p5kept pass \
   && [ \"\$(command grep -oE '^(test-[a-z]+|verdict|b1-[a-z0-9-]+) exit=' '$WORK/e2e-pass/out/status.txt' | sed 's/ exit=\$//' | paste -sd' ')\" = 'test-control test-fix verdict b1-control-128-1 b1-fix-128-1 b1-control-128-2 b1-fix-128-2 b1-control-128-3 b1-fix-128-3 b1-control-2304-1 b1-fix-2304-1 b1-verdict' ] \
   && [ \"\$(ls '$WORK/e2e-pass/out/b1' | command grep -c 'json\$')\" = 9 ] && command grep -qF 'b1/control-128-1.json' '$WORK/e2e-pass/out/SHA256SUMS' \
   && command grep -qF 'B1, the performance run: a separate section that does not change the verdict above.' '$WORK/e2e-pass/run.log'"
for k in hasfixcontrol:control-128 hasfixfix:'control-128 fix-128'; do
  mode=${k%%:*} ran=${k#*:}
  e2e "$KIT" "b1-$mode" FAKE_B1="$mode"; rc=$?
  check "b1 $mode: has_fix is wrong, so b1 stops after '$ran' and is NOT RUN, and the test arms' CONFIRMED and exit 0 stand" \
    "[ $rc = 0 ] && p5kept b1-$mode && b1 b1-$mode 'NOT RUN' && [ \"\$(b1order b1-$mode)\" = '$ran' ] && [ -s '$WORK/e2e-b1-$mode/out/b1/NOT_RUN' ]"
done
e2e "$KIT" b1-zeropreempt FAKE_B1=zeropreempt; rc=$?
check "b1 zeropreempt: a pool-128 run with no preemption makes b1 INVALID, its values printed as they are, and the verdict stands" \
  "[ $rc = 0 ] && p5kept b1-zeropreempt && b1 b1-zeropreempt INVALID && b1t b1-zeropreempt 'B1 INVALID: control-128-2: preemptions=0'"
for k in storageshort:'fix-128-1: the metadata server ran short of pages 1 times' preempt2304:'fix-2304-1: preemptions=3, so the pool-2304 control preempted' \
  storedshort:'fix-128-2: stored_keys=1990, fewer than the 2003 blocks its load saves'; do
  mode=${k%%:*} why=${k#*:}
  e2e "$KIT" "b1-$mode" FAKE_B1="$mode"; rc=$?
  check "b1 $mode: b1 is INVALID ($why), all eight runs still made, and the verdict stands" \
    "[ $rc = 0 ] && p5kept b1-$mode && b1 b1-$mode INVALID && b1t b1-$mode 'B1 INVALID: $why' && [ \"\$(b1order b1-$mode)\" = '$B1_ORDER_WANT' ]"
done
e2e "$KIT" b1-nojson FAKE_B1=nojson; rc=$?
check "b1 nojson: a run that dies before its JSON makes b1 INCOMPLETE, the other seven still run, and the verdict stands" \
  "[ $rc = 0 ] && p5kept b1-nojson && b1 b1-nojson INCOMPLETE && [ \"\$(b1order b1-nojson)\" = '$B1_ORDER_WANT' ]"
t0=$(date +%s); E2E_OUTER_S=260 e2e "$KIT" b1-hang FAKE_B1=hang BUDGET_S=200 B1_CAP_S=30; rc=$?; took=$(( $(date +%s) - t0 ))
check "b1 hang: b1 runs out of budget and stops alone, writing b1/STOPPED, while the test arms' verdict, exit 0 and logs stand; run.sh ends inside BUDGET_S ($took s)" \
  "[ $rc = 0 ] && p5kept b1-hang && b1 b1-hang INCOMPLETE && command grep -qF 'the budget ran out before b1-' '$WORK/e2e-b1-hang/out/b1/STOPPED' \
   && command grep -qx 'b1-control-128-1 exit=124 t=[0-9]*' '$WORK/e2e-b1-hang/out/status.txt' && [ -s '$WORK/e2e-b1-hang/out/e2e-fix.log' ] \
   && ( cd '$WORK/e2e-b1-hang/out' && sha256sum -c --quiet SHA256SUMS ) && [ $took -le 200 ]"
cp -r "$KIT" "$WORK/tampered-bench" && printf '\n' >>"$WORK/tampered-bench/bench_preempt.py"
e2e "$WORK/tampered-bench" tampered-bench; rc=$?
check "a bench_preempt.py that is not the pinned one stops b1 before any b1 process, and the verdict stands" \
  "[ $rc = 0 ] && p5kept tampered-bench && command grep -qF 'bench_preempt.py has sha256' '$WORK/e2e-tampered-bench/out/b1/STOPPED' && ! [ -s '$WORK/e2e-tampered-bench/b1order' ]"
check "b1: each run had its own TMPDIR, deleted after it, and none is left; disk.txt records the free space before each" \
  "! [ -e '$WORK/e2e-pass/cwd/b1-tmp' ] && [ \"\$(command grep -c '^b1-[a-z0-9-]* free_gb=[0-9][0-9]*\$' '$WORK/e2e-pass/out/b1/disk.txt')\" = 8 ]"
cp -r "$KIT" "$WORK/nodisk" && sed -i 's/^B1_MIN_FREE_GB=10$/B1_MIN_FREE_GB=1000000/' "$WORK/nodisk/run.sh"
e2e "$WORK/nodisk" b1-nodisk; rc=$?
check "b1 stops before its first run when too little disk is free, and the verdict stands" \
  "[ $rc = 0 ] && p5kept b1-nodisk && command grep -qF 'GB free before b1-control-128-1, under 1000000' '$WORK/e2e-b1-nodisk/out/b1/STOPPED' && ! [ -s '$WORK/e2e-b1-nodisk/b1order' ]"
e2e "$KIT" b1-only P5=0; rc=$?
check "P5=0, a b1-only session: no test process, no test verdict, all eight b1 runs, and run.sh exits with b1's VALID, 0" \
  "[ $rc = 0 ] && b1 b1-only VALID && command grep -qx 'test arms skipped (P5=0)' '$WORK/e2e-b1-only/out/status.txt' \
   && ! command grep -qE '^(test-|verdict exit)' '$WORK/e2e-b1-only/out/status.txt' && ! [ -e '$WORK/e2e-b1-only/out/verdict.txt' ] \
   && ! [ -s '$WORK/e2e-b1-only/order' ] && [ \"\$(b1order b1-only)\" = '$B1_ORDER_WANT' ]"
e2e "$KIT" b1-only-invalid P5=0 FAKE_B1=zeropreempt; rc=$?
check "P5=0 with a pool-128 run that did not preempt exits 6, b1's INVALID" "[ $rc = 6 ] && b1 b1-only-invalid INVALID"
e2e "$KIT" b1-only-notrun P5=0 FAKE_B1=hasfixcontrol; rc=$?
check "P5=0 with a wrong has_fix exits 4, b1's NOT RUN" "[ $rc = 4 ] && b1 b1-only-notrun 'NOT RUN'"
cp -r "$KIT" "$WORK/oldbench" && cp "$ROOT/hack/vllm-hf3fs-preemption-fake/bench_b1.py" "$WORK/oldbench/bench_preempt.py" \
  && sed -i "s/^BENCH_SHA256=.*/BENCH_SHA256=$BENCH1_SHA256/" "$WORK/oldbench/run.sh"
e2e "$WORK/oldbench" oldbench; rc=$?
check "a kit pinned to the first bench's sha256 but shipping another file stops b1, so the re-pin is what runs" \
  "[ $rc = 0 ] && command grep -qF 'not the pinned $BENCH1_SHA256' '$WORK/e2e-oldbench/out/b1/STOPPED'"
e2e "$KIT" b1-off B1=0; rc=$?
check "B1=0 skips b1 and leaves the verdict as it is" "[ $rc = 0 ] && p5kept b1-off && command grep -qx 'b1 skipped (B1=0)' '$WORK/e2e-b1-off/out/status.txt' && ! [ -e '$WORK/e2e-b1-off/out/b1' ]"
for kind in fixmismatch:2:FINDING fixsmallerr:2:FINDING fixother:2:FINDING fixfault:2:FINDING \
  fixnotimeout:5:INCONCLUSIVE fixprecond:5:INCONCLUSIVE controlpass:5:INCONCLUSIVE controlprecond:5:INCONCLUSIVE controlsmall:5:INCONCLUSIVE \
  controltimeout:5:INCONCLUSIVE controlkv:4:'NOT RUN' fixload:4:'NOT RUN' skip:3:INCOMPLETE nosummary:3:INCOMPLETE setupboth:4:'NOT RUN' oldline:3:INCOMPLETE; do
  k=${kind%%:*} rest=${kind#*:} want_rc=${rest%%:*} want=${rest#*:}
  e2e "$KIT" "$k" FAKE_MODE="$k"; rc=$?
  check "$k: the run is $want, exit $want_rc" "[ $rc = $want_rc ] && v $k '$want'"
done
check "controlprecond: the verdict names the precondition not met" "vt controlprecond 'precondition not met: held block reused'"
t0=$(date +%s); e2e "$KIT" hang FAKE_MODE=hang BUDGET_S=100 ARM_CAP_S=30; rc=$?; took=$(( $(date +%s) - t0 ))
check "hang: each process is cut at its cap or the budget left, and run.sh ends inside BUDGET_S ($took s)" \
  "command grep -qx 'test-control exit=124 t=[0-9]*' '$WORK/e2e-hang/out/status.txt' \
   && { { [ $rc = 3 ] && command grep -qx 'test-fix exit=124 t=[0-9]*' '$WORK/e2e-hang/out/status.txt'; } || { [ $rc = 1 ] && stopped hang 'the budget ran out before test-fix'; }; } \
   && v hang INCOMPLETE && [ $took -le 100 ]"
# lastend NAME: the t= of the last timed step, which must come before BUDGET_S less the reserve the verdict and checksums need.
lastend() { command grep -E '^test-[a-z]+ exit=' "$WORK/e2e-$1/out/status.txt" | tail -n 1 | sed 's/.* t=//'; }
e2e "$KIT" hangterm FAKE_MODE=hangterm BUDGET_S=100 ARM_CAP_S=40; rc=$?
check "hangterm: a process that ignores SIGTERM is killed after the grace, and the last step still ends by BUDGET_S less the reserve ($(lastend hangterm) s)" \
  "[ $rc = 1 ] && command grep -qx 'test-control exit=137 t=[0-9]*' '$WORK/e2e-hangterm/out/status.txt' && [ \"\$(lastend hangterm)\" -le 40 ]"
m=$(mutant nograce run.sh 's/^  local left=\$(( STEP_BUDGET_S - RESERVE_S - KILL_GRACE_S - /  local left=$(( STEP_BUDGET_S - RESERVE_S - /')
[ -n "$m" ] && e2e "$m" m-nograce FAKE_MODE=hangterm BUDGET_S=100 ARM_CAP_S=40
mcheck "mutant: a step budget that leaves out the kill grace overruns the reserve and is caught" "[ \"\$(lastend m-nograce)\" -gt 40 ]"
for p in tests-only fix-and-tests; do
  cp -r "$KIT" "$WORK/tampered-$p" && printf '\n' >>"$WORK/tampered-$p/$p.patch"
  e2e "$WORK/tampered-$p" "tampered-$p"; rc=$?
  check "a $p.patch that is not the pinned one stops the run before any checkout" \
    "[ $rc = 1 ] && stopped tampered-$p '$p.patch has sha256' && ! command grep -q '^worktree-vllm' '$WORK/e2e-tampered-$p/out/status.txt'"
done
m=$(mutant othertree run.sh 's/^FIX_TREE=441714150d9afe8fd27523f66f288568e8a8c1e8$/FIX_TREE=0000000000000000000000000000000000000000/')
[ -n "$m" ] && e2e "$m" othertree
mcheck "a fix whose tree is not the pinned one stops the run before any test" "stopped othertree 'not the pinned 0000000' && ! [ -s '$WORK/e2e-othertree/order' ]"
m=$(mutant otherbase run.sh 's/^BASE_TREE=e6819e279d40268d45eee2bfa134d5d04b05e53f$/BASE_TREE=0000000000000000000000000000000000000000/')
[ -n "$m" ] && e2e "$m" otherbase
mcheck "a base whose tree is not the pinned one stops the run before any test" "stopped otherbase 'not the pinned 0000000' && ! [ -s '$WORK/e2e-otherbase/order' ]"
m=$(mutant othercontrol run.sh 's/^CONTROL_TREE=66cc798220693c7256072a87e1a8ab19952f37c5$/CONTROL_TREE=0000000000000000000000000000000000000000/')
[ -n "$m" ] && e2e "$m" othercontrol
mcheck "a control whose tree is not the pinned one stops the run before any test" "stopped othercontrol 'the control has tree' && ! [ -s '$WORK/e2e-othercontrol/order' ]"
m=$(mutant otherwheel run.sh 's/^WHEEL_COMMIT=e2052f5c7ad64564f00dd4592e77c27785c9333f$/WHEEL_COMMIT=dd8c157895f01875bc5f44c51003bbe330647330/')
[ -n "$m" ] && e2e "$m" otherwheel
mcheck "a wheel commit that is not the base's first parent stops the run" "stopped otherwheel 'not the wheel commit dd8c1578'"
check "controlkv: a NOT RUN on memory prints the startup check's 'available KV cache memory' line" \
  "vt controlkv 'kv memory: ' && vt controlkv 'which is larger than the available KV cache memory (0.01 GiB)'"

# ---------------------------------------------------------------- the PR head pin, and kit p4's pins left in p5, each caught end to end
m=$(mutant otherprtree run.sh 's/^PR_HEAD_TREE=441714150d9afe8fd27523f66f288568e8a8c1e8$/PR_HEAD_TREE=0000000000000000000000000000000000000000/')
[ -n "$m" ] && e2e "$m" m-otherprtree
mcheck "a PR head tree that is not the fix's stops the run before any test" "stopped m-otherprtree 'is not the PR head' && ! [ -s '$WORK/e2e-m-otherprtree/order' ]"
m=$(mutant noprcheck run.sh 's/^PR_HEAD_TREE=441714150d9afe8fd27523f66f288568e8a8c1e8$/PR_HEAD_TREE=0000000000000000000000000000000000000000/; s/^\[ "\$FIX_TREE" = "\$PR_HEAD_TREE" \] ||/true ||/')
[ -n "$m" ] && e2e "$m" m-noprcheck
mcheck "mutant: a run.sh without the PR head check is caught" "! stopped m-noprcheck 'is not the PR head'"
m=$(mutant p4testssha run.sh "s/^TESTS_PATCH_SHA256=$TESTS_SHA256\$/TESTS_PATCH_SHA256=$P4_TESTS_SHA256/")
[ -n "$m" ] && e2e "$m" m-p4testssha
mcheck "mutant: p4's tests-only.patch sha256 stops the run" "stopped m-p4testssha 'tests-only.patch has sha256 $TESTS_SHA256, not the pinned $P4_TESTS_SHA256'"
m=$(mutant p4fixsha run.sh "s/^FIX_PATCH_SHA256=$FIX_SHA256\$/FIX_PATCH_SHA256=$P4_FIX_SHA256/")
[ -n "$m" ] && e2e "$m" m-p4fixsha
mcheck "mutant: p4's fix-and-tests.patch sha256 stops the run" "stopped m-p4fixsha 'fix-and-tests.patch has sha256 $FIX_SHA256, not the pinned $P4_FIX_SHA256'"
m=$(mutant p4fixtree run.sh "s/^FIX_TREE=$FIX_TREE\$/FIX_TREE=$P4_FIX_TREE/")
[ -n "$m" ] && e2e "$m" m-p4fixtree
mcheck "mutant: p4's fix tree stops the run before any test" "stopped m-p4fixtree 'has tree $FIX_TREE, not the pinned $P4_FIX_TREE' && ! [ -s '$WORK/e2e-m-p4fixtree/order' ]"
m=$(mutant p4controltree run.sh "s/^CONTROL_TREE=$CONTROL_TREE\$/CONTROL_TREE=$P4_CONTROL_TREE/")
[ -n "$m" ] && e2e "$m" m-p4controltree
mcheck "mutant: p4's control tree stops the run before any test" "stopped m-p4controltree 'has tree $CONTROL_TREE, not the pinned $P4_CONTROL_TREE' && ! [ -s '$WORK/e2e-m-p4controltree/order' ]"
m=$(mutant p4blob run.sh "s/^TEST_BLOB=$TEST_BLOB\$/TEST_BLOB=$P4_TEST_BLOB/")
[ -n "$m" ] && e2e "$m" m-p4blob
mcheck "mutant: p4's test blob stops the run before any test" "stopped m-p4blob 'test file is blob $TEST_BLOB, not the pinned $P4_TEST_BLOB' && ! [ -s '$WORK/e2e-m-p4blob/order' ]"
m=$(mutant noblobcheck run.sh "s/^TEST_BLOB=$TEST_BLOB\$/TEST_BLOB=$P4_TEST_BLOB/; s/^  \\[ \"\\\$blob\" = \"\\\$TEST_BLOB\" \\] ||/  true ||/")
[ -n "$m" ] && e2e "$m" m-noblobcheck
mcheck "mutant: a run.sh without the test blob check is caught" "! stopped m-noblobcheck 'not the pinned $P4_TEST_BLOB'"

# ---------------------------------------------------------------- mutants of run.sh, caught end to end
m=$(mutant testspin run.sh 's/^\[ "\$got_tests" = "\$TESTS_PATCH_SHA256" \] ||/true ||/')
[ -n "$m" ] && cp "$WORK/tampered-tests-only/tests-only.patch" "$m/" && e2e "$m" m-testspin
mcheck "mutant: a run.sh that skips tests-only.patch's sha256 pin is caught" "! stopped m-testspin 'tests-only.patch has sha256'"
m=$(mutant fixpin run.sh 's/^\[ "\$got_fix" = "\$FIX_PATCH_SHA256" \] ||/true ||/')
[ -n "$m" ] && cp "$WORK/tampered-fix-and-tests/fix-and-tests.patch" "$m/" && e2e "$m" m-fixpin
mcheck "mutant: a run.sh that skips fix-and-tests.patch's sha256 pin is caught" "! stopped m-fixpin 'fix-and-tests.patch has sha256'"
m=$(mutant nobasetree run.sh 's/^BASE_TREE=e6819e279d40268d45eee2bfa134d5d04b05e53f$/BASE_TREE=0000000000000000000000000000000000000000/; s/^\[ "\$tree" = "\$BASE_TREE" \] ||/true ||/')
[ -n "$m" ] && e2e "$m" m-nobasetree
mcheck "mutant: a run.sh without the base's tree check is caught" "! stopped m-nobasetree 'not the pinned 0000000'"
m=$(mutant nofixtree run.sh 's/^FIX_TREE=441714150d9afe8fd27523f66f288568e8a8c1e8$/FIX_TREE=0000000000000000000000000000000000000000/; s/^\[ "\$tree" = "\$FIX_TREE" \] ||/true ||/')
[ -n "$m" ] && e2e "$m" m-nofixtree
mcheck "mutant: a run.sh without the fix's tree check is caught" "! stopped m-nofixtree 'not the pinned 0000000'"
m=$(mutant swapped run.sh 's/^RUNS=(control fix)$/RUNS=(fix control)/')
[ -n "$m" ] && e2e "$m" m-swapped
mcheck "mutant: the arms run in the other order is caught by the order check" "[ \"\$(order m-swapped)\" != '$ORDER_WANT' ]"
m=$(mutant crossed run.sh 's/^  if \[ "\$1" = control \]; then$/  if [ "$1" = fix ]; then/')
[ -n "$m" ] && e2e "$m" m-crossed
mcheck "mutant: each arm's log holding the other arm's code does not report CONFIRMED" "! v m-crossed CONFIRMED"
m=$(mutant controlfixed run.sh 's/^    git -C vllm apply "\$TESTS_PATCH"/    git -C vllm apply "$FIX_PATCH"/')
[ -n "$m" ] && e2e "$m" m-controlfixed
mcheck "mutant: a CONTROL patched with the fix is stopped by the control's tree pin" "stopped m-controlfixed 'the control has tree' && ! v m-controlfixed CONFIRMED"
m=$(mutant controlfixedunguarded run.sh 's/^    git -C vllm apply "\$TESTS_PATCH"/    git -C vllm apply "$FIX_PATCH"/; s/^    \[ "\$t" = "\$CONTROL_TREE" \] ||/    true ||/')
[ -n "$m" ] && e2e "$m" m-controlfixedunguarded
mcheck "mutant: a CONTROL patched with the fix, past the tree pin, does not report CONFIRMED" "[ -f '$WORK/e2e-m-controlfixedunguarded/out/verdict.txt' ] && ! v m-controlfixedunguarded CONFIRMED"
m=$(mutant nos run.sh 's/ -q -s --tb=short; }$/ -q --tb=short; }/')
[ -n "$m" ] && e2e "$m" m-nos
mcheck "mutant: test runs without -s do not report CONFIRMED" "[ -f '$WORK/e2e-m-nos/out/verdict.txt' ] && ! v m-nos CONFIRMED"
m=$(mutant offline run.sh 's/^export HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1$/true/')
[ -n "$m" ] && e2e "$m" m-offline FAKE_EXPECT_OFFLINE=1
mcheck "mutant: a run.sh that leaves the hub online for the tests does not report CONFIRMED" "! v m-offline CONFIRMED"
m=$(mutant notimeout run.sh 's/^  timeout --kill-after="\$KILL_GRACE_S" "\$cap" "\$@" > "\$log" 2>&1$/  "$@" > "$log" 2>\&1/')
[ -n "$m" ] && { E2E_OUTER_S=90 e2e "$m" m-notimeout FAKE_MODE=hang BUDGET_S=100 ARM_CAP_S=30; rc=$?; }
mcheck "mutant: a step without its timeout overruns the budget and is caught" "[ \"\${rc:-0}\" = 124 ]"

m=$(mutant b1nopreflight run.sh 's/^    if \[ -n "\$got" \] && \[ "\$got" != "\$want" \]; then$/    if false; then/')
[ -n "$m" ] && e2e "$m" m-b1nopreflight FAKE_B1=hasfixcontrol
mcheck "mutant: a run.sh without b1's has_fix preflight runs on past a wrong tree, and is caught" "[ \"\$(b1order m-b1nopreflight)\" != control-128 ]"
m=$(mutant b1stopall run.sh 's/^  if \[ "\$PHASE" = b1 \]; then$/  if false; then/')
[ -n "$m" ] && E2E_OUTER_S=260 e2e "$m" m-b1stopall FAKE_B1=hang BUDGET_S=200 B1_CAP_S=30
mcheck "mutant: a b1 stop that writes the run-wide STOPPED and verdict is caught, since it would change the test arms' evidence" "! p5kept m-b1stopall"
m=$(mutant b1nopin run.sh 's/^  \[ "\$got" = "\$BENCH_SHA256" \] ||/  true ||/')
[ -n "$m" ] && printf '\n' >>"$m/bench_preempt.py" && e2e "$m" m-b1nopin
mcheck "mutant: a run.sh that skips the bench's sha256 pin is caught" "! command grep -qF 'bench_preempt.py has sha256' '$WORK/e2e-m-b1nopin/out/b1/STOPPED' 2>/dev/null"

m=$(mutant p5gate run.sh 's/^\[ "\$P5" = 1 \] || \[ "\$B1" = 1 \] ||/true ||/')
mcheck "mutant: a run.sh that takes P5=0 B1=0, with nothing to run, is caught" "! { ! dry '$m' -- P5=0 B1=0; }"
m=$(mutant p5skipignored run.sh 's/^if \[ "\$P5" = 1 \]; then$/if true; then/')
[ -n "$m" ] && e2e "$m" m-p5skipignored P5=0
mcheck "mutant: a run.sh that runs the test arms under P5=0 is caught" "[ -s '$WORK/e2e-m-p5skipignored/order' ]"
m=$(mutant b1keeptmp run.sh 's/^    rm -rf "\$tmp"$/    true/')
[ -n "$m" ] && e2e "$m" m-b1keeptmp
mcheck "mutant: a run.sh that leaves each run's storage on disk is caught" "! b1 m-b1keeptmp VALID"
m=$(mutant b1nodiskguard run.sh 's/^B1_MIN_FREE_GB=10$/B1_MIN_FREE_GB=1000000/; s/^    \[ "\${free_gb:-0}" -ge "\$B1_MIN_FREE_GB" \] ||/    true ||/')
[ -n "$m" ] && e2e "$m" m-b1nodiskguard
mcheck "mutant: a run.sh without the free-space guard is caught" "! command grep -qF 'GB free before' '$WORK/e2e-m-b1nodiskguard/out/b1/STOPPED' 2>/dev/null"

# ---------------------------------------------------------------- mutants of verdict.py, caught by the unit checks
caught() { ! python3 -I "$CHECK" "$1" "$FAKES" >"$WORK/mutant.log" 2>&1; }
while IFS='|' read -r name sedexpr; do
  [ -n "$name" ] || continue
  m=$(mutant "$name" verdict.py "$sedexpr")
  mcheck "mutant: verdict $name is caught" "caught '$m'"
done <<'MUTANTS'
confirms without CONTROL's page mismatch|s/^    elif control\["gpu"\] != "mismatch":$/    elif False:/
confirms a CONTROL error far from 1|s/^    elif control\["max_error"\] < OTHER_KV_MIN:$/    elif False:/
confirms a CONTROL whose hold timed out|s/^    elif control\["hold_timed_out"\] is not False:$/    elif False:/
confirms a FIX whose hold did not time out|s/^    elif fix\["hold_timed_out"\] is not True:$/    elif False:/
lets a FIX page mismatch pass|s/^    if fix\["gpu"\] in ("faulted", "mismatch") or (fix\["gpu"\] == "failed" and not setup_both):$/    if fix["gpu"] in ("faulted",) or (fix["gpu"] == "failed" and not setup_both):/
lets a FIX fault pass|s/^    if fix\["gpu"\] in ("faulted", "mismatch") or (fix\["gpu"\] == "failed" and not setup_both):$/    if fix["gpu"] in ("mismatch",) or (fix["gpu"] == "failed" and not setup_both):/
lets a FIX failure before the comparison pass|s/^    if fix\["gpu"\] in ("faulted", "mismatch") or (fix\["gpu"\] == "failed" and not setup_both):$/    if fix["gpu"] in ("faulted", "mismatch"):/
lets a FIX error at 0.05 or more pass|s/^ERROR_LIMIT = 0.05$/ERROR_LIMIT = 0.5/
expects the earlier file's three CPU tests|s/^CPU_TESTS = ()$/CPU_TESTS = ("TestHF3FSHandlePreemptions::a", "TestHF3FSHandlePreemptions::b", "TestHF3FSHandlePreemptions::c")/
drops the verbatim pytest summary|s/^        lines.append(f"  pytest summary (verbatim): {p.get('summary_raw')}")$/        pass/
prints the stripped summary as verbatim|s/^            rec\["summary_raw"\] = line.rstrip("\\r")$/            rec["summary_raw"] = line.strip("= ")/
calls a precondition failure a fix failure|s/^    elif gpu_bad and precondition:$/    elif False:/
misreads the reuse precondition|s/("held block reused", "no held block was reused by the other request")/("held block reused", "NEVER MATCHES")/
inverts hold_timed_out|s/m.group(3) == "True"$/m.group(3) == "False"/
accepts a held line with no reused block|s/^    elif gpu_bad and rec\["held_line"\] and (not rec\["held"\] or not rec\["reused"\]):$/    elif False:/
accepts a pass that printed nothing|s/^    elif rec\["held_line"\] is None or rec\["errors"\] is None:$/    elif False:/
lets preconditions pass to the control rule|s/^    elif "precondition" in states:$/    elif False:/
misses the KV memory cause|s/re.compile(r"KV cache is needed, which is larger than the available KV cache memory")/re.compile(r"NEVER MATCHES")/
misses the model load cause|s/re.compile(r"LocalEntryNotFoundError|Cannot find the requested files|couldn't connect to|RepositoryNotFound|GatedRepo")/re.compile(r"NEVER MATCHES")/
reads harness causes from captured logs|s/^    tb = "\\n".join(x for x in lines if x.startswith(("E ", ">")))$/    tb = "\\n".join(lines)/
misses an illegal access|s/^    rec\["illegal_lines"\] = \[f"{i}:{x}" for i, x in enumerate(lines, start=1) if ILLEGAL_RE.search(x)\]$/    rec["illegal_lines"] = []/
ignores a missing summary|s/^    elif summary is None or rc not in (0, 1):$/    elif False:/
ignores a skipped GPU test|s/^    elif got.get("skipped"):$/    elif False:/
accepts a process that ran other than the file's one test|s/^    elif sum(got.values()) != 1 + len(CPU_TESTS):$/    elif False:/
ignores no CUDA|s/^        if env.get("cuda_available") is not True or not env.get("device_name"):$/        if False:/
ignores a stopped run|s/^    if os.path.exists(os.path.join(out, "STOPPED")):$/    if False:/
misses vLLM's KV memory lines|s/^KV_MEMORY_RE = re.compile(r"\[Aa\]vailable KV cache memory")$/KV_MEMORY_RE = re.compile(r"NEVER MATCHES")/
reads only the capitalised KV memory line|s/^KV_MEMORY_RE = re.compile(r"\[Aa\]vailable KV cache memory")$/KV_MEMORY_RE = re.compile(r"Available KV cache memory")/
does not print the KV memory lines|s/^        lines.extend(f"  kv memory: {x}" for x in p.get("kv_memory_lines", \[\])\[:10\])$/        pass/
calls a setup failure in both arms a FINDING|s/^    setup_both = (control\["gpu"\] == "failed" and fix\["gpu"\] == "failed" and control\["fail_at"\] is not None$/    setup_both = False and (control["fail_at"] is not None/
merges failures at different lines|s/^                  and control\["fail_at"\] == fix\["fail_at"\] and control\["first_e"\] == fix\["first_e"\])$/                  and True)/
merges failures with different errors|s/ and control\["first_e"\] == fix\["first_e"\])$/)/
judges the older relative page errors line|s/^ERRORS_RE = re.compile(r"held-save page errors: /ERRORS_RE = re.compile(r"relative page errors: /
judges the end-of-run pages|s/^ERRORS_RE = re.compile(r"held-save page errors: /ERRORS_RE = re.compile(r"end-of-run page errors: /
lets the older line through|s/^OLD_ERRORS_RE = re.compile(r"relative page errors: \\\[")$/OLD_ERRORS_RE = re.compile(r"NEVER MATCHES")/
exits 0 when inconclusive|s/{"CONFIRMED": 0, "FINDING": 2, "NOT RUN": 4, "INCONCLUSIVE": 5}/{"CONFIRMED": 0, "FINDING": 2, "NOT RUN": 4, "INCONCLUSIVE": 0}/
MUTANTS
while IFS='|' read -r name sedexpr; do
  [ -n "$name" ] || continue
  m=$(mutant "$name" b1_verdict.py "$sedexpr")
  mcheck "mutant: b1_verdict $name is caught" "caught '$m'"
done <<'B1MUTANTS'
ignores a wrong has_fix|s/^        if d.get("has_fix") is not WANT_HAS_FIX\[arm\]:$/        if False:/
lets a pool-128 run without preemption through|s/^        if pool == PREEMPT_POOL and d.get("preemptions") == 0:$/        if False:/
ignores a run's exit status|s/^        if run\["exit"\] != 0:$/        if False:/
ignores b1's STOPPED|s/^    for name in ("NOT_RUN", "STOPPED"):$/    for name in ("NOT_RUN",):/
rounds the values it prints|s/{json.dumps(d.get(k))}" for k in FIELDS) + f" (expected_keys=/{json.dumps(round(d.get(k), 2) if isinstance(d.get(k), float) else d.get(k))}" for k in FIELDS) + f" (expected_keys=/
drops the verbatim JSON|s/^        lines.extend("    " + x for x in run\["raw"\].rstrip("\\n").split("\\n"))$/        pass/
lets a preempting pool-2304 control through|s/^        if pool == CONTROL_POOL and d.get("preemptions") != 0:$/        if False:/
misses the metadata server running short of pages|s/^        if short:$/        if False:/
lets a run that stored too few keys through|s/^        elif run\["expected_keys"\] is not None and d\["stored_keys"\] < run\["expected_keys"\]:$/        elif False:/
leaves the warm-up out of the expected keys|s/ + (WARMUP_PROMPT_TOKENS + out - 1) \/\/ BENCH_BLOCK_SIZE$//
takes a JSON without stored_keys|s/^        if "stored_keys" not in d:$/        if False:/
calls an invalid b1 valid|s/^    elif rec\["invalid"\]:$/    elif False:/
B1MUTANTS

# ---------------------------------------------------------------- the runner: refusals before any AWS call
check "the runner refuses g6, which the SCP blocks, and takes g5.2xlarge" \
  "! INSTANCE_TYPE=g6.xlarge bash '$S' --print-schedule >'$WORK/g6.out' 2>&1 && INSTANCE_TYPE=g5.2xlarge bash '$S' --print-schedule >'$WORK/g52.out' 2>&1"
mkdir -p "$WORK/awsbin"
cat >"$WORK/awsbin/aws" <<'EOF'
#!/bin/bash
echo "aws $*" >> "$AWS_CALLS"
case "$1 $2" in "sts get-caller-identity") echo 000000000000 ;; esac
exit 0
EOF
chmod +x "$WORK/awsbin/aws"
export AWS_CALLS="$WORK/aws-calls"
session() {
  : >"$AWS_CALLS"
  ( cd "$1" && env PATH="$WORK/awsbin:$PATH" AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null SESSION_CONFIRM=yes OUT="$2" \
    SCRATCH="$WORK" bash hack/gpu-kit-session.sh "$KITREL" >"$WORK/session.out" 2>&1 )
}
# A clone of a linked worktree checks out the main repository's HEAD, so this tree's own commit is checked out by its SHA.
git clone -q "$ROOT" "$WORK/clone" 2>"$WORK/clone.err" && git -C "$WORK/clone" checkout -q "$(git -C "$ROOT" rev-parse HEAD)" 2>>"$WORK/clone.err"
if [ -f "$WORK/clone/$KITREL/run.sh" ] && [ -f "$WORK/clone/hack/gpu-kit-session.sh" ]; then
  echo junk >"$WORK/clone/hack/untracked.txt"
  session "$WORK/clone" "$WORK/out-dirty"; rc=$?
  check "the runner refuses a tree with an untracked file before any AWS call" "[ $rc != 0 ] && command grep -qF 'working tree is dirty' '$WORK/session.out' && [ ! -s '$AWS_CALLS' ]"
  rm "$WORK/clone/hack/untracked.txt"
  session "$WORK/clone" "$WORK/out-clean"; rc=$?
  check "the same clone, clean, gets past the tree checks to the (fake) account check and buys nothing" \
    "[ $rc != 0 ] && command grep -q '^aws sts get-caller-identity' '$AWS_CALLS' && command grep -qF 'the account check failed' '$WORK/session.out' \
     && ! command grep -q '^aws ec2 run-instances' '$AWS_CALLS'"
else
  check "the kit and the runner are committed at HEAD, so the runner checks can run ($(cat "$WORK/clone.err"))" "false"
fi

# The session ships the kit directory as committed, so this test must leave nothing in it or beside its own scripts.
check "the kit directory and the fakes hold no bytecode or other untracked file after the run" \
  "[ -z \"\$(git -C '$ROOT' status --porcelain --untracked-files=all --ignored -- '$KITREL' hack/vllm-hf3fs-preemption-fake hack/vllm-hf3fs-preemption-kit-check.py)\" ]"

echo
if [ "$failures" = 0 ]; then echo "all checks passed"; else echo "$failures check(s) failed" >&2; exit 1; fi
