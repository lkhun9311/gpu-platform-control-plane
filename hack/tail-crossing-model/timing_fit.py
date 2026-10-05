"""The reduced timing family, fitted on held-out episodes from the logged synchronous cells of one archive.

The pass branch of docs/superpowers/specs/2026-10-05-can-the-stock-engine-time-an-iteration-instrument-validation.md
calls for this fit; it was written before any of that registration's cells came back.

    step_ms = c + f(P) + d1*n + d2*n^2 + m*P*n   (+ k*K_d with --context)

P is the context tokens scheduled in the step, n the generation requests, f piecewise linear with knots at 0, 256,
512, 1,024 and 2,048 and f(0) = 0, and K_d the summed context of the step's decoders.
The left side is not the logged elapsed_ms but elapsed_ms plus the per-step time the timer omits, from the clock fit
in iterlog.fit_clock.

    python3 timing_fit.py ARCHIVE/m5c-run [--context] [--mixed-omitted b|b-prime]
    python3 timing_fit.py --self-test

Only the standard library is used: neither numpy nor scipy was installed on the machine this was written on, and a
fit that silently needs a package nobody has is a fit that does not run on the day.
"""

import json
import math
import os
import random
import sys

import instrument_gates
import iterlog
from iterlog import Refusal

BUDGET = iterlog.BUDGET
KNOTS = (0, 256, 512, 1024, 2048)
BLOCKS = instrument_gates.BLOCKS
ARMS = ("serial-log", "burst-log", "stagger-log")
# Every third complete episode of a setting, in episode order, is held out; ordinals 2, 5, 8, ... (0-based).
HOLDOUT_EVERY = 3
# A setting needs one held-out and two training episodes at the least, so three is the floor.
MIN_EPISODES = 3
MAX_CONDITION = 100.0
MAX_HELDOUT_ERROR = 0.10
# Relative to the largest eigenvalue of the column-normalised Gram matrix; below it a column is a combination of others.
RANK_TOL = 1e-10


def columns(context):
    names = ["c"] + [f"f[{a}-{b}]" for a, b in zip(KNOTS, KNOTS[1:])] + ["d1", "d2", "m"]
    return names + (["k"] if context else [])


def features(P, n, K, context):
    """One step's row of the design.

    f is written as the sum of its segments, each clamped to its own knot interval, so a coefficient is that
    segment's slope in ms per token, f(0) = 0 holds by construction, and nonnegative slopes make f nondecreasing:
    scheduling more prefill tokens never makes a step shorter.
    """
    if P > BUDGET:
        raise Refusal(f"a step schedules {P} context tokens, above the {BUDGET}-token budget the knots end at")
    row = [1.0] + [float(min(max(P - a, 0), b - a)) for a, b in zip(KNOTS, KNOTS[1:])]
    row += [float(n), float(n * n), float(P * n)]
    return row + ([float(K)] if context else [])


# ---------------------------------------------------------------------------------------------------------------
# Reading an archive


def episodes_of(kind, reqs):
    """A cell's requests grouped into episodes, each with its setting, in the order they were sent.

    The same reassembly instrument_gates.settings makes: a burst is the rows sharing an offset, and a staggered
    episode is its decoders followed by the one prefill row with a smaller cap.
    """
    groups = []
    for q in reqs:
        if groups and groups[-1][0]["offset"] == q["offset"]:
            groups[-1].append(q)
        else:
            groups.append([q])
    out = []
    if kind == "serial":
        for g in groups:
            if len(g) != 1:
                raise Refusal(f"serial trace: {len(g)} requests share offset {g[0]['offset']} ms")
            out.append(((kind, g[0]["input_tokens"], g[0]["cap"]), g))
        return out
    if kind == "burst":
        for g in groups:
            if len({q["input_tokens"] for q in g}) != 1:
                raise Refusal(f"burst at offset {g[0]['offset']} ms is not homogeneous, so its decoder context is "
                              f"not known by construction")
            out.append(((kind, len(g), g[0]["input_tokens"], g[0]["cap"]), g))
        return out
    i = 0
    while i < len(groups):
        dec = groups[i]
        if i + 1 >= len(groups) or len(groups[i + 1]) != 1 or groups[i + 1][0]["cap"] >= dec[0]["cap"]:
            raise Refusal(f"staggered trace: the decoders at offset {dec[0]['offset']} ms have no prefill after them")
        pre = groups[i + 1][0]
        out.append(((kind, len(dec), dec[0]["input_tokens"], pre["input_tokens"]), dec + [pre]))
        i += 2
    return out


