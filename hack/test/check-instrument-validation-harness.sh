#!/usr/bin/env bash
# Pins what the shell harness does differently for instrument-validation-2026-10-05 and its second session,
# instrument-validation-s2-2026-10-05, and that it does nothing differently for any other study.
#
# Sections 7 onward are session 2's: the warm-up, its W refusal, its boundary file, its upload and
# accounting, its share of the deadline projections, and a byte comparison of session 1's plan output
# against the matrix at HEAD, so adding session 2 is shown not to have moved session 1.
#
# WHY THIS EXISTS
#
# The study's arms vary the engine's arguments (-log, -nolog, -async) and the trace length (serial, burst,
# stagger), and every refusal that guards them fires on a rented card, after the engine is up.
# Each refusal is therefore driven here on a crafted input, so "the guard exists" is a run that printed it.
# The other half is the property the change must not break: every existing study's cell applies the
# checked-in engine manifest by its own path and records its declared row exactly as before.
#
# HOW
#
# deploy_arm, engine_applied_record, capture_engine_log, cell_duration_ms and the two projections are
# extracted from hack/m5c-matrix.sh by name and driven with a stub `k`; the matrix itself is sourced
# nowhere, because sourcing it runs a paid matrix.
# The top-level refusals and the cell order are read by running the real matrix with PLAN_ONLY and a stub
# benchharness that refuses every subcommand, so the run stops at the first question it asks the registry,
# after load-source.txt and the plan line are written.
#
# WHAT IT DOES NOT ESTABLISH
#
# That vLLM v0.27.1 accepts --enable-logging-iteration-details or prints the two keys in its non-default
# args line; the crafted lines here are the shape the brief names, and only a card can confirm them.
# That gen-trace accepts these arms; the Go side of the study is registered elsewhere.
# That `gen-trace --warmup` exists or writes what the stub here writes; the stub's warm-up trace is the
# shape section 2 of the session-2 registration describes, and the Go side owns the real one.
set -uo pipefail

cd "$(dirname "$0")/../.."

failures=0
say() { echo; echo "== $*"; }
ok() { echo "   ok: $*"; }
bad() {
	echo "   FAIL: $*" >&2
	failures=$((failures + 1))
}

SRC=hack/m5c-matrix.sh
LIB=hack/lib/instrument-validation.sh
BASE=config/vllm/deployment.yaml
IV=instrument-validation-2026-10-05
# The matrix's default MODEL_REVISION, which session 3 pins on the engine's command line.
REV=aa8e72537993ba99e69dfaafa59ed015b17504d1
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/tmp"

extract() {
	awk -v fn="$1" '
		$0 ~ "^" fn "\\(\\) \\{" { inside = 1 }
		inside { print }
		inside && /^\}/ { exit }
	' "$SRC"
}

FNS="deploy_arm engine_applied_record capture_engine_log cell_duration_ms cell_charge_ms warmup_gen_trace warmup_span_ms
	warmup_boundary_record run_warmup seed_for_rep iv_cold_projection_min iv_remaining_projection
	expected_outputs expected_outputs_by_class cell_refusal_rows cell_refused_stop cell_timing_record warmup_refusal_log"
{
	echo 'set -uo pipefail'
	echo ". $LIB"
	for fn in $FNS; do extract "$fn"; done
} > "$WORK/fns.sh"
for fn in $FNS; do
	grep -q "^$fn() {" "$WORK/fns.sh" || bad "$fn was not extracted from $SRC; the harness is testing nothing"
done
bash -n "$WORK/fns.sh" || bad "the extracted functions do not parse, so an extraction stopped inside a body"
# deploy_arm's last line waits for the gateway; an extraction that stopped early would lose it silently.
grep -q 'gateway never became ready' "$WORK/fns.sh" || bad "deploy_arm was cut short by the extraction"

# The stub cluster. Every engine manifest applied by path is logged, and the Deployment's args are answered
# from the last one, as the API server would after a plain apply.
cat > "$WORK/stubs.sh" <<'STUBS'
fail() { echo "MATRIX FAILED: $*" >&2; exit 1; }
say() { echo "== $*"; }
apply_device_plugin() { return 0; }
engine_kv_report() { :; }
engine_diagnosis() { :; }
routing_record() { :; }
mps_clients_connected() { return 0; }
arm_refused() { echo "REFUSED $1: $2" >&2; }
k() {
	case "$*" in
		"apply -f -"*) cat >/dev/null; return 0 ;;
		"apply -f "*)
			echo "$3" >> "$WORK/applied.log"
			case "$3" in */service.yaml) ;; *) cp "$3" "$WORK/last-applied.yaml" ;; esac
			return 0 ;;
		"get deploy"*"args}"*)
			grep -E '^[[:space:]]*- ' "$WORK/last-applied.yaml" | sed -n '/Qwen/,$p' | grep -v 'name:' \
				| sed 's/^[[:space:]]*- //' | awk 'BEGIN {printf "["} {printf "%s\"%s\"", (NR > 1 ? "," : ""), $0} END {printf "]"}'
			return 0 ;;
		"get pods"*"restartCount"*) printf '%s' "$STUB_RESTARTS"; return 0 ;;
		"get pod"*"nodeName"*) printf 'n1'; return 0 ;;
		"logs"*)
			[ "${STUB_LOGS_FAIL:-}" = 1 ] && { echo "error: stub logs refused" >&2; return 1; }
			printf '%s\n' "$STUB_LOG"; return 0 ;;
		"create secret"* | "create serviceaccount"* | "create clusterrolebinding"*) echo "kind: X"; return 0 ;;
		*) return 0 ;;
	esac
}
STUBS

# run_deploy <study> <topology> <label> -> runs deploy_arm in a subshell; stdout+stderr to $WORK/deploy.out
run_deploy() {
	local study="$1" topo="$2" label="$3"
	: > "$WORK/applied.log"
	rm -f "$WORK/out/applied-values.tsv" "$WORK/out/cell-timings.tsv" "$WORK/out/"cell-refused-*.txt
	mkdir -p "$WORK/out"
	(
		# shellcheck disable=SC1090,SC1091
		. "$WORK/fns.sh"
		# shellcheck disable=SC1091
		. "$WORK/stubs.sh"
		STUDY="$study" LADDER="" OUT="$WORK/out" NS_A=a NS_B=b GW_IMAGE=g cell_n=1
		# What run_cell holds when it calls deploy_arm, which a refusal records through cell_refused_stop.
		rep=1 cell_secs=0 cells_done=0 CELL_T0=$(date +%s) MODEL_REVISION="$REV"
		export WORK
		deploy_arm "$topo" "$label"
	) > "$WORK/deploy.out" 2>&1
}

# --- 1. every other study deploys the checked-in manifest, by its own path ------------------------------
say "1. existing studies apply exactly the checked-in engine manifests and record the same declared row"
old_declared=$(grep -E '^[[:space:]]*- --' "$BASE" | grep -o -- '--[a-z-]*=[0-9A-Za-z./-]*' | tr '\n' ' ')
for study in sharing-matrix-2026-09-10 tail-crossing-lc256-2026-10-04 tail-crossing-lc2048-2026-10-05 tail-crossing-lc8192-2026-10-04; do
	export STUB_LOG="non-default args: {'model': 'Qwen/Qwen2.5-3B-Instruct'}" STUB_RESTARTS="0 "
	for topo in R1 shared; do
		if ! run_deploy "$study" "$topo" "$topo"; then
			bad "$study/$topo: deploy_arm failed under the stub: $(tail -3 "$WORK/deploy.out")"
			continue
		fi
		got=$(grep -v 'service.yaml' "$WORK/applied.log" | tr '\n' ' ')
		[ "$got" = "$BASE " ] && ok "$study/$topo applies $BASE by its own path" \
			|| bad "$study/$topo applied ${got@Q} rather than $BASE; an existing study's engine is no longer the checked-in one"
		decl=$(awk -F'\t' '$4 == "declared" {print $5 "|" $6}' "$WORK/out/applied-values.tsv")
		[ "$decl" = "$BASE|${old_declared}" ] && ok "$study/$topo's declared row is byte-identical to the old pattern's" \
			|| bad "$study/$topo's declared row changed: ${decl@Q}"
	done
	for topo in timeSlicing mps; do
		run_deploy "$study" "$topo" "$topo" || { bad "$study/$topo: deploy_arm failed: $(tail -3 "$WORK/deploy.out")"; continue; }
		got=$(tr '\n' ' ' < "$WORK/applied.log")
		[ "$got" = "config/vllm-shared/engine-a.yaml config/vllm-shared/engine-b.yaml " ] && ok "$study/$topo applies the two checked-in split engines" \
			|| bad "$study/$topo applied ${got@Q}"
	done
done
# And the checked-in file is the file at HEAD, so "by its own path" also means "the same bytes as today".
if git diff --quiet HEAD -- "$BASE" config/vllm-shared/engine-a.yaml config/vllm-shared/engine-b.yaml; then
	ok "the three engine manifests are unchanged against HEAD"
else
	bad "an engine manifest differs from HEAD, so 'the checked-in path' no longer means today's bytes"
fi

# --- 2. the study's arms render the base plus exactly their arguments -----------------------------------
say "2. each arm's manifest is the base plus exactly its own arguments"
# shellcheck disable=SC1090
. "$LIB"
for arm in serial-log burst-nolog stagger-async; do
	if ! why=$(iv_render_manifest "$IV" "$arm" "$BASE" "$WORK/r-$arm.yaml"); then
		bad "$arm did not render: $why"
		continue
	fi
	added=$(diff "$BASE" "$WORK/r-$arm.yaml" | grep '^>' | sed 's/^> *//' | tr '\n' ' ')
	case "$arm" in
		*-log) want="- --no-async-scheduling - --enable-logging-iteration-details " ;;
		*-nolog) want="- --no-async-scheduling " ;;
		*-async) want="" ;;
	esac
	[ "$added" = "$want" ] && ok "$arm adds ${want:-nothing}" || bad "$arm added ${added@Q}, wanted ${want@Q}"
	removed=$(diff "$BASE" "$WORK/r-$arm.yaml" | grep -c '^<' || true)
	[ "$removed" = 0 ] && ok "$arm removes nothing from the base" || bad "$arm removed $removed line(s) from the base"
done
printf 'args:\n  - --port=8000\n  - --port=8000\n' > "$WORK/two-anchors.yaml"
out=$(iv_render_manifest "$IV" serial-log "$WORK/two-anchors.yaml" "$WORK/x.yaml") \
	&& bad "a base with two port lines rendered" || { echo "$out" | grep -q "has 2 '- --port=8000' lines" && ok "a base with two anchors refuses: $out" || bad "wrong refusal: $out"; }
printf 'args:\n  - --dtype=half\n' > "$WORK/no-anchor.yaml"
out=$(iv_render_manifest "$IV" serial-log "$WORK/no-anchor.yaml" "$WORK/x.yaml") \
	&& bad "a base with no port line rendered" || { echo "$out" | grep -q "has 0 '- --port=8000' lines" && ok "a base with no anchor refuses: $out" || bad "wrong refusal: $out"; }
out=$(iv_render_manifest "$IV" R1 "$BASE" "$WORK/x.yaml") \
	&& bad "the arm R1 rendered under this study" || { echo "$out" | grep -q "not one of study $IV's nine arms" && ok "an arm outside the study refuses: $out" || bad "wrong refusal: $out"; }

# --- 3. deploy_arm under the study: applied-values shows the args; the process line is judged ------------
say "3. the study's cells record their arguments at every stage and refuse a contradicting engine"
LOG_LINE="non-default args: {'model': 'Qwen/Qwen2.5-3B-Instruct', 'async_scheduling': False, 'enable_logging_iteration_details': True}"
NOLOG_LINE="non-default args: {'model': 'Qwen/Qwen2.5-3B-Instruct', 'async_scheduling': False}"
ASYNC_LINE="non-default args: {'model': 'Qwen/Qwen2.5-3B-Instruct'}"
export STUB_RESTARTS="0 "
export STUB_LOG="$LOG_LINE"
if run_deploy "$IV" R1 serial-log; then
	ok "serial-log deploys with an engine that reports its arm's configuration"
	for stage in declared applied process; do
		row=$(awk -F'\t' -v s="$stage" '$4 == s' "$WORK/out/applied-values.tsv")
		case "$stage" in
			declared) printf '%s' "$row" | grep -q -- '--no-async-scheduling --enable-logging-iteration-details' ;;
			applied) printf '%s' "$row" | grep -q -- '"--no-async-scheduling","--enable-logging-iteration-details"' ;;
			process) printf '%s' "$row" | grep -q "'async_scheduling': False, 'enable_logging_iteration_details': True" ;;
		esac && ok "the $stage row shows the extra arguments" || bad "the $stage row does not show them: ${row@Q}"
	done
	awk -F'\t' '$4 == "declared" {print $5}' "$WORK/out/applied-values.tsv" | grep -qx 'config/vllm/deployment.yaml+serial-log' \
		&& ok "the declared row names the base and the arm, not a temporary path" || bad "the declared row's source is $(awk -F'\t' '$4 == "declared" {print $5}' "$WORK/out/applied-values.tsv")"
else
	bad "serial-log with a matching engine was refused: $(tail -3 "$WORK/deploy.out")"
fi
STUB_LOG="$NOLOG_LINE" run_deploy "$IV" R1 burst-nolog && ok "burst-nolog deploys with a matching engine" || bad "burst-nolog refused: $(tail -2 "$WORK/deploy.out")"
STUB_LOG="$ASYNC_LINE" run_deploy "$IV" R1 stagger-async && ok "stagger-async deploys with a matching engine" || bad "stagger-async refused: $(tail -2 "$WORK/deploy.out")"
grep -qv 'service.yaml' "$WORK/applied.log" && ! grep -qx "$BASE" "$WORK/applied.log" \
	&& ok "the study's cells apply a rendered copy, never the base by its path" || bad "the study applied: $(tr '\n' ' ' < "$WORK/applied.log")"

