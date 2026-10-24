# shellcheck shell=bash
# The MPS capability session's instruments for B0 to B3, by the 2026-10-24 amendment of
# docs/superpowers/specs/2026-09-25-can-mps-engage-on-this-card-at-all.md.
#
# Each function starts its bar in the journal (hack/lib/mps-journal.sh), reads the cluster, saves what it read under
# MPSCAP_OUT, and decides the bar as pass, fail or unmeasured.
# B4 and B5 are judged by `benchharness mps-capability-bar` (internal/bench/mps_capability_bars.go), because they
# parse a process table and replay rows; their capture is here.
#
# A kubectl that could not answer is UNMEASURED, never an empty answer: "could not ask" and "nothing there" are
# different facts, and this repository has more than once read the first as the second.
#
# Callers set MPSCAP_CTX (the kube context), MPSCAP_OUT (the evidence directory) and MPS_JOURNAL.

MPSCAP_PLUGIN_NS="${MPSCAP_PLUGIN_NS:-gpu-platform-control-plane-system}"
MPSCAP_POLL="${MPSCAP_POLL:-5}"

# The request timeout is shortened for the diagnostics, which run inside the supervisor's grace after a kill.
mpscap_k() { kubectl --context "$MPSCAP_CTX" --request-timeout="${MPSCAP_REQUEST_TIMEOUT:-20s}" "$@"; }

# mpscap_pin_hash FILE...: one hash over each file's path and contents, in the order given.
#
# The session computes it in the tree it launches from and the instance in the tree it unpacked, so equal values say
# the manifests applied are the ones registered.
mpscap_pin_hash() {
  local f
  for f in "$@"; do
    [ -f "$f" ] || { echo "missing:$f"; continue; }
    printf '%s\t%s\n' "$f" "$(sha256sum "$f" | cut -d' ' -f1)"
  done | sha256sum | cut -d' ' -f1
}

# mpscap_pin_check FACT WANT FILE...: records FACT true when the files hash to WANT and false when they hash to
# anything else; with no WANT it records nothing, so PASS stays out of reach without making the run INVALID.
mpscap_pin_check() {
  local fact="$1" want="$2" got
  shift 2
  got="$(mpscap_pin_hash "$@")"
  if [ -z "$want" ]; then
    echo "$fact: the session passed no pin, so it is not established"
    return 1
  fi
  if [ "$got" = "$want" ]; then
    mj_fact "$fact" true "$got"
    return 0
  fi
  mj_fact "$fact" false "the files hash to $got, the registered commit's to $want"
  echo "$fact: the files hash to $got, not the registered $want"
  return 1
}

