#!/usr/bin/env bash
#
# Mutation runs for hack/vllm-gdn-68414-session-test.sh: each mutation breaks one guard of run 3 in a copy of the session's files, and the offline test must fail on it.
# A mutation whose edit changed nothing is reported as not applied and counts as a failure of this script, so a stale pattern cannot pass as a killed mutant.
# The unmutated copy must pass first, or no mutant's failure means anything.
#
#   bash hack/vllm-gdn-68414-session-mutate.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK=$(mktemp -d)
[ -n "${KEEP_WORK:-}" ] || trap 'rm -rf "$WORK"' EXIT
D=hack/vllm-gdn-68414

# copy DIR: the files the session and its test read, without the run records.
copy() {
  mkdir -p "$1/hack/lib" "$1/$D"
  cp "$ROOT/hack/vllm-gdn-68414-session.sh" "$ROOT/hack/vllm-gdn-68414-session-test.sh" "$ROOT/hack/m5c-gpu-session.sh" "$1/hack/"
  cp "$ROOT/hack/lib/spot-run.sh" "$1/hack/lib/"
  find "$ROOT/$D" -maxdepth 1 -type f -exec cp {} "$1/$D/" \;
}

copy "$WORK/base"
if ! bash "$WORK/base/hack/vllm-gdn-68414-session-test.sh" > "$WORK/base.log" 2>&1; then
  echo "the unmutated copy fails its own test; see $WORK/base.log" >&2
  tail -n 5 "$WORK/base.log" >&2
  exit 2
fi
echo "base  the unmutated copy passes ($(grep -c '^ok' "$WORK/base.log") checks)"

survived=0
n=0
# mutate NAME FILE SED: one mutant, killed only when the test exits non-zero with at least one FAIL line.
mutate() {
  local name=$1 file=$2 expr=$3 m rc fails
  n=$((n + 1))
  m="$WORK/m$n"
  copy "$m"
  sed -i "$expr" "$m/$file"
  if cmp -s "$ROOT/$file" "$m/$file"; then
    echo "NOT APPLIED  $name ($file: $expr)"
    survived=$((survived + 1))
    return
  fi
  bash "$m/hack/vllm-gdn-68414-session-test.sh" > "$m.log" 2>&1
  rc=$?
  fails=$(grep -c '^FAIL' "$m.log")
  if [ "$rc" != 0 ] && [ "$fails" -gt 0 ]; then
    echo "killed ($fails FAIL)  $name: $(grep -m1 '^FAIL' "$m.log" | cut -c6-150)"
  else
    echo "SURVIVED  $name (rc=$rc, $fails FAIL)"
    survived=$((survived + 1))
  fi
}

