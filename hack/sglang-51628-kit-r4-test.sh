#!/usr/bin/env bash
#
# Offline checks for the SGLang #51628 kit r4 in docs/oss/sglang-51628/kit-r4, run before any GPU is bought.
# No GPU, no network and no AWS: docker, nvidia-smi, pip, pytest, the SGLang server and client, Triton, torch and the Hub are fakes
# (hack/sglang-51628-fake and hack/sglang-51628-fake-r4).
# The SGLang source is a local git repository the test builds: a fake sglang package, plus preimages of the three files prewarm.patch edits,
# made from the patch's own context lines, so the real patch applies with git and the fake server sees whether it was applied.
# Its commit and trees cannot be cb337923's, so the end-to-end runs pass theirs through the offline-test settings, which the verdict prints;
# the real pins are checked by the unit checks.
# Each rule is also run against a mutant that breaks it, and the mutant must be caught, so a check that cannot fail does not pass silently.
# The session checks need the kit committed, since the session ships a commit; they clone this tree's HEAD.
#
#   bash hack/sglang-51628-kit-r4-test.sh
set -uo pipefail
unset INSTANCE_TYPE KIT_ENV SESSION_CONFIRM AWS_PROFILE CONTROL BUDGET_S KIT_DRY_RUN KIT_OFFLINE_TEST MODEL IMAGE SGLANG_IMAGE BURSTS THRESHOLD \
  SGLANG_TRITON_SLOW_COMPILE_THRESHOLD_SECS SGLANG_UNIFIED_RADIX_TREE_CORE_BACKEND SGLANG_RUST_BUILD_MODE SGLANG_CACHE_DIR SGL51628_COMPILE_LOG \
  SGL51628_ROOT SGL51628_HOST_ROOT SGL51628_OFFLINE_TEST SGL51628_TEST_REPO SGL51628_TEST_SHA SGL51628_TEST_BASE_TREE SGL51628_TEST_FIX_TREE \
  FAKE_SCENARIO FAKE_DIR FAKE_VENV FAKE_PYTEST FAKE_INSTALL_FAIL FAKE_TREECORE_FAIL FAKE_NO_LISTENER FAKE_DOWNLOAD_FAIL FAKE_PULL_FAIL \
  FAKE_DIGEST FAKE_REVISION FAKE_DRIVER FAKE_BURST_FAIL FAKE_SHORT FAKE_SLOW_DECODE
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KIT="$ROOT/docs/oss/sglang-51628/kit-r4"
FAKES="$ROOT/hack/sglang-51628-fake"
FAKES4="$ROOT/hack/sglang-51628-fake-r4"
CHECK="$ROOT/hack/sglang-51628-kit-r4-check.py"
R2="$ROOT/hack/gpu-kit-runs/2026-11-21-sglang-51628-r2/run/results/c/main"
# Scratch space lives on disk, since /tmp is RAM-backed on the development machine.
SCRATCH="${SCRATCH:-$HOME/.cache/sglang-51628}"
# An empty WORK would point every path at /, where a check can pass on files that were never written, so the run stops instead.
mkdir -p "$SCRATCH" || { echo "FAIL cannot create the scratch directory $SCRATCH" >&2; exit 1; }
WORK=$(mktemp -d -p "$SCRATCH") && [ -n "$WORK" ] && [ -d "$WORK" ] || { echo "FAIL cannot create a work directory under $SCRATCH" >&2; exit 1; }
export SCRATCH TMPDIR="$SCRATCH"
# The kit is force-added past the docs ignore rule, so no bytecode may be left in it for a later git add -f to pick up.
export PYTHONDONTWRITEBYTECODE=1
[ -n "${KEEP_WORK:-}" ] || trap 'rm -rf "$WORK"' EXIT
failures=0
# check runs its condition with eval in this shell, so a condition that loops keeps its exit inside a subshell, or one failure would end the test.
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1" >&2; failures=$((failures + 1)); fi; }
mcheck() { if [ -n "$m" ]; then check "$@"; else echo "FAIL $1 (the mutant was not made)" >&2; failures=$((failures + 1)); fi; }

# mutant NAME FILE SED: a copy of the kit with SED applied to FILE, and its directory; a SED that changes nothing is an error.
mutant() {
  local d
  d="$WORK/m-$(printf '%s' "$1" | tr -c 'A-Za-z0-9' '-')"
  cp -r "$KIT" "$d"
  sed -i "$3" "$d/$2"
  cmp -s "$KIT/$2" "$d/$2" && { echo "the mutant $1 changed nothing" >&2; return 1; }
  echo "$d"
}

