# shellcheck shell=bash
# The prospective-admission measurement pilot's parts of hack/m5c-matrix.sh.
#
# Scoped in docs/superpowers/specs/2026-10-08-measuring-prospective-admission-design.md, "The measurement
# pilot". Kept in its own file, as hack/lib/instrument-validation.sh is for its studies, so that every line the
# pilot adds to the matrix is a call into here and the matrix's other studies run exactly as before.
#
# Sourced by the matrix; it defines functions and constants and runs nothing.

PP_STUDY=prospective-pilot-2026-10-08
# The registered model and its snapshot. The validator compares the engine against these and not against the
# caller's MODEL_REVISION, which would set both sides of the comparison (pilot review 11, finding 3).
PP_MODEL="Qwen/Qwen2.5-3B-Instruct"
PP_MODEL_REVISION=aa8e72537993ba99e69dfaafa59ed015b17504d1
# The pilot's own step logger: the frozen step_logging_scheduler.py is pinned by the archived studies' hashes.
PP_PLUGIN=hack/vllm-plugins/pilot_step_logger.py
PP_CLASS=pilot_step_logger.PilotStepLoggingScheduler
PP_CONFIGMAP=pilot-step-plugin
PP_STEP_LOG=/var/log/pilot-step/step.jsonl
PP_GATEWAY_RECORD=/var/log/gateway/record.jsonl
# On the node, so an engine restarted for the next arm reuses the weights rather than downloading them again.
PP_CACHE_HOSTPATH=/var/lib/pilot-hf-cache
# The registered batch budget and the base manifest's, which the renderer replaces exactly once.
PP_BUDGET=512
PP_BASE_BUDGET=2048
# The prospective arm's caps, and the static arm's frozen burst and threshold (design page, "Arms").
PP_PROSPECTIVE_PREFILL=30000
PP_PROSPECTIVE_STREAMS=4
PP_STATIC_BURST=30000
PP_STATIC_THRESHOLD=1
# The admission diagnostic's two treatments (design page, "v25"): the engine's per-step prefill cap and the
# gateway's serial-prefill hold.
PP_DIAG_PREFILL_CAP=384
PP_DIAG_MAX_HOLD=25s
PP_DIAG_STUDY=admission-diagnostic-2026-10-10
# v26, hold-cap against a frontier of fixed spacings (design page, "v26"): the gateway's fixed-spacing mode at four
# spacings, held as long as serial-prefill holds.
PP_FRONTIER_STUDY=admission-frontier-2026-10-10
PP_FRONTIER_SEEDS="861 862 863"

# The pilot, the admission diagnostic and v26 share this apparatus: its capture, sidecar, sampler and calibration.
pp_is_study() { [ "${1:-}" = "$PP_STUDY" ] || [ "${1:-}" = "$PP_DIAG_STUDY" ] || [ "${1:-}" = "$PP_FRONTIER_STUDY" ]; }

# The study a stage belongs to; a stage filed under another study would be scored by rules it was not bought under.
pp_stage_study() {
  case "${1:-}" in
    A | B) echo "$PP_STUDY" ;;
    D) echo "$PP_DIAG_STUDY" ;;
    E) echo "$PP_FRONTIER_STUDY" ;;
    *) echo "PILOT_STAGE is ${1@Q}; the stages are A, B, D and E" >&2; return 1 ;;
  esac
}

# v26's frozen trace checksums, by seed, as `benchharness gen-trace` writes them into the manifest at the study's load:
# one for every arm that replays the whole trace, and one for R1, which replays its premium rows only. Frozen in the
# registration before purchase (v26 review, B6 and C5): a lighter seed, rate or duration changes the checksum.
pp_frontier_checksum() {
  case "${1:-}:${2:-}" in
    861:R1) echo e9d7faf0b01e9daf95cdba101c6200fe43dd8cf0bf60c6f1c3903117517572c2 ;;
    861:*) echo ad83bde4313cf3ed6f4a52c7820271ca4689cb3b1d01f0dad0bd47aeeaf0f79a ;;
    862:R1) echo 1f4f471e058d7050b61fcbe8c5d240c9ccc8ef732adfb4d62498ea630e4f207c ;;
    862:*) echo 1ec48cb1c290367902b3665e6837b42582e4e4c8723fb0b8edf2fc71905d46b9 ;;
    863:R1) echo f7cff96a1d35858b179245a0e470adac222fcc7869be5dbbd766697b8f0304e7 ;;
    863:*) echo 0bff6066f348a6168236be006a232d92a581d73fea81c56e45dbf0eaebc4ca4b ;;
    *) echo "seed ${1@Q} is not one of v26's frozen seeds ($PP_FRONTIER_SEEDS)" >&2; return 1 ;;
  esac
}

