#!/usr/bin/env bash
# Run one cell of the stranded-GPU campaign and record what happened.
#
# The pre-registration is docs/superpowers/specs/2026-09-29-stranded-gpu-frozen-protocol.md and the machine
# copy is hack/stranded-protocol.yaml. This script implements them; it does not choose them. Every number it
# needs -- the submission sequence, the layout, the images, the per-step timeout -- is read from the protocol
# file, so a value changed there changes the run and a value changed here changes nothing.
#
# It PERFORMS and RECORDS. It does not judge: the record goes to cmd/strandedrun's check-cell, which is where
# the protocol is enforced. Keeping those apart is what lets a verdict be re-reached from the recorded bytes
# after the cluster is gone.
#
# Usage:
#   hack/stranded-cell.sh cell <arm> <repetition> <attempt>   # one attempt at one cell
#   hack/stranded-cell.sh teardown                            # remove this campaign's namespace
#
# Environment:
#   CONTEXT   kube context                    (default kind-stranded)
#   EXDIR     evidence directory              (default ex/cell-<arm>-rep<n>-try<n>-<UTC>)
#   PROTOCOL  protocol file                   (default hack/stranded-protocol.yaml)
#
# Deliberately NOT here: creating or configuring the cluster. render-cluster writes the kind configuration and
# the arm decides what it installs; a script that both configured the scheduler and measured it could not be
# read as evidence about a configuration someone else applied.

set -euo pipefail

CONTEXT="${CONTEXT:-kind-stranded}"
PROTOCOL="${PROTOCOL:-hack/stranded-protocol.yaml}"
NS=stranded
# The sibling fragmentation study (docs/superpowers/specs/2026-09-24-node-level-gpu-fragmentation.md) counts
# headroom across EVERY namespace and takes its context from an environment variable. The protocol invalidates
# a cell for its fixture being present, so the namespace is distinct and the check below is not decorative.
SIBLING_NS=frag

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/bin/strandedrun"

k() { kubectl --context "$CONTEXT" "$@"; }
say() { printf '%s  %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$EXDIR/run.log"; }

# kjson LABEL ARGS... -- run `k ARGS... -o json`, leave it in a file, and print that file's path.
#
# Never `k get ... -o json | python3 - <<'PY'`. `python3 -` reads its PROGRAM from stdin, the heredoc supplies
# that program and is the later redirection, so the heredoc wins and the pipe goes nowhere: json.load(sys.stdin)
# then reads the consumed heredoc and sees EOF. Measured -- this script's first real run died with
# "Expecting value: line 1 column 1 (char 0)" while kubectl was returning 219 KB perfectly well.
#
# The emptiness check is not belt-and-braces either. In a measurement study "no GPU demand anywhere" and "the
# query never reached a cluster" are the same bytes, so an empty payload is refused rather than counted as zero.
kjson() {
  local label="$1"; shift
  local out="$EXDIR/api-$label.json"
  if ! k "$@" -o json >"$out" 2>>"$EXDIR/run.log"; then
    say "kubectl $* failed; see run.log"
    return 1
  fi
  if [ ! -s "$out" ]; then
    say "kubectl $* returned an empty payload, which is not a reading of anything"
    return 1
  fi
  printf '%s' "$out"
}

# invalid <registered-reason> -- record the attempt as invalid and stop, with the reason the protocol knows.
#
# The reason must be one of the protocol's registered names. check-cell refuses anything else, on the ground
# that a reason worded after the attempt was seen is a reason chosen from the outcome. So this function passes
# the string through untouched rather than describing what went wrong in its own words.
invalid() {
  local reason="$1"
  say "INVALID: $reason"
  write_record "$reason"
  say "the attempt is recorded and retained at $EXDIR/record.json"
  exit 0
}

usage() {
  sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 2
}

# ---------------------------------------------------------------------------- protocol

# read_protocol fills the globals the run needs, from the file rather than from this script.
read_protocol() {
  [ -f "$PROTOCOL" ] || { echo "no protocol at $PROTOCOL" >&2; exit 1; }
  # One python invocation rather than six, so the values cannot come from different reads of a file that
  # changed in between.
  local out
  out="$(python3 - "$PROTOCOL" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
subs = d["submissions"]
print("SUB_IDS=(" + " ".join(s["id"] for s in subs) + ")")
print("SUB_REQS=(" + " ".join(str(s["request"]) for s in subs) + ")")
print("LAYOUT=(" + " ".join(str(w) for w in d["node_layout"]["workers"]) + ")")
print(f'SCHED_IMAGE="{d["images"]["scheduler"]}"')
print(f'STEP_TIMEOUT={d["barriers"]["per_step_timeout_seconds"]}')
print(f'WANT_CENSUSES={d["expected_counts"]["accepted_censuses"]}')
arms = {a["name"]: a for a in d["arms"]}
print("ARM_NAMES=(" + " ".join(arms) + ")")
PY
)" || { echo "the protocol at $PROTOCOL could not be read" >&2; exit 1; }
  eval "$out"
  say "protocol: ${#SUB_IDS[@]} submissions, layout ${LAYOUT[*]}, ${STEP_TIMEOUT}s per step"
}

