"""Writes every distinct attention composition of the step-boundary archive's measured steps, for BENCH_GRID=3.

docs/superpowers/specs/2026-10-07-an-operator-model-with-measured-attention.md.

    python3 archive_compositions.py ARCHIVE/m5c-run > compositions.json

A composition is what the attention kernel sees in one step: each prefilling request's scheduled tokens q and
computed tokens c, and each decoder's context K. c and K are rounded up to the KV block (16 tokens), which is the
kernel's own granularity, so steps that differ only inside a block share a composition. The step population is
step_family_dev.load's.
"""

import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "tail-crossing-model"))

import step_boundary as sb  # noqa: E402
import step_family_dev as dev  # noqa: E402

BLOCK = 16


def up(x):
    return -(-x // BLOCK) * BLOCK


def composition(s, adds):
    """(((q, c), ...), (K, ...)) of one scheduled step, sorted, with c and K rounded up to the block."""
    pre = tuple(sorted((q, up(s["computed"][r])) for r, q in s["tokens"].items()
                       if s["computed"][r] < adds[r]["prompt"]))
    dec = tuple(sorted(up(s["computed"][r] + 1) for r in s["tokens"] if s["computed"][r] >= adds[r]["prompt"]))
    return pre, dec


def steps_with_compositions(run, cells=None):
    """(setting, block, step features, composition) for every measured step of cells, step_family_dev.load's by default."""
    out = []
    for arm, b in (cells or dev.CELLS):
        kind = arm.split("-")[0]
        adds, sched, _, _, _ = sb.step_records(run, arm, b)
        by_t0 = {s["t0"]: s for s in sched}
        for e in sb.episodes_of_cell(run, arm, b, kind):
            for st in e["steps"]:
                s = by_t0.get(round(st["t0_ms"] * 1e6))
                if s is None:
                    raise SystemExit(f"{arm}-{b}: a measured step's t0 matches no scheduled step")
                out.append((e["setting"], b, st, composition(s, adds)))
    return out


# The S1 confirmation's nine cells (docs/superpowers/specs/2026-10-07-confirming-s1-on-unseen-settings-design.md).
CONFIRM_CELLS = [(f"{k}-step", b) for k in ("serial", "burst", "stagger") for b in (1, 2, 3)]


def main():
    # --confirm reads the confirmation's cells; it prints compositions only, never an occupancy, so the manifest
    # can be fixed and timed before anyone sees how the steps went.
    confirm = "--confirm" in sys.argv[1:]
    args = [a for a in sys.argv[1:] if a != "--confirm"]
    rows = steps_with_compositions(args[0], CONFIRM_CELLS if confirm else None)
    counts = {}
    for _, _, _, comp in rows:
        counts[comp] = counts.get(comp, 0) + 1
    comps = [dict(id=i, prefills=[list(p) for p in comp[0]], decoders=list(comp[1]), steps=n)
             for i, (comp, n) in enumerate(sorted(counts.items(), key=lambda kv: str(kv[0])))]
    json.dump(dict(block=BLOCK, steps=len(rows), compositions=comps), sys.stdout)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
