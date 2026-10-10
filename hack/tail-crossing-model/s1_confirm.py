"""The S1 confirmation's evaluator: prediction only, nothing fitted.

docs/superpowers/specs/2026-10-07-confirming-s1-on-unseen-settings-design.md, and the registration that freezes it.

    BENCHHARNESS=... python3 s1_confirm.py ARCHIVE/m5c-run COMPOSITIONS.json KERNEL_TIMES.json
    python3 s1_confirm.py --self-test

S1's coefficients are the literal below, printed by the stage-2 run at b57c104. Each step of the fresh cells is
predicted as those terms plus 36 x the measured attention for its composition, and judged against the bounds S1
passed: an endpoint fails beyond +-10% on its mean or 15% on its mean |step error|. A coverage the design requires
and the data lack is a refusal, not a skipped endpoint. The archive is gated first with the step-boundary
evaluator's own gates, pointed at this study's cells, seed and id.
"""

import hashlib
import json
import math
import os
import random
import statistics
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "attention-bench"))

import archive_compositions as ac  # noqa: E402
import step_boundary as sb  # noqa: E402
import step_family_dev as dev  # noqa: E402
import step_family_operator as op  # noqa: E402
import step_family_operator2 as op2  # noqa: E402
from iterlog import Refusal  # noqa: E402

STUDY = "step-confirm-2026-10-07"
SEED = 47
CELLS = sorted(ac.CONFIRM_CELLS)
# S1's all-data predictor, docs/superpowers/specs/2026-10-07-graph-and-eager-mixed-steps.md (stage 2, b57c104).
S1 = (("c", 15.4473), ("f[0-256]", 0.0786395), ("f[256-512]", 0.0897957), ("f[512-1024]", 0.0958142),
      ("f[1024-2048]", 0.0937947), ("d1", 0.111382), ("d2", 0.0), ("u_graph", 1.46159), ("u_eager", 7.28906))
LAYERS = 36
DEVICE, FA_VERSION = "NVIDIA A10G", 2
TOL, STEP_TOL, MIN_STEPS, MAX_UNJUDGED = 0.10, 0.15, 10, 0.10
# The coverage the design was built to test; each must be judged, or the confirmation cannot speak.
COVERAGE = (("graph-run mixed steps (T <= 128)", lambda st: st["P"] > 0 and st["n"] > 0 and st["P"] + st["n"] <= 128),
            ("eager mixed steps (T > 128)", lambda st: st["P"] > 0 and st["n"] > 0 and st["P"] + st["n"] > 128),
            ("mixed steps with several prefills", lambda st: st["P"] > 0 and st["n"] > 0 and st["prefills"] >= 2))


def predict(st):
    names = op2.cols_s1()
    if tuple(names) != tuple(n for n, _ in S1):
        raise Refusal(f"S1's columns are {names}, not the frozen {[n for n, _ in S1]}")
    return sum(c * x for (_, c), x in zip(S1, op2.row_s1(st))) + st["attn"]


def gates(run, harness):
    """The step-boundary evaluator's archive and instrument gates, on this study's cells, seed and id."""
    saved = sb.STUDY, sb.CELLS, sb.REGISTERED_SEED
    sb.STUDY, sb.CELLS, sb.REGISTERED_SEED = STUDY, CELLS, SEED
    try:
        study = __import__("instrument_gates").study_of(run)
        if study != STUDY:
            raise Refusal(f"the archive's rows carry study {study!r}, not {STUDY!r}")
        return sb.gate_archive(run, harness) + sb.gate_instrument(run)
    finally:
        sb.STUDY, sb.CELLS, sb.REGISTERED_SEED = saved


def bind_kernel(run, comp_path, kernel):
    """{composition: attention ms} after proving the times are a GPU's, by graph replay, for this archive's manifest."""
    fresh = {}
    for _, _, _, comp in ac.steps_with_compositions(run, CELLS):
        fresh[comp] = fresh.get(comp, 0) + 1
    return check_kernel(open(comp_path, "rb").read(), kernel, fresh)