def reconstruct(reqs, steps):
    """Each step's P, n and decoder context K_d, replayed from step order alone.

    The log carries no request ids, so the contexts are rebuilt by walking the episode's steps in order.
    Requests are taken first come, first served by send time, which is how v0.27.1's scheduler admits them; the
    logged context tokens of a step are dealt to the requests whose prompts are not yet fully scheduled, in that
    order, and a request whose prompt is completed in a step has produced its first token by the end of it.
    A decoder in a later step has produced g tokens before the step, so the step attends over L + g of its tokens
    (its prompt, the g - 1 tokens already in the cache, and the one it is fed now), and K_d is the sum of L + g over
    the step's decoders.
    Each rebuilt step is checked against the log -- the number of requests it deals context tokens to against the
    logged context requests, the decoders still running against the logged generation requests -- so a rebuild
    that does not reproduce the log refuses rather than returning a context the episode did not have.
    """
    order = sorted(reqs, key=lambda q: (q["send_ms"], q["index"]))
    left = [q["input_tokens"] for q in order]
    made = [0] * len(order)
    out = []
    for s in steps:
        if s["gen_tokens"] != s["gen_reqs"]:
            raise Refusal(f"iteration {s['index']}: {s['gen_reqs']} generation requests and {s['gen_tokens']} "
                          f"generation tokens; one token per decoder is the only step shape this family describes")
        decoding = [i for i in range(len(order)) if left[i] == 0 and 0 < made[i] < order[i]["output_tokens"]]
        if len(decoding) != s["gen_reqs"]:
            raise Refusal(f"iteration {s['index']}: the log has {s['gen_reqs']} generation requests and the episode, "
                          f"replayed in order, has {len(decoding)} decoders running")
        K = sum(order[i]["input_tokens"] + made[i] for i in decoding)
        P, dealt, finished = s["ctx_tokens"], 0, []
        for i in range(len(order)):
            if P == 0:
                break
            if left[i] > 0:
                take = min(left[i], P)
                left[i] -= take
                P -= take
                dealt += 1
                if left[i] == 0:
                    finished.append(i)
        if P or dealt != s["ctx_reqs"]:
            raise Refusal(f"iteration {s['index']}: {s['ctx_tokens']} context tokens over {s['ctx_reqs']} requests "
                          f"cannot be dealt to the episode's unscheduled prompts in send order")
        if s["ctx_tokens"] == 0 and s["gen_reqs"] == 0:
            raise Refusal(f"iteration {s['index']} schedules nothing")
        for i in decoding:
            made[i] += 1
        for i in finished:
            made[i] = 1
        out.append(dict(P=s["ctx_tokens"], n=s["gen_reqs"], K=K, elapsed=s["elapsed_ms"]))
    unfinished = [order[i]["index"] for i in range(len(order)) if left[i] or made[i] != order[i]["output_tokens"]]
    if unfinished:
        raise Refusal(f"the episode's steps end with request(s) {unfinished[:3]} not finished as the client saw them")
    return out


def load_episodes(run):
    """Every logged synchronous episode, with its setting, block and steps.

    The same refusals instrument_gates makes on these cells are made again here, because this fit can run on an
    archive nobody passed through the gates: a failed request, a preemption, a missing or repeated iteration, and
    an episode whose steps overlap another's all refuse.
    """
    out = []
    for arm in ARMS:
        kind = arm.split("-")[0]
        for b in BLOCKS:
            reqs = instrument_gates.load_cell(run, arm, b)
            p = instrument_gates.preemptions(run, arm, b)
            if p:
                raise Refusal(f"{arm}-{b}: {p:g} preemption(s); a preempted request recomputes its prompt, which the "
                              f"rebuild of step contexts does not model")
            iters = iterlog.parse(open(os.path.join(run, f"engine-log-{arm}-{b}.txt")))
            iterlog.check_indices(iters)
            eps = episodes_of(kind, reqs)
            for pos, ((setting, ep), steps) in enumerate(zip(eps, instrument_gates.segment(iters, [e for _, e in eps]))):
                out.append(dict(setting=setting, block=b, pos=pos, steps=reconstruct(ep, steps)))
    return out


