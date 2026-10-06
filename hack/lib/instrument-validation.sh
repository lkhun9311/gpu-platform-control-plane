# What the instrument-validation studies change about a cell, in one place both runners source.
#
# docs/superpowers/specs/2026-10-05-can-the-stock-engine-time-an-iteration-instrument-validation.md registers
# nine arms whose names carry two facts the harness must act on: the episode type (serial, burst, stagger)
# decides the trace length, and the suffix (-log, -nolog, -async) decides the engine's arguments.
# docs/superpowers/specs/2026-10-05-instrument-validation-session-2.md keeps the nine arms and their engine
# arguments, changes the trace lengths, and adds a verified warm-up before every cell's measured replay.
# hack/m5c-gpu-session.sh needs the durations to size its credential margin and hack/m5c-matrix.sh needs all
# of it to run the cells, so a second copy in either file would be the copy that drifts.
#
# docs/superpowers/specs/2026-10-06-instrument-validation-session-3.md keeps session 2's lengths and warm-up, pins
# the model and tokenizer revision on the engine's command line, and judges gate S on the warm-up as well.
#
# docs/superpowers/specs/2026-10-06-instrument-validation-session-4.md is session 3 with one unscored 2,048/16
# conditioning request between the warm-up's cycle and its two verification requests, and it keeps the engine log
# of a cell refused at its warm-up.
#
# Every function here answers only for these four studies, and takes the study as its first argument.
# The study is passed rather than read from $STUDY so a caller cannot get session 1's lengths for a session-2
# cell by forgetting to set a global, and so a test can drive either study without exporting anything.
# A caller asks iv_is_study first, so every other study's cells never reach this file and deploy exactly
# what they deployed before it existed.
#
# Every refusal prints its reason on stdout and returns 1, so the caller decides how loudly to fail and the
# reason travels into whatever record the caller keeps.

IV_STUDY=instrument-validation-2026-10-05
IV_S2_STUDY=instrument-validation-s2-2026-10-05
IV_S3_STUDY=instrument-validation-s3-2026-10-06
IV_S4_STUDY=instrument-validation-s4-2026-10-06
# The step-boundary session (docs/superpowers/specs/2026-10-06-where-the-late-prefill-waits-step-boundary-session.md):
# session 4's episodes, warm-ups and pins, with -step arms that load hack/vllm-plugins/step_logging_scheduler.py.
IV_STEP_STUDY=step-boundary-2026-10-06
# The instrument as the -step arms load it: the ConfigMap the matrix creates from it, the class vLLM imports, and
# where the log is written inside the engine container, on an emptyDir the matrix reads before the cell ends.
IV_STEP_PLUGIN=hack/vllm-plugins/step_logging_scheduler.py
IV_STEP_CONFIGMAP=step-logging-scheduler
IV_STEP_CLASS=step_logging_scheduler.StepLoggingScheduler
IV_STEP_LOG=/steplog/step.jsonl

# Session 2's trace lengths in ms, one per episode type, as the main session measured them from the generator.
#
# Section 5 says every trace length is fixed by the generator before launch, so these were read off its spans
# rather than chosen; each is long enough for its episode type's trace at any seed.
# iv_duration_ms refuses while any of them is not a number, so a placeholder put back here stops the plan check,
# the session's credential margin and every cell alike.
IV_S2_DURATION_MS_SERIAL=500000
IV_S2_DURATION_MS_BURST=320000
IV_S2_DURATION_MS_STAGGER=2410000
# The --duration-ms each arm's warm-up trace is generated with, which gen-trace requires of an episode study.
#
# The warm-up is one cycle, not the measured trace's many, so it gets its own bound: the main session measured
# its spans at seed 11 as 87,200, 107,580 and 484,800 ms and set these above them.
# Session 3's warm-up is session 2's, and session 4's adds its conditioning request's one drained 2,000 ms gap.
# Session 4's spans are therefore taken as 89,200, 109,580 and 486,800 ms, still under every bound here.
# They are session 3's spans plus 2,000 ms, not read off a session-4 generator, which did not exist when they were written.
IV_S4_WARMUP_SPAN_MS_SERIAL=89200
IV_S4_WARMUP_SPAN_MS_BURST=109580
IV_S4_WARMUP_SPAN_MS_STAGGER=486800
IV_S2_WARMUP_DURATION_MS_SERIAL=100000
IV_S2_WARMUP_DURATION_MS_BURST=120000
IV_S2_WARMUP_DURATION_MS_STAGGER=500000

# The warm-up's verification requests must land here, by section 2 of the session-2 registration.
#
# 231 ms is session 1's warm median TTFT for a drained 2,048-token request with 16 outputs.
# Integers in per-mille so the shell can carry them; the comparison itself is done in python3.
IV_S2_WARM_TTFT_MS=231
IV_S2_WARM_TTFT_TOL_PERMILLE=50
IV_S2_WARM_PAIR_TOL_PERMILLE=20
IV_S2_WARM_TOKENS=2048

