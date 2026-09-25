#!/usr/bin/env bash
# Run the simulated-MIG control-plane study.
#
# The pre-registration is docs/superpowers/specs/2026-09-24-simulated-mig-profiles.md and it is fixed: this
# script implements those arms and bars, it does not choose them.
#
# Usage:
#   hack/mig.sh fixture              # namespace, flavour, queue, and the two profile plugins
#   hack/mig.sh trial <arm> <rep>    # one trial of one arm: P, Q, M or I
#   hack/mig.sh study                # five counterbalanced blocks, 20 confirmatory trials
#   hack/mig.sh teardown
#
# Environment:
#   CONTEXT   kube context                     (default kind-platform)
#   REPO      repository root holding experiments/  (default: this script's parent)
#   EXDIR     evidence directory               (default ex/mig-<UTC timestamp>)
#   WINDOW    observation seconds after submit (default 180)

set -euo pipefail
set -m

CONTEXT="${CONTEXT:-kind-platform}"
NS=mig
PLUGIN_NS=mig-sim
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Manifests live in the repository, which is not always where this script is run from.
#
# The fragmentation runner was executed from an immutable copy in a scratchpad so that editing the repo
# could not disturb a run in flight; ROOT then pointed at the scratchpad, `sed` on a missing file wrote an
# empty one, and 25 trials died at `kubectl apply` with "no objects passed to apply".
REPO="${REPO:-$ROOT}"
if [[ ! -d "$REPO/experiments/mig" ]]; then
  echo "REPO=$REPO does not contain experiments/mig; set REPO to the repository root" >&2
  exit 1
fi

LOCKDIR="${LOCKDIR:-/tmp/mig.lock}"
WINDOW="${WINDOW:-180}"

# The two opaque profile keys. Nothing here models a real card's partitioning.
P_KEY="nvidia.com/mig-1g.5gb"
Q_KEY="nvidia.com/mig-2g.10gb"

# The eligible set. The control-plane node is excluded by its own NoSchedule taint, which kind applies by
# default and this repository does not declare -- so it is verified per trial rather than assumed.
NODE_A=platform-worker
NODE_B=platform-worker2

k() { kubectl --context "$CONTEXT" "$@"; }
now() { date -u +%s.%N; }
say() { printf '%s  %s\n' "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" "$*" | tee -a "$EXDIR/run.log"; }

acquire_lock() {
  if mkdir "$LOCKDIR" 2>/dev/null; then
    echo $$ >"$LOCKDIR/pid"
    LOCK_HELD=1
    return 0
  fi
  local owner
  owner="$(cat "$LOCKDIR/pid" 2>/dev/null || true)"
  if [[ -n "$owner" ]] && kill -0 "$owner" 2>/dev/null; then
    echo "another run (pid $owner) holds $LOCKDIR" >&2
    exit 1
  fi
  echo "removing a stale lock left by pid ${owner:-unknown}" >&2
  rm -rf "$LOCKDIR"
  mkdir "$LOCKDIR" && echo $$ >"$LOCKDIR/pid" && LOCK_HELD=1
}
release_lock() {
  [[ "${LOCK_HELD:-0}" == "1" ]] || return 0
  rm -rf "$LOCKDIR"
  LOCK_HELD=0
}

# Advertised inventory, per node and per profile, read from the nodes themselves.
inventory() {
  python3 - "$CONTEXT" "$NODE_A" "$NODE_B" "$P_KEY" "$Q_KEY" <<'PY'
import json
import subprocess
import sys

context, node_a, node_b, p_key, q_key = sys.argv[1:6]
nodes = [node_a, node_b]


def kubectl(args):
    out = subprocess.run(["kubectl", "--context", context] + args, capture_output=True, text=True)
    return json.loads(out.stdout) if out.stdout.strip() else {"items": []}


alloc = {n: {} for n in nodes}
for node in kubectl(["get", "nodes", "-o", "json"])["items"]:
    name = node["metadata"]["name"]
    if name in alloc:
        for key in (p_key, q_key):
            alloc[name][key] = int(node["status"]["allocatable"].get(key, 0))

used = {n: {p_key: 0, q_key: 0} for n in nodes}
for pod in kubectl(["get", "pods", "-A", "-o", "json"])["items"]:
    if pod["status"].get("phase") in ("Succeeded", "Failed"):
        continue
    node = pod["spec"].get("nodeName")
    if node not in used:
        continue
    for container in pod["spec"]["containers"]:
        limits = (container.get("resources") or {}).get("limits") or {}
        for key in (p_key, q_key):
            used[node][key] += int(limits.get(key, 0))

free = {n: {key: alloc[n].get(key, 0) - used[n][key] for key in (p_key, q_key)} for n in nodes}
print(json.dumps({
    "allocatable": alloc,
    "used": used,
    "free": free,
    "free_total": {key: sum(free[n][key] for n in nodes) for key in (p_key, q_key)},
}))
PY
}

