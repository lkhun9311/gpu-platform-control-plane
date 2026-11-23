#!/usr/bin/env bash
#
# Offline checks for the vLLM HF3FS preemption kit p6 in docs/oss/vllm-hf3fs-preemption/kit-p6, run before any GPU is bought.
# Kit p6 runs FIX alone, the PR head 4ec2f316 with gathers.patch (the runtime session's 23884c5eb2), and then its bench arm b2 on the same tree.
# This test checks:
#   both patches and bench_preempt_v2.py by their full sha256, the gathers patch and the bench against the prefixes and suffixes given;
#   that git am of both onto the base gives the PR head's tree and then 23884c5eb2's, against the commits in VLLM_SRC;
#   the same wheel and blocking-path check as kit p5, and kits p1 to p5 left as committed;
#   vLLM's startup check and the reset check on the patched test file, in the CPU vLLM environment CPU_VLLM_PY;
#   the verdict (FIX alone, every held-save page error 0.0) and b2's report (the runtime session's rules of 2026-11-23) on built logs;
#   run.sh end to end on fakes, and a mutant for each guard and rule, which must be caught.
# No GPU, no network and no AWS: python, pytest and the bench are the fakes in hack/vllm-hf3fs-preemption-fake,
# hf and nvidia-smi are the fakes in hack/vllm-69058-fake, and aws is a fake that records its calls.
# The runner checks need the kit committed, since the session ships a commit; they clone this tree's HEAD.
#
#   VLLM_SRC=/path/to/vllm [CPU_VLLM_PY=/path/to/cpu-venv/bin/python] bash hack/vllm-hf3fs-preemption-p6-kit-test.sh
set -uo pipefail
unset INSTANCE_TYPE KIT_ENV SESSION_CONFIRM AWS_PROFILE
# The checks assert the kit's and the fakes' defaults, so a caller's settings must not reach them.
unset P6 B2 B2_CAP_S P5 B1 B1_CAP_S FAKE_B1 FAKE_B1_LOG FAKE_BENCH_V2 BUDGET_S ARM_CAP_S CASE_CAP_S E2E_CAP_S UNIT_CAP_S PYTEST_CAP_S LLM_CAP_S \
  KIT_DRY_RUN KIT_OFFLINE_TEST OFFLINE_VLLM_SRC OFFLINE_MODEL_BIN_SHA256 FAKE_MODE FAKE_CUDA FAKE_HF FAKE_HF_DIR FAKE_NVSMI FAKE_ORDER_LOG \
  FAKE_EXPECT_OFFLINE HF_HUB_OFFLINE TRANSFORMERS_OFFLINE VLLM_ENABLE_V1_MULTIPROCESSING CUDA_LAUNCH_BLOCKING
# Python must not leave bytecode beside a mutant, where a same-size edit restored within a second could reuse it.
export PYTHONDONTWRITEBYTECODE=1
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KITREL=docs/oss/vllm-hf3fs-preemption/kit-p6
KIT="$ROOT/$KITREL"
KIT5REL=docs/oss/vllm-hf3fs-preemption/kit-p5
STARTUP="$ROOT/hack/vllm-hf3fs-preemption-startup-check.py"
CPU_VLLM_PY="${CPU_VLLM_PY:-$HOME/workspace/oss/vllm/.venv-cpu/bin/python}"
FAKES="$ROOT/hack/vllm-hf3fs-preemption-fake"
TOOLFAKES="$ROOT/hack/vllm-69058-fake"
CHECK="$ROOT/hack/vllm-hf3fs-preemption-p6-kit-check.py"
SRC="${VLLM_SRC:-$HOME/workspace/oss/vllm}"
BASE=0e3c8dbdae9d55149b0fba4e6c1014b4b08c9c73
BASE_TREE=e6819e279d40268d45eee2bfa134d5d04b05e53f
WHEEL=e2052f5c7ad64564f00dd4592e77c27785c9333f
PR_HEAD=4ec2f316fb847673a5edb3ce337a0abae9263899
PR_HEAD_TREE=441714150d9afe8fd27523f66f288568e8a8c1e8
P6_COMMIT=23884c5eb20699e463f177d06d0ecde297fb3e46
FIX_TREE=e7475ec46141b6764a1cf9874bcd7efa1e7003db
TEST_BLOB=b5edb870ccf6d8e90634ee652b275cb6d7ed58e8
TF=tests/v1/kv_connector/unit/test_hf3fs_preemption.py
FIX_SHA256=8da42418ce7bcd85a85c19067a8c4da2dece1dbb485b765e0471759abed30eb6
GATHERS_SHA256=ae802dc58d3eda026d09b1f5ec201f74dde9bd4e871dcd8c918554dd1029b1cd
BENCH_SHA256=7dee7790119fd3ee5db8b59116d1fe4266fea639847286f7dce8daa1085907f3
STORE="$HOME/workspace/storage/open-source/contributions/vllm/hf3fs-preemption-save"
GATHERS_SRC="$STORE/p6/0001-Bugfix-KV-Connector-Wait-only-for-HF3FS-gathers-of-p.patch"
BENCH_SRC="$STORE/bench/bench_preempt_v2.py"
B2_ORDER_WANT="fix-128 fix-128 fix-128 fix-2304"
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
check "the kit's Python, the fakes and the checker compile" \
  "python3 -I -X pycache_prefix='$WORK/pyc' -m py_compile '$KIT/verdict.py' '$KIT/b2_verdict.py' '$KIT/bench_preempt_v2.py' '$KIT/envprobe.py' '$FAKES/pytest_p1.py' '$FAKES/bench_b1.py' '$CHECK'"