# expect_process_refusal <label> <line> <phrase>
expect_process_refusal() {
	if STUB_LOG="$2" run_deploy "$IV" R1 "$1"; then
		bad "$1 deployed against ${2@Q}; the engine contradicts the arm and the cell went on to replay"
	elif grep -q "MATRIX FAILED: REFUSED $1 before replay: .*$3" "$WORK/deploy.out"; then
		ok "$1 refused: $(grep -o "REFUSED $1 before replay: [^:]*" "$WORK/deploy.out")"
		# The refusal is recorded as the cell's outcome before the run stops.
		[ "$(awk -F'\t' 'NR > 1 {print $2 "/" $3 "/" $4}' "$WORK/out/cell-timings.tsv")" = "$1/1/refused-before-replay" ] \
			&& grep -q "^REFUSED $1 before replay: .*$3" "$WORK/out/cell-refused-$1-1.txt" \
			|| bad "$1's refusal was not recorded: row $(tail -1 "$WORK/out/cell-timings.tsv") file $(cat "$WORK/out/cell-refused-$1-1.txt")"
	else
		bad "$1 failed, but not with the refusal wanted ($3): $(tail -2 "$WORK/deploy.out")"
	fi
}
expect_process_refusal serial-log "$ASYNC_LINE" "does not report async_scheduling False"
expect_process_refusal serial-log "$NOLOG_LINE" "does not report enable_logging_iteration_details True"
expect_process_refusal serial-nolog "$LOG_LINE" "reports enable_logging_iteration_details True"
expect_process_refusal serial-nolog "$ASYNC_LINE" "does not report async_scheduling False"
expect_process_refusal serial-async "$LOG_LINE" "reports async_scheduling False"
expect_process_refusal serial-async "non-default args: {'enable_logging_iteration_details': True}" "reports enable_logging_iteration_details True"
expect_process_refusal serial-async "" "printed no non-default args line"

# --- 4. the per-cell engine log ------------------------------------------------------------------------
say "4. each cell saves its engine log and refuses one that contradicts its arm"
# expect_log <label> <log text> <restarts> <ok|phrase>
expect_log() {
	rm -f "$WORK/out/engine-log-$1-1.txt"
	out=$(
		# shellcheck disable=SC1090,SC1091
		. "$WORK/fns.sh"
		# shellcheck disable=SC1091
		. "$WORK/stubs.sh"
		STUDY="$IV" OUT="$WORK/out" NS_A=a STUB_LOG="$2" STUB_RESTARTS="$3"
		capture_engine_log "$1" 1
	) && rc=0 || rc=$?
	if [ "$4" = ok ]; then
		if [ "$rc" = 0 ] && cmp -s "$WORK/out/engine-log-$1-1.txt" <(printf '%s\n' "$2"); then
			ok "$1 saved its whole log to engine-log-$1-1.txt and passed"
		else
			bad "$1 should have passed and saved its log; rc=$rc out=${out@Q}"
		fi
	elif [ "$rc" != 0 ] && printf '%s' "$out" | grep -q "$4"; then
		ok "$1 refused: $out"
	else
		bad "$1 was not refused with '$4'; rc=$rc out=${out@Q}"
	fi
}
ITER='INFO engine.py:1 Iteration(number=3, num_running=1, scheduled_tokens=2048)'
expect_log serial-log "startup
$ITER" "0 " ok
expect_log serial-log "startup only" "0 " "zero Iteration( lines"
expect_log burst-nolog "startup only" "0 " ok
expect_log burst-nolog "startup
$ITER" "0 " "holds 1 Iteration( line(s) although the arm registers logging off"
expect_log stagger-async "$ITER" "0 " "holds 1 Iteration( line(s)"
expect_log serial-log "$ITER" "1 " "restart counts read 1"
expect_log serial-log "$ITER" "0 0 " "restart counts read 0 0"
STUB_LOGS_FAIL=1 expect_log serial-log "$ITER" "0 " "could not read the engine log"
# The run_cell call site, read as text: judged before the hook and refused after it.
body=$(extract run_cell)
j=$(printf '%s\n' "$body" | grep -n 'capture_engine_log "\$label" "\$rep"' | cut -d: -f1)
h=$(printf '%s\n' "$body" | grep -n 'timeout "\${CELL_DONE_HOOK_TIMEOUT' | cut -d: -f1)
f=$(printf '%s\n' "$body" | grep -n 'REFUSED \$label rep \$rep after replay' | cut -d: -f1)
r=$(printf '%s\n' "$body" | grep -n -- '--raw-out "\$OUT/raw-' | cut -d: -f1)
if [ -n "$j" ] && [ -n "$h" ] && [ -n "$f" ] && [ -n "$r" ] && [ "$r" -lt "$j" ] && [ "$j" -lt "$h" ] && [ "$h" -lt "$f" ]; then
	ok "run_cell captures after the replay ($r < $j), uploads ($h), then refuses ($f)"
else
	bad "run_cell's order is replay=$r capture=$j hook=$h refuse=$f; the log must be taken after the replay and uploaded before the refusal"
fi
grep -q 'send "\$out/engine-log-\$arm-\$rep.txt" "engine-log-\$arm-\$rep.txt"' hack/m5c-gpu-session.sh \
	&& ok "the session's per-cell upload sends engine-log-<arm>-<rep>.txt" || bad "the session's per-cell hook does not send the engine log"

# --- 5. durations and projections ----------------------------------------------------------------------
say "5. each cell's trace length is its arm's, and the deadline arithmetic charges it"
(
	# shellcheck disable=SC1090
	. "$WORK/fns.sh"
	LADDER="" STUDY=sharing-matrix-2026-09-10 DURATION_MS=420000
	[ "$(cell_duration_ms R1)" = 420000 ] && [ "$(cell_duration_ms serial-log)" = 420000 ]
) && ok "every other study's cell length is its single DURATION_MS" || bad "an existing study's cell length is not DURATION_MS"
(
	# shellcheck disable=SC1090
	. "$WORK/fns.sh"
	LADDER="" STUDY="$IV" DURATION_MS=""
	[ "$(cell_duration_ms serial-nolog)" = 180000 ] && [ "$(cell_duration_ms burst-async)" = 330000 ] && [ "$(cell_duration_ms stagger-log)" = 630000 ]
) && ok "the study's cells are 180000, 330000 and 630000 ms by episode type" || bad "the study's per-arm durations are wrong"
proj=$(
	# shellcheck disable=SC1090
	. "$WORK/fns.sh"
	LADDER="" STUDY="$IV"
	CELLS=("R1|serial-log|1|1|0|0" "R1|stagger-log|1|1|0|0" "R1|burst-log|1|1|0|0")
	# (8+4) + (8+12) + (8+7) = 47, times 1.2 = 56
	echo "cold=$(iv_cold_projection_min)"
	# two cells done in 1500 s, whose replays were 180 + 630 s: overhead (1500-810)/2 = 345 s.
	# the last cell is 345 + 330 = 675 s; 675*1.2 = 810 s = 14 min (rounded up).
	cells_done=2 cell_secs=1500
	echo "mid=$(iv_remaining_projection)"
)
[ "$proj" = "cold=56
mid=14 675 345" ] && ok "the projections charge each cell its own length: $(echo $proj)" || bad "projection read ${proj@Q}, wanted cold=56 and mid=14 675 345"

# --- 6. the real matrix: refusals before anything, and the cell order ---------------------------------
say "6. the real matrix refuses what this study cannot take, and plans its blocks"
printf '#!/bin/sh\necho "stub benchharness refuses $1" >&2\nexit 1\n' > "$WORK/bh"
chmod +x "$WORK/bh"
SYNC="serial-log serial-nolog burst-log burst-nolog stagger-log stagger-nolog"
ASYNC="serial-async burst-async stagger-async"
# `env -u` is an option and must come before every assignment, so "no ARMS" is its own word here.
mx() {
	local arms=(ARMS="$SYNC $ASYNC") unset_arms=()
	if [ "${2:-}" = NOARMS ]; then arms=(); unset_arms=(-u ARMS); set -- "$1" "${@:3}"; fi
	env -u DURATION_MS -u SWEEP -u LADDER -u RATE -u PREMIUM_WEIGHT -u NOISY_WEIGHT -u PROBE_WEIGHT -u PREMIUM_RATE \
		-u PREMIUM_PROMPT_CHARS -u NOISY_PROMPT_CHARS -u PREMIUM_OUTPUT_TOKENS -u NOISY_OUTPUT_TOKENS \
		"${unset_arms[@]}" TMPDIR="$WORK/tmp" PLAN_ONLY=1 PLATFORM=kind KCTX=none \
		BENCHHARNESS_BIN="$WORK/bh" STUDY="$IV" REPS=3 \
		"${arms[@]}" OUT="$WORK/m-$1" "${@:2}" bash "$SRC" 2>&1
}
# expect_mx <name> <phrase> env...
expect_mx() {
	local name="$1" phrase="$2"; shift 2
	out=$(mx "$name" "$@") && rc=0 || rc=$?
	if [ "$rc" != 0 ] && printf '%s' "$out" | grep -qF "$phrase"; then
		ok "$name refused: $(printf '%s' "$out" | grep -F "$phrase" | head -1 | cut -c1-160)"
	else
		bad "$name was not refused with '$phrase'; rc=$rc: $(printf '%s' "$out" | tail -2)"
	fi
}
expect_mx duration "DURATION_MS is '420000' and study $IV sets the trace length per arm" DURATION_MS=420000
expect_mx sweep "SWEEP is set and study $IV registers no best-effort sweep" SWEEP=0.1
# The study takes no load, and a load variable is refused rather than silently unused.
expect_mx rate "RATE is '1' and study $IV takes no load" RATE=1
expect_mx weight "NOISY_WEIGHT is '0.05' and study $IV takes no load" NOISY_WEIGHT=0.05
# And the prompt shape, which used to be dropped before gen-trace and still recorded as declared.
expect_mx shape "PREMIUM_PROMPT_CHARS=999 PREMIUM_OUTPUT_TOKENS=3 set, and study $IV's lengths" PREMIUM_PROMPT_CHARS=999 PREMIUM_OUTPUT_TOKENS=3
expect_mx arms-unset "ARMS is unset and study $IV has none of the default topologies" NOARMS
expect_mx foreign-arm "arm 'R1' is not one of study $IV's nine arms" ARMS="serial-log R1"
expect_mx unregistered "STUDY is 'instrument-validation-2026-10-06'" STUDY=instrument-validation-2026-10-06
# The plan itself: the run gets as far as asking the registry, which the stub refuses.
out=$(mx plan) && rc=0 || rc=$?
if [ "$rc" != 0 ] && printf '%s' "$out" | grep -q 'stub benchharness refuses study-arrivals'; then
	ok "a well-formed plan passes every shell refusal and reaches the registry"
else
	bad "a well-formed plan stopped before the registry: $(printf '%s' "$out" | tail -2)"
fi
plan=$(printf '%s' "$out" | grep '^== plan:' | sed 's/^== plan: [0-9]* cell(s): //')
n=$(printf '%s' "$out" | grep -o '^== plan: [0-9]*' | grep -o '[0-9]*$')
[ "$n" = 21 ] && ok "three blocks of six and three async cells: 21" || bad "the plan has ${n:-no} cells, wanted 21: $plan"
read -ra P <<<"$plan"
blocks_ok=1
for b in 0 1 2; do
	got=$(printf '%s\n' "${P[@]:$((b * 6)):6}" | sort | tr '\n' ' ')
	[ "$got" = "$(printf '%s\n' $SYNC | sort | tr '\n' ' ')" ] || blocks_ok=0
done
tail3=$(printf '%s\n' "${P[@]:18:3}" | sort | tr '\n' ' ')
[ "$blocks_ok" = 1 ] && [ "$tail3" = "$(printf '%s\n' $ASYNC | sort | tr '\n' ' ')" ] \
	&& ok "each block holds the six sync arms and the async arms come once at the end" \
	|| bad "the blocks are not the registration's: $plan"
[ "${P[*]:0:6}" != "${P[*]:6:6}" ] && ok "two blocks differ in order" || bad "blocks 1 and 2 share an order, so the order is not per block"
dur=$(grep '^duration_ms:' "$WORK/m-plan/load-source.txt" || true)
printf '%s' "$dur" | grep -q ' serial-log/1=180000' && printf '%s' "$dur" | grep -q ' stagger-async/1=630000' \
	&& printf '%s' "$dur" | grep -q ' burst-nolog/3=330000' \
	&& ok "load-source.txt records each cell's duration: $(printf '%s' "$dur" | cut -c1-80)..." \
	|| bad "load-source.txt carries no per-cell duration line: ${dur@Q}"
# The topology column is not in the plan line, so the two CELLS builders are read as text.
r1=$(awk "index(\$0, \"printf '%s R1|%s|\") {c++} END {print c+0}" "$SRC")
[ "$r1" = 2 ] && ok "both of the study's cell builders deploy the one-engine topology" \
	|| bad "$r1 of the study's two cell builders use the R1 topology"
# And an existing study writes no duration line, so its record is as before.
out=$(env -u DURATION_MS TMPDIR="$WORK/tmp" PLAN_ONLY=1 PLATFORM=kind KCTX=none BENCHHARNESS_BIN="$WORK/bh" \
	RATE=1 PREMIUM_WEIGHT=1 NOISY_WEIGHT=0.054 PROBE_WEIGHT=0 DURATION_MS=420000 REPS=1 ARMS="R1 shared" \
	OUT="$WORK/m-old" bash "$SRC" 2>&1) || true
if [ -f "$WORK/m-old/load-source.txt" ] && ! grep -q '^duration_ms:' "$WORK/m-old/load-source.txt"; then
	ok "the sharing matrix's load-source.txt has no duration line"
else
	bad "the sharing matrix's load-source.txt changed or was not written: $(printf '%s' "$out" | tail -2)"
fi

# ======================================= session 2 =======================================================
IV2=instrument-validation-s2-2026-10-05

# --- 7. the study is accepted, its lengths are the generator's, and a placeholder refuses ------------------
say "7. session 2 is accepted wherever session 1 is, with the generator's lengths, and a placeholder length refuses"
iv_is_study "$IV2" && iv_is_study "$IV" && ! iv_is_study sharing-matrix-2026-09-10 \
	&& ok "iv_is_study accepts sessions 1 and 2 and not another study" || bad "iv_is_study does not cover the two sessions"
iv_has_warmup "$IV2" && ! iv_has_warmup "$IV" && ok "session 2 warms up and session 1 does not" || bad "iv_has_warmup is wrong for sessions 1 and 2"
s2=$(for a in serial-log burst-nolog stagger-async; do iv_duration_ms "$IV2" "$a"; iv_warmup_duration_ms "$IV2" "$a"; done | tr '\n' ' ')
[ "$s2" = "500000 100000 320000 120000 2410000 500000 " ] && ok "session 2's measured and warm-up lengths are the main session's: $s2" \
	|| bad "session 2's lengths read $s2"
out=$(iv_warmup_duration_ms "$IV" serial-log) && bad "session 1 had a warm-up length" \
	|| { printf '%s' "$out" | grep -qF "registers no warm-up" && ok "session 1 has no warm-up length: $out" || bad "wrong refusal: $out"; }
# expect_placeholder <function> <variable> <phrase>: the table entry put back to a placeholder refuses.
expect_placeholder() {
	out=$(eval "$2=FILL-FROM-GENERATOR-SPAN"; "$1" "$IV2" serial-log) && bad "$2 as a placeholder was returned as ${out@Q}" \
		|| { printf '%s' "$out" | grep -qF "$3" && ok "a placeholder $2 refuses: $out" || bad "wrong refusal: $out"; }
}
expect_placeholder iv_duration_ms IV_S2_DURATION_MS_SERIAL "trace length for serial-log is still 'FILL-FROM-GENERATOR-SPAN' in hack/lib/instrument-validation.sh"
expect_placeholder iv_warmup_duration_ms IV_S2_WARMUP_DURATION_MS_SERIAL "warm-up length for serial-log is still 'FILL-FROM-GENERATOR-SPAN'"
out=$(iv_duration_ms "$IV2" R1) && bad "R1 had a session-2 length" \
	|| { [ "$out" = "arm 'R1' is not one of study $IV2's nine arms ({serial,burst,stagger}-{log,nolog,async}), so it has no registered trace length" ] \
		&& ok "an arm outside session 2 refuses by name" || bad "wrong refusal: $out"; }
out=$(iv_duration_ms instrument-validation-2026-10-06 serial-log) && bad "an unknown study had a length" \
	|| { printf '%s' "$out" | grep -qF "is none of $IV, $IV2, instrument-validation-s3-2026-10-06 and instrument-validation-s4-2026-10-06" && ok "an unknown study refuses: $out" || bad "wrong refusal: $out"; }
s1=$(for a in serial-log burst-nolog stagger-async; do iv_duration_ms "$IV" "$a"; done | tr '\n' ' ')
[ "$s1" = "180000 330000 630000 " ] && ok "session 1's lengths are unchanged" || bad "session 1's lengths moved: $s1"
# The engine arguments do not wait for the lengths: they are a property of the suffix.
for arm in serial-log burst-nolog stagger-async; do
	iv_render_manifest "$IV2" "$arm" "$BASE" "$WORK/r2-$arm.yaml" >/dev/null && cmp -s "$WORK/r2-$arm.yaml" "$WORK/r-$arm.yaml" \
		|| bad "$arm renders differently under session 2"
done && ok "session 2's arms render the same manifests as session 1's"
STUB_LOG="$LOG_LINE" run_deploy "$IV2" R1 serial-log && ok "a session-2 cell deploys and passes the process-args refusal" \
	|| bad "a session-2 cell was refused at deploy: $(tail -2 "$WORK/deploy.out")"
STUB_LOG="$ASYNC_LINE" run_deploy "$IV2" R1 serial-log && bad "session 2 deployed serial-log on an async engine" \
	|| { grep -q "REFUSED serial-log before replay: .*does not report async_scheduling False" "$WORK/deploy.out" \
		&& ok "session 2 keeps the process-args refusal" || bad "wrong refusal: $(tail -2 "$WORK/deploy.out")"; }
expect_mx s2-duration "DURATION_MS is '420000' and study $IV2 sets the trace length per arm (serial 500000, burst 320000, stagger 2410000 ms)" \
	STUDY="$IV2" DURATION_MS=420000

# A raw row: index, send ns, TTFT in microseconds (0 = no first token), engine input tokens, errorKind.
row() {
	local first=$(($2 + $3 * 1000)) err=""
	[ "$3" = 0 ] && first=0
	[ -n "${5:-}" ] && err=",\"errorKind\":\"$5\""
	if [ "$first" = 0 ]; then
		printf '{"index":%d,"sendUnixNanos":%d,"engineInputTokens":%d%s}\n' "$1" "$2" "$4" "$err"
	else
		printf '{"index":%d,"sendUnixNanos":%d,"firstTokenUnixNanos":%d,"engineInputTokens":%d%s}\n' "$1" "$2" "$first" "$4" "$err"
	fi
}
T0=1759650000000000000
# warm <file> <ttft-a us> <ttft-b us> [tokens-b] [errorKind-b]: a warm-up whose verification pair is a, b.
# The file is written out of send order, so a check that read the file's last lines would read the wrong rows.
warm() {
	{
		row 3 $((T0 + 61000000000)) "$3" "${4:-2048}" "${5:-}"
		row 0 "$T0" 412000 2048
		row 2 $((T0 + 60000000000)) "$2" 2048
		row 1 $((T0 + 1000000000)) 21000 256
	} > "$1"
}

# --- 8. W: the verification pair must be warm and alike ------------------------------------------------
say "8. W refuses a warm-up whose verification requests are not warm, alike, complete and 2,048 tokens"
# expect_w <name> <file> <ok|phrase...>
expect_w() {
	local name="$1" f="$2" p
	shift 2
	out=$(iv_warmup_refusal "$f") && rc=0 || rc=$?
	if [ "$1" = ok ]; then
		[ "$rc" = 0 ] && [ -z "$out" ] && ok "$name passes W" || bad "$name should pass W; rc=$rc out=${out@Q}"
		return
	fi
	[ "$rc" != 0 ] || { bad "$name passed W"; return; }
	for p in "$@"; do
		printf '%s' "$out" | grep -qF "$p" || { bad "$name was refused without '$p': $out"; return; }
	done
	ok "$name refused: $out"
}
warm "$WORK/w-good.jsonl" 230000 233500
expect_w good "$WORK/w-good.jsonl" ok
warm "$WORK/w-edge.jsonl" 219500 223800
expect_w "a pair 5% and 2% inside both bounds" "$WORK/w-edge.jsonl" ok
warm "$WORK/w-slow.jsonl" 250000 251000
expect_w too-slow "$WORK/w-slow.jsonl" "250.000 ms" "251.000 ms" "250.000 ms is more than 5% from 231 ms" "251.000 ms is more than 5% from 231 ms"
warm "$WORK/w-unequal.jsonl" 222000 238000
expect_w unequal "$WORK/w-unequal.jsonl" "222.000 ms and 238.000 ms differ by more than 2% of the smaller"
warm "$WORK/w-errored.jsonl" 230000 233000 2048 timeout
expect_w errored "$WORK/w-errored.jsonl" "index 3 did not complete" "TTFT 230.000 ms" "TTFT 233.000 ms"
warm "$WORK/w-tokens.jsonl" 230000 233000 1024
expect_w wrong-length "$WORK/w-tokens.jsonl" "index 3 is not a 2048-token request"
warm "$WORK/w-notoken.jsonl" 230000 0 2048 timeout
expect_w no-first-token "$WORK/w-notoken.jsonl" "index 3 has no first token" "TTFT no first token"
expect_w missing "$WORK/w-absent.jsonl" "no warm-up rows were written at $WORK/w-absent.jsonl"
row 0 "$T0" 230000 2048 > "$WORK/w-one.jsonl"
expect_w one-row "$WORK/w-one.jsonl" "only 1 warm-up row(s), and W needs two verification requests"
: > "$WORK/w-empty.jsonl"
expect_w empty "$WORK/w-empty.jsonl" "only 0 warm-up row(s)"
printf 'not json\n' > "$WORK/w-garbage.jsonl"
expect_w not-json "$WORK/w-garbage.jsonl" "warm-up row 1 of $WORK/w-garbage.jsonl is not JSON"

# --- 9. the warm-up boundary --------------------------------------------------------------------------
say "9. a -log cell records its last warm-up iteration; the others record none"
# expect_boundary <label> <log text> <want|phrase> [logs-fail]
expect_boundary() {
	rm -f "$WORK/out/warmup-boundary-$1-1.txt"
	out=$(
		# shellcheck disable=SC1090,SC1091
		. "$WORK/fns.sh"
		# shellcheck disable=SC1091
		. "$WORK/stubs.sh"
		STUDY="$IV2" OUT="$WORK/out" NS_A=a STUB_LOG="$2" STUB_LOGS_FAIL="${4:-}"
		warmup_boundary_record "$1" 1
	) && rc=0 || rc=$?
	got=$(cat "$WORK/out/warmup-boundary-$1-1.txt" 2>&1) || got="<no file>"
	case "$3" in
		[0-9]* | none)
			[ "$rc" = 0 ] && [ "$got" = "$3" ] && ok "$1 wrote warmup-boundary-$1-1.txt holding $got" \
				|| bad "$1 should have written $3; rc=$rc file=${got@Q} out=${out@Q}" ;;
		*)
			[ "$rc" != 0 ] && [ "$got" = "<no file>" ] && printf '%s' "$out" | grep -qF "$3" && ok "$1 refused with no file written: $out" \
				|| bad "$1 was not refused with '$3'; rc=$rc file=${got@Q} out=${out@Q}" ;;
	esac
}
# iterlog.py's line shape, so the boundary is read from what the evaluator parses.
iter_line() { printf 'INFO 10-05 12:00:00 [loggers.py:182] %sIteration(%d): 1 context requests, 2048 context tokens, 0 generation requests, 0 generation tokens, iteration elapsed time: 10.00 ms' "${2:-}" "$1"; }
ITER2=$(iter_line 12)
# The highest index, not the last line's, and the data-parallel prefix is read too.
expect_boundary serial-log "startup
$(iter_line 5)
$(iter_line 40 'Engine 000: ')
$ITER2" 40
expect_boundary burst-log "startup only" "holds no Iteration(N) line after its warm-up"
expect_boundary stagger-log "$ITER2" "could not read the engine log after stagger-log rep 1's warm-up" 1
expect_boundary serial-nolog "$ITER2" none
expect_boundary burst-async "" none

