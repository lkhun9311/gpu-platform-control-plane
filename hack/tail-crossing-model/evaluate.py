"""Apply the registered tests P1-P3 to stages 2 and 3, from the raw rows.

Run: python3 hack/tail-crossing-model/evaluate.py <stage-2 m5c-run> <stage-3 m5c-run> <S_B seconds>

The percentiles are computed here from the rows, independently of `benchharness report`, with the same
convention (nearest rank, every trace of an arm pooled, completed latency-critical requests only), so the
two can be held against each other. The tests are the ones the model-first registration's amendments fixed
before either stage was bought:

  P1  the short level's p99 multiple exceeds the long level's at every BE level (a manipulation check)
  P2  short level: pooled p95 within 10% of isolated at or below lambda*/2, and at least S_B/4 above it at
      or above 2 lambda*, with lambda* = 0.05 / S_B
  P3  the mean over the window's BE levels of (short added p99 - long added p99) is positive, with the
      window 2 lambda*99 .. 10 lambda*99 and lambda*99 = 0.01 / S_B
"""
import glob
import json
import math
import os
import re
import sys

RAW = re.compile(r"raw-(.+)-(\d+)\.jsonl$")


def nearest_rank(xs, q):
    xs = sorted(xs)
    return xs[max(0, math.ceil(q * len(xs)) - 1)]


def load(run_dir):
    """arm -> {rep: [LC TTFT ms]}, per-arm excluded counts, per-(arm, rep) offered/completed, and LC schedules.

    OFFERED comes from the TRACE, not from the raw rows. Counting raw rows let a recording that lost rows
    shrink its own denominator, so two deleted latency-critical rows passed as a complete cell -- found by an
    independent review. Each raw row is joined to its trace row by index, and a raw row whose scheduled offset
    disagrees with the trace means the file is not that trace's replay.
    """
    arms, excluded, per_trace, sched = {}, {}, {}, {}
    for path in glob.glob(os.path.join(run_dir, "raw-*.jsonl")):
        m = RAW.search(os.path.basename(path))
        arm, rep = m.group(1), int(m.group(2))
        trace_path = os.path.join(run_dir, f"trace-{arm}-{rep}.jsonl")
        if not os.path.exists(trace_path):
            sys.exit(f"NOT TESTED: {os.path.basename(path)} has no trace-{arm}-{rep}.jsonl to be checked against")
        with open(trace_path) as f:
            lc = {r["index"]: r["offsetMs"] for r in map(json.loads, f) if r["tenant"] == "premium-1"}
        got = {}
        with open(path) as f:
            for line in f:
                r = json.loads(line)
                if r.get("tenant") != "premium-1":
                    continue
                if r["index"] not in lc or r.get("scheduledOffsetMs") != lc[r["index"]]:
                    sys.exit(f"NOT TESTED: {os.path.basename(path)} row {r['index']} is not its trace's latency-critical request at that offset")
                got[r["index"]] = r
        ttft = []
        for idx in lc:
            r = got.get(idx)
            if r is None or r.get("errorKind") or not r.get("firstTokenUnixNanos") or r.get("httpStatus") != 200:
                excluded[arm] = excluded.get(arm, 0) + 1
                continue
            ttft.append((r["firstTokenUnixNanos"] - r["sendUnixNanos"]) / 1e6)
        arms.setdefault(arm, {})[rep] = ttft
        per_trace[arm, rep] = (len(lc), len(ttft))
        sched[arm, rep] = sorted(lc.values())
    return arms, excluded, per_trace, sched


def refusal(name, per_trace):
    """Why this stage's tails may not be tested, or "" -- the conditions the report's readings apply.

    A test applied to the survivors of a censored tail is a test of a selected population, so the same two
    refusals the report holds (`tailCrossingRefusal`) are held here, per trace: any excluded latency-critical
    request at or above 1% of a trace, and fewer than 100 completions in a trace. An independent review
    found this script issuing verdicts without either.
    """
    for (arm, rep), (offered, done) in sorted(per_trace.items()):
        if offered and (offered - done) / offered >= 0.01:
            return f"{name}: {arm} repetition {rep} lost {offered - done} of {offered} latency-critical requests, so its tail is censored"
        if done < 100:
            return f"{name}: {arm} repetition {rep} completed {done} latency-critical requests, below the 100 a nearest-rank p99 needs"
    return ""


