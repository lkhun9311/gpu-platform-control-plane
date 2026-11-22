#!/usr/bin/env bash
#
# Offline checks for the vLLM #69058 kit r6 in docs/oss/vllm-69058/kit-r6, run before any GPU is bought.
# No GPU, no network and no AWS: python (with pytest), hf and nvidia-smi are the fakes in hack/vllm-69058-fake, and aws is a fake that records its calls.
# The vLLM checkout is real, a detached worktree of a local vLLM repository (VLLM_SRC) at the base, with the pinned patch applied by git am.
# Each verdict rule and each run.sh guard is also run against a mutant that breaks it, and the mutant must be caught.
# The runner checks need the kit committed, since the session ships a commit; they clone this tree's HEAD.
# Kits r1, r3, r4 and r5 were checked by this script's earlier versions, at 2f31a67b, a32a3a10, 5b2ff327 and 61bcb206.
#
#   VLLM_SRC=/path/to/vllm bash hack/vllm-69058-kit-test.sh
set -uo pipefail
unset INSTANCE_TYPE KIT_ENV SESSION_CONFIRM AWS_PROFILE
# The checks assert the kit's and the fakes' defaults, so a caller's settings must not reach them.
unset BUDGET_S E2E_CAP_S UNIT_CAP_S PYTEST_CAP_S LLM_CAP_S KIT_DRY_RUN KIT_OFFLINE_TEST OFFLINE_VLLM_SRC OFFLINE_MODEL_BIN_SHA256 \
  FAKE_MODE FAKE_CUDA FAKE_HF FAKE_HF_DIR FAKE_NVSMI FAKE_EXPECT_OFFLINE HF_HUB_OFFLINE TRANSFORMERS_OFFLINE VLLM_ENABLE_V1_MULTIPROCESSING CUDA_LAUNCH_BLOCKING
# Python must not leave bytecode beside a mutant, where a same-size edit restored within a second could reuse it.
export PYTHONDONTWRITEBYTECODE=1
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KIT="$ROOT/docs/oss/vllm-69058/kit-r6"
FAKES="$ROOT/hack/vllm-69058-fake"
CHECK="$ROOT/hack/vllm-69058-kit-check.py"
SRC="${VLLM_SRC:-$HOME/workspace/oss/vllm}"
BASE=9ee44f044e6f3bbc49b96facb4cfda659cd783a5
FIX_TREE=fb3683d3d688b435cdb2d18070aa1f8692bc598f
TF=tests/v1/kv_connector/unit/test_hf3fs_load_failure.py
PATCH_SHA256=21adc4fcca8da477b23cebd447082679b231d33f18070fd75378e0e7b73bd42c
STORAGE="$HOME/workspace/storage"
STORAGE_REF=0b20acb2:open-source/contributions/vllm/hf3fs-load-errors-69058/review-69095/c41f7726-shutdown.patch
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
  "python3 -I -X pycache_prefix='$WORK/pyc' -m py_compile '$KIT/verdict.py' '$KIT/envprobe.py' '$FAKES/pytest_r6.py' '$CHECK'"
if command -v shellcheck >/dev/null; then
  check "shellcheck finds no error in run.sh" "shellcheck -S error '$KIT/run.sh'"
else
  echo "skip shellcheck is not installed here"
fi

# ---------------------------------------------------------------- the pins
check "the kit's patch has the pinned sha256, which starts 21adc4fcca8da477" \
  "[ \"\$(sha256sum '$KIT/c41f7726-shutdown.patch' | cut -d' ' -f1)\" = $PATCH_SHA256 ] && [ \${PATCH_SHA256:0:16} = 21adc4fcca8da477 ]"
check "run.sh pins the patch, the base by commit and tree, and the result by the fix's tree" \
  "command grep -qx 'PATCH_SHA256=$PATCH_SHA256' '$KIT/run.sh' && command grep -qx 'BASE_SHA=$BASE' '$KIT/run.sh' \
   && command grep -qx 'BASE_TREE=5cdf5ed74707a1e5fb0509a058c1d86aba70d3cb' '$KIT/run.sh' && command grep -qx 'FIX_TREE=$FIX_TREE' '$KIT/run.sh' \
   && command grep -qx 'FIX_SHA=c41f7726f65880039674767691073d52ce502ef9' '$KIT/run.sh'"
