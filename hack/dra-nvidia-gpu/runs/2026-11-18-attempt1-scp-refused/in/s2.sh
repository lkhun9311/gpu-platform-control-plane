#!/bin/bash
# S2, the checkpoint across a restart: an MPS claim held in PrepareStarted by a control daemon that cannot start (the
# #1639 trigger), the plugin killed with SIGKILL while it is there, and what survives the restart and the release.
#
# #1639 is assigned to linskybing; this gathers evidence only.
# The daemon is kept from starting exactly as #1639's reproduction does it: a ResourceQuota on the driver's namespace
# that admits no pod beyond those already there.
# Each repetition records four things after the restart and again SETTLE_S after the release: the checkpoint entry,
# the MPS control daemon Deployment, the shm mount, and the GPU's compute mode.
# The plugin's periodic stale-claim cleanup runs every ten minutes (ResourceClaimCleanupInterval at the pinned commit),
# which this budget cannot wait for, so the second reading is what survived the kubelet's unprepare and SETTLE_S, not
# proof that cleanup never comes.
# A repetition is valid only if the claim reached PrepareStarted, the plugin restarted, and the release completed; the
# phase exits 4 unless all REPS are valid.
set -u
. "$(dirname "$0")/lib.sh"
T0=$(date +%s)
REPS=3
REP_MIN_S=280
# How long after the release the survivors are read; see above for what it does and does not show.
SETTLE_S=60
MPS_SPEC="$SRC/demo/specs/quickstart/v1/gpu-test-mps.yaml"
MPS_NS=gpu-test-mps
QUOTA=s2-block-new-pods

install_chart --set featureGates.MPSSupport=true || { note "the chart did not install"; exit 2; }
printf 'rep\tvalid\tclaim_uid\treached_prepare_started\trestarted\treleased\tstate_after_restart\tdeploy_after_restart\tnode_mount_after_restart\tcompute_mode_after_restart\tstate_settled\tdeploy_settled\tnode_mount_settled\thost_mount_settled\tcompute_mode_settled\n' >"$D/result.tsv"

block_pods() {
  local n
  n=$(kubectl get pods -n "$NS" --no-headers 2>/dev/null | wc -l)
  [ "$n" -gt 0 ] || return 1
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

# Each reader echoes "unread" when its command failed, so a failed read is never taken for zero or Default.
mps_deploys() { local o; o=$(kubectl get deploy -n "$NS" -o name 2>/dev/null) || { echo unread; return; }; grep -c mps-control-daemon <<<"$o"; }
node_mounts() { local o; o=$(timeout 20 docker exec "$WORKER" cat /proc/mounts 2>/dev/null) || { echo unread; return; }; grep -c gpu.nvidia.com/mps <<<"$o"; }
host_mounts() { grep -c gpu.nvidia.com/mps /proc/mounts; }
compute_mode() { local o; o=$(nvidia-smi --query-gpu=compute_mode --format=csv,noheader 2>/dev/null | head -1); echo "${o:-unread}"; }
ns_gone() { local o; o=$(kubectl get ns "$MPS_NS" --ignore-not-found -o name 2>/dev/null) && [ -z "$o" ]; }

# The quota stays until the namespace is gone, so the daemon cannot start while the claim may still exist.
release() {
  kubectl delete ns "$MPS_NS" --wait=true --timeout="$(left 90)s" || return 1
  ns_gone || return 1
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

save_plugin_log() { timeout 30 kubectl logs -n "$NS" "$1" -c gpus --tail=-1 "${@:3}" >"$2" 2>"$2.err"; }

valid_reps=0
for r in $(seq 1 "$REPS"); do
  if ! enough "$REP_MIN_S"; then note "rep $r not started: under $REP_MIN_S s left"; break; fi
  pod=$(plugin_pod)
  [ -n "$pod" ] || { note "rep $r: no running plugin pod"; break; }
  step "r$r-quota" block_pods || { note "rep $r: the quota was not created"; reset_mps; continue; }
  step "r$r-apply" kubectl apply -f "$MPS_SPEC"
  poll 60 3 has_claim
  uid=$(claim_uid)
  started=no restarted=no released=no
  if [ -n "$uid" ] && step "r$r-wait-prepare-started" poll 120 3 in_state "$uid" PrepareStarted; then
    started=yes
    before=$(gpus_restarts "$pod")
    save_plugin_log "$pod" "$D/r$r.plugin-before-kill.log"
    step "r$r-sigkill" sigkill_plugin || note "rep $r: the kill did not reach the plugin"
    step "r$r-restart" poll 120 3 restarted "$pod" "${before:-0}" && restarted=yes
    # The killed instance's log is the restarted container's previous one; it holds the prepare the kill interrupted.
    save_plugin_log "$pod" "$D/r$r.plugin-killed.log" --previous
  else
    note "rep $r: the claim never reached PrepareStarted; nothing was killed"
  fi
  a_state=$(cp_state "$uid") a_dep=$(mps_deploys) a_mnt=$(node_mounts) a_mode=$(compute_mode)
  step "r$r-release" release && released=yes || note "rep $r: the release did not complete; the settled readings are not after a release"
  step "r$r-settle" sleep "$(left "$SETTLE_S")"
  b_state=$(cp_state "$uid") b_dep=$(mps_deploys) b_mnt=$(node_mounts) b_host=$(host_mounts) b_mode=$(compute_mode)
  save_plugin_log "$pod" "$D/r$r.plugin-settled.log"
  kubectl get deploy,pods -n "$NS" -o wide >"$D/r$r.driver-ns.txt" 2>&1
  valid=no
  [ "$started" = yes ] && [ "$restarted" = yes ] && [ "$released" = yes ] && valid=yes && valid_reps=$(( valid_reps + 1 ))
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$r" "$valid" "${uid:-none}" "$started" "$restarted" \
    "$released" "$a_state" "$a_dep" "$a_mnt" "$a_mode" "$b_state" "$b_dep" "$b_mnt" "$b_host" "$b_mode" >>"$D/result.tsv"
  note "rep $r (valid=$valid): $SETTLE_S s after the release: entry $b_state, $b_dep daemon(s), $b_mnt node mount(s), mode $b_mode"
  step "r$r-reset" reset_mps
done
collect
note "$valid_reps of $REPS repetitions valid"
[ "$valid_reps" = "$REPS" ] || exit 4
