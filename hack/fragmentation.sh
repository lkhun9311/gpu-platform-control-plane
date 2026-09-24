#!/usr/bin/env bash
# Run the node-level GPU fragmentation study.
#
# The pre-registration is docs/superpowers/specs/2026-09-24-node-level-gpu-fragmentation.md and it is fixed:
# this script implements those arms and bars, it does not choose them.
#
# Usage:
#   hack/fragmentation.sh fixture            # namespace, ResourceFlavor, ClusterQueue, LocalQueue
#   hack/fragmentation.sh trial <arm> <n>    # one trial of one arm
#   hack/fragmentation.sh study              # all five blocks, counterbalanced
#   hack/fragmentation.sh teardown
#
# Environment:
#   CONTEXT   kube context                        (default kind-platform)
#   EXDIR     evidence directory                  (default ex/frag-<UTC timestamp>)
#   WINDOW    observation seconds after submit    (default 180)

set -euo pipefail
set -m

CONTEXT="${CONTEXT:-kind-platform}"
NS=frag
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCKDIR="${LOCKDIR:-/tmp/fragmentation.lock}"
WINDOW="${WINDOW:-180}"

# The two workers. The control-plane node is excluded by its own NoSchedule taint, since the target Pod
# carries no toleration -- so the eligible set is these two and the advertised total of six GPUs is not six
# the target can reach.
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

# Headroom, measured the way the pre-registration defines it: allocatable minus the GPU requests of
# non-terminal Pods bound to the node, across every namespace.
#
# Terminal Pods are excluded because they hold no device, and counting them would report fragmentation that
# does not exist. Every namespace is scanned because a Pod outside `frag` would distort the vector without
# appearing in any of this experiment's own objects.
headroom() {
  python3 - "$CONTEXT" "$NODE_A" "$NODE_B" <<'PY'
import json
import subprocess
import sys

# The context is passed as an argument, not re-derived by asking a subshell to echo $CONTEXT: that shell is
# not this script's shell, so it would have returned the empty string and silently queried whatever the
# default context happens to be -- which on this machine is a torn-down EKS cluster.
context, *nodes = sys.argv[1:]


def kubectl(args):
    out = subprocess.run(["kubectl", "--context", context] + args, capture_output=True, text=True)
    return json.loads(out.stdout) if out.stdout.strip() else {"items": []}


allocatable = {}
for node in kubectl(["get", "nodes", "-o", "json"])["items"]:
    name = node["metadata"]["name"]
    if name in nodes:
        allocatable[name] = int(node["status"]["allocatable"].get("nvidia.com/gpu", 0))

used = {n: 0 for n in nodes}
for pod in kubectl(["get", "pods", "-A", "-o", "json"])["items"]:
    if pod["status"].get("phase") in ("Succeeded", "Failed"):
        continue
    node = pod["spec"].get("nodeName")
    if node not in used:
        continue
    for container in pod["spec"]["containers"]:
        limits = (container.get("resources") or {}).get("limits") or {}
        used[node] += int(limits.get("nvidia.com/gpu", 0))

free = {n: allocatable.get(n, 0) - used[n] for n in nodes}
print(json.dumps({
    "allocatable": allocatable,
    "used": used,
    "free": free,
    "sum_free": sum(free.values()),
    "max_free": max(free.values()) if free else 0,
}))
PY
}

