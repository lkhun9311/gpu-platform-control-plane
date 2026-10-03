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
	extract warm_cell_estimate
	extract expected_outputs
	extract record_expected_files
} > "$WORK/recorders.sh"

for fn in cell_timing_record cell_judgement_record warm_cell_estimate expected_outputs record_expected_files; do
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
# Read the DECISION by its column name, not by its position in the line.
#
# This was `grep -q '	continue$'`, anchored to the end of the row. Adding two columns after the decision
# moved it off the end, and the assertion then failed with the message "only the stops were recorded" --
# which was false: the continues were there. A fixture that names a field by where it happens to sit reports
# the wrong defect the first time the row grows, and the edit that grew it was mine.
col_of() { awk -F'\t' -v name="$2" 'NR==1 {for (i=1; i<=NF; i++) if ($i == name) {print i; exit}}' "$1"; }
dcol=$(col_of "$OUT3/cell-judgements.tsv" decision)
if [ -z "$dcol" ]; then
	bad "cell-judgements.tsv has no 'decision' column, so no assertion below can name the field it means"
elif awk -F'\t' -v c="$dcol" 'NR>1 && $c == "continue" {found=1} END {exit !found}' "$OUT3/cell-judgements.tsv"; then
	ok "a boundary that continued left a row"
else
	bad "only the stops were recorded; afterwards 'the projection was wrong' and 'the projection was never consulted' read the same"
fi
rcol=$(col_of "$OUT3/cell-judgements.tsv" remain_min)
bcol=$(col_of "$OUT3/cell-judgements.tsv" basis)
pcol=$(col_of "$OUT3/cell-judgements.tsv" projected_min)
if [ -n "$rcol" ] && awk -F'\t' -v r="$rcol" -v b="$bcol" -v p="$pcol" \
	'NR>1 && $r == "unreadable" && $b == "none" && $p == "none" {found=1} END {exit !found}' \
	"$OUT3/cell-judgements.tsv"; then
	ok "an unreadable deadline is recorded as unreadable rather than as a number"
else
	bad "the boundary with no readable deadline did not say so: $(tr '\n' '|' < "$OUT3/cell-judgements.tsv" 2>/dev/null)"
fi

# --- 4b. the parallel warm-cell estimate reports its sample size, including zero and one -----------------
#
# An external review named three sample boundaries the running mean cannot express: no valid warm cell, one,
# and none for a particular arm. The first two are now reported as themselves rather than smoothed into a
# number -- a mean over no cells is not a long estimate, and a mean over one is a single observation wearing
# an average's name.
#
# Pinned here because the columns were added and nothing held them. That is the shape this file exists for.
say "4b. the warm-cell estimate says 'none' at zero, names a single observation at one, and averages above that"
for tc in "0:none-completed" "1:single-observation" "3:s"; do
	n=${tc%%:*}
	want=${tc#*:}
	OUT4="$WORK/warm$n"
	mkdir -p "$OUT4"
	printf 'cell\tarm\trep\toutcome\tstart_utc\tend_utc\telapsed_s\tcum_s\tcells_done\n' > "$OUT4/cell-timings.tsv"
	i=0
	while [ "$i" -lt "$n" ]; do
		i=$((i + 1))
		printf '%s\tR1\t1\tcompleted\tx\ty\t700\t700\t%s\n' "$i" "$i" >> "$OUT4/cell-timings.tsv"
	done
	# A refused cell in every case, so the estimate is shown to EXCLUDE it rather than merely to average.
	printf '9\tmps\t1\trefused\tx\ty\t600\t600\t9\n' >> "$OUT4/cell-timings.tsv"
	got=$(
		# shellcheck disable=SC1091
		. "$WORK/recorders.sh"
		OUT="$OUT4"
		warm_cell_estimate
	)
	got_n=${got%% *}
	got_per=${got#* }
	if [ "$got_n" != "$n" ]; then
		bad "with $n completed cell(s) the estimator reports n=${got_n@Q}; the sample size it prints is not the one it averaged"
	else
		case "$got_per" in
		*"$want"*) ok "with $n completed cell(s) the parallel estimate reads ${got_per@Q}" ;;
		*) bad "with $n completed cell(s) the parallel estimate reads ${got_per@Q}, which does not contain ${want@Q}" ;;
		esac
	fi