# ---------------------------------------------------------------------------- preconditions

# verify_arm collects the qualification evidence from the API and lets strandedrun judge it.
#
# The readings come from the scheduler pod: its command, its volumes, its image and its restart count. No
# credential beyond read access and no entering the node -- /configz would say what the scheduler LOADED, and
# what qualifies an arm is what was SUPPLIED.
verify_arm() {
  local arm="$1"
  local args image restarts vols profile
  args="$(k -n kube-system get pod -l component=kube-scheduler \
    -o jsonpath='{range .items[0].spec.containers[0].command[*]}{@}{","}{end}' 2>/dev/null | sed 's/,$//')"
  image="$(k -n kube-system get pod -l component=kube-scheduler \
    -o jsonpath='{.items[0].status.containerStatuses[0].image}' 2>/dev/null)"
  restarts="$(k -n kube-system get pod -l component=kube-scheduler \
    -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}' 2>/dev/null)"
  vols="$(k -n kube-system get pod -l component=kube-scheduler \
    -o jsonpath='{range .items[0].spec.volumes[*]}{.name}{" "}{end}' 2>/dev/null)"
  case "$vols" in *stranded-scheduler*) profile=yes ;; *) profile=no ;; esac

  [ -n "$args" ] || invalid missing_arm_qualification_evidence
  [ -n "$image" ] || invalid missing_arm_qualification_evidence
  ARM_IMAGE="$image"; ARM_RESTARTS="${restarts:-0}"

  local extra=()
  if [ "$arm" = "S-gpu-most" ]; then
    # check-treatment's verdict is a separate reading and is taken below, once a probe has been placed.
    extra=(-treatment-applied="$TREATMENT_APPLIED")
  else
    extra=(-demand-scheduled="$DEMAND_SCHEDULED")
  fi
  if ! "$BIN" qualify-arm -arm="$arm" -protocol="$PROTOCOL" \
      -scheduler-args="$args" -scheduler-image="$image" -restarts="${restarts:-0}" \
      -profile-file="$profile" "${extra[@]}" >>"$EXDIR/qualify-arm.log" 2>&1; then
    say "qualify-arm refused arm $arm; see $EXDIR/qualify-arm.log"
    invalid missing_arm_qualification_evidence
  fi
  ARM_QUALIFIED=true
  say "arm $arm qualified: image $image, $restarts restart(s), profile-file=$profile"
}

