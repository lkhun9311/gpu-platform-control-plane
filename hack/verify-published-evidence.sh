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
ANALYSIS_COMMIT="${ANALYSIS_COMMIT:-e203db7}"
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
	if [ -z "$head" ]; then
		bad "this tree has no git HEAD, so the analysis version cannot be established"
	elif [ "$head" != "$ANALYSIS_COMMIT" ]; then
		bad "the analysis is $head and the published figures were produced by $ANALYSIS_COMMIT; check out that commit, or pass ANALYSIS_COMMIT=$head to say you intend a different scorer"
	else
		good "the analysis commit is the published $ANALYSIS_COMMIT"
	fi
	if [ "$dirty" -ne 0 ]; then
		bad "$dirty uncommitted change(s) under cmd/ or internal/; the scorer being run is not $ANALYSIS_COMMIT"
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
chain=0
missing_field=0
for m in "$DIR"/manifest-*.yaml; do
	[ -f "$m" ] || continue
	chain=$((chain + 1))
	for k in "${keys[@]}"; do
		grep -q "$k" "$m" || {
			bad "$(basename "$m") carries no $k"
			missing_field=$((missing_field + 1))
		}
	done
	tc=$(grep -m1 'traceChecksum' "$m" | tr -d ' "' | cut -d: -f2)
	if [ -n "$tc" ] && ! grep -q "$tc" "$DIR"/raw-*.jsonl 2>/dev/null; then
		bad "$(basename "$m")'s traceChecksum $tc appears in no raw row"
	fi
done
if [ "$chain" -eq 0 ]; then
	bad "$DIR has no manifest-*.yaml, so provenance cannot be checked"
elif [ "$missing_field" -eq 0 ]; then
	good "$chain manifests name ${keys[*]}, and each traceChecksum appears in the rows"
fi

printf '\n'
if [ "$fail" -eq 0 ]; then
	echo "VERIFIED: the published figures were reproduced from the published rows."
	exit 0
fi
echo "NOT VERIFIED: see the FAIL lines above." >&2
exit 1