def clock(run):
    """b and b' from the three logged serial cells pooled, by iterlog's section-3 clock.

    The serial cells are attributed one cell at a time, because attribution walks one log, and then fitted together:
    the clock's two constants are properties of the engine, not of a block, and a pooled fit has the most step
    counts to regress on.
    b' is fitted per input length; the registration's I3 bounds how far those differ, and their mean is used here.
    """
    attributed = []
    for b in BLOCKS:
        reqs = instrument_gates.load_cell(run, "serial-log", b)
        by_send = sorted(reqs, key=lambda q: q["send_ms"])
        for p, q in zip(by_send, by_send[1:]):
            if q["send_ms"] < p["end_ms"]:
                raise Refusal(f"serial-log-{b}: request {q['index']} was sent before request {p['index']} ended")
        iters = iterlog.parse(open(os.path.join(run, f"engine-log-serial-log-{b}.txt")))
        iterlog.check_indices(iters)
        attributed += iterlog.attribute_serial(iters, sorted(reqs, key=lambda q: (q["offset"], q["index"])))
    fit = iterlog.fit_clock(attributed)
    b_prime = sum(fit["b_decode"].values()) / len(fit["b_decode"])
    # An omitted time below zero would make a step shorter than the part of it the timer saw, which no engine does;
    # it means the clock fit is wrong, and adding it back would publish a duration built on that.
    if fit["b"] < 0 or b_prime < 0:
        raise Refusal(f"the clock gives a negative omitted time (b {fit['b']:.3f} ms, b' {b_prime:.3f} ms)")
    return dict(a=fit["a"], b=fit["b"], b_prime=b_prime, b_decode=fit["b_decode"])


# ---------------------------------------------------------------------------------------------------------------
# Linear algebra, standard library only


def solve(A, y):
    """Gaussian elimination with partial pivoting; the callers have already refused a singular design."""
    n = len(y)
    M = [list(map(float, A[i])) + [float(y[i])] for i in range(n)]
    for c in range(n):
        p = max(range(c, n), key=lambda r: abs(M[r][c]))
        if M[p][c] == 0.0:
            raise Refusal("a passive-set subproblem of the nonnegative fit is singular")
        M[c], M[p] = M[p], M[c]
        for r in range(c + 1, n):
            f = M[r][c] / M[c][c]
            if f:
                for j in range(c, n + 1):
                    M[r][j] -= f * M[c][j]
    x = [0.0] * n
    for c in range(n - 1, -1, -1):
        x[c] = (M[c][n] - sum(M[c][j] * x[j] for j in range(c + 1, n))) / M[c][c]
    return x


def eigenvalues(S):
    """Cyclic Jacobi rotations on a symmetric matrix; small enough here (at most ten columns) to run to convergence."""
    n = len(S)
    A = [row[:] for row in S]
    for _ in range(100):
        off = sum(A[i][j] ** 2 for i in range(n) for j in range(n) if i != j)
        if off <= 1e-30 * max(1e-300, sum(A[i][i] ** 2 for i in range(n))):
            return sorted(A[i][i] for i in range(n))
        for p in range(n):
            for q in range(p + 1, n):
                if A[p][q] == 0.0:
                    continue
                theta = (A[q][q] - A[p][p]) / (2.0 * A[p][q])
                t = (1.0 if theta >= 0 else -1.0) / (abs(theta) + math.sqrt(theta * theta + 1.0))
                c = 1.0 / math.sqrt(t * t + 1.0)
                s = t * c
                for k in range(n):
                    akp, akq = A[k][p], A[k][q]
                    A[k][p], A[k][q] = c * akp - s * akq, s * akp + c * akq
                for k in range(n):
                    apk, aqk = A[p][k], A[q][k]
                    A[p][k], A[q][k] = c * apk - s * aqk, s * apk + c * aqk
    raise Refusal("the eigenvalues of the design did not converge, so its condition number is unknown")


