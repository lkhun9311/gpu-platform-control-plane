#!/usr/bin/env python3
"""What the local rehearsal of the Slurm on EC2 session must show, read from its verdict.json.

The rehearsal has no GPU, so B1a's CUDA rule must not hold and B1b must be INVALID in every repetition; everything
else must be observed and every rule held. Any other outcome is a FAIL, printed per line; exit 1 if any.
"""
import json
import sys

v = json.load(open(sys.argv[1]))
fails = []
if v.get("void"):
    fails.append("the session was VOID: " + "; ".join(v["void"]))
else:
    for r in v["b1"]:
        held = {x["rule"]: x["held"] for x in r.get("rules", [])}
        if r["status"] != "observed" or held.get("B1a: a CUDA op returns the expected sum") is not False:
            fails.append(f"B1 rep {r['rep']}: expected observed with no CUDA, got {r['status']} {held}")
        if r.get("b1b", {}).get("status") != "INVALID":
            fails.append(f"B1 rep {r['rep']}: expected B1b INVALID, got {r.get('b1b')}")
    checks = [(f"B2 rep {r['rep']}", r) for r in v["b2"]] + [(f"B3{k}", r) for k, r in sorted(v["b3"].items())] + [("B4", v["b4"])]
    if len(v["b2"]) != 3 or sorted(v["b3"]) != ["a", "b"]:
        fails.append(f"expected 3 B2 repetitions and B3a, B3b; got {len(v['b2'])} and {sorted(v['b3'])}")
    for label, r in checks:
        if r["status"] != "observed":
            fails.append(f"{label}: {r['status']}: {r['reasons']}")
        for x in r.get("rules", []):
            if not x["held"]:
                fails.append(f"{label}: did not hold: {x['rule']}")
for f in fails:
    print("FAIL " + f)
print(f"{len(fails)} FAIL(s)")
sys.exit(1 if fails else 0)