# A stub benchharness that answers the warm-up's two calls and records what it was asked.
cat > "$WORK/benchharness" <<'BH'
#!/bin/bash
echo "$*" >> "$BH_LOG"
case "$1" in
	gen-trace)
		warm=0; t=""; m=""
		while [ $# -gt 0 ]; do
			case "$1" in --warmup) warm=1 ;; --trace-out) t="$2"; shift ;; --manifest-out) m="$2"; shift ;; esac
			shift
		done
		if [ "$warm" = 1 ] && [ -n "${BH_WARM_TRACE:-}" ]; then
			cp "$BH_WARM_TRACE" "$t"
		elif [ "$warm" = 1 ]; then
			[ -z "${BH_NO_WARMUP:-}" ] || { echo "flag provided but not defined: -warmup" >&2; exit 2; }
			printf '{"index":0,"offsetMs":0}\n{"index":1,"offsetMs":1000}\n{"index":2,"offsetMs":%s}\n{"index":3,"offsetMs":%s}\n' \
				"${BH_LAST_OFFSET:-61000}" "${BH_LAST_OFFSET:-61000}" > "$t"
		else
			printf '{"index":0,"offsetMs":0}\n' > "$t"
		fi
		echo "manifest" > "$m" ;;
	replay)
		while [ $# -gt 0 ]; do case "$1" in --raw-out) cp "$BH_WARM_RAW" "$2"; shift ;; esac; shift; done ;;
	# What PLAN_ONLY asks before and after each trace, answered as the registry answers these studies.
	study-arrivals) echo episodes ;;
	study-traces) echo one ;;
	study-frozen-tuple) echo "study $3 froze no load tuple" >&2; exit 1 ;;
	matrix-plan-check)
		while [ $# -gt 0 ]; do case "$1" in --arm) echo "$2: stub plan check passed"; shift ;; esac; shift; done ;;
	*) echo "stub benchharness refuses $1" >&2; exit 1 ;;
esac
BH
chmod +x "$WORK/benchharness"

# --- 10. run_warmup end to end ------------------------------------------------------------------------
say "10. run_warmup generates, replays, records the boundary and judges W, ending the run on a refusal"
# drive_warmup <label> <raw fixture> <log text>: runs run_warmup in a subshell; output to $WORK/warm.out
drive_warmup() {
	rm -f "$WORK/out/"*warmup* "$WORK/bh.log" "$WORK/out/cell-timings.tsv" "$WORK/out/"cell-refused-*.txt
	(
		# shellcheck disable=SC1090,SC1091
		. "$WORK/fns.sh"
		# shellcheck disable=SC1091
		. "$WORK/stubs.sh"
		cell_n=1 cell_secs=0 cells_done=0 CELL_T0=$(date +%s)
		STUDY="${DW_STUDY:-$IV2}" LADDER="" OUT="$WORK/out" NS_A=a STUB_LOG="$3" SEEDS="" TRACE_POLICY=one
		MODEL=Qwen/Qwen2.5-3B-Instruct REQUEST_TIMEOUT_MS=120000 ENGINE_IMAGE=e@sha256:1 GATEWAY_IMAGE_REF=g@sha256:2
		SOURCE_COMMIT=abc MODEL_REVISION=rev PROVENANCE_FLAG=--require-provenance LOAD_FLAGS=() PROMPT_FLAGS=()
		export BH_LOG="$WORK/bh.log" BH_WARM_RAW="$2"
		run_warmup "$1" 1
	) > "$WORK/warm.out" 2>&1
}
if drive_warmup serial-log "$WORK/w-good.jsonl" "$ITER2"; then
	files=$(cd "$WORK/out" && ls raw-warmup-serial-log-1.jsonl warmup-boundary-serial-log-1.txt warmup-trace-serial-log-1.jsonl warmup-manifest-serial-log-1.yaml 2>&1 | tr '\n' ' ')
	[ "$files" = "raw-warmup-serial-log-1.jsonl warmup-boundary-serial-log-1.txt warmup-manifest-serial-log-1.yaml warmup-trace-serial-log-1.jsonl " ] \
		&& ok "a passing warm-up leaves its four files in OUT" || bad "the warm-up left: $files"
	[ "$(cat "$WORK/out/warmup-boundary-serial-log-1.txt")" = 12 ] && ok "its boundary is the log's last iteration, 12" \
		|| bad "its boundary reads $(cat "$WORK/out/warmup-boundary-serial-log-1.txt")"
	g=$(grep '^gen-trace' "$WORK/bh.log")
	[ "$g" = "gen-trace --warmup --seed 11 --duration-ms 100000 --study $IV2 --arm serial-log --model Qwen/Qwen2.5-3B-Instruct --gateway-url http://127.0.0.1:18080 --engine-image e@sha256:1 --gateway-image g@sha256:2 --gateway-sha abc --tokenizer-rev rev --timeout-ms 120000 --trace-out $WORK/out/warmup-trace-serial-log-1.jsonl --manifest-out $WORK/out/warmup-manifest-serial-log-1.yaml" ] \
		&& ok "gen-trace --warmup is called with the cell's seed and provenance and the warm-up's own length" || bad "gen-trace was called as: $g"
	r=$(grep '^replay' "$WORK/bh.log")
	[ "$r" = "replay --manifest $WORK/out/warmup-manifest-serial-log-1.yaml --require-provenance --target http://127.0.0.1:18080 --api-keys premium-1=premium-key,standard-noisy=standard-key --raw-out $WORK/out/raw-warmup-serial-log-1.jsonl" ] \
		&& ok "the warm-up replays its own manifest into raw-warmup-serial-log-1.jsonl" || bad "replay was called as: $r"
else
	bad "a good warm-up was refused: $(tail -3 "$WORK/warm.out")"
