#!/usr/bin/env bash
# The drill's out-of-band machine console: what an operator has besides the Kubernetes API.
# On EKS the same questions go to EC2 (`aws ec2 describe-instances`, `aws ec2 terminate-instances`); here each worker
# node is a container, and this reads and changes the container's power state.
#
#   hack/drill/oob.sh list
#   hack/drill/oob.sh status NODE      # on and answering / on and not answering (hung) / off
#   hack/drill/oob.sh poweroff NODE    # hard power-off, for good; then the Node object goes, as on EKS
#
# Every call is logged to the drill's state directory, which is how the drill knows what was confirmed off and when.
set -uo pipefail
DRILL_STATE=${DRILL_STATE:-$HOME/.cache/gpuaas-drill}
CLUSTER=drill
OOB_LOG=$DRILL_STATE/oob.log
mkdir -p "$DRILL_STATE"
note() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*" >>"$OOB_LOG"; }

machine() {
  case "$1" in
    "$CLUSTER"-worker | "$CLUSTER"-worker[0-9]) ;;
    *) echo "unknown machine '$1' (the console manages the worker nodes: $(docker ps -a --filter "name=^$CLUSTER-worker" --format '{{.Names}}' | sort | paste -sd' '))" >&2; exit 2 ;;
  esac
}

state_of() {
  local s
  s=$(docker inspect -f '{{.State.Status}}' "$1") || return 1
  case "$s" in
    running) echo "on, answering" ;;
    paused) echo "on, not answering (hung)" ;;
    exited | dead | created) echo "off" ;;
    *) echo "unknown ($s)" ;;
  esac
}

case "${1:-}" in
  list)
    note "list"
    for m in $(docker ps -a --filter "name=^$CLUSTER-worker" --format '{{.Names}}' | sort); do echo "$m: $(state_of "$m")"; done
    ;;
  status)
    machine "${2:-}"
    s=$(state_of "$2") || { echo "cannot read $2" >&2; exit 1; }
    note "status $2 $s"
    echo "$2: $s"
    ;;
  poweroff)
    machine "${2:-}"
    # A hung machine is killed where it hangs, never thawed first: docker kills a paused container without
    # letting its processes run again (checked on this host's docker, 2026-11-07).
    if [ "$(state_of "$2")" != off ]; then
      docker kill "$2" >/dev/null || { echo "power-off of $2 failed" >&2; exit 1; }
    fi
    for _ in $(seq 1 20); do
      [ "$(state_of "$2")" = off ] && break
      sleep 1
    done
    s=$(state_of "$2")
    note "poweroff $2 $s"
    echo "$2: $s"
    [ "$s" = off ] || exit 1
    # What the cloud does next: on EKS the node lifecycle controller deletes the Node of a terminated instance, and the
    # Pods bound to it are then garbage-collected. Without it a dead node's Pods stay Terminating for good, since no
    # kubelet is left to confirm them (found rehearsing S3).
    if kubectl --context "kind-$CLUSTER" delete node "$2" --wait=false >/dev/null; then
      note "node-object-deleted $2"
      echo "$2: Node object removed, as the cloud provider does for a terminated instance"
    fi
    ;;
  *)
    sed -n '2,10p' "$0"
    exit 2
    ;;
esac
