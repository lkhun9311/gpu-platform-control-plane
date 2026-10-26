#!/usr/bin/env bash
#
# The cell procedure of the GPU fault-reaction study, shared by the free rehearsal on kind
# (hack/gpu-fault-reaction.sh) and the paid session's instance (hack/gpu-fault-instance.sh).
# docs/superpowers/specs/2026-10-27-gpu-fault-reaction-design.md is the registration; every number below that
# is not derived there is a convention it names.
#
# WHAT THE CALLER PROVIDES
#   GF_MODE        fake (the gpu-simulator's fake DCGM) or dcgm (the study exporter with its host engine)
#   GF_OUT         the session directory; repetitions go to $GF_OUT/reps, checks to $GF_OUT/checks
#   GF_TARGET      the node whose card is faulted
#   GF_HEALTHY     the node the displaced job must land on
#   GF_SYS         the namespace of the exporter and the operator
#   GF_NS          the training namespace, whose GPUQuotaPolicy gives a ClusterQueue of one GPU
#   GF_EXPORTER    the label selector of the exporter Pods
#   GF_JOB_IMAGE   the job's image, already on the nodes
#   GF_CONTEXT     a kube context, or empty for the current KUBECONFIG
#   GF_ARMS_END    epoch seconds by which the last repetition must have finished, or empty for none
#   GF_LOG         the session log
#
# Like hack/lib/spot-run.sh it never calls `set`, never `cd`s and installs no traps: those belong to the caller.
# Every function returns non-zero on failure and says why on stderr.

# The registered conventions, each named in the registration with its reason.
GF_WINDOW_S=120
GF_SETTLE_S=10
GF_START_S=60
GF_RESET_S=60
GF_SENTINEL_S=10
GF_OFFSET_S=900
GF_PROBE_PERIOD=0.2
GF_STALE_WAIT_S=15
GF_LATCH_WAIT_S=10
# One repetition's longest path: start, settle, window, sentinel, reset.
GF_REP_BUDGET_S=$((GF_START_S + GF_SETTLE_S + GF_WINDOW_S + GF_SENTINEL_S + GF_RESET_S))

# Field IDs (dcgmlib/dcgm_fields.h) and the exporter's names for them.
declare -A GF_FIELD_NAME=([230]=DCGM_FI_DEV_XID_ERRORS [311]=DCGM_FI_DEV_ECC_DBE_VOL_TOTAL [310]=DCGM_FI_DEV_ECC_SBE_VOL_TOTAL)
declare -A GF_ARM_FIELD=([xid]=230 [ecc]=311 [benign]=310 [none]=230)
declare -A GF_ARM_VALUE=([xid]=79 [ecc]=1 [benign]=1 [none]=)

gf_log() { echo "$(date -u +%H:%M:%S) $*" | tee -a "${GF_LOG:-/dev/stderr}" >&2; }
gf_now() { date +%s.%N; }
gfk() {
  if [ -n "${GF_CONTEXT:-}" ]; then kubectl --context "$GF_CONTEXT" "$@"; else kubectl "$@"; fi
}

# gf_exporter_pod NODE echoes the one Running exporter Pod on NODE, and fails unless there is exactly one.
gf_exporter_pod() {
  local listed pods
  # A terminating Pod is still Running, and reading it would read an exporter on its way out.
  listed=$(gfk -n "$GF_SYS" get pods -l "$GF_EXPORTER" --field-selector "spec.nodeName=$1,status.phase=Running" \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.deletionTimestamp}{"\n"}{end}') || return 1
  pods=$(awk 'NF == 1 {print $1}' <<<"$listed")
  [ -n "$pods" ] && [ "$(wc -l <<<"$pods")" = 1 ] || { echo "not exactly one exporter Pod on $1: '$listed'" >&2; return 1; }
  echo "$pods"
}

gf_proxy() { echo "/api/v1/namespaces/$GF_SYS/pods/$GF_POD:9400/proxy$1"; }

# gf_metrics echoes the target exporter's /metrics, through the apiserver's Pod proxy.
gf_metrics() { gfk get --raw "$(gf_proxy /metrics)"; }

