"""Report for kit p5's performance run b1, which is apart from the test arms' verdict and never changes it.

usage: python b1_verdict.py OUT
Reads OUT/status.txt and OUT/b1/: each run's ARM-POOL-RUN.json, and STOPPED or NOT_RUN if run.sh wrote them.
Prints every run's JSON verbatim, as bench_preempt.py wrote it, and its fields on one line; no value is rounded or changed.
The states, in order:
  NOT RUN when a run's has_fix is not false on CONTROL and true on FIX, since then a tree is not the one b1 times;
  INCOMPLETE when b1 stopped, or a run is missing, unreadable or did not exit 0;
  INVALID when a pool-128 run reports no preemption, since then its load did not do what b1 measures,
    when a pool-2304 run reports any, since then it is no longer the no-preemption control,
    when a run's stored_keys is fewer than the blocks its load saves, or its log shows the HF3FS metadata server short of pages,
    since then saves were dropped and the run timed less work;
  VALID otherwise.
Exit status: 0 VALID, 3 INCOMPLETE, 4 NOT RUN, 6 INVALID.
"""

import json
import os
import re
import sys

RUNS = (("control", 128, 1), ("fix", 128, 1), ("control", 128, 2), ("fix", 128, 2), ("control", 128, 3), ("fix", 128, 3),
        ("control", 2304, 1), ("fix", 2304, 1))
# The pool that must preempt, and the one that must not.
PREEMPT_POOL = 128
CONTROL_POOL = 2304
# The in-process metadata server's warning when its file has fewer free pages than a save asks for.
# The save then goes on with the pages it got; the pinned bench's 8 GiB file should never get there.
SHORT_RE = re.compile(r"Rank \d+ only allocated \d+ pages for \d+ keys")
# bench_preempt.py's fixed block size and warm-up prompt, which with each JSON's own counts give the keys its load stores.
BENCH_BLOCK_SIZE = 16
WARMUP_PROMPT_TOKENS = 64