# ---------------------------------------------------------------- parse and compile
check "run.sh, measure.sh, the fakes and this test parse" \
  "bash -n '$KIT/run.sh' && bash -n '$KIT/measure.sh' && bash -n '$FAKES4/docker' && bash -n '$0'"
check "the kit's Python, the r4 fakes and the checker compile" \
  "python3 -I -X pycache_prefix='$WORK/pyc' -m py_compile '$KIT/verdict.py' '$KIT/probe_hook.py' '$KIT/sgl51628_compile_hook.py' '$CHECK' \
   \$(find '$FAKES4' -name '*.py')"
check "the kit holds no bytecode" "[ -z \"\$(find '$KIT' -name '*.pyc' -o -name __pycache__)\" ]"

# ---------------------------------------------------------------- the units
units() { python3 -I "$CHECK" "$1" "$FAKES" "$R2" >"$2" 2>&1; }
units "$KIT" "$WORK/units.log"; rc=$?
check "the unit checks pass ($(command grep -c '^ok' "$WORK/units.log") ok, $(command grep -c '^FAIL' "$WORK/units.log") failed)" "[ $rc = 0 ]"
command grep -E '^FAIL|Traceback' "$WORK/units.log" >&2

# ---------------------------------------------------------------- run.sh's settings and the patch pin, before anything is pulled
dry() { local k=$1; shift; rm -rf "$WORK/dry"; env -i PATH="$PATH" HOME="$HOME" KIT_DRY_RUN=1 OUT="$WORK/dry" "$@" bash "$k/run.sh" >"$WORK/dry.out" 2>&1; }
check "the default settings are accepted: budget 3250, the pinned image, source, patch and model" \
  "dry '$KIT' && command grep -qx 'budget_s=3250' '$WORK/dry/settings.txt' \
   && command grep -qx 'sglang_sha=cb337923d576f48a4accba439af9cfbc9b720a2c' '$WORK/dry/settings.txt' \
   && command grep -qx 'image_sha=03fde9cc392a5f84a54a365635ffed0061cdf1b8' '$WORK/dry/settings.txt' \
   && command grep -qx 'patch_sha256=6aa4b47ca4aa314d0cae6d35e8894df0caa1e7565b403f028eda50a7d94624f9' '$WORK/dry/patch.txt' \
   && command grep -qx 'model=nvidia/Nemotron-H-4B-Instruct-128K@f3c0b6c3b7fcb39e132b6007386e33a586d6e6cb' '$WORK/dry/settings.txt'"
check "BUDGET_S over 3250 is refused" "! dry '$KIT' BUDGET_S=3300 && command grep -qF 'at most 3250' '$WORK/dry.out'"
check "BUDGET_S that is not whole seconds is refused" "! dry '$KIT' BUDGET_S=1e3 && command grep -qF 'whole seconds' '$WORK/dry.out'"
for v in MODEL=x CONTROL=on SGLANG_UNIFIED_RADIX_TREE_CORE_BACKEND=python SGLANG_RUST_BUILD_MODE=auto SGLANG_TRITON_SLOW_COMPILE_THRESHOLD_SECS=0; do
  check "${v%%=*} is refused rather than ignored" "! dry '$KIT' $v && command grep -qF '${v%%=*} is set' '$WORK/dry.out'"
done
m=$(mutant patch-bytes prewarm.patch 's/^+CHUNK_SIZE = 64$/+CHUNK_SIZE = 65/')
mcheck "mutant: a prewarm.patch with one changed line is refused by its sha256 before anything runs" \
  "! dry '$m' && command grep -qF 'prewarm.patch is ' '$WORK/dry.out' && [ ! -e '$WORK/dry/settings.txt' ]"
m=$(mutant patch-pin run.sh 's/^PATCH_SHA256=6aa4/PATCH_SHA256=7aa4/')
mcheck "mutant: a run.sh pinned to another patch hash refuses the real patch" "! dry '$m' && command grep -qF 'not 7aa4' '$WORK/dry.out'"

