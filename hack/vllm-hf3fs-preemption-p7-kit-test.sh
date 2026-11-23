#!/usr/bin/env bash
#
# Offline checks for the vLLM HF3FS preemption kit p7 in docs/oss/vllm-hf3fs-preemption/kit-p7, run before any GPU is bought.
# Kit p7 runs CONTROL (p6's code, 23884c5eb2, with only 7528cc07's test file) and then FIX (the PR head 7528cc07, which fences partial gathers).
# This test checks:
#   fence.patch by its full sha256, against the prefix and suffix given, and the three git ams against 7528cc07 fetched into VLLM_SRC;
#   CONTROL's tree, the same wheel and blocking-path check as kits p5 and p6, and kits p1 to p6 left as committed;
#   vLLM's startup check and the reset check on the new test file, in the CPU vLLM environment CPU_VLLM_PY;
#   the verdict on built logs, and run.sh end to end on fakes, with a mutant for each guard and rule, which must be caught.
# No GPU, no network and no AWS: python and pytest are the fakes in hack/vllm-hf3fs-preemption-fake (pytest_p7.py for this file),
# hf and nvidia-smi are the fakes in hack/vllm-69058-fake, and aws is a fake that records its calls.
# The runner checks need the kit committed, since the session ships a commit; they clone this tree's HEAD.
#
#   VLLM_SRC=/path/to/vllm [CPU_VLLM_PY=/path/to/cpu-venv/bin/python] bash hack/vllm-hf3fs-preemption-p7-kit-test.sh
set -uo pipefail
unset INSTANCE_TYPE KIT_ENV SESSION_CONFIRM AWS_PROFILE
# The checks assert the kit's and the fakes' defaults, so a caller's settings must not reach them.
unset P6 B2 B2_CAP_S P5 B1 B1_CAP_S FAKE_B1 FAKE_B1_LOG FAKE_BENCH_V2 BUDGET_S ARM_CAP_S CASE_CAP_S E2E_CAP_S UNIT_CAP_S PYTEST_CAP_S LLM_CAP_S \
  KIT_DRY_RUN KIT_OFFLINE_TEST OFFLINE_VLLM_SRC OFFLINE_MODEL_BIN_SHA256 FAKE_MODE FAKE_CUDA FAKE_HF FAKE_HF_DIR FAKE_NVSMI FAKE_ORDER_LOG \
  FAKE_EXPECT_OFFLINE HF_HUB_OFFLINE TRANSFORMERS_OFFLINE VLLM_ENABLE_V1_MULTIPROCESSING CUDA_LAUNCH_BLOCKING