# gf_exported FIELD echoes the value the exporter serves for FIELD on the target card, or fails.
gf_exported() {
  local body v
  body=$(gf_metrics) || return 1
  v=$(awk -v n="${GF_FIELD_NAME[$1]}" -v u="UUID=\"$GF_UUID\"" 'index($0, n "{") == 1 && index($0, u) {print $NF; exit}' <<<"$body")
  [ -n "$v" ] || return 1
  echo "$v"
}

# gf_inject FIELD VALUE writes into DCGM's cache, always at the registered fixed offset into the future.
gf_inject() {
  case "$GF_MODE" in
    fake)
      gfk create --raw "$(gf_proxy "/inject?gpu=0&field=$1&value=$2&offset=$GF_OFFSET_S")" -f "$GF_EMPTY_BODY" >/dev/null ;;
    dcgm)
      gfk -n "$GF_SYS" exec "$GF_POD" -c hostengine -- dcgmi test --inject --gpuid 0 -f "$1" -v "$2" --offset "$GF_OFFSET_S" ;;
    *) echo "GF_MODE '$GF_MODE'" >&2; return 1 ;;
  esac
}

# gf_readback FIELD echoes the value DCGM returns for FIELD on GPU 0.
#
# On a real host engine it is `dcgmi dmon`, not `dcgmi test --introspect`: introspection prints the cache's
# metadata (newest and oldest timestamps, fetch counts), not the value (astra review, finding 1, re-derived from
# the pinned binary's strings). dmon prints one row per entity, "GPU 0  <value>", which is what is parsed.
gf_readback() {
  case "$GF_MODE" in
    fake) gfk get --raw "$(gf_proxy "/introspect?gpu=0&field=$1")" | tr -d '[:space:]' ;;
    dcgm)
      local out
      out=$(gfk -n "$GF_SYS" exec "$GF_POD" -c hostengine -- dcgmi dmon -e "$1" -i 0 -c 1) || return 1
      printf '%s\n' "$out" >>"$GF_OUT/dmon-raw.log"
      awk '$1 == "GPU" && $2 == "0" {v = $3} END {if (v == "") exit 1; print v}' <<<"$out" ;;
  esac
}

# gf_exporter_state up|down takes the target's exporter away, or brings it back.
gf_exporter_state() {
  case "$GF_MODE" in
    fake) gfk create --raw "$(gf_proxy "/exporter?state=$1")" -f "$GF_EMPTY_BODY" >/dev/null ;;
    dcgm)
      # The DaemonSet's Pod leaves the node when its own selector stops matching, which is how an exporter
      # leaves. The node's label is not touched: the device plugin selects on it too, and taking the plugin away
      # would change allocatable and so the very boundary P5 records.
      if [ "$1" = down ]; then
        gfk -n "$GF_SYS" patch ds dcgm-exporter --type=json \
          -p '[{"op":"add","path":"/spec/template/spec/nodeSelector/gpufault-study~1exporter","value":"away"}]' >/dev/null || return 1
        gfk -n "$GF_SYS" wait --for=delete "pod/$GF_POD" --timeout=60s >/dev/null || return 1
      else
        gfk -n "$GF_SYS" patch ds dcgm-exporter --type=json \
          -p '[{"op":"remove","path":"/spec/template/spec/nodeSelector/gpufault-study~1exporter"}]' >/dev/null || return 1
        gf_wait_exporter || return 1
      fi ;;
  esac
}

# gf_wait_exporter waits for the target's exporter Pod, records it in GF_POD, and waits for it to serve the card.
gf_wait_exporter() {
  local i
  for i in $(seq 1 60); do
    if GF_POD=$(gf_exporter_pod "$GF_TARGET" 2>/dev/null) &&
      gfk -n "$GF_SYS" wait --for=condition=Ready "pod/$GF_POD" --timeout=5s >/dev/null 2>&1 &&
      gf_metrics 2>/dev/null | grep -q "^${GF_FIELD_NAME[230]}{"; then
      export GF_POD
      return 0
    fi
    sleep 3
  done
  echo "the exporter on $GF_TARGET never served ${GF_FIELD_NAME[230]} (attempt $i)" >&2
  return 1
}

gf_allocatable() { gfk get node "$GF_TARGET" -o jsonpath='{.status.allocatable.nvidia\.com/gpu}'; }