def nnls(G, h, tol=1e-10):
    """Lawson and Hanson's active-set method on the normal equations: minimise x'Gx/2 - h'x subject to x >= 0.

    G is the column-normalised Gram matrix, whose condition the caller has bounded by 100^2 before this runs, so
    the normal equations lose at most four of the sixteen digits.
    The result is checked against the Karush-Kuhn-Tucker conditions before it is returned, because an active-set
    loop that stops early returns a plausible vector that is not the minimum.
    """
    n = len(h)
    x, passive = [0.0] * n, []

    def grad(v):
        return [h[i] - sum(G[i][j] * v[j] for j in range(n)) for i in range(n)]

    for _ in range(10 * n + 10):
        w = grad(x)
        free = [j for j in range(n) if j not in passive]
        if not free or max(w[j] for j in free) <= tol:
            break
        passive.append(max(free, key=lambda j: w[j]))
        for _ in range(10 * n + 10):
            zp = solve([[G[i][j] for j in passive] for i in passive], [h[i] for i in passive])
            z = [0.0] * n
            for i, v in zip(passive, zp):
                z[i] = v
            if all(z[i] > 0 for i in passive):
                x = z
                break
            alpha = min(x[i] / (x[i] - z[i]) for i in passive if z[i] <= 0)
            x = [x[i] + alpha * (z[i] - x[i]) for i in range(n)]
            passive = [i for i in passive if x[i] > tol]
            x = [x[i] if i in passive else 0.0 for i in range(n)]
        else:
            raise Refusal("the nonnegative fit's inner loop did not converge")
    else:
        raise Refusal("the nonnegative fit did not converge")
    w = grad(x)
    for i in range(n):
        if x[i] < 0 or w[i] > 1e-7 or (x[i] > 0 and abs(w[i]) > 1e-7):
            raise Refusal(f"the nonnegative fit stopped off its optimum at column {i} (x {x[i]:.3g}, gradient {w[i]:.3g})")
    return x


# ---------------------------------------------------------------------------------------------------------------
# The fit


def true_ms(step, b, b_prime, mixed):
    """elapsed_ms plus the time the timer omits for a step of that kind.

    A context step gets b and a decode-only step b', as iterlog.fit_clock measured them on lone requests.
    A mixed step -- context tokens and decoders together -- was never measured by either clock.
    It gets b by default, because b is defined per context step: section 3 charges b to every one of a request's k
    context steps whatever else shares them, and a mixed step is one of its prefill's context steps.
    --mixed-omitted b-prime is there so the choice's effect can be shown, not to choose it after seeing data.
    """
    if step["P"] == 0:
        return step["elapsed"] + b_prime
    if step["n"] == 0:
        return step["elapsed"] + b
    return step["elapsed"] + (b if mixed == "b" else b_prime)


def split(episodes, context):
    """Hold out every third complete episode of each setting, by episode order, and refuse a setting with too few.

    Episode order is block, then position in the cell; the split is by whole episode, never by step, because steps of
    one episode share its decoders and its timing and would leak into each other across a step split.
    """
    by = {}
    for e in sorted(episodes, key=lambda e: (e["block"], e["pos"])):
        by.setdefault(e["setting"], []).append(e)
    few = {s: len(v) for s, v in by.items() if len(v) < MIN_EPISODES}
    if not by or few:
        raise Refusal(f"too few episodes: {MIN_EPISODES} complete episodes per setting are needed, and "
                      f"{len(few)} setting(s) have fewer, e.g. {sorted(few.items(), key=str)[:3]}")
    train, held = {}, {}
    for s, eps in by.items():
        for i, e in enumerate(eps):
            (held if i % HOLDOUT_EVERY == HOLDOUT_EVERY - 1 else train).setdefault(s, []).append(e)
    if context:
        # The context coefficient may only be fitted where decoder context is known by construction: a homogeneous
        # burst, and a serial request, which is a burst of one.
        # A staggered episode's decoder context depends on how many decode steps ran before its prefill arrived, a
        # client timing rather than a design value, so under --context it is held out whole: predicted, never fitted.
        for s in [s for s in train if s[0] == "stagger"]:
            held[s] = held[s] + train.pop(s)
    return train, held


