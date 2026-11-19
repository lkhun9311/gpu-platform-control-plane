#!/bin/bash
# S5, #1278's candidate standalone reproducer: a template-generated claim in PrepareCompleted whose pod and claim are
# force-deleted, and gone from the API, while the gpu-kubelet-plugin is down.
#
# S1 deletes normally.
# On attempt 5 both of its objects were still in the API when the plugin returned, kubelet then unprepared, and the
# entry went, so S1 never reached the condition the issue describes.
# This phase follows the issue's "Candidate standalone reproducer" step by step:
#   the issue's ResourceClaimTemplate and pod (registry.k8s.io/pause:3.10, one full GPU);
#   step 2, the pod's generated claim read from status.resourceClaimStatuses, and its UID;
#   step 3, PrepareCompleted in the checkpoint;
#   step 4, the plugin made unavailable;
#   step 5, the pod and then the claim deleted with --force --grace-period=0;
#   step 6, the plugin restored and registered;
#   step 7, the entry read against an API that no longer has the claim;
#   step 8, a watch, which runs on to one plugin cleanup interval when the entry survives its first part;
#   steps 9 and 10, a second pod from the same template, whose prepare is recorded.
# It departs from the issue in three places, each recorded.
# Each repetition has its own namespace.
# The plugin goes down the way S1 takes it down: its DaemonSet is pinned to a node label no node has.
# The issue's step 5 does not mention finalizers, and --force does not bypass them, so a claim still present 30 s after
# its delete has its finalizers removed; the result says whether that was needed.
#
# A repetition is valid only if
#   the claim reached PrepareCompleted and its name came from the pod's resourceClaimStatuses,
#   the plugin went down,
#   both force deletes were issued and succeeded,
#   the pod and the claim were both read as gone from the API while the plugin was still down,
#   the plugin came back,
#   and the first part of the watch ran its full length with a readable checkpoint.
# A repetition where either object is still present, or could not be read, is invalid whatever the checkpoint shows.
# A finding is an entry for that claim that is still in the checkpoint at the end of the watch.
# One GPU cannot serve a new claim while a leaked entry holds it, so a finding ends the repetitions.
# The phase exits 4 unless every repetition it started was valid and either all REPS ran or a valid one found the leak.
# A read that fails is recorded as "unread", never as absent or zero.
set -u
. "$(dirname "$0")/lib.sh"
T0=$(date +%s)
REPS=3
# Two kubelet retry periods, as S1 watches.
WATCH_S=150
# One gpu-kubelet-plugin cleanup interval plus 30 s, counted from the plugin's return: ResourceClaimCleanupInterval is
# 10 minutes in cmd/gpu-kubelet-plugin/cleanup.go at the pinned commit.
# It is spent only after a finding, and only as far as the phase's deadline allows; the result records how far it got.
CLEANUP_WATCH_S=630
# The time a repetition without a finding typically takes, plus FINAL_S; a repetition that cannot have it is not started.
REP_MIN_S=400
# Kept clear of the deadline by every watch, for the logs, the issue's second pod, the result row and the verdict.
# The deadline is also the runner's hard timeout, so a watch that ran into it would leave a finding unrecorded.
FINAL_S=150
DOWN_LABEL=dra-gpu-session/plugin-down
# Where kubelet keeps its DRA claim-info cache inside the kind node.
KUBELET_DRA_STATE=/var/lib/kubelet/dra_manager_state

install_chart || { note "the chart did not install"; exit 2; }
printf 'rep\tvalid\tclaim_name\tclaim_uid\tpod_uid\tafter_prepare\tforce_delete\tfinalizers_removed\tpod_while_down\tclaim_while_down\tat_return\tafter_watch\twatched_s\tcleanup_interval_watched\tkubelet_unprepare_lines_pod_uid\tkubelet_lines_claim_uid\tplugin_unprepare_called\tpod_b\tpod_b_events_naming_uid\n' >"$D/result.tsv"

# manifest NS POD writes the issue's template and pod, with S1's toleration for the GPU node's taint.
manifest() {
  cat <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: $1
---
apiVersion: resource.k8s.io/v1
kind: ResourceClaimTemplate
metadata:
  namespace: $1
  name: gpu-claim
spec:
  spec:
    devices:
      requests:
      - name: gpu
        exactly:
          allocationMode: ExactCount
          count: 1
          deviceClassName: gpu.nvidia.com
---
apiVersion: v1
kind: Pod
metadata:
  namespace: $1
  name: $2
spec:
  restartPolicy: Never
  resourceClaims:
  - name: gpu
    resourceClaimTemplateName: gpu-claim
  containers:
  - name: test
    image: registry.k8s.io/pause:3.10
    resources:
      claims:
      - name: gpu
        request: gpu
  tolerations:
  - key: "nvidia.com/gpu"
    operator: "Exists"
    effect: "NoSchedule"
EOF
}