# mpscap_b0_b1: the plugin and the control daemon alive, read around the node's advertisement, which must be 2.
#
# The Pods are read before and after the node, so a Pod that restarted or was replaced while the advertisement was
# read cannot lend it its credibility: B0 needs the same Pod, Running, with no restart, on both sides.
mpscap_b0_b1() {
  mj_start B0 || return 1
  mj_start B1 || return 1
  local sel="app.kubernetes.io/name=gpu-platform-control-plane" before node after verdict b0 b1
  before="$(mpscap_k get pods -n "$MPSCAP_PLUGIN_NS" -l "$sel" -o json 2>&1)" || before="UNREADABLE $before"
  node="$(mpscap_k get nodes -l platform.lkhun9311.github.io/gpu-sharing=true -o json 2>&1)" || node="UNREADABLE $node"
  after="$(mpscap_k get pods -n "$MPSCAP_PLUGIN_NS" -l "$sel" -o json 2>&1)" || after="UNREADABLE $after"
  printf '%s\n' "$before" >"$MPSCAP_OUT/b0-pods-before.json"
  printf '%s\n' "$node" >"$MPSCAP_OUT/b1-node.json"
  printf '%s\n' "$after" >"$MPSCAP_OUT/b0-pods-after.json"
  verdict="$(python3 - "$MPSCAP_OUT/b0-pods-before.json" "$MPSCAP_OUT/b1-node.json" "$MPSCAP_OUT/b0-pods-after.json" <<'PY'
import json, sys
def load(p):
    text = open(p).read()
    if text.startswith("UNREADABLE"):
        return None, text[len("UNREADABLE "):].strip()[:160]
    try:
        return json.loads(text), None
    except Exception as exc:
        return None, f"not JSON: {exc}"
before, eb = load(sys.argv[1])
node, en = load(sys.argv[2])
after, ea = load(sys.argv[3])

def b1():
    if node is None:
        return "unmeasured", f"the sharing node could not be read: {en}"
    items = node.get("items", [])
    if len(items) != 1:
        return "fail", f"{len(items)} nodes carry the sharing label, not one"
    gpus = ((items[0].get("status") or {}).get("allocatable") or {}).get("nvidia.com/gpu")
    if gpus is None:
        return "fail", f"node {items[0]['metadata']['name']} advertises no nvidia.com/gpu"
    return ("pass" if gpus == "2" else "fail"), f"node {items[0]['metadata']['name']} advertises nvidia.com/gpu {gpus}"

def pods(doc, component):
    return [p for p in doc.get("items", []) if (p["metadata"].get("labels") or {}).get("app.kubernetes.io/component") == component]

def alive(p):
    st = p.get("status") or {}
    cs = st.get("containerStatuses")
    if not cs:
        return None, "has no container status"
    restarts = sum(c.get("restartCount", 0) for c in cs)
    if p["metadata"].get("deletionTimestamp"):
        return False, "is being deleted"
    if st.get("phase") != "Running":
        return False, f"is {st.get('phase')}"
    if restarts:
        return False, f"has restarted {restarts} time(s)"
    return True, "Running with 0 restarts"

def b0():
    if before is None or after is None:
        return "unmeasured", f"the plugin Pods could not be read: {eb or ea}"
    out, unknown = [], []
    ok = True
    for comp in ("nvidia-device-plugin-mps-plugin", "nvidia-mps-control-daemon"):
        pb, pa = pods(before, comp), pods(after, comp)
        if len(pb) != 1 or len(pa) != 1:
            ok = False
            out.append(f"{comp}: {len(pb)} Pod(s) before the node read and {len(pa)} after, not one")
            continue
        if pb[0]["metadata"]["uid"] != pa[0]["metadata"]["uid"]:
            ok = False
            out.append(f"{comp}: the Pod was replaced while the node was read")
            continue
        for when, p in (("before", pb[0]), ("after", pa[0])):
            good, why = alive(p)
            if good is None:
                unknown.append(f"{comp} {p['metadata']['name']} {why} {when} the node read")
            elif not good:
                ok = False
                out.append(f"{comp} {p['metadata']['name']} {why} {when} the node read")
        out.append(f"{comp} {pb[0]['metadata']['name']} uid {pb[0]['metadata']['uid']}")
    if not ok:
        return "fail", "; ".join(out)
    if unknown:
        return "unmeasured", "; ".join(unknown)
    return "pass", "; ".join(out)

r0, d0 = b0()
r1, d1 = b1()
print(f"{r0}\t{d0}")
print(f"{r1}\t{d1}")
PY
)" || verdict=$'unmeasured\tthe B0 judgement did not run\nunmeasured\tthe B1 judgement did not run'
  b0="$(sed -n 1p <<<"$verdict")"
  b1="$(sed -n 2p <<<"$verdict")"
  mj_decide B0 "${b0%%$'\t'*}" "${b0#*$'\t'}"
  mj_decide B1 "${b1%%$'\t'*}" "${b1#*$'\t'}"
  # The stopping rule: B1 failed ends the session rather than retrying with other plugin settings.
  [ "${b1%%$'\t'*}" = pass ]
}