# verify_layout reads allocatable back from each node by name, because the manifest is not evidence.
verify_layout() {
  local nodesjson observed
  nodesjson="$(kjson nodes-layout get nodes)" || { say "could not read nodes for the layout check"; exit 1; }
  observed="$(python3 - "$nodesjson" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
out = []
for n in d["items"]:
    name = n["metadata"]["name"]
    if name.endswith("control-plane"):
        continue
    label = (n["metadata"].get("labels") or {}).get("stranded.gpu-platform/devices", "")
    alloc = n["status"]["allocatable"].get("nvidia.com/gpu", "0")
    out.append(f"{name}:{label}:{alloc}")
print(",".join(out))
PY
)"
  say "observed layout: $observed"
  local want
  want="$(IFS=,; echo "${LAYOUT[*]}")"
  if ! "$BIN" verify-layout -layout="$want" -observed="$observed" >>"$EXDIR/verify-layout.log" 2>&1; then
    say "verify-layout refused; see $EXDIR/verify-layout.log"
    invalid advertised_capacity_not_2_1_1_at_start
  fi
}

# verify_isolation refuses to run where the sibling study's fixture is installed, or where foreign GPU demand
# already exists. Both are registered invalidation reasons, and both are one word away in practice.
verify_isolation() {
  if k get namespace "$SIBLING_NS" >/dev/null 2>&1; then
    say "namespace $SIBLING_NS exists on this cluster"
    invalid the_sibling_studys_fixture_installed_on_the_cells_cluster
  fi
  local pods foreign
  # A read failure is an execution error, not a registered invalidation reason. Dressing it as one would put a
  # protocol name on something the protocol never described.
  pods="$(kjson pods-isolation get pods -A)" || { say "could not read pods for the isolation check"; exit 1; }
  foreign="$(python3 - "$pods" "$NS" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); mine = sys.argv[2]; n = 0
for p in d["items"]:
    q = sum(int(c.get("resources", {}).get("requests", {}).get("nvidia.com/gpu", 0) or 0)
            for c in p["spec"]["containers"])
    if q and p["metadata"]["namespace"] != mine:
        n += 1
print(n)
PY
)"
  if [ "$foreign" -ne 0 ]; then
    say "$foreign GPU-requesting pod(s) outside $NS"
    invalid a_submission_of_this_campaign_outside_its_own_cluster
  fi
  say "isolation holds: no $SIBLING_NS namespace, no foreign GPU demand"
}

# ---------------------------------------------------------------------------- the sequence

# submit STEP_INDEX -- create one submission pod and wait for it to bind or to be refused.
#
# pause:3.10 rather than anything that runs: a dead pod holds no devices, and an image whose entrypoint exits
# would leave the census reading zero while the record said a pod had been submitted.
submit() {
  local idx="$1" id="${SUB_IDS[$1]}" req="${SUB_REQS[$1]}"
  say "submitting $id (request $req)"
  if ! k -n "$NS" apply -f - >>"$EXDIR/run.log" 2>&1 <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: $id
  labels:
    stranded.gpu-platform/submission: "$id"
spec:
  restartPolicy: Never
  containers:
    - name: hold
      image: registry.k8s.io/pause:3.10
      resources:
        limits:
          nvidia.com/gpu: "$req"
YAML
  then
    say "the API refused $id"
    DISPOSITIONS[$idx]=api-rejected
    return 0
  fi

  # Bound or refused within the registered timeout. No `|| true` anywhere in this wait: the sibling study's
  # own notes record a 120-second wait for a Job that could never start, swallowed by `|| true`, whose summary
  # still read "5/5 reached scheduled" -- the kind of green that means nothing.
  local deadline=$((SECONDS + STEP_TIMEOUT)) node events
  while ((SECONDS < deadline)); do
    node="$(k -n "$NS" get pod "$id" -o jsonpath='{.spec.nodeName}' 2>/dev/null)"
    if [ -n "$node" ]; then
      DISPOSITIONS[$idx]=bound
      NODES[$idx]="$node"
      say "$id bound to $node after $((SECONDS - deadline + STEP_TIMEOUT))s"
      return 0
    fi
    events="$(k -n "$NS" get events --field-selector "involvedObject.name=$id,reason=FailedScheduling" \
      -o jsonpath='{range .items[*]}{.message}{"\n"}{end}' 2>/dev/null)"
    if [ -n "$events" ]; then
      printf '%s\n' "$events" >>"$EXDIR/failed-scheduling-$id.log"
      DISPOSITIONS[$idx]=queued-unadmitted
      say "$id refused placement; events retained"
      return 0
    fi
    sleep 2
  done
  say "$id neither bound nor produced a scheduling refusal within ${STEP_TIMEOUT}s"
  invalid step_neither_bound_nor_refused_within_timeout
}

