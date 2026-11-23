#!/usr/bin/env bash
#
# Offline gate for the single-A10G capacity kit (experiments/a10g-capacity): nothing here buys or launches anything.
#
#   bash hack/a10g-capacity-kit-test.sh            every check below
#   SKIP_E2E=1 bash hack/a10g-capacity-kit-test.sh  steps 1 to 4 only
#
# 1. The analysis's unit tests, every fixture's verdict (each rule passing and failing), and the mutants.
# 2. capacityrun's Go tests: the contract against this build's pins, the trace, the stage and the restart prober.
# 3. The kit's pins: the source commit it builds is pushed and its sender code equals this tree's.
# 4. run.sh: syntax, a dry run, and each refusal (a moved pin, a KIT_ setting, a non-empty OUT, a bad scale).
# 5. run.sh end to end against the benchharness stub, time-compressed by 0.1: it must reach its report with no exclusion,
#    find an unstable rung inside the ladder, run the cycle and three restarts.
# 6. The same with one cycle row deleted before the report: the ledger check must fail it (exit 3, rule X4).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
KIT=experiments/a10g-capacity/kit
TEST=experiments/a10g-capacity/test
WORK=$(mktemp -d /tmp/a10g-kit-test.XXXXXX)
fails=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; fails=$((fails + 1)); }

# ---------------------------------------------------------------- 1
( cd "$TEST" && PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -q test_kit ) > "$WORK/unit.log" 2>&1 &&
  ok "unit tests and fixtures ($(grep -o 'Ran [0-9]* tests' "$WORK/unit.log"))" || { bad "unit tests"; tail -20 "$WORK/unit.log"; }
python3 "$TEST/fixtures.py" "$WORK/fixtures" > /dev/null 2>&1 || bad "fixtures did not build"
while IFS=$'\t' read -r name cmd want why; do
  case "$cmd" in rung) target=$name/rung-01 ;; cycle) target=$name/cycle ;; *) target=$name ;; esac
  python3 -I "$KIT/analysis.py" "$cmd" "$KIT/contract.json" "$WORK/fixtures/$target" > "$WORK/fx-$name.log" 2>&1
  got=$?
  line=$(grep -m1 -E 'REFUSED|"S[123] |exclusions:|"result"' "$WORK/fx-$name.log" | sed 's/^ *//' | cut -c1-100)
  [ "$got" = "$want" ] && ok "fixture $name: exit $got as required ($why) ${line:+-- $line}" || bad "fixture $name: exit $got, want $want ($why)"
done < <(python3 -c 'import json,sys; [print("\t".join([f["name"], f["cmd"], str(f["want_exit"]), f["why"]])) for f in json.load(open(sys.argv[1]))]' "$WORK/fixtures/manifest.json")
( cd "$TEST" && python3 mutate.py ) > "$WORK/mutants.log" 2>&1 && ok "mutants: $(tail -1 "$WORK/mutants.log")" ||
  { bad "mutants"; grep -E 'SURVIVED|STALE' "$WORK/mutants.log"; tail -1 "$WORK/mutants.log"; }

# ---------------------------------------------------------------- 2
go test -count=1 ./cmd/capacityrun > "$WORK/go.log" 2>&1 && ok "capacityrun go tests" || { bad "capacityrun go tests"; tail -20 "$WORK/go.log"; }

# ---------------------------------------------------------------- 3
src=$(sed -n 's/^SRC_SHA=\([0-9a-f]\{40\}\)$/\1/p' "$KIT/run.sh")
if [ -z "$src" ]; then
  bad "run.sh pins no 40-character SRC_SHA"
else
  git cat-file -e "$src^{commit}" 2>/dev/null && ok "SRC_SHA $src is a commit here" || bad "SRC_SHA $src is not a commit in this repository"
  [ -n "$(git branch -r --contains "$src" 2>/dev/null)" ] && ok "SRC_SHA is on a pushed branch" || bad "SRC_SHA $src is on no pushed branch, so the instance cannot fetch it"
  # The kit builds the sender at SRC_SHA, so the sender code there must be the code tested here.
  git diff --quiet "$src" HEAD -- cmd/capacityrun internal/bench internal/engineargs internal/gateway api go.mod go.sum &&
    ok "the sender code at SRC_SHA equals this tree's" || bad "the sender code changed after SRC_SHA; repin it"
