"""Per-iteration records of a stock vLLM v0.27.1 engine, attributed to requests and checked against the client.

Registered in docs/superpowers/specs/2026-10-05-can-the-stock-engine-time-an-iteration-instrument-validation.md.
The engine logs one line per step under --enable-logging-iteration-details, and the line carries no request id,
so a request's steps can be recovered only where the traffic makes them unambiguous: a drained serial episode.

    python3 iterlog.py --self-test
    python3 iterlog.py ENGINE_LOG RAW_ROWS.jsonl     # serial cells only
"""

import json
import math
import os
import re
import statistics
import sys

BUDGET = 2048

# The format string of LoggingStatLogger._log_iteration_details at v0.27.1 (vllm/v1/metrics/loggers.py:182-196).
# The engine prefix is optional because a single-engine logger may print it or not.
LINE = re.compile(
    r"(?:Engine \d{3}: )?Iteration\((\d+)\): (\d+) context requests, (\d+) context tokens, "
    r"(\d+) generation requests, (\d+) generation tokens, iteration elapsed time: ([0-9.]+) ms( \(dummy\))?, "
    r"GPU KV cache usage: ([0-9.]+)%")


class Refusal(Exception):
    pass


def parse(lines):
    """Every iteration line, in log order.

    A line that names an iteration but does not match is refused rather than skipped: a skipped line is a
    missing step, and a missing step is exactly what the accounting gate exists to catch.
    """
    out = []
    for n, line in enumerate(lines, 1):
        if "Iteration(" not in line:
            continue
        m = LINE.search(line)
        if not m:
            raise Refusal(f"line {n} names an iteration but does not match the v0.27.1 format: {line.strip()[:160]}")
        idx, cr, ct, gr, gt, ms, dummy, kv = m.groups()
        if dummy:
            raise Refusal(f"line {n} is a dummy iteration, which only data parallelism produces; this engine has none")
        out.append(dict(index=int(idx), ctx_reqs=int(cr), ctx_tokens=int(ct), gen_reqs=int(gr),
                        gen_tokens=int(gt), elapsed_ms=float(ms), kv=float(kv)))
    return out


def check_indices(iters):
    """Gate I2's first half: the index runs without a gap or a repeat from wherever the capture began.

    The capture may start after the engine has stepped (warm-up), so the first index is not required to be zero.
    """
    if not iters:
        raise Refusal("no iteration lines: was --enable-logging-iteration-details passed, and is INFO logged?")
    for a, b in zip(iters, iters[1:]):
        if b["index"] != a["index"] + 1:
            raise Refusal(f"iteration {a['index']} is followed by {b['index']}: a step is missing or repeated")


def attribute_serial(iters, requests):
    """Split a drained serial episode's steps among its requests, in send order.

    Each request is ceil(L / BUDGET) context steps and then outputTokens - 1 generation steps, and every step of a
    serial episode carries exactly one request. Anything else -- two requests in one step, a count that does not
    match -- refuses the episode, because attributing by order is only sound when nothing overlaps.
    """
    out, i = [], 0
    for r in requests:
        k = math.ceil(r["input_tokens"] / BUDGET)
        g = r["output_tokens"] - 1
        mine = iters[i:i + k + g]
        if len(mine) != k + g:
            raise Refusal(f"request {r['index']} needs {k + g} steps and the log has {len(mine)} left")
        ctx, gen = mine[:k], mine[k:]
        for s in ctx:
            if (s["ctx_reqs"], s["gen_reqs"]) != (1, 0):
                raise Refusal(f"request {r['index']}: iteration {s['index']} is not a lone context step: {s}")
        if sum(s["ctx_tokens"] for s in ctx) != r["input_tokens"]:
            raise Refusal(f"request {r['index']}: its context steps schedule {sum(s['ctx_tokens'] for s in ctx)} "
                          f"tokens, not {r['input_tokens']}")
        for s in gen:
            if (s["ctx_reqs"], s["gen_reqs"], s["gen_tokens"]) != (0, 1, 1):
                raise Refusal(f"request {r['index']}: iteration {s['index']} is not a lone decode step: {s}")
        out.append(dict(r, k=k, ctx_ms=[s["elapsed_ms"] for s in ctx], gen_ms=[s["elapsed_ms"] for s in gen]))
        i += k + g
    if i != len(iters):
        raise Refusal(f"{len(iters) - i} iteration(s) after the last request belong to nothing in the trace")
    return out


