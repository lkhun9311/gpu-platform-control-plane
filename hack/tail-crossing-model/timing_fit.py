"""The reduced timing family, fitted on held-out episodes from the logged synchronous cells of one archive.

Registered in docs/superpowers/specs/2026-10-05-a-timing-family-fitted-from-the-iteration-log.md, the pass branch of
docs/superpowers/specs/2026-10-05-can-the-stock-engine-time-an-iteration-instrument-validation.md.

    step_ms = c + f(P) + d1*n + d2*n^2 + m*P*n + h*sum(p_i*C_i)   [+ k*K_d when I4 requires it]

P is the context tokens scheduled in the step, n the generation requests, f piecewise linear with knots at 0, 256,
512, 1,024 and 2,048 and f(0) = 0, p_i request i's prompt tokens in the step and C_i its prompt tokens processed
before it, and K_d the summed context of the step's decoders.
The left side is not the logged elapsed_ms but elapsed_ms plus the per-step time the timer omits, from the clock fit
in iterlog.fit_clock on the serial training episodes.

A session-2 archive (study instrument-validation-s2-2026-10-05, docs/superpowers/specs/2026-10-05-instrument-validation-
session-2.md) is told apart by instrument_gates.study_of and differs in four places, each one function below:
its warm-up iterations are cut off by instrument_gates.measured_iters, its matrix is registered_design(True), its
hold-out is heldout_cycles generalised to six episodes a block, and its context steps' omitted time is the frozen
clock (session_clock).
The last two are not in the fit's registration, which was written for session 1, and the output says so.

    python3 timing_fit.py ARCHIVE/m5c-run                    # the registered verdict
    python3 timing_fit.py ARCHIVE/m5c-run --flip-context     # a labelled sensitivity run, never the verdict
    BENCHHARNESS=bin python3 timing_fit.py ARCHIVE/m5c-run --logged   # the logged-engine registration (2026-10-06)
    python3 timing_fit.py --self-test

Exit status: 0 PASS, 1 FAIL, 3 UNRESOLVED; a refusal exits with its message.
Only the standard library is used: neither numpy nor scipy was installed on the machine this was written on, and a
fit that silently needs a package nobody has is a fit that does not run on the day.
"""

import json
import math
import os
import random
import statistics
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
# Session 2's staggered decoders are capped at 512 output tokens (section 4); the setting's name does not carry the cap,
# so it is checked on its own, or a session-1-shaped staggered cell would pass for a session-2 one.
STAGGER_DECODE_CAP_S2 = 512
# The two choices session 2 needs that the fit's registration (written for session 1) does not make.
# They are printed with every session-2 result until a dated amendment registers them.
UNREGISTERED_S2 = (
    "hold-out generalised from one of three episodes per block to a third of them (heldout_cycles); not registered",
    "context steps' omitted time is the frozen session-2 clock b + c*P, not fit_clock's b (session_clock); not registered",
)


def registered_settings():
    """The settings internal/bench/episodes.go generates, as this fit names them; the matrix must hold all of them."""
    s = {("serial", L, c) for L in (256, 512, 1024, 2048, 4096, 8192) for c in (1, 16, 64)}
    s |= {("burst", n, L, 64) for n in (1, 4, 16) for L in (256, 2048, 8192)} | {("burst", 64, 256, 64)}
    s |= {("stagger", n, c, p) for n in (1, 4, 16) for c in (256, 8192) for p in (256, 8192)}
    return s


def registered_design(s2):
    """Each registered setting and the number of its episodes every cell must hold, mirrored from episodes.go.

    Session 1 (designS1) holds every setting three times a cell.
    Session 2 (designS2; sections 4 and 5 of its registration) adds serial lengths 768, 3,072 and 6,144 and runs six
    serial cycles, keeps three burst cycles, and runs three full staggered cycles followed by four more of the
    short-prefill (256-token) settings only, so those are seven a cell and the long-prefill ones three.
    """
    if not s2:
        return {s: len(CYCLES) for s in registered_settings()}
    d = {("serial", L, c): 6 for L in (256, 512, 768, 1024, 2048, 3072, 4096, 6144, 8192) for c in (1, 16, 64)}
    d.update({s: 3 for s in registered_settings() if s[0] == "burst"})
    d.update({s: (7 if s[3] == 256 else 3) for s in registered_settings() if s[0] == "stagger"})
    return d


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
    # The episode's last request, which in a staggered episode is the prefill sent while the decoders run.
    last = order.index(reqs[-1])
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
        P, dealt, finished, H, late = s["ctx_tokens"], 0, [], 0, False
        for i in range(len(order)):
            if P == 0:
                break
            if left[i] > 0:
                take = min(left[i], P)
                late = late or i == last
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
        # late marks a step in which the last request's prompt is scheduled; only session 2's staggered gate reads it.
        out.append(dict(P=s["ctx_tokens"], n=s["gen_reqs"], K=K, H=H, elapsed=s["elapsed_ms"], late=late))
    unfinished = [order[i]["index"] for i in range(len(order)) if left[i] or made[i] != order[i]["output_tokens"]]
    if unfinished:
        raise Refusal(f"the episode's steps end with request(s) {unfinished[:3]} not finished as the client saw them")
    return out


def check_study(run, arm, b):
    """Sessions 2 and 3: every row of the cell carries the archive's study, since study_of reads one cell's first row."""
    study = instrument_gates.study_of(run)
    with open(os.path.join(run, f"raw-{arm}-{b}.jsonl")) as f:
        other = {json.loads(l).get("study", "") for l in f} - {study}
    if other:
        raise Refusal(f"{arm}-{b}: rows of study {sorted(other)} in a {study} archive; one archive is one session")