# A fixed arm's spacing as a Go duration, from its name: fixed-1.62 is 1.62s. Only the registered four are accepted.
pp_fixed_spacing() {
  case "${1:-}" in
    fixed-1.62 | fixed-1.66 | fixed-1.70 | fixed-1.74) echo "${1#fixed-}s" ;;
    *) echo "arm ${1@Q} is not one of v26's fixed spacings" >&2; return 1 ;;
  esac
}

# The arms a stage buys, in the design's order: stage A has no static control, because its rate R is fitted
# from stage A's prospective arm.
pp_stage_arms() {
  case "${1:-}" in
    A) printf '%s\n' R1 off prospective ;;
    B) printf '%s\n' R1 off static-cap prospective ;;
    # The diagnostic: R1 once, then off, hold, cap and hold-cap in each block (design page, "v25").
    D) printf '%s\n' R1 off hold cap hold-cap ;;
    # v26: R1 once, then off, hold-cap and the four fixed spacings in each block (design page, "v26").
    E) printf '%s\n' R1 off hold-cap fixed-1.62 fixed-1.66 fixed-1.70 fixed-1.74 ;;
    *) echo "PILOT_STAGE is ${1@Q}; the pilot has stages A and B, the diagnostic stage D and v26 stage E" >&2; return 1 ;;
  esac
}

# The engine's per-step prefill cap for an arm: the diagnostic's cap and hold-cap arms and v26's fixed arms run with
# it, the other registered arms with none. An unregistered arm is refused: a default of 0 would run a fixed arm
# uncapped and the validator, reading the same answer, would approve it (v26 review, C2).
pp_arm_prefill_cap() {
  case "${1:-}" in
    cap | hold-cap | fixed-1.62 | fixed-1.66 | fixed-1.70 | fixed-1.74) echo "$PP_DIAG_PREFILL_CAP" ;;
    R1 | off | hold | prospective | static-cap) echo 0 ;;
    *) echo "arm ${1@Q} has no registered prefill cap" >&2; return 1 ;;
  esac
}

# The arguments every pilot engine adds to the base manifest, one per line, in the order they are inserted; $2 is the
# arm's prefill cap, 0 for none.
pp_engine_args() {
  local rev="${1:-}" cap="${2:-0}"
  [[ "$rev" =~ ^[0-9a-f]{40}$ ]] || {
    echo "the pilot pins the engine's model and tokenizer revision and was given ${rev@Q}, which is not a 40-character commit SHA"
    return 1; }
  printf '%s\n' --scheduling-policy=priority --no-async-scheduling --enable-logging-iteration-details \
    "--scheduler-cls=$PP_CLASS" "--revision=$rev" "--tokenizer-revision=$rev"
  [ "$cap" = 0 ] || printf '%s\n' "--long-prefill-token-threshold=$cap"
}