# gf_nh_field NODE JSONPATH reads the NodeHealth whose spec.nodeName is NODE.
gf_nh_field() {
  gfk get nodehealths -o json | python3 -c '
import json, sys
node, path = sys.argv[1], sys.argv[2]
items = [i for i in json.load(sys.stdin)["items"] if i["spec"]["nodeName"] == node]
if len(items) != 1:
    sys.exit("not exactly one NodeHealth for " + node)
nh = items[0]
if path.startswith("cond:"):
    t, k = path[5:].split(".")
    c = [c for c in nh.get("status", {}).get("conditions", []) if c["type"] == t]
    print(c[0][k] if c else "")
elif path.startswith("ann:"):
    print(nh["metadata"].get("annotations", {}).get("gpufault.platform.lkhun9311.github.io/" + path[4:], ""))
' "$1" "$2"
}

gf_tainted() {
  gfk get node "$1" -o jsonpath='{range .spec.taints[*]}{.key}{"\n"}{end}' | grep -qx 'platform.lkhun9311.github.io/gpu-fault'
}

# gf_wait_until SECONDS CMD... polls CMD every half second until it succeeds or SECONDS pass.
gf_wait_until() {
  local until=$(( $(date +%s) + $1 )); shift
  while [ "$(date +%s)" -lt "$until" ]; do "$@" && return 0; sleep 0.5; done
  "$@"
}

gf_is_clear() {
  [ "$(gf_nh_field "$GF_TARGET" cond:GPUHealthy.status)" = True ] && [ "$(gf_nh_field "$GF_TARGET" cond:GPUSignal.status)" = True ] &&
    [ -z "$(gf_nh_field "$GF_TARGET" ann:fingerprint)" ] && ! gf_tainted "$GF_TARGET"
}

# gf_reset injects the baseline into every field the smoke cell passed and waits for the platform to clear.
gf_reset() {
  local f
  for f in $GF_FIELDS; do
    gf_inject "$f" 0 >/dev/null || { echo "reset: injecting $f=0 failed" >&2; return 1; }
  done
  [ -z "${GF_OPERATOR_UP:-}" ] && return 0
  gf_wait_until "$GF_RESET_S" gf_is_clear
}

# --------------------------------------------------------------------------------------------------- watches
# gf_watch_start DIR JOB starts one watch per resource, each recording its start and end in watch-<name>.log.
# A watch that ended inside the window is a gap, and the scorer refuses the repetition for it.
gf_watch_start() {
  local dir=$1 job=$2 name
  GF_WATCH_PIDFILES=()
  for name in node nodehealth workload job pods; do
    local args=()
    case $name in
      node) args=(get node --field-selector "metadata.name=$GF_TARGET") ;;
      nodehealth) args=(get nodehealths) ;;
      workload) args=(-n "$GF_NS" get workloads.kueue.x-k8s.io) ;;
      job) args=(-n "$GF_NS" get jobs.batch --field-selector "metadata.name=$job") ;;
      pods) args=(-n "$GF_NS" get pods -l "batch.kubernetes.io/job-name=$job") ;;
    esac
    (
      echo "start $(gf_now)" >>"$dir/watch-$name.log"
      # kubectl itself, not the gfk function: a backgrounded function is a subshell, and killing it left the
      # kubectl inside running, writing the next repetition's events into this one's stream (rehearsal,
      # 2026-10-26: repetition 1 was scored as misattributed from repetition 2's latch).
      kubectl ${GF_CONTEXT:+--context "$GF_CONTEXT"} "${args[@]}" -w -o json >"$dir/watch-$name.json" 2>>"$dir/watch-$name.err" &
      echo $! >"$dir/watch-$name.pid"
      wait $!
      echo "end $(gf_now) $?" >>"$dir/watch-$name.log"
    ) &
    GF_WATCH_PIDFILES+=("$dir/watch-$name.pid")
  done
  # Each watch must have delivered its initial objects before anything is injected, or its start is not before.
  for name in node nodehealth workload job pods; do
    gf_wait_until 20 test -s "$dir/watch-$name.json" || { echo "watch $name delivered nothing in 20 s" >&2; return 1; }
  done
}

