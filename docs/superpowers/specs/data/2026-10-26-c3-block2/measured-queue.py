"""What the gateway measured in each block's cell: contenders held by the spacing and their longest wait, how many
contenders were in prefill at once and for how long, and how many premium requests waited past 600 and 1,000 ms.
Run from the repository root with the three blocks' archives in block order:
  python3 docs/superpowers/specs/data/2026-10-26-c3-block2/measured-queue.py <block 1's m5c-run> <block 2's> <block 3's>
A contender is taken to be in prefill from its admission to its first content, which includes its first decode step.
Premium waits here run from the gateway's arrival to its first content; they are not the registered endpoint."""
import json, sys

ARMS = ["fixedS-long", "hold-cap-long", "fixedS-ref", "sizeaware-long", "off-long"]
print("arm\tblock\tadmitted\theld by the spacing\tmax wait ms\tpeak in prefill\tseconds with 2+ in prefill\tpremium\tpremium > 600 ms\tpremium > 1000 ms")
for arm in ARMS:
    for b, d in enumerate(sys.argv[1:], start=1):
        done = [r for r in map(json.loads, open("%s/gateway-record-%s-1.jsonl" % (d, arm))) if r.get("ev") == "done"]
        c = [r for r in done if r.get("tenant") == "standard-noisy" and r.get("decision") == "admit"]
        held = sum(1 for r in c if r.get("reason") == "fixed_spacing_waited")
        wait = max((r["decidedUnixNanos"] - r["arrivedUnixNanos"]) / 1e6 for r in c)
        # An end sorts before a start at the same instant, so a release at first content is not counted as overlap.
        ev = sorted([(r["decidedUnixNanos"], 1) for r in c] + [(r["firstContentUnixNanos"], -1) for r in c])
        live = peak = 0
        two, last = 0.0, None
        for t, s in ev:
            if last is not None and live >= 2:
                two += (t - last) / 1e9
            live += s
            peak = max(peak, live)
            last = t
        p = [(r["firstContentUnixNanos"] - r["arrivedUnixNanos"]) / 1e6 for r in done
             if r.get("tenant") == "premium-1" and r.get("firstContentUnixNanos")]
        print("%s\t%d\t%d\t%d\t%.0f\t%d\t%.1f\t%d\t%d\t%d" % (arm, b, len(c), held, wait, peak, two, len(p),
                                                             sum(x > 600 for x in p), sum(x > 1000 for x in p)))