def fit_clock(attributed):
    """Section 3's clock: TTFT - sum(context elapsed) = a + b*k, and b' from decode spacing.

    Ordinary least squares on k. The fit is refused when k does not vary, because then a and b are the same
    number and the omitted per-step time cannot be told from the fixed request-path delay.
    """
    xs = [r["k"] for r in attributed]
    ys = [r["ttft_ms"] - sum(r["ctx_ms"]) for r in attributed]
    if len(set(xs)) < 2:
        raise Refusal("every request has the same number of context steps, so a and b are not separately identified")
    mx, my = statistics.fmean(xs), statistics.fmean(ys)
    b = sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / sum((x - mx) ** 2 for x in xs)
    a = my - b * mx
    residual = [abs(y - (a + b * x)) / r["ttft_ms"] for x, y, r in zip(xs, ys, attributed)]
    # The decode clock is the same regression, on generation steps.
    #
    # The client stamps its end after the stream's usage chunk and [DONE] (internal/bench/httpsender.go), not at
    # the last token, so end - first carries a termination delay that is fitted as the intercept rather than spread
    # over the steps. Sums are compared with sums: an earlier version set the client's mean spacing against the
    # median logged step, and one slow step that both clocks saw then read as ten milliseconds of omitted time.
    b_dec, d_end = {}, {}
    for L in sorted({r["input_tokens"] for r in attributed}):
        rs = [r for r in attributed if r["input_tokens"] == L]
        gs = [len(r["gen_ms"]) for r in rs]
        if len(set(gs)) < 2:
            raise Refusal(f"every {L}-token request has {gs[0]} generation steps, so b' and the end delay are not "
                          f"separately identified")
        zs = [r["end_ms"] - r["first_ms"] - sum(r["gen_ms"]) for r in rs]
        mg, mz = statistics.fmean(gs), statistics.fmean(zs)
        b_dec[L] = sum((g - mg) * (z - mz) for g, z in zip(gs, zs)) / sum((g - mg) ** 2 for g in gs)
        d_end[L] = mz - b_dec[L] * mg
    return dict(a=a, b=b, worst_residual=max(residual), b_decode=b_dec, end_delay=d_end)


def load_requests(raw_path):
    rows = [json.loads(l) for l in open(raw_path)]
    # A failed request is refused, not dropped: dropping it leaves the iteration accounting consistent and the fit
    # clean for an episode the registration says must be refused.
    failed = [r["index"] for r in rows if r.get("errorKind")]
    if failed:
        raise Refusal(f"{len(failed)} failed request(s), first index {failed[0]}")
    rows.sort(key=lambda r: r["sendUnixNanos"])
    # Drained is checked, not assumed: a request queued behind its predecessor still yields lone steps in order,
    # and its TTFT then carries queueing that the clock fit would book as omitted engine time.
    for p, r in zip(rows, rows[1:]):
        if r["sendUnixNanos"] < p["endUnixNanos"]:
            raise Refusal(f"request {r['index']} was sent before request {p['index']} ended, so the episode was not "
                          f"drained")
    return [dict(index=r["index"], input_tokens=r["engineInputTokens"], output_tokens=r["engineOutputTokens"],
                 ttft_ms=(r["firstTokenUnixNanos"] - r["sendUnixNanos"]) / 1e6,
                 first_ms=r["firstTokenUnixNanos"] / 1e6, end_ms=r["endUnixNanos"] / 1e6) for r in rows]


def _line(i, cr, ct, gr, gt, ms):
    return (f"INFO 10-05 12:00:00 [loggers.py:182] Iteration({i}): {cr} context requests, {ct} context tokens, "
            f"{gr} generation requests, {gt} generation tokens, iteration elapsed time: {ms:.2f} ms, "
            f"GPU KV cache usage: 0.4%")


def _synthetic(a=6.0, b=1.5, step_ms=10.0, dec_ms=13.3, b_dec=1.5, d_end=3.0, slow=0.0):
    """A serial episode whose true a, b, b' and end delay are known, so the fit can be held to them.

    `slow` adds that many milliseconds to one decode step, seen by both the log and the client, which must not
    move b': it is engine time, and the timer saw it.
    """
    lines, reqs, i, t = [], [], 40, 0.0
    shape = [(256, 16), (256, 1), (2048, 16), (2048, 64), (4096, 1), (4096, 16), (8192, 16), (8192, 64)]
    for n, (L, out) in enumerate(shape):
        k = math.ceil(L / BUDGET)
        ctx = [step_ms * min(BUDGET, L - j * BUDGET) / BUDGET for j in range(k)]
        for j, ms in enumerate(ctx):
            lines.append(_line(i, 1, min(BUDGET, L - j * BUDGET), 0, 0, ms)); i += 1
        gen = [dec_ms + (slow if (n == 2 and g == 3) else 0.0) for g in range(out - 1)]
        for ms in gen:
            lines.append(_line(i, 0, 0, 1, 1, ms)); i += 1
        ttft = a + sum(ctx) + b * k
        first = t + ttft
        reqs.append(dict(index=n, input_tokens=L, output_tokens=out, ttft_ms=ttft, first_ms=first,
                         end_ms=first + sum(gen) + b_dec * len(gen) + d_end))
        t += 10_000
    return lines, reqs


