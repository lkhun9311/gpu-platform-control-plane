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
engine_pod() { # name uid phase [waiting-reason] [unscheduled-message]
  local w="" c=""
  [[ -n "${4:-}" ]] && w=", \"containerStatuses\": [{\"state\": {\"waiting\": {\"reason\": \"$4\"}}}]"
  [[ -n "${5:-}" ]] && c=", \"conditions\": [{\"type\": \"PodScheduled\", \"status\": \"False\", \"message\": \"$5\"}]"
  printf '{"items": [{"metadata": {"name": "%s", "uid": "%s"}, "status": {"phase": "%s"%s%s}}]}' "$1" "$2" "$3" "$w" "$c"
}
event() { # pod reason message
  printf '{"items": [{"involvedObject": {"kind": "Pod", "name": "%s"}, "reason": "%s", "message": "%s"}]}' "$1" "$2" "$3"
}
no_events='{"items": []}'
refusal_msg='Allocate failed due to no healthy devices present; cannot allocate unhealthy devices nvidia.com/gpu'
b2_rules() { # pods-a pods-b events-a events-b [events-rc]
  rule "*get pods -n m5c-a *" "$1"; rule "*get pods -n m5c-b *" "$2"
  rule "*get events -n m5c-a *" "$3" "${5:-0}"; rule "*get events -n m5c-b *" "$4" "${5:-0}"
}
soon() { echo $(( $(date +%s) + ${1:-60} )); }

scenario
put a "$(engine_pod vllm-shared-a-1 ua Running)"; put b "$(engine_pod vllm-shared-b-1 ub Running)"; put none "$no_events"
b2_rules a b none none
uids="$(mpscap_b2 m5c-a m5c-b "$(soon)")" && ok "a Running pair returns 0" || bad "a Running pair returned non-zero"
expect "both Running" B2 pass "uid ua Running"
[[ "$uids" == "ua ub" ]] && ok "the pair's UIDs are printed for B3 and B4" || bad "printed '$uids', not the two UIDs"
[[ "$(fact no_healthy_devices_event)" == false && "$(fact images_pulled)" == true && "$(fact schedulable)" == true ]] &&
  ok "a Running pair records no refusal, pulled images and scheduled Pods" || bad "facts: $(grep fact "$MPS_JOURNAL")"

