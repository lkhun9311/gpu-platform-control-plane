"""The workload-queue predictor F and its sufficiency gates, as registered.

Run: python3 hack/tail-crossing-model/queue_predictor.py <out-dir>

Implements docs/superpowers/specs/2026-10-05-a-workload-queue-predictor-computational.md. The order is the
registration's: profile the single-tenant curves, fit the effective work per tenant profile, compute and
WRITE F (and the secondary F') for every shared profile, and only then generate the reference outcomes the
gates compare against. Nothing about a shared outcome reaches a prediction.

Two choices the registration left open are fixed here and reported with the result: the fit of `a` uses
the first 200 forecast seeds (30001-30200) rather than all 2,000, and the secondary predictor draws 200,000
samples with its own seed.
"""
import json
import math
import multiprocessing
import os
import random
import sys

sys.path.insert(0, os.path.dirname(__file__))
from itersim import simulate  # noqa: E402
from predict import PARAMS  # noqa: E402
from sufficiency import BE_LENGTHS, LC_LENGTHS, RHO_B, RHO_LC, uncontended  # noqa: E402

P = PARAMS["measured"]
PROFILING = range(10001, 10051)
FORECAST = range(30001, 32001)
FIT_FORECAST = range(30001, 30201)
REFERENCE = range(20001, 21001)
BOOT = 200
DUR = 600.0


def nr(xs, q):
    xs = sorted(xs)
    return xs[max(0, math.ceil(q * len(xs)) - 1)]


def poisson(lam, seed, kind):
    if lam <= 0:
        return []
    rng, t, out = random.Random(f"vq/{seed}/{kind}"), 0.0, []
    while True:
        t += rng.expovariate(lam)
        if t >= DUR:
            return out
        out.append(t)


def virtual(lam_l, lam_b, a_l, a_b, u, seeds, who="LC"):
    """Latencies of `who` in the virtual FCFS workload queue: backlog at arrival plus its own latency u."""
    lat = []
    for s in seeds:
        arr = sorted([(t, "LC") for t in poisson(lam_l, s, "LC")] + [(t, "BE") for t in poisson(lam_b, s, "BE")])
        end = 0.0
        for t, k in arr:
            wait = end - t if end > t else 0.0
            end = t + wait + (a_l if k == "LC" else a_b)
            if k == who:
                lat.append(wait + u)
    return lat


def fit_work(curve, u, who):
    """Golden-section fit of the effective work per arrival to a single-tenant curve [(rate, p95, p99)]."""
    hi = (1 - 1e-6) / max(r for r, _, _ in curve)

    def loss(a):
        tot = 0.0
        for rate, m95, m99 in curve:
            xs = virtual(rate if who == "LC" else 0, rate if who == "BE" else 0, a, a, u, FIT_FORECAST, who)
            tot += math.log(nr(xs, .95) / m95) ** 2 + math.log(nr(xs, .99) / m99) ** 2
        return tot

    lo, g = 0.0, (math.sqrt(5) - 1) / 2
    c, d = hi - g * (hi - lo), lo + g * (hi - lo)
    fc, fd = loss(c), loss(d)
    for _ in range(60):
        if fc < fd:
            hi, d, fd = d, c, fc
            c = hi - g * (hi - lo)
            fc = loss(c)
        else:
            lo, c, fc = c, d, fd
            d = lo + g * (hi - lo)
            fd = loss(d)
    return (lo + hi) / 2


def profile_curve(job):
    """Single-tenant pooled p95/p99 over the profiling seeds: ('LC', L, rate) or ('BE', B, rate)."""
    kind, length, rate = job
    vals = []
    for s in PROFILING:
        if kind == "LC":
            vals += simulate(rate, length, 0, seed=s, **P)["lc"]
        else:
            vals += simulate(0, 0, rate, len_be=length, seed=s, **P)["be"]
    return job, nr(vals, .95) / 1000, nr(vals, .99) / 1000, [v / 1000 for v in vals] if kind == "LC" else None