# Python must not leave bytecode beside a mutant, where a same-size edit restored within a second could reuse it.
export PYTHONDONTWRITEBYTECODE=1
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KITREL=docs/oss/vllm-hf3fs-preemption/kit-p7
KIT="$ROOT/$KITREL"
KIT6REL=docs/oss/vllm-hf3fs-preemption/kit-p6
STARTUP="$ROOT/hack/vllm-hf3fs-preemption-startup-check.py"
CPU_VLLM_PY="${CPU_VLLM_PY:-$HOME/workspace/oss/vllm/.venv-cpu/bin/python}"
FAKES="$ROOT/hack/vllm-hf3fs-preemption-fake"
TOOLFAKES="$ROOT/hack/vllm-69058-fake"
CHECK="$ROOT/hack/vllm-hf3fs-preemption-p7-kit-check.py"
SRC="${VLLM_SRC:-$HOME/workspace/oss/vllm}"
BASE=0e3c8dbdae9d55149b0fba4e6c1014b4b08c9c73
BASE_TREE=e6819e279d40268d45eee2bfa134d5d04b05e53f
WHEEL=e2052f5c7ad64564f00dd4592e77c27785c9333f
PR_HEAD_TREE=441714150d9afe8fd27523f66f288568e8a8c1e8
P6_COMMIT=23884c5eb20699e463f177d06d0ecde297fb3e46
P6_TREE=e7475ec46141b6764a1cf9874bcd7efa1e7003db
P7_HEAD=7528cc07f44ca7f864118fad29e08ea36abf19ef
FIX_TREE=49fd5c2fdd30efa118592a9d243ba9adf884e639
CONTROL_TREE=f0db55b74fe67706789aac52722e8a3390fecf52
TEST_BLOB=912b5f88eaaeba37b2b4b16f2091b6c99fd2aeb4
TF=tests/v1/kv_connector/unit/test_hf3fs_preemption.py
FIX_SHA256=8da42418ce7bcd85a85c19067a8c4da2dece1dbb485b765e0471759abed30eb6
GATHERS_SHA256=ae802dc58d3eda026d09b1f5ec201f74dde9bd4e871dcd8c918554dd1029b1cd
FENCE_SHA256=62aee4be428e28801471d6d2e92a02ae2004dc4b426a23bb5ebf533d2966af5f
FENCE_SRC="$HOME/workspace/storage/open-source/contributions/vllm/hf3fs-preemption-save/p7/0001-Bugfix-KV-Connector-Fence-partial-HF3FS-gathers-befo.patch"
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
check "the kit's Python, the fake and the checker compile" \
  "python3 -I -X pycache_prefix='$WORK/pyc' -m py_compile '$KIT/verdict.py' '$KIT/envprobe.py' '$FAKES/pytest_p7.py' '$CHECK'"

# ---------------------------------------------------------------- the pins
check "the kit holds the three patches, verdict.py, run.sh and envprobe.py, and nothing else" \
  "[ \"\$(ls '$KIT' | paste -sd' ')\" = 'envprobe.py fence.patch fix-and-tests.patch gathers.patch run.sh verdict.py' ]"
check "fence.patch has the pinned sha256, which starts 62aee4be and ends 6af5f as the runtime session gave it" \
  "[ \"\$(sha256sum '$KIT/fence.patch' | cut -d' ' -f1)\" = $FENCE_SHA256 ] && [ \${FENCE_SHA256:0:8} = 62aee4be ] && [ \${FENCE_SHA256: -5} = 6af5f ]"
check "fix-and-tests.patch, gathers.patch and envprobe.py are kit p6's, byte for byte, with their pinned sha256s" \
  "cmp -s '$ROOT/$KIT6REL/fix-and-tests.patch' '$KIT/fix-and-tests.patch' && cmp -s '$ROOT/$KIT6REL/gathers.patch' '$KIT/gathers.patch' \
   && cmp -s '$ROOT/$KIT6REL/envprobe.py' '$KIT/envprobe.py' && [ \"\$(sha256sum '$KIT/fix-and-tests.patch' | cut -d' ' -f1)\" = $FIX_SHA256 ] \
   && [ \"\$(sha256sum '$KIT/gathers.patch' | cut -d' ' -f1)\" = $GATHERS_SHA256 ]"
check "run.sh pins the three patches, the base, each step's tree, the control's tree and the test blob" \
  "command grep -qx 'FENCE_PATCH_SHA256=$FENCE_SHA256' '$KIT/run.sh' && command grep -qx 'GATHERS_PATCH_SHA256=$GATHERS_SHA256' '$KIT/run.sh' \
   && command grep -qx 'FIX_PATCH_SHA256=$FIX_SHA256' '$KIT/run.sh' && command grep -qx 'BASE_SHA=$BASE' '$KIT/run.sh' \
   && command grep -qx 'PR_HEAD_TREE=$PR_HEAD_TREE' '$KIT/run.sh' && command grep -qx 'P6_TREE=$P6_TREE' '$KIT/run.sh' \
   && command grep -qx 'P7_HEAD=$P7_HEAD' '$KIT/run.sh' && command grep -qx 'FIX_TREE=$FIX_TREE' '$KIT/run.sh' \
   && command grep -qx 'CONTROL_TREE=$CONTROL_TREE' '$KIT/run.sh' && command grep -qx 'TEST_BLOB=$TEST_BLOB' '$KIT/run.sh' \
   && command grep -qx 'WHEEL_COMMIT=$WHEEL' '$KIT/run.sh'"