scenario
put pend "$(engine_pod vllm-shared-a-1 ua Pending)"; put a "$(engine_pod vllm-shared-a-1 ua Running)"; put b "$(engine_pod vllm-shared-b-1 ub Running)"; put none "$no_events"
b2_rules "pend|pend|a" b none none
mpscap_b2 m5c-a m5c-b "$(soon)" >/dev/null
expect "engine a Running on the third poll" B2 pass
scenario
put a "$(engine_pod vllm-shared-a-1 ua Failed)"; put b "$(engine_pod vllm-shared-b-1 ub Running)"; put none "$no_events"
put refused "$(event vllm-shared-a-1 UnexpectedAdmissionError "$refusal_msg")"
b2_rules a b refused none
mpscap_b2 m5c-a m5c-b "$(soon)" >/dev/null && bad "a refused device returned 0" || ok "a refused device returns non-zero"
expect "the kubelet refused the device" B2 fail "no healthy devices"
[[ "$(fact no_healthy_devices_event)" == true ]] && ok "the refusal is recorded as a fact" || bad "the refusal fact is $(fact no_healthy_devices_event)"
# The event decides B2 even when both Pods end up Running: the bar says no such event on either.
scenario
put a "$(engine_pod vllm-shared-a-1 ua Running)"; put b "$(engine_pod vllm-shared-b-1 ub Running)"; put none "$no_events"
put refused "$(event vllm-shared-b-1 UnexpectedAdmissionError "$refusal_msg")"
b2_rules a b none refused
mpscap_b2 m5c-a m5c-b "$(soon)" >/dev/null
expect "a refusal before both ran" B2 fail "no healthy devices"
# codex, review of cc26b174: an event about anything but the engines' own Pods must not decide the bar.
scenario
put a "$(engine_pod vllm-shared-a-1 ua Running)"; put b "$(engine_pod vllm-shared-b-1 ub Running)"; put none "$no_events"
put other "$(event some-debug-pod UnexpectedAdmissionError "$refusal_msg")"
b2_rules a b other none
mpscap_b2 m5c-a m5c-b "$(soon)" >/dev/null
expect "a refusal about another Pod in the namespace" B2 pass
[[ "$(fact no_healthy_devices_event)" == false ]] && ok "another Pod's event is not recorded as a refusal" || bad "another Pod's event became the fact $(fact no_healthy_devices_event)"
# codex, review of cc26b174: a captured refusal is kept when the other namespace's events could not be read.
scenario
put a "$(engine_pod vllm-shared-a-1 ua Failed)"; put b "$(engine_pod vllm-shared-b-1 ub Running)"; put err "error: the server was unable to return a response"
put refused "$(event vllm-shared-a-1 UnexpectedAdmissionError "$refusal_msg")"
rule "*get pods -n m5c-a *" a; rule "*get pods -n m5c-b *" b; rule "*get events -n m5c-a *" refused; rule "*get events -n m5c-b *" err 1
mpscap_b2 m5c-a m5c-b "$(soon)" >/dev/null
expect "a refusal read beside unreadable events" B2 fail "no healthy devices"
[[ "$(fact no_healthy_devices_event)" == true ]] && ok "the refusal fact is kept though one event read failed" || bad "the refusal fact is '$(fact no_healthy_devices_event)'"
# codex, review of cc26b174: a phase that ran out leaves B2 interrupted, never decided.
scenario
put a "$(engine_pod vllm-shared-a-1 ua Pending)"; put b "$(engine_pod vllm-shared-b-1 ub Pending)"; put none "$no_events"
b2_rules a b none none
mpscap_b2 m5c-a m5c-b "$(soon 1)" >/dev/null 2>&1
expect "Pods still Pending when the phase ran out" B2 interrupted
scenario
put a "$(engine_pod vllm-shared-a-1 ua Running)"; put b "$(engine_pod vllm-shared-b-1 ub Running)"; put none "$no_events"
b2_rules a b none none
mpscap_b2 m5c-a m5c-b "$(( $(date +%s) - 1 ))" >/dev/null 2>&1 && bad "a B2 called after its deadline returned 0" || ok "a B2 called after its deadline returns non-zero"
expect "a Running pair seen only after the deadline" B2 interrupted
scenario
put a "$(engine_pod vllm-shared-a-1 ua Pending ImagePullBackOff)"; put b "$(engine_pod vllm-shared-b-1 ub Pending)"; put none "$no_events"
b2_rules a b none none
mpscap_b2 m5c-a m5c-b "$(soon 1)" >/dev/null 2>&1
expect "an image still failing to pull at the deadline" B2 interrupted
[[ "$(fact images_pulled)" == false ]] && ok "an image still failing to pull is recorded, which makes the run INVALID" || bad "images_pulled is '$(fact images_pulled)'"
"$work/benchharness" mps-capability-verdict --journal "$MPS_JOURNAL" | grep -q "images_pulled is false" && ok "the classifier reads the pull failure" || bad "the classifier did not read the pull failure"
# codex, review of cc26b174: a pull error that resolved on engine a cannot turn engine b's refusal into INVALID.
scenario
put a "$(engine_pod vllm-shared-a-1 ua Running)"; put b "$(engine_pod vllm-shared-b-1 ub Failed)"
put ev-a "$(event vllm-shared-a-1 Failed 'Failed to pull image: rpc error: context deadline exceeded')"
put ev-b "$(event vllm-shared-b-1 UnexpectedAdmissionError "$refusal_msg")"
b2_rules a b ev-a ev-b
mpscap_b2 m5c-a m5c-b "$(soon)" >/dev/null
[[ -z "$(fact images_pulled)" ]] && ok "a pull error that resolved records no failed pull" || bad "a resolved pull error recorded images_pulled $(fact images_pulled)"
scenario
put a "$(engine_pod vllm-shared-a-1 ua Pending "" '0/2 nodes are available: 1 node(s) had untolerated taint')"; put b "$(engine_pod vllm-shared-b-1 ub Pending)"; put none "$no_events"
b2_rules a b none none
mpscap_b2 m5c-a m5c-b "$(soon 1)" >/dev/null 2>&1
[[ "$(fact schedulable)" == false ]] && ok "a Pod still unschedulable for a taint is recorded" || bad "schedulable is '$(fact schedulable)'"
scenario
put a "$(engine_pod vllm-shared-a-1 ua Pending "" '0/2 nodes are available: 2 Insufficient nvidia.com/gpu')"; put b "$(engine_pod vllm-shared-b-1 ub Pending)"; put none "$no_events"
b2_rules a b none none
mpscap_b2 m5c-a m5c-b "$(soon 1)" >/dev/null 2>&1
[[ -z "$(fact schedulable)" ]] && ok "unschedulable for want of the device is not a broken apparatus" || bad "schedulable was recorded as $(fact schedulable)"
scenario
put a "$(engine_pod vllm-shared-a-1 ua Running)"; put b "$(engine_pod vllm-shared-b-1 ub Running)"; put err "error: the server was unable to return a response"
b2_rules a b err err 1
mpscap_b2 m5c-a m5c-b "$(soon 1)" >/dev/null 2>&1
expect "events never readable" B2 interrupted
[[ -z "$(fact no_healthy_devices_event)" ]] && ok "no refusal fact is recorded from unread events" || bad "a refusal fact came from unread events: $(fact no_healthy_devices_event)"
scenario
put a '{"items": [{"metadata": {"name": "vllm-shared-a-1", "uid": "ua"}, "status": {"phase": "Running"}}, {"metadata": {"name": "vllm-shared-a-2", "uid": "ua2"}, "status": {"phase": "Running"}}]}'
put b "$(engine_pod vllm-shared-b-1 ub Running)"; put none "$no_events"
b2_rules a b none none
mpscap_b2 m5c-a m5c-b "$(soon 1)" >/dev/null 2>&1
expect "two live Pods for one engine never pass" B2 interrupted

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

