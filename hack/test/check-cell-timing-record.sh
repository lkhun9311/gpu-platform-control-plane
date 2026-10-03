#!/usr/bin/env bash
# Runs the matrix's per-cell timing and judgement recorders, without a card and without a cell.
#
# WHY THIS EXISTS
#
# The fifteen-cell run's per-cell duration is NOWHERE in its archive. The 11.61 min/cell figure this
# repository published was back-computed from raw request timestamps, because `cell_secs` is a running total
# for the projection and nothing wrote the parts. So "was the stop/continue judgement made on a sane
# number" could not be answered after the run at all.
#
# The recorders that fix that are only reached by a real cell on a rented card. Writing them and declaring
# them done would be adding a record nobody has seen produce a row -- the shape this repository keeps
# finding in its own checks. So the functions are extracted and driven here against synthetic values.
#
# WHAT IT REFUSES
#
#   - a completed cell that leaves no row
#   - a REFUSED cell that leaves no row            -- the half a one-sided recorder misses, and the half
#                                                     whose absence would look like a measurement error
#   - a header written twice, or not at all
#   - a row whose column count differs from the header's
#   - a boundary judgement that records only the stops
#   - a `date` failure that moves the columns instead of degrading one field
#
# WHAT IT DOES NOT ESTABLISH
#
# That the matrix CALLS them. The call sites are read here as text, not executed: driving them for real
# needs a cell, and a cell needs a card. The closing line says so.
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

# Extract the two recorders by name from the real script.
#
# Copied rather than sourced: the script runs a paid matrix on import, and `source`-ing it would be the
# worst possible way to test a timing function. awk takes the function bodies between their own braces at
# column zero, which is how every function in that file is written.
extract() {
	awk -v fn="$1" '
		$0 ~ "^" fn "\\(\\) \\{" { inside = 1 }
		inside { print }
		inside && /^\}/ { exit }
	' "$SRC"
}

{
	echo 'set -uo pipefail'
	echo 'cell_n=0; cell_secs=0; cells_done=0; cells_total=15'
	echo 'JUDGE_REMAIN=""; JUDGE_BASIS=""; JUDGE_PROJECTED=""'
	extract cell_timing_record
	extract cell_judgement_record
} > "$WORK/recorders.sh"

for fn in cell_timing_record cell_judgement_record; do
	grep -q "^$fn() {" "$WORK/recorders.sh" ||
		bad "$fn was not extracted from $SRC; the harness is testing nothing"
done

# --- 1. both outcomes leave a row, and the header is written once ------------------------------------------
say "1. a completed cell and a REFUSED cell each leave exactly one row"
OUT="$WORK/out1"
mkdir -p "$OUT"
(
	# shellcheck disable=SC1091
	. "$WORK/recorders.sh"
	OUT="$OUT"
	cell_n=1 cell_secs=700 cells_done=1
	cell_timing_record R1 1 completed 1000 1700
	cell_n=2 cell_secs=1300 cells_done=2
	cell_timing_record mps 1 refused 1700 2300
)
rows=$(grep -cv '^cell	' "$OUT/cell-timings.tsv" 2>/dev/null || echo 0)
heads=$(grep -c '^cell	arm	rep' "$OUT/cell-timings.tsv" 2>/dev/null || echo 0)
if [ "$rows" = 2 ] && [ "$heads" = 1 ]; then
	ok "two rows under one header"
else
	bad "expected 2 rows and 1 header, got rows=$rows headers=$heads: $(tr '\n' '|' < "$OUT/cell-timings.tsv" 2>/dev/null)"
fi
grep -q '	refused	' "$OUT/cell-timings.tsv" 2>/dev/null \
	&& ok "the refused cell is recorded, not only the completed one" \
	|| bad "the refused cell left no row; a timing file that omits refusals disagrees with the projection that consumed their time"
# 1700-1000 = 700, and the elapsed column must be that rather than the cumulative total.
grep -q '	700	' "$OUT/cell-timings.tsv" 2>/dev/null \
	&& ok "the elapsed column is this cell's own time, not the running total" \
	|| bad "no row carries the 700 s this cell took: $(tr '\n' '|' < "$OUT/cell-timings.tsv" 2>/dev/null)"

# --- 2. every row has the header's column count -----------------------------------------------------------
say "2. no row has more or fewer columns than the header"
want=$(head -1 "$OUT/cell-timings.tsv" | awk -F'\t' '{print NF}')
badcols=$(awk -F'\t' -v w="$want" 'NF != w {c++} END {print c+0}' "$OUT/cell-timings.tsv")
if [ "$badcols" = 0 ]; then
	ok "all rows have $want columns"
else
	bad "$badcols row(s) do not have the header's $want columns"
fi