gf_watch_stop() {
  local f
  for f in "${GF_WATCH_PIDFILES[@]+"${GF_WATCH_PIDFILES[@]}"}"; do
    [ -s "$f" ] && kill "$(cat "$f")" 2>>"$GF_LOG"
  done
  # Each watch's subshell writes its end record after its kubectl exits; wait for those, and nothing else.
  for f in "${GF_WATCH_PIDFILES[@]+"${GF_WATCH_PIDFILES[@]}"}"; do
    gf_wait_until 10 grep -q '^end ' "${f%.pid}.log" || echo "watch ${f%.pid} wrote no end record" >&2
    # The end record says the subshell went on; that its kubectl is gone is checked, not assumed.
    if [ -s "$f" ] && ps -p "$(cat "$f")" >/dev/null; then echo "watch $(cat "$f") still running after its kill" >&2; fi
  done
  GF_WATCH_PIDFILES=()
  return 0
}

# gf_probe_start FIELD FILE samples the exporter's value for FIELD every GF_PROBE_PERIOD seconds into FILE.
gf_probe_start() {
  local field=$1 file=$2
  (
    while :; do
      v=$(gf_exported "$field" 2>/dev/null) || v=ERR
      printf '%s\t%s\n' "$(gf_now)" "$v" >>"$file"
      sleep "$GF_PROBE_PERIOD"
    done
  ) &
  GF_PROBE_PID=$!
}

gf_probe_stop() { [ -n "${GF_PROBE_PID:-}" ] && kill "$GF_PROBE_PID" 2>>"$GF_LOG"; GF_PROBE_PID=""; }

# ----------------------------------------------------------------------------------------------- one repetition
gf_submit_job() {
  cat <<EOF | gfk apply -f - >/dev/null
apiVersion: platform.lkhun9311.github.io/v1
kind: MLTrainingJob
metadata:
  name: $1
  namespace: $GF_NS
spec:
  queue: gpu-$GF_NS
  image: $GF_JOB_IMAGE
  command: ["sh", "-c", "trap 'exit 143' TERM; while true; do sleep 1; done"]
  gpuCount: 1
  parallelism: 1
  completions: 1
EOF
}

# gf_job_pod_on JOB NODE succeeds when the job has exactly one Pod, Ready, on NODE.
gf_job_pod_on() {
  local out
  out=$(gfk -n "$GF_NS" get pods -l "batch.kubernetes.io/job-name=$1" \
    -o jsonpath='{range .items[*]}{.spec.nodeName}{" "}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}') || return 1
  [ "$out" = "$2 True" ]
}

