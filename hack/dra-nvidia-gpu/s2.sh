#!/bin/bash
# S2, the checkpoint across a restart: an MPS claim held in PrepareStarted by a control daemon that cannot start (the
# #1639 trigger), the plugin killed with SIGKILL while it is there, and what survives the restart and the release.
#
# #1639 is assigned to linskybing; this gathers evidence only.
# The daemon is kept from starting exactly as #1639's reproduction does it: a ResourceQuota on the driver's namespace
# that admits no pod beyond those already there.
# Each repetition records four things after the restart and again after the claim is released: the checkpoint entry,
# the MPS control daemon Deployment, the shm mount, and the GPU's compute mode.
set -u
. "$(dirname "$0")/lib.sh"
T0=$(date +%s)
REPS=3
REP_MIN_S=280
# How long the released claim is left before the survivors are read, so a cleanup that runs on a timer has its turn.
SETTLE_S=60
MPS_SPEC="$SRC/demo/specs/quickstart/v1/gpu-test-mps.yaml"
MPS_NS=gpu-test-mps
QUOTA=s2-block-new-pods

install_chart --set featureGates.MPSSupport=true || { note "the chart did not install"; exit 2; }
printf 'rep\tclaim_uid\treached_prepare_started\trestarted\tstate_after_restart\tdeploy_after_restart\tnode_mount_after_restart\tcompute_mode_after_restart\tstate_after_release\tdeploy_after_release\tnode_mount_after_release\thost_mount_after_release\tcompute_mode_after_release\n' >"$D/result.tsv"

block_pods() {
  local n
  n=$(kubectl get pods -n "$NS" --no-headers 2>/dev/null | wc -l)
  kubectl -n "$NS" create quota "$QUOTA" --hard="pods=$n"
}

claim_uid() { kubectl get resourceclaims -n "$MPS_NS" -o jsonpath='{.items[0].metadata.uid}' 2>/dev/null; }
has_claim() { [ -n "$(claim_uid)" ]; }
in_state() { [ "$(cp_state "$1")" = "$2" ]; }

# The kill goes to the plugin's own process inside the kind node, so it is SIGKILL and not the kubelet's graceful stop.
gpus_restarts() {
  kubectl get pod -n "$NS" "$1" -o jsonpath='{.status.containerStatuses[?(@.name=="gpus")].restartCount}'
}
sigkill_plugin() {
  local cid pid
  cid=$(docker exec "$WORKER" crictl ps --name '^gpus$' -q | head -1) && [ -n "$cid" ] || return 1
  pid=$(docker exec "$WORKER" crictl inspect -o go-template --template '{{.info.pid}}' "$cid") && [ -n "$pid" ] || return 1
  docker exec "$WORKER" kill -KILL "$pid"
}
restarted() {
  [ "$(gpus_restarts "$1")" -gt "$2" ] 2>/dev/null &&
    [ "$(kubectl get pod -n "$NS" "$1" -o jsonpath='{.status.containerStatuses[?(@.name=="gpus")].ready}')" = true ]
}

mps_deploys() { kubectl get deploy -n "$NS" -o name 2>/dev/null | grep -c mps-control-daemon; }
node_mounts() { timeout 20 docker exec "$WORKER" grep -c gpu.nvidia.com/mps /proc/mounts; }
host_mounts() { grep -c gpu.nvidia.com/mps /proc/mounts; }
compute_mode() { nvidia-smi --query-gpu=compute_mode --format=csv,noheader | head -1; }

release() {
  kubectl delete ns "$MPS_NS" --wait=true --timeout="$(left 90)s"
  kubectl delete quota -n "$NS" "$QUOTA" --ignore-not-found
}

# What a repetition left behind is removed, so the next one and S3 start from a GPU in Default mode with no daemon.
reset_mps() {
  kubectl delete ns "$MPS_NS" --ignore-not-found --wait=true --timeout="$(left 60)s"
  kubectl delete quota -n "$NS" "$QUOTA" --ignore-not-found
  kubectl get deploy -n "$NS" -o name | grep mps-control-daemon | xargs -r kubectl delete -n "$NS" --wait=true
  timeout 30 docker exec "$WORKER" sh -c 'grep gpu.nvidia.com/mps /proc/mounts | cut -d" " -f2 | xargs -r -n1 umount'
  nvidia-smi -c DEFAULT
}

for r in $(seq 1 "$REPS"); do
  if ! enough "$REP_MIN_S"; then note "rep $r not started: under $REP_MIN_S s left"; break; fi
  pod=$(plugin_pod)
  [ -n "$pod" ] || { note "rep $r: no running plugin pod"; break; }
  step "r$r-quota" block_pods || { note "rep $r: the quota was not created"; reset_mps; continue; }
  step "r$r-apply" kubectl apply -f "$MPS_SPEC"
  poll 60 3 has_claim
  uid=$(claim_uid)
  started=no restarted=no
  if [ -n "$uid" ] && step "r$r-wait-prepare-started" poll 120 3 in_state "$uid" PrepareStarted; then
    started=yes
    before=$(gpus_restarts "$pod")
    step "r$r-sigkill" sigkill_plugin || note "rep $r: the kill did not reach the plugin"
    step "r$r-restart" poll 120 3 restarted "$pod" "${before:-0}" && restarted=yes
  else
    note "rep $r: the claim never reached PrepareStarted; nothing was killed"
  fi
  a_state=$(cp_state "$uid") a_dep=$(mps_deploys) a_mnt=$(node_mounts) a_mode=$(compute_mode)
  step "r$r-release" release
  step "r$r-settle" sleep "$(left "$SETTLE_S")"
  b_state=$(cp_state "$uid") b_dep=$(mps_deploys) b_mnt=$(node_mounts) b_host=$(host_mounts) b_mode=$(compute_mode)
  kubectl get deploy,pods -n "$NS" -o wide >"$D/r$r.driver-ns.txt" 2>&1
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$r" "${uid:-none}" "$started" "$restarted" "$a_state" "$a_dep" \
    "$a_mnt" "$a_mode" "$b_state" "$b_dep" "$b_mnt" "$b_host" "$b_mode" >>"$D/result.tsv"
  note "rep $r: $started/$restarted; after release: entry $b_state, $b_dep daemon(s), $b_mnt node mount(s), mode $b_mode"
  step "r$r-reset" reset_mps
done
collect
