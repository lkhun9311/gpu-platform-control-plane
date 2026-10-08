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

pp_is_study() { [ "${1:-}" = "$PP_STUDY" ]; }

# The arms a stage buys, in the design's order: stage A has no static control, because its rate R is fitted
# from stage A's prospective arm.
pp_stage_arms() {
  case "${1:-}" in
    A) printf '%s\n' R1 off prospective ;;
    B) printf '%s\n' R1 off static-cap prospective ;;
    *) echo "PILOT_STAGE is ${1@Q}; the pilot has stages A and B" >&2; return 1 ;;
  esac
}

# The arguments every pilot engine adds to the base manifest, one per line, in the order they are inserted.
pp_engine_args() {
  local rev="${1:-}"
  [[ "$rev" =~ ^[0-9a-f]{40}$ ]] || {
    echo "the pilot pins the engine's model and tokenizer revision and was given ${rev@Q}, which is not a 40-character commit SHA"
    return 1; }
  printf '%s\n' --scheduling-policy=priority --no-async-scheduling --enable-logging-iteration-details \
    "--scheduler-cls=$PP_CLASS" "--revision=$rev" "--tokenizer-revision=$rev"
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
  local base="$1" dest="$2" rev="${3:-}" extra anchor n removed added
  extra=$(pp_engine_args "$rev") || { echo "$extra"; return 1; }
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
  [ "$removed" = 2 ] && [ "$added" = 25 ] \
    || { echo "rendering the pilot engine changed $base by $removed removed and $added added lines, not 2 and 25"; return 1; }
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
    R1 | off) printf '%s\n' -admission-mode=off ;;
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
  case "$stage" in A | B) ;; *) echo "PILOT_STAGE is ${stage@Q}" >&2; return 1 ;; esac
  printf -- '--request-id-prefix=pp-%s-%s-%s\n' "$stage" "$arm" "$rep"
}

# The non-default arguments every pilot engine must report, as Python prints them, one key=value per line.
#
# Every key the registration names must appear with its value, and any other non-default key refuses the engine
# (design page, build item 5): a validator that read a subset passed an engine with prefix caching on, bfloat16
# and one sequence. The model and port are positional or infrastructure, and are compared for presence only.
pp_expected_args() {
  local rev="$PP_MODEL_REVISION"
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
}

# Refuses an engine whose `non-default args: {...}` line ($1) is not exactly the registered configuration.
#
# The line is parsed as a Python literal rather than grepped, so a key cannot match inside another key's name and
# a value cannot be matched by a prefix. Keys allowed to differ in value only: model_tag and model (the model),
# port and host.
pp_process_args_refusal() {
  local line="$1" expected
  expected=$(pp_expected_args)
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

  kubectl --context "$KCTX" port-forward -n "$NS_A" "pod/$pod" "$PP_FENCE_PORT:8000" >"$OUT/fence-forward-$label-$rep.log" 2>&1 &
  pf=$!
  code=000
  while [ "$(date +%s)" -lt "$deadline" ]; do
    code=$(curl -sS -o "$OUT/fence-$label-$rep.json" -w '%{http_code}' --max-time $(( deadline - $(date +%s) )) \
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

  gwpod=$(timeout "$(left)" kubectl --context "$KCTX" get pods -n "$NS_A" -l app=m5c-gateway -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  node=$(timeout "$(left)" kubectl --context "$KCTX" get pod -n "$NS_A" "$gwpod" -o jsonpath='{.spec.nodeName}' 2>/dev/null)
  uid=$(timeout "$(left)" kubectl --context "$KCTX" get pod -n "$NS_A" "$gwpod" -o jsonpath='{.metadata.uid}' 2>/dev/null)
  if [ -n "$node" ] && [ -n "$uid" ] && timeout "$(left)" docker exec "$node" cat \
       "/var/lib/kubelet/pods/$uid/volumes/kubernetes.io~empty-dir/gwrecord/$(basename "$PP_GATEWAY_RECORD")" \
       > "$OUT/gateway-record-$label-$rep.jsonl" 2>/dev/null; then
    :
  else
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