iv_is_study() { [ "${1:-}" = "$IV_STUDY" ] || [ "${1:-}" = "$IV_S2_STUDY" ] || [ "${1:-}" = "$IV_S3_STUDY" ] || [ "${1:-}" = "$IV_S4_STUDY" ] || [ "${1:-}" = "$IV_STEP_STUDY" ]; }

# Sessions 2 to 4 warm the engine before their measured replay; session 1 measured request 0 cold.
iv_has_warmup() { [ "${1:-}" = "$IV_S2_STUDY" ] || [ "${1:-}" = "$IV_S3_STUDY" ] || [ "${1:-}" = "$IV_S4_STUDY" ] || [ "${1:-}" = "$IV_STEP_STUDY" ]; }

# Only sessions 3 and 4 pin the model revision on the engine's command line and demand the engine report it back.
#
# Adding the flags to sessions 1 or 2 would change the engine their archives measured.
iv_pins_revision() { [ "${1:-}" = "$IV_S3_STUDY" ] || [ "${1:-}" = "$IV_S4_STUDY" ] || [ "${1:-}" = "$IV_STEP_STUDY" ]; }

# Only sessions 3 and 4's staggered decoders carry min_tokens = max_tokens = 512, so only there must each produce 512.
#
# Session 2's decoders could stop at end-of-sequence, and demanding 512 of them would refuse what it registered.
iv_fixes_decoder_length() { [ "${1:-}" = "$IV_S3_STUDY" ] || [ "${1:-}" = "$IV_S4_STUDY" ] || [ "${1:-}" = "$IV_STEP_STUDY" ]; }

# Only session 4's warm-up ends with a conditioning request before its two verification requests.
#
# Gate S on the warm-up drops one more tail request for it, and an earlier session's cycle would lose its last prefill.
# The step-boundary study buys session 4's warm-ups, conditioning request included (found by review: without it here
# gate S read the conditioner as a decoder episode with no prefill and refused the first staggered warm-up).
iv_conditions_warmup() { [ "${1:-}" = "$IV_S4_STUDY" ] || [ "${1:-}" = "$IV_STEP_STUDY" ]; }

# Only session 4 keeps the engine log of a cell refused at its warm-up.
#
# Session 3's refused cell had none, so the transient W caught could not be read from the engine's side.
# Sessions 2 and 3 stop exactly as their archives show.
iv_keeps_warmup_refusal_log() { [ "${1:-}" = "$IV_S4_STUDY" ] || [ "${1:-}" = "$IV_STEP_STUDY" ]; }

# The directory of instrument_gates.py, resolved once when sourced so a caller that changes directory still finds it.
#
# Empty when it is absent, and iv_stagger_refusal then refuses rather than judge nothing.
# Tested before the cd so that sourcing from a partial tree prints nothing: session 1's plan output is pinned byte for byte.
IV_GATES_DIR=""
if [ -d "$(dirname "${BASH_SOURCE[0]}")/../tail-crossing-model" ]; then
  IV_GATES_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../tail-crossing-model" && pwd) || IV_GATES_DIR=""
fi

# Refuses an arm that is not one of the study's nine, or a study that is not one of the three.
#
# Separate from the durations so the engine-argument functions do not depend on session 2's length table:
# the arguments are a property of the arm's suffix, and a length refusal should not read as an engine one.
# The message is session 1's word for word, because its harness test pins it.
iv_arm_refusal() {
  local study="${1:-}" arm="${2:-}"
  iv_is_study "$study" || {
    echo "study ${study@Q} is none of $IV_STUDY, $IV_S2_STUDY, $IV_S3_STUDY and $IV_S4_STUDY, so this file has nothing registered for it"
    return 1; }
  # The step-boundary study has its own five arms, and no other study admits a -step arm.
  if [ "$study" = "$IV_STEP_STUDY" ]; then
    case "$arm" in
      serial-log | serial-step | burst-log | burst-step | stagger-step) return 0 ;;
    esac
    echo "arm ${arm@Q} is not one of study $study's five arms (serial-log, serial-step, burst-log, burst-step, stagger-step)"
    return 1
  fi
  case "$arm" in
    serial-log | serial-nolog | serial-async | burst-log | burst-nolog | burst-async | stagger-log | stagger-nolog | stagger-async) return 0 ;;
  esac
  echo "arm ${arm@Q} is not one of study $study's nine arms ({serial,burst,stagger}-{log,nolog,async}), so it has no registered trace length"
  return 1
}