# Writes the pilot engine's manifest to $2 from the base manifest $1, pinning revision $3.
#
# Four changes, each at a line the base has exactly once, and proved: the result minus exactly the changed lines
# equals the base, so a change that landed twice, nowhere, or inside a comment refuses instead of deploying.
#   the budget line is replaced by the registered budget;
#   the pilot's arguments go after the `- --port=8000` line;
#   the plugin's environment, mounts and ConfigMap volume go after the container's image, volumeMounts and
#   volumes lines;
#   the hf-cache volume's emptyDir becomes a hostPath, so weights survive the engine's restart between arms.
pp_render_manifest() {
  local base="$1" dest="$2" rev="${3:-}" cap="${4:-0}" extra anchor n removed added want_added
  extra=$(pp_engine_args "$rev" "$cap") || { echo "$extra"; return 1; }
  for anchor in '^[[:space:]]*- --port=8000[[:space:]]*$' "^[[:space:]]*- --max-num-batched-tokens=$PP_BASE_BUDGET[[:space:]]*\$" \
                '^[[:space:]]*image: ' '^[[:space:]]*volumeMounts:[[:space:]]*$' '^[[:space:]]*volumes:[[:space:]]*$'; do
    n=$(grep -cE "$anchor" "$base") || true
    [ "$n" = 1 ] || { echo "$base has $n lines matching $anchor and the pilot changes exactly one"; return 1; }
  done
  # hf-cache is named twice, as a mount and as a volume; only the volume, after `volumes:`, is changed.
  n=$(grep -cE '^[[:space:]]*- name: hf-cache[[:space:]]*$' "$base") || true
  [ "$n" = 2 ] || { echo "$base names hf-cache $n times, not as one mount and one volume"; return 1; }
  EXTRA="$extra" STEP_LOG="$PP_STEP_LOG" CM="$PP_CONFIGMAP" BUDGET="$PP_BUDGET" BASE_BUDGET="$PP_BASE_BUDGET" \
  CACHE="$PP_CACHE_HOSTPATH" awk '
    function ind(line) { s = line; sub(/[^ ].*/, "", s); return s }
    # The hf-cache volume: its next line is the emptyDir this replaces.
    in_cache && /emptyDir/ { print ind($0) "hostPath:"; print ind($0) "  path: " ENVIRON["CACHE"]; print ind($0) "  type: DirectoryOrCreate"; in_cache = 0; next }
    $0 ~ "^[[:space:]]*- --max-num-batched-tokens=" ENVIRON["BASE_BUDGET"] "[[:space:]]*$" {
      print ind($0) "- --max-num-batched-tokens=" ENVIRON["BUDGET"]; next
    }
    { print }
    /^[[:space:]]*- name: hf-cache[[:space:]]*$/ { if (seen_mounts_volumes) in_cache = 1 }
    /^[[:space:]]*- --port=8000[[:space:]]*$/ {
      i = ind($0); k = split(ENVIRON["EXTRA"], a, "\n")
      for (j = 1; j <= k; j++) if (a[j] != "") print i "- " a[j]
    }
    /^[[:space:]]*image: / {
      i = ind($0)
      print i "env:"; print i "  - name: PYTHONPATH"; print i "    value: /opt/step-plugin"
      print i "  - name: STEP_LOG_PATH"; print i "    value: " ENVIRON["STEP_LOG"]
    }
    /^[[:space:]]*volumeMounts:[[:space:]]*$/ {
      i = ind($0)
      print i "  - name: step-plugin"; print i "    mountPath: /opt/step-plugin"; print i "    readOnly: true"
      print i "  - name: steplog"; print i "    mountPath: /var/log/pilot-step"
    }
    /^[[:space:]]*volumes:[[:space:]]*$/ {
      seen_mounts_volumes = 1; i = ind($0)
      print i "  - name: step-plugin"; print i "    configMap:"; print i "      name: " ENVIRON["CM"]
      print i "  - name: steplog"; print i "    emptyDir: {}"
    }
  ' "$base" > "$dest" || { echo "could not write $dest"; return 1; }
  # Exactly: the budget line and the hf-cache emptyDir removed; the budget, six arguments, five environment,
  # five mount, five volume and three hostPath lines added.
  removed=$(diff "$base" "$dest" | grep -c '^<') || true
  added=$(diff "$base" "$dest" | grep -c '^>') || true
  want_added=25
  [ "$cap" = 0 ] || want_added=26
  [ "$removed" = 2 ] && [ "$added" = "$want_added" ] \
    || { echo "rendering the pilot engine changed $base by $removed removed and $added added lines, not 2 and $want_added"; return 1; }
  grep -qxE "[[:space:]]*- --max-num-batched-tokens=$PP_BUDGET" "$dest" \
    || { echo "the rendered manifest does not carry the registered budget of $PP_BUDGET"; return 1; }
  grep -qE "^[[:space:]]*path: $PP_CACHE_HOSTPATH\$" "$dest" \
    || { echo "the rendered manifest does not mount the weights from $PP_CACHE_HOSTPATH"; return 1; }
}

# The gateway's arguments for an arm, one per line. $2 is the static arm's rate R, required for that arm only.
#
# Every arm binds priority, enforces the benchmark profile and writes the per-request record; the arms differ
# only in admission (design page, "Arms").
pp_gateway_args() {
  local arm="$1" rate="${2:-}"
  printf '%s\n' -bind-priority -enforce-benchmark-profile "-request-record-path=$PP_GATEWAY_RECORD"
  case "$arm" in
    # The diagnostic's cap arm differs from off only in the engine.
    R1 | off | cap) printf '%s\n' -admission-mode=off ;;
    hold | hold-cap) printf '%s\n' -admission-mode=serial-prefill "-admission-serial-prefill-max-hold=$PP_DIAG_MAX_HOLD" ;;
    # v26's controls: the same longest hold as serial-prefill, so the two differ only in what releases a contender.
    fixed-*)
      local spacing
      spacing=$(pp_fixed_spacing "$arm") || return 1
      printf '%s\n' -admission-mode=fixed-spacing "-admission-fixed-spacing=$spacing" "-admission-fixed-spacing-max-hold=$PP_DIAG_MAX_HOLD" ;;
    static-cap)
      [[ "$rate" =~ ^[1-9][0-9]*$ ]] || {
        echo "the static arm runs at the rate R fitted in stage A, and PILOT_STATIC_RATE is ${rate@Q}, which is not a positive integer" >&2
        return 1; }
      printf '%s\n' -admission-mode=static-cap "-admission-long-threshold=$PP_STATIC_THRESHOLD" \
        "-admission-static-burst=$PP_STATIC_BURST" "-admission-static-rate=$rate" ;;
    prospective)
      printf '%s\n' -admission-mode=prospective "-admission-prospective-prefill-tokens=$PP_PROSPECTIVE_PREFILL" \
        "-admission-prospective-streams=$PP_PROSPECTIVE_STREAMS" ;;
    *) echo "arm ${arm@Q} is not one of the pilot's" >&2; return 1 ;;
  esac
}