def expected_keys(d):
    """Every full block a load computes is saved: prompt + output - 1 tokens per request, the last token never computed, and the warm-up's."""
    n, prompt, out = d["num_requests"], d["prompt_tokens"], d["output_tokens"]
    return n * ((prompt + out - 1) // BENCH_BLOCK_SIZE) + (WARMUP_PROMPT_TOKENS + out - 1) // BENCH_BLOCK_SIZE
WANT_HAS_FIX = {"control": False, "fix": True}
FIELDS = ("has_fix", "pool_blocks", "wall_s", "output_tok_per_s", "step_ms_p50", "step_ms_p90", "step_ms_p99", "step_ms_max",
          "preemptions", "wait_calls", "wait_total_s", "wait_ms_p50", "wait_ms_max", "stored_keys", "storage_pages")


def judge(out):
    b1 = os.path.join(out, "b1")
    rcs = {}
    if os.path.exists(os.path.join(out, "status.txt")):
        for line in open(os.path.join(out, "status.txt")):
            m = re.match(r"^b1-(\w+)-(\d+)-(\d+) exit=(-?\d+)", line)
            if m:
                rcs[(m.group(1), int(m.group(2)), int(m.group(3)))] = int(m.group(4))
    rec = {"runs": [], "not_run": [], "incomplete": [], "invalid": []}
    for name in ("NOT_RUN", "STOPPED"):
        path = os.path.join(b1, name)
        if os.path.exists(path):
            (rec["not_run"] if name == "NOT_RUN" else rec["incomplete"]).append(f"b1/{name}: " + open(path).read().strip())
    for arm, pool, i in RUNS:
        run = {"name": f"{arm}-{pool}-{i}", "arm": arm, "pool": pool, "exit": rcs.get((arm, pool, i)), "raw": None, "data": None}
        path = os.path.join(b1, f"{arm}-{pool}-{i}.json")
        if os.path.exists(path):
            run["raw"] = open(path).read()
            try:
                run["data"] = json.loads(run["raw"])
            except ValueError as e:
                run["error"] = f"unreadable JSON: {e}"
        rec["runs"].append(run)
        d = run["data"]
        if d is None:
            rec["incomplete"].append(f"{run['name']}: " + (run.get("error") or "no JSON") + f" (exit {run['exit']})")
            continue
        if d.get("has_fix") is not WANT_HAS_FIX[arm]:
            rec["not_run"].append(f"{run['name']}: has_fix={d.get('has_fix')!r}, where the {arm} tree must report {WANT_HAS_FIX[arm]}")
        if d.get("pool_blocks") != pool:
            rec["incomplete"].append(f"{run['name']}: pool_blocks={d.get('pool_blocks')!r}, not {pool}")
        if run["exit"] != 0:
            rec["incomplete"].append(f"{run['name']}: the process exited {run['exit']}")
        if pool == PREEMPT_POOL and d.get("preemptions") == 0:
            rec["invalid"].append(f"{run['name']}: preemptions=0, so the pool-{PREEMPT_POOL} load did not preempt")
        if pool == CONTROL_POOL and d.get("preemptions") != 0:
            rec["invalid"].append(f"{run['name']}: preemptions={d.get('preemptions')!r}, so the pool-{CONTROL_POOL} control preempted")
        try:
            run["expected_keys"] = expected_keys(d)
        except (KeyError, TypeError) as e:
            run["expected_keys"] = None
            rec["incomplete"].append(f"{run['name']}: the JSON lacks the counts stored_keys is checked against ({e!r})")
        if "stored_keys" not in d:
            rec["incomplete"].append(f"{run['name']}: the JSON has no stored_keys, so it is not the pinned bench's")
        elif run["expected_keys"] is not None and d["stored_keys"] < run["expected_keys"]:
            rec["invalid"].append(f"{run['name']}: stored_keys={d['stored_keys']!r}, fewer than the {run['expected_keys']} blocks its load saves")
        log = os.path.join(b1, f"{arm}-{pool}-{i}.log")
        short = [x.strip() for x in open(log, errors="replace")] if os.path.exists(log) else []
        short = [x for x in short if SHORT_RE.search(x)]
        if short:
            rec["invalid"].append(f"{run['name']}: the metadata server ran short of pages {len(short)} times, so saves were dropped; first: {short[0]}")
    if rec["not_run"]:
        rec["state"] = "NOT RUN"
    elif rec["incomplete"]:
        rec["state"] = "INCOMPLETE"
    elif rec["invalid"]:
        rec["state"] = "INVALID"
    else:
        rec["state"] = "VALID"
    return rec


def render(rec):
    lines = ["B1, the performance run: a separate section that does not change the verdict above."]
    for run in rec["runs"]:
        d = run["data"]
        lines.append(f"b1 {run['arm'].upper()} pool {run['pool']} run {run['name'].rsplit('-', 1)[1]} (exit {run['exit']}):")
        if d is None:
            lines.append("  " + (run.get("error") or "no JSON"))
            continue
        # json.dumps writes each value back exactly as it was read, with no rounding.
        lines.append("  " + " ".join(f"{k}={json.dumps(d.get(k))}" for k in FIELDS) + f" (expected_keys={run.get('expected_keys')})")
        lines.append("  verbatim:")
        lines.extend("    " + x for x in run["raw"].rstrip("\n").split("\n"))
    for key, label in (("not_run", "NOT RUN"), ("incomplete", "INCOMPLETE"), ("invalid", "INVALID")):
        lines.extend(f"B1 {label}: {x}" for x in rec[key])
    lines.append(f"B1: {rec['state']}")
    return lines


def main(argv):
    if len(argv) != 2 or not os.path.isdir(argv[1]):
        print("usage: b1_verdict.py OUT", file=sys.stderr)
        return 3
    rec = judge(argv[1])
    os.makedirs(os.path.join(argv[1], "b1"), exist_ok=True)
    with open(os.path.join(argv[1], "b1", "b1-verdict.json"), "w") as f:
        json.dump({k: v for k, v in rec.items() if k != "runs"} | {"runs": [{k: v for k, v in r.items() if k != "raw"} for r in rec["runs"]]},
                  f, indent=1, sort_keys=True)
    print("\n".join(render(rec)))
    return {"VALID": 0, "NOT RUN": 4, "INVALID": 6}.get(rec["state"], 3)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
