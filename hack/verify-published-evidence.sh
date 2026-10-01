#!/usr/bin/env bash
#
# Reproduces the published figures from the published evidence, and exits 0 only when every one of them
# matches.
#
# WHY A WRAPPER AND NOT JUST A DOCUMENTED COMMAND
#
# `benchharness report` on the ten-cell evidence exits **1** by design: reading 4d is a gate, that run
# declares one `sharingMode`, so there is no sharing candidate and the harness refuses to print a verdict
# rather than reporting an empty outcome space as a finding. A reader or a CI job that treats the exit code
# as the answer will record a correct reproduction as a failure.
#
# The opposite shortcut is worse. A wrapper that maps every exit 1 to success would also swallow a missing
# file, an unreadable row, a flag typo and a binary too old to carry the 4d gate. That last one is not
# hypothetical: a `benchharness` built before 2026-10-01 prints "none of the readings fired. That is not a
# result; it is a gap in the outcome space" and exits **0** on this same evidence -- the withdrawn wording and
# the withdrawn exit status together. A check that accepted exit 0 would accept it.
#
# So this script requires the refusal to be the EXPECTED refusal, named by its reading id and its sentence,
# and it requires every published number to appear. Nothing else counts as a pass.
#
# WHAT IT CANNOT DO
#
# It recomputes an analysis from rows that were collected once. It does not re-run the experiment, does not
# touch a GPU, and cannot tell you the rows describe what the manifests say they describe -- that is what the
# checksums and the manifests' own corpus and tokenizer digests are for, and this script verifies those too
# rather than assuming them.
set -uo pipefail

usage() {
	cat >&2 <<'USAGE'
usage: verify-published-evidence.sh <unpacked-evidence-dir> [--sums <file>]

  <unpacked-evidence-dir>  a directory unpacked from one of the published archives
  --sums <file>            the matching SHA256SUMS (default: <dir>/../<dir basename>.SHA256SUMS,
                           then <dir>/SHA256SUMS)

Exits 0 only when the input checksums match, the analysis binary is the pinned one, every published figure is
reproduced, and the run's expected refusal is the one that fires.
USAGE
	exit 2
}

[ $# -ge 1 ] || usage
DIR=""
SUMS=""
while [ $# -gt 0 ]; do
	case "$1" in
	--sums)
		[ $# -ge 2 ] || usage
		SUMS="$2"
		shift 2
		;;
	-h | --help) usage ;;
	-*) usage ;;
	*)
		[ -z "$DIR" ] || usage
		DIR="$1"
		shift
		;;
	esac
done
[ -n "$DIR" ] || usage
[ -d "$DIR" ] || {
	echo "verify: $DIR is not a directory" >&2
	exit 2
}

ROOT=$(cd "$(dirname "$0")/.." && pwd)
base=$(basename "$DIR")
if [ -z "$SUMS" ]; then
	for c in "$DIR/../$base.SHA256SUMS" "$DIR/SHA256SUMS"; do
		[ -f "$c" ] && {
			SUMS="$c"
			break
		}
	done
fi

fail=0
# Declared here because the provenance section reads it to decide which manifest fields this evidence is
# contracted to carry; the recomputation section sets it.
expect_refusal=""
step() { printf '\n== %s\n' "$1"; }
bad() {
	printf 'FAIL: %s\n' "$1" >&2
	fail=1
}
good() { printf 'ok   %s\n' "$1"; }

# 1. The inputs are the published bytes.
#
# Checked first and checked by file, because every later assertion is about numbers derived from these rows.
# A list that cannot be found is a failure rather than a skip: "I did not verify the inputs" and "the inputs
# verified" must not print the same thing.
step "inputs"
if [ -z "$SUMS" ] || [ ! -f "$SUMS" ]; then
	bad "no SHA256SUMS found for $base; pass --sums <file>"
else
	SUMS=$(cd "$(dirname "$SUMS")" && pwd)/$(basename "$SUMS")
	n_want=$(grep -c . "$SUMS")
	n_ok=$( (cd "$DIR" && sha256sum -c "$SUMS" 2>/dev/null) | grep -c ': OK$' || true)
	if [ "$n_ok" -eq "$n_want" ] && [ "$n_want" -gt 0 ]; then
		good "$n_ok/$n_want files match $(basename "$SUMS")"
	else
		bad "$n_ok of $n_want files match $(basename "$SUMS")"
		(cd "$DIR" && sha256sum -c "$SUMS" 2>&1 | grep -v ': OK$' | head -8) >&2
	fi
