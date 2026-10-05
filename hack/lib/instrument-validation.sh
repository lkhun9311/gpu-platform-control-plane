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
# Every function here answers only for these two studies, and takes the study as its first argument.
# The study is passed rather than read from $STUDY so a caller cannot get session 1's lengths for a session-2
# cell by forgetting to set a global, and so a test can drive either study without exporting anything.
# A caller asks iv_is_study first, so every other study's cells never reach this file and deploy exactly
# what they deployed before it existed.
#
# Every refusal prints its reason on stdout and returns 1, so the caller decides how loudly to fail and the
# reason travels into whatever record the caller keeps.

IV_STUDY=instrument-validation-2026-10-05
IV_S2_STUDY=instrument-validation-s2-2026-10-05

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

iv_is_study() { [ "${1:-}" = "$IV_STUDY" ] || [ "${1:-}" = "$IV_S2_STUDY" ]; }

# Only session 2 warms the engine before its measured replay; session 1 measured request 0 cold.
iv_has_warmup() { [ "${1:-}" = "$IV_S2_STUDY" ]; }

# Refuses an arm that is not one of the study's nine, or a study that is not one of the two.
#
# Separate from the durations so the engine-argument functions do not depend on session 2's length table:
# the arguments are a property of the arm's suffix, and a length refusal should not read as an engine one.
# The message is session 1's word for word, because its harness test pins it.
iv_arm_refusal() {
  local study="${1:-}" arm="${2:-}"
  iv_is_study "$study" || {
    echo "study ${study@Q} is neither $IV_STUDY nor $IV_S2_STUDY, so this file has nothing registered for it"
    return 1; }
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
  local study="${1:-}" arm="${2:-}" v
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
iv_engine_args() {
  iv_arm_refusal "${1:-}" "${2:-}" || return 1
  case "$2" in
    *-log) printf '%s\n' --no-async-scheduling --enable-logging-iteration-details ;;
    *-nolog) printf '%s\n' --no-async-scheduling ;;
    *-async) ;;
  esac
}

# Writes the manifest this arm deploys to $4, from the base manifest $3.
#
# The extra arguments go directly after the `- --port=8000` line, at that line's indentation.
# Proved rather than assumed: the result minus exactly the inserted lines must be byte-identical to the base,
# so an insertion that landed twice, nowhere, or inside a comment refuses instead of deploying.
iv_render_manifest() {
  local study="$1" arm="$2" base="$3" dest="$4" extra anchor_n
  extra=$(iv_engine_args "$study" "$arm") || { echo "$extra"; return 1; }
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
# $3 is the `non-default args: {...}` line vLLM printed at startup, which is the engine's own account and so
# the only one that survives an admission webhook or a flag the engine silently ignored.
# Python prints the dict with single quotes; double quotes are accepted too so a change of repr cannot turn
# a present key into a false refusal that reads like a missing one.
iv_process_args_refusal() {
  local study="$1" arm="$2" line="${3:-}" async_false=0 logging_true=0
  iv_arm_refusal "$study" "$arm" || return 1
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
  local study="$1" arm="$2" log="$3" n
  iv_arm_refusal "$study" "$arm" || return 1
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
    *-log) ;;
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