if [ -f "$FENCE_SRC" ]; then
  check "the kit's fence.patch is byte for byte storage's $FENCE_SRC" "cmp -s '$KIT/fence.patch' '$FENCE_SRC'"
else
  echo "skip $FENCE_SRC is gone; the sha256 pin stands"
fi
check "kits p1 to p6 are left as committed" "git -C '$ROOT' diff --quiet HEAD -- docs/oss/vllm-hf3fs-preemption/kit-p1 docs/oss/vllm-hf3fs-preemption/kit-p2 \
  docs/oss/vllm-hf3fs-preemption/kit-p3 docs/oss/vllm-hf3fs-preemption/kit-p4 docs/oss/vllm-hf3fs-preemption/kit-p5 '$KIT6REL'"
if git -C "$SRC" cat-file -e "$BASE^{commit}" 2>"$WORK/src.err"; then
  check "the local base has the pinned tree, and its first parent is the wheel commit with no blocking-path change" \
    "[ \"\$(git -C '$SRC' rev-parse $BASE^{tree})\" = $BASE_TREE ] && [ \"\$(git -C '$SRC' rev-parse $BASE^1)\" = $WHEEL ] \
     && [ -z \"\$(git -C '$SRC' diff --no-renames --name-only $WHEEL $BASE -- csrc cmake CMakeLists.txt pyproject.toml vllm/_custom_ops.py vllm/_cpu_ops.py)\" ]"
else
  check "the local repository holds the base 0e3c8dbdae ($(cat "$WORK/src.err"))" "false"
fi
# The PR head, fetched from lkhun9311/vllm fix/hf3fs-preemption-save into VLLM_SRC.
if git -C "$SRC" cat-file -e "$P7_HEAD^{commit}" 2>"$WORK/p7.err"; then
  check "7528cc07 has 23884c5eb2 as its parent and the pinned tree, and 23884c5eb2 p6's tree" \
    "[ \"\$(git -C '$SRC' rev-parse $P7_HEAD^)\" = $P6_COMMIT ] && [ \"\$(git -C '$SRC' rev-parse $P7_HEAD^{tree})\" = $FIX_TREE ] \
     && [ \"\$(git -C '$SRC' rev-parse $P6_COMMIT^{tree})\" = $P6_TREE ]"
  git -C "$SRC" worktree add -q --detach "$WORK/apply" "$BASE" >"$WORK/apply.log" 2>&1 \
    && git -C "$WORK/apply" -c user.name=kit -c user.email=kit@localhost -c commit.gpgsign=false am -q "$KIT/fix-and-tests.patch" "$KIT/gathers.patch" "$KIT/fence.patch" >>"$WORK/apply.log" 2>&1
  check "git am of the three patches on the base gives 7528cc07's tree: git diff --quiet against it is clean, with p6's tree one step before" \
    "git -C '$WORK/apply' diff --quiet HEAD $P7_HEAD && [ \"\$(git -C '$WORK/apply' rev-parse HEAD^{tree})\" = $FIX_TREE ] \
     && [ \"\$(git -C '$WORK/apply' rev-parse HEAD^^{tree})\" = $P6_TREE ] && [ \"\$(git -C '$WORK/apply' rev-parse HEAD:$TF)\" = $TEST_BLOB ]"
  # CONTROL is p6's tree with only 7528cc07's test file.
  ctl=$(export GIT_INDEX_FILE="$WORK/ctl-index"; git -C "$WORK/apply" read-tree $P6_TREE && git -C "$WORK/apply" update-index --cacheinfo 100644,$TEST_BLOB,$TF && git -C "$WORK/apply" write-tree)
  rm -f "$WORK/ctl-index"
  check "CONTROL, p6's tree with only 7528cc07's test file, has the pinned tree" "[ '$ctl' = $CONTROL_TREE ]"
  git -C "$SRC" worktree remove --force "$WORK/apply" >>"$WORK/apply.log" 2>&1
