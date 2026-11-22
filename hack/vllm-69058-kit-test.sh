#!/usr/bin/env bash
#
# Offline checks for the vLLM #69058 kit r5 in docs/oss/vllm-69058/kit-r5, run before any GPU is bought.
# No GPU, no network and no AWS: python (with pytest), hf and nvidia-smi are the fakes in hack/vllm-69058-fake, and aws is a fake that records its calls.
# The vLLM checkout is real, a detached worktree of a local vLLM repository (VLLM_SRC) that holds the arm and the test file's commit.
# Each verdict rule and each run.sh guard is also run against a mutant that breaks it, and the mutant must be caught.
# The runner checks need the kit committed, since the session ships a commit; they clone this tree's HEAD.
# Kits r1, r3 and r4 were checked by this script's earlier versions, at 2f31a67b, a32a3a10 and 5b2ff327.
#
#   VLLM_SRC=/path/to/vllm bash hack/vllm-69058-kit-test.sh
set -uo pipefail
unset INSTANCE_TYPE KIT_ENV SESSION_CONFIRM AWS_PROFILE
# The checks assert the kit's and the fakes' defaults, so a caller's settings must not reach them.
unset BUDGET_S E2E_CAP_S UNIT_CAP_S PYTEST_CAP_S LLM_CAP_S KIT_DRY_RUN KIT_OFFLINE_TEST OFFLINE_VLLM_SRC OFFLINE_MODEL_BIN_SHA256 \
  FAKE_MODE FAKE_CUDA FAKE_HF FAKE_HF_DIR FAKE_EXPECT_OFFLINE HF_HUB_OFFLINE TRANSFORMERS_OFFLINE VLLM_ENABLE_V1_MULTIPROCESSING CUDA_LAUNCH_BLOCKING
# Python must not leave bytecode beside a mutant, where a same-size edit restored within a second could reuse it.
export PYTHONDONTWRITEBYTECODE=1
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KIT="$ROOT/docs/oss/vllm-69058/kit-r5"
FAKES="$ROOT/hack/vllm-69058-fake"
CHECK="$ROOT/hack/vllm-69058-kit-check.py"
SRC="${VLLM_SRC:-$HOME/workspace/oss/vllm}"
ARM=bb14b99792981d8dcebcce5fe7eacfb46e4258fb
TEST_SRC=9ee44f044e6f3bbc49b96facb4cfda659cd783a5
TF=tests/v1/kv_connector/unit/test_hf3fs_load_failure.py
DIFF_SHA256=8950a5701a0669507eea07d7ed5e2f8cf63a845f6893dce079590e000530cb9a
STORAGE="$HOME/workspace/storage"
STORAGE_REF=93038508:open-source/contributions/vllm/hf3fs-load-errors-69058/review-69095/diag-r5-on-bb14b997.diff
# The fake hf writes "fake pytorch_model.bin" plus a newline as the weights, and this is its sha256.
FAKE_BIN_SHA256=702621c64b6d1269dfb348b9109f388ab469b74f394201717a1b1cd9cd1a5d8b
# Scratch space lives on disk, since /tmp is RAM-backed on the development machine.
SCRATCH="${SCRATCH:-$HOME/.cache/vllm-69058}"
mkdir -p "$SCRATCH" || exit 1
# An empty WORK would turn every "$WORK/..." below, the cleanup's removals included, into a path at the root.
WORK=$(mktemp -d -p "$SCRATCH") && [ -n "$WORK" ] && [ -d "$WORK" ] || { echo "could not make a scratch directory under $SCRATCH" >&2; exit 1; }
# Everything this test and its tools write goes under WORK, which the cleanup removes, so nothing is left in /tmp.
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
  "python3 -I -X pycache_prefix='$WORK/pyc' -m py_compile '$KIT/verdict.py' '$KIT/envprobe.py' '$FAKES/pytest_r5.py' '$CHECK'"
