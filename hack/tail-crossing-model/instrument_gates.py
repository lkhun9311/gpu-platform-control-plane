"""Gates I1-I5 of the instrument-validation registration, read from one archive.

docs/superpowers/specs/2026-10-05-can-the-stock-engine-time-an-iteration-instrument-validation.md, with its
amendment of 2026-10-05. Blocks are repetitions 1-3; a cell is raw-<arm>-<rep>.jsonl beside trace-<arm>-<rep>.jsonl,
engine-log-<arm>-<rep>.txt and, for preemptions, engine-metrics-<arm>-<rep>-{before,after}.prom.

    BENCHHARNESS=path/to/benchharness python3 instrument_gates.py ARCHIVE/m5c-run
    python3 instrument_gates.py --self-test
"""

import json
import math
import os
import random
import statistics
import sys

import iterlog
from iterlog import Refusal

BLOCKS = (1, 2, 3)
TYPES = ("serial", "burst", "stagger")
BOOT = 2000
POOLED, PER_SETTING, COMPLETENESS, STABILITY = 0.02, 0.05, 0.05, 0.05

# Session 2 (docs/superpowers/specs/2026-10-05-instrument-validation-session-2.md) is told apart by the study its rows
# carry, and only that study takes the paths below; session 1's verdict must come out of this file unchanged.
STUDY_S2 = "instrument-validation-s2-2026-10-05"
# Session 3 (2026-10-06-instrument-validation-session-3.md) is session 2 with fixed-length staggered decoders: every
# session-2 path applies to it, and it adds the decoder-length check and S on the warm-up's staggered episodes.
STUDY_S3 = "instrument-validation-s3-2026-10-06"
# Session 4 (2026-10-06-instrument-validation-session-4.md) is session 3 with a conditioning request between the
# warm-up's cycle and its verification requests.
STUDY_S4 = "instrument-validation-s4-2026-10-06"
STUDY_S1 = "instrument-validation-2026-10-05"
# Every study this file can judge; any other id is refused rather than judged by session 1's rules.
# Without this, a later session's rows fell through to session 1's path with no warning (found by review).
KNOWN_STUDIES = (STUDY_S1, STUDY_S2, STUDY_S3, STUDY_S4)
WARM_STUDIES = (STUDY_S2, STUDY_S3, STUDY_S4)
FIXED_LENGTH_STUDIES = (STUDY_S3, STUDY_S4)
# Session 3 registers every staggered decoder at exactly 512 output tokens, not merely "at its cap": a decoder capped
# lower would satisfy cap-equality and still not be the registered decode window (found by review).
S3_DECODER_TOKENS = 512
# The prefill clock frozen from session 1's 159 warm serial-log requests; session 2 predicts with it and never refits.
CLOCK_A, CLOCK_B, CLOCK_C = 6.446325, 17.776531, 0.002620206
WARM_TTFT_MS, WARM_TOL, WARM_PAIR_TOL = 231.0, 0.05, 0.02
# A stream's end is stamped after its last token by the stream's termination; session 1's decode regressions put that
# delay at no more than 0.43 ms at any length, so S demands the prefill's first token a full millisecond earlier.
S_END_MARGIN_MS = 1.0


def study_of(run):
    """The study the serial-log rows of block 1 were recorded under; every row of a cell carries it."""
    with open(os.path.join(run, "raw-serial-log-1.jsonl")) as f:
        return json.loads(f.readline()).get("study", "")


def load_cell(run, arm, rep, warmup=False):
    """A cell's requests joined to their trace rows, one dict per request, refusing anything that does not join.

    warmup=True reads the cell's warm-up instead, which the matrix writes as warmup-trace-* beside raw-warmup-*.
    """
    tname, rname = (f"warmup-trace-{arm}-{rep}.jsonl", f"raw-warmup-{arm}-{rep}.jsonl") if warmup else \
        (f"trace-{arm}-{rep}.jsonl", f"raw-{arm}-{rep}.jsonl")
    # A cell the run never bought is a refusal that names it, not a traceback (session 3 stopped after seven cells).
    for name in (tname, rname):
        if not os.path.exists(os.path.join(run, name)):
            raise Refusal(f"{arm}-{rep}: {name} is missing, so the cell was not recorded and the gates cannot be read")
    trace = {r["index"]: r for r in map(json.loads, open(os.path.join(run, tname)))}
    raw = [json.loads(l) for l in open(os.path.join(run, rname))]
    if len(raw) != len(trace) or {r["index"] for r in raw} != set(trace):
        raise Refusal(f"{arm}-{rep}: {len(raw)} raw rows against {len(trace)} trace rows -- a request was lost or added")
    failed = [r["index"] for r in raw if r.get("errorKind")]
    if failed:
        raise Refusal(f"{arm}-{rep}: {len(failed)} failed request(s), first index {failed[0]} (gate I2)")
    out = []
    for r in raw:
        t = trace[r["index"]]
        out.append(dict(index=r["index"], offset=t["offsetMs"], cap=t["maxOutputTokens"],
                        input_tokens=r["engineInputTokens"], output_tokens=r["engineOutputTokens"],
                        ttft_ms=(r["firstTokenUnixNanos"] - r["sendUnixNanos"]) / 1e6, send_ms=r["sendUnixNanos"] / 1e6,
                        first_ms=r["firstTokenUnixNanos"] / 1e6, end_ms=r["endUnixNanos"] / 1e6,
                        finish=r.get("finishReason", "")))
    out.sort(key=lambda q: (q["offset"], q["index"]))
    return out


def settings(kind, reqs):
    """Each request's setting: the episode's parameters and the request's role in it.

    Episodes are recovered from the trace's offsets, because that is what the generator controls: a serial episode
    is one row, a burst is the rows sharing an offset, and a staggered episode is a set of decoders sharing an offset
    followed by one prefill row with a smaller output cap.

    A request's role inside a burst, or among a stagger's decoders, is its rank by TTFT within its episode.
    The requests of one burst are not alike: the sixteenth of a 16 x 8,192 burst waits for fifteen prompts, and the
    engine, not the trace, decides which request that is. Pooled as one setting, a bootstrap that resamples them
    moves the median between positions, and with no overhead at all I1's burst interval was +/-14% (reproduced
    2026-10-05 after the fit code's author reported it, before any burst cell of the paid run was read). Ranked, a
    setting holds one value per cycle, as a serial setting does.
    """
    groups = []
    for q in reqs:
        if groups and groups[-1][0]["offset"] == q["offset"]:
            groups[-1].append(q)
        else:
            groups.append([q])
    keyed = []
    if kind in ("serial", "burst"):
        for g in groups:
            for rank, q in enumerate(sorted(g, key=lambda q: q["ttft_ms"])):
                keyed.append(((len(g), q["input_tokens"], q["cap"], rank), q))
        return keyed
    i = 0
    while i < len(groups):
        dec = groups[i]
        if i + 1 >= len(groups) or len(groups[i + 1]) != 1 or groups[i + 1][0]["cap"] >= dec[0]["cap"]:
            raise Refusal(f"staggered trace: the decoders at offset {dec[0]['offset']} ms have no prefill after them")
        pre = groups[i + 1][0]
        ep = (len(dec), dec[0]["input_tokens"], pre["input_tokens"])
        keyed.extend(((ep + ("decoder", rank), q) for rank, q in enumerate(sorted(dec, key=lambda q: q["ttft_ms"]))))
        keyed.append((ep + ("prefill",), pre))
        i += 2
    return keyed


def itl(q):
    return (q["end_ms"] - q["first_ms"]) / (q["output_tokens"] - 1) if q["output_tokens"] >= 2 else None


def by_setting(kind, reqs, quantity):
    out = {}
    for s, q in settings(kind, reqs):
        v = q["ttft_ms"] if quantity == "ttft" else itl(q)
        if v is not None:
            out.setdefault(s, []).append(v)
    return out


