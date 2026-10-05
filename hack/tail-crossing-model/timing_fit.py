"""The reduced timing family, fitted on held-out episodes from the logged synchronous cells of one archive.

Registered in docs/superpowers/specs/2026-10-05-a-timing-family-fitted-from-the-iteration-log.md, the pass branch of
docs/superpowers/specs/2026-10-05-can-the-stock-engine-time-an-iteration-instrument-validation.md.

    step_ms = c + f(P) + d1*n + d2*n^2 + m*P*n + h*sum(p_i*C_i)   [+ k*K_d when I4 requires it]

P is the context tokens scheduled in the step, n the generation requests, f piecewise linear with knots at 0, 256,
512, 1,024 and 2,048 and f(0) = 0, p_i request i's prompt tokens in the step and C_i its prompt tokens processed
before it, and K_d the summed context of the step's decoders.
The left side is not the logged elapsed_ms but elapsed_ms plus the per-step time the timer omits, from the clock fit
in iterlog.fit_clock on the serial training episodes.

    python3 timing_fit.py ARCHIVE/m5c-run                    # the registered verdict
    python3 timing_fit.py ARCHIVE/m5c-run --flip-context     # a labelled sensitivity run, never the verdict
    python3 timing_fit.py --self-test

Exit status: 0 PASS, 1 FAIL, 3 UNRESOLVED; a refusal exits with its message.
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
CYCLES = (1, 2, 3)
ARMS = ("serial-log", "burst-log", "stagger-log")
SEED = 20261005
BOOT = 200
MAX_CONDITION = 100.0
MAX_HELDOUT_ERROR = 0.10
# Relative to the largest eigenvalue of the column-normalised Gram matrix; below it a column is a combination of others.
RANK_TOL = 1e-10
# instrument_gates.context_effect appends these words to an I4 line exactly when |I4| > 5%.
# The decision is read from that function's own output, so this fit and the published I4 cannot disagree.
CONTEXT_MARK = "the timing family needs a context term"
NOT_INTERPRETED = ("coefficients are not individually interpreted: a pass establishes a predictor of step time for "
                   "this engine and these settings, not measured physical costs")
STAGGER_LABEL = "conditional on the send-order reconstruction of decoder and prompt contexts"


def registered_settings():
    """The settings internal/bench/episodes.go generates, as this fit names them; the matrix must hold all of them."""
    s = {("serial", L, c) for L in (256, 512, 1024, 2048, 4096, 8192) for c in (1, 16, 64)}
    s |= {("burst", n, L, 64) for n in (1, 4, 16) for L in (256, 2048, 8192)} | {("burst", 64, 256, 64)}
    s |= {("stagger", n, c, p) for n in (1, 4, 16) for c in (256, 8192) for p in (256, 8192)}
    return s


def columns(context):
    names = ["c"] + [f"f[{a}-{b}]" for a, b in zip(KNOTS, KNOTS[1:])] + ["d1", "d2", "m", "h"]
    return names + (["k"] if context else [])


def features(st, context):
    """One step's row of the design.

    f is written as the sum of its segments, each clamped to its own knot interval, so a coefficient is that
    segment's slope in ms per token, f(0) = 0 holds by construction, and nonnegative slopes make f nondecreasing.
    """
    P, n = st["P"], st["n"]
    if P > BUDGET:
        raise Refusal(f"a step schedules {P} context tokens, above the {BUDGET}-token budget the knots end at")
    row = [1.0] + [float(min(max(P - a, 0), b - a)) for a, b in zip(KNOTS, KNOTS[1:])]
    row += [float(n), float(n * n), float(P * n), float(st["H"])]
    return row + ([float(st["K"])] if context else [])


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
    """Each step's P, n, decoder context K_d and earlier-chunk load H, replayed from step order alone.

    The log carries no request ids, so the contexts are rebuilt by walking the episode's steps in order.
    Requests are taken first come, first served by send time, which is how v0.27.1's scheduler admits them; the
    logged context tokens of a step are dealt to the requests whose prompts are not yet fully scheduled, in that
    order, and a request whose prompt is completed in a step has produced its first token by the end of it.
    A decoder in a later step has produced g tokens before the step, so the step attends over L + g of its tokens
    (its prompt, the g - 1 tokens already in the cache, and the one it is fed now), and K_d is the sum of L + g over
    the step's decoders.
    A request dealt p tokens of its prompt after C of them were processed in earlier steps attends p new tokens over
    C cached ones, and H is the sum of p * C over the step's prompts.
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
        P, dealt, finished, H = s["ctx_tokens"], 0, [], 0
        for i in range(len(order)):
            if P == 0:
                break
            if left[i] > 0:
                take = min(left[i], P)
                H += take * (order[i]["input_tokens"] - left[i])
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
        out.append(dict(P=s["ctx_tokens"], n=s["gen_reqs"], K=K, H=H, elapsed=s["elapsed_ms"]))
    unfinished = [order[i]["index"] for i in range(len(order)) if left[i] or made[i] != order[i]["output_tokens"]]
    if unfinished:
        raise Refusal(f"the episode's steps end with request(s) {unfinished[:3]} not finished as the client saw them")
    return out