# ---------------------------------------------------------------- measure.sh's arguments
mkdir -p "$WORK/margs/d"
D="$WORK/margs/d"
marg() { bash "$KIT/measure.sh" "$@" >"$WORK/marg.out" 2>&1; }
marg base "$D"; rc=$?
check "measure.sh refuses an arm call without its eight arguments" "[ $rc = 2 ] && command grep -qF usage '$WORK/marg.out'"
marg other "$D" "$D" "$D" "$D" "$D" 99; rc=$?
check "measure.sh refuses a mode that is not prep, base or fix" "[ $rc = 2 ] && command grep -qF 'not prep, base or fix' '$WORK/marg.out'"
marg base "$D" "$D" "$D" "$D" "$D" 99 maybe; rc=$?
check "measure.sh refuses a treecore that is not rust or python" "[ $rc = 2 ] && command grep -qF 'not rust or python' '$WORK/marg.out'"
marg prep "$D" "$D" "$D" "$D" "$D" 12x; rc=$?
check "measure.sh refuses a deadline that is not an epoch" "[ $rc = 2 ] && command grep -qF 'is not an epoch' '$WORK/marg.out'"
marg fix "$D" "$D" "$D" "$WORK/margs/none" "$D" 99 rust; rc=$?
check "measure.sh refuses a source directory that does not exist" "[ $rc = 2 ] && command grep -qF 'must exist' '$WORK/marg.out'"

# ---------------------------------------------------------------- the fake SGLang repository
REPO="$WORK/sglang-repo"
mkdir -p "$REPO/python"
cp -r "$FAKES/py/sglang" "$REPO/python/sglang"
find "$REPO" -name __pycache__ -prune -exec rm -rf {} +
cp -r "$FAKES4/tree/sglang/." "$REPO/python/sglang/"
# The preimage of each file the patch edits: its hunks' context and removed lines, in order, apart, so git apply finds each hunk.
python3 -I - "$KIT/prewarm.patch" "$REPO" <<'EOF'
import os, sys
patch, repo = sys.argv[1], sys.argv[2]
files, cur, in_hunk = {}, None, False
for ln in open(patch).read().split("\n"):
    if ln.startswith("diff --git") or ln == "-- ":
        cur, in_hunk = None, False
    elif ln.startswith("--- "):
        src = ln[4:]
    elif ln.startswith("+++ "):
        cur = None if src == "/dev/null" else ln[6:]
        if cur:
            files[cur] = []
    elif ln.startswith("@@") and cur:
        files[cur].append((int(ln.split()[1].split(",")[0][1:]), []))
        in_hunk = True
    elif cur and in_hunk and (ln.startswith(" ") or ln.startswith("-")):
        files[cur][-1][1].append(ln[1:])
# git apply anchors a hunk that starts at line 1 to the file's start and one with short trailing context to its end, so neither gets filler there.
for path, hunks in files.items():
    os.makedirs(os.path.dirname(os.path.join(repo, path)), exist_ok=True)
    body = []
    for i, (start, h) in enumerate(hunks):
        body += ([] if start == 1 else [f"# preimage filler {i}.{j}" for j in range(4)]) + h
    with open(os.path.join(repo, path), "w") as f:
        f.write("\n".join(body) + "\n")
EOF
git -C "$REPO" init -q && git -C "$REPO" add -A && \
  git -C "$REPO" -c user.name=test -c user.email=test@invalid -c core.hooksPath=/dev/null commit -q -m "fake sglang tree" || echo "FAIL could not build the fake repository" >&2
TSHA=$(git -C "$REPO" rev-parse HEAD)
TBASE=$(git -C "$REPO" rev-parse 'HEAD^{tree}')
TFIX=$(cd "$REPO" && GIT_INDEX_FILE="$WORK/fix.idx" git read-tree HEAD && GIT_INDEX_FILE="$WORK/fix.idx" git apply --cached "$KIT/prewarm.patch" && GIT_INDEX_FILE="$WORK/fix.idx" git write-tree)
check "the real prewarm.patch applies to the fake tree's preimages" "[ -n '$TFIX' ] && [ '$TFIX' != '$TBASE' ]"