def load_episodes(run, s2=False):
    """Every logged synchronous episode, with its setting, block, cycle and steps.

    The cycle of an episode is its occurrence of that setting within its cell, counted in send order: the generator
    places each setting exactly once per cycle, and check_matrix refuses any cell where that does not hold.
    A failed request, a preemption, a missing or repeated iteration and an episode whose steps overlap another's
    refuse here as well as in the gates, because this loader does not go through them.
    In session 2 the iterations are instrument_gates.measured_iters', which drops the warm-up up to the cell's recorded
    boundary and refuses a log that lacks one; the warm-up's steps belong to no trace episode.
    """
    out = []
    for arm in ARMS:
        kind = arm.split("-")[0]
        for b in BLOCKS:
            if s2:
                check_study(run, arm, b)
            reqs = instrument_gates.load_cell(run, arm, b)
            p = instrument_gates.preemptions(run, arm, b)
            if p:
                raise Refusal(f"{arm}-{b}: {p:g} preemption(s); a preempted request recomputes its prompt, which the "
                              f"rebuild of step contexts does not model")
            iters = instrument_gates.measured_iters(run, arm, b, s2)
            eps, seen = episodes_of(kind, reqs), {}
            if s2 and kind == "stagger":
                caps = sorted({q["cap"] for _, e in eps for q in e[:-1]})
                if caps != [STAGGER_DECODE_CAP_S2]:
                    raise Refusal(f"{arm}-{b}: staggered decoders capped at {caps} output tokens; session 2 registers "
                                  f"{STAGGER_DECODE_CAP_S2}")
            for pos, ((setting, ep), steps) in enumerate(zip(eps, instrument_gates.segment(iters, [e for _, e in eps]))):
                seen[setting] = seen.get(setting, 0) + 1
                out.append(dict(setting=setting, block=b, cycle=seen[setting], pos=pos,
                                reqs=[q["index"] for q in ep], steps=reconstruct(ep, steps),
                                # The staggered prefill is the episode's last row; only the logged policy reads it.
                                late_ttft_ms=ep[-1]["ttft_ms"] if kind == "stagger" else None))
    return out


def check_matrix(episodes, design=None):
    """Exactly the registered settings, each its registered number of times in every block; anything else is not the design.

    design is registered_design's table; None is session 1's, three episodes of every setting in every block.
    """
    design = design or registered_design(False)
    want = set(design)
    have = {e["setting"] for e in episodes}
    if have != want:
        raise Refusal(f"incomplete matrix: settings missing {sorted(want - have, key=str)[:3]}, unregistered "
                      f"{sorted(have - want, key=str)[:3]}")
    count = {}
    for e in episodes:
        count[(e["setting"], e["block"])] = count.get((e["setting"], e["block"]), 0) + 1
    bad = [(s, b, count.get((s, b), 0)) for s in sorted(want, key=str) for b in BLOCKS
           if count.get((s, b), 0) != design[s]]
    if bad:
        need = (f"exactly {design[next(iter(want))]} episodes" if len(set(design.values())) == 1 else
                f"exactly its registered episodes ({', '.join(f'{k} {v}' for k, v in sorted(_counts(design).items()))})")
        raise Refusal(f"incomplete matrix: every setting needs {need} in each of blocks {BLOCKS}, and "
                      f"{len(bad)} (setting, block) pair(s) do not have them, e.g. {bad[:2]}")


def _counts(design):
    """The distinct per-block counts of each episode type, for a refusal's wording."""
    out = {}
    for s, n in design.items():
        out.setdefault(s[0], set()).add(n)
    return {k: "/".join(map(str, sorted(v))) for k, v in out.items()}


def heldout_cycle(setting, block):
    """The cycle held out of this setting in this block.

    A permutation of the three cycles per setting, seeded by the registration's seed and the setting's name, so
    each block holds out a different cycle and every cycle position sits on both sides of the split.
    A string seed is hashed by SHA-512 in Python 3, so this is the same on every machine and every run.
    """
    return random.Random(f"{SEED}/{setting!r}").sample(CYCLES, 3)[block - 1]


def heldout_cycles(setting, block, per_block):
    """The cycles held out of this setting in this block, when every block holds per_block episodes of it.

    NOT REGISTERED -- a generalisation for session 2, whose serial settings have six episodes a block.
    The registration holds out one of three episodes per block, the held-out cycle rotating across the blocks by a
    permutation drawn per setting from seed 20261005.
    Generalised: the cycles 1..per_block are permuted by the same seeded draw, and block b holds out the b-th third of
    that permutation, so a third of each block is held out, each cycle position is held out in exactly one block and
    trained on in the other two, and every position sits on both sides of the split.
    At per_block = 3 it is the registered rule draw for draw: random.sample picks positions by the population's length
    alone, so sampling range(1, 4) and the tuple (1, 2, 3) return the same order (the self-test checks every setting).
    A count that is not a multiple of the number of blocks has no equal thirds and is refused rather than rounded.
    """
    if per_block % len(BLOCKS):
        raise Refusal(f"{setting}: {per_block} episodes per block cannot be split into {len(BLOCKS)} equal held-out "
                      f"thirds, so the hold-out rule does not apply to it")
    k = per_block // len(BLOCKS)
    order = random.Random(f"{SEED}/{setting!r}").sample(range(1, per_block + 1), per_block)
    return set(order[(block - 1) * k:block * k])


def split(episodes, design=None):
    """Training and predicted episodes, by whole episode, never by step.

    Serial episodes, as homogeneous bursts of one, and burst episodes train, less the rotating held-out cycles.
    Staggered episodes are never trained on: they are the out-of-sample test of two kinds of work in one step, and
    all of them are predicted.
    design is registered_design's table; None is session 1's, where each setting's held-out cycle is heldout_cycle's.
    """
    train, held = {}, {}
    for e in sorted(episodes, key=lambda e: (e["block"], e["pos"])):
        s = e["setting"]
        if design is None:
            out = s[0] == "stagger" or e["cycle"] == heldout_cycle(s, e["block"])
        else:
            out = s[0] == "stagger" or e["cycle"] in heldout_cycles(s, e["block"], design[s])
        (held if out else train).setdefault(s, []).append(e)
    return train, held


