"""Per-iteration records of a stock vLLM v0.27.1 engine, attributed to requests and checked against the client.

Registered in docs/superpowers/specs/2026-10-05-can-the-stock-engine-time-an-iteration-instrument-validation.md.
The engine logs one line per step under --enable-logging-iteration-details, and the line carries no request id,
so a request's steps can be recovered only where the traffic makes them unambiguous: a drained serial episode.

    python3 iterlog.py --self-test
    python3 iterlog.py ENGINE_LOG RAW_ROWS.jsonl     # serial cells only
"""

import json
import math
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
    spaced = [r for r in attributed if len(r["gen_ms"]) >= 2]
    b_dec = {}
    for L in sorted({r["input_tokens"] for r in spaced}):
        rs = [r for r in spaced if r["input_tokens"] == L]
        itl = statistics.median((r["end_ms"] - r["first_ms"]) / len(r["gen_ms"]) for r in rs)
        b_dec[L] = itl - statistics.median(m for r in rs for m in r["gen_ms"])
    return dict(a=a, b=b, worst_residual=max(residual), b_decode=b_dec)


def load_requests(raw_path):
    rows = [json.loads(l) for l in open(raw_path)]
    rows = [r for r in rows if not r.get("errorKind")]
    rows.sort(key=lambda r: r["sendUnixNanos"])
    return [dict(index=r["index"], input_tokens=r["engineInputTokens"], output_tokens=r["engineOutputTokens"],
                 ttft_ms=(r["firstTokenUnixNanos"] - r["sendUnixNanos"]) / 1e6,
                 first_ms=r["firstTokenUnixNanos"] / 1e6, end_ms=r["endUnixNanos"] / 1e6) for r in rows]


def _line(i, cr, ct, gr, gt, ms):
    return (f"INFO 10-05 12:00:00 [loggers.py:182] Iteration({i}): {cr} context requests, {ct} context tokens, "
            f"{gr} generation requests, {gt} generation tokens, iteration elapsed time: {ms:.2f} ms, "
            f"GPU KV cache usage: 0.4%")


def _synthetic(a=6.0, b=1.5, step_ms=10.0, dec_ms=13.3, b_dec=1.5):
    """A serial episode whose true a, b and b' are known, so the fit can be held to them."""
    lines, reqs, i, t = [], [], 40, 0.0
    for n, (L, out) in enumerate([(256, 16), (2048, 16), (4096, 16), (8192, 16), (256, 1), (8192, 64)]):
        k = math.ceil(L / BUDGET)
        ctx = [step_ms * min(BUDGET, L - j * BUDGET) / BUDGET for j in range(k)]
        for j, ms in enumerate(ctx):
            lines.append(_line(i, 1, min(BUDGET, L - j * BUDGET), 0, 0, ms)); i += 1
        for _ in range(out - 1):
            lines.append(_line(i, 0, 0, 1, 1, dec_ms)); i += 1
        ttft = a + sum(ctx) + b * k
        first = t + ttft
        reqs.append(dict(index=n, input_tokens=L, output_tokens=out, ttft_ms=ttft, first_ms=first,
                         end_ms=first + (out - 1) * (dec_ms + b_dec)))
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
    print(f"ok: a {fit['a']:.3f} ms, b {fit['b']:.3f} ms per context step, b' {fit['b_decode']} recovered exactly")

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