# mpscap_b2 NS_A NS_B DEADLINE_EPOCH: both engine Pods Running, with no "no healthy devices" event on either, polled
# until the phase deadline.
#
# The Pods are told apart by UID, so a Pod replaced during the wait is the new one and not a stale read; their UIDs
# are printed on success, for B3 and B4 to probe the same Pods.
# Only events about the engines' own Pods count, so an event about anything else in the namespace cannot fail the bar.
# An observation completed after the deadline decides nothing: the amendment leaves a phase that ran out with its bar
# interrupted, so B2 is then left started and undecided, whatever the last poll saw.
# Three facts are recorded here because only here are they seen:
# - whether the kubelet refused the device, recorded true whenever such an event was read and false only when both
#   namespaces' events were read and neither had one;
# - whether an image is failing to pull, and whether a Pod cannot be scheduled for a reason that is not the device,
#   read from each Pod's current state rather than its history, so an error that resolved on one engine cannot make
#   a run INVALID that the other engine's refusal makes REFUSED.
mpscap_b2() {
  local ns_a="$1" ns_b="$2" deadline="$3" sel="app.kubernetes.io/component=vllm-shared" verdict="" pa pb ev result=""
  mj_start B2 || return 1
  while [ "$(date +%s)" -lt "$deadline" ]; do
    pa="$(mpscap_k get pods -n "$ns_a" -l "$sel" -o json 2>&1)" || pa="UNREADABLE $pa"
    pb="$(mpscap_k get pods -n "$ns_b" -l "$sel" -o json 2>&1)" || pb="UNREADABLE $pb"
    printf '%s\n' "$pa" >"$MPSCAP_OUT/b2-pods-a.json"
    printf '%s\n' "$pb" >"$MPSCAP_OUT/b2-pods-b.json"
    ev="$(mpscap_k get events -n "$ns_a" -o json 2>&1)" || ev="UNREADABLE $ev"
    printf '%s\n' "$ev" >"$MPSCAP_OUT/b2-events-a.json"
    ev="$(mpscap_k get events -n "$ns_b" -o json 2>&1)" || ev="UNREADABLE $ev"
    printf '%s\n' "$ev" >"$MPSCAP_OUT/b2-events-b.json"
    verdict="$(python3 - "$MPSCAP_OUT" <<'PY'
import json, os, sys
out = sys.argv[1]
def load(name):
    text = open(os.path.join(out, name)).read()
    if text.startswith("UNREADABLE"):
        return None
    try:
        return json.loads(text)
    except Exception:
        return None
docs = {k: load(f"b2-{k}.json") for k in ("pods-a", "pods-b", "events-a", "events-b")}
# The engines' Deployments are vllm-shared-a and vllm-shared-b, so their Pods' names start with this.
def ours(e):
    o = e.get("involvedObject") or {}
    return o.get("kind") == "Pod" and o.get("name", "").startswith("vllm-shared-")
events = [e for k in ("events-a", "events-b") if docs[k] for e in docs[k].get("items", []) if ours(e)]
refused = any("no healthy devices" in (e.get("message") or "") for e in events)
events_read = docs["events-a"] is not None and docs["events-b"] is not None
state, uids, pulling, unscheduled = [], [], False, False
running = True
for k in ("pods-a", "pods-b"):
    d = docs[k]
    if d is None:
        running = False
        state.append(f"{k}: unreadable")
        continue
    current = [p for p in d.get("items", []) if not p["metadata"].get("deletionTimestamp")]
    # Every current Pod is read for these two, before the count below can skip any: a refused Pod left Failed beside
    # its replacement must not hide the replacement's failure to pull (codex, review of ab6d3b1a).
    for p in current:
        st = p.get("status") or {}
        waiting = [((c.get("state") or {}).get("waiting") or {}).get("reason") for c in st.get("containerStatuses") or []]
        if any(w in ("ErrImagePull", "ImagePullBackOff") for w in waiting):
            pulling = True
        for c in st.get("conditions") or []:
            if c.get("type") == "PodScheduled" and c.get("status") == "False" and "nvidia.com/gpu" not in (c.get("message") or ""):
                unscheduled = True
    # A Pod that has ended is not one of the pair; the engine is its live replacement.
    live = [p for p in current if (p.get("status") or {}).get("phase") not in ("Failed", "Succeeded")]
    if len(live) != 1:
        running = False
        state.append(f"{k}: {len(live)} live Pod(s)")
        continue
    p = live[0]
    st = p.get("status") or {}
    phase = st.get("phase")
    waiting = [((c.get("state") or {}).get("waiting") or {}).get("reason") for c in st.get("containerStatuses") or []]
    state.append(f"{k}: {p['metadata']['name']} uid {p['metadata']['uid']} {phase}" + (f" waiting {','.join(w for w in waiting if w)}" if any(waiting) else ""))
    uids.append(p["metadata"]["uid"])
    if phase != "Running":
        running = False
facts = f"refused={int(refused)} pulling={int(pulling)} unscheduled={int(unscheduled)} events_read={int(events_read)}"
detail = "; ".join(state)
if refused:
    print(f"fail\t{detail}; a no healthy devices event about an engine Pod was recorded\t{facts}\t")
elif running and len(uids) == 2 and events_read:
    print(f"pass\t{detail}\t{facts}\t{' '.join(uids)}")
else:
    print(f"wait\t{detail}\t{facts}\t")
PY
)" || verdict=$'wait\tthe B2 judgement did not run\trefused=0 pulling=0 unscheduled=0 events_read=0\t'
    # An observation that ended after the deadline is not inside the phase, so it decides nothing.
    if [ "$(date +%s)" -gt "$deadline" ]; then break; fi
    result="${verdict%%$'\t'*}"
    [ "$result" = wait ] || break
    result=""
    sleep "$MPSCAP_POLL"
  done
  # The first field is the poll's own result, already in $result unless the deadline overrode it.
  local detail facts uids
  IFS=$'\t' read -r _ detail facts uids <<<"$verdict"
  case "$facts" in
    *refused=1*) mj_fact no_healthy_devices_event true "$detail" ;;
    *events_read=1*) mj_fact no_healthy_devices_event false ;;
  esac
  case "$result" in
    pass)
      mj_decide B2 pass "$detail"
      # Both Pods ran, so whatever an image or the scheduler did on the way did not stop the arrangement.
      mj_fact images_pulled true
      mj_fact schedulable true
      printf '%s\n' "$uids"
      return 0 ;;
    fail) mj_decide B2 fail "$detail" ;;
    *) echo "B2 ran out of its phase with ${detail:-no observation}; it is left interrupted" >&2 ;;
  esac
  case "$facts" in *pulling=1*) mj_fact images_pulled false "$detail" ;; esac
  case "$facts" in *unscheduled=1*) mj_fact schedulable false "$detail" ;; esac
  return 1
}