# Which of the three states the evidence says we are in, or "unknown".
#
# Returned as a word so the bars can be checked mechanically. The point of the study is that "Pending" is not
# one of the possible answers -- it is the ambiguity this function refuses to reproduce.
classify() {
  local target="$1"
  python3 - "$CONTEXT" "$NS" "$target" "$NODE_A" "$NODE_B" <<'PY'
import json
import subprocess
import sys

context, ns, target, *nodes = sys.argv[1:]


def kubectl(args, raw=False):
    out = subprocess.run(["kubectl", "--context", context] + args, capture_output=True, text=True)
    if raw:
        return out.stdout.strip()
    return json.loads(out.stdout) if out.stdout.strip() else None


workloads = kubectl(["-n", ns, "get", "workload", "-o", "json"]) or {"items": []}
admitted = False
quota_message = ""
for workload in workloads["items"]:
    owners = workload["metadata"].get("ownerReferences") or []
    if not any(target in (o.get("name") or "") for o in owners):
        continue
    for condition in workload.get("status", {}).get("conditions", []):
        if condition["type"] == "Admitted" and condition["status"] == "True":
            admitted = True
        if condition["type"] in ("QuotaReserved", "Admitted") and condition["status"] != "True":
            quota_message = condition.get("message", "")

job = kubectl(["-n", ns, "get", "job", target, "-o", "json"])
suspended = bool((job or {}).get("spec", {}).get("suspend"))

pods = kubectl(["-n", ns, "get", "pods", "-l", f"job-name={target}", "-o", "json"]) or {"items": []}
pod = pods["items"][0] if pods["items"] else None
unschedulable = False
scheduler_message = ""
if pod:
    for condition in pod.get("status", {}).get("conditions", []):
        if condition["type"] == "PodScheduled" and condition["status"] == "False":
            unschedulable = condition.get("reason") == "Unschedulable"
            scheduler_message = condition.get("message", "")

# Headroom is recomputed here rather than passed in, so the classification and the arithmetic it cites come
# from the same instant.
allocatable, used = {}, {n: 0 for n in nodes}
for node in (kubectl(["get", "nodes", "-o", "json"]) or {"items": []})["items"]:
    name = node["metadata"]["name"]
    if name in nodes:
        allocatable[name] = int(node["status"]["allocatable"].get("nvidia.com/gpu", 0))
for p in (kubectl(["get", "pods", "-A", "-o", "json"]) or {"items": []})["items"]:
    if p["status"].get("phase") in ("Succeeded", "Failed"):
        continue
    n = p["spec"].get("nodeName")
    if n not in used:
        continue
    for c in p["spec"]["containers"]:
        used[n] += int(((c.get("resources") or {}).get("limits") or {}).get("nvidia.com/gpu", 0))
free = {n: allocatable.get(n, 0) - used[n] for n in nodes}
sum_free, max_free = sum(free.values()), (max(free.values()) if free else 0)

R = 2
if not admitted and suspended and pod is None:
    state = "quota-shortage"
elif admitted and not suspended and pod is not None and unschedulable:
    if "nvidia.com/gpu" not in scheduler_message:
        state = "unknown"
    elif sum_free >= R and max_free < R:
        state = "fragmentation"
    elif sum_free < R:
        state = "aggregate-shortage"
    else:
        state = "unknown"
elif pod is not None and pod.get("spec", {}).get("nodeName"):
    state = "scheduled"
else:
    state = "unknown"

print(json.dumps({
    "state": state, "admitted": admitted, "suspended": suspended,
    "pod_exists": pod is not None, "unschedulable": unschedulable,
    "scheduler_message": scheduler_message[:200], "quota_message": quota_message[:200],
    "free": free, "sum_free": sum_free, "max_free": max_free,
    "node_name": (pod or {}).get("spec", {}).get("nodeName"),
    "cr_phase": kubectl(["-n", ns, "get", "mltrainingjob", target,
                         "-o", "jsonpath={.status.phase}"], raw=True),
}))
PY
}

# Refuse to start a trial whose fixture is not what the pre-registration says it is.
#
# A trial that begins from the wrong headroom measures nothing, and its failure would look like a result.
verify_fixture() {
  local snapshot
  snapshot="$(headroom)"
  local alloc_a alloc_b
  alloc_a="$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['allocatable'].get('$NODE_A',0))" "$snapshot")"
  alloc_b="$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['allocatable'].get('$NODE_B',0))" "$snapshot")"
  if [[ "$alloc_a" != "2" || "$alloc_b" != "2" ]]; then
    say "INVALID: allocatable is ($alloc_a,$alloc_b), expected (2,2)"
    return 1
  fi
  local used
  used="$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(sum(d['used'].values()))" "$snapshot")"
  if [[ "$used" != "0" ]]; then
    say "INVALID: $used GPUs already in use before the trial"
    return 1
  fi
  return 0
}

set_quota() {
  k patch clusterqueue frag --type=json \
    -p "[{\"op\":\"replace\",\"path\":\"/spec/resourceGroups/0/flavors/0/resources/0/nominalQuota\",\"value\":$1}]" \
    >>"$EXDIR/run.log" 2>&1
}