if command -v shellcheck >/dev/null; then
  check "shellcheck finds no error in run.sh" "shellcheck -S error '$KIT/run.sh'"
else
  echo "skip shellcheck is not installed here"
fi

# ---------------------------------------------------------------- the pins
check "the kit's diagnostic patch has the pinned sha256, which starts 8950a5701a066950" \
  "[ \"\$(sha256sum '$KIT/diag-r5-on-bb14b997.diff' | cut -d' ' -f1)\" = $DIFF_SHA256 ] && [ \${DIFF_SHA256:0:16} = 8950a5701a066950 ]"
check "run.sh pins the patch, the arm by commit and tree, the test file's commit by commit and tree, and the test file by sha256" \
  "command grep -qx 'DIFF_SHA256=$DIFF_SHA256' '$KIT/run.sh' && command grep -qx 'ARM_SHA=$ARM' '$KIT/run.sh' && command grep -qx 'ARM_TREE=8256f29750a8035f563029cfd6c7e1bb40558b0b' '$KIT/run.sh' \
   && command grep -qx 'TEST_SRC_SHA=$TEST_SRC' '$KIT/run.sh' && command grep -qx 'TEST_SRC_TREE=5cdf5ed74707a1e5fb0509a058c1d86aba70d3cb' '$KIT/run.sh' \
   && command grep -qx 'TEST_FILE_SHA256=af58d2b74ba20c35ec547e70648e0a9de04736edbd5cf6e63c3e3780d2574217' '$KIT/run.sh' && command grep -qx 'ARM_REF=refs/pull/69095/head' '$KIT/run.sh'"
if git -C "$STORAGE" show "$STORAGE_REF" >"$WORK/storage.diff" 2>"$WORK/storage.err"; then
  check "the kit's patch is byte for byte storage $STORAGE_REF" "cmp -s '$KIT/diag-r5-on-bb14b997.diff' '$WORK/storage.diff'"
  check "storage commit 93038508 is on its origin/main" "git -C '$STORAGE' merge-base --is-ancestor 93038508 origin/main 2>>'$WORK/storage.err'"
else
  check "storage $STORAGE_REF is readable ($(cat "$WORK/storage.err"))" "false"
fi
check "the patch touches only Python files under vllm/" \
  "! command grep '^diff --git ' '$KIT/diag-r5-on-bb14b997.diff' | command grep -vqE '^diff --git a/(vllm/[^ ]*\.py) b/\1$' && command grep -q '^diff --git a/vllm/' '$KIT/diag-r5-on-bb14b997.diff'"
check "the patch's added lines are logging and synchronize calls, no deleted line" \
  "! command grep -E '^-[^-]' '$KIT/diag-r5-on-bb14b997.diff' | command grep -q . && command grep -c 'torch.cuda.synchronize()' '$KIT/diag-r5-on-bb14b997.diff' | command grep -qx 4"

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
check "the default settings are accepted and record the one command exactly as the spec gives it" \
  "dry '$KIT' && command grep -qx 'budget_s=450' '$WORK/dry/settings.txt' && command grep -qx 'e2e_cap_s=360' '$WORK/dry/settings.txt' \
   && command grep -qx 'command=CUDA_LAUNCH_BLOCKING=1 VLLM_ENABLE_V1_MULTIPROCESSING=0 python -m pytest $TF::TestHF3FSLoadFailureEndToEnd -q -p no:cacheprovider --tb=long' '$WORK/dry/settings.txt'"
check "the command has no -x, so both cases run" "! command grep -E '^CMD=.*(-x|--exitfirst)' '$KIT/run.sh'"
check "a positional argument is refused, and nothing is written" "! dry '$KIT' extra && command grep -qF 'takes no arguments' '$WORK/dry.out' && [ ! -e '$WORK/dry' ]"
check "BUDGET_S=451, which would take the bill past \$0.25, is refused" "! dry '$KIT' -- BUDGET_S=451 && command grep -qF 'at most 450' '$WORK/dry.out'"
check "BUDGET_S that is not whole seconds, at or below the reserve, or with a leading zero is refused" \
  "! dry '$KIT' -- BUDGET_S=10m && ! dry '$KIT' -- BUDGET_S=60 && ! dry '$KIT' -- BUDGET_S=0300"