# mpscap_b3 NS_A UID_A NS_B UID_B: each engine Pod a real MPS client, by its own account.
#
# Both Pods are probed even when the first fails, so the record says what each one was. A probe that could not run
# is unmeasured; one that ran and found no variable, no directory or no socket is a failure.
mpscap_b3() {
  local ns uid pod probe rc ipc lines=() results=() i
  mj_start B3 || return 1
  for i in 1 2; do
    if [ "$i" = 1 ]; then ns="$1" uid="$2"; else ns="$3" uid="$4"; fi
    pod="$(mpscap_k get pods -n "$ns" -o jsonpath="{range .items[?(@.metadata.uid==\"$uid\")]}{.metadata.name}{end}" 2>&1)" || {
      results+=(unmeasured); lines+=("$ns: the Pod could not be looked up: ${pod:0:160}"); continue; }
    if [ -z "$pod" ]; then results+=(fail); lines+=("$ns: the Pod B2 decided on (uid $uid) is gone"); continue; fi
    ipc="$(mpscap_k get pod -n "$ns" "$pod" -o jsonpath='{.spec.hostIPC}' 2>&1)" || {
      results+=(unmeasured); lines+=("$ns/$pod: hostIPC could not be read: ${ipc:0:160}"); continue; }
    if [ "$ipc" != true ]; then results+=(fail); lines+=("$ns/$pod: hostIPC is ${ipc:-absent}, so it cannot reach the daemon's pipe"); continue; fi
    # Single-quoted on purpose: the variables expand inside the Pod, which is the environment being asked about.
    # shellcheck disable=SC2016
    probe="$(mpscap_k exec -n "$ns" "$pod" -- sh -c '
      pipe="${CUDA_MPS_PIPE_DIRECTORY:-unset}"
      if [ "$pipe" = "unset" ]; then echo "PIPE=unset"; exit 0; fi
      if [ ! -d "$pipe" ]; then echo "PIPE=$pipe DIR=missing"; exit 0; fi
      sock=no
      for candidate in "$pipe"/control "$pipe"/nvidia-mps/control; do [ -S "$candidate" ] && sock=yes && break; done
      echo "PIPE=$pipe DIR=present CONTROL=$sock"' 2>&1)"
    rc=$?
    printf '%s\n' "$probe" >"$MPSCAP_OUT/b3-probe-$ns.txt"
    if [ "$rc" != 0 ]; then results+=(unmeasured); lines+=("$ns/$pod: the probe could not run (exit $rc): ${probe:0:160}"); continue; fi
    case "$probe" in
      *CONTROL=yes*) results+=(pass); lines+=("$ns/$pod: $probe") ;;
      *PIPE=unset* | *DIR=missing* | *CONTROL=no*) results+=(fail); lines+=("$ns/$pod: $probe") ;;
      *) results+=(unmeasured); lines+=("$ns/$pod: the probe answered '${probe:0:120}'") ;;
    esac
  done
  local result=pass detail
  detail="$(printf '%s; ' "${lines[@]}")"
  # A measured failure outranks an unmeasured probe: one engine seen not to be a client is a failed bar.
  case " ${results[*]} " in
    *" fail "*) result=fail ;;
    *" unmeasured "*) result=unmeasured ;;
  esac
  mj_decide B3 "$result" "${detail%; }"
  [ "$result" = pass ]
}

