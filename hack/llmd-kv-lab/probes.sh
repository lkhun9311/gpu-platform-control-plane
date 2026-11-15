#!/usr/bin/env bash
# Repeated probes of the three effects observe.sh found once each, so a single lucky or unlucky request cannot carry
# a claim in docs/14_LLMD_KV_ROUTING_LAB.md. Each probe starts its arm fresh (hack/llmd-kv-lab.sh mode) and writes into
# hack/llmd-kv-lab/runs/<stamp>/<arm>/.
#
#   oob ARM               a new family warmed directly on each pod in turn, twice round, then sent through the gateway.
#                         Warming every pod means a tie-break cannot land on the warm pod more than its share.
#   lag ARM               a new family sent twice, with 0.1 to 2.5 s between the two, three times per gap.
#                         When does the second request find the first one's prefix?
#   leave ARM N           N times: delete one simulator pod, and as soon as the EPP logs the EOF warm a new family on a
#                         different, healthy pod; then the same warm-up with nothing leaving, as the control.
#                         Does a healthy pod's warm-up reach the index?
#   epp-restart ARM       the EPP replaced three ways (pod delete, rollout restart, and rollout restart right after a
#                         simulator rollout, the order run 20261115-run1 used); after each, a family warmed on one pod.
#                         Do simulators that predate the new EPP deliver events to it? Then a rolling restart tested
#                         before the old EPP has exited, which is the window a real rollout leaves open.
#
# Usage: hack/llmd-kv-lab/probes.sh oob|lag|leave|epp-restart|rollout-nowait ARM [N]
set -euo pipefail

SAY_AS=probes
# shellcheck source=hack/llmd-kv-lab/lib.sh
source "$(dirname "$0")/lib.sh"

# warm_then_route STEP FAMILY POD WAIT: warm FAMILY twice on POD directly, wait, then send it once through the gateway.
# The gateway request's served pod and cached tokens say whether the EPP had learned of the warm-up.
warm_then_route() {
  drive "$1-warm" "$(pod_url "$3")" "direct:$3" "$2*2"
  sleep "$4"
  drive "$1-gw" "$GATEWAY" gateway "$2"
}

probe_oob() {
  local rep p
  for rep in 1 2; do
    for p in $(sim_pods); do
      warm_then_route "oob-$rep-$p" "O$rep-$p" "$p" 3
    done
  done
  snap oob-end
}

probe_lag() {
  local g rep
  for g in 0.1 0.3 0.6 1.0 1.5 2.5; do
    for rep in 1 2 3; do
      drive "lag-$g-$rep" "$GATEWAY" gateway "L${g}r$rep*2" "${g}s"
    done
  done
  snap lag-end
}

probe_leave() {
  local n=${1:-5} rep keeper leaver before i
  for rep in $(seq 1 "$n"); do
    k rollout status deployment/vllm-d --timeout=300s >/dev/null
    # The replacement for the previous round's deleted pod must have rejoined before this round starts.
    for i in $(seq 1 60); do
      [ "$(sim_pods | wc -l)" = 3 ] && [ "$(k get pods -l llm-d.ai/component=decode --no-headers | wc -l)" = 3 ] && break
      sleep 2
    done
    sleep 10
    keeper=$(sim_pods | sed -n 1p)
    leaver=$(sim_pods | sed -n 2p)
    snap "leave-$rep-before"
    before=$(eof_count)
    say "[$ARM] leave $rep: deleting $leaver, warming V$rep on $keeper"
    k delete pod "$leaver" --wait=false >/dev/null
    # Push mode logs an EOF within a second or two; pull mode never does, so LEAVE_EOF_POLLS bounds the wait there.
    for i in $(seq 1 "${LEAVE_EOF_POLLS:-120}"); do
      [ "$(eof_count)" -gt "$before" ] && break
      sleep 0.25
    done
    echo "rep $rep: EOF lines $before -> $(eof_count) after $i polls at $(date -u +%FT%T.%NZ)" >>"$RUN/$ARM/leave-eof.txt"
    warm_then_route "leave-$rep" "V$rep" "$keeper" 3
    snap "leave-$rep-after"
    # The control: the same pod, the same wait, nobody leaving.
    sleep 12
    warm_then_route "control-$rep" "C$rep" "$keeper" 3
  done
  snap leave-end
}

