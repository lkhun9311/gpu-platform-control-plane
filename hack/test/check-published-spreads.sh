#!/usr/bin/env bash
# RECOMPUTES every published spread, range and width from the per-repetition values the documents carry.
#
# WHY THIS EXISTS
#
# A published sentence read "`R1`'s five repetitions span 173.579-174.393 ms, a width of 0.8 ms". Those are
# the row's FIRST and LAST values. The extremes are 171.882 and 175.269 and the width is 3.387 ms, so the
# endpoints and the width were both wrong -- and the archive's own readings.txt had already printed "spread
# of 3.9 ms" for the control. A figure that contradicted the tool in the same directory went out in prose.
#
# Nothing could have caught it. `make docs-check` tests that backticked names resolve; the token-unit gate
# tests wordings. Neither does arithmetic. So this one does: every claim cites a block of per-repetition
# values in docs/13_PER_REPETITION_VALUES.md, and every claim's displayed figure is recomputed from that
# block and compared against what is actually written in the document.
#
# WHY THE VALUES LIVE IN A DOCUMENT AND NOT IN THE ARCHIVE
#
# The run archives are .gitignore'd, so a check that reads them cannot run in CI, and a local-only gate is
# one nobody runs. Keeping the inputs beside the claim is what makes this runnable from a clone. The cost is
# stated in the data file: these are per-repetition statistics, so this check verifies the RANGE computed
# from them and cannot verify that each p99 was computed correctly from the requests underneath.
#
# WHAT IT REFUSES, AND WHY EACH ONE IS SEPARATE
#
#   - a published figure that does not recompute       -- compared NUMERICALLY, so "14,351" and "14351"
#                                                         are the same endpoint and only the value is at
#                                                         issue, never the grouping
#   - a claim whose block id does not exist            -- the citation is dangling
#   - a block no claim cites and whose values appear
#     in no publication verbatim                       -- a declaration nothing is held to
#   - an endpoint or width that does not recompute     -- the defect this file is named for
#   - a repetition id set that differs from `reps`     -- a dropped or duplicated replay
#   - a duplicate block id                             -- two sources of truth for one figure
#   - a value that does not parse as a number          -- a silent zero is worse than a refusal
#
# The last three matter because the first two are satisfiable by deleting things in pairs. Deleting a block
# AND its claim leaves the file consistent; `reps` is what makes that visible.
#
# WHAT IT DOES NOT ESTABLISH
#
# Said in the closing line as well as here. Internal consistency is not provenance: five values invented
# together, or copied from another run, recompute perfectly. docs/12_EVIDENCE_CHECKSUMS.md commits the
# archive digests and that is the chain which answers provenance -- for a reader who has the archive.
set -euo pipefail

cd "$(dirname "$0")/../.."

failures=0
say() { echo; echo "== $*"; }
ok() { echo "   ok: $*"; }
bad() {
	echo "   FAIL: $*" >&2
	failures=$((failures + 1))
}

DATA=docs/13_PER_REPETITION_VALUES.md

# The documents a claim may live in, declared rather than discovered.
#
# astra's review of this design was explicit: the population must be the PUBLICATION SET, not the set of
# files that happen to contain a marker. A checker that walks "every file with a block" cannot see a claim
# that lost its block, which is the direction the defect actually travelled.
PUBLICATIONS=(
	README.md
	docs/11_WHAT_THIS_MEASURED.md
	docs/12_EVIDENCE_CHECKSUMS.md
	docs/superpowers/specs/2026-09-10-does-splitting-the-card-buy-protection.md
)

