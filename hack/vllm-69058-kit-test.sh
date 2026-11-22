#!/usr/bin/env bash
#
# Offline checks for the vLLM #69058 kit r4 in docs/oss/vllm-69058/kit-r4, run before any GPU is bought.
# No GPU, no network and no AWS: python (with pytest), hf and nvidia-smi are the fakes in hack/vllm-69058-fake, and aws is a fake that records its calls.
# The vLLM checkout is real, a detached worktree of a local vLLM repository (VLLM_SRC) that holds both arms' commits.
# Each verdict rule and each run.sh guard is also run against a mutant that breaks it, and the mutant must be caught.
# The runner checks need the kit committed, since the session ships a commit; they clone this tree's HEAD.
# Kits r1 and r3 were checked by this script's earlier versions, at 2f31a67b and a32a3a10.
#
#   VLLM_SRC=/path/to/vllm bash hack/vllm-69058-kit-test.sh
set -uo pipefail
unset INSTANCE_TYPE KIT_ENV SESSION_CONFIRM AWS_PROFILE
# The checks assert the kit's and the fakes' defaults, so a caller's settings must not reach them.
unset BUDGET_S UNIT_CAP_S E2E_CAP_S PYTEST_CAP_S LLM_CAP_S KIT_DRY_RUN KIT_OFFLINE_TEST OFFLINE_VLLM_SRC OFFLINE_MODEL_BIN_SHA256 \
  FAKE_MODE FAKE_CUDA FAKE_HF FAKE_HF_DIR FAKE_EXPECT_OFFLINE FAKE_ORDER_LOG HF_HUB_OFFLINE TRANSFORMERS_OFFLINE VLLM_ENABLE_V1_MULTIPROCESSING CUDA_LAUNCH_BLOCKING