# census STEP_INDEX -- read the cluster live and let strandedrun compute the registered figure.
#
# Read at the moment of judging, not at rollout time: a census taken right after `kubectl rollout status`
# once showed two of three nodes advertising zero GPUs, and the same read a minute later gave 2,1,1.
census() {
  local idx="$1" step="c$(($1 + 1))"
  local nodesjson podsjson nodes subs
  # Labelled per step, so six censuses leave six readings rather than overwriting one.
  nodesjson="$(kjson "nodes-$step" get nodes)" || { say "could not read nodes for census $step"; exit 1; }
  nodes="$(python3 - "$nodesjson" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
print(",".join(f"{n['metadata']['name']}:{n['status']['allocatable'].get('nvidia.com/gpu','0')}:0"
                for n in d["items"] if not n["metadata"]["name"].endswith("control-plane")))
PY
)"
  # Reserved is recomputed from bound pods rather than tracked, so the ledger and the cluster cannot diverge.
  podsjson="$(kjson "pods-$step" -n "$NS" get pods)" || { say "could not read pods for census $step"; exit 1; }
  nodes="$(python3 - "$podsjson" "$nodes" <<'PY'
import json, sys, collections
spec = sys.argv[2]
res = collections.Counter()
d = json.load(open(sys.argv[1]))
for p in d["items"]:
    n = p["spec"].get("nodeName")
    if not n or p["status"].get("phase") not in ("Running", "Pending"):
        continue
    res[n] += sum(int(c.get("resources", {}).get("requests", {}).get("nvidia.com/gpu", 0) or 0)
                  for c in p["spec"]["containers"])
out = []
for part in spec.split(","):
    name, alloc, _ = part.split(":")
    out.append(f"{name}:{alloc}:{res[name]}")
print(",".join(out))
PY
)"
  subs=""
  for i in $(seq 0 "$idx"); do
    local entry="${SUB_IDS[$i]}:${SUB_REQS[$i]}:${DISPOSITIONS[$i]}"
    [ "${DISPOSITIONS[$i]}" = "bound" ] && entry="$entry:${NODES[$i]}"
    subs="${subs:+$subs,}$entry"
  done
  say "census $step: nodes $nodes"
  if ! "$BIN" take-census -step="$step" -nodes="$nodes" -submissions="$subs" -settled \
      -protocol="$PROTOCOL" -step-number="$((idx + 1))" -json \
      >"$EXDIR/census-$step.json" 2>>"$EXDIR/run.log"; then
    say "take-census refused $step; see run.log"
    invalid ledger_membership_mismatch
  fi
  say "census $step: $(python3 -c "
import json;d=json.load(open('$EXDIR/census-$step.json'))
print(f\"stranded={d['stranded_devices']} reserved={d['reserved_total']} blocked={d.get('blocked') or []}\")")"
}

# ---------------------------------------------------------------------------- qualification probe

