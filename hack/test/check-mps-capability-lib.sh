#!/usr/bin/env bash
#
# Checks hack/lib/mps-capability.sh's instruments for B0 to B3 with kubectl replaced by a stub, and every journal they
# write judged by the real `benchharness mps-capability-verdict`, without a cluster, a card or money.
#
#   bash hack/test/check-mps-capability-lib.sh
#
# The stub answers from rules: each line of $STUB/rules is a shell glob over kubectl's arguments, then one or more
# answer files separated by '|', taken in turn on successive matching calls with the last repeated, then an exit code.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

fails=0
ok() { echo "ok: $*"; }
bad() { echo "FAIL: $*"; fails=$((fails + 1)); }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

go build -o "$work/benchharness" ./cmd/benchharness || { echo "check-mps-capability-lib: could not build benchharness"; exit 1; }
mkdir -p "$work/bin"
cat >"$work/bin/kubectl" <<'EOF'
#!/usr/bin/env python3
import fnmatch, os, sys
stub = os.environ["STUB"]
args = " ".join(sys.argv[1:])
with open(os.path.join(stub, "calls.log"), "a") as f:
    f.write(args + "\n")
for i, line in enumerate(open(os.path.join(stub, "rules"))):
    line = line.rstrip("\n")
    if not line:
        continue
    glob, files, rc = line.split("\t")
    if fnmatch.fnmatchcase(args, glob):
        counter = os.path.join(stub, f"count.{i}")
        n = int(open(counter).read()) if os.path.exists(counter) else 0
        open(counter, "w").write(str(n + 1))
        seq = files.split("|")
        name = seq[min(n, len(seq) - 1)]
        if name != "-":
            sys.stdout.write(open(os.path.join(stub, name)).read())
        sys.exit(int(rc))
sys.stderr.write("stub kubectl: no rule for: " + args + "\n")
sys.exit(97)
EOF
chmod +x "$work/bin/kubectl"
export PATH="$work/bin:$PATH" MPSCAP_CTX=ctx MPSCAP_POLL=0
# shellcheck source=hack/lib/mps-journal.sh
source hack/lib/mps-journal.sh
# shellcheck source=hack/lib/mps-capability.sh
source hack/lib/mps-capability.sh