# The whole of the arithmetic, in python3 so it is decimal rather than shell float.
#
# ROUNDING IS AT THE END, ONCE. Subtracting two rounded endpoints is a different number from rounding the
# difference: 175.269 - 171.882 = 3.387 rounds to 3.4, while 175.3 - 171.9 = 3.4 only coincidentally agrees
# here and will not elsewhere. astra named this one specifically.
#
# Ratios are joined by repetition id. range(Ai/Bi) is not range(A)/range(B), and the second is what a reader
# computes by hand from two published spreads.
recompute() {
	python3 - "$DATA" "$@" <<-'PY'
		import re, sys
		from decimal import Decimal, ROUND_HALF_UP

		data_path, *publications = sys.argv[1:]
		text = open(data_path, encoding="utf-8").read()

		# --- refuse a block KIND nobody checks ---------------------------------------------------------
		#
		# This is first because it is the failure that has already happened. Nine input- and derived-blocks
		# were added to the data file and the gate stayed GREEN with BLOCKS=5: the parser matched only
		# "spread-block", so the new declarations were invisible -- not wrong, not reported, just unread.
		# A checker that silently ignores a new declaration is worse than one that breaks on it, because
		# breaking is how you find out.
		#
		# So every `<!-- …-block` comment in the file must be a kind this script knows, and adding a tenth
		# kind without teaching the parser fails here rather than passing quietly.
		KNOWN_KINDS = ("spread-block", "input-block", "derived-block")
		blocks, problems = {}, []
		for kind in re.findall(r"<!--\s*([a-z-]+-block)\b", text):
		    if kind not in KNOWN_KINDS:
		        problems.append(
		            f"the data file declares a {kind} and this checker does not read that kind; a declaration "
		            f"no check covers is the defect this gate exists for")

		# --- parse the spread blocks ------------------------------------------------------------------
		REQUIRED = ("id", "archive", "source", "arm", "tenant", "population",
		            "statistic", "unit", "input_level", "reps", "count", "offered", "excluded",
		            "aggregation", "rounding")
		for header, table in re.findall(r"<!-- spread-block\n(.*?)-->\n\n((?:\|[^\n]*\n)+)", text, re.S):
		    fields = {}
		    for line in header.strip().splitlines():
		        if ":" not in line:
		            problems.append(f"block header line is not 'key: value': {line!r}")
		            continue
		        k, v = line.split(":", 1)
		        fields[k.strip()] = v.strip()
		    bid = fields.get("id", "<no id>")
		    missing = [k for k in REQUIRED if k not in fields]
		    if missing:
		        problems.append(f"block {bid} is missing field(s): {', '.join(missing)}")
		    unknown = [k for k in fields if k not in REQUIRED]
		    if unknown:
		        problems.append(f"block {bid} has unknown field(s): {', '.join(unknown)}")
		    # `count` is the SAMPLE SIZE each repetition's statistic was taken over, one per rep.
		    #
		    # It exists because a p99 is a statistic over requests and the document published only the
		    # statistic. The ten-cell shared arm's third repetition is the case: its 4000.510 ms was computed
		    # over 4,654 completed requests where every other repetition had 4,655, because one request came
		    # back 502 with no first token and no end timestamp -- so it has no latency to contribute and
		    # cannot be included at all. A reader given five numbers and no sizes reads five equal samples.
		    reps_listed = [r.strip() for r in fields.get("reps", "").split(",") if r.strip()]
		    counts_listed = [c.strip() for c in fields.get("count", "").split(",") if c.strip()]
		    if len(counts_listed) != len(reps_listed):
		        problems.append(
		            f"block {bid} lists {len(reps_listed)} repetition(s) and {len(counts_listed)} sample "
		            f"size(s); one count per repetition or the sizes cannot be read against the values")
		    for c in counts_listed:
		        if not c.isdigit():
		            problems.append(f"block {bid} has a non-numeric sample size {c!r}")
		    # `offered` and `excluded` say what the sample size is a size OF, which `count` alone cannot.
		    #
		    # A p99 over 4,654 requests is a different claim depending on whether 4,654 were sent or 4,655
		    # were sent and one was dropped. The second is the ten-cell shared arm, and until these fields
		    # existed the document published the 4,654 and said nothing about the request that is missing
		    # from it -- so a reader could not tell a small sample from a censored one. Recomputed: had that
		    # one request been the slowest premium request of its repetition, the p99 would have been
		    # 4011.620 ms rather than 4000.510, a bound of 11.110 ms against an arm difference of 23x.
		    #
		    # `excluded` names the DISPOSITION CLASSES of internal/bench/report.go's Summarize switch, in its
		    # precedence: timed_out, rejected, failed. Classes are joined with `+` inside a repetition and
		    # the repetitions with `,`; a repetition that excluded nothing is the word `none`, because an
		    # empty field would make "nothing was dropped" and "nobody looked" the same string.
		    offered_listed = [o.strip() for o in fields.get("offered", "").split(",") if o.strip()]
		    excluded_listed = [e.strip() for e in fields.get("excluded", "").split(",") if e.strip()]
		    if len(offered_listed) != len(reps_listed):
		        problems.append(
		            f"block {bid} lists {len(reps_listed)} repetition(s) and {len(offered_listed)} offered "
		            f"count(s); one per repetition or the exclusions cannot be read against the sizes")
		    if len(excluded_listed) != len(reps_listed):
		        problems.append(
		            f"block {bid} lists {len(reps_listed)} repetition(s) and {len(excluded_listed)} "
		            f"exclusion field(s); one per repetition, with `none` where nothing was excluded")
		    for o in offered_listed:
		        if not o.isdigit():
		            problems.append(f"block {bid} has a non-numeric offered count {o!r}")
		    # The arithmetic, checked WITHOUT the archive so it also runs where the archives are absent:
		    # offered = count + everything excluded. The classes are disjoint by construction in Summarize,
		    # so their sum is the whole exclusion and this identity has to hold in the published numbers.
		    for i, rep in enumerate(reps_listed):
		        if i >= len(counts_listed) or i >= len(offered_listed) or i >= len(excluded_listed):
		            break
		        if not counts_listed[i].isdigit() or not offered_listed[i].isdigit():
		            continue
		        exc_total, exc_bad = 0, False
		        if excluded_listed[i] != "none":
		            for part in excluded_listed[i].split("+"):
		                cls, _, num = part.partition("=")
		                if cls not in ("timed_out", "rejected", "failed") or not num.isdigit():
		                    problems.append(
		                        f"block {bid} repetition {rep} excludes {part!r}, which is not "
		                        f"timed_out=, rejected= or failed= with a count; those are the classes "
		                        f"internal/bench/report.go assigns and the document may not invent others")
		                    exc_bad = True
		                    continue
		                exc_total += int(num)
		        if exc_bad:
		            continue
		        if int(offered_listed[i]) != int(counts_listed[i]) + exc_total:
		            problems.append(
		                f"block {bid} repetition {rep} offers {offered_listed[i]} and accounts for "
		                f"{counts_listed[i]} + {exc_total}; a request that is neither in the sample nor in "
		                f"an exclusion class is one the document has lost")
		    rows = [r for r in table.strip().splitlines()[2:] if r.strip().startswith("|")]
		    vals = {}
		    for r in rows:
		        cells = [c.strip() for c in r.strip().strip("|").split("|")]
		        if len(cells) != 2:
		            problems.append(f"block {bid} row is not 'rep | value': {r.strip()!r}")
		            continue
		        rep, raw = cells
		        if rep in vals:
		            problems.append(f"block {bid} lists repetition {rep} more than once")
		        try:
		            vals[rep] = Decimal(raw)
		        except Exception:
		            problems.append(f"block {bid} value for rep {rep} does not parse as a number: {raw!r}")
		    want = [r.strip() for r in fields.get("reps", "").split(",") if r.strip()]
		    if sorted(vals) != sorted(want):
		        problems.append(
		            f"block {bid} declares reps {want} and lists {sorted(vals)}; a replay that is missing "
		            f"from both the claim and the declaration would otherwise stay consistent")
		    if bid in blocks:
		        problems.append(f"block id {bid} is declared twice, so one figure has two sources of truth")
		    blocks[bid] = vals

		# --- parse the single-valued inputs and the multipliers ---------------------------------------
		#
		# A token count is one number that held on every row, so it has no repetitions to range over. The
		# published multipliers divide those numbers, and `unit` is a SEMANTIC TYPE rather than a label:
		# engine-token is the engine's own prompt_tokens, gateway-estimate-token is ceil(chars/4), and a
		# multiplier that mixes them is the defect that put a withdrawn 5.9x into the documents.
		INPUT_REQUIRED = ("id", "archive", "source", "population", "unit", "value", "basis")
		UNITS = ("engine-token", "gateway-estimate-token", "requests")
		inputs = {}
		for header in re.findall(r"<!-- input-block\n(.*?)-->", text, re.S):
		    f = {}
		    for line in header.strip().splitlines():
		        if ":" not in line:
		            problems.append(f"input-block header line is not 'key: value': {line!r}")
		            continue
		        k, v = line.split(":", 1)
		        f[k.strip()] = v.strip()
		    iid = f.get("id", "<no id>")
		    for k in INPUT_REQUIRED:
		        if k not in f:
		            problems.append(f"input-block {iid} is missing field {k!r}")
		    for k in f:
		        if k not in INPUT_REQUIRED:
		            problems.append(f"input-block {iid} has unknown field {k!r}")
		    if f.get("unit") not in UNITS:
		        problems.append(
		            f"input-block {iid} declares unit {f.get('unit')!r}, which is not one of {UNITS}; a unit "
		            f"this checker does not know cannot be type-checked against the others")
		    if iid in inputs or iid in blocks:
		        problems.append(f"id {iid} is declared twice")
		    try:
		        inputs[iid] = (Decimal(f.get("value", "")), f.get("unit"))
		    except Exception:
		        problems.append(f"input-block {iid} value {f.get('value')!r} does not parse as a number")

		DERIVED_REQUIRED = ("id", "kind", "numerator", "denominator", "unit", "rounding")
		DERIVED_OPTIONAL = ("provenance",)
		derived = {}
		for header in re.findall(r"<!-- derived-block\n(.*?)-->", text, re.S):
		    f = {}
		    for line in header.strip().splitlines():
		        if ":" in line:
		            k, v = line.split(":", 1)
		            f[k.strip()] = v.strip()
		    did = f.get("id", "<no id>")
		    for k in DERIVED_REQUIRED:
		        if k not in f:
		            problems.append(f"derived-block {did} is missing field {k!r}")
		    for k in f:
		        if k not in DERIVED_REQUIRED + DERIVED_OPTIONAL:
		            problems.append(f"derived-block {did} has unknown field {k!r}")
		    if did in derived or did in blocks or did in inputs:
		        problems.append(f"id {did} is declared twice")

		    def side(expr, which):
		        """One side of a ratio: a single input id, or 'count*value + count*value'."""
		        terms = [t.strip() for t in expr.split("+")]
		        total, units, counts = Decimal(0), set(), []
		        for t in terms:
		            parts = [p.strip() for p in t.split("*")]
		            if len(parts) == 1:
		                if parts[0] not in inputs:
		                    problems.append(f"derived-block {did}: {which} names {parts[0]!r}, not a declared input")
		                    return None, None
		                v, u = inputs[parts[0]]
		                total += v
		                units.add(u)
		            elif len(parts) == 2:
		                for p in parts:
		                    if p not in inputs:
		                        problems.append(f"derived-block {did}: {which} names {p!r}, not a declared input")
		                        return None, None
		                (cv, cu), (vv, vu) = inputs[parts[0]], inputs[parts[1]]
		                if cu != "requests":
		                    problems.append(
		                        f"derived-block {did}: {which} weights by {parts[0]!r}, whose unit is {cu!r} "
		                        f"rather than 'requests'")
		                    return None, None
		                total += cv * vv
		                units.add(vu)
		                counts.append(parts[0])
		            else:
		                problems.append(f"derived-block {did}: {which} term {t!r} is not 'value' or 'count*value'")
		                return None, None
		        if len(units) != 1:
		            problems.append(
		                f"derived-block {did}: {which} mixes units {sorted(units)}; a ratio over two different "
		                f"semantic types is not a multiplier of either")
		            return None, None
		        return total, units.pop()

		    kind = f.get("kind")
		    if kind not in ("per-request-ratio", "weighted-total-ratio"):
		        problems.append(
		            f"derived-block {did} declares kind {kind!r}; only 'per-request-ratio' and "
		            f"'weighted-total-ratio' are permitted, and a third shape has to be registered here first")
		        continue
		    n, nu = side(f.get("numerator", ""), "numerator")
		    d, du = side(f.get("denominator", ""), "denominator")
		    if n is None or d is None:
		        continue
		    if nu != du:
		        problems.append(
		            f"derived-block {did} divides {nu} by {du}; both sides must carry the same semantic type")
		        continue
		    if kind == "per-request-ratio" and ("*" in f.get("numerator", "") or "+" in f.get("numerator", "")):
		        problems.append(f"derived-block {did} is a per-request-ratio but its numerator is weighted")
		        continue
		    if kind == "weighted-total-ratio" and "*" not in f.get("numerator", ""):
		        problems.append(f"derived-block {did} is a weighted-total-ratio but its numerator has no count")
		        continue
		    # An ESTIMATE-derived multiplier is refused unless it says it is the withdrawn record.
		    #
		    # 5.9x came from dividing two gateway estimates and was withdrawn in favour of 3.8x from the
		    # engine's own counts. Quoting the withdrawn figure AS a historical record has to stay possible,
		    # or the documents cannot say what they corrected.
		    if nu == "gateway-estimate-token" and f.get("provenance") != "withdrawn-historical":
		        problems.append(
		            f"derived-block {did} is computed from gateway estimates and does not declare "
		            f"'provenance: withdrawn-historical'; an estimate-derived multiplier must not stand as a "
		            f"current measurement")
		        continue
		    if d == 0:
		        problems.append(f"derived-block {did} divides by zero")
		        continue
		    derived[did] = n / d

		def as_number(shown):
		    """The published text as a number, with thousands separators removed.

		    A span is published as "14,351-15,078 ms" and the recomputed value is 14351. Comparing the two
		    as STRINGS fails on the comma, and parsing "14,351" with Decimal raises -- so both of this
		    checker's paths got it wrong, in opposite directions, and a correct sentence would have been
		    reported.

		    The comma is stripped rather than generated. If the checker produced the grouping it would be
		    checking formatting, and what it is for is the VALUE: "14,351", "14351" and "14351.0" are the
		    same endpoint and a reader is free to write any of them.
		    """
		    return Decimal(shown.replace(",", "").strip())

		def q(value, dp, shown=None):
		    """Render a recomputed value the way the document would.

		    No normalize(). Decimal("10.000").normalize() is Decimal("1E+1"), so a claim published as "10"
		    was reported as disagreeing with "1E+1" -- the checker's own formatting, not the figure. Caught
		    by section 0 the first time it ran.

		    With no dp, the comparison is numeric: the published text is parsed and compared as a number, so
		    "10", "10.0" and "10.000" are all the same endpoint. A dp means the document displays a rounded
		    figure, and then the rounding is done once, here, on the full-precision value.
		    """
		    try:
		        parsed = as_number(shown) if shown is not None else None
		    except Exception:
		        parsed = None
		    if dp is not None:
		        rounded = value.quantize(Decimal(1).scaleb(-dp), rounding=ROUND_HALF_UP)
		        # Numeric comparison, so the document may group thousands however it likes.
		        if parsed is not None and parsed == rounded:
		            return shown.strip()
		        return str(rounded)
		    if parsed is not None and parsed == value:
		        return shown.strip()
		    return str(value)

		def series(spec):
		    """spec is a block id, a derived-block id, or 'ratio A / B' joined by repetition.

		    A derived block is a SINGLE value, so it comes back as a one-entry mapping. Returning it in the
		    same shape as a spread keeps one comparison path: the alternative was a second branch in the
		    claim loop, and two paths that format and round separately are two paths that drift.
		    """
		    parts = spec.split()
		    if parts[0] in derived:
		        return {"value": derived[parts[0]]}, parts[0]
		    if parts[0] != "ratio":
		        return blocks.get(parts[0]), parts[0]
		    a, b = parts[1], parts[3]
		    if a not in blocks or b not in blocks:
		        return None, f"{a} / {b}"
		    if sorted(blocks[a]) != sorted(blocks[b]):
		        problems.append(f"ratio {a} / {b} cannot be paired: repetition ids differ")
		        return None, f"{a} / {b}"
		    return {r: blocks[a][r] / blocks[b][r] for r in blocks[a]}, f"{a} / {b}"

		# --- check every claim in every declared publication ------------------------------------------
		cited, claims = set(), 0
		CLAIM = re.compile(r"<!-- claim: (.+?) -->(.*?)<!-- /claim -->", re.S)
		for path in publications:
		    try:
		        doc = open(path, encoding="utf-8").read()
		    except OSError as e:
		        problems.append(f"declared publication {path} cannot be read: {e}")
		        continue
		    for spec, shown in CLAIM.findall(doc):
		        claims += 1
		        toks = spec.split()
		        dp = None
		        for t in toks:
		            if t.startswith("dp="):
		                dp = int(t.split("=", 1)[1])
		        toks = [t for t in toks if not t.startswith("dp=")]
		        which = toks[-1]
		        vals, name = series(" ".join(toks[:-1]))
		        # A token counts as a citation when it NAMES A DECLARED BLOCK -- not when it matches a
		        # prefix.
		        #
		        # This read `t.startswith("m5c-")`, which is the project's own id convention, so every real
		        # id was collected and section 0's synthetic `t-good` never was. CITED stayed 0 there, the
		        # uncited-block check fired on the correct document, and the two assertions that would have
		        # caught it were themselves the ones failing. The real documents passed for a coincidence:
		        # their ids happen to carry that prefix.
		        #
		        # Narrowing a population by a naming rule is the same defect this whole gate was written
		        # after -- a check that cannot see the rows it was supposed to cover.
		        for t in toks:
		            if t in blocks or t in derived or t in inputs:
		                cited.add(t)
		        if vals is None:
		            problems.append(f"{path}: claim cites {name}, which is not a declared block")
		            continue
		        v = list(vals.values())
		        # `median` is the REGISTERED point estimate, and it was published with no block behind it.
		        #
		        # 174.268 ms, 4000.579 ms and 14868.019 ms appear in docs/11, docs/12 and the design spec as
		        # "median of per-repetition p99" -- the figure the registered estimand divides -- and carried
		        # no claim marker, so this gate's population never contained them. The uncited-BLOCK check
		        # is the mirror image of that and could not see it: a block with no citation is refused, a
		        # citation with no block is refused, and a FIGURE WITH NEITHER was invisible.
		        #
		        # The convention is internal/bench/report.go's medianOf, frozen by the design spec's third
		        # 2026-09-30 amendment: the mean of the two central order statistics on an even count,
		        # "because it makes B and C continuous in the observations". Five repetitions take the middle
		        # one; the ninth pilot's two would take their mean, which is why this is not `sorted()[n//2]`.
		        def _median(xs):
		            s = sorted(xs)
		            n = len(s)
		            return s[n // 2] if n % 2 else (s[n // 2 - 1] + s[n // 2]) / 2

		        got = {"min": min(v), "max": max(v), "width": max(v) - min(v),
		               "median": _median(v),
		               "value": v[0] if len(v) == 1 else None}.get(which)
		        if got is None:
		            problems.append(
		                f"{path}: claim asks for {which!r} from {name}; a spread takes min, max or width and "
		                f"a derived multiplier takes value")
		            continue
		        want = q(got, dp, shown.strip())
		        if shown.strip() != want:
		            problems.append(
		                f"{path}: claim '{spec}' is published as {shown.strip()!r} and recomputes to "
		                f"{want!r} from {name}")

		# --- a block nothing is held to --------------------------------------------------------------
		#
		# A marker is one way to cite a block. The other is a publication that quotes the values verbatim --
		# docs/12 prints the ten-cell rows inside a fenced block of expected report output, and putting
		# markers inside quoted output would corrupt the thing being quoted.
		published = "\n".join(
		    open(p, encoding="utf-8").read() for p in publications if __import__("os").path.exists(p))
		for bid, vals in blocks.items():
		    if bid in cited:
		        continue
		    if vals and all(str(x) in published for x in vals.values()):
		        continue
		    problems.append(
		        f"block {bid} is cited by no claim and its values appear in no publication, so it is a "
		        f"declaration nothing is held to")

		# The same rule for the other two kinds, and it has to be the same rule.
		#
		# The first version of this loop covered `blocks` only. When input- and derived-blocks were added the
		# gate stayed green over nine unchecked declarations -- so an uncited-declaration check that knows
		# one kind out of three is the same silence in a smaller place. A derived block earns its keep only
		# by being quoted; an input block earns its keep by feeding one that is.
		for did in derived:
		    if did not in cited:
		        problems.append(
		            f"derived-block {did} is cited by no claim, so a multiplier is declared that no published "
		            f"sentence is held to")
		feeding = set()
		for header in re.findall(r"<!-- derived-block\n(.*?)-->", text, re.S):
		    for line in header.strip().splitlines():
		        if line.split(":", 1)[0].strip() in ("numerator", "denominator"):
		            for tok in re.split(r"[+*]", line.split(":", 1)[1]):
		                feeding.add(tok.strip())
		for iid in inputs:
		    if iid not in cited and iid not in feeding:
		        problems.append(
		            f"input-block {iid} is cited by no claim and feeds no multiplier, so it is a value nothing "
		            f"is computed from")

		print(f"BLOCKS={len(blocks)} INPUTS={len(inputs)} DERIVED={len(derived)} "
		      f"CLAIMS={claims} CITED={len(cited)}")
		for p in problems:
		    print(f"PROBLEM {p}")
	PY
}

# --- 0. the checker reports a wrong figure, and spares a right one ----------------------------------------
#
# Over a SYNTHETIC tree through the same function, because checking the arithmetic in isolation would prove
# nothing about the block parser, the claim matcher, the rounding or the publication set. Every mutation this
# gate is meant to survive is downstream of those.
say "0. the checker fails on a wrong endpoint, a wrong width and a dangling citation"
SELF="$(mktemp -d)"
trap 'rm -rf "$SELF"' EXIT
mkdir -p "$SELF/docs"
cat > "$SELF/data.md" <<'EOF'
<!-- spread-block
id: t-good
archive: x
source: y
arm: R1
tenant: premium-1
population: completed
statistic: TTFT p99
unit: ms
input_level: per-repetition-statistic
reps: 1,2,3
count: 100,100,100
offered: 100,100,100
excluded: none,none,none
aggregation: min, max, max-minus-min
rounding: half-up at the displayed decimal place
-->

| rep | v |
| --- | ---: |
| 1 | 10.000 |
| 2 | 13.387 |
| 3 | 11.000 |
EOF
cat > "$SELF/docs/right.md" <<'EOF'
It spans <!-- claim: t-good min -->10<!-- /claim --> to <!-- claim: t-good max -->13.387<!-- /claim -->,
a width of <!-- claim: t-good width dp=1 -->3.4<!-- /claim -->.
EOF
cat > "$SELF/docs/wrong.md" <<'EOF'
It spans <!-- claim: t-good min -->10.000<!-- /claim --> to <!-- claim: t-good max -->11.000<!-- /claim -->,
a width of <!-- claim: t-good width dp=1 -->1.0<!-- /claim -->.
EOF
cat > "$SELF/docs/dangling.md" <<'EOF'
It spans <!-- claim: t-absent min -->10<!-- /claim -->.
EOF
# A document that cites nothing, for the uncited-block assertion. It is passed ALONGSIDE another file so
# that the publication set is the same shape as the real one.
cat > "$SELF/docs/silent.md" <<'EOF'
This document publishes no spread at all.
EOF

# A SECOND data file with an EVEN repetition count, because the registered median convention only shows
# itself there.
#
# All five real blocks carry five repetitions, so `median` lands on the middle value and the convention for
# an even count -- the mean of the two central order statistics, frozen by the design spec's third
# 2026-09-30 amendment -- is never exercised. Replacing it with `sorted()[n//2]` left the whole gate green.
# The ninth pilot has two repetitions, so this is the shape a block over that archive would have.
#
# 10.000 and 13.387 average to 11.6935. Taking the upper of the two would publish 13.387, which is why the
# two readings differ here and nowhere in the real document.
cat > "$SELF/data2.md" <<'EOF'
<!-- spread-block
id: t-even
archive: x
source: y
arm: R1
tenant: premium-1
population: completed
statistic: TTFT p99
unit: ms
input_level: per-repetition-statistic
reps: 1,2
count: 100,100
offered: 100,100
excluded: none,none
aggregation: min, max, max-minus-min
rounding: half-up at the displayed decimal place
-->

| rep | v |
| --- | ---: |
| 1 | 10.000 |
| 2 | 13.387 |
EOF
cat > "$SELF/docs/median2.md" <<'EOF'
Its median is <!-- claim: t-even median dp=4 -->11.6935<!-- /claim --> ms.
EOF

self_run() { ( DATA="$SELF/data.md"; recompute "$@" ); }
even_run() { ( DATA="$SELF/data2.md"; recompute "$SELF/docs/median2.md" ); }

got=$(self_run "$SELF/docs/right.md")
if printf '%s\n' "$got" | grep -q '^PROBLEM'; then
	bad "the self-test's CORRECT document was reported: $(printf '%s' "$got" | tr '\n' ' ')"
else
	ok "a document whose endpoints and width recompute is not reported"
fi

# TWO problems, not three, and the reason is worth keeping.
#
# wrong.md takes the row's FIRST and LAST values as the endpoints -- the real defect's shape. Here the first
# value IS the minimum, so `min` is correct and only `max` and `width` are wrong. That is exactly what
# happened in the published sentence: 173.579 was the first value and the true minimum was 171.882, so the
# lower endpoint was wrong there and right here. An expectation of 3 was my error, and section 0 caught it.
got=$(self_run "$SELF/docs/wrong.md")
n=$(printf '%s\n' "$got" | grep -c '^PROBLEM' || true)
if [ "$n" = 2 ] &&
	printf '%s\n' "$got" | grep -q "claim 't-good max'" &&
	printf '%s\n' "$got" | grep -q "claim 't-good width dp=1'"; then
	ok "the wrong upper endpoint and the wrong width are both reported, and the right lower one is not"
else
	bad "expected 2 problems naming max and width, got $n: $(printf '%s' "$got" | tr '\n' ' ')"
fi

got=$(self_run "$SELF/docs/dangling.md")
if printf '%s\n' "$got" | grep -q 'not a declared block'; then
	ok "a claim citing an absent block is reported"
else
	bad "a dangling citation was not reported: $(printf '%s' "$got" | tr '\n' ' ')"
fi

# A block nothing cites must be reported. Checked over a publication set that cites nothing -- the first
# attempt at this suppressed the check when fewer than two files were passed, which switched off the
# assertion that was supposed to prove the check works. The condition for disabling a check must never
# overlap with the case the check is being tested on.
got=$(self_run "$SELF/docs/silent.md" "$SELF/docs/dangling.md")
if printf '%s\n' "$got" | grep -q 'nothing is held to'; then
	ok "a block no claim cites is reported"
else
	bad "an uncited block passed: $(printf '%s' "$got" | tr '\n' ' ')"
fi

# The registered median convention, on the only sample shape that can show it.
#
# Every real block has five repetitions, so `median` is the middle value and the even-count rule is never
# reached: replacing it with `sorted()[n//2]` left this gate green. The ninth pilot has two repetitions, so
# two is the shape a block over that archive would take, and 10.000 with 13.387 average to 11.6935 while
# the upper of the pair is 13.387. The two readings differ only here.
got=$(even_run)
if printf '%s\n' "$got" | grep -q '^PROBLEM'; then
	bad "the even-count median was reported as disagreeing: $(printf '%s' "$got" | tr '\n' ' ')"
else
	ok "a two-repetition median is the mean of the pair (11.6935), not the upper of the two"
fi

# --- 0b. the five refusals the token blocks brought with them ---------------------------------------------
#
# Each of these was written and none of them had refused anything. That is the state the whole gate exists to
# stop: nine input- and derived-blocks were added earlier the same day and the checker stayed GREEN over
# them, because its regex matched one block kind out of three. A refusal nobody has watched fire is a
# refusal in name.
#
# Built as one synthetic data file per case, because a single file with five faults would stop at the first
# and leave four unexercised.
say "0b. a block kind nobody reads, an undeclared input, a mixed unit, an estimate multiplier and an unpermitted shape"

mk() { # mk <name> <data-file-body>
	mkdir -p "$SELF/$1/docs"
	cat > "$SELF/$1/data.md"
	cat > "$SELF/$1/docs/doc.md" <<'EOD'
The multiplier is <!-- claim: t-ratio value dp=3 -->2.000<!-- /claim -->x.
EOD
}
case_run() { ( DATA="$SELF/$1/data.md"; recompute "$SELF/$1/docs/doc.md" ); }

GOOD_INPUTS='<!-- input-block
id: t-a
archive: x
source: y
population: p
unit: engine-token
value: 512
basis: b
-->

<!-- input-block
id: t-b
archive: x
source: y
population: p
unit: engine-token
value: 256
basis: b
-->
'
GOOD_DERIVED='<!-- derived-block
id: t-ratio
kind: per-request-ratio
numerator: t-a
denominator: t-b
unit: ratio-of-engine-token
rounding: half-up at the displayed decimal place
-->
'
# The control: the shape all five faults are introduced into. If this is not clean the five below prove
# nothing about the faults.
mk control <<EOF
$GOOD_INPUTS
$GOOD_DERIVED
EOF
got=$(case_run control)
if printf '%s\n' "$got" | grep -q '^PROBLEM'; then
	bad "the control data file was reported, so the five cases below cannot isolate their faults: $(printf '%s' "$got" | tr '\n' ' ')"
else
	ok "a correct input/derived pair is not reported"
fi

# 1. a block kind the parser does not read -- the silence that actually happened.
mk unknownkind <<EOF
$GOOD_INPUTS
$GOOD_DERIVED
<!-- summary-block
id: t-other
-->
EOF
printf '%s\n' "$(case_run unknownkind)" | grep -q 'does not read that kind' \
	&& ok "a block kind this checker does not read is refused" \
	|| bad "an unknown block kind passed silently, which is the defect this gate was extended for"

# 2. a multiplier naming an input that was never declared.
mk undeclared <<EOF
$GOOD_INPUTS
<!-- derived-block
id: t-ratio
kind: per-request-ratio
numerator: t-absent
denominator: t-b
unit: ratio-of-engine-token
rounding: half-up at the displayed decimal place
-->
EOF
printf '%s\n' "$(case_run undeclared)" | grep -q "not a declared input" \
	&& ok "a multiplier citing an undeclared input is refused" \
	|| bad "an undeclared input reference passed"

# 3. engine tokens divided by a gateway estimate. Dimensionless does not mean comparable.
mk mixedunit <<EOF
$GOOD_INPUTS
<!-- input-block
id: t-est
archive: x
source: y
population: p
unit: gateway-estimate-token
value: 294
basis: b
-->

<!-- derived-block
id: t-ratio
kind: per-request-ratio
numerator: t-a
denominator: t-est
unit: ratio-of-engine-token
rounding: half-up at the displayed decimal place
-->
EOF
printf '%s\n' "$(case_run mixedunit)" | grep -q 'same semantic type' \
	&& ok "dividing an engine count by a gateway estimate is refused" \
	|| bad "a mixed-unit ratio passed; this is the shape that published a withdrawn 5.9x"

# 4. an estimate-derived multiplier standing as a current measurement.
mk estimate <<EOF
<!-- input-block
id: t-e1
archive: x
source: y
population: p
unit: gateway-estimate-token
value: 294
basis: b
-->

<!-- input-block
id: t-e2
archive: x
source: y
population: p
unit: gateway-estimate-token
value: 50
basis: b
-->

<!-- derived-block
id: t-ratio
kind: per-request-ratio
numerator: t-e1
denominator: t-e2
unit: ratio-of-gateway-estimate-token
rounding: half-up at the displayed decimal place
-->
EOF
got=$(case_run estimate)
printf '%s\n' "$got" | grep -q 'withdrawn-historical' \
	&& ok "an estimate-derived multiplier without a withdrawn-historical provenance is refused" \
	|| bad "an estimate-derived multiplier stood as a current measurement: $(printf '%s' "$got" | tr '\n' ' ')"
# And the same file WITH the declaration must pass, or the refusal has swallowed the historical record.
mk estimateok <<EOF
<!-- input-block
id: t-e1
archive: x
source: y
population: p
unit: gateway-estimate-token
value: 294
basis: b
-->

<!-- input-block
id: t-e2
archive: x
source: y
population: p
unit: gateway-estimate-token
value: 50
basis: b
-->

<!-- derived-block
id: t-ratio
kind: per-request-ratio
numerator: t-e1
denominator: t-e2
unit: ratio-of-gateway-estimate-token
rounding: half-up at the displayed decimal place
provenance: withdrawn-historical
-->
EOF
printf '%s\n' "$(case_run estimateok)" | grep -q 'withdrawn-historical' \
	&& bad "the withdrawn-historical declaration did not exempt the quotation, so a corrected figure cannot be quoted as the record" \
	|| ok "with provenance declared, the withdrawn figure can still be quoted"

# 4b. a declaration nothing is held to, for the two kinds the real data no longer exercises.
#
# ADDED after a mutation run. Deleting the uncited-derived check and the uncited-input check both left the
# whole suite GREEN: those two had fired exactly once, on real data, back when the three multipliers were
# declared and not yet quoted. Once the markers went in, the real file stopped exercising them and the
# self-test never had. "I watched it fire once" is not "the check is pinned".
mk uncitedderived <<EOF
$GOOD_INPUTS
$GOOD_DERIVED
<!-- derived-block
id: t-orphan
kind: per-request-ratio
numerator: t-a
denominator: t-b
unit: ratio-of-engine-token
rounding: half-up at the displayed decimal place
-->
EOF
printf '%s\n' "$(case_run uncitedderived)" | grep -q 'no published sentence is held to' \
	&& ok "a multiplier no sentence quotes is refused" \
	|| bad "an uncited multiplier passed; a declared figure nothing is held to is the silence this gate is for"

mk uncitedinput <<EOF
$GOOD_INPUTS
$GOOD_DERIVED
<!-- input-block
id: t-spare
archive: x
source: y
population: p
unit: engine-token
value: 999
basis: b
-->
EOF
printf '%s\n' "$(case_run uncitedinput)" | grep -q 'nothing is computed from' \
	&& ok "an input that feeds no multiplier and no claim is refused" \
	|| bad "an orphan input passed, so a value can sit in the file with nothing depending on it"

# 5. a shape outside the two permitted ones.
mk badshape <<EOF
$GOOD_INPUTS
<!-- derived-block
id: t-ratio
kind: difference
numerator: t-a
denominator: t-b
unit: ratio-of-engine-token
rounding: half-up at the displayed decimal place
-->
EOF
printf '%s\n' "$(case_run badshape)" | grep -q 'only .per-request-ratio. and' \
	&& ok "a formula shape that was never registered is refused" \
	|| bad "an unregistered formula shape passed, and the data file becomes a language"

# --- 1. every published spread recomputes -----------------------------------------------------------------
say "1. every published spread, range and width recomputes from its declared values"
out=$(recompute "${PUBLICATIONS[@]}")
summary=$(printf '%s\n' "$out" | grep '^BLOCKS=' || true)
problems=$(printf '%s\n' "$out" | grep '^PROBLEM ' || true)
if [ -z "$summary" ]; then
	bad "the recomputation printed no summary line, so it did not run to completion"
else
	ok "$summary"
fi
if [ -n "$problems" ]; then
	while IFS= read -r line; do bad "${line#PROBLEM }"; done <<< "$problems"
else
	ok "no claim disagrees with the values it cites"
fi

# --- 3. the published values recompute FROM THE RAW ROWS, where the archive is on this disk --------------
#
# Section 1 recomputes a claim from the document's declared values, and the closing line of this gate says
# what that leaves open: five values invented together recompute perfectly. This narrows it. Each
# spread-block names an archive; where that archive is here, every repetition's statistic and sample size
# is computed again from the raw request rows and held against the block.
#
# THE ARCHIVES ARE GITIGNORED, so this cannot run in CI and must not pretend otherwise. An archive that is
# absent is reported as SKIPPED and counted separately -- never as an `ok`, which is the shape this
# repository keeps finding in its own checks. The closing summary names the skipped count.
# raw_rows_check prints one line per block: CHECK, SKIP or PROBLEM. It calls neither ok nor bad.
#
# A FUNCTION, because the skip path has to be driven on a document whose archive is absent -- and the only
# honest way to assert "a skip is not counted as a pass" is to run this code and read what it emitted.
# Four text-based assertions in a row were walked past by mutations that reworded or deleted the message;
# the fifth is this. `DATA` is read here and nowhere else, so a subshell can point it at a synthetic file,
# exactly as self_run and case_run already do for the recomputation.
raw_rows_check() {
	while IFS='|' read -r bid archive arm reps counts offered excluded vals; do
		[ -n "$bid" ] || continue
		if [ ! -f "$archive/evidence.tgz" ]; then
			echo "SKIP $bid cites $archive, which is not on this disk"
			continue
		fi
	WORK3=$(mktemp -d)
	tar -xzf "$archive/evidence.tgz" -C "$WORK3" 2>/dev/null
	out3=$(ARM="$arm" REPS="$reps" COUNTS="$counts" OFFERED="$offered" EXCLUDED="$excluded" VALS="$vals" python3 - "$WORK3/m5c-run" <<'PY'
import json, math, os, sys
from decimal import Decimal
d = sys.argv[1]
arm = os.environ["ARM"]
reps = [r.strip() for r in os.environ["REPS"].split(",") if r.strip()]
counts = [c.strip() for c in os.environ["COUNTS"].split(",") if c.strip()]
offered = [o.strip() for o in os.environ["OFFERED"].split(",") if o.strip()]
excluded = [e.strip() for e in os.environ["EXCLUDED"].split(",") if e.strip()]
vals = [v.strip() for v in os.environ["VALS"].split(",") if v.strip()]
def p99(v):
    v = sorted(v)
    return v[max(0, math.ceil(0.99 * len(v)) - 1)]
# The disposition classes are the ones internal/bench/report.go's Summarize switch assigns, IN ITS ORDER:
# timeout first, then an admission shed (429, or 413 carrying a reason), then any other errorKind, and only
# then is a row with a first token completed and one without it failed. Classifying by a different
# precedence here would make the document and the scorer disagree about one archive -- the same shape as the
# pooled point estimate that was published beside a per-repetition interval.
def classify(r):
    if (r.get("errorKind") or "") == "timeout":
        return "timed_out"
    st, ar = r.get("httpStatus") or 0, r.get("admissionReason") or ""
    if st == 429 or (st == 413 and ar):
        return "rejected"
    if r.get("errorKind"):
        return "failed"
    s, ft = r.get("sendUnixNanos") or 0, r.get("firstTokenUnixNanos") or 0
    return "completed" if (s and ft) else "failed"
problems = []
# zip() truncates to the shortest list, so unequal lengths would silently drop the tail of a block and
# report CHECKED over fewer repetitions than the document publishes.
if not (len(reps) == len(counts) == len(offered) == len(excluded) == len(vals)):
    problems.append(
        f"{arm}: the block carries {len(reps)} reps, {len(counts)} counts, {len(offered)} offered, "
        f"{len(excluded)} excluded and {len(vals)} values; the recomputation would drop the tail")
for rep, want_n, want_off, want_exc, want_v in zip(reps, counts, offered, excluded, vals):
    f = os.path.join(d, f"raw-{arm}-{rep}.jsonl")
    if not os.path.exists(f):
        problems.append(f"raw-{arm}-{rep}.jsonl is not in the archive, so this repetition's value has nothing behind it")
        continue
    lat, tally, off_n = [], {}, 0
    for line in open(f):
        line = line.strip()
        if not line:
            continue
        r = json.loads(line)
        if r.get("tenant") != "premium-1":
            continue
        off_n += 1
        k = classify(r)
        tally[k] = tally.get(k, 0) + 1
        s, ft = r.get("sendUnixNanos") or 0, r.get("firstTokenUnixNanos") or 0
        if s and ft:
            lat.append(Decimal(ft - s) / Decimal(10) ** 6)
    if not lat:
        problems.append(f"{arm} rep {rep}: no premium request in the archive carries both a send and a first-token time")
        continue
    got_n = len(lat)
    if str(got_n) != want_n:
        problems.append(f"{arm} rep {rep}: the document publishes a sample of {want_n} and the archive holds {got_n}")
    # Held against the COMPLETED disposition as well, not only against the rows carrying a latency: a
    # timed-out request that recorded a first token sits in one population and not the other, and the
    # published sample would then not be the completed population the block says it is.
    if str(tally.get("completed", 0)) != want_n:
        problems.append(
            f"{arm} rep {rep}: the document publishes a sample of {want_n} and the completed disposition "
            f"holds {tally.get('completed', 0)}")
    if str(off_n) != want_off:
        problems.append(f"{arm} rep {rep}: the document publishes {want_off} offered and the archive holds {off_n}")
    got_exc = "+".join(f"{k}={tally[k]}" for k in sorted(tally) if k != "completed") or "none"
    if got_exc != want_exc:
        problems.append(f"{arm} rep {rep}: the document publishes excluded {want_exc!r} and the archive gives {got_exc!r}")
    got_v = p99(lat).quantize(Decimal("0.001"))
    if got_v != Decimal(want_v):
        problems.append(f"{arm} rep {rep}: the document publishes {want_v} ms and the raw rows give {got_v} ms")
for p in problems:
    print("PROBLEM " + p)
print(f"CHECKED {arm} reps={len(reps)}")
PY
	)
	rm -rf "$WORK3"
		while IFS= read -r l; do
			case "$l" in
			PROBLEM*) echo "$l" ;;
			CHECKED*) echo "CHECK $bid recomputed from raw: ${l#CHECKED }" ;;
			esac
		done <<< "$out3"
	done <<EOF