if git -C "$STORAGE" show "$STORAGE_REF" >"$WORK/storage.patch" 2>"$WORK/storage.err"; then
  check "the kit's patch is byte for byte storage $STORAGE_REF, on its origin/main" \
    "cmp -s '$KIT/c41f7726-shutdown.patch' '$WORK/storage.patch' && git -C '$STORAGE' merge-base --is-ancestor 0b20acb2 origin/main 2>>'$WORK/storage.err'"
else
  check "storage $STORAGE_REF is readable ($(cat "$WORK/storage.err"))" "false"
fi
if git -C "$SRC" cat-file -e "c41f7726f65880039674767691073d52ce502ef9^{commit}" 2>"$WORK/src.err"; then
  check "the local source commit c41f7726 has the pinned tree and the base as its parent" \
    "[ \"\$(git -C '$SRC' rev-parse c41f7726f65880039674767691073d52ce502ef9^{tree})\" = $FIX_TREE ] && [ \"\$(git -C '$SRC' rev-parse c41f7726f65880039674767691073d52ce502ef9^)\" = $BASE ]"
else
  echo "skip the local repository does not hold c41f7726 ($(cat "$WORK/src.err"))"
fi
check "the patch touches only the test file and the connector" \
  "[ \"\$(command grep '^diff --git ' '$KIT/c41f7726-shutdown.patch' | paste -sd' ')\" = 'diff --git a/$TF b/$TF diff --git a/vllm/distributed/kv_transfer/kv_connector/v1/hf3fs/hf3fs_connector.py b/vllm/distributed/kv_transfer/kv_connector/v1/hf3fs/hf3fs_connector.py' ]"

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
check "the default settings are accepted and record the spec's one command, with no CUDA_LAUNCH_BLOCKING and no -x" \
  "dry '$KIT' && command grep -qx 'budget_s=450' '$WORK/dry/settings.txt' && command grep -qx 'e2e_cap_s=330' '$WORK/dry/settings.txt' \
   && command grep -qxF 'command=VLLM_ENABLE_V1_MULTIPROCESSING=0 python -m pytest $TF::TestHF3FSLoadFailureEndToEnd -q -p no:cacheprovider --tb=long' '$WORK/dry/settings.txt' \
   && command grep -qx 'wheel_commit=dd8c157895f01875bc5f44c51003bbe330647330' '$WORK/dry/settings.txt'"
check "CUDA_LAUNCH_BLOCKING set by a caller is refused rather than passed to the test" "! dry '$KIT' -- CUDA_LAUNCH_BLOCKING=1 && command grep -qF 'runs without it' '$WORK/dry.out'"
check "a positional argument is refused, and nothing is written" "! dry '$KIT' extra && command grep -qF 'takes no arguments' '$WORK/dry.out' && [ ! -e '$WORK/dry' ]"
check "BUDGET_S above 450, not whole seconds, at or below the reserve, or with a leading zero is refused" \
  "! dry '$KIT' -- BUDGET_S=451 && ! dry '$KIT' -- BUDGET_S=10m && ! dry '$KIT' -- BUDGET_S=60 && ! dry '$KIT' -- BUDGET_S=0300"
check "E2E_CAP_S with a leading zero or under 30, and earlier kits' cap settings, are refused" \
  "! dry '$KIT' -- E2E_CAP_S=0330 && ! dry '$KIT' -- E2E_CAP_S=5 && ! dry '$KIT' -- LLM_CAP_S=600"
m=$(mutant budgetcap run.sh 's/^BUDGET_MAX_S=450$/BUDGET_MAX_S=600/')
mcheck "mutant: a run.sh that takes BUDGET_S=451 is caught" "! { ! dry '$m' -- BUDGET_S=451; }"
m=$(mutant blockingok run.sh 's/^\[ -z "\${CUDA_LAUNCH_BLOCKING:-}" \] ||/true ||/')
mcheck "mutant: a run.sh that lets CUDA_LAUNCH_BLOCKING through is caught" "! { ! dry '$m' -- CUDA_LAUNCH_BLOCKING=1; }"

