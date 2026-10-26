"""Fixed-S's and hold-cap's premium p99 at long, and hold-cap's prefill median, per seed and pace, as the main study's
gate replay committed them before purchase (data/2026-10-25-c3-main/gate-*.json and sensitivity-gate-*.json).
It reads those files and runs nothing.
Run from the repository root: python3 docs/superpowers/specs/data/2026-10-26-c3-block2/replay-per-seed.py"""
import glob, json, re

D = "docs/superpowers/specs/data/2026-10-25-c3-main/"
S = 1680.4
files = glob.glob(D + "gate-*.json") + glob.glob(D + "sensitivity-gate-*.json")
# gate-1.0275.json and sensitivity-gate-1.0275.json would be the same pace twice; only gate files carry it here.
by_pace = {}
for f in files:
    j = json.load(open(f))
    by_pace.setdefault(j["pace"], j)
print("pace\tseed\treplay d(long) ms\tmargin over S ms\tfixedS p99 ms\thold-cap p99 ms")
for pace in sorted(by_pace):
    for seed, v in sorted(by_pace[pace]["long"]["per_seed"].items()):
        d = v["hold_cap_prefill_p50_ms"]
        print("%s\t%s\t%.1f\t%+.1f\t%.1f\t%.1f" % (pace, seed, d, d - S, v["premium_p99_ms"]["fixedS"], v["premium_p99_ms"]["hold-cap"]))