def gate_i1(cells, kind, quantity, rng, stat=statistics.median, role=None, label=""):
    """d(s, b) = log(stat on / stat off) per setting and block; pooled 95% interval within 2%, each setting within 5%.

    Session 1 compares medians. Session 2 compares staggered TTFT by mean, because a median jumps between the two modes
    session 1 showed, and judges the prefill role on its own as well (role="prefill") so decoder ranks cannot dilute it.
    """
    def pick(data):
        return {s: v for s, v in data.items() if role is None or (len(s) > 3 and s[3] == role)}

    on = {b: pick(by_setting(kind, cells[(f"{kind}-log", b)], quantity)) for b in BLOCKS}
    off = {b: pick(by_setting(kind, cells[(f"{kind}-nolog", b)], quantity)) for b in BLOCKS}
    # Every one of the six cells must hold the same settings.
    #
    # Comparing only within a block let a setting absent from both cells of one block drop out of every block,
    # and a ten-fold overhead on that setting in the other two blocks then passed (found by review, reproduced).
    sets = [set(on[b]) for b in BLOCKS] + [set(off[b]) for b in BLOCKS]
    union = set().union(*sets)
    missing = sorted(union - set.intersection(*sets), key=str)
    if missing or not union:
        raise Refusal(f"I1 {kind} {quantity}: settings missing from some cell: {missing[:3]}")
    keys = sorted(union, key=str)

    # The bootstrap resamples whole episodes, keeping every rank of one episode together.
    #
    # A setting's values are listed in episode order, so index i of every rank of one episode type in one cell is the
    # same episode. Resampling each rank on its own treated ranks that move together -- a whole burst slower -- as
    # independent, and a review showed it passing at +/-1% where episode resampling gives +/-6%. The group is the
    # setting without its role and rank, so a staggered episode's decoders and its prefill are drawn together too.
    def group(s):
        return s[:3]

    sizes = {}
    for side, data in (("on", on), ("off", off)):
        for b in BLOCKS:
            for s in keys:
                n = sizes.setdefault((side, b, group(s)), len(data[b][s]))
                if n != len(data[b][s]):
                    raise Refusal(f"I1 {kind} {quantity}: in {side}-{b}, setting {s} has {len(data[b][s])} values and "
                                  f"its episode type has {n}, so its ranks cannot be resampled as whole episodes")

    def pooled(draw):
        def med(side, data, b, s):
            v = data[b][s]
            return stat([v[i] for i in draw[(side, b, group(s))]])
        return statistics.fmean(math.log(med("on", on, b, s) / med("off", off, b, s)) for s in keys for b in BLOCKS)

    # Both are as registered, and both are weaker than their labels read (issue 326).
    # The interval resamples episodes within each cell and holds the three blocks fixed, so it carries no
    # between-block variance: block effects of +0.2, -0.2 and 0 give a zero-width interval.
    point = pooled({k: range(n) for k, n in sizes.items()})
    boot = sorted(pooled({k: rng.choices(range(n), k=n) for k, n in sizes.items()}) for _ in range(BOOT))
    lo, hi = boot[int(0.025 * BOOT)], boot[int(0.975 * BOOT) - 1]
    worst = max(keys, key=lambda s: abs(statistics.fmean(
        math.log(stat(on[b][s]) / stat(off[b][s])) for b in BLOCKS)))
    worst_d = statistics.fmean(math.log(stat(on[b][worst]) / stat(off[b][worst])) for b in BLOCKS)
    # The registration bounds the mean of d = log(on/off), so "within 5%" is |d| <= 0.05: an actual +5.1% passes and
    # -4.9% fails. Read as ratios the bounds are log(0.95) to log(1.05), and no recorded verdict falls between the two.
    ok = -POOLED <= lo and hi <= POOLED and abs(worst_d) <= PER_SETTING
    return ok, f"I1 {kind:7s} {quantity:4s}{label}: mean d {point:+.4f}, 95% [{lo:+.4f}, {hi:+.4f}]; worst setting {worst} {worst_d:+.4f}"


def preemptions(run, arm, rep):
    """The engine's preemption counter across the cell, or a refusal when it cannot be read: unread is not zero."""
    def total(which):
        path = os.path.join(run, f"engine-metrics-{arm}-{rep}-{which}.prom")
        if not os.path.exists(path):
            raise Refusal(f"{arm}-{rep}: {path} is missing, so preemptions cannot be counted (gate I2)")
        samples = [float(l.rsplit(" ", 1)[1]) for l in open(path) if l.startswith("vllm:num_preemptions_total")]
        # A scrape without the counter is unread, and unread is not zero.
        if not samples:
            raise Refusal(f"{arm}-{rep}: {path} has no vllm:num_preemptions_total sample (gate I2)")
        return sum(samples)
    return total("after") - total("before")


def measured_iters(run, arm, b, s2):
    """The cell's iterations, every one accounted for; in session 2, only those after the warm-up boundary are returned.

    The whole log is checked for contiguity first, so the warm-up and the measured replay are one unbroken sequence and
    the boundary cannot hide a lost step on either side of it.
    """
    iters = iterlog.parse(open(os.path.join(run, f"engine-log-{arm}-{b}.txt")))
    iterlog.check_indices(iters)
    if not s2:
        return iters
    # Each cell starts a fresh engine, whose iteration index starts at 0 (session 1's real logs did), so a capture
    # that begins later has lost the head of the warm-up, which contiguity alone would not notice (found by review).
    if iters and iters[0]["index"] != 0:
        raise Refusal(f"{arm}-{b}: the captured log starts at iteration {iters[0]['index']}, not 0, so part of the "
                      f"warm-up is missing from it")
    path = os.path.join(run, f"warmup-boundary-{arm}-{b}.txt")
    if not os.path.exists(path):
        raise Refusal(f"{arm}-{b}: {path} is missing, so the warm-up's iterations cannot be told from the measured ones")
    text = open(path).read().strip()
    if not text.isdigit():
        raise Refusal(f"{arm}-{b}: the warm-up boundary reads {text!r}, not an iteration index")
    boundary = int(text)
    if not any(s["index"] == boundary for s in iters):
        raise Refusal(f"{arm}-{b}: the warm-up boundary {boundary} is not an iteration in the captured log")
    # The warm-up's steps are reconciled with the warm-up's requests, as the measured steps are with the measured ones:
    # every prompt token the warm-up sent is scheduled before the boundary and none after it (found by review).
    warm = os.path.join(run, f"raw-warmup-{arm}-{b}.jsonl")
    sent = sum(json.loads(l).get("engineInputTokens", 0) for l in open(warm))
    scheduled = sum(s["ctx_tokens"] for s in iters if s["index"] <= boundary)
    if sent != scheduled:
        raise Refusal(f"{arm}-{b}: the warm-up sent {sent} prompt tokens and the log schedules {scheduled} before the "
                      f"boundary, so the boundary does not separate the warm-up from the measured trace")
    return [s for s in iters if s["index"] > boundary]


def frozen_clock(cells_by_block):
    """Session 2's I3 for prefill: the frozen clock's signed error per serial setting, judged by its median.

    Each serial request is its own episode, so the bootstrap resamples requests within each setting and block.
    """
    errs = {}
    for b, att in cells_by_block.items():
        for r in att:
            steps = [min(2048, r["input_tokens"] - 2048 * j) for j in range(r["k"])]
            pred = sum(r["ctx_ms"]) + CLOCK_A + sum(CLOCK_B + CLOCK_C * p for p in steps)
            # Grouped by the trace's cap, the registered setting: a request that stopped early at EOS still belongs to it.
            errs.setdefault((r["input_tokens"], r["cap"]), {}).setdefault(b, []).append(
                (pred - r["ttft_ms"]) / r["ttft_ms"])
    rng = random.Random(20261005)
    lines, ok = [], True
    every = [e for by in errs.values() for v in by.values() for e in v]
    for s in sorted(errs):
        by = errs[s]
        point = statistics.median([e for v in by.values() for e in v])
        boot = sorted(statistics.median([e for v in by.values() for e in rng.choices(v, k=len(v))]) for _ in range(BOOT))
        lo, hi = boot[int(0.025 * BOOT)], boot[int(0.975 * BOOT) - 1]
        good = -PER_SETTING <= lo and hi <= PER_SETTING
        ok = ok and good
        lines.append(f"I3 frozen clock {s}: median error {point:+.4f}, 95% [{lo:+.4f}, {hi:+.4f}]" + ("" if good else "  <- outside 5%"))
    lines.append(f"I3 frozen clock: {len(every)} requests, largest |error| {max(map(abs, every)):.4f}, "
                 f"{sum(abs(e) > 0.05 for e in every)} beyond 5% (published, not gated)")
    return ok, lines


def gate_i2_i3(run, cells, s2=False):
    """Preemptions on every paired cell, accounting on the logged ones, and the clock fit on the serial ones."""
    lines, fits, attributed = [], [], {}
    for (arm, b), reqs in sorted(cells.items()):
        # The logging-off cells are the comparison I1 rests on, so a preemption there refuses as well.
        p = preemptions(run, arm, b)
        if p:
            raise Refusal(f"{arm}-{b}: {p:g} preemption(s) (gate I2)")
        if not arm.endswith("-log"):
            continue
        iters = measured_iters(run, arm, b, s2)
        if arm == "serial-log":
            # The same drained check iterlog.load_requests makes, because this loader does not go through it.
            by_send = sorted(reqs, key=lambda q: q["send_ms"])
            for p, q in zip(by_send, by_send[1:]):
                if q["send_ms"] < p["end_ms"]:
                    raise Refusal(f"{arm}-{b}: request {q['index']} was sent before request {p['index']} ended, so "
                                  f"the serial episode was not drained")
            att = iterlog.attribute_serial(iters, reqs)
            fits.append(iterlog.fit_clock(att))
            attributed[b] = att
    lines.append(f"I2 accounting: no failed request or preemption in any paired cell; contiguous iterations in every logged one")
    worst_res = max(f["worst_residual"] for f in fits)
    if s2:
        prefill_ok, more = frozen_clock(attributed)
        lines += more
    else:
        prefill_ok = worst_res <= COMPLETENESS
        lines.append(f"I3 clock: a {[round(f['a'], 3) for f in fits]} ms, b {[round(f['b'], 3) for f in fits]} ms per step, "
                     f"worst residual {worst_res:.4f} of TTFT")
    spread = []
    for f in fits:
        v = list(f["b_decode"].values())
        spread.append(max(v) - min(v))
    itl_med = statistics.median(x for (arm, _), rs in cells.items() if arm == "serial-log" for q in rs
                                if (x := itl(q)) is not None)
    lines.append(f"I3 decode: b' by length {[{k: round(v, 3) for k, v in f['b_decode'].items()} for f in fits]}, "
                 f"widest spread {max(spread):.3f} ms against a median inter-token time of {itl_med:.3f} ms")
    ok = prefill_ok and max(spread) <= COMPLETENESS * itl_med
    return ok, lines