check "E2E_CAP_S with a leading zero or under 30 is refused" "! dry '$KIT' -- E2E_CAP_S=0360 && ! dry '$KIT' -- E2E_CAP_S=5"
check "earlier kits' cap settings are refused rather than ignored" "! dry '$KIT' -- UNIT_CAP_S=300 && ! dry '$KIT' -- LLM_CAP_S=600 && ! dry '$KIT' -- PYTEST_CAP_S=300"
mkdir -p "$WORK/used" && echo old >"$WORK/used/e2e.log"
env -i PATH="$PATH" HOME="$HOME" KIT_DRY_RUN=1 OUT="$WORK/used" bash "$KIT/run.sh" >"$WORK/used.out" 2>&1; rc=$?
check "an OUT that holds an earlier run is refused" "[ $rc != 0 ] && command grep -qF 'is not empty' '$WORK/used.out'"
m=$(mutant budgetcap run.sh 's/^BUDGET_MAX_S=450$/BUDGET_MAX_S=600/')
mcheck "mutant: a run.sh that takes BUDGET_S=451 is caught" "! { ! dry '$m' -- BUDGET_S=451 && command grep -qF 'at most' '$WORK/dry.out'; }"
m=$(mutant octal run.sh 's/^\[\[ \$BUDGET_S =~ \^\[1-9\]\[0-9\]\*\$ \]\]/[[ $BUDGET_S =~ ^[0-9]+$ ]]/')
mcheck "mutant: a run.sh that takes BUDGET_S=0300 is caught" "! { ! dry '$m' -- BUDGET_S=0300; }"
m=$(mutant args run.sh 's/^\[ \$# = 0 \] ||/true ||/')
mcheck "mutant: a run.sh that ignores an argument is caught" "! { ! dry '$m' extra && command grep -qF 'takes no arguments' '$WORK/dry.out'; }"

# ---------------------------------------------------------------- the budget against the runner's rates
# The bill runs to bring-up + BUDGET_S + evidence upload + the runner's 360 s from upload deadline to confirmed termination.
S="$ROOT/hack/gpu-kit-session.sh"
rate=$(sed -n 's/^    g5.xlarge) echo "[0-9.]* \([0-9.]*\) [0-9]*" ;;$/\1/p' "$S")
bring=$(sed -n 's/^BRINGUP_S=\([0-9]*\)$/\1/p' "$S")
upl=$(sed -n 's/^EVIDENCE_UPLOAD_S=\([0-9]*\)$/\1/p' "$S")
sched=$(INSTANCE_TYPE=g5.xlarge bash "$S" --print-schedule 2>&1)
tail_s=$(python3 -I -c 'import re,sys; d=dict(re.findall(r"(\w+)=([\w.]+)", sys.argv[1])); print(int(d["termination_s"]) - int(d["evidence_s"]))' "$sched")
kitmax=$(sed -n 's/^BUDGET_MAX_S=\([0-9]*\)$/\1/p' "$KIT/run.sh")
worst=$(python3 -I -c 'import sys; b,k,u,t,r = map(float, sys.argv[1:]); print(f"{(b + k + u + t) / 3600 * r:.4f} {int(b + k + u + t)}")' "${bring:-x}" "${kitmax:-x}" "${upl:-x}" "${tail_s:-x}" "${rate:-x}")
check "the runner's g5.xlarge rate, phases and termination tail read as 0.7683, 300, 60, 360 ($rate, $bring, $upl, $tail_s)" "[ '$rate $bring $upl $tail_s' = '0.7683 300 60 360' ]"
check "BUDGET_S at its maximum bills ${worst#* } s and \$${worst% *}, at most the asked \$0.25" "python3 -I -c 'import sys; sys.exit(0 if ${worst% *} <= 0.25 else 1)'"
check "run.sh's header states that bill, 1,170 s and \$0.2497" "[ '$worst' = '0.2497 1170' ] && command grep -qF 'which is 1,170 s and \$0.2497 at the default 450 s' '$KIT/run.sh'"
check "the runner's own backstop for g5.xlarge stays \$0.8579, as run.sh's header says" \
  "[ '$sched' = 'instance_type=g5.xlarge harness_end_s=3600 evidence_s=3660 stop_s=3720 termination_s=4020 worst_case_usd=0.8579' ] && command grep -qF 'session'\''s \$0.8579' '$KIT/run.sh'"