# gf_cell ARM REP BLOCK SEQ runs one registered repetition. It returns 2 when the session must stop its arms.
gf_cell() {
  local arm=$1 rep=$2 block=$3 seq=$4
  local dir field value job pre="ok" t0 t1 trb rb tend alloc0 alloc1 sentinel="" tsent=""
  dir="$GF_OUT/reps/$(printf %02d "$seq")-$arm"
  field=${GF_ARM_FIELD[$arm]} value=${GF_ARM_VALUE[$arm]} job="gf-$(printf %02d "$seq")-$arm"
  mkdir -p "$dir" || return 2
  # Written first and rewritten at the end, so a repetition the deadline cuts is scored as cut, not lost.
  printf 'mode=%s\narm=%s\nrep=%s\nblock=%s\ncut=true\n' "$GF_MODE" "$arm" "$rep" "$block" >"$dir/cell.env"
  gf_log "rep $seq: $arm (block $block, repetition $rep)"

  # Step 1: pre-state, read before anything is submitted.
  gf_is_clear || pre="target not clear before the repetition"
  local f
  for f in $GF_FIELDS; do
    [ "$(gf_readback "$f")" = 0 ] || pre="field $f not at baseline before the repetition"
  done
  # Step 2: the job on the target, with the healthy node held off until it is there.
  gfk taint node "$GF_HEALTHY" gpufault-study/hold=true:NoSchedule --overwrite >/dev/null || return 2
  gf_submit_job "$job" || { gf_log "rep $seq: could not submit $job"; return 2; }
  if ! gf_wait_until "$GF_START_S" gf_job_pod_on "$job" "$GF_TARGET"; then
    pre="the job's Pod was not Ready on $GF_TARGET within ${GF_START_S}s"
  fi
  gfk taint node "$GF_HEALTHY" gpufault-study/hold- >/dev/null || return 2
  sleep "$GF_SETTLE_S"

  gf_watch_start "$dir" "$job" || pre="a watch did not start"
  [ "$arm" != none ] && gf_probe_start "$field" "$dir/probe.tsv"
  alloc0=$(gf_allocatable)
  # Step 3: injection, bracketed by the call, then the readback that confirms it.
  t0=$(gf_now)
  if [ "$arm" != none ]; then
    gf_inject "$field" "$value" >>"$dir/inject.log" 2>&1 || gf_log "rep $seq: injection call failed"
  fi
  t1=$(gf_now)
  rb=$(gf_readback "$field" 2>>"$dir/inject.log")
  trb=$(gf_now)
  tend=$(python3 -c 'import sys; print(f"{float(sys.argv[1]) + float(sys.argv[2]):.9f}")' "$t1" "$GF_WINDOW_S")
  # Step 4: the window, from the end of the injection call.
  sleep "$(python3 -c 'import sys,time; print(max(0.0, float(sys.argv[1]) - time.time()))' "$tend")"
  if [ "$arm" = none ]; then
    # The sentinel, after the window: a benign value the operator must be seen to read, so that a quiet window
    # is a window it was watching. A distinct value per repetition, so an older reading cannot match.
    sentinel=$((100 + seq)) tsent=$(gf_now)
    gf_inject 310 "$sentinel" >>"$dir/inject.log" 2>&1
    gf_wait_until "$GF_SENTINEL_S" gf_reading_has "$GF_UUID/${GF_FIELD_NAME[310]}=$sentinel" ||
      gf_log "rep $seq: the operator did not record the sentinel within ${GF_SENTINEL_S}s"
  fi
  alloc1=$(gf_allocatable)
  gf_probe_stop
  gf_watch_stop
  {
    printf 'mode=%s\narm=%s\nrep=%s\nblock=%s\nseq=%s\njob=%s\ntarget=%s\nhealthy=%s\nuuid=%s\n' \
      "$GF_MODE" "$arm" "$rep" "$block" "$seq" "$job" "$GF_TARGET" "$GF_HEALTHY" "$GF_UUID"
    printf 'field=%s\nvalue=%s\nbaseline=0\nreadback=%s\n' "$field" "$value" "$rb"
    printf 't_inject_start=%s\nt_inject_end=%s\nt_rb=%s\nt_window_end=%s\n' "$t0" "$t1" "$trb" "$tend"
    printf 'pre_state=%s\nalloc_before=%s\nalloc_after=%s\n' "$pre" "$alloc0" "$alloc1"
    [ -n "$sentinel" ] && printf 'sentinel_value=%s\nt_sentinel_start=%s\n' "$sentinel" "$tsent"
    echo "cut=false"
  } >"$dir/cell.env"
  gfk -n "$GF_NS" get workloads.kueue.x-k8s.io,jobs.batch,pods,mltrainingjobs -o yaml >"$dir/final-objects.yaml" 2>&1
  gfk get nodehealths -o yaml >"$dir/final-nodehealths.yaml" 2>&1
  gfk -n "$GF_SYS" logs deploy/gpu-platform-control-plane-controller-manager --since=5m >"$dir/operator.log" 2>&1

  # Step 6: reset, and the job removed.
  local reset=ok
  gf_reset || reset=timeout
  gfk -n "$GF_NS" delete mltrainingjob "$job" --wait=true --timeout=60s >>"$dir/reset.log" 2>&1 || reset="$reset; job not deleted"
  gf_wait_until 60 gf_job_pods_gone "$job" || reset="$reset; pods not gone"
  echo "reset=$reset" >>"$dir/cell.env"
  gf_log "rep $seq: done, readback $rb, reset $reset"
  [ "$reset" = ok ] || return 2
}

gf_reading_has() { tr ',' '\n' <<<"$(gf_nh_field "$GF_TARGET" ann:reading)" | grep -qxF "$1"; }

# gf_job_pods_gone JOB succeeds when listing the job's Pods worked and found none; a failed list is not "none".
gf_job_pods_gone() {
  local out
  out=$(gfk -n "$GF_NS" get pods -l "batch.kubernetes.io/job-name=$1" -o name) || return 1
  [ -z "$out" ]
}