def fit(episodes, b, b_prime, context=False, mixed="b", bound=MAX_HELDOUT_ERROR):
    names = columns(context)
    train, held = split(episodes, context)
    p = len(names)
    G = [[0.0] * p for _ in range(p)]
    h = [0.0] * p
    for s, eps in train.items():
        steps = [st for e in eps for st in e["steps"]]
        # Each setting carries total weight one, whatever its step count: a 16-decoder burst at 8,192 tokens has
        # thirty times the steps of a lone 256-token request, and would otherwise choose the coefficients alone.
        w = 1.0 / len(steps)
        for st in steps:
            x, y = features(st["P"], st["n"], st["K"], context), true_ms(st, b, b_prime, mixed)
            for i in range(p):
                h[i] += w * x[i] * y
                for j in range(p):
                    G[i][j] += w * x[i] * x[j]
    norms = [math.sqrt(G[i][i]) for i in range(p)]
    dead = [names[i] for i in range(p) if norms[i] == 0.0]
    if dead:
        raise Refusal(f"rank-deficient design: no training step moves column(s) {dead}")
    Gn = [[G[i][j] / (norms[i] * norms[j]) for j in range(p)] for i in range(p)]
    lam = eigenvalues(Gn)
    if lam[0] <= RANK_TOL * lam[-1]:
        raise Refusal(f"rank-deficient design: the column-normalised Gram matrix has eigenvalue {lam[0]:.3g} against "
                      f"{lam[-1]:.3g}, so some column is a combination of the others")
    cond = math.sqrt(lam[-1] / lam[0])
    if cond > MAX_CONDITION:
        raise Refusal(f"the column-normalised design has condition number {cond:.1f}, above {MAX_CONDITION:g}: the "
                      f"coefficients trade off against each other and no one of them is determined")
    gamma = nnls(Gn, [h[i] / norms[i] for i in range(p)])
    beta = [g / n for g, n in zip(gamma, norms)]
    report = []
    for s, eps in sorted(held.items(), key=lambda kv: str(kv[0])):
        steps = [st for e in eps for st in e["steps"]]
        obs = sum(true_ms(st, b, b_prime, mixed) for st in steps) / len(steps)
        pred = sum(sum(c * x for c, x in zip(beta, features(st["P"], st["n"], st["K"], context)))
                   for st in steps) / len(steps)
        report.append((s, len(eps), obs, pred, pred / obs - 1))
    worst = max(report, key=lambda r: abs(r[4]))
    if abs(worst[4]) > bound:
        raise Refusal(f"held-out setting {worst[0]}: predicted mean step {worst[3]:.3f} ms against {worst[2]:.3f} ms "
                      f"observed over {worst[1]} episode(s), {worst[4]:+.1%}, beyond {bound:.0%}")
    return dict(coefficients=dict(zip(names, beta)), at_zero=[n for n, v in zip(names, beta) if v == 0.0],
                condition=cond, train_settings=len(train), heldout=report, mixed_omitted=mixed,
                # The intercept column is 1 on every step, so its Gram entry is the total weight the fit used.
                weight_total=G[0][0], trained=sorted(train, key=str),
                f_at_knots={k: sum(beta[1 + i] * (min(max(k - a, 0), b2 - a)) for i, (a, b2)
                                   in enumerate(zip(KNOTS, KNOTS[1:]))) for k in KNOTS})


def run_fit(run, context=False, mixed="b"):
    clk = clock(run)
    out = fit(load_episodes(run), clk["b"], clk["b_prime"], context, mixed)
    out["clock"] = clk
    return out


# ---------------------------------------------------------------------------------------------------------------
# Self-test on synthetic archives whose coefficients are known

TRUTH = dict(c=12.0, s=(0.13, 0.12, 0.115, 0.11), d1=0.15, d2=0.002, m=0.00002, k=0.0)
CLOCK = dict(a=6.0, b=1.5, b_prime=1.2, d_end=3.0)


def _true_step(P, n, K, t):
    f = sum(sl * min(max(P - a, 0), b - a) for sl, (a, b) in zip(t["s"], zip(KNOTS, KNOTS[1:])))
    return t["c"] + f + t["d1"] * n + t["d2"] * n * n + t["m"] * P * n + t["k"] * K