$(python3 - "$DATA" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
for header, table in re.findall(r"<!-- spread-block\n(.*?)-->\n\n((?:\|[^\n]*\n)+)", text, re.S):
    f = dict(
        (k.strip(), v.strip())
        for k, v in (l.split(":", 1) for l in header.strip().splitlines() if ":" in l)
    )
    rows = [r for r in table.strip().splitlines()[2:] if r.strip().startswith("|")]
    vals = [r.strip().strip("|").split("|")[1].strip() for r in rows]
    print("|".join([f.get("id", ""), f.get("archive", ""), f.get("arm", ""),
                    f.get("reps", ""), f.get("count", ""), f.get("offered", ""),
                    f.get("excluded", ""), ",".join(vals)]))
PY
)
EOF
}

say "3. where the archive is on this disk, every repetition recomputes from its raw rows"
raw_out=$(raw_rows_check)
raw_checked=$(printf '%s\n' "$raw_out" | grep -c '^CHECK ' || true)
raw_skipped=$(printf '%s\n' "$raw_out" | grep -c '^SKIP ' || true)
while IFS= read -r l; do
	case "$l" in
	PROBLEM*) bad "${l#PROBLEM }" ;;
	CHECK*) ok "${l#CHECK }" ;;
	SKIP*) echo "   SKIPPED: ${l#SKIP }; its values stand on section 1 alone" >&2 ;;
	esac
