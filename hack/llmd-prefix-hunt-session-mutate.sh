#!/usr/bin/env bash
#
# Mutation runs for hack/llmd-prefix-hunt-session-test.sh: each mutation breaks one guard in a copy of the session's files, and the offline test must fail on it.
# A mutation whose edit changed nothing is reported as not applied and counts as a failure of this script, so a stale pattern cannot pass as a killed mutant.
# The unmutated copy must pass first, or no mutant's failure means anything.
#
#   bash hack/llmd-prefix-hunt-session-mutate.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRATCH="${SCRATCH:-$HOME/.cache/llmd-prefix-hunt}"
mkdir -p "$SCRATCH"
WORK=$(mktemp -d -p "$SCRATCH")
[ -n "${KEEP_WORK:-}" ] || trap 'rm -rf "$WORK"' EXIT
D=hack/llmd-prefix-hunt

# copy DIR: the files the session and its test read, without any run records.
copy() {
  mkdir -p "$1/hack/lib" "$1/$D/probe"
  cp "$ROOT/hack/llmd-prefix-hunt-session.sh" "$ROOT/hack/llmd-prefix-hunt-session-test.sh" "$ROOT/hack/m5c-gpu-session.sh" "$1/hack/"
  cp "$ROOT/hack/lib/spot-run.sh" "$1/hack/lib/"
  cp "$ROOT/$D/runner.sh" "$ROOT/$D/verdict.py" "$1/$D/"
  cp "$ROOT/$D/probe/"*.go "$ROOT/$D/probe/go.mod" "$ROOT/$D/probe/go.sum" "$1/$D/probe/"
}

copy "$WORK/base"
if ! bash "$WORK/base/hack/llmd-prefix-hunt-session-test.sh" > "$WORK/base.log" 2>&1; then
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
  bash "$m/hack/llmd-prefix-hunt-session-test.sh" > "$m.log" 2>&1
  rc=$?
  fails=$(grep -c '^FAIL' "$m.log")
  if [ "$rc" != 0 ] && [ "$fails" -gt 0 ]; then
    echo "killed ($fails FAIL)  $name: $(grep -m1 '^FAIL' "$m.log" | cut -c6-150)"
  else
    echo "SURVIVED  $name (rc=$rc, $fails FAIL)"
    survived=$((survived + 1))
  fi
  rm -rf "$m"
}