def session_clock(s2, fitted):
    """The omitted time added back to each step: b per context step, b' per decode-only step.

    Session 1, as registered: b and b' both from fitted, iterlog.fit_clock on the serial training episodes.
    Session 2, NOT REGISTERED: the fit's registration says b comes from fit_clock, but session 1 showed that a constant
    per context step is the wrong form, and session 2 froze a + sum(b + c*P_j) from session 1's data and tests it in I3.
    Fitting a constant b on session 2 would add back an omitted time of the form the instrument rejected, so a context
    step (and a mixed step under the nominal convention) gets the frozen CLOCK_B + CLOCK_C * P, and a decode-only step
    gets fit_clock's b', which session 2 left as session 1 defined it.
    The frozen a is per request, not per step, and is not added to any step, as fit_clock's a is not in session 1.
    """
    if not s2:
        return fitted
    return dict(fitted, b=instrument_gates.CLOCK_B, c=instrument_gates.CLOCK_C, fitted_a=fitted["a"],
                fitted_b=fitted["b"], a=instrument_gates.CLOCK_A,
                prefill="frozen session-2 clock: context step omits CLOCK_B + CLOCK_C * P ms; fitted a and b unused")


def context_omitted_ms(P, b, per_token):
    """A context step's omitted time: b, or b + per_token * P where session_clock gives a per-token cost."""
    return b if per_token is None else b + per_token * P


def clock(run, keep=None, s2=False):
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
        iters = instrument_gates.measured_iters(run, "serial-log", b, s2)
        attributed += [r for r in iterlog.attribute_serial(iters, reqs) if keep is None or (b, r["index"]) in keep]
    fit = iterlog.fit_clock(attributed)
    b_prime = sum(fit["b_decode"].values()) / len(fit["b_decode"])
    # An omitted time below zero would make a step shorter than the part of it the timer saw, which no engine does;
    # it means the clock fit is wrong, and adding it back would publish a duration built on that.
    # In session 2 the fitted b is replaced by the frozen clock (session_clock) and added to nothing, so only b' is judged.
    if (fit["b"] < 0 and not s2) or b_prime < 0:
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


def true_ms(step, b, b_prime, mixed, per_token=None):
    """elapsed_ms plus the time the timer omits for a step of that kind.

    A context step gets b and a decode-only step b', as iterlog.fit_clock measured them on lone requests.
    A mixed step -- context tokens and decoders together -- was never measured by either clock.
    The nominal convention gives it b, because b is defined per context step of a request whatever shares the step;
    the registration runs b' on mixed steps as well, every time, and a disagreement makes the verdict unresolved.
    per_token is None in session 1; in session 2 "b" means the frozen b + c * P (session_clock).
    """
    if step["P"] == 0:
        return step["elapsed"] + b_prime
    if step["n"] == 0:
        return step["elapsed"] + context_omitted_ms(step["P"], b, per_token)
    return step["elapsed"] + (context_omitted_ms(step["P"], b, per_token) if mixed == "b" else b_prime)


def episode_sums(e, b, b_prime, mixed, context, per_token=None):
    """An episode's contribution to the normal equations, unweighted: sum x x', sum x y and its step count."""
    p = len(columns(context))
    G, h = [[0.0] * p for _ in range(p)], [0.0] * p
    for st in e["steps"]:
        x, y = features(st, context), true_ms(st, b, b_prime, mixed, per_token)
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


def _err(steps, beta, b, b_prime, mixed, context, per_token=None):
    obs = sum(true_ms(st, b, b_prime, mixed, per_token) for st in steps) / len(steps)
    pred = sum(sum(c * x for c, x in zip(beta, features(st, context))) for st in steps) / len(steps)
    return dict(observed_ms=obs, predicted_ms=pred, error=pred / obs - 1, steps=len(steps))


def fit(train, held, b, b_prime, context, mixed, bound=MAX_HELDOUT_ERROR, boot=BOOT, per_token=None, late_gate=False,
        ttft_a=None):
    """One fit and its verdict on the predicted episodes.

    A structural failure -- an unidentified design -- refuses; a prediction outside the bound is a "fail" verdict, so
    the caller can set the two mixed-step conventions side by side.
    The check is per setting and per phase: steps carrying context tokens and pure-decode steps are held to the
    bound separately, because a pooled mean lets opposite errors cancel and lets hundreds of decode steps dilute a
    few prefill steps.
    per_token is session_clock's c, None in session 1.
    late_gate (session 2) gates a third subset of every staggered setting: the steps that schedule the late prefill's
    prompt. Among the 66 context steps of a (16, 8,192, 256) episode one serves it, so the context phase barely moves
    when that step doubles (-0.35%, found by review), and the late prefill is the thing the staggered test exists for.
    Session 1 is scored without it, so its published output stays what it was.
    """
    names = columns(context)
    p = len(names)
    sums = {id(e): episode_sums(e, b, b_prime, mixed, context, per_token) for eps in train.values() for e in eps}
    G, h = normal_equations(train, sums, p)
    beta, cond = solve_normalised(G, h, names, check=True)
    report, failures = [], []
    for s, eps in sorted(held.items(), key=lambda kv: str(kv[0])):
        steps = [st for e in eps for st in e["steps"]]
        phases = {}
        subsets = [("context", lambda st: st["P"] > 0), ("decode", lambda st: st["P"] == 0)]
        if late_gate and s[0] == "stagger":
            bare = [(e["block"], e["cycle"]) for e in eps if not any(st["late"] for st in e["steps"])]
            if bare:
                raise Refusal(f"{s}: episode(s) (block, cycle) {bare[:3]} have no step scheduling the late prefill, so "
                              f"the staggered test of mixing has nothing to judge")
            subsets.append(("late-prefill", lambda st: st["late"]))
        for phase, keep in subsets:
            mine = [st for st in steps if keep(st)]
            if mine:
                phases[phase] = _err(mine, beta, b, b_prime, mixed, context, per_token)
                if abs(phases[phase]["error"]) > bound:
                    failures.append(f"{s} {phase} steps: predicted {phases[phase]['predicted_ms']:.3f} ms against "
                                    f"{phases[phase]['observed_ms']:.3f} ms, {phases[phase]['error']:+.1%}")
        item = dict(setting=list(s), phases=phases,
                    pooled_published_not_gated=_err(steps, beta, b, b_prime, mixed, context, per_token),
                    blocks={str(bl): _err([st for e in eps if e["block"] == bl for st in e["steps"]], beta, b, b_prime,
                                          mixed, context, per_token)["error"]
                            for bl in BLOCKS if any(e["block"] == bl for e in eps)},
                    episodes=[dict(block=e["block"], cycle=e["cycle"],
                                   error=_err(e["steps"], beta, b, b_prime, mixed, context, per_token)["error"])
                              for e in eps])
        if s[0] == "stagger":
            item["label"] = STAGGER_LABEL
            if ttft_a is not None:
                item["late_prefill_ttft"] = late_ttft(eps, beta, context, ttft_a)
                r = item["late_prefill_ttft"]["ratio"]
                if not 1 - bound <= r <= 1 + bound:
                    failures.append(f"{s} late-prefill client TTFT: predicted/observed {r:.4f}, outside "
                                    f"[{1 - bound:.2f}, {1 + bound:.2f}]")
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


