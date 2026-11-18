#!/bin/bash
# S1, the #1278 path: a claim in PrepareCompleted whose pod and claim are deleted while the gpu-kubelet-plugin is down.
#
# The maintainers expect kubelet to retry NodeUnprepareResources once the plugin is back, which would remove the entry.
# Each repetition records the checkpoint around every step, then watches the entry for two kubelet retry periods after
# the plugin returns, with both the kubelet's and the plugin's logs.
# A finding is an entry for a claim the API no longer has that survives the watch, with no unprepare for it in either log.
#
# A repetition is valid only if the claim reached PrepareCompleted, the plugin went down and came back, and the watch
# ran its full length; the phase exits 4 unless all REPS are valid, so a run that never set up the experiment cannot
# pass for one that observed nothing wrong.
# A read that fails is recorded as "unread", never as absent or zero.
set -u
. "$(dirname "$0")/lib.sh"
T0=$(date +%s)
REPS=3
# Two kubelet retry periods; the DRA manager's reconcile period is taken as 60 s, which this run does not verify.
WATCH_S=150
# A typical repetition, not the worst case: every wait inside one is also capped by the phase's deadline, and a
# repetition the deadline cuts short is recorded as invalid rather than run past it.
REP_MIN_S=300
DOWN_LABEL=dra-gpu-session/plugin-down

install_chart || { note "the chart did not install"; exit 2; }
printf 'rep\tvalid\tclaim_uid\tafter_prepare\tpod_gone_while_down\tclaim_gone_while_down\tat_return\tafter_watch\tkubelet_unprepare_lines\tplugin_unprepare_lines\n' >"$D/result.tsv"

manifest() {
  cat <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: $1
---
apiVersion: resource.k8s.io/v1
kind: ResourceClaim
metadata:
  namespace: $1
  name: gpu
spec:
  devices:
    requests:
    - name: gpu
      exactly:
        deviceClassName: gpu.nvidia.com
---
apiVersion: v1
kind: Pod
metadata:
  namespace: $1
  name: pod
spec:
  restartPolicy: Never
  containers:
  - name: ctr
    image: ubuntu:22.04
    command: ["bash", "-c"]
    args: ["nvidia-smi -L; trap 'exit 0' TERM; sleep 9999 & wait"]
    resources:
      claims:
      - name: gpu
  resourceClaims:
  - name: gpu
    resourceClaimName: gpu
  tolerations:
  - key: "nvidia.com/gpu"
    operator: "Exists"
    effect: "NoSchedule"
EOF
}

prepare() {
  kubectl apply -f "$1" && kubectl wait -n "$2" --for=condition=Ready pod/pod --timeout="$(left 150)s"
}

# The DaemonSet is pinned to a label no node has, so its pod is removed and not replaced until the label is dropped.
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
  plugin_ready 120
}

# presence OBJ NS echoes gone, present, or unread: only the API's own not-found is taken as gone.
presence() {
  local o
  o=$(kubectl get -n "$2" "$1" --ignore-not-found -o name 2>/dev/null) || { echo unread; return; }
  [ -z "$o" ] && echo gone || echo present
}
gone() { [ "$(presence "$1" "$2")" = gone ]; }

# Both deletions are issued without waiting, as a controller would; whether each object leaves while the plugin is down
# is part of the record, not a precondition.
delete_both() {
  kubectl delete -n "$1" pod/pod --wait=false && kubectl delete -n "$1" resourceclaim/gpu --wait=false || return 1
  poll 60 3 gone pod/pod "$1"
  poll 15 3 gone resourceclaim/gpu "$1"
  return 0
}

# watch_entry UID records the entry every 10 s for WATCH_S, and fails if the phase's deadline cut the watch short.
watch_entry() {
  local uid=$1 full=$(( $(date +%s) + WATCH_S )) until=$(( $(date +%s) + $(left "$WATCH_S") ))
  while :; do
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $(cp_state "$uid")" >>"$D/r$r.timeline"
    [ "$(date +%s)" -lt "$until" ] || break
    sleep 10
  done
  [ "$until" -ge "$full" ]
}