fi

# ---------------------------------------------------------------- 4
bash -n "$KIT/run.sh" && ok "run.sh parses" || bad "run.sh does not parse"
o=$WORK/dry; mkdir -p "$o"
OUT=$o KIT_DRY_RUN=1 bash "$KIT/run.sh" > "$WORK/dry.log" 2>&1 && grep -q 'settings accepted' "$WORK/dry.log" && ok "dry run accepts the contract" || bad "dry run"
refuse() { # label, then env assignments; run.sh must exit non-zero
  local label=$1; shift
  local o=$WORK/refuse-$label; mkdir -p "$o"
  if env "$@" OUT="$o" KIT_DRY_RUN=1 bash "$KIT/run.sh" > "$o.log" 2>&1; then bad "run.sh accepted $label"; else ok "run.sh refuses $label: $(tail -1 "$o.log" | cut -c1-80)"; fi
}
refuse pin SRC_SHA=0000000000000000000000000000000000000000
refuse kit-setting KIT_RATES=10
refuse scale KIT_OFFLINE_TEST=1 KIT_TEST_SCALE=2
o=$WORK/nonempty; mkdir -p "$o"; touch "$o/leftover"
if OUT=$o KIT_DRY_RUN=1 bash "$KIT/run.sh" > "$WORK/nonempty.log" 2>&1; then bad "run.sh accepted a non-empty OUT"; else ok "run.sh refuses a non-empty OUT"; fi

if [ "${SKIP_E2E:-}" = 1 ]; then
  echo "SKIPPED the end-to-end runs (SKIP_E2E=1); this is not a pass of steps 5 and 6"
  echo; [ "$fails" = 0 ] && { echo "checks passed (steps 1-4 only)"; exit 0; } || { echo "$fails check(s) failed"; exit 1; }
fi

# ---------------------------------------------------------------- 5, 6
mkdir -p "$WORK/bin"
go build -o "$WORK/bin/capacityrun" ./cmd/capacityrun && go build -o "$WORK/bin/benchharness" ./cmd/benchharness || bad "could not build the binaries"
OUT=$WORK/e2e KIT_OFFLINE_TEST=1 KIT_TEST_BIN=$WORK/bin bash "$KIT/run.sh" > "$WORK/e2e.log" 2>&1
rc=$?
r=$WORK/e2e/report.json
if [ "$rc" = 0 ] && [ -f "$r" ] && python3 - "$r" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
p = r["plan"]
assert p["run"] and p["status"] == "saturated" and p["first_unstable"] is not None, p
c = r["stages"]["cycle"]
assert set(c["segments"]) == {"baseline", "saturation", "overload", "recovery"}, c["segments"].keys()
assert c["recovery"].get("recovered") is True, c["recovery"]
assert [x["outcome"] for x in r["restarts"]] == ["serving"] * 3, r["restarts"]
assert not r["exclusions"], r["exclusions"]
PY
then
  ok "end to end: $(grep -m1 '^pilot:' "$WORK/e2e/report.txt"); $(grep -m1 -E '^  recovery: ([0-9]|not)' "$WORK/e2e/report.txt" | sed 's/^ *//'); 3 restarts serving"
else
  bad "end to end (exit $rc)"; tail -30 "$WORK/e2e.log"
fi
OUT=$WORK/e2e-drop KIT_OFFLINE_TEST=1 KIT_TEST_BIN=$WORK/bin KIT_TEST_FAULTS=drop-row KIT_TEST_PORT=18474 bash "$KIT/run.sh" > "$WORK/e2e-drop.log" 2>&1
rc=$?
if [ "$rc" = 3 ] && grep -q '^exclusions: X4 .*/cycle: ' "$WORK/e2e-drop/report.txt"; then
  ok "a deleted cycle row fails the ledger: $(grep -m1 '^exclusions:' "$WORK/e2e-drop/report.txt" | cut -c1-110)"
else
  bad "a deleted cycle row was not caught (exit $rc)"; tail -10 "$WORK/e2e-drop.log"
fi

echo "work directory: $WORK"
echo; [ "$fails" = 0 ] && { echo "all checks passed"; exit 0; } || { echo "$fails check(s) failed"; exit 1; }