def check_kernel(raw, kernel, fresh):
    """The binding itself, apart from reading an archive: raw is the manifest's bytes, fresh the archive's counts."""
    if kernel.get("compositions_sha256") != hashlib.sha256(raw).hexdigest():
        raise Refusal("the kernel times were taken for another composition manifest (sha256 differs)")
    manifest = json.loads(raw)
    listed = {(tuple(tuple(p) for p in c["prefills"]), tuple(c["decoders"])): c for c in manifest["compositions"]}
    if set(listed) != set(fresh) or any(listed[k]["steps"] != v for k, v in fresh.items()):
        raise Refusal("the composition manifest is not what this archive's steps hold")
    # The GPU and FlashAttention version S1's attention term was measured with, not merely some GPU (found by review:
    # an H100's FA3 times would have passed and changed every prediction).
    if kernel.get("grid") != "3" or kernel.get("device") != DEVICE or kernel.get("fa_version") != FA_VERSION:
        raise Refusal(f"the kernel times are grid {kernel.get('grid')!r} on {kernel.get('device')!r} with FA "
                      f"{kernel.get('fa_version')!r}, not grid 3 on {DEVICE} with FA {FA_VERSION}")
    us = {}
    for r in kernel["rows"]:
        if r.get("timing") != "graph":
            raise Refusal(f"composition {r.get('id')} was not timed by graph replay")
        v = r.get("us_median")
        if not isinstance(v, (int, float)) or not math.isfinite(v) or v < 0:
            raise Refusal(f"composition {r.get('id')} has the time {v!r}")
        us[r["id"]] = v
    if set(us) != {c["id"] for c in manifest["compositions"]}:
        raise Refusal("the kernel times do not cover the manifest's compositions one to one")
    return {k: LAYERS * us[c["id"]] / 1000.0 for k, c in listed.items()}


def steps(run, attn):
    out = []
    for s, b, st, comp in ac.steps_with_compositions(run, CELLS):
        if st["occ"] <= 0 or not math.isfinite(st["occ"]):
            raise Refusal(f"a step of {s} has occupancy {st['occ']}")
        out.append((s, b, dict(st, attn=attn[comp], prefills=len(comp[0]))))
    return out


def endpoint(rows):
    """mean error, mean |step error| and per-block mean errors of (block, step, prediction) rows."""
    obs = statistics.fmean(st["occ"] for _, st, _ in rows)
    pred = statistics.fmean(p for _, _, p in rows)
    step = statistics.fmean(abs(p / st["occ"] - 1) for _, st, p in rows)
    blocks = {}
    for b in sorted({b for b, _, _ in rows}):
        mine = [(st, p) for bb, st, p in rows if bb == b]
        blocks[b] = statistics.fmean(p for _, p in mine) / statistics.fmean(st["occ"] for st, _ in mine) - 1
    return pred / obs - 1, step, blocks


def required_phases(setting):
    """The phases a setting must show, from its shape alone, so a phase with no step refuses rather than vanishes.

    A serial request with one output token never decodes; every other request does. A burst begins with a step of
    prefills alone. A staggered episode always has decoders running when its late prefill arrives.
    """
    kind = setting[0]
    if kind == "serial":
        return {"prefill-only"} | ({"decode"} if setting[2] > 1 else set())
    if kind == "burst":
        return {"prefill-only", "decode"}
    if kind == "stagger":
        return {"decode", "mixed", "late-prefill"}
    raise Refusal(f"setting {setting} is of no registered episode type")


