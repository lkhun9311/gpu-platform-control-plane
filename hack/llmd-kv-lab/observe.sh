#!/usr/bin/env bash
# Runs the lab's observations against a cluster hack/llmd-kv-lab.sh brought up, and writes every raw artefact into
# hack/llmd-kv-lab/runs/<stamp>/ so each claim in docs/14_LLMD_KV_ROUTING_LAB.md can be re-read from what was recorded.
#
# Each arm starts from fresh simulator pods behind a freshly started EPP, so no arm inherits another's cache, and then
# replays the same prompt sequence. The arms are the EPP configs in this directory: precise (KV events, simulators
# dial the EPP's bound socket, upstream's dev default), precise-pull (KV events, the EPP dials each pod),
# precise-spec (precise plus speculative indexing) and approx (no events; the EPP remembers its own decisions).
#   affinity  four families interleaved through the gateway; does each family keep landing on one pod?
#   oob       a family warmed on one pod directly, bypassing the EPP, then sent through the gateway
#   evict     the pod holding F0 flooded directly with other prefixes until F0 is evicted, then F0 through the gateway
#   restart   the EPP pod deleted; the four families sent again once its replacement is ready
# The event-driven arms add:
#   zmq-block the ZMQ path dropped in the node's FORWARD chain while a family is warmed directly, then restored;
#             were the events from the blocked window ever indexed?
#   leave     one simulator pod deleted, and a family warmed on a healthy pod inside the window that follows
#   recovery  (precise only, RECOVERY_MINUTES > 0) a minute-by-minute check that events keep arriving after the restart
#
# Usage: [RECOVERY_MINUTES=n] hack/llmd-kv-lab/observe.sh [precise|precise-pull|precise-spec|approx|all]
set -euo pipefail

SAY_AS=observe
# shellcheck source=hack/llmd-kv-lab/lib.sh
source "$(dirname "$0")/lib.sh"
lab_init