fi
drive_warmup serial-log "$WORK/w-slow.jsonl" "$ITER2" && bad "a slow warm-up went on to the measured replay" \
	|| { grep -qF "MATRIX FAILED: W REFUSED serial-log rep 1: the warm-up verification requests are" "$WORK/warm.out" \
		&& ok "a slow warm-up ends the run: $(grep -o 'W REFUSED.*' "$WORK/warm.out" | cut -c1-200)" || bad "wrong failure: $(tail -2 "$WORK/warm.out")"; }
[ "$(awk -F'\t' 'NR > 1 {print $2 "/" $3 "/" $4}' "$WORK/out/cell-timings.tsv")" = "serial-log/1/refused-at-warmup" ] \
	&& grep -q '^W REFUSED serial-log rep 1: ' "$WORK/out/cell-refused-serial-log-1.txt" \
	&& ok "the W refusal is recorded as the cell's outcome, refused-at-warmup, with its message in cell-refused-serial-log-1.txt" \
	|| bad "the W refusal was not recorded: $(cat "$WORK/out/cell-timings.tsv" "$WORK/out/cell-refused-serial-log-1.txt")"
[ -f "$WORK/out/raw-warmup-serial-log-1.jsonl" ] && [ -f "$WORK/out/warmup-boundary-serial-log-1.txt" ] \
	&& ok "a refused warm-up's rows and boundary stay in OUT for the archive" || bad "a refused warm-up left no evidence"
drive_warmup serial-log "$WORK/w-good.jsonl" "startup only" && bad "a -log warm-up with no iterations went on" \
	|| { grep -qF "MATRIX FAILED: REFUSED serial-log rep 1 at its warm-up boundary: the engine log for serial-log holds no Iteration(N) line" "$WORK/warm.out" \
		&& ok "a -log warm-up with no iteration line ends the run" || bad "wrong failure: $(tail -2 "$WORK/warm.out")"; }
BH_NO_WARMUP=1 drive_warmup serial-log "$WORK/w-good.jsonl" "$ITER2" && bad "a harness without --warmup was accepted" \
	|| { grep -qF "MATRIX FAILED: gen-trace --warmup serial-log" "$WORK/warm.out" \
		&& ok "a benchharness that refuses --warmup ends the run before any replay" || bad "wrong failure: $(tail -2 "$WORK/warm.out")"; }
# The two replays take the same flags, read as text so a flag added to one and not the other is seen.
replay_flags() { extract "$1" | awk '/benchharness" replay --manifest/ {on = 1} on {print} on && /--raw-out/ {exit}' \
	| sed -e 's/--manifest "[^"]*"//' -e 's/--raw-out "[^"]*"//' -e 's/|| fail .*//' -e 's/\\$//' | tr -s ' \t\n' ' '; }
rw=$(replay_flags run_warmup)
rc_=$(replay_flags run_cell)
[ "$rw" = "$rc_" ] && [ -n "$rc_" ] && ok "the warm-up replay takes the measured replay's flags:$rc_" \
	|| bad "the replays differ: warm-up ${rw@Q} measured ${rc_@Q}"
body=$(extract run_cell)
w=$(printf '%s\n' "$body" | grep -n 'run_warmup "\$label" "\$rep"' | cut -d: -f1)
p=$(printf '%s\n' "$body" | grep -n '\[ "\$pf_up" = "1" \]' | cut -d: -f1)
g=$(printf '%s\n' "$body" | grep -n 'benchharness" gen-trace --seed' | cut -d: -f1)
s=$(printf '%s\n' "$body" | grep -n 'scrape_engine_metrics "\$arm" "\$label" "\$rep" before' | cut -d: -f1)
if [ -n "$w" ] && [ -n "$p" ] && [ -n "$g" ] && [ -n "$s" ] && [ "$p" -lt "$w" ] && [ "$w" -lt "$g" ] && [ "$w" -lt "$s" ]; then
	ok "run_cell warms up after the gateway is proved ($p < $w) and before the measured trace ($g) and scrape ($s)"
else
	bad "run_cell's order is gateway=$p warm-up=$w gen-trace=$g scrape=$s"
fi
printf '%s\n' "$body" | grep -B2 'run_warmup "\$label" "\$rep"' | grep -qF 'iv_has_warmup "${STUDY:-}"' \
	&& ok "only a study with a warm-up calls it" || bad "run_warmup is not guarded by iv_has_warmup"

# --- 11. the upload and the accounting ----------------------------------------------------------------
say "11. the per-cell upload sends the warm-up's files and the accounting counts them"
for f in 'raw-warmup-$arm-$rep.jsonl' 'warmup-boundary-$arm-$rep.txt' 'warmup-trace-$arm-$rep.jsonl' 'warmup-manifest-$arm-$rep.yaml'; do
	grep -qF "send \"\$out/$f\" \"$f\"" hack/m5c-gpu-session.sh && ok "the per-cell upload sends $f" || bad "the per-cell upload does not send $f"
done
# account <dir>: the per-class rows and the total, from the extracted functions over a crafted OUT.
account() {
	(
		# shellcheck disable=SC1090
		. "$WORK/fns.sh"
		LADDER="" OUT="$1"
		expected_outputs_by_class
		echo "total $(expected_outputs | cut -d' ' -f1) $(($(find "$1" -maxdepth 1 -type f | wc -l) + 1))"
	)
}
A="$WORK/acct"
mkdir -p "$A"
printf 'cell\tarm\trep\toutcome\tstart_utc\tend_utc\telapsed_s\tcum_s\tcells_done\n1\tserial-log\t1\tcompleted\ta\tb\t60\t60\t1\n' > "$A/cell-timings.tsv"
for f in evidence.log load-source.txt cell-judgements.tsv applied-values.tsv cell-environment.tsv engine-log-serial-log-1.txt \
	trace-serial-log-1.jsonl raw-serial-log-1.jsonl manifest-serial-log-1.yaml port-forward-serial-log-1.log \
	engine-metrics-serial-log-1-before.prom engine-metrics-serial-log-1-after.prom; do : > "$A/$f"; done
before=$(account "$A")
for f in raw-warmup-serial-log-1.jsonl warmup-boundary-serial-log-1.txt warmup-trace-serial-log-1.jsonl warmup-manifest-serial-log-1.yaml; do : > "$A/$f"; done
after=$(account "$A")
mism=$(printf '%s\n' "$after" | awk '$2 != $3')
[ -z "$mism" ] && ok "a completed session-2 cell with its warm-up agrees in every class and in total" || bad "classes disagree: $mism"
[ "$(printf '%s\n' "$after" | grep '^conditional')" = "conditional 7 7" ] && [ "$(printf '%s\n' "$before" | grep '^conditional')" = "conditional 3 3" ] \
	&& ok "the four warm-up files are counted in the conditional row (3 -> 7), not as strays or unattributed" \
	|| bad "conditional before ${before@Q} after ${after@Q}"
[ "$(printf '%s\n' "$after" | grep '^stray-cell-outputs')" = "stray-cell-outputs 0 0" ] && [ "$(printf '%s\n' "$after" | grep '^unattributed')" = "unattributed 0 0" ] \
	&& ok "raw-warmup-* is not read as a stray cell output" || bad "stray or unattributed moved: $after"

# --- 12. the projections charge the warm-up ------------------------------------------------------------
say "12. session 2's deadline projections charge each cell its warm-up's span"
proj=$(
	# shellcheck disable=SC1090
	. "$WORK/fns.sh"
	LADDER="" STUDY="$IV2" SEEDS="" TRACE_POLICY=one MODEL=m REQUEST_TIMEOUT_MS=1 PROMPT_FLAGS=()
	IV_S2_DURATION_MS_SERIAL=200000 IV_S2_DURATION_MS_BURST=300000 IV_S2_DURATION_MS_STAGGER=600000
	export BH_LOG="$WORK/bh-proj.log"
	rm -f "$BH_LOG" "$WORK"/warmup-plan-*
	CELLS=("R1|serial-log|1|1|0|0" "R1|stagger-log|1|1|0|0" "R1|burst-log|2|1|0|0")
	echo "charge=$(cell_charge_ms serial-log 1)"
	# 61000 + 30000 of warm-up on each: (8+5+1) + (8+12+1) + (8+7+1) = 51, times 1.2 = 61.
	echo "cold=$(iv_cold_projection_min)"
	# two cells done in 1500 s whose charges were 291 + 691 s: overhead (1500-982+1)/2 = 259 s.
	# the last is 259 + 391 = 650 s; 650*1.2 = 780 s = 13 min (rounded up, (780+59)/60).
	cells_done=2 cell_secs=1500
	echo "mid=$(iv_remaining_projection)"
	echo "gens=$(grep -c -- '--warmup' "$BH_LOG")"
)
[ "$proj" = "charge=291000
cold=61
mid=13 650 259
gens=3" ] && ok "each cell is charged its length plus its warm-up, and each warm-up trace is generated once: $(echo $proj)" \
	|| bad "projection read ${proj@Q}"
proj1=$(
	# shellcheck disable=SC1090
	. "$WORK/fns.sh"
	LADDER="" STUDY="$IV"
	export BH_LOG="$WORK/bh-proj1.log"
	rm -f "$BH_LOG"
	echo "$(cell_charge_ms serial-log 1) $([ -e "$BH_LOG" ] && echo called || echo not-called)"
)
[ "$proj1" = "180000 not-called" ] && ok "session 1 is charged its length alone and never asks for a warm-up" || bad "session 1's charge read ${proj1@Q}"

# --- 13. the real matrix's plan, session 2 filled in, and session 1 against its own history -------------
# The commit session 2's harness was built on; session 1's plan must read as it did there.
# A later change that moves session 1 on purpose updates this SHA in the same change, and says why.
S1_BASE=d0e04c292fcb489a2b1a77f7a7028540101c90e3
# CI checks out one commit deep, so the base is fetched by its full SHA when it is not already here.
# A fetch that fails still fails the comparison below, loudly: an absent base is not a passed comparison.
git cat-file -e "$S1_BASE^{commit}" || git fetch --quiet --depth=1 origin "$S1_BASE" || true
say "13. PLAN_ONLY generates every session-2 warm-up, and session 1's plan output is byte-identical to $S1_BASE"
# tree <dir> [ref]: the files PLAN_ONLY reads, from the working tree or, for the matrix and its lib, from ref.
tree() {
	mkdir -p "$1/hack"
	cp -r hack/lib hack/input-length-resolution.json "$1/hack/" && cp -r config "$1/" && cp "$SRC" "$1/hack/" || return 1
	if [ -n "${2:-}" ]; then
		git show "$2:hack/m5c-matrix.sh" > "$1/hack/m5c-matrix.sh" && git show "$2:$LIB" > "$1/$LIB" || return 1
	fi
}
# plan_run <tree> <out> env...: PLAN_ONLY through the answering stub; output and the stub's log, normalized.
plan_run() {
	local t="$1" o="$2"
	shift 2
	rm -rf "$o" "$WORK/bh-plan.log"
	env -u DURATION_MS -u SWEEP -u LADDER -u RATE -u PREMIUM_WEIGHT -u NOISY_WEIGHT -u PROBE_WEIGHT -u PREMIUM_RATE \
		-u PREMIUM_PROMPT_CHARS -u NOISY_PROMPT_CHARS -u PREMIUM_OUTPUT_TOKENS -u NOISY_OUTPUT_TOKENS -u SEEDS \
		TMPDIR="$WORK/tmp" PLAN_ONLY=1 PLATFORM=kind KCTX=none BENCHHARNESS_BIN="$WORK/benchharness" BH_LOG="$WORK/bh-plan.log" \
		REPS=3 ARMS="$SYNC $ASYNC" OUT="$o" "$@" bash "$t/hack/m5c-matrix.sh" > "$o.out" 2>&1
	local rc=$?
	sed -i -e "s|$t|TREE|g" -e "s|$o|OUT|g" -e 's|tmp\.[A-Za-z0-9]*|TMP|g' "$o.out"
	[ -f "$WORK/bh-plan.log" ] && sed -e "s|$t|TREE|g" -e "s|$o|OUT|g" -e 's|tmp\.[A-Za-z0-9]*|TMP|g' "$WORK/bh-plan.log" > "$o.bh"
	return "$rc"
}
if ! git cat-file -e "$S1_BASE^{commit}"; then
	bad "$S1_BASE is not a commit here, so session 1 cannot be compared against it"
elif tree "$WORK/t-base" "$S1_BASE" && tree "$WORK/t-cur" && tree "$WORK/t-s2"; then
	# Session 1, before and after.
	plan_run "$WORK/t-base" "$WORK/p-base" STUDY="$IV"; rb=$?
	plan_run "$WORK/t-cur" "$WORK/p-cur" STUDY="$IV"; rcur=$?
	if [ "$rb" = 0 ] && [ "$rcur" = 0 ] && grep -q "^== PLAN OK under study $IV" "$WORK/p-cur.out"; then
		cmp -s "$WORK/p-base.out" "$WORK/p-cur.out" && ok "session 1's PLAN_ONLY output is byte-identical to $S1_BASE's ($(wc -l < "$WORK/p-cur.out") lines)" \
			|| bad "session 1's plan output moved: $(diff "$WORK/p-base.out" "$WORK/p-cur.out" | head -6)"
		cmp -s "$WORK/p-base.bh" "$WORK/p-cur.bh" && ok "session 1 asks the harness exactly what it asked at $S1_BASE ($(wc -l < "$WORK/p-cur.bh") calls, none with --warmup: $(grep -c -- '--warmup' "$WORK/p-cur.bh"))" \
			|| bad "session 1's harness calls moved: $(diff "$WORK/p-base.bh" "$WORK/p-cur.bh" | head -6)"
		cmp -s "$WORK/p-base/load-source.txt" "$WORK/p-cur/load-source.txt" && ok "session 1's load-source.txt is byte-identical" \
			|| bad "session 1's load-source.txt moved: $(diff "$WORK/p-base/load-source.txt" "$WORK/p-cur/load-source.txt" | head -4)"
	else
		bad "session 1's plan did not pass under the answering stub (base rc=$rb, current rc=$rcur): $(tail -2 "$WORK/p-cur.out")"
	fi
	# PLAN_ONLY never prints the load banner or runs a projection, so those are compared from each tree's own
	# functions, driven alike; a mutation of the banner text left every comparison above green.
	s1_fns() (
		cd "$1" || exit 1
		{
			echo 'set -uo pipefail'
			echo ". $LIB"
			for fn in load_banner cell_duration_ms cell_charge_ms warmup_span_ms iv_cold_projection_min iv_remaining_projection; do
				awk -v fn="$fn" '$0 ~ "^" fn "\\(\\) \\{" {inside = 1} inside {print} inside && /^\}/ {exit}' hack/m5c-matrix.sh
			done
		} > fns.sh
		# shellcheck disable=SC1091
		. ./fns.sh
		say() { echo "== $*"; }
		LADDER="" SWEEP="" STUDY="$IV" ARMS="$SYNC $ASYNC" REPS=3 PLATFORM=kind OUT=o
		CELLS=("R1|serial-log|1|0|0|0" "R1|stagger-nolog|2|0|0|0" "R1|burst-async|1|0|0|0")
		load_banner
		echo "cold=$(iv_cold_projection_min)"
		cells_done=1 cell_secs=900
		echo "mid=$(iv_remaining_projection)"
	)
	b=$(s1_fns "$WORK/t-base" 2>&1)
	c=$(s1_fns "$WORK/t-cur" 2>&1)
	[ "$b" = "$c" ] && printf '%s' "$c" | grep -q '^== load: none' && printf '%s' "$c" | grep -q '^cold=[0-9]' \
		&& ok "session 1's banner and both projections read as at $S1_BASE: $(printf '%s' "$c" | grep -E '^(cold|mid)=' | tr '\n' ' ')" \
		|| bad "session 1's banner or projections moved: $(diff <(printf '%s\n' "$b") <(printf '%s\n' "$c") | head -6)"
	# Session 2 as checked in.
	if plan_run "$WORK/t-s2" "$WORK/p-s2" STUDY="$IV2" && grep -q "^== PLAN OK under study $IV2" "$WORK/p-s2.out"; then
		n=$(grep -c 'warm-up span 91000 ms' "$WORK/p-s2.out")
		[ "$n" = 21 ] && ok "every one of the 21 cells has its warm-up generated and its span printed" || bad "$n of 21 cells printed a warm-up span"
		# Each warm-up call is its cell's measured call plus --warmup, once the output paths and length are set aside.
		strip() { sed -e 's/ --warmup//' -e 's/ --duration-ms [0-9]*//' -e 's/ --trace-out [^ ]*//' -e 's/ --manifest-out [^ ]*//' | sort; }
		if [ "$(grep '^gen-trace --warmup' "$WORK/p-s2.bh" | strip)" = "$(grep '^gen-trace' "$WORK/p-s2.bh" | grep -v -- '--warmup' | strip)" ]; then
			ok "each plan warm-up call is the cell's own gen-trace call plus --warmup, with its own length"
		else
			bad "the warm-up calls differ from the measured ones: $(diff <(grep '^gen-trace --warmup' "$WORK/p-s2.bh" | strip) <(grep '^gen-trace' "$WORK/p-s2.bh" | grep -v -- '--warmup' | strip) | head -4)"
		fi
		wl=$(grep '^gen-trace --warmup' "$WORK/p-s2.bh" | sed -E 's/.*--duration-ms ([0-9]+) .*--arm ([a-z]+)-.*/\2=\1/' | sort -u | tr '\n' ' ')
		[ "$wl" = "burst=120000 serial=100000 stagger=500000 " ] && ok "warm-ups are generated at their own lengths: $wl" || bad "warm-up lengths: $wl"
		dl=$(grep '^duration_ms:' "$WORK/p-s2/load-source.txt")
		printf '%s' "$dl" | grep -q ' serial-log/1=500000' && printf '%s' "$dl" | grep -q ' stagger-async/1=2410000' \
			&& ok "load-source.txt records session 2's measured lengths" || bad "load-source.txt: $dl"
	else
		bad "session 2's plan did not pass: $(tail -3 "$WORK/p-s2.out")"
	fi
	# A placeholder put back into the table refuses the plan before anything is generated.
	tree "$WORK/t-s2p" && sed -i 's/^IV_S2_DURATION_MS_BURST=.*/IV_S2_DURATION_MS_BURST=FILL-FROM-GENERATOR-SPAN/' "$WORK/t-s2p/$LIB"
	plan_run "$WORK/t-s2p" "$WORK/p-s2p" STUDY="$IV2" && bad "a plan with a placeholder length passed" \
		|| { grep -qF "MATRIX FAILED: study $IV2's trace length for burst-log is still 'FILL-FROM-GENERATOR-SPAN'" "$WORK/p-s2p.out" \
			&& ! [ -s "$WORK/p-s2p.bh" ] && ok "a placeholder length refuses the plan before the harness is asked anything: $(grep -o 'MATRIX FAILED.*' "$WORK/p-s2p.out" | cut -c1-140)" \
			|| bad "wrong plan failure: $(tail -2 "$WORK/p-s2p.out")"; }
	BH_NO_WARMUP=1 plan_run "$WORK/t-s2" "$WORK/p-s2n" STUDY="$IV2" && bad "a plan whose harness lacks --warmup passed" \
		|| { grep -q 'PLAN REFUSED: gen-trace --warmup could not build serial-.*flag provided but not defined: -warmup' "$WORK/p-s2n.out" \
			&& grep -q '21 planned cell(s) could not be scored' "$WORK/p-s2n.out" \
			&& ok "a harness without --warmup refuses all 21 cells before anything is rented" || bad "wrong plan failure: $(tail -3 "$WORK/p-s2n.out")"; }
else
	bad "could not build the plan trees"
fi

# --- gate S, run per cell by the matrix itself --------------------------------------------------------------
#
# The block is cut out of the matrix and executed, not grepped for, because its condition is what decides whether
# a violating staggered cell stops the session; a stagger rehearsal on kind would take most of an hour per cell.
# Its data are the evaluator's own synthetic session-2 archive, whose staggered episodes satisfy S, and the same
# archive with one prefill moved before its decoders' first tokens.
say "gate S runs per staggered cell of session 2, and nowhere else"
s_block=$(awk '/# Session 2.s gate S, on this cell/ {on=1} on {print} on && /^  fi$/ {exit}' "$SRC")
if [ -z "$s_block" ]; then
	bad "the matrix has no gate-S block to execute"
else
	s_run="$WORK/s-archive"
	mkdir -p "$s_run"
	python3 -c 'import sys; sys.path.insert(0, "hack/tail-crossing-model"); import instrument_gates as g; g._s2_run(sys.argv[1])' "$s_run" \
		|| bad "could not build the synthetic session-2 archive"
	run_s() { ( STUDY="$1"; label="$2"; rep=1; OUT="$s_run"; LADDER=""; engine_log_refusal=""
		. hack/lib/instrument-validation.sh; eval "$s_block"; printf '%s' "$engine_log_refusal" ) }
	r=$(run_s instrument-validation-s2-2026-10-05 stagger-log)
	[ -z "$r" ] && ok "a staggered cell that satisfies S passes" || bad "a good staggered cell was refused: $r"
	python3 - "$s_run" <<'PY'
import json, os, sys
run = sys.argv[1]
trace = {r["index"]: r for r in map(json.loads, open(os.path.join(run, "trace-stagger-log-1.jsonl")))}
prefill = next(i for i, r in trace.items() if r["maxOutputTokens"] == 16)
path = os.path.join(run, "raw-stagger-log-1.jsonl")
rows = [json.loads(l) for l in open(path)]
next(r for r in rows if r["index"] == prefill)["sendUnixNanos"] = 0
open(path, "w").writelines(json.dumps(r) + "\n" for r in rows)
PY
	r=$(run_s instrument-validation-s2-2026-10-05 stagger-log)
	case "$r" in
		"gate S: "*"(gate S)"*) ok "a staggered cell that violates S is refused: ${r:0:120}" ;;
		*) bad "a violating staggered cell was not refused by gate S: ${r:-nothing}" ;;
	esac
	r=$(run_s instrument-validation-s2-2026-10-05 serial-log)
	[ -z "$r" ] && ok "a serial cell is not judged by S" || bad "a serial cell was judged by S: $r"
	r=$(run_s instrument-validation-2026-10-05 stagger-log)
	[ -z "$r" ] && ok "session 1 is not judged by S" || bad "session 1 was judged by S: $r"