else
  check "the local repository holds the PR head 7528cc07; fetch lkhun9311/vllm fix/hf3fs-preemption-save ($(cat "$WORK/p7.err"))" "false"
fi

# ---------------------------------------------------------------- vLLM's startup check and the reset check, on the new test file
startup() {
  local n=$1 sedexpr=${2:-} a="$WORK/apply"
  [ -e "$a" ] && git -C "$SRC" worktree remove --force "$a" >>"$WORK/apply.log" 2>&1
  git -C "$SRC" worktree add -q --detach "$a" "$BASE" >>"$WORK/apply.log" 2>&1 \
    && git -C "$a" -c user.name=kit -c user.email=kit@localhost -c commit.gpgsign=false am -q "$KIT/fix-and-tests.patch" "$KIT/gathers.patch" "$KIT/fence.patch" >>"$WORK/apply.log" 2>&1 || return 9
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
  check "startup and reset: vLLM accepts the new test file's max_model_len 736 with 48 blocks, and its bounded reset frees after 3 steps and fails after 50" \
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
check "the default settings: budget 900, CONTROL then FIX with the runtime session's command, and the control described" \
  "dry '$KIT' && command grep -qx 'budget_s=900' '$WORK/dry/settings.txt' && command grep -qx 'arm_cap_s=360' '$WORK/dry/settings.txt' \
   && command grep -qxF 'order=control fix, each in its own process' '$WORK/dry/settings.txt' \
   && command grep -qxF 'command=python -m pytest $TF -q -s --tb=short --durations=0' '$WORK/dry/settings.txt' \
   && command grep -qxF \"control=p6's code with only $P7_HEAD's test file, pinned by tree $CONTROL_TREE\" '$WORK/dry/settings.txt'"
check "BUDGET_S above 900 and ARM_CAP_S under 30 are refused" "! dry '$KIT' BUDGET_S=901 && ! dry '$KIT' ARM_CAP_S=10"

# ---------------------------------------------------------------- the budget against the runner's rates
S="$ROOT/hack/gpu-kit-session.sh"
bring=$(sed -n 's/^BRINGUP_S=\([0-9]*\)$/\1/p' "$S")
upl=$(sed -n 's/^EVIDENCE_UPLOAD_S=\([0-9]*\)$/\1/p' "$S")
kitmax=$(sed -n 's/^BUDGET_MAX_S=\([0-9]*\)$/\1/p' "$KIT/run.sh")
for t in g5.xlarge:0.3457:0.8579 g5.2xlarge:0.3907:0.9696; do
  type=${t%%:*} want=$(echo "$t" | cut -d: -f2) backstop=${t##*:}
  rate=$(sed -n "s/^    $type) echo \"[0-9.]* \([0-9.]*\) [0-9]*\" ;;\$/\1/p" "$S")
  sched=$(INSTANCE_TYPE=$type bash "$S" --print-schedule 2>&1)
  tail_s=$(python3 -I -c 'import re,sys; d=dict(re.findall(r"(\w+)=([\w.]+)", sys.argv[1])); print(int(d["termination_s"]) - int(d["evidence_s"]))' "$sched")
  worst=$(python3 -I -c 'import sys; b,k,u,t,r = map(float, sys.argv[1:]); print(f"{(b + k + u + t) / 3600 * r:.4f} {int(b + k + u + t)}")' "${bring:-x}" "${kitmax:-x}" "${upl:-x}" "${tail_s:-x}" "${rate:-x}")
  check "$type: BUDGET_S at its maximum, $kitmax s, bills ${worst#* } s at \$$rate/h, \$${worst% *}, as run.sh's header says" \
    "[ '$worst' = '$want 1620' ] && command grep -qF '\$$want on $type' '$KIT/run.sh'"
  check "$type: the runner's own backstop stays \$$backstop, as run.sh's header says" "[[ '$sched' == *worst_case_usd=$backstop ]] && command grep -qF '\$$backstop on $type' '$KIT/run.sh'"
done

# ---------------------------------------------------------------- end to end on the fakes, with the real checkout and three real git ams
e2e() {
  local k=$1 n=$2; shift 2
  local d="$WORK/e2e-$n"
  mkdir -p "$d/cwd" "$d/hf"
  ( cd "$d/cwd" && timeout --kill-after=5 "${E2E_OUTER_S:-120}" env PATH="$FAKES:$TOOLFAKES:$PATH" KIT_OFFLINE_TEST=1 OFFLINE_VLLM_SRC="$SRC" \
    FAKE_HF_DIR="$d/hf" OFFLINE_MODEL_BIN_SHA256="$FAKE_BIN_SHA256" FAKE_ORDER_LOG="$d/order" OUT="$d/out" "$@" bash "$k/run.sh" >"$d/run.log" 2>&1 )
}
v() { command grep -qx "VERDICT: $2" "$WORK/e2e-$1/out/verdict.txt"; }
vt() { command grep -qF -- "$2" "$WORK/e2e-$1/out/verdict.txt"; }
order() { [ -f "$WORK/e2e-$1/order" ] && paste -sd' ' "$WORK/e2e-$1/order"; }
stopped() { [ -f "$WORK/e2e-$1/out/STOPPED" ] && command grep -qF -- "$2" "$WORK/e2e-$1/out/STOPPED"; }

e2e "$KIT" pass FAKE_EXPECT_OFFLINE=1; rc=$?
check "pass: CONTROL fails exactly the new test, FIX passes both with every held-save page error 0.0; CONFIRMED, exit 0, in order CONTROL then FIX" \
  "[ $rc = 0 ] && v pass CONFIRMED && [ \"\$(order pass)\" = 'control fix' ] \
   && vt pass '  pytest summary (verbatim): 1 failed, 1 passed, 21 warnings in 72.34s (0:01:12)' && vt pass '  pytest summary (verbatim): 2 passed, 21 warnings in 72.34s (0:01:12)' \
   && vt pass '    E   assert (None is not None)' && vt pass 'held-save page errors: [0.0, 0.0, 0.0]' && vt pass '9.10s call     $TF::TestHF3FSPreemptionEndToEnd::test_failed_gather_still_fences_its_reads'"
check "pass: three git ams give the PR's first head, p6 and then 7528cc07's tree; CONTROL is the pinned tree; the fence is only in FIX" \
  "command grep -q '^pr_head commit=[0-9a-f]\{40\} tree=$PR_HEAD_TREE parent=$BASE\$' '$WORK/e2e-pass/out/versions.txt' \
   && command grep -q '^p6 commit=[0-9a-f]\{40\} tree=$P6_TREE parent=' '$WORK/e2e-pass/out/versions.txt' \
   && command grep -q '^fix commit=[0-9a-f]\{40\} tree=$FIX_TREE parent=' '$WORK/e2e-pass/out/versions.txt' \
   && command grep -qx 'control tree=$CONTROL_TREE' '$WORK/e2e-pass/out/versions.txt' \
   && command grep -qx 'fence_marker control=0 fix=1 control_wait_for_gathers=1' '$WORK/e2e-pass/out/versions.txt' \
   && command grep -qx 'control test_blob=$TEST_BLOB' '$WORK/e2e-pass/out/versions.txt' && command grep -qx 'fix test_blob=$TEST_BLOB' '$WORK/e2e-pass/out/versions.txt' \
   && ( cd '$WORK/e2e-pass/out' && sha256sum -c --quiet SHA256SUMS ) && ! git -C '$SRC' worktree list | command grep -qF '$WORK/e2e-pass/'"
for kind in fixnewfail:2:FINDING controlnewpass:5:INCONCLUSIVE controlfirstfail:5:INCONCLUSIVE fixnonzero:5:INCONCLUSIVE fixnotimeout:5:INCONCLUSIVE \
  setupboth:4:'NOT RUN' controlkv:4:'NOT RUN' skip:3:INCOMPLETE; do
  k=${kind%%:*} rest=${kind#*:} want_rc=${rest%%:*} want=${rest#*:}
  e2e "$KIT" "$k" FAKE_MODE="$k"; rc=$?
  check "$k: the run is $want, exit $want_rc" "[ $rc = $want_rc ] && v $k '$want'"
done
t0=$(date +%s); e2e "$KIT" hang FAKE_MODE=hang BUDGET_S=100 ARM_CAP_S=30; rc=$?; took=$(( $(date +%s) - t0 ))
check "hang: each process is cut at its cap or the budget left, and run.sh ends inside BUDGET_S ($took s)" \
  "command grep -qx 'test-control exit=124 t=[0-9]*' '$WORK/e2e-hang/out/status.txt' && v hang INCOMPLETE && [ $took -le 100 ]"
for p in fence gathers fix-and-tests; do
  cp -r "$KIT" "$WORK/tampered-$p" && printf '\n' >>"$WORK/tampered-$p/$p.patch"
  e2e "$WORK/tampered-$p" "tampered-$p"; rc=$?
  check "a $p.patch that is not the pinned one stops the run before any checkout" \
    "[ $rc = 1 ] && stopped tampered-$p '$p.patch has sha256' && ! command grep -q '^worktree-vllm' '$WORK/e2e-tampered-$p/out/status.txt'"
done

# ---------------------------------------------------------------- mutants of run.sh, caught end to end
m=$(mutant wrongsha run.sh 's/^FENCE_PATCH_SHA256=62aee4be.*$/FENCE_PATCH_SHA256=0000000000000000000000000000000000000000000000000000000000000000/')
[ -n "$m" ] && e2e "$m" m-wrongsha
mcheck "mutant: a wrong fence.patch sha256 pin stops the run" "stopped m-wrongsha 'not the pinned 00000000'"
m=$(mutant fencepin run.sh 's/^\[ "\$got_fence" = "\$FENCE_PATCH_SHA256" \] ||/true ||/')
[ -n "$m" ] && cp "$WORK/tampered-fence/fence.patch" "$m/" && e2e "$m" m-fencepin
mcheck "mutant: a run.sh that skips fence.patch's sha256 pin is caught" "! stopped m-fencepin 'fence.patch has sha256'"
m=$(mutant nofixtree run.sh 's/^FIX_TREE=49fd5c2fdd30efa118592a9d243ba9adf884e639$/FIX_TREE=0000000000000000000000000000000000000000/; s/^\[ "\$tree" = "\$FIX_TREE" \] ||/true ||/')
[ -n "$m" ] && e2e "$m" m-nofixtree
mcheck "mutant: a run.sh without the fix's tree check is caught" "! stopped m-nofixtree 'not the pinned 0000000'"
m=$(mutant othercontrol run.sh 's/^CONTROL_TREE=f0db55b74fe67706789aac52722e8a3390fecf52$/CONTROL_TREE=0000000000000000000000000000000000000000/')
[ -n "$m" ] && e2e "$m" m-othercontrol
mcheck "a control whose tree is not the pinned one stops the run before any test" "stopped m-othercontrol 'the control has tree' && ! [ -s '$WORK/e2e-m-othercontrol/order' ]"
fixctl='s/^    git -C vllm checkout -q --detach -f "\$P6_HEAD" || stop "could not check out the p6 commit for the control"$/    git -C vllm checkout -q --detach -f "$FIX_HEAD" || stop "could not check out the p6 commit for the control"/'
m=$(mutant controlhasfix run.sh "$fixctl")
[ -n "$m" ] && e2e "$m" m-controlhasfix
mcheck "mutant: a CONTROL that also has the fix is stopped by the control's pins, and does not report CONFIRMED" "stopped m-controlhasfix 'the control' && ! v m-controlhasfix CONFIRMED"
m=$(mutant controlhasfixunguarded run.sh "$fixctl; "'s/^    \[ "\$t" = "\$CONTROL_TREE" \] ||/    true ||/; s/^    \[ "\$(git -C vllm status --porcelain --untracked-files=no)" = " M \$TEST_FILE" \] || \[ "\$(git -C vllm status --porcelain --untracked-files=no)" = "M  \$TEST_FILE" \] ||$/    true ||/; s/^    \[ "\$(git -C vllm rev-parse HEAD)" = "\$P6_HEAD" \] ||/    true ||/')
[ -n "$m" ] && e2e "$m" m-controlhasfixunguarded
mcheck "mutant: a CONTROL that has the fix, past its pins, passes the new test, and the verdict refuses to confirm" \
  "! v m-controlhasfixunguarded CONFIRMED && vt m-controlhasfixunguarded 'CONTROL passed the new test'"
m=$(mutant nofencemarker run.sh 's/^\[ "\$n_control" = 0 \] && \[ "\$n_fix" -ge 1 \] && \[ "\$n_gathers" = 1 \] ||$/true ||/; s/^FIX_TREE=49fd5c2fdd30efa118592a9d243ba9adf884e639$/FIX_TREE=e7475ec46141b6764a1cf9874bcd7efa1e7003db/; s/^step git-am-fence 60 --log "\$OUT\/git-am-fence.log" git -C vllm .* am -q "\$FENCE_PATCH" ||$/true ||/; s/^\[ "\$parent" = "\$P6_HEAD" \] ||/true ||/')
[ -n "$m" ] && e2e "$m" m-nofencemarker
mcheck "mutant: a FIX without the fence, past its tree pin and the fence-marker check, is caught downstream" "! v m-nofencemarker CONFIRMED"

# ---------------------------------------------------------------- mutants of verdict.py, caught by the unit checks
caught() { ! python3 -I "$CHECK" "$1" "$FAKES" >"$WORK/mutant.log" 2>&1; }
while IFS='|' read -r name sedexpr; do
  [ -n "$name" ] || continue
  m=$(mutant "$name" verdict.py "$sedexpr")
  mcheck "mutant: verdict $name is caught" "caught '$m'"
done <<'MUTANTS'
accepts a CONTROL pass of the new test|s/^    elif not control\["new_failed"\]:$/    elif False:/
lets FIX fail the new test|s/^    if fix\["new_failed"\]:$/    if False:/
accepts CONTROL failing the first test|s/^    elif control\["gpu"\] != "passed":$/    elif False:/
lets a nonzero held-save error confirm|s/^    elif any(e != 0.0 for e in fix\["errors"\]):$/    elif False:/
confirms without the hold timing out|s/^    elif fix\["hold_timed_out"\] is not True:$/    elif False:/
merges first-test failures at different lines|s/^                  and control\["fail_at"\] == fix\["fail_at"\] and control\["first_e"\] == fix\["first_e"\])$/                  and True)/
counts other than the file's two tests|s/^CPU_TESTS = (NEW_TEST,)$/CPU_TESTS = ()/
drops CONTROL's new-test E lines|s/^        lines.extend(f"    {x}" for x in p.get("new_e", \[\])\[:20\])$/        pass/
drops the durations|s/^        lines.extend(f"    {x}" for x in p.get("durations", \[\]))$/        pass/
drops the verbatim pytest summary|s/^        lines.append(f"  pytest summary (verbatim): {p.get('summary_raw')}")$/        pass/
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
