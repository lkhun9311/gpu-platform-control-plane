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


if __name__ == "__main__":
    check()
    predict()