# gf_arms runs the registered twenty repetitions in their rotated blocks, stopping at the deadline, after a reset
# that does not clear, or after two invalid-looking repetitions in a row.
gf_arms() {
  local arms=(xid ecc benign none) b i arm seq=0 rc
  # Five blocks are registered; GF_BLOCKS exists only so a rehearsal can be shorter, and the scorer counts what ran.
  for b in $(seq 1 "${GF_BLOCKS:-5}"); do
    for i in 0 1 2 3; do
      arm=${arms[$(( (i + b - 1) % 4 ))]}
      seq=$((seq + 1))
      if ! grep -qx "arm_$arm=run" "$GF_OUT/smoke.env"; then
        gf_log "rep $seq: $arm is not run, by the smoke cell"
        continue
      fi
      if [ -n "${GF_ARMS_END:-}" ] && [ $(( $(date +%s) + GF_REP_BUDGET_S )) -gt "$GF_ARMS_END" ]; then
        gf_log "rep $seq and later: not started, the arms phase ends at $GF_ARMS_END"
        echo "not_started_from=$seq" >>"$GF_OUT/arms.env"
        return 0
      fi
      gf_cell "$arm" "$b" "$b" "$seq"
      rc=$?
      if [ "$rc" = 2 ]; then
        gf_log "rep $seq: the arms stop here (a reset that did not clear, or a step that could not run)"
        echo "stopped_at=$seq" >>"$GF_OUT/arms.env"
        return 0
      fi
    done
  done
}

# --------------------------------------------------------------------------------------------------- smoke cell
# gf_smoke runs S1 to S6 before the operator exists, and writes smoke.env with which arms may run.
#
# The decision table is the registration's: the host engine, the exporter or field 230 or 311 failing stops the
# session, because the platform's policy needs both fault fields to call a card healthy; field 310 failing skips
# the two controls, because both use it (the benign arm injects it, and no-injection reads its sentinel).
gf_smoke() {
  local s="$GF_OUT/smoke.env" f v ok
  : >"$s"
  smoke_stop() { echo "stop=$1" >>"$s"; printf 'arm_xid=skipped\narm_ecc=skipped\narm_benign=skipped\narm_none=skipped\n' >>"$s"; gf_log "SMOKE STOP: $1"; return 1; }
  # S1.
  gf_wait_exporter || { smoke_stop "S1: no exporter serving on $GF_TARGET"; return 1; }
  if [ "$GF_MODE" = dcgm ]; then
    gfk -n "$GF_SYS" exec "$GF_POD" -c hostengine -- sh -c 'command -v dcgmi && command -v nv-hostengine' >>"$GF_OUT/smoke.log" 2>&1 ||
      { smoke_stop "S1: dcgmi or nv-hostengine not in the exporter Pod"; return 1; }
    gfk -n "$GF_SYS" exec "$GF_POD" -c hostengine -- dcgmi discovery -l >"$GF_OUT/smoke-discovery.txt" 2>&1 ||
      { smoke_stop "S1: dcgmi discovery failed"; return 1; }
    grep -q A10G "$GF_OUT/smoke-discovery.txt" || { smoke_stop "S1: the host engine does not list an A10G"; return 1; }
  fi
  echo "S1=pass" >>"$s"
  # S2: the card's UUID, and every field on /metrics.
  GF_UUID=$(gf_metrics | awk -v n="${GF_FIELD_NAME[230]}{" 'index($0, n) == 1 {match($0, /UUID="[^"]*"/); print substr($0, RSTART + 6, RLENGTH - 7); exit}')
  export GF_UUID
  [ -n "$GF_UUID" ] || { smoke_stop "S2: no UUID on ${GF_FIELD_NAME[230]}"; return 1; }
  echo "uuid=$GF_UUID" >>"$s"
  GF_FIELDS=""
  for f in 230 311 310; do
    if gf_exported "$f" >/dev/null; then echo "S2_$f=pass" >>"$s"; else echo "S2_$f=fail" >>"$s"; fi
  done
  # S3 to S5, then S6 around them.
  echo "alloc_before=$(gf_allocatable)" >>"$s"
  for f in 230 311 310; do
    v=$([ "$f" = 230 ] && echo 79 || echo 1)
    ok=pass
    grep -qx "S2_$f=pass" "$s" || ok="fail: not exported"
    [ "$ok" = pass ] && { gf_inject "$f" "$v" >>"$GF_OUT/smoke.log" 2>&1 || ok="fail: inject"; }
    [ "$ok" = pass ] && { [ "$(gf_readback "$f")" = "$v" ] || ok="fail: readback"; }
    [ "$ok" = pass ] && { gf_wait_until 10 gf_exported_is "$f" "$v" || ok="fail: not served within 10 s"; }
    [ "$ok" = pass ] && { sleep 30; gf_exported_is "$f" "$v" || ok="fail: not persistent for 30 s"; }
    [ "$ok" = pass ] && { gf_inject "$f" 0 >>"$GF_OUT/smoke.log" 2>&1 || ok="fail: reset inject"; }
    [ "$ok" = pass ] && { [ "$(gf_readback "$f")" = 0 ] || ok="fail: reset readback"; }
    [ "$ok" = pass ] && { gf_wait_until 10 gf_exported_is "$f" 0 || ok="fail: reset not served within 10 s"; }
    echo "S_inject_$f=$ok" >>"$s"
    [ "$ok" = pass ] && GF_FIELDS="$GF_FIELDS $f"
  done
  echo "alloc_after=$(gf_allocatable)" >>"$s"
  export GF_FIELDS
  grep -qx 'S_inject_230=pass' "$s" || { smoke_stop "S3: field 230"; return 1; }
  grep -qx 'S_inject_311=pass' "$s" || { smoke_stop "S4: field 311"; return 1; }
  printf 'arm_xid=run\narm_ecc=run\n' >>"$s"
  if grep -qx 'S_inject_310=pass' "$s"; then
    printf 'arm_benign=run\narm_none=run\n' >>"$s"
  else
    printf 'arm_benign=skipped\narm_none=skipped\n' >>"$s"
  fi
  gf_log "smoke: $(paste -sd' ' "$s")"
}