# Python must not leave bytecode beside a mutant, where a same-size edit restored within a second could reuse it.
export PYTHONDONTWRITEBYTECODE=1
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KIT="$ROOT/docs/oss/vllm-69058/kit-r4"
FAKES="$ROOT/hack/vllm-69058-fake"
CHECK="$ROOT/hack/vllm-69058-kit-check.py"
SRC="${VLLM_SRC:-$HOME/workspace/oss/vllm}"
ARM_A=bb14b99792981d8dcebcce5fe7eacfb46e4258fb
ARM_B=9ee44f044e6f3bbc49b96facb4cfda659cd783a5
TF=tests/v1/kv_connector/unit/test_hf3fs_load_failure.py
# The fake hf writes "fake pytorch_model.bin" plus a newline as the weights, and this is its sha256.
FAKE_BIN_SHA256=702621c64b6d1269dfb348b9109f388ab469b74f394201717a1b1cd9cd1a5d8b
# Scratch space lives on disk, since /tmp is RAM-backed on the development machine.
SCRATCH="${SCRATCH:-$HOME/.cache/vllm-69058}"
mkdir -p "$SCRATCH" || exit 1
# An empty WORK would turn every "$WORK/..." below, the cleanup's removals included, into a path at the root.
WORK=$(mktemp -d -p "$SCRATCH") && [ -n "$WORK" ] && [ -d "$WORK" ] || { echo "could not make a scratch directory under $SCRATCH" >&2; exit 1; }
export TMPDIR="$WORK/tmp"
mkdir -p "$TMPDIR" || exit 1
cleanup() {
  # Worktrees the e2e runs added to the local vLLM repository are removed even when a run stopped before its own cleanup.
  for w in "$WORK"/e2e-*/cwd/vllm; do
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
check "run.sh, this test and the shell fakes parse" "bash -n '$KIT/run.sh' && bash -n '$0' && bash -n '$FAKES/python' && bash -n '$FAKES/nvidia-smi' && bash -n '$FAKES/hf'"
check "the kit's Python, the fake pytest and the checker compile" \
  "python3 -I -X pycache_prefix='$WORK/pyc' -m py_compile '$KIT/verdict.py' '$KIT/envprobe.py' '$FAKES/pytest_r4.py' '$CHECK'"
if command -v shellcheck >/dev/null; then
  check "shellcheck finds no error in run.sh" "shellcheck -S error '$KIT/run.sh'"
else
  echo "skip shellcheck is not installed here"
fi

# ---------------------------------------------------------------- the arms' pins, against a local repository that holds both commits
check "run.sh pins both arms by commit and tree, and arm B's test file by sha256" \
  "command grep -qx 'ARM_A_SHA=$ARM_A' '$KIT/run.sh' && command grep -qx 'ARM_A_TREE=8256f29750a8035f563029cfd6c7e1bb40558b0b' '$KIT/run.sh' \
   && command grep -qx 'ARM_B_SHA=$ARM_B' '$KIT/run.sh' && command grep -qx 'ARM_B_TREE=5cdf5ed74707a1e5fb0509a058c1d86aba70d3cb' '$KIT/run.sh' \
   && command grep -qx 'TEST_FILE_SHA256=af58d2b74ba20c35ec547e70648e0a9de04736edbd5cf6e63c3e3780d2574217' '$KIT/run.sh' \
   && command grep -qx 'ARM_A_REF=refs/pull/69095/head' '$KIT/run.sh'"
if git -C "$SRC" cat-file -e "$ARM_A^{commit}" 2>"$WORK/src.err" && git -C "$SRC" cat-file -e "$ARM_B^{commit}" 2>>"$WORK/src.err"; then
  check "the local commits have the pinned trees" \
    "[ \"\$(git -C '$SRC' rev-parse $ARM_A^{tree})\" = 8256f29750a8035f563029cfd6c7e1bb40558b0b ] && [ \"\$(git -C '$SRC' rev-parse $ARM_B^{tree})\" = 5cdf5ed74707a1e5fb0509a058c1d86aba70d3cb ]"
  check "arm B's test file has the pinned sha256 and arm A does not have it" \
    "[ \"\$(git -C '$SRC' show $ARM_B:$TF | sha256sum | cut -d' ' -f1)\" = af58d2b74ba20c35ec547e70648e0a9de04736edbd5cf6e63c3e3780d2574217 ] && ! git -C '$SRC' cat-file -e $ARM_A:$TF 2>>'$WORK/src.err'"
  check "arm B is arm A plus Python changes under vllm/ and tests/ only, so one precompiled install serves both" \
    "git -C '$SRC' merge-base --is-ancestor $ARM_A $ARM_B && ! git -C '$SRC' diff --name-only $ARM_A $ARM_B | command grep -vqE '^(vllm|tests)/.*\.py$'"
else
  check "VLLM_SRC=$SRC holds both arms ($(cat "$WORK/src.err"))" "false"
fi
check "run.sh records why step 3 is not run, with the issue body's pinned sha256" \
  "command grep -qx 'ISSUE_BODY_SHA256=2f8a4cff3bd0ed230e2c2cd08b3bce4f400e75342060404b31a673072583d4f1' '$KIT/run.sh'"

# ---------------------------------------------------------------- the Python units
python3 -I "$CHECK" "$KIT" "$FAKES" >"$WORK/units.log" 2>&1; rc=$?
check "the unit checks pass ($(command grep -c '^ok' "$WORK/units.log") ok, $(command grep -c '^FAIL' "$WORK/units.log") failed)" "[ $rc = 0 ]"
command grep '^FAIL' "$WORK/units.log" >&2

# ---------------------------------------------------------------- run.sh's arguments and settings
# dry KIT [ARG...] -- [VAR=VALUE...]: run.sh's settings stage only, its output in $WORK/dry.out.
dry() {
  local k=$1; shift
  local args=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do args+=("$1"); shift; done
  [ "${1:-}" = -- ] && shift
  rm -rf "$WORK/dry"
  env -i PATH="$PATH" HOME="$HOME" KIT_DRY_RUN=1 OUT="$WORK/dry" "$@" bash "$k/run.sh" "${args[@]}" >"$WORK/dry.out" 2>&1
}
check "the default settings are accepted and record both steps' commands, step 2's environment, the order and why step 3 is not run" \
  "dry '$KIT' && command grep -qx 'budget_s=1500' '$WORK/dry/settings.txt' && command grep -qx 'unit_cap_s=300' '$WORK/dry/settings.txt' && command grep -qx 'e2e_cap_s=600' '$WORK/dry/settings.txt' \
   && command grep -qx 'command_1=python -m pytest $TF -k not EndToEnd -q -p no:cacheprovider' '$WORK/dry/settings.txt' \
   && command grep -qx 'command_2=CUDA_LAUNCH_BLOCKING=1 VLLM_ENABLE_V1_MULTIPROCESSING=0 python -m pytest $TF::TestHF3FSLoadFailureEndToEnd -q -p no:cacheprovider -x --tb=long' '$WORK/dry/settings.txt' \
   && command grep -qx 'order=arm A steps 1 and 2, then arm B steps 1 and 2' '$WORK/dry/settings.txt' \
   && command grep -q '^command_3=not run; the #69058 issue body (sha256 2f8a4cff' '$WORK/dry/settings.txt'"
check "a positional argument is refused, and nothing is written" "! dry '$KIT' extra && command grep -qF 'takes no arguments' '$WORK/dry.out' && [ ! -e '$WORK/dry' ]"
check "BUDGET_S=1501, which would take the bill toward \$0.50, is refused" "! dry '$KIT' -- BUDGET_S=1501 && command grep -qF 'at most 1500' '$WORK/dry.out'"
check "BUDGET_S that is not whole seconds, at or below the reserve, or with a leading zero is refused" \
  "! dry '$KIT' -- BUDGET_S=10m && ! dry '$KIT' -- BUDGET_S=60 && ! dry '$KIT' -- BUDGET_S=0900"
check "UNIT_CAP_S and E2E_CAP_S with a leading zero or under 30 are refused" \
  "! dry '$KIT' -- UNIT_CAP_S=0300 && command grep -qF 'without a leading zero' '$WORK/dry.out' && ! dry '$KIT' -- E2E_CAP_S=5"
check "earlier kits' PYTEST_CAP_S and LLM_CAP_S are refused rather than ignored" "! dry '$KIT' -- PYTEST_CAP_S=300 && ! dry '$KIT' -- LLM_CAP_S=600"
mkdir -p "$WORK/used" && echo old >"$WORK/used/a-1.log"
env -i PATH="$PATH" HOME="$HOME" KIT_DRY_RUN=1 OUT="$WORK/used" bash "$KIT/run.sh" >"$WORK/used.out" 2>&1; rc=$?
check "an OUT that holds an earlier run is refused" "[ $rc != 0 ] && command grep -qF 'is not empty' '$WORK/used.out'"
m=$(mutant budgetcap run.sh 's/^BUDGET_MAX_S=1500$/BUDGET_MAX_S=1600/')
mcheck "mutant: a run.sh that takes BUDGET_S=1501 is caught" "! { ! dry '$m' -- BUDGET_S=1501 && command grep -qF 'at most' '$WORK/dry.out'; }"
m=$(mutant octal run.sh 's/^\[\[ \$BUDGET_S =~ \^\[1-9\]\[0-9\]\*\$ \]\]/[[ $BUDGET_S =~ ^[0-9]+$ ]]/')
mcheck "mutant: a run.sh that takes BUDGET_S=0900 is caught" "! { ! dry '$m' -- BUDGET_S=0900; }"
m=$(mutant args run.sh 's/^\[ \$# = 0 \] ||/true ||/')
mcheck "mutant: a run.sh that ignores an argument is caught" "! { ! dry '$m' extra && command grep -qF 'takes no arguments' '$WORK/dry.out'; }"

# ---------------------------------------------------------------- the budget against the runner's rates
# The bill runs to bring-up + BUDGET_S + evidence upload + the runner's 360 s from upload deadline to confirmed termination.
S="$ROOT/hack/gpu-kit-session.sh"
rate=$(sed -n 's/^    g5.xlarge) echo "[0-9.]* \([0-9.]*\) [0-9]*" ;;$/\1/p' "$S")
bring=$(sed -n 's/^BRINGUP_S=\([0-9]*\)$/\1/p' "$S")
upl=$(sed -n 's/^EVIDENCE_UPLOAD_S=\([0-9]*\)$/\1/p' "$S")
kit_s=$(sed -n 's/^KIT_S=\([0-9]*\)$/\1/p' "$S")
sched=$(INSTANCE_TYPE=g5.xlarge bash "$S" --print-schedule 2>&1)
tail_s=$(python3 -I -c 'import re,sys; d=dict(re.findall(r"(\w+)=([\w.]+)", sys.argv[1])); print(int(d["termination_s"]) - int(d["evidence_s"]))' "$sched")
kitmax=$(sed -n 's/^BUDGET_MAX_S=\([0-9]*\)$/\1/p' "$KIT/run.sh")
worst=$(python3 -I -c 'import sys; b,k,u,t,r = map(float, sys.argv[1:]); print(f"{(b + k + u + t) / 3600 * r:.4f} {int(b + k + u + t)}")' "${bring:-x}" "${kitmax:-x}" "${upl:-x}" "${tail_s:-x}" "${rate:-x}")
check "the runner's g5.xlarge rate, phases, run.sh window and termination tail read as 0.7683, 300, 60, 3300, 360 ($rate, $bring, $upl, $kit_s, $tail_s)" \
  "[ '$rate $bring $upl $kit_s $tail_s' = '0.7683 300 60 3300 360' ]"
check "BUDGET_S at its maximum, $kitmax s, stays inside the runner's $kit_s s for run.sh" "[ '${kitmax:-0}' -lt '${kit_s:-0}' ]"
check "BUDGET_S at its maximum bills ${worst#* } s and \$${worst% *}, under the approved \$0.50" "python3 -I -c 'import sys; sys.exit(0 if ${worst% *} < 0.50 else 1)'"
check "run.sh's header states that bill, 2,220 s and \$0.4738" "[ '$worst' = '0.4738 2220' ] && command grep -qF 'which is 2,220 s and \$0.4738 at the default 1,500 s' '$KIT/run.sh'"
check "the runner's own backstop for g5.xlarge stays \$0.8579, as run.sh's header says" \
  "[ '$sched' = 'instance_type=g5.xlarge harness_end_s=3600 evidence_s=3660 stop_s=3720 termination_s=4020 worst_case_usd=0.8579' ] && command grep -qF 'session'\''s \$0.8579' '$KIT/run.sh'"

# ---------------------------------------------------------------- end to end on the fakes, with the real checkout
# e2e KIT NAME [VAR=VALUE...]: the whole kit on the fakes into $WORK/e2e-NAME/out; its exit status is run.sh's, or 124 if the outer cap hit.
e2e() {
  local k=$1 n=$2; shift 2
  local d="$WORK/e2e-$n"
  mkdir -p "$d/cwd" "$d/hf"
  ( cd "$d/cwd" && timeout --kill-after=5 "${E2E_OUTER_S:-120}" env PATH="$FAKES:$PATH" KIT_OFFLINE_TEST=1 OFFLINE_VLLM_SRC="$SRC" \
    FAKE_HF_DIR="$d/hf" OFFLINE_MODEL_BIN_SHA256="$FAKE_BIN_SHA256" FAKE_ORDER_LOG="$d/order" OUT="$d/out" "$@" bash "$k/run.sh" >"$d/run.log" 2>&1 )
}
v() { command grep -qx "VERDICT: $2" "$WORK/e2e-$1/out/verdict.txt"; }
vt() { command grep -qF "$2" "$WORK/e2e-$1/out/verdict.txt"; }
order() { [ -f "$WORK/e2e-$1/order" ] && paste -sd' ' "$WORK/e2e-$1/order"; }

e2e "$KIT" pass FAKE_EXPECT_OFFLINE=1; rc=$?
check "pass: step 1 as the spec expects on both arms and step 2 passing is AS EXPECTED, exit 0" "[ $rc = 0 ] && v pass 'AS EXPECTED'"
check "pass: the arms ran A then B, steps 1 then 2 within each" "[ \"\$(order pass)\" = 'a-1 a-2 b-1 b-2' ] \
  && [ \"\$(command grep -oE '^test-[ab]-[12]' '$WORK/e2e-pass/out/status.txt' | paste -sd' ')\" = 'test-a-1 test-a-2 test-b-1 test-b-2' ]"
check "pass: the verdict keeps both arms' step 1 summary lines and the three failures on arm A" \
  "vt pass 'arm A step 1: AS EXPECTED: 3 failed, 1 passed, 2 deselected' && vt pass 'arm B step 1: AS EXPECTED: 4 passed, 2 deselected' \
   && [ \"\$(command grep -c '^  failed: ' '$WORK/e2e-pass/out/verdict.txt')\" = 3 ]"
check "pass: both arms say no illegal access and that step 3 was not run" "vt pass 'arm A illegal memory access: no' && vt pass 'arm B illegal memory access: no' \
  && [ \"\$(command grep -c 'step 3 (run.sh fault, nofault): not run' '$WORK/e2e-pass/out/verdict.txt')\" = 2 ]"
check "pass: every pytest run had the hub offline after the checked download" "command grep -qx 'hub_offline=1 from the first test run on' '$WORK/e2e-pass/out/settings.txt'"
check "pass: the records hold both arms' commits and trees, the test file's sha256 and the model's revision" \
  "command grep -qx 'arm_a commit=$ARM_A tree=8256f29750a8035f563029cfd6c7e1bb40558b0b' '$WORK/e2e-pass/out/versions.txt' \
   && command grep -qx 'arm_b commit=$ARM_B tree=5cdf5ed74707a1e5fb0509a058c1d86aba70d3cb' '$WORK/e2e-pass/out/versions.txt' \
   && command grep -qx 'test_file_sha256=af58d2b74ba20c35ec547e70648e0a9de04736edbd5cf6e63c3e3780d2574217' '$WORK/e2e-pass/out/versions.txt' \
   && command grep -qx 'model_rev=27dcfa74d334bc871f3234de431e71c6eeba5dd6' '$WORK/e2e-pass/out/versions.txt'"
check "pass: arm A had only the copied test file, untracked, and arm B was clean at its commit" \
  "[ \"\$(sed -n 2p '$WORK/e2e-pass/out/tree-a.txt')\" = '?? $TF' ] && [ \"\$(head -1 '$WORK/e2e-pass/out/tree-b.txt')\" = $ARM_B ] && [ \"\$(wc -l < '$WORK/e2e-pass/out/tree-b.txt')\" = 2 ]"
check "pass: the run leaves checksums of everything it wrote and removed its worktree" \
  "( cd '$WORK/e2e-pass/out' && sha256sum -c --quiet SHA256SUMS ) && ! git -C '$SRC' worktree list | command grep -qF '$WORK/e2e-pass/'"

# Step 2's illegal memory access in each shape is a result with its frame, never a harness failure.
for kind in s2_illegal:'frame hf3fs_mock_client.py:110 (logged record)' s2_illegal_tb:'gather_scatter_helper.py:141 in gather (python traceback)' \
  s2_illegal_pt:'__init__.py:1083 (AcceleratorError) (pytest traceback)' s2_crash:'frame hf3fs_mock_client.py:110 (logged record)'; do
  k=${kind%%:*} frame=${kind#*:}
  e2e "$KIT" "$k" FAKE_MODE="$k"; rc=$?
  check "$k: arm B's illegal memory access is reported yes with its frame, as a result, and the run is AS EXPECTED, exit 0" \
    "[ $rc = 0 ] && v $k 'AS EXPECTED' && vt $k 'arm B illegal memory access: yes, first at log line' && vt $k '$frame' && vt $k 'arm B step 2: RESULT' \
     && vt $k 'cause: CUDA illegal memory access' && [ -s '$WORK/e2e-$k/out/b-2-illegal.txt' ] && vt $k 'arm A illegal memory access: no'"
done
e2e "$KIT" s2_kvmem FAKE_MODE=s2_kvmem; rc=$?
check "s2_kvmem: arm A's KV memory failure is NOT RUN with its cause, exit 4" "[ $rc = 4 ] && v s2_kvmem 'NOT RUN' && vt s2_kvmem 'arm A step 2: NOT RUN' && vt s2_kvmem 'cause: KV cache memory'"
e2e "$KIT" s2_fail FAKE_MODE=s2_fail; rc=$?
check "s2_fail: an assertion failure in step 2 is a result, exit 0" "[ $rc = 0 ] && vt s2_fail 'arm A step 2: RESULT' && vt s2_fail \"cause: failed: E           AssertionError: assert 'length' == 'error'\""
e2e "$KIT" s1_finding FAKE_MODE=s1_finding; rc=$?
check "s1_finding: arm B's step 1 with a failure is a FINDING, exit 2" "[ $rc = 2 ] && v s1_finding FINDING && vt s1_finding \"arm B step 1: FINDING\""
e2e "$KIT" s1_nosummary FAKE_MODE=s1_nosummary; rc=$?
check "s1_nosummary: a step 1 with no summary is INCOMPLETE, exit 3" "[ $rc = 3 ] && v s1_nosummary INCOMPLETE"
e2e "$KIT" s2_skip FAKE_MODE=s2_skip; rc=$?
check "s2_skip: step 2 skipped on the GPU is INCOMPLETE, exit 3" "[ $rc = 3 ] && v s2_skip INCOMPLETE"
e2e "$KIT" nocuda FAKE_CUDA=0; rc=$?
check "no CUDA: torch seeing no GPU is INCOMPLETE, exit 3" "[ $rc = 3 ] && v nocuda INCOMPLETE"
e2e "$KIT" hf_fail FAKE_HF=fail; rc=$?
check "a failed model download stops the run before any test, INCOMPLETE" "[ $rc = 1 ] && command grep -qF 'hf download facebook/opt-125m failed' '$WORK/e2e-hf_fail/out/STOPPED' && ! [ -s '$WORK/e2e-hf_fail/order' ]"
e2e "$KIT" hf_badrev FAKE_HF=badrev; rc=$?
check "another model revision stops the run" "[ $rc = 1 ] && command grep -qF 'not the pinned 27dcfa74d334bc871f3234de431e71c6eeba5dd6' '$WORK/e2e-hf_badrev/out/STOPPED'"
e2e "$KIT" hf_badsha FAKE_HF=badsha; rc=$?
check "other weights stop the run" "[ $rc = 1 ] && command grep -qF 'is not the pinned sha256' '$WORK/e2e-hf_badsha/out/STOPPED'"

# A pytest that never returns is cut at its step's cap, and the budget then stops the run.
# With 100 s and a 60 s reserve, arm A's step 1 gets its 30 s cap, step 2 the 10 s left, and arm B nothing.
t0=$(date +%s); e2e "$KIT" hang FAKE_MODE=hang BUDGET_S=100 UNIT_CAP_S=30 E2E_CAP_S=30; rc=$?; took=$(( $(date +%s) - t0 ))
check "hang: each step is cut at its cap or the budget left, the budget stops the run before arm B, and run.sh ends inside BUDGET_S ($took s)" \
  "[ $rc = 1 ] && command grep -qx 'test-a-1 exit=124 t=[0-9]*' '$WORK/e2e-hang/out/status.txt' && command grep -qx 'test-a-2 exit=124 t=[0-9]*' '$WORK/e2e-hang/out/status.txt' \
   && command grep -qF 'the budget ran out before test-b-1' '$WORK/e2e-hang/out/STOPPED' && v hang INCOMPLETE && [ $took -le 100 ]"

# The pins refuse another commit for an arm.
m=$(mutant otherarm run.sh 's/^ARM_B_SHA=9ee44f044e6f3bbc49b96facb4cfda659cd783a5$/ARM_B_SHA=2f170a0fed20fd84dfcf6da2a3a8188a32f67e4e/')
[ -n "$m" ] && e2e "$m" otherarm
mcheck "an arm B pinned to another commit is refused by its tree pin before any test" \
  "command grep -qF 'arm b: commit 2f170a0fed20fd84dfcf6da2a3a8188a32f67e4e has tree' '$WORK/e2e-otherarm/out/STOPPED' && ! [ -s '$WORK/e2e-otherarm/order' ]"

# ---------------------------------------------------------------- mutants of run.sh, caught end to end
m=$(mutant notreepin run.sh 's/^ARM_B_SHA=9ee44f044e6f3bbc49b96facb4cfda659cd783a5$/ARM_B_SHA=2f170a0fed20fd84dfcf6da2a3a8188a32f67e4e/; s/^  \[ "\$tree" = "\$3" \] ||/  true ||/')
[ -n "$m" ] && e2e "$m" m-notreepin
mcheck "mutant: a run.sh without the tree pin runs another commit as arm B and is caught" \
  "! { [ -f '$WORK/e2e-m-notreepin/out/STOPPED' ] && command grep -qF 'has tree' '$WORK/e2e-m-notreepin/out/STOPPED'; }"
m=$(mutant noblocking run.sh 's/^ENV_2=(CUDA_LAUNCH_BLOCKING=1 VLLM_ENABLE_V1_MULTIPROCESSING=0)$/ENV_2=(VLLM_ENABLE_V1_MULTIPROCESSING=0)/')
[ -n "$m" ] && e2e "$m" m-noblocking
mcheck "mutant: a step 2 without CUDA_LAUNCH_BLOCKING=1 does not report AS EXPECTED" "! v m-noblocking 'AS EXPECTED'"
m=$(mutant armorder run.sh 's/^for a in a b; do$/for a in b a; do/')
[ -n "$m" ] && e2e "$m" m-armorder
mcheck "mutant: running arm B before arm A is caught by the order check" "[ \"\$(order m-armorder)\" != 'a-1 a-2 b-1 b-2' ]"
m=$(mutant aisb run.sh 's/^    git -C vllm checkout -q --detach -f "\$ARM_A_SHA" || stop "could not check out arm A"$/    git -C vllm checkout -q --detach -f "$ARM_B_SHA" || stop "could not check out arm A"/')
[ -n "$m" ] && e2e "$m" m-aisb
mcheck "mutant: an arm A that is arm B's whole commit does not report AS EXPECTED" "! v m-aisb 'AS EXPECTED'"
m=$(mutant nocopy run.sh 's/^    git -C vllm show "\$ARM_B_SHA:\$TEST_FILE" > "vllm\/\$TEST_FILE" || stop "could not copy \$TEST_FILE into arm A"$/    true/')
[ -n "$m" ] && e2e "$m" m-nocopy
mcheck "mutant: an arm A without the copied test file does not report AS EXPECTED" "! v m-nocopy 'AS EXPECTED'"
m=$(mutant nounit run.sh 's/^CMD_1=(python -m pytest "\$TEST_FILE" -k "not EndToEnd" -q -p no:cacheprovider)$/CMD_1=(python -m pytest "$TEST_FILE" -q -p no:cacheprovider)/')
[ -n "$m" ] && e2e "$m" m-nounit
mcheck "mutant: a step 1 that does not deselect the end-to-end class does not report AS EXPECTED" "! v m-nounit 'AS EXPECTED'"
m=$(mutant offline run.sh 's/^export HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1$/true/')
[ -n "$m" ] && e2e "$m" m-offline FAKE_EXPECT_OFFLINE=1
mcheck "mutant: a run.sh that leaves the hub online for the tests does not report AS EXPECTED" "! v m-offline 'AS EXPECTED'"
m=$(mutant revcheck run.sh 's/^\[ "\$(basename "\$snap")" = "\$MODEL_REV" \] ||/true ||/')
[ -n "$m" ] && e2e "$m" m-revcheck FAKE_HF=badrev
mcheck "mutant: a run.sh that takes another model revision is caught" "! [ -f '$WORK/e2e-m-revcheck/out/STOPPED' ]"
m=$(mutant notimeout run.sh 's/^  timeout --kill-after=10 "\$cap" "\$@" > "\$log" 2>&1$/  "$@" > "$log" 2>\&1/')
[ -n "$m" ] && { E2E_OUTER_S=90 e2e "$m" m-notimeout FAKE_MODE=hang BUDGET_S=100 UNIT_CAP_S=30 E2E_CAP_S=30; rc=$?; }
mcheck "mutant: a step without its timeout overruns the budget and is caught" "[ \"\${rc:-0}\" = 124 ]"

# ---------------------------------------------------------------- mutants of verdict.py, caught by the unit checks
caught() { ! python3 -I "$CHECK" "$1" "$FAKES" >"$WORK/mutant.log" 2>&1; }
while IFS='|' read -r name sedexpr; do
  [ -n "$name" ] || continue
  m=$(mutant "$name" verdict.py "$sedexpr")
  mcheck "mutant: verdict $name is caught" "caught '$m'"
done <<'MUTANTS'
classifies an illegal access as a harness failure|s/^        rec.update(state="RESULT", cause="CUDA illegal memory access")$/        rec.update(state="NOT RUN", cause="other harness failure")/
checks harness causes before the illegal access|s/^    if illegal:$/    if illegal and not run["summary"]:/
misses an illegal access logged as CUDA_ERROR_ILLEGAL_ADDRESS only|s/^ILLEGAL_RE = re.compile(r"illegal memory access|CUDA_ERROR_ILLEGAL_ADDRESS|cudaErrorIllegalAddress")$/ILLEGAL_RE = re.compile(r"illegal memory access")/
reads logs in text mode|s/ errors="replace", newline="").read())/ errors="replace").read())/
numbers lines with splitlines|s/^    lines = text.split("\\n")$/    lines = text.splitlines()/
takes the outermost Python frame|s/^                inner = frames\[-1\]$/                inner = frames[0]/
gives no frame for a logged record|s/^    if m and not line.startswith("E "):$/    if False:/
gives no frame from pytest's traceback|s/^            s = PYTEST_SITE_RE.match(lines\[j\])$/            s = None/
reads only the =-padded summary|s/^SUMMARY_RE = re.compile(r"^=\*\\s\*(/SUMMARY_RE = re.compile(r"^=+\\s+(/
expects arm A to pass step 1|s/^EXPECTED_1 = {"a": {"failed": 3, "passed": 1}, "b": {"passed": 4}}$/EXPECTED_1 = {"a": {"passed": 4}, "b": {"passed": 4}}/
counts deselected tests|s/ if k not in ("deselected", "warnings")}$/ if k not in ("warnings",)}/
ignores a missing step 1 summary|s/^    if run\["summary"\] is None:$/    if False:/
ignores step 1's exit code|s/^    if rc not in (0, 1):$/    if False:/
ignores an exit code that disagrees with the counts|s/^    if rc != (1 if c.get("failed") or c.get("errors") else 0):$/    if False:/
takes a step 2 skip as a result|s/^    if c.get("skipped"):$/    if False:/
takes a step 2 with no summary as a result|s/^    if run\["summary"\] is None or rc not in (0, 1):$/    if False:/
misses the KV memory cause|s/re.compile(r"KV cache is needed, which is larger than the available KV cache memory")/re.compile(r"NEVER MATCHES")/
reads harness causes from captured logs|s/^    tb = \[x for x in run\["lines"\] if x.startswith(("E ", ">"))\]$/    tb = run["lines"]/
ignores no CUDA|s/^        if env.get("cuda_available") is not True or not env.get("device_name"):$/        if False:/
ignores a stopped run|s/^    if os.path.exists(os.path.join(out, "STOPPED")):$/    if False:/
ranks INCOMPLETE above a FINDING|s/^    if "FINDING" in states:$/    if "FINDING" in states and not rec["gaps"]:/
lets a NOT RUN pass as AS EXPECTED|s/^    elif "NOT RUN" in states:$/    elif False:/
exits 0 on INCOMPLETE|s/{"AS EXPECTED": 0, "FINDING": 2, "NOT RUN": 4}.get(rec\["verdict"\], 3)/{"AS EXPECTED": 0, "FINDING": 2, "NOT RUN": 4}.get(rec["verdict"], 0)/
drops step 3's not-run line|s/^        lines.append(f"arm {arm.upper()} step 3 (run.sh fault, nofault): {rec\['step3'\]}")$/        pass/
writes no illegal-access block|s/^                f.write("\\n".join(ia\["block"\]) + "\\n")$/                pass/
MUTANTS

