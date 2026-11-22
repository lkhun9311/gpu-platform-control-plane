#!/usr/bin/env bash
#
# Offline checks for the vLLM HF3FS preemption kit p1 in docs/oss/vllm-hf3fs-preemption/kit-p1, run before any GPU is bought.
# No GPU, no network and no AWS: python (with pytest) is the fake in hack/vllm-hf3fs-preemption-fake,
# hf and nvidia-smi are the fakes in hack/vllm-69058-fake, and aws is a fake that records its calls.
# The vLLM checkout is real, a detached worktree of a local vLLM repository (VLLM_SRC) at the base, with tests-only.patch applied by a real git apply
# and fix-and-tests.patch by a real git am.
# Each verdict rule and each run.sh guard is also run against a mutant that breaks it, and the mutant must be caught.
# The runner checks need the kit committed, since the session ships a commit; they clone this tree's HEAD.
#
#   VLLM_SRC=/path/to/vllm bash hack/vllm-hf3fs-preemption-kit-test.sh
set -uo pipefail
unset INSTANCE_TYPE KIT_ENV SESSION_CONFIRM AWS_PROFILE
# The checks assert the kit's and the fakes' defaults, so a caller's settings must not reach them.
unset BUDGET_S ARM_CAP_S CASE_CAP_S E2E_CAP_S UNIT_CAP_S PYTEST_CAP_S LLM_CAP_S KIT_DRY_RUN KIT_OFFLINE_TEST OFFLINE_VLLM_SRC OFFLINE_MODEL_BIN_SHA256 \
  FAKE_MODE FAKE_CUDA FAKE_HF FAKE_HF_DIR FAKE_NVSMI FAKE_ORDER_LOG FAKE_EXPECT_OFFLINE HF_HUB_OFFLINE TRANSFORMERS_OFFLINE VLLM_ENABLE_V1_MULTIPROCESSING CUDA_LAUNCH_BLOCKING
# Python must not leave bytecode beside a mutant, where a same-size edit restored within a second could reuse it.
export PYTHONDONTWRITEBYTECODE=1
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KIT="$ROOT/docs/oss/vllm-hf3fs-preemption/kit-p1"
KITREL=docs/oss/vllm-hf3fs-preemption/kit-p1
FAKES="$ROOT/hack/vllm-hf3fs-preemption-fake"
TOOLFAKES="$ROOT/hack/vllm-69058-fake"
CHECK="$ROOT/hack/vllm-hf3fs-preemption-kit-check.py"
SRC="${VLLM_SRC:-$HOME/workspace/oss/vllm}"
BASE=17323e0b1ca54296cc3016b72d481ecffc17e69b
BASE_TREE=a410ffdbc9d649f1f42940c1d8c0a3d7b6d771bc
FIX_TREE=883fa9981d3361141c6997ec9fdd9aa8d34a8dc9
CONTROL_TREE=cb462c3b25e5a49eabf7d86b7a93558b362b1dd1
TEST_BLOB=b489f5e191a91c3b1361cd721ab8ec41f6811467
WHEEL=e29c741da8d11e2ae7ba381bb78b6f703812cae1
TF=tests/v1/kv_connector/unit/test_hf3fs_preemption.py
TESTS_SHA256=0dd71c18920fb49a3f8feab1755db2bc239669f815dd0e51c4e6d81267d44edf
FIX_SHA256=276a4d3148dc145b4bf4223df07ade72255a0e62b85f076e6cf7834b7ffc8508
STORAGE="$HOME/workspace/storage"
STORAGE_DIR=open-source/contributions/vllm/hf3fs-preemption-save
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
  "python3 -I -X pycache_prefix='$WORK/pyc' -m py_compile '$KIT/verdict.py' '$KIT/envprobe.py' '$FAKES/pytest_p1.py' '$CHECK'"
if command -v shellcheck >/dev/null; then
  check "shellcheck finds no error in run.sh" "shellcheck -S error '$KIT/run.sh'"
else
  echo "skip shellcheck is not installed here"
fi

# ---------------------------------------------------------------- the pins
check "the kit holds both patches with the pinned sha256s, which start 0dd71c18920fb49a and 276a4d3148dc145b" \
  "[ \"\$(ls '$KIT' | paste -sd' ')\" = 'envprobe.py fix-and-tests.patch run.sh tests-only.patch verdict.py' ] \
   && [ \"\$(sha256sum '$KIT/tests-only.patch' | cut -d' ' -f1)\" = $TESTS_SHA256 ] && [ \${TESTS_SHA256:0:16} = 0dd71c18920fb49a ] \
   && [ \"\$(sha256sum '$KIT/fix-and-tests.patch' | cut -d' ' -f1)\" = $FIX_SHA256 ] && [ \${FIX_SHA256:0:16} = 276a4d3148dc145b ]"