done
# And the refused cell must not be in the average: three 700 s completions beside a 600 s refusal average
# 700, not 675.
refper=$(
	# shellcheck disable=SC1091
	. "$WORK/recorders.sh"
	OUT="$WORK/warm3"
	warm_cell_estimate
)
if [ "${refper#* }" = 700s ]; then
	ok "the refused cell's time is excluded from the warm average"
else
	bad "the warm average reads ${refper@Q} rather than 700s, so the refused cell is inside the sample this figure exists to separate"
fi

# An aggregation that could not run must not print itself as a measurement of zero.
#
# This is the defect class this repository keeps finding, and it was inside the very field added to stop
# it: a file with size and no read permission passes `[ -s ]`, fails awk, and the old code's
# `|| echo 0` turned that into `none-completed` for a file holding two completed cells.
UNREAD="$WORK/unreadable"
mkdir -p "$UNREAD"
cp "$WORK/warm3/cell-timings.tsv" "$UNREAD/cell-timings.tsv"
chmod 000 "$UNREAD/cell-timings.tsv"
if head -c 1 "$UNREAD/cell-timings.tsv" >/dev/null 2>&1; then
	# Root reads anything, so the case did not run. That is reported as a failure rather than passed over:
	# a check that cannot tell "did not run" from "passed" is the thing this file exists to refuse.
	bad "the unreadable-file case did not run -- the file is still readable (running as $(id -un)?), so nothing here establishes that a failed aggregation is distinguishable from an empty sample"
else
	unread_got=$(
		# shellcheck disable=SC1091
		. "$WORK/recorders.sh"
		OUT="$UNREAD"
		warm_cell_estimate
	)
	case "$unread_got" in
	*aggregation-failed*) ok "an unreadable timings file reports ${unread_got@Q} -- the aggregation's own failure, named" ;;
	*none-completed* | 0\ *)
		bad "an unreadable timings file reports ${unread_got@Q}, which a reader takes as 'no cell completed' when the aggregation simply did not run"
		;;
	*)
		bad "an unreadable timings file reports ${unread_got@Q}, which names neither the failure nor a count; 'no file', 'cannot read it' and 'nothing completed' are three different facts and this collapses two of them"
		;;
	esac
fi
chmod 644 "$UNREAD/cell-timings.tsv"

# A missing file is a third fact, and it is not the second one either.
MISSING="$WORK/nofile"
mkdir -p "$MISSING"
missing_got=$(
	# shellcheck disable=SC1091
	. "$WORK/recorders.sh"
	OUT="$MISSING"
	warm_cell_estimate
)
case "$missing_got" in
*no-timings-file*) ok "a missing timings file reports ${missing_got@Q} -- no recorder ever ran, said as itself" ;;
*none-completed* | 0\ *)
	bad "a missing timings file reports ${missing_got@Q}, conflating 'no recorder ever ran' with 'no cell completed'"
	;;
*)
	bad "a missing timings file reports ${missing_got@Q} instead of naming the absent file; a run that never recorded anything is not a run whose file could not be read"
	;;
esac

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