fi

# ======================================= session 3 =======================================================
IV3=instrument-validation-s3-2026-10-06

# --- 14. accepted with session 2's lengths, and nothing else of sessions 1 and 2 moves ----------------------
say "14. session 3 is accepted wherever session 2 is, with session 2's lengths, and sessions 1 and 2 do not move"
iv_is_study "$IV3" && iv_has_warmup "$IV3" && ok "session 3 is an instrument-validation study with a warm-up" \
	|| bad "session 3 is not accepted, or has no warm-up"
iv_pins_revision "$IV3" && ! iv_pins_revision "$IV2" && ! iv_pins_revision "$IV" \
	&& iv_fixes_decoder_length "$IV3" && ! iv_fixes_decoder_length "$IV2" && ! iv_fixes_decoder_length "$IV" \
	&& ok "only session 3 pins the revision and fixes the decoders' length" || bad "a session-3 rule reaches session 1 or 2"
l2=""; l3=""
for a in serial-log serial-nolog serial-async burst-log burst-nolog burst-async stagger-log stagger-nolog stagger-async; do
	l2="$l2 $a=$(iv_duration_ms "$IV2" "$a")/$(iv_warmup_duration_ms "$IV2" "$a")"
	l3="$l3 $a=$(iv_duration_ms "$IV3" "$a")/$(iv_warmup_duration_ms "$IV3" "$a")"
done
[ "$l3" = "$l2" ] && ok "every arm's measured and warm-up length is session 2's:$l3" || bad "session 3's lengths differ: ${l3@Q} against ${l2@Q}"
# Sessions 1 and 2 render byte-identical manifests whether or not a revision is passed, so the pin cannot reach them.
for st in "$IV" "$IV2"; do
	for arm in serial-log burst-nolog stagger-async; do
		iv_render_manifest "$st" "$arm" "$BASE" "$WORK/r12-$arm.yaml" "$REV" >/dev/null && cmp -s "$WORK/r12-$arm.yaml" "$WORK/r-$arm.yaml" \
			|| bad "$st's $arm renders differently when given a revision"
	done
done && ok "sessions 1 and 2 render the same manifests with a revision passed as without"
for arm in serial-log burst-nolog stagger-async; do
	if ! why=$(iv_render_manifest "$IV3" "$arm" "$BASE" "$WORK/r3-$arm.yaml" "$REV"); then
		bad "session 3's $arm did not render: $why"
		continue
	fi
	added=$(diff "$WORK/r-$arm.yaml" "$WORK/r3-$arm.yaml" | grep '^>' | sed 's/^> *//' | tr '\n' ' ')
	removed=$(diff "$WORK/r-$arm.yaml" "$WORK/r3-$arm.yaml" | awk '/^</ {c++} END {print c+0}')
	[ "$added" = "- --revision=$REV - --tokenizer-revision=$REV " ] && [ "$removed" = 0 ] \
		&& ok "session 3's $arm is session 2's manifest plus exactly the two revision pins" \
		|| bad "session 3's $arm added ${added@Q} and removed $removed line(s) against session 2's"
done
out=$(iv_render_manifest "$IV3" serial-log "$BASE" "$WORK/x.yaml" main) && bad "session 3 rendered a branch name as its revision" \
	|| { [ "$out" = "study $IV3 pins the engine's model and tokenizer revision and was given 'main', which is not a 40-character commit SHA, so the pin would not name one snapshot" ] \
		&& ok "a revision that is not a commit SHA refuses: $out" || bad "wrong refusal: $out"; }
out=$(iv_render_manifest "$IV3" serial-log "$BASE" "$WORK/x.yaml") && bad "session 3 rendered with no revision" \
	|| { printf '%s' "$out" | grep -qF "was given '', which is not a 40-character commit SHA" && ok "no revision refuses" || bad "wrong refusal: $out"; }

# --- 15. the engine must report the pinned revision -------------------------------------------------------
say "15. a session-3 cell refuses an engine that does not report the pinned revision and tokenizer revision"
# vLLM prints its non-default args as a Python dict, strings single-quoted, as applied-values.tsv of
# hack/m5c-20261005-135632 shows for 'model': 'Qwen/Qwen2.5-3B-Instruct'.
PIN=", 'revision': '$REV', 'tokenizer_revision': '$REV'"
LOG3="non-default args: {'model': 'Qwen/Qwen2.5-3B-Instruct', 'async_scheduling': False, 'enable_logging_iteration_details': True$PIN}"
NOLOG3="non-default args: {'model': 'Qwen/Qwen2.5-3B-Instruct', 'async_scheduling': False$PIN}"
ASYNC3="non-default args: {'model': 'Qwen/Qwen2.5-3B-Instruct'$PIN}"
OTHER=0123456789abcdef0123456789abcdef01234567
# expect_rev <name> <arm> <line> <ok|exact message>
expect_rev() {
	out=$(iv_process_args_refusal "$IV3" "$2" "$3" "$REV") && rc=0 || rc=$?
	if [ "$4" = ok ]; then
		[ "$rc" = 0 ] && ok "$1 passes" || bad "$1 should pass: $out"
	elif [ "$rc" != 0 ] && [ "$out" = "$4" ]; then
		ok "$1 refused: ${out:0:150}"
	else
		bad "$1 was not refused as wanted; rc=$rc out=${out@Q}"
	fi
}
expect_rev "a -log engine reporting both pins" serial-log "$LOG3" ok
expect_rev "a -nolog engine reporting both pins" burst-nolog "$NOLOG3" ok
expect_rev "an -async engine reporting both pins" stagger-async "$ASYNC3" ok
expect_rev "session 2's engine line, with no revision" serial-log "$LOG_LINE" \
	"the engine for serial-log does not report 'revision': '$REV' in its non-default args, so the snapshot it loaded is not the one the study pins: $LOG_LINE"
L="non-default args: {'model': 'Qwen/Qwen2.5-3B-Instruct', 'async_scheduling': False, 'enable_logging_iteration_details': True, 'revision': None, 'tokenizer_revision': '$REV'}"
expect_rev "an engine reporting revision None" serial-log "$L" \
	"the engine for serial-log does not report 'revision': '$REV' in its non-default args, so the snapshot it loaded is not the one the study pins: $L"
# tokenizer_revision alone must not satisfy revision, which a pattern without the leading quote would let it.
L="non-default args: {'model': 'Qwen/Qwen2.5-3B-Instruct', 'async_scheduling': False, 'tokenizer_revision': '$REV'}"
expect_rev "an engine reporting only the tokenizer revision" burst-nolog "$L" \
	"the engine for burst-nolog does not report 'revision': '$REV' in its non-default args, so the snapshot it loaded is not the one the study pins: $L"
L="non-default args: {'model': 'Qwen/Qwen2.5-3B-Instruct', 'revision': '$REV'}"
expect_rev "an engine missing the tokenizer revision" stagger-async "$L" \
	"the engine for stagger-async does not report 'tokenizer_revision': '$REV' in its non-default args, so the snapshot it loaded is not the one the study pins: $L"
L="non-default args: {'model': 'Qwen/Qwen2.5-3B-Instruct', 'revision': '$OTHER', 'tokenizer_revision': '$OTHER'}"
expect_rev "an engine on another revision" stagger-async "$L" \
	"the engine for stagger-async does not report 'revision': '$REV' in its non-default args, so the snapshot it loaded is not the one the study pins: $L"