def _simulate(spec, t, rng, noise, slow):
    """A forward scheduler, written apart from reconstruct() so a shared mistake is not a shared blind spot.

    spec is a list of (input tokens, cap, is_late); a late request arrives once every earlier one has produced four
    tokens, which is the staggered episode's shape.
    Running decoders take one token of the budget each, then prompts are scheduled first come, first served.
    """
    rem = [L for L, _, _ in spec]
    prod = [0] * len(spec)
    arrived = [not late for _, _, late in spec]
    steps, done_at, first_at = [], [None] * len(spec), [None] * len(spec)
    while any(prod[i] < spec[i][1] for i in range(len(spec))):
        for i, (_, _, late) in enumerate(spec):
            if late and not arrived[i] and all(prod[j] >= 4 for j in range(len(spec)) if not spec[j][2]):
                arrived[i] = True
        dec = [i for i in range(len(spec)) if rem[i] == 0 and 0 < prod[i] < spec[i][1]]
        budget, P, cr, completed = BUDGET - len(dec), 0, 0, []
        for i in range(len(spec)):
            if arrived[i] and rem[i] and budget:
                take = min(rem[i], budget)
                rem[i] -= take
                budget -= take
                P += take
                cr += 1
                if rem[i] == 0:
                    completed.append(i)
        K = sum(spec[i][0] + prod[i] for i in dec)
        T = _true_step(P, len(dec), K, t) * (1 + rng.gauss(0, noise)) * slow
        steps.append(dict(P=P, cr=cr, n=len(dec), T=T))
        for i in dec:
            prod[i] += 1
            if prod[i] == spec[i][1]:
                done_at[i] = len(steps) - 1
        for i in completed:
            prod[i] = 1
            first_at[i] = len(steps) - 1
            if spec[i][1] == 1:
                done_at[i] = len(steps) - 1
    return steps, first_at, done_at


def _cycle(kind):
    if kind == "serial":
        return [[(L, c, False)] for L in (256, 512, 1024, 2048, 4096, 8192) for c in (1, 16, 64)]
    if kind == "burst":
        return [[(L, 64, False)] * n for n in (1, 4, 16) for L in (256, 2048, 8192)] + [[(256, 64, False)] * 64]
    return [[(c, 128, False)] * n + [(p, 16, True)] for n in (1, 4, 16) for c in (256, 8192) for p in (256, 8192)]


def _setting(kind, spec):
    if kind == "serial":
        return ("serial", spec[0][0], spec[0][1])
    if kind == "burst":
        return ("burst", len(spec), spec[0][0], spec[0][1])
    return ("stagger", len(spec) - 1, spec[0][0], spec[-1][0])


def _line(i, cr, ct, gr, ms):
    # Six decimals rather than vLLM's two, so exact recovery is not limited by the synthetic log's own rounding.
    return (f"INFO 10-05 12:00:00 [loggers.py:182] Iteration({i}): {cr} context requests, {ct} context tokens, "
            f"{gr} generation requests, {gr} generation tokens, iteration elapsed time: {ms:.6f} ms, "
            f"GPU KV cache usage: 0.4%")


def _synthetic_run(run, truth=TRUTH, noise=0.0, slow=None, seed=3):
    """Three blocks of the three logged arms, every registered setting three times a cell, from known coefficients.

    slow maps a setting to a factor applied to its third-cycle episodes in every block -- the ones the split holds out.
    """
    rng, slow = random.Random(seed), slow or {}
    for kind in ("serial", "burst", "stagger"):
        for b in BLOCKS:
            cyc, trace, raw, lines, it, idx, ep_no = _cycle(kind), [], [], [], 50, 0, 0
            for cycle in range(3):
                for spec in rng.sample(cyc, len(cyc)):
                    start = ep_no * 100_000
                    ep_no += 1
                    factor = slow.get(_setting(kind, spec), 1.0) if cycle == 2 else 1.0
                    steps, first_at, done_at = _simulate(spec, truth, rng, noise, factor)
                    t0 = start + CLOCK["a"]
                    ends, late_send = [], None
                    for st in steps:
                        if late_send is None and any(late for _, _, late in spec) and st["P"] and st["n"]:
                            late_send = t0 - CLOCK["a"]
                        omitted = CLOCK["b"] if st["P"] else CLOCK["b_prime"]
                        lines.append(_line(it, st["cr"], st["P"], st["n"], st["T"] - omitted))
                        it += 1
                        t0 += st["T"]
                        ends.append(t0)
                    for i, (L, cap, late) in enumerate(spec):
                        send = late_send if late else start
                        offset = round(send)
                        trace.append(dict(index=idx, offsetMs=offset, tenant="premium-1", maxOutputTokens=cap))
                        raw.append(dict(index=idx, engineInputTokens=L, engineOutputTokens=cap,
                                        sendUnixNanos=int(offset * 1e6),
                                        firstTokenUnixNanos=int((ends[first_at[i]] - (offset - send)) * 1e6),
                                        endUnixNanos=int((ends[done_at[i]] + CLOCK["d_end"] - (offset - send)) * 1e6)))
                        idx += 1
            arm = f"{kind}-log"
            for name, rows in ((f"trace-{arm}-{b}.jsonl", trace), (f"raw-{arm}-{b}.jsonl", raw)):
                with open(os.path.join(run, name), "w") as f:
                    f.writelines(json.dumps(r) + "\n" for r in rows)
            with open(os.path.join(run, f"engine-log-{arm}-{b}.txt"), "w") as f:
                f.write("\n".join(lines) + "\n")
            for which in ("before", "after"):
                with open(os.path.join(run, f"engine-metrics-{arm}-{b}-{which}.prom"), "w") as f:
                    f.write('vllm:num_preemptions_total{engine="0"} 2\n')