# mpscap_engines_ready UID_A UID_B: both engine Pods, found by UID, report Ready; prints why not otherwise.
mpscap_engines_ready() {
  local pods
  pods="$(mpscap_k get pods -A -o json 2>&1)" || { echo "the Pods could not be read: ${pods:0:160}"; return 1; }
  # Through a file, because the heredoc below is already python's stdin and a here-string beside it would be dropped.
  printf '%s\n' "$pods" >"$MPSCAP_OUT/ready-pods.json"
  python3 - "$MPSCAP_OUT/ready-pods.json" "$1" "$2" <<'PY'
import json, sys
want = sys.argv[2:]
by_uid = {p["metadata"]["uid"]: p for p in json.load(open(sys.argv[1])).get("items", [])}
bad = []
for uid in want:
    p = by_uid.get(uid)
    if p is None:
        bad.append(f"Pod {uid} is gone")
        continue
    ready = any(c.get("type") == "Ready" and c.get("status") == "True" for c in (p.get("status") or {}).get("conditions") or [])
    if not ready:
        bad.append(f"{p['metadata']['namespace']}/{p['metadata']['name']} is not Ready")
if bad:
    print("; ".join(bad))
    sys.exit(1)
PY
}

# mpscap_b4 UID_A UID_B BENCHHARNESS: the two tables the page names, captured on the host while both engines are Ready,
# with each listed process's cgroup, judged by `benchharness mps-capability-bar --bar B4`.
#
# Readiness is read before and after the capture, so a table taken while an engine restarted is not judged as one
# taken while both served. MPSCAP_PROC replaces /proc in the test.
mpscap_b4() {
  local uid_a="$1" uid_b="$2" bh="$3" why t_rc q_rc pid out dir="$MPSCAP_OUT/b4-cgroups"
  mj_start B4 || return 1
  if ! why="$(mpscap_engines_ready "$uid_a" "$uid_b")"; then
    mj_decide B4 unmeasured "the table was not captured, because both engines were not Ready: $why"
    return 1
  fi
  nvidia-smi >"$MPSCAP_OUT/b4-nvidia-smi.txt" 2>"$MPSCAP_OUT/b4-nvidia-smi.err"
  t_rc=$?
  nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv >"$MPSCAP_OUT/b4-compute-apps.csv" 2>"$MPSCAP_OUT/b4-compute-apps.err"
  q_rc=$?
  mkdir -p "$dir"
  # Every PID either command lists, so the judge has a cgroup for each client it could be asked to attribute.
  for pid in $( { grep -oE '^\|[[:space:]]+[0-9]+[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+[0-9]+' "$MPSCAP_OUT/b4-nvidia-smi.txt" | awk '{print $NF}'
                  awk -F, 'NR > 1 && $1 ~ /^ *[0-9]+ *$/ {gsub(/ /, "", $1); print $1}' "$MPSCAP_OUT/b4-compute-apps.csv"; } | sort -un); do
    cp "${MPSCAP_PROC:-/proc}/$pid/cgroup" "$dir/$pid.cgroup" 2>>"$MPSCAP_OUT/b4-cgroups.err" || true
  done
  if ! why="$(mpscap_engines_ready "$uid_a" "$uid_b")"; then
    mj_decide B4 unmeasured "both engines were Ready before the capture and not after it: $why"
    return 1
  fi
  if ! out="$("$bh" mps-capability-bar --bar B4 --table "$MPSCAP_OUT/b4-nvidia-smi.txt" --table-exit "$t_rc" \
    --query-exit "$q_rc" --cgroups "$dir" --engine-a "$uid_a" --engine-b "$uid_b" 2>&1)"; then
    mj_decide B4 unmeasured "the judge could not read the capture: ${out:0:200}"
    return 1
  fi
  mj_decide B4 "${out%%$'\t'*}" "${out#*$'\t'}"
  [ "${out%%$'\t'*}" = pass ]
}

