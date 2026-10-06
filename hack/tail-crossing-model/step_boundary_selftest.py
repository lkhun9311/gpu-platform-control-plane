"""Self-tests of step_boundary.py's pure parts; each case names the mutation that turns it red.

Not covered here: gate_archive and the end-to-end evaluate() on a whole archive, which need a step-boundary archive
this repository does not yet have. gate_archive is built from instrument_gates functions that have their own tests.
"""

import math
import random

import step_boundary as sb
from iterlog import Refusal


def _serial_cell(scale, rng, noise=0.002):
    reqs = []
    for i, (L, cap) in enumerate((L, c) for L in (256, 2048, 8192) for c in (1, 16, 64) for _ in range(6)):
        ttft = (20 + L * 0.03) * scale * (1 + rng.gauss(0, noise))
        out = cap
        first = 1000.0 * i + ttft
        end = first + (out - 1) * 15.0 * scale * (1 + rng.gauss(0, noise))
        reqs.append(dict(index=i, offset=1000 * i, cap=cap, input_tokens=L, output_tokens=out, ttft_ms=ttft,
                         send_ms=1000.0 * i, first_ms=first, end_ms=end))
    return reqs


def _burst_cell(scale, rng, noise=0.002):
    reqs, i = [], 0
    for e, (n, L) in enumerate((n, L) for n in (1, 4, 16) for L in (256, 2048) for _ in range(3)):
        for r in range(n):
            ttft = (30 + L * 0.03 * (r + 1)) * scale * (1 + rng.gauss(0, noise))
            first = 10000.0 * e + ttft
            reqs.append(dict(index=i, offset=10000 * e, cap=64, input_tokens=L, output_tokens=64, ttft_ms=ttft,
                             send_ms=10000.0 * e, first_ms=first, end_ms=first + 63 * 15.0 * scale))
            i += 1
    return reqs


def _cells(step_scale_by_block):
    rng = random.Random(7)
    cells = {}
    for b in sb.ODD:
        cells[("serial-log", b)] = _serial_cell(1.0, rng)
        cells[("serial-step", b)] = _serial_cell(step_scale_by_block(b), rng)
    for b in range(1, 7):
        cells[("burst-log", b)] = _burst_cell(1.0, rng)
        cells[("burst-step", b)] = _burst_cell(step_scale_by_block(b), rng)
    return cells


def run():
    # Mutation that turns this red: compare the bounds in the wrong direction, or drop the interval.
    ok, lines, failures = sb.gate_overhead(_cells(lambda b: 1.0))
    assert ok, failures
    print("ok: an instrument with no overhead passes the paired gate --", lines[0])
    ok, _, failures = sb.gate_overhead(_cells(lambda b: 1.08))
    assert not ok and failures, "an 8% overhead passed"
    print(f"ok: an 8% overhead fails it -- {failures[0]}")
    # Block effects that cancel in the mean but not in the interval: +6% and -6% in alternate blocks of each type.
    # (+/-3% would rightly pass at six burst blocks: the half-width is about 0.034 against a bound of 0.049.)
    alt = {1: 1.06, 3: 0.94, 5: 1.06, 2: 0.94, 4: 1.06, 6: 0.94}
    ok, _, failures = sb.gate_overhead(_cells(lambda b: alt[b]))
    assert not ok and failures, "alternating +/-6% block effects passed, so the interval does not carry block variance"
    print(f"ok: alternating +/-6% blocks fail it on width -- {failures[0]}")

    m, lo, hi = sb.paired_interval([0.01, 0.02, 0.03])
    assert abs(m - 0.02) < 1e-12 and abs((hi - m) - 4.302652729749464 * 0.01 / math.sqrt(3)) < 1e-12, (m, lo, hi)
    print("ok: the paired interval is mean +/- t(0.975, n-1) * sd / sqrt(n)")

    # Step features straight from the instrument's counts.
    adds = {"a": {"prompt": 300}, "d": {"prompt": 100}}
    sched = [{"step": 1, "t0": 0, "tokens": {"a": 256, "d": 1}, "computed": {"a": 0, "d": 120}},
             {"step": 2, "t0": 10_000_000, "tokens": {"a": 44, "d": 1}, "computed": {"a": 256, "d": 121}}]
    done = {1: {"t3": 9_000_000}, 2: {"t3": 19_500_000}}
    st = sb.step_features(sched, done, adds, late={"a"})
    assert (st[0]["P"], st[0]["n"], st[0]["K"], st[0]["H"], st[0]["late"]) == (256, 1, 121, 0, True), st[0]
    assert (st[1]["P"], st[1]["H"], round(st[1]["occ"], 3)) == (44, 44 * 256, 9.5), st[1]
    print("ok: step features come from the instrument's computed counts: P, n, K = c + 1, H = p * C, occupancy t0..t3")

    # Q1 compares the mean wait beyond the idle baseline with half the pilot's gap, per setting.
    eps = [dict(setting=s, ms={"P-A": 2.0 + half * 2, "A-F": 0.5}) for s, half in sb.Q1_HALF_GAP_MS.items()]
    held, lines = sb.q1(eps, {256: 2.0}, {s: 256 for s in sb.Q1_HALF_GAP_MS})
    assert held, lines
    eps2 = [dict(setting=s, ms={"P-A": 2.0 + half * 0.5, "A-F": 0.1}) for s, half in sb.Q1_HALF_GAP_MS.items()]
    held, lines = sb.q1(eps2, {256: 2.0}, {s: 256 for s in sb.Q1_HALF_GAP_MS})
    assert not held and all("does not hold" in l for l in lines), lines
    print("ok: Q1 holds when the wait is twice the half-gap and not when it is a quarter of the gap")
    try:
        sb.q1(eps[:-1], {256: 2.0}, {s: 256 for s in sb.Q1_HALF_GAP_MS})
        raise AssertionError("Q1 accepted a setting with no late prefill")
    except Refusal as e:
        print(f"ok: Q1 refuses a setting with no late prefill -- {e}")

    # The thirds rule: three serial blocks hold out each third once, six burst blocks each twice.
    assert [sb.heldout_third(None, j) for j in range(3)] == [0, 1, 2]
    assert sorted(sb.heldout_third(None, j) for j in range(6)) == [0, 0, 1, 1, 2, 2]
    print("ok: each third of a setting's cycles is held out once in three blocks and twice in six")

    # The split itself: one fixed order per setting, so over six burst cells of three cycles each cycle position is
    # held out exactly twice, and over three serial cells of six cycles each position exactly once.
    # Mutation that turns this red: draw the order per cell instead of once per setting.
    for setting, cells, n, times in ((("burst", 4, 256, 64), 6, 3, 2), (("serial", 2048, 16), 3, 6, 1)):
        train = {setting: [(j, dict(setting=setting, cycle=c, steps=[])) for j in range(cells) for c in range(1, n + 1)]}
        _, ho = sb.split_heldout(train)
        held = {}
        for e in ho[setting]:
            held[e["cycle"]] = held.get(e["cycle"], 0) + 1
        assert held == {c: times for c in range(1, n + 1)}, (setting, held)
    print("ok: every cycle position is held out exactly twice in six burst cells and once in three serial cells")
    run_with_harness()


