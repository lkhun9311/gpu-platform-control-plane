#!/usr/bin/env bash
#
# Offline checks for the vLLM #69058 kit in docs/oss/vllm-69058/kit-r1, run before any GPU is bought.
# No GPU, no network and no AWS: pytest, python, hf and nvidia-smi are the fakes in hack/vllm-69058-fake, and aws is a fake that records its calls.
# The vLLM checkout is real, a detached worktree at the pinned commit of a local vLLM repository (VLLM_SRC), so the pinned diff is applied for real.
# Each verdict rule and each run.sh guard is also run against a mutant that breaks it, and the mutant must be caught.
# The runner checks need the kit committed, since the session ships a commit; they clone this tree's HEAD.
#
#   VLLM_SRC=/path/to/vllm bash hack/vllm-69058-kit-test.sh
set -uo pipefail
unset INSTANCE_TYPE KIT_ENV SESSION_CONFIRM AWS_PROFILE
# The checks assert the kit's and the fakes' defaults, so a caller's settings must not reach them.
unset BUDGET_S PYTEST_CAP_S LLM_CAP_S KIT_DRY_RUN KIT_OFFLINE_TEST OFFLINE_VLLM_SRC OFFLINE_MODEL_BIN_SHA256 FAKE_MODE FAKE_CUDA FAKE_HF FAKE_HF_DIR \
  FAKE_EXPECT_OFFLINE HF_HUB_OFFLINE TRANSFORMERS_OFFLINE VLLM_ENABLE_V1_MULTIPROCESSING
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KIT="$ROOT/docs/oss/vllm-69058/kit-r1"
FAKES="$ROOT/hack/vllm-69058-fake"
CHECK="$ROOT/hack/vllm-69058-kit-check.py"
SRC="${VLLM_SRC:-$HOME/workspace/oss/vllm}"
VLLM_SHA=2f170a0fed20fd84dfcf6da2a3a8188a32f67e4e
DIFF_SHA256=210caa5fa2f391720dabba5445d297bc414c31ebf650358b8325009644ecf11d
# The runtime session re-pinned the diff at storage commit b7dc8449, its round-4 draft, so the comparison reads that commit, not the file as it is now.
STORAGE="$HOME/workspace/storage"
STORAGE_REF=b7dc8449:open-source/contributions/vllm/hf3fs-load-errors-69058/local-fix.diff
# The fake hf writes "fake pytorch_model.bin" plus a newline as the weights, and this is its sha256.
FAKE_BIN_SHA256=702621c64b6d1269dfb348b9109f388ab469b74f394201717a1b1cd9cd1a5d8b
# Scratch space lives on disk, since /tmp is RAM-backed on the development machine.
SCRATCH="${SCRATCH:-$HOME/.cache/vllm-69058}"
mkdir -p "$SCRATCH" || exit 1
# An empty WORK would turn every "$WORK/..." below, the cleanup's removals included, into a path at the root.
WORK=$(mktemp -d -p "$SCRATCH") && [ -n "$WORK" ] && [ -d "$WORK" ] || { echo "could not make a scratch directory under $SCRATCH" >&2; exit 1; }
cleanup() {
  # Worktrees the e2e runs added to the local vLLM repository are removed even when a run stopped before its own cleanup.
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
check "run.sh, this test and the shell fakes parse" "bash -n '$KIT/run.sh' && bash -n '$0' && bash -n '$FAKES/python' && bash -n '$FAKES/nvidia-smi' && bash -n '$FAKES/hf'"
check "the kit's Python, the fake pytest and the checker compile" \
  "python3 -I -X pycache_prefix='$WORK/pyc' -m py_compile '$KIT/verdict.py' '$KIT/envprobe.py' '$FAKES/pytest' '$CHECK'"
if command -v shellcheck >/dev/null; then
  check "shellcheck finds no error in run.sh" "shellcheck -S error '$KIT/run.sh'"
else
  echo "skip shellcheck is not installed here"
fi

# ---------------------------------------------------------------- the pinned diff, applied to a local checkout of the pinned commit
check "the kit's diff has the pinned sha256" "[ \"\$(sha256sum '$KIT/local-fix.diff' | cut -d' ' -f1)\" = $DIFF_SHA256 ]"
check "run.sh pins the same sha256 and commit" "command grep -qx 'DIFF_SHA256=$DIFF_SHA256' '$KIT/run.sh' && command grep -qx 'VLLM_SHA=$VLLM_SHA' '$KIT/run.sh'"
check "run.sh pins opt-125m at 27dcfa74d3 with the hub's sha256 for pytorch_model.bin" \
  "command grep -qx 'MODEL_REV=27dcfa74d334bc871f3234de431e71c6eeba5dd6' '$KIT/run.sh' && command grep -qx 'MODEL_BIN_SHA256=2d74da6615135c58cf3cf9ad4cb11e7c613ff9e55fe658a47ab83b6c8d1174a9' '$KIT/run.sh'"
if git -C "$STORAGE" show "$STORAGE_REF" >"$WORK/storage.diff" 2>"$WORK/storage.err"; then
  check "the kit's diff is byte for byte storage $STORAGE_REF" "cmp -s '$KIT/local-fix.diff' '$WORK/storage.diff'"
  # A newer draft in storage is reported, not taken: the kit runs what the spec pinned.
  cmp -s "$KIT/local-fix.diff" "$STORAGE/${STORAGE_REF#*:}" ||
    echo "note storage's working copy of the diff differs from $STORAGE_REF (sha256 $(sha256sum "$STORAGE/${STORAGE_REF#*:}" | cut -d' ' -f1)); the kit keeps the pinned one"
else
  echo "skip storage $STORAGE_REF is not readable here: $(cat "$WORK/storage.err")"
fi
if git -C "$SRC" cat-file -e "$VLLM_SHA^{commit}" 2>"$WORK/src.err"; then
  git -C "$SRC" worktree add -q --detach "$WORK/apply" "$VLLM_SHA" >"$WORK/apply.log" 2>&1
  check "a local checkout at $VLLM_SHA takes the whole diff" "git -C '$WORK/apply' apply --check '$KIT/local-fix.diff'"
  check "the base side, the diff's tests/ part, leaves everything under vllm/ untouched" \
    "git -C '$WORK/apply' apply --include='tests/*' '$KIT/local-fix.diff' && git -C '$WORK/apply' diff --quiet HEAD -- vllm/ && ! git -C '$WORK/apply' diff --quiet HEAD -- tests/"
  git -C "$WORK/apply" reset -q --hard
else
  check "VLLM_SRC=$SRC holds $VLLM_SHA ($(cat "$WORK/src.err"))" "false"
fi

# ---------------------------------------------------------------- the Python units
python3 -I "$CHECK" "$KIT" "$FAKES/cpu-logs" >"$WORK/units.log" 2>&1; rc=$?
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
check "the default settings are accepted and recorded, the three commands and (c)'s environment included" \
  "dry '$KIT' && command grep -qx 'budget_s=3200' '$WORK/dry/settings.txt' && command grep -qx 'llm_cap_s=900' '$WORK/dry/settings.txt' \
   && command grep -qx 'command_a=pytest tests/v1/kv_connector/unit/test_hf3fs_connector.py -k TestHF3FSLoadErrors or TestHF3FSSchedulerLoadFailure -rA' '$WORK/dry/settings.txt' \
   && command grep -qx 'command_c=cd tests && pytest -v -s v1/kv_connector/unit/test_hf3fs_connector.py -k TestHF3FSLoadFailureEndToEnd -rA' '$WORK/dry/settings.txt' \
   && command grep -qx 'command_c_env=VLLM_ENABLE_V1_MULTIPROCESSING=0' '$WORK/dry/settings.txt' \
   && command grep -qx 'command_b=pytest tests/v1/kv_connector/unit/test_hf3fs_connector.py -rA' '$WORK/dry/settings.txt'"
check "a positional argument is refused, and nothing is written" "! dry '$KIT' extra && command grep -qF 'takes no arguments' '$WORK/dry.out' && [ ! -e '$WORK/dry' ]"
check "BUDGET_S=3201, past the session's 3,300 s for run.sh less a margin, is refused" "! dry '$KIT' -- BUDGET_S=3201 && command grep -qF 'at most 3200' '$WORK/dry.out'"
check "BUDGET_S that is not whole seconds is refused" "! dry '$KIT' -- BUDGET_S=10m"
check "BUDGET_S at or below the verdict reserve is refused" "! dry '$KIT' -- BUDGET_S=60"
check "BUDGET_S with a leading zero, which bash would read as octal, is refused" "! dry '$KIT' -- BUDGET_S=0900 && ! dry '$KIT' -- BUDGET_S=01500"
check "PYTEST_CAP_S and LLM_CAP_S with a leading zero are refused" \
  "! dry '$KIT' -- PYTEST_CAP_S=090 && command grep -qF 'without a leading zero' '$WORK/dry.out' && ! dry '$KIT' -- LLM_CAP_S=0900"
check "PYTEST_CAP_S and LLM_CAP_S under 30 are refused" "! dry '$KIT' -- PYTEST_CAP_S=5 && command grep -qF 'at least 30' '$WORK/dry.out' && ! dry '$KIT' -- LLM_CAP_S=5"
check "BUDGET_S=900 is accepted" "dry '$KIT' -- BUDGET_S=900 && command grep -qx 'budget_s=900' '$WORK/dry/settings.txt'"
mkdir -p "$WORK/used" && echo old >"$WORK/used/base-a.log"
env -i PATH="$PATH" HOME="$HOME" KIT_DRY_RUN=1 OUT="$WORK/used" bash "$KIT/run.sh" >"$WORK/used.out" 2>&1; rc=$?
check "an OUT that holds an earlier run is refused" "[ $rc != 0 ] && command grep -qF 'is not empty' '$WORK/used.out'"
m=$(mutant budgetcap run.sh 's/^BUDGET_MAX_S=3200$/BUDGET_MAX_S=3300/')
mcheck "mutant: a run.sh that takes BUDGET_S=3201 is caught" "! { ! dry '$m' -- BUDGET_S=3201 && command grep -qF 'at most' '$WORK/dry.out'; }"
m=$(mutant octal run.sh 's/^\[\[ \$BUDGET_S =~ \^\[1-9\]\[0-9\]\*\$ \]\]/[[ $BUDGET_S =~ ^[0-9]+$ ]]/')
mcheck "mutant: a run.sh that takes BUDGET_S=01500 is caught" "! { ! dry '$m' -- BUDGET_S=0900 && ! dry '$m' -- BUDGET_S=01500; }"
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
check "BUDGET_S at its maximum bills ${worst#* } s and \$${worst% *}, under the approved \$1.00" "python3 -I -c 'import sys; sys.exit(0 if ${worst% *} < 1.00 else 1)'"
check "run.sh's header states that bill, 3,920 s and \$0.8366" "[ '$worst' = '0.8366 3920' ] && command grep -qF 'which is 3,920 s and \$0.8366 at the default 3,200 s' '$KIT/run.sh'"
check "the runner's own backstop for g5.xlarge stays \$0.8579, as run.sh's header says" \
  "[ '$sched' = 'instance_type=g5.xlarge harness_end_s=3600 evidence_s=3660 stop_s=3720 termination_s=4020 worst_case_usd=0.8579' ] && command grep -qF 'session'\''s \$0.8579' '$KIT/run.sh'"

# ---------------------------------------------------------------- end to end on the fakes, with the real checkout
# e2e KIT NAME [VAR=VALUE...]: the whole kit on the fakes into $WORK/e2e-NAME/out; its exit status is run.sh's, or 124 if the outer cap hit.
e2e() {
  local k=$1 n=$2; shift 2
  local d="$WORK/e2e-$n"
  mkdir -p "$d/cwd" "$d/hf"
  ( cd "$d/cwd" && timeout --kill-after=5 "${E2E_CAP_S:-120}" env PATH="$FAKES:$PATH" KIT_OFFLINE_TEST=1 OFFLINE_VLLM_SRC="$SRC" \
    FAKE_HF_DIR="$d/hf" OFFLINE_MODEL_BIN_SHA256="$FAKE_BIN_SHA256" OUT="$d/out" "$@" bash "$k/run.sh" >"$d/run.log" 2>&1 )
}
v() { command grep -qx "VERDICT: $2" "$WORK/e2e-$1/out/verdict.txt"; }
vc() { command grep -qx "VERDICT (c): $2" "$WORK/e2e-$1/out/verdict.txt"; }
vu() { command grep -qx "VERDICT (a,b): $2" "$WORK/e2e-$1/out/verdict.txt"; }
order() { command grep -oE '^test-[a-z]+-[abc]' "$WORK/e2e-$1/out/status.txt" | paste -sd' '; }

e2e "$KIT" pass FAKE_EXPECT_OFFLINE=1; rc=$?
check "pass: base fails and the fix passes in (a), (c) and (b), so the kit reports AS EXPECTED twice and exits 0" "[ $rc = 0 ] && v pass 'AS EXPECTED' && vu pass 'AS EXPECTED' && vc pass 'AS EXPECTED'"
check "pass: the six runs ran in the order a, c, b, base before fix, with the spec's commands and (c) in tests/ with its environment" \
  "[ \"\$(order pass)\" = 'test-base-a test-fix-a test-base-c test-fix-c test-base-b test-fix-b' ]"
check "pass: every pytest run had the hub offline after the checked download" "command grep -qx 'hub_offline=1 from the first test run on' '$WORK/e2e-pass/out/settings.txt'"
check "pass: the model's revision and file hashes are recorded" \
  "command grep -qx 'model_rev=27dcfa74d334bc871f3234de431e71c6eeba5dd6' '$WORK/e2e-pass/out/versions.txt' && [ \"\$(wc -l < '$WORK/e2e-pass/out/model-files.sha256')\" = 7 ] \
   && command grep -qx '$FAKE_BIN_SHA256  pytorch_model.bin' '$WORK/e2e-pass/out/model-files.sha256'"
check "pass: the CUDA-only test line says base FAILED, fix PASSED" \
  "command grep -qx 'CUDA-only test test_failed_batch_reported_when_last_batch_succeeds: base FAILED, fix PASSED' '$WORK/e2e-pass/out/verdict.txt'"
check "pass: the end-to-end lines say where base failed and that the fix passed" \
  "command grep -qxF 'end-to-end base test_failed_read_honors_policy[fail]: state=FAILED at=assert retry.finish_reason == \"error\"' '$WORK/e2e-pass/out/verdict.txt' \
   && command grep -qxF 'end-to-end base test_failed_read_honors_policy[recompute]: state=FAILED at=assert retry.token_ids == cold.token_ids' '$WORK/e2e-pass/out/verdict.txt' \
   && command grep -qxF 'end-to-end fix test_failed_read_honors_policy[recompute]: state=PASSED' '$WORK/e2e-pass/out/verdict.txt'"
check "pass: the verdict keeps each summary line with its time and the failing assertion lines" \
  "command grep -qE '^base-a \(exit 1\): =+ 8 failed, 18 deselected, 1 warning in [0-9.]+s =+$' '$WORK/e2e-pass/out/verdict.txt' && command grep -qF 'AssertionError: assert 10 == 8' '$WORK/e2e-pass/out/verdict.txt' \
   && command grep -qE '^fix-c \(exit 0\): =+ 2 passed, 24 deselected' '$WORK/e2e-pass/out/verdict.txt' && command grep -qE '^fix-b \(exit 0\): =+ 26 passed' '$WORK/e2e-pass/out/verdict.txt'"
check "pass: no finding outside the ten" "! command grep -q '^FINDING' '$WORK/e2e-pass/out/verdict.txt'"
check "pass: the records hold the GPU, the versions, the checkout SHA and the diff's sha256" \
  "command grep -q 'A10G' '$WORK/e2e-pass/out/gpu.txt' && command grep -qx 'vllm_head=$VLLM_SHA' '$WORK/e2e-pass/out/versions.txt' \
   && command grep -qx 'diff_sha256=$DIFF_SHA256' '$WORK/e2e-pass/out/versions.txt' && command grep -q '\"torch\"' '$WORK/e2e-pass/out/versions.txt'"
check "pass: the base tree changed only the test file and the fix tree all three files" \
  "[ \"\$(command grep -c '^ M ' '$WORK/e2e-pass/out/tree-base.txt')\" = 1 ] && [ \"\$(command grep -c '^ M ' '$WORK/e2e-pass/out/tree-fix.txt')\" = 3 ]"
check "pass: the run leaves checksums of everything it wrote" "( cd '$WORK/e2e-pass/out' && sha256sum -c --quiet SHA256SUMS )"
check "pass: the run removed its worktree of the local repository" "! git -C '$SRC' worktree list | command grep -qF '$WORK/e2e-pass/'"

e2e "$KIT" fixfail FAKE_MODE=fixfail; rc=$?
check "(a) fail: the CUDA-only test failing with the fix is NOT AS EXPECTED, exit 2" "[ $rc = 2 ] && vu fixfail 'NOT AS EXPECTED' && vc fixfail 'AS EXPECTED'"
e2e "$KIT" basepass FAKE_MODE=basepass; rc=$?
check "(a) fail: the CUDA-only test passing on base is NOT AS EXPECTED, exit 2" "[ $rc = 2 ] && vu basepass 'NOT AS EXPECTED'"
e2e "$KIT" skip FAKE_MODE=skip; rc=$?
check "(a) skip: a skipped CUDA-only test is INCOMPLETE, exit 3, never a pass" "[ $rc = 3 ] && vu skip INCOMPLETE"
e2e "$KIT" nosummary FAKE_MODE=nosummary; rc=$?
check "missing: pytest stopping before its summary is INCOMPLETE, exit 3" "[ $rc = 3 ] && v nosummary INCOMPLETE"
e2e "$KIT" error FAKE_MODE=error; rc=$?
check "(a) error: a setup error with the fix is INCOMPLETE, exit 3" "[ $rc = 3 ] && vu error INCOMPLETE"
e2e "$KIT" outside FAKE_MODE=outside; rc=$?
check "(b) finding: an older test that only base fails is named as a FINDING and the kit exits 2, not AS EXPECTED" \
  "[ $rc = 2 ] && vu outside 'NOT AS EXPECTED' && command grep -qx 'FINDING outside the ten: tests/v1/kv_connector/unit/test_hf3fs_connector.py::TestHf3fsMockClient::test_multiple_tensors_rw: base FAILED, fix PASSED' '$WORK/e2e-outside/out/verdict.txt'"
e2e "$KIT" nocuda FAKE_CUDA=0; rc=$?
check "no CUDA: torch seeing no GPU is INCOMPLETE for both, exit 3" "[ $rc = 3 ] && vu nocuda INCOMPLETE && vc nocuda INCOMPLETE"

# The (c) rules end to end.
e2e "$KIT" c_basepass FAKE_MODE=c_basepass; rc=$?
check "(c) fail: [fail] passing on base is NOT AS EXPECTED, exit 2" "[ $rc = 2 ] && vc c_basepass 'NOT AS EXPECTED' && vu c_basepass 'AS EXPECTED'"
e2e "$KIT" c_fixfail FAKE_MODE=c_fixfail; rc=$?
check "(c) fail: [recompute] failing its token comparison with the fix is NOT AS EXPECTED, exit 2" "[ $rc = 2 ] && vc c_fixfail 'NOT AS EXPECTED'"
e2e "$KIT" c_rbase FAKE_MODE=c_recompute_basepass; rc=$?
check "(c) [recompute] passing on base is recorded and the kit still reports AS EXPECTED" \
  "[ $rc = 0 ] && vc c_rbase 'AS EXPECTED' && command grep -qxF 'end-to-end base test_failed_read_honors_policy[recompute]: state=PASSED' '$WORK/e2e-c_rbase/out/verdict.txt'"
e2e "$KIT" c_skip FAKE_MODE=c_skip; rc=$?
check "(c) skip: skipped end-to-end tests are INCOMPLETE, exit 3" "[ $rc = 3 ] && vc c_skip INCOMPLETE"
for kind in timeout:'timeout in the 60 s wait for stored keys' oom:'OOM with two LLM instances' layout:'KV layout registration error' \
  noread:'the failing read never reached HF3FS' error:'other harness failure (ERROR)'; do
  k=${kind%%:*} cause=${kind#*:}
  e2e "$KIT" "c_$k" FAKE_MODE="c_$k"; rc=$?
  check "(c) NOT RUN: a $k failure is reported as NOT RUN with its cause, exit 4, never a verdict" \
    "[ $rc = 4 ] && vc c_$k 'NOT RUN' && v c_$k 'NOT RUN' && command grep -qF 'NOT RUN (c): ' '$WORK/e2e-c_$k/out/verdict.txt' && command grep -qF ': $cause' '$WORK/e2e-c_$k/out/verdict.txt'"
done

# The model download's three ways to fail, each leaving (c) NOT RUN while (a) and (b) still run.
for kind in fail:'hf download facebook/opt-125m exited non-zero' badrev:'not the pinned 27dcfa74d334bc871f3234de431e71c6eeba5dd6' badsha:'is not the pinned sha256'; do
  k=${kind%%:*} cause=${kind#*:}
  e2e "$KIT" "hf_$k" FAKE_HF="$k"; rc=$?
  check "model $k: (c) is NOT RUN with the cause, it never ran, the hub stayed online, and (a) and (b) still decided" \
    "[ $rc = 4 ] && vc hf_$k 'NOT RUN' && vu hf_$k 'AS EXPECTED' && command grep -qF '$cause' '$WORK/e2e-hf_$k/out/c-not-run.txt' \
     && [ \"\$(order hf_$k)\" = 'test-base-a test-fix-a test-base-b test-fix-b' ] && ! command grep -q '^hub_offline' '$WORK/e2e-hf_$k/out/settings.txt'"
  check "model $k: (b) ran with the end-to-end class deselected, on both sides" \
    "command grep -qx 'command_b_run=pytest tests/v1/kv_connector/unit/test_hf3fs_connector.py -k not TestHF3FSLoadFailureEndToEnd -rA (the end-to-end class deselected, since (c) is not run)' '$WORK/e2e-hf_$k/out/settings.txt' \
     && ! command grep -q 'TestHF3FSLoadFailureEndToEnd' '$WORK/e2e-hf_$k/out/base-b.log' '$WORK/e2e-hf_$k/out/fix-b.log'"
done
m=$(mutant bkeepe2e run.sh 's/^  CMD_B=(pytest "\$TEST_FILE" -k "not TestHF3FSLoadFailureEndToEnd" -rA)$/  true/')
[ -n "$m" ] && e2e "$m" m-bkeepe2e FAKE_HF=fail
mcheck "mutant: a run.sh that still runs the end-to-end class in (b) after a failed download is caught" \
  "command grep -q 'TestHF3FSLoadFailureEndToEnd' '$WORK/e2e-m-bkeepe2e/out/base-b.log'"

# A pytest that never returns is cut at PYTEST_CAP_S, and the budget then stops the run before (c).
# With 100 s and a 60 s reserve, base-a gets its 30 s cap, fix-a the 10 s left, and base-c nothing.
t0=$(date +%s); e2e "$KIT" hang FAKE_MODE=hang BUDGET_S=100 PYTEST_CAP_S=30; rc=$?; took=$(( $(date +%s) - t0 ))
check "hang: each pytest is cut at its cap or the budget left, the budget stops the run, the verdict is INCOMPLETE, and run.sh ends inside BUDGET_S ($took s)" \
  "[ $rc = 1 ] && command grep -qx 'test-base-a exit=124 t=[0-9]*' '$WORK/e2e-hang/out/status.txt' && command grep -qx 'test-fix-a exit=124 t=[0-9]*' '$WORK/e2e-hang/out/status.txt' \
   && command grep -qF 'the budget ran out before test-base-c' '$WORK/e2e-hang/out/STOPPED' && v hang INCOMPLETE && [ $took -le 100 ]"

cp -r "$KIT" "$WORK/tampered" && printf '\n' >>"$WORK/tampered/local-fix.diff"
e2e "$WORK/tampered" tampered; rc=$?
check "a diff that is not the pinned one stops the run before any checkout" \
  "[ $rc = 1 ] && command grep -qF 'not the pinned' '$WORK/e2e-tampered/out/STOPPED' && ! command grep -q '^worktree-vllm' '$WORK/e2e-tampered/out/status.txt'"

# ---------------------------------------------------------------- mutants of run.sh, caught end to end
m=$(mutant pin run.sh 's/^\[ "\$got" = "\$DIFF_SHA256" \] ||/true ||/')
[ -n "$m" ] && cp "$WORK/tampered/local-fix.diff" "$m/local-fix.diff" && e2e "$m" m-pin
mcheck "mutant: a run.sh that skips the sha256 pin is caught" "! { [ -f '$WORK/e2e-m-pin/out/STOPPED' ] && command grep -qF 'not the pinned' '$WORK/e2e-m-pin/out/STOPPED'; }"
m=$(mutant baseall run.sh "s/apply --include='tests\/\*' \"\$DIFF\"/apply \"\$DIFF\"/")
[ -n "$m" ] && e2e "$m" m-baseall
mcheck "mutant: a base side that applies the whole diff does not report AS EXPECTED" "! v m-baseall 'AS EXPECTED'"
m=$(mutant nobaseguard run.sh "s/apply --include='tests\/\*' \"\$DIFF\"/apply \"\$DIFF\"/; s/|| stop \"the base side changed code under vllm\/\"/|| true/")
[ -n "$m" ] && e2e "$m" m-nobaseguard
mcheck "mutant: the same with its guard gone is reported NOT AS EXPECTED by the verdict" "v m-nobaseguard 'NOT AS EXPECTED'"
# The diff also changes utils/common.py, which a connector-only guard would not see on the base side.
m=$(mutant basecommon run.sh "s/apply --include='tests\/\*' \"\$DIFF\"/apply --include='tests\/*' --include='*\/utils\/common.py' \"\$DIFF\"/")
[ -n "$m" ] && e2e "$m" basecommon
mcheck "a base side that also takes the diff's common.py is stopped by the vllm/ guard" \
  "command grep -qF 'the base side changed code under vllm/' '$WORK/e2e-basecommon/out/STOPPED'"
m=$(mutant basecommon-oldguard run.sh "s/apply --include='tests\/\*' \"\$DIFF\"/apply --include='tests\/*' --include='*\/utils\/common.py' \"\$DIFF\"/; s/git -C vllm diff --quiet HEAD -- vllm\/ ||/git -C vllm diff --quiet HEAD -- \"\$CONNECTOR\" ||/")
[ -n "$m" ] && e2e "$m" m-basecommon-oldguard
mcheck "mutant: a guard that checks only the connector lets that base side through, and is caught" \
  "! { [ -f '$WORK/e2e-m-basecommon-oldguard/out/STOPPED' ] && command grep -qF 'the base side changed code under vllm/' '$WORK/e2e-m-basecommon-oldguard/out/STOPPED'; }"
m=$(mutant nora run.sh 's/^CMD_A=(pytest "\$TEST_FILE" -k "TestHF3FSLoadErrors or TestHF3FSSchedulerLoadFailure" -rA)$/CMD_A=(pytest "$TEST_FILE" -k "TestHF3FSLoadErrors or TestHF3FSSchedulerLoadFailure")/')
[ -n "$m" ] && e2e "$m" m-nora
mcheck "mutant: a command (a) without -rA does not report AS EXPECTED" "! v m-nora 'AS EXPECTED'"
m=$(mutant cenv run.sh 's/env -C vllm\/tests VLLM_ENABLE_V1_MULTIPROCESSING=0 "\${CMD_C\[@\]}"/env -C vllm\/tests "${CMD_C[@]}"/')
[ -n "$m" ] && e2e "$m" m-cenv
mcheck "mutant: a command (c) without VLLM_ENABLE_V1_MULTIPROCESSING=0 does not report AS EXPECTED" "! v m-cenv 'AS EXPECTED'"
m=$(mutant ccwd run.sh 's/env -C vllm\/tests VLLM_ENABLE_V1_MULTIPROCESSING=0/env -C vllm VLLM_ENABLE_V1_MULTIPROCESSING=0/')
[ -n "$m" ] && e2e "$m" m-ccwd
mcheck "mutant: a command (c) run from the checkout root instead of tests/ does not report AS EXPECTED" "! v m-ccwd 'AS EXPECTED'"
m=$(mutant order run.sh 's/^for cmd in a c b; do$/for cmd in a b c; do/')
[ -n "$m" ] && e2e "$m" m-order
mcheck "mutant: running (b) before (c) is caught by the order check" "[ \"\$(order m-order)\" != 'test-base-a test-fix-a test-base-c test-fix-c test-base-b test-fix-b' ]"
m=$(mutant offline run.sh 's/^    export HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1$/    true/')
[ -n "$m" ] && e2e "$m" m-offline FAKE_EXPECT_OFFLINE=1
mcheck "mutant: a run.sh that leaves the hub online for the tests does not report AS EXPECTED" "! v m-offline 'AS EXPECTED'"
m=$(mutant revcheck run.sh 's/^  elif \[ "\$rev" != "\$MODEL_REV" \]; then$/  elif false; then/')
[ -n "$m" ] && e2e "$m" m-revcheck FAKE_HF=badrev
mcheck "mutant: a run.sh that takes another model revision is caught" "! vc m-revcheck 'NOT RUN'"
m=$(mutant shacheck run.sh 's/^  elif ! command grep -qx "\$MODEL_BIN_SHA256  pytorch_model.bin" "\$OUT\/model-files.sha256"; then$/  elif false; then/')
[ -n "$m" ] && e2e "$m" m-shacheck FAKE_HF=badsha
mcheck "mutant: a run.sh that takes other weights is caught" "! vc m-shacheck 'NOT RUN'"
m=$(mutant cskip run.sh 's/^  \[ "\$cmd" = c \] && \[ -e "\$OUT\/c-not-run.txt" \] && {/  false \&\& {/')
[ -n "$m" ] && e2e "$m" m-cskip FAKE_HF=fail
mcheck "mutant: a run.sh that still runs (c) after a failed download is caught" "[ \"\$(order m-cskip)\" != 'test-base-a test-fix-a test-base-b test-fix-b' ]"
m=$(mutant notimeout run.sh 's/^  timeout --kill-after=10 "\$cap" "\$@" > "\$log" 2>&1$/  "$@" > "$log" 2>\&1/')
[ -n "$m" ] && { E2E_CAP_S=90 e2e "$m" m-notimeout FAKE_MODE=hang BUDGET_S=100 PYTEST_CAP_S=30; rc=$?; }
mcheck "mutant: a step without its timeout overruns the budget and is caught" "[ \"\${rc:-0}\" = 124 ]"

# ---------------------------------------------------------------- mutants of verdict.py, caught by the unit checks
caught() { ! python3 -I "$CHECK" "$1" "$FAKES/cpu-logs" >"$WORK/mutant.log" 2>&1; }
while IFS='|' read -r name sedexpr; do
  [ -n "$name" ] || continue
  m=$(mutant "$name" verdict.py "$sedexpr")
  mcheck "mutant: verdict $name is caught" "caught '$m'"
done <<'MUTANTS'
passes a skip|s/^    if c.get("skipped", 0) or run\["skipped_lines"\]:$/    if False:/
ignores a missing summary|s/^    if run\["summary"\] is None:$/    if False:/
ignores a missing log|s/^        return \[f"{name}: no log"\]$/        return []/
ignores pytest's exit code|s/^    elif rc not in (0, 1):$/    elif False:/
ignores a missing exit code|s/^    if rc is None:$/    if False:/
ignores an exit code that disagrees|s/^    if rc is not None and rc in (0, 1) and rc != (1 if failed or errored else 0):$/    if False:/
ignores unit errors|s/^    if c.get("errors", 0) > len(own_errors):$/    if False:/
counts an end-to-end error as a unit gap|s/^    own_errors = {t for t, o in run\["outcomes"\].items() if o == "ERROR" and t in EXPECTED_C}$/    own_errors = set()/
ignores other outcomes|s/^    if others:$/    if False:/
ignores xfail and xpass|s/^        if c.get(k, 0):$/        if False:/
ignores a count mismatch|s/^    if (passed, failed, errored) != (c.get("passed", 0), c.get("failed", 0), c.get("errors", 0)):$/    if False:/
ignores a run with no tests|s/^    if passed + failed + errored == 0:$/    if False:/
ignores duplicates|s/^    if run\["duplicates"\]:$/    if False:/
takes any (a) selection|s/^    if cmd == "a" and ids != EXPECTED_A:$/    if False:/
takes a whole file without the new tests|s/^    if cmd == "b" and not b_needs <= ids:$/    if False:/
takes any (c) selection|s/^    if cmd == "c" and ids != EXPECTED_C:$/    if False:/
takes different tests on the two sides|s/^        if b is not None and f is not None and set(b\["outcomes"\]) != set(f\["outcomes"\]):$/        if False:/
ignores no CUDA|s/^        if env.get("cuda_available") is not True:$/        if False:/
ignores an unnamed device|s/^        if not env.get("device_name"):$/        if False:/
ignores a missing env.json|s/^        common.append(f"env.json unreadable: {e}")$/        pass/
ignores a stopped run|s/^    if os.path.exists(os.path.join(out, "STOPPED")):$/    if False:/
decides the unit verdict despite gaps|s/^    if not rec\["gaps"\]:$/    if True:/
does not require base to fail (a)|s/^    ("base", "a"): EXPECTED_A,$/    ("base", "a"): frozenset(),/
does not require the fix to pass (b)|s/^    ("fix", "b"): frozenset(),$/    ("fix", "b"): EXPECTED_A,/
brings back the by-design base pass|s/^    ("base", "\([ab]\)"): EXPECTED_A,$/    ("base", "\1"): EXPECTED_A - {SCHED + "test_failed_later_batch_keeps_prefix_and_saves_the_rest"},/
judges end-to-end outcomes in the unit verdict|s/ if o == "FAILED" and t not in EXPECTED_C}$/ if o == "FAILED"}/
reports every decided unit run AS EXPECTED|s/^        rec\["verdict"\] = "NOT AS EXPECTED" if rec\["deviations"\] or rec\["findings"\] else "AS EXPECTED"$/        rec["verdict"] = "AS EXPECTED"/
drops headers padded with fewer than three underscores|s/^HEADER_RE = re.compile(r"^_+ /HEADER_RE = re.compile(r"^_{3,} /
reads a frame separator as a header|s/^HEADER_RE = re.compile(r"^_+ (\[^_\\s\]/HEADER_RE = re.compile(r"^_+ (\\S/
hides a base and fix difference outside the ten|s/^            if ob != of:$/            if False:/
counts the ten as findings|s/^        for t in sorted((set(b\["outcomes"\]) | set(f\["outcomes"\])) - JUDGED):$/        for t in sorted(set(b["outcomes"]) | set(f["outcomes"])):/
does not normalize ids printed from tests|s/^    if marker in test_id:$/    if False:/
ignores the kit's c-not-run.txt|s/^    if os.path.exists(not_run_path):$/    if False:/
decides (c) despite gaps|s/^    if c_rec\["gaps"\]:$/    if False:/
decides (c) despite a harness failure|s/^    if c_rec\["not_run"\]:$/    if False:/
takes any failure as deciding|s/^    if outcome == "FAILED":$/    if outcome == "FAILED":\n        return {"state": "FAILED", "at": "any"}/
takes a deciding line from any frame|s/^            if pattern.match(own) and asserted:$/            if any(pattern.match(x) for x in lines) and asserted:/
takes a non-assertion error as deciding|s/^            if pattern.match(own) and asserted:$/            if pattern.match(own):/
judges (b) on the end-to-end class when (c) did not run|s/^            b_needs = EXPECTED_A if os.path.exists(os.path.join(out, "c-not-run.txt")) else JUDGED$/            b_needs = JUDGED/
does not require base [fail] to fail|s/^    if s\[f"base {name_f}"\] != {"state": "FAILED", "at": 'assert retry.finish_reason == "error"'}:$/    if False:/
judges base [recompute] instead of base [fail]|s/^    if s\[f"base {name_f}"\] != /    if s[f"base {name_r}"] != /
does not require the fix to pass (c)|s/^        if s\[f"fix {name}"\] != {"state": "PASSED"}:$/        if False:/
misses the stored-keys timeout|s/re.compile(r"condition not met before the timeout")/re.compile(r"NEVER MATCHES")/
misses an OOM|s/re.compile(r"OutOfMemoryError|CUDA out of memory|out of memory", re.I)/re.compile(r"NEVER MATCHES")/
misses a model load failure|s/re.compile(r"LocalEntryNotFoundError|[^"]*")/re.compile(r"NEVER MATCHES")/
misses a KV layout error|s/re.compile(r"register_kv_caches|kv\[_ \]cache\[_ \]layout|layout", re.I)/re.compile(r"NEVER MATCHES")/
misses a read that never reached HF3FS|s/re.compile(r"^>\\s+assert faults\\.num_failed_reads > 0", re.M)/re.compile(r"NEVER MATCHES")/
ranks NOT RUN above a deviation|s/^    for v in ("NOT AS EXPECTED", "INCOMPLETE", "NOT RUN"):$/    for v in ("NOT RUN", "NOT AS EXPECTED", "INCOMPLETE"):/
exits 0 on INCOMPLETE|s/{"AS EXPECTED": 0, "NOT AS EXPECTED": 2, "NOT RUN": 4}.get(rec\["overall"\], 3)/{"AS EXPECTED": 0, "NOT AS EXPECTED": 2, "NOT RUN": 4}.get(rec["overall"], 0)/
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
    SCRATCH="$WORK" bash hack/gpu-kit-session.sh "${3-docs/oss/vllm-69058/kit-r1}" >"$WORK/session.out" 2>&1 )
}
# A clone of a linked worktree checks out the main repository's HEAD, so this tree's own commit is checked out by its SHA.
git clone -q "$ROOT" "$WORK/clone" 2>"$WORK/clone.err" && git -C "$WORK/clone" checkout -q "$(git -C "$ROOT" rev-parse HEAD)" 2>>"$WORK/clone.err"
if [ -f "$WORK/clone/docs/oss/vllm-69058/kit-r1/run.sh" ] && [ -f "$WORK/clone/hack/gpu-kit-session.sh" ]; then
  session "$WORK/clone" "$WORK/out-nokit" docs/oss/vllm-69058; rc=$?
  check "the runner refuses a kit path with no run.sh before any AWS call" "[ $rc != 0 ] && command grep -qF 'has no run.sh' '$WORK/session.out' && [ ! -s '$AWS_CALLS' ]"
  echo junk >"$WORK/clone/hack/untracked.txt"
  session "$WORK/clone" "$WORK/out-dirty"; rc=$?
  check "the runner refuses a tree with an untracked file before any AWS call" \
    "[ $rc != 0 ] && command grep -qF 'working tree is dirty' '$WORK/session.out' && [ ! -s '$AWS_CALLS' ]"
  rm "$WORK/clone/hack/untracked.txt"
  echo '# edit' >>"$WORK/clone/docs/oss/vllm-69058/kit-r1/run.sh"
  session "$WORK/clone" "$WORK/out-modified"; rc=$?
  check "the runner refuses the kit with an uncommitted edit before any AWS call" \
    "[ $rc != 0 ] && command grep -qE 'working tree is dirty|kit has uncommitted or untracked files' '$WORK/session.out' && [ ! -s '$AWS_CALLS' ]"
  git -C "$WORK/clone" checkout -q -- docs/oss/vllm-69058/kit-r1/run.sh
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
