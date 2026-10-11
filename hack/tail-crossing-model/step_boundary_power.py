"""The step-boundary registration's planning power for its overhead gate, reproducible.

    python3 step_boundary_power.py hack/m5c-20261005-222736/m5c-run

The stand-in for each endpoint's block-to-block SD is session 5's paired logged/unlogged blocks, the nearest
measurement of a per-cell change on this engine; it is a different instrument, so the result plans and certifies
nothing. Endpoints are independent normal block effects at zero true effect; all 75 must pass together.
"""

import math
import random
import statistics
import sys

import instrument_gates as g
import step_boundary as sb

SIMS, SEED = 20000, 3


def main(run):
    sds = []
    for kind, fn in (("serial", sb.serial_endpoints), ("burst", sb.burst_endpoints)):
        per = {b: (fn(g.load_cell(run, f"{kind}-nolog", b)), fn(g.load_cell(run, f"{kind}-log", b))) for b in g.BLOCKS}
        for k in per[1][0]:
            sds.append((kind, statistics.stdev([math.log(per[b][1][k] / per[b][0][k]) for b in g.BLOCKS])))
    lo, hi = sb.BOUND
    rng, passed = random.Random(SEED), 0
    for _ in range(SIMS):
        ok = True
        for kind, sd in sds:
            n = 3 if kind == "serial" else 6
            m, a, b = sb.paired_interval([rng.gauss(0, sd) for _ in range(n)])
            if not (lo <= a and b <= hi):
                ok = False
                break
        passed += ok
    print(f"{len(sds)} endpoints; largest SD serial {max(s for k, s in sds if k == 'serial'):.7f}, "
          f"burst {max(s for k, s in sds if k == 'burst'):.7f}; joint pass at zero effect {passed}/{SIMS} = {passed / SIMS:.4f} "
          f"(seed {SEED})")


if __name__ == "__main__":
    main(sys.argv[1])