# ---------------------------------------------------------------- end to end on the fakes
mkdir -p "$WORK/fakebin"
ln -s "$FAKES4/docker" "$WORK/fakebin/docker"
cp "$FAKES/nvidia-smi" "$WORK/fakebin/"
ln -s "$(command -v python3)" "$WORK/fakebin/python"
python3 -m venv --without-pip "$WORK/venv" || { echo "FAIL could not make the fake container's venv" >&2; exit 1; }
VSITE=$("$WORK/venv/bin/python" -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')
echo "$FAKES/py" >"$VSITE/_sgl51628_fakes.pth"
echo "$FAKES4/py" >"$VSITE/_sgl51628_fakes_r4.pth"
# e2e KIT NAME [VAR=VALUE...]: the whole kit on the fakes into $WORK/e2e-NAME/out; its exit status is run.sh's.
e2e() {
  local k=$1 n=$2; shift 2
  local d="$WORK/e2e-$n"
  mkdir -p "$d/fd" "$d/cwd"
  rm -f "$VSITE/sgl51628_compile_hook.pth" "$VSITE"/__editable__.sglang*.pth
  ( cd "$d/cwd" && env PATH="$WORK/fakebin:$PATH" FAKE_DIR="$d/fd" FAKE_VENV="$WORK/venv" KIT_OFFLINE_TEST=1 SGL51628_HOST_ROOT="$d/host" OUT="$d/out" \
    SGL51628_TEST_REPO="file://$REPO" SGL51628_TEST_SHA="$TSHA" SGL51628_TEST_BASE_TREE="$TBASE" SGL51628_TEST_FIX_TREE="$TFIX" "$@" \
    bash "$k/run.sh" >"$d/run.log" 2>&1 )
}
ports_free() { ! ss -ltn 2>/dev/null | command grep -qE '127\.0\.0\.1:30000\b'; }
check "the server port is free before the end-to-end runs" "ports_free"
V() { echo "$WORK/e2e-$1/out/verdict.txt"; }
C() { echo "$WORK/e2e-$1/out/c"; }

e2e "$KIT" improved; rc=$?
check "improved: FIX's prewarm moves the scan before ready, IMPROVED, exit 0" \
  "[ $rc = 0 ] && command grep -qx 'VERDICT: IMPROVED' \"\$(V improved)\" && command grep -qx '  Mamba2 compiles after ready: 12 1' \"\$(V improved)\""
check "improved: the verdict says the source pins are the offline test's" "command grep -qF 'OFFLINE TEST: the source pins' \"\$(V improved)\""
check "improved: the prewarm line, the tests, the startup and the TreeCore are reported" \
  "command grep -qx '  prewarm (FIX): 1 layer geometries in 2.4 s' \"\$(V improved)\" && command grep -qx 'TESTS FIX: pass: 3 passed in 0.11s (exit 0)' \"\$(V improved)\" \
   && command grep -q '^  launch to ready s: ' \"\$(V improved)\" && command grep -qx 'TREECORE: rust' \"\$(V improved)\""
check "improved: each arm imported sglang from its own tree, installed over the image" \
  "command grep -qx \"sglang_dir=\$(realpath '$WORK/e2e-improved/host/src/base/python/sglang')\" \"\$(C improved)/base/measure.txt\" \
   && command grep -qx \"sglang_dir=\$(realpath '$WORK/e2e-improved/host/src/fix/python/sglang')\" \"\$(C improved)/fix/measure.txt\""
check "improved: both trees recorded the pinned commit and tree, and FIX the patch's numstat, before and after" \
  "( for a in base fix; do for w in before after; do command grep -qx 'commit=$TSHA' '$WORK/e2e-improved/out/source-'\$a-\$w.txt || exit 1; done; done ) && \
   command grep -qx 'tree=$TBASE' '$WORK/e2e-improved/out/source-base-after.txt' && command grep -qx 'tree=$TFIX' '$WORK/e2e-improved/out/source-fix-after.txt' \
   && command grep -qE 'test_mamba2_prefill_prewarm\.py +\| +158 ' '$WORK/e2e-improved/out/source-fix-before.stat'"
check "improved: both servers ran with exactly the spec's flags and the same environment, apart from their own paths" \
  "[ \"\$(command grep -F 'sglang.launch_server' \"\$(C improved)/base/commands.txt\" | sed 's|/c/base/|/c/ARM/|g; s|triton-base|triton-ARM|')\" \
     = \"\$(command grep -F 'sglang.launch_server' \"\$(C improved)/fix/commands.txt\" | sed 's|/c/fix/|/c/ARM/|g; s|triton-fix|triton-ARM|')\" ] \
   && command grep -qE -- '-m sglang\.launch_server --model-path [^ ]+/nemotron-h-4b-instruct-128k --trust-remote-code \$' \"\$(C improved)/fix/commands.txt\" \
   && ! command grep -q 'SGLANG_TRITON_SLOW_COMPILE_THRESHOLD_SECS\|--warmups' \"\$(C improved)/base/commands.txt\" \"\$(C improved)/fix/commands.txt\""
check "improved: the client ran the four bursts with r2's seeds in both arms" \
  "( for a in base fix; do [ \"\$(command grep -oE -- '--max-concurrency [0-9]+ --seed [0-9]+' \"\$(C improved)/\$a/commands.txt\" | tr '\n' ' ')\" \
     = '--max-concurrency 32 --seed 42 --max-concurrency 16 --seed 161 --max-concurrency 16 --seed 162 --max-concurrency 16 --seed 163 ' ] || exit 1; done )"
check "improved: the tests ran in FIX only, before its server, on a Triton cache of their own" \
  "[ -f \"\$(C improved)/fix/pytest.log\" ] && [ ! -e \"\$(C improved)/base/pytest.log\" ] \
   && [ \"\$(command grep -n 'pytest\|server on an empty' \"\$(C improved)/fix/measure-steps.log\" | head -n 1 | command grep -c pytest)\" = 1 ]"
check "improved: the arms ran in fresh containers, prep then base then fix" \
  "[ \"\$(command grep -oE '^run --rm --name sgl51628-[a-z]+' '$WORK/e2e-improved/fd/docker-calls' | sed 's/.*-//' | tr '\n' ' ')\" = 'prep base fix ' ]"
check "improved: the arms got the built TreeCore artifacts, not cargo's target tree" \
  "[ -n \"\$(find \"\$(C improved)/fix/home/.cache/sglang/rust_extensions/artifacts\" -name 'mem_cache*')\" ] && [ ! -e \"\$(C improved)/fix/home/.cache/sglang/rust_extensions/targets\" ]"
check "improved: the run leaves checksums of everything it wrote" "( cd '$WORK/e2e-improved/out' && sha256sum -c --quiet SHA256SUMS )"
check "improved: the port is free after the run" "ports_free"

e2e "$KIT" nochange FAKE_SCENARIO=nochange; rc=$?
check "nochange: FIX compiling as much after ready is NO CHANGE, exit 0, with why" \
  "[ $rc = 0 ] && command grep -qx 'VERDICT: NO CHANGE' \"\$(V nochange)\" && command grep -qF 'not clearly fewer' \"\$(V nochange)\""
e2e "$KIT" testfail FAKE_PYTEST=fail; rc=$?
check "testfail: a failed unit test makes NO CHANGE despite fewer compiles" \
  "[ $rc = 0 ] && command grep -qx 'VERDICT: NO CHANGE' \"\$(V testfail)\" && command grep -qF 'unit tests did not pass (1 failed, 2 passed' \"\$(V testfail)\""
e2e "$KIT" testskip FAKE_PYTEST=skip; rc=$?
check "testskip: the CUDA test skipped is NO CHANGE" "[ $rc = 0 ] && command grep -qx 'VERDICT: NO CHANGE' \"\$(V testskip)\""
e2e "$KIT" gatefail FAKE_SCENARIO=gatefail; rc=$?
check "gatefail: no disabling line is NOT RUN, exit 4, no traffic, and FIX is not bought" \
  "[ $rc = 4 ] && command grep -qx 'VERDICT: NOT RUN' \"\$(V gatefail)\" && command grep -qF 'the gate failed in BASE' \"\$(V gatefail)\" \
   && [ -z \"\$(ls -A \"\$(C gatefail)/base/bursts\")\" ] && [ ! -e \"\$(C gatefail)/fix/measure.txt\" ] \
   && command grep -q '^fix-skipped: BASE did not reach traffic' '$WORK/e2e-gatefail/out/status.txt'"
e2e "$KIT" noprewarm FAKE_SCENARIO=noprewarm; rc=$?
check "noprewarm: FIX without the prewarm line is NOT RUN, exit 4, and sends no traffic" \
  "[ $rc = 4 ] && command grep -qF 'the gate failed in FIX' \"\$(V noprewarm)\" && [ -z \"\$(ls -A \"\$(C noprewarm)/fix/bursts\")\" ]"
e2e "$KIT" foreign FAKE_SCENARIO=foreign; rc=$?
check "foreign: kernels compiled from the image's own tree are NOT RUN, exit 3" \
  "[ $rc = 3 ] && command grep -qF 'compiled from outside the arm' \"\$(V foreign)\""
e2e "$KIT" treecorefail FAKE_TREECORE_FAIL=1; rc=$?
check "treecorefail: a failed TreeCore build runs both arms on the Python TreeCore and says so" \
  "[ $rc = 0 ] && command grep -qx 'VERDICT: IMPROVED' \"\$(V treecorefail)\" && command grep -qF 'TREECORE: python (fallback: the build exited 1' \"\$(V treecorefail)\" \
   && command grep -q 'SGLANG_UNIFIED_RADIX_TREE_CORE_BACKEND=python' \"\$(C treecorefail)/base/commands.txt\" \
   && command grep -q 'SGLANG_UNIFIED_RADIX_TREE_CORE_BACKEND=python' \"\$(C treecorefail)/fix/commands.txt\""
e2e "$KIT" installfail FAKE_INSTALL_FAIL=1; rc=$?
check "installfail: a tree that does not install stops after prep, before any arm" \
  "[ $rc = 1 ] && command grep -qF 'the prep container did not finish' '$WORK/e2e-installfail/out/STOPPED' && [ ! -e \"\$(C installfail)/base/measure.txt\" ] \
   && command grep -qx 'VERDICT: NOT RUN' \"\$(V installfail)\""
e2e "$KIT" budget BUDGET_S=1500; rc=$?
check "budget: a budget that cannot hold two arms stops before the prep" \
  "[ $rc = 1 ] && command grep -qF 'two arms need 1800 s' '$WORK/e2e-budget/out/STOPPED' && ! command grep -q '^run' '$WORK/e2e-budget/fd/docker-calls'"
e2e "$KIT" nolistener FAKE_NO_LISTENER=1; rc=$?
check "nolistener: a failed positive control stops BASE before its server, NOT RUN" \
  "[ $rc = 3 ] && command grep -qF 'positive control' \"\$(V nolistener)\" && [ ! -e \"\$(C nolistener)/base/server.log\" ]"
e2e "$KIT" burstfail FAKE_BURST_FAIL=162; rc=$?
check "burstfail: a burst without a result is NOT RUN and named" "[ $rc = 3 ] && command grep -qF 'c16-r2: the client exited 1' \"\$(V burstfail)\""
e2e "$KIT" driver FAKE_DRIVER=570.10; rc=$?
check "driver: a driver older than 580 stops before the pull" \
  "[ $rc = 1 ] && command grep -qF 'older than 580' '$WORK/e2e-driver/out/STOPPED' && [ ! -e '$WORK/e2e-driver/fd/docker-calls' ]"
e2e "$KIT" revision FAKE_REVISION=deadbeef; rc=$?
check "revision: an image built from another commit stops before it runs" \
  "[ $rc = 1 ] && command grep -qF \"label is 'deadbeef'\" '$WORK/e2e-revision/out/STOPPED' && ! command grep -q '^run' '$WORK/e2e-revision/fd/docker-calls'"
e2e "$KIT" othercommit SGL51628_TEST_SHA=0000000000000000000000000000000000000000; rc=$?
check "othercommit: a commit that cannot be fetched stops before any container" \
  "[ $rc = 1 ] && command grep -qF 'fetching SGLang' '$WORK/e2e-othercommit/out/STOPPED' && ! command grep -q '^run' '$WORK/e2e-othercommit/fd/docker-calls'"
check "the port is free after every run" "ports_free"

# ---------------------------------------------------------------- mutants of run.sh and measure.sh, caught end to end
m=$(mutant patch-bytes prewarm.patch 's/^+CHUNK_SIZE = 64$/+CHUNK_SIZE = 65/')
e2e "$m" m-patch
mcheck "mutant: a changed prewarm.patch stops before any container" \
  "command grep -qF 'prewarm.patch is ' '$WORK/e2e-m-patch/out/STOPPED' && [ ! -e '$WORK/e2e-m-patch/fd/docker-calls' ]"
m=$(mutant patch-unchecked run.sh 's/^\[ "\$have_patch" = "\$PATCH_SHA256" \] ||/true ||/')
cp "$WORK/m-patch-bytes/prewarm.patch" "$m/prewarm.patch"
e2e "$m" m-patch-unchecked
mcheck "mutant: a run.sh that skips the patch hash still stops on the FIX tree, which the changed patch moves" \
  "command grep -qF 'the FIX tree is not' '$WORK/e2e-m-patch-unchecked/out/STOPPED' && command grep -qx 'VERDICT: NOT RUN' \"\$(V m-patch-unchecked)\""
m=$(mutant patch-to-base run.sh 's/step patch git -C "\$SRC\/fix" apply/step patch git -C "$SRC\/base" apply/')
e2e "$m" m-patch-to-base
mcheck "mutant: a run.sh that patches BASE instead of FIX is stopped by the source pins" \
  "command grep -qF 'the BASE tree is not' '$WORK/e2e-m-patch-to-base/out/STOPPED' && ! command grep -q '^run' '$WORK/e2e-m-patch-to-base/fd/docker-calls'"
m=$(mutant both-patched run.sh 's/^source_ok \(base\|fix\) before .*$/:/; s/step patch git -C "\$SRC\/fix" apply --index "\$HERE\/prewarm.patch"/step patch bash -c "git -C $SRC\/fix apply --index $HERE\/prewarm.patch \&\& git -C $SRC\/base apply --index $HERE\/prewarm.patch"/')
e2e "$m" m-both-patched
mcheck "mutant: a run.sh that patches both trees and skips its own pins is NOT RUN by the verdict, not IMPROVED" \
  "command grep -qx 'VERDICT: NOT RUN' \"\$(V m-both-patched)\" && command grep -qF 'base before: tree' \"\$(V m-both-patched)\" \
   && command grep -qF 'BASE logged the prewarm line' \"\$(V m-both-patched)\""
m=$(mutant unpatched run.sh 's/^source_ok \(base\|fix\) before .*$/:/; s/step patch git -C "\$SRC\/fix" apply --index/step patch true/')
e2e "$m" m-unpatched
mcheck "mutant: a run.sh whose FIX is the unpatched tree, its own pins skipped, is NOT RUN, not NO CHANGE" \
  "command grep -qx 'VERDICT: NOT RUN' \"\$(V m-unpatched)\" && command grep -qF 'fix before: tree' \"\$(V m-unpatched)\""
m=$(mutant gate measure.sh 's/^\[ -n "\$gate_line" \] && \[ -z "\$capture_line" \] || gate=fail$/:/')
e2e "$m" m-gate FAKE_SCENARIO=gatefail
mcheck "mutant: a measure.sh that sends traffic without the gate line is caught, and the verdict still says NOT RUN" \
  "[ -n \"\$(ls -A \"\$(C m-gate)/base/bursts\")\" ] && command grep -qx 'VERDICT: NOT RUN' \"\$(V m-gate)\""
m=$(mutant prewarm-gate measure.sh 's/^\[ "\$MODE" = fix \] && \[ -z "\$prewarm_line" \] && gate=fail$/:/')
e2e "$m" m-prewarm FAKE_SCENARIO=noprewarm
mcheck "mutant: a measure.sh that sends FIX traffic without the prewarm line is caught, and the verdict still says NOT RUN" \
  "[ -n \"\$(ls -A \"\$(C m-prewarm)/fix/bursts\")\" ] && command grep -qx 'VERDICT: NOT RUN' \"\$(V m-prewarm)\""
m=$(mutant noinstall measure.sh 's/-m pip install --no-deps --no-build-isolation -e python/-c pass/')
e2e "$m" m-noinstall
mcheck "mutant: a measure.sh that does not install the tree stops: python would import the image's sglang" \
  "! command grep -qx 'VERDICT: IMPROVED' \"\$(V m-noinstall)\" && command grep -qx 'stopped=install' \"\$(C m-noinstall)/prep/measure.txt\""
m=$(mutant cache measure.sh 's/^rm -rf "\$cache"; mkdir -p "\$cache"$/mkdir -p "$cache"; touch "$cache\/stale"/')
e2e "$m" m-cache
mcheck "mutant: a measure.sh that starts a server on a Triton cache that is not empty is caught" "command grep -qF 'entries at the start, not 0' \"\$(V m-cache)\""
m=$(mutant seed measure.sh 's/c16-r2:16:32:162/c16-r2:16:32:161/')
e2e "$m" m-seed
mcheck "mutant: a measure.sh whose bursts repeat a seed is caught by the plan check" "command grep -qF 'a different burst plan' \"\$(V m-seed)\""
m=$(mutant treecore-env measure.sh 's/^\[ -f "\$PREP\/rust-env.txt" \] && mapfile -t RUST_ENV < "\$PREP\/rust-env.txt"$/RUST_ENV=(X=1)/')
e2e "$m" m-treecore-env
mcheck "mutant: a server without the rustup location falls back to the Python TreeCore, which the verdict catches" \
  "command grep -qF 'not the prep' \"\$(V m-treecore-env)\""
check "the port is free after the mutants" "ports_free"

# ---------------------------------------------------------------- mutants of verdict.py, each caught by the unit checks
vmut() { # NAME SED
  m=$(mutant "v-$1" verdict.py "$2")
  units "$m" "$WORK/units-$1.log"
  mcheck "mutant: verdict.py $1 is caught by the unit checks" "command grep -q '^FAIL\|Traceback' '$WORK/units-$1.log'"
}
vmut "with another pinned patch hash" 's/^PATCH_SHA256 = "6aa4/PATCH_SHA256 = "7aa4/'
vmut "that ignores the patch hash" 's/    if patch.get("patch_sha256") != PATCH_SHA256:/    if False:/'
vmut "that ignores the source pins" 's/        v\["missing"\].extend(source_problems(out_dir, arm, pin))/        pass/'
vmut "that ignores a tree hash" 's/        if s.get("tree") != want_tree:/        if False:/'
vmut "that ignores the diff after the arm" 's/        if s\["numstat"\] != want_num:/        if False:/'
vmut "that passes the gate without the GQA line" 's/    if gate is None:/    if False:/'
vmut "that passes FIX without the prewarm line" 's/    if need_prewarm and prewarm is None:/    if False:/'
vmut "that ignores a prefill capture" 's/    if capture is not None:/    if False:/'
vmut "that lets BASE prewarm" 's/    if name == "base" and rep\["prewarm"\] is not None:/    if False:/'
vmut "that ignores kernels from another tree" 's/    if foreign:/    if False:/'
vmut "that ignores the TreeCore" 's/    if rep\["treecore"\] != TREECORE_CLASS.get(treecore):/    if False:/'
vmut "that counts a cache hit as a compile" 's/if c\["cache_hit"\] or c\["t"\] < ready or classify/if c["t"] < ready or classify/'
vmut "that calls any drop clearly fewer" 's/    clearly = f <= CLEAR_RATIO \* b and b - f >= CLEAR_MIN_DROP/    clearly = f < b/'
vmut "without the minimum drop" 's/^CLEAR_MIN_DROP = 5$/CLEAR_MIN_DROP = 0/'
vmut "that ignores the tests" 's/    if clearly and tests\["status"\] == "pass":/    if clearly:/'
vmut "that takes any passing count as the tests" 's/int(m.group(1)) == EXPECTED_TESTS and bad is None/bad is None/'
vmut "that lets a skipped burst pass" 's/            missing.append(f"{e\[.label.\]}: skipped, the time ran out")/            pass/'
vmut "that exits 0 on a failed gate" 's/        return v, 4/        return v, 0/'

# ---------------------------------------------------------------- the session: the cost print and the dirty-tree refusal
sched() { env -i PATH="$PATH" HOME="$HOME" INSTANCE_TYPE="$1" bash "$ROOT/hack/gpu-kit-session.sh" --print-schedule 2>&1; }
s2=$(sched g5.2xlarge)
check "the session prints the g5.2xlarge worst case, \$0.9696 to the 4,020 s termination deadline" \
  "[ \"$s2\" = 'instance_type=g5.2xlarge harness_end_s=3600 evidence_s=3660 stop_s=3720 termination_s=4020 worst_case_usd=0.9696' ]"
git clone -q "$ROOT" "$WORK/clone" 2>"$WORK/clone.err" || echo "FAIL could not clone HEAD: $(cat "$WORK/clone.err")" >&2
mkdir -p "$WORK/awsbin"
printf '#!/bin/bash\necho "fake aws $*" >> "%s/aws-calls"\necho "fake aws: no network here" >&2\nexit 1\n' "$WORK" >"$WORK/awsbin/aws"
chmod +x "$WORK/awsbin/aws"
session() { ( cd "$WORK/clone" && env -i PATH="$WORK/awsbin:$PATH" HOME="$HOME" SESSION_CONFIRM=yes OUT="$WORK/sess-$1" INSTANCE_TYPE=g5.2xlarge \
  bash hack/gpu-kit-session.sh docs/oss/sglang-51628/kit-r4 >"$WORK/sess-$1.log" 2>&1 ); }
check "the clone of HEAD holds the committed kit, its patch byte for byte" \
  "[ -f '$WORK/clone/docs/oss/sglang-51628/kit-r4/run.sh' ] && cmp -s '$WORK/clone/docs/oss/sglang-51628/kit-r4/prewarm.patch' '$KIT/prewarm.patch'"
# --ignored matters: docs/ is ignored, so a kit file that was never added would not show as untracked.
check "the committed kit is the working one: nothing modified, untracked or ignored in it" \
  "[ -z \"\$(git -C '$ROOT' status --porcelain --ignored -- docs/oss/sglang-51628/kit-r4 hack/sglang-51628-kit-r4-check.py hack/sglang-51628-kit-r4-test.sh hack/sglang-51628-fake-r4)\" ]"
echo "# edit" >>"$WORK/clone/docs/oss/sglang-51628/kit-r4/run.sh"
session edited; rc=$?
check "the session refuses an uncommitted edit to the kit, before any AWS call" \
  "[ $rc != 0 ] && command grep -qF 'SESSION REFUSED: the working tree is dirty' '$WORK/sess-edited.log' && [ ! -e '$WORK/aws-calls' ]"
git -C "$WORK/clone" checkout -q -- docs/oss/sglang-51628/kit-r4/run.sh
session clean; rc=$?
check "a clean tree passes the dirty-tree check and stops only at the first AWS call" \
  "[ $rc != 0 ] && command grep -qF 'the account check failed' '$WORK/sess-clean.log' && ! command grep -qF 'dirty' '$WORK/sess-clean.log'"

echo
if [ "$failures" = 0 ]; then echo "all checks passed"; else echo "$failures check(s) failed" >&2; fi
[ "$failures" = 0 ]