def judge(rows, expected_settings):
    """rows: (setting, block, step, prediction). Returns (passed, lines); refuses when the test cannot speak."""
    observed = {(s, ph) for s, _, st, _ in rows for ph in dev.phases_judged(st)}
    missing = sorted({(s, ph) for s in expected_settings for ph in required_phases(s)} - observed, key=str)
    if missing:
        raise Refusal(f"{len(missing)} required endpoint(s) have no measured step, first {missing[0]} "
                      f"(found by review: a missing phase used to vanish rather than refuse)")
    lines, failures, judged, unjudged = [], [], 0, 0
    by = {}
    for s, b, st, p in rows:
        for ph in dev.phases_judged(st):
            by.setdefault((s, ph), []).append((b, st, p))
    for (s, ph), rs in sorted(by.items(), key=lambda kv: str(kv[0])):
        err, step, blocks = endpoint(rs)
        tag = ""
        if len(rs) < MIN_STEPS:
            unjudged += 1
            tag = "  (under the floor, not judged)"
        else:
            judged += 1
            if abs(err) > TOL or step > STEP_TOL:
                failures.append(f"{s} {ph}")
                tag = "  OUTSIDE"
        lines.append(f"  {s} {ph}: {len(rs)} steps, mean {err:+.1%}, |step| {step:.1%}, blocks "
                     + ", ".join(f"{b} {v:+.1%}" for b, v in blocks.items()) + tag)
    for name, keep in COVERAGE:
        rs = [(b, st, p) for _, b, st, p in rows if keep(st)]
        if len(rs) < MIN_STEPS:
            raise Refusal(f"the design's coverage '{name}' has {len(rs)} steps, under {MIN_STEPS}, so it cannot be judged")
        err, step, blocks = endpoint(rs)
        judged += 1
        bad = abs(err) > TOL or step > STEP_TOL
        if bad:
            failures.append(name)
        lines.append(f"  coverage {name}: {len(rs)} steps, mean {err:+.1%}, |step| {step:.1%}, blocks "
                     + ", ".join(f"{b} {v:+.1%}" for b, v in blocks.items()) + ("  OUTSIDE" if bad else ""))
    total = judged + unjudged
    if unjudged / total > MAX_UNJUDGED:
        raise Refusal(f"{unjudged} of {total} endpoints are under the {MIN_STEPS}-step floor, more than {MAX_UNJUDGED:.0%}")
    passed = not failures
    head = [f"S1 frozen at b57c104, nothing fitted: {judged} endpoints judged, {unjudged} under the floor, "
            f"{len(failures)} outside +-{TOL:.0%} on the mean or {STEP_TOL:.0%} on |step|"]
    return passed, head + lines + [f"CONFIRMATION: {'PASS' if passed else 'FAIL'}"]


def evaluate(run, harness, comp_path, kernel):
    lines = gates(run, harness)
    attn = bind_kernel(run, comp_path, kernel)
    st = steps(run, attn)
    expected = set()
    for arm, b in CELLS:
        kind = arm.split("-")[0]
        reqs = __import__("instrument_gates").load_cell(run, arm, b)
        # The settings the traces hold, keyed exactly as the steps' episodes are, so a setting with no step is seen.
        expected |= {setting for setting, _ in __import__("timing_fit").episodes_of(kind, reqs)}
    passed, more = judge([(s, b, x, predict(x)) for s, b, x in st], expected)
    return passed, lines + more