# Which of the three states the evidence says we are in, or "unknown".
#
# Read from the Workload, the Job and the Pod. MLTrainingJob.phase and Job.status.active are deliberately not
# consulted: Finding 6 showed the latter counts pending Pods, so both would call an unplaced job Running.
classify() {
  local job="$1" want_key="$2" other_key="$3"
  python3 - "$CONTEXT" "$NS" "$job" "$want_key" "$other_key" "$NODE_A" "$NODE_B" <<'PY'
import json
import subprocess
import sys

context, ns, job_name, want, other, *nodes = sys.argv[1:]


def kubectl(args):
    out = subprocess.run(["kubectl", "--context", context] + args, capture_output=True, text=True)
    return json.loads(out.stdout) if out.stdout.strip() else None


admitted = False
reserved = {}
quota_message = ""
for workload in ((kubectl(["-n", ns, "get", "workload", "-o", "json"]) or {"items": []})["items"]):
    owners = workload["metadata"].get("ownerReferences") or []
    if not any((o.get("name") or "") == job_name for o in owners):
        continue
    for condition in workload.get("status", {}).get("conditions", []):
        if condition["type"] == "Admitted" and condition["status"] == "True":
            admitted = True
        if condition["type"] in ("QuotaReserved", "Admitted") and condition["status"] != "True":
            quota_message = condition.get("message", "")
    # What Kueue actually reserved, by key. H1 lives here: the requested key must survive into the
    # reservation rather than being folded into some other resource.
    for assignment in (workload.get("status", {}).get("admission", {}) or {}).get("podSetAssignments", []) or []:
        for key, value in (assignment.get("resourceUsage") or {}).items():
            reserved[key] = str(value)

job = kubectl(["-n", ns, "get", "job", job_name, "-o", "json"])
suspended = bool((job or {}).get("spec", {}).get("suspend"))

pods = kubectl(["-n", ns, "get", "pods", "-l", f"job-name={job_name}", "-o", "json"]) or {"items": []}
pod = pods["items"][0] if pods["items"] else None
unschedulable = False
scheduler_message = ""
if pod:
    for condition in pod.get("status", {}).get("conditions", []):
        if condition["type"] == "PodScheduled" and condition["status"] == "False":
            unschedulable = condition.get("reason") == "Unschedulable"
            scheduler_message = condition.get("message", "")

alloc = {n: {} for n in nodes}
for node in ((kubectl(["get", "nodes", "-o", "json"]) or {"items": []})["items"]):
    name = node["metadata"]["name"]
    if name in alloc:
        for key in (want, other):
            alloc[name][key] = int(node["status"]["allocatable"].get(key, 0))
used = {n: {want: 0, other: 0} for n in nodes}
for p in ((kubectl(["get", "pods", "-A", "-o", "json"]) or {"items": []})["items"]):
    if p["status"].get("phase") in ("Succeeded", "Failed"):
        continue
    n = p["spec"].get("nodeName")
    if n not in used:
        continue
    for c in p["spec"]["containers"]:
        limits = (c.get("resources") or {}).get("limits") or {}
        for key in (want, other):
            used[n][key] += int(limits.get(key, 0))
free_want = sum(alloc[n].get(want, 0) - used[n][want] for n in nodes)
free_other = sum(alloc[n].get(other, 0) - used[n][other] for n in nodes)

if not admitted and suspended and pod is None:
    state = "quota-blocked"
elif admitted and not suspended and pod is not None and unschedulable:
    # The scheduler must name the key that was actually requested. A message about some other resource means
    # the Pod is stuck for a reason this study does not model, and that is `unknown`, not a mismatch.
    state = "profile-mismatch" if want in scheduler_message and free_want == 0 else "unknown"
elif pod is not None and pod.get("spec", {}).get("nodeName"):
    state = "scheduled"
else:
    state = "unknown"

print(json.dumps({
    "state": state, "admitted": admitted, "suspended": suspended,
    "pod_exists": pod is not None, "unschedulable": unschedulable,
    "reserved": reserved,
    "reserved_wrong_key": sorted(key for key in reserved if key not in (want, other)),
    "free_want": free_want, "free_other": free_other,
    "node_name": (pod or {}).get("spec", {}).get("nodeName"),
    "pod_uid": (pod or {}).get("metadata", {}).get("uid"),
    "scheduler_message": scheduler_message[:200],
    "quota_message": quota_message[:200],
}))
PY
}