# --- 6. the expected file count comes from the outcomes, and four real archives pin the arithmetic --------
#
# The eighth of the nine log questions asks whether the files came from one run and are complete. The
# published digest lists verify a count they took FROM the directory, which cannot see a file that was never
# written. This count comes from the cells instead.
#
# The four cases below are the real archives' numbers. They are reproduced from synthetic timing rows, so a
# change to the arithmetic reddens here rather than being discovered on a rented card.
say "6. the expected file count is computed from completed cells, refused arms and invalid arms"
expect_count() {
	# $1 completed cells, $2 refused arms, $3 invalid arms, $4 wanted total, $5 the archive it came from
	OUT6="$WORK/exp-$1-$2-$3"
	mkdir -p "$OUT6"
	printf 'cell\tarm\trep\toutcome\tstart_utc\tend_utc\telapsed_s\tcum_s\tcells_done\n' > "$OUT6/cell-timings.tsv"
	i=0
	while [ "$i" -lt "$1" ]; do
		i=$((i + 1))
		printf '%s\tR1\t1\tcompleted\tx\ty\t700\t700\t%s\n' "$i" "$i" >> "$OUT6/cell-timings.tsv"
	done
	i=0
	while [ "$i" -lt "$2" ]; do
		i=$((i + 1))
		printf 'refused because\n' > "$OUT6/refused-arm$i.txt"
		# A refused arm also leaves a timing row, and counting ROWS instead of files would over-expect it.
		printf '9%s\tarm%s\t1\trefused\tx\ty\t600\t600\t9\n' "$i" "$i" >> "$OUT6/cell-timings.tsv"
	done
	i=0
	while [ "$i" -lt "$3" ]; do
		i=$((i + 1))
		printf 'invalid because\n' > "$OUT6/invalid-arm$i.txt"
	done
	got=$(
		# shellcheck disable=SC1091
		. "$WORK/recorders.sh"
		OUT="$OUT6"
		LADDER=""
		expected_outputs
	)
	# The CELL-DERIVED part is what these archives can pin, and only that.
	#
	# Their total cannot be reproduced by today's formula and should not be: they hold two fixed files
	# (evidence.log, README.txt) where a run of this script now leaves five or six. Asserting the total
	# would force the fixed-file set back to the stale constant an external review had just rejected. So the
	# fixed count is taken from the function's own basis string and subtracted from both sides.
	exp=${got%% *}
	basis=${got#* }
	fx=${basis##*fixed-}
	# `$(( ))` treats a non-numeric name as zero WITHOUT an error, so a basis the parse could not read
	# would subtract nothing and the comparison would look like it had accounted for the fixed files.
	# "Could not read the fixed count" must not arrive here as "there were no fixed files".
	case "$fx" in
	'' | *[!0-9]*)
		bad "the basis ${basis@Q} carries no readable fixed-file count, so this case cannot subtract one; an unparsed count would silently behave as zero"
		return
		;;
	esac
	if [ "$(( exp - fx ))" = "$(( $4 - 2 ))" ]; then
		ok "$1 completed + $2 refused arm(s) + $3 invalid arm(s) owes $(( exp - fx )) cell files, as $5's $4 minus its two fixed files"
	else
		bad "$1 completed + $2 refused + $3 invalid gives $(( exp - fx )) cell files (expected $exp, fixed $fx), but $5 holds $(( $4 - 2 )) beside its two fixed files; the per-cell arithmetic and the archives disagree"
	fi
}
#
# ⚠️ These four numbers are the archives AS THEY WERE, and they are no longer the formula's whole test.
#
# The four agreed with a `+2` constant for evidence.log and README.txt, and that agreement was not evidence:
# those runs predate load-source.txt and the two cell-*.tsv recorders, so the constant matched what they
# happened to hold and would have under-counted the very next run. The fixture below therefore builds only
# the files each archive actually had, and the FUTURE shape is a separate case under it.
expect_count 3 1 0 15 m5c-20260912-084918
expect_count 6 0 0 26 m5c-20260913-011031
expect_count 10 0 0 42 m5c-20261001-023515
expect_count 15 0 0 62 m5c-20261002-014903
# The shape this script writes NOW: the same ten completed cells, plus the three files those archives
# predate. 10x4 + 0 + 0 + fixed(evidence.log, load-source.txt, expected-files.txt, cell-timings.tsv,
# cell-judgements.tsv, README.txt) = 46.
OUT6N="$WORK/exp-now"
mkdir -p "$OUT6N"
printf 'cell\tarm\trep\toutcome\tstart_utc\tend_utc\telapsed_s\tcum_s\tcells_done\n' > "$OUT6N/cell-timings.tsv"
i=0
while [ "$i" -lt 10 ]; do
	i=$((i + 1))
	printf '%s\tR1\t1\tcompleted\tx\ty\t700\t700\t%s\n' "$i" "$i" >> "$OUT6N/cell-timings.tsv"
done
printf 'at_utc\tcell\tcells_done\tcells_total\tremain_min\tbasis\tprojected_min\tdecision\twarm_n\twarm_per\n' > "$OUT6N/cell-judgements.tsv"
printf 'x\t1\t1\t10\t60\tnone\tnone\tcontinue\t1\t700s\n' >> "$OUT6N/cell-judgements.tsv"
: > "$OUT6N/evidence.log"
: > "$OUT6N/load-source.txt"
: > "$OUT6N/README.txt"
now_got=$(
	# shellcheck disable=SC1091
	. "$WORK/recorders.sh"
	OUT="$OUT6N"
	LADDER=""
	expected_outputs
)
if [ "${now_got%% *}" = 46 ]; then
	ok "a run of this script's current shape owes 46 files, counting the three its older archives predate and its own expected-files.txt"
else
	bad "a complete ten-cell run of the CURRENT script gives ${now_got%% *} rather than 46; the fixed files are being added as a constant from an older archive's shape, so a complete archive would report a shortfall"
fi
# A refused arm whose file was never written must DISAGREE, not lower both sides by one.
OUT6M="$WORK/exp-row-no-file"
mkdir -p "$OUT6M"
printf 'cell\tarm\trep\toutcome\tstart_utc\tend_utc\telapsed_s\tcum_s\tcells_done\n' > "$OUT6M/cell-timings.tsv"
printf '1\tR1\t1\tcompleted\tx\ty\t700\t700\t1\n' >> "$OUT6M/cell-timings.tsv"
printf '2\tmps\t1\trefused\tx\ty\t600\t600\t2\n' >> "$OUT6M/cell-timings.tsv"
printf 'at_utc\tcell\tcells_done\tcells_total\tremain_min\tbasis\tprojected_min\tdecision\twarm_n\twarm_per\n' > "$OUT6M/cell-judgements.tsv"
: > "$OUT6M/evidence.log"
: > "$OUT6M/load-source.txt"
rowonly_got=$(
	# shellcheck disable=SC1091
	. "$WORK/recorders.sh"
	OUT="$OUT6M"
	LADDER=""
	expected_outputs
)
# 1x4 + refused 1 + invalid 0 + fixed(evidence.log, load-source.txt, expected-files.txt, cell-timings.tsv,
# cell-judgements.tsv) = 10
if [ "${rowonly_got%% *}" = 10 ]; then
	ok "a refused arm with a timing row and no refused-<arm>.txt is still expected, so its absence shows as a shortfall"
else
	bad "a refused arm with a row and no file gives ${rowonly_got%% *} rather than 10; counting the files instead of the rows lowers both sides together and a file that was never written agrees"
fi
# Five refused repetitions of ONE arm are five timing rows and one file.
OUT6R="$WORK/exp-rep-overwrite"
mkdir -p "$OUT6R"
printf 'cell\tarm\trep\toutcome\tstart_utc\tend_utc\telapsed_s\tcum_s\tcells_done\n' > "$OUT6R/cell-timings.tsv"
for r in 1 2 3 4 5; do
	printf '%s\tmps\t%s\trefused\tx\ty\t600\t600\t%s\n' "$r" "$r" "$r" >> "$OUT6R/cell-timings.tsv"
done
printf 'refused because\n' > "$OUT6R/refused-mps.txt"
# A judgements file, because any cell at all means one: cell_deadline_check is run_cell's first line and its
# wrapper records on every exit. A fixture without it would be pinning "a missing judgements file still
# agrees", which is the opposite of what the unconditional expectation is for.
printf 'at_utc\tcell\tcells_done\tcells_total\tremain_min\tbasis\tprojected_min\tdecision\twarm_n\twarm_per\n' > "$OUT6R/cell-judgements.tsv"
rep_got=$(
	# shellcheck disable=SC1091
	. "$WORK/recorders.sh"
	OUT="$OUT6R"
	LADDER=""
	expected_outputs
)
# 0x4 + refused 1 + invalid 0 + fixed(evidence.log, load-source.txt, expected-files.txt, cell-timings.tsv,
# cell-judgements.tsv) = 6. Counting the five ROWS instead of the one arm would give 10.
if [ "${rep_got%% *}" = 6 ]; then
	ok "five refused repetitions of one arm owe one file, not five"
else
	bad "five refused repetitions of one arm give ${rep_got%% *} rather than 6; 10 is what counting the timing rows gives, and the refusal file is written per arm"
fi
# An INVALID arm leaves a `refused` timing row, and must not be expected to leave a refusal file.
#
# mps_clients_connected calls arm_invalid and returns 1 from inside deploy_arm; the caller's
# `if ! deploy_arm` then writes a refused row. So the row says refused while the directory holds
# invalid-mps.txt and no refused-mps.txt, and expecting both would report a complete invalid run as short.
#
# This case exists because the fix for it was green under every other fixture: none of them held an invalid
# file and a refused row together, so deleting the exclusion changed nothing. Checking it by hand in a
# scratch directory is not the same as a gate holding it.
OUT6I="$WORK/exp-invalid-and-refused"
mkdir -p "$OUT6I"
printf 'cell\tarm\trep\toutcome\tstart_utc\tend_utc\telapsed_s\tcum_s\tcells_done\n' > "$OUT6I/cell-timings.tsv"
printf '1\tR1\t1\tcompleted\tx\ty\t700\t700\t1\n' >> "$OUT6I/cell-timings.tsv"
printf '2\tmps\t1\trefused\tx\ty\t600\t600\t2\n' >> "$OUT6I/cell-timings.tsv"
printf 'at_utc\tcell\tcells_done\tcells_total\tremain_min\tbasis\tprojected_min\tdecision\twarm_n\twarm_per\n' > "$OUT6I/cell-judgements.tsv"
printf 'invalid because\n' > "$OUT6I/invalid-mps.txt"
: > "$OUT6I/evidence.log"
: > "$OUT6I/load-source.txt"
inv_got=$(
	# shellcheck disable=SC1091
	. "$WORK/recorders.sh"
	OUT="$OUT6I"
	LADDER=""
	expected_outputs
)
# 1x4 + refused 0 + invalid 1 + fixed 5 = 10. Counting the invalid arm as a refusal too gives 11.
if [ "${inv_got%% *}" = 10 ]; then
	ok "an invalid arm's refused row is not also expected to leave a refusal file (${inv_got#* })"
else
	bad "an invalid arm with a refused row gives ${inv_got%% *} rather than 10; 11 is what expecting a refused-<arm>.txt beside its invalid-<arm>.txt gives, and that reports a complete invalid run as one file short"
fi
# One arm can be refused on one repetition and INVALID on another, leaving both files.
#
# CELLS is repetition-major, so each arm is deployed again every repetition. Excluding an arm from the
# refusal expectation whenever invalid-<arm>.txt exists therefore under-expected by one on a complete
# archive -- and with cell-judgements.tsv also missing, the under-expectation cancelled the shortfall into
# `agree=yes`. The next two cases hold both halves of that.
OUT6B="$WORK/exp-both-files"
mkdir -p "$OUT6B"
printf 'cell\tarm\trep\toutcome\tstart_utc\tend_utc\telapsed_s\tcum_s\tcells_done\n' > "$OUT6B/cell-timings.tsv"
printf '1\tmps\t1\trefused\tx\ty\t600\t600\t1\n' >> "$OUT6B/cell-timings.tsv"
printf '2\tmps\t2\trefused\tx\ty\t600\t1200\t2\n' >> "$OUT6B/cell-timings.tsv"
printf 'at_utc\tcell\tcells_done\tcells_total\tremain_min\tbasis\tprojected_min\tdecision\twarm_n\twarm_per\n' > "$OUT6B/cell-judgements.tsv"
printf 'refused because\n' > "$OUT6B/refused-mps.txt"
printf 'invalid because\n' > "$OUT6B/invalid-mps.txt"
: > "$OUT6B/evidence.log"
: > "$OUT6B/load-source.txt"
both_got=$(
	# shellcheck disable=SC1091
	. "$WORK/recorders.sh"
	OUT="$OUT6B"
	LADDER=""
	expected_outputs
)
# 0x4 + refused file 1 + invalid file 1 + unwritten 0 + fixed 5 = 7, and the directory holds 6 plus its own.
if [ "${both_got%% *}" = 7 ]; then
	ok "an arm that was refused once and invalid once owes both files (${both_got#* })"
else
	bad "an arm with both files gives ${both_got%% *} rather than 7; excluding the arm because invalid-<arm>.txt exists drops the refusal it really did write, and a complete archive then reports a shortfall"
fi
# The cancellation itself: the under-expectation above, beside a genuinely missing judgements file.
OUT6C="$WORK/exp-cancellation"
mkdir -p "$OUT6C"
cp "$OUT6B/cell-timings.tsv" "$OUT6C/cell-timings.tsv"
printf 'refused because\n' > "$OUT6C/refused-mps.txt"
printf 'invalid because\n' > "$OUT6C/invalid-mps.txt"
: > "$OUT6C/evidence.log"
: > "$OUT6C/load-source.txt"
canc_got=$(
	# shellcheck disable=SC1091
	. "$WORK/recorders.sh"
	OUT="$OUT6C"
	LADDER=""
	expected_outputs
)
canc_act=$(( $(find "$OUT6C" -maxdepth 1 -type f | wc -l) + 1 ))
if [ "${canc_got%% *}" = 7 ] && [ "$canc_act" = 6 ]; then
	ok "a missing judgements file beside an arm carrying both files still reads as a shortfall (${canc_got%% *} owed, $canc_act held)"
else
	bad "that archive owes ${canc_got%% *} and holds $canc_act; when those are equal a missing judgements file and an under-expected refusal have cancelled, and the comparison reports agree on an archive with two gaps"
fi
# A missing cell-judgements.tsv must show as a shortfall, not lower the expectation with it.
#
# cell_deadline_check is run_cell's first line and its wrapper records on all seven exits, so any timing row
# at all means a judgements file. Testing for the file instead of assuming it is the defect that made the
# refusal count agree with itself, one file along.
OUT6J="$WORK/exp-no-judgements"
mkdir -p "$OUT6J"
printf 'cell\tarm\trep\toutcome\tstart_utc\tend_utc\telapsed_s\tcum_s\tcells_done\n' > "$OUT6J/cell-timings.tsv"
printf '1\tR1\t1\tcompleted\tx\ty\t700\t700\t1\n' >> "$OUT6J/cell-timings.tsv"
: > "$OUT6J/evidence.log"
: > "$OUT6J/load-source.txt"
noj_got=$(
	# shellcheck disable=SC1091
	. "$WORK/recorders.sh"
	OUT="$OUT6J"
	LADDER=""
	expected_outputs
)
# 1x4 + 0 + 0 + fixed 5 = 9, the judgements file included although it is absent, so its absence shows.
if [ "${noj_got%% *}" = 9 ]; then
	ok "a run with cells but no cell-judgements.tsv still owes one (${noj_got#* }), so the gap is visible"
else
	bad "a run with cells and no cell-judgements.tsv gives ${noj_got%% *} rather than 9; making that file conditional lets a run that never judged a boundary agree with itself"
fi
# The ladder is refused rather than counted with the matrix's formula.
ladder_got=$(
	# shellcheck disable=SC1091
	. "$WORK/recorders.sh"
	OUT="$WORK/exp-6-0-0"
	LADDER="1:shared,timeSlicing"
	expected_outputs
)
case "$ladder_got" in
*ladder-not-expressed*) ok "a ladder run reports ${ladder_got@Q} rather than a matrix count" ;;
*) bad "a ladder run reports ${ladder_got@Q}; its cells are not matrix cells and the matrix formula does not describe them, so a number here would look checked and not be" ;;
esac
# And the two silences, as in section 4b: no file, and a file that cannot be aggregated.
nofile_got=$(
	# shellcheck disable=SC1091
	. "$WORK/recorders.sh"
	OUT="$WORK/nofile"
	LADDER=""
	expected_outputs
)
case "$nofile_got" in
*no-timings-file*) ok "with no timings file the expected count reports ${nofile_got@Q} rather than a count of the fixed files" ;;
*) bad "with no timings file the expected count reports ${nofile_got@Q}; '0 cells completed' and 'no recorder ran' are different facts" ;;
esac
# The third silence. Without this case the `unreadable` branch of expected_outputs pins nothing, which is
# how a branch comes to exist and be dead -- the shape section 4b was written for, one function along.
UNREAD6="$WORK/exp-unreadable"
mkdir -p "$UNREAD6"
cp "$WORK/exp-6-0-0/cell-timings.tsv" "$UNREAD6/cell-timings.tsv"
chmod 000 "$UNREAD6/cell-timings.tsv"
if head -c 1 "$UNREAD6/cell-timings.tsv" >/dev/null 2>&1; then
	bad "the unreadable-file case of the expected count did not run -- the file is still readable (running as $(id -un)?), so the branch that distinguishes a failed aggregation from an empty one is unpinned here"