# The trace length, in ms, of one arm under one study.
#
# Each trace is a whole number of complete cycles of its episode type, and gen-trace refuses a duration
# shorter than the trace, so the duration is a property of the arm rather than of the run.
# Session 1's values are the main session's, from the generator that study registered.
iv_duration_ms() {
  local study="${1:-}" arm="${2:-}" v
  iv_arm_refusal "$study" "$arm" || return 1
  if [ "$study" = "$IV_STUDY" ]; then
    case "$arm" in
      serial-*) echo 180000 ;;
      burst-*) echo 330000 ;;
      stagger-*) echo 630000 ;;
    esac
    return 0
  fi
  case "$arm" in
    serial-*) v="$IV_S2_DURATION_MS_SERIAL" ;;
    burst-*) v="$IV_S2_DURATION_MS_BURST" ;;
    stagger-*) v="$IV_S2_DURATION_MS_STAGGER" ;;
  esac
  case "$v" in
    '' | *[!0-9]*)
      echo "study $study's trace length for $arm is still ${v@Q} in hack/lib/instrument-validation.sh; fill IV_S2_DURATION_MS_SERIAL, _BURST and _STAGGER from the generator's spans before any plan can pass"
      return 1 ;;
  esac
  echo "$v"
}

# The --duration-ms an arm's warm-up trace is generated with; only session 2 has a warm-up.
iv_warmup_duration_ms() {
  local study="${1:-}" arm="${2:-}" v s
  iv_arm_refusal "$study" "$arm" || return 1
  iv_has_warmup "$study" || { echo "study $study registers no warm-up, so it has no warm-up length"; return 1; }
  case "$arm" in
    serial-*) v="$IV_S2_WARMUP_DURATION_MS_SERIAL" ;;
    burst-*) v="$IV_S2_WARMUP_DURATION_MS_BURST" ;;
    stagger-*) v="$IV_S2_WARMUP_DURATION_MS_STAGGER" ;;
  esac
  case "$v" in
    '' | *[!0-9]*)
      echo "study $study's warm-up length for $arm is still ${v@Q} in hack/lib/instrument-validation.sh; fill IV_S2_WARMUP_DURATION_MS_SERIAL, _BURST and _STAGGER from the generator's warm-up spans before any plan can pass"
      return 1 ;;
  esac
  # Session 4 shares session 2's bounds, so a bound its longer warm-up outgrew refuses here rather than on the card.
  if [ "$study" = "$IV_S4_STUDY" ] || [ "$study" = "$IV_STEP_STUDY" ]; then
    case "$arm" in
      serial-*) s="$IV_S4_WARMUP_SPAN_MS_SERIAL" ;;
      burst-*) s="$IV_S4_WARMUP_SPAN_MS_BURST" ;;
      stagger-*) s="$IV_S4_WARMUP_SPAN_MS_STAGGER" ;;
    esac
    [ "$v" -gt "$s" ] || {
      echo "study $study's warm-up length for $arm is $v ms and its warm-up spans $s ms, so the bound does not hold the conditioning request"
      return 1; }
  fi
  echo "$v"
}

# The span a warm-up trace is charged, in ms: its last request's offset plus a fixed 30 s.
#
# The 30 s covers the last request itself and the replay client's drain, which the offsets do not show.
# One copy for both runners, because the matrix projects its deadline from it and the session its
# credential margin, and two copies of one sum are two answers to one question.
# Every non-empty row must carry an offset, or the span would be read off part of the trace.
iv_trace_span_ms() {
  local t="$1" last
  last=$(awk '
    NF { n++ }
    match($0, /"offsetMs":[0-9]+/) { v = substr($0, RSTART + 11, RLENGTH - 11) + 0; if (!k || v > m) m = v; k++ }
    END { if (n == 0 || k != n) exit 1; printf "%d\n", m }' "$t") \
    || { echo "the warm-up trace $t has no rows, or rows without an offsetMs, so its span cannot be read"; return 1; }
  echo $(( last + 30000 ))
}

# One line naming each episode type's length, for the refusals that tell an operator why DURATION_MS is refused.
iv_duration_summary() {
  local study="$1" s b g
  s=$(iv_duration_ms "$study" serial-log) || s="?"
  b=$(iv_duration_ms "$study" burst-log) || b="?"
  g=$(iv_duration_ms "$study" stagger-log) || g="?"
  echo "serial $s, burst $b, stagger $g ms"
}

# The arguments this arm appends to config/vllm/deployment.yaml, one per line.
#
# -async appends nothing: the async engine is the stock default, and the registration buys it only as the
# control the earlier archives measured.
# Session 3 appends the revision pins to every arm, from $3, which the matrix passes as its MODEL_REVISION.
# A full commit SHA is demanded because a branch or tag name would pin nothing: it moves under the same words.
iv_engine_args() {
  local rev="${3:-}"
  iv_arm_refusal "${1:-}" "${2:-}" || return 1
  if iv_pins_revision "$1"; then
    [[ "$rev" =~ ^[0-9a-f]{40}$ ]] || {
      echo "study $1 pins the engine's model and tokenizer revision and was given ${rev@Q}, which is not a 40-character commit SHA, so the pin would not name one snapshot"
      return 1; }
  fi
  case "$2" in
    *-log) printf '%s\n' --no-async-scheduling --enable-logging-iteration-details ;;
    *-step) printf '%s\n' --no-async-scheduling --enable-logging-iteration-details "--scheduler-cls=$IV_STEP_CLASS" ;;
    *-nolog) printf '%s\n' --no-async-scheduling ;;
    *-async) ;;
  esac
  if iv_pins_revision "$1"; then printf '%s\n' "--revision=$rev" "--tokenizer-revision=$rev"; fi
}