prepare() {
  kubectl apply -f "$1" && kubectl wait -n "$2" --for=condition=Ready pod/pod --timeout="$(left 150)s"
}

# The same two patches as S1's plugin_down and plugin_up.
plugin_down() {
  local ds
  ds=$(plugin_ds) && [ -n "$ds" ] || return 1
  kubectl patch ds -n "$NS" "$ds" --type merge \
    -p "{\"spec\":{\"template\":{\"spec\":{\"nodeSelector\":{\"$DOWN_LABEL\":\"true\"}}}}}" || return 1
  poll 90 3 no_plugin_pod
}

plugin_up() {
  local ds
  ds=$(plugin_ds) && [ -n "$ds" ] || return 1
  kubectl patch ds -n "$NS" "$ds" --type json -p '[{"op":"remove","path":"/spec/template/spec/nodeSelector"}]' || return 1
  plugin_ready 120 || return 1
  # A rollout and a ResourceSlice do not show registration: slices outlive the outage, and the plugin's health probe
  # only logs the registration status.
  # A finding made against a plugin kubelet never registered would be the outage continuing, so registration is required.
  poll 90 5 registered
}

# registered is true once the running plugin's log shows kubelet's NotifyRegistrationStatus with plugin_registered:true.
# plugin_down waited until no plugin pod was left, so the only log this reads is the new pod's.
registered() {
  timeout 30 kubectl logs -n "$NS" -l "$PLUGIN_SEL" -c gpus --tail=-1 2>>"$D/registration.err" |
    grep -q 'NotifyRegistrationStatus" request="plugin_registered:true"'
}

# presence OBJ NS echoes gone, present, or unread: only the API's own not-found is taken as gone.
presence() {
  local o
  o=$(kubectl get -n "$2" "$1" --ignore-not-found -o name 2>>"$D/presence.err") || { echo unread; return; }
  [ -z "$o" ] && echo gone || echo present
}
gone() { [ "$(presence "$1" "$2")" = gone ]; }

# force_delete NS CLAIM is the issue's step 5: the pod, then its generated claim, both forced, and fails if either fails.
# The claim is owned by the pod, so the garbage collector can remove it before its own delete is sent.
# Its delete therefore accepts not-found; whether the claim is gone is decided by the reads after it, not here.
force_delete() {
  timeout "$(left 30)" kubectl delete -n "$1" pod/pod --force --grace-period=0 --wait=false || return 1
  timeout "$(left 30)" kubectl delete -n "$1" "resourceclaim/$2" --force --grace-period=0 --wait=false --ignore-not-found
}

# until_gone NS CLAIM waits for both objects to leave the API.
# A claim still present after 30 s is held by a finalizer, so its finalizers are recorded and then removed.
# It sets FIN_REMOVED, and does not itself decide validity: the reads after it do.
until_gone() {
  FIN_REMOVED=no
  poll 30 3 gone pod/pod "$1"
  poll 30 3 gone "resourceclaim/$2" "$1" && return 0
  kubectl get -n "$1" "resourceclaim/$2" -o yaml >"$D/r$r.claim-before-finalizer-removal.yaml" 2>&1
  timeout "$(left 30)" kubectl patch -n "$1" "resourceclaim/$2" --type merge -p '{"metadata":{"finalizers":null}}' || return 1
  FIN_REMOVED=yes
  poll 30 3 gone "resourceclaim/$2" "$1"
}

# mark LABEL appends the claim's checkpoint state to the repetition's timeline and saves kubelet's DRA state.
mark() {
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $1 $(cp_state "$uid")" >>"$D/r$r.timeline"
  timeout 20 docker exec "$WORKER" cat "$KUBELET_DRA_STATE" >"$D/r$r.kubelet-dra-state.$1.json" 2>"$D/r$r.kubelet-dra-state.$1.err"
}