# ---------------------------------------------------------------- end to end on the fakes, with the real checkout
# e2e KIT NAME [VAR=VALUE...]: the whole kit on the fakes into $WORK/e2e-NAME/out; its exit status is run.sh's, or 124 if the outer cap hit.
e2e() {
  local k=$1 n=$2; shift 2
  local d="$WORK/e2e-$n"
  mkdir -p "$d/cwd" "$d/hf"
  ( cd "$d/cwd" && timeout --kill-after=5 "${E2E_OUTER_S:-120}" env PATH="$FAKES:$PATH" KIT_OFFLINE_TEST=1 OFFLINE_VLLM_SRC="$SRC" \
    FAKE_HF_DIR="$d/hf" OFFLINE_MODEL_BIN_SHA256="$FAKE_BIN_SHA256" OUT="$d/out" "$@" bash "$k/run.sh" >"$d/run.log" 2>&1 )
}
v() { command grep -qx "VERDICT: $2" "$WORK/e2e-$1/out/verdict.txt"; }
vt() { command grep -qF -- "$2" "$WORK/e2e-$1/out/verdict.txt"; }

e2e "$KIT" pass FAKE_EXPECT_OFFLINE=1; rc=$?
check "pass: both cases fail with the fault and DIAG lines, and the diagnostic is COMPLETE, exit 0" "[ $rc = 0 ] && v pass COMPLETE"
check "pass: each case's verdict has its first illegal access, the last DIAG sync ok before it, and its grep lines" \
  "vt pass 'case [fail]: FAILED+ERROR' && vt pass 'case [recompute]: FAILED' \
   && [ \"\$(command grep -c '^  last DIAG sync ok before it: [0-9]*:.*DIAG step forward sync ok\$' '$WORK/e2e-pass/out/verdict.txt')\" = 2 ] \
   && [ \"\$(command grep -c '^  first illegal memory access: [0-9]*:.*Task execution error: Triton Error \[CUDA\]: an illegal memory access' '$WORK/e2e-pass/out/verdict.txt')\" = 2 ] \
   && vt pass 'DIAG load 7-bb read failed' && vt pass 'Failing 1 request(s)' && vt pass 'Read operation failed for Loaded request 7-bb'"
check "pass: no out-of-range line is claimed" "[ \"\$(command grep -c '^  DIAG save out of range: none\$' '$WORK/e2e-pass/out/verdict.txt')\" = 2 ]"
check "pass: the test ran in a checkout of the arm with exactly the patch's file changed and the copied test file untracked" \
  "[ \"\$(head -1 '$WORK/e2e-pass/out/tree.txt')\" = $ARM ] && command grep -qx ' M vllm/distributed/kv_transfer/kv_connector/v1/hf3fs/hf3fs_connector.py' '$WORK/e2e-pass/out/tree.txt' \
   && command grep -qx '?? $TF' '$WORK/e2e-pass/out/tree.txt' && [ \"\$(command grep -c '^ M \|^?? ' '$WORK/e2e-pass/out/tree.txt')\" = 2 ]"
