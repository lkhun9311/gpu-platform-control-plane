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
#   churn ARM             a simulator deleted under traffic, then one restarted in place; does the EPP keep crediting
#                         a pod with a cache it no longer has (issue #599)?
#   cancel ARM            six long requests cancelled by their clients after 1 s; does the simulators' work stop, and
#                         what do the EPP's load scorers believe afterwards (issue #599)?
#
# Usage: hack/llmd-kv-lab/probes.sh oob|lag|leave|epp-restart|rollout-nowait|churn|cancel ARM [N]
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
      [ "$(sim_pods | wc -l)" = "${LAB_SIM_REPLICAS:-3}" ] && [ "$(k get pods -l llm-d.ai/component=decode --no-headers | wc -l)" = "${LAB_SIM_REPLICAS:-3}" ] && break
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

# gauges POD: the simulator's running and waiting counts, read through the API server proxy, as "running waiting".
gauges() {
  curl -sf "$(pod_url "$1")/metrics" | awk '
    /^vllm:num_requests_running[{ ]/ {r += $NF} /^vllm:num_requests_waiting[{ ]/ {w += $NF}
    END {printf "%d %d\n", r, w}'
}

# probe_churn replaces a simulator two ways while the EPP holds cache state about it, for issue #599's week-1 exit.
#
# 1. Pod delete under traffic: requests for the family the pod holds are in flight on it when it is deleted, and the
#    Deployment brings a pod with a new name and address; the question is whether any request fails.
# 2. Container restart in place: kubelet restarts the simulator inside the same pod, so the name and address the EPP
#    keys its state by do not change while the cache behind them is emptied.
#    The question is whether the EPP still believes the pod holds what it held, and routes a prefix there as a hit.
# Each step records, per gateway request, the served pod, the simulator's cached tokens and the EPP's scores.
probe_churn() {
  local victim i rc0 rc1 cid
  for i in 1 2; do drive "churn-warm-a$i" "$GATEWAY" gateway "CA*2"; done
  victim=$(family_pod CA)
  say "[$ARM] churn 1: CA lives on $victim; deleting it under four concurrent streams of CA"
  echo "$victim" >"$RUN/$ARM/churn1-victim.txt"
  snap churn1-before
  # The streams send CA, the family the victim holds, so the prefix scorer steers them to the victim and requests are
  # in flight there when it goes; four at once keep its one-at-a-time queue non-empty.
  # A stream of a family of its own reached the victim 0 to 5 times in the first runs, which tested nothing.
  local streams=() s
  for s in 1 2 3 4; do
    "$DRIVER" -url "$GATEWAY" -target gateway -plan "CA*40" -gap 100ms -tag "$ARM-churn1-stream$s" \
      -out "$RUN/$ARM/requests.jsonl" >/dev/null 2>"$RUN/$ARM/churn1-stream$s.err" &
    streams+=($!)
  done
  sleep 3
  date -u +%Y-%m-%dT%H:%M:%S.%NZ >"$RUN/$ARM/churn1-delete-at.txt"
  k delete pod "$victim" --wait=false >/dev/null
  for s in "${streams[@]}"; do
    wait "$s" || say "[$ARM] churn 1: a stream during the delete had failed requests (churn1-stream*.err)"
  done
  for i in $(seq 1 60); do
    [ "$(sim_pods | wc -l)" = "${LAB_SIM_REPLICAS:-3}" ] \
      && [ "$(k get pods -l llm-d.ai/component=decode --no-headers | wc -l)" = "${LAB_SIM_REPLICAS:-3}" ] && break
    sleep 2
  done
  sleep 10
  sim_pods >"$RUN/$ARM/churn1-pods-after.txt"
  drive "churn1-after" "$GATEWAY" gateway "CA*2"
  snap churn1-after

  for i in 1 2; do drive "churn-warm-b$i" "$GATEWAY" gateway "CB*2"; done
  victim=$(family_pod CB)
  rc0=$(k get pod "$victim" -o jsonpath='{.status.containerStatuses[0].restartCount}')
  cid=$(k get pod "$victim" -o jsonpath='{.status.containerStatuses[0].containerID}')
  say "[$ARM] churn 2: CB lives on $victim (restarts $rc0); stopping its simulator container ${cid#containerd://}"
  snap churn2-before
  docker exec "$NODE" crictl stop "${cid#containerd://}" >/dev/null
  for i in $(seq 1 90); do
    rc1=$(k get pod "$victim" -o jsonpath='{.status.containerStatuses[0].restartCount}')
    [ "$rc1" -gt "$rc0" ] && [ "$(k get pod "$victim" -o jsonpath='{.status.containerStatuses[0].ready}')" = true ] && break
    sleep 2
  done
  echo "victim=$victim restarts $rc0 -> $rc1 ip=$(k get pod "$victim" -o jsonpath='{.status.podIP}')" >"$RUN/$ARM/churn2-restart.txt"
  # Ten seconds covers the EPP's metrics refresh and, in push and pull modes alike, the simulator's 1 s reconnect.
  sleep 10
  snap churn2-after-restart
  drive "churn2-after" "$GATEWAY" gateway "CB*2"
  snap churn2-after
}

# probe_cancel cancels requests the simulators are running or queueing, and asks whether the work stops.
#
# With one request at a time per simulator (the #599 shape), six long requests leave each of two pods one running and
# two waiting; every client gives up after 1 s.
# A simulator that aborts a request whose client left, as vLLM does, is idle within about a second; one that keeps
# generating stays busy for the queue's whole output, about 13 s here, and every later request waits behind it.
# Then ten short requests through the gateway show what the EPP's load scorers believe after the cancellations.
probe_cancel() {
  local i p t0 body pids=()
  [ -n "$(k get deployment vllm-d -o jsonpath='{.spec.template.spec.containers[0].args}' | grep -o -- '--max-num-seqs=1')" ] \
    || { say "[$ARM] cancel expects --max-num-seqs=1 (replay599.sh env); refusing to read a different shape"; return 1; }
  snap cancel-before
  t0=$(date +%s.%N)
  for i in 1 2 3 4 5 6; do
    body=$(printf '{"model":"%s","prompt":"cancel probe %s-%d: count slowly.","max_tokens":900,"ignore_eos":true,"stream":true}' \
      "TinyLlama/TinyLlama-1.1B-Chat-v1.0" "$ARM" "$i")
    # curl exits 28 on its own timeout, which is the cancellation; its status is recorded rather than judged.
    # The "|| rc=" keeps errexit, which the subshell inherits, from ending it before the status is written.
    (rc=0
      curl -sN -o /dev/null -w "cancel-$i http=%{http_code} first_byte_s=%{time_starttransfer} total_s=%{time_total}" \
        --max-time 1 -H 'Content-Type: application/json' -H "x-request-id: $ARM-cancel-$i" \
        -d "$body" "$GATEWAY/v1/completions" || rc=$?
      echo " curl_exit=$rc") >>"$RUN/$ARM/cancel-clients.txt" &
    pids+=($!)
    sleep 0.05
  done
  # Only the clients are waited for: a bare wait would also wait for lab_init's kubectl proxy, which never exits.
  wait "${pids[@]}"
  # Twice a second for 20 s: each pod's running and waiting counts after every client has gone.
  for i in $(seq 1 40); do
    for p in $(sim_pods); do
      printf '%s %s %s\n' "$(awk -v a="$(date +%s.%N)" -v b="$t0" 'BEGIN {printf "%.1f", a - b}')" "$p" "$(gauges "$p")"
    done
    sleep 0.5
  done >"$RUN/$ARM/cancel-gauges.txt"
  snap cancel-after
  drive "cancel-after" "$GATEWAY" gateway "$(for i in $(seq 1 10); do printf 'K%d,' "$i"; done)" 500ms
}

[ $# -ge 2 ] || { echo "usage: $0 oob|lag|leave|epp-restart|rollout-nowait|churn|cancel ARM [N]" >&2; exit 2; }
lab_init
fresh_arm "$2"
touch "$RUN/$ARM/requests.jsonl"
case $1 in
  oob) probe_oob ;;
  lag) probe_lag ;;
  leave) probe_leave "${3:-5}" ;;
  epp-restart) probe_epp_restart ;;
  rollout-nowait) probe_rollout_nowait ;;
  churn) probe_churn ;;
  cancel) probe_cancel ;;
  *) echo "usage: $0 oob|lag|leave|epp-restart|rollout-nowait|churn|cancel ARM [N]" >&2; exit 2 ;;
esac
save_epp_log "$(epp_pod)" end
python3 -I "$REPO/hack/llmd-kv-lab/summarize.py" "$RUN" >"$RUN/summary-$1-$2.txt"
say "probe $1 on $2 written to ${RUN#"$REPO"/}"
