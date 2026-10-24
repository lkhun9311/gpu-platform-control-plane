#!/usr/bin/env bash
#
# Checks hack/lib/mps-journal.sh against the reader it writes for: every journal here is judged by the real
# `benchharness mps-capability-verdict`, so the writer and the classifier cannot drift apart unnoticed.
#
#   bash hack/test/check-mps-journal.sh
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

fails=0
ok() { echo "ok: $*"; }
bad() { echo "FAIL: $*"; fails=$((fails + 1)); }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

go build -o "$work/benchharness" ./cmd/benchharness || { echo "check-mps-journal: could not build benchharness"; exit 1; }
# shellcheck source=hack/lib/mps-journal.sh
source hack/lib/mps-journal.sh

verdict() { "$work/benchharness" mps-capability-verdict --journal "$MPS_JOURNAL" 2>&1; }

# A whole passing session, written as the session would write it.
export MPS_JOURNAL="$work/pass.jsonl"
for b in B0 B1 B2 B3 B4 B5; do mj_start "$b" && mj_decide "$b" pass "read as registered"; done
for f in launch_time_read overlay_pinned manifests_pinned images_pulled schedulable termination_confirmed diagnostics_uploaded provenance_complete; do
  mj_fact "$f" true
done
mj_fact no_healthy_devices_event false
mj_fact daemon_rejected_client false
out=$(verdict)
[[ "$out" == "MPS: PASS"* ]] && ok "a whole session written by the library reads as PASS" || bad "a whole session did not read as PASS: $out"

# A reason quoting an event, with quotes, a newline and a backslash, must stay one readable line.
export MPS_JOURNAL="$work/quoted.jsonl"
mj_start B2 && mj_decide B2 fail $'kubelet said "Allocate failed due to no healthy devices"\nsecond line \\ end'
mj_fact launch_time_read true
mj_fact termination_confirmed true
lines=$(wc -l <"$MPS_JOURNAL")
out=$(verdict)
# Four records, the start, the decision and two facts, so four lines: one more would be the reason's newline.
[[ "$lines" == 4 && "$out" == "MPS: INCONCLUSIVE"* ]] && ok "a quoted multi-line reason stays one line and the journal stays readable" ||
  bad "a quoted reason broke the journal ($lines lines): $out"
grep -q 'no healthy devices' "$MPS_JOURNAL" && ok "the reason is kept verbatim" || bad "the reason was lost"

# A session cut short after B1 started: interrupted, not passed and not absent.
export MPS_JOURNAL="$work/cut.jsonl"
mj_start B0 && mj_decide B0 pass ok
mj_start B1
mj_fact launch_time_read true
mj_fact termination_confirmed true
out=$(verdict)
grep -qx "B1 interrupted" <<<"$out" && grep -qx "B2 absent" <<<"$out" && ok "a bar started and never decided reads as interrupted" ||
  bad "the cut-short session read as: $out"
[[ "$(mj_result B0)" == pass && -z "$(mj_result B1)" ]] && ok "mj_result reads a decided bar and nothing for an undecided one" ||
  bad "mj_result gave '$(mj_result B0)' and '$(mj_result B1)'"

# What the library must refuse to write, because the reader would refuse the journal.
export MPS_JOURNAL="$work/refused.jsonl"
mj_start B6 2>/dev/null && bad "a bar the registration does not have was written" || ok "an unknown bar is refused"
mj_start B0 && { mj_decide B0 ok 2>/dev/null && bad "a result that is not pass, fail or unmeasured was written" || ok "an unknown result is refused"; }
mj_fact provenance_complete yes 2>/dev/null && bad "a fact that is not true or false was written" || ok "a non-boolean fact is refused"
mj_fact provenance_complete true
mj_fact provenance_complete false 2>/dev/null && bad "a fact was recorded twice" || ok "a second record of a fact is refused"
mj_has_fact provenance_complete && ok "mj_has_fact finds a recorded fact" || bad "mj_has_fact missed a recorded fact"
mj_has_fact diagnostics_uploaded && bad "mj_has_fact found a fact never recorded" || ok "mj_has_fact does not find an absent fact"
[[ $(wc -l <"$MPS_JOURNAL") == 2 ]] && ok "none of the refused lines reached the file" || bad "a refused line reached the file: $(cat "$MPS_JOURNAL")"
( unset MPS_JOURNAL; mj_start B0 2>/dev/null ) && bad "a line was written with no MPS_JOURNAL" || ok "no MPS_JOURNAL is refused"

# The upload hook runs after every line, so a journal cut short has still been uploaded as far as it got.
export MPS_JOURNAL="$work/hook.jsonl" MPS_JOURNAL_ON_APPEND="eval echo x >>$work/hook.count"
mj_start B0 && mj_decide B0 pass ok && mj_fact launch_time_read true
unset MPS_JOURNAL_ON_APPEND
[[ $(wc -l <"$work/hook.count") == 3 ]] && ok "the upload hook ran once per line" || bad "the upload hook ran $(wc -l <"$work/hook.count") times for 3 lines"

if [[ $fails -ne 0 ]]; then
  echo "check-mps-journal: $fails failure(s)"
  exit 1
fi
echo "check-mps-journal: all checks passed"
