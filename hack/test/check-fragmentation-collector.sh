#!/usr/bin/env bash
#
# Checks that hack/fragmentation.sh samples its timeline continuously while the repack arm intervenes, with every
# cluster call replaced by a stub, without a cluster.
#
#   bash hack/test/check-fragmentation-collector.sh
#
# The study's pre-registration invalidates a trial on a collection gap over 5 s.
# Before the collector ran as its own process, the R arm's intervention paused the sampler for 13.6 s in all five
# trials, so here the stubbed replica takes 7 s to run, longer than the rule allows, and the timeline must still show
# no gap over 5 s and must itself contain the middle state.
# About 70 s, most of it the script's own fixed sleeps.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

fails=0
ok() { echo "ok: $*"; }
bad() { echo "FAIL: $*"; fails=$((fails + 1)); }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# run_trial NAME ARM [CLASSIFY_LIMIT] [WINDOW] [FAIL_DELETE] [HANG]: one stubbed trial of ARM in its own evidence
# directory; CLASSIFY_LIMIT makes the stubbed classifier fail on that call, as a dead kubectl would, FAIL_DELETE=1 makes
# the original holder's deletion fail, so set -e ends the foreground mid-intervention, and HANG=1 makes the classifier's
# second call block in a child process, as a kubectl request with no timeout would.
run_trial() {
  local name="$1" arm="$2" limit="${3:-0}" window="${4:-4}" fail_delete="${5:-0}" hang="${6:-0}" dir="$work/$1"
  mkdir -p "$dir"
  echo fragmentation >"$dir/state"
  (
    # shellcheck source=hack/fragmentation.sh
    source hack/fragmentation.sh
    EXDIR="$dir" WINDOW="$window" REPACK_AT=2 REPACK_WATCH=3
    # main installs this trap; the sourced script does not run main, so the case installs it as main does.
    trap on_exit EXIT
    STATE="$dir/state"
    calls=0
    k() {
      printf '%s\n' "$*" >>"$EXDIR/k-calls.log"
      if [[ "$*" == *"delete job frag-h1-"* ]]; then
        [[ "$fail_delete" == 1 ]] && return 1
        echo scheduled >"$STATE"
      fi
      return 0
    }
    free_for() {
      case "$(cat "$STATE")" in
        fragmentation) echo '"free": {"platform-worker": 1, "platform-worker2": 1}, "sum_free": 2, "max_free": 1' ;;
        middle) echo '"free": {"platform-worker": 1, "platform-worker2": 0}, "sum_free": 1, "max_free": 1' ;;
        scheduled) echo '"free": {"platform-worker": 0, "platform-worker2": 0}, "sum_free": 0, "max_free": 0' ;;
      esac
    }
    classify() {
      calls=$((calls + 1))
      echo "$calls" >>"$EXDIR/classify-calls"
      if ((CLASSIFY_LIMIT > 0)) && (($(wc -l <"$EXDIR/classify-calls") >= CLASSIFY_LIMIT)); then
        echo "stub: kubectl refused" >&2
        return 1
      fi
      if [[ "$hang" == 1 ]] && (($(wc -l <"$EXDIR/classify-calls") >= 2)); then
        sleep 300 &
        echo $! >"$EXDIR/hung-pid"
        wait $!
      fi
      local st
      st="$(cat "$STATE")"
      case "$st" in
        middle) st=aggregate-shortage ;;
      esac
      echo "{\"state\": \"$st\", \"cr_phase\": \"Running\", \"pod_uid\": \"target-uid\", $(free_for)}"
    }
    headroom() { echo "{$(free_for)}"; }
    submit_holder() { HOLDER_FAILURE=""; return 0; }
    wait_holder_running() {
      # The replica is the slow one, as on the cluster; the trial's own holders start at once.
      if [[ "$1" == frag-h3-* ]]; then
        sleep 7
        echo middle >"$STATE"
      fi
      return 0
    }
    cleanup_trial() { :; }
    verify_fixture() { return 0; }
    set_quota() { :; }
    CLASSIFY_LIMIT="$limit"
    : >"$EXDIR/classify-calls"
    printf 'arm\trep\tfinal_state\tstate_seconds\th4\n' >"$EXDIR/results.tsv"
    trial "$arm" 1
  ) >"$dir/out.txt" 2>&1
  rc=$?
}

run_trial repack R
line="$(grep -P '^R\t1\t' "$work/repack/results.tsv" || true)"
if [[ $rc -eq 0 && "$line" == *"gap_rule=ok"*"coverage=ok"* ]]; then
  ok "a 7 s intervention left no collection gap over 5 s and the timeline covered the window ($(grep -o 'max_gap=[0-9.]*s' <<<"$line"))"