# Writes the manifest this arm deploys to $4, from the base manifest $3; $5 is the revision session 3 pins.
#
# The extra arguments go directly after the `- --port=8000` line, at that line's indentation.
# Proved rather than assumed: the result minus exactly the inserted lines must be byte-identical to the base,
# so an insertion that landed twice, nowhere, or inside a comment refuses instead of deploying.
iv_render_manifest() {
  local study="$1" arm="$2" base="$3" dest="$4" rev="${5:-}" extra anchor_n
  extra=$(iv_engine_args "$study" "$arm" "$rev") || { echo "$extra"; return 1; }
  anchor_n=$(awk '/^[[:space:]]*- --port=8000[[:space:]]*$/ {c++} END {print c+0}' "$base") \
    || { echo "could not read $base"; return 1; }
  [ "$anchor_n" = 1 ] \
    || { echo "$base has $anchor_n '- --port=8000' lines and the arguments are inserted after exactly one"; return 1; }
  EXTRA="$extra" awk '
    { print }
    /^[[:space:]]*- --port=8000[[:space:]]*$/ {
      indent = $0; sub(/-.*/, "", indent)
      n = split(ENVIRON["EXTRA"], a, "\n")
      for (i = 1; i <= n; i++) if (a[i] != "") print indent "- " a[i]
    }
  ' "$base" > "$dest" || { echo "could not write $dest"; return 1; }
  # The inserted lines are the only difference, or the manifest is not what the arm declares.
  if [ -n "$extra" ]; then
    if ! diff <(grep -vxE "[[:space:]]*- ($(printf '%s' "$extra" | paste -sd'|' -))" "$dest") "$base" >/dev/null; then
      echo "the rendered manifest for $arm differs from $base by more than the inserted arguments"
      return 1
    fi
    [ "$(grep -cxE "[[:space:]]*- ($(printf '%s' "$extra" | paste -sd'|' -))" "$dest")" = "$(printf '%s\n' "$extra" | grep -c .)" ] \
      || { echo "the rendered manifest for $arm does not carry each of its arguments exactly once"; return 1; }
  else
    cmp -s "$dest" "$base" || { echo "the rendered manifest for $arm should equal $base and does not"; return 1; }
  fi
  case "$arm" in
    *-step) iv_add_step_mounts "$dest" || return 1 ;;
  esac
}

# Prints the replay flag that tags every request of one cell and phase with X-Request-Id, for the step-boundary
# study only, so every other study's replay command stays what it was.
#
# The engine is new in every cell, so <arm>-<rep>-<phase> is unique among the requests one engine sees, and the
# warm-up's ids cannot collide with the measured replay's.
iv_request_id_flag() {
  local study="$1" arm="$2" rep="$3" phase="$4"
  [ "$study" = "$IV_STEP_STUDY" ] || return 0
  case "$phase" in warmup | measured) ;; *) echo "phase ${phase@Q} is neither warmup nor measured" >&2; return 1 ;; esac
  printf -- '--request-id-prefix=%s-%s-%s\n' "$arm" "$rep" "$phase"
}