expect_rev "a pinned engine on the wrong scheduler" serial-log "$ASYNC3" \
	"the engine for serial-log does not report async_scheduling False in its non-default args, so it is not the synchronous engine the arm registers: $ASYNC3"
# Session 2 is judged as before: its old line passes with the revision passed, and the pins change nothing.
iv_process_args_refusal "$IV2" serial-log "$LOG_LINE" "$REV" >/dev/null && iv_process_args_refusal "$IV" serial-log "$LOG_LINE" "$REV" >/dev/null \
	&& ok "sessions 1 and 2 accept their unpinned engine line with a revision passed" || bad "sessions 1 or 2 now demand a revision"
# Through deploy_arm, which is what a paid cell runs.
if STUB_LOG="$LOG3" run_deploy "$IV3" R1 serial-log; then
	grep -qx -- "[[:space:]]*- --revision=$REV" "$WORK/last-applied.yaml" && grep -qx -- "[[:space:]]*- --tokenizer-revision=$REV" "$WORK/last-applied.yaml" \
		&& ok "a session-3 cell applies a manifest carrying both pins and passes its engine's report" \
		|| bad "the applied session-3 manifest lacks a pin: $(grep -- '--' "$WORK/last-applied.yaml" | tr '\n' ' ')"
	awk -F'\t' '$4 == "declared" {print $6}' "$WORK/out/applied-values.tsv" | grep -qF -- "--revision=$REV --tokenizer-revision=$REV" \
		&& ok "the declared row shows both pins" || bad "the declared row lacks the pins: $(awk -F'\t' '$4 == "declared"' "$WORK/out/applied-values.tsv")"
else
	bad "a session-3 cell with a pinned engine was refused: $(tail -2 "$WORK/deploy.out")"
fi
if STUB_LOG="$LOG_LINE" run_deploy "$IV3" R1 serial-log; then
	bad "a session-3 cell deployed on an engine that reports no revision"
elif grep -qF "MATRIX FAILED: REFUSED serial-log before replay: the engine for serial-log does not report 'revision': '$REV'" "$WORK/deploy.out" \
	&& [ "$(awk -F'\t' 'NR > 1 {print $2 "/" $3 "/" $4}' "$WORK/out/cell-timings.tsv")" = "serial-log/1/refused-before-replay" ] \
	&& [ -s "$WORK/out/cell-refused-serial-log-1.txt" ]; then
	ok "an unpinned engine refuses the cell before replay and records it: $(grep -o 'REFUSED serial-log before replay: [^,]*' "$WORK/deploy.out")"
else
	bad "wrong refusal or no record: $(tail -2 "$WORK/deploy.out")"
fi

# --- 16. gate S on the warm-up, and session 3's decoders --------------------------------------------------
say "16. gate S judges the warm-up's staggered cycle before the measured replay, and session 3 its decoders' length"
# stagger_fixture <dir> <arm> <warmup|measured> <good|late|short|stop512|nohead>
# Two staggered episodes (16 and 4 decoders capped at 512, each followed by a 2,048-token prefill capped at 16);
# a warm-up adds the lone warm request at its head and two lone verification requests at its tail.
# late: one decoder ends before its prefill's first token. short: one decoder stops at 480 tokens on `stop`,
# still outlasting the prefill, so only session 3's length rule can see it. stop512: 512 tokens but `stop`.
cat > "$WORK/stagger_fixture.py" <<'PY'
import json, os, sys
d, arm, kind, variant = sys.argv[1:5]
# Session 4's fixtures: `cond` inserts the conditioning request, and the prefill length can be the generator's 8,192.
# Without them the fixture is byte-for-byte what sessions 2 and 3 were tested on.
cond = sys.argv[5] if len(sys.argv) > 5 else "none"
pre_tokens = int(sys.argv[6]) if len(sys.argv) > 6 else 2048
T0 = 1759650000000  # ms
trace, raw = [], []
def add(offset, cap, tokens, ttft, out, end_after_first, finish="length"):
    i = len(trace)
    trace.append(dict(index=i, offsetMs=offset, tenant="premium-1", maxOutputTokens=cap,
                      **({"minOutputTokens": cap} if cap == 512 else {})))
    send = T0 + offset
    raw.append(dict(index=i, sendUnixNanos=send * 10**6, firstTokenUnixNanos=int((send + ttft) * 10**6),
                    endUnixNanos=int((send + ttft + end_after_first) * 10**6), engineInputTokens=tokens,
                    engineOutputTokens=out, finishReason=finish))
if kind == "warmup" and variant != "nohead":
    add(0, 16, 2048, 412.0, 16, 100.0)
for e, n in enumerate((16, 4)):
    t = 100000 * (e + 1)
    for j in range(n):
        out, finish, end = 512, "length", 7665.0
        if e == 0 and j == 3 and variant == "late":
            end = 1500.0
        if e == 1 and j == 2 and variant == "short":
            out, finish = 480, "stop"
        if e == 1 and j == 2 and variant == "stop512":
            finish = "stop"
        add(t, 512, 8192, 300.0, out, end, finish)
    add(t + 2000, 16, pre_tokens, 231.0, 16, 160.0)
v0 = 300000
if kind == "warmup" and cond != "none":
    # cond: the registered 2,048/16 request; cond1024 and cond32 change its length or its cap.
    add(300000, 32 if cond == "cond32" else 16, 1024 if cond == "cond1024" else 2048, 240.0, 16, 100.0)
    v0 = 302000
if kind == "warmup":
    add(v0, 16, 2048, 230.0, 16, 100.0)
    add(v0 + 2000, 16, 2048, 233.0, 16, 100.0)
pre = "warmup-trace" if kind == "warmup" else "trace"
rpre = "raw-warmup" if kind == "warmup" else "raw"
with open(os.path.join(d, f"{pre}-{arm}-1.jsonl"), "w") as f:
    f.writelines(json.dumps(r) + "\n" for r in trace)
with open(os.path.join(d, f"{rpre}-{arm}-1.jsonl"), "w") as f:
    f.writelines(json.dumps(r) + "\n" for r in raw)
PY
# expect_s <name> <study> <phase> <variant> <ok|exact message>: iv_stagger_refusal on a fresh fixture.
expect_s() {
	local d="$WORK/s3-$1"
	rm -rf "$d"; mkdir -p "$d"
	python3 "$WORK/stagger_fixture.py" "$d" stagger-log "$3" "$4" || { bad "$1: the fixture was not written"; return; }
	out=$(iv_stagger_refusal "$2" stagger-log "$d" 1 "$3") && rc=0 || rc=$?
	if [ "$5" = ok ]; then
		[ "$rc" = 0 ] && [ -z "$out" ] && ok "$1 passes" || bad "$1 should pass; rc=$rc out=${out@Q}"
	elif [ "$rc" != 0 ] && [ "$out" = "$5" ]; then
		ok "$1 refused: $out"
	else
		bad "$1 was not refused as wanted; rc=$rc out=${out@Q}"
	fi
}
LATE_W="the warm-up of stagger-log-1: a decoder of the episode at offset 100000 ms finished before the prefill's first token (gate S)"
# Index 20 is the third decoder of the second episode: the warm request is 0, the first episode 1 to 17.
SHORT_W="the warm-up of stagger-log-1: 1 of 20 staggered decoders did not produce 512 output tokens with finish reason length; the first, index 20, has cap 512 and reported 480 tokens and finish reason 'stop' (gate S)"
expect_s "session 2, a good warm-up" "$IV2" warmup good ok
expect_s "session 3, a good warm-up" "$IV3" warmup good ok
expect_s "session 2, a warm-up whose decoder ends before the prefill" "$IV2" warmup late "$LATE_W"
expect_s "session 3, a warm-up whose decoder ends before the prefill" "$IV3" warmup late "$LATE_W"
expect_s "session 2, a warm-up decoder stopping at 480 tokens" "$IV2" warmup short ok
expect_s "session 3, a warm-up decoder stopping at 480 tokens" "$IV3" warmup short "$SHORT_W"
expect_s "session 3, a warm-up decoder at 512 tokens but finish reason stop" "$IV3" warmup stop512 \
	"the warm-up of stagger-log-1: 1 of 20 staggered decoders did not produce 512 output tokens with finish reason length; the first, index 20, has cap 512 and reported 512 tokens and finish reason 'stop' (gate S)"
expect_s "a warm-up without its warm request" "$IV2" warmup nohead \
	"the warm-up of stagger-log-1: the warm-up is not a lone warm request, a staggered cycle and two lone verification requests, so its staggered episodes cannot be told apart (gate S)"
expect_s "session 2, a measured cell decoder stopping at 480 tokens" "$IV2" measured short ok
expect_s "session 3, a measured cell decoder stopping at 480 tokens" "$IV3" measured short \
	"stagger-log-1: 1 of 20 staggered decoders did not produce 512 output tokens with finish reason length; the first, index 19, has cap 512 and reported 480 tokens and finish reason 'stop' (gate S)"
expect_s "session 3, a good measured cell" "$IV3" measured good ok
out=$(iv_stagger_refusal "$IV" stagger-log "$WORK" 1 warmup) && bad "session 1 was judged by the warm-up gate" \
	|| { [ "$out" = "study $IV registers no gate S in the harness, so it judges none" ] && ok "session 1 has no gate S here: $out" || bad "wrong refusal: $out"; }
# The measured block the matrix executes, cut out and run as section "gate S" above runs it, now for session 3.
run_s_in() { ( STUDY="$2"; label=stagger-log; rep=1; OUT="$1"; LADDER=""; engine_log_refusal=""
	. hack/lib/instrument-validation.sh; eval "$s_block"; printf '%s' "$engine_log_refusal" ) }
d="$WORK/s3-block"; rm -rf "$d"; mkdir -p "$d"
python3 "$WORK/stagger_fixture.py" "$d" stagger-log measured short
r=$(run_s_in "$d" "$IV3")
[ "$r" = "gate S: stagger-log-1: 1 of 20 staggered decoders did not produce 512 output tokens with finish reason length; the first, index 19, has cap 512 and reported 480 tokens and finish reason 'stop' (gate S)" ] \
	&& ok "the matrix's measured block refuses session 3's short decoder: ${r:0:110}" || bad "the measured block read ${r@Q}"
r=$(run_s_in "$d" "$IV2")
[ -z "$r" ] && ok "the same cell passes the block under session 2" || bad "session 2's block refused: $r"
# run_warmup end to end: generated, replayed, W passed, then S on the warm-up decides.
# drive_s3 <study> <variant>: the stub replays the fixture's warm-up trace and rows.
drive_s3() {
	local d="$WORK/s3-drive"
	rm -rf "$d"; mkdir -p "$d"
	python3 "$WORK/stagger_fixture.py" "$d" stagger-log warmup "$2" || { echo "the fixture was not written" > "$WORK/warm.out"; return 1; }
	DW_STUDY="$1" BH_WARM_TRACE="$d/warmup-trace-stagger-log-1.jsonl" drive_warmup stagger-log "$d/raw-warmup-stagger-log-1.jsonl" "$ITER2"
}
drive_s3 "$IV3" good && ok "a session-3 staggered warm-up that satisfies S and W goes on to the measured replay" \
	|| bad "a good session-3 staggered warm-up was refused: $(tail -2 "$WORK/warm.out")"
if drive_s3 "$IV3" short; then
	bad "a session-3 warm-up with a short decoder went on to the measured replay"
elif grep -qxF "MATRIX FAILED: REFUSED stagger-log rep 1 at its warm-up: gate S: $SHORT_W" "$WORK/warm.out" \
	&& [ "$(awk -F'\t' 'NR > 1 {print $2 "/" $3 "/" $4}' "$WORK/out/cell-timings.tsv")" = "stagger-log/1/refused-at-warmup" ] \
	&& [ "$(cat "$WORK/out/cell-refused-stagger-log-1.txt")" = "REFUSED stagger-log rep 1 at its warm-up: gate S: $SHORT_W" ]; then
	ok "a short warm-up decoder ends the run before the measured replay and is recorded refused-at-warmup"
else
	bad "wrong failure or no record: $(tail -2 "$WORK/warm.out")"
fi
if drive_s3 "$IV2" late; then
	bad "a session-2 warm-up violating S went on to the measured replay"
elif grep -qxF "MATRIX FAILED: REFUSED stagger-log rep 1 at its warm-up: gate S: $LATE_W" "$WORK/warm.out"; then
	ok "session 2's warm-up is judged by S as well"
else
	bad "wrong failure: $(tail -2 "$WORK/warm.out")"
fi
drive_s3 "$IV2" short && ok "session 2's warm-up does not judge decoder length" || bad "session 2's warm-up was refused: $(tail -2 "$WORK/warm.out")"
body=$(extract run_warmup)
wn=$(printf '%s\n' "$body" | grep -n 'iv_warmup_refusal' | cut -d: -f1)
sn=$(printf '%s\n' "$body" | grep -n 'iv_stagger_refusal' | cut -d: -f1)
[ -n "$wn" ] && [ -n "$sn" ] && [ "$wn" -lt "$sn" ] && ok "run_warmup judges W ($wn) before S ($sn)" || bad "run_warmup's order is W=$wn S=$sn"

# --- 17. a refused cell's outcome, and the accounting that reads it ---------------------------------------
say "17. a refused cell is recorded before the run stops, and its files are not strays"
body=$(extract run_cell)
printf '%s\n' "$body" | grep -A1 '\[ -z "\$engine_log_refusal" \] \\' | grep -qF 'cell_refused_stop "$label" "$rep" after-replay' \
	&& ok "run_cell refuses after replay through cell_refused_stop" || bad "run_cell's after-replay refusal does not record the cell"
if ! unrecorded=$(awk '/fail "(W )?REFUSED/ {print NR ": " $0}' "$SRC"); then
	bad "could not read $SRC for unrecorded refusals"
elif [ -n "$unrecorded" ]; then
	bad "a cell refusal still fails without recording: $unrecorded"
else
	ok "no cell refusal in the matrix calls fail without cell_refused_stop"