def schedules(run_dir):
    """rep -> the latency-critical scheduled offsets of that repetition's baseline trace."""
    out = {}
    for path in glob.glob(os.path.join(run_dir, "trace-R1-*.jsonl")):
        rep = int(re.search(r"-(\d+)\.jsonl$", path).group(1))
        with open(path) as f:
            out[rep] = sorted(json.loads(l)["offsetMs"] for l in f if json.loads(l)["tenant"] == "premium-1")
    return out


def seeds(run_dir):
    with open(os.path.join(run_dir, "load-source.txt")) as f:
        m = re.search(r"^seeds: (.+)$", f.read(), re.M)
    return m.group(1).split() if m else None


def rate_of(run_dir):
    """BE rate per level label, read back from the archive's own load record."""
    with open(os.path.join(run_dir, "load-source.txt")) as f:
        text = f.read()
    m = re.search(r"sweep: best-effort (.+?) /s", text)
    rates = m.group(1).split()
    return {f"be{i + 1:02d}-shared": float(r) for i, r in enumerate(rates)}


def pooled(arms, arm, q):
    vals = [x for rep in sorted(arms[arm]) for x in arms[arm][rep]]
    return nearest_rank(vals, q), len(vals)


def main(short_dir, long_dir, s_b):
    lam95, lam99 = 0.05 / s_b, 0.01 / s_b
    short, ex_s, pt_s, sc_s = load(short_dir)
    long_, ex_l, pt_l, sc_l = load(long_dir)
    # Every arm of a repetition must offer that repetition's baseline schedule, in both stages: the pairing
    # was checked on the baselines only, so a contended cell replayed from another schedule passed.
    for name, sc in (("short", sc_s), ("long", sc_l)):
        for (arm, rep), offsets in sorted(sc.items()):
            if offsets != sc.get(("R1", rep)):
                sys.exit(f"NOT TESTED: {name} {arm} repetition {rep} offered a different latency-critical schedule from its baseline")
    for why in (refusal("short", pt_s), refusal("long", pt_l)):
        if why:
            sys.exit(f"NOT TESTED: {why}")
    # The interaction is a comparison ACROSS the two stages, so the stages must be the same draws: the same
    # seeds recorded, the same repetitions, and -- what the seeds are for -- the same latency-critical
    # schedule in each repetition's baseline. Matching repetition numbers alone can be different seeds.
    if seeds(short_dir) != seeds(long_dir):
        sys.exit(f"NOT TESTED: the stages recorded seeds {seeds(short_dir)} and {seeds(long_dir)}")
    sch_s, sch_l = schedules(short_dir), schedules(long_dir)
    if sorted(sch_s) != sorted(sch_l) or any(sch_s[r] != sch_l[r] for r in sch_s):
        sys.exit("NOT TESTED: the two stages' baselines offered different latency-critical schedules, so they are not paired draws")
    # And the schedules checked must be the repetitions POOLED. Trace files alone said 1, 2 and 3 while one
    # stage's third raw files were gone -- an independent review pooled 469 requests against 322 and this
    # script certified them paired. Every arm of both stages must hold exactly the validated repetitions.
    for name, arms in (("short", short), ("long", long_)):
        for arm, reps in sorted(arms.items()):
            if sorted(reps) != sorted(sch_s):
                sys.exit(f"NOT TESTED: {name} {arm} pooled repetitions {sorted(reps)}, not the paired {sorted(sch_s)}")
    rates = rate_of(short_dir)
    if rates != rate_of(long_dir):
        sys.exit("the two stages swept different BE rates; the interaction is not defined")
    for name, arms in (("short", short), ("long", long_)):
        reps = {a: sorted(r) for a, r in arms.items()}
        if len({tuple(v) for v in reps.values()}) != 1:
            sys.exit(f"{name}: arms hold different repetitions {reps}; the pooled comparison is not paired")
    print(f"S_B {s_b:.4f} s  lambda*95 {lam95:.4f}  lambda*99 {lam99:.4f}  P3 window {2 * lam99:.4f}..{10 * lam99:.4f} req/s")
    print(f"excluded LC rows (error, no first token, or non-200): short {ex_s or 'none'}, long {ex_l or 'none'}")
    print(f"paired across stages: seeds {seeds(short_dir)}, repetitions {sorted(sch_s)}, identical baseline schedules;"
          f" smallest trace completed {min(d for _, d in list(pt_s.values()) + list(pt_l.values()))} requests")
    b = {}
    for name, arms in (("short", short), ("long", long_)):
        for q in (.95, .99):
            b[name, q] = pooled(arms, "R1", q)
    print(f"isolated  short p95 {b['short', .95][0]:.1f} p99 {b['short', .99][0]:.1f} (n={b['short', .99][1]})"
          f"   long p95 {b['long', .95][0]:.1f} p99 {b['long', .99][0]:.1f} (n={b['long', .99][1]})")
    print("BE req/s  | short p95  +ms   x    | short p99  +ms   x    | long p99  +ms   x    | short-long added p99")
    rows = []
    for arm, rate in sorted(rates.items(), key=lambda kv: kv[1]):
        s95, _ = pooled(short, arm, .95)
        s99, _ = pooled(short, arm, .99)
        l99, _ = pooled(long_, arm, .99)
        a95, a99s, a99l = s95 - b["short", .95][0], s99 - b["short", .99][0], l99 - b["long", .99][0]
        rows.append((rate, a95, a99s, a99l, s99 / b["short", .99][0], l99 / b["long", .99][0]))
        print(f"{rate:<9} | {s95:8.1f} {a95:+7.1f} {s95 / b['short', .95][0]:5.2f} | {s99:8.1f} {a99s:+7.1f} {s99 / b['short', .99][0]:5.2f}"
              f" | {l99:8.1f} {a99l:+7.1f} {l99 / b['long', .99][0]:5.2f} | {a99s - a99l:+8.1f}")
    p1 = all(r[4] > r[5] for r in rows)
    # The grid was registered as lambda*/2, lambda*, 2 lambda*, 4 lambda* ROUNDED TO FOUR DECIMALS, before
    # any cell existed, and the registration named which point fills which role. Comparing the rounded rates
    # against the unrounded boundaries put 0.0241 just above lambda*/2 = 0.024092 and 0.0964 just above
    # 10 lambda*99 = 0.09637, so the first run of this script reported "no level" for P2's low side and a
    # two-point P3 window. The tolerance is the rounding's own half-unit, and no wider.
    tol = 0.5e-4
    low = [r for r in rows if r[0] <= lam95 / 2 + tol]
    high = [r for r in rows if r[0] >= 2 * lam95 - tol]
    p2_low = all(r[1] <= 0.10 * b["short", .95][0] for r in low) if low else None
    p2_high = all(r[1] >= s_b * 1000 / 4 for r in high) if high else None
    window = [r for r in rows if 2 * lam99 - tol <= r[0] <= 10 * lam99 + tol]
    p3_mean = sum(r[2] - r[3] for r in window) / len(window) if window else None
    print(f"P1 short multiple > long multiple at every level: {'holds' if p1 else 'FALSIFIED'}")
    base95 = b["short", .95][0]
    print(f"P2 low side at {[r[0] for r in low]}: rise {[f'{100 * r[1] / base95:.1f}%' for r in low]} against 10%:"
          f" {'holds' if p2_low else 'FALSIFIED' if p2_low is False else 'no level'}")
    print(f"P2 high side at {[r[0] for r in high]}: {'holds' if p2_high else 'FALSIFIED' if p2_high is False else 'no level'}")
    print(f"P3 window {[r[0] for r in window]}: mean(short added - long added) = "
          f"{'n/a' if p3_mean is None else f'{p3_mean:+.1f} ms'} -> "
          f"{'n/a' if p3_mean is None else 'holds' if p3_mean > 0 else 'FALSIFIED'}")


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2], float(sys.argv[3]))
