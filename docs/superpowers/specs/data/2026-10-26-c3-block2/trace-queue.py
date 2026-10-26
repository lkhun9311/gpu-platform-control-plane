"""The queue a fixed spacing builds from a trace's contender arrivals alone, with no engine:
admission_i = max(arrival_i, admission_{i-1} + spacing).
Run from the repository root with the three blocks' archives in block order:
  python3 docs/superpowers/specs/data/2026-10-26-c3-block2/trace-queue.py <block 1's m5c-run> <block 2's> <block 3's>
If it reproduces the gateway's measured waits, the queue is the trace's property and not the card's."""
import json, sys

SPACING = 1680.4
SEEDS = {1: 882, 2: 892, 3: 893}
print("block\tseed\tcontenders\theld by the spacing\tlongest run of back-to-back admissions\tmax wait ms")
for b, d in enumerate(sys.argv[1:], start=1):
    arrivals = sorted(r["offsetMs"] for r in map(json.loads, open("%s/trace-fixedS-long-1.jsonl" % d)) if r.get("isNoisy"))
    waits, last = [], None
    for a in arrivals:
        x = a if last is None else max(a, last + SPACING)
        waits.append(x - a)
        last = x
    # A run counts its admissions, the one that starts it included: that one did not wait, the rest did
    # (astra's attack, 4: counting only the waits gave one fewer).
    longest = run = 0
    for w in waits:
        run = run + 1 if w > 0 else 1
        longest = max(longest, run)
    print("%d\t%d\t%d\t%d\t%d\t%.0f" % (b, SEEDS[b], len(arrivals), sum(w > 0 for w in waits), longest, max(waits)))
