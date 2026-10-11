"""Which workload summaries suffice to predict the latency-critical shared tail, in the simulator.

Run: python3 hack/tail-crossing-model/sufficiency.py

Implements section 4 of docs/superpowers/specs/2026-10-05-what-an-admission-rule-has-to-know-computational.md
exactly as registered: the domain of section 2, the feature sets of section 3, leave-one-latency-critical-
length-out k-nearest-neighbour prediction (k = 3) on log-standardised features, and the 95th percentile of
the held-out relative error against 10%.
"""
import math
import multiprocessing
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
from itersim import nearest_rank, simulate  # noqa: E402
from predict import PARAMS  # noqa: E402

P = PARAMS["measured"]
LC_LENGTHS = (256, 512, 1024, 2048, 4096, 8192)
RHO_LC = (0.05, 0.15, 0.30, 0.45)
BE_LENGTHS = (2048, 4096, 8192)
RHO_B = (0.01, 0.02, 0.05, 0.10)
SEEDS = range(1, 11)
K = 3


def uncontended(length, out):
    """The simulator's latency of one request alone: the TTFT of a single-request trace."""
    return simulate(0, 0, 0, trace=[(0.0, "lc", length, out)], **P)["lc"][0] / 1000.0


def pooled_p99(args):
    lam_lc, len_lc, lam_be, len_be = args
    vals = []
    for s in SEEDS:
        vals += simulate(lam_lc, len_lc, lam_be, len_be=len_be, seed=s, **P)["lc"]
    return nearest_rank(vals, .99)


def main():
    u_lc = {L: uncontended(L, 64) for L in LC_LENGTHS}
    s_b = {L: uncontended(L, 16) for L in BE_LENGTHS}
    iso_jobs, jobs, meta = [], [], []
    for L in LC_LENGTHS:
        for r in RHO_LC:
            iso_jobs.append((r / u_lc[L], L, 0, 8192))
            for B in BE_LENGTHS:
                for rb in RHO_B:
                    jobs.append((r / u_lc[L], L, rb / s_b[B], B))
                    meta.append((L, r, B, rb))
    with multiprocessing.Pool(max(1, os.cpu_count() - 2)) as pool:
        iso = dict(zip([(j[1], round(j[0] * u_lc[j[1]], 2)) for j in iso_jobs], pool.map(pooled_p99, iso_jobs)))
        shared = pool.map(pooled_p99, jobs)
    rows = []
    for (L, r, B, rb), y in zip(meta, shared):
        iso99 = iso[L, r] / 1000.0
        rows.append(dict(L=L, r=r, B=B, rb=rb, S_B=s_b[B], y=(y / 1000.0) / s_b[B],
                         A=(rb, iso99 / s_b[B]), Bset=(rb, iso99 / s_b[B], r), C=(rb, iso99 / s_b[B], r, L / B)))
    print("uncontended LC latency (s):", {L: round(v, 4) for L, v in u_lc.items()})
    print("S_B (s):", {L: round(v, 4) for L, v in s_b.items()})
    print(f"profiles: {len(rows)} contended, {len(iso)} isolated, {len(SEEDS)} traces each")
    for name, key in (("A (rho_B, iso/S_B)", "A"), ("B (+ rho_LC)", "Bset"), ("C (+ L_LC/L_BE)", "C")):
        errs = []
        for held in LC_LENGTHS:
            train = [x for x in rows if x["L"] != held]
            test = [x for x in rows if x["L"] == held]
            logs = [[math.log(v) for v in x[key]] for x in train]
            dim = len(logs[0])
            mu = [sum(v[i] for v in logs) / len(logs) for i in range(dim)]
            sd = [math.sqrt(sum((v[i] - mu[i]) ** 2 for v in logs) / len(logs)) or 1.0 for i in range(dim)]
            z = [[(v[i] - mu[i]) / sd[i] for i in range(dim)] for v in logs]
            for t in test:
                zt = [(math.log(t[key][i]) - mu[i]) / sd[i] for i in range(dim)]
                near = sorted(range(len(train)), key=lambda j: sum((z[j][i] - zt[i]) ** 2 for i in range(dim)))[:K]
                yhat = math.exp(sum(math.log(train[j]["y"]) for j in near) / K)
                errs.append(abs(yhat - t["y"]) / t["y"])
        errs.sort()
        p95 = errs[max(0, math.ceil(0.95 * len(errs)) - 1)]
        print(f"set {name:22s}: held-out error median {100 * errs[len(errs) // 2]:5.1f}%  p95 {100 * p95:6.1f}%"
              f"  max {100 * errs[-1]:6.1f}%  -> {'SUFFICIENT' if p95 <= 0.10 else 'not sufficient'} at 10%")


if __name__ == "__main__":
    main()