else
	unread6_got=$(
		# shellcheck disable=SC1091
		. "$WORK/recorders.sh"
		OUT="$UNREAD6"
		LADDER=""
		expected_outputs
	)
	case "$unread6_got" in
	*aggregation-failed*) ok "an unreadable timings file makes the expected count report ${unread6_got@Q}" ;;
	*) bad "an unreadable timings file makes the expected count report ${unread6_got@Q}; a figure produced without reading the outcomes is not an expected count" ;;
	esac
fi
chmod 644 "$UNREAD6/cell-timings.tsv"

# --- 7. a run that died still records the comparison ------------------------------------------------------
#
# The comparison used to be written after README.txt, which is the one path where it is least interesting: a
# run that reached the end has what it owed. The runs worth comparing are the ones that stopped at a
# deadline or hit `fail`, and those leave through cleanup. So the recorder is driven here WITHOUT a
# README.txt -- the shape of a run that stopped after two cells of ten.
say "7. a run that stopped early still leaves expected-files.txt, and its own file is inside the count"
OUT7="$WORK/died"
mkdir -p "$OUT7"
printf 'cell\tarm\trep\toutcome\tstart_utc\tend_utc\telapsed_s\tcum_s\tcells_done\n' > "$OUT7/cell-timings.tsv"
printf '1\tR1\t1\tcompleted\tx\ty\t700\t700\t1\n' >> "$OUT7/cell-timings.tsv"
printf '2\tshared\t1\tcompleted\tx\ty\t700\t1400\t2\n' >> "$OUT7/cell-timings.tsv"
printf 'at_utc\tcell\tcells_done\tcells_total\tremain_min\tbasis\tprojected_min\tdecision\twarm_n\twarm_per\n' > "$OUT7/cell-judgements.tsv"
printf 'x\t2\t2\t10\t5\twarm\t95\tstop\t2\t700s\n' >> "$OUT7/cell-judgements.tsv"
: > "$OUT7/evidence.log"
: > "$OUT7/load-source.txt"
# Four per cell for the two that finished, so the directory holds what a two-cell run leaves.
for c in R1-1 shared-1; do
	for p in trace raw; do : > "$OUT7/$p-$c.jsonl"; done
	: > "$OUT7/manifest-$c.yaml"
	: > "$OUT7/port-forward-$c.log"
