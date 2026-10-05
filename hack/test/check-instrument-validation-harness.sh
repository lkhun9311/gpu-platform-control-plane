#!/usr/bin/env bash
# Pins what the shell harness does differently for instrument-validation-2026-10-05, and that it does
# nothing differently for any other study.
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

FNS="deploy_arm engine_applied_record capture_engine_log cell_duration_ms iv_cold_projection_min iv_remaining_projection"
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
	rm -f "$WORK/out/applied-values.tsv"
	mkdir -p "$WORK/out"
	(
		# shellcheck disable=SC1090,SC1091
		. "$WORK/fns.sh"
		# shellcheck disable=SC1091
		. "$WORK/stubs.sh"
		STUDY="$study" LADDER="" OUT="$WORK/out" NS_A=a NS_B=b GW_IMAGE=g cell_n=1
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
	if ! why=$(iv_render_manifest "$arm" "$BASE" "$WORK/r-$arm.yaml"); then
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
out=$(iv_render_manifest serial-log "$WORK/two-anchors.yaml" "$WORK/x.yaml") \
	&& bad "a base with two port lines rendered" || { echo "$out" | grep -q "has 2 '- --port=8000' lines" && ok "a base with two anchors refuses: $out" || bad "wrong refusal: $out"; }
printf 'args:\n  - --dtype=half\n' > "$WORK/no-anchor.yaml"
out=$(iv_render_manifest serial-log "$WORK/no-anchor.yaml" "$WORK/x.yaml") \
	&& bad "a base with no port line rendered" || { echo "$out" | grep -q "has 0 '- --port=8000' lines" && ok "a base with no anchor refuses: $out" || bad "wrong refusal: $out"; }
out=$(iv_render_manifest R1 "$BASE" "$WORK/x.yaml") \
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

echo
if [ "$failures" = 0 ]; then
	echo "check-instrument-validation-harness: every check passed"
else
	echo "check-instrument-validation-harness: $failures check(s) FAILED" >&2
	exit 1
fi