def load_episodes(run):
    """Every logged synchronous episode, with its setting, block, cycle and steps.

    The cycle of an episode is its occurrence of that setting within its cell, counted in send order: the generator
    places each setting exactly once per cycle, and check_matrix refuses any cell where that does not hold.
    A failed request, a preemption, a missing or repeated iteration and an episode whose steps overlap another's
    refuse here as well as in the gates, because this loader does not go through them.
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
            eps, seen = episodes_of(kind, reqs), {}
            for pos, ((setting, ep), steps) in enumerate(zip(eps, instrument_gates.segment(iters, [e for _, e in eps]))):
                seen[setting] = seen.get(setting, 0) + 1
                out.append(dict(setting=setting, block=b, cycle=seen[setting], pos=pos,
                                reqs=[q["index"] for q in ep], steps=reconstruct(ep, steps)))
    return out


def check_matrix(episodes):
    """Exactly the registered settings, each nine times, three in every block; anything else is not the design."""
    want = registered_settings()
    have = {e["setting"] for e in episodes}
    if have != want:
        raise Refusal(f"incomplete matrix: settings missing {sorted(want - have, key=str)[:3]}, unregistered "
                      f"{sorted(have - want, key=str)[:3]}")
    count = {}
    for e in episodes:
        count[(e["setting"], e["block"])] = count.get((e["setting"], e["block"]), 0) + 1
    bad = [(s, b, count.get((s, b), 0)) for s in sorted(want, key=str) for b in BLOCKS if count.get((s, b), 0) != 3]
    if bad:
        raise Refusal(f"incomplete matrix: every setting needs exactly 3 episodes in each of blocks {BLOCKS}, and "
                      f"{len(bad)} (setting, block) pair(s) do not have them, e.g. {bad[:2]}")


def heldout_cycle(setting, block):
    """The cycle held out of this setting in this block.

    A permutation of the three cycles per setting, seeded by the registration's seed and the setting's name, so
    each block holds out a different cycle and every cycle position sits on both sides of the split.
    A string seed is hashed by SHA-512 in Python 3, so this is the same on every machine and every run.
    """
    return random.Random(f"{SEED}/{setting!r}").sample(CYCLES, 3)[block - 1]


def split(episodes):
    """Training and predicted episodes, by whole episode, never by step.

    Serial episodes, as homogeneous bursts of one, and burst episodes train, less the rotating held-out cycle.
    Staggered episodes are never trained on: they are the out-of-sample test of two kinds of work in one step, and
    all nine are predicted.
    """
    train, held = {}, {}
    for e in sorted(episodes, key=lambda e: (e["block"], e["pos"])):
        s = e["setting"]
        out = s[0] == "stagger" or e["cycle"] == heldout_cycle(s, e["block"])
        (held if out else train).setdefault(s, []).append(e)
    return train, held


def clock(run, keep=None):
    """b and b' by iterlog's section-3 clock, from the serial requests in keep, a set of (block, request index).

    Attribution walks a whole cell's log, so every serial request is attributed; only the kept ones are fitted.
    The caller passes the serial training episodes' requests, so no held-out client time reaches a training target.
    b' is fitted per input length; the instrument page's I3 bounds how far those differ, and their mean is used.
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
        attributed += [r for r in iterlog.attribute_serial(iters, reqs) if keep is None or (b, r["index"]) in keep]
    fit = iterlog.fit_clock(attributed)
    b_prime = sum(fit["b_decode"].values()) / len(fit["b_decode"])
    # An omitted time below zero would make a step shorter than the part of it the timer saw, which no engine does;
    # it means the clock fit is wrong, and adding it back would publish a duration built on that.
    if fit["b"] < 0 or b_prime < 0:
        raise Refusal(f"the clock gives a negative omitted time (b {fit['b']:.3f} ms, b' {b_prime:.3f} ms)")
    return dict(a=fit["a"], b=fit["b"], b_prime=b_prime, b_decode={str(k): v for k, v in fit["b_decode"].items()},
                requests=len(attributed))


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
    """Cyclic Jacobi rotations on a symmetric matrix; small enough here (at most eleven columns) to run to convergence."""
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
    The nominal convention gives it b, because b is defined per context step of a request whatever shares the step;
    the registration runs b' on mixed steps as well, every time, and a disagreement makes the verdict unresolved.
    """
    if step["P"] == 0:
        return step["elapsed"] + b_prime
    if step["n"] == 0:
        return step["elapsed"] + b
    return step["elapsed"] + (b if mixed == "b" else b_prime)


def episode_sums(e, b, b_prime, mixed, context):
    """An episode's contribution to the normal equations, unweighted: sum x x', sum x y and its step count."""
    p = len(columns(context))
    G, h = [[0.0] * p for _ in range(p)], [0.0] * p
    for st in e["steps"]:
        x, y = features(st, context), true_ms(st, b, b_prime, mixed)
        for i in range(p):
            h[i] += x[i] * y
            for j in range(p):
                G[i][j] += x[i] * x[j]
    return G, h, len(e["steps"])


def normal_equations(train, sums, p):
    """Each setting carries total weight one, whatever its step count.

    A 16-decoder burst at 8,192 tokens has thirty times the steps of a lone 256-token request, and would otherwise
    choose the coefficients alone.
    """
    G, h = [[0.0] * p for _ in range(p)], [0.0] * p
    for s, eps in train.items():
        steps = sum(sums[id(e)][2] for e in eps)
        for e in eps:
            Ge, he, _ = sums[id(e)]
            for i in range(p):
                h[i] += he[i] / steps
                for j in range(p):
                    G[i][j] += Ge[i][j] / steps
    return G, h


def solve_normalised(G, h, names, check):
    p = len(names)
    norms = [math.sqrt(G[i][i]) for i in range(p)]
    dead = [names[i] for i in range(p) if norms[i] == 0.0]
    if dead:
        raise Refusal(f"rank-deficient design: no training step moves column(s) {dead}")
    Gn = [[G[i][j] / (norms[i] * norms[j]) for j in range(p)] for i in range(p)]
    cond = None
    if check:
        lam = eigenvalues(Gn)
        if lam[0] <= RANK_TOL * lam[-1]:
            raise Refusal(f"rank-deficient design: the column-normalised Gram matrix has eigenvalue {lam[0]:.3g} "
                          f"against {lam[-1]:.3g}, so some column is a combination of the others")
        cond = math.sqrt(lam[-1] / lam[0])
        if cond > MAX_CONDITION:
            raise Refusal(f"the column-normalised design has condition number {cond:.1f}, above {MAX_CONDITION:g}: "
                          f"the coefficients trade off against each other and no one of them is determined")
    gamma = nnls(Gn, [h[i] / norms[i] for i in range(p)])
    return [g / n for g, n in zip(gamma, norms)], cond


def _err(steps, beta, b, b_prime, mixed, context):
    obs = sum(true_ms(st, b, b_prime, mixed) for st in steps) / len(steps)
    pred = sum(sum(c * x for c, x in zip(beta, features(st, context))) for st in steps) / len(steps)
    return dict(observed_ms=obs, predicted_ms=pred, error=pred / obs - 1, steps=len(steps))


def fit(train, held, b, b_prime, context, mixed, bound=MAX_HELDOUT_ERROR, boot=BOOT):
    """One fit and its verdict on the predicted episodes.

    A structural failure -- an unidentified design -- refuses; a prediction outside the bound is a "fail" verdict, so
    the caller can set the two mixed-step conventions side by side.
    The check is per setting and per phase: steps carrying context tokens and pure-decode steps are held to the
    bound separately, because a pooled mean lets opposite errors cancel and lets hundreds of decode steps dilute a
    few prefill steps.
    """
    names = columns(context)
    p = len(names)
    sums = {id(e): episode_sums(e, b, b_prime, mixed, context) for eps in train.values() for e in eps}
    G, h = normal_equations(train, sums, p)
    beta, cond = solve_normalised(G, h, names, check=True)
    report, failures = [], []
    for s, eps in sorted(held.items(), key=lambda kv: str(kv[0])):
        steps = [st for e in eps for st in e["steps"]]
        phases = {}
        for phase, keep in (("context", lambda st: st["P"] > 0), ("decode", lambda st: st["P"] == 0)):
            mine = [st for st in steps if keep(st)]
            if mine:
                phases[phase] = _err(mine, beta, b, b_prime, mixed, context)
                if abs(phases[phase]["error"]) > bound:
                    failures.append(f"{s} {phase} steps: predicted {phases[phase]['predicted_ms']:.3f} ms against "
                                    f"{phases[phase]['observed_ms']:.3f} ms, {phases[phase]['error']:+.1%}")
        item = dict(setting=list(s), phases=phases, pooled_published_not_gated=_err(steps, beta, b, b_prime, mixed, context),
                    blocks={str(bl): _err([st for e in eps if e["block"] == bl for st in e["steps"]], beta, b, b_prime,
                                          mixed, context)["error"] for bl in BLOCKS if any(e["block"] == bl for e in eps)},
                    episodes=[dict(block=e["block"], cycle=e["cycle"],
                                   error=_err(e["steps"], beta, b, b_prime, mixed, context)["error"]) for e in eps])
        if s[0] == "stagger":
            item["label"] = STAGGER_LABEL
        report.append(item)
    # Whole episodes are resampled within each training setting, the way the split assigns them.
    rng = random.Random(SEED)
    draws = []
    for _ in range(boot):
        resampled = {s: rng.choices(eps, k=len(eps)) for s, eps in sorted(train.items(), key=lambda kv: str(kv[0]))}
        Gb, hb = normal_equations(resampled, sums, p)
        draws.append(solve_normalised(Gb, hb, names, check=False)[0])
    intervals = {}
    for i, n in enumerate(names):
        v = sorted(d[i] for d in draws)
        intervals[n] = [v[int(0.025 * boot)], v[int(0.975 * boot) - 1]] if boot else None
    return dict(verdict="fail" if failures else "pass", failures=failures, mixed_omitted=mixed,
                coefficients=dict(zip(names, beta)), intervals_95=intervals,
                at_zero=[n for n, v in zip(names, beta) if v == 0.0], condition=cond,
                # The intercept column is 1 on every step, so its Gram entry is the total weight the fit used.
                weight_total=G[0][0], trained=[list(s) for s in sorted(train, key=str)], heldout=report)


def combine(nominal, sensitivity):
    """Both conventions must agree: neither clock measures a mixed step, so a split verdict is not either one."""
    if nominal == sensitivity:
        return nominal.upper()
    return "UNRESOLVED"


def context_decision(run):
    lines = instrument_gates.context_effect(run)
    # No I4 line means I4 was not computable, and an unread context effect is not an absent one.
    if not lines:
        raise Refusal("I4 produced no line, so whether the family needs a context term is not decided")
    return any(CONTEXT_MARK in l for l in lines), lines


def run_fit(run, flip_context=False, boot=BOOT, gates=None):
    # gates is replaced only by the self-test, to show that a failing verdict refuses.
    passed, gate_lines = (gates or instrument_gates.evaluate)(run)
    if not passed:
        raise Refusal(f"the instrument gates do not pass on this archive ({gate_lines[-1]}), so there is no "
                      f"established quantity to fit")
    eps = load_episodes(run)
    check_matrix(eps)
    train, held = split(eps)
    keep = {(e["block"], i) for s, v in train.items() if s[0] == "serial" for e in v for i in e["reqs"]}
    clk = clock(run, keep)
    needs, i4 = context_decision(run)
    context = needs != flip_context
    nominal = fit(train, held, clk["b"], clk["b_prime"], context, "b", boot=boot)
    sensitivity = fit(train, held, clk["b"], clk["b_prime"], context, "b-prime", boot=boot)
    return dict(
        verdict=combine(nominal["verdict"], sensitivity["verdict"]),
        run=("SENSITIVITY: the context term is forced opposite to I4's decision; this is not the registered verdict"
             if flip_context else "registered"),
        verdicts={"mixed steps + b (nominal)": nominal["verdict"], "mixed steps + b' (sensitivity)": sensitivity["verdict"]},
        context_term=context, i4_requires_context=needs, i4=i4, gates=gate_lines, clock=clk,
        note=NOT_INTERPRETED, stagger=f"staggered predictions are {STAGGER_LABEL}",
        nominal=nominal, sensitivity=sensitivity)


# ---------------------------------------------------------------------------------------------------------------
# Self-test on synthetic archives whose coefficients are known

TRUTH = dict(c=12.0, s=(0.13, 0.12, 0.115, 0.11), d1=0.15, d2=0.002, m=0.00002, h=2e-6, k=0.0)
CLOCK = dict(a=6.0, b=1.5, b_prime=1.2, d_end=3.0)


def _true_step(P, n, K, H, t):
    f = sum(sl * min(max(P - a, 0), b - a) for sl, (a, b) in zip(t["s"], zip(KNOTS, KNOTS[1:])))
    return t["c"] + f + t["d1"] * n + t["d2"] * n * n + t["m"] * P * n + t["h"] * H + t["k"] * K


def _simulate(spec, t, rng, noise, slow):
    """A forward scheduler, written apart from reconstruct() so a shared mistake is not a shared blind spot.

    spec is a list of (input tokens, cap, is_late); a late request arrives once every earlier one has produced four
    tokens, which is the staggered episode's shape.
    Running decoders take one token of the budget each, then prompts are scheduled first come, first served.
    slow is (factor, phase): the factor applies to that phase's steps, "context", "decode" or "all".
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
        budget, P, cr, completed, H = BUDGET - len(dec), 0, 0, [], 0
        for i in range(len(spec)):
            if arrived[i] and rem[i] and budget:
                take = min(rem[i], budget)
                H += take * (spec[i][0] - rem[i])
                rem[i] -= take
                budget -= take
                P += take
                cr += 1
                if rem[i] == 0:
                    completed.append(i)
        K = sum(spec[i][0] + prod[i] for i in dec)
        factor, phase = slow
        hit = phase == "all" or (phase == "context") == (P > 0)
        T = _true_step(P, len(dec), K, H, t) * (1 + rng.gauss(0, noise)) * (factor if hit else 1.0)
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