done
(
	# shellcheck disable=SC1091
	. "$WORK/recorders.sh"
	OUT="$OUT7"
	LADDER=""
	record_expected_files
) 2>/dev/null
if [ -s "$OUT7/expected-files.txt" ]; then
	ok "a run that stopped at a boundary left expected-files.txt"
else
	bad "a run that stopped early left no expected-files.txt, so the only runs that record the comparison are the ones that did not need it"
fi
# 2x4 + 0 + 0 + fixed(evidence.log, load-source.txt, expected-files.txt, cell-timings.tsv,
# cell-judgements.tsv; no README.txt) = 13, and the directory holds 12 plus the file being written.
died_exp=$(awk -F'\t' '$1 == "expected" {print $2}' "$OUT7/expected-files.txt" 2>/dev/null)
died_act=$(awk -F'\t' '$1 == "actual" {print $2}' "$OUT7/expected-files.txt" 2>/dev/null)
died_agree=$(awk -F'\t' '$1 == "agree" {print $2}' "$OUT7/expected-files.txt" 2>/dev/null)
if [ "$died_exp" = 13 ] && [ "$died_act" = 13 ] && [ "$died_agree" = yes ]; then
	ok "the stopped run owes 13 and holds 13, counting expected-files.txt itself"
else
	bad "the stopped run records expected=${died_exp@Q} actual=${died_act@Q} agree=${died_agree@Q}; a complete-for-its-length archive must agree, and the file being written is one of the files it counts"