probe_epp_restart() {
  local how p old
  for how in delete rollout sims-then-rollout; do
    old=$(epp_pod)
    say "[$ARM] epp-restart $how: replacing $old"
    snap "restart-$how-before"
    save_epp_log "$old" "before-$how"
    case $how in
      delete) k delete pod "$old" --wait=false >/dev/null ;;
      rollout) k rollout restart deployment/$EPP >/dev/null ;;
      sims-then-rollout)
        k rollout restart deployment/vllm-d >/dev/null
        k rollout status deployment/vllm-d --timeout=300s >/dev/null
        k rollout restart deployment/$EPP >/dev/null
        ;;
    esac
    # These three wait for the old EPP process to be gone before testing, so they ask only whether simulators that
    # predate the new EPP reach it once nothing else is listening; rollout-nowait below asks what happens before that.
    k wait --for=delete pod/"$old" --timeout=180s >/dev/null || true
    wait_epp_ready
    sleep 10
    { epp_pod; echo; } >>"$RUN/$ARM/epp-pods.txt"
    snap "restart-$how-after"
    for p in $(sim_pods); do
      warm_then_route "restart-$how-$p" "R-$how-$p" "$p" 3
    done
    snap "restart-$how-after-warm"
    save_epp_log "$(epp_pod)" "restart-$how"
  done
  probe_rollout_nowait
}

# probe_rollout_nowait tests the window a rolling update opens: the new EPP is Ready and routing while the old one is
# still terminating (the deployment allows it terminationGracePeriodSeconds), and in push mode the simulators are
# still connected to the old one. Warm-ups are sent as soon as the new EPP serves, then again after the old pod is gone.
probe_rollout_nowait() {
  local old new p t0 tready tgone grace
  old=$(epp_pod)
  grace=$(k get deployment $EPP -o jsonpath='{.spec.template.spec.terminationGracePeriodSeconds}')
  say "[$ARM] epp-restart rollout-nowait: replacing $old (grace ${grace}s) and testing before it exits"
  snap restart-nowait-before
  save_epp_log "$old" before-nowait
  t0=$(date +%s)
  k rollout restart deployment/$EPP >/dev/null
  wait_epp_ready
  tready=$(date +%s)
  new=$(epp_pod)
  for p in $(sim_pods); do
    warm_then_route "nowait-during-$p" "N-during-$p" "$p" 3
  done
  snap restart-nowait-during
  save_epp_log "$old" nowait-old-during
  k wait --for=delete pod/"$old" --timeout=300s >/dev/null || true
  tgone=$(date +%s)
  # The simulators redial after the old process closes their connections, so give them their retry interval.
  sleep 5
  for p in $(sim_pods); do
    warm_then_route "nowait-after-$p" "N-after-$p" "$p" 3
  done
  snap restart-nowait-after
  save_epp_log "$new" restart-nowait
  echo "old=$old new=$new grace=${grace}s new_ready_after=$((tready - t0))s old_gone_after=$((tgone - t0))s" \
    >"$RUN/$ARM/restart-nowait-timing.txt"
}

[ $# -ge 2 ] || { echo "usage: $0 oob|lag|leave|epp-restart|rollout-nowait ARM [N]" >&2; exit 2; }
lab_init
fresh_arm "$2"
touch "$RUN/$ARM/requests.jsonl"
case $1 in
  oob) probe_oob ;;
  lag) probe_lag ;;
  leave) probe_leave "${3:-5}" ;;
  epp-restart) probe_epp_restart ;;
  rollout-nowait) probe_rollout_nowait ;;
  *) echo "usage: $0 oob|lag|leave|epp-restart|rollout-nowait ARM [N]" >&2; exit 2 ;;
esac
save_epp_log "$(epp_pod)" end
python3 -I "$REPO/hack/llmd-kv-lab/summarize.py" "$RUN" >"$RUN/summary-$1-$2.txt"
say "probe $1 on $2 written to $RUN"
