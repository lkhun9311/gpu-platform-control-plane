#!/usr/bin/env bash
#
# Resolves a declared input-token count into the character length that produces exactly that many tokens.
#
# WHY THIS EXISTS
#
# GpuSharingBenchmark declares prompt lengths in TOKENS. The trace generator is configured in CHARACTERS.
# `ceil(chars/4)` relates them badly and is not invertible: this repository's own calibration measures it at
# 50 estimated against 68 measured on a 200-character prompt, and 10,000 against 7,695 on a 40,000-character
# one. So the conversion cannot be computed. It has to be MEASURED, once, and recorded.
#
# An external review named the procedure: generate candidates with the real corpus, tokenize the complete
# templated request, and accept only a candidate whose count EQUALS the declaration. This is that procedure.
#
# WHY THE TOKENIZER IS NOT A SECOND COPY OF A DECISION
#
# cmd/benchharness/exacttokens.go refuses to vendor a tokenizer, on the grounds that "a tokenizer vendored
# here would be a second copy of a decision that lives in the served model". That objection is sound and does
# not apply: this script tokenizes INSIDE THE SERVING IMAGE ITSELF, pinned by digest, and that image carries
# transformers 5.15.0 and tokenizers 0.22.2 -- the same versions as the CPU image the calibration was taken
# with, measured rather than assumed. It is the same implementation, not a copy of it.
#
# No weights are downloaded. Tokenizing needs the tokenizer files and the chat template; 3.7 GB of
# safetensors would add nothing. The tokenizer files are byte-identical across Qwen2.5 0.5B, 3B and 7B, which
# was also measured.
#
# WHY THE SEARCH IS LINEAR AND NOT BINARY
#
# The token count is NOT monotone in the character count. Measured over 100..400 characters it DECREASES 29
# times and repeats 189 times, because byte-pair merges differ at the boundary. A binary search would step
# over answers that exist. So an affine fit narrows the window and the window is then swept exhaustively.
#
# Several character lengths give the same token count -- 8 of them for 256 tokens in a 301-wide window. The
# registered rule is to take the SMALLEST, which is the fewest bytes on the wire for the declared count.
#
# WHAT THIS DOES NOT ESTABLISH
#
# That the engine will agree. The engine is the authority on its own count, and `stamp-exact-tokens` asks it
# at run time; this resolves a length BEFORE a card is rented, which is a different and earlier question.
# If the two disagree, the engine is right and the table is stale -- and the run must refuse rather than
# report, which is what the recorded provenance is for.
set -euo pipefail

cd "$(dirname "$0")/.." || exit 1
ROOT=$(pwd)

# The serving image, by digest, and the tokenizer revision it serves. Both are recorded in the table so a
# later reader can tell what produced these numbers, and so a change to either invalidates it loudly.
SERVING_IMAGE="${SERVING_IMAGE:-vllm/vllm-openai@sha256:0a51ea5b4ae2dc5d81890e5173f54203d2a3ae0cfffe51b8fd2afd4391bfd967}"
MODEL="${MODEL:-Qwen/Qwen2.5-3B-Instruct}"
MODEL_REVISION="${MODEL_REVISION:-aa8e72537993ba99e69dfaafa59ed015b17504d1}"
# Half-width of the sweep, in characters, either side of the affine estimate.
#
# 150 was enough for both sample values with room to spare: the matches for 256 tokens landed 117 characters
# above the estimate and the ones for 8192 landed 108 above. A window that finds nothing is reported as
# unreachable AT THIS WINDOW rather than as unreachable, because those are different claims.
WINDOW="${WINDOW:-150}"
OUT="${OUT:-hack/input-length-resolution.json}"
# Optional: write every measured (characters, tokens) pair, not only the matches.
#
# The resolution table answers "which length gives this count". The series answers "what does the curve look
# like", which is what shows the non-monotonicity -- and a figure drawn from a one-off command is a figure
# nobody can redraw. Off by default because the table is the product and the series is evidence for a claim
# about it.
SERIES_OUT="${SERIES_OUT:-}"

# The affine fit to the three committed calibration points, used ONLY to place the window.
#
# predictedTokens = 30.3034727 + 0.1916281914 * chars, residuals under 1.1 tokens at all three points. It is
# a search initializer and never an answer: acceptance is the exact measured count.
FIT_A="30.3034727"
FIT_B="0.1916281914"

say()  { printf '== %s\n' "$*"; }
fail() { printf 'resolve-input-lengths: %s\n' "$*" >&2; exit 1; }

[ "$#" -gt 0 ] || fail "usage: $0 <tokens> [<tokens> ...]
Each argument is a declared inputTokens value from a GpuSharingBenchmark spec."

for t in "$@"; do
  case "$t" in
    ''|*[!0-9]*) fail "token target ${t@Q} is not a positive integer" ;;
  esac
  [ "$t" -gt 0 ] || fail "token target $t is not positive"
done

command -v docker >/dev/null || fail "docker is not installed; this tokenizes inside the serving image"
command -v curl >/dev/null || fail "curl is not installed; the tokenizer files are fetched from the registry"
command -v go >/dev/null || fail "go is not installed; the prompts come from the real corpus via benchharness"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