render_job() {
  local name="$1" profile="$2" role="$3" out="$4"
  sed -e "s|NAME_PLACEHOLDER|$name|g" -e "s|PROFILE_PLACEHOLDER|$profile|g" -e "s|ROLE_PLACEHOLDER|$role|g" \
    "$REPO/experiments/mig/target.yaml" >"$out"
  if [[ ! -s "$out" ]]; then
    say "INVALID: $name rendered empty; is REPO=$REPO the repository root?"
    return 1
  fi
  if grep -q PLACEHOLDER "$out"; then
    say "INVALID: a placeholder survived substitution in $name"
    return 1
  fi
  return 0
}

set_quota() {
  local p="$1" q="$2"
  k patch clusterqueue mig --type=json \
    -p "[{\"op\":\"replace\",\"path\":\"/spec/resourceGroups/0/flavors/0/resources/0/nominalQuota\",\"value\":$p},
         {\"op\":\"replace\",\"path\":\"/spec/resourceGroups/0/flavors/0/resources/1/nominalQuota\",\"value\":$q}]" \
    >>"$EXDIR/run.log" 2>&1
}

# Point a profile's plugin at a node, and wait until that node actually advertises it.
#
# Arm M is exactly this: the `q` plugin is moved to advertise `p` on W2 instead, same device count, different
# key. The wait matters because a DaemonSet rescheduling is not instant and a trial that starts before the
# node's allocatable has caught up measures the previous arm.
place_plugin() {
  local ds="$1" node="$2" key="$3" want="$4"
  k -n "$PLUGIN_NS" patch daemonset "$ds" --type=json \
    -p "[{\"op\":\"replace\",\"path\":\"/spec/template/spec/nodeSelector/kubernetes.io~1hostname\",\"value\":\"$node\"},
         {\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/env/0/value\",\"value\":\"$key\"}]" \
    >>"$EXDIR/run.log" 2>&1

  local deadline=$((SECONDS + 180))
  while ((SECONDS < deadline)); do
    local got
    got="$(k get node "$node" -o jsonpath="{.status.allocatable['${key//./\\.}']}" 2>/dev/null || true)"
    [[ "${got:-0}" == "$want" ]] && return 0
    sleep 3
  done
  say "INVALID: $node did not advertise $key=$want within 180s (saw '${got:-0}')"
  return 1
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    fixture | trial | study | teardown) ;;
    *)
      echo "usage: $0 {fixture|trial <arm> <rep>|study|teardown}" >&2
      exit 1
      ;;
  esac
  shift

  acquire_lock
  EXDIR="${EXDIR:-ex/mig-$(date -u +%Y%m%dT%H%M%SZ)}"
  mkdir -p "$EXDIR"
  trap release_lock EXIT

  "$cmd" "$@"
}

fixture() {
  say "applying the plugin DaemonSets and the queue objects"
  k apply -f "$REPO/experiments/mig/plugins.yaml" >>"$EXDIR/run.log" 2>&1
  k apply -f "$REPO/experiments/mig/queue.yaml" >>"$EXDIR/run.log" 2>&1

  local deadline=$((SECONDS + 180))
  while ((SECONDS < deadline)); do
    [[ "$(k get clusterqueue mig -o jsonpath='{.status.conditions[?(@.type=="Active")].status}' 2>/dev/null)" == "True" ]] &&
      {
        say "ClusterQueue mig is Active"
        break
      }
    sleep 3
  done

  say "waiting for both profiles to appear in allocatable"
  place_plugin mig-sim-p "$NODE_A" "$P_KEY" 2 || exit 1
  place_plugin mig-sim-q "$NODE_B" "$Q_KEY" 2 || exit 1
  say "inventory: $(inventory)"
}

# Wait until a Job's own Workload reports the condition we are about to judge on.
#
# Polling the Job alone is not enough: Kueue creates the Workload asynchronously, and a trial that starts
# classifying before it exists reads "not admitted" from an object that does not yet have an opinion.
await_workload() {
  local job="$1" deadline=$((SECONDS + 60))
  while ((SECONDS < deadline)); do
    local n
    n="$(k -n "$NS" get workload -o json 2>/dev/null |
      python3 -c "
import json,sys
d=json.load(sys.stdin)
print(sum(1 for w in d['items']
          for o in (w['metadata'].get('ownerReferences') or [])
          if o.get('name') == '$job'))" 2>/dev/null || echo 0)"
    [[ "$n" == "1" ]] && return 0
    sleep 1
  done
  return 1
}

