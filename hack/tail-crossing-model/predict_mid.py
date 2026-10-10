"""The 2,048-token level's curve, predicted before any of its cells is bought.

Run: python3 hack/tail-crossing-model/predict_mid.py

It generates, with the real `benchharness gen-trace`, the exact traces the stage will replay -- the seeds,
rates, duration and prompt lengths are the stage's own -- and puts each through the model with the
`measured` parameters, which were fixed on 2026-10-05 from one isolated measurement and have not been
re-fitted since. So what this prints is a prediction for those traces, not for a fresh draw of the arrival
process, and the only error left between it and the card is the model's.

It also prints the two other levels' measured multiples beside the prediction, which is what P5 compares.
"""
import json
import os
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(__file__))
from itersim import nearest_rank, simulate  # noqa: E402
from predict import PARAMS  # noqa: E402

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
STUDY = "tail-crossing-lc2048-2026-10-05"
LC_RATE, SEEDS, DURATION_MS = 0.2864, (1, 2, 3), 600000
LEVELS = {"be01-shared": 0.0241, "be02-shared": 0.0482, "be03-shared": 0.0964, "be04-shared": 0.1927}
CHARS_TO_TOKENS = {10532: 2048, 42579: 8192}
# The other two levels' measured pooled p99 multiples (stage 2, 256 tokens; stage 3, 8,192 tokens), from
# the 2026-10-05 result. P5 says the 2,048-token level's multiple lies strictly between them.
MEASURED_MULTIPLE = {
    "be01-shared": (11.56, 1.06), "be02-shared": (10.59, 1.09),
    "be03-shared": (13.30, 1.25), "be04-shared": (17.55, 1.46),
}


def gen_trace(arm, seed, noisy_rate, out):
    cmd = [os.path.join(out, "benchharness"), "gen-trace", "--seed", str(seed), "--duration-ms", str(DURATION_MS),
           "--premium-rate", str(LC_RATE), "--noisy-rate", str(noisy_rate), "--probe-rate", "0",
           "--study", STUDY, "--arm", arm, "--premium-prompt-chars", "10532", "--noisy-prompt-chars", "42579",
           "--premium-output-tokens", "64", "--noisy-output-tokens", "16", "--timeout-ms", "60000",
           "--trace-out", os.path.join(out, f"{arm}-{seed}.jsonl"), "--manifest-out", os.path.join(out, f"{arm}-{seed}.yaml")]
    subprocess.run(cmd, check=True, capture_output=True)
    with open(os.path.join(out, f"{arm}-{seed}.jsonl")) as f:
        return [(r["offsetMs"] / 1000.0, "be" if r["isNoisy"] else "lc", CHARS_TO_TOKENS[r["promptLenChars"]], r["maxOutputTokens"])
                for r in map(json.loads, f)]


def main():
    p = PARAMS["measured"]
    with tempfile.TemporaryDirectory() as out:
        subprocess.run(["go", "build", "-o", os.path.join(out, "benchharness"), "./cmd/benchharness"], check=True, cwd=ROOT)
        pooled = {}
        for arm, rate in [("R1", LEVELS["be01-shared"])] + list(LEVELS.items()):
            ttft = []
            for seed in SEEDS:
                ttft += simulate(0, 0, 0, trace=gen_trace(arm, seed, rate, out), **p)["lc"]
            pooled[arm] = (nearest_rank(ttft, .95), nearest_rank(ttft, .99), len(ttft))
    b95, b99, n = pooled["R1"]
    print(f"# predicted with the 'measured' parameters on the stage's own traces (seeds {SEEDS})")
    print(f"R1          n={n}  p95 {b95:.1f}  p99 {b99:.1f}")
    for arm, rate in LEVELS.items():
        q95, q99, _ = pooled[arm]
        hi, lo = MEASURED_MULTIPLE[arm]
        m = q99 / b99
        print(f"{arm} BE {rate}/s  p95 {q95:.1f}  p99 {q99:.1f}  = {m:.2f}x, +{q99 - b99:.1f} ms"
              f"   [256 measured {hi}x > predicted {m:.2f}x > 8192 measured {lo}x: {'yes' if lo < m < hi else 'NO'}]")


if __name__ == "__main__":
    main()