run_arm() {
  fresh_arm "$1"
  snap 0-start

  say "[$ARM] affinity: F0..F3 interleaved, four rounds, through the gateway"
  drive affinity "$GATEWAY" gateway "F0,F1,F2,F3,F0,F1,F2,F3,F0,F1,F2,F3,F0,F1,F2,F3"
  snap 1-after-affinity

  local warm
  warm=$(other_pod "$(family_pod F0)")
  say "[$ARM] oob: W1 warmed directly on $warm, then three requests through the gateway"
  drive oob-warm "$(pod_url "$warm")" "direct:$warm" "W1*2"
  sleep 2
  drive oob "$GATEWAY" gateway "W1*3"
  snap 2-after-oob

  local holder
  holder=$(family_pod F0)
  say "[$ARM] evict: $holder holds F0; flooding it directly with twelve other prefixes"
  drive evict-flood "$(pod_url "$holder")" "direct:$holder" "E0,E1,E2,E3,E4,E5,E6,E7,E8,E9,E10,E11"
  sleep 2
  drive evict "$GATEWAY" gateway "F0*2"
  snap 3-after-evict

  if [ "$ARM" != approx ]; then
    local blocked
    blocked=$(other_pod "$(family_pod W1)" "$holder")
    [ -n "$blocked" ] || blocked=$(other_pod "$(family_pod W1)")
    say "[$ARM] zmq-block: dropping tcp/5557 in $NODE FORWARD; warming W2 directly on $blocked"
    snap 4-before-block
    docker exec "$NODE" iptables -I FORWARD -p tcp --dport 5557 -j DROP
    docker exec "$NODE" iptables -I FORWARD -p tcp --sport 5557 -j DROP
    date -u +%FT%TZ >"$RUN/$ARM/zmq-blocked-at.txt"
    drive block-warm "$(pod_url "$blocked")" "direct:$blocked" "W2*2"
    sleep 2
    drive block-gw "$GATEWAY" gateway "W2"
    snap 5-while-blocked
    sleep 30
    docker exec "$NODE" iptables -D FORWARD -p tcp --dport 5557 -j DROP
    docker exec "$NODE" iptables -D FORWARD -p tcp --sport 5557 -j DROP
    date -u +%FT%TZ >"$RUN/$ARM/zmq-restored-at.txt"
    say "[$ARM] zmq-block: restored; waiting 20s for any buffered events"
    sleep 20
    snap 6-after-restore
    drive restore-gw "$GATEWAY" gateway "W2*2"
    snap 7-after-restore-requests

    # The EPP binds one socket for every simulator, and a single publisher closing its connection was seen to end
    # that socket's Recv with EOF and tear the subscriber down for its retry interval.
    # This asks whether a different, healthy pod's events are lost in that window.
    local leaver keeper
    keeper=$(other_pod "$(family_pod W1)")
    leaver=$(other_pod "$keeper")
    say "[$ARM] publisher-leave: deleting $leaver, then warming W3 directly on $keeper"
    snap 7b-before-leave
    local eofs_before eofs i
    eofs_before=$(eof_count)
    k delete pod "$leaver" --wait=false >/dev/null
    date -u +%FT%T.%NZ >"$RUN/$ARM/leave-deleted-at.txt"
    # Warm only once the EOF has been logged, so the warm-up lands inside the window being asked about.
    for i in $(seq 1 60); do
      eofs=$(eof_count)
      [ "$eofs" -gt "$eofs_before" ] && break
      sleep 0.5
    done
    echo "EOF lines before=$eofs_before after=$eofs, polled $i times" >"$RUN/$ARM/leave-eof.txt"
    date -u +%FT%T.%NZ >>"$RUN/$ARM/leave-eof.txt"
    drive leave-warm "$(pod_url "$keeper")" "direct:$keeper" "W3*2"
    sleep 15
    snap 7c-after-leave
    drive leave-gw "$GATEWAY" gateway "W3*2"
    # The same warm-up with no publisher leaving, as the control for the step above.
    drive leave-control-warm "$(pod_url "$keeper")" "direct:$keeper" "W4*2"
    sleep 3
    drive leave-control-gw "$GATEWAY" gateway "W4*2"
    snap 7d-after-leave-requests
    k rollout status deployment/vllm-d --timeout=300s >/dev/null
  fi

  local first
  first=$(epp_pod)
  save_epp_log "$first" 1
  say "[$ARM] restart: deleting EPP pod $first"
  k delete pod "$first" --wait=false >/dev/null
  # The old pod must be gone, not just a new one Ready, or the gateway could still be talking to the old process.
  k wait --for=delete pod/"$first" --timeout=120s >/dev/null || true
  wait_epp_ready
  epp_pod >"$RUN/$ARM/epp-pod-2.txt"
  snap 8-after-restart
  drive restart "$GATEWAY" gateway "F1,F2,F3,W1,F1,F2,F3,W1"
  snap 9-after-restart-requests
  if [ "$ARM" != approx ]; then
    # Families that existed before the restart test the lost index; a family warmed after it tests whether events
    # reach the new EPP at all.
    local rw
    rw=$(other_pod "$(family_pod F1)")
    say "[$ARM] restart: R1 warmed directly on $rw after the restart, then through the gateway"
    drive restart-warm "$(pod_url "$rw")" "direct:$rw" "R1*2"
    sleep 3
    drive restart-gw "$GATEWAY" gateway "R1*2"
    snap 9b-after-restart-warm
    if [ "$ARM" = precise ]; then recovery_probe; fi
  fi
  save_epp_log "$(epp_pod)" 2
  k logs -l llm-d.ai/component=decode --tail=-1 --prefix >"$RUN/$ARM/sim.log" 2>&1 || true
}

# recovery_probe watches, for RECOVERY_MINUTES, whether KV events from the simulators that predate the EPP restart
# ever reach the new EPP: each minute it warms a new family directly on one pod and snapshots the counters and the
# simulators' sockets. Off by default because it is slow; the answer it gives is how long the silence lasts.
recovery_probe() {
  local minutes=${RECOVERY_MINUTES:-0} m p
  [ "$minutes" -gt 0 ] || return 0
  p=$(sim_pods | head -1)
  say "[$ARM] recovery: probing $p once a minute for $minutes minutes"
  for m in $(seq 1 "$minutes"); do
    sleep 60
    drive "recovery-warm-$m" "$(pod_url "$p")" "direct:$p" "P$m"
    sleep 2
    snap "r$(printf %02d "$m")"
  done
}

case "${1:-all}" in
  precise | precise-pull | precise-spec | approx) run_arm "$1" ;;
  all) run_arm precise; run_arm precise-pull; run_arm precise-spec; run_arm approx ;;
  *) echo "usage: $0 [precise|precise-pull|precise-spec|approx|all]" >&2; exit 2 ;;
esac
python3 -I "$REPO/hack/llmd-kv-lab/summarize.py" "$RUN" | tee "$RUN/summary.txt"
say "run written to $RUN"