def run_with_harness():
    """The registered-seed check against real gen-trace output; needs BENCHHARNESS, and refuses rather than skips."""
    import os, shutil, subprocess, tempfile
    harness = os.environ.get("BENCHHARNESS")
    if not harness:
        raise AssertionError("BENCHHARNESS is unset: the seed check's test needs a built benchharness and does not skip")
    lib = os.path.join(sb.instrument_gates.REPO, "hack", "lib", "instrument-validation.sh")
    with tempfile.TemporaryDirectory() as run:
        def gen(arm, b, warm, seed):
            fn = "iv_warmup_duration_ms" if warm else "iv_duration_ms"
            dur = subprocess.run(["bash", "-c", f'source "$0"; {fn} "$1" "$2"', lib, sb.STUDY, arm],
                                 capture_output=True, text=True, check=True).stdout.strip()
            out = os.path.join(run, f"{'warmup-trace' if warm else 'trace'}-{arm}-{b}.jsonl")
            subprocess.run([harness, "gen-trace"] + (["--warmup"] if warm else []) + ["--seed", str(seed), "--duration-ms", dur,
                            "--study", sb.STUDY, "--arm", arm, "--model", "m", "--gateway-url", "http://x", "--timeout-ms", "1",
                            "--trace-out", out, "--manifest-out", out + ".yaml"], capture_output=True, check=True)
        for arm, b in sb.CELLS:
            gen(arm, b, False, sb.REGISTERED_SEED)
            gen(arm, b, True, sb.REGISTERED_SEED)
        line = sb.check_registered_seed(run, harness)
        print(f"ok: traces generated at the registered seed pass -- {line}")
        # Mutation that turns this red: regenerate from the manifest's seed instead of the registered one.
        gen("burst-step", 4, False, sb.REGISTERED_SEED + 1)
        try:
            sb.check_registered_seed(run, harness)
            raise AssertionError("a trace from another seed passed")
        except Refusal as e:
            assert "trace-burst-step-4.jsonl is not what seed" in str(e), e
            print(f"ok: a trace from another seed is refused -- {e}")
    # Q3's refusal is its verdict and does not erase the rest.
    def refusing(run):
        raise Refusal("the column-normalised design has condition number 412.0")
    lines = sb.q3_verdict("unused", fit=refusing)
    assert lines == ["Q3: REFUSED -- the column-normalised design has condition number 412.0"], lines
    print("ok: a Q3 refusal becomes Q3's verdict line instead of ending the evaluation")


if __name__ == "__main__":
    run()