fi
# A short archive must say so rather than agreeing.
rm -f "$OUT7/raw-shared-1.jsonl" "$OUT7/expected-files.txt"
(
	# shellcheck disable=SC1091
	. "$WORK/recorders.sh"
	OUT="$OUT7"
	LADDER=""
	record_expected_files
) 2>/dev/null
short_agree=$(awk -F'\t' '$1 == "agree" {print $2}' "$OUT7/expected-files.txt" 2>/dev/null)
case "$short_agree" in
no*) ok "an archive missing one raw file reports ${short_agree@Q}" ;;
*) bad "an archive missing one raw file reports agree=${short_agree@Q}; the comparison exists to notice exactly this" ;;
esac
# Called a SECOND time into the same directory, with the first call's file still there.
#
# hack/test/rehearse-m5c-matrix.sh passes one OUT_DIR to three invocations and never empties it, so from the
# second run on `find` already counts expected-files.txt and an unconditional +1 counted it twice -- which
# could cancel out a genuinely missing file into agree=yes. Every fixture above started from a directory
# without the file, so removing that correction changed nothing anywhere.
: > "$OUT7/raw-shared-1.jsonl" # restore the file the shortfall case removed, so this run is complete again
(
	# shellcheck disable=SC1091
	. "$WORK/recorders.sh"
	OUT="$OUT7"
	LADDER=""
	record_expected_files
) 2>/dev/null
reuse_exp=$(awk -F'\t' '$1 == "expected" {print $2}' "$OUT7/expected-files.txt" 2>/dev/null)
reuse_act=$(awk -F'\t' '$1 == "actual" {print $2}' "$OUT7/expected-files.txt" 2>/dev/null)
reuse_agree=$(awk -F'\t' '$1 == "agree" {print $2}' "$OUT7/expected-files.txt" 2>/dev/null)
if [ "$reuse_exp" = 13 ] && [ "$reuse_act" = 13 ] && [ "$reuse_agree" = yes ]; then
	ok "a second run into the same directory counts its own file once, not twice"