fi
# acct_case <name> <outcome> <label-rep> <files...>: a crafted OUT with one completed cell and one refused one.
acct_case() {
	local name="$1" outcome="$2" cell="$3" D="$WORK/acct-$1" f
	shift 3
	rm -rf "$D"; mkdir -p "$D"
	printf 'cell\tarm\trep\toutcome\tstart_utc\tend_utc\telapsed_s\tcum_s\tcells_done\n1\tserial-log\t1\tcompleted\ta\tb\t60\t60\t1\n' > "$D/cell-timings.tsv"
	[ "$outcome" = none ] || printf '2\t%s\t%s\t%s\ta\tb\t60\t120\t2\n' "${cell%-*}" "${cell##*-}" "$outcome" >> "$D/cell-timings.tsv"
	for f in evidence.log load-source.txt cell-judgements.tsv applied-values.tsv cell-environment.tsv engine-log-serial-log-1.txt \
		trace-serial-log-1.jsonl raw-serial-log-1.jsonl manifest-serial-log-1.yaml port-forward-serial-log-1.log \
		engine-metrics-serial-log-1-before.prom engine-metrics-serial-log-1-after.prom "$@"; do : > "$D/$f"; done
	account "$D"
}
C=stagger-log-1
AFTER="trace-$C.jsonl raw-$C.jsonl manifest-$C.yaml port-forward-$C.log engine-metrics-$C-before.prom engine-metrics-$C-after.prom engine-log-$C.txt"
WARM="raw-warmup-$C.jsonl warmup-boundary-$C.txt warmup-trace-$C.jsonl warmup-manifest-$C.yaml"
# shellcheck disable=SC2086
a=$(acct_case unrecorded none $C $AFTER $WARM)
printf '%s\n' "$a" | grep -qx 'stray-cell-outputs 0 6' && ok "session 2's shape, a refused cell with no row, reads as six strays: the defect" \
	|| bad "the unrecorded case read: $(printf '%s\n' "$a" | awk '$2 != $3')"
# shellcheck disable=SC2086
a=$(acct_case after refused-after-replay $C $AFTER $WARM cell-refused-$C.txt)
m=$(printf '%s\n' "$a" | awk '$2 != $3')
[ -z "$m" ] && printf '%s\n' "$a" | grep -qx 'cell-refusal-files 1 1' && printf '%s\n' "$a" | grep -qx 'cell-outputs 8 8' \
	&& ok "a cell refused after replay agrees in every class and in total: $(printf '%s\n' "$a" | grep -E '^(cell-|total)' | tr '\n' ' ')" \
	|| bad "after-replay disagrees: $m"
# shellcheck disable=SC2086
a=$(acct_case warm refused-at-warmup $C port-forward-$C.log $WARM cell-refused-$C.txt)
m=$(printf '%s\n' "$a" | awk '$2 != $3')
[ -z "$m" ] && printf '%s\n' "$a" | grep -qx 'cell-outputs 5 5' && ok "a cell refused at its warm-up owes its port-forward log and agrees" || bad "at-warmup disagrees: $m"
a=$(acct_case before refused-before-replay $C cell-refused-$C.txt)
m=$(printf '%s\n' "$a" | awk '$2 != $3')
[ -z "$m" ] && ok "a cell refused before replay owes only its refusal file and agrees" || bad "before-replay disagrees: $m"
# shellcheck disable=SC2086
a=$(acct_case nofile refused-after-replay $C $AFTER $WARM)
printf '%s\n' "$a" | grep -qx 'cell-refusal-files 1 0' && ok "a recorded refusal whose file is missing is a shortfall in its own class" \
	|| bad "a missing cell-refused file was not seen: $(printf '%s\n' "$a" | awk '$2 != $3')"
a=$(acct_case norow none $C cell-refused-$C.txt)
printf '%s\n' "$a" | grep -qx 'stray-cell-outputs 0 1' && printf '%s\n' "$a" | grep -qx 'cell-refusal-files 0 0' \
	&& ok "a cell-refused file with no row is a stray, not credit" || bad "an unowed cell-refused file read: $(printf '%s\n' "$a" | awk '$2 != $3')"
a=$(acct_case plain none $C)
printf '%s\n' "$a" | grep -q '^cell-refusal-files' && bad "a run with no cell refusal prints a cell-refusal-files row" \
	|| ok "a run with no cell refusal prints the classes it printed before"

# --- 18. the plans: session 2 byte-identical to before session 3, and session 3 is session 2 by another name ---
S2_BASE=b7b319e6e27c5240178c1edaf49c05b8376f424d
git cat-file -e "$S2_BASE^{commit}" || git fetch --quiet --depth=1 origin "$S2_BASE" || true
say "18. session 2's plan is byte-identical to $S2_BASE, and session 3's plan is session 2's under its own id"
if ! git cat-file -e "$S2_BASE^{commit}"; then
	bad "$S2_BASE is not a commit here, so session 2 cannot be compared against it"
elif tree "$WORK/t-base2" "$S2_BASE" && tree "$WORK/t-cur2"; then
	plan_run "$WORK/t-base2" "$WORK/p-base2" STUDY="$IV2"; rb=$?
	plan_run "$WORK/t-cur2" "$WORK/p-cur2" STUDY="$IV2"; rc2=$?
	plan_run "$WORK/t-cur2" "$WORK/p-cur3" STUDY="$IV3"; rc3=$?
	if [ "$rb" = 0 ] && [ "$rc2" = 0 ] && [ "$rc3" = 0 ] && grep -q "^== PLAN OK under study $IV3" "$WORK/p-cur3.out"; then
		for x in out bh; do
			cmp -s "$WORK/p-base2.$x" "$WORK/p-cur2.$x" && ok "session 2's plan $x is byte-identical to $S2_BASE's ($(wc -l < "$WORK/p-cur2.$x") lines)" \
				|| bad "session 2's plan $x moved: $(diff "$WORK/p-base2.$x" "$WORK/p-cur2.$x" | head -6)"
			cmp -s "$WORK/p-cur2.$x" <(sed "s/$IV3/$IV2/g" "$WORK/p-cur3.$x") && ok "session 3's plan $x is session 2's with the study id replaced" \
				|| bad "session 3's plan $x differs from session 2's: $(diff "$WORK/p-cur2.$x" <(sed "s/$IV3/$IV2/g" "$WORK/p-cur3.$x") | head -6)"
		done
		cmp -s "$WORK/p-base2/load-source.txt" "$WORK/p-cur2/load-source.txt" && ok "session 2's load-source.txt is byte-identical" \
			|| bad "session 2's load-source.txt moved: $(diff "$WORK/p-base2/load-source.txt" "$WORK/p-cur2/load-source.txt" | head -4)"
	else
		bad "a plan did not pass (base rc=$rb, session 2 rc=$rc2, session 3 rc=$rc3): $(tail -2 "$WORK/p-cur3.out")"
	fi
else
	bad "could not build the session-2 plan trees"
fi

# ======================================= session 4 =======================================================
IV4=instrument-validation-s4-2026-10-06

# --- 19. accepted with everything of session 3's -----------------------------------------------------------
say "19. session 4 is accepted wherever session 3 is, with session 3's lengths, pins and decoder rule"
iv_is_study "$IV4" && iv_has_warmup "$IV4" && iv_pins_revision "$IV4" && iv_fixes_decoder_length "$IV4" \
	&& ok "session 4 is a warmed, revision-pinned, fixed-decoder study" || bad "session 4 lacks one of session 3's rules"
iv_conditions_warmup "$IV4" && iv_keeps_warmup_refusal_log "$IV4" \
	&& ! iv_conditions_warmup "$IV3" && ! iv_conditions_warmup "$IV2" && ! iv_conditions_warmup "$IV" \
	&& ! iv_keeps_warmup_refusal_log "$IV3" && ! iv_keeps_warmup_refusal_log "$IV2" && ! iv_keeps_warmup_refusal_log "$IV" \
	&& ok "only session 4 conditions its warm-up and keeps a refused warm-up's engine log" || bad "a session-4 rule reaches sessions 1 to 3"
l4=""
for a in serial-log serial-nolog serial-async burst-log burst-nolog burst-async stagger-log stagger-nolog stagger-async; do
	l4="$l4 $a=$(iv_duration_ms "$IV4" "$a")/$(iv_warmup_duration_ms "$IV4" "$a")"
done
[ "$l4" = "$l3" ] && ok "every arm's measured and warm-up length is session 3's:$l4" || bad "session 4's lengths differ: ${l4@Q} against ${l3@Q}"
# The spans are session 3's plus the conditioning request's 2,000 ms gap, until the Go generator reports its own.
[ "$IV_S4_WARMUP_SPAN_MS_SERIAL $IV_S4_WARMUP_SPAN_MS_BURST $IV_S4_WARMUP_SPAN_MS_STAGGER" = "$((87200 + 2000)) $((107580 + 2000)) $((484800 + 2000))" ] \
	&& ok "session 4's warm-up spans are session 3's plus 2,000 ms" || bad "session 4's spans read $IV_S4_WARMUP_SPAN_MS_SERIAL $IV_S4_WARMUP_SPAN_MS_BURST $IV_S4_WARMUP_SPAN_MS_STAGGER"
out=$(IV_S2_WARMUP_DURATION_MS_BURST=109580; iv_warmup_duration_ms "$IV4" burst-log) && bad "a bound equal to session 4's span passed as ${out@Q}" \
	|| { [ "$out" = "study $IV4's warm-up length for burst-log is 109580 ms and its warm-up spans 109580 ms, so the bound does not hold the conditioning request" ] \
		&& ok "a bound that does not exceed session 4's span refuses: $out" || bad "wrong refusal: $out"; }
out=$(IV_S2_WARMUP_DURATION_MS_BURST=109580; iv_warmup_duration_ms "$IV3" burst-log) \
	&& [ "$out" = 109580 ] && ok "the same bound still serves session 3, whose warm-up is shorter" || bad "session 3 read the session-4 span guard: $out"
for arm in serial-log burst-nolog stagger-async; do
	iv_render_manifest "$IV4" "$arm" "$BASE" "$WORK/r4-$arm.yaml" "$REV" >/dev/null && cmp -s "$WORK/r4-$arm.yaml" "$WORK/r3-$arm.yaml" \
		|| bad "session 4's $arm does not render session 3's manifest"
done && ok "session 4 renders session 3's manifests, revision pins included"
out=$(iv_process_args_refusal "$IV4" serial-log "$LOG_LINE" "$REV") && bad "session 4 accepted an unpinned engine" \
	|| { printf '%s' "$out" | grep -qF "does not report 'revision': '$REV'" && ok "session 4 refuses an engine that does not report the pin" || bad "wrong refusal: $out"; }

# --- 20. gate S's warm-up slice: the first request and the last three ----------------------------------------
say "20. session 4's warm-up drops its first and last three requests from S, each of the three a lone 2,048/16 request"
# expect_s4 <name> <study> <variant> <cond> <prefill tokens> <ok|exact message>
expect_s4() {
	local d="$WORK/s4-$1"
	rm -rf "$d"; mkdir -p "$d"
	python3 "$WORK/stagger_fixture.py" "$d" stagger-log warmup "$3" "$4" "$5" || { bad "$1: the fixture was not written"; return; }
	out=$(iv_stagger_refusal "$2" stagger-log "$d" 1 warmup) && rc=0 || rc=$?
	if [ "$6" = ok ]; then
		[ "$rc" = 0 ] && [ -z "$out" ] && ok "$1 passes" || bad "$1 should pass; rc=$rc out=${out@Q}"
	elif [ "$rc" != 0 ] && [ "$out" = "$6" ]; then
		ok "$1 refused: $out"
	else
		bad "$1 was not refused as wanted; rc=$rc out=${out@Q}"
	fi
}
NOCOND="the warm-up of stagger-log-1: the last three requests of the warm-up must each be a lone 2048-token request capped at 16"
expect_s4 "session 4, a warm-up with its conditioning request" "$IV4" good cond 8192 ok
expect_s4 "session 4, the same with 2,048-token prefills" "$IV4" good cond 2048 ok
# Without the conditioner, the third request from the end is the cycle's last prefill, which the generator draws at 256 or 8,192 tokens.
expect_s4 "session 4, a session-3 warm-up with no conditioning request" "$IV4" good none 8192 \
	"$NOCOND, and index 22 is a 8192-token request capped at 16, so the warm-up has no conditioning request (gate S)"
expect_s4 "session 4, a 256-token last prefill and no conditioning request" "$IV4" good none 256 \
	"$NOCOND, and index 22 is a 256-token request capped at 16, so the warm-up has no conditioning request (gate S)"
# A 2,048-token prefill would pass the tail check, and S still refuses the episode left without its prefill.
expect_s4 "session 4, no conditioning request and a 2,048-token last prefill" "$IV4" good none 2048 \
	"staggered trace: the decoders at offset 200000 ms have no prefill after them"
expect_s4 "session 4, a 1,024-token conditioning request" "$IV4" good cond1024 8192 \
	"$NOCOND, and index 23 is a 1024-token request capped at 16, so the warm-up has no conditioning request (gate S)"
expect_s4 "session 4, a conditioning request capped at 32" "$IV4" good cond32 8192 \
	"$NOCOND, and index 23 is a 2048-token request capped at 32, so the warm-up has no conditioning request (gate S)"
expect_s4 "session 4, a warm-up without its warm request" "$IV4" nohead cond 8192 \
	"the warm-up of stagger-log-1: the warm-up is not a lone warm request, a staggered cycle, a lone conditioning request and two lone verification requests, so its staggered episodes cannot be told apart (gate S)"
expect_s4 "session 4, a decoder ending before the prefill" "$IV4" late cond 8192 "$LATE_W"
expect_s4 "session 4, a decoder stopping at 480 tokens" "$IV4" short cond 8192 "$SHORT_W"
# Sessions 2 and 3 keep first and last two, so a conditioned warm-up leaves its conditioner inside their slice.
expect_s4 "session 3, a warm-up with a conditioning request" "$IV3" good cond 8192 \
	"staggered trace: the decoders at offset 300000 ms have no prefill after them"
expect_s4 "session 2, a warm-up with a conditioning request" "$IV2" good cond 8192 \
	"staggered trace: the decoders at offset 300000 ms have no prefill after them"
expect_s4 "session 3, its own warm-up with 8,192-token prefills" "$IV3" good none 8192 ok
# The measured phase is not sliced, so session 4 judges a measured cell as session 3 does.
d="$WORK/s4-measured"; rm -rf "$d"; mkdir -p "$d"
python3 "$WORK/stagger_fixture.py" "$d" stagger-log measured short
a3=$(iv_stagger_refusal "$IV3" stagger-log "$d" 1 measured); a4=$(iv_stagger_refusal "$IV4" stagger-log "$d" 1 measured)
[ -n "$a4" ] && [ "$a4" = "$a3" ] && ok "a measured cell is judged identically under sessions 3 and 4" || bad "measured: s3 ${a3@Q} s4 ${a4@Q}"
r=$(run_s_in "$d" "$IV4")
[ "$r" = "gate S: $a4" ] && ok "the matrix's measured block refuses session 4's short decoder" || bad "the measured block read ${r@Q}"