# Adds what a -step arm's engine needs to load the instrument, to a manifest iv_render_manifest already rendered.
#
# Three insertions, each at a line the base manifest has exactly once: PYTHONPATH and STEP_LOG_PATH after the
# container's image line, the plugin and log mounts after its volumeMounts line, and the ConfigMap and emptyDir
# volumes after the pod's volumes line. Proved the way the arguments are: the result minus exactly the inserted
# lines is byte-identical to the input, so an insertion that landed twice or nowhere refuses instead of deploying.
iv_add_step_mounts() {
  local dest="$1" tmp anchor n inserted
  tmp="$dest.step"
  for anchor in '^[[:space:]]*image: vllm/' '^[[:space:]]*volumeMounts:[[:space:]]*$' '^[[:space:]]*volumes:[[:space:]]*$'; do
    n=$(grep -cE "$anchor" "$dest") || true
    [ "$n" = 1 ] || { echo "$dest has $n lines matching $anchor and the instrument's mounts go after exactly one"; return 1; }
  done
  STEP_LOG="$IV_STEP_LOG" CM="$IV_STEP_CONFIGMAP" awk '
    function ind(line) { s = line; sub(/[^ ].*/, "", s); return s }
    { print }
    /^[[:space:]]*image: vllm\// {
      i = ind($0)
      print i "env:"; print i "  - name: PYTHONPATH"; print i "    value: /opt/step-plugin"
      print i "  - name: STEP_LOG_PATH"; print i "    value: " ENVIRON["STEP_LOG"]
    }
    /^[[:space:]]*volumeMounts:[[:space:]]*$/ {
      i = ind($0)
      print i "  - name: step-plugin"; print i "    mountPath: /opt/step-plugin"; print i "    readOnly: true"
      print i "  - name: steplog"; print i "    mountPath: " substr(ENVIRON["STEP_LOG"], 1, index(substr(ENVIRON["STEP_LOG"], 2), "/"))
    }
    /^[[:space:]]*volumes:[[:space:]]*$/ {
      i = ind($0)
      print i "  - name: step-plugin"; print i "    configMap:"; print i "      name: " ENVIRON["CM"]
      print i "  - name: steplog"; print i "    emptyDir: {}"
    }
  ' "$dest" > "$tmp" || { echo "could not write $tmp"; return 1; }
  inserted=$(diff "$dest" "$tmp" | grep -c '^>') || true
  [ "$inserted" = 15 ] && [ "$(diff "$dest" "$tmp" | grep -c '^<')" = 0 ] \
    || { echo "adding the instrument's mounts changed $dest by $inserted added lines and some removed, not exactly 15 added"; return 1; }
  mv "$tmp" "$dest"
}

# Refuses a cell whose engine did not report the configuration its arm registers.
#
# $3 is the `non-default args: {...}` line vLLM printed at startup, which is the engine's own account and so
# the only one that survives an admission webhook or a flag the engine silently ignored.
# Python prints the dict with single quotes; double quotes are accepted too so a change of repr cannot turn
# a present key into a false refusal that reads like a missing one.
# $4 is the revision session 3 pinned; sessions 1 and 2 ignore it, so their cells are judged exactly as before.
iv_process_args_refusal() {
  local study="$1" arm="$2" line="${3:-}" rev="${4:-}" async_false=0 logging_true=0 step_cls=0 key pat
  iv_arm_refusal "$study" "$arm" || return 1
  case "$line" in
    "non-default args: {"*) ;;
    *)
      echo "the engine for $arm printed no non-default args line (recorded ${line:-nothing}), so which engine this cell measured cannot be read from the engine itself"
      return 1 ;;
  esac
  # Session 2's engine reported no revision at all, so the snapshot it loaded was the manifest's word alone.
  # The quote before each key keeps `revision` from matching inside `tokenizer_revision`.
  # Matched in bash rather than through a pipe, so a pipefail caller cannot read a SIGPIPE as an absent key.
  if iv_pins_revision "$study"; then
    [[ "$rev" =~ ^[0-9a-f]{40}$ ]] || {
      echo "study $study pins the engine's revision and was given ${rev@Q}, which is not a 40-character commit SHA, so the engine's report cannot be checked against it"
      return 1; }
    for key in revision tokenizer_revision; do
      pat="['\"]${key}['\"]: ['\"]${rev}['\"]"
      [[ "$line" =~ $pat ]] || {
        echo "the engine for $arm does not report '$key': '$rev' in its non-default args, so the snapshot it loaded is not the one the study pins: $line"
        return 1; }
    done
  fi
  printf '%s' "$line" | grep -qE "['\"]async_scheduling['\"]: False" && async_false=1
  printf '%s' "$line" | grep -qE "['\"]enable_logging_iteration_details['\"]: True" && logging_true=1
  # The instrument is loaded in exactly the -step cells: vLLM reports a non-default scheduler class, and a -log cell
  # that reported one would be a paired control carrying the treatment.
  if [[ "$line" =~ [\'\"]scheduler_cls[\'\"]:\ [\'\"]${IV_STEP_CLASS}[\'\"] ]]; then step_cls=1; else step_cls=0; fi
  case "$arm" in
    *-step)
      [ "$step_cls" = 1 ] || {
        echo "the engine for $arm does not report scheduler_cls '$IV_STEP_CLASS', so the instrument the arm registers was not loaded: $line"
        return 1; } ;;
    *)
      [ "$step_cls" = 0 ] || {
        echo "the engine for $arm reports scheduler_cls '$IV_STEP_CLASS' although its arm loads no instrument: $line"
        return 1; } ;;
  esac
  case "$arm" in
    *-log | *-nolog | *-step)
      [ "$async_false" = 1 ] || {
        echo "the engine for $arm does not report async_scheduling False in its non-default args, so it is not the synchronous engine the arm registers: $line"
        return 1; } ;;
    *-async)
      [ "$async_false" = 0 ] || {
        echo "the engine for $arm reports async_scheduling False, so the async control would be measured on the synchronous engine: $line"
        return 1; } ;;
  esac
  case "$arm" in
    *-log | *-step)
      [ "$logging_true" = 1 ] || {
        echo "the engine for $arm does not report enable_logging_iteration_details True, so iteration logging is off in a cell whose arm registers it on: $line"
        return 1; } ;;
    *-nolog | *-async)
      [ "$logging_true" = 0 ] || {
        echo "the engine for $arm reports enable_logging_iteration_details True although the arm registers logging off: $line"
        return 1; } ;;
  esac
  return 0
}

