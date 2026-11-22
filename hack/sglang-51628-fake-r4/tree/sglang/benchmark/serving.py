"""A fake sglang.benchmark.serving for the #51628 kit r4's offline test, with the decode fields r4 reads.

It takes only the flags the kit passes, asks the fake server for one burst, and writes the result line the real client writes.
FAKE_BURST_FAIL=<seed> makes the burst with that seed exit 1 without a result; FAKE_SHORT=<seed> completes one request fewer.
"""

import argparse
import json
import os
import sys
import time
import urllib.request

p = argparse.ArgumentParser()
for flag in ("--backend", "--host", "--model", "--tokenizer", "--dataset-name", "--output-file"):
    p.add_argument(flag, required=True)
p.add_argument("--port", type=int, required=True)
p.add_argument("--random-input-len", type=int, required=True)
p.add_argument("--random-output-len", type=int, required=True)
p.add_argument("--random-range-ratio", type=float, required=True)
p.add_argument("--num-prompts", type=int, required=True)
p.add_argument("--max-concurrency", type=int, required=True)
p.add_argument("--seed", type=int, required=True)
p.add_argument("--output-details", action="store_true")
p.add_argument("--disable-tqdm", action="store_true")
a = p.parse_args()
if a.dataset_name != "random-ids" or (a.random_input_len, a.random_output_len, a.random_range_ratio) != (1024, 512, 1.0):
    sys.exit("fake client: not the spec's traffic")
if os.environ.get("FAKE_BURST_FAIL") == str(a.seed):
    sys.exit(1)
with urllib.request.urlopen(f"http://{a.host}:{a.port}/fake_burst?seed={a.seed}", timeout=30) as r:
    stall = json.loads(r.read())["stall_ms"]
time.sleep(0.2)
n = a.num_prompts
done = n - 1 if os.environ.get("FAKE_SHORT") == str(a.seed) else n
ttfts = [(50.0 + stall + 3 * i) / 1000 for i in range(done)]
ms = sorted(t * 1000 for t in ttfts)
result = {
    "completed": done,
    "max_concurrency": a.max_concurrency,
    "mean_ttft_ms": sum(ms) / len(ms),
    "median_ttft_ms": ms[len(ms) // 2],
    "p99_ttft_ms": ms[-1],
    "ttfts": ttfts,
    "errors": [""] * done,
    # r4 reads the c16 decode numbers; a stall on the first burst does not touch them.
    "median_itl_ms": 21.75,
    "output_throughput": 265.0 - (5.0 if os.environ.get("FAKE_SLOW_DECODE") == "1" else 0.0),
}
with open(a.output_file, "a") as f:
    f.write(json.dumps(result) + "\n")