# ---------------------------------------------------------------- the budget against the runner's rates, on both instance types
S="$ROOT/hack/gpu-kit-session.sh"
bring=$(sed -n 's/^BRINGUP_S=\([0-9]*\)$/\1/p' "$S")
upl=$(sed -n 's/^EVIDENCE_UPLOAD_S=\([0-9]*\)$/\1/p' "$S")
kitmax=$(sed -n 's/^BUDGET_MAX_S=\([0-9]*\)$/\1/p' "$KIT/run.sh")
for t in g5.xlarge:0.2497:0.8579 g5.2xlarge:0.2822:0.9696; do
  type=${t%%:*} want=$(echo "$t" | cut -d: -f2) backstop=${t##*:}
  rate=$(sed -n "s/^    $type) echo \"[0-9.]* \([0-9.]*\) [0-9]*\" ;;\$/\1/p" "$S")
  sched=$(INSTANCE_TYPE=$type bash "$S" --print-schedule 2>&1)
  tail_s=$(python3 -I -c 'import re,sys; d=dict(re.findall(r"(\w+)=([\w.]+)", sys.argv[1])); print(int(d["termination_s"]) - int(d["evidence_s"]))' "$sched")
  worst=$(python3 -I -c 'import sys; b,k,u,t,r = map(float, sys.argv[1:]); print(f"{(b + k + u + t) / 3600 * r:.4f} {int(b + k + u + t)}")' "${bring:-x}" "${kitmax:-x}" "${upl:-x}" "${tail_s:-x}" "${rate:-x}")
  check "$type: BUDGET_S at its maximum, $kitmax s, bills ${worst#* } s at \$$rate/h, \$${worst% *}, as run.sh's header says" \
    "[ '$worst' = '$want 1170' ] && command grep -qF '\$$want on $type' '$KIT/run.sh'"
  check "$type: the runner's own backstop stays \$$backstop, as run.sh's header says" \
    "[[ '$sched' == *worst_case_usd=$backstop ]] && command grep -qF '\$$backstop on $type' '$KIT/run.sh'"
done

# ---------------------------------------------------------------- end to end on the fakes, with the real checkout and a real git am
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
check "pass: with the fix applied both cases pass, and the run is AS EXPECTED, exit 0" "[ $rc = 0 ] && v pass 'AS EXPECTED' && vt pass 'summary (exit 0): 2 passed'"
check "pass: the applied commit has the fix's tree and the base as its parent, and the versions record both" \
  "command grep -q '^applied commit=[0-9a-f]\{40\} tree=$FIX_TREE parent=$BASE ' '$WORK/e2e-pass/out/versions.txt' && command grep -qx 'base commit=$BASE tree=5cdf5ed74707a1e5fb0509a058c1d86aba70d3cb' '$WORK/e2e-pass/out/versions.txt'"
check "pass: the steps ran in order with the hub offline, and the run left checksums and no worktree" \
  "[ \"\$(command grep -oE '^(nvidia-smi|materialize-base|git-am|envprobe|download-model|test-e2e)' '$WORK/e2e-pass/out/status.txt' | paste -sd' ')\" = 'nvidia-smi materialize-base git-am envprobe download-model test-e2e' ] \
   && command grep -qx 'hub_offline=1 for the test run' '$WORK/e2e-pass/out/settings.txt' && ( cd '$WORK/e2e-pass/out' && sha256sum -c --quiet SHA256SUMS ) \
   && ! git -C '$SRC' worktree list | command grep -qF '$WORK/e2e-pass/'"
e2e "$KIT" illegal FAKE_MODE=illegal; rc=$?
check "illegal: 2 passed with an illegal access in the log is a FINDING, exit 2" "[ $rc = 2 ] && v illegal FINDING && vt illegal 'FINDING: an illegal memory access is in the log'"
e2e "$KIT" onefail FAKE_MODE=onefail; rc=$?
check "onefail: 1 failed, 1 passed is a FINDING, exit 2" "[ $rc = 2 ] && v onefail FINDING && vt onefail 'not 2 passed'"
e2e "$KIT" kvmem FAKE_MODE=kvmem; rc=$?
check "kvmem: a KV memory failure is NOT RUN, exit 4" "[ $rc = 4 ] && v kvmem 'NOT RUN' && vt kvmem 'NOT RUN: KV cache memory'"
e2e "$KIT" skip FAKE_MODE=skip; rc=$?
check "skip: both cases skipped on the GPU is INCOMPLETE, exit 3" "[ $rc = 3 ] && v skip INCOMPLETE"
e2e "$KIT" nosummary FAKE_MODE=nosummary; rc=$?
check "nosummary: pytest dying before its summary is INCOMPLETE, exit 3" "[ $rc = 3 ] && v nosummary INCOMPLETE"
t0=$(date +%s); e2e "$KIT" hang FAKE_MODE=hang BUDGET_S=100 E2E_CAP_S=30; rc=$?; took=$(( $(date +%s) - t0 ))
check "hang: the test is cut at its cap, the verdict is INCOMPLETE, and run.sh ends inside BUDGET_S ($took s)" \
  "[ $rc = 3 ] && command grep -qx 'test-e2e exit=124 t=[0-9]*' '$WORK/e2e-hang/out/status.txt' && v hang INCOMPLETE && [ $took -le 100 ]"
cp -r "$KIT" "$WORK/tampered" && printf '\n' >>"$WORK/tampered/c41f7726-shutdown.patch"
e2e "$WORK/tampered" tampered; rc=$?
check "a patch that is not the pinned one stops the run before any checkout" \
  "[ $rc = 1 ] && command grep -qF 'not the pinned' '$WORK/e2e-tampered/out/STOPPED' && ! command grep -q '^worktree-vllm' '$WORK/e2e-tampered/out/status.txt'"
m=$(mutant othertree run.sh 's/^FIX_TREE=fb3683d3d688b435cdb2d18070aa1f8692bc598f$/FIX_TREE=0000000000000000000000000000000000000000/')
[ -n "$m" ] && e2e "$m" othertree
mcheck "a result whose tree is not the pinned one stops the run before the test" "command grep -qF 'the tree of c41f7726' '$WORK/e2e-othertree/out/STOPPED' && ! [ -e '$WORK/e2e-othertree/out/e2e.log' ]"

# ---------------------------------------------------------------- mutants of run.sh, caught end to end
m=$(mutant pin run.sh 's/^\[ "\$got" = "\$PATCH_SHA256" \] ||/true ||/')
[ -n "$m" ] && cp "$WORK/tampered/c41f7726-shutdown.patch" "$m/" && e2e "$m" m-pin
mcheck "mutant: a run.sh that skips the patch's sha256 pin is caught" "! { [ -f '$WORK/e2e-m-pin/out/STOPPED' ] && command grep -qF 'not the pinned' '$WORK/e2e-m-pin/out/STOPPED'; }"
m=$(mutant notreecheck run.sh 's/^FIX_TREE=fb3683d3d688b435cdb2d18070aa1f8692bc598f$/FIX_TREE=0000000000000000000000000000000000000000/; s/^\[ "\$tree" = "\$FIX_TREE" \] ||/true ||/')
[ -n "$m" ] && e2e "$m" m-notreecheck
mcheck "mutant: a run.sh without the result's tree check is caught" "! command grep -qF 'the tree of c41f7726' '$WORK/e2e-m-notreecheck/out/STOPPED'"
m=$(mutant noam run.sh 's/^step git-am 60 --log "\$OUT\/git-am.log" git -C vllm -c user.name=kit -c user.email=kit@localhost -c commit.gpgsign=false am -q "\$PATCH" ||$/true ||/')
[ -n "$m" ] && e2e "$m" m-noam
mcheck "mutant: a run that never applies the fix does not report AS EXPECTED" "! v m-noam 'AS EXPECTED'"
m=$(mutant withblocking run.sh 's/^ENV=(VLLM_ENABLE_V1_MULTIPROCESSING=0)$/ENV=(CUDA_LAUNCH_BLOCKING=1 VLLM_ENABLE_V1_MULTIPROCESSING=0)/')
[ -n "$m" ] && e2e "$m" m-withblocking
mcheck "mutant: a test run with CUDA_LAUNCH_BLOCKING does not report AS EXPECTED" "! v m-withblocking 'AS EXPECTED'"
m=$(mutant withx run.sh 's/ -q -p no:cacheprovider --tb=long)$/ -q -p no:cacheprovider -x --tb=long)/')
[ -n "$m" ] && e2e "$m" m-withx
mcheck "mutant: a test run with -x does not report AS EXPECTED" "! v m-withx 'AS EXPECTED'"
m=$(mutant offline run.sh 's/^export HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1$/true/')
[ -n "$m" ] && e2e "$m" m-offline FAKE_EXPECT_OFFLINE=1
mcheck "mutant: a run.sh that leaves the hub online for the test does not report AS EXPECTED" "! v m-offline 'AS EXPECTED'"
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
accepts any count of passes|s/^        if got != {"passed": 2} or rc != 0:$/        if got.get("failed") or got.get("errors"):/
accepts 2 passed with a nonzero exit|s/^        if got != {"passed": 2} or rc != 0:$/        if got != {"passed": 2}:/
misses an illegal access|s/^    rec\["illegal_lines"\] = \[f"{i}:{x}" for i, x in enumerate(p\["lines"\], start=1) if ILLEGAL_RE.search(x)\]$/    rec["illegal_lines"] = []/
misses CUDA_ERROR_ILLEGAL_ADDRESS|s/^ILLEGAL_RE = re.compile(r"illegal memory access|CUDA_ERROR_ILLEGAL_ADDRESS|cudaErrorIllegalAddress")$/ILLEGAL_RE = re.compile(r"illegal memory access")/
calls an illegal access a harness failure|s/^    if rec\["illegal_lines"\]:$/    if False:/
misses the KV memory cause|s/re.compile(r"KV cache is needed, which is larger than the available KV cache memory")/re.compile(r"NEVER MATCHES")/
reads harness causes from captured logs|s/^    tb = "\\n".join(x for x in p\["lines"\] if x.startswith(("E ", ">")))$/    tb = "\\n".join(p["lines"])/
reads logs in text mode|s/ errors="replace", newline="").read())$/ errors="replace").read())/
ignores a missing summary|s/^    elif p\["summary"\] is None or rc not in (0, 1):$/    elif False:/
ignores skips|s/^    elif c.get("skipped"):$/    elif False:/
ignores no CUDA|s/^        if env.get("cuda_available") is not True or not env.get("device_name"):$/        if False:/
ignores a stopped run|s/^    if os.path.exists(os.path.join(out, "STOPPED")):$/    if False:/
ranks INCOMPLETE above a FINDING|s/^    if rec\["findings"\]:$/    if rec["findings"] and not rec["gaps"]:/
exits 0 on a FINDING|s/{"AS EXPECTED": 0, "FINDING": 2, "NOT RUN": 4}.get(rec\["verdict"\], 3)/{"AS EXPECTED": 0, "FINDING": 0, "NOT RUN": 4}.get(rec["verdict"], 3)/
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
    SCRATCH="$WORK" bash hack/gpu-kit-session.sh "${3-docs/oss/vllm-69058/kit-r6}" >"$WORK/session.out" 2>&1 )
}
# A clone of a linked worktree checks out the main repository's HEAD, so this tree's own commit is checked out by its SHA.
git clone -q "$ROOT" "$WORK/clone" 2>"$WORK/clone.err" && git -C "$WORK/clone" checkout -q "$(git -C "$ROOT" rev-parse HEAD)" 2>>"$WORK/clone.err"
if [ -f "$WORK/clone/docs/oss/vllm-69058/kit-r6/run.sh" ] && [ -f "$WORK/clone/hack/gpu-kit-session.sh" ]; then
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