# Refuses a cell whose captured engine log contradicts the arm's logging setting.
#
# A -log cell with no iteration line is the failure this study exists to catch: logging silently off reads
# as an engine that ran no iterations.
# A -nolog or -async cell with one means the cell's logging overhead is not the one its arm names.
# Counted with awk because `grep -c` prints 0 and exits 1 on no match, which reads as a failed count.
iv_engine_log_refusal() {
  local study="$1" arm="$2" log="$3" n
  iv_arm_refusal "$study" "$arm" || return 1
  [ -f "$log" ] || { echo "no engine log was captured for $arm at $log"; return 1; }
  n=$(awk 'index($0, "Iteration(") {c++} END {print c+0}' "$log") \
    || { echo "could not count iteration lines in $log"; return 1; }
  # A -step arm logs iterations too: it is a -log engine with the instrument loaded.
  case "$arm" in
    *-log | *-step)
      [ "$n" -gt 0 ] || {
        echo "the engine log for $arm holds zero Iteration( lines, so iteration logging was off in a cell whose arm registers it on ($log)"
        return 1; } ;;
    *)
      [ "$n" = 0 ] || {
        echo "the engine log for $arm holds $n Iteration( line(s) although the arm registers logging off ($log)"
        return 1; } ;;
  esac
  return 0
}

# Prints the last warm-up iteration index of one cell, or `none` for an arm that logs no iterations.
#
# $3 is the engine log as it stood after the warm-up replay and before the measured one, so its highest
# Iteration(N) is the boundary the evaluator checks the measured iterations against.
# The highest rather than the last, so a line printed out of order cannot move the boundary backwards.
# A -log arm with none refuses: the boundary is what lets every warm-up iteration be accounted for, and a log
# that shows none would make the first measured iteration indistinguishable from a warm-up one.
iv_warmup_boundary() {
  local study="$1" arm="$2" log="${3:-}" n
  iv_arm_refusal "$study" "$arm" || return 1
  iv_has_warmup "$study" || { echo "study $study registers no warm-up, so it has no warm-up boundary"; return 1; }
  case "$arm" in
    *-log | *-step) ;;
    *) echo none; return 0 ;;
  esac
  [ -f "$log" ] || { echo "no engine log was read for $arm's warm-up boundary at $log"; return 1; }
  # Matches `Iteration(123):` with or without the `Engine 000: ` prefix iterlog.py also accepts.
  n=$(awk '
    { s = $0
      while (match(s, /Iteration\([0-9]+\)/)) {
        v = substr(s, RSTART + 10, RLENGTH - 11) + 0
        if (!seen || v > m) { m = v; seen = 1 }
        s = substr(s, RSTART + RLENGTH)
      } }
    END { if (seen) printf "%d\n", m }' "$log") \
    || { echo "could not read iteration indices from $log"; return 1; }
  [ -n "$n" ] || {
    echo "the engine log for $arm holds no Iteration(N) line after its warm-up, so the last warm-up iteration cannot be recorded and the measured iterations could not be told from the warm-up's ($log)"
    return 1; }
  echo "$n"
}