submit_holder() {
  local name="$1" node="$2"
  sed -e "s|NAME_PLACEHOLDER|$name|g" -e "s|NODE_PLACEHOLDER|$node|g" \
    "$ROOT/experiments/fragmentation/holder.yaml" >"$EXDIR/$name.yaml"
  if grep -q PLACEHOLDER "$EXDIR/$name.yaml"; then
    say "INVALID: a placeholder survived substitution in $name.yaml"
    HOLDER_FAILURE=substitution
    return 1
  fi
  # apply and substitution are separate failures, reported separately.
  #
  # The first rehearsal recorded "holder-substitution" for a name the API rejected as not RFC 1123 -- the
  # substitution had worked perfectly. A wrong invalidation reason sends the next reader to the wrong file.
  if ! k apply -f "$EXDIR/$name.yaml" >>"$EXDIR/run.log" 2>&1; then
    say "INVALID: the API refused holder $name; see run.log"
    HOLDER_FAILURE=apply-refused
    return 1
  fi
  HOLDER_FAILURE=""
  return 0
}

wait_holder_running() {
  local name="$1" node="$2" deadline=$((SECONDS + 120))
  while ((SECONDS < deadline)); do
    local phase on
    phase="$(k -n "$NS" get pods -l "job-name=$name" -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)"
    on="$(k -n "$NS" get pods -l "job-name=$name" -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null || true)"
    [[ "$phase" == "Running" && "$on" == "$node" ]] && return 0
    sleep 2
  done
  say "INVALID: holder $name did not reach Running on $node within 120s"
  return 1
}

cleanup_trial() {
  k -n "$NS" delete mltrainingjob --all --ignore-not-found >>"$EXDIR/run.log" 2>&1 || true
  k -n "$NS" delete job --all --ignore-not-found >>"$EXDIR/run.log" 2>&1 || true
  local deadline=$((SECONDS + 120))
  while ((SECONDS < deadline)); do
    local pods
    pods="$(k -n "$NS" get pods --no-headers 2>/dev/null | wc -l)"
    [[ "$pods" == "0" ]] && return 0
    sleep 2
  done
  say "WARNING: pods still present in $NS after cleanup"
}

trial() {
  local arm="$1" rep="$2"
  local tag="$arm-$rep"
  # Object names take a lower-case arm letter; the record keeps the upper-case one.
  #
  # `frag-h1-F-0` is not a valid RFC 1123 subdomain, and the API says so only at apply time -- after the
  # trial has already torn down the previous one and patched the quota.
  local slug="${arm,,}-$rep"
  local target="frag-target-$slug"
  say "=== trial $tag ==="

  cleanup_trial
  verify_fixture || { echo -e "$arm\t$rep\tINVALID\tfixture" >>"$EXDIR/results.tsv"; return 0; }

  # Arms differ only in where the holders go and what the quota is.
  local quota=4
  case "$arm" in
    P | R) holders=("h1:$NODE_B" "h2:$NODE_B") ;;
    F) holders=("h1:$NODE_A" "h2:$NODE_B") ;;
    Q)
      holders=("h1:$NODE_B" "h2:$NODE_B")
      quota=3
      ;;
    S)
      holders=("h1:$NODE_B" "h2:$NODE_B" "h3:$NODE_A")
      quota=5
      ;;
    *)
      echo "unknown arm $arm" >&2
      return 1
      ;;
  esac

  set_quota "$quota"
  local spec
  for spec in "${holders[@]}"; do
    local hname="frag-${spec%%:*}-$slug" hnode="${spec##*:}"
    submit_holder "$hname" "$hnode" || { echo -e "$arm\t$rep\tINVALID\tholder-${HOLDER_FAILURE:-unknown}" >>"$EXDIR/results.tsv"; return 0; }
    wait_holder_running "$hname" "$hnode" || { echo -e "$arm\t$rep\tINVALID\tholder-placement" >>"$EXDIR/results.tsv"; return 0; }
  done

  headroom >"$EXDIR/headroom-before-$tag.json"
  say "headroom before target: $(cat "$EXDIR/headroom-before-$tag.json")"
  sleep 10

  sed "s|NAME_PLACEHOLDER|$target|g" "$ROOT/experiments/fragmentation/target.yaml" >"$EXDIR/$target.yaml"
  local t0
  t0="$(now)"
  k apply -f "$EXDIR/$target.yaml" >>"$EXDIR/run.log" 2>&1
  say "target $target submitted"

  # One snapshot a second for the whole window, so the classification and the CR's own phase are recorded
  # side by side at every instant rather than reconciled afterwards.
  local deadline
  deadline=$(python3 -c "print($t0 + $WINDOW)")
  : >"$EXDIR/timeline-$tag.jsonl"
  local rescued=0
  while (($(python3 -c "print(1 if $(now) < $deadline else 0)"))); do
    local snap
    snap="$(classify "$target")"
    python3 -c "