def gate_i5(cells, arms=("serial-log", "serial-nolog")):
    """The first and last blocks' serial medians, per setting, on each of arms."""
    worst = (0.0, None)
    for arm in arms:
        first, last = by_setting("serial", cells[(arm, 1)], "ttft"), by_setting("serial", cells[(arm, 3)], "ttft")
        for s in first:
            d = abs(math.log(statistics.median(last[s]) / statistics.median(first[s])))
            worst = max(worst, (d, (arm,) + s), key=lambda w: w[0])
    return worst[0] <= STABILITY, f"I5 stability: worst first-to-last drift {worst[0]:.4f} at {worst[1]}"


def segment(iters, episodes):
    """Assign a drained cell's steps to its episodes, in order, by the context tokens each episode must schedule.

    The log has no request ids, so the only join is arithmetic: episode e schedules exactly sum(input tokens)
    context tokens, and because the engine is drained between episodes no step can carry two episodes' work.
    """
    out, i = [], 0
    for ep in episodes:
        need, mine = sum(q["input_tokens"] for q in ep), []
        while i < len(iters) and (need > 0 or iters[i]["ctx_tokens"] == 0):
            s = iters[i]
            if s["ctx_tokens"] > need:
                raise Refusal(f"iteration {s['index']} schedules {s['ctx_tokens']} context tokens and the episode "
                              f"has {need} left: two episodes overlap, so the cell was not drained")
            need -= s["ctx_tokens"]
            mine.append(s)
            i += 1
        if need:
            raise Refusal(f"the log ends with {need} context tokens of an episode unscheduled")
        out.append(mine)
    if i != len(iters):
        raise Refusal(f"{len(iters) - i} iteration(s) after the last episode belong to nothing in the trace")
    return out


def context_effect(run, s2=None):
    """I4, published: mean elapsed of pure decode steps at the same decoder count, short context against long."""
    by = {}
    for b in BLOCKS:
        reqs = load_cell(run, "burst-log", b)
        groups = []
        for q in reqs:
            if groups and groups[-1][0]["offset"] == q["offset"]:
                groups[-1].append(q)
            else:
                groups.append([q])
        iters = measured_iters(run, "burst-log", b, study_of(run) in WARM_STUDIES if s2 is None else s2)
        for ep, steps in zip(groups, segment(iters, groups)):
            n, L = len(ep), ep[0]["input_tokens"]
            by.setdefault((n, L), []).extend(s["elapsed_ms"] for s in steps
                                             if s["ctx_tokens"] == 0 and s["gen_reqs"] == n)
    lines = []
    for n in sorted({n for n, _ in by}):
        lens = sorted(L for m, L in by if m == n and by[(m, L)])
        if len(lens) < 2:
            continue
        lo, hi = statistics.fmean(by[(n, lens[0])]), statistics.fmean(by[(n, lens[-1])])
        lines.append(f"I4 context (published): {n} decoders, mean decode step {lo:.3f} ms at {lens[0]} tokens and "
                     f"{hi:.3f} ms at {lens[-1]}, {hi / lo - 1:+.2%}"
                     + ("; beyond 5%, the timing family needs a context term" if abs(hi / lo - 1) > 0.05 else ""))
    return lines


def check_warmup(run, arm, b):
    """W: the warm-up's last two requests, both drained 2,048-token requests, within 5% of 231 ms and 2% of each other."""
    path = os.path.join(run, f"raw-warmup-{arm}-{b}.jsonl")
    if not os.path.exists(path):
        raise Refusal(f"{arm}-{b}: no warm-up rows at {path} (gate W)")
    rows = sorted((json.loads(l) for l in open(path)), key=lambda r: r["sendUnixNanos"])[-2:]
    if len(rows) != 2 or any(r.get("errorKind") or r.get("engineInputTokens") != 2048 for r in rows):
        raise Refusal(f"{arm}-{b}: the warm-up's last two rows are not two successful 2,048-token requests (gate W)")
    t = [(r["firstTokenUnixNanos"] - r["sendUnixNanos"]) / 1e6 for r in rows]
    # "Within 2% of each other" is measured against the smaller, as the matrix measures it before the cell is bought.
    if any(abs(x / WARM_TTFT_MS - 1) > WARM_TOL for x in t) or (max(t) - min(t)) / min(t) > WARM_PAIR_TOL:
        raise Refusal(f"{arm}-{b}: verification TTFTs {t[0]:.1f} and {t[1]:.1f} ms are not both within 5% of "
                      f"{WARM_TTFT_MS:.0f} ms and 2% of each other (gate W)")


def warmup_stagger_episodes(run, arm, b, trailing=2):
    """The staggered cycle inside a staggered cell's warm-up, without the warm-up's single requests around it.

    The warm-up is one drained 2,048-token request, one cycle of the cell's episode type, then two drained 2,048-token
    verification requests (session 2's registration, section 2); the three are checked to be exactly that, so a
    warm-up of another shape refuses instead of being paired up as decoders and prefills.
    """
    # trailing is how many single requests close the warm-up: two verification requests, and from session 4 a
    # conditioning request before them.
    reqs = load_cell(run, arm, b, warmup=True)
    ends = reqs[:1] + reqs[-trailing:]
    if len(reqs) < 3 + trailing or any(q["input_tokens"] != 2048 or q["cap"] != 16 for q in ends) \
            or len({q["offset"] for q in ends}) != 1 + trailing or reqs[1]["offset"] == reqs[0]["offset"]:
        raise Refusal(f"{arm}-{b}: the warm-up is not one 2,048-token request, a staggered cycle and {trailing} closing "
                      f"2,048-token requests, so its staggered episodes cannot be located (gate S)")
    return reqs[1:-trailing]


def check_stagger(reqs, arm, b, fixed_length=False):
    """S: each prefill is sent after every decoder's first token and starts before any decoder has finished.

    fixed_length (session 3) also requires every decoder to have produced exactly its cap and stopped on it; session 2
    lost the composition because decoders capped at 512 stopped at end-of-sequence after as few as 101 tokens.
    """
    groups = []
    for q in reqs:
        if groups and groups[-1][0]["offset"] == q["offset"]:
            groups[-1].append(q)
        else:
            groups.append([q])
    for i in range(0, len(groups), 2):
        dec, pre = groups[i], groups[i + 1][0]
        if fixed_length:
            short = [d for d in dec if d["cap"] != S3_DECODER_TOKENS or d["output_tokens"] != S3_DECODER_TOKENS
                     or d["finish"] != "length"]
            if short:
                raise Refusal(f"{arm}-{b}: a decoder of the episode at offset {dec[0]['offset']} ms produced "
                              f"{short[0]['output_tokens']} of {short[0]['cap']} tokens and finished "
                              f"{short[0]['finish'] or 'without a reason'} (gate S)")
        if pre["send_ms"] <= max(d["first_ms"] for d in dec):
            raise Refusal(f"{arm}-{b}: the prefill at offset {pre['offset']} ms was sent before every decoder's first "
                          f"token, so the episode is not the registered composition (gate S)")
        if pre["first_ms"] >= min(d["end_ms"] for d in dec) - S_END_MARGIN_MS:
            raise Refusal(f"{arm}-{b}: a decoder of the episode at offset {dec[0]['offset']} ms finished before the "
                          f"prefill's first token (gate S)")


def evaluate(run, rng=None, logged=False):
    """The registered gates; logged=True is the logged-engine policy instead.

    logged=True is docs/superpowers/specs/2026-10-06-a-timing-family-for-the-logged-synchronous-engine.md: the logged
    engine is the system, so only the logged cells are read, I1 is not a gate (there is nothing unlogged to compare),
    and I5 is read on the logged serial arm. It is admitted only for session 4's design, the one session 5 bought,
    and it never changes what the default path prints.
    """
    rng = rng or random.Random(20261005)
    study = study_of(run)
    if study not in KNOWN_STUDIES:
        raise Refusal(f"study {study!r} is not one this evaluator was registered for, so it has no rules to judge it by")
    if logged and study != STUDY_S4:
        raise Refusal(f"the logged-engine policy is registered for {STUDY_S4}'s design only, not {study!r}")
    s2 = study in WARM_STUDIES
    s3 = study in FIXED_LENGTH_STUDIES
    trailing = 3 if study == STUDY_S4 else 2
    suffixes = ("log",) if logged else ("log", "nolog")
    cells = {}
    for kind in TYPES:
        for suffix in suffixes:
            for b in BLOCKS:
                cells[(f"{kind}-{suffix}", b)] = load_cell(run, f"{kind}-{suffix}", b)
    verdicts, lines = {}, []
    if s2:
        # W and S are refusals: a cell that was not warmed, or a staggered episode that was not the registered
        # composition, is not measured.
        # The async controls are held to them when present; the pre-purchase amendment dropped them from the
        # session, and that every planned arm came back is the session script's check, not this one's.
        asyncs = [f"{k}-async" for k in TYPES if os.path.exists(os.path.join(run, f"raw-{k}-async-1.jsonl"))]
        for kind in TYPES:
            for suffix in suffixes:
                for b in BLOCKS:
                    check_warmup(run, f"{kind}-{suffix}", b)
        for arm in asyncs:
            check_warmup(run, arm, 1)
        for suffix in suffixes:
            for b in BLOCKS:
                check_stagger(load_cell(run, f"stagger-{suffix}", b), f"stagger-{suffix}", b, fixed_length=s3)
                if s3:
                    # The warm-up's staggered episodes are held to S too: session 2's warm-up broke it as well.
                    check_stagger(warmup_stagger_episodes(run, f"stagger-{suffix}", b, trailing), f"stagger-{suffix} warm-up", b,
                                  fixed_length=True)
        if "stagger-async" in asyncs:
            check_stagger(load_cell(run, "stagger-async", 1), "stagger-async", 1, fixed_length=s3)
        lines.append(f"W warm-up and S staggered composition: every cell passes; async controls present: {asyncs or 'none'}")
    for kind in (() if logged else TYPES):
        for quantity in ("ttft", "itl"):
            mean = s2 and kind == "stagger" and quantity == "ttft"
            ok, line = gate_i1(cells, kind, quantity, rng, stat=statistics.fmean if mean else statistics.median)
            verdicts.setdefault("I1", []).append(ok)
            lines.append(line)
            if mean:
                ok, line = gate_i1(cells, kind, quantity, rng, stat=statistics.fmean, role="prefill", label=" prefill")
                verdicts["I1"].append(ok)
                lines.append(line)
    ok, more = gate_i2_i3(run, cells, s2)
    verdicts["I3"] = [ok]
    lines += more
    ok, line = gate_i5(cells, arms=("serial-log",) if logged else ("serial-log", "serial-nolog"))
    verdicts["I5"] = [ok]
    lines.append(line)
    lines += context_effect(run)
    passed = all(all(v) for v in verdicts.values())
    if logged:
        lines.append("logged-engine policy: I1 is not a gate" + ("; PASS: I2, I3 and I5 hold" if passed else
                     "; FAIL: " + ", ".join(k for k, v in verdicts.items() if not all(v))))
        return passed, lines
    lines.append("PASS: I1, I2, I3 and I5 hold" if passed else
                 "FAIL: " + ", ".join(k for k, v in verdicts.items() if not all(v)))
    return passed, lines


