#!/usr/bin/env bash
# Drives the matrix's engine /metrics scrape without a card, an engine or a cluster.
#
# WHY THIS EXISTS
#
# The 2026-10-04 model-first registration found that a mechanism model explains between a fifth and two thirds
# of the shared tail the fifteen-cell run measured, and that nothing in the archive can say where the rest
# went: TTFT is stamped only by the client, and no engine counter was ever read. The scrape is what turns
# the next cell's TTFT into time waiting and time in prefill.
#
# It runs only on a rented card, so it is extracted here and driven against stubbed kubectl and curl.
#
# WHAT IT REFUSES
#
#   - a cell phase that leaves NO file -- a scrape that failed silently reads later as "never measured"
#   - a scrape failure that fails the cell, which would spend a paid cell on secondary evidence
#   - a split topology scraped on one engine only
#   - an answer with no `vllm:` series accepted as the engine's
#   - a port-forward left running, which would hold 18081 for the next cell
#
# WHAT IT DOES NOT ESTABLISH
#
# That this engine build exposes per-request queue and prefill histograms, and that run_cell's call sites
# execute: the first is a property of the image and the second needs a cell. The call sites are read as text.
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
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

extract() {
	awk -v fn="$1" '
		$0 ~ "^" fn "\\(\\) \\{" { inside = 1 }
		inside { print }
		inside && /^\}/ { exit }
	' "$SRC"
}

extract scrape_engine_metrics > "$WORK/fn.sh"
grep -q '^scrape_engine_metrics() {' "$WORK/fn.sh" || bad "scrape_engine_metrics was not extracted from $SRC; the harness is testing nothing"

# kubectl stays up like a real port-forward and records its arguments and pid; curl answers per STUB_CURL.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$STUB_LOG/kubectl.args"
echo $$ >> "$STUB_LOG/kubectl.pids"
[ "${STUB_KUBECTL:-up}" = dies ] && { echo "error: unable to forward port" >&2; exit 1; }
exec sleep 30
EOF
cat > "$WORK/bin/curl" <<'EOF'
#!/usr/bin/env bash
out=""
while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift 2 ;; *) shift ;; esac; done
case "${STUB_CURL:-ok}" in
ok) printf '# HELP vllm:request_queue_time_seconds x\nvllm:request_queue_time_seconds_count 3\n' > "$out" ;;
notengine) printf 'go_gc_duration_seconds 0\n' > "$out" ;;
fail) exit 7 ;;
esac
EOF
chmod +x "$WORK/bin/kubectl" "$WORK/bin/curl"

# Runs the function in a fresh shell, so a failing function cannot take the harness with it.
run() {
	local case_dir="$WORK/$1"
	shift
	mkdir -p "$case_dir/out" "$case_dir/log"
	(
		export PATH="$WORK/bin:$PATH" STUB_LOG="$case_dir/log"
		OUT="$case_dir/out" KCTX=stub NS_A=ns-a NS_B=ns-b METRICS_SCRAPE_TRIES=2
		# shellcheck disable=SC1091
		. "$WORK/fn.sh"
		scrape_engine_metrics "$@"
		echo "rc=$?" > "$case_dir/rc"
	)
	CASE="$case_dir"
}

no_forward_left() {
	local pid
	while read -r pid; do
		kill -0 "$pid" 2>/dev/null && return 1
	done < <(cat "$CASE/log/kubectl.pids" 2>/dev/null)
	return 0
}

say "1. the exclusive engine: one .prom per phase, the forward ended"
run r1 R1 R1 1 before
if [ -f "$CASE/out/engine-metrics-R1-1-before.prom" ] && grep -q '^vllm:' "$CASE/out/engine-metrics-R1-1-before.prom"; then
	ok "R1 before wrote its engine's series"
else
	bad "R1 before left $(ls "$CASE/out" | tr '\n' ' ')rather than engine-metrics-R1-1-before.prom holding vllm: series"
fi
grep -q 'port-forward -n ns-a deploy/vllm-qwen25-3b 18081:8000' "$CASE/log/kubectl.args" 2>/dev/null \
	&& ok "it forwarded to the exclusive engine in NS_A" \
	|| bad "kubectl was called as $(cat "$CASE/log/kubectl.args" 2>/dev/null); wanted a forward to deploy/vllm-qwen25-3b in ns-a"