fi

# 2. The analysis code is the pinned one.
#
# The figures are a property of the rows AND of the scorer. A reader holding an older build gets a different
# verdict from the same rows, so the version is part of the claim rather than a detail of the environment.
# ⚠️ This section said "the analysis code is the pinned one" and pinned nothing: it built whatever the
# working tree held and PRINTED the HEAD it found. A reader on a different commit, or with uncommitted
# edits, got a VERIFIED that described their tree rather than the published figures. The expected commit is
# now compared, and a dirty tree is named, because "I built something" and "I built the analysis these
# numbers came from" are different claims.
# The COLLECTION commit comes from the archive, not from a literal in this file.
#
# ⚠️ The first version of this check hard-coded the then-current HEAD as "the published analysis". That is
# wrong twice over: the next commit to this repository made the check fail on evidence nothing had touched,
# and a constant in the checker cannot be evidence about the archive. The archive's own `commit.txt` is the
# fact -- it records the tree the RUN was bought from. A reader who wants to re-score with a different
# analysis passes ANALYSIS_COMMIT and the output says so.
#
# Distinguish three states rather than two: pinned and matching, pinned and differing, and not pinnable
# because the archive carries no commit.txt (the ninth pilot does not). The third is a scope statement, not
# a failure -- a checker that fails an older archive for being older is asserting a contract that did not
# exist, which this script already got wrong once with tokenizerRev.
step "analysis code"
if [ -d "$ROOT/cmd/benchharness" ]; then
	BIN=$(mktemp -d)/benchharness
	head=$(cd "$ROOT" && git rev-parse --short HEAD 2>/dev/null || echo "")
	dirty=$(cd "$ROOT" && git status --porcelain -- cmd internal 2>/dev/null | wc -l)
	if (cd "$ROOT" && go build -o "$BIN" ./cmd/benchharness) 2>/dev/null; then
		good "built from ${head:-an unversioned tree}"
	else
		bad "could not build ./cmd/benchharness from $ROOT"
		BIN=""
	fi
	collected=""
	[ -f "$DIR/commit.txt" ] && collected=$(cut -c1-7 "$DIR/commit.txt" 2>/dev/null)
	want="${ANALYSIS_COMMIT:-}"
	if [ -z "$head" ]; then
		bad "this tree has no git HEAD, so the analysis version cannot be established"
	elif [ -n "$want" ]; then
		if [ "$head" = "${want:0:7}" ]; then
			good "the analysis is $head, the version you asked for"
		else
			bad "the analysis is $head and you asked for $want"
		fi
	elif [ -n "$collected" ]; then
		if [ "$head" = "$collected" ]; then
			good "the analysis is $head, the same tree this evidence was collected from"
		else
			echo "ok   the analysis is $head; the evidence was COLLECTED at $collected"
			echo "     (re-scoring collected evidence with a later analysis is the normal case -- reading 4d,"
			echo "      for one, postdates both runs. Pass ANALYSIS_COMMIT to require a specific scorer.)"
		fi
	else
		echo "ok   the analysis is $head"
		echo "     (this archive carries no commit.txt, so the collection tree cannot be named from it)"
	fi
	if [ "$dirty" -ne 0 ]; then
		bad "$dirty uncommitted change(s) under cmd/ or internal/, so the scorer being run is not any committed version"
	fi
else
	bad "run this from a clone of the repository; $ROOT has no cmd/benchharness"
	BIN=""
fi