def _write_cell(run, arm, rep, reqs, log_lines, preempt=0, study=STUDY_S1):
    with open(os.path.join(run, f"trace-{arm}-{rep}.jsonl"), "w") as f:
        for q in reqs:
            f.write(json.dumps(dict(index=q["index"], offsetMs=q["offset"], tenant="premium-1",
                                    maxOutputTokens=q["cap"])) + "\n")
    with open(os.path.join(run, f"raw-{arm}-{rep}.jsonl"), "w") as f:
        for q in reqs:
            f.write(json.dumps(dict(index=q["index"], study=study, engineInputTokens=q["input_tokens"],
                                    engineOutputTokens=q["output_tokens"], sendUnixNanos=int(q["send"] * 1e6),
                                    firstTokenUnixNanos=int(q["first"] * 1e6), endUnixNanos=int(q["end"] * 1e6))) + "\n")
    with open(os.path.join(run, f"engine-log-{arm}-{rep}.txt"), "w") as f:
        f.write("\n".join(log_lines) + "\n")
    for which, v in (("before", 3), ("after", 3 + preempt)):
        with open(os.path.join(run, f"engine-metrics-{arm}-{rep}-{which}.prom"), "w") as f:
            f.write(f'vllm:num_preemptions_total{{engine="0"}} {v}\n')


def _synthetic_run(run, overhead=0.0, seed=7, context=0.0, s2=False, clock_c=CLOCK_C, dec_cap=128):
    """Nine paired cells whose truth is known: the logging-on cells are slower by the factor (1 + overhead).

    A burst's decode steps are slower by the factor (1 + context * L / 8192), so I4 has a known effect to find.
    """
    rng = random.Random(seed)
    for kind in TYPES:
        for suffix in ("log", "nolog"):
            for b in BLOCKS:
                scale = 1 + overhead if suffix == "log" else 1.0
                reqs, lines, t, idx, it = [], [], 0.0, 0, 100
                for cycle in range(3):
                    if kind == "serial":
                        eps = [[(L, c)] for L in (256, 2048, 8192) for c in (1, 16)]
                    elif kind == "burst":
                        eps = [[(L, 16)] * n for n in (1, 4) for L in (256, 8192)]
                    else:
                        eps = [[(c, dec_cap)] * n + [(p, 16)] for n in (1, 4) for c in (256, 8192) for p in (256, 8192)]
                    for ep in eps:
                        decs, rest = (ep[:-1], ep[-1:]) if kind == "stagger" else (ep, [])
                        for j, group in enumerate((decs, rest)):
                            for L, c in group:
                                k = math.ceil(L / 2048)
                                noise = 1 + rng.gauss(0, 0.002)
                                ctx = [10.0 * scale * noise * min(2048, L - j2 * 2048) / 2048 for j2 in range(k)]
                                if kind != "burst":
                                    for j2, ms in enumerate(ctx):
                                        lines.append(iterlog._line(it, 1, min(2048, L - j2 * 2048), 0, 0, ms)); it += 1
                                    for _ in range(c - 1):
                                        lines.append(iterlog._line(it, 0, 0, 1, 1, 13.3 * scale * noise)); it += 1
                                if s2:
                                    # Session 2's serial requests are generated by the frozen clock (with clock_c in
                                    # place of c, so a test can make the engine disagree with it).
                                    steps = [min(2048, L - j2 * 2048) for j2 in range(k)]
                                    ttft = sum(ctx) + CLOCK_A + sum(CLOCK_B + clock_c * p for p in steps)
                                else:
                                    ttft = 6.0 + sum(ctx) + 1.5 * k
                                send = t + (200 if j else 0)
                                reqs.append(dict(index=idx, offset=round(send), cap=c, input_tokens=L, output_tokens=c,
                                                 send=send, first=send + ttft,
                                                 end=send + ttft + (c - 1) * (13.3 * scale * noise + 1.5)))
                                idx += 1
                        if kind == "burst":
                            n, (L, c) = len(ep), ep[0]
                            left = n * L
                            while left:
                                chunk = min(2048, left)
                                lines.append(iterlog._line(it, 1, chunk, 0, 0, 10.0 * scale * chunk / 2048)); it += 1
                                left -= chunk
                            for _ in range(c - 1):
                                ms = 13.3 * scale * (1 + context * L / 8192) * (1 + rng.gauss(0, 0.002))
                                lines.append(iterlog._line(it, 0, 0, n, n, ms)); it += 1
                        t += 10_000
                if s2:
                    # Three warm-up iterations ahead of the measured ones, whose indices start at 100.
                    if suffix == "log":
                        # The warm-up's three 2,048-token requests are its only context steps, so the tokens before
                        # the boundary reconcile with raw-warmup's; the rest are its decode steps.
                        lines = ([iterlog._line(i, 1, 2048, 0, 0, 200.0) for i in range(3)]
                                 + [iterlog._line(i, 0, 0, 1, 1, 13.3) for i in range(3, 100)] + lines)
                    with open(os.path.join(run, f"warmup-boundary-{kind}-{suffix}-{b}.txt"), "w") as f:
                        f.write("99\n" if suffix == "log" else "none\n")
                    with open(os.path.join(run, f"raw-warmup-{kind}-{suffix}-{b}.jsonl"), "w") as f:
                        for i, ttft in enumerate((231.0, 230.0, 232.0)):
                            f.write(json.dumps(dict(index=i, engineInputTokens=2048, sendUnixNanos=int(i * 1e10),
                                                    firstTokenUnixNanos=int(i * 1e10 + ttft * 1e6))) + "\n")
                _write_cell(run, f"{kind}-{suffix}", b, reqs, lines, study=STUDY_S2 if s2 else STUDY_S1)


def _positional_bursts(run, seed=3):
    """Make each burst's TTFT grow with the request's admission position, in an order the engine picks at random.

    That is what a real burst does, and it is what the first I1 could not handle: with no overhead its burst interval
    was +/-14%.
    """
    rng = random.Random(seed)
    for suffix in ("log", "nolog"):
        for b in BLOCKS:
            offsets = {r["index"]: r["offsetMs"] for r in map(json.loads, open(os.path.join(run, f"trace-burst-{suffix}-{b}.jsonl")))}
            path = os.path.join(run, f"raw-burst-{suffix}-{b}.jsonl")
            raw = [json.loads(l) for l in open(path)]
            groups = {}
            for r in raw:
                groups.setdefault(offsets[r["index"]], []).append(r)
            for rs in groups.values():
                rng.shuffle(rs)
                for j, r in enumerate(rs):
                    base = r["firstTokenUnixNanos"] - r["sendUnixNanos"]
                    shift = int(base * (j + 1) * (1 + rng.gauss(0, 0.002))) - base
                    r["firstTokenUnixNanos"] += shift
                    r["endUnixNanos"] += shift
            with open(path, "w") as f:
                f.writelines(json.dumps(r) + "\n" for r in raw)


def _s2_run(run, asyncs=True, **kw):
    """A session-2 archive: the synthetic cells, with the async controls copied from each type's first unlogged cell."""
    import shutil
    _synthetic_run(run, s2=True, **kw)
    for kind in (TYPES if asyncs else ()):
        for name in os.listdir(run):
            if f"{kind}-nolog-1" in name:
                shutil.copy(os.path.join(run, name), os.path.join(run, name.replace(f"{kind}-nolog-1", f"{kind}-async-1")))