def predict_job(job):
    (L, r, B, rb), lam_l, lam_b, a_l, a_b, u_l, q0, iso_sample, s_b = job
    if lam_l * a_l + lam_b * a_b >= 1:
        f = None
    else:
        f = q0 + nr(virtual(lam_l, lam_b, a_l, a_b, u_l, FORECAST), .99) - nr(virtual(lam_l, 0, a_l, a_b, u_l, FORECAST), .99)
    rng = random.Random(f"secondary/{L}/{r}/{B}/{rb}")
    z = []
    for _ in range(200000):
        x = rng.choice(iso_sample)
        w = rng.uniform(0, s_b) / (1 - r) if rng.random() < min(1.0, rb) else 0.0
        z.append(x + w)
    return [L, r, B, rb], f, nr(z, .99)


def boot_p99(per_trace, rng, idx_sets):
    """Pooled nearest-rank p99 for each resample of whole traces, without building the resampled pool.

    A resample is a multiset of traces, so its pool is every trace's values weighted by how often the trace
    was drawn. The p99 sits in the top 1%, so one descending pass over (value, trace) with those weights finds
    it -- the same answer as sorting the pool, at the cost of the top of it.
    """
    desc = sorted(((v, i) for i, t in enumerate(per_trace) for v in t), reverse=True)
    sizes = [len(t) for t in per_trace]
    out = []
    for idx in idx_sets:
        w = [0] * len(per_trace)
        for i in idx:
            w[i] += 1
        total = sum(w[i] * sizes[i] for i in range(len(sizes)))
        from_top = total - 1 - (max(0, math.ceil(.99 * total) - 1))
        acc = 0
        for v, i in desc:
            acc += w[i]
            if acc > from_top:
                out.append(v)
                break
    return out


def reference_job(job):
    (L, r, B, rb), lam_l, lam_b = job
    iso_t, sh_t = [], []
    for s in REFERENCE:
        iso_t.append([v / 1000 for v in simulate(lam_l, L, 0, seed=s, **P)["lc"]])
        sh_t.append([v / 1000 for v in simulate(lam_l, L, lam_b, len_be=B, seed=s, **P)["lc"]])
    q_iso = nr([v for t in iso_t for v in t], .99)
    q = nr([v for t in sh_t for v in t], .99)
    rng = random.Random(f"boot/{L}/{r}/{B}/{rb}")
    n = len(sh_t)
    idx_sets = [[rng.randrange(n) for _ in range(n)] for _ in range(BOOT)]
    bq, bi = boot_p99(sh_t, rng, idx_sets), boot_p99(iso_t, rng, idx_sets)
    bd = sorted(x - y for x, y in zip(bq, bi))
    bq = sorted(bq)
    return [L, r, B, rb], q, q_iso, (bq[int(0.025 * BOOT)], bq[int(0.975 * BOOT) - 1]), (bd[int(0.025 * BOOT)], bd[int(0.975 * BOOT) - 1])


def gate(errs_unfav, errs_fav):
    def p95(e):
        e = sorted(e)
        return e[max(0, math.ceil(.95 * len(e)) - 1)]
    u, f = p95(errs_unfav), p95(errs_fav)
    return ("PASS" if u <= .10 else "FAIL" if f > .10 else "INCONCLUSIVE"), u, f