# mpscap_b5_start and mpscap_b5_decide RAW REPLAY_EXIT BENCHHARNESS bracket the matrix's own replay of the frozen
# trace, so a replay that is killed leaves B5 interrupted rather than absent.
mpscap_b5_start() { mj_start B5; }
mpscap_b5_decide() {
  local raw="$1" rc="$2" bh="$3" out
  if [ ! -f "$raw" ]; then
    mj_decide B5 fail "the replay exited $rc and wrote no raw file"
    return 1
  fi
  if ! out="$("$bh" mps-capability-bar --bar B5 --raw "$raw" --replay-exit "$rc" 2>&1)"; then
    mj_decide B5 unmeasured "the judge could not read the replay: ${out:0:200}"
    return 1
  fi
  mj_decide B5 "${out%%$'\t'*}" "${out#*$'\t'}"
  [ "${out%%$'\t'*}" = pass ]
}

# mpscap_pods_named COMPONENT: the plugin namespace's Pods of COMPONENT, failing when there are none.
mpscap_pods_named() {
  local names
  names="$(mpscap_k get pods -n "$MPSCAP_PLUGIN_NS" -l "app.kubernetes.io/component=$1" -o name 2>&1)" || { echo "$names"; return 1; }
  [ -n "$names" ] || { echo "no Pod of $1 in $MPSCAP_PLUGIN_NS"; return 1; }
  echo "$names"
}

