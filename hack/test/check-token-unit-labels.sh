#!/usr/bin/env bash
# Pins the UNIT a published prompt size is stated in: the engine's own count, with the gateway's estimate
# labelled wherever it appears.
#
# WHY THIS EXISTS
#
# Every raw row of every paid run carries TWO input-token numbers, and they disagree:
#
#   engineInputTokens   what the engine itself reported for that request  (internal/bench/replay.go)
#   estInputTokens      ceil(chars/4), the score the gateway admits on    (internal/gateway/proxy.go)
#
# The published documents compared two runs' loads using the SECOND one. The ninth pilot's premium prompt
# was quoted as "50 tokens" and the 2026-10-02 run's as "294", so the prefill increase read as 5.9x. The
# engine reported 68 and 256 on those same rows, which is 3.8x. `internal/gateway/proxy.go` calls its own
# number "never an exact count", and it exists to be compared against an admission threshold -- not to
# describe how much prefill a request carries. So a claim about prefill work stated in that unit overstates
# the load change by 1.56x, in the one paragraph the README introduces as "stated because it moves the
# number".
#
# Both numbers are legitimate and neither is deleted. What the repository got wrong was writing one of them
# as though it were the other. This check does not choose the unit; it refuses an UNLABELLED estimate in a
# publication.
#
# WHAT IT CANNOT DO
#
# It cannot tell whether the unit a sentence chose is the right one for the claim that sentence makes. A line
# saying "the premium prompt was 294 tokens (the gateway's ceil(chars/4) estimate)" passes here and is still
# the wrong unit for a prefill argument. That judgement is in the 2026-10-02 amendment to
# docs/superpowers/specs/2026-09-10-does-splitting-the-card-buy-protection.md, not in a grep.
#
# It also says nothing about the pre-registrations under docs/superpowers/specs/. Those are deliberately
# NOT scanned -- see section 3, which asserts that exclusion rather than leaving it to be noticed.
set -euo pipefail

cd "$(dirname "$0")/../.."

failures=0
say() { echo "== $*"; }
ok()  { echo "   ok: $*"; }
bad() { echo "   FAIL: $*" >&2; failures=$(( failures + 1 )); }

# The three shapes the defect actually took, rather than every shape it could take.
#
# "294 tokens" / "294-token" was the common one; "at 294" appeared with a latency attached ("69.5 ms at 50
# tokens and 174 ms at 294"), which carries no "tok" at all; and "294 against 50" appeared in a table
# caption. 68 and 256 are the engine's numbers and must NOT match -- they are what the fix uses.
ESTIMATE_CITED='(\b(50|294)[ -]?(tok|tokens)\b|\bat (50|294)\b|\b(50|294) (against|instead of)\b)'

# An estimator label anywhere on the same line exempts it. `estInputTokens` and `ceil(` are the precise
# forms; "estimate" and "gateway" catch the prose ones.
ESTIMATE_LABEL='estInputTokens|ceil\(|estimate|gateway'