def _expected(truth, context):
    return dict(zip(columns(context), [truth["c"], *truth["s"], truth["d1"], truth["d2"], truth["m"]]
                    + ([truth["k"]] if context else [])))


def _close(got, want, rel):
    return all(abs(got[k] - v) <= rel * abs(v) + 1e-9 for k, v in want.items())


def self_test():
    import tempfile

    def refuses(what, fn, words):
        try:
            fn()
        except Refusal as e:
            assert words in str(e), f"{what}: refused for another reason -- {e}"
            print(f"ok: refuses {what} -- {e}")
            return
        raise AssertionError(f"{what} was accepted")

    with tempfile.TemporaryDirectory() as run:
        _synthetic_run(run)
        clean = run_fit(run)
        assert abs(clean["clock"]["b"] - CLOCK["b"]) < 1e-6 and abs(clean["clock"]["b_prime"] - CLOCK["b_prime"]) < 1e-6
        assert _close(clean["coefficients"], _expected(TRUTH, False), 1e-5), clean["coefficients"]
        print(f"ok: noise-free, every coefficient recovered within 1e-5 relative; condition {clean['condition']:.1f} "
              f"on the registered design; b {clean['clock']['b']:.3f}, b' {clean['clock']['b_prime']:.3f} ms; worst "
              f"held-out error {max(abs(r[4]) for r in clean['heldout']):.1e}")
        assert abs(clean["weight_total"] - clean["train_settings"]) < 1e-9, clean["weight_total"]
        print(f"ok: {clean['train_settings']} training settings carry total weight {clean['weight_total']:.6f}, one each")
        eps = load_episodes(run)
        b, bp = clean["clock"]["b"], clean["clock"]["b_prime"]

        refuses("a rank-deficient design (no step above 1,024 context tokens)",
                lambda: fit([e for e in eps if all(st["P"] <= 1024 for st in e["steps"])], b, bp), "rank-deficient")
        # c, n and n^2 at n of 30 to 32 only are nearly collinear without being exactly so.
        squeezed = [dict(setting=("x", P, n), block=1, pos=i, steps=[dict(P=P, n=n, K=0, elapsed=_true_step(P, n, 0, TRUTH))])
                    for P in (0, 128, 384, 768, 1536) for n in ((30, 31, 32) if P == 0 else (0, 30)) for i in range(3)]
        refuses("an ill-conditioned design", lambda: fit(squeezed, 0.0, 0.0), "condition number")
        target = sorted((e for e in eps if e["setting"] == ("burst", 4, 2048, 64)), key=lambda e: (e["block"], e["pos"]))
        some = [e for e in eps if e not in target[2:]]
        refuses("a setting with two episodes", lambda: fit(some, b, bp), "too few episodes")
        # With n of 0 or 1 only, the n and n^2 columns are equal: no zero column, but a zero eigenvalue.
        binary = [dict(e, setting=("y",) + e["setting"][1:]) for e in squeezed if e["setting"][2] in (0, 30)]
        for e in binary:
            e["steps"] = [dict(st, n=min(st["n"], 1)) for st in e["steps"]]
        refuses("a design with two identical columns", lambda: fit(binary, 0.0, 0.0),
                "some column is a combination")

    with tempfile.TemporaryDirectory() as run:
        _synthetic_run(run)
        path = os.path.join(run, "engine-log-burst-log-2.txt")
        ls = open(path).read().splitlines()
        i = next(j for j, l in enumerate(ls) if "0 context requests, 0 context tokens, 4 generation requests" in l)
        ls[i] = ls[i].replace("4 generation requests, 4 generation tokens", "3 generation requests, 3 generation tokens")
        with open(path, "w") as f:
            f.write("\n".join(ls) + "\n")
        refuses("a step whose decoder count the replay does not reproduce", lambda: load_episodes(run),
                "replayed in order")

    with tempfile.TemporaryDirectory() as run:
        _synthetic_run(run, slow={("burst", 4, 2048, 64): 1.25})
        refuses("a held-out setting 25% slower than its training episodes", lambda: run_fit(run), "held-out setting")
        # The slowed episodes are all held out, so with the bound lifted the coefficients must be the clean fit's.
        # Any difference is a slowed episode in the training set.
        clk = clock(run)
        lifted = fit(load_episodes(run), clk["b"], clk["b_prime"], bound=math.inf)
        assert _close(lifted["coefficients"], clean["coefficients"], 1e-9), "a held-out episode reached the training set"
        print("ok: with the bound lifted the coefficients equal the clean fit's, so no held-out episode was trained on")

    with tempfile.TemporaryDirectory() as run:
        _synthetic_run(run, noise=0.01, seed=5)
        noisy = run_fit(run)
        assert _close({k: noisy["coefficients"][k] for k in ("c", "d1")}, {"c": TRUTH["c"], "d1": TRUTH["d1"]}, 0.05), noisy
        print(f"ok: 1% step noise passes, worst held-out error {max(abs(r[4]) for r in noisy['heldout']):.2%}, "
              f"c {noisy['coefficients']['c']:.3f} (true {TRUTH['c']}), d1 {noisy['coefficients']['d1']:.4f}")

    # Large enough that leaving the term out moves a held-out setting beyond 10%; at k = 5e-5 it does not (worst 8.3%),
    # so the held-out bound alone cannot decide whether the family needs the term -- gate I4 has to.
    ctx_truth = dict(TRUTH, k=0.0002)
    with tempfile.TemporaryDirectory() as run:
        _synthetic_run(run, truth=ctx_truth)
        got = run_fit(run, context=True)
        assert _close(got["coefficients"], _expected(ctx_truth, True), 1e-5), got["coefficients"]
        assert not [t for t in got["trained"] if t[0] == "stagger"], got["trained"]
        assert any(r[0][0] == "stagger" for r in got["heldout"]), got["heldout"]
        print(f"ok: with a context term, k {got['coefficients']['k']:.3g} ms/token recovered from serial and burst "
              f"steps alone; staggered episodes predicted within {max(abs(r[4]) for r in got['heldout'] if r[0][0] == 'stagger'):.1e}")
        refuses("the same archive fitted without the context term it needs", lambda: run_fit(run), "held-out setting")


def main(argv):
    if argv[1:] == ["--self-test"]:
        self_test()
        return
    args = argv[1:]
    context = "--context" in args
    args = [a for a in args if a != "--context"]
    mixed = "b"
    if "--mixed-omitted" in args:
        i = args.index("--mixed-omitted")
        if i + 1 >= len(args) or args[i + 1] not in ("b", "b-prime"):
            sys.exit(__doc__)
        mixed = args[i + 1]
        del args[i:i + 2]
    if len(args) != 1:
        sys.exit(__doc__)
    out = run_fit(args[0], context, mixed)
    out["heldout"] = [dict(setting=list(s), episodes=k, observed_ms=o, predicted_ms=p, error=e)
                      for s, k, o, p, e in out["heldout"]]
    out["clock"]["b_decode"] = {str(k): v for k, v in out["clock"]["b_decode"].items()}
    print(json.dumps(out, indent=2))


if __name__ == "__main__":
    try:
        main(sys.argv)
    except Refusal as e:
        sys.exit(f"REFUSED: {e}")