check "pass: the records hold the commits and trees, the patch's and the test file's sha256, and the model's revision" \
  "command grep -qx 'arm commit=$ARM tree=8256f29750a8035f563029cfd6c7e1bb40558b0b' '$WORK/e2e-pass/out/versions.txt' \
   && command grep -qx 'test_src commit=$TEST_SRC tree=5cdf5ed74707a1e5fb0509a058c1d86aba70d3cb' '$WORK/e2e-pass/out/versions.txt' \
   && command grep -qx 'diff_sha256=$DIFF_SHA256' '$WORK/e2e-pass/out/versions.txt' \
   && command grep -qx 'test_file_sha256=af58d2b74ba20c35ec547e70648e0a9de04736edbd5cf6e63c3e3780d2574217' '$WORK/e2e-pass/out/versions.txt' \
   && command grep -qx 'model_rev=27dcfa74d334bc871f3234de431e71c6eeba5dd6' '$WORK/e2e-pass/out/versions.txt'"
check "pass: the files are checked out under timed steps before any read, the hub is offline, and the full log is kept" \
  "[ \"\$(command grep -oE '^(materialize-test-src|materialize-arm|apply-check|envprobe|test-e2e)' '$WORK/e2e-pass/out/status.txt' | paste -sd' ')\" = 'materialize-test-src materialize-arm apply-check envprobe test-e2e' ] \
   && command grep -qx 'hub_offline=1 for the test run' '$WORK/e2e-pass/out/settings.txt' && [ -s '$WORK/e2e-pass/out/e2e.log' ]"
check "pass: the run leaves checksums of everything it wrote and removed its worktree" \
  "( cd '$WORK/e2e-pass/out' && sha256sum -c --quiet SHA256SUMS ) && ! git -C '$SRC' worktree list | command grep -qF '$WORK/e2e-pass/'"
e2e "$KIT" oor FAKE_MODE=oor; rc=$?
check "oor: the DIAG save out-of-range line is reported for each case" "[ $rc = 0 ] && [ \"\$(command grep -c \"^  DIAG save out of range: \['[0-9]*:.*DIAG save 6-aa block ids out of range\" '$WORK/e2e-oor/out/verdict.txt')\" = 2 ]"
e2e "$KIT" passed FAKE_MODE=pass; rc=$?
check "passed: both cases passing is COMPLETE and says there is nothing to extract" "[ $rc = 0 ] && v passed COMPLETE && vt passed 'no captured output for a passing case'"
e2e "$KIT" skip FAKE_MODE=skip; rc=$?
check "skip: both cases skipped on the GPU is INCOMPLETE, exit 3" "[ $rc = 3 ] && v skip INCOMPLETE"
e2e "$KIT" nosummary FAKE_MODE=nosummary; rc=$?
check "nosummary: pytest dying before its summary is INCOMPLETE, exit 3" "[ $rc = 3 ] && v nosummary INCOMPLETE"
e2e "$KIT" nocuda FAKE_CUDA=0; rc=$?
check "no CUDA is INCOMPLETE, exit 3" "[ $rc = 3 ] && v nocuda INCOMPLETE"
e2e "$KIT" hf_fail FAKE_HF=fail; rc=$?
check "a failed model download stops the run before the test" "[ $rc = 1 ] && command grep -qF 'hf download facebook/opt-125m failed' '$WORK/e2e-hf_fail/out/STOPPED' && ! [ -e '$WORK/e2e-hf_fail/out/e2e.log' ]"
e2e "$KIT" hf_badsha FAKE_HF=badsha; rc=$?
check "other weights stop the run" "[ $rc = 1 ] && command grep -qF 'is not the pinned sha256' '$WORK/e2e-hf_badsha/out/STOPPED'"
t0=$(date +%s); e2e "$KIT" hang FAKE_MODE=hang BUDGET_S=100 E2E_CAP_S=30; rc=$?; took=$(( $(date +%s) - t0 ))
check "hang: the test is cut at its cap, the verdict is INCOMPLETE, and run.sh ends inside BUDGET_S ($took s)" \
  "[ $rc = 3 ] && command grep -qx 'test-e2e exit=124 t=[0-9]*' '$WORK/e2e-hang/out/status.txt' && v hang INCOMPLETE && [ $took -le 100 ]"

