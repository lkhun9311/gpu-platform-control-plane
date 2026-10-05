# What the instrument-validation study changes about a cell, in one place both runners source.
#
# docs/superpowers/specs/2026-10-05-can-the-stock-engine-time-an-iteration-instrument-validation.md registers
# nine arms whose names carry two facts the harness must act on: the episode type (serial, burst, stagger)
# decides the trace length, and the suffix (-log, -nolog, -async) decides the engine's arguments.
# hack/m5c-gpu-session.sh needs the durations to size its credential margin and hack/m5c-matrix.sh needs all
# of it to run the cells, so a second copy in either file would be the copy that drifts.
#
# Every function here answers only for this study.
# A caller asks iv_is_study first, so every other study's cells never reach this file and deploy exactly
# what they deployed before it existed.
#
# Every refusal prints its reason on stdout and returns 1, so the caller decides how loudly to fail and the
# reason travels into whatever record the caller keeps.

IV_STUDY=instrument-validation-2026-10-05

iv_is_study() { [ "${1:-}" = "$IV_STUDY" ]; }

# The trace length, in ms, of one arm.
#
# Each trace is exactly three complete cycles of its episode type, and gen-trace refuses a duration shorter
# than the trace, so the duration is a property of the arm rather than of the run.
# The values are the main session's, from the generator the other half of this study registers.
iv_duration_ms() {
  case "${1:-}" in
    serial-log | serial-nolog | serial-async) echo 180000 ;;
    burst-log | burst-nolog | burst-async) echo 330000 ;;
    stagger-log | stagger-nolog | stagger-async) echo 630000 ;;
    *)
      echo "arm ${1@Q} is not one of study $IV_STUDY's nine arms ({serial,burst,stagger}-{log,nolog,async}), so it has no registered trace length"
      return 1 ;;
  esac
}

# The arguments this arm appends to config/vllm/deployment.yaml, one per line.
#
# -async appends nothing: the async engine is the stock default, and the registration buys it only as the
# control the earlier archives measured.
iv_engine_args() {
  iv_duration_ms "${1:-}" >/dev/null || { iv_duration_ms "${1:-}"; return 1; }
  case "$1" in
    *-log) printf '%s\n' --no-async-scheduling --enable-logging-iteration-details ;;
    *-nolog) printf '%s\n' --no-async-scheduling ;;
    *-async) ;;
  esac
}

# Writes the manifest this arm deploys to $3, from the base manifest $2.
#
# The extra arguments go directly after the `- --port=8000` line, at that line's indentation.
# Proved rather than assumed: the result minus exactly the inserted lines must be byte-identical to the base,
# so an insertion that landed twice, nowhere, or inside a comment refuses instead of deploying.
iv_render_manifest() {
  local arm="$1" base="$2" dest="$3" extra anchor_n
  extra=$(iv_engine_args "$arm") || { echo "$extra"; return 1; }
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
}

# Refuses a cell whose engine did not report the configuration its arm registers.
#
# $2 is the `non-default args: {...}` line vLLM printed at startup, which is the engine's own account and so
# the only one that survives an admission webhook or a flag the engine silently ignored.
# Python prints the dict with single quotes; double quotes are accepted too so a change of repr cannot turn
# a present key into a false refusal that reads like a missing one.
iv_process_args_refusal() {
  local arm="$1" line="${2:-}" async_false=0 logging_true=0
  iv_duration_ms "$arm" >/dev/null || { iv_duration_ms "$arm"; return 1; }
  case "$line" in
    "non-default args: {"*) ;;
    *)
      echo "the engine for $arm printed no non-default args line (recorded ${line:-nothing}), so which engine this cell measured cannot be read from the engine itself"
      return 1 ;;
  esac
  printf '%s' "$line" | grep -qE "['\"]async_scheduling['\"]: False" && async_false=1
  printf '%s' "$line" | grep -qE "['\"]enable_logging_iteration_details['\"]: True" && logging_true=1
  case "$arm" in
    *-log | *-nolog)
      [ "$async_false" = 1 ] || {
        echo "the engine for $arm does not report async_scheduling False in its non-default args, so it is not the synchronous engine the arm registers: $line"
        return 1; } ;;
    *-async)
      [ "$async_false" = 0 ] || {
        echo "the engine for $arm reports async_scheduling False, so the async control would be measured on the synchronous engine: $line"
        return 1; } ;;
  esac
  case "$arm" in
    *-log)
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
  local arm="$1" log="$2" n
  iv_duration_ms "$arm" >/dev/null || { iv_duration_ms "$arm"; return 1; }
  [ -f "$log" ] || { echo "no engine log was captured for $arm at $log"; return 1; }
  n=$(awk 'index($0, "Iteration(") {c++} END {print c+0}' "$log") \
    || { echo "could not count iteration lines in $log"; return 1; }
  case "$arm" in
    *-log)
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