def _s3_run(run, short_decoder=False, short_warmup=False, dec_cap=S3_DECODER_TOKENS, study=STUDY_S3, conditioner=None):
    """A session-3 archive: session 2's, recorded under session 3, every decoder stopping on its cap.

    Each staggered cell gets a warm-up of the registered shape -- one 2,048-token request, one staggered episode, two
    verification requests -- and its logged cell a warm-up head whose context steps reconcile with those requests.
    """
    _s2_run(run, asyncs=False, dec_cap=dec_cap)
    for name in os.listdir(run):
        if name.startswith("raw-") and not name.startswith("raw-warmup-"):
            path = os.path.join(run, name)
            rows = [json.loads(l) for l in open(path)]
            for r in rows:
                r["study"] = study
                r["finishReason"] = "length"
            with open(path, "w") as f:
                f.writelines(json.dumps(r) + "\n" for r in rows)
    for suffix in ("log", "nolog"):
        for b in BLOCKS:
            arm = f"stagger-{suffix}"
            plan = [(0, 2048, 16, 0, 231.0, 300.0, "length"), (10_000, 256, 512, 0, 50.0, 9_000.0, "length"),
                    (10_200, 256, 16, 0, 60.0, 400.0, "length"), (20_000, 2048, 16, 0, 231.0, 300.0, "length"),
                    (30_000, 2048, 16, 0, 231.5, 300.0, "length")]
            if short_warmup and (suffix, b) == ("nolog", 2):
                plan[1] = (10_000, 256, 512, 0, 50.0, 100.0, "stop")
            # Session 4 puts a conditioning request between the cycle and the verification requests.
            if conditioner if conditioner is not None else study == STUDY_S4:
                plan.insert(3, (15_000, 2048, 16, 0, 233.0, 300.0, "length"))
            with open(os.path.join(run, f"warmup-trace-{arm}-{b}.jsonl"), "w") as f:
                f.writelines(json.dumps(dict(index=i, offsetMs=o, tenant="premium-1", maxOutputTokens=cap)) + "\n"
                             for i, (o, _, cap, *_) in enumerate(plan))
            with open(os.path.join(run, f"raw-warmup-{arm}-{b}.jsonl"), "w") as f:
                for i, (o, tok, cap, _, ttft, dur, fin) in enumerate(plan):
                    send = int(o * 1e6)
                    f.write(json.dumps(dict(index=i, study=study, engineInputTokens=tok,
                                            engineOutputTokens=cap if fin == "length" else cap // 3, finishReason=fin,
                                            sendUnixNanos=send, firstTokenUnixNanos=send + int(ttft * 1e6),
                                            endUnixNanos=send + int(dur * 1e6))) + "\n")
            if suffix == "log":
                path = os.path.join(run, f"engine-log-{arm}-{b}.txt")
                lines = open(path).read().splitlines()
                head = [iterlog._line(i, 1, tok, 0, 0, 10.0) for i, (_, tok, *_) in enumerate(plan)]
                head += [iterlog._line(i, 0, 0, 1, 1, 13.3) for i in range(len(head), 100)]
                with open(path, "w") as f:
                    f.write("\n".join(head + lines[100:]) + "\n")
    if short_decoder:
        path = os.path.join(run, "raw-stagger-log-3.jsonl")
        trace = {r["index"]: r for r in map(json.loads, open(os.path.join(run, "trace-stagger-log-3.jsonl")))}
        rows = [json.loads(l) for l in open(path)]
        r = next(r for r in rows if trace[r["index"]]["maxOutputTokens"] == S3_DECODER_TOKENS)
        r["finishReason"] = "stop"
        with open(path, "w") as f:
            f.writelines(json.dumps(x) + "\n" for x in rows)