# 3. The report reproduces every published figure, and refuses for the registered reason.
step "recomputation"
if [ -n "${BIN:-}" ] && [ -x "$BIN" ]; then
	raws=()
	for f in "$DIR"/raw-*.jsonl; do [ -f "$f" ] && raws+=(--raw "$f"); done
	if [ ${#raws[@]} -eq 0 ]; then
		bad "$DIR has no raw-*.jsonl"
	else
		out=$("$BIN" report "${raws[@]}" 2>&1)
		rc=$?

		# The arms present decide which figures are expected. A ten-cell R1/shared pair publishes the
		# registered estimand; the ninth pilot's three arms publish the 27.2x and 14.5x table instead, and
		# asserting the ten-cell numbers against it would fail for the wrong reason.
		if printf '%s\n' "$out" | grep -q '^shared ' && printf '%s\n' "$out" | grep -q '^R1 ' &&
			! printf '%s\n' "$out" | grep -q '^timeSlicing '; then
			want=(
				"174.078" "173.832" "174.297" "174.387" "174.034"
				"3996.117" "4000.349" "4000.510" "3998.338" "3997.887"
				"median 174.078" "median 3998.338"
				"baselineP99Ms  174" "colocatedP99Ms 3998" "interferenceRatio 22.977"
				"No interval is published"
			)
			expect_rc=1
			expect_refusal='4d'
			expect_answer='none of the readings COULD fire'
		else
			# The ninth pilot's figures are bound to their ARMS, and the ANSWER is asserted.
			#
			# This asked for "69.5", "1892" and "1007" anywhere in the output and exit 0. An external review
			# built a counter-example from the real judgment block: an output whose answer was reading 1
			# instead of 5 passed. Three numbers appearing somewhere is not the published table -- the table
			# says WHICH arm each belongs to and which reading fired.
			want=(
				"R1 " "shared " "timeSlicing "
				"69.5" "1892" "1007"
				"ANSWER: 5"
			)
			expect_rc=0
			expect_refusal=''
			expect_answer='ANSWER: 5'
		fi

		missing=0
		for w in "${want[@]}"; do
			printf '%s\n' "$out" | grep -qF "$w" || {
				bad "the report does not contain $w"
				missing=$((missing + 1))
			}
		done
		[ "$missing" -eq 0 ] && good "${#want[@]} published figures reproduced"

		# The exit status is an assertion, in both directions.
		if [ "$rc" -ne "$expect_rc" ]; then
			bad "report exited $rc, expected $expect_rc for this evidence"
			if [ "$expect_rc" = "1" ] && [ "$rc" = "0" ]; then
				echo "      exit 0 here means the 4d gate did not fire -- an analysis build older than" >&2
				echo "      2026-10-01 does that, and its ANSWER line is one this project withdrew." >&2
			fi
		else
			good "report exited $rc, as this evidence requires"
		fi

		# And the refusal has to be the registered one, named by id.
		# BOTH the reading id and the sentence, not either.
		#
		# This was `||`, while the comment above it said the refusal is "named by its reading id". An output
		# carrying the sentence and no 4d line passed -- which is exactly the evidence shape a scorer built
		# before the gate existed produces.
		if [ -n "$expect_refusal" ]; then
			if printf '%s\n' "$out" | grep -qE "^[[:space:]]*\[[^]]*\][[:space:]]+${expect_refusal}\b"; then
				good "reading $expect_refusal is present by id"
			else
				bad "no reading line names $expect_refusal; the refusal is not the registered one"
				printf '%s\n' "$out" | grep -E 'ANSWER|^[[:space:]]*\[' | head -8 >&2
			fi
		fi
		# The ANSWER line is asserted for every run shape, because it is the one line a reader quotes.
		if [ -n "${expect_answer:-}" ]; then
			if printf '%s\n' "$out" | grep -qF "$expect_answer"; then
				good "the answer is \"$expect_answer\", as published"
			else
				bad "the answer is not \"$expect_answer\"; a different reading fired or none did"
				printf '%s\n' "$out" | grep -E 'ANSWER' | head -4 >&2
			fi
		fi
	fi
fi

# 4. The inner chain, so a reader does not have to take the provenance on trust either.
step "provenance chain"
# tokenizerRev is required of the ten-cell evidence and NOT of the ninth pilot, because the ninth pilot
# predates it: the ten-cell run carried "the first paid manifest ever to name a tokenizer". Demanding the
# field of both would report the older run as defective for being older, which is a checker asserting a
# contract its own repository says did not exist yet.
keys=(promptCorpusSHA traceChecksum study)
[ "$expect_refusal" = "4d" ] && keys+=(tokenizerRev)

# Counted BEFORE the field loop, so "this manifest is missing a field" and "there are no manifests" stay
# different sentences. The first version counted after it and used `continue 2`, which skipped the increment
# on any manifest that failed a field -- so six failures printed, and then the script said there were no
# manifests at all.
# ⚠️ This section checked that a field NAME was present and that a checksum appeared in SOME raw file.
# Both were weaker than the sentence this script prints. A field with an empty value passed, and
# manifest-shared-3's checksum satisfied the check by appearing in raw-R1-1. An external review named the
# overclaim: a VERIFIED read as "provenance is bound" was not earned.
#
# What is bound now, and why each is checkable from the archive alone:
#   1. the manifest's traceChecksum IS the sha256 of the trace file of the SAME label -- measured: the
#      value is the file digest with no normalisation (stripping newlines gives a different hash), so this
#      is a direct comparison rather than a convention being trusted;
#   2. every raw row of a label carries its own manifest's checksum, not merely one that exists somewhere;
#   3. an arm's repetitions all name ONE trace, because `shared` replays one trace five times -- two
#      checksums under one arm means a repetition came from somewhere else;
#   4. promptCorpusSHA, tokenizerRev and study agree across the whole archive by VALUE.
#
# What is still not bound, stated here so the output cannot be read as more: the corpus itself is not in
# the archive, so (4) establishes internal consistency and not that the corpus is the one the registration
# names. That is what docs/12's committed digests are for.
chain=0
problems=0
traced=0
untraced=0
declare -A arm_trace=()
declare -A field_value=()
for m in "$DIR"/manifest-*.yaml; do
	[ -f "$m" ] || continue
	chain=$((chain + 1))
	label=$(basename "$m" .yaml); label=${label#manifest-}
	arm=${label%-*}

	for k in "${keys[@]}"; do
		v=$(grep -m1 "^${k}:" "$m" | tr -d ' "' | cut -d: -f2-)
		if [ -z "$v" ]; then
			bad "$(basename "$m") has no value for $k (the field name alone is not provenance)"
			problems=$((problems + 1))
			continue
		fi
		# promptCorpusSHA, tokenizerRev and study must agree across the archive.
		if [ "$k" != "traceChecksum" ]; then
			prev=${field_value[$k]:-}
			if [ -z "$prev" ]; then
				field_value[$k]=$v
			elif [ "$prev" != "$v" ]; then
				bad "$k disagrees across the archive: $prev and $v. One run cannot have two corpora or two tokenizers"
				problems=$((problems + 1))
			fi
		fi
	done

	tc=${field_value[skip]:-}
	tc=$(grep -m1 '^traceChecksum:' "$m" | tr -d ' "' | cut -d: -f2-)
	[ -n "$tc" ] || continue

	# 1. the checksum is this label's trace file.
	t="$DIR/trace-$label.jsonl"
	if [ -f "$t" ]; then
		got=$(sha256sum "$t" | cut -d' ' -f1)
		if [ "$got" != "$tc" ]; then
			bad "trace-$label.jsonl hashes to $got and its manifest names $tc; the rows were replayed from a different trace than the manifest records"
			problems=$((problems + 1))
		else
			traced=$((traced + 1))
		fi
	else
		# Not a failure. The ninth pilot archived evidence.log, manifests and raw rows and no traces, so
		# demanding one would report that run as defective for predating the practice -- the mistake this
		# script already made once by requiring tokenizerRev of it. The count is reported instead, so a
		# reader can see how much of the chain was actually closed.
		untraced=$((untraced + 1))
	fi

	# 2. this label's OWN raw rows carry it.
	r="$DIR/raw-$label.jsonl"
	if [ -f "$r" ]; then
		if ! grep -q "$tc" "$r"; then
			bad "raw-$label.jsonl carries no row naming $tc, so these rows are not the ones that manifest describes"
			problems=$((problems + 1))
		fi
	else
		bad "$(basename "$m") has no raw-$label.jsonl beside it"
		problems=$((problems + 1))
	fi

	# 3. one trace per arm.
	prev=${arm_trace[$arm]:-}
	if [ -z "$prev" ]; then
		arm_trace[$arm]=$tc
	elif [ "$prev" != "$tc" ]; then
		bad "arm $arm names two traces ($prev and $tc); its repetitions did not replay identical traffic"
		problems=$((problems + 1))
	fi
done
if [ "$chain" -eq 0 ]; then
	bad "$DIR has no manifest-*.yaml, so provenance cannot be checked"
elif [ "$problems" -eq 0 ]; then
	good "$chain manifests: each label's rows carry its checksum, one trace per arm, ${#field_value[@]} identifier(s) agree archive-wide"
	if [ "$traced" -gt 0 ]; then
		good "$traced of $chain traceChecksums ARE the digest of their own trace file"
	fi
	if [ "$untraced" -gt 0 ]; then
		echo "ok   $untraced manifest(s) name a trace this archive does not carry"
		echo "     (their checksum is bound to the rows but not to a trace file, because this run archived none)"
	fi
	echo "     (the corpus itself is not in the archive, so the identifier agreement is internal consistency)"
fi

printf '\n'
if [ "$fail" -eq 0 ]; then
	echo "VERIFIED: the published figures were reproduced from the published rows."
	exit 0
fi
echo "NOT VERIFIED: see the FAIL lines above." >&2
exit 1