# Refuses a warm-up whose two verification requests do not show a warm engine (W, section 2).
#
# The last two rows by send time are the verification requests, because the warm-up trace ends with them.
# Each must be a completed 2,048-token row, each TTFT within 5% of 231 ms, and the two within 2% of each
# other, measured against the smaller so the tolerance does not widen as the pair slows.
# python3 rather than awk because the nanosecond stamps exceed a double's exact range and the rows are JSON.
# Prints nothing and returns 0 on a pass; prints the reason with both values and returns 1 otherwise.
iv_warmup_refusal() {
  local raw="$1" out rc=0
  [ -f "$raw" ] || { echo "no warm-up rows were written at $raw, so the verification requests cannot be read"; return 1; }
  out=$(IV_RAW="$raw" IV_MS="$IV_S2_WARM_TTFT_MS" IV_TOL="$IV_S2_WARM_TTFT_TOL_PERMILLE" \
    IV_PAIR="$IV_S2_WARM_PAIR_TOL_PERMILLE" IV_TOK="$IV_S2_WARM_TOKENS" python3 -c '
import json, os, sys
raw, want = os.environ["IV_RAW"], float(os.environ["IV_MS"])
tol, pair, tok = int(os.environ["IV_TOL"]) / 1000, int(os.environ["IV_PAIR"]) / 1000, int(os.environ["IV_TOK"])
rows = []
with open(raw) as f:
    for n, line in enumerate(f, 1):
        if not line.strip():
            continue
        try:
            rows.append(json.loads(line))
        except ValueError as e:
            print(f"warm-up row {n} of {raw} is not JSON ({e})")
            sys.exit(1)
rows.sort(key=lambda r: r.get("sendUnixNanos", 0))
last = rows[-2:]
def describe(r):
    first, send = r.get("firstTokenUnixNanos", 0), r.get("sendUnixNanos", 0)
    ttft = f"{(first - send) / 1e6:.3f} ms" if first > 0 and send > 0 else "no first token"
    idx, ntok, kind = r.get("index"), r.get("engineInputTokens", 0), r.get("errorKind") or "none"
    return f"index {idx} ({ntok} tokens, errorKind {kind}, TTFT {ttft})"
named = " and ".join(describe(r) for r in last) or "no rows"
why = []
if len(last) < 2:
    why.append(f"only {len(rows)} warm-up row(s), and W needs two verification requests")
for r in last:
    idx = r.get("index")
    if r.get("errorKind"):
        why.append(f"index {idx} did not complete")
    if r.get("engineInputTokens") != tok:
        why.append(f"index {idx} is not a {tok}-token request")
    if not (r.get("firstTokenUnixNanos", 0) > 0 and r.get("sendUnixNanos", 0) > 0):
        why.append(f"index {idx} has no first token")
if not why:
    a, b = [(r["firstTokenUnixNanos"] - r["sendUnixNanos"]) / 1e6 for r in last]
    for v in (a, b):
        if abs(v - want) > tol * want:
            why.append(f"{v:.3f} ms is more than {tol:.0%} from {want:g} ms")
    if abs(a - b) > pair * min(a, b):
        why.append(f"{a:.3f} ms and {b:.3f} ms differ by more than {pair:.0%} of the smaller")
if why:
    print(f"the warm-up verification requests are {named}: " + "; ".join(why) + f" ({raw})")
    sys.exit(1)
') || rc=$?
  [ "$rc" = 0 ] && return 0
  echo "${out:-python3 exited $rc and said nothing, so the verification requests were not read}"
  return 1
}

# Refuses a staggered cell whose episodes are not the registered composition (gate S); $5 is warmup or measured.
#
# measured judges trace-/raw-<arm>-<rep>.jsonl through the evaluator's own load_cell and check_stagger, so the cell
# is refused by exactly the rule the verdict will apply; for session 2 that is all it does, as before session 3.
# warmup judges warmup-trace-/raw-warmup-<arm>-<rep>.jsonl, joined with load_cell's refusals, and only the staggered
# cycle between the lone warm request at its head and the two lone verification requests at its tail.
# Session 4's tail is three lone 2,048/16 requests, its conditioning request and the two verification requests.
# The warm-up is judged too because session 2's warm-up violated S as well, and the registration stops on it before
# the measured replay is bought.
# Session 3 also refuses any staggered decoder that did not produce exactly 512 tokens and stop on its length,
# because decoders stopping early at end-of-sequence is what ended session 2.
# Decoders are found by the episode structure rather than by their cap, so a trace with no 512 cap cannot pass by
# having no decoders to check.
# A refusal prints its one-line reason; anything else (a missing file, a crash) keeps its traceback.
iv_stagger_refusal() {
  local study="$1" arm="$2" run="$3" rep="$4" phase="$5" out rc=0 fixed=0 tail=2
  iv_arm_refusal "$study" "$arm" || return 1
  iv_has_warmup "$study" || { echo "study $study registers no gate S in the harness, so it judges none"; return 1; }
  case "$arm" in
    stagger-*) ;;
    *) echo "$arm is not a staggered arm, so gate S has no episodes to judge in it"; return 1 ;;
  esac
  case "$phase" in
    warmup | measured) ;;
    *) echo "gate S was asked about phase ${phase@Q}, which is neither warmup nor measured"; return 1 ;;
  esac
  [ -n "$IV_GATES_DIR" ] \
    || { echo "hack/tail-crossing-model was not found when hack/lib/instrument-validation.sh was sourced, so gate S cannot be judged"; return 1; }
  if iv_fixes_decoder_length "$study"; then fixed=1; fi
  if iv_conditions_warmup "$study"; then tail=3; fi
  out=$(python3 -c '
import json, os, sys
gates, run, arm, rep, phase, fixed, tail = sys.argv[1:8]
tail = int(tail)
WARM_TOKENS, WARM_CAP = 2048, 16
sys.path.insert(0, gates)
import instrument_gates as g
rep = int(rep)
DECODER_TOKENS = 512

def rows(path):
    with open(path) as f:
        return [json.loads(l) for l in f if l.strip()]

try:
    if phase == "measured":
        tpath = os.path.join(run, f"trace-{arm}-{rep}.jsonl")
        rpath = os.path.join(run, f"raw-{arm}-{rep}.jsonl")
        name = arm
        reqs = g.load_cell(run, arm, rep)
    else:
        tpath = os.path.join(run, f"warmup-trace-{arm}-{rep}.jsonl")
        rpath = os.path.join(run, f"raw-warmup-{arm}-{rep}.jsonl")
        name = f"the warm-up of {arm}"
        trace = {r["index"]: r for r in rows(tpath)}
        raw = rows(rpath)
        # The same two refusals load_cell makes of a measured cell, so a warm-up is joined no more loosely.
        if len(raw) != len(trace) or {r["index"] for r in raw} != set(trace):
            raise g.Refusal(f"{name}-{rep}: {len(raw)} raw rows against {len(trace)} trace rows -- a request was lost or added")
        failed = [r["index"] for r in raw if r.get("errorKind")]
        if failed:
            raise g.Refusal(f"{name}-{rep}: {len(failed)} failed request(s), first index {failed[0]}")
        reqs = []
        for r in raw:
            t = trace[r["index"]]
            reqs.append(dict(index=r["index"], offset=t["offsetMs"], cap=t["maxOutputTokens"],
                             input_tokens=r["engineInputTokens"], output_tokens=r["engineOutputTokens"],
                             ttft_ms=(r["firstTokenUnixNanos"] - r["sendUnixNanos"]) / 1e6, send_ms=r["sendUnixNanos"] / 1e6,
                             first_ms=r["firstTokenUnixNanos"] / 1e6, end_ms=r["endUnixNanos"] / 1e6))
        reqs.sort(key=lambda q: (q["offset"], q["index"]))
        offsets = [q["offset"] for q in reqs]
        lone = [offsets.count(o) == 1 for o in offsets]
        if len(reqs) < 3 + tail or not (lone[0] and all(lone[-tail:])):
            if tail == 2:
                raise g.Refusal(f"{name}-{rep}: the warm-up is not a lone warm request, a staggered cycle and two lone "
                                f"verification requests, so its staggered episodes cannot be told apart (gate S)")
            raise g.Refusal(f"{name}-{rep}: the warm-up is not a lone warm request, a staggered cycle, a lone conditioning "
                            f"request and two lone verification requests, so its staggered episodes cannot be told apart (gate S)")
        # A lone tail request is not enough for session 4: the warm-up of an earlier session ends on a lone prefill too.
        # Each dropped tail request must be the drained 2,048/16 request the registration places there, or S loses an episode.
        if tail == 3:
            for q in reqs[-3:]:
                idx, ntok, cap = q["index"], q["input_tokens"], q["cap"]
                if ntok != WARM_TOKENS or cap != WARM_CAP:
                    raise g.Refusal(f"{name}-{rep}: the last three requests of the warm-up must each be a lone {WARM_TOKENS}-token "
                                    f"request capped at {WARM_CAP}, and index {idx} is a {ntok}-token "
                                    f"request capped at {cap}, so the warm-up has no conditioning request (gate S)")
        reqs = reqs[1:-tail]
    if phase != "measured" or fixed == "1":
        # The episode structure, refused by name rather than by an IndexError inside check_stagger.
        keyed = g.settings("stagger", reqs)
    if fixed == "1":
        trace_by = {r["index"]: r for r in rows(tpath)}
        raw_by = {r["index"]: r for r in rows(rpath)}
        decs = [q for s, q in keyed if s[3] == "decoder"]
        if not decs:
            raise g.Refusal(f"{name}-{rep}: no staggered decoder was found, so their lengths cannot be judged (gate S)")
        bad = [q["index"] for q in decs
               if trace_by[q["index"]].get("maxOutputTokens") != DECODER_TOKENS
               or raw_by[q["index"]].get("engineOutputTokens") != DECODER_TOKENS
               or raw_by[q["index"]].get("finishReason") != "length"]
        if bad:
            cap = trace_by[bad[0]].get("maxOutputTokens")
            got = raw_by[bad[0]].get("engineOutputTokens")
            why = raw_by[bad[0]].get("finishReason")
            raise g.Refusal(f"{name}-{rep}: {len(bad)} of {len(decs)} staggered decoders did not produce {DECODER_TOKENS} "
                            f"output tokens with finish reason length; the first, index {bad[0]}, has cap {cap} and "
                            f"reported {got} tokens and finish reason {why!r} (gate S)")
    g.check_stagger(reqs, name, rep)
except g.Refusal as e:
    print(e)
    sys.exit(1)
' "$IV_GATES_DIR" "$run" "$arm" "$rep" "$phase" "$fixed" "$tail" 2>&1) || rc=$?
  [ "$rc" = 0 ] && return 0
  echo "${out:-python3 exited $rc and said nothing, so gate S was not judged}"
  return 1
}