done <<< "$raw_out"
if [ "$raw_skipped" = 0 ]; then
	ok "every cited archive was on this disk, so no block rests on section 1 alone"
else
	echo "   SKIPPED TOTAL: $raw_skipped block(s) had no archive here. That is not a pass: those values are recomputed from the document only." >&2
fi

# A MISSING ARCHIVE MUST NOT COUNT AS A PASS, and nothing above establishes that.
#
# Both cited archives are on this disk, so the skip path never runs here -- and swapping its `SKIPPED` line
# for an `ok` left this gate green. The claim "a skipped case is not a passed one" was a sentence in the
# summary and in a comment, which is the shape this repository keeps finding. So the skip path is driven on
# a synthetic data file whose block cites an archive that does not exist, and the assertion is that the run
# does NOT report it as satisfied.
say "3b. a block whose archive is absent is reported as skipped, not as checked"
MISSING_DOC="$(mktemp -d)/absent.md"
sed 's|^archive: hack/m5c-20261002-014903$|archive: hack/m5c-no-such-archive|' "$DATA" > "$MISSING_DOC"
if ! grep -q '^archive: hack/m5c-no-such-archive$' "$MISSING_DOC"; then
	bad "the synthetic document still names a real archive, so this case did not exercise the skip path at all"
else
	skip_out=$(
		DATA="$MISSING_DOC"
		python3 - "$DATA" <<'PY'
import re, sys, os
text = open(sys.argv[1]).read()
absent = checked = 0
for header, _ in re.findall(r"<!-- spread-block\n(.*?)-->\n\n((?:\|[^\n]*\n)+)", text, re.S):
    f = dict((k.strip(), v.strip()) for k, v in (l.split(":", 1) for l in header.strip().splitlines() if ":" in l))
    if os.path.isfile(os.path.join(f.get("archive", ""), "evidence.tgz")):
        checked += 1
    else:
        absent += 1
print(f"ABSENT {absent} CHECKED {checked}")
PY
	)
	absent_n=$(printf '%s' "$skip_out" | awk '{print $2}')
	if [ "${absent_n:-0}" -ge 1 ]; then
		ok "the skip path is reachable: $skip_out for a document citing a missing archive"
	else
		bad "a document citing hack/m5c-no-such-archive produced $skip_out; if no block is absent, the skip branch cannot be exercised and its wording is untested"
	fi
	# And the production gate must not call that state satisfied.
	# NEITHER skip reporter may be an `ok`, and that is what is asserted -- not that a string exists.
	#
	# My first attempt grepped for the message text. Both mutations keep the text: turning
	# `echo "   SKIPPED TOTAL: …" >&2` into `ok "SKIPPED TOTAL: …"` leaves `SKIPPED TOTAL: $raw_skipped`
	# in the file, so the assertion passed while the skip was being counted as a pass. That is the fourth
	# time this session a text check stood in for a behaviour check, and the second AFTER I wrote the note
	# about it.
	#
	# `ok` is a function that increments nothing and prints a pass; `bad` raises the failure count. So the
	# property is: no line that reports a skip calls `ok`. Counted over both reporters at once, because
	# pinning one of two is how the total came to be free in the first place.
	# Keyed on `raw_skipped`, not on the word SKIPPED, because a mutation rewrites the message.
	#
	# Two earlier versions of this assertion failed for the same reason, one after the other. Grepping for
	# the message text passed when `echo "   SKIPPED TOTAL: …" >&2` became `ok "SKIPPED TOTAL: …"` -- the
	# text survived. Grepping for `ok ".*SKIPPED` then passed when the per-block line became
	# `ok "$bid cites $archive…"`, which drops the word entirely. And counting SKIPPED mentions to prove the
	# reporters exist passed with both deleted, because this comment and the closing summary mention it ten
	# times. Fifth text-for-behaviour substitution this session, three of them in this one assertion.
	#
	# `raw_skipped` is the variable the skip path increments and nothing else touches, so the two lines that
	# report a skip are the lines mentioning it outside this section. The property: none of them calls ok.
	# RUN the skip path and read what it emitted. Five text assertions were walked past before this.
	#
	# The history is worth keeping because each attempt failed for a reason the previous one should have
	# taught me: grepping the message text survived a reworded message; grepping `ok ".*SKIPPED` survived a
	# message that drops the word; counting SKIPPED mentions survived deleting both reporters, because the
	# comments mention it; keying on `raw_skipped` counted the assertion's own message and three comments,
	# and its `>= 3` threshold was a number I picked after seeing the mutation I had in mind.
	#
	# raw_rows_check is a function that emits CHECK, SKIP and PROBLEM lines and calls neither ok nor bad, so
	# the property is checkable by running it against a document whose archives are absent: the blocks that
	# cannot be recomputed come back as SKIP, and nothing that comes back as SKIP is countable as a pass.
	absent_out=$( DATA="$MISSING_DOC"; raw_rows_check )
	a_skip=$(printf '%s\n' "$absent_out" | grep -c '^SKIP ' || true)
	a_check=$(printf '%s\n' "$absent_out" | grep -c '^CHECK ' || true)
	a_problem=$(printf '%s\n' "$absent_out" | grep -c '^PROBLEM ' || true)
	# The expected counts are the disk's, counted independently just above, not literals.
	# They were 3 and 2 -- the blocks absent and present on the machine that wrote this -- and on CI, where no
	# archive is checked out, all five are absent and the literal failed a correct run.
	want_skip=$(printf '%s' "$skip_out" | awk '{print $2}')
	want_check=$(printf '%s' "$skip_out" | awk '{print $4}')
	if [ -n "$want_skip" ] && [ "$a_skip" = "$want_skip" ] && [ "$a_check" = "$want_check" ]; then
		ok "with $want_skip archive(s) absent the path emits $a_skip SKIP and $a_check CHECK: a block it could not recompute is never emitted as one it did"
	else
		bad "a document whose archives are absent for ${want_skip:-?} block(s) and present for ${want_check:-?} produced $a_skip SKIP and $a_check CHECK lines; a skip emitted as a check is a value nothing recomputed being counted as recomputed"
	fi
	if [ "$a_problem" = 0 ]; then
		ok "a missing archive produces no PROBLEM either: absent is reported as absent, not as a disagreement"
	else
		bad "a missing archive produced $a_problem PROBLEM line(s); 'the archive is not here' and 'the published value is wrong' are different findings and this conflates them"
	fi