# ---------------------------------------------------------------- the pins
check "the kit holds both patches, the bench, the two verdicts, run.sh and envprobe.py, and nothing else" \
  "[ \"\$(ls '$KIT' | paste -sd' ')\" = 'b2_verdict.py bench_preempt_v2.py envprobe.py fix-and-tests.patch gathers.patch run.sh verdict.py' ]"
check "gathers.patch has the pinned sha256, which starts ae802dc5 and ends 29b1cd as the runtime session gave it" \
  "[ \"\$(sha256sum '$KIT/gathers.patch' | cut -d' ' -f1)\" = $GATHERS_SHA256 ] && [ \${GATHERS_SHA256:0:8} = ae802dc5 ] && [ \${GATHERS_SHA256: -6} = 29b1cd ]"
check "bench_preempt_v2.py has the pinned sha256, which starts 7dee7790 and ends 5907f3 as the runtime session gave it" \
  "[ \"\$(sha256sum '$KIT/bench_preempt_v2.py' | cut -d' ' -f1)\" = $BENCH_SHA256 ] && [ \${BENCH_SHA256:0:8} = 7dee7790 ] && [ \${BENCH_SHA256: -6} = 5907f3 ]"
check "fix-and-tests.patch and envprobe.py are kit p5's, byte for byte, and fix-and-tests.patch has kit p5's sha256" \
  "cmp -s '$ROOT/$KIT5REL/fix-and-tests.patch' '$KIT/fix-and-tests.patch' && cmp -s '$ROOT/$KIT5REL/envprobe.py' '$KIT/envprobe.py' \
   && [ \"\$(sha256sum '$KIT/fix-and-tests.patch' | cut -d' ' -f1)\" = $FIX_SHA256 ]"
check "run.sh pins both patches, the base by commit and tree, the PR head and its tree, 23884c5eb2's tree, the test blob, the bench and the wheel" \
  "command grep -qx 'FIX_PATCH_SHA256=$FIX_SHA256' '$KIT/run.sh' && command grep -qx 'GATHERS_PATCH_SHA256=$GATHERS_SHA256' '$KIT/run.sh' \
   && command grep -qx 'BASE_SHA=$BASE' '$KIT/run.sh' && command grep -qx 'BASE_TREE=$BASE_TREE' '$KIT/run.sh' \
   && command grep -qx 'PR_HEAD=$PR_HEAD' '$KIT/run.sh' && command grep -qx 'PR_HEAD_TREE=$PR_HEAD_TREE' '$KIT/run.sh' \
   && command grep -qx 'P6_COMMIT=$P6_COMMIT' '$KIT/run.sh' && command grep -qx 'FIX_TREE=$FIX_TREE' '$KIT/run.sh' \
   && command grep -qx 'TEST_BLOB=$TEST_BLOB' '$KIT/run.sh' && command grep -qx 'BENCH_SHA256=$BENCH_SHA256' '$KIT/run.sh' \
   && command grep -qx 'WHEEL_COMMIT=$WHEEL' '$KIT/run.sh'"