# offenders ROOT -- prints "path:lineno:text" for each publication line citing an estimate without a label.
#
# It takes a root so the self-test can run the SAME function over a synthetic tree. Checking the regex
# against a string would prove nothing about the file walk, the label exemption or the exclusion of
# docs/superpowers/, all of which are downstream of it.
offenders() {
  local root="$1" f hits
  for f in "$root"/README.md "$root"/docs/*.md; do
    [ -f "$f" ] || continue
    # `grep` exits 1 when a file has no match and pipefail would abort the whole script on that -- which is
    # the HEALTHY case here. Both greps get `|| true` for exactly that reason.
    hits=$(grep -nE "$ESTIMATE_CITED" "$f" 2>/dev/null | grep -vE "$ESTIMATE_LABEL" || true)
    [ -z "$hits" ] || printf '%s\n' "$hits" | sed "s|^|$f:|"
  done
}

# --- 0. the detector can fail -----------------------------------------------------------------------------
#
# A synthetic publication tree with one violating line and one labelled line. If the walk, the exemption or
# the counting breaks, this section goes red before any real finding is reported.
say "0. the scanner reports an unlabelled estimate and spares a labelled one"
SELF="$(mktemp -d)"
trap 'rm -rf "$SELF"' EXIT
mkdir -p "$SELF/docs" "$SELF/docs/superpowers/specs"
cat > "$SELF/README.md" <<'EOF'
The premium prompt was 294 tokens instead of 50.
EOF
cat > "$SELF/docs/99_LABELLED.md" <<'EOF'
The gateway's estInputTokens score was 294 tokens against 50.
The harness estimate, ceil(chars/4), gives 50 and 294.
EOF
cat > "$SELF/docs/superpowers/specs/2026-01-01-registration.md" <<'EOF'
It offered a 294-token premium prompt against the pilot's 50.
EOF
found=$(offenders "$SELF" || true)
n=$(printf '%s' "$found" | grep -c . || true)
if [ "$n" = 1 ] && printf '%s' "$found" | grep -q 'README.md'; then
  ok "one finding, and it is the unlabelled README line"
else
  bad "self-test expected exactly 1 finding in README.md, got $n: $(printf '%s' "$found" | tr '\n' ' ')"
fi
if printf '%s' "$found" | grep -q '99_LABELLED'; then
  bad "a labelled line was reported; the exemption does not work"
else
  ok "a line naming the estimator is not reported"
fi
if printf '%s' "$found" | grep -q 'superpowers'; then
  bad "a pre-registration was scanned; section 3's exclusion is not real"
else
  ok "docs/superpowers/specs/ is outside the walk"
fi

# --- 1. no publication cites the estimate without naming it -----------------------------------------------
say "1. the published documents state prompt sizes in the engine's own count"
real=$(offenders "." || true)
if [ -z "$real" ]; then
  ok "no unlabelled estimate in README.md or docs/*.md"
else
  bad "$(printf '%s' "$real" | grep -c . || true) line(s) cite the gateway's estimate as a token count:"
  printf '%s\n' "$real" | sed 's/^/        /' >&2
fi

# --- 2. the two numbers still are what the documents say they are -----------------------------------------
#
# docs/12_EVIDENCE_CHECKSUMS.md explains the disagreement by citing these two lines. If either definition
# moves, that explanation becomes false with every document still reading as correct.
say "2. the code the explanation cites still defines both numbers that way"
if grep -qE 'meta\.EstInputTokens = \(totalChars \+ 3\) / 4' internal/gateway/proxy.go; then
  ok "internal/gateway/proxy.go still computes ceil(chars/4)"
else
  bad "proxy.go no longer computes (totalChars + 3) / 4; docs/12's explanation of estInputTokens is stale"
fi
if grep -qE 'EngineInputTokens:[[:space:]]*res\.PromptTokens' internal/bench/replay.go; then
  ok "internal/bench/replay.go still records what the engine reported"
else
  bad "replay.go no longer assigns res.PromptTokens; 'the engine's own count' is no longer sourced"
fi

# --- 3. the pre-registrations are excluded on purpose, and that is asserted --------------------------------
#
# docs/superpowers/specs/ holds pre-registrations and dated corrections whose wrong text is preserved
# deliberately: "a registration repaired after the fact is worse than one that is wrong in public". Four
# such lines quote 294 against 50 and must stay. Widening this check to cover them would make the gate
# demand exactly the silent rewrite the registrations forbid -- so the exclusion is pinned here, with its
# reason, rather than living in a glob nobody reads.
say "3. the pre-registrations keep their original wording"
spec=docs/superpowers/specs/2026-09-10-does-splitting-the-card-buy-protection.md
preserved=$(grep -cE "$ESTIMATE_CITED" "$spec" || true)
if [ "$preserved" -ge 1 ]; then
  ok "$preserved preserved line(s) in the sharing pre-registration are untouched by this check"
else
  bad "no preserved estimate citation found in $spec -- it may have been silently rewritten"
fi
if grep -q 'the unit a prompt size is published in' "$spec"; then
  ok "the sharing pre-registration carries the dated amendment that fixes the unit"
else
  bad "$spec has no amendment fixing the unit; the preserved lines then have nothing correcting them"
fi

echo
if [ "$failures" = "0" ]; then
  say "TOKEN UNIT LABELS PINNED: publications state the engine's count, the estimate is labelled where it appears, both definitions still hold, and the pre-registrations keep their wording."
else
  echo "FAILED: $failures assertion(s) above." >&2
  exit 1
fi