def main(out):
    os.makedirs(out, exist_ok=True)
    u_l = {L: uncontended(L, 64) for L in LC_LENGTHS}
    u_b = {B: uncontended(B, 16) for B in BE_LENGTHS}
    lc_rate = {(L, r): r / u_l[L] for L in LC_LENGTHS for r in RHO_LC}
    be_rate = {(B, rb): rb / u_b[B] for B in BE_LENGTHS for rb in RHO_B}
    pool = multiprocessing.Pool(max(1, os.cpu_count() - 2))
    prof = pool.map(profile_curve, [("LC", L, lc_rate[L, r]) for L in LC_LENGTHS for r in RHO_LC] +
                    [("BE", B, be_rate[B, rb]) for B in BE_LENGTHS for rb in RHO_B])
    curves, q0, iso_sample = {}, {}, {}
    for (kind, length, rate), p95, p99, sample in prof:
        curves.setdefault((kind, length), []).append((rate, p95, p99))
        if kind == "LC":
            q0[length, rate], iso_sample[length, rate] = p99, sample
    a_l = {L: fit_work(curves["LC", L], u_l[L], "LC") for L in LC_LENGTHS}
    a_b = {B: fit_work(curves["BE", B], u_b[B], "BE") for B in BE_LENGTHS}
    profiles = [(L, r, B, rb) for L in LC_LENGTHS for r in RHO_LC for B in BE_LENGTHS for rb in RHO_B]
    preds = pool.map(predict_job, [((L, r, B, rb), lc_rate[L, r], be_rate[B, rb], a_l[L], a_b[B], u_l[L],
                                    q0[L, lc_rate[L, r]], iso_sample[L, lc_rate[L, r]], u_b[B]) for L, r, B, rb in profiles])
    with open(os.path.join(out, "predictions.json"), "w") as f:
        json.dump(dict(u_l=u_l, u_b=u_b, a_l=a_l, a_b=a_b, curves={f"{k[0]}-{k[1]}": v for k, v in curves.items()},
                       predictions=[dict(profile=p, F=fv, F_secondary=fs) for p, fv, fs in preds]), f, indent=1)
    print(f"predictions written for {len(preds)} profiles before any reference trace; a_L {a_l}; a_B {a_b}")
    refs = pool.map(reference_job, [((L, r, B, rb), lc_rate[L, r], be_rate[B, rb]) for L, r, B, rb in profiles])
    pool.close()
    with open(os.path.join(out, "references.json"), "w") as f:
        json.dump([dict(profile=p, Q=q, Q_iso=qi, Q_ci=ci, D_ci=di) for p, q, qi, ci, di in refs], f, indent=1)
    pm = {tuple(p): (fv, fs) for p, fv, fs in preds}
    g1u, g1f, g3u, g3f, sec, strata = [], [], [], [], [], {}
    for p, q, qi, (lo, hi), (dlo, dhi) in refs:
        fv, fs = pm[tuple(p)]
        L, B = p[0], p[2]
        if fv is None:
            eu = ef = du = df = float("inf")
        else:
            eu = max(abs(fv - lo) / lo, abs(fv - hi) / hi)
            ef = 0.0 if lo <= fv <= hi else min(abs(fv - lo) / lo, abs(fv - hi) / hi)
            dF, floor = fv - q0[L, lc_rate[L, p[1]]], 0.1 * u_b[B]
            du = max(abs(dF - dlo) / max(abs(dlo), floor), abs(dF - dhi) / max(abs(dhi), floor))
            df = 0.0 if dlo <= dF <= dhi else min(abs(dF - dlo) / max(abs(dlo), floor), abs(dF - dhi) / max(abs(dhi), floor))
        g1u.append(eu); g1f.append(ef); g3u.append(du); g3f.append(df)
        strata.setdefault(L, ([], []))[0].append(eu)
        strata[L][1].append(ef)
        sec.append(abs(fs - q) / q)
    print("G1 overall          %s  p95 error unfavourable %.1f%% favourable %.1f%%" % (lambda g: (g[0], 100 * g[1], 100 * g[2]))(gate(g1u, g1f)))
    for L in LC_LENGTHS:
        g = gate(*strata[L])
        print(f"G2 LC {L:5d} tokens  {g[0]}  p95 error unfavourable {100 * g[1]:.1f}% favourable {100 * g[2]:.1f}%")
    print("G3 increment        %s  p95 error unfavourable %.1f%% favourable %.1f%%" % (lambda g: (g[0], 100 * g[1], 100 * g[2]))(gate(g3u, g3f)))
    sec.sort()
    print(f"secondary F' (not gated): p95 error {100 * sec[max(0, math.ceil(.95 * len(sec)) - 1)]:.1f}% median {100 * sec[len(sec) // 2]:.1f}%")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