else
	bad "a second run into a directory that already held expected-files.txt records expected=${reuse_exp@Q} actual=${reuse_act@Q} agree=${reuse_agree@Q}; adding 1 unconditionally counts the file twice and can hide a missing one"
fi
# And the recorder must be REACHED on the paths that matter, which this file cannot execute.
#
# Everything above calls record_expected_files directly, so deleting its call site in cleanup left all of it
# green -- the test drove the function and never asked whether anything drives it. Read as text, the way
# section 5 reads the timing recorder's call sites, and for the same reason: exercising a trap needs a run,
# and a run needs a card.
grep -q 'CLEANED=1' "$SRC" && grep -A 2 'CLEANED=1' "$SRC" | grep -q 'record_expected_files' \
	&& ok "cleanup calls record_expected_files, so a run that stopped at a deadline or hit fail still writes the comparison" \
	|| bad "cleanup does not call record_expected_files; only runs that reach the end would record the comparison, and those are the runs whose archives are complete"
# One call site, not one per exit path: cleanup has four traps behind it and `fail` exits through them.
sites=$(grep -c '^\s*record_expected_files$' "$SRC" || true)
if [ "$sites" = 1 ]; then
	ok "one call site, inside the handler every exit passes through"
else
	bad "found $sites bare record_expected_files call sites, want 1; a comparison written from several exit paths is a comparison the next exit path will not have"