def _write(run, name, rows):
    with open(os.path.join(run, name), "w") as f:
        f.writelines(json.dumps(r) + "\n" for r in rows)


def _synthetic_run(run, truth=TRUTH, noise=0.0, slow=None, seed=3, clk=CLOCK, mixed_truth="b", nolog_ttft=1.0,
                   omit=None):
    """Three blocks of the six synchronous arms, every registered setting three times a cell, from known coefficients.

    slow maps a setting to (factor, phase), applied to the episodes the split holds out of that setting.
    mixed_truth is the omitted time the synthetic engine really has on a mixed step.
    nolog_ttft scales the logging-off cells' TTFT, to make the instrument gates fail.
    omit is a setting left out of block 2's first cycle, so the archive is one episode short.
    """
    rng, slow = random.Random(seed), slow or {}
    for kind in ("serial", "burst", "stagger"):
        for b in BLOCKS:
            cyc, trace, raw, lines, it, idx, ep_no = _cycle(kind), [], [], [], 50, 0, 0
            for cycle in CYCLES:
                for spec in rng.sample(cyc, len(cyc)):
                    start = ep_no * 100_000
                    ep_no += 1
                    s = _setting(kind, spec)
                    if s == omit and b == 2 and cycle == 1:
                        continue
                    sl = slow.get(s, (1.0, "all")) if cycle == heldout_cycle(s, b) else (1.0, "all")
                    steps, first_at, done_at = _simulate(spec, truth, rng, noise, sl)
                    t0 = start + clk["a"]
                    ends, late_send = [], None
                    for st in steps:
                        if late_send is None and any(late for _, _, late in spec) and st["P"] and st["n"]:
                            late_send = t0 - clk["a"]
                        mixed = st["P"] and st["n"]
                        omitted = (clk[mixed_truth.replace("-", "_")] if mixed else clk["b"]) if st["P"] else clk["b_prime"]
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
                                        endUnixNanos=int((ends[done_at[i]] + clk["d_end"] - (offset - send)) * 1e6)))
                        idx += 1
            off = []
            for r in raw:
                shift = int((r["firstTokenUnixNanos"] - r["sendUnixNanos"]) * (nolog_ttft - 1))
                off.append(dict(r, firstTokenUnixNanos=r["firstTokenUnixNanos"] + shift, endUnixNanos=r["endUnixNanos"] + shift))
            for suffix, rows in (("log", raw), ("nolog", off)):
                arm = f"{kind}-{suffix}"
                _write(run, f"trace-{arm}-{b}.jsonl", trace)
                _write(run, f"raw-{arm}-{b}.jsonl", rows)
                for which in ("before", "after"):
                    with open(os.path.join(run, f"engine-metrics-{arm}-{b}-{which}.prom"), "w") as f:
                        f.write('vllm:num_preemptions_total{engine="0"} 2\n')
            with open(os.path.join(run, f"engine-log-{kind}-log-{b}.txt"), "w") as f:
                f.write("\n".join(lines) + "\n")


