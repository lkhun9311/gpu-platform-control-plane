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
	expected_outputs expected_outputs_by_class"
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
	&& ok "iv_is_study accepts both sessions and nothing else" || bad "iv_is_study does not cover exactly the two sessions"
iv_has_warmup "$IV2" && ! iv_has_warmup "$IV" && ok "only session 2 warms up" || bad "iv_has_warmup is not session 2 alone"
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
	|| { printf '%s' "$out" | grep -qF "is neither $IV nor $IV2" && ok "an unknown study refuses: $out" || bad "wrong refusal: $out"; }
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
		if [ "$warm" = 1 ]; then
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
	rm -f "$WORK/out/"*warmup* "$WORK/bh.log"
	(
		# shellcheck disable=SC1090,SC1091
		. "$WORK/fns.sh"
		# shellcheck disable=SC1091
		. "$WORK/stubs.sh"
		STUDY="$IV2" LADDER="" OUT="$WORK/out" NS_A=a STUB_LOG="$3" SEEDS="" TRACE_POLICY=one
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
S1_BASE=d0e04c2
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

echo
if [ "$failures" = 0 ]; then
	echo "check-instrument-validation-harness: every check passed"
else
	echo "check-instrument-validation-harness: $failures check(s) FAILED" >&2
	exit 1
fi