no_forward_left && ok "the forward is gone, so 18081 is free for the next cell" || bad "a port-forward outlived the scrape"
grep -q 'rc=0' "$CASE/rc" || bad "the scrape returned $(cat "$CASE/rc")"

say "2. a split topology: both engines, each in its own namespace"
run split timeSlicing rung01-timeSlicing 1 after
for s in a b; do
	[ -f "$CASE/out/engine-metrics-rung01-timeSlicing-1-after-$s.prom" ] \
		&& ok "engine $s has its own file" \
		|| bad "engine $s left no engine-metrics-rung01-timeSlicing-1-after-$s.prom; got $(ls "$CASE/out" | tr '\n' ' ')"
done
grep -q 'ns-b deploy/vllm-shared-b' "$CASE/log/kubectl.args" 2>/dev/null \
	&& ok "the second engine was reached in NS_B" \
	|| bad "the second engine was not forwarded in ns-b: $(cat "$CASE/log/kubectl.args" 2>/dev/null)"
no_forward_left || bad "a port-forward outlived the split scrape"

say "3. an engine that never answers: a named .err, and the cell is not failed"
STUB_CURL=fail run noanswer shared shared 2 before
if [ -f "$CASE/out/engine-metrics-shared-2-before.err" ] && [ ! -f "$CASE/out/engine-metrics-shared-2-before.prom" ]; then
	ok "the failure is a file a reader can count, not an absence"
else
	bad "an unanswered scrape left $(ls "$CASE/out" | tr '\n' ' ')rather than one .err and no .prom"
fi
grep -q 'rc=0' "$CASE/rc" && ok "the cell goes on" || bad "a failed scrape returned $(cat "$CASE/rc"); the cell's own evidence would be lost to secondary evidence"
no_forward_left || bad "a port-forward outlived the failed scrape"

say "4. an answer that is not the engine's"
STUB_CURL=notengine run notengine R1 R1 1 after
grep -q 'vllm:' "$CASE/out/engine-metrics-R1-1-after.err" 2>/dev/null \
	&& [ ! -f "$CASE/out/engine-metrics-R1-1-after.prom" ] \
	&& ok "a /metrics page with no vllm: series is refused by name" \
	|| bad "a non-engine answer left $(ls "$CASE/out" | tr '\n' ' ')"

say "5. a forward that dies at once"
STUB_KUBECTL=dies run pfdies R1 R1 1 before
grep -q 'unable to forward port' "$CASE/out/engine-metrics-R1-1-before.err" 2>/dev/null \
	&& ok "the .err carries kubectl's own reason" \
	|| bad "a dead forward left $(ls "$CASE/out" | tr '\n' ' ')without kubectl's reason in an .err"

say "6. a topology with no known engine"
run unknown bogus bogus 1 before
[ -f "$CASE/out/engine-metrics-bogus-1-before.err" ] \
	&& ok "an unknown topology is written down rather than skipped" \
	|| bad "an unknown topology left $(ls "$CASE/out" | tr '\n' ' ')"

say "7. run_cell calls it on both sides of the replay (read as text)"
body=$(extract run_cell)
before_line=$(printf '%s\n' "$body" | grep -n 'scrape_engine_metrics .* before' | head -1 | cut -d: -f1)
replay_line=$(printf '%s\n' "$body" | grep -n 'benchharness" replay' | head -1 | cut -d: -f1)
after_line=$(printf '%s\n' "$body" | grep -n 'scrape_engine_metrics .* after' | head -1 | cut -d: -f1)
if [ -n "$before_line" ] && [ -n "$replay_line" ] && [ -n "$after_line" ] \
	&& [ "$before_line" -lt "$replay_line" ] && [ "$replay_line" -lt "$after_line" ]; then
	ok "before at line $before_line, replay at $replay_line, after at $after_line of run_cell"
else
	bad "run_cell's order is before=${before_line:-absent} replay=${replay_line:-absent} after=${after_line:-absent}"
fi

echo
if [ "$failures" -gt 0 ]; then
	echo "check-engine-metrics-scrape: $failures failure(s)" >&2
	exit 1
fi
echo "check-engine-metrics-scrape: every case passed (the call sites were read as text, not executed)"
