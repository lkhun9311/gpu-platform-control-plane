#!/usr/bin/env bash
# A WORDING REGRESSION CHECK for the two input-token units, plus two definitions the prose depends on.
#
# The name matters and the first version of this file overstated it. It said it "pins the unit a published
# prompt size is stated in", and a review on 2026-10-02 broke it with five sentences in under a minute:
#
#   The prefill grew 5.9x.
#   The premium prompt was **294 tokens**; the gateway build changed.
#   The contender prompt was 10645 tokens.
#   The premium prompt was 295 tokens.
#   The premium prompt was 294 input tokens.
#
# All five passed. The first carries the estimate's MULTIPLIER rather than its value; the second was exempted
# because the word "gateway" appeared anywhere on the line; the third uses the contender's estimate, which was
# never in the pattern; the fourth is off by one; the fifth puts a word between the number and "tokens".
# Three of those five are fixed below. "5.9x" and "295" are not, and cannot be by this method -- a grep over
# prose cannot know which numbers are estimates.
#
# So this check does ONE thing honestly: it stops the exact wordings that were already published and
# corrected from coming back. It is not a guard against the defect class, and the closing line says so.
# The structural fix -- generating published figures from a table tied to archive, tenant, field and
# aggregation -- is registered as an open issue rather than pretended here.
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

# The shapes the defect actually took, plus the three the review's bypasses showed were missing.
#
# "294 tokens" / "294-token" was the common one; "at 294" appeared with a latency attached ("69.5 ms at 50
# tokens and 174 ms at 294"), which carries no "tok" at all; and "294 against 50" appeared in a table
# caption. Added after the review: the contender's estimates (10,000 and 10,645), and an interposed word
# ("294 input tokens"), which the adjacency requirement missed.
#
# 68, 256, 7,695 and 8,192 are the engine's numbers and must NOT match -- they are what the fix uses.
#
# What is deliberately NOT here: "5.9x" and near-misses like "295". A multiplier derived from the estimate is
# not distinguishable from any other multiplier by pattern, and widening to bare numbers would flag every
# figure in the documents. That gap is the reason this file is named a regression check.
ESTIMATE_CITED='(\b(50|294|10,?000|10,?645)([ -]?[a-z]+)?[ -]?(tok|tokens)\b|\bat (50|294)\b|\b(50|294) (against|instead of)\b)'

# An estimator label anywhere on the same line exempts it.
#
# "gateway" was in this list and had to come out: "The premium prompt was **294 tokens**; the gateway build
# changed" was exempted by a word that says nothing about which estimator produced 294. What remains names
# the estimator itself -- the field, the formula, or the word "estimate".
ESTIMATE_LABEL='estInputTokens|ceil\(|estimate'

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
# The HARNESS computes the number that lands in the evidence, and checking only the gateway missed that.
#
# raw rows do not copy the gateway's score: internal/bench/replay.go:253 calls its own estimator, which is
# bench.EstInputTokensForChars. So the gateway formula could stay and the recorded estInputTokens still
# change, with this section green -- a review found it on 2026-10-02. Both are pinned now.
if grep -qE 'return \(promptLenChars \+ 3\) / 4' internal/bench/replay.go; then
  ok "internal/bench/replay.go still computes the same ceil(chars/4) for the recorded rows"
else
  bad "EstInputTokensForChars no longer computes (promptLenChars + 3) / 4, so the estimate in the evidence is not the one docs/12 describes"
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
# A COUNT, not a presence test, and the floor is the number that was there when this was written.
#
# "at least one matching line plus the amendment title" was the first version, and a review pointed out that
# it would pass with the original paragraphs almost entirely deleted. A drop below the floor is either a
# silent rewrite of a registration or a deliberate edit that has to come with a dated correction and a new
# floor here.
#
# The floor is MEASURED, not guessed: it was written as 6 from memory and the widened pattern actually
# matches 7 -- the contender's "10,000 tok" line. A floor one below the truth lets exactly one registration
# line disappear in silence, which is the hole this floor exists to close.
PRESERVED_FLOOR=7
preserved=$(grep -cE "$ESTIMATE_CITED" "$spec" || true)
if [ "$preserved" -ge "$PRESERVED_FLOOR" ]; then
  ok "$preserved preserved line(s) in the sharing pre-registration, at or above the floor of $PRESERVED_FLOOR"
else
  bad "the sharing pre-registration carries $preserved preserved estimate citation(s) against a floor of $PRESERVED_FLOOR -- registration text was removed without raising the floor"
fi
# The corrections have to still be there, not just their headings.
#
# Checking for the amendment title alone passed while its body could be gone. These three phrases are the
# load-bearing sentences of the two dated corrections: the unit rule, the withdrawal of the timeout as a
# rival explanation, and the arithmetic correction to the repetition spread.
for phrase in \
  'the unit a prompt size is published in' \
  'The timeout, which earlier' \
  'Corrected 2026-10-02'; do
  if grep -qF "$phrase" "$spec"; then
    ok "the dated correction still says ${phrase@Q}"
  else
    bad "$spec no longer contains ${phrase@Q}, so a correction's heading may be standing without its body"
  fi
done

echo
if [ "$failures" = "0" ]; then
  say "TOKEN UNIT WORDINGS PINNED: the corrected phrasings have not come back, both estimator definitions still compute ceil(chars/4), and the pre-registrations keep their preserved lines and their dated corrections."
  say "NOT established by this check: that every published prompt size is in the engine's unit. A multiplier such as \"5.9x\", or a near-miss such as \"295 tokens\", passes -- see the header. The structural fix is an open issue."
else
  echo "FAILED: $failures assertion(s) above." >&2
  exit 1
fi