cp -r "$KIT" "$WORK/tampered" && printf '\n' >>"$WORK/tampered/diag-r5-on-bb14b997.diff"
e2e "$WORK/tampered" tampered; rc=$?
check "a patch that is not the pinned one stops the run before any checkout" \
  "[ $rc = 1 ] && command grep -qF 'not the pinned' '$WORK/e2e-tampered/out/STOPPED' && ! command grep -q '^worktree-vllm' '$WORK/e2e-tampered/out/status.txt'"
# A patch that also touches a test, with its pin moved to match, must be refused by the file guard.
cp -r "$KIT" "$WORK/testpatch" && printf 'diff --git a/%s b/%s\n' "$TF" "$TF" >>"$WORK/testpatch/diag-r5-on-bb14b997.diff"
sed -i "s/^DIFF_SHA256=.*/DIFF_SHA256=$(sha256sum "$WORK/testpatch/diag-r5-on-bb14b997.diff" | cut -d' ' -f1)/" "$WORK/testpatch/run.sh"
e2e "$WORK/testpatch" testpatch; rc=$?
check "a patch that touches a file outside vllm/'s Python is refused before any checkout" \
  "[ $rc = 1 ] && command grep -qF 'touches a file other than Python under vllm/' '$WORK/e2e-testpatch/out/STOPPED'"

# ---------------------------------------------------------------- mutants of run.sh, caught end to end
m=$(mutant pin run.sh 's/^\[ "\$got" = "\$DIFF_SHA256" \] || stop "the diagnostic patch/true || stop "the diagnostic patch/')
[ -n "$m" ] && cp "$WORK/tampered/diag-r5-on-bb14b997.diff" "$m/" && e2e "$m" m-pin
mcheck "mutant: a run.sh that skips the patch's sha256 pin is caught" "! { [ -f '$WORK/e2e-m-pin/out/STOPPED' ] && command grep -qF 'not the pinned' '$WORK/e2e-m-pin/out/STOPPED'; }"
m=$(mutant fileguard run.sh 's/^! command grep -vE .\^diff --git a\/(vllm\/\[^ \]\*\\.py) b\/\\1\$. "\$OUT\/diff-files.txt" > "\$OUT\/diff-files-outside.txt" ||$/true ||/')
[ -n "$m" ] && cp "$WORK/testpatch/diag-r5-on-bb14b997.diff" "$m/" && sed -i "s/^DIFF_SHA256=.*/DIFF_SHA256=$(sha256sum "$WORK/testpatch/diag-r5-on-bb14b997.diff" | cut -d' ' -f1)/" "$m/run.sh" && e2e "$m" m-fileguard
mcheck "mutant: a run.sh without the patch's file guard is caught" "! command grep -qF 'touches a file other than Python under vllm/' '$WORK/e2e-m-fileguard/out/STOPPED'"
m=$(mutant noblocking run.sh 's/^ENV=(CUDA_LAUNCH_BLOCKING=1 VLLM_ENABLE_V1_MULTIPROCESSING=0)$/ENV=(VLLM_ENABLE_V1_MULTIPROCESSING=0)/')
[ -n "$m" ] && e2e "$m" m-noblocking
mcheck "mutant: the test without CUDA_LAUNCH_BLOCKING=1 does not report COMPLETE" "! v m-noblocking COMPLETE"
m=$(mutant withx run.sh 's/^CMD=(python -m pytest "\$TEST_FILE::TestHF3FSLoadFailureEndToEnd" -q -p no:cacheprovider --tb=long)$/CMD=(python -m pytest "$TEST_FILE::TestHF3FSLoadFailureEndToEnd" -q -p no:cacheprovider -x --tb=long)/')
[ -n "$m" ] && e2e "$m" m-withx
mcheck "mutant: the test with -x does not report COMPLETE" "! v m-withx COMPLETE"
m=$(mutant notreepin run.sh 's/^ARM_SHA=bb14b99792981d8dcebcce5fe7eacfb46e4258fb$/ARM_SHA=2f170a0fed20fd84dfcf6da2a3a8188a32f67e4e/; s/^  \[ "\$tree" = "\$3" \] ||/  true ||/')
[ -n "$m" ] && e2e "$m" m-notreepin
mcheck "mutant: a run.sh without the tree pin runs another commit and is caught" "! { [ -f '$WORK/e2e-m-notreepin/out/STOPPED' ] && command grep -qF 'has tree' '$WORK/e2e-m-notreepin/out/STOPPED'; }"
m=$(mutant nopatch run.sh 's/^git -C vllm apply "\$DIFF" || stop "the diagnostic patch did not apply"$/true/; s/^cmp -s "\$OUT\/changed.txt" "\$OUT\/diff-names.txt" ||/true ||/')
[ -n "$m" ] && e2e "$m" m-nopatch
mcheck "mutant: a run without the diagnostic patch does not report COMPLETE" "! v m-nopatch COMPLETE"
m=$(mutant offline run.sh 's/^export HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1$/true/')
[ -n "$m" ] && e2e "$m" m-offline FAKE_EXPECT_OFFLINE=1
mcheck "mutant: a run.sh that leaves the hub online for the test does not report COMPLETE" "! v m-offline COMPLETE"
m=$(mutant notimeout run.sh 's/^  timeout --kill-after=10 "\$cap" "\$@" > "\$log" 2>&1$/  "$@" > "$log" 2>\&1/')
[ -n "$m" ] && { E2E_OUTER_S=90 e2e "$m" m-notimeout FAKE_MODE=hang BUDGET_S=100 E2E_CAP_S=30; rc=$?; }
mcheck "mutant: a step without its timeout overruns the budget and is caught" "[ \"\${rc:-0}\" = 124 ]"