# ---------------------------------------------------------------- the runner: refusals before any AWS call
check "the runner refuses g6, which the SCP blocks" "! INSTANCE_TYPE=g6.xlarge bash '$S' --print-schedule >/dev/null 2>&1"
mkdir -p "$WORK/awsbin"
cat >"$WORK/awsbin/aws" <<'EOF'
#!/bin/bash
echo "aws $*" >> "$AWS_CALLS"
case "$1 $2" in "sts get-caller-identity") echo 000000000000 ;; esac
exit 0
EOF
chmod +x "$WORK/awsbin/aws"
export AWS_CALLS="$WORK/aws-calls"
# session CLONE OUT [ARG]: the clone's runner on the clone's kit with a fake aws, SESSION_CONFIRM=yes; output in $WORK/session.out.
session() {
  : >"$AWS_CALLS"
  ( cd "$1" && env PATH="$WORK/awsbin:$PATH" AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null SESSION_CONFIRM=yes OUT="$2" \
    SCRATCH="$WORK" bash hack/gpu-kit-session.sh "${3-docs/oss/vllm-69058/kit-r4}" >"$WORK/session.out" 2>&1 )
}
# A clone of a linked worktree checks out the main repository's HEAD, so this tree's own commit is checked out by its SHA.
git clone -q "$ROOT" "$WORK/clone" 2>"$WORK/clone.err" && git -C "$WORK/clone" checkout -q "$(git -C "$ROOT" rev-parse HEAD)" 2>>"$WORK/clone.err"
if [ -f "$WORK/clone/docs/oss/vllm-69058/kit-r4/run.sh" ] && [ -f "$WORK/clone/hack/gpu-kit-session.sh" ]; then
  session "$WORK/clone" "$WORK/out-nokit" docs/oss/vllm-69058; rc=$?
  check "the runner refuses a kit path with no run.sh before any AWS call" "[ $rc != 0 ] && command grep -qF 'has no run.sh' '$WORK/session.out' && [ ! -s '$AWS_CALLS' ]"
  echo junk >"$WORK/clone/hack/untracked.txt"
  session "$WORK/clone" "$WORK/out-dirty"; rc=$?
  check "the runner refuses a tree with an untracked file before any AWS call" \
    "[ $rc != 0 ] && command grep -qF 'working tree is dirty' '$WORK/session.out' && [ ! -s '$AWS_CALLS' ]"
  rm "$WORK/clone/hack/untracked.txt"
  echo '# edit' >>"$WORK/clone/docs/oss/vllm-69058/kit-r4/run.sh"
  session "$WORK/clone" "$WORK/out-modified"; rc=$?
  check "the runner refuses the kit with an uncommitted edit before any AWS call" \
    "[ $rc != 0 ] && command grep -qE 'working tree is dirty|kit has uncommitted or untracked files' '$WORK/session.out' && [ ! -s '$AWS_CALLS' ]"
  git -C "$WORK/clone" checkout -q -- docs/oss/vllm-69058/kit-r4/run.sh
  session "$WORK/clone" "$WORK/out-clean"; rc=$?
  # The fake account is not the lab's, so the clean run stops at the account check, the first step after the tree checks.
  check "the same clone, clean, gets past the tree checks to the (fake) account check and buys nothing" \
    "[ $rc != 0 ] && command grep -q '^aws sts get-caller-identity' '$AWS_CALLS' && command grep -qF 'the account check failed' '$WORK/session.out' \
     && ! command grep -q '^aws ec2 run-instances' '$AWS_CALLS'"
else
  check "the kit and the runner are committed at HEAD, so the runner checks can run ($(cat "$WORK/clone.err"))" "false"
fi

echo
if [ "$failures" = 0 ]; then echo "all checks passed"; else echo "$failures check(s) failed" >&2; exit 1; fi
