"""What the engine's step log shows of contender prefill in each block's long cells: the most contenders given prompt
tokens in one step, the most started and unfinished at once, the steps with two contenders' prompt work, and of those
the steps that used the whole 512-token budget with no premium prompt work in them.
Run from the repository root with the three blocks' archives in block order:
  python3 docs/superpowers/specs/data/2026-10-26-c3-block2/engine-steps.py <block 1's m5c-run> <block 2's> <block 3's>
A contender is a request whose prompt exceeds 1,000 tokens, as the scorer's engine_prefill takes it; a request still
owed prompt tokens in a step is prefilling in it."""
import sys
sys.path.insert(0, "hack/prospective-pilot")
import simulate as sim

print("arm\tblock\tmost contenders given prompt tokens in one step\tmost started and unfinished\tsteps with 2 contenders' prompt work\tof them full budget, no premium prompt work")
for arm in ("fixedS-long", "hold-cap-long", "sizeaware-long"):
    for b, d in enumerate(sys.argv[1:], start=1):
        _, steps, adds = sim.load_cell(d, arm, 1)
        started, finished = set(), set()
        most_step = most_open = two = crowded = 0
        for s in (x for x in steps if x.get("ev") == "sched"):
            owed = [e for e in s["tokens"] if e in adds and s["computed"].get(e, 0) < adds[e]["prompt"]]
            cont = [e for e in owed if adds[e]["prompt"] > 1000]
            started.update(cont)
            # A contender finishing in this step was still prefilling in it, so it counts before it is marked done.
            most_open = max(most_open, len(started - finished))
            finished.update(e for e in cont if s["computed"].get(e, 0) + s["tokens"][e] >= adds[e]["prompt"])
            most_step = max(most_step, len(cont))
            if len(cont) >= 2:
                two += 1
                if sum(s["tokens"].values()) >= 512 and not any(adds[e]["prompt"] <= 1000 for e in owed):
                    crowded += 1
        print("%s\t%d\t%d\t%d\t%d\t%d" % (arm, b, most_step, most_open, two, crowded))