def self_test_s4():
    """Session 4: session 3's paths with a conditioning request closing the warm-up's staggered cycle."""
    import tempfile
    with tempfile.TemporaryDirectory() as run:
        _s3_run(run, study=STUDY_S4)
        passed, lines = evaluate(run)
        assert passed, "\n".join(lines)
        print("ok: session 4, a warm-up with its conditioning request -> PASS")
    with tempfile.TemporaryDirectory() as run:
        _s3_run(run, study=STUDY_S4, conditioner=False)
        try:
            evaluate(run)
            raise AssertionError("a session-4 warm-up without its conditioning request was accepted")
        except Refusal as e:
            assert "cannot be located" in str(e), e
            print(f"ok: refuses a session-4 warm-up without its conditioning request -- {e}")
    # Staggered TTFT is compared by mean because a median can sit in either of two modes and ignore the other.
    # Slowing the episodes above each prefill setting's median leaves the median where it was and moves the mean,
    # so this fails only while the mean is the statistic; with the median put back it passes (issue 325).
    with tempfile.TemporaryDirectory() as run:
        _s3_run(run, study=STUDY_S4)
        for b in BLOCKS:
            keyed = settings("stagger", load_cell(run, "stagger-log", b))
            slow = set()
            for s in {s for s, _ in keyed if s[3] == "prefill"}:
                episodes = sorted((q for k, q in keyed if k == s), key=lambda q: q["ttft_ms"])
                assert len(episodes) >= 3, f"setting {s} has {len(episodes)} episodes, too few for a median to hold"
                slow |= {q["index"]: q["ttft_ms"] for q in episodes[len(episodes) // 2 + 1:]}.items()
            path = os.path.join(run, f"raw-stagger-log-{b}.jsonl")
            rows = [json.loads(l) for l in open(path)]
            for r in rows:
                for index, ttft in slow:
                    if r["index"] == index:
                        r["firstTokenUnixNanos"] += int(0.4 * ttft * 1e6)
                        r["endUnixNanos"] += int(0.4 * ttft * 1e6)
            with open(path, "w") as f:
                f.writelines(json.dumps(r) + "\n" for r in rows)
        passed, lines = evaluate(run)
        prefill = next(l for l in lines if l.startswith("I1 stagger") and " prefill:" in l)
        # The point estimate, not the verdict: a median's bootstrap also widens past 2% when it draws a slowed
        # episode, so "it failed" held with the median put back.
        # Both comparisons are pinned: the prefill role's pooled mean, and the worst setting of all staggered roles.
        whole = next(l for l in lines if l.startswith("I1 stagger ttft:"))
        point = float(prefill.split("mean d ")[1].split(",")[0])
        worst = float(whole.rsplit(" ", 1)[1])
        assert not passed and point > 0.1 and worst > 0.1, (prefill, whole)
        print(f"ok: slowing the episodes above the median moves the staggered prefill's mean -> FAIL: {prefill}")
    # check_design hands every trace to the Go check and refuses on the first it rejects; a stub stands in for the
    # harness, rejecting one trace, so what is pinned is the wiring (the Go refusals have their own tests).
    with tempfile.TemporaryDirectory() as run:
        _s3_run(run, study=STUDY_S4)
        stub = os.path.join(run, "stub-harness")
        with open(stub, "w") as f:
            f.write('#!/bin/sh\ncase "$*" in *trace-burst-log-2.jsonl*) echo "error: a setting is missing" >&2; exit 1;; esac\n')
        os.chmod(stub, 0o755)
        try:
            check_design(run, stub)
            raise AssertionError("a trace the design check rejected was accepted")
        except Refusal as e:
            assert "trace-burst-log-2.jsonl" in str(e) and "a setting is missing" in str(e), e
            print(f"ok: refuses an archive one of whose traces the design check rejects -- {e}")
        # And the command line runs it: a check nothing calls would leave the test above green.
        import subprocess
        env = dict(os.environ, BENCHHARNESS=stub)
        p = subprocess.run([sys.executable, os.path.abspath(__file__), run], env=env, capture_output=True, text=True)
        assert p.returncode != 0 and "trace-burst-log-2.jsonl" in p.stderr, (p.returncode, p.stderr[-300:])
        env.pop("BENCHHARNESS")
        p = subprocess.run([sys.executable, os.path.abspath(__file__), run], env=env, capture_output=True, text=True)
        assert p.returncode != 0 and "set BENCHHARNESS" in p.stderr, (p.returncode, p.stderr[-300:])
        print("ok: the command line runs the design check, and refuses without a harness to run it with")
    # An archive that stopped before its last cell, as session 3's did.
    with tempfile.TemporaryDirectory() as run:
        _s3_run(run, study=STUDY_S4)
        os.remove(os.path.join(run, "raw-stagger-nolog-3.jsonl"))
        try:
            evaluate(run)
            raise AssertionError("an archive missing a cell was judged")
        except Refusal as e:
            assert "raw-stagger-nolog-3.jsonl is missing" in str(e), e
            print(f"ok: refuses an archive missing a cell -- {e}")
    # The logged-engine policy reads only the logged cells: with every unlogged file deleted it still passes, and it
    # prints no I1, because the logged engine is the system and there is nothing unlogged to compare it with.
    with tempfile.TemporaryDirectory() as run:
        _s3_run(run, study=STUDY_S4)
        for name in os.listdir(run):
            if "-nolog-" in name:
                os.remove(os.path.join(run, name))
        passed, lines = evaluate(run, logged=True)
        assert passed and not any(l.startswith("I1 ") for l in lines), lines
        assert lines[-1] == "logged-engine policy: I1 is not a gate; PASS: I2, I3 and I5 hold", lines[-1]
        print(f"ok: the logged-engine policy passes on logged cells alone -- {lines[-1]}")
    # Its I5 is still a gate: drift between the first and last block's logged serial cells fails it.
    with tempfile.TemporaryDirectory() as run:
        _s3_run(run, study=STUDY_S4)
        path = os.path.join(run, "raw-serial-log-3.jsonl")
        rows = [json.loads(l) for l in open(path)]
        for r in rows:
            r["firstTokenUnixNanos"] += int(0.1 * (r["firstTokenUnixNanos"] - r["sendUnixNanos"]))
        with open(path, "w") as f:
            f.writelines(json.dumps(r) + "\n" for r in rows)
        passed, lines = evaluate(run, logged=True)
        assert not passed and "I5" in lines[-1], lines[-1]
        print(f"ok: the logged-engine policy fails a 10% first-to-last drift -- {lines[-1]}")
    with tempfile.TemporaryDirectory() as run:
        _s3_run(run, study=STUDY_S3)
        try:
            evaluate(run, logged=True)
            raise AssertionError("the logged-engine policy judged a study it is not registered for")
        except Refusal as e:
            assert "registered for" in str(e), e
            print(f"ok: the logged-engine policy refuses another study -- {e}")
    # Provenance: the manifests' image and revision and the engine's applied flags, per logged cell.
    image, rev = go_const("InputLengthServingImage"), go_const("InputLengthTokenizerRevision")
    arms = [f"{k}-log" for k in TYPES]

    def provenance_files(run, drop_flag=None, digest=image):
        timings = ["cell\tarm\trep"]
        applied = ["cell\tarm\tdeploy\tstage\tsource\tvalue"]
        for i, (arm, b) in enumerate([(a, b) for b in BLOCKS for a in arms], 1):
            timings.append(f"{i}\t{arm}\t{b}")
            args = ["Qwen/Qwen2.5-3B-Instruct", "--no-async-scheduling", f"--revision={rev}",
                    f"--tokenizer-revision={rev}", "--enable-logging-iteration-details"]
            if (arm, b) == drop_flag:
                args.remove("--enable-logging-iteration-details")
            applied.append(f"{i}\t{arm}\tvllm-qwen25-3b\tapplied\tdeploy/vllm-qwen25-3b\t{json.dumps(args)}")
            for kind in ("manifest", "warmup-manifest"):
                with open(os.path.join(run, f"{kind}-{arm}-{b}.yaml"), "w") as f:
                    f.write(f"arm: {arm}\nimageDigests:\n  engine: {digest}\nseed: 11\nstudy: {STUDY_S4}\n"
                            f"tokenizerRev: {rev}\n")
        for name, rows in (("cell-timings.tsv", timings), ("applied-values.tsv", applied)):
            with open(os.path.join(run, name), "w") as f:
                f.write("\n".join(rows) + "\n")

    for what, kw, words in [(None, {}, None),
                            ("a logged cell whose engine ran without the logging flag",
                             dict(drop_flag=("burst-log", 2)), "missing ['--enable-logging-iteration-details']"),
                            ("a cell whose manifest names another engine image",
                             dict(digest="vllm/vllm-openai@sha256:" + "0" * 64), "imageDigests.engine")]:
        with tempfile.TemporaryDirectory() as run:
            _s3_run(run, study=STUDY_S4)
            provenance_files(run, **kw)
            try:
                line = check_provenance(run, arms)
                assert what is None, f"{what} was accepted"
                print(f"ok: provenance of nine logged cells with their registered engine -- {line}")
            except Refusal as e:
                assert what is not None and words in str(e), e
                print(f"ok: refuses {what} -- {e}")
    # Warm-up design: a stub gen-trace that writes back the archive's own warm-up, so only a changed one differs.
    with tempfile.TemporaryDirectory() as run:
        _s3_run(run, study=STUDY_S4)
        provenance_files(run)
        stub = os.path.join(run, "stub-gen-trace")
        with open(stub, "w") as f:
            f.write('#!/bin/sh\narm=""; out=""\nwhile [ $# -gt 0 ]; do case "$1" in --arm) arm="$2";; '
                    '--trace-out) out="$2";; esac; shift; done\n'
                    f'cp "{run}/warmup-trace-$arm-1.jsonl" "$out"\n')
        os.chmod(stub, 0o755)
        for name in os.listdir(run):
            if name.startswith("warmup-trace-") and "-nolog-" in name:
                os.remove(os.path.join(run, name))
        line = check_warmup_design(run, stub)
        print(f"ok: warm-ups that match their regeneration pass -- {line}")
        path = os.path.join(run, "warmup-trace-stagger-log-3.jsonl")
        rows = open(path).read().splitlines()
        with open(path, "w") as f:
            f.write("\n".join(rows[:-1]) + "\n")
        try:
            check_warmup_design(run, stub)
            raise AssertionError("a warm-up trace missing its last row was accepted")
        except Refusal as e:
            assert "warmup-trace-stagger-log-3.jsonl is not the warm-up" in str(e), e
            print(f"ok: refuses a warm-up trace that is not its regeneration -- {e}")
    with tempfile.TemporaryDirectory() as run:
        _s3_run(run, study=STUDY_S4)
        for name in os.listdir(run):
            if "-nolog-" in name:
                os.remove(os.path.join(run, name))
        try:
            check_archive(run, "unused", logged=True)
            raise AssertionError("a logged-only archive reached the paired design check")
        except Refusal as e:
            assert "logged-only archive needs the logged-engine study" in str(e), e
            print(f"ok: a logged-only archive is refused by name until its study exists -- {e}")
    # A session-4 archive that would pass, relabelled with a study no rule here was registered for.
    with tempfile.TemporaryDirectory() as run:
        _s3_run(run, study="instrument-validation-unregistered", conditioner=True)
        try:
            evaluate(run)
            raise AssertionError("an unregistered study was judged")
        except Refusal as e:
            assert "not one this evaluator was registered for" in str(e), e
            print(f"ok: refuses a study it has no rules for -- {e}")


def self_test_s3():
    """Session 3: every session-2 path, plus fixed-length decoders and S on the warm-up's staggered episode."""
    import tempfile
    with tempfile.TemporaryDirectory() as run:
        _s3_run(run)
        passed, lines = evaluate(run)
        assert passed, "\n".join(lines)
        print("ok: session 3, decoders at their caps and a warm-up of the registered shape -> PASS")
    for what, kw, words in [("a measured decoder that stopped on end-of-sequence", dict(short_decoder=True), "finished stop"),
                            ("decoders capped at 128 that reached their cap", dict(dec_cap=128), "128 of 128"),
                            ("a warm-up decoder that stopped early", dict(short_warmup=True), "warm-up-2")]:
        with tempfile.TemporaryDirectory() as run:
            _s3_run(run, **kw)
            try:
                evaluate(run)
            except Refusal as e:
                assert words in str(e) and "(gate S)" in str(e), e
                print(f"ok: refuses {what} -- {e}")
                continue
            raise AssertionError(f"{what} was accepted")


def self_test_s2():
    """Session 2's paths: the frozen clock, W, S and the warm-up boundary, each shown to fire."""
    import tempfile
    with tempfile.TemporaryDirectory() as run:
        _s2_run(run)
        passed, lines = evaluate(run)
        assert passed, "\n".join(lines)
        assert any("I3 frozen clock" in l for l in lines) and any(" prefill:" in l for l in lines), lines
        print("ok: session 2, an engine the frozen clock describes -> PASS, with the prefill role judged on its own")
    with tempfile.TemporaryDirectory() as run:
        _s2_run(run, asyncs=False)
        passed, lines = evaluate(run)
        assert passed and any("async controls present: none" in l for l in lines), lines
        print("ok: session 2 without the async controls -> PASS, and the output says they are absent")
    with tempfile.TemporaryDirectory() as run:
        _s2_run(run, clock_c=3 * CLOCK_C)
        passed, lines = evaluate(run)
        assert not passed and "I3" in lines[-1], lines[-1]
        print(f"ok: an engine whose per-token cost is three times the frozen c -> {lines[-1]}")

    def refused(what, prepare, words):
        with tempfile.TemporaryDirectory() as run:
            _s2_run(run)
            prepare(run)
            try:
                evaluate(run)
            except Refusal as e:
                assert words in str(e), e
                print(f"ok: refuses {what} -- {e}")
                return
            raise AssertionError(f"{what} was accepted")

    def rewrite(run, name, f):
        path = os.path.join(run, name)
        rows = [json.loads(l) for l in open(path)]
        f(rows)
        with open(path, "w") as out:
            out.writelines(json.dumps(r) + "\n" for r in rows)

    refused("a slow verification request",
            lambda run: rewrite(run, "raw-warmup-burst-log-2.jsonl",
                                lambda rows: rows[-1].update(firstTokenUnixNanos=rows[-1]["sendUnixNanos"] + int(260e6))),
            "(gate W)")
    refused("a cold async control",
            lambda run: rewrite(run, "raw-warmup-serial-async-1.jsonl",
                                lambda rows: rows[-2].update(firstTokenUnixNanos=rows[-2]["sendUnixNanos"] + int(455e6))),
            "(gate W)")

    def early_prefill(run):
        trace = {r["index"]: r for r in map(json.loads, open(os.path.join(run, "trace-stagger-nolog-3.jsonl")))}
        prefill = next(i for i, r in trace.items() if r["maxOutputTokens"] == 16)
        rewrite(run, "raw-stagger-nolog-3.jsonl",
                lambda rows: next(r for r in rows if r["index"] == prefill).update(sendUnixNanos=0))
    refused("a prefill sent before its decoders' first tokens", early_prefill, "(gate S)")
    refused("a missing warm-up boundary",
            lambda run: os.remove(os.path.join(run, "warmup-boundary-serial-log-1.txt")), "is missing")
    def drop_head(run):
        path = os.path.join(run, "engine-log-serial-log-2.txt")
        lines = open(path).read().splitlines()
        with open(path, "w") as f:
            f.write("\n".join(lines[2:]) + "\n")
    refused("a log missing the head of its warm-up", drop_head, "part of the warm-up is missing")

    # A request that stopped early at EOS keeps its registered setting: frozen_clock groups by the trace's cap.
    def req(cap, out):
        steps = [256]
        ttft = 10.0 + CLOCK_A + CLOCK_B + CLOCK_C * 256
        return dict(input_tokens=256, k=1, ctx_ms=[10.0], ttft_ms=ttft, cap=cap, output_tokens=out)
    _, lines = frozen_clock({b: [req(16, 16), req(16, 16), req(16, 15)] for b in BLOCKS})
    assert any("(256, 16)" in l for l in lines) and not any("(256, 15)" in l for l in lines), lines
    print("ok: a request that stopped early at EOS stays in its registered (length, cap) setting")
    refused("a warm-up whose tokens the log does not schedule before the boundary",
            lambda run: rewrite(run, "raw-warmup-serial-log-3.jsonl", lambda rows: rows[0].update(engineInputTokens=4096)),
            "does not separate the warm-up")

    def prefill_at_decoder_end(run):
        # The prefill's first token half a millisecond before a decoder's stream end: inside the termination delay.
        trace = {r["index"]: r for r in map(json.loads, open(os.path.join(run, "trace-stagger-log-2.jsonl")))}
        rows = [json.loads(l) for l in open(os.path.join(run, "raw-stagger-log-2.jsonl"))]
        pre = next(r for r in rows if trace[r["index"]]["maxOutputTokens"] == 16)
        off = trace[pre["index"]]["offsetMs"]
        dec = [r for r in rows if trace[r["index"]]["maxOutputTokens"] == 128 and off - 1000 < trace[r["index"]]["offsetMs"] < off]
        dec[0]["endUnixNanos"] = pre["firstTokenUnixNanos"] + int(0.5e6)
        with open(os.path.join(run, "raw-stagger-log-2.jsonl"), "w") as f:
            f.writelines(json.dumps(r) + "\n" for r in rows)
    refused("a prefill whose first token falls inside a decoder's termination delay", prefill_at_decoder_end, "(gate S)")
    refused("a boundary that is not in the log",
            lambda run: open(os.path.join(run, "warmup-boundary-burst-log-3.txt"), "w").write("4242\n"),
            "is not an iteration in the captured log")


def self_test():
    import tempfile
    self_test_s4()
    self_test_s3()
    self_test_s2()
    with tempfile.TemporaryDirectory() as run:
        _synthetic_run(run)
        _positional_bursts(run)
        cells = {(f"burst-{x}", b): load_cell(run, f"burst-{x}", b) for x in ("log", "nolog") for b in BLOCKS}
        ok, line = gate_i1(cells, "burst", "ttft", random.Random(1))
        assert ok, line
        print(f"ok: bursts whose TTFT grows with admission position, no overhead -> PASS: {line}")
    with tempfile.TemporaryDirectory() as run:
        # The review's case: whole cycles scaled alike in both arms, here by exp(-0.04), 1 and exp(0.04).
        # Resampled by episode the interval is about +/-2.7% and fails; resampled rank by rank it narrows to about
        # +/-1.4% and passes, because ten ranks that move together are counted as ten independent draws.
        # The size is chosen so the two methods land on opposite sides of the 2% bound in this ten-setting archive.
        _synthetic_run(run)
        _positional_bursts(run)
        for suffix in ("log", "nolog"):
            for b in BLOCKS:
                path = os.path.join(run, f"raw-burst-{suffix}-{b}.jsonl")
                trace = {r["index"]: r["offsetMs"] for r in map(json.loads, open(os.path.join(run, f"trace-burst-{suffix}-{b}.jsonl")))}
                cycle_of = {o: i * 3 // len(set(trace.values())) for i, o in enumerate(sorted(set(trace.values())))}
                rows = [json.loads(l) for l in open(path)]
                for r in rows:
                    scale = math.exp(0.04 * (cycle_of[trace[r["index"]]] - 1))
                    base = r["firstTokenUnixNanos"] - r["sendUnixNanos"]
                    r["firstTokenUnixNanos"] += int(base * scale) - base
                with open(path, "w") as f:
                    f.writelines(json.dumps(r) + "\n" for r in rows)
        cells = {(f"burst-{x}", b): load_cell(run, f"burst-{x}", b) for x in ("log", "nolog") for b in BLOCKS}
        ok, line = gate_i1(cells, "burst", "ttft", random.Random(1))
        assert not ok, line
        print(f"ok: whole cycles scaled by exp(+/-0.04) -> FAIL, the interval kept wide: {line}")
    with tempfile.TemporaryDirectory() as run:
        _synthetic_run(run)
        passed, lines = evaluate(run)
        print("\n".join(lines))
        assert passed, "a null overhead failed"
        print("ok: no overhead -> PASS")
        assert not any("context term" in l for l in lines), lines
    with tempfile.TemporaryDirectory() as run:
        _synthetic_run(run, context=0.10)
        passed, lines = evaluate(run)
        i4 = [l for l in lines if l.startswith("I4")]
        # The truth is 1.10 / (1 + 0.10 * 256 / 8192) - 1 = +9.66%, not +10%: the short context carries a little too.
        assert i4 and all(("+9.6" in l or "+9.7" in l) and "context term" in l for l in i4), i4
        print(f"ok: a 10% context effect is published: {i4[-1]}")
    with tempfile.TemporaryDirectory() as run:
        _synthetic_run(run)
        path = os.path.join(run, "engine-log-burst-log-2.txt")
        ls = open(path).read().splitlines()
        ls = [l.replace("1 context requests, 2048 context tokens", "1 context requests, 2304 context tokens", 1)
              if "2048 context tokens" in l else l for l in ls]
        with open(path, "w") as f:
            f.write("\n".join(ls) + "\n")
        try:
            evaluate(run)
            raise AssertionError("a step spanning two episodes was accepted")
        except Refusal as e:
            # The overlap refusal itself, by its words: without the check the walk overruns and a later refusal
            # ("the log ends with -1024 context tokens") fires instead, which kept this test green with no check.
            assert "two episodes overlap" in str(e), e
            print(f"ok: refuses a step spanning two burst episodes -- {e}")
    with tempfile.TemporaryDirectory() as run:
        _synthetic_run(run, overhead=0.04)
        passed, lines = evaluate(run)
        assert not passed and lines[-1].startswith("FAIL") and "I1" in lines[-1], lines
        print("ok: a 4% logging overhead -> FAIL on I1")
    with tempfile.TemporaryDirectory() as run:
        _synthetic_run(run)
        os.remove(os.path.join(run, "engine-metrics-burst-log-2-after.prom"))
        try:
            evaluate(run)
            raise AssertionError("an unreadable preemption counter was read as zero")
        except Refusal as e:
            print(f"ok: refuses an unreadable preemption counter -- {e}")
    with tempfile.TemporaryDirectory() as run:
        _synthetic_run(run)
        with open(os.path.join(run, "engine-metrics-stagger-log-3-after.prom"), "w") as f:
            f.write('vllm:num_preemptions_total{engine="0"} 4\n')
        try:
            evaluate(run)
            raise AssertionError("a preemption was accepted")
        except Refusal as e:
            print(f"ok: refuses a preemption -- {e}")
    def refused(what, prepare, words):
        with tempfile.TemporaryDirectory() as run:
            _synthetic_run(run)
            prepare(run)
            try:
                evaluate(run)
            except Refusal as e:
                assert words in str(e), e
                print(f"ok: refuses {what} -- {e}")
                return
            raise AssertionError(f"{what} was accepted")

    def write(run, name, text):
        with open(os.path.join(run, name), "w") as f:
            f.write(text)

    def drop_setting(run):
        for arm in ("burst-log", "burst-nolog"):
            trace = [json.loads(l) for l in open(os.path.join(run, f"trace-{arm}-2.jsonl"))]
            raw = [json.loads(l) for l in open(os.path.join(run, f"raw-{arm}-2.jsonl"))]
            gone = {r["index"] for r in raw if r["engineInputTokens"] == 8192}
            write(run, f"trace-{arm}-2.jsonl", "".join(json.dumps(r) + "\n" for r in trace if r["index"] not in gone))
            write(run, f"raw-{arm}-2.jsonl", "".join(json.dumps(r) + "\n" for r in raw if r["index"] not in gone))

    refused("a setting missing from both cells of one block", drop_setting, "settings missing from some cell")
    refused("a scrape without the preemption counter",
            lambda run: write(run, "engine-metrics-serial-log-1-after.prom", "vllm:other_total 1\n"),
            "no vllm:num_preemptions_total sample")
    refused("a preemption in a logging-off cell",
            lambda run: write(run, "engine-metrics-serial-nolog-2-after.prom",
                              'vllm:num_preemptions_total{engine="0"} 5\n'), "serial-nolog-2: 2 preemption(s)")
    with tempfile.TemporaryDirectory() as run:
        _synthetic_run(run)
        path = os.path.join(run, "raw-serial-log-1.jsonl")
        rows = [json.loads(l) for l in open(path)]
        rows[5]["sendUnixNanos"] = rows[4]["endUnixNanos"] - 1
        with open(path, "w") as f:
            f.writelines(json.dumps(r) + "\n" for r in rows)
        try:
            evaluate(run)
            raise AssertionError("an undrained serial episode was accepted")
        except Refusal as e:
            print(f"ok: refuses an undrained serial episode -- {e}")
    with tempfile.TemporaryDirectory() as run:
        _synthetic_run(run)
        _ = [l for l in open(os.path.join(run, "raw-serial-nolog-2.jsonl"))]
        with open(os.path.join(run, "raw-serial-nolog-2.jsonl"), "w") as f:
            f.writelines(_[:-1])
        try:
            evaluate(run)
            raise AssertionError("a lost request was accepted")
        except Refusal as e:
            print(f"ok: refuses a lost request -- {e}")


def check_design(run, harness):
    """Refuse an archive any of whose traces is not the matrix its study registers, by the Go check the plan passed.

    evaluate() compares cells with each other, so an archive missing a setting from every cell alike (every 64-request
    burst, say) passed it (found by review, issue 326). The registered matrix lives in internal/bench/episodes.go, and
    re-running that check here, rather than mirroring the design in Python, keeps one definition of it.
    The self-tests' synthetic archives are not registered matrices, so this runs on real archives only, from main.
    """
    import subprocess
    study = study_of(run)
    traces = sorted(n for n in os.listdir(run) if n.startswith("trace-") and n.endswith(".jsonl"))
    arms = sorted({n[len("trace-"):].rsplit("-", 1)[0] for n in traces})
    if not traces:
        raise Refusal(f"{run} holds no trace-*.jsonl, so its matrix cannot be checked against the registration")
    for n in traces:
        arm = n[len("trace-"):].rsplit("-", 1)[0]
        p = subprocess.run([harness, "matrix-plan-check", "--trace", os.path.join(run, n), "--study", study,
                            "--arm", arm, "--arms", " ".join(arms)], capture_output=True, text=True)
        if p.returncode != 0:
            raise Refusal(f"{n} is not the matrix {study} registers: {(p.stderr or p.stdout).strip()}")
    return f"Design: all {len(traces)} traces are the matrix {study} registers (matrix-plan-check)"


REPO = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))


def go_const(name):
    """A string constant of internal/bench/inputlengths.go, read from the source so the pin has one definition."""
    import re
    src = open(os.path.join(REPO, "internal", "bench", "inputlengths.go")).read()
    m = re.search(rf'^const {name} = "([^"]+)"$', src, re.M)
    if not m:
        raise Refusal(f"internal/bench/inputlengths.go has no string constant {name}, so the pin cannot be read")
    return m.group(1)


def manifest_fields(path):
    """The flat and one-level-nested scalar fields of a gen-trace manifest, which is all provenance needs."""
    out, parent = {}, None
    for line in open(path):
        if not line.strip() or ":" not in line:
            continue
        key, _, val = line.rstrip("\n").partition(":")
        if not line.startswith(" "):
            parent = key.strip()
            if val.strip():
                out[parent] = val.strip().strip('"')
        elif parent:
            out[f"{parent}.{key.strip()}"] = val.strip().strip('"')
    return out


def check_warmup_design(run, harness):
    """Refuse a warm-up trace that is not what the generator makes from the cell's recorded seed.

    The Go plan check scores measured traces only, so before this a warm-up could have been anything W and S did
    not happen to read (found by review). Regenerating it with gen-trace --warmup, from the seed its own manifest
    records and the warm-up length hack/lib/instrument-validation.sh defines, and comparing bytes, keeps the
    generator the one definition of a warm-up.
    """
    import subprocess, tempfile
    study = study_of(run)
    lib = os.path.join(REPO, "hack", "lib", "instrument-validation.sh")
    names = sorted(n for n in os.listdir(run) if n.startswith("warmup-trace-") and n.endswith(".jsonl"))
    if not names:
        raise Refusal(f"{run} holds no warmup-trace-*.jsonl, so its warm-ups cannot be checked")
    with tempfile.TemporaryDirectory() as tmp:
        for n in names:
            cell = n[len("warmup-trace-"):-len(".jsonl")]
            arm = cell.rsplit("-", 1)[0]
            seed = manifest_fields(os.path.join(run, f"warmup-manifest-{cell}.yaml")).get("seed")
            dur = subprocess.run(["bash", "-c", f'source "$0"; iv_warmup_duration_ms "$1" "$2"', lib, study, arm],
                                 capture_output=True, text=True)
            if dur.returncode != 0 or not seed:
                raise Refusal(f"{n}: no warm-up length or seed to regenerate it from: {dur.stdout.strip()} {dur.stderr.strip()}")
            out = os.path.join(tmp, n)
            p = subprocess.run([harness, "gen-trace", "--warmup", "--seed", seed, "--duration-ms", dur.stdout.strip(),
                                "--study", study, "--arm", arm, "--model", "Qwen/Qwen2.5-3B-Instruct",
                                "--gateway-url", "http://127.0.0.1:18080", "--timeout-ms", "60000",
                                "--trace-out", out, "--manifest-out", out + ".yaml"], capture_output=True, text=True)
            if p.returncode != 0:
                raise Refusal(f"{n}: gen-trace --warmup could not regenerate it: {(p.stderr or p.stdout).strip()[-300:]}")
            if open(out, "rb").read() != open(os.path.join(run, n), "rb").read():
                raise Refusal(f"{n} is not the warm-up gen-trace makes from seed {seed}, so it is not the registered warm-up")
    return f"Design: all {len(names)} warm-up traces are what gen-trace --warmup makes from their recorded seeds"


def check_provenance(run, arms):
    """Refuse a cell whose engine image, model revision or engine flags are not the registered ones.

    A study string in the rows says which rules apply; it does not say which engine produced them. The manifests
    record the image digest and tokenizer revision gen-trace was told, and applied-values.tsv records the flags the
    engine Deployment actually carried, keyed by cell number, which cell-timings.tsv maps to an arm and block.
    """
    image, rev = go_const("InputLengthServingImage"), go_const("InputLengthTokenizerRevision")
    study = study_of(run)
    for arm in arms:
        for b in BLOCKS:
            for kind in ("manifest", "warmup-manifest"):
                path = os.path.join(run, f"{kind}-{arm}-{b}.yaml")
                if not os.path.exists(path):
                    raise Refusal(f"{arm}-{b}: {kind}-{arm}-{b}.yaml is missing, so the cell's provenance is unknown")
                m = manifest_fields(path)
                for key, want in (("study", study), ("tokenizerRev", rev), ("imageDigests.engine", image)):
                    if m.get(key) != want:
                        raise Refusal(f"{arm}-{b}: {kind} records {key} {m.get(key)!r}, not the registered {want!r}")
    cell_of = {}
    for row in list(map(lambda l: l.rstrip("\n").split("\t"), open(os.path.join(run, "cell-timings.tsv"))))[1:]:
        cell_of[(row[1], int(row[2]))] = row[0]
    applied = {}
    for row in list(map(lambda l: l.rstrip("\n").split("\t"), open(os.path.join(run, "applied-values.tsv"))))[1:]:
        if len(row) == 6 and row[3] == "applied" and row[2].startswith("vllm"):
            applied[row[0]] = json.loads(row[5])
    for arm in arms:
        for b in BLOCKS:
            args = applied.get(cell_of.get((arm, b)))
            if args is None:
                raise Refusal(f"{arm}-{b}: applied-values.tsv has no applied engine arguments for it")
            want = {"--no-async-scheduling", f"--revision={rev}", f"--tokenizer-revision={rev}"}
            if arm.endswith("-log"):
                want.add("--enable-logging-iteration-details")
            missing = sorted(want - set(args))
            if missing or (not arm.endswith("-log") and "--enable-logging-iteration-details" in args):
                raise Refusal(f"{arm}-{b}: the engine ran with {args}, missing {missing} or logging where none is registered")
    return f"Provenance: {len(arms) * len(BLOCKS)} cells ran {image.split('@')[1][:19]}, revision {rev[:12]}, with their registered flags"


def check_archive(run, harness, logged=False):
    """Every check an archive passes before a gate is read; the command line and timing_fit both go through it."""
    arms = [f"{k}-log" for k in TYPES] if logged else [f"{k}-{s}" for k in TYPES for s in ("log", "nolog")]
    # The Go plan check admits the logged arms only beside their unlogged pairs, so a logged-only archive -- which
    # only the logged-engine registration's confirmatory session would make -- is refused here by name rather than
    # by a matrix error. Its study is section 8 item 1 of that registration, built only after a passing pilot.
    if logged and not any(n.startswith("trace-") and "-nolog-" in n for n in os.listdir(run)):
        raise Refusal("a logged-only archive needs the logged-engine study registered in internal/bench (section 8 "
                      "item 1 of the 2026-10-06 logged-engine registration), which is built only after a passing pilot")
    lines = [check_design(run, harness)]
    if study_of(run) in WARM_STUDIES:
        lines.append(check_warmup_design(run, harness))
    if logged:
        lines.append(check_provenance(run, arms))
    return lines


if __name__ == "__main__":
    try:
        if sys.argv[1:] == ["--self-test"]:
            self_test()
        elif len(sys.argv) == 2:
            # BENCHHARNESS names a built cmd/benchharness; it is required rather than skipped when absent, because a
            # design check that quietly did not run reads exactly like one that passed.
            harness = os.environ.get("BENCHHARNESS")
            if not harness:
                raise Refusal("set BENCHHARNESS to a built cmd/benchharness: the archive's traces are checked against "
                              "the registered matrix before any gate is read")
            print("\n".join(check_archive(sys.argv[1], harness)))
            passed, lines = evaluate(sys.argv[1])
            print("\n".join(lines))
            sys.exit(0 if passed else 1)
        else:
            sys.exit(__doc__)
    except Refusal as e:
        sys.exit(f"REFUSED: {e}")