def self_test():
    rng = random.Random(3)

    def truth(st):
        return predict(st)
    rows, expected = [], set()
    for b in (1, 2, 3):
        for n, q in ((8, 120), (8, 1536), (15, 384), (5, 32)):
            s = ("stagger", n, 6144, q)
            expected.add(s)
            for _ in range(12):
                for st in (dict(P=q, n=n, K=n * 6144, H=0, late=True, attn=2.0 * n, prefills=1, occ=0.0),
                           dict(P=0, n=n, K=n * 6144, H=0, late=False, attn=0.3 * n, prefills=0, occ=0.0)):
                    st["occ"] = truth(st) * (1 + rng.gauss(0, 0.01))
                    rows.append((s, b, st, predict(st)))
            # A burst's first step of prefills alone, its several-prefill mixed steps, and its decode steps.
            for st in (dict(P=1536, n=0, K=0, H=0, late=False, attn=1.5, prefills=4, occ=0.0),
                       dict(P=64, n=8, K=8 * 384, H=0, late=False, attn=1.0, prefills=2, occ=0.0),
                       dict(P=0, n=8, K=8 * 400, H=0, late=False, attn=0.4, prefills=0, occ=0.0)):
                for _ in range(4):
                    st2 = dict(st, occ=truth(st) * (1 + rng.gauss(0, 0.01)))
                    rows.append((("burst", 8, 384, 64), b, st2, predict(st2)))
        expected.add(("burst", 8, 384, 64))
    passed, lines = judge(rows, expected)
    assert passed, "\n".join(lines)
    print("ok: steps that S1 predicts pass, with every coverage judged and per-block errors published")
    slow = [(s, b, dict(st, occ=st["occ"] * (1.2 if st["late"] else 1.0)), p) for s, b, st, p in rows]
    passed, lines = judge(slow, expected)
    assert not passed and any("OUTSIDE" in l for l in lines), "\n".join(lines)
    print("ok: late prefills 20% slower than S1 predicts fail the confirmation")
    try:
        # The burst setting holds every several-prefill step, so it leaves the expected set with them.
        judge([r for r in rows if r[0] != ("burst", 8, 384, 64)], expected - {("burst", 8, 384, 64)})
        raise AssertionError("a confirmation with no several-prefill step was judged")
    except Refusal as e:
        assert "several prefills" in str(e), e
        print(f"ok: a missing coverage refuses -- {e}")
    try:
        judge(rows, expected | {("stagger", 8, 6144, 121)})
        raise AssertionError("a registered setting with no step was judged")
    except Refusal as e:
        print(f"ok: a registered setting with no measured step refuses -- {e}")
    # A required phase with no step refuses: serial at cap 64 whose steps never decoded.
    serial = [(("serial", 512, 64), b, dict(P=512, n=0, K=0, H=0, late=False, attn=0.5, prefills=1, occ=0.0), 0.0)
              for b in (1, 2, 3) for _ in range(5)]
    serial = [(s, b, dict(st, occ=predict(st)), predict(st)) for s, b, st, _ in serial]
    try:
        judge(rows + serial, expected | {("serial", 512, 64)})
        raise AssertionError("a serial setting with no decode step was judged")
    except Refusal as e:
        assert "('serial', 512, 64), 'decode'" in str(e), e
        print(f"ok: a required phase with no step refuses -- {str(e)[:90]}")
    # The kernel binding: a good file passes, and each way a file can be wrong refuses.
    # Mutation that turns this red: drop any one check in check_kernel.
    # A -step-only archive names its study from its serial-step cell (found by review: serial-log was assumed).
    import tempfile
    import instrument_gates
    with tempfile.TemporaryDirectory() as d:
        open(os.path.join(d, "raw-serial-step-1.jsonl"), "w").write(json.dumps({"study": STUDY}) + "\n")
        assert instrument_gates.study_of(d) == STUDY
    print("ok: an archive with only -step cells is read as its study")
    comp = ((((120, 0),), (6160,) * 8), 3)
    raw = json.dumps({"compositions": [{"id": 0, "prefills": [[120, 0]], "decoders": [6160] * 8, "steps": 3}]}).encode()
    good = {"grid": "3", "fa_version": 2, "device": "NVIDIA A10G", "compositions_sha256": hashlib.sha256(raw).hexdigest(),
            "rows": [{"id": 0, "timing": "graph", "us_median": 400.0}]}
    fresh = {comp[0]: comp[1]}
    assert abs(check_kernel(raw, good, fresh)[comp[0]] - 14.4) < 1e-9
    for what, kernel, fr in (("another manifest", dict(good, compositions_sha256="0" * 64), fresh),
                             ("a manifest the archive does not hold", good, {comp[0]: 4}),
                             ("a NaN time", dict(good, rows=[{"id": 0, "timing": "graph", "us_median": float("nan")}]), fresh),
                             ("an eager time", dict(good, rows=[{"id": 0, "timing": "eager", "us_median": 1.0}]), fresh),
                             ("a stub", dict(good, fa_version="stub", device=None), fresh),
                             ("another GPU's FA3 times", dict(good, fa_version=3, device="NVIDIA H100 80GB HBM3"), fresh)):
        try:
            check_kernel(raw, kernel, fr)
            raise AssertionError(f"{what} was accepted")
        except Refusal as e:
            print(f"ok: the kernel binding refuses {what} -- {e}")
    assert tuple(op2.cols_s1()) == tuple(n for n, _ in S1)
    print("ok: S1's frozen literal names its columns in the evaluator's order")


if __name__ == "__main__":
    try:
        if sys.argv[1:] == ["--self-test"]:
            self_test()
        elif len(sys.argv) == 4:
            harness = os.environ.get("BENCHHARNESS")
            if not harness:
                raise Refusal("set BENCHHARNESS to a built cmd/benchharness: the archive is gated before any prediction")
            passed, lines = evaluate(sys.argv[1], harness, sys.argv[2], json.load(open(sys.argv[3])))
            print("\n".join(lines))
            sys.exit(0 if passed else 3)
        else:
            sys.exit(__doc__)
    except Refusal as e:
        sys.exit(f"REFUSED: {e}")