check "run.sh pins both patches, the base by commit and tree, the fix's and the control's trees, the test blob and the wheel commit" \
  "command grep -qx 'TESTS_PATCH_SHA256=$TESTS_SHA256' '$KIT/run.sh' && command grep -qx 'FIX_PATCH_SHA256=$FIX_SHA256' '$KIT/run.sh' \
   && command grep -qx 'BASE_SHA=$BASE' '$KIT/run.sh' && command grep -qx 'BASE_TREE=$BASE_TREE' '$KIT/run.sh' \
   && command grep -qx 'FIX_TREE=$FIX_TREE' '$KIT/run.sh' && command grep -qx 'CONTROL_TREE=$CONTROL_TREE' '$KIT/run.sh' \
   && command grep -qx 'TEST_BLOB=$TEST_BLOB' '$KIT/run.sh' && command grep -qx 'WHEEL_COMMIT=$WHEEL' '$KIT/run.sh'"
# Storage's history is to be rewritten, so the patches are pinned by sha256; storage is compared only while it still holds them.
for p in tests-only.patch fix-and-tests.patch; do
  if git -C "$STORAGE" show "origin/main:$STORAGE_DIR/$p" >"$WORK/storage-$p" 2>"$WORK/storage.err"; then
    check "the kit's $p is byte for byte storage's origin/main:$STORAGE_DIR/$p" "cmp -s '$KIT/$p' '$WORK/storage-$p'"
  else
    echo "skip storage's origin/main no longer holds $STORAGE_DIR/$p; the sha256 pin stands ($(head -c 200 "$WORK/storage.err" | iconv -f UTF-8 -t UTF-8 -c))"
  fi
done
if git -C "$SRC" cat-file -e "$BASE^{commit}" 2>"$WORK/src.err"; then
  check "the local base has the pinned tree, and its first parent is the wheel commit with no blocking-path change" \
    "[ \"\$(git -C '$SRC' rev-parse $BASE^{tree})\" = $BASE_TREE ] && [ \"\$(git -C '$SRC' rev-parse $BASE^1)\" = $WHEEL ] \
     && [ -z \"\$(git -C '$SRC' diff --no-renames --name-only $WHEEL $BASE -- csrc cmake CMakeLists.txt pyproject.toml vllm/_custom_ops.py vllm/_cpu_ops.py)\" ]"
else
  check "the local repository holds the base 17323e0b1c ($(cat "$WORK/src.err"))" "false"
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
  "dry '$KIT' && command grep -qx 'budget_s=600' '$WORK/dry/settings.txt' && command grep -qx 'arm_cap_s=240' '$WORK/dry/settings.txt' \
   && command grep -qxF 'order=control fix, each in its own process' '$WORK/dry/settings.txt' \
   && command grep -qxF 'command=python -m pytest $TF -q -p no:cacheprovider -s --tb=short' '$WORK/dry/settings.txt'"
check "CUDA_LAUNCH_BLOCKING set by a caller is refused rather than passed to the tests" "! dry '$KIT' -- CUDA_LAUNCH_BLOCKING=1 && command grep -qF 'runs without it' '$WORK/dry.out'"
check "a positional argument is refused, and nothing is written" "! dry '$KIT' extra && command grep -qF 'takes no arguments' '$WORK/dry.out' && [ ! -e '$WORK/dry' ]"
check "BUDGET_S above 600, not whole seconds, at or below the reserve, or with a leading zero is refused" \
  "! dry '$KIT' -- BUDGET_S=601 && ! dry '$KIT' -- BUDGET_S=10m && ! dry '$KIT' -- BUDGET_S=60 && ! dry '$KIT' -- BUDGET_S=0300"
check "ARM_CAP_S with a leading zero or under 30, and earlier kits' cap settings, are refused" \
  "! dry '$KIT' -- ARM_CAP_S=0240 && ! dry '$KIT' -- ARM_CAP_S=5 && ! dry '$KIT' -- CASE_CAP_S=180"
m=$(mutant budgetcap run.sh 's/^BUDGET_MAX_S=600$/BUDGET_MAX_S=800/')
mcheck "mutant: a run.sh that takes BUDGET_S=601 is caught" "! { ! dry '$m' -- BUDGET_S=601; }"
m=$(mutant blockingok run.sh 's/^\[ -z "\${CUDA_LAUNCH_BLOCKING:-}" \] ||/true ||/')
mcheck "mutant: a run.sh that lets CUDA_LAUNCH_BLOCKING through is caught" "! { ! dry '$m' -- CUDA_LAUNCH_BLOCKING=1; }"

