"""A1 part 1: does the replay's step model hold in the capped regime, by contender chunk size?

Fits simulate.py's five-feature step model on pilot A and B exactly as the replay does (checked against the
published coefficients and the 282,897-step count), then measures, on every other GPU archive of the pilot load
(diagnostic D, frontier E, length calibration F), the measured step period against the prediction, binned by the
largest contender chunk in the step and by whether the step's total tokens fit the 128-token CUDA-graph capture.
Also refits on every archive and reports the same bins in-sample, and the count of steps per bin, so coverage of
small capped chunks deep in a contender's context is visible.

Read-only on the archives; writes nothing but stdout.
"""
import json
import os
import sys

sys.path.insert(0, "/home/lkhun9311/workspace/gpu-cp-t2/hack/prospective-pilot")
import pilot_report as pr  # noqa: E402
import simulate as sim  # noqa: E402

H = "/home/lkhun9311/workspace/gpu-platform-control-plane/hack/"
FIT = [H + "m5c-20261008-235046-pilotA/m5c-run", H + "m5c-20261009-013656-pilotB/m5c-run"]
HELD = [H + "m5c-20261009-122503-diagD/m5c-run", H + "m5c-20261010-024449-frontierE/m5c-run",
        H + "m5c-20261010-080107-lencalF/m5c-run"]

BINS = [(0, 0), (1, 64), (65, 128), (129, 192), (193, 256), (257, 383), (384, 384), (385, 511), (512, 512)]


def cell_steps(d, arm, rep):
    """(features, period ms, largest contender chunk, contender context before it, total tokens) per busy step."""
    steps = pr.jsonl(os.path.join(d, "step-log-%s-%d.jsonl" % (arm, rep)))
    adds = {s["id"]: s for s in steps if s.get("ev") == "add"}
    sched = [s for s in steps if s.get("ev") == "sched"]
    out = []
    for a, b in zip(sched, sched[1:]):
        period = (b["t0"] - a["t0"]) / 1e6
        if period > 500:
            continue
        chunk, ctx = 0, 0
        for e, n in a["tokens"].items():
            p = adds[e]["prompt"] if e in adds else 0
            c = a["computed"].get(e, 0)
            if p > 1000 and c < p:
                f = min(n, p - c)
                if f > chunk:
                    chunk, ctx = f, c
        out.append((sim.step_features(a, adds), period, chunk, ctx, sum(a["tokens"].values())))
    return out


def fit(dirs):
    k = 5
    xtx = [[0.0] * k for _ in range(k)]
    xty = [0.0] * k
    n = 0
    for d in dirs:
        for arm, rep in pr.cells(d):
            for x, y, _, _, _ in cell_steps(d, arm, rep):
                for i in range(k):
                    xty[i] += x[i] * y
                    for j in range(k):
                        xtx[i][j] += x[i] * x[j]
                n += 1
    return sim.solve(xtx, xty), n


def binname(chunk):
    for lo, hi in BINS:
        if lo <= chunk <= hi:
            return "%d-%d" % (lo, hi)
    return "?"


def evaluate(dirs, coef, label):
    acc = {}
    for d in dirs:
        sess = os.path.basename(os.path.dirname(d))
        for arm, rep in pr.cells(d):
            for x, y, chunk, ctx, tot in cell_steps(d, arm, rep):
                p = sum(c * v for c, v in zip(coef, x))
                deep = "deep" if ctx >= 2000 else "shallow"
                graph = "<=128" if tot <= 128 else ">128"
                for key in (("chunk", binname(chunk)), ("chunk-depth", binname(chunk), deep if chunk else "-"),
                            ("graph", graph, "contender" if chunk else "no-contender"),
                            ("session-arm", sess[-9:], arm)):
                    a = acc.setdefault(key, [0, 0.0, 0.0, []])
                    a[0] += 1
                    a[1] += y
                    a[2] += p
                    if len(a[3]) < 200000:
                        a[3].append(y / p if p > 0 else float("nan"))
    print("== %s" % label)
    print("key | steps | sum measured / sum predicted | median per-step ratio | p10 | p90")
    for key in sorted(acc, key=lambda k: (k[0], str(k[1:]))):
        n, y, p, r = acc[key]
        r = sorted(v for v in r if v == v)
        print("%s | %d | %.4f | %.4f | %.4f | %.4f" % (
            " ".join(map(str, key)), n, y / p, pr.nearest_rank(r, 0.5), pr.nearest_rank(r, 0.1), pr.nearest_rank(r, 0.9)))


def main():
    coef, n = fit(FIT)
    print(json.dumps({"fit": "pilotA+pilotB", "coef_ms": [round(c, 4) for c in coef], "steps": n}))
    evaluate(HELD, coef, "held out: diagD, frontierE, lencalF, fitted on pilots A and B")
    evaluate(FIT, coef, "in sample: pilots A and B")
    coef_all, n_all = fit(FIT + HELD)
    print(json.dumps({"fit": "all five sessions", "coef_ms": [round(c, 4) for c in coef_all], "steps": n_all}))
    evaluate(HELD, coef_all, "capped sessions, fitted on all five")


if __name__ == "__main__":
    main()