case_n=0
scenario() {
  case_n=$((case_n + 1))
  STUB="$work/s$case_n"
  MPSCAP_OUT="$STUB/out"
  MPS_JOURNAL="$STUB/journal.jsonl"
  export STUB MPSCAP_OUT MPS_JOURNAL
  mkdir -p "$MPSCAP_OUT"
  : >"$STUB/rules"
}
# rule GLOB FILES [RC]
rule() { printf '%s\t%s\t%s\n' "$1" "$2" "${3:-0}" >>"$STUB/rules"; }
put() { printf '%s\n' "$2" >"$STUB/$1"; }
# result BAR: the bar's state as the real classifier reads this case's journal.
result() { "$work/benchharness" mps-capability-verdict --journal "$MPS_JOURNAL" 2>&1 | awk -v b="$1" '$1 == b { print $2 }'; }
detail() { python3 -c 'import json,sys
for l in open(sys.argv[1]):
    r = json.loads(l)
    if r.get("bar") == sys.argv[2] and r.get("state") == "decided": print(r.get("detail", ""))' "$MPS_JOURNAL" "$1"; }
fact() { python3 -c 'import json,sys
for l in open(sys.argv[1]):
    r = json.loads(l)
    if r.get("type") == "fact" and r.get("name") == sys.argv[2]: print(str(r["value"]).lower())' "$MPS_JOURNAL" "$1"; }
expect() { # NAME BAR WANT [NEEDLE]
  local got d
  got="$(result "$2")"
  d="$(detail "$2")"
  if [[ "$got" != "$3" ]]; then bad "$1: $2 is ${got:-missing}, want $3 ($d)"; return; fi
  if [[ -n "${4:-}" && "$d" != *"$4"* ]]; then bad "$1: $2's detail has no '$4': $d"; return; fi
  ok "$1: $2 $got"
}

# --- B0 and B1 ---------------------------------------------------------------------------------------------------
plugin_pod() { # component name uid phase restarts [deleting]
  local del=""
  [[ -n "${6:-}" ]] && del=', "deletionTimestamp": "2026-10-24T00:00:00Z"'
  printf '{"metadata": {"name": "%s", "uid": "%s", "labels": {"app.kubernetes.io/component": "%s"}%s}, "status": {"phase": "%s", "containerStatuses": [{"restartCount": %s}]}}' \
    "$2" "$3" "$1" "$del" "$4" "$5"
}
items() { local IFS=,; echo "{\"items\": [$*]}"; }
healthy="$(items "$(plugin_pod nvidia-device-plugin-mps-plugin plug-1 u-plug Running 0)" "$(plugin_pod nvidia-mps-control-daemon mpsd-1 u-mpsd Running 0)")"
sharing_node() { printf '{"items": [{"metadata": {"name": "m5cgpu-worker"}, "status": {"allocatable": {"nvidia.com/gpu": "%s"}}}]}' "$1"; }

scenario
put pods "$healthy"; put node "$(sharing_node 2)"
rule "*get pods -n gpu-platform-control-plane-system*" pods; rule "*get nodes*" node
mpscap_b0_b1 && ok "B1 passing returns 0" || bad "B1 passing returned non-zero"
expect "both alive and two advertised" B0 pass "u-plug"
expect "both alive and two advertised" B1 pass "nvidia.com/gpu 2"
grep -q -- "--context ctx" "$STUB/calls.log" && ok "the instruments ask the session's context" || bad "the context was not passed: $(head -1 "$STUB/calls.log")"

scenario
put pods "$healthy"; put node "$(sharing_node 0)"
rule "*get pods -n gpu-platform-control-plane-system*" pods; rule "*get nodes*" node
mpscap_b0_b1 && bad "B1 failing returned 0, so the session would go on past the stopping rule" || ok "B1 failing returns non-zero"
expect "zero advertised" B1 fail "nvidia.com/gpu 0"
scenario
put pods "$healthy"; put node "$(sharing_node 4)"
rule "*get pods -n gpu-platform-control-plane-system*" pods; rule "*get nodes*" node
mpscap_b0_b1
expect "four advertised: exactly two, not at least" B1 fail "nvidia.com/gpu 4"
scenario
put pods "$healthy"; put err "error: You must be logged in to the server (Unauthorized)"
rule "*get pods -n gpu-platform-control-plane-system*" pods; rule "*get nodes*" err 1
mpscap_b0_b1
expect "an unreadable node is not zero" B1 unmeasured "Unauthorized"
scenario
put before "$healthy"
put after "$(items "$(plugin_pod nvidia-device-plugin-mps-plugin plug-1 u-plug Running 1)" "$(plugin_pod nvidia-mps-control-daemon mpsd-1 u-mpsd Running 0)")"
put node "$(sharing_node 2)"
rule "*get pods -n gpu-platform-control-plane-system*" "before|after"; rule "*get nodes*" node
mpscap_b0_b1
expect "a restart while the node was read" B0 fail "restarted 1 time"
expect "the advertisement itself still read" B1 pass
scenario
put before "$healthy"
put after "$(items "$(plugin_pod nvidia-device-plugin-mps-plugin plug-2 u-plug2 Running 0)" "$(plugin_pod nvidia-mps-control-daemon mpsd-1 u-mpsd Running 0)")"
put node "$(sharing_node 2)"
rule "*get pods -n gpu-platform-control-plane-system*" "before|after"; rule "*get nodes*" node
mpscap_b0_b1
expect "a replaced plugin Pod" B0 fail "replaced"
scenario
# CrashLoopBackOff is a container's waiting reason, not a phase: the Pod stays Running and its restarts climb, which is
# why a rollout wait could pass it.
put pods "$(items "$(plugin_pod nvidia-device-plugin-mps-plugin plug-1 u-plug Running 6)" "$(plugin_pod nvidia-mps-control-daemon mpsd-1 u-mpsd Running 0)")"
put node "$(sharing_node 0)"
rule "*get pods -n gpu-platform-control-plane-system*" pods; rule "*get nodes*" node
mpscap_b0_b1
expect "the eighth pilot's crash-looping plugin" B0 fail "restarted 6"
scenario
put pods "$(items "$(plugin_pod nvidia-device-plugin-mps-plugin plug-1 u-plug Running 0)")"
put node "$(sharing_node 2)"
rule "*get pods -n gpu-platform-control-plane-system*" pods; rule "*get nodes*" node
mpscap_b0_b1
expect "no control daemon" B0 fail "nvidia-mps-control-daemon: 0 Pod(s)"
# An old plugin Pod still live beside its replacement: which one advertised cannot be told.
scenario
put pods "$(items "$(plugin_pod nvidia-device-plugin-mps-plugin plug-1 u-plug Running 0)" "$(plugin_pod nvidia-device-plugin-mps-plugin plug-2 u-plug2 Running 0)" "$(plugin_pod nvidia-mps-control-daemon mpsd-1 u-mpsd Running 0)")"
put node "$(sharing_node 2)"
rule "*get pods -n gpu-platform-control-plane-system*" pods; rule "*get nodes*" node
mpscap_b0_b1
expect "two live plugin Pods" B0 fail "nvidia-device-plugin-mps-plugin: 2 Pod(s)"
scenario
put pods "$(items "$(plugin_pod nvidia-device-plugin-mps-plugin plug-1 u-plug Running 0)" "$(plugin_pod nvidia-mps-control-daemon mpsd-1 u-mpsd Running 0 deleting)")"
put node "$(sharing_node 2)"
rule "*get pods -n gpu-platform-control-plane-system*" pods; rule "*get nodes*" node
mpscap_b0_b1
expect "a terminating daemon" B0 fail "being deleted"
scenario
put pods '{"items": [{"metadata": {"name": "plug-1", "uid": "u-plug", "labels": {"app.kubernetes.io/component": "nvidia-device-plugin-mps-plugin"}}, "status": {"phase": "Running"}}, {"metadata": {"name": "mpsd-1", "uid": "u-mpsd", "labels": {"app.kubernetes.io/component": "nvidia-mps-control-daemon"}}, "status": {"phase": "Running", "containerStatuses": [{"restartCount": 0}]}}]}'
put node "$(sharing_node 2)"
rule "*get pods -n gpu-platform-control-plane-system*" pods; rule "*get nodes*" node
mpscap_b0_b1
expect "no container status is unknown, not zero restarts" B0 unmeasured "no container status"

# --- B2 ----------------------------------------------------------------------------------------------------------
engine_pod() { # name uid phase [waiting-reason]
  local w=""
  [[ -n "${4:-}" ]] && w=", \"containerStatuses\": [{\"state\": {\"waiting\": {\"reason\": \"$4\"}}}]"
  printf '{"items": [{"metadata": {"name": "%s", "uid": "%s"}, "status": {"phase": "%s"%s}}]}' "$1" "$2" "$3" "$w"
}
event() { printf '{"items": [{"reason": "%s", "message": "%s"}]}' "$1" "$2"; }
no_events='{"items": []}'
b2_rules() {
  rule "*get pods -n m5c-a *" "$1"; rule "*get pods -n m5c-b *" "$2"
  rule "*get events -n m5c-a *" "$3"; rule "*get events -n m5c-b *" "$4"
}

scenario
put a "$(engine_pod eng-a ua Running)"; put b "$(engine_pod eng-b ub Running)"; put none "$no_events"
b2_rules a b none none
uids="$(mpscap_b2 m5c-a m5c-b $(( $(date +%s) + 60 )))" && ok "a Running pair returns 0" || bad "a Running pair returned non-zero"
expect "both Running" B2 pass "uid ua Running"
[[ "$uids" == "ua ub" ]] && ok "the pair's UIDs are printed for B3 and B4" || bad "printed '$uids', not the two UIDs"
[[ "$(fact no_healthy_devices_event)" == false && "$(fact images_pulled)" == true && "$(fact schedulable)" == true ]] &&
  ok "a Running pair records no refusal, pulled images and scheduled Pods" || bad "facts: $(grep fact "$MPS_JOURNAL")"

scenario
put pend "$(engine_pod eng-a ua Pending)"; put a "$(engine_pod eng-a ua Running)"; put b "$(engine_pod eng-b ub Running)"; put none "$no_events"
b2_rules "pend|pend|a" b none none
mpscap_b2 m5c-a m5c-b $(( $(date +%s) + 60 )) >/dev/null
expect "engine a Running on the third poll" B2 pass
scenario
put a "$(engine_pod eng-a ua Failed)"; put b "$(engine_pod eng-b ub Running)"; put none "$no_events"
put refused "$(event UnexpectedAdmissionError 'Allocate failed due to no healthy devices present; cannot allocate unhealthy devices nvidia.com/gpu')"
b2_rules a b refused none
mpscap_b2 m5c-a m5c-b $(( $(date +%s) + 60 )) >/dev/null && bad "a refused device returned 0" || ok "a refused device returns non-zero"
expect "the kubelet refused the device" B2 fail "no healthy devices"
[[ "$(fact no_healthy_devices_event)" == true ]] && ok "the refusal is recorded as a fact" || bad "the refusal fact is $(fact no_healthy_devices_event)"
# The event decides B2 even when both Pods end up Running: the bar says no such event on either.
scenario
put a "$(engine_pod eng-a ua Running)"; put b "$(engine_pod eng-b ub Running)"; put none "$no_events"
put refused "$(event UnexpectedAdmissionError 'Allocate failed due to no healthy devices present')"
b2_rules a b none refused
mpscap_b2 m5c-a m5c-b $(( $(date +%s) + 60 )) >/dev/null
expect "a refusal before both ran" B2 fail "no healthy devices"
scenario
put a "$(engine_pod eng-a ua Pending ImagePullBackOff)"; put b "$(engine_pod eng-b ub Pending)"; put none "$no_events"
b2_rules a b none none
mpscap_b2 m5c-a m5c-b $(( $(date +%s) - 1 )) >/dev/null
expect "an image that did not pull, at the deadline" B2 fail "not both Running"
[[ "$(fact images_pulled)" == false ]] && ok "an image pull failure is recorded, which makes the run INVALID" || bad "images_pulled is $(fact images_pulled)"
"$work/benchharness" mps-capability-verdict --journal "$MPS_JOURNAL" | grep -q "images_pulled is false" && ok "the classifier reads the pull failure" || bad "the classifier did not read the pull failure"
scenario
put a "$(engine_pod eng-a ua Pending)"; put b "$(engine_pod eng-b ub Pending)"; put none "$no_events"
put sched "$(event FailedScheduling '0/2 nodes are available: 1 node(s) had untolerated taint')"
b2_rules a b sched none
mpscap_b2 m5c-a m5c-b $(( $(date +%s) - 1 )) >/dev/null
[[ "$(fact schedulable)" == false ]] && ok "a Pod unschedulable for a taint is recorded" || bad "schedulable is $(fact schedulable)"
scenario
put a "$(engine_pod eng-a ua Pending)"; put b "$(engine_pod eng-b ub Pending)"; put none "$no_events"
put sched "$(event FailedScheduling '0/2 nodes are available: 2 Insufficient nvidia.com/gpu')"
b2_rules a b sched none
mpscap_b2 m5c-a m5c-b $(( $(date +%s) - 1 )) >/dev/null
[[ -z "$(fact schedulable)" ]] && ok "unschedulable for want of the device is not a broken apparatus" || bad "schedulable was recorded as $(fact schedulable)"
# A transient scheduling event before both Pods ran must not make a working run INVALID.
scenario
put a "$(engine_pod eng-a ua Running)"; put b "$(engine_pod eng-b ub Running)"; put none "$no_events"
put sched "$(event FailedScheduling '0/2 nodes are available: 1 node(s) had untolerated taint')"
b2_rules a b sched none
mpscap_b2 m5c-a m5c-b $(( $(date +%s) + 60 )) >/dev/null
[[ "$(fact schedulable)" == true ]] && ok "a scheduling wait that resolved leaves schedulable true" || bad "schedulable is $(fact schedulable)"
scenario
put a "$(engine_pod eng-a ua Running)"; put b "$(engine_pod eng-b ub Running)"; put err "error: the server was unable to return a response"
b2_rules a b err err
# Both event reads fail, with exit 1.
python3 - "$STUB/rules" <<'PY'
import sys
p = sys.argv[1]
lines = open(p).read().splitlines()
open(p, "w").write("\n".join(l[:-1] + "1" if "get events" in l else l for l in lines) + "\n")
PY
mpscap_b2 m5c-a m5c-b $(( $(date +%s) - 1 )) >/dev/null
expect "events that could not be read are not no events" B2 unmeasured "could not be read"
[[ -z "$(fact no_healthy_devices_event)" ]] && ok "no refusal fact is recorded from unread events" || bad "a refusal fact came from unread events: $(fact no_healthy_devices_event)"
scenario
put a '{"items": [{"metadata": {"name": "eng-a", "uid": "ua"}, "status": {"phase": "Running"}}, {"metadata": {"name": "eng-a2", "uid": "ua2"}, "status": {"phase": "Running"}}]}'
put b "$(engine_pod eng-b ub Running)"; put none "$no_events"
b2_rules a b none none
mpscap_b2 m5c-a m5c-b $(( $(date +%s) - 1 )) >/dev/null
expect "two live Pods for one engine" B2 fail "2 live Pod(s)"

# --- B3 ----------------------------------------------------------------------------------------------------------
b3_rules() { # probe-a rc-a probe-b rc-b [ipc-a]
  put name-a eng-a; put name-b eng-b; put ipc-a "${5:-true}"; put ipc-b true; put probe-a "$1"; put probe-b "$3"
  rule "*get pods -n m5c-a -o jsonpath*" name-a; rule "*get pods -n m5c-b -o jsonpath*" name-b
  rule "*get pod -n m5c-a eng-a -o jsonpath*hostIPC*" ipc-a; rule "*get pod -n m5c-b eng-b -o jsonpath*hostIPC*" ipc-b
  rule "*exec -n m5c-a eng-a*" probe-a "$2"; rule "*exec -n m5c-b eng-b*" probe-b "$4"
}
client="PIPE=/tmp/nvidia-mps DIR=present CONTROL=yes"
scenario
b3_rules "$client" 0 "$client" 0
mpscap_b3 m5c-a ua m5c-b ub && ok "two clients return 0" || bad "two clients returned non-zero"
expect "both are MPS clients" B3 pass "CONTROL=yes"
grep -q 'uid==\\"ua\\"\|uid=="ua"' "$STUB/calls.log" && ok "the Pod is found by the UID B2 decided on" || bad "the Pod was not looked up by UID: $(grep jsonpath "$STUB/calls.log" | head -1)"
scenario
b3_rules "PIPE=unset" 0 "$client" 0
mpscap_b3 m5c-a ua m5c-b ub
expect "engine a has no pipe variable" B3 fail "PIPE=unset"
grep -q "exec -n m5c-b" "$STUB/calls.log" && ok "engine b is probed after engine a failed" || bad "engine b was not probed after engine a failed"
scenario
b3_rules "PIPE=/tmp/nvidia-mps DIR=present CONTROL=no" 0 "$client" 0
mpscap_b3 m5c-a ua m5c-b ub
expect "a pipe directory with no socket" B3 fail "CONTROL=no"
scenario
b3_rules "error: unable to upgrade connection" 1 "$client" 0
mpscap_b3 m5c-a ua m5c-b ub
expect "a probe that could not run is not a missing socket" B3 unmeasured "could not run"
scenario
b3_rules "error: unable to upgrade connection" 1 "PIPE=unset" 0
mpscap_b3 m5c-a ua m5c-b ub
expect "a measured failure outranks an unmeasured probe" B3 fail "PIPE=unset"
scenario
b3_rules "$client" 0 "$client" 0 false
mpscap_b3 m5c-a ua m5c-b ub
expect "a Pod outside the host IPC namespace" B3 fail "hostIPC is false"
scenario
b3_rules "$client" 0 "$client" 0
put name-a ""
mpscap_b3 m5c-a ua m5c-b ub
expect "the Pod B2 decided on is gone" B3 fail "is gone"

if [[ $fails -ne 0 ]]; then
  echo "check-mps-capability-lib: $fails failure(s)"
  exit 1
fi
echo "check-mps-capability-lib: all checks passed"