# ---------------------------------------------------------------- mutants of verdict.py, caught by the unit checks
caught() { ! python3 -I "$CHECK" "$1" "$FAKES" >"$WORK/mutant.log" 2>&1; }
while IFS='|' read -r name sedexpr; do
  [ -n "$name" ] || continue
  m=$(mutant "$name" verdict.py "$sedexpr")
  mcheck "mutant: verdict $name is caught" "caught '$m'"
done <<'MUTANTS'
drops Failing from the grep|s/^GREP_RE = re.compile(r"DIAG|illegal|Failing|Read operation failed")$/GREP_RE = re.compile(r"DIAG|illegal|Read operation failed")/
finds no DIAG sync|s/^SYNC_OK_RE = re.compile(r"DIAG .\*sync ok")$/SYNC_OK_RE = re.compile(r"NEVER MATCHES")/
takes the first DIAG sync instead of the last|s/^            last_sync = next(((i, x) for i, x in reversed(block\[:hit\]) if SYNC_OK_RE.search(x)), None)$/            last_sync = next(((i, x) for i, x in block[:hit] if SYNC_OK_RE.search(x)), None)/
takes a DIAG sync after the fault|s/^            last_sync = next(((i, x) for i, x in reversed(block\[:hit\]) if SYNC_OK_RE.search(x)), None)$/            last_sync = next(((i, x) for i, x in reversed(block) if SYNC_OK_RE.search(x)), None)/
misses out-of-range lines|s/^OUT_OF_RANGE_RE = re.compile(r"DIAG save .\*out of range")$/OUT_OF_RANGE_RE = re.compile(r"NEVER MATCHES")/
orders by the file instead of the captured blocks|s/^    for block in (b for s in sections for b in captured_blocks(s)):$/    for block in ():/
numbers lines from zero|s/^    for i, line in enumerate(lines, start=1):$/    for i, line in enumerate(lines):/
reads logs in text mode|s/ errors="replace", newline="").read())$/ errors="replace").read())/
calls an unlisted case passed|s/^    covered = parsed\["summary"\] is not None and parsed\["counts"\].get("passed", 0) == len(unlisted)$/    covered = parsed["summary"] is not None/
ignores a case with no outcome|s/^            if rec\["cases"\]\[case\]\["outcome"\] == "not run or unknown":$/            if False:/
ignores a run with no DIAG line|s/^        if not any("DIAG" in x for x in parsed\["lines"\]) and parsed\["summary"\] and any(parsed\["outcomes"\].values()):$/        if False:/
ignores a missing summary|s/^        if parsed\["summary"\] is None:$/        if False:/
ignores pytest's exit code|s/^        elif rc not in (0, 1):$/        elif False:/
ignores skips|s/^        if parsed\["counts"\].get("skipped"):$/        if False:/
ignores no CUDA|s/^        if env.get("cuda_available") is not True or not env.get("device_name"):$/        if False:/
ignores a stopped run|s/^    if os.path.exists(os.path.join(out, "STOPPED")):$/    if False:/
accepts a failed case with no DIAG of its own|s/^            if c\["outcome"\] not in ("passed", "not run or unknown") and not own_diag:$/            if False:/
never flags a case that ran after an earlier fault|s/^            if c\["first_illegal"\] and not earlier_fault:$/            if False:/
exits 0 on INCOMPLETE|s/^    return 0 if rec\["verdict"\] == "COMPLETE" else 3$/    return 0/
MUTANTS