# --- B4: the capture, with nvidia-smi a stub and /proc a directory ------------------------------------------------
cat >"$work/bin/nvidia-smi" <<'SMI'
#!/usr/bin/env bash
case "$*" in
  *--query-compute-apps*) f=csv ;;
  "") f=table ;;
  *) f=other ;;
esac
[ -e "$STUB/smi-$f" ] && cat "$STUB/smi-$f"
[ -e "$STUB/smi-$f.rc" ] && exit "$(cat "$STUB/smi-$f.rc")"
exit 0
SMI
chmod +x "$work/bin/nvidia-smi"
ready_pods() { # ready-a ready-b
  printf '{"items": [{"metadata": {"name": "eng-a", "namespace": "m5c-a", "uid": "0b6f4c1e-2d3a-4b5c-8d9e-0f1a2b3c4d5e"}, "status": {"conditions": [{"type": "Ready", "status": "%s"}]}}, {"metadata": {"name": "eng-b", "namespace": "m5c-b", "uid": "9e8d7c6b-5a49-4382-a1b0-c9d8e7f6a5b4"}, "status": {"conditions": [{"type": "Ready", "status": "%s"}]}}]}' "$1" "$2"
}
ua=0b6f4c1e-2d3a-4b5c-8d9e-0f1a2b3c4d5e ub=9e8d7c6b-5a49-4382-a1b0-c9d8e7f6a5b4
b4_scene() { # table-rows...
  scenario
  put ready "$(ready_pods True True)"
  rule "*get pods -A -o json*" ready
  printf '%s\n' '| Processes:  |' "$@" >"$STUB/smi-table"
  printf 'pid, process_name, used_memory [MiB]\n4242, nvidia-cuda-mps-server, 28 MiB\n5151, /usr/bin/python3, 10230 MiB\n6161, /usr/bin/python3, 10230 MiB\n' >"$STUB/smi-csv"
  export MPSCAP_PROC="$STUB/proc"
  mkdir -p "$MPSCAP_PROC/4242" "$MPSCAP_PROC/5151" "$MPSCAP_PROC/6161"
  echo "0::/system.slice/nvidia-mps.scope" >"$MPSCAP_PROC/4242/cgroup"
  echo "0::/kubelet-kubepods-burstable-pod${ua//-/_}.slice/cri-containerd-a.scope" >"$MPSCAP_PROC/5151/cgroup"
  echo "0::/kubelet-kubepods-burstable-pod${ub//-/_}.slice/cri-containerd-b.scope" >"$MPSCAP_PROC/6161/cgroup"
}
server='|    0   N/A  N/A      4242      C   nvidia-cuda-mps-server     28MiB |'
c1='|    0   N/A  N/A      5151    M+C   /usr/bin/python3      10230MiB |'
c2='|    0   N/A  N/A      6161    M+C   /usr/bin/python3      10230MiB |'
b4_scene "$server" "$c1" "$c2"
mpscap_b4 "$ua" "$ub" "$work/benchharness" && ok "a captured server and two clients return 0" || bad "a passing B4 returned non-zero"
expect "one server, one client per engine" B4 pass "pid 6161 in Pod $ub"
[[ -s "$MPSCAP_OUT/b4-cgroups/5151.cgroup" && -s "$MPSCAP_OUT/b4-cgroups/4242.cgroup" ]] && ok "each listed PID's cgroup is kept as evidence" || bad "the cgroups were not copied: $(ls "$MPSCAP_OUT/b4-cgroups")"
b4_scene "$server" "$c1" '|    0   N/A  N/A      6161      C   /usr/bin/python3      10230MiB |'
mpscap_b4 "$ua" "$ub" "$work/benchharness"
expect "engine b running without MPS" B4 fail "exactly two M+C"
b4_scene "$server" "$c1" "$c2"
echo 9 >"$STUB/smi-table.rc"
mpscap_b4 "$ua" "$ub" "$work/benchharness"
expect "nvidia-smi that failed" B4 unmeasured "exited 9"
b4_scene "$server" "$c1" "$c2"
put ready "$(ready_pods True False)"
mpscap_b4 "$ua" "$ub" "$work/benchharness"
expect "engine b not Ready, so no table is taken" B4 unmeasured "is not Ready"
[[ ! -e "$MPSCAP_OUT/b4-nvidia-smi.txt" ]] && ok "no table is captured while an engine is not Ready" || bad "a table was captured while an engine was not Ready"
b4_scene "$server" "$c1" "$c2"
put notready "$(ready_pods True False)"
: >"$STUB/rules"; rule "*get pods -A -o json*" "ready|notready"
mpscap_b4 "$ua" "$ub" "$work/benchharness"
expect "an engine that stopped being Ready during the capture" B4 unmeasured "not after it"