# ---------------------------------------------------------------- the budget against the runner's rates, on both instance types
S="$ROOT/hack/gpu-kit-session.sh"
bring=$(sed -n 's/^BRINGUP_S=\([0-9]*\)$/\1/p' "$S")
upl=$(sed -n 's/^EVIDENCE_UPLOAD_S=\([0-9]*\)$/\1/p' "$S")
kitmax=$(sed -n 's/^BUDGET_MAX_S=\([0-9]*\)$/\1/p' "$KIT/run.sh")
for t in g5.xlarge:0.2817:0.8579 g5.2xlarge:0.3184:0.9696; do
  type=${t%%:*} want=$(echo "$t" | cut -d: -f2) backstop=${t##*:}
  rate=$(sed -n "s/^    $type) echo \"[0-9.]* \([0-9.]*\) [0-9]*\" ;;\$/\1/p" "$S")
  sched=$(INSTANCE_TYPE=$type bash "$S" --print-schedule 2>&1)
  tail_s=$(python3 -I -c 'import re,sys; d=dict(re.findall(r"(\w+)=([\w.]+)", sys.argv[1])); print(int(d["termination_s"]) - int(d["evidence_s"]))' "$sched")
  worst=$(python3 -I -c 'import sys; b,k,u,t,r = map(float, sys.argv[1:]); print(f"{(b + k + u + t) / 3600 * r:.4f} {int(b + k + u + t)}")' "${bring:-x}" "${kitmax:-x}" "${upl:-x}" "${tail_s:-x}" "${rate:-x}")
  check "$type: BUDGET_S at its maximum, $kitmax s, bills ${worst#* } s at \$$rate/h, \$${worst% *}, as run.sh's header says" \
    "[ '$worst' = '$want 1320' ] && command grep -qF '\$$want on $type' '$KIT/run.sh'"
  check "$type: the runner's own backstop stays \$$backstop, as run.sh's header says" \
    "[[ '$sched' == *worst_case_usd=$backstop ]] && command grep -qF '\$$backstop on $type' '$KIT/run.sh'"
done
check "g5.xlarge's bill at the maximum budget stays under \$0.30" "python3 -I -c 'import sys; sys.exit(0 if 0.2817 < 0.30 else 1)'"

# ---------------------------------------------------------------- end to end on the fakes, with the real checkout, git apply and git am
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
check "pass: CONTROL fails the comparison with preconditions met, FIX passes, and the run is CONFIRMED, exit 0" "[ $rc = 0 ] && v pass CONFIRMED"
check "pass: the two processes ran CONTROL then FIX, on the right code" \
  "[ \"\$(order pass)\" = '$ORDER_WANT' ] && [ \"\$(command grep -oE '^test-[a-z]+' '$WORK/e2e-pass/out/status.txt' | paste -sd' ')\" = 'test-control test-fix' ]"
check "pass: the fix commit has the pinned tree and the base as its parent, the control the pinned tree, both the pinned test blob, and the hook only in the fix" \
  "command grep -q '^fix commit=[0-9a-f]\{40\} tree=$FIX_TREE parent=$BASE\$' '$WORK/e2e-pass/out/versions.txt' \
   && command grep -qx 'base commit=$BASE tree=$BASE_TREE' '$WORK/e2e-pass/out/versions.txt' \
   && [ \"\$(command grep -c '^control tree=$CONTROL_TREE\$' '$WORK/e2e-pass/out/versions.txt')\" = 2 ] \
   && command grep -qx 'control test_blob=$TEST_BLOB' '$WORK/e2e-pass/out/versions.txt' && command grep -qx 'fix test_blob=$TEST_BLOB' '$WORK/e2e-pass/out/versions.txt' \
   && command grep -qx 'handle_preemptions_defs control=0 fix=1' '$WORK/e2e-pass/out/versions.txt' \
   && command grep -qx 'base_first_parent=$WHEEL wheel_commit=$WHEEL' '$WORK/e2e-pass/out/versions.txt' && [ ! -s '$WORK/e2e-pass/out/wheel-blocking-diff.txt' ]"
check "pass: the verdict prints each arm's summary, held line, page errors and CONTROL's traceback" \
  "vt pass 'CONTROL: GPU test mismatch (exit 1): 3 failed, 1 passed, 20 warnings' && vt pass 'FIX: GPU test passed (exit 0): 4 passed, 20 warnings' \
   && vt pass 'held line: held=[20, 21, 22, 23] reused=[21, 22] hold_timed_out=False' && vt pass 'held line: held=[20, 21, 22, 23] reused=[21, 22] hold_timed_out=True' \
   && vt pass 'page errors: [0.9731, 1.0214]' && vt pass 'E   AssertionError: [0.9731, 1.0214]'"
check "pass: the hub was offline, and the run left checksums and no worktree" \
  "command grep -qx 'hub_offline=1 for the test runs' '$WORK/e2e-pass/out/settings.txt' && ( cd '$WORK/e2e-pass/out' && sha256sum -c --quiet SHA256SUMS ) \
   && ! git -C '$SRC' worktree list | command grep -qF '$WORK/e2e-pass/'"
for kind in fixmismatch:2:FINDING fixsmallerr:2:FINDING fixcpufail:2:FINDING fixother:2:FINDING fixfault:2:FINDING \
  fixnotimeout:5:INCONCLUSIVE fixprecond:5:INCONCLUSIVE controlpass:5:INCONCLUSIVE controlprecond:5:INCONCLUSIVE controlsmall:5:INCONCLUSIVE \
  controltimeout:5:INCONCLUSIVE controlkv:4:'NOT RUN' fixload:4:'NOT RUN' skip:3:INCOMPLETE nosummary:3:INCOMPLETE; do
  k=${kind%%:*} rest=${kind#*:} want_rc=${rest%%:*} want=${rest#*:}
  e2e "$KIT" "$k" FAKE_MODE="$k"; rc=$?
  check "$k: the run is $want, exit $want_rc" "[ $rc = $want_rc ] && v $k '$want'"
done
check "controlprecond: the verdict names the precondition not met" "vt controlprecond 'precondition not met: held block reused'"
t0=$(date +%s); e2e "$KIT" hang FAKE_MODE=hang BUDGET_S=100 ARM_CAP_S=30; rc=$?; took=$(( $(date +%s) - t0 ))
check "hang: each process is cut at its cap or the budget left, and run.sh ends inside BUDGET_S ($took s)" \
  "[ $rc = 3 ] && command grep -qx 'test-control exit=124 t=[0-9]*' '$WORK/e2e-hang/out/status.txt' \
   && { command grep -qx 'test-fix exit=124 t=[0-9]*' '$WORK/e2e-hang/out/status.txt' || stopped hang 'the budget ran out before test-fix'; } && v hang INCOMPLETE && [ $took -le 100 ]"
for p in tests-only fix-and-tests; do
  cp -r "$KIT" "$WORK/tampered-$p" && printf '\n' >>"$WORK/tampered-$p/$p.patch"
  e2e "$WORK/tampered-$p" "tampered-$p"; rc=$?
  check "a $p.patch that is not the pinned one stops the run before any checkout" \
    "[ $rc = 1 ] && stopped tampered-$p '$p.patch has sha256' && ! command grep -q '^worktree-vllm' '$WORK/e2e-tampered-$p/out/status.txt'"
done
m=$(mutant othertree run.sh 's/^FIX_TREE=883fa9981d3361141c6997ec9fdd9aa8d34a8dc9$/FIX_TREE=0000000000000000000000000000000000000000/')
[ -n "$m" ] && e2e "$m" othertree
mcheck "a fix whose tree is not the pinned one stops the run before any test" "stopped othertree 'not the pinned 0000000' && ! [ -s '$WORK/e2e-othertree/order' ]"
m=$(mutant otherbase run.sh 's/^BASE_TREE=a410ffdbc9d649f1f42940c1d8c0a3d7b6d771bc$/BASE_TREE=0000000000000000000000000000000000000000/')
[ -n "$m" ] && e2e "$m" otherbase
mcheck "a base whose tree is not the pinned one stops the run before any test" "stopped otherbase 'not the pinned 0000000' && ! [ -s '$WORK/e2e-otherbase/order' ]"
m=$(mutant othercontrol run.sh 's/^CONTROL_TREE=cb462c3b25e5a49eabf7d86b7a93558b362b1dd1$/CONTROL_TREE=0000000000000000000000000000000000000000/')
[ -n "$m" ] && e2e "$m" othercontrol
mcheck "a control whose tree is not the pinned one stops the run before any test" "stopped othercontrol 'the control has tree' && ! [ -s '$WORK/e2e-othercontrol/order' ]"
m=$(mutant otherwheel run.sh 's/^WHEEL_COMMIT=e29c741da8d11e2ae7ba381bb78b6f703812cae1$/WHEEL_COMMIT=dd8c157895f01875bc5f44c51003bbe330647330/')
[ -n "$m" ] && e2e "$m" otherwheel
mcheck "a wheel commit that is not the base's first parent stops the run" "stopped otherwheel 'not the wheel commit dd8c1578'"

# ---------------------------------------------------------------- mutants of run.sh, caught end to end
m=$(mutant testspin run.sh 's/^\[ "\$got_tests" = "\$TESTS_PATCH_SHA256" \] ||/true ||/')
[ -n "$m" ] && cp "$WORK/tampered-tests-only/tests-only.patch" "$m/" && e2e "$m" m-testspin
mcheck "mutant: a run.sh that skips tests-only.patch's sha256 pin is caught" "! stopped m-testspin 'tests-only.patch has sha256'"
m=$(mutant fixpin run.sh 's/^\[ "\$got_fix" = "\$FIX_PATCH_SHA256" \] ||/true ||/')
[ -n "$m" ] && cp "$WORK/tampered-fix-and-tests/fix-and-tests.patch" "$m/" && e2e "$m" m-fixpin
mcheck "mutant: a run.sh that skips fix-and-tests.patch's sha256 pin is caught" "! stopped m-fixpin 'fix-and-tests.patch has sha256'"
m=$(mutant nobasetree run.sh 's/^BASE_TREE=a410ffdbc9d649f1f42940c1d8c0a3d7b6d771bc$/BASE_TREE=0000000000000000000000000000000000000000/; s/^\[ "\$tree" = "\$BASE_TREE" \] ||/true ||/')
[ -n "$m" ] && e2e "$m" m-nobasetree
mcheck "mutant: a run.sh without the base's tree check is caught" "! stopped m-nobasetree 'not the pinned 0000000'"
m=$(mutant nofixtree run.sh 's/^FIX_TREE=883fa9981d3361141c6997ec9fdd9aa8d34a8dc9$/FIX_TREE=0000000000000000000000000000000000000000/; s/^\[ "\$tree" = "\$FIX_TREE" \] ||/true ||/')
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
m=$(mutant nos run.sh 's/ -q -p no:cacheprovider -s --tb=short; }$/ -q -p no:cacheprovider --tb=short; }/')
[ -n "$m" ] && e2e "$m" m-nos
mcheck "mutant: test runs without -s do not report CONFIRMED" "[ -f '$WORK/e2e-m-nos/out/verdict.txt' ] && ! v m-nos CONFIRMED"
m=$(mutant offline run.sh 's/^export HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1$/true/')
[ -n "$m" ] && e2e "$m" m-offline FAKE_EXPECT_OFFLINE=1
mcheck "mutant: a run.sh that leaves the hub online for the tests does not report CONFIRMED" "! v m-offline CONFIRMED"
m=$(mutant notimeout run.sh 's/^  timeout --kill-after=10 "\$cap" "\$@" > "\$log" 2>&1$/  "$@" > "$log" 2>\&1/')
[ -n "$m" ] && { E2E_OUTER_S=90 e2e "$m" m-notimeout FAKE_MODE=hang BUDGET_S=100 ARM_CAP_S=30; rc=$?; }
mcheck "mutant: a step without its timeout overruns the budget and is caught" "[ \"\${rc:-0}\" = 124 ]"

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
lets a FIX page mismatch pass|s/^    if fix\["gpu"\] in ("faulted", "failed", "mismatch"):$/    if fix["gpu"] in ("faulted", "failed"):/
lets a FIX fault pass|s/^    if fix\["gpu"\] in ("faulted", "failed", "mismatch"):$/    if fix["gpu"] in ("failed", "mismatch"):/
lets a FIX error at 0.05 or more pass|s/^ERROR_LIMIT = 0.05$/ERROR_LIMIT = 0.5/
ignores FIX's CPU tests|s/^    if fix\["cpu_failed"\] and fix\["summary"\] is not None:$/    if False:/
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
accepts a process that ran other than the file's four tests|s/^    elif sum(got.values()) != 1 + len(CPU_TESTS):$/    elif False:/
ignores no CUDA|s/^        if env.get("cuda_available") is not True or not env.get("device_name"):$/        if False:/
ignores a stopped run|s/^    if os.path.exists(os.path.join(out, "STOPPED")):$/    if False:/
exits 0 when inconclusive|s/{"CONFIRMED": 0, "FINDING": 2, "NOT RUN": 4, "INCONCLUSIVE": 5}/{"CONFIRMED": 0, "FINDING": 2, "NOT RUN": 4, "INCONCLUSIVE": 0}/
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

echo
if [ "$failures" = 0 ]; then echo "all checks passed"; else echo "$failures check(s) failed" >&2; exit 1; fi