else
  bad "the repack trial broke the gap rule or did not finish (rc=$rc): ${line:-no R line}; $(tail -n 3 "$work/repack/out.txt")"
fi
middle="$(grep -o 'middle_state_samples=[0-9]*' <<<"$line" | cut -d= -f2)"
if [[ -n "$middle" ]] && ((middle >= 5)); then
  ok "the timeline itself saw the middle state in $middle samples"
else
  bad "the timeline saw the middle state in ${middle:-no} samples; expected at least 5 across the 10 s before the deletion"
fi
if [[ "$line" == R$'\t'1$'\t'scheduled$'\t'* ]]; then
  ok "the repacked target ended scheduled"
else
  bad "the repacked target did not end scheduled: ${line:-no R line}"
fi
if [[ "$line" == *$'\t'pod_uids=1$'\t'scheduled_after_delete=*$'\t'repack_bar=pass* ]]; then
  ok "the registered bar was judged from the timeline: $(grep -o 'scheduled_after_delete=[0-9.]*s' <<<"$line")"
else
  bad "the repack bar was not judged a pass from the timeline: ${line:-no R line}"
fi
if grep -q 'delete job frag-h1-r-1' "$work/repack/k-calls.log"; then
  ok "the original holder was deleted through the stub, so the case exercised the intervention"
else
  bad "the stub never saw the original holder's deletion: $(head -n 5 "$work/repack/k-calls.log")"
fi
# The samples must span the intervention, not stop before it: the last one comes after the original's deletion.
last_t="$(tail -n 1 "$work/repack/timeline-R-1.jsonl" | python3 -c 'import json,sys; print(json.load(sys.stdin)["t"])')"
del_t="$(grep original-delete "$work/repack/events-R-1.jsonl" | python3 -c 'import json,sys; print(json.load(sys.stdin)["t"])')"
if python3 -c "import sys; sys.exit(0 if $last_t >= $del_t + 2 else 1)"; then
  ok "the timeline runs past the deletion ($last_t s against $del_t s)"
else
  bad "the timeline ends at $last_t s, before the deletion at $del_t s had been watched"
fi

# A window shorter than REPACK_AT must not let the collector finish before the repack it is there to watch.
run_trial short R 0 1
line="$(grep -P '^R\t1\t' "$work/short/results.tsv" || true)"
last_t="$(tail -n 1 "$work/short/timeline-R-1.jsonl" | python3 -c 'import json,sys; print(json.load(sys.stdin)["t"])')"
del_t="$(grep original-delete "$work/short/events-R-1.jsonl" | python3 -c 'import json,sys; print(json.load(sys.stdin)["t"])')"
if [[ "$line" == *"gap_rule=ok"*"coverage=ok"* ]] && python3 -c "import sys; sys.exit(0 if $last_t >= $del_t + 2 else 1)"; then
  ok "a 1 s window still sampled through the repack, to $last_t s against a deletion at $del_t s"
else
  bad "a window shorter than REPACK_AT ended the sampling early: ${line:-no R line}, last sample $last_t s, deletion $del_t s"
fi

# A foreground that fails mid-intervention must not leave its collector sampling forever.
run_trial abort R 0 4 1
if [[ $rc -ne 0 ]]; then
  ok "a failed deletion ended the trial under set -e (rc=$rc)"
else
  bad "a failed deletion did not end the trial: $(tail -n 3 "$work/abort/out.txt")"
fi
before="$(wc -l <"$work/abort/timeline-R-1.jsonl")"
sleep 3
after="$(wc -l <"$work/abort/timeline-R-1.jsonl")"
if [[ "$before" == "$after" && ! -e "$work/abort/intervening-R-1" ]]; then
  ok "the exit trap stopped the collector ($after samples, unchanged 3 s later, marker removed)"
else
  bad "the collector kept sampling after the foreground died: $before then $after samples, marker $(ls "$work/abort" | grep -c intervening)"
fi

# A foreground that fails while the collector is blocked in a cluster call must not leave that call's processes behind.
run_trial hung R 0 4 1 1
hung="$(cat "$work/hung/hung-pid" 2>&1)"
sleep 1
if [[ "$hung" =~ ^[0-9]+$ ]] && ! ps -p "$hung" -o comm= >/dev/null; then
  ok "the exit trap ended the collector's blocked child (pid $hung is gone)"
else
  bad "the collector's blocked child outlived the trial: pid ${hung:-unrecorded} $(ps -p "$hung" -o stat=,comm= 2>&1)"
  [[ "$hung" =~ ^[0-9]+$ ]] && kill "$hung"
fi

# A collector that dies must not read as a short, clean window.
run_trial dead F 3
if grep -qP '^F\t1\tINVALID\tcollector-failed' "$work/dead/results.tsv"; then
  ok "a collector that died is an invalid trial"