def self_test():
    """The parser, the attribution and the fit, each made to fail on purpose so a refusal is seen to fire."""
    lines, reqs = _synthetic()
    iters = parse(["noise line"] + lines)
    check_indices(iters)
    fit = fit_clock(attribute_serial(iters, reqs))
    assert abs(fit["a"] - 6.0) < 1e-6 and abs(fit["b"] - 1.5) < 1e-6, fit
    assert fit["worst_residual"] < 1e-9, fit
    assert all(abs(v - 1.5) < 1e-6 for v in fit["b_decode"].values()), fit
    assert all(abs(v - 3.0) < 1e-6 for v in fit["end_delay"].values()), fit
    print(f"ok: a {fit['a']:.3f} ms, b {fit['b']:.3f} ms per context step, b' and the 3 ms end delay recovered "
          f"exactly at every length")
    slow_lines, slow_reqs = _synthetic(slow=150.0)
    slow_fit = fit_clock(attribute_serial(parse(slow_lines), slow_reqs))
    assert all(abs(v - 1.5) < 1e-6 for v in slow_fit["b_decode"].values()), slow_fit
    print("ok: one decode step 150 ms slower, seen by both clocks, leaves b' at 1.5 ms")

    def refuses(what, fn):
        try:
            fn()
        except Refusal as e:
            print(f"ok: refuses {what} -- {e}")
            return
        raise AssertionError(f"{what} was accepted")

    refuses("a malformed iteration line", lambda: parse([lines[0].replace("context tokens", "ctx tokens")]))
    refuses("a missing step", lambda: check_indices(parse(lines[:3] + lines[4:])))
    refuses("a repeated step", lambda: check_indices(parse(lines[:3] + lines[2:])))
    refuses("an empty capture", lambda: check_indices(parse([])))
    refuses("an extra trailing step", lambda: attribute_serial(parse(lines + [_line(999, 0, 0, 1, 1, 13.3)]), reqs))
    refuses("a step that is short of the trace", lambda: attribute_serial(parse(lines[:-1]), reqs))
    two = lines[:]
    two[0] = _line(40, 2, 256, 0, 0, 10.0)
    refuses("two requests in one step", lambda: attribute_serial(parse(two), reqs))
    wrong = [dict(r) for r in reqs]
    wrong[1]["input_tokens"] = 2000
    refuses("a context-token count that does not match", lambda: attribute_serial(parse(lines), wrong))
    flat = [r for r in attribute_serial(parse(lines), reqs) if r["k"] == 1]
    refuses("a fit where every request has one context step", lambda: fit_clock(flat))
    one_cap = [r for r in attribute_serial(parse(lines), reqs) if r["output_tokens"] == 16]
    refuses("a decode fit where every request has one output length", lambda: fit_clock(one_cap))

    import tempfile

    def raw_of(rs, mutate):
        rows = [dict(index=r["index"], engineInputTokens=r["input_tokens"], engineOutputTokens=r["output_tokens"],
                     sendUnixNanos=int((r["first_ms"] - r["ttft_ms"]) * 1e6),
                     firstTokenUnixNanos=int(r["first_ms"] * 1e6), endUnixNanos=int(r["end_ms"] * 1e6)) for r in rs]
        mutate(rows)
        f = tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False)
        f.write("".join(json.dumps(x) + "\n" for x in rows))
        f.close()
        return f.name

    for what, mutate in [("a failed request", lambda rows: rows[3].update(errorKind="timeout")),
                         ("a request sent before its predecessor ended",
                          lambda rows: rows[4].update(sendUnixNanos=rows[3]["endUnixNanos"] - 1))]:
        path = raw_of(reqs, mutate)
        try:
            refuses(what, lambda: load_requests(path))
        finally:
            os.remove(path)
    path = raw_of(reqs, lambda rows: None)
    try:
        assert len(load_requests(path)) == len(reqs)
        print("ok: the untouched rows load")
    finally:
        os.remove(path)


def main(argv):
    if argv[1:] == ["--self-test"]:
        self_test()
        return
    if len(argv) != 3:
        sys.exit(__doc__)
    iters = parse(open(argv[1]))
    check_indices(iters)
    fit = fit_clock(attribute_serial(iters, load_requests(argv[2])))
    print(json.dumps(fit, indent=2))


if __name__ == "__main__":
    try:
        main(sys.argv)
    except Refusal as e:
        sys.exit(f"REFUSED: {e}")