# qualify_treatment runs a SEPARATE probe on a fixture where the two strategies disagree, before the sequence.
#
# The first version of this reused registered submission s1 as the probe and fed check-treatment the empty
# layout. That was refused, correctly, and the refusal is a measured property of the registered layout: on an
# empty 2,1,1 a one-device probe reaches allocation fraction (0+1)/1 on BOTH one-device nodes, so MostAllocated
# scores them equally and the winner would come from a tiebreak the model does not include. A fixture on which
# the two strategies agree qualifies nothing.
#
# Holding one one-device node first breaks the tie: the candidates become worker(2 free) and worker2(1 free), and
# MostAllocated prefers worker2 at 1/1 while LeastAllocated prefers worker at 1/2. Measured both ways --
# naming the other strategy makes check-treatment refuse the same placement.
#
# The probe and its holder are deleted before the registered sequence runs. They are qualification evidence,
# which the protocol excludes from the comparison, and leaving them in place would change the cluster the
# sequence starts from.
qualify_treatment() {
  local holder_node="stranded-worker3" probe_node
  say "qualification probe: holding $holder_node so the two one-device nodes do not tie"
  k -n "$NS" apply -f - >>"$EXDIR/run.log" 2>&1 <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: qual-holder
spec:
  restartPolicy: Never
  nodeSelector:
    kubernetes.io/hostname: $holder_node
  containers:
    - name: hold
      image: registry.k8s.io/pause:3.10
      resources:
        limits:
          nvidia.com/gpu: "1"
YAML
  local deadline=$((SECONDS + STEP_TIMEOUT))
  while ((SECONDS < deadline)); do
    [ -n "$(k -n "$NS" get pod qual-holder -o jsonpath='{.spec.nodeName}' 2>/dev/null)" ] && break
    sleep 2
  done
  if [ -z "$(k -n "$NS" get pod qual-holder -o jsonpath='{.spec.nodeName}' 2>/dev/null)" ]; then
    say "the qualification holder never bound, so no discriminating fixture exists"
    invalid missing_arm_qualification_evidence
  fi

  k -n "$NS" apply -f - >>"$EXDIR/run.log" 2>&1 <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: qual-probe
spec:
  restartPolicy: Never
  containers:
    - name: hold
      image: registry.k8s.io/pause:3.10
      resources:
        limits:
          nvidia.com/gpu: "1"
YAML
  deadline=$((SECONDS + STEP_TIMEOUT))
  while ((SECONDS < deadline)); do
    probe_node="$(k -n "$NS" get pod qual-probe -o jsonpath='{.spec.nodeName}' 2>/dev/null)"
    [ -n "$probe_node" ] && break
    sleep 2
  done
  if [ -z "${probe_node:-}" ]; then
    say "the qualification probe never bound"
    invalid missing_arm_qualification_evidence
  fi
  say "qualification probe landed on $probe_node"

  # The fixture states the cluster AS THE PROBE SAW IT: the holder's node is full, the others are free.
  if "$BIN" check-treatment -strategy=MostAllocated \
      -nodes="stranded-worker:${LAYOUT[0]}:0,stranded-worker2:${LAYOUT[1]}:0,$holder_node:${LAYOUT[2]}:${LAYOUT[2]}" \
      -request=1 -observed="$probe_node" >>"$EXDIR/check-treatment.log" 2>&1; then
    TREATMENT_APPLIED=yes
  else
    TREATMENT_APPLIED=no
  fi
  PROBE_NODE="$probe_node"; export PROBE_NODE
  say "check-treatment: applied=$TREATMENT_APPLIED"

  k -n "$NS" delete pod qual-holder qual-probe --wait=true >>"$EXDIR/run.log" 2>&1
  say "qualification evidence removed; the sequence starts from the layout it verified"
}

# ---------------------------------------------------------------------------- the record

