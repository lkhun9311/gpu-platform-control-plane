"""Stage 2: the operator model with separate fixed costs for graph-run and eager mixed steps, as registered.

docs/superpowers/specs/2026-10-07-graph-and-eager-mixed-steps.md.

    python3 step_family_operator2.py ARCHIVE/m5c-run COMPOSITIONS.json KERNEL_TIMES.json
    python3 step_family_operator2.py --self-test

step_family_operator.py is frozen with its result; this file adds two candidates to its table and runs them through
its own evaluate_candidate, so the test, the loss, the folds and the measured attention are exactly O1's.
"""

import json
import random
import sys

import step_family_operator as op  # noqa: E402
from iterlog import Refusal  # noqa: E402

GRAPH_MAX_TOKENS = 128


def cols_s1():
    # O1's non-attention terms with its one mixed surcharge u split by graph eligibility.
    return [c for c in op.cols_nonattn() if c != "u"] + ["u_graph", "u_eager"]


def row_s1(st):
    base = op.row_nonattn(st)[:-1]  # drop u, which is the last column of O1's row
    mixed = st["P"] > 0 and st["n"] > 0
    eager = st["P"] + st["n"] > GRAPH_MAX_TOKENS
    return base + [1.0 if mixed and not eager else 0.0, 1.0 if mixed and eager else 0.0]


def cols_s2():
    return cols_s1() + ["e_prefill"]


def row_s2(st):
    eager_prefill = st["P"] > 0 and st["n"] == 0 and st["P"] > GRAPH_MAX_TOKENS
    return row_s1(st) + [1.0 if eager_prefill else 0.0]


STAGE2 = {"S1": (cols_s1, row_s1, True), "S2": (cols_s2, row_s2, True)}
op.CANDIDATES.update(STAGE2)


def evaluate(run, compositions, kernel):
    steps = op.load(run, compositions, kernel)
    lines = [f"{len(steps)} measured steps; attention measured, coefficient 1; the archive's fifth development use"]
    passing = []
    for i, name in enumerate(STAGE2):
        passed, more, size, _ = op.evaluate_candidate(name, steps)
        lines += more
        if passed:
            passing.append((size, i, name))
    if not passing:
        lines.append("SELECTED: none -- no stage-2 candidate passes")
        return None, lines
    name = min(passing)[2]
    lines.append(f"SELECTED: {name}, to be frozen; a confirmation on fresh cells needs its own registration and the owner's approval")
    return name, lines


def self_test():
    assert op.row_nonattn(dict(P=256, n=1))[-1] == 1.0 and op.cols_nonattn()[-1] == "u", "u is not O1's last column"
    rng = random.Random(9)

    def nonattn(st):
        T = st["P"] + st["n"]
        mixed = st["P"] > 0 and st["n"] > 0
        return 12 + 0.1 * st["P"] + 0.3 * st["n"] + (0.5 if mixed and T <= 128 else 8.0 if mixed else 0.0)
    steps = []
    for b in (1, 3, 5):
        for n in (1, 4, 16):
            for q in (4, 16, 64, 256, 1024):
                s = ("stagger", n, 8192, q)
                for _ in range(12):
                    for st in (dict(P=q, n=n, K=n * 8192, H=0, late=True, attn=2.0 * n),
                               dict(P=0, n=n, K=n * 8192, H=0, late=False, attn=0.3 * n)):
                        steps.append((s, b, dict(st, occ=(nonattn(st) + st["attn"]) * (1 + rng.gauss(0, 0.004)))))
        for P in (64, 200, 300, 600, 1500, 2000):
            for _ in range(12):
                st = dict(P=P, n=0, K=0, H=0, late=False, attn=0.002 * P)
                steps.append((("serial", P, 16), b, dict(st, occ=(nonattn(st) + st["attn"]) * (1 + rng.gauss(0, 0.004)))))
    p1, l1, _, _ = op.evaluate_candidate("O1", steps)
    ps, ls, _, model = op.evaluate_candidate("S1", steps)
    assert not p1, "\n".join(l1)
    assert ps and model["u_eager"] > model["u_graph"], "\n".join(ls)
    print(f"ok: two fixed costs fail O1's single u and pass S1 (u_graph {model['u_graph']:.2f}, u_eager {model['u_eager']:.2f})")


if __name__ == "__main__":
    try:
        if sys.argv[1:] == ["--self-test"]:
            self_test()
        elif len(sys.argv) == 4:
            selected, lines = evaluate(sys.argv[1], json.load(open(sys.argv[2])), json.load(open(sys.argv[3])))
            print("\n".join(lines))
            sys.exit(0 if selected else 3)
        else:
            sys.exit(__doc__)
    except Refusal as e:
        sys.exit(f"REFUSED: {e}")