# watch_until UID END records the entry every 10 s until END (epoch seconds), and stops FINAL_S before the deadline.
# It fails if that cut it short.
watch_until() {
  local uid=$1 end=$2 until
  until=$end
  [ "$until" -le $(( DL - FINAL_S )) ] || until=$(( DL - FINAL_S ))
  while :; do
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) watch $(cp_state "$uid")" >>"$D/r$r.timeline"
    [ "$(date +%s)" -lt "$until" ] || break
    sleep 10
  done
  [ "$until" -ge "$end" ]
}

# count FILE PATTERN UID echoes the lines naming both UID and PATTERN, or unread when the log or the UID was not read.
count() { if [ -s "$1" ] && [ -n "$3" ]; then grep -F -- "$3" "$1" | grep -ci -- "$2"; else echo unread; fi; }

# The plugin pod is replaced at every repetition, so its log is saved before it goes and after its successor's watch.
save_plugin_log() { timeout 30 kubectl logs -n "$NS" -l "$PLUGIN_SEL" -c gpus --tail=-1 --prefix >"$1" 2>"$1.err"; }

# pod_b NS is the issue's steps 9 and 10: a second pod from the same template, then what kubelet said about it.
# It sets POD_B to ready, not-ready or apply-failed, and never decides validity.
# A pod that could not be created is apply-failed, so it is never read as a replacement refused its device.
pod_b() {
  manifest "$1" pod-b | sed '1,/^---$/d' >"$D/r$r.pod-b.yaml"
  POD_B=apply-failed
  kubectl apply -f "$D/r$r.pod-b.yaml" >>"$D/r$r.pod-b.log" 2>&1 || return 1
  POD_B=not-ready
  kubectl wait -n "$1" --for=condition=Ready pod/pod-b --timeout="$(left 90)s" >>"$D/r$r.pod-b.log" 2>&1 && POD_B=ready
  kubectl get events -n "$1" --field-selector involvedObject.name=pod-b >"$D/r$r.pod-b-events.txt" 2>&1
  kubectl describe pod -n "$1" pod-b >"$D/r$r.pod-b-describe.txt" 2>&1
}

