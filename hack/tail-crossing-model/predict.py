"""Print the model's check against the one measured operating point, then its predictions for the curve.

Run: python3 hack/tail-crossing-model/predict.py
The traces are drawn by Python's generator, not the harness's, so a model trace is not the trace a cell replays.
"""
import statistics

from itersim import nearest_rank, simulate

# Two parameter sets.
# NOMINAL is fitted to the 2026-09-04 microtest (fcfs, 7,695 tokens): 685 / 623 / 588 ms long TTFT at budgets
# 512 / 2048 / 8192 and a 48.7 ms uncontended short TTFT.
# SLOW raises only the per-token prefill cost, because the shared run's contender never finished a first token
# in under about 1.18 s, which NOMINAL cannot produce.
PARAMS = {
    "nominal": dict(C0=0.007, B=0.0000715, D=0.0003, OC=0.032),
    "slow-prefill": dict(C0=0.007, B=0.00011, D=0.0003, OC=0.032),
}

# The one operating point measured with both tenants, m5c-20261002-014903 (readings.txt:5-13).
RATE, NOISY_WEIGHT = 9.4045, 0.026
LC_RATE = RATE / (1 + NOISY_WEIGHT)
BE_RATE = RATE * NOISY_WEIGHT / (1 + NOISY_WEIGHT)
MEASURED = "R1 p99 174.268 ms; shared p99 4000.579 ms (per-repetition medians, one trace, seed 11)"

SEEDS = range(1, 6)
LAM_LC = 0.2864
BE_LOADS = (0.0286, 0.0716, 0.1432, 0.2864)


def check():
    print(f"## model check against the measured point: {MEASURED}")
    for name, p in PARAMS.items():
        r1 = [nearest_rank(simulate(LC_RATE, 256, 0, dur=505, seed=s, **p)["lc"], .99) for s in SEEDS]
        sh = [nearest_rank(simulate(LC_RATE, 256, BE_RATE, dur=505, seed=s, **p)["lc"], .99) for s in SEEDS]
        print(f"  {name:13s} R1 p99 per trace {fmt(r1)}  shared p99 per trace {fmt(sh)}")


def fmt(xs):
    return "[" + ", ".join(f"{x:.0f}" for x in xs) + "]"


def predict():
    for name, p in PARAMS.items():
        print(f"## prediction, {name}: LC {LAM_LC} req/s, {len(SEEDS)} traces of 600 s per cell")
        for length in (256, 8192):
            iso = [simulate(LAM_LC, length, 0, seed=s, **p)["lc"] for s in SEEDS]
            iso_pool = [x for t in iso for x in t]
            b99, b95 = nearest_rank(iso_pool, .99), nearest_rank(iso_pool, .95)
            print(f"  LC {length:5d} tokens  isolated pooled p99 {b99:.0f}  p95 {b95:.0f}  (n={len(iso_pool)})")
            for lam_be in BE_LOADS:
                sh = [simulate(LAM_LC, length, lam_be, seed=s, **p)["lc"] for s in SEEDS]
                per = [nearest_rank(t, .99) for t in sh]
                pool = [x for t in sh for x in t]
                s99, s95 = nearest_rank(pool, .99), nearest_rank(pool, .95)
                print(f"    BE {lam_be:.4f}/s  per-trace p99 {fmt(per)} (median {statistics.median(per):.0f})"
                      f"  pooled p99 {s99:.0f} = {s99 / b99:.2f}x, +{s99 - b99:.0f} ms"
                      f"  pooled p95 {s95:.0f} = {s95 / b95:.2f}x, +{s95 - b95:.0f} ms")


def sweep():
    """P3's window: where the short level's added p99 exceeds the long level's, on a finer BE grid.

    P3 originally tested "the lowest BE load" without saying which, and the model reverses its direction
    below the short level's coincidence threshold, so the window has to be read off the model, not assumed.
    """
    for name, p in PARAMS.items():
        print(f"## P3 sweep, {name}: added pooled p99 (ms), LC 256 against LC 8192")

        def pooled(length, lam_be):
            return nearest_rank([x for s in SEEDS for x in simulate(LAM_LC, length, lam_be, seed=s, **p)["lc"]], .99)

        base = {length: pooled(length, 0) for length in (256, 8192)}
        for lam_be in (0.005, 0.01, 0.015, 0.02, 0.0286, 0.04, 0.0716, 0.1, 0.1432, 0.2, 0.2864, 0.4):
            short, long_ = pooled(256, lam_be) - base[256], pooled(8192, lam_be) - base[8192]
            print(f"  BE {lam_be:.4f}/s  short +{short:.0f}  long +{long_:.0f}  {'short > long' if short > long_ else 'REVERSED'}")


def power():
    """How often P3's registered test holds on the model itself, across disjoint sets of five traces.

    A pointwise sign test was registered first and the model broke it at an untested rate inside the window
    (slow-prefill, 0.086 req/s), so the test is chosen by its behaviour here rather than by how it reads.
    """
    sets = [range(100 + 5 * j, 105 + 5 * j) for j in range(20)]
    for name, p in PARAMS.items():
        s_b = 4 * p["C0"] + p["B"] * 8192 + p["OC"]
        lam99 = 0.01 / s_b
        grid = [lam99 * k for k in (2, 3, 4, 5, 6, 7, 8, 10)]
        points, means = [], 0
        for seeds in sets:
            def pooled(length, lam_be):
                return nearest_rank([x for s in seeds for x in simulate(LAM_LC, length, lam_be, seed=s, **p)["lc"]], .99)

            base = {length: pooled(length, 0) for length in (256, 8192)}
            diff = [(pooled(256, g) - base[256]) - (pooled(8192, g) - base[8192]) for g in grid]
            points.append(sum(d > 0 for d in diff))
            means += statistics.mean(diff) > 0
        print(f"## P3 power, {name}: S_B {s_b:.3f} s, window {grid[0]:.4f}-{grid[-1]:.4f} req/s, 8 points, 20 sets of 5 traces")
        print(f"  points in the predicted direction per set: {points}")
        print(f"  sets whose mean difference over the window is positive: {means}/20")


if __name__ == "__main__":
    check()
    predict()
    sweep()
    power()