cleanup_trial() {
  k -n "$NS" delete job --all --ignore-not-found >>"$EXDIR/run.log" 2>&1 || true
  local deadline=$((SECONDS + 120))
  while ((SECONDS < deadline)); do
    local pods workloads
    pods="$(k -n "$NS" get pods --no-headers 2>/dev/null | wc -l)"
    workloads="$(k -n "$NS" get workload --no-headers 2>/dev/null | wc -l)"
    [[ "$pods" == "0" && "$workloads" == "0" ]] && return 0
    sleep 2
  done
  say "WARNING: objects survived cleanup in $NS"
}

# Refuse to start a trial whose inventory is not what the arm declares.
#
# A trial that begins from the wrong advertised capacity measures the previous arm, and its result would look
# like a finding rather than a mistake.
verify_inventory() {
  local want_a="$1" want_b="$2" key_a="$3" key_b="$4"
  local snap
  snap="$(inventory)"
  echo "$snap" >"$EXDIR/inventory-$TAG.json"
  local got
  got="$(python3 -c "
import json,sys
d=json.loads(sys.argv[1])
a=d['allocatable']['$NODE_A'].get('$key_a',0)
b=d['allocatable']['$NODE_B'].get('$key_b',0)
print(f'{a},{b}')" "$snap")"
  if [[ "$got" != "$want_a,$want_b" ]]; then
    say "INVALID: inventory is ($got), expected ($want_a,$want_b)"
    return 1
  fi
  local busy
  busy="$(python3 -c "
import json,sys
d=json.loads(sys.argv[1])
print(sum(v for node in d['used'].values() for v in node.values()))" "$snap")"
  if [[ "$busy" != "0" ]]; then
    say "INVALID: $busy profile devices already in use before the trial"
    return 1
  fi
  return 0
}

trial() {
  local arm="$1" rep="$2"
  TAG="$arm-$rep"
  local slug="${arm,,}-$rep"
  say "=== trial $TAG ==="

  cleanup_trial

  # Each arm is a statement about inventory and quota, and nothing else changes.
  local p_quota=1 q_quota=1 want_key="$Q_KEY" other_key="$P_KEY"
  local inv_a=2 inv_b=2 key_b="$Q_KEY"
  case "$arm" in
    P) ;;
    Q) q_quota=0 ;;
    # The only manipulation is the key W2 advertises: same device count, different name.
    M) key_b="$P_KEY" ;;
    # `I` asks about `p` rather than `q`, and holds `p` with a first Job.
    I)
      want_key="$P_KEY"
      other_key="$Q_KEY"
      ;;
    *)
      echo "unknown arm $arm" >&2
      return 1
      ;;
  esac

  place_plugin mig-sim-p "$NODE_A" "$P_KEY" "$inv_a" || {
    echo -e "$arm\t$rep\tINVALID\tplugin-p" >>"$EXDIR/results.tsv"
    return 0
  }
  place_plugin mig-sim-q "$NODE_B" "$key_b" "$inv_b" || {
    echo -e "$arm\t$rep\tINVALID\tplugin-q" >>"$EXDIR/results.tsv"
    return 0
  }
  verify_inventory "$inv_a" "$inv_b" "$P_KEY" "$key_b" || {
    echo -e "$arm\t$rep\tINVALID\tinventory" >>"$EXDIR/results.tsv"
    return 0
  }
  set_quota "$p_quota" "$q_quota"

  # `I` exhausts p with a holder first, so the second p request has quota, not capacity, against it.
  if [[ "$arm" == "I" ]]; then
    render_job "mig-holder-$slug" "$P_KEY" holder "$EXDIR/holder-$slug.yaml" || {
      echo -e "$arm\t$rep\tINVALID\tholder-render" >>"$EXDIR/results.tsv"
      return 0
    }
    k apply -f "$EXDIR/holder-$slug.yaml" >>"$EXDIR/run.log" 2>&1
    local hd=$((SECONDS + 120))
    while ((SECONDS < hd)); do
      [[ "$(k -n "$NS" get pods -l "job-name=mig-holder-$slug" -o jsonpath='{.items[0].status.phase}' 2>/dev/null)" == "Running" ]] && break
      sleep 2
    done
    say "holder running; p quota is now spent"
  fi

  local target="mig-target-$slug"
  render_job "$target" "$want_key" target "$EXDIR/$target.yaml" || {
    echo -e "$arm\t$rep\tINVALID\ttarget-render" >>"$EXDIR/results.tsv"
    return 0
  }
  local t0
  t0="$(now)"
  k apply -f "$EXDIR/$target.yaml" >>"$EXDIR/run.log" 2>&1
  say "submitted $target requesting $want_key"

  await_workload "$target" || say "WARNING: no Workload appeared for $target within 60s"

  local deadline
  deadline=$(python3 -c "print($t0 + $WINDOW)")
  : >"$EXDIR/timeline-$TAG.jsonl"
  while (($(python3 -c "print(1 if $(now) < $deadline else 0)"))); do
    local snap
    snap="$(classify "$target" "$want_key" "$other_key")"
    python3 -c "