say "build benchharness (the corpus and its tiling live in Go and are not reimplemented here)"
go build -o "$WORK/bh" ./cmd/benchharness || fail "build benchharness"

say "fetch the tokenizer files at revision ${MODEL_REVISION:0:12} (no weights)"
mkdir -p "$WORK/tok"
for f in tokenizer.json tokenizer_config.json vocab.json merges.txt; do
  curl -fsSL --max-time 120 -o "$WORK/tok/$f" \
    "https://huggingface.co/$MODEL/resolve/$MODEL_REVISION/$f" \
    || fail "fetch $f at $MODEL_REVISION"
done
# The identity of what was just fetched, computed here rather than trusted from the calibration file.
#
# Two values for one name is how a number stops being checkable, and that happened once already in this
# work: a shell pipeline and a Python helper combined the same four hashes differently and disagreed. The
# rule is written out in tokenizer_calibration.json and reproduced here, so the table can carry a value a
# reader can recompute.
COMBINED="$(cd "$WORK/tok" && for f in merges.txt tokenizer.json tokenizer_config.json vocab.json; do
  printf '%s  %s\n' "$(sha256sum "$f" | cut -d' ' -f1)" "$f"
done | sha256sum | cut -d' ' -f1)"
say "  tokenizer core files combined sha256 ${COMBINED:0:16}"

# The corpus hash, from the binary that owns the corpus.
#
# Every token count below depends on the corpus bytes. The table's own first comment said the corpus was
# recorded and it was not, so changing promptCorpus would have left both copies of the table agreeing with
# each other and disagreeing with what the sender emits. An external review found that.
CORPUS_SHA="$("$WORK/bh" print-prompt --corpus-sha)" || fail "read the prompt corpus sha from benchharness"
case "$CORPUS_SHA" in
  [0-9a-f]*) ;;
  *) fail "benchharness printed ${CORPUS_SHA@Q} for the corpus sha, which is not a hex digest" ;;
esac
say "  prompt corpus sha256 ${CORPUS_SHA:0:16}"

say "generate the candidate prompts with the real corpus"
mkdir -p "$WORK/p"
windows=""
for t in "$@"; do
  c0=$(python3 -c "print(int(($t - $FIT_A) / $FIT_B))")
  lo=$(( c0 - WINDOW )); [ "$lo" -lt 1 ] && lo=1
  hi=$(( c0 + WINDOW ))
  mkdir -p "$WORK/p/$t"
  for n in $(seq "$lo" "$hi"); do
    "$WORK/bh" print-prompt --chars "$n" > "$WORK/p/$t/$n.txt" || fail "print-prompt --chars $n"
    # print-prompt emits exactly n bytes with no trailing newline, measured. If that changes, every count
    # below shifts by however many bytes were added, so it is checked rather than assumed.
    got=$(wc -c < "$WORK/p/$t/$n.txt")
    [ "$got" -eq "$n" ] || fail "print-prompt --chars $n produced $got bytes; the prompt is no longer exactly n characters and every count here would be measuring a different string"
  done
  windows="$windows $t:$lo:$hi"
  say "  $t tokens: window $lo..$hi ($(( hi - lo + 1 )) candidates)"
done

say "tokenize inside $SERVING_IMAGE"
printf '%s\n' "$windows" | tr ' ' '\n' | grep . > "$WORK/windows.txt"
docker run --rm \
  -v "$WORK/p:/p:ro" -v "$WORK/tok:/tok:ro" -v "$WORK/windows.txt:/windows.txt:ro" \
  --entrypoint python3 "$SERVING_IMAGE" -c '
import json, os, sys
from transformers import AutoTokenizer

t = AutoTokenizer.from_pretrained("/tok")
if not getattr(t, "chat_template", None):
    sys.exit("the tokenizer loaded without a chat template; the count would be of the bare prompt and not of the request the sender builds")

results = {}
for line in open("/windows.txt"):
    target, lo, hi = (int(x) for x in line.strip().split(":"))
    counts, hits, dec, flat, prev = {}, [], 0, 0, None
    for n in range(lo, hi + 1):
        text = open(f"/p/{target}/{n}.txt", "rb").read().decode("utf-8")
        if len(text) != n:
            sys.exit(f"candidate {n} decoded to {len(text)} characters; the corpus is ASCII and this must not happen")
        # The same single user message the sender builds, with the same generation prompt.
        ids = t.apply_chat_template(
            [{"role": "user", "content": text}], tokenize=True, add_generation_prompt=True)["input_ids"]
        c = len(ids)
        counts[n] = c
        if prev is not None:
            if c < prev: dec += 1
            if c == prev: flat += 1
        prev = c
        if c == target:
            hits.append(n)
    results[target] = {
        "series": [[n, counts[n]] for n in sorted(counts)],
        "chars": min(hits) if hits else None,
        "matches": len(hits),
        "allMatches": hits,
        "window": [lo, hi],
        "decreasesInWindow": dec,
        "repeatsInWindow": flat,
    }