gf_exported_is() { [ "$(gf_exported "$1" 2>/dev/null)" = "$2" ]; }

# ------------------------------------------------------------------------------------------------ stale checks
gf_record_during() {
  local file=$1
  {
    echo "during_signal_status=$(gf_nh_field "$GF_TARGET" cond:GPUSignal.status)"
    echo "during_signal_reason=$(gf_nh_field "$GF_TARGET" cond:GPUSignal.reason)"
    echo "during_healthy_status=$(gf_nh_field "$GF_TARGET" cond:GPUHealthy.status)"
    echo "during_taint=$(gf_tainted "$GF_TARGET" && echo present || echo absent)"
    echo "during_latched=$(gf_nh_field "$GF_TARGET" ann:fingerprint)"
  } >>"$file"
}

# gf_stale_checks runs the two registered cells that take the exporter away with the operator running.
gf_stale_checks() {
  local d
  d="$GF_OUT/checks/stale-healthy"
  mkdir -p "$d"
  gf_log "check stale-healthy"
  if gf_is_clear && gf_exporter_state down; then
    sleep "$GF_STALE_WAIT_S"
    gf_record_during "$d/check.env"
    gf_exporter_state up || { gf_log "stale-healthy: the exporter did not come back"; return 1; }
    gf_wait_until 30 gf_is_clear || gf_log "stale-healthy: not clear 30 s after the exporter came back"
  else
    echo "precondition=failed" >>"$d/check.env"
  fi

  d="$GF_OUT/checks/stale-latched"
  mkdir -p "$d"
  gf_log "check stale-latched"
  gf_inject 230 79 >>"$d/inject.log" 2>&1
  gf_wait_until "$GF_LATCH_WAIT_S" gf_tainted "$GF_TARGET" || gf_log "stale-latched: no taint within ${GF_LATCH_WAIT_S}s"
  echo "before_latched=$(gf_nh_field "$GF_TARGET" ann:fingerprint)" >>"$d/check.env"
  if gf_exporter_state down; then
    sleep "$GF_STALE_WAIT_S"
    gf_record_during "$d/check.env"
    gf_exporter_state up || { gf_log "stale-latched: the exporter did not come back"; return 1; }
  fi
  # A restarted real host engine starts from an empty cache; the fake keeps its cache. The baseline is injected
  # either way, so what clears the latch is a fresh zero reading, never the exporter's return alone.
  gf_reset
  {
    echo "after_latched=$(gf_nh_field "$GF_TARGET" ann:fingerprint)"
    echo "after_taint=$(gf_tainted "$GF_TARGET" && echo present || echo absent)"
  } >>"$d/check.env"
}