# The gateway's arguments as the YAML flow list its Deployment carries.
pp_gateway_args_yaml() {
  local args
  args=$(pp_gateway_args "$@") || return 1
  printf '%s\n' "$args" | awk 'BEGIN {printf "["} NR > 1 {printf ", "} {printf "\"%s\"", $0} END {printf "]"}'
}

# The replay's request-ID prefix: stage, arm and block, so every ID is unique across the whole pilot.
pp_request_id_flag() {
  local stage="$1" arm="$2" rep="$3"
  case "$stage" in A | B | D | E) ;; *) echo "PILOT_STAGE is ${stage@Q}" >&2; return 1 ;; esac
  printf -- '--request-id-prefix=pp-%s-%s-%s\n' "$stage" "$arm" "$rep"
}

# The non-default arguments every pilot engine must report, as Python prints them, one key=value per line.
#
# Every key the registration names must appear with its value, and any other non-default key refuses the engine
# (design page, build item 5): a validator that read a subset passed an engine with prefix caching on, bfloat16
# and one sequence. The model and port are positional or infrastructure, and are compared for presence only.
pp_expected_args() {
  local rev="$PP_MODEL_REVISION" cap="${1:-0}"
  cat <<EOF
model_tag='$PP_MODEL'
model='$PP_MODEL'
EOF
  cat <<EOF
dtype='half'
max_model_len=16384
max_num_seqs=64
gpu_memory_utilization=0.9
enable_prefix_caching=False
max_num_batched_tokens=$PP_BUDGET
scheduling_policy='priority'
async_scheduling=False
enable_logging_iteration_details=True
scheduler_cls='$PP_CLASS'
revision='$rev'
tokenizer_revision='$rev'
EOF
  # The prefill cap is registered only where the arm runs it; anywhere else it is an unregistered key.
  [ "$cap" = 0 ] || echo "long_prefill_token_threshold=$cap"
}

# Refuses an engine whose `non-default args: {...}` line ($1) is not exactly the registered configuration.
#
# The line is parsed as a Python literal rather than grepped, so a key cannot match inside another key's name and
# a value cannot be matched by a prefix. Keys allowed to differ in value only: model_tag and model (the model),
# port and host.
pp_process_args_refusal() {
  local line="$1" cap="${2:-0}" expected
  expected=$(pp_expected_args "$cap")
  # A rehearsal's stub serves no model and calls itself 'stub'; only a run that waived the engine pin, which no
  # paid run may carry, is excused the model keys' values. Their presence is still required.
  local waive_model="${ENGINE_PIN_WAIVED:-}"
  python3 - "$line" "$expected" "$waive_model" <<'PY'
import ast, sys
line, expected, waive_model = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
start = line.find("{")
if not line.startswith("non-default args:") and "non-default args:" not in line or start < 0:
    print("the engine printed no non-default args line, so its configuration is unknown"); sys.exit(1)
try:
    got = ast.literal_eval(line[start:])
except Exception as e:
    print("the engine's non-default args line could not be parsed: %s" % e); sys.exit(1)
want = {}
for kv in expected.strip().splitlines():
    k, v = kv.split("=", 1)
    want[k] = ast.literal_eval(v)
# Port and host are infrastructure and may appear or not. The model keys must appear, with the registered model,
# unless the engine pin was waived for a rehearsal.
optional = {"port", "host"}
problems = []
for k, v in want.items():
    if k not in got:
        problems.append("%s is missing" % k)
    elif got[k] != v and not (waive_model and k in ("model_tag", "model")):
        problems.append("%s is %r, registered %r" % (k, got[k], v))
for k in got:
    if k not in want and k not in optional:
        problems.append("%s=%r is not in the registration" % (k, got[k]))
if problems:
    print("the engine is not the registered apparatus: " + "; ".join(sorted(problems))); sys.exit(1)
PY
}

PP_EVIDENCE=hack/prospective-pilot/pilot_evidence.py
# The whole barrier and capture after a replay, bounded (design page, "The fence" and pilot review 9, finding 4).
PP_CAPTURE_BOUND_S="${PP_CAPTURE_BOUND_S:-300}"
PP_FENCE_PORT="${PP_FENCE_PORT:-18081}"