# --- B5 ----------------------------------------------------------------------------------------------------------
scenario
row() { printf '{"arm":"mps","tenant":"%s","httpStatus":%s,"study":"mps-capability-2026-10-24"}\n' "$1" "$2"; }
{ row premium-1 200; row standard-noisy 200; } >"$STUB/raw.jsonl"
mpscap_b5_start && mpscap_b5_decide "$STUB/raw.jsonl" 0 "$work/benchharness" && ok "a clean replay returns 0" || bad "a clean replay returned non-zero"
expect "both tenants answered" B5 pass "premium-1 1, standard-noisy 1"
scenario
mpscap_b5_start; mpscap_b5_decide "$STUB/none.jsonl" 2 "$work/benchharness"
expect "a replay that wrote nothing" B5 fail "wrote no raw file"
scenario
{ row premium-1 200; row standard-noisy 503; } >"$STUB/raw.jsonl"
mpscap_b5_start; mpscap_b5_decide "$STUB/raw.jsonl" 0 "$work/benchharness"
expect "a 5xx" B5 fail "1 5xx"

# --- the diagnostics ---------------------------------------------------------------------------------------------
diag_scene() {
  scenario
  put ok "something"
  put events '{"items": []}'
  rule "*get events -A -o json*" events
  rule "*logs*--previous*" ok 1
  rule "*" ok
  printf 'pid, process_name, used_memory [MiB]\n' >"$STUB/smi-csv"
  printf '| Processes: |\n' >"$STUB/smi-table"
}
diag_scene
mpscap_diagnostics m5c-a m5c-b && ok "every required diagnostic collected returns 0" || bad "the diagnostics returned non-zero: $(cat "$MPSCAP_OUT/diag/inventory.tsv")"
[[ $(awk -F'\t' 'NR > 1' "$MPSCAP_OUT/diag/inventory.tsv" | wc -l) == 12 ]] && ok "the inventory lists all twelve commands" || bad "the inventory lists $(awk 'NR > 1' "$MPSCAP_OUT/diag/inventory.tsv" | wc -l) commands"
awk -F'\t' '$1 ~ /previous/ && $2 != 0 && $5 == "no"' "$MPSCAP_OUT/diag/inventory.tsv" | grep -q . && ok "a missing previous log is recorded and not required" || bad "the previous log's row is wrong"
[[ "$(fact no_healthy_devices_event)" == false ]] && ok "with B2 cut short, the diagnostics record that no refusal event exists" || bad "the fact is $(fact no_healthy_devices_event)"
grep -q -- "describe pods -n m5c-a" "$STUB/calls.log" && grep -q -- "logs -n gpu-platform-control-plane-system -l app.kubernetes.io/component=nvidia-mps-control-daemon" "$STUB/calls.log" &&
  ok "the engine Pods are described and the daemon's log is read" || bad "a mandatory diagnostic was not asked for"