import json,sys
d=json.loads(sys.argv[1]); d['t']=round($(now)-$t0,2); print(json.dumps(d,sort_keys=True))" "$snap" \
      >>"$EXDIR/timeline-$tag.jsonl"

    # The repack arm intervenes once, 60 seconds in, and never by deleting first.
    if [[ "$arm" == "R" && "$rescued" == "0" ]] &&
      (($(python3 -c "print(1 if $(now)-$t0 > 60 else 0)"))); then
      say "R: creating the replica holder on $NODE_A before deleting the original"
      submit_holder "frag-h3-$slug" "$NODE_A" && wait_holder_running "frag-h3-$slug" "$NODE_A" || true
      say "R: middle state $(headroom)"
      sleep 10
      say "R: deleting the original holder on $NODE_B"
      k -n "$NS" delete job "frag-h2-$slug" --ignore-not-found >>"$EXDIR/run.log" 2>&1
      rescued=1
    fi
    sleep 1
  done

  # The verdict is the state that held for the window, plus whatever the CR claimed while it held.
  python3 - "$EXDIR/timeline-$tag.jsonl" "$arm" "$rep" <<'PY' | tee -a "$EXDIR/results.tsv"
import collections
import json
import sys

path, arm, rep = sys.argv[1], sys.argv[2], sys.argv[3]
rows = [json.loads(line) for line in open(path)]
states = collections.Counter(r["state"] for r in rows)
final = rows[-1]["state"] if rows else "none"
# H4: what did the CR say while no Pod was scheduled?
lying = sum(1 for r in rows if r["state"] in ("fragmentation", "aggregate-shortage")
            and r.get("cr_phase") == "Running")
print("\t".join([arm, rep, final,
                 ",".join(f"{k}={v}" for k, v in states.most_common()),
                 f"cr_said_running_while_unscheduled={lying}s"]))
PY
}

study() {
  printf 'arm\trep\tfinal_state\tstate_seconds\th4\n' >"$EXDIR/results.tsv"
  # Counterbalanced: each arm appears once in every position.
  local blocks=("P F Q S R" "F Q S R P" "Q S R P F" "S R P F Q" "R P F Q S")
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

fixture() {
  say "applying namespace, ResourceFlavor, ClusterQueue and LocalQueue"
  k apply -f "$ROOT/experiments/fragmentation/fixture.yaml" >>"$EXDIR/run.log" 2>&1
  local deadline=$((SECONDS + 120))
  while ((SECONDS < deadline)); do
    [[ "$(k get clusterqueue frag -o jsonpath='{.status.conditions[?(@.type=="Active")].status}' 2>/dev/null)" == "True" ]] &&
      {
        say "ClusterQueue frag is Active"
        return 0
      }
    sleep 3
  done
  say "ClusterQueue frag did not become Active within 120s"
  exit 1
}

teardown() {
  say "removing the experiment"
  k -n "$NS" delete mltrainingjob --all --ignore-not-found >>"$EXDIR/run.log" 2>&1 || true
  k -n "$NS" delete job --all --ignore-not-found >>"$EXDIR/run.log" 2>&1 || true
  k -n "$NS" delete localqueue frag --ignore-not-found >>"$EXDIR/run.log" 2>&1 || true
  k delete clusterqueue frag --ignore-not-found >>"$EXDIR/run.log" 2>&1 || true
  k delete resourceflavor frag --ignore-not-found >>"$EXDIR/run.log" 2>&1 || true
  k delete namespace "$NS" --ignore-not-found >>"$EXDIR/run.log" 2>&1 || true
  say "teardown complete"
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
  EXDIR="${EXDIR:-ex/frag-$(date -u +%Y%m%dT%H%M%SZ)}"
  mkdir -p "$EXDIR"
  trap release_lock EXIT

  "$cmd" "$@"
}

main "$@"