# Printed, not written. /p is mounted read-only on purpose: the container needs to read candidates and
# nothing else, and an earlier version wrote its results there and would have failed on the mount -- a
# failure that reads as "tokenizing did not work".
print("RESULTS_JSON_BEGIN")
print(json.dumps(results, indent=2))
' > "$WORK/tok.out" 2>&1 || { sed 's/^/    /' "$WORK/tok.out" >&2; fail "tokenizing failed inside the serving image"; }
sed -n '1,200p' "$WORK/tok.out" | sed 's/^/    /'

# The results are carved out of the container's stdout by their marker, so a warning printed before them
# cannot end up inside the JSON.
sed -n '/^RESULTS_JSON_BEGIN$/,$p' "$WORK/tok.out" | tail -n +2 > "$WORK/results.json"
[ -s "$WORK/results.json" ] || { sed 's/^/    /' "$WORK/tok.out" >&2; fail "the container printed no results block"; }
python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$WORK/results.json" \
  || fail "the results block is not valid JSON; the container's output is above"

say "write $OUT"
python3 - "$WORK/results.json" "$OUT" "$MODEL" "$MODEL_REVISION" "$COMBINED" "$SERVING_IMAGE" "$WORK/tok" "$CORPUS_SHA" "$SERIES_OUT" <<'PY'
import json, sys, hashlib
res_path, out_path, model, rev, combined, image, tok_dir, corpus_sha = sys.argv[1:9]
res = json.load(open(res_path))

unreachable = [t for t, r in res.items() if r["chars"] is None]

# The chat template hash, read from the fetched config rather than copied from the calibration file.
#
# An earlier version of this block carried this comment and never computed the value, so the table went out
# without it. A comment that describes work the code does not do is the defect class this repository spends
# most of its effort on.
tmpl = json.load(open(f"{tok_dir}/tokenizer_config.json")).get("chat_template")
if not tmpl:
    sys.exit("the fetched tokenizer_config.json carries no chat_template; the counts above were taken with "
             "one, so the table cannot record what produced them")
tmpl_sha = hashlib.sha256(tmpl.encode()).hexdigest()

table = {
    "_comment": (
        "Declared inputTokens resolved to the character length that produces EXACTLY that many tokens, "
        "measured inside the serving image. Regenerate with hack/resolve-input-lengths.sh whenever the "
        "tokenizer revision, the chat template or the prompt corpus changes -- each is recorded below and "
        "each changes every number here."),
    "_rule": (
        "Several character lengths give the same token count, so the recorded one is the SMALLEST: the "
        "fewest bytes on the wire for the declared count. allMatches keeps the rest so the choice is "
        "visible rather than implied."),
    "_searchNote": (
        "The token count is not monotone in the character count -- decreasesInWindow records how often it "
        "fell inside each sweep. A binary search would step over answers that exist, so the window is swept "
        "exhaustively. The window comes from an affine fit to the three calibration points and is only a "
        "search initializer; acceptance is the exact measured count."),
    "tokenizer": model,
    "tokenizerRevision": rev,
    "tokenizerCoreFilesCombinedSHA256": combined,
    "chatTemplateSHA256": tmpl_sha,
    "promptCorpusSHA256": corpus_sha,
    "servingImage": image,
    "resolved": {t: r for t, r in sorted(res.items(), key=lambda kv: int(kv[0])) if r["chars"] is not None},
    "unreachableAtThisWindow": unreachable,
}
series_path = sys.argv[9] if len(sys.argv) > 9 and sys.argv[9] else ""
if series_path:
    series = {
        "_comment": (
            "Every measured (characters, tokens) pair from the sweeps that produced "
            "hack/input-length-resolution.json. This is the evidence for the non-monotonicity claim: the "
            "token count falls as the character count rises, repeatedly, because byte-pair merges differ at "
            "the boundary. Regenerate with SERIES_OUT set on hack/resolve-input-lengths.sh."),
        "tokenizer": model,
        "tokenizerRevision": rev,
        "promptCorpusSHA256": corpus_sha,
        "servingImage": image,
        "series": {t: r["series"] for t, r in sorted(res.items(), key=lambda kv: int(kv[0]))},
    }
    json.dump(series, open(series_path, "w"), indent=2)
    open(series_path, "a").write("\n")
    total = sum(len(v) for v in series["series"].values())
    print(f"  wrote {total} measured pairs to {series_path}")

# The series is evidence and the table is the product, so the table does not carry it.
for r in res.values():
    r.pop("series", None)
json.dump(table, open(out_path, "w"), indent=2)
open(out_path, "a").write("\n")
print(f"  wrote {len(table['resolved'])} resolved value(s)"
      + (f", {len(unreachable)} unreachable at this window: {unreachable}" if unreachable else ""))
PY

say "done"
printf '\nThe table is at %s. It is NOT yet what CompilePlan reads -- copying a measured value into Go is a\n' "$OUT"
printf 'separate step, and the values must be transcribed with the count of matches beside them so a later\n'
printf 'reader can see how many lengths gave the same answer.\n'