fi
rm -rf "$(dirname "$MISSING_DOC")"

# --- 2. the data file is tracked -------------------------------------------------------------------------
#
# An untracked file does not exist to a checker that reads `git ls-files`, and docs-check is one. The data
# file being ignored would make this whole gate pass over an empty population.
say "2. the values file is tracked, so a clone can run this"
if git ls-files --error-unmatch "$DATA" > /dev/null 2>&1; then
	ok "$DATA is tracked"
else
	bad "$DATA is not tracked by git; .gitignore publishes markdown selectively and this file must be in the allow-list"
fi

echo
if [ "$failures" = "0" ]; then
	say "PUBLISHED SPREADS RECOMPUTE: every cited endpoint and width was derived again from the per-repetition values in the document, in decimal, rounded once at the end."
	say "ALSO established, but ONLY where the archive is on this disk: section 3 recomputes each repetition's statistic AND its sample size from the raw request rows, so a value invented and a value measured no longer read the same. Where an archive is absent the line says SKIPPED and the count is reported, because the archives are gitignored and a skipped case is not a passed one."
	say "NOT established by this check: that an archive present here is the one the run produced -- provenance is docs/12_EVIDENCE_CHECKSUMS.md's digest chain. Nor that the figures published from blocks WITHOUT an archive on disk came from any run at all; for those, five values invented together still recompute perfectly."
else
	echo "FAILED: $failures assertion(s) above." >&2
	exit 1
fi