# Appends one phase stamp, in UTC, to the cell's phase record.
pp_phase() {
  local label="$1" rep="$2" phase="$3"
  printf '%s\t%s\t%s\t%s\n' "$label" "$rep" "$phase" "$(date -u +%Y-%m-%dT%H:%M:%S.%NZ)" >> "$OUT/phases.tsv"
}

# Captures one pilot cell's evidence after its replay returned, within PP_CAPTURE_BOUND_S seconds.
#
# Exit 0: the cell's evidence is complete. Exit 1: the arm is ineligible for calibration (the reason is written
# to ineligible-<label>-<rep>.txt) and acquisition goes on. Exit 3: the apparatus was not the registered one, and
# the pilot stops; the reason is printed.
#
#   1. The fence: one request straight to the engine, after the window. Synchronous scheduling runs one step at a
#      time, so its completion means every step that began before the window end has run and been logged.
#   2. The sentinel, rewritten until the step logger's terminal record says everything produced was written.
#   3. The step log, the engine's own iteration log, and the gateway's record. The gateway image has no shell, so
#      its emptyDir is read from the node, by the pod's UID, before the namespace is deleted.
#   4. The priority witness: every request the scheduler received at its tier's priority.
# Whether something already listens on a local port. A helper's port-forward that lost the race for its port fails
# quietly, and curl then reads whatever owns the port, a stale engine's metrics or a stale fence, as this cell's
# (v26 review, C27).
pp_port_taken() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