diag_scene
put events '{"items": [{"reason": "UnexpectedAdmissionError", "message": "Allocate failed due to no healthy devices present"}]}'
mpscap_diagnostics m5c-a m5c-b
[[ "$(fact no_healthy_devices_event)" == true ]] && ok "a refusal event found only by the diagnostics is recorded" || bad "the refusal event was missed: $(fact no_healthy_devices_event)"
diag_scene
mj_fact no_healthy_devices_event false
mpscap_diagnostics m5c-a m5c-b
[[ $(grep -c no_healthy_devices_event "$MPS_JOURNAL") == 1 ]] && ok "a fact B2 already recorded is not recorded again" || bad "the fact was recorded twice"
diag_scene
: >"$STUB/rules"; rule "*describe pods -n m5c-a*" ok 1; rule "*get events -A -o json*" events; rule "*" ok
mpscap_diagnostics m5c-a m5c-b && bad "a failed describe returned 0" || ok "a required diagnostic that failed returns non-zero"
diag_scene
: >"$STUB/rules"; rule "*get events -A -o json*" ok 1; rule "*" ok
mpscap_diagnostics m5c-a m5c-b
[[ -z "$(fact no_healthy_devices_event)" ]] && ok "events that could not be read record no refusal fact either way" || bad "a fact came from unread events"

# --- the supervisor, with harmless commands and deadlines seconds away ---------------------------------------------
export MPSCAP_SUPERVISE_POLL=0.2
scenario
far=$(( $(date +%s) + 600 ))
mpscap_supervise "$far" "$far" "$far" 5 -- bash -c 'exit 7'
rc=$?
[[ "$rc" == 7 ]] && ok "a command that ends on its own returns its own status, not the supervisor's" || bad "a command exiting 7 returned $rc"
scenario
start=$(date +%s)
mpscap_supervise $(( start + 2 )) "$far" "$far" 5 -- bash -c 'echo $$ >"$MPSCAP_OUT/pid"; sleep 300' 2>"$STUB/sup.err"
rc=$?
took=$(( $(date +%s) - start ))
[[ "$rc" == 124 ]] && ok "phase 1 running out with B2 undecided stops the run" || bad "phase 1 ran out and the supervisor returned $rc"
(( took <= 10 )) && ok "it stopped within seconds of the deadline ($took s)" || bad "it took $took s to stop"
grep -q "phase 1 ran out" "$STUB/sup.err" && ok "it says which phase ran out" || bad "it did not say which phase: $(cat "$STUB/sup.err")"
child=$(cat "$MPSCAP_OUT/pid" 2>/dev/null)
sleep 0.5
[[ -n "$child" ]] && ! kill -0 "$child" 2>/dev/null && ok "the command's own process is gone, not orphaned" || bad "the command's process $child is still alive"
# A grandchild in the same group goes too, since the matrix's port-forwards and replays are its children.
scenario
mpscap_supervise $(( $(date +%s) + 2 )) "$far" "$far" 5 -- bash -c 'sleep 300 & echo $! >"$MPSCAP_OUT/grandchild"; wait' 2>/dev/null
gc=$(cat "$MPSCAP_OUT/grandchild" 2>/dev/null)
sleep 0.5
[[ -n "$gc" ]] && ! kill -0 "$gc" 2>/dev/null && ok "a grandchild of the command is stopped with it" || bad "the grandchild $gc survived"
# The TERM is what runs the matrix's cleanup, and the grace lets it finish before KILL.
scenario
mpscap_supervise $(( $(date +%s) + 2 )) "$far" "$far" 10 -- bash -c 'trap "sleep 1; echo cleaned >\"$MPSCAP_OUT/trap\"; exit 143" TERM; sleep 300 & wait' 2>/dev/null
[[ "$(cat "$MPSCAP_OUT/trap" 2>/dev/null)" == cleaned ]] && ok "the command's TERM trap ran to completion inside the grace" || bad "the TERM trap did not finish before KILL"
# A phase whose bar was decided in time does not stop the run when its deadline passes.
scenario
mj_start B2; mj_decide B2 pass "both Running"
mpscap_supervise $(( $(date +%s) - 1 )) "$far" "$far" 5 -- bash -c 'sleep 1; exit 0' 2>/dev/null
rc=$?
[[ "$rc" == 0 ]] && ok "a past deadline whose bar is decided does not stop the run" || bad "a decided phase stopped the run ($rc)"
scenario
mj_start B2; mj_decide B2 pass ok
mpscap_supervise $(( $(date +%s) - 10 )) $(( $(date +%s) + 2 )) "$far" 5 -- bash -c 'sleep 300' 2>"$STUB/sup.err"
rc=$?
[[ "$rc" == 124 ]] && grep -q "phase 2 ran out" "$STUB/sup.err" && ok "phase 2 running out with B4 undecided stops the run" || bad "phase 2: rc $rc, $(cat "$STUB/sup.err")"
unset MPSCAP_SUPERVISE_POLL

if [[ $fails -ne 0 ]]; then
  echo "check-mps-capability-lib: $fails failure(s)"
  exit 1
fi
echo "check-mps-capability-lib: all checks passed"