else
  bad "a collector that died was not reported invalid: $(cat "$work/dead/results.tsv")"
fi
if grep -q 'stub: kubectl refused' "$work/dead/collector-F-1.log"; then
  ok "the collector's error is kept in its log"
else
  bad "the collector's error was not kept: $(cat "$work/dead/collector-F-1.log" 2>&1)"
fi

# The judgement itself: the gap R's old timelines had is invalid, and one at the rule's edge is not.
(
  source hack/fragmentation.sh
  printf '%s\n' '{"state":"fragmentation","t":59.9}' '{"state":"scheduled","t":73.5}' >"$work/old.jsonl"
  printf '%s\n' '{"state":"fragmentation","t":10.0}' '{"state":"fragmentation","t":15.0}' >"$work/edge.jsonl"
  judge_timeline "$work/old.jsonl" R 1 "$work/none.jsonl" >"$work/old.out"
  judge_timeline "$work/edge.jsonl" F 1 >"$work/edge.out"
  # A timeline with no gap that stopped 18 s before its window was due to end.
  printf '%s\n' '{"state":"fragmentation","t":0.5}' '{"state":"fragmentation","t":1.5}' '{"state":"fragmentation","t":2.5}' >"$work/early.jsonl"
  printf '%s\n' '{"event":"window-end","t":21.0}' >"$work/early-events.jsonl"
  judge_timeline "$work/early.jsonl" F 1 "$work/early-events.jsonl" >"$work/early.out"
  # The bar's two ways to fail: a replacement Pod, and the same Pod scheduled 61 s after the deletion.
  printf '%s\n' '{"event":"replica-running","t":2.0}' '{"event":"original-delete","t":10.0}' >"$work/bar-events.jsonl"
  printf '%s\n' '{"state":"fragmentation","t":9.0,"pod_uid":"a"}' '{"state":"scheduled","t":11.0,"pod_uid":"b"}' >"$work/replaced.jsonl"
  printf '%s\n' '{"state":"fragmentation","t":9.0,"pod_uid":"a"}' '{"state":"scheduled","t":71.0,"pod_uid":"a"}' >"$work/late.jsonl"
  judge_timeline "$work/replaced.jsonl" R 1 "$work/bar-events.jsonl" >"$work/replaced.out"
  judge_timeline "$work/late.jsonl" R 1 "$work/bar-events.jsonl" >"$work/late.out"
  # A target whose Pod first appears after the deletion was never stranded, so nothing recovered.
  printf '%s\n' '{"state":"quota-short","t":9.0}' '{"state":"scheduled","t":11.0,"pod_uid":"a"}' >"$work/unseen.jsonl"
  judge_timeline "$work/unseen.jsonl" R 1 "$work/bar-events.jsonl" >"$work/unseen.out"
)
if grep -qP 'pod_uids=1\tscheduled_after_delete=1.00s\trepack_bar=fail' "$work/unseen.out"; then
  ok "a Pod not seen stranded before the deletion fails the repack bar"
else
  bad "a Pod first seen after the deletion passed the repack bar: $(cat "$work/unseen.out")"
fi
if grep -qP 'pod_uids=2\tscheduled_after_delete=1.00s\trepack_bar=fail' "$work/replaced.out"; then
  ok "a replacement Pod fails the repack bar"
else
  bad "a replacement Pod was not failed: $(cat "$work/replaced.out")"
fi
if grep -qP 'pod_uids=1\tscheduled_after_delete=61.00s\trepack_bar=fail' "$work/late.out"; then
  ok "scheduling 61 s after the deletion fails the repack bar"
else
  bad "a 61 s wait was not failed: $(cat "$work/late.out")"
fi
if grep -q 'max_gap=1.00s.*gap_rule=ok.*coverage=INVALID' "$work/early.out"; then
  ok "a timeline that stopped early with no gap inside it fails coverage"
else
  bad "a timeline that stopped 18 s early was not caught: $(cat "$work/early.out")"
fi
if grep -q 'max_gap=13.60s.*gap_rule=INVALID.*coverage=unknown.*middle_state_samples=0' "$work/old.out"; then
  ok "a 13.6 s gap is judged invalid, no window end is coverage unknown, and no events means no middle-state samples"
else
  bad "the old R timeline was not judged invalid: $(cat "$work/old.out")"
fi
if grep -q 'max_gap=5.00s.*gap_rule=ok' "$work/edge.out"; then
  ok "a gap of exactly 5 s is within the rule"
else
  bad "a 5 s gap was judged against the rule: $(cat "$work/edge.out")"
fi

if ((fails > 0)); then
  echo "$fails check(s) failed"
  exit 1
fi
echo "all checks passed"
