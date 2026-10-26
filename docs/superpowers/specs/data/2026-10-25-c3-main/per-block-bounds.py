"""Each arm's premium TTFT p99 bounds per length and block, which the registration publishes beside the pooled ones
headroom-main reports ("Published whatever the verdict"); the verdict reads only the pooled ones.
Run from the repository root with the three blocks' archives in block order:
  python3 docs/superpowers/specs/data/2026-10-25-c3-main/per-block-bounds.py <block 1's m5c-run> <block 2's> <block 3's>
Each cell is read by the scorer's own score_cell and boxed by its own _box, so a figure here is the one it pools."""
import sys, json
sys.path.insert(0, "hack/prospective-pilot")
import pilot_report as pr

for b, d in enumerate(sys.argv[1:], start=1):
    seed = pr.MAIN_SEEDS[b]

    def prov(arm, rep, d=d, seed=seed):
        return pr.provenance(d, arm, rep, study=pr.MAIN_STUDY, seed=seed,
                             want=pr.MAIN_CHECKSUMS[seed]["R1" if arm == "R1" else arm.rsplit("-", 1)[1]])

    for c in pr.MAIN_CELLS:
        if c.startswith("R1"):
            continue
        reports, outcomes = {}, {}
        pr.score_cell(d, c, prov, lambda *a: None, [], reports, outcomes)
        if c not in reports:
            print(json.dumps({"block": b, "cell": c, "scored": False}), flush=True)
            continue
        sched_hi, arr_lo, sched_lo, arr_hi = pr._box([reports[c]])
        print(json.dumps({"block": b, "cell": c, "premium_p99_sched_hi_ms": sched_hi, "premium_p99_arr_lo_ms": arr_lo,
                          "premium_p99_sched_lo_ms": sched_lo, "premium_p99_arr_hi_ms": arr_hi}), flush=True)