for pair in "$GATHERS_SRC:gathers.patch" "$BENCH_SRC:bench_preempt_v2.py"; do
  src=${pair%:*} dst=${pair##*:}
  if [ -f "$src" ]; then
    check "the kit's $dst is byte for byte storage's $src" "cmp -s '$KIT/$dst' '$src'"
  else
    echo "skip $src is gone; the sha256 pin stands"
  fi
done
check "kits p1 to p5 are left as committed" \
  "git -C '$ROOT' diff --quiet HEAD -- docs/oss/vllm-hf3fs-preemption/kit-p1 docs/oss/vllm-hf3fs-preemption/kit-p2 docs/oss/vllm-hf3fs-preemption/kit-p3 docs/oss/vllm-hf3fs-preemption/kit-p4 '$KIT5REL'"
if git -C "$SRC" cat-file -e "$BASE^{commit}" 2>"$WORK/src.err"; then
  check "the local base has the pinned tree, and its first parent is the wheel commit with no blocking-path change" \
    "[ \"\$(git -C '$SRC' rev-parse $BASE^{tree})\" = $BASE_TREE ] && [ \"\$(git -C '$SRC' rev-parse $BASE^1)\" = $WHEEL ] \
     && [ -z \"\$(git -C '$SRC' diff --no-renames --name-only $WHEEL $BASE -- csrc cmake CMakeLists.txt pyproject.toml vllm/_custom_ops.py vllm/_cpu_ops.py)\" ]"
else
  check "the local repository holds the base 0e3c8dbdae ($(cat "$WORK/src.err"))" "false"
fi
if git -C "$SRC" cat-file -e "$P6_COMMIT^{commit}" 2>"$WORK/p6.err" && git -C "$SRC" cat-file -e "$PR_HEAD^{commit}" 2>>"$WORK/p6.err"; then
  check "23884c5eb2 has the PR head as its parent and the pinned tree, and the PR head the base and its pinned tree" \
    "[ \"\$(git -C '$SRC' rev-parse $P6_COMMIT^)\" = $PR_HEAD ] && [ \"\$(git -C '$SRC' rev-parse $P6_COMMIT^{tree})\" = $FIX_TREE ] \
     && [ \"\$(git -C '$SRC' rev-parse $PR_HEAD^)\" = $BASE ] && [ \"\$(git -C '$SRC' rev-parse $PR_HEAD^{tree})\" = $PR_HEAD_TREE ]"
  git -C "$SRC" worktree add -q --detach "$WORK/apply" "$BASE" >"$WORK/apply.log" 2>&1 \
    && git -C "$WORK/apply" -c user.name=kit -c user.email=kit@localhost -c commit.gpgsign=false am -q "$KIT/fix-and-tests.patch" >>"$WORK/apply.log" 2>&1
  t1=$(git -C "$WORK/apply" rev-parse HEAD^{tree} 2>/dev/null)
  git -C "$WORK/apply" -c user.name=kit -c user.email=kit@localhost -c commit.gpgsign=false am -q "$KIT/gathers.patch" >>"$WORK/apply.log" 2>&1
  check "git am of both patches on the base gives the PR head's tree and then 23884c5eb2's: git diff --quiet against it is clean" \
    "[ '$t1' = $PR_HEAD_TREE ] && git -C '$WORK/apply' diff --quiet HEAD $P6_COMMIT && [ \"\$(git -C '$WORK/apply' rev-parse HEAD^{tree})\" = $FIX_TREE ] \
     && [ \"\$(git -C '$WORK/apply' rev-parse HEAD:$TF)\" = $TEST_BLOB ]"
  git -C "$SRC" worktree remove --force "$WORK/apply" >>"$WORK/apply.log" 2>&1
else
  check "the local repository holds the PR head and 23884c5eb2 ($(cat "$WORK/p6.err"))" "false"
fi

# ---------------------------------------------------------------- vLLM's startup check and the reset check, on the patched test file
# startup NAME [SED]: the base with both patches, the test file edited by SED if given, then the startup check with --reset.
startup() {
  local n=$1 sedexpr=${2:-} a="$WORK/apply"
  [ -e "$a" ] && git -C "$SRC" worktree remove --force "$a" >>"$WORK/apply.log" 2>&1
  git -C "$SRC" worktree add -q --detach "$a" "$BASE" >>"$WORK/apply.log" 2>&1 \
    && git -C "$a" -c user.name=kit -c user.email=kit@localhost -c commit.gpgsign=false am -q "$KIT/fix-and-tests.patch" "$KIT/gathers.patch" >>"$WORK/apply.log" 2>&1 || return 9
  if [ -n "$sedexpr" ]; then
    cp "$a/$TF" "$WORK/startup-orig.py" && sed -i "$sedexpr" "$a/$TF" || return 9
    cmp -s "$WORK/startup-orig.py" "$a/$TF" && { echo "the startup mutant $n changed nothing" >"$WORK/startup-$n.log"; return 9; }
  fi
  ( cd "$a" && env -i PATH="$PATH" HOME="$HOME" TMPDIR="$TMPDIR" HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 PYTHONPATH="$a" PYTHONDONTWRITEBYTECODE=1 \
    timeout --kill-after=5 300 "$CPU_VLLM_PY" -B "$STARTUP" "$a" "$MODEL_REV" --reset ) >"$WORK/startup-$n.log" 2>"$WORK/startup-$n.err"
}
sl() { command grep -qF -- "$2" "$WORK/startup-$1.log"; }
MODEL_REV=$(sed -n 's/^MODEL_REV=\([0-9a-f]\{40\}\)$/\1/p' "$KIT/run.sh")
if [ -x "$CPU_VLLM_PY" ] && [ -n "$MODEL_REV" ]; then
  startup pinned; rc=$?
  check "startup and reset: vLLM accepts the patched test's max_model_len 736 with 48 blocks, and its bounded reset frees after 3 steps and fails after 50" \
    "[ $rc = 0 ] && sl pinned 'ok   vLLM'\"'\"'s get_kv_cache_configs accepts max_model_len 736 with num_gpu_blocks_override=48' \
     && sl pinned 'ok   _reset_prefix_cache is bounded' && sl pinned 'took 3' && sl pinned 'took 50' && sl pinned 'startup check passed'"
  [ $rc = 0 ] || tail -n 5 "$WORK/startup-pinned.log" "$WORK/startup-pinned.err" >&2
  startup m1024 's/^MAX_MODEL_LEN = 736$/MAX_MODEL_LEN = 1024/'; rc=$?
  check "startup mutant: MAX_MODEL_LEN 1024 is refused by vLLM's own check" "[ $rc = 1 ] && sl m1024 'FAIL vLLM'\"'\"'s get_kv_cache_configs accepts max_model_len 1024'"
  startup mbare 's/^            _reset_prefix_cache(llm)$/            assert llm.reset_prefix_cache()/'; rc=$?
  check "reset mutant: the bare assert is caught" "[ $rc = 1 ] && sl mbare 'FAIL no bare assert on llm.reset_prefix_cache() is left in the test'"
  git -C "$SRC" worktree remove --force "$WORK/apply" >>"$WORK/apply.log" 2>&1
else
  check "the CPU vLLM environment $CPU_VLLM_PY is there and run.sh pins MODEL_REV, so the startup check can run" "false"
fi

# ---------------------------------------------------------------- the Python units
python3 -I "$CHECK" "$KIT" "$FAKES" >"$WORK/units.log" 2>&1; rc=$?
check "the unit checks pass ($(command grep -c '^ok' "$WORK/units.log") ok, $(command grep -c '^FAIL' "$WORK/units.log") failed)" "[ $rc = 0 ]"
command grep '^FAIL' "$WORK/units.log" >&2

# ---------------------------------------------------------------- run.sh's settings
dry() {
  local k=$1; shift
  rm -rf "$WORK/dry"
  env -i PATH="$PATH" HOME="$HOME" KIT_DRY_RUN=1 OUT="$WORK/dry" "$@" bash "$k/run.sh" >"$WORK/dry.out" 2>&1
}
check "the default settings: budget 1200, the test arm 600 and FIX alone with the runtime session's command, b2 on, four b2 runs" \
  "dry '$KIT' && command grep -qx 'budget_s=1200' '$WORK/dry/settings.txt' && command grep -qx 'p6_budget_s=600' '$WORK/dry/settings.txt' \
   && command grep -qx 'arm_cap_s=300' '$WORK/dry/settings.txt' && command grep -qxF 'order=fix, each in its own process' '$WORK/dry/settings.txt' \
   && command grep -qxF 'command=python -m pytest $TF -q -s --tb=short' '$WORK/dry/settings.txt' && command grep -qx 'b2=1' '$WORK/dry/settings.txt' \
   && command grep -qF 'b2_order=fix:128:1 fix:128:2 fix:128:3 fix:2304:1, each in its own process' '$WORK/dry/settings.txt' \
   && command grep -qx 'control=none: kit p5'\"'\"'s, unchanged by gathers.patch' '$WORK/dry/settings.txt'"
check "BUDGET_S above 1200, P6 or B2 other than 0 or 1, P6=0 with B2=0, and B2_CAP_S under 30 are refused; P6=0 alone is taken" \
  "! dry '$KIT' BUDGET_S=1201 && ! dry '$KIT' P6=2 && ! dry '$KIT' B2=2 && ! dry '$KIT' P6=0 B2=0 && ! dry '$KIT' B2_CAP_S=10 && dry '$KIT' P6=0"
m=$(mutant p6gate run.sh 's/^\[ "\$P6" = 1 \] || \[ "\$B2" = 1 \] ||/true ||/')
mcheck "mutant: a run.sh that takes P6=0 B2=0 is caught" "dry '$m' P6=0 B2=0"

# ---------------------------------------------------------------- the budget against the runner's rates
S="$ROOT/hack/gpu-kit-session.sh"
bring=$(sed -n 's/^BRINGUP_S=\([0-9]*\)$/\1/p' "$S")
upl=$(sed -n 's/^EVIDENCE_UPLOAD_S=\([0-9]*\)$/\1/p' "$S")
kitmax=$(sed -n 's/^BUDGET_MAX_S=\([0-9]*\)$/\1/p' "$KIT/run.sh")
for t in g5.xlarge:0.4098:0.8579 g5.2xlarge:0.4631:0.9696; do
  type=${t%%:*} want=$(echo "$t" | cut -d: -f2) backstop=${t##*:}
  rate=$(sed -n "s/^    $type) echo \"[0-9.]* \([0-9.]*\) [0-9]*\" ;;\$/\1/p" "$S")
  sched=$(INSTANCE_TYPE=$type bash "$S" --print-schedule 2>&1)
  tail_s=$(python3 -I -c 'import re,sys; d=dict(re.findall(r"(\w+)=([\w.]+)", sys.argv[1])); print(int(d["termination_s"]) - int(d["evidence_s"]))' "$sched")
  worst=$(python3 -I -c 'import sys; b,k,u,t,r = map(float, sys.argv[1:]); print(f"{(b + k + u + t) / 3600 * r:.4f} {int(b + k + u + t)}")' "${bring:-x}" "${kitmax:-x}" "${upl:-x}" "${tail_s:-x}" "${rate:-x}")
  check "$type: BUDGET_S at its maximum, $kitmax s, bills ${worst#* } s at \$$rate/h, \$${worst% *}, as run.sh's header says" \
    "[ '$worst' = '$want 1920' ] && command grep -qF '\$$want on $type' '$KIT/run.sh'"
  check "$type: the runner's own backstop stays \$$backstop, as run.sh's header says" "[[ '$sched' == *worst_case_usd=$backstop ]] && command grep -qF '\$$backstop on $type' '$KIT/run.sh'"
done

# ---------------------------------------------------------------- end to end on the fakes, with the real checkout and two real git ams
e2e() {
  local k=$1 n=$2; shift 2
  local d="$WORK/e2e-$n"
  mkdir -p "$d/cwd" "$d/hf"
  ( cd "$d/cwd" && timeout --kill-after=5 "${E2E_OUTER_S:-120}" env PATH="$FAKES:$TOOLFAKES:$PATH" KIT_OFFLINE_TEST=1 OFFLINE_VLLM_SRC="$SRC" \
    FAKE_HF_DIR="$d/hf" OFFLINE_MODEL_BIN_SHA256="$FAKE_BIN_SHA256" FAKE_ORDER_LOG="$d/order" FAKE_B1_LOG="$d/b2order" OUT="$d/out" "$@" bash "$k/run.sh" >"$d/run.log" 2>&1 )
}
v() { command grep -qx "VERDICT: $2" "$WORK/e2e-$1/out/verdict.txt"; }
vt() { command grep -qF -- "$2" "$WORK/e2e-$1/out/verdict.txt"; }
order() { [ -f "$WORK/e2e-$1/order" ] && paste -sd' ' "$WORK/e2e-$1/order"; }
b2() { command grep -qx "B2: $2" "$WORK/e2e-$1/out/b2/b2-verdict.txt"; }
b2t() { command grep -qF -- "$2" "$WORK/e2e-$1/out/b2/b2-verdict.txt"; }
b2order() { [ -f "$WORK/e2e-$1/b2order" ] && paste -sd' ' "$WORK/e2e-$1/b2order"; }
stopped() { [ -f "$WORK/e2e-$1/out/STOPPED" ] && command grep -qF -- "$2" "$WORK/e2e-$1/out/STOPPED"; }
# kept NAME: the test arm's CONFIRMED and exit 0 stand, with no run-wide STOPPED and one verdict, written before b2.
kept() { [ ! -e "$WORK/e2e-$1/out/STOPPED" ] && v "$1" CONFIRMED && [ "$(command grep -c '^verdict exit=0 ' "$WORK/e2e-$1/out/status.txt")" = 1 ]; }

e2e "$KIT" pass FAKE_EXPECT_OFFLINE=1; rc=$?
check "pass: FIX alone passes with every held-save page error 0.0, CONFIRMED, exit 0, its pytest summary printed verbatim" \
  "[ $rc = 0 ] && v pass CONFIRMED && vt pass '  pytest summary (verbatim): 1 passed, 20 warnings in 61.20s (0:01:01)' && vt pass 'held-save page errors: [0.0, 0.0, 0.0]' \
   && [ \"\$(order pass)\" = fix ] && ! [ -e '$WORK/e2e-pass/out/e2e-control.log' ]"
check "pass: the PR head and then 23884c5eb2's tree, the hook calling wait_for_gathers, no wait_for_saves, and the patched test blob" \
  "command grep -q '^pr_head commit=[0-9a-f]\{40\} tree=$PR_HEAD_TREE parent=$BASE\$' '$WORK/e2e-pass/out/versions.txt' \
   && command grep -q '^fix commit=[0-9a-f]\{40\} tree=$FIX_TREE parent=' '$WORK/e2e-pass/out/versions.txt' \
   && command grep -qx 'fix_defs handle_preemptions=1 wait_for_gathers=1 wait_for_saves=0 hook_calls_gathers=1' '$WORK/e2e-pass/out/versions.txt' \
   && command grep -qx 'fix test_blob=$TEST_BLOB' '$WORK/e2e-pass/out/versions.txt' && command grep -qx 'base_first_parent=$WHEEL wheel_commit=$WHEEL' '$WORK/e2e-pass/out/versions.txt'"
check "pass: b2 ran four FIX runs in order after the test, VALID, with b1's stored_keys beside each, and left no TMPDIR" \
  "[ \"\$(b2order pass)\" = '$B2_ORDER_WANT' ] && b2 pass VALID && kept pass && b2t pass 'stored_keys 1883 beside b1 at pool 128: CONTROL 1882/1883/1883, FIX 1883/1883/1883' \
   && b2t pass 'fix_wait=\"wait_for_gathers\"' && ! [ -e '$WORK/e2e-pass/cwd/b2-tmp' ] && ( cd '$WORK/e2e-pass/out' && sha256sum -c --quiet SHA256SUMS )"
for kind in fixnonzero:5:INCONCLUSIVE fixnotimeout:5:INCONCLUSIVE fixprecond:5:INCONCLUSIVE fixmismatch:2:FINDING fixfault:2:FINDING fixother:2:FINDING \
  fixload:4:'NOT RUN' skip:3:INCOMPLETE nosummary:3:INCOMPLETE; do
  k=${kind%%:*} rest=${kind#*:} want_rc=${rest%%:*} want=${rest#*:}
  e2e "$KIT" "$k" FAKE_MODE="$k" B2=0; rc=$?
  check "$k: the run is $want, exit $want_rc" "[ $rc = $want_rc ] && v $k '$want'"
done
for k in nofixwait:INCOMPLETE zeropreemptfix:INVALID savefail:INVALID storageshort:INVALID keysoff:INVALID keys2304:INVALID preempt2304:INVALID hasfixfix:'NOT RUN'; do
  mode=${k%%:*} want=${k#*:}
  e2e "$KIT" "b2-$mode" FAKE_B1="$mode"; rc=$?
  check "b2 $mode: b2 is $want, and the test arm's CONFIRMED and exit 0 stand" "[ $rc = 0 ] && kept b2-$mode && b2 b2-$mode '$want'"
done
check "b2 hasfixfix: a wrong has_fix stops b2 after its first run" "[ \"\$(b2order b2-hasfixfix)\" = fix-128 ] && [ -s '$WORK/e2e-b2-hasfixfix/out/b2/NOT_RUN' ]"
check "b2 keys2304: the pool-2304 rule (c) is what fires" "b2t b2-keys2304 'fix-2304-1: (c) stored_keys=2002, not exactly 2003'"
check "b2 savefail: rule (a) fires on the failed write" "b2t b2-savefail 'fix-128-2: (a) 1 save failure lines'"
check "b2 keysoff: rule (b) fires on 1,800 keys" "b2t b2-keysoff 'fix-128-3: (b) stored_keys=1800'"
t0=$(date +%s); E2E_OUTER_S=260 e2e "$KIT" b2-hang FAKE_B1=hang BUDGET_S=200 B2_CAP_S=30; rc=$?; took=$(( $(date +%s) - t0 ))
check "b2 hang: b2 runs out of budget and stops alone while the test arm's verdict and exit 0 stand; run.sh ends inside BUDGET_S ($took s)" \
  "[ $rc = 0 ] && kept b2-hang && b2 b2-hang INCOMPLETE && command grep -qF 'the budget ran out before b2-' '$WORK/e2e-b2-hang/out/b2/STOPPED' && [ $took -le 200 ]"
e2e "$KIT" b2-only P6=0; rc=$?
check "P6=0: no test process, all four b2 runs, and run.sh exits with b2's VALID, 0" \
  "[ $rc = 0 ] && b2 b2-only VALID && ! [ -s '$WORK/e2e-b2-only/order' ] && ! [ -e '$WORK/e2e-b2-only/out/verdict.txt' ] && [ \"\$(b2order b2-only)\" = '$B2_ORDER_WANT' ]"
e2e "$KIT" b2-only-invalid P6=0 FAKE_B1=keys2304; rc=$?
check "P6=0 with an invalid b2 exits 6" "[ $rc = 6 ] && b2 b2-only-invalid INVALID"
for p in gathers fix-and-tests; do
  cp -r "$KIT" "$WORK/tampered-$p" && printf '\n' >>"$WORK/tampered-$p/$p.patch"
  e2e "$WORK/tampered-$p" "tampered-$p"; rc=$?
  check "a $p.patch that is not the pinned one stops the run before any checkout" \
    "[ $rc = 1 ] && stopped tampered-$p '$p.patch has sha256' && ! command grep -q '^worktree-vllm' '$WORK/e2e-tampered-$p/out/status.txt'"
done
cp -r "$KIT" "$WORK/tampered-bench" && printf '\n' >>"$WORK/tampered-bench/bench_preempt_v2.py"
e2e "$WORK/tampered-bench" tampered-bench; rc=$?
check "a bench_preempt_v2.py that is not the pinned one stops b2 alone, and the verdict stands" \
  "[ $rc = 0 ] && kept tampered-bench && command grep -qF 'bench_preempt_v2.py has sha256' '$WORK/e2e-tampered-bench/out/b2/STOPPED' && ! [ -s '$WORK/e2e-tampered-bench/b2order' ]"

# ---------------------------------------------------------------- mutants of run.sh, caught end to end
m=$(mutant gatherspin run.sh 's/^\[ "\$got_gathers" = "\$GATHERS_PATCH_SHA256" \] ||/true ||/')
[ -n "$m" ] && cp "$WORK/tampered-gathers/gathers.patch" "$m/" && e2e "$m" m-gatherspin
mcheck "mutant: a run.sh that skips gathers.patch's sha256 pin is caught" "! stopped m-gatherspin 'gathers.patch has sha256'"
m=$(mutant wrongsha run.sh 's/^GATHERS_PATCH_SHA256=ae802dc5.*$/GATHERS_PATCH_SHA256=0000000000000000000000000000000000000000000000000000000000000000/')
[ -n "$m" ] && e2e "$m" m-wrongsha
mcheck "mutant: a wrong gathers.patch sha256 pin stops the run" "stopped m-wrongsha 'not the pinned 00000000'"
m=$(mutant nofixtree run.sh 's/^FIX_TREE=e7475ec46141b6764a1cf9874bcd7efa1e7003db$/FIX_TREE=0000000000000000000000000000000000000000/; s/^\[ "\$tree" = "\$FIX_TREE" \] ||/true ||/')
[ -n "$m" ] && e2e "$m" m-nofixtree
mcheck "mutant: a run.sh without the fix's tree check is caught" "! stopped m-nofixtree 'not the pinned 0000000'"
m=$(mutant otherfixtree run.sh 's/^FIX_TREE=e7475ec46141b6764a1cf9874bcd7efa1e7003db$/FIX_TREE=0000000000000000000000000000000000000000/')
[ -n "$m" ] && e2e "$m" m-otherfixtree
mcheck "a fix tree that is not 23884c5eb2's stops the run before any test" "stopped m-otherfixtree 'not the pinned 0000000' && ! [ -s '$WORK/e2e-m-otherfixtree/order' ]"
m=$(mutant controlsneaks run.sh 's/^RUNS=(fix)$/RUNS=(control fix)/')
[ -n "$m" ] && e2e "$m" m-controlsneaks
mcheck "mutant: a CONTROL arm sneaking into the test runs is refused, and does not report CONFIRMED" "stopped m-controlsneaks 'runs FIX alone' && ! v m-controlsneaks CONFIRMED"
m=$(mutant controlsneaksunguarded run.sh 's/^RUNS=(fix)$/RUNS=(control fix)/; s/^  \[ "\$1" = fix \] ||/  true ||/')
[ -n "$m" ] && e2e "$m" m-controlsneaksunguarded
mcheck "mutant: a CONTROL arm past the arm guard leaves a CONTROL log, which the verdict refuses" \
  "[ -f '$WORK/e2e-m-controlsneaksunguarded/out/verdict.txt' ] && ! v m-controlsneaksunguarded CONFIRMED && vt m-controlsneaksunguarded 'a CONTROL arm ran'"
# A FIX that is the PR head without gathers.patch, with the tree pin and parent check moved to let it through, still has wait_for_saves:
# the definitions check must stop it, and a run.sh without that check must not.
skipg='s/^step git-am-gathers 60 --log "\$OUT\/git-am-gathers.log" git -C vllm .* am -q "\$GATHERS_PATCH" ||$/true ||/; s/^FIX_TREE=e7475ec46141b6764a1cf9874bcd7efa1e7003db$/FIX_TREE=441714150d9afe8fd27523f66f288568e8a8c1e8/; s/^\[ "\$parent" = "\$HEAD1" \] ||/true ||/'
m=$(mutant nogathers run.sh "$skipg")
[ -n "$m" ] && e2e "$m" m-nogathers
mcheck "a FIX without wait_for_gathers, past the tree pin, is stopped by the definitions check" \
  "stopped m-nogathers 'wait_for_gathers 0, wait_for_saves 1' && ! [ -s '$WORK/e2e-m-nogathers/order' ]"
m=$(mutant nogathersdefs run.sh "$skipg; s/^\[ \"\\\$n_hook\" = 1 \] && \[ \"\\\$n_gathers\" = 1 \] && \[ \"\\\$n_saves\" = 0 \] && \[ \"\\\$n_calls\" = 1 \] ||\$/true ||/")
[ -n "$m" ] && e2e "$m" m-nogathersdefs
mcheck "mutant: a run.sh without the definitions check runs the PR head as if it were the gather-only one, and is caught" \
  "! stopped m-nogathersdefs 'wait_for_gathers 0, wait_for_saves 1'"
m=$(mutant b2nopreflight run.sh 's/^    if \[ -n "\$got" \] && \[ "\$got" != "\$want" \]; then$/    if false; then/')
[ -n "$m" ] && e2e "$m" m-b2nopreflight FAKE_B1=hasfixfix
mcheck "mutant: a run.sh without b2's has_fix preflight runs on past a wrong tree, and is caught" "[ \"\$(b2order m-b2nopreflight)\" != fix-128 ]"
m=$(mutant b2stopall run.sh 's/^  if \[ "\$PHASE" = b2 \]; then$/  if false; then/')
[ -n "$m" ] && E2E_OUTER_S=260 e2e "$m" m-b2stopall FAKE_B1=hang BUDGET_S=200 B2_CAP_S=30
mcheck "mutant: a b2 stop that writes the run-wide STOPPED is caught" "! kept m-b2stopall"

# ---------------------------------------------------------------- mutants of verdict.py and b2_verdict.py, caught by the unit checks
caught() { ! python3 -I "$CHECK" "$1" "$FAKES" >"$WORK/mutant.log" 2>&1; }
while IFS='|' read -r file name sedexpr; do
  [ -n "$file" ] || continue
  m=$(mutant "$file-$name" "$file" "$sedexpr")
  mcheck "mutant: $file $name is caught" "caught '$m'"
done <<'MUTANTS'
verdict.py|lets a nonzero held-save error confirm|s/^    elif any(e != 0.0 for e in fix\["errors"\]):$/    elif False:/
verdict.py|confirms without the hold timing out|s/^    elif fix\["hold_timed_out"\] is not True:$/    elif False:/
verdict.py|lets a CONTROL log through|s/^    if os.path.exists(os.path.join(out, "e2e-control.log")) or any(line.startswith("test-control ") for line in _status(out)):$/    if False:/
verdict.py|calls a FIX failure before the comparison no finding|s/^    if fix\["gpu"\] in ("faulted", "mismatch", "failed"):$/    if fix["gpu"] in ("faulted", "mismatch"):/
verdict.py|lets a 0.07 held-save error pass|s/^    elif fix\["max_error"\] is not None and fix\["max_error"\] >= ERROR_LIMIT:$/    elif False:/
verdict.py|drops the verbatim pytest summary|s/^        lines.append(f"  pytest summary (verbatim): {p.get('summary_raw')}")$/        pass/
b2_verdict.py|misses the save failure lines (a)|s/^SAVE_FAILURE_RE = re.compile(.*$/SAVE_FAILURE_RE = re.compile(r"NEVER MATCHES")/
b2_verdict.py|misses only Write operation failed (a)|s/|Write operation failed|/|/
b2_verdict.py|misses the only-allocated line (a)|s/^SHORT_RE = re.compile(.*$/SHORT_RE = re.compile(r"NEVER MATCHES")/
b2_verdict.py|drops the 1% rule (b)|s/^        if not lo <= keys <= hi:$/        if False:/
b2_verdict.py|widens the 1% rule to 10% (b)|s/^B1_TOLERANCE = 0.01$/B1_TOLERANCE = 0.1/
b2_verdict.py|drops the exact 2,003 rule at pool 2304 (c)|s/^        if pool == CONTROL_POOL and keys != CONTROL_POOL_KEYS:$/        if False:/
b2_verdict.py|lets a preempting pool-2304 run through|s/^        if pool == CONTROL_POOL and d.get("preemptions") != 0:$/        if False:/
b2_verdict.py|lets a pool-128 run without preemption through|s/^        if pool == PREEMPT_POOL and d.get("preemptions") == 0:$/        if False:/
b2_verdict.py|takes a JSON without fix_wait|s/^        if "fix_wait" not in d:$/        if False:/
b2_verdict.py|takes wait_for_saves as the gather-only head|s/^FIX_WAIT = "wait_for_gathers"$/FIX_WAIT = "wait_for_saves"/
b2_verdict.py|rounds the values it prints|s/{json.dumps(d.get(k))}" for k in FIELDS))$/{json.dumps(round(d.get(k), 2) if isinstance(d.get(k), float) else d.get(k))}" for k in FIELDS))/
MUTANTS

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
  "[ -z \"\$(git -C '$ROOT' status --porcelain --untracked-files=all --ignored -- '$KITREL' hack/vllm-hf3fs-preemption-fake '$CHECK')\" ]"

echo
if [ "$failures" = 0 ]; then echo "all checks passed"; else echo "$failures check(s) failed" >&2; exit 1; fi
