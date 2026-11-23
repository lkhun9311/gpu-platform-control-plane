"""Report for kit p6's bench arm b2, on FIX alone, which is apart from the test arm's verdict and never changes it.

usage: python b2_verdict.py OUT
Reads OUT/status.txt and OUT/b2/: each run's fix-POOL-RUN.json and .log, and STOPPED or NOT_RUN if run.sh wrote them.
Prints every run's JSON verbatim, as bench_preempt_v2.py wrote it, its fields on one line, and b1's stored_keys at the same pool beside it.
No value is rounded or changed.
The states, in order:
  NOT RUN when a run's has_fix is not true or its fix_wait is not wait_for_gathers, since then the tree is not the gather-only head;
  INCOMPLETE when b2 stopped, or a run is missing, unreadable, did not exit 0, or has no fix_wait, since then it is not bench_preempt_v2.py's;
  INVALID, by the runtime session's rules of 2026-11-23, when
    (a) a run's log shows a save failure, or the metadata server short of pages;
    (b) a run's stored_keys is not within 1% of b1's at the same pool;
    (c) the pool-2304 run's stored_keys is not exactly 2,003;
    or a pool-128 run did not preempt, or the pool-2304 run did;
  VALID otherwise.
Exit status: 0 VALID, 3 INCOMPLETE, 4 NOT RUN, 6 INVALID.
"""

import json
import os
import re
import sys

RUNS = (("fix", 128, 1), ("fix", 128, 2), ("fix", 128, 3), ("fix", 2304, 1))
PREEMPT_POOL = 128
CONTROL_POOL = 2304
FIX_WAIT = "wait_for_gathers"
# b1's stored_keys (gpuaas 28845963), by pool and arm, which b2's FIX runs are compared with.
B1_STORED = {128: {"control": (1882, 1883, 1883), "fix": (1883, 1883, 1883)}, 2304: {"control": (2003,), "fix": (2003,)}}
# (b): within this fraction of every b1 value at the same pool.
B1_TOLERANCE = 0.01
# (c): the blocks a pool-2304 load saves, which nothing preempts: 64 requests x 31 full blocks + 19 for the warm-up.
CONTROL_POOL_KEYS = 2003
# (a): the HF3FS connector's save failures, and the metadata server's warning when its file has fewer free pages than a save asks for.
SAVE_FAILURE_RE = re.compile(r"Page allocation failed|Buffer allocation failed|Write operation failed|Task execution error")
SHORT_RE = re.compile(r"Rank \d+ only allocated \d+ pages for \d+ keys")
FIELDS = ("has_fix", "fix_wait", "pool_blocks", "wall_s", "output_tok_per_s", "step_ms_p50", "step_ms_p90", "step_ms_p99", "step_ms_max",
          "preemptions", "wait_calls", "wait_total_s", "wait_ms_p50", "wait_ms_max", "stored_keys", "storage_pages")


def b1_values(pool):
    return [v for arm in ("control", "fix") for v in B1_STORED[pool][arm]]


def b1_text(pool):
    b = B1_STORED[pool]
    return f"b1 at pool {pool}: CONTROL {'/'.join(map(str, b['control']))}, FIX {'/'.join(map(str, b['fix']))}"