write_record() {
  local reason="${1:-}"
  python3 - "$EXDIR" "$ARM" "$REP" "$TRY" "$ARM_IMAGE" "$ARM_RESTARTS" \
      "${ARM_QUALIFIED:-false}" "${TREATMENT_APPLIED:-}" "$reason" <<'PY' >"$EXDIR/record.json"
import glob, json, os, sys
exdir, arm, rep, try_, image, restarts, qualified, treat, reason = sys.argv[1:10]
rec = {
    "arm": arm, "repetition": int(rep), "attempt": int(try_),
    "arm_verdict": {"arm": arm, "qualified": qualified == "true",
                    "scheduler_image": image, "restarts": int(restarts or 0)},
    "censuses": [],
}
if arm == "S-gpu-most" and treat:
    rec["treatment_verdict"] = {"strategy": "MostAllocated", "observed": os.environ.get("PROBE_NODE", ""),
                                "applied": treat == "yes"}
for path in sorted(glob.glob(os.path.join(exdir, "census-c*.json")),
                   key=lambda p: int(os.path.basename(p)[8:-5])):
    rec["censuses"].append(json.load(open(path)))
if reason:
    rec["invalidated_because"] = reason
print(json.dumps(rec, indent=2))
PY
}

# ---------------------------------------------------------------------------- entry points

run_cell() {
  ARM="$1"; REP="$2"; TRY="$3"
  EXDIR="${EXDIR:-$ROOT/ex/cell-$ARM-rep$REP-try$TRY-$(date -u +%Y%m%dT%H%M%SZ)}"
  mkdir -p "$EXDIR"
  : >"$EXDIR/run.log"
  say "cell $ARM repetition $REP attempt $TRY, context $CONTEXT, evidence $EXDIR"

  [ -x "$BIN" ] || { say "no strandedrun binary at $BIN; run: go build -o $BIN ./cmd/strandedrun"; exit 1; }
  read_protocol

  local known=no
  for a in "${ARM_NAMES[@]}"; do [ "$a" = "$ARM" ] && known=yes; done
  [ "$known" = yes ] || { say "arm $ARM is not registered in $PROTOCOL"; exit 1; }

  verify_isolation
  verify_layout

  # The arm's own evidence needs readings the run has not taken yet -- whether demand schedules, and
  # check-treatment's verdict -- so the arm is qualified after the first submissions rather than before. What
  # is checked FIRST is the layout and the isolation, which must hold before any pod exists.
  k get namespace "$NS" >/dev/null 2>&1 || k create namespace "$NS" >>"$EXDIR/run.log" 2>&1
  k -n "$NS" delete pods --all --wait=true >>"$EXDIR/run.log" 2>&1 || true

  DISPOSITIONS=(); NODES=()
  for i in "${!SUB_IDS[@]}"; do
    DISPOSITIONS[i]=""; NODES[i]=""
  done

  TREATMENT_APPLIED=""; DEMAND_SCHEDULED=""
  [ "$ARM" = "S-gpu-most" ] && qualify_treatment

  for i in "${!SUB_IDS[@]}"; do
    submit "$i"
    census "$i"
    if [ -z "$DEMAND_SCHEDULED" ] && [ "${DISPOSITIONS[$i]}" = "bound" ]; then
      DEMAND_SCHEDULED=yes
    fi
  done
  [ -n "$DEMAND_SCHEDULED" ] || DEMAND_SCHEDULED=no

  verify_arm "$ARM"
  write_record ""
  say "recorded $EXDIR/record.json with ${WANT_CENSUSES} expected censuses"

  # The script performs and records; check-cell judges. Running it here is a convenience, and its verdict is
  # printed rather than acted on -- a performer that could decide its own attempt was valid would be judging
  # its own work.
  say "verdict from check-cell:"
  "$BIN" check-cell -record="$EXDIR/record.json" -protocol="$PROTOCOL" 2>&1 | tee -a "$EXDIR/run.log" | sed 's/^/    /'
}

teardown() {
  EXDIR="${EXDIR:-/tmp}"
  kubectl --context "$CONTEXT" delete namespace "$NS" --ignore-not-found
}

case "${1:-}" in
  cell)     [ $# -eq 4 ] || usage; run_cell "$2" "$3" "$4" ;;
  teardown) teardown ;;
  *)        usage ;;
esac