# mpscap_diagnostics NS_A NS_B: the page's mandatory diagnostics, on every exit path, before anything is deleted.
#
# Each command's output is kept with its exit status, size and SHA-256 in diag/inventory.tsv, so a missing piece is a
# recorded failure rather than an absent file. The previous container's log is asked for and may legitimately not
# exist; every other command must succeed, and the function returns non-zero when one did not.
# It also records whether a "no healthy devices" event exists, when B2 was cut short before it could say.
mpscap_diagnostics() {
  local ns_a="$1" ns_b="$2" d="$MPSCAP_OUT/diag" missing=0 name rc comp
  mkdir -p "$d"
  printf 'name\texit\tbytes\tsha256\trequired\n' >"$d/inventory.tsv"
  # diag NAME REQUIRED COMMAND...
  diag() {
    name="$1"; local required="$2"; shift 2
    "$@" >"$d/$name" 2>&1
    rc=$?
    printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$rc" "$(wc -c <"$d/$name")" "$(sha256sum "$d/$name" | cut -d' ' -f1)" "$required" >>"$d/inventory.tsv"
    if [ "$rc" != 0 ] && [ "$required" = yes ]; then missing=$((missing + 1)); fi
    return 0
  }
  diag "describe-pods-$ns_a.txt" yes mpscap_k describe pods -n "$ns_a"
  diag "describe-pods-$ns_b.txt" yes mpscap_k describe pods -n "$ns_b"
  diag "pods-$ns_a.json" yes mpscap_k get pods -n "$ns_a" -o json
  diag "pods-$ns_b.json" yes mpscap_k get pods -n "$ns_b" -o json
  diag events-all.json yes mpscap_k get events -A -o json
  diag "describe-pods-$MPSCAP_PLUGIN_NS.txt" yes mpscap_k describe pods -n "$MPSCAP_PLUGIN_NS"
  for comp in nvidia-device-plugin-mps-plugin nvidia-mps-control-daemon; do
    # `logs -l` with no matching Pod prints "No resources found" and exits 0, so the Pods are named first and none is
    # a failed diagnostic (codex, review of 9b25fe70).
    diag "pods-$comp.txt" yes mpscap_pods_named "$comp"
    diag "logs-$comp.txt" yes mpscap_k logs -n "$MPSCAP_PLUGIN_NS" -l "app.kubernetes.io/component=$comp" --all-containers --tail=-1
    diag "logs-$comp-previous.txt" no mpscap_k logs -n "$MPSCAP_PLUGIN_NS" -l "app.kubernetes.io/component=$comp" --all-containers --previous --tail=-1
  done
  diag nvidia-smi.txt yes nvidia-smi
  diag nvidia-smi-compute-apps.csv yes nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv
  # Only events about the engines' own Pods, in their own namespaces, as B2 reads them: another workload's refusal
  # is not this session's (codex, review of 9b25fe70).
  local found
  if ! mj_has_fact no_healthy_devices_event && found="$(python3 - "$d/events-all.json" "$ns_a" "$ns_b" <<'PY'
import json, sys
try:
    events = json.load(open(sys.argv[1])).get("items", [])
except Exception:
    sys.exit(1)
for e in events:
    o = e.get("involvedObject") or {}
    if o.get("kind") == "Pod" and o.get("namespace") in sys.argv[2:] and o.get("name", "").startswith("vllm-shared-") \
            and "no healthy devices" in (e.get("message") or ""):
        print(f"{o['namespace']}/{o['name']}: {e.get('message')}")
        break
PY
)"; then
    if [ -n "$found" ]; then
      mj_fact no_healthy_devices_event true "found by the diagnostics after B2 was cut short: $found"
    else
      mj_fact no_healthy_devices_event false
    fi
  fi
  [ "$missing" = 0 ]
}

# mpscap_supervise END1 END2 END3 GRACE -- COMMAND...: COMMAND run in its own process group, ended when a phase runs out.
#
# The phases end at the amendment's epochs, each with the bar that closes it: B2 at END1, B4 at END2 and B5 at END3.
# The deadline is enforced from outside the work, because the work's own waits are longer than its phase and a
# wait that has not returned cannot check a clock.
# At a deadline whose bar is undecided the group gets TERM, which runs the matrix's cleanup and with it the
# diagnostics, and KILL after GRACE seconds. The bar stays started and undecided, which the classifier reads as
# interrupted.
# Returns COMMAND's status, or 124 when a phase ran out.
mpscap_supervise() {
  local ends=("$1" "$2" "$3") grace="$4" bars=(B2 B4 B5) pid i now
  shift 5
  setsid "$@" &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    now="$(date +%s)"
    for i in 0 1 2; do
      if [ "$now" -ge "${ends[$i]}" ] && [ -z "$(mj_result "${bars[$i]}")" ]; then
        echo "mps supervisor: phase $((i + 1)) ran out at $(date -u -d "@${ends[$i]}" +%H:%M:%SZ) with ${bars[$i]} undecided; stopping the run" >&2
        kill -TERM -- "-$pid" 2>/dev/null
        local waited=0
        while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt "$grace" ]; do sleep 1; waited=$((waited + 1)); done
        kill -KILL -- "-$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
        return 124
      fi
    done
    sleep "${MPSCAP_SUPERVISE_POLL:-2}"
  done
  wait "$pid"
}
