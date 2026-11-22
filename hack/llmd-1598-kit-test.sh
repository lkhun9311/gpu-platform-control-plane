#!/usr/bin/env bash
#
# Offline gate for the llm-d-router #1598 pilot kit (docs/oss/llmd-1598): nothing here buys or launches anything.
#
#   bash hack/llmd-1598-kit-test.sh            every check below
#   SKIP_E2E=1 bash hack/llmd-1598-kit-test.sh  the unit tests, mutants and run.sh refusals only
#
# 1. The unit tests: every analysis, ledger, join and verdict rule on synthetic rows; they and every later step must leave
#    no temporary directory behind, and a deliberately dropped cleanup must be seen.
# 2. The mutants: each breaks one rule, and the tests must fail on every one.
# 3. run.sh: syntax, a dry run, and each refusal (budget, a moved pin, a KIT_ override, a non-empty OUT).
# 4. run.sh end to end offline: the real EPP binaries (A1 at the pinned router SHA, A2 with #4313 merged, checked against
#    the pinned merged tree) and the pinned Envoy, in front of four fake engines; the verdict must be APPARATUS HOLDS.
# 5. The same with an engine fault each (a token counter off by one, a cache reset that fails); the verdict must be
#    APPARATUS FAILED naming the check, so a broken check cannot pass silently.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
KIT=docs/oss/llmd-1598/kit
TEST=docs/oss/llmd-1598/test
BIN=${KIT_TEST_BIN:-$HOME/.cache/llmd1598-bin}
# TMPDIR moves the scratch off /tmp when /tmp is short of space or inodes; the end-to-end runs leave about 800 files each.
WORK=$(mktemp -d "${TMPDIR:-/tmp}/llmd1598-kit-test.XXXXXX")
# The gate's own directory goes on every exit, a failure included; KEEP_WORK=1 keeps it to read the logs.
# Earlier runs kept it and the tests' own directories, and filled /tmp's inodes.
[ "${KEEP_WORK:-}" = 1 ] || trap 'rm -rf "$WORK"' EXIT
# Everything the tests, the mutants and the kit create with tempfile goes into this directory, which must be empty
# again after each step; counting it before and after is how a leak shows here rather than in /tmp.
TT=$WORK/tmp
mkdir -p "$TT"
fails=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; fails=$((fails + 1)); }
left_in() { find "$1" -mindepth 1 -maxdepth 1 | wc -l; }
no_leftovers() { # label; TT must hold nothing the step left behind
  local n; n=$(left_in "$TT")
  if [ "$n" = 0 ]; then ok "$1 left no temporary directories"; else bad "$1 left $n temporary entries in TMPDIR"; ls "$TT" | head -5; rm -rf "${TT:?}"/*; fi
}

# ---------------------------------------------------------------- 1, 2
[ "$(left_in "$TT")" = 0 ] || bad "TMPDIR for the tests is not empty before they start"
( cd "$TEST" && TMPDIR=$TT python3 -m unittest -q test_kit ) > "$WORK/unit.log" 2>&1 && ok "unit tests ($(grep -o 'Ran [0-9]* tests' "$WORK/unit.log"))" \
  || { bad "unit tests"; tail -20 "$WORK/unit.log"; }
no_leftovers "unit tests"
# The leftover check must see a dropped cleanup: KIT_TEST_LEAK=1 makes the tests skip their removal.
leak=$WORK/leak; mkdir -p "$leak"
( cd "$TEST" && KIT_TEST_LEAK=1 TMPDIR=$leak python3 -m unittest -q test_kit ) > "$WORK/leak.log" 2>&1
n=$(left_in "$leak")
[ "$n" -gt 0 ] && ok "the leftover check sees a dropped cleanup ($n directories)" || bad "a dropped cleanup left nothing to see"
rm -rf "$leak"
( cd "$TEST" && TMPDIR=$TT python3 mutate.py ) > "$WORK/mutants.log" 2>&1 && ok "mutants: $(tail -1 "$WORK/mutants.log")" \
  || { bad "mutants"; grep -E 'SURVIVED|STALE' "$WORK/mutants.log"; tail -1 "$WORK/mutants.log"; }
no_leftovers "mutants"

# ---------------------------------------------------------------- 3
bash -n "$KIT/run.sh" && ok "run.sh parses" || bad "run.sh does not parse"
o=$WORK/dry; mkdir -p "$o"
for st in pilot pilot2 pilot3; do
  o=$WORK/dry-$st; mkdir -p "$o"
  OUT=$o STAGE=$st KIT_DRY_RUN=1 bash "$KIT/run.sh" > "$WORK/dry-$st.log" 2>&1 && grep -q 'settings accepted' "$WORK/dry-$st.log" \
    && grep -q "^stage=$st$" "$o/settings.txt" && ok "dry run accepts STAGE=$st" || bad "dry run STAGE=$st"
done
refuse() { # label, then env assignments; run.sh must exit non-zero and print why
  local label=$1; shift
  local o=$WORK/refuse-$label; mkdir -p "$o"
  if env "$@" OUT="$o" KIT_DRY_RUN=1 bash "$KIT/run.sh" > "$o.log" 2>&1; then bad "run.sh accepted $label"; else ok "run.sh refuses $label: $(tail -1 "$o.log" | cut -c1-90)"; fi
}
refuse budget STAGE=pilot2 BUDGET_S=3300
refuse no-stage STAGE=
refuse unknown-stage STAGE=main
refuse pin STAGE=pilot2 ROUTER_SHA=0000000000000000000000000000000000000000
refuse override STAGE=pilot2 KIT_ARMS=A1
o=$WORK/nonempty; mkdir -p "$o"; touch "$o/leftover"
if OUT=$o STAGE=pilot2 KIT_DRY_RUN=1 bash "$KIT/run.sh" > "$WORK/nonempty.log" 2>&1; then bad "run.sh accepted a non-empty OUT"; else ok "run.sh refuses a non-empty OUT"; fi

if [ "${SKIP_E2E:-}" = 1 ]; then
  echo "SKIPPED the end-to-end runs (SKIP_E2E=1); this is not a pass of steps 4 and 5"
  echo; [ "$fails" = 0 ] && { echo "checks passed (steps 1-3 only)"; exit 0; } || { echo "$fails check(s) failed"; exit 1; }
fi

# ---------------------------------------------------------------- the real binaries, from the kit's own pins
pin() { sed -n "s/^$1=\(.*\)$/\1/p" "$KIT/run.sh" | head -1; }
ROUTER_SHA=$(pin ROUTER_SHA); PR_SHA=$(pin PR_SHA); MERGED_TREE=$(pin MERGED_TREE); ENVOY_SHA256=$(pin ENVOY_SHA256)
ENVOY_URL=$(pin ENVOY_URL)
mkdir -p "$BIN"
if [ ! -x "$BIN/epp-a1" ] || [ ! -x "$BIN/epp-a2" ]; then
  src=$BIN/router; rm -rf "$src"; mkdir -p "$src"
  ( git -C "$src" init -q && git -C "$src" fetch -q --filter=blob:none https://github.com/llm-d/llm-d-router "$ROUTER_SHA" &&
    git -C "$src" fetch -q --filter=blob:none https://github.com/DolevAdas/llm-d-router "$PR_SHA" &&
    git -C "$src" checkout -q "$ROUTER_SHA" && cd "$src" && GOTOOLCHAIN=go1.27.4 CGO_ENABLED=0 go build -trimpath -o "$BIN/epp-a1" ./cmd/epp &&
    git -c user.name=kit -c user.email=kit@localhost merge --no-ff --no-edit -q "$PR_SHA" &&
    [ "$(git rev-parse 'HEAD^{tree}')" = "$MERGED_TREE" ] &&
    GOTOOLCHAIN=go1.27.4 CGO_ENABLED=0 go build -trimpath -o "$BIN/epp-a2" ./cmd/epp ) > "$WORK/build.log" 2>&1 \
    || { bad "building the EPP binaries; see $WORK/build.log"; tail -5 "$WORK/build.log"; exit 1; }
fi
if [ ! -x "$BIN/envoy" ] || [ "$(sha256sum "$BIN/envoy" | cut -d' ' -f1)" != "$ENVOY_SHA256" ]; then
  curl -fsSL -o "$BIN/envoy" "$ENVOY_URL" && chmod +x "$BIN/envoy" || { bad "envoy download"; exit 1; }
fi
[ "$(sha256sum "$BIN/envoy" | cut -d' ' -f1)" = "$ENVOY_SHA256" ] && ok "envoy matches the pinned sha256" || { bad "envoy sha256"; exit 1; }
ok "EPP binaries: $(sha256sum "$BIN/epp-a1" "$BIN/epp-a2" | awk '{print substr($1,1,12)}' | tr '\n' ' ')"

e2e() { # label, expected exit, budget, faults, a check on the verdict, then the stage, the fake engines' ITL and the time scale
  local label=$1 want=$2 budget=$3 faults=$4 expect=$5 stage=${6:-pilot} itl=${7:-4} scale=${8:-0.2}
  local o=$WORK/e2e-$label
  TMPDIR=$TT OUT=$o STAGE=$stage KIT_TEST_ITL_MS=$itl KIT_TEST_SCALE=$scale KIT_OFFLINE_TEST=1 KIT_TEST_BIN=$BIN KIT_TEST_FAKE=$PWD/$TEST/fake_engine.py KIT_TEST_BUDGET_S=$budget \
    KIT_TEST_FAULTS="$faults" bash "$KIT/run.sh" > "$o.log" 2>&1
  local rc=$?
  if [ "$rc" = "$want" ] && grep -qE "$expect" "$o/verdict.txt" 2>/dev/null; then
    ok "offline $label: exit $rc, $(head -1 "$o/verdict.txt")"
  else
    bad "offline $label: exit $rc (wanted $want), verdict: $(head -3 "$o/verdict.txt" 2>/dev/null | tr '\n' ' ')"
  fi
  # Every run leaves its records checksummed, whatever the verdict.
  ( cd "$o" && sha256sum -c --quiet SHA256SUMS ) > /dev/null 2>&1 && ok "offline $label: SHA256SUMS verifies" || bad "offline $label: SHA256SUMS"
}
# ---------------------------------------------------------------- 4, 5
e2e clean 0 1500 "" '^verdict: APPARATUS HOLDS'
e2e token-off-by-one 4 150 "token_off_by_one" 'failed .*ledger'
e2e reset-fails 4 150 "reset_fails" 'failed .*reset'
# The second pilot on fake engines slow enough (25 ms a token) that both ladders find a knee: the verdict must hold with an
# anchor for every block, and K's primed bursts must have gone out within the registered span.
e2e pilot2 0 1500 "" '^verdict: APPARATUS HOLDS' pilot2 25
# The K-only third pilot on fake engines that, like vLLM, send headers at once and the body after prefill: under the second
# pilot's header bound every preloaded burst would be invalid; under the body bound the acceptance rules must pass.
# At scale 0.5 each K cell keeps all 12 bursts, so the 90%-within-2-ms release rule is judged as on the GPU, where one slow
# release on this shared host is one burst in twelve rather than one in four.
e2e pilot3 0 900 "" '^verdict: APPARATUS HOLDS' pilot3 4 0.5

echo
no_leftovers "the end-to-end runs"
if [ "$fails" = 0 ]; then echo "all checks passed"; exit 0; else echo "$fails check(s) failed"; exit 1; fi