# --- 21. a warm-up refusal keeps the engine log, and the per-cell upload sends it -----------------------
say "21. session 4 keeps a refused warm-up's engine log and runs the real per-cell upload over it; sessions 2 and 3 do neither"
# The real hook, cut out of hack/m5c-gpu-session.sh and run against a recording aws.
awk '/^cat > \/usr\/local\/bin\/m5c-cell-done <<.CELLHOOK.$/ {on = 1; next} on && /^CELLHOOK$/ {exit} on {print}' hack/m5c-gpu-session.sh \
	| sed 's|__BUCKET__|bkt|; s|__PREFIX__|pfx|' > "$WORK/cell-done"
chmod +x "$WORK/cell-done"
grep -q 'engine-log-\$arm-\$rep.txt' "$WORK/cell-done" && bash -n "$WORK/cell-done" || bad "the per-cell hook was not cut out of hack/m5c-gpu-session.sh whole"
mkdir -p "$WORK/awsbin"
printf '#!/bin/bash\necho "$*" >> "$AWS_LOG"\n' > "$WORK/awsbin/aws"
chmod +x "$WORK/awsbin/aws"
# drive_refusal <study> <label> <raw> <log text> <restarts> [logs-fail]: run_warmup with the hook armed.
drive_refusal() {
	# applied-values.tsv is section 1's deploy record in the shared OUT, and the hook would send it as a run record.
	rm -f "$WORK/out/"engine-log-* "$WORK/aws.log" "$WORK/out/applied-values.tsv"
	PATH="$WORK/awsbin:$PATH" AWS_LOG="$WORK/aws.log" CELL_DONE_HOOK="$WORK/cell-done" DW_STUDY="$1" \
		STUB_RESTARTS="$5" STUB_LOGS_FAIL="${6:-}" drive_warmup "$2" "$3" "$4"
}
sent() { awk '{print $3}' "$WORK/aws.log" | sed 's|.*/||' | sort | tr '\n' ' '; }
ELOG="engine startup
$(iter_line 7)
a warm-up's own line"
if drive_refusal "$IV4" serial-nolog "$WORK/w-slow.jsonl" "$ELOG" "0 "; then
	bad "a slow session-4 warm-up went on to the measured replay"
else
	[ "$(cat "$WORK/out/engine-log-serial-nolog-1.txt")" = "$ELOG" ] && ok "a W refusal keeps the engine log, as the cluster returned it" \
		|| bad "the engine log after a W refusal: $(cat "$WORK/out/engine-log-serial-nolog-1.txt" 2>&1)"
	s=$(sent)
	[ "$s" = "cell-refused-serial-nolog-1.txt cell-timings.tsv engine-log-serial-nolog-1.txt raw-warmup-serial-nolog-1.jsonl warmup-boundary-serial-nolog-1.txt warmup-manifest-serial-nolog-1.yaml warmup-trace-serial-nolog-1.jsonl " ] \
		&& ok "the per-cell upload sent the engine log with the warm-up's files and the timing row: $s" || bad "the upload sent: ${s:-nothing}"
	grep -qxF "MATRIX FAILED: $(cat "$WORK/out/cell-refused-serial-nolog-1.txt")" "$WORK/warm.out" \
		&& grep -q '^W REFUSED serial-nolog rep 1: the warm-up verification requests are .*(.*/raw-warmup-serial-nolog-1.jsonl)$' "$WORK/out/cell-refused-serial-nolog-1.txt" \
		&& [ "$(awk -F'\t' 'NR > 1 {print $2 "/" $3 "/" $4}' "$WORK/out/cell-timings.tsv")" = "serial-nolog/1/refused-at-warmup" ] \
		&& ok "the refusal reads as before, with nothing appended, and is recorded refused-at-warmup" || bad "the refusal record: $(tail -2 "$WORK/warm.out")"
fi
drive_refusal "$IV4" serial-log "$WORK/w-good.jsonl" "startup only" "0 " && bad "a session-4 -log warm-up with no iterations went on" \
	|| { [ "$(cat "$WORK/out/engine-log-serial-log-1.txt")" = "startup only" ] && sent | grep -q 'engine-log-serial-log-1.txt' \
		&& grep -qF "MATRIX FAILED: REFUSED serial-log rep 1 at its warm-up boundary:" "$WORK/warm.out" \
		&& ok "a boundary refusal keeps and uploads the engine log" || bad "boundary: $(tail -2 "$WORK/warm.out")"; }
d4="$WORK/s4-drive"; rm -rf "$d4"; mkdir -p "$d4"
python3 "$WORK/stagger_fixture.py" "$d4" stagger-log warmup late cond 8192
BH_WARM_TRACE="$d4/warmup-trace-stagger-log-1.jsonl" drive_refusal "$IV4" stagger-log "$d4/raw-warmup-stagger-log-1.jsonl" "$ITER2" "0 " \
	&& bad "a session-4 warm-up violating S went on" \
	|| { [ "$(cat "$WORK/out/engine-log-stagger-log-1.txt")" = "$ITER2" ] && sent | grep -q 'engine-log-stagger-log-1.txt' \
		&& grep -qxF "MATRIX FAILED: REFUSED stagger-log rep 1 at its warm-up: gate S: $LATE_W" "$WORK/warm.out" \
		&& ok "a warm-up S refusal keeps and uploads the engine log" || bad "warm-up S: $(tail -2 "$WORK/warm.out")"; }
python3 "$WORK/stagger_fixture.py" "$d4" stagger-log warmup good cond 8192
BH_WARM_TRACE="$d4/warmup-trace-stagger-log-1.jsonl" drive_refusal "$IV4" stagger-log "$d4/raw-warmup-stagger-log-1.jsonl" "$ITER2" "0 " \
	&& ! [ -e "$WORK/out/engine-log-stagger-log-1.txt" ] && ! [ -e "$WORK/aws.log" ] \
	&& ok "a passing conditioned warm-up keeps no log early and uploads nothing" || bad "a good session-4 warm-up: $(tail -2 "$WORK/warm.out")"
# A log that could not be read, or covers a restarted container, is named in the refusal; the refusal still stands.
drive_refusal "$IV4" serial-nolog "$WORK/w-slow.jsonl" "$ELOG" "0 " 1
! [ -e "$WORK/out/engine-log-serial-nolog-1.txt" ] \
	&& grep -q "^MATRIX FAILED: W REFUSED serial-nolog rep 1: .* \[engine log: could not read the engine log for serial-nolog rep 1: error: stub logs refused \]$" "$WORK/warm.out" \
	&& ok "an unreadable engine log leaves no file and is named in the refusal" || bad "unreadable log: $(tail -1 "$WORK/warm.out")"
drive_refusal "$IV4" serial-nolog "$WORK/w-slow.jsonl" "$ELOG" "2 "
[ -s "$WORK/out/engine-log-serial-nolog-1.txt" ] && grep -qF "[engine log: kept $WORK/out/engine-log-serial-nolog-1.txt, but the engine pod's restart counts read 2 , not one pod at 0, so it covers the newest container only]" "$WORK/warm.out" \
	&& ok "a restarted engine's log is kept and the refusal says it is partial" || bad "restarted: $(tail -1 "$WORK/warm.out")"
# Sessions 2 and 3: the same refusals, no log, no upload, the same message.
for st in "$IV2" "$IV3"; do
	drive_refusal "$st" serial-nolog "$WORK/w-slow.jsonl" "$ELOG" "0 " && bad "$st: a slow warm-up went on"
	! [ -e "$WORK/out/engine-log-serial-nolog-1.txt" ] && ! [ -e "$WORK/aws.log" ] \
		&& [ "$(tail -1 "$WORK/warm.out")" = "MATRIX FAILED: $(cat "$WORK/out/cell-refused-serial-nolog-1.txt")" ] \
		&& ok "$st's W refusal keeps no log and uploads nothing, as its archive shows" || bad "$st moved: $(ls "$WORK/out" | grep engine-log) $(cat "$WORK/aws.log" 2>&1)"
done
# The engine log is in the accounting's conditional class, so a session-4 refused cell still agrees.
# shellcheck disable=SC2086
a=$(acct_case warm4 refused-at-warmup $C port-forward-$C.log $WARM cell-refused-$C.txt engine-log-$C.txt)
m=$(printf '%s\n' "$a" | awk '$2 != $3')
[ -z "$m" ] && ok "a cell refused at its warm-up with its engine log agrees in every class" || bad "at-warmup with log disagrees: $m"

# --- 22. sessions 1 to 3's plans are byte-identical to the commit before session 4 ----------------------
S4_BASE=a480b8bb75c86fc4f836d6dd0a5f5f636eddf250
git cat-file -e "$S4_BASE^{commit}" || git fetch --quiet --depth=1 origin "$S4_BASE" || true
say "22. sessions 1 to 3's plans are byte-identical to $S4_BASE, and session 4's is session 3's under its own id"
if ! git cat-file -e "$S4_BASE^{commit}"; then
	bad "$S4_BASE is not a commit here, so sessions 1 to 3 cannot be compared against it"
elif tree "$WORK/t-base4" "$S4_BASE" && tree "$WORK/t-cur4"; then
	for st in "$IV" "$IV2" "$IV3"; do
		plan_run "$WORK/t-base4" "$WORK/p4b-$st" STUDY="$st"; rb=$?
		plan_run "$WORK/t-cur4" "$WORK/p4c-$st" STUDY="$st"; rc_=$?
		if [ "$rb" = 0 ] && [ "$rc_" = 0 ] && cmp -s "$WORK/p4b-$st.out" "$WORK/p4c-$st.out" && cmp -s "$WORK/p4b-$st.bh" "$WORK/p4c-$st.bh" \
			&& cmp -s "$WORK/p4b-$st/load-source.txt" "$WORK/p4c-$st/load-source.txt"; then
			ok "$st's plan output, harness calls and load-source.txt are byte-identical ($(wc -l < "$WORK/p4c-$st.out") lines, $(wc -l < "$WORK/p4c-$st.bh") calls)"
		else
			bad "$st's plan moved (base rc=$rb, current rc=$rc_): $(diff "$WORK/p4b-$st.out" "$WORK/p4c-$st.out" | head -4)"
		fi
	done
	plan_run "$WORK/t-cur4" "$WORK/p4c-$IV4" STUDY="$IV4"; rc4=$?
	if [ "$rc4" = 0 ] && grep -q "^== PLAN OK under study $IV4" "$WORK/p4c-$IV4.out"; then
		# Session 4 orders block 1 with a staggered cell first, so its plan is session 3's as a set, not line for line.
		for x in out bh; do
			cmp -s <(sort "$WORK/p4c-$IV3.$x" | grep -v '^== plan:') <(sed "s/$IV4/$IV3/g" "$WORK/p4c-$IV4.$x" | sort | grep -v '^== plan:') \
				&& ok "session 4's plan $x is session 3's with the study id replaced, up to order" \
				|| bad "session 4's plan $x differs from session 3's: $(diff <(sort "$WORK/p4c-$IV3.$x") <(sed "s/$IV4/$IV3/g" "$WORK/p4c-$IV4.$x" | sort) | head -4)"
		done
		first4=$(grep -m1 '^== plan:' "$WORK/p4c-$IV4.out" | awk '{print $5}')
		second4=$(grep -m1 '^== plan:' "$WORK/p4c-$IV4.out" | awk '{print $6}')
		case "$first4:$second4" in
			stagger-*:stagger-*) bad "session 4 moved both staggered cells to the front of block 1: $first4 $second4" ;;
			stagger-*:*) ok "session 4's block 1 starts with one staggered cell ($first4), the rest in hash order" ;;
			*) bad "session 4's first cell is ${first4:-nothing}, not a staggered one" ;;
		esac
	else
		bad "session 4's plan did not pass (rc=$rc4): $(tail -2 "$WORK/p4c-$IV4.out")"
	fi
	plan_run "$WORK/t-base4" "$WORK/p4b-$IV4" STUDY="$IV4" && bad "the matrix before session 4 accepted it" \
		|| { grep -qF "MATRIX FAILED: STUDY is '$IV4'" "$WORK/p4b-$IV4.out" && ok "the matrix before this change refused session 4, so the acceptance above is this change's" \
			|| bad "the base refused session 4 differently: $(tail -1 "$WORK/p4b-$IV4.out")"; }
else
	bad "could not build the session-4 plan trees"
fi

# ======================================= step boundary ===================================================
IVS=step-boundary-2026-10-06

# --- 22. the step-boundary study takes session 4's warm-up rules -------------------------------------------
# A review found the study missing from iv_conditions_warmup: gate S then read the warm-up's conditioning request
# as a decoder episode with no prefill and would have refused the first staggered cell of the session.
say "22. the step-boundary study is session 4's in every warm-up rule, and has its own five arms"
iv_is_study "$IVS" && iv_has_warmup "$IVS" && iv_pins_revision "$IVS" && iv_fixes_decoder_length "$IVS" \
	&& iv_conditions_warmup "$IVS" && iv_keeps_warmup_refusal_log "$IVS" \
	&& ok "the step-boundary study is warmed, pinned, fixed-decoder and conditioned like session 4" \
	|| bad "the step-boundary study lacks one of session 4's warm-up rules"
ls=""; l4s=""
for a in serial burst stagger; do
	ls="$ls $a=$(iv_warmup_duration_ms "$IVS" "$a-step")"
	l4s="$l4s $a=$(iv_warmup_duration_ms "$IV4" "$a-log")"
done
[ "$ls" = "$l4s" ] && ok "its warm-up lengths are session 4's:$ls" || bad "its warm-up lengths ${ls@Q} differ from session 4's ${l4s@Q}"
out=$(iv_arm_refusal "$IVS" stagger-log) && bad "the step-boundary study admitted stagger-log" \
	|| ok "the step-boundary study refuses an arm outside its five: $out"
out=$(iv_arm_refusal "$IV4" serial-step) && bad "session 4 admitted a -step arm" \
	|| ok "session 4 refuses a -step arm: $(printf '%s' "$out" | cut -c1-80)"
# The block layout, shared by the matrix and the session's completeness check (the session once failed a complete run).
iv_arm_in_block "$IVS" serial-step 3 && ! iv_arm_in_block "$IVS" serial-log 2 && ! iv_arm_in_block "$IVS" stagger-step 6 \
	&& iv_arm_in_block "$IVS" burst-step 6 && iv_arm_in_block "$IV4" serial-log 2 \
	&& ok "serial and staggered cells are in blocks 1, 3 and 5 only, burst in all six, other studies unchanged" \
	|| bad "iv_arm_in_block does not lay out the registered blocks"
[ "$(iv_request_id_flag "$IVS" stagger-step 3 measured)" = "--request-id-prefix=stagger-step-3-measured" ] \
	&& [ -z "$(iv_request_id_flag "$IV4" stagger-log 3 measured)" ] \
	&& ok "only the step-boundary study tags its requests with X-Request-Id" || bad "request-id flags are wrong"

echo
if [ "$failures" = 0 ]; then
	echo "check-instrument-validation-harness: every check passed"
else
	echo "check-instrument-validation-harness: $failures check(s) FAILED" >&2
	exit 1
fi