# ---------------------------------------------------------------- the runner: refusals before any AWS call
check "the runner refuses g6, which the SCP blocks" "! INSTANCE_TYPE=g6.xlarge bash '$S' --print-schedule >'$WORK/g6.out' 2>&1"
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
    SCRATCH="$WORK" bash hack/gpu-kit-session.sh "${3-docs/oss/vllm-69058/kit-r5}" >"$WORK/session.out" 2>&1 )
}
# A clone of a linked worktree checks out the main repository's HEAD, so this tree's own commit is checked out by its SHA.
git clone -q "$ROOT" "$WORK/clone" 2>"$WORK/clone.err" && git -C "$WORK/clone" checkout -q "$(git -C "$ROOT" rev-parse HEAD)" 2>>"$WORK/clone.err"
if [ -f "$WORK/clone/docs/oss/vllm-69058/kit-r5/run.sh" ] && [ -f "$WORK/clone/hack/gpu-kit-session.sh" ]; then
  session "$WORK/clone" "$WORK/out-nokit" docs/oss/vllm-69058; rc=$?
  check "the runner refuses a kit path with no run.sh before any AWS call" "[ $rc != 0 ] && command grep -qF 'has no run.sh' '$WORK/session.out' && [ ! -s '$AWS_CALLS' ]"
  echo junk >"$WORK/clone/hack/untracked.txt"
  session "$WORK/clone" "$WORK/out-dirty"; rc=$?
  check "the runner refuses a tree with an untracked file before any AWS call" \
    "[ $rc != 0 ] && command grep -qF 'working tree is dirty' '$WORK/session.out' && [ ! -s '$AWS_CALLS' ]"
  rm "$WORK/clone/hack/untracked.txt"
  echo '# edit' >>"$WORK/clone/docs/oss/vllm-69058/kit-r5/run.sh"
  session "$WORK/clone" "$WORK/out-modified"; rc=$?
  check "the runner refuses the kit with an uncommitted edit before any AWS call" \
    "[ $rc != 0 ] && command grep -qE 'working tree is dirty|kit has uncommitted or untracked files' '$WORK/session.out' && [ ! -s '$AWS_CALLS' ]"
  git -C "$WORK/clone" checkout -q -- docs/oss/vllm-69058/kit-r5/run.sh
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