# --- 3. a broken date degrades ONE field and does not shift the row ---------------------------------------
say "3. an unconvertible timestamp degrades one field rather than moving the columns"
OUT2="$WORK/out3"
mkdir -p "$OUT2"
(
	# shellcheck disable=SC1091
	. "$WORK/recorders.sh"
	OUT="$OUT2"
	cell_n=1 cell_secs=0 cells_done=1
	# A start that cannot be a timestamp at all.
	#
	# The first version of this case passed "" and it did NOT exercise the fallback: the function reads
	# "@${t0:-0}", so an empty string becomes 0 and `date` happily returns 1970-01-01. The assertion then
	# failed for a reason that had nothing to do with the path it was written for -- a fixture that misses
	# its own target. "xyz" is what `date` actually refuses.
	cell_timing_record R1 1 completed "xyz" 1700
) 2> "$WORK/date.err"
got=$(awk -F'\t' 'NR==2 {print NF}' "$OUT2/cell-timings.tsv" 2>/dev/null)
if [ "$got" = "$want" ]; then
	ok "the row still has $want columns"
else
	bad "a bad timestamp produced $got columns against the header's $want; every column after it is shifted"
fi
grep -q 'epoch:' "$OUT2/cell-timings.tsv" 2>/dev/null \
	&& ok "the field says what it could not convert instead of being blank" \
	|| bad "the unconvertible timestamp left a blank rather than a marked value"

# --- 4. the judgement record covers CONTINUES as well as stops --------------------------------------------
say "4. a boundary that continued is recorded, not only one that stopped"
OUT3="$WORK/out4"
mkdir -p "$OUT3"
(
	# shellcheck disable=SC1091
	. "$WORK/recorders.sh"
	OUT="$OUT3"
	cell_n=3 cells_done=3 cells_total=15
	JUDGE_REMAIN=120 JUDGE_BASIS="mean-of-3-completed-cells-700s" JUDGE_PROJECTED=168
	cell_judgement_record stop
	cell_n=4 cells_done=4
	JUDGE_REMAIN=300 JUDGE_BASIS="mean-of-4-completed-cells-690s" JUDGE_PROJECTED=126
	cell_judgement_record continue
	# And a boundary where the deadline could not be read at all: the JUDGE_* are empty, and the row must
	# still exist and say so. An unreadable deadline currently returns "continue", so it is the case most
	# likely to pass unnoticed.
	cell_n=5 cells_done=5
	JUDGE_REMAIN="" JUDGE_BASIS="" JUDGE_PROJECTED=""
	cell_judgement_record continue
)
jrows=$(grep -cv '^at_utc	' "$OUT3/cell-judgements.tsv" 2>/dev/null || echo 0)
if [ "$jrows" = 3 ]; then
	ok "three boundaries, three rows"
else
	bad "expected 3 judgement rows, got $jrows"
fi
grep -q '	continue$' "$OUT3/cell-judgements.tsv" 2>/dev/null \
	&& ok "a boundary that continued left a row" \
	|| bad "only the stops were recorded; afterwards 'the projection was wrong' and 'the projection was never consulted' read the same"
grep -q 'unreadable	none	none' "$OUT3/cell-judgements.tsv" 2>/dev/null \
	&& ok "an unreadable deadline is recorded as unreadable rather than as a number" \
	|| bad "the boundary with no readable deadline did not say so: $(tr '\n' '|' < "$OUT3/cell-judgements.tsv" 2>/dev/null)"

# --- 5. the matrix actually calls them --------------------------------------------------------------------
#
# Read as text. Executing the call sites needs a cell, and a cell needs a card.
say "5. both call sites exist in the matrix, on the completed path AND the refused path"
calls=$(grep -c 'cell_timing_record "\$label" "\$rep"' "$SRC" || true)
if [ "$calls" = 2 ]; then
	ok "two cell_timing_record call sites"
else
	bad "found $calls cell_timing_record call sites, want 2 (completed and refused)"
fi
grep -q 'cell_timing_record "\$label" "\$rep" refused' "$SRC" \
	&& ok "the refused path records" \
	|| bad "the refused path does not record, so its card time would be missing from the file while counted in the projection"
grep -q 'cell_timing_record "\$label" "\$rep" completed' "$SRC" \
	&& ok "the completed path records" \
	|| bad "the completed path does not record"
# The judgement wrapper, not a per-branch call: cell_deadline_check has seven exits.
grep -q 'cell_deadline_check_inner || rc=\$?' "$SRC" \
	&& ok "the judgement is recorded by a wrapper, so a future eighth branch cannot skip it" \
	|| bad "cell_deadline_check no longer wraps its inner check; a record placed per-branch will miss the next branch added"

echo
if [ "$failures" = "0" ]; then
	say "CELL TIMING AND JUDGEMENT RECORDS PRODUCE ROWS: both outcomes, one header, stable columns under a bad timestamp, and every boundary including the ones that continued."
	say "NOT established by this check: that a real cell reaches these functions. The call sites are read as text here -- driving them needs a cell, and a cell needs a rented card. Nor does a recorded number mean the judgement it records was correct; it means the judgement can now be re-examined."
else
	echo "FAILED: $failures assertion(s) above." >&2
	exit 1
fi