def judge(out):
    b2 = os.path.join(out, "b2")
    rcs = {}
    if os.path.exists(os.path.join(out, "status.txt")):
        for line in open(os.path.join(out, "status.txt")):
            m = re.match(r"^b2-(\w+)-(\d+)-(\d+) exit=(-?\d+)", line)
            if m:
                rcs[(m.group(1), int(m.group(2)), int(m.group(3)))] = int(m.group(4))
    rec = {"runs": [], "not_run": [], "incomplete": [], "invalid": []}
    for name in ("NOT_RUN", "STOPPED"):
        path = os.path.join(b2, name)
        if os.path.exists(path):
            (rec["not_run"] if name == "NOT_RUN" else rec["incomplete"]).append(f"b2/{name}: " + open(path).read().strip())
    for arm, pool, i in RUNS:
        name = f"{arm}-{pool}-{i}"
        run = {"name": name, "arm": arm, "pool": pool, "exit": rcs.get((arm, pool, i)), "raw": None, "data": None, "failures": []}
        path = os.path.join(b2, f"{name}.json")
        if os.path.exists(path):
            run["raw"] = open(path).read()
            try:
                run["data"] = json.loads(run["raw"])
            except ValueError as e:
                run["error"] = f"unreadable JSON: {e}"
        log = os.path.join(b2, f"{name}.log")
        # Rule (a) reads the log, so a run without a readable one cannot be shown free of save failures.
        try:
            run["failures"] = [x.strip() for x in open(log, errors="replace") if SAVE_FAILURE_RE.search(x) or SHORT_RE.search(x)]
            run["log_ok"] = True
        except OSError as e:
            run["log_ok"] = False
            run["log_error"] = f"no readable log: {e}"
        rec["runs"].append(run)
        d = run["data"]
        if not run["log_ok"]:
            rec["incomplete"].append(f"{name}: {run['log_error']}, so rule (a) cannot be checked")
        if d is None:
            rec["incomplete"].append(f"{name}: " + (run.get("error") or "no JSON") + f" (exit {run['exit']})")
            continue
        if d.get("has_fix") is not True:
            rec["not_run"].append(f"{name}: has_fix={d.get('has_fix')!r}, where the FIX tree must report True")
        if "fix_wait" not in d:
            rec["incomplete"].append(f"{name}: the JSON has no fix_wait, so it is not bench_preempt_v2.py's")
        elif d["fix_wait"] != FIX_WAIT:
            rec["not_run"].append(f"{name}: fix_wait={d['fix_wait']!r}, where the gather-only head times {FIX_WAIT}")
        if d.get("pool_blocks") != pool:
            rec["incomplete"].append(f"{name}: pool_blocks={d.get('pool_blocks')!r}, not {pool}")
        if run["exit"] != 0:
            rec["incomplete"].append(f"{name}: the process exited {run['exit']}")
        if pool == PREEMPT_POOL and d.get("preemptions") == 0:
            rec["invalid"].append(f"{name}: preemptions=0, so the pool-{PREEMPT_POOL} load did not preempt")
        if pool == CONTROL_POOL and d.get("preemptions") != 0:
            rec["invalid"].append(f"{name}: preemptions={d.get('preemptions')!r}, so the pool-{CONTROL_POOL} control preempted")
        if run["failures"]:
            rec["invalid"].append(f"{name}: (a) {len(run['failures'])} save failure lines in its log; first: {run['failures'][0]}")
        keys = d.get("stored_keys")
        if not isinstance(keys, int):
            rec["incomplete"].append(f"{name}: stored_keys={keys!r} is not a count")
            continue
        # Within 1% of every b1 value: the intersection of their bands, 1,864.17 to 1,900.82 at pool 128.
        lo, hi = max(v * (1 - B1_TOLERANCE) for v in b1_values(pool)), min(v * (1 + B1_TOLERANCE) for v in b1_values(pool))
        if not lo <= keys <= hi:
            rec["invalid"].append(f"{name}: (b) stored_keys={keys} is not within {B1_TOLERANCE:.0%} of {b1_text(pool)}")
        if pool == CONTROL_POOL and keys != CONTROL_POOL_KEYS:
            rec["invalid"].append(f"{name}: (c) stored_keys={keys}, not exactly {CONTROL_POOL_KEYS}")
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
    lines = ["B2, the bench arm on FIX: a separate section that does not change the verdict above."]
    for run in rec["runs"]:
        d = run["data"]
        lines.append(f"b2 FIX pool {run['pool']} run {run['name'].rsplit('-', 1)[1]} (exit {run['exit']}):")
        if d is None:
            lines.append("  " + (run.get("error") or "no JSON"))
            continue
        # json.dumps writes each value back exactly as it was read, with no rounding.
        lines.append("  " + " ".join(f"{k}={json.dumps(d.get(k))}" for k in FIELDS))
        lines.append(f"  stored_keys {json.dumps(d.get('stored_keys'))} beside {b1_text(run['pool'])}")
        lines.append(f"  save failure lines in its log: {len(run['failures'])}")
        lines.append("  verbatim:")
        lines.extend("    " + x for x in run["raw"].rstrip("\n").split("\n"))
    for key, label in (("not_run", "NOT RUN"), ("incomplete", "INCOMPLETE"), ("invalid", "INVALID")):
        lines.extend(f"B2 {label}: {x}" for x in rec[key])
    lines.append(f"B2: {rec['state']}")
    return lines


def main(argv):
    if len(argv) != 2 or not os.path.isdir(argv[1]):
        print("usage: b2_verdict.py OUT", file=sys.stderr)
        return 3
    rec = judge(argv[1])
    os.makedirs(os.path.join(argv[1], "b2"), exist_ok=True)
    with open(os.path.join(argv[1], "b2", "b2-verdict.json"), "w") as f:
        json.dump({k: v for k, v in rec.items() if k != "runs"} | {"runs": [{k: v for k, v in r.items() if k != "raw"} for r in rec["runs"]]},
                  f, indent=1, sort_keys=True)
    print("\n".join(render(rec)))
    return {"VALID": 0, "NOT RUN": 4, "INVALID": 6}.get(rec["state"], 3)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