valid_reps=0
started=0
finding=no
for r in $(seq 1 "$REPS"); do
  if ! enough "$REP_MIN_S"; then note "rep $r not started: under $REP_MIN_S s left"; break; fi
  started=$(( started + 1 ))
  ns="s5-r$r"
  uid=""
  manifest "$ns" pod >"$D/r$r.yaml"
  if ! step "r$r-prepare" prepare "$D/r$r.yaml" "$ns"; then
    note "rep $r: the pod did not become ready; the repetition is void"
    printf '%s\tno\t\t\t\tnot-ready\t\t\t\t\t\t\t\t\t\t\t\t\t\n' "$r" >>"$D/result.tsv"
    kubectl delete ns "$ns" --wait=false >>"$D/ns-delete.log" 2>&1
    continue
  fi
  # Step 2: the generated claim's name comes from the pod's status, as the issue reads it.
  kubectl get -n "$ns" pod/pod -o jsonpath='{.status.resourceClaimStatuses}' >"$D/r$r.resource-claim-statuses.json" 2>&1
  claim=$(kubectl get -n "$ns" pod/pod -o jsonpath='{.status.resourceClaimStatuses[?(@.name=="gpu")].resourceClaimName}' 2>>"$D/r$r.read.err")
  pod_uid=$(kubectl get -n "$ns" pod/pod -o jsonpath='{.metadata.uid}' 2>>"$D/r$r.read.err")
  [ -n "$claim" ] && uid=$(kubectl get -n "$ns" "resourceclaim/$claim" -o jsonpath='{.metadata.uid}' 2>>"$D/r$r.read.err")
  after_prepare=unread
  [ -n "$uid" ] && after_prepare=$(cp_state "$uid")
  mark prepared
  kubectl get -n "$ns" pod/pod ${claim:+resourceclaim/$claim} -o yaml >"$D/r$r.objects-before-delete.yaml" 2>&1
  save_plugin_log "$D/r$r.plugin-before-down.log"
  down=yes forced=no up=yes watched=yes FIN_REMOVED=no
  if [ -z "$uid" ]; then
    note "rep $r: no generated claim in the pod's resourceClaimStatuses; the repetition is void"
    down=no
  elif ! step "r$r-plugin-down" plugin_down; then
    note "rep $r: the plugin did not go down; the repetition is void"
    down=no
  else
    mark plugin-down
    step "r$r-force-delete" force_delete "$ns" "$claim" && forced=yes
    step "r$r-until-gone" until_gone "$ns" "$claim"
  fi
  # Read while the plugin is still down: this is the issue's precondition, and the validity rule's.
  pod_while_down=$(presence pod/pod "$ns")
  claim_while_down=unread
  [ -n "$claim" ] && claim_while_down=$(presence "resourceclaim/$claim" "$ns")
  kubectl get -n "$ns" pod/pod ${claim:+resourceclaim/$claim} -o yaml >"$D/r$r.objects-while-down.yaml" 2>&1
  mark deleted
  step "r$r-plugin-up" plugin_up || { up=no; note "rep $r: the plugin did not come back within its bound"; }
  returned_at=$(date +%s)
  at_return=$(cp_state "$uid")
  mark plugin-up
  step "r$r-watch" watch_until "$uid" $(( returned_at + WATCH_S )) || { watched=no; note "rep $r: the deadline cut the watch short"; }
  after_watch=$(cp_state "$uid")
  cleanup_watched=no
  if [ "$after_watch" != absent ] && [ "$after_watch" != unread ]; then
    # Step 8: the entry outlived two kubelet retry periods, so the watch runs on to one plugin cleanup interval.
    step "r$r-cleanup-watch" watch_until "$uid" $(( returned_at + CLEANUP_WATCH_S )) && cleanup_watched=yes
    after_watch=$(cp_state "$uid")
  fi
  watched_s=$(( $(date +%s) - returned_at ))
  mark watched
  timeout 30 docker exec "$WORKER" journalctl -u kubelet --no-pager --since "@$T0" >"$D/r$r.kubelet.log" 2>"$D/r$r.kubelet.err"
  save_plugin_log "$D/r$r.plugin-after-watch.log"
  cat "$D/r$r.plugin-before-down.log" "$D/r$r.plugin-after-watch.log" >"$D/r$r.plugin.log" 2>>"$D/r$r.read.err"
  # kubelet's unprepare errors name the pod, not the claim, so they are counted by the pod's UID.
  kubelet_pod=unread
  [ -n "$pod_uid" ] && kubelet_pod=$(count "$D/r$r.kubelet.log" unprepare "$pod_uid")
  kubelet_claim=$(count "$D/r$r.kubelet.log" "$uid" "$uid")
  plugin_called=$(count "$D/r$r.plugin.log" "Unprepare called" "$uid")
  valid=no
  [ "$after_prepare" = PrepareCompleted ] && [ "$down" = yes ] && [ "$forced" = yes ] &&
    [ "$pod_while_down" = gone ] && [ "$claim_while_down" = gone ] &&
    [ "$up" = yes ] && [ "$watched" = yes ] && [ "$after_watch" != unread ] && valid=yes && valid_reps=$(( valid_reps + 1 ))
  pod_b_state=- pod_b_uid=-
  if [ "$valid" = yes ] && [ "$after_watch" != absent ]; then
    finding=yes
    note "rep $r: FINDING: claim $uid is gone from the API and still $after_watch in the checkpoint ${watched_s} s after the plugin returned"
    step "r$r-pod-b" pod_b "$ns"
    pod_b_state=$POD_B
    pod_b_uid=$(grep -c -F -- "$uid" "$D/r$r.pod-b-events.txt")
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$r" "$valid" "$claim" "$uid" "$pod_uid" \
    "$after_prepare" "$forced" "$FIN_REMOVED" "$pod_while_down" "$claim_while_down" "$at_return" "$after_watch" "$watched_s" \
    "$cleanup_watched" "$kubelet_pod" "$kubelet_claim" "$plugin_called" "$pod_b_state" "$pod_b_uid" >>"$D/result.tsv"
  note "rep $r (valid=$valid): claim $claim $uid $after_prepare; pod $pod_while_down and claim $claim_while_down while down; $at_return at the return; $after_watch after ${watched_s} s"
  [ "$valid" = yes ] || note "rep $r is invalid: an object still present, or unread, while the plugin was down does not test #1278"
  if [ "$finding" = yes ]; then
    note "the leaked entry holds the only GPU, so no further repetition can prepare; the repetitions end here"
    break
  fi
  kubectl delete ns "$ns" --wait=false >>"$D/ns-delete.log" 2>&1
done
collect
note "$valid_reps of $started started repetitions valid (REPS=$REPS), finding=$finding"
echo "valid_reps=$valid_reps started=$started reps=$REPS finding=$finding" >"$D/verdict.txt"
[ "$valid_reps" = "$started" ] || exit 4
[ "$valid_reps" = "$REPS" ] || { [ "$finding" = yes ] && [ "$valid_reps" -ge 1 ]; } || exit 4
exit 0