# #68415 is dormant in run 4: its state script and verdict are neither shipped nor run, so only its diffs' hashes and pins are still checked.
# The stride verdict accepting a failure that is not assert_close's, or skipping the whole file.
mutate "the stride verdict ignores what the failure was" "$D/stride-verdict.py" 's|        if all(BUG_LINE in t.splitlines() and any(x.startswith(MISMATCH) for x in t.splitlines()) for _, _, t in tc):|        if True:|'
mutate "the stride verdict accepts an error for a failure" "$D/stride-verdict.py" 's|    if all(o == "failure" for _, o, _ in tc):|    if all(o in ("failure", "error") for _, o, _ in tc):|'
mutate "the stride verdict skips the whole file" "$D/stride-verdict.py" 's|    elif rf != "passed":|    elif False:|'
mutate "the stride verdict ignores the whole file's shape" "$D/stride-verdict.py" 's| and shape == FILE_SHAPE and not bad:| and not bad:|'
mutate "the stride verdict lets BEFORE run other cases" "$D/stride-verdict.py" 's|    if len(names) != 3 or set(names) != CASES:|    if False:|'
# #68416 BEFORE applying the fix.
mutate "#68416 BEFORE applies the whole fix" "$D/stride-state.sh" 's|^  before) DIFF=\$IN/stride-test.diff ;;|  before) DIFF=$IN/stride-fix.diff ;;|'
mutate "#68416 runs without -k stride" "$D/stride-state.sh" 's|^SELECT=("$TEST" -k stride)|SELECT=("$TEST")|'
# The summary missing the assertion lines.
mutate "the summary prints no assertion lines" "$D/pytest-summary.py" 's|                    al = assertion_lines(text)|                    al = []|'
mutate "the summary drops the E lines and keeps the statement" "$D/pytest-summary.py" 's|    return \[f"> {s}" for s in src\] + \[lines\[i\] for i in e if lines\[i\].strip() != "E"\]|    return [f"> {s}" for s in src]|'
mutate "the summary drops the image" "$D/pytest-summary.py" 's|    out += \[f"   {x}" for x in image(sweep)\]|    pass|'
mutate "pytest runs without --tb=short" "$D/lib.sh" 's| -rA --tb=short -p no:cacheprovider| -rA -p no:cacheprovider|'
# A wrong diff hash.
mutate "a wrong #68416 fix pin" "hack/vllm-gdn-68414-session.sh" 's|^STRIDE_FIX_DIFF_SHA256=0|STRIDE_FIX_DIFF_SHA256=1|'
mutate "a wrong #68416 test pin" "hack/vllm-gdn-68414-session.sh" 's|^STRIDE_TEST_DIFF_SHA256=2|STRIDE_TEST_DIFF_SHA256=3|'
mutate "a changed #68416 fix diff" "$D/stride-fix.diff" 's|^+            ).to(tl.int64)$|+            ).to(tl.int32)|'
mutate "a changed #68415 test diff" "$D/kda-test.diff" 's|^+    num_tokens = 4$|+    num_tokens = 5|'
# Another item's fix leaking into #68416's BEFORE.
mutate "#68416's pins accept #68415's fixed kda.py in BEFORE" "$D/stride-pins.txt" 's|^before 64079bb4f2225db34868c55f1bb506f8beb2a48be0654bda2c884faeead9bdff |before e32c1408cf36626235d81f337ed5ac7159d5bb3996d1728398a042e961541143 |'
mutate "#68415's pins accept #68416's fixed fused_recurrent.py in BEFORE" "$D/kda-pins.txt" 's|^before 9915fb0fe69f3b1205eff1532cb51c4cb640badd4e1bdf8dddced89de6e2ed69 |before 56e92a496560766dded4de0c407645f60ddd0d3dd41b749f30db3ab329e4a7e5 |'
mutate "a state goes on when the image's files are not the commit's" "$D/lib.sh" 's|  \[ "\$base" = ok \] \|\| refuse|  true \|\| refuse|'
mutate "the stride import check ignores #68415's fix in kda.py" "$D/stride-verdict.py" 's|    if st.get("kda_fix_grep_rc") != "1" or st.get("kda_bug_grep_rc") != "0":|    if False:|'
mutate "the pins drop torch_utils.py" "$D/lib.sh" 's|^PINNED_PATHS=8|PINNED_PATHS=7|'
# The image and the base proof.
mutate "the runner pins run 3's image" "$D/runner.sh" 's|sha256:639209c4b3c1f16f309837668608ac889e92db0d4dd4facf5a6987c6d54ef8ac|sha256:9071b00dc36251a304e9099ed40b42a8260f8feb23432c8f312689e34c4d3f5f|g'
mutate "the stride verdict accepts run 3's image" "$D/stride-verdict.py" 's|^IMAGE_DIGEST = .*|IMAGE_DIGEST = "sha256:9071b00dc36251a304e9099ed40b42a8260f8feb23432c8f312689e34c4d3f5f"|'
mutate "the stride verdict ignores what the collection loaded" "$D/stride-verdict.py" 's|    if st.get("loaded_differs") != "none":|    if False:|'
mutate "the differs list is run 3's" "$D/stride-differs.txt" 's|^recipes/models/deepseek-ai/DeepSeek-V4.1-Flash.yaml$|vllm/v1/engine/detokenizer.py|'
mutate "the probe compares against no list" "$D/lib.sh" 's|  hits=$(awk .{print $2}. "$O/loaded-modules.txt" 2>/dev/null \| grep -Fxf "$PROBE_DIFFERS" \| paste -sd, -)|  hits=""|'
# #68415 staying out of run 4.
mutate "the runner runs a #68415 state again" "$D/runner.sh" 's|^step "stride states done"$|step "stride states done"\ncontained kda-state.sh kda-before $(( SETUP_S + PROBE_S + PYTEST_S + STOP_S )) "$PYTEST_S" "$PROBE_S"|'
mutate "derive-pins.sh derives #68415 on run 4's image" "$D/derive-pins.sh" 's|^  kda \| kda-differs) echo .*|  kda \| kda-differs) STATES="base: before:kda-test.diff after:kda-fix.diff"; DIFFBASE=428c371b32c18a788def35abea1cb9f579278381; FIXCOMMIT=841cd50ff065f983c49f0cbd3cb63ac662de4ed7 ;;|'
# What codex's adversarial passes added: the unfit #68416 diffs, the quoted provenance, and the GPU.
mutate "the session buys with #68416's unfit fix diff" "hack/vllm-gdn-68414-session.sh" 's|^for unfit in 6bf2352933b148465f6437098280bfba2c1e4ff7ca586ca3d5e9d87fc71a6fe9 |for unfit in |'
mutate "the session buys with #68416's unfit test diff" "hack/vllm-gdn-68414-session.sh" 's| abbfbaf392a39a3083ab1ff285dd3f747ebde4fa07b157f20781503391ea3ec4; do$|; do|'
mutate "the stride verdict ignores the recorded provenance" "$D/stride-verdict.py" 's|    elif ev != "ok":|    elif False:|'
mutate "the stride verdict ignores the recorded GPU" "$D/stride-verdict.py" 's|    if "A10G" not in st.get("gpu_name", ""):|    if False:|'

echo "$n mutant(s), $survived not killed"
[ "$survived" = 0 ]