def late_ttft(eps, beta, context, a):
    """Section 3 item 2 of the logged-engine registration: the late prefill's whole client TTFT, conditionally.

    Predicted is the frozen per-request a plus the predicted durations of the late prompt's own context-bearing steps,
    which reconstruct() marks by token accounting alone; nothing here reads the observed first-token time to choose
    steps. The ratio is of means with the blocks weighted equally, and the block ratios and per-episode residuals are
    published because opposite errors cancel in a mean.
    """
    def pred(e):
        late = [st for st in e["steps"] if st["late"]]
        if not late:
            raise Refusal(f"{e['setting']} block {e['block']} cycle {e['cycle']}: no step schedules the late prefill")
        return a + sum(sum(c * x for c, x in zip(beta, features(st, context))) for st in late)
    blocks = sorted({e["block"] for e in eps})
    by = {bl: [(pred(e), e["late_ttft_ms"]) for e in eps if e["block"] == bl] for bl in blocks}
    mp = statistics.fmean(statistics.fmean(p for p, _ in v) for v in by.values())
    mo = statistics.fmean(statistics.fmean(o for _, o in v) for v in by.values())
    return dict(ratio=mp / mo, predicted_ms=mp, observed_ms=mo,
                blocks={str(bl): statistics.fmean(p for p, _ in v) / statistics.fmean(o for _, o in v)
                        for bl, v in by.items()},
                residuals_ms=[dict(block=e["block"], cycle=e["cycle"], residual=pred(e) - e["late_ttft_ms"]) for e in eps])


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