fi
# The trap is armed long before the function it ends up calling is defined.
#
# `trap cleanup EXIT` sits at the top of the script and expected_outputs is defined near the cell code, with
# dozens of `fail` calls in between. A run that dies acquiring the card reaches cleanup first, so the
# recorder must survive its own callee not existing yet.
say "7b. a run that died before expected_outputs was defined still leaves a readable, non-numeric record"
OUT7B="$WORK/died-early"
mkdir -p "$OUT7B"
: > "$OUT7B/evidence.log"
: > "$OUT7B/load-source.txt"
(
	# shellcheck disable=SC1091
	. "$WORK/recorders.sh"
	unset -f expected_outputs
	OUT="$OUT7B"
	record_expected_files
) 2>/dev/null
early_exp=$(awk -F'\t' '$1 == "expected" {print $2}' "$OUT7B/expected-files.txt" 2>/dev/null)
early_agree=$(awk -F'\t' '$1 == "agree" {print $2}' "$OUT7B/expected-files.txt" 2>/dev/null)
case "$early_exp:$early_agree" in
*[0-9]:*) bad "a run that died before the counting function existed recorded expected=${early_exp@Q}; a number here is an expectation nothing computed" ;;
:*) bad "a run that died early left no expected field at all (agree=${early_agree@Q}); the file would be read as a comparison with a blank side" ;;
*:not-evaluable*) ok "a run that died before expected_outputs existed records expected=${early_exp@Q} and agree=not-evaluable" ;;
*) bad "a run that died early recorded expected=${early_exp@Q} agree=${early_agree@Q}, which is neither a refusal nor a comparison" ;;
esac
# The guard must be in the production function, not only in this test's arrangement.
grep -q 'declare -F expected_outputs' "$SRC" \
	&& ok "record_expected_files checks that its callee is defined before calling it" \
	|| bad "record_expected_files calls expected_outputs unguarded; cleanup is trapped before that function exists, so an early death would write a file whose basis field is empty"

echo
if [ "$failures" = "0" ]; then
	say "CELL TIMING AND JUDGEMENT RECORDS PRODUCE ROWS: both outcomes, one header, stable columns under a bad timestamp, and every boundary including the ones that continued."
	say "NOT established by this check: that a real cell reaches these functions. The call sites are read as text here -- driving them needs a cell, and a cell needs a rented card. Nor does a recorded number mean the judgement it records was correct; it means the judgement can now be re-examined."
else
	echo "FAILED: $failures assertion(s) above." >&2
	exit 1
fi