pp_capture() {
  local label="$1" rep="$2" deadline pod gwpod node uid pf code why=""
  # $3 is when the replay returned; the bound runs from there, not from when capture starts.
  deadline=$(( ${3:-$(date +%s)} + PP_CAPTURE_BOUND_S ))
  # Every blocking command runs under the time left, so a stalled exec, log read or node read cannot outlast the
  # bound; the deadline is otherwise only checked between iterations (review of 20cbf33).
  left() { local l=$(( deadline - $(date +%s) )); [ "$l" -gt 0 ] && echo "$l" || echo 1; }
  expired() { [ "$(date +%s)" -ge "$deadline" ]; }
  pod=$(timeout "$(left)" kubectl --context "$KCTX" get pods -n "$NS_A" -l app.kubernetes.io/component=vllm -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  [ -n "$pod" ] || { pp_ineligible "$label" "$rep" "no engine pod to capture from"; return 1; }

  ! pp_port_taken "$PP_FENCE_PORT" || { pp_ineligible "$label" "$rep" "port $PP_FENCE_PORT was already in use before the fence's forward"; return 1; }
  kubectl --context "$KCTX" port-forward -n "$NS_A" "pod/$pod" "$PP_FENCE_PORT:8000" >"$OUT/fence-forward-$label-$rep.log" 2>&1 &
  pf=$!
  code=000
  while [ "$(date +%s)" -lt "$deadline" ]; do
    # left() never answers below one second: a budget computed across the second's boundary was 0, which curl
    # reads as no timeout at all (v26 review, C28).
    code=$(curl -sS -o "$OUT/fence-$label-$rep.json" -w '%{http_code}' --max-time "$(left)" \
      -H 'Content-Type: application/json' -H "X-Request-Id: fence-$label-$rep" \
      -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"x\"}],\"max_tokens\":1}" \
      "http://127.0.0.1:$PP_FENCE_PORT/v1/chat/completions" 2>/dev/null) || code=000
    [ "$code" = 200 ] && break
    sleep 1
  done
  kill "$pf" 2>/dev/null || true; wait "$pf" 2>/dev/null || true
  [ "$code" = 200 ] || { pp_ineligible "$label" "$rep" "the fence did not complete within the bound (last status $code)"; return 1; }
  pp_phase "$label" "$rep" fence-done

  local term=2
  while [ "$(date +%s)" -lt "$deadline" ]; do
    timeout "$(left)" kubectl --context "$KCTX" exec -n "$NS_A" "$pod" -- touch "$PP_STEP_LOG.sentinel" >/dev/null 2>&1 || true
    sleep 2
    timeout "$(left)" kubectl --context "$KCTX" exec -n "$NS_A" "$pod" -- cat "$PP_STEP_LOG" > "$OUT/step-log-$label-$rep.jsonl" 2>/dev/null || true
    if why=$(python3 "$PP_EVIDENCE" terminal "$OUT/step-log-$label-$rep.jsonl"); then term=0; break; fi
  done
  pp_phase "$label" "$rep" terminal-read
  timeout "$(left)" kubectl --context "$KCTX" logs -n "$NS_A" "$pod" > "$OUT/engine-log-$label-$rep.txt" 2>/dev/null \
    || why="${why:+$why; }the engine's own log could not be read"

  if ! node=$(pp_read_gateway_record "$OUT/gateway-record-$label-$rep.jsonl" "$deadline"); then
    why="${why:+$why; }the gateway's record could not be read from node ${node:-unknown}"
  fi
  pp_phase "$label" "$rep" capture-done

  # The priority witness runs before the bound is judged: a complete step log that shows a request at the wrong
  # priority is an apparatus fault, and a later read running out of time must not demote it to ineligibility
  # (review of ffe3047).
  local prio prc=2
  if [ "$term" = 0 ]; then
    # The status is taken beside the call: inside `if ! cmd`, $? is the negation's, which is always 0.
    prio=$(python3 "$PP_EVIDENCE" priority "$OUT/step-log-$label-$rep.jsonl" "$OUT/raw-$label-$rep.jsonl") && prc=0 || prc=$?
    [ "$prc" != 1 ] || { echo "$prio"; return 3; }
  fi
  if expired; then
    pp_ineligible "$label" "$rep" "the capture did not finish within ${PP_CAPTURE_BOUND_S}s of the replay's return${why:+: $why}"
    return 1
  fi
  if [ "$term" != 0 ]; then pp_ineligible "$label" "$rep" "${why:-the step log never showed a complete terminal record}"; return 1; fi
  [ "$prc" = 0 ] || { pp_ineligible "$label" "$rep" "$prio"; return 1; }
  [ -z "$why" ] || { pp_ineligible "$label" "$rep" "$why"; return 1; }
  return 0
}

# pp_read_gateway_record copies the gateway's record to dest before the epoch deadline, and prints the node.
# Each call is bounded by the time left when it starts, so the four together cannot outlast the deadline; a duration
# passed once was spent four times over (review of a0602d0).
# The gateway image has no shell, so its emptyDir is read from the node, by the pod's UID.
pp_read_gateway_record() {
  local dest="$1" deadline="$2" gwpod node uid
  _gl() { local l=$(( deadline - $(date +%s) )); [ "$l" -gt 0 ] && echo "$l" || echo 1; }
  gwpod=$(timeout "$(_gl)" kubectl --context "$KCTX" get pods -n "$NS_A" -l app=m5c-gateway -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  node=$(timeout "$(_gl)" kubectl --context "$KCTX" get pod -n "$NS_A" "$gwpod" -o jsonpath='{.spec.nodeName}' 2>/dev/null)
  uid=$(timeout "$(_gl)" kubectl --context "$KCTX" get pod -n "$NS_A" "$gwpod" -o jsonpath='{.metadata.uid}' 2>/dev/null)
  printf '%s' "$node"
  # Read to a temporary file and moved over dest only when the read succeeded with something in it: a failed read
  # truncated dest, and the sidecar then uploaded the empty file over the last good snapshot (v26 review, C29).
  [ -n "$node" ] && [ -n "$uid" ] && timeout "$(_gl)" docker exec "$node" cat \
    "/var/lib/kubelet/pods/$uid/volumes/kubernetes.io~empty-dir/gwrecord/$(basename "$PP_GATEWAY_RECORD")" > "$dest.tmp" 2>/dev/null \
    && [ -s "$dest.tmp" ] && mv -f "$dest.tmp" "$dest" || { rm -f "$dest.tmp"; return 1; }
}

# The evidence sidecar (design page, "Rows leave the instance as they are written", build item 8): during a replay,
# every PP_SIDECAR_INTERVAL_S seconds, and at once when PP_SPOT_NOTICE_FILE appears, it hands the live rows and a
# fresh copy of the gateway's record to CELL_SIDECAR_HOOK, which the paid session points at S3. Each upload's
# interval goes to sidecar-uploads.tsv, because an upload is part of the apparatus whose timing the pilot measures.
# Without a hook it does nothing, as on kind unless the rehearsal gives one.
PP_SIDECAR_INTERVAL_S="${PP_SIDECAR_INTERVAL_S:-30}"
PP_SIDECAR_HOOK_TIMEOUT_S=25
pp_sidecar_upload() {
  local label="$1" rep="$2" trigger="$3" t0 t1 rc bytes
  local raw="$OUT/live-raw-$label-$rep.jsonl" gw="$OUT/live-gateway-record-$label-$rep.jsonl"
  t0=$(date +%s%N)
  pp_read_gateway_record "$gw" $(( $(date +%s) + 10 )) >/dev/null || true
  timeout "$PP_SIDECAR_HOOK_TIMEOUT_S" "$CELL_SIDECAR_HOOK" "$raw" "$gw" "$label" "$rep" >/dev/null 2>&1 && rc=0 || rc=$?
  t1=$(date +%s%N)
  bytes=$(( $(stat -c %s "$raw" 2>/dev/null || echo 0) + $(stat -c %s "$gw" 2>/dev/null || echo 0) ))
  [ -s "$OUT/sidecar-uploads.tsv" ] || printf 'cell\ttrigger\tstart_unix_ns\tend_unix_ns\thook_rc\tbytes\n' > "$OUT/sidecar-uploads.tsv"
  printf '%s-%s\t%s\t%s\t%s\t%s\t%s\n' "$label" "$rep" "$trigger" "$t0" "$t1" "$rc" "$bytes" >> "$OUT/sidecar-uploads.tsv"
}
# Started at the replay's start, in the background; it ends itself when the matrix that started it is gone.
pp_sidecar_start() {
  local label="$1" rep="$2" parent=$$
  PP_SIDECAR_PID=""
  [ -n "${CELL_SIDECAR_HOOK:-}" ] || return 0
  # In WORK, not OUT: the matrix counts every file in OUT, dotfiles included.
  PP_SIDECAR_STOP="${WORK:-$OUT}/sidecar-stop-$label-$rep"
  rm -f "$PP_SIDECAR_STOP"
  (
    next=$(( $(date +%s) + PP_SIDECAR_INTERVAL_S )); noticed=""
    while kill -0 "$parent" 2>/dev/null && [ ! -e "$PP_SIDECAR_STOP" ]; do
      if [ -z "$noticed" ] && [ -n "${PP_SPOT_NOTICE_FILE:-}" ] && [ -e "$PP_SPOT_NOTICE_FILE" ]; then
        noticed=1
        pp_sidecar_upload "$label" "$rep" spot-notice
      elif [ "$(date +%s)" -ge "$next" ]; then
        pp_sidecar_upload "$label" "$rep" interval
        next=$(( $(date +%s) + PP_SIDECAR_INTERVAL_S ))
      fi
      sleep 1
    done
  ) &
  PP_SIDECAR_PID=$!
  PP_BACKGROUND_PIDS="${PP_BACKGROUND_PIDS:-} $!"
}
# Stopped by a flag the loop reads between uploads, without waiting, so an upload in flight neither eats into the
# capture's bound nor loses its row: a TERM deferred until the hook returned exited before the row was written
# (review of a0602d0). The per-cell hook sends the complete files after the capture.
pp_sidecar_stop() {
  [ -n "${PP_SIDECAR_PID:-}" ] || return 0
  : > "$PP_SIDECAR_STOP"
  PP_SIDECAR_PID=""
}

# The engine sampler: during a replay, every PP_SAMPLE_INTERVAL_S seconds, the engine's running and waiting requests,
# KV-cache usage and preemption count, into engine-samples-<cell>.tsv. These are SAMPLES: a peak or a stretch with every
# slot taken can fall between two of them, so they are published as sampled observations and never as a maximum or a
# duration (v25 review, finding 7). vLLM publishes the gauges from finished steps, so a sample is the state at the last
# step's end. A read that fails leaves a "scrape-failed" row, so a gap in the series is visible as one. The cadence is
# held to the interval from each sample's start, not stretched by the read. Its own port-forward, on its own port.
PP_SAMPLE_INTERVAL_S="${PP_SAMPLE_INTERVAL_S:-1}"
PP_SAMPLE_PORT="${PP_SAMPLE_PORT:-18083}"
pp_sampler_start() {
  local label="$1" rep="$2" parent=$$ out="$OUT/engine-samples-$1-$2.tsv"
  PP_SAMPLER_STOP="${WORK:-$OUT}/sampler-stop-$label-$rep"
  rm -f "$PP_SAMPLER_STOP"
  printf 'unix_ms\tmetric\tvalue\n' > "$out"
  if pp_port_taken "$PP_SAMPLE_PORT"; then
    printf '%s\tport-taken\t\n' "$(( $(date +%s%N) / 1000000 ))" >> "$out"
    PP_SAMPLER_PID=""
    return 0
  fi
  (
    kubectl --context "$KCTX" port-forward -n "$NS_A" deploy/vllm-qwen25-3b "$PP_SAMPLE_PORT:8000" \
      > "${WORK:-$OUT}/sampler-pf-$label-$rep.log" 2>&1 &
    pf=$!
    trap 'kill $pf 2>/dev/null' EXIT
    while kill -0 "$parent" 2>/dev/null && [ ! -e "$PP_SAMPLER_STOP" ]; do
      # Milliseconds from nanoseconds: this date prints all nine digits for %3N, so the width is not trusted.
      now=$(( $(date +%s%N) / 1000000 ))
      if page=$(curl -sf --max-time 1 "http://127.0.0.1:$PP_SAMPLE_PORT/metrics" 2>/dev/null); then
        printf '%s\n' "$page" | awk -v t="$now" '/^vllm:(num_requests_running|num_requests_waiting|kv_cache_usage_perc|num_preemptions_total)\{/ {
            name = $1; sub(/\{.*/, "", name); printf "%s\t%s\t%s\n", t, name, $NF }' >> "$out"
      else
        printf '%s\tscrape-failed\t\n' "$now" >> "$out"
      fi
      # Sleep what is left of the interval after the read, so a slow read does not stretch the cadence.
      left=$(awk -v i="$PP_SAMPLE_INTERVAL_S" -v t0="$now" -v t1="$(( $(date +%s%N) / 1000000 ))" 'BEGIN { d = i - (t1 - t0) / 1000; print (d > 0 ? d : 0) }')
      sleep "$left"
    done
  ) &
  PP_SAMPLER_PID=$!
  PP_BACKGROUND_PIDS="${PP_BACKGROUND_PIDS:-} $!"
}

# Waits, at most PP_BACKGROUND_WAIT_S, for every sidecar and sampler this matrix started, so the archive is not read
# while one is still copying or appending its last row (v26 review, C30). The stops only set flags, so a capture's
# bound is not spent here; this runs once, before the archive is closed.
PP_BACKGROUND_WAIT_S="${PP_BACKGROUND_WAIT_S:-40}"
pp_wait_background() {
  local pid deadline=$(( $(date +%s) + PP_BACKGROUND_WAIT_S ))
  for pid in ${PP_BACKGROUND_PIDS:-}; do
    while kill -0 "$pid" 2>/dev/null && [ "$(date +%s)" -lt "$deadline" ]; do sleep 1; done
    kill -0 "$pid" 2>/dev/null && { say "a background writer, pid $pid, was still running after ${PP_BACKGROUND_WAIT_S}s and was stopped"; kill "$pid" 2>/dev/null; }
  done
  PP_BACKGROUND_PIDS=""
}
pp_sampler_stop() {
  [ -n "${PP_SAMPLER_PID:-}" ] || return 0
  : > "$PP_SAMPLER_STOP"
  PP_SAMPLER_PID=""
}

# Records why a cell is ineligible for calibration; the cell's measurements are still reported.
pp_ineligible() {
  printf '%s\n' "$3" > "$OUT/ineligible-$1-$2.txt"
  say "  $1 rep $2 is ineligible for calibration: $3"
}

# Checks the study's frozen exact token counts against this session's engine, once, after the first cell's
# evidence is captured, so its calib- requests appear in no arm's step log (design page, build item 18).
# Exit 0 when the engine counts what was frozen; otherwise prints why, and the pilot stops: every trace was
# stamped from those counts, so an engine that disagrees is not the apparatus they describe.
pp_calibrate() {
  local pod pf out rc
  pod=$(k get pods -n "$NS_A" -l app.kubernetes.io/component=vllm -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  [ -n "$pod" ] || { echo "no engine pod to calibrate against"; return 1; }
  ! pp_port_taken "$PP_FENCE_PORT" || { echo "port $PP_FENCE_PORT was already in use before the calibration's forward, so its answers could be another engine's"; return 1; }
  kubectl --context "$KCTX" port-forward -n "$NS_A" "pod/$pod" "$PP_FENCE_PORT:8000" >"$OUT/calibration-forward.log" 2>&1 &
  pf=$!
  # Wait for the tunnel rather than a fixed two seconds: a probe sent before it listens fails as a connection
  # error, and verify-exact-tokens does not retry, so a slow tunnel read as a token mismatch (review of bc74ce0).
  local i ready=""
  for i in $(seq 1 60); do
    kill -0 "$pf" 2>/dev/null || break
    if curl -sS -o /dev/null --max-time 2 "http://127.0.0.1:$PP_FENCE_PORT/v1/models" 2>/dev/null; then ready=1; break; fi
    sleep 1
  done
  if [ -z "$ready" ]; then
    kill "$pf" 2>/dev/null || true; wait "$pf" 2>/dev/null || true
    echo "the calibration tunnel to $pod never answered within 60s, so the engine's counts were not checked: $(tail -1 "$OUT/calibration-forward.log" 2>/dev/null)"
    return 1
  fi
  out=$("$WORK/benchharness" verify-exact-tokens --study "$STUDY" --engine-url "http://127.0.0.1:$PP_FENCE_PORT" --model "$MODEL" 2>&1) \
    && rc=0 || rc=$?
  kill "$pf" 2>/dev/null || true; wait "$pf" 2>/dev/null || true
  printf '%s\n' "$out" > "$OUT/calibration.txt"
  [ "$rc" = 0 ] || { printf '%s\n' "$out" | tail -1; return 1; }
}