def run_fit(run, flip_context=False, boot=BOOT, gates=None, logged=False, harness=None):
    """The fit's verdict; logged=True is docs/superpowers/specs/2026-10-06-a-timing-family-for-the-logged-synchronous-engine.md.

    Under that policy the archive must first pass instrument_gates.check_archive (design, warm-ups, provenance), so
    this path cannot skip what the command line checks; I1 is not a gate; k is always in the family, because I4 reads
    held-out episodes; and the late prefill's client TTFT is gated under both conventions.
    """
    if logged:
        if not harness:
            raise Refusal("the logged-engine policy checks the archive with cmd/benchharness; pass its path")
        checks = instrument_gates.check_archive(run, harness, logged=True)
        passed, gate_lines = (gates or (lambda r: instrument_gates.evaluate(r, logged=True)))(run)
        gate_lines = checks + gate_lines
    else:
        # gates is replaced only by the self-test, to show that a failing verdict refuses.
        passed, gate_lines = (gates or instrument_gates.evaluate)(run)
    if not passed:
        raise Refusal(f"the instrument gates do not pass on this archive ({gate_lines[-1]}), so there is no "
                      f"established quantity to fit")
    # Session 3 is session 2's design with fixed-length staggered decoders, so it takes every session-2 path.
    study = instrument_gates.study_of(run)
    s2 = study in instrument_gates.WARM_STUDIES
    # Session 1 keeps its own code path, argument for argument, so its output cannot move.
    design = registered_design(True) if s2 else None
    eps = load_episodes(run, s2)
    check_matrix(eps, design)
    train, held = split(eps, design)
    keep = {(e["block"], i) for s, v in train.items() if s[0] == "serial" for e in v for i in e["reqs"]}
    clk = session_clock(s2, clock(run, keep, s2))
    needs, i4 = context_decision(run)
    context = (True if logged else needs) != flip_context
    a = clk["a"] if logged else None
    nominal = fit(train, held, clk["b"], clk["b_prime"], context, "b", boot=boot, per_token=clk.get("c"), late_gate=s2,
                  ttft_a=a)
    sensitivity = fit(train, held, clk["b"], clk["b_prime"], context, "b-prime", boot=boot, per_token=clk.get("c"),
                      late_gate=s2, ttft_a=a)
    if logged:
        extra = dict(study=study, policy="logged-engine registration (2026-10-06): I1 not a gate, k always in the "
                                          "family, late-prefill client TTFT gated")
    else:
        extra = dict(study=study, unregistered=list(UNREGISTERED_S2)) if s2 else {}
    return dict(
        **extra,
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
    # The step a late request arrives before, which session 2's synthetic archive sends it at.
    arrived_at = [0] * len(spec)
    steps, done_at, first_at = [], [None] * len(spec), [None] * len(spec)
    while any(prod[i] < spec[i][1] for i in range(len(spec))):
        for i, (_, _, late) in enumerate(spec):
            if late and not arrived[i] and all(prod[j] >= 4 for j in range(len(spec)) if not spec[j][2]):
                arrived[i] = True
                arrived_at[i] = len(steps)
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
    return steps, first_at, done_at, arrived_at


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
                    steps, first_at, done_at, _ = _simulate(spec, truth, rng, noise, sl)
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
                        # Session 1's rows carry its study as the real ones do; the evaluator refuses a row without one.
                        raw.append(dict(index=idx, study=instrument_gates.STUDY_S1, engineInputTokens=L,
                                        engineOutputTokens=cap, sendUnixNanos=int(offset * 1e6),
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


# The synthetic session-2 engine omits the frozen clock on context steps; b' and the end delay are session 1's synthetic ones.
CLOCK_S2 = dict(a=instrument_gates.CLOCK_A, b=instrument_gates.CLOCK_B, c=instrument_gates.CLOCK_C, b_prime=1.2,
                d_end=3.0)
WARMUP_STEPS = 30
# The frozen b of 17.8 ms per context step is larger than session 1's synthetic c of 12 ms, so a small mixed step would
# log a negative elapsed time; a larger intercept keeps every synthetic step longer than the time its timer omits.
TRUTH_S2 = dict(TRUTH, c=25.0)


def _plan_s2(kind, decode_cap):
    """One cell's cycles, as designS2 lays them out: full cycles, then the short-prefill staggered settings alone."""
    if kind == "serial":
        full = [[(L, c, False)] for L in (256, 512, 768, 1024, 2048, 3072, 4096, 6144, 8192) for c in (1, 16, 64)]
        return [full] * 6
    if kind == "burst":
        return [_cycle("burst")] * 3
    full = [[(c, decode_cap, False)] * n + [(p, 16, True)] for n in (1, 4, 16) for c in (256, 8192) for p in (256, 8192)]
    return [full] * 3 + [[e for e in full if e[-1][0] == 256]] * 4


def _synthetic_run_s2(run, truth=None, noise=0.0, slow=None, seed=3, clk=CLOCK_S2, mixed_truth="b", nolog_ttft=1.0,
                      drop=None, decode_cap=STAGGER_DECODE_CAP_S2, cycles=None, late_factor=None):
    """A session-2 archive from known coefficients: registered_design(True)'s matrix, warm-ups, boundaries and study.

    Kept apart from _synthetic_run so that session 1's synthetic archives, which the self-test pins, cannot move.
    Each logged engine log starts at iteration 0 with WARMUP_STEPS warm-up iterations that no trace request owns, so a
    fit that read them would refuse or misfit; the boundary file names the last of them.
    The engine's context-step omission is clk's b + c * P, the frozen form, so instrument_gates' I3 holds exactly.
    A staggered prefill is sent at the step it arrives before, after its decoders' first tokens, so gate S holds.
    slow maps a training setting to (factor, phase), applied to the episodes heldout_cycles holds out of it.
    drop is a (setting, block) one of whose episodes is left out; cycles overrides _plan_s2's for one type.
    late_factor maps a staggered setting to a factor on the steps that schedule its late prefill's prompt.
    """
    rng, slow, design, truth = random.Random(seed), slow or {}, registered_design(True), truth or TRUTH_S2
    study = instrument_gates.STUDY_S2
    for kind in ("serial", "burst", "stagger"):
        for b in BLOCKS:
            plan = (cycles or {}).get(kind) or _plan_s2(kind, decode_cap)
            trace, raw, idx, ep_no, seen = [], [], 0, 0, {}
            # The warm-up's three 2,048-token requests are its only context steps, so the prompt tokens before the
            # boundary reconcile with raw-warmup's, as instrument_gates.measured_iters requires.
            lines = [_line(i, 1, 2048, 0, 200.0) if i < 3 else _line(i, 0, 0, 1, 14.0) for i in range(WARMUP_STEPS)]
            it = WARMUP_STEPS
            for cyc in plan:
                for spec in rng.sample(cyc, len(cyc)):
                    start = ep_no * 100_000
                    ep_no += 1
                    s = _setting(kind, spec)
                    seen[s] = seen.get(s, 0) + 1
                    if drop == (s, b) and seen[s] == 1:
                        continue
                    held = s[0] != "stagger" and seen[s] in heldout_cycles(s, b, design.get(s, 3))
                    sl = slow.get(s, (1.0, "all")) if held else (1.0, "all")
                    steps, first_at, done_at, arrived_at = _simulate(spec, truth, rng, noise, sl)
                    t0 = start + clk["a"]
                    ends, late_send = [], None
                    for j, st in enumerate(steps):
                        if any(late for _, _, late in spec) and j == max(arrived_at):
                            late_send = t0 - clk["a"]
                        # The late request's prompt is scheduled from its arrival to its first token, in every such step.
                        if (late_factor or {}).get(s) and max(arrived_at) <= j <= first_at[-1] and st["P"]:
                            st = dict(st, T=st["T"] * late_factor[s])
                        ctx = clk["b"] + clk["c"] * st["P"]
                        mixed = st["P"] and st["n"]
                        omitted = ((ctx if mixed_truth == "b" else clk["b_prime"]) if mixed else ctx) if st["P"] \
                            else clk["b_prime"]
                        lines.append(_line(it, st["cr"], st["P"], st["n"], st["T"] - omitted))
                        it += 1
                        t0 += st["T"]
                        ends.append(t0)
                    for i, (L, cap, late) in enumerate(spec):
                        send = late_send if late else start
                        offset = round(send)
                        trace.append(dict(index=idx, offsetMs=offset, tenant="premium-1", maxOutputTokens=cap))
                        raw.append(dict(index=idx, study=study, engineInputTokens=L, engineOutputTokens=cap,
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
                # One cold request and the two verification requests gate W reads.
                _write(run, f"raw-warmup-{arm}-{b}.jsonl",
                       [dict(index=i, study=study, engineInputTokens=2048, sendUnixNanos=int(i * 1e10),
                             firstTokenUnixNanos=int(i * 1e10 + ms * 1e6)) for i, ms in enumerate((400.0, 231.0, 231.5))])
                for which in ("before", "after"):
                    with open(os.path.join(run, f"engine-metrics-{arm}-{b}-{which}.prom"), "w") as f:
                        f.write('vllm:num_preemptions_total{engine="0"} 2\n')
            with open(os.path.join(run, f"engine-log-{kind}-log-{b}.txt"), "w") as f:
                f.write("\n".join(lines) + "\n")
            with open(os.path.join(run, f"warmup-boundary-{kind}-log-{b}.txt"), "w") as f:
                f.write(f"{WARMUP_STEPS - 1}\n")


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


# sha256 of json.dumps(run_fit(<_synthetic_run(noise=0.01, seed=5)>, gates=_PASSED), sort_keys=True), taken from
# timing_fit.py as committed at 0560304, before session 2 reached this file.
# Session 1's fit must come out of the session-2 change byte for byte; the noisy archive exercises the bootstrap too.
# random.gauss draws through the platform's log and cos, so another libm could move the hash without any code change:
# a mismatch there is a reason to re-take the hash at 0560304 on that machine, not to update it here.
S1_PIN = "2e533855a5c2579334358bda79a4f15794217e8024e9491f293ff06b2ea0a915"


def self_test_s2():
    """Session 2's paths: warm-up cut, per-study matrix, generalised hold-out and the frozen clock, each made to fire."""
    import hashlib
    import tempfile

    # Session 3 takes session 2's paths: the same archive recorded under session 3's study fits to the same verdict,
    # and a cell mixing the two studies is refused.
    with tempfile.TemporaryDirectory() as run:
        _synthetic_run_s2(run)
        for name in os.listdir(run):
            if name.startswith("raw-") and not name.startswith("raw-warmup-"):
                path = os.path.join(run, name)
                rows = [json.loads(l) for l in open(path)]
                for r in rows:
                    r["study"] = instrument_gates.STUDY_S3
                with open(path, "w") as f:
                    f.writelines(json.dumps(r) + "\n" for r in rows)
        got = run_fit(run, boot=0, gates=_PASSED)
        assert got["study"] == instrument_gates.STUDY_S3 and got["verdict"] in ("PASS", "UNRESOLVED"), got["verdict"]
        print(f"ok: a session-3 archive takes session 2's paths -> {got['verdict']} under {got['study']}")
        path = os.path.join(run, "raw-burst-log-2.jsonl")
        rows = [json.loads(l) for l in open(path)]
        rows[0]["study"] = instrument_gates.STUDY_S2
        with open(path, "w") as f:
            f.writelines(json.dumps(r) + "\n" for r in rows)
        try:
            run_fit(run, boot=0, gates=_PASSED)
            raise AssertionError("a cell mixing two studies was accepted")
        except Refusal as e:
            assert "one archive is one session" in str(e), e
            print(f"ok: refuses a session-3 archive with a session-2 row -- {e}")

    def refuses(what, fn, words):
        try:
            fn()
        except Refusal as e:
            assert words in str(e), f"{what}: refused for another reason -- {e}"
            print(f"ok: refuses {what} -- {e}")
            return
        raise AssertionError(f"{what} was accepted")

    with tempfile.TemporaryDirectory() as run:
        _synthetic_run(run, noise=0.01, seed=5)
        got = hashlib.sha256(json.dumps(run_fit(run, gates=_PASSED), sort_keys=True).encode()).hexdigest()
        assert got == S1_PIN, f"session 1's fit output moved: {got}"
        print("ok: a session-1 synthetic archive's fit output is byte-identical to the fit as committed at 0560304")
    for s in registered_settings():
        if s[0] != "stagger":
            assert all(heldout_cycles(s, b, 3) == {heldout_cycle(s, b)} for b in BLOCKS), s
    print("ok: at three episodes a block the generalised hold-out is the registered one in every setting and block")

    design = registered_design(True)
    with tempfile.TemporaryDirectory() as run:
        _synthetic_run_s2(run)
        # The real gates, as run_fit calls them by default.
        clean = run_fit(run, boot=0)
        nom = clean["nominal"]
        assert clean["study"] == instrument_gates.STUDY_S2 and clean["unregistered"] == list(UNREGISTERED_S2)
        assert clean["gates"][-1].startswith("PASS"), clean["gates"][-1]
        assert _close(nom["coefficients"], _expected(TRUTH_S2, False), 1e-5), nom["coefficients"]
        assert (clean["clock"]["b"], clean["clock"]["c"]) == (instrument_gates.CLOCK_B, instrument_gates.CLOCK_C)
        assert abs(clean["clock"]["b_prime"] - CLOCK_S2["b_prime"]) < 1e-6, clean["clock"]
        print(f"ok: session 2 under the real gates ({clean['gates'][-1]}): every coefficient recovered within 1e-5 "
              f"relative with the frozen clock (b {clean['clock']['b']}, c {clean['clock']['c']}) on context steps and "
              f"b' {clean['clock']['b_prime']:.3f} from fit_clock; fit_clock's own b would be "
              f"{clean['clock']['fitted_b']:.2f} ms")
        # The synthetic engine omits the frozen b + c*P on mixed steps and b' is 1.2 ms, so the sensitivity convention
        # misstates every mixed step by about 16.6 ms; the verdict must say unresolved, not pass.
        assert nom["verdict"] == "pass" and clean["sensitivity"]["verdict"] == "fail", clean["verdicts"]
        assert clean["verdict"] == "UNRESOLVED", clean["verdict"]
        print(f"ok: mixed steps under b' ({CLOCK_S2['b_prime']} ms) against the frozen b + c*P -> {clean['verdicts']} -> "
              f"{clean['verdict']} -- {clean['sensitivity']['failures'][0]}")
        eps = load_episodes(run, True)
        train, held = split(eps, design)
        for s, n in design.items():
            if s[0] == "stagger":
                assert s not in train and len(held[s]) == 3 * n, (s, len(held[s]))
                continue
            k = n // len(BLOCKS)
            for b in BLOCKS:
                assert sorted(e["cycle"] for e in held[s] if e["block"] == b) == sorted(heldout_cycles(s, b, n))
                assert len([e for e in held[s] if e["block"] == b]) == k, (s, b)
            assert sorted(e["cycle"] for e in held[s]) == list(range(1, n + 1)), (s, sorted(e["cycle"] for e in held[s]))
            assert len(train[s]) == 2 * n, (s, len(train[s]))
        print("ok: serial settings hold out 2 of 6 per block (6 held, 12 trained, each cycle position held out in one "
              "block); bursts 1 of 3; staggered all predicted, 21 short-prefill and 9 long-prefill episodes")
        print(f"ok: the result names its unregistered choices -- {clean['unregistered']}")
        clean_coef = nom["coefficients"]

        refuses("a session-2 matrix one serial episode short", lambda: check_matrix(
            [e for e in eps if not (e["setting"] == ("serial", 3072, 16) and e["block"] == 2 and e["cycle"] == 4)],
            design), "incomplete matrix")
        refuses("session-1 counts (three serial cycles a block) in a session-2 archive", lambda: check_matrix(
            [e for e in eps if e["setting"][0] != "serial" or e["cycle"] <= 3], design), "incomplete matrix")
        refuses("a session-2 archive read against session 1's matrix", lambda: check_matrix(eps), "incomplete matrix")
        refuses("a hold-out of seven episodes a block", lambda: heldout_cycles(("stagger", 1, 256, 256), 1, 7),
                "equal held-out")

    def prepared(prepare, **kw):
        def go():
            with tempfile.TemporaryDirectory() as run:
                _synthetic_run_s2(run, **kw)
                prepare(run)
                run_fit(run, boot=0, gates=_PASSED)
        return go

    refuses("a missing warm-up boundary", prepared(
        lambda run: os.remove(os.path.join(run, "warmup-boundary-burst-log-2.txt"))), "is missing")

    def other_study(run):
        path = os.path.join(run, "raw-stagger-log-3.jsonl")
        rows = [json.loads(l) for l in open(path)]
        rows[4]["study"] = "instrument-validation-2026-10-05"
        _write(run, "raw-stagger-log-3.jsonl", rows)
    refuses("a cell carrying session 1's study", prepared(other_study), "one archive is one session")
    refuses("staggered decoders at session 1's cap of 128", prepared(lambda run: None, decode_cap=128),
            "session 2 registers 512")
    refuses("an archive one serial episode short", prepared(lambda run: None, drop=(("serial", 6144, 64), 3)),
            "incomplete matrix")

    with tempfile.TemporaryDirectory() as run:
        _synthetic_run_s2(run)
        refuses("a session-2 archive whose gates verdict is FAIL",
                lambda: run_fit(run, boot=0, gates=lambda r: (False, ["FAIL: I3"])), "instrument gates do not pass")
    with tempfile.TemporaryDirectory() as run:
        # An engine omitting 22 ms per context step, not the frozen 17.8: about 6% of a 256-token TTFT, so the real I3
        # fails and the fit refuses.
        _synthetic_run_s2(run, clk=dict(CLOCK_S2, b=22.0))
        refuses("a session-2 archive the real gates fail", lambda: run_fit(run, boot=0), "instrument gates do not pass")

    with tempfile.TemporaryDirectory() as run:
        _synthetic_run_s2(run, slow={("serial", 3072, 16): (1.25, "all")})
        r = run_fit(run, boot=0, gates=_PASSED)
        assert r["nominal"]["verdict"] == "fail", r["verdicts"]
        assert _close(r["nominal"]["coefficients"], clean_coef, 1e-9), "a held-out episode reached the training set"
        print(f"ok: the held-out third of a serial setting 25% slower -> nominal fail with the clean coefficients -- "
              f"{r['nominal']['failures'][0]}")

    with tempfile.TemporaryDirectory() as run:
        _synthetic_run_s2(run, noise=0.01, seed=5)
        r = run_fit(run, boot=0, gates=_PASSED)
        assert r["nominal"]["verdict"] == "pass", r["nominal"]["failures"]
        print(f"ok: session 2 at 1% step noise -> nominal pass, worst held-out phase error {_worst(r['nominal']):.2%}")

    late = ("stagger", 16, 8192, 256)
    with tempfile.TemporaryDirectory() as run:
        _synthetic_run_s2(run, late_factor={late: 2.0})
        r = run_fit(run, boot=0, gates=_PASSED)
        for conv in ("nominal", "sensitivity"):
            it = next(i for i in r[conv]["heldout"] if tuple(i["setting"]) == late)
            assert any(f.startswith(f"{late} late-prefill") for f in r[conv]["failures"]), (conv, r[conv]["failures"])
            assert abs(it["phases"]["context"]["error"]) <= MAX_HELDOUT_ERROR, it["phases"]["context"]
        it = next(i for i in r["nominal"]["heldout"] if tuple(i["setting"]) == late)
        print(f"ok: the late prefill's step doubled in {late} -> late-prefill subset "
              f"{it['phases']['late-prefill']['error']:+.1%} over {it['phases']['late-prefill']['steps']} step(s) fails "
              f"in both conventions, while its context phase reads {it['phases']['context']['error']:+.2%}")
        eps = load_episodes(run, True)
        train, held = split(eps, design)
        held[late][0] = dict(held[late][0], steps=[dict(st, late=False) for st in held[late][0]["steps"]])
        refuses("a staggered episode with no step scheduling its late prefill",
                lambda: fit(train, held, CLOCK_S2["b"], CLOCK_S2["b_prime"], False, "b", boot=0,
                            per_token=CLOCK_S2["c"], late_gate=True), "no step scheduling the late prefill")

    with tempfile.TemporaryDirectory() as run:
        # An engine whose omitted time falls with the prompt's length: fit_clock's b comes out negative.
        # Session 2 adds the frozen clock, not that b, so the fit runs; the gates (stubbed here) would judge the engine.
        _synthetic_run_s2(run, clk=dict(CLOCK_S2, b=0.0, c=-0.002))
        r = run_fit(run, boot=0, gates=_PASSED)
        assert r["clock"]["fitted_b"] < 0 and r["clock"]["b"] == instrument_gates.CLOCK_B, r["clock"]
        print(f"ok: a session-2 archive whose fitted b is {r['clock']['fitted_b']:.2f} ms is not refused for it "
              f"-> {r['verdict']}, scored with the frozen b {r['clock']['b']}")
    self_test_logged()


def self_test_logged():
    """The logged-engine policy: its archive checks cannot be skipped, and the late prefill's client TTFT is gated."""
    import tempfile
    with tempfile.TemporaryDirectory() as run:
        _synthetic_run_s2(run)
        try:
            run_fit(run, boot=0, logged=True)
            raise AssertionError("the logged-engine policy ran without a harness to check the archive with")
        except Refusal as e:
            assert "cmd/benchharness" in str(e), e
            print(f"ok: the logged-engine policy refuses without a harness -- {e}")
        stub = os.path.join(run, "stub-harness")
        with open(stub, "w") as f:
            f.write('#!/bin/sh\necho "error: not the registered matrix" >&2\nexit 1\n')
        os.chmod(stub, 0o755)
        called = []
        try:
            run_fit(run, boot=0, logged=True, harness=stub, gates=lambda r: called.append(r) or (True, []))
            raise AssertionError("an archive whose design check failed was fitted")
        except Refusal as e:
            assert "not the registered matrix" in str(e) and not called, (e, called)
            print(f"ok: the logged-engine policy checks the archive before the gates -- {e}")
    # The checks above are the ones a real archive needs; these synthetic archives are not one, so they are replaced.
    real = instrument_gates.check_archive
    instrument_gates.check_archive = lambda run, harness, logged=False: ["archive checks replaced by the self-test"]
    try:
        with tempfile.TemporaryDirectory() as run:
            _synthetic_run_s2(run)
            r = run_fit(run, boot=0, gates=_PASSED, logged=True, harness="unused")
            ratios = [it["late_prefill_ttft"]["ratio"] for it in r["nominal"]["heldout"] if "late_prefill_ttft" in it]
            assert len(ratios) == 12 and r["verdicts"]["mixed steps + b (nominal)"] == "pass", r["verdicts"]
            assert r["context_term"] is True and "unregistered" not in r, (r["context_term"], list(r))
            print(f"ok: logged-engine policy, an engine the family describes -> nominal pass, late-prefill TTFT ratios "
                  f"{min(ratios):.4f} to {max(ratios):.4f}, k in the family")
        # The late prefill's first token 20% later at the client, every step untouched: only item 2 can see it.
        with tempfile.TemporaryDirectory() as run:
            _synthetic_run_s2(run)
            for b in BLOCKS:
                path = os.path.join(run, f"raw-stagger-log-{b}.jsonl")
                trace = {t["index"]: t for t in map(json.loads, open(os.path.join(run, f"trace-stagger-log-{b}.jsonl")))}
                rows = [json.loads(l) for l in open(path)]
                for x in rows:
                    if trace[x["index"]]["maxOutputTokens"] < STAGGER_DECODE_CAP_S2:
                        x["firstTokenUnixNanos"] += int(0.2 * (x["firstTokenUnixNanos"] - x["sendUnixNanos"]))
                with open(path, "w") as f:
                    f.writelines(json.dumps(x) + "\n" for x in rows)
            r = run_fit(run, boot=0, gates=_PASSED, logged=True, harness="unused")
            fails = r["nominal"]["failures"]
            assert r["verdicts"]["mixed steps + b (nominal)"] == "fail" and fails and all(
                "late-prefill client TTFT" in f for f in fails), fails
            print(f"ok: a late prefill 20% slower at the client alone fails item 2 -- {fails[0]}")
    finally:
        instrument_gates.check_archive = real


def main(argv):
    if argv[1:] == ["--self-test"]:
        self_test()
        self_test_s2()
        return 0
    args = argv[1:]
    flip = "--flip-context" in args
    # --logged is the logged-engine registration's policy; it checks the archive with BENCHHARNESS, which it requires.
    logged = "--logged" in args
    args = [a for a in args if a not in ("--flip-context", "--logged")]
    if len(args) != 1:
        sys.exit(__doc__)
    out = run_fit(args[0], flip, logged=logged, harness=os.environ.get("BENCHHARNESS"))
    print(json.dumps(out, indent=2))
    print(f"{out['run']}: {out['verdict']} -- {out['verdicts']}; context term {out['context_term']}", file=sys.stderr)
    print(out["note"], file=sys.stderr)
    for line in out.get("unregistered", []):
        print(f"UNREGISTERED: {line}", file=sys.stderr)
    return {"PASS": 0, "FAIL": 1}.get(out["verdict"], 3)


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except Refusal as e:
        sys.exit(f"REFUSED: {e}")
