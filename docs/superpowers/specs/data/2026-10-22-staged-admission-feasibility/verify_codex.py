"""Re-derive codex's coverage claims and the tenant token shares from the measured step logs."""
import glob, json, os, sys
H = "/home/lkhun9311/workspace/gpu-platform-control-plane/hack/"
DIRS = [H + s + "/m5c-run" for s in ("m5c-20261008-235046-pilotA", "m5c-20261009-013656-pilotB", "m5c-20261009-122503-diagD",
                                     "m5c-20261010-024449-frontierE", "m5c-20261010-080107-lencalF")]
bins = [(1, 64), (65, 128), (129, 256), (257, 384), (385, 512)]
cov = {b: {"steps": 0, "first": 0, "interior": 0, "final": 0, "int_ctx": [], "int_total512": 0, "int_other_contender": 0} for b in bins}
for d in DIRS:
    for p in sorted(glob.glob(d + "/step-log-*.jsonl")):
        adds = {}
        for line in open(p):
            s = json.loads(line)
            if s.get("ev") == "add":
                adds[s["id"]] = s["prompt"]
                continue
            if s.get("ev") != "sched":
                continue
            seen = set()
            pf_cont = [e for e, n in s["tokens"].items() if adds.get(e) == 7695 and s["computed"].get(e, 0) < 7695]
            for e in pf_cont:
                c = s["computed"].get(e, 0)
                f = min(s["tokens"][e], 7695 - c)
                for b in bins:
                    if b[0] <= f <= b[1]:
                        x = cov[b]
                        if b not in seen:
                            x["steps"] += 1
                            seen.add(b)
                        if c == 0:
                            x["first"] += 1
                        elif c + f < 7695:
                            x["interior"] += 1
                            x["int_ctx"].append(c)
                            if sum(s["tokens"].values()) == 512:
                                x["int_total512"] += 1
                            if len(pf_cont) > 1:
                                x["int_other_contender"] += 1
                        else:
                            x["final"] += 1
for b in bins:
    x = cov[b]
    ctx = x["int_ctx"]
    print(b, {k: v for k, v in x.items() if k != "int_ctx"}, "interior ctx range", (min(ctx), max(ctx)) if ctx else None)
# Token shares by tenant in diagD off cells, measured.
for rep in (1, 2, 3):
    p = H + "m5c-20261009-122503-diagD/m5c-run/step-log-off-%d.jsonl" % rep
    adds, prem, cont = {}, 0, 0
    for line in open(p):
        s = json.loads(line)
        if s.get("ev") == "add":
            adds[s["id"]] = s["prompt"]
        elif s.get("ev") == "sched":
            for e, n in s["tokens"].items():
                if adds.get(e) == 7695:
                    cont += n
                elif adds.get(e) == 68:
                    prem += n
    print("diagD off-%d tokens premium %d contender %d contender share %.4f" % (rep, prem, cont, cont / (prem + cont)))