# count_unprepare FILE UID echoes the lines naming both the claim and an unprepare, or unread when the log was not read.
count_unprepare() { if [ -s "$1" ]; then grep "$2" "$1" | grep -ci unprepare; else echo unread; fi; }

# The plugin pod is replaced at every repetition, so its log is saved before it goes and after its successor's watch.
save_plugin_log() { timeout 30 kubectl logs -n "$NS" -l "$PLUGIN_SEL" -c gpus --tail=-1 --prefix >"$1" 2>"$1.err"; }

valid_reps=0
for r in $(seq 1 "$REPS"); do
  if ! enough "$REP_MIN_S"; then note "rep $r not started: under $REP_MIN_S s left"; break; fi
  ns="s1-r$r"
  manifest "$ns" >"$D/r$r.yaml"
  if ! step "r$r-prepare" prepare "$D/r$r.yaml" "$ns"; then
    note "rep $r: the pod did not become ready; the repetition is void"
    printf '%s\tno\t\tnot-ready\t\t\t\t\t\t\n' "$r" >>"$D/result.tsv"
    kubectl delete ns "$ns" --wait=false >/dev/null 2>&1
    continue
  fi
  uid=$(kubectl get -n "$ns" resourceclaim/gpu -o jsonpath='{.metadata.uid}')
  after_prepare=$(cp_state "$uid")
  kubectl get -n "$ns" pod/pod resourceclaim/gpu -o yaml >"$D/r$r.objects-before-delete.yaml" 2>&1
  save_plugin_log "$D/r$r.plugin-before-down.log"
  down=yes up=yes watched=yes
  if ! step "r$r-plugin-down" plugin_down; then
    note "rep $r: the plugin did not go down; the repetition is void"
    down=no
  else
    step "r$r-delete" delete_both "$ns"
  fi
  pod_gone=$(presence pod/pod "$ns")
  claim_gone=$(presence resourceclaim/gpu "$ns")
  kubectl get -n "$ns" pod/pod resourceclaim/gpu -o yaml >"$D/r$r.objects-while-down.yaml" 2>&1
  step "r$r-plugin-up" plugin_up || { up=no; note "rep $r: the plugin did not come back within its bound"; }
  at_return=$(cp_state "$uid")
  step "r$r-watch" watch_entry "$uid" || { watched=no; note "rep $r: the deadline cut the watch short"; }
  after_watch=$(cp_state "$uid")
  timeout 30 docker exec "$WORKER" journalctl -u kubelet --no-pager --since "@$T0" >"$D/r$r.kubelet.log" 2>"$D/r$r.kubelet.err"
  save_plugin_log "$D/r$r.plugin-after-watch.log"
  kubelet_lines=$(count_unprepare "$D/r$r.kubelet.log" "$uid")
  cat "$D/r$r.plugin-before-down.log" "$D/r$r.plugin-after-watch.log" >"$D/r$r.plugin.log" 2>/dev/null
  plugin_lines=$(count_unprepare "$D/r$r.plugin.log" "$uid")
  valid=no
  [ "$after_prepare" = PrepareCompleted ] && [ "$down" = yes ] && [ "$up" = yes ] && [ "$watched" = yes ] &&
    [ "$after_watch" != unread ] && valid=yes && valid_reps=$(( valid_reps + 1 ))
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$r" "$valid" "$uid" "$after_prepare" "$pod_gone" "$claim_gone" "$at_return" \
    "$after_watch" "$kubelet_lines" "$plugin_lines" >>"$D/result.tsv"
  note "rep $r (valid=$valid): claim $uid $after_prepare -> $at_return at the plugin's return -> $after_watch after the watch"
  kubectl delete ns "$ns" --wait=false >/dev/null 2>&1
done
collect
note "$valid_reps of $REPS repetitions valid"
[ "$valid_reps" = "$REPS" ] || exit 4