import json,sys
d=json.loads(sys.argv[1]); d['t']=round($(now)-$t0,2); print(json.dumps(d,sort_keys=True))" "$snap" \
      >>"$EXDIR/timeline-$TAG.jsonl"
    sleep 1
  done

  python3 - "$EXDIR/timeline-$TAG.jsonl" "$arm" "$rep" <<'INNER' | tee -a "$EXDIR/results.tsv"
import collections
import json
import sys

path, arm, rep = sys.argv[1], sys.argv[2], sys.argv[3]
rows = [json.loads(line) for line in open(path)]
states = collections.Counter(r["state"] for r in rows)
final = rows[-1]["state"] if rows else "none"
# Durations from timestamps, never from sample counts: the fragmentation study published "145 seconds" for a
# window spanning 179.1s because a count was printed with an "s" after it.
gaps = [rows[i + 1]["t"] - rows[i]["t"] for i in range(len(rows) - 1)]
worst = max(gaps) if gaps else 0.0
wrong = sorted({k for r in rows for k in r.get("reserved_wrong_key", [])})
print("\t".join([arm, rep, final,
                  ",".join(f"{k}={v}" for k, v in states.most_common()),
                  f"span={rows[-1]['t'] - rows[0]['t']:.1f}s" if len(rows) > 1 else "span=0s",
                  f"max_gap={worst:.2f}s",
                  f"wrong_key={','.join(wrong) if wrong else 'none'}"]))
INNER
}

study() {
  printf 'arm\trep\tfinal_state\tstate_samples\tspan\tmax_gap\twrong_key\n' >"$EXDIR/results.tsv"
  # Counterbalanced: each arm appears once in every position.
  local blocks=("P Q M I" "Q M I P" "M I P Q" "I P Q M" "P M Q I")
  local block rep=0
  for block in "${blocks[@]}"; do
    rep=$((rep + 1))
    local arm
    for arm in $block; do
      trial "$arm" "$rep"
    done
  done
  cleanup_trial
  say "study complete"
  cat "$EXDIR/results.tsv" | tee -a "$EXDIR/run.log"
}

teardown() {
  say "removing the experiment"
  k -n "$NS" delete job --all --ignore-not-found >>"$EXDIR/run.log" 2>&1 || true
  k -n "$NS" delete localqueue mig --ignore-not-found >>"$EXDIR/run.log" 2>&1 || true
  k delete clusterqueue mig --ignore-not-found >>"$EXDIR/run.log" 2>&1 || true
  k delete resourceflavor mig --ignore-not-found >>"$EXDIR/run.log" 2>&1 || true
  k delete namespace "$NS" --ignore-not-found >>"$EXDIR/run.log" 2>&1 || true
  k delete namespace "$PLUGIN_NS" --ignore-not-found >>"$EXDIR/run.log" 2>&1 || true

  # The profile keys survive in capacity, and that is not a failed teardown.
  #
  # A kubelet drops an extended resource's ALLOCATABLE to zero as soon as its device plugin stops answering,
  # but keeps the name in CAPACITY until the node restarts. Nothing can be scheduled against it -- allocatable
  # is what the scheduler reads -- so the next experiment is unaffected. Reported rather than hidden, because
  # a leftover name in `kubectl get node -o json` looks exactly like debris to whoever finds it next.
  say "residual profile keys (allocatable must be 0):"
  k get nodes -o json 2>/dev/null | python3 -c "
import json, sys
for node in json.load(sys.stdin)['items']:
    keys = {k: v for k, v in node['status']['allocatable'].items() if 'mig' in k}
    if keys:
        print('   ', node['metadata']['name'], keys)
" | tee -a "$EXDIR/run.log"
  say "teardown complete"
}

main "$@"