def _expected(truth, context):
    return dict(zip(columns(context), [truth["c"], *truth["s"], truth["d1"], truth["d2"], truth["m"], truth["h"]]
                    + ([truth["k"]] if context else [])))


def _close(got, want, rel):
    return all(abs(got[k] - v) <= rel * abs(v) + 1e-9 for k, v in want.items())


def _worst(r, phase=None):
    return max(abs(it["phases"][ph]["error"]) for it in r["heldout"] for ph in it["phases"] if phase in (None, ph))


def _PASSED(run):
    return True, ["gates stubbed as passed by the self-test"]


def self_test():
    """Synthetic archives, scored with the instrument gates stubbed as passed except where the gates are the subject.

    The real gates fail these archives on I1 with no logging overhead at all: within a burst or a staggered episode
    the requests' TTFTs differ by design (the sixteenth request of a burst waits for fifteen prompts), and resampling
    requests within a setting independently in the on and off cells widens the burst interval to about +-8%.
    That is a property of the gate, reported to the registration, not something this fit can repair.
    """
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
        clean = run_fit(run, gates=_PASSED)
        nom = clean["nominal"]
        assert clean["verdict"] == "PASS", (clean["verdict"], nom["failures"], clean["sensitivity"]["failures"])
        assert abs(clean["clock"]["b"] - CLOCK["b"]) < 1e-6 and abs(clean["clock"]["b_prime"] - CLOCK["b_prime"]) < 1e-6
        assert _close(nom["coefficients"], _expected(TRUTH, False), 1e-5), nom["coefficients"]
        assert not clean["context_term"] and not clean["i4_requires_context"], clean["i4"]
        print(f"ok: I4 {clean['i4'][-1].split(': ', 1)[1][:60]}... -> no context term")
        print(f"ok: noise-free, every coefficient recovered within 1e-5 relative, h {nom['coefficients']['h']:.3g} "
              f"included; condition {nom['condition']:.1f}; b {clean['clock']['b']:.3f}, b' {clean['clock']['b_prime']:.3f} "
              f"ms from {clean['clock']['requests']} serial training requests; worst held-out phase error "
              f"{_worst(nom):.1e}; verdicts {clean['verdicts']}")
        assert abs(nom["weight_total"] - len(nom["trained"])) < 1e-9, nom["weight_total"]
        assert not [t for t in nom["trained"] if t[0] == "stagger"], nom["trained"]
        stag = [it for it in nom["heldout"] if it["setting"][0] == "stagger"]
        assert len(stag) == 12 and all(it["label"] == STAGGER_LABEL and len(it["episodes"]) == 9 for it in stag)
        print(f"ok: {len(nom['trained'])} training settings, weight {nom['weight_total']:.6f}, none staggered; all 12 "
              f"staggered settings predicted from 9 episodes each and labelled conditional")
        # Noise-free, every resample gives the estimate up to rounding, so the bracket is checked to 1e-9 relative.
        assert all(lo - 1e-9 * abs(v) <= v <= hi + 1e-9 * abs(v) for n, (lo, hi) in nom["intervals_95"].items()
                   for v in [nom["coefficients"][n]])
        assert NOT_INTERPRETED in clean["note"]
        print(f"ok: bootstrap intervals bracket every estimate; c in [{nom['intervals_95']['c'][0]:.4f}, "
              f"{nom['intervals_95']['c'][1]:.4f}]; at zero {nom['at_zero']}; note printed")
        for s, n in ((("serial", 8192, 16), 6), (("burst", 64, 256, 64), 6)):
            eps = [e for it in nom["heldout"] if tuple(it["setting"]) == s for e in it["episodes"]]
            assert len(eps) == 3 and sorted(e["block"] for e in eps) == [1, 2, 3], eps
        eps = load_episodes(run)
        train, held = split(eps)
        for s in registered_settings() - {x for x in registered_settings() if x[0] == "stagger"}:
            hc = sorted(e["cycle"] for e in held[s])
            tc = sorted(e["cycle"] for e in train[s])
            assert len(held[s]) == 3 and len(train[s]) == 6 and hc == [1, 2, 3] and tc == [1, 1, 2, 2, 3, 3], (s, hc, tc)
        print("ok: in every training setting one episode per block is held out, its cycle rotating: 6 train, 3 held, "
              "every cycle on both sides")
        b, bp = clean["clock"]["b"], clean["clock"]["b_prime"]

        refuses("an incomplete matrix (one episode dropped)", lambda: check_matrix(eps[1:]), "incomplete matrix")
        refuses("an incomplete matrix (an episode repeated)", lambda: check_matrix(eps + eps[:1]), "incomplete matrix")
        refuses("an incomplete matrix (a setting absent)",
                lambda: check_matrix([e for e in eps if e["setting"] != ("burst", 64, 256, 64)]), "incomplete matrix")
        low = [e for e in eps if all(st["P"] <= 1024 for st in e["steps"])]
        refuses("a rank-deficient design (no step above 1,024 context tokens)",
                lambda: fit(*split(low), b, bp, False, "b", boot=0), "rank-deficient")

        def hand(rows, tag):
            return [dict(setting=(tag, P, n), block=bl, cycle=cy, pos=0, reqs=[],
                         steps=[dict(P=P, n=n, K=0, H=H, elapsed=_true_step(P, n, 0, H, TRUTH))])
                    for P, n, H in rows for bl in BLOCKS for cy in CYCLES]
        base = [(P, 0, 0) for P in (128, 384, 768, 1536)] + [(2048, 0, 2048 * 2048), (2048, 0, 2048 * 4096)]
        # c, n and n^2 at n of 30 to 32 only are nearly collinear without being exactly so.
        squeezed = hand(base + [(0, n, 0) for n in (30, 31, 32)] + [(P, 30, 0) for P in (128, 384, 768, 1536)], "x")
        refuses("an ill-conditioned design", lambda: fit(*split(squeezed), 0.0, 0.0, False, "b", boot=0), "condition number")
        # With n of 0 or 1 only, the n and n^2 columns are equal: no zero column, but a zero eigenvalue.
        binary = hand(base + [(0, 1, 0)] + [(P, 1, 0) for P in (128, 384, 768, 1536)], "y")
        refuses("a design with two identical columns", lambda: fit(*split(binary), 0.0, 0.0, False, "b", boot=0),
                "some column is a combination")

    with tempfile.TemporaryDirectory() as run:
        _synthetic_run(run)
        refuses("an archive whose gates verdict is FAIL", lambda: run_fit(run, boot=0, gates=lambda r: (False, ["FAIL: I3"])),
                "instrument gates do not pass")
        # The default is the real evaluator on the same directory.
        # It failed I1 on these archives until I1 ranked a burst's requests within their episode; this case pinned
        # that failure, and now holds the opposite: the whole path, real gates included, reaches a passing fit.
        real = run_fit(run, boot=0)
        assert real["verdict"] == "PASS", real["verdict"]
        print("ok: the same archive under the real instrument_gates.evaluate passes the gates and the fit")

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
        _synthetic_run(run, omit=("serial", 2048, 16))
        refuses("an archive one episode short", lambda: run_fit(run, boot=0, gates=_PASSED), "incomplete matrix")

    with tempfile.TemporaryDirectory() as run:
        _synthetic_run(run, slow={("burst", 4, 2048, 64): (1.25, "all")})
        r = run_fit(run, boot=0, gates=_PASSED)
        assert r["verdict"] == "FAIL", r["verdict"]
        print(f"ok: a held-out setting 25% slower -> FAIL in both conventions -- {r['nominal']['failures'][0]}")
        # The slowed episodes are exactly the held-out ones, so the coefficients must be the clean fit's.
        assert _close(r["nominal"]["coefficients"], nom["coefficients"], 1e-9), "a held-out episode reached the training set"
        print("ok: the coefficients equal the clean fit's, so no held-out episode was trained on")

    with tempfile.TemporaryDirectory() as run:
        _synthetic_run(run, slow={("serial", 8192, 16): (1.30, "decode")})
        r = run_fit(run, boot=0, gates=_PASSED)
        it = next(i for i in r["nominal"]["heldout"] if i["setting"] == ["serial", 8192, 16])
        assert r["verdict"] == "FAIL" and abs(it["pooled_published_not_gated"]["error"]) < MAX_HELDOUT_ERROR, it
        print(f"ok: decode steps of a held-out setting 30% slower -> FAIL on the decode phase "
              f"({it['phases']['decode']['error']:+.1%}) while the pooled mean is {it['pooled_published_not_gated']['error']:+.1%}")

    with tempfile.TemporaryDirectory() as run:
        _synthetic_run(run, clk=dict(CLOCK, b=25.0), mixed_truth="b-prime")
        r = run_fit(run, boot=0, gates=_PASSED)
        assert r["verdicts"]["mixed steps + b' (sensitivity)"] == "pass" and r["verdict"] == "UNRESOLVED", r["verdicts"]
        print(f"ok: an engine whose mixed steps omit b', with b = 25 ms -> {r['verdicts']} -> {r['verdict']}")
    assert combine("pass", "fail") == combine("fail", "pass") == "UNRESOLVED" and combine("fail", "fail") == "FAIL"

    with tempfile.TemporaryDirectory() as run:
        _synthetic_run(run)
        eps = load_episodes(run)
        train, held = split(eps)
        e = next(e for e in held[("serial", 8192, 16)])
        for arm in ("serial-log", "serial-nolog"):
            path = os.path.join(run, f"raw-{arm}-{e['block']}.jsonl")
            rows = [json.loads(l) for l in open(path)]
            for row in rows:
                if row["index"] in e["reqs"]:
                    d = int(0.03 * (row["firstTokenUnixNanos"] - row["sendUnixNanos"]))
                    row["firstTokenUnixNanos"] += d
                    row["endUnixNanos"] += d
            _write(run, os.path.basename(path), rows)
        r = run_fit(run, boot=0, gates=_PASSED)
        everything = clock(run)
        assert abs(r["clock"]["b"] - CLOCK["b"]) < 1e-6 and abs(everything["b"] - CLOCK["b"]) > 1e-3, (r["clock"], everything)
        print(f"ok: a held-out serial request's TTFT 3% longer leaves the fitted b at {r['clock']['b']:.4f} ms; "
              f"a clock on every serial request would read {everything['b']:.4f}")

    ctx_truth = dict(TRUTH, k=0.0002)
    with tempfile.TemporaryDirectory() as run:
        _synthetic_run(run, truth=ctx_truth)
        got = run_fit(run, boot=0, gates=_PASSED)
        assert got["context_term"] and got["i4_requires_context"] and got["verdict"] == "PASS", got["verdicts"]
        assert _close(got["nominal"]["coefficients"], _expected(ctx_truth, True), 1e-5), got["nominal"]["coefficients"]
        assert not [t for t in got["nominal"]["trained"] if t[0] == "stagger"]
        print(f"ok: I4 {[l.split(': ', 1)[1][:24] for l in got['i4']]} -> context term chosen, k "
              f"{got['nominal']['coefficients']['k']:.3g} recovered without staggered training")
        flip = run_fit(run, flip_context=True, boot=0, gates=_PASSED)
        assert flip["run"].startswith("SENSITIVITY") and not flip["context_term"] and flip["verdict"] == "FAIL", flip["verdicts"]
        print(f"ok: --flip-context is labelled sensitivity and, without the term, fails -- {flip['nominal']['failures'][0]}")

    with tempfile.TemporaryDirectory() as run:
        _synthetic_run(run, noise=0.01, seed=5)
        noisy = run_fit(run, gates=_PASSED)
        n = noisy["nominal"]
        assert noisy["verdict"] == "PASS", noisy["verdicts"]
        print(f"ok: 1% step noise -> {noisy['verdict']}, worst held-out phase error {_worst(n):.2%}; 95% intervals "
              + ", ".join(f"{k} [{lo:.3g}, {hi:.3g}]" for k, (lo, hi) in n["intervals_95"].items() if k in ("c", "d1", "m", "h")))


def main(argv):
    if argv[1:] == ["--self-test"]:
        self_test()
        return 0
    args = argv[1:]
    flip = "--flip-context" in args
    args = [a for a in args if a != "--flip-context"]
    if len(args) != 1:
        sys.exit(__doc__)
    out = run_fit(args[0], flip)
    print(json.dumps(out, indent=2))
    print(f"{out['run']}: {out['verdict']} -- {out['verdicts']}; context term {out['context_term']}", file=sys.stderr)
    print(out["note"], file=sys.stderr)
    return {"PASS": 0, "FAIL": 1}.get(out["verdict"], 3)


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except Refusal as e:
        sys.exit(f"REFUSED: {e}")