# ------------------------------------------------------------------------------------------------ the platform
# gf_install_queueing installs Kueue from the repository's pinned manifest, the CRDs and the resource flavor.
gf_install_queueing() {
  gfk apply --server-side -f config/kueue-controller/manifests.yaml >>"$GF_LOG" 2>&1 || { echo "kueue apply" >&2; return 1; }
  gfk -n kueue-system wait --for=condition=Available deploy/kueue-controller-manager --timeout=300s >>"$GF_LOG" 2>&1 ||
    { echo "kueue not Available" >&2; return 1; }
  gfk kustomize config/crd >"$GF_OUT/crds.yaml" 2>>"$GF_LOG" || return 1
  gfk apply --server-side -f "$GF_OUT/crds.yaml" >>"$GF_LOG" 2>&1 || { echo "CRDs" >&2; return 1; }
  # Kueue's webhook answers a little after its Deployment is Available, so the flavor is retried.
  gf_wait_until 90 gf_apply_quiet config/kueue/resourceflavor.yaml || { echo "resource flavor" >&2; return 1; }
}

gf_apply_quiet() { gfk apply -f "$1" >>"$GF_LOG" 2>&1; }

# gf_deploy_operator IMAGE deploys the operator without its webhook, with the DCGM fault path and eviction on.
#
# Without the webhook because its certificate needs cert-manager, and nothing it guards is part of this study;
# the fault path's flags are read back from the running Deployment, not assumed from the patch.
gf_deploy_operator() {
  local img=$1 dep=gpu-platform-control-plane-controller-manager
  gfk kustomize config/operator >"$GF_OUT/operator.yaml" 2>>"$GF_LOG" || return 1
  gfk apply --server-side -f "$GF_OUT/operator.yaml" >>"$GF_LOG" 2>&1 || { echo "operator apply" >&2; return 1; }
  gfk -n "$GF_SYS" set image "deploy/$dep" "manager=$img" >>"$GF_LOG" 2>&1 || return 1
  gfk -n "$GF_SYS" patch "deploy/$dep" --type=json -p "[
    {\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/imagePullPolicy\",\"value\":\"IfNotPresent\"},
    {\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/args/-\",\"value\":\"--gpu-fault-source=dcgm\"},
    {\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/args/-\",\"value\":\"--gpu-fault-evict-workloads\"},
    {\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/args/-\",\"value\":\"--gpu-fault-exporter-selector=$GF_EXPORTER\"}
  ]" >>"$GF_LOG" 2>&1 || return 1
  gfk -n "$GF_SYS" rollout status "deploy/$dep" --timeout=240s >>"$GF_LOG" 2>&1 || { echo "operator rollout" >&2; return 1; }
  gfk -n "$GF_SYS" get "deploy/$dep" -o jsonpath='{.spec.template.spec.containers[0].args}' >"$GF_OUT/operator-args.json" || return 1
  grep -q -- '--gpu-fault-source=dcgm' "$GF_OUT/operator-args.json" || { echo "the fault path is not in the running args" >&2; return 1; }
  export GF_OPERATOR_UP=1
}

gf_cq_quota_is_one() {
  [ "$(gfk get clusterqueue "gpu-$GF_NS" -o jsonpath='{.spec.resourceGroups[0].flavors[0].resources[0].nominalQuota}')" = 1 ]
}

# gf_tenant creates the training namespace's one-GPU quota and a NodeHealth per node, then waits for both to work.
gf_tenant() {
  gfk apply -f - >>"$GF_LOG" 2>&1 <<EOF || return 1
apiVersion: v1
kind: Namespace
metadata:
  name: $GF_NS
---
apiVersion: platform.lkhun9311.github.io/v1
kind: GPUQuotaPolicy
metadata:
  name: $GF_NS-quota
spec:
  tenant: $GF_NS
  targetNamespace: $GF_NS
  limits:
    gpuCount: 1
  trainingQuota: true
---
apiVersion: platform.lkhun9311.github.io/v1
kind: NodeHealth
metadata:
  name: gf-target
spec:
  nodeName: $GF_TARGET
---
apiVersion: platform.lkhun9311.github.io/v1
kind: NodeHealth
metadata:
  name: gf-healthy
spec:
  nodeName: $GF_HEALTHY
EOF
  gf_wait_until 90 gf_cq_quota_is_one || { echo "no ClusterQueue gpu-$GF_NS with a quota of 1" >&2; return 1; }
  gf_wait_until 60 gf_is_clear || { echo "the target's NodeHealth never read clear" >&2; return 1; }
}