# The verdict's guards: what keeps a void from passing as a result.
mutate "the verdict judges without a passing calibration" "$D/verdict.py" 's|    if calib != "pass" or len(sizes) != 1:|    if len(sizes) != 1:|'
mutate "the verdict judges with two engine block sizes" "$D/verdict.py" 's|    if calib != "pass" or len(sizes) != 1:|    if calib != "pass":|'
mutate "dedup ignores a prefix the engine still served after the flood" "$D/verdict.py" 's|            if post\["realized_cached_tokens"\] != 0:|            if False:|'
mutate "dedup ignores blocks never removed on the wire" "$D/verdict.py" 's|            if unremoved:|            if False:|'
mutate "dedup ignores a stale control" "$D/verdict.py" 's|        if pred(inc_post, "r16") != 0 or pred(inc_post, "r64") != 0:|        if False:|'
mutate "rows skip the token parity check" "$D/verdict.py" 's|    if row.get("router_prompt_tokens") != row.get("engine_prompt_tokens"):|    if False:|'
mutate "rows skip their failures" "$D/verdict.py" 's|    if row.get("error") or row.get("status") != 200 or row.get("realized_cached_tokens", -1) < 0:|    if False:|'
mutate "bias ignores an engine off its block rule" "$D/verdict.py" 's|        if r\["realized_cached_tokens"\] != expect:|        if False:|'
mutate "bias never refutes" "$D/verdict.py" 's|    if over == 0:|    if over < 0:|'
mutate "bias counts the last token as servable" "$D/verdict.py" 's|        expect = floor_to(min(r\["shared_len"\], n - 1), e)|        expect = floor_to(min(r["shared_len"], n), e)|'
# The session's exit status and its cost.
mutate "the session succeeds on a void" "hack/llmd-prefix-hunt-session.sh" 's|    case "$(verdict_of "$h")" in confirmed \| refuted) ;; \*) return 1 ;; esac|    true|'
mutate "the cost cap is raised" "hack/llmd-prefix-hunt-session.sh" 's|^COST_CAP_USD=3.00|COST_CAP_USD=30.00|'
mutate "the Spot cap is raised" "hack/llmd-prefix-hunt-session.sh" 's|^MAX_PRICE_FIXED=0.70|MAX_PRICE_FIXED=1.70|'
mutate "the probe bound grows in the session only" "hack/llmd-prefix-hunt-session.sh" 's|^PROBE_S=900|PROBE_S=1200|'
mutate "the session tests a different router commit than go.mod pins" "hack/llmd-prefix-hunt-session.sh" 's|^ROUTER_COMMIT=7fc31fd13348|ROUTER_COMMIT=7fc31fd13349|'
# The runner's pins and order.
mutate "the runner pulls another image" "$D/runner.sh" 's|sha256:20fdb089454afbb324efa4110a2c025ff7b27cc1a086e07aa580b18df8ad1ce1"$|sha256:cf5b2fdd087eb4f6d261736967cc5cde974bd22ff4df50365f8fa419b6b4c484"|'
mutate "the runner skips the revision label" "$D/runner.sh" 's|  grep -q " $VLLM_COMMIT\\$" "$D/image-identity.txt" \|\| { step "IMAGE IDENTITY FAILED|  true \|\| { step "IMAGE IDENTITY FAILED|'
mutate "the runner serves another model revision" "$D/runner.sh" 's|^MODEL_REV=895c3a49bc3fa70a340399125c650a463535e71c|MODEL_REV=main|'
mutate "the runner sets the engine block size" "$D/runner.sh" 's|--max-model-len 4096 --enforce-eager|--max-model-len 4096 --block-size 16 --enforce-eager|'
mutate "the runner starts the probe while A is not ready" "$D/runner.sh" 's|^ready a "$ADDR_A" "$START_A_S" \|\| {|true \|\| {|'
mutate "the runner floods only the capacity once over" "$D/runner.sh" 's|^flood=$(( (kv_tokens \* 3 / 2 + 1023) / 1024 ))|flood=$(( (kv_tokens + 1023) / 1024 ))|'
mutate "the runner probes without a readable KV capacity" "$D/runner.sh" 's|  step "KV CAPACITY UNREAD from replica a.s log"; stop_all; exit 2|  kv_tokens=107520|'
# The probe and its plan.
mutate "the probe predicts without waiting for events to settle" "$D/probe/main.go" 's|if s.Phase != "flood" \&\& !t.settle(o.quiet, o.grace, o.maxSettle) {|if false \&\& !t.settle(o.quiet, o.grace, o.maxSettle) {|'
mutate "the control case also sends full reports" "$D/probe/plan.go" 's|}{{"full", full, true}, {"incremental", inc, false}} {|}{{"full", full, true}, {"incremental", inc, true}} {|'
mutate "the probe reads the prediction after the request" "$D/probe/main.go" 's|^\t\tsend(ctx, client, target.base()+path, raw, \&rec)$|\t\t// the send moved above the prediction|; s|^\t\tif err := predict(ctx, parser, tokens, routers, o.pods, s, path, raw, o.model, \&rec); err != nil {|\t\tsend(ctx, client, target.base()+path, raw, \&rec)\n\t\tt.settle(o.quiet, o.grace, o.maxSettle)\n\t\tif err := predict(ctx, parser, tokens, routers, o.pods, s, path, raw, o.model, \&rec); err != nil {|'
mutate "the plan sends the post rows before the flood" "$D/probe/plan.go" 's|^\t\tfor i := range floodPrompts {|\t\tfor i := range 0 {|'

echo "$n mutant(s), $survived not killed"
[ "$survived" = 0 ]
