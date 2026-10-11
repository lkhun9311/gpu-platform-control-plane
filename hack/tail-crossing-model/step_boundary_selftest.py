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
    run_files()
    run_with_harness()


def _write(path, rows):
    import json
    with open(path, "w") as f:
        f.writelines(json.dumps(r) + "\n" for r in rows)


def run_files():
    """Cases that need an archive on disk but no harness: the overlap refusal and the engine-configuration check."""
    import json, os, tempfile, hashlib
    # Two burst episodes whose requests share a step: their occupancy belongs to neither, so the cell is refused.
    # Mutation that turns this red: drop the overlap check from episodes_of_cell.
    with tempfile.TemporaryDirectory() as run:
        trace, raw, adds = [], [], []
        for i, off in enumerate((0, 0, 10000, 10000)):
            trace.append(dict(index=i, offsetMs=off, tenant="premium-1", maxOutputTokens=2))
            rid = f"burst-step-1-measured-{i}"
            raw.append(dict(index=i, requestId=rid, study=sb.STUDY, engineInputTokens=4, engineOutputTokens=2,
                            sendUnixNanos=off * 10**6, firstTokenUnixNanos=off * 10**6 + 5 * 10**6,
                            endUnixNanos=off * 10**6 + 9 * 10**6))
            adds.append(dict(ev="add", id=f"chatcmpl-{rid}-abcd", mono=off * 10**6, anchor=[0, 0, 1], arrival_wall=0,
                             prompt=4, self=1))
        ids = [a["id"] for a in adds]
        recs = adds + [dict(ev="sched", step=1, t0=1, t1=2, anchor=[0, 0, 1], tokens={ids[0]: 4, ids[1]: 4, ids[2]: 4},
                            computed={ids[0]: 0, ids[1]: 0, ids[2]: 0}, self=1),
                       dict(ev="done", step=1, t2=3, t3=4, self=1)]
        _write(os.path.join(run, "trace-burst-step-1.jsonl"), trace)
        _write(os.path.join(run, "raw-burst-step-1.jsonl"), raw)
        _write(os.path.join(run, "step-log-burst-step-1.jsonl"), recs)
        try:
            sb.episodes_of_cell(run, "burst-step", 1, "burst")
            raise AssertionError("a step shared by two episodes was accepted")
        except Refusal as e:
            assert "more than one measured episode" in str(e), e
            print(f"ok: a step shared by two episodes refuses the cell -- {e}")
    # A wall clock that steps inside a cell: one offset would misplace its stamps, so the cell is refused.
    # Mutation that turns this red: compute the spread and return it without the bound.
    with tempfile.TemporaryDirectory() as run:
        def log(step_ns):
            return [dict(ev="add", id="chatcmpl-x-abcd", mono=0, anchor=[0, 1000, 2], arrival_wall=0, prompt=4, self=1),
                    dict(ev="sched", step=1, t0=10, t1=11, anchor=[10, 1010 + step_ns, 12], tokens={"chatcmpl-x-abcd": 4},
                         computed={"chatcmpl-x-abcd": 0}, self=1),
                    dict(ev="done", step=1, t2=12, t3=13, self=1)]
        _write(os.path.join(run, "step-log-serial-step-1.jsonl"), log(sb.MAX_CLOCK_SPREAD_NS))
        print(f"ok: a spread at the bound passes -- {sb.step_records(run, 'serial-step', 1)[4]} ns")
        _write(os.path.join(run, "step-log-serial-step-1.jsonl"), log(sb.MAX_CLOCK_SPREAD_NS + 1))
        try:
            sb.step_records(run, "serial-step", 1)
            raise AssertionError("a wall clock that stepped inside the cell was accepted")
        except Refusal as e:
            assert "offset spread" in str(e), e
            print(f"ok: refuses a wall clock that stepped inside the cell -- {e}")
    # The registered engine configuration and the archived instrument hash, cell by cell.
    # Mutation that turns this red: check only the arguments check_provenance already reads.
    with tempfile.TemporaryDirectory() as run:
        sha = hashlib.sha256(open(sb.PLUGIN, "rb").read()).hexdigest()
        def lay(args_for, sha_for):
            timings, applied = ["cell\tarm\trep"], ["cell\tarm\tdeploy\tstage\tsource\tvalue"]
            for i, (arm, b) in enumerate(sb.CELLS, 1):
                timings.append(f"{i}\t{arm}\t{b}")
                applied.append(f"{i}\t{arm}\tvllm-qwen25-3b\tapplied\tdeploy\t{json.dumps(args_for(arm, b))}")
                if arm.endswith("-step"):
                    open(os.path.join(run, f"step-plugin-{arm}-{b}.sha256"), "w").write(f"{sha_for(arm, b)}  plugin\n")
            open(os.path.join(run, "cell-timings.tsv"), "w").write("\n".join(timings) + "\n")
            open(os.path.join(run, "applied-values.tsv"), "w").write("\n".join(applied) + "\n")
        rev = sb.instrument_gates.go_const("InputLengthTokenizerRevision")
        good = lambda arm, b: (list(sb.REGISTERED_ARGS) + ["--no-async-scheduling", "--enable-logging-iteration-details"]
                               + ([f"--scheduler-cls={sb.STEP_CLASS}"] if arm.endswith("-step") else [])
                               + [f"--revision={rev}", f"--tokenizer-revision={rev}"])
        lay(good, lambda arm, b: sha)
        print(f"ok: the registered configuration passes -- {sb.check_registered_engine(run)}")
        for what, args_for, sha_for, words in [
                ("a 512-token budget", lambda arm, b: [a.replace("=2048", "=512") for a in good(arm, b)], lambda a, b: sha,
                 "max-num-batched-tokens as ['512']"),
                ("prefix caching enabled", lambda arm, b: good(arm, b) + ["--enable-prefix-caching"], lambda a, b: sha,
                 "which the registration does not"),
                ("another instrument", good, lambda arm, b: "0" * 64 if (arm, b) == ("stagger-step", 3) else sha,
                 "not this tree's"),
                ("a budget overridden in space form", lambda arm, b: good(arm, b) + ["--max-num-batched-tokens", "512"],
                 lambda a, b: sha, "max-num-batched-tokens"),
                ("a dtype overridden later", lambda arm, b: good(arm, b) + ["--dtype=bfloat16"], lambda a, b: sha, "dtype"),
                ("async scheduling appended", lambda arm, b: good(arm, b) + ["--async-scheduling"], lambda a, b: sha,
                 "--async-scheduling"),
                ("another revision appended", lambda arm, b: good(arm, b) + ["--revision=0123abc"], lambda a, b: sha,
                 "revision as"),
                ("a logged control given the instrument in space form",
                 lambda arm, b: good(arm, b) + (["--scheduler-cls", sb.STEP_CLASS] if arm == "burst-log" else []),
                 lambda a, b: sha, "logged control ran with a scheduler class")]:
            lay(args_for, sha_for)
            try:
                sb.check_registered_engine(run)
                raise AssertionError(f"{what} was accepted")
            except Refusal as e:
                assert words in str(e), (what, e)
                print(f"ok: refuses {what} -- {str(e)[:110]}")


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
    # The exit status carries Q3: the session's own analysis exited 0 with Q3 FAIL before this.
    # Mutation that turns this red: return 0 whenever the gates pass.
    pre = ["Q3: condition 13.7, 37 training settings, 49 held-out or staggered settings, 13 phase(s) outside 10%"]
    for gates_ok, last, want in ((False, "Q3: PASS", 1), (True, "Q3: PASS", 0), (True, "Q3: FAIL", 3),
                                 (True, "Q3: REFUSED -- condition 412.0", 3)):
        got = sb.exit_status(gates_ok, pre + [last])
        assert got == want, (gates_ok, last, got)
    try:
        sb.exit_status(True, pre)
        raise AssertionError("an evaluation with no Q3 verdict line got a status")
    except Refusal as e:
        assert "0 Q3 verdict lines" in str(e), e
    print("ok: the exit status is 0 only with the gates and Q3 passing, 3 for a Q3 that did not, 1 for a failed gate")


if __name__ == "__main__":
    run()
