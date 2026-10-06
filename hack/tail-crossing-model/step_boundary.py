"""The step-boundary session's evaluator, as registered.

docs/superpowers/specs/2026-10-06-where-the-late-prefill-waits-step-boundary-session.md.

    BENCHHARNESS=path/to/benchharness python3 step_boundary.py ARCHIVE/m5c-run
    python3 step_boundary.py --self-test

Gates run in order and each refuses: the archive (design, warm-ups, provenance, W, S, I2, every registered cell
present), the instrument (check_step_log on every -step cell), then the overhead equivalence on the serial and
burst pairs. After the gates, the late prefill's TTFT is decomposed from the instrument's stamps and the family
is fitted on measured occupancy. Q1 and Q3 are reported whatever the other says.
"""

import json
import math
import os
import random
import statistics
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "vllm-plugins"))

import check_step_log  # noqa: E402
import instrument_gates  # noqa: E402
import timing_fit  # noqa: E402
from iterlog import Refusal  # noqa: E402

STUDY = "step-boundary-2026-10-06"
# The registered cells: serial and staggered in blocks 1, 3 and 5, burst in all six (section 2).
ODD = (1, 3, 5)
CELLS = sorted([(f"serial-{m}", b) for m in ("log", "step") for b in ODD]
               + [(f"burst-{m}", b) for m in ("log", "step") for b in range(1, 7)]
               + [("stagger-step", b) for b in ODD])
BOUND = (math.log(0.95), math.log(1.05))
# Two-sided 95% t quantiles for the paired blocks: 3 serial pairs (df 2), 6 burst pairs (df 5).
T95 = {2: 4.302652729749464, 5: 2.570581835636314}
# Q1's reference, half the mean gap the logged-engine pilot left on each short-prefill setting under the context
# convention, re-derived from docs/superpowers/specs/data/2026-10-06-logged-engine-pilot.json before any cell.
Q1_HALF_GAP_MS = {(1, 256, 256): 9.873, (1, 8192, 256): 15.442, (4, 256, 256): 8.967,
                  (4, 8192, 256): 15.047, (16, 256, 256): 13.162, (16, 8192, 256): 28.532}
SEED = 20261005


# ---------------------------------------------------------------------------------------------------------------
# Gate 1: the archive


def gate_archive(run, harness):
    lines = []
    if instrument_gates.study_of(run) != STUDY:
        raise Refusal(f"{run} is study {instrument_gates.study_of(run)!r}, not {STUDY}")
    present = sorted((n[len("trace-"):].rsplit("-", 1)[0], int(n.rsplit("-", 1)[1][:-len(".jsonl")]))
                     for n in os.listdir(run) if n.startswith("trace-") and n.endswith(".jsonl"))
    if present != CELLS:
        missing = sorted(set(CELLS) - set(present))
        extra = sorted(set(present) - set(CELLS))
        raise Refusal(f"the archive's cells are not the registered 21: missing {missing[:3]}, extra {extra[:3]}; "
                      f"an incomplete session is a refusal")
    lines.append(instrument_gates.check_design(run, harness))
    lines.append(instrument_gates.check_warmup_design(run, harness))
    lines.append(check_registered_seed(run, harness))
    lines.append(instrument_gates.check_provenance(run, None, CELLS))
    for arm, b in CELLS:
        instrument_gates.check_warmup(run, arm, b)
        p = instrument_gates.preemptions(run, arm, b)
        if p:
            raise Refusal(f"{arm}-{b}: {p:g} preemption(s) (I2)")
        instrument_gates.measured_iters(run, arm, b, True)
        reqs = instrument_gates.load_cell(run, arm, b)
        if arm.startswith("serial-"):
            by_send = sorted(reqs, key=lambda q: q["send_ms"])
            for a, q in zip(by_send, by_send[1:]):
                if q["send_ms"] < a["end_ms"]:
                    raise Refusal(f"{arm}-{b}: request {q['index']} was sent before {a['index']} ended (I2)")
        if arm.startswith("stagger-"):
            instrument_gates.check_stagger(reqs, arm, b, fixed_length=True)
            instrument_gates.check_stagger(instrument_gates.warmup_stagger_episodes(run, arm, b, 3), f"{arm} warm-up", b,
                                           fixed_length=True)
    lines.append(f"W, S and I2: all {len(CELLS)} registered cells pass")
    return lines


REGISTERED_SEED = 31


def check_registered_seed(run, harness):
    """Every measured and warm-up trace is what gen-trace makes at the registered seed, byte for byte.

    The design check proves a trace is the registered matrix and the warm-up check regenerates from the seed its
    own manifest names; neither proves the seed is the registered one, so another seed's traces would have passed
    and pairs could have replayed different episodes (found by review).
    """
    import subprocess, tempfile
    lib = os.path.join(instrument_gates.REPO, "hack", "lib", "instrument-validation.sh")
    with tempfile.TemporaryDirectory() as tmp:
        for arm, b in CELLS:
            for warm, fn, prefix in ((False, "iv_duration_ms", "trace"), (True, "iv_warmup_duration_ms", "warmup-trace")):
                dur = subprocess.run(["bash", "-c", f'source "$0"; {fn} "$1" "$2"', lib, STUDY, arm],
                                     capture_output=True, text=True)
                if dur.returncode != 0:
                    raise Refusal(f"{arm}: no registered length: {dur.stdout.strip()} {dur.stderr.strip()}")
                out = os.path.join(tmp, f"{prefix}-{arm}-{b}.jsonl")
                cmd = [harness, "gen-trace"] + (["--warmup"] if warm else []) + [
                    "--seed", str(REGISTERED_SEED), "--duration-ms", dur.stdout.strip(), "--study", STUDY, "--arm", arm,
                    "--model", "Qwen/Qwen2.5-3B-Instruct", "--gateway-url", "http://127.0.0.1:18080", "--timeout-ms",
                    "60000", "--trace-out", out, "--manifest-out", out + ".yaml"]
                p = subprocess.run(cmd, capture_output=True, text=True)
                if p.returncode != 0:
                    raise Refusal(f"{arm}-{b}: gen-trace could not regenerate it: {(p.stderr or p.stdout).strip()[-300:]}")
                if open(out, "rb").read() != open(os.path.join(run, f"{prefix}-{arm}-{b}.jsonl"), "rb").read():
                    raise Refusal(f"{prefix}-{arm}-{b}.jsonl is not what seed {REGISTERED_SEED} generates")
    return f"Seed: all {2 * len(CELLS)} measured and warm-up traces are seed {REGISTERED_SEED}'s, byte for byte"


# ---------------------------------------------------------------------------------------------------------------
# Gate 2: the instrument


def raw_rows(run, arm, b):
    rows = []
    for name in (f"raw-warmup-{arm}-{b}.jsonl", f"raw-{arm}-{b}.jsonl"):
        rows += [json.loads(l) for l in open(os.path.join(run, name))]
    return rows


def gate_instrument(run):
    lines = []
    for arm, b in CELLS:
        if not arm.endswith("-step"):
            continue
        outputs = {}
        for r in raw_rows(run, arm, b):
            if not r.get("requestId"):
                raise Refusal(f"{arm}-{b}: row {r['index']} carries no request id, so it cannot join the instrument")
            outputs[r["requestId"]] = r["engineOutputTokens"]
        got = check_step_log.check(open(os.path.join(run, f"step-log-{arm}-{b}.jsonl")).read().splitlines(),
                                   open(os.path.join(run, f"engine-log-{arm}-{b}.txt")).read().splitlines(), outputs)
        lines.append(f"{arm}-{b}: " + "; ".join(got))
    return lines


# ---------------------------------------------------------------------------------------------------------------
# Gate 3: overhead, where it can be powered


def itl(q):
    return (q["end_ms"] - q["first_ms"]) / (q["output_tokens"] - 1) if q["output_tokens"] >= 2 else None


def serial_endpoints(reqs):
    """Each serial setting's median TTFT and median ITL, keyed (setting, quantity)."""
    by = {}
    for q in reqs:
        s = (q["input_tokens"], q["cap"])
        by.setdefault((s, "ttft"), []).append(q["ttft_ms"])
        v = itl(q)
        if v is not None:
            by.setdefault((s, "itl"), []).append(v)
    return {k: statistics.median(v) for k, v in by.items()}


def burst_endpoints(reqs):
    """Each burst episode type's mean over episodes of its mean TTFT, max TTFT and mean ITL."""
    eps = {}
    for q in reqs:
        eps.setdefault(q["offset"], []).append(q)
    by = {}
    for e in eps.values():
        s = (len(e), e[0]["input_tokens"], e[0]["cap"])
        by.setdefault((s, "mean-ttft"), []).append(statistics.fmean(q["ttft_ms"] for q in e))
        by.setdefault((s, "max-ttft"), []).append(max(q["ttft_ms"] for q in e))
        itls = [v for v in map(itl, e) if v is not None]
        if itls:
            by.setdefault((s, "mean-itl"), []).append(statistics.fmean(itls))
    return {k: statistics.fmean(v) for k, v in by.items()}


def paired_interval(diffs):
    """The paired-block mean of log(step / log) and its 95% t-interval."""
    n = len(diffs)
    m = statistics.fmean(diffs)
    h = T95[n - 1] * statistics.stdev(diffs) / math.sqrt(n)
    return m, m - h, m + h


def gate_overhead(cells):
    """cells maps (arm, block) to that cell's requests; every endpoint's interval must lie inside the bounds."""
    lines, failures = [], []
    for kind, blocks, endpoints in (("serial", ODD, serial_endpoints), ("burst", tuple(range(1, 7)), burst_endpoints)):
        per = {b: (endpoints(cells[(f"{kind}-log", b)]), endpoints(cells[(f"{kind}-step", b)])) for b in blocks}
        keys = set(per[blocks[0]][0])
        for b in blocks:
            if set(per[b][0]) != keys or set(per[b][1]) != keys:
                raise Refusal(f"{kind} block {b}: its endpoints are not the same set as block {blocks[0]}'s")
        worst = None
        for k in sorted(keys, key=str):
            m, lo, hi = paired_interval([math.log(per[b][1][k] / per[b][0][k]) for b in blocks])
            # Parenthesised: `not a <= lo and hi <= b` negates only the first comparison and passed an 8% overhead.
            if not (BOUND[0] <= lo and hi <= BOUND[1]):
                failures.append(f"{kind} {k}: mean {m:+.4f}, 95% [{lo:+.4f}, {hi:+.4f}]")
            if worst is None or max(abs(lo), abs(hi)) > worst[0]:
                worst = (max(abs(lo), abs(hi)), k, m, lo, hi)
        lines.append(f"overhead {kind}: {len(keys)} endpoints over {len(blocks)} pairs; widest {worst[1]} "
                     f"mean {worst[2]:+.4f}, 95% [{worst[3]:+.4f}, {worst[4]:+.4f}] (log ratio)")
    return not failures, lines, failures


# ---------------------------------------------------------------------------------------------------------------
# The instrument's records, per -step cell


def step_records(run, arm, b):
    recs = [json.loads(l) for l in open(os.path.join(run, f"step-log-{arm}-{b}.jsonl"))]
    adds = {r["id"]: r for r in recs if r["ev"] == "add"}
    sched = [r for r in recs if r["ev"] == "sched"]
    done = {r["step"]: r for r in recs if r["ev"] == "done"}
    # Monotonic to wall: each anchor's wall reading less the midpoint of its bracket; one cell, one host, one offset.
    offs = [r["anchor"][1] - (r["anchor"][0] + r["anchor"][2]) / 2 for r in list(adds.values()) + sched]
    offset = statistics.median(offs)
    spread = max(offs) - min(offs)
    return adds, sched, done, offset, spread


def engine_id(adds, rid):
    ids = [k for k in adds if k.startswith("chatcmpl-" + rid + "-")]
    if len(ids) != 1:
        raise Refusal(f"request {rid} matches {len(ids)} engine requests")
    return ids[0]


# ---------------------------------------------------------------------------------------------------------------
# Q1: where the late prefill's TTFT goes


def decompose(run, arm, b):
    """Per staggered late prefill: S->P, P->A, A->F, F->O and O->C in ms, from the client rows and the instrument."""
    adds, sched, done, offset, _ = step_records(run, arm, b)
    rows = {r["index"]: r for r in map(json.loads, open(os.path.join(run, f"raw-{arm}-{b}.jsonl")))}
    reqs = instrument_gates.load_cell(run, arm, b)
    keyed = instrument_gates.settings("stagger", reqs)
    out = []
    for s, q in keyed:
        if s[3] != "prefill":
            continue
        rid = engine_id(adds, rows[q["index"]]["requestId"])
        a = adds[rid]
        first = next((x for x in sched if rid in x["tokens"]), None)
        last = next((x for x in sched if rid in x["tokens"]
                     and x["computed"][rid] + x["tokens"][rid] >= a["prompt"]), None)
        if first is None or last is None:
            raise Refusal(f"{arm}-{b}: the late prefill {rid} has no step that schedules or completes its prompt")
        S = rows[q["index"]]["sendUnixNanos"]
        C = rows[q["index"]]["firstTokenUnixNanos"]
        P = a["arrival_wall"]
        A = a["mono"] + offset
        F = first["t0"] + offset
        O = done[last["step"]]["t3"] + offset
        if not S <= P <= A <= F <= O <= C:
            raise Refusal(f"{arm}-{b}: the late prefill {rid}'s stamps are out of order")
        out.append(dict(setting=s[:3], block=b, ms={k: v / 1e6 for k, v in
                        (("S-P", P - S), ("P-A", A - P), ("A-F", F - A), ("F-O", O - F), ("O-C", C - O))}))
    return out


def serial_baseline(run):
    """The median P->A of serial-step requests by prompt length: the frontend-to-scheduler time of an idle engine."""
    by = {}
    for b in ODD:
        adds, _, _, offset, _ = step_records(run, "serial-step", b)
        for r in map(json.loads, open(os.path.join(run, f"raw-serial-step-{b}.jsonl"))):
            a = adds[engine_id(adds, r["requestId"])]
            by.setdefault(r["engineInputTokens"], []).append((a["mono"] + offset - a["arrival_wall"]) / 1e6)
    return {k: statistics.median(v) for k, v in by.items()}


def gaps(run):
    """The time between one step's update exit and the next step's scheduling entry, which occupancy leaves out.

    Published, not gated (section 5): a simulator that advanced straight from one step to the next would omit it.
    Only gaps inside an episode count, where the engine had work waiting; an idle engine's wait for the next
    request is not a step gap.
    """
    lines = []
    for kind in ("serial", "burst", "stagger"):
        blocks = ODD if kind != "burst" else tuple(range(1, 7))
        g, per_block = [], {}
        for b in blocks:
            # The population, as registered: consecutive steps of one measured episode, by the episode's own
            # requests; warm-up steps belong to no measured episode and are not in it.
            for e in episodes_of_cell(run, f"{kind}-step", b, kind):
                for a, nxt in zip(e["steps"], e["steps"][1:]):
                    v = nxt["t0_ms"] - a["t3_ms"]
                    g.append(v)
                    per_block.setdefault(b, []).append(v)
        if g:
            g.sort()
            blocks_txt = ", ".join(f"block {b} {statistics.median(v):.3f}" for b, v in sorted(per_block.items()))
            lines.append(f"inter-step gap {kind}: median {statistics.median(g):.3f} ms, p95 {g[int(0.95 * (len(g) - 1))]:.3f} ms "
                         f"over {len(g)} gaps within measured episodes (block medians: {blocks_txt})")
    return lines


def q1(episodes, baseline, prompt_tokens):
    """For each short-prefill setting, whether the mean wait (P->A beyond the idle baseline, plus A->F) is at
    least half the pilot's mean gap. A prediction written before the data, reported, not a gate."""
    lines, held = [], True
    for s, half in sorted(Q1_HALF_GAP_MS.items()):
        eps = [e for e in episodes if e["setting"] == s]
        if not eps:
            raise Refusal(f"Q1: no late prefill of setting {s}")
        base = baseline.get(prompt_tokens[s])
        if base is None:
            raise Refusal(f"Q1: no serial baseline at {prompt_tokens[s]} prompt tokens")
        waits = {}
        for e in eps:
            waits.setdefault(e.get("block"), []).append(e["ms"]["P-A"] - base + e["ms"]["A-F"])
        wait = statistics.fmean(w for v in waits.values() for w in v)
        ok = wait >= half
        held = held and ok
        blocks = ", ".join(f"block {b} {statistics.fmean(v):.3f}" for b, v in sorted(waits.items(), key=str))
        # Uncertainty, published and not judged: the t95 interval of the block means (df = blocks - 1).
        means = [statistics.fmean(v) for v in waits.values()]
        ci = ""
        if len(means) in (3, 6):
            m, lo, hi = paired_interval(means)
            ci = f"; block-mean t95 [{lo:.3f}, {hi:.3f}] ms"
        lines.append(f"Q1 {s}: mean wait {wait:.3f} ms against half the pilot's gap {half:.3f} ms -> "
                     f"{'holds' if ok else 'does not hold'} (by block: {blocks}{ci})")
    return held, lines


# ---------------------------------------------------------------------------------------------------------------
# Q3: the family on measured occupancy


def step_features(sched, done, adds, late=frozenset()):
    """Each step's P, n, K, H and late flag from the instrument's own counts, and its occupancy t0 to t3 in ms."""
    out = []
    for s in sched:
        P = n = K = H = 0
        is_late = False
        for rid, t in s["tokens"].items():
            c, p = s["computed"][rid], adds[rid]["prompt"]
            if c < p:
                P += t
                H += t * c
                is_late = is_late or rid in late
            else:
                n += 1
                K += c + 1
        out.append(dict(P=P, n=n, K=K, H=H, late=is_late, occ=(done[s["step"]]["t3"] - s["t0"]) / 1e6,
                        t0_ms=s["t0"] / 1e6, t3_ms=done[s["step"]]["t3"] / 1e6, rids=set(s["tokens"])))
    return out


def heldout_third(setting, block_index):
    """The third of a setting's cycles held out in the block_index-th cell of its type (0-based).

    The 2026-10-05 amendment's rule for three blocks, generalised: a per-setting seeded order of the cell's cycles
    is cut into thirds and the cell at index j holds out third j mod 3, so in six burst blocks each third is held
    out twice and in three serial blocks once.
    """
    return block_index % 3


def episodes_of_cell(run, arm, b, kind):
    adds, sched, done, _, _ = step_records(run, arm, b)
    rows = {r["index"]: r for r in map(json.loads, open(os.path.join(run, f"raw-{arm}-{b}.jsonl")))}
    reqs = instrument_gates.load_cell(run, arm, b)
    late = set()
    groups = []
    for setting, ep in timing_fit.episodes_of(kind, reqs):
        rids = {engine_id(adds, rows[q["index"]]["requestId"]) for q in ep}
        if kind == "stagger":
            late.add(engine_id(adds, rows[ep[-1]["index"]]["requestId"]))
        groups.append((setting, rids))
    steps = step_features(sched, done, adds, late)
    seen, out = {}, []
    for setting, rids in groups:
        seen[setting] = seen.get(setting, 0) + 1
        mine = [st for st in steps if st["rids"] and st["rids"] <= rids]
        out.append(dict(setting=setting, block=b, cycle=seen[setting], steps=mine))
    return out


def split_heldout(train):
    """Training and held-out episodes per setting from train's (cell index, episode) pairs.

    One seeded order of a setting's cycle positions, fixed across its cells, is cut into thirds, and the cell at
    index j holds out third j mod 3. Redrawing the order per cell left a cycle position never held out (found by
    review).
    """
    tr, ho = {}, {}
    for s, items in train.items():
        counts = {}
        for j, _ in items:
            counts[j] = counts.get(j, 0) + 1
        if len(set(counts.values())) != 1 or next(iter(counts.values())) % 3:
            raise Refusal(f"Q3: setting {s} has {counts} episodes per cell, not one multiple of three in every cell")
        n = next(iter(counts.values()))
        order = sorted(range(1, n + 1), key=lambda c: random.Random(f"{SEED}/{s}/{c}").random())
        for j in sorted(counts):
            third = heldout_third(s, j)
            out = set(order[third * n // 3:(third + 1) * n // 3])
            for jj, e in items:
                if jj == j:
                    (ho if e["cycle"] in out else tr).setdefault(s, []).append(e)
    return tr, ho


def q3(run):
    names = timing_fit.columns(True)
    # Training candidates by setting, each tagged with its cell's index among its type's blocks; staggered episodes
    # are never trained on and are all predicted.
    train, held = {}, {}
    for kind in ("serial", "burst", "stagger"):
        blocks = ODD if kind != "burst" else tuple(range(1, 7))
        for j, b in enumerate(blocks):
            for e in episodes_of_cell(run, f"{kind}-step", b, kind):
                if kind == "stagger":
                    held.setdefault(e["setting"], []).append(e)
                else:
                    train.setdefault(e["setting"], []).append((j, e))
    # Split each training setting's episodes, cell by cell, by the seeded thirds rule.
    tr, extra = split_heldout(train)
    ho = dict(held)
    for s, eps in extra.items():
        ho.setdefault(s, []).extend(eps)
    # Equal total weight per training setting.
    p = len(names)
    G, h = [[0.0] * p for _ in range(p)], [0.0] * p
    for s, eps in tr.items():
        steps = [st for e in eps for st in e["steps"]]
        if not steps:
            continue
        w = 1.0 / len(steps)
        for st in steps:
            x = timing_fit.features(st, True)
            for i in range(p):
                h[i] += w * x[i] * st["occ"]
                for k2 in range(p):
                    G[i][k2] += w * x[i] * x[k2]
    beta, cond = timing_fit.solve_normalised(G, h, names, check=True)
    failures, lines = [], []
    for s, eps in sorted(ho.items(), key=lambda kv: str(kv[0])):
        steps = [st for e in eps for st in e["steps"]]
        phases = [("context", lambda st: st["P"] > 0), ("decode", lambda st: st["P"] == 0)]
        if s[0] == "stagger":
            phases.append(("late-prefill", lambda st: st["late"]))
        for name, keep in phases:
            mine = [st for st in steps if keep(st)]
            if not mine:
                continue
            obs = statistics.fmean(st["occ"] for st in mine)
            pred = statistics.fmean(sum(c * x for c, x in zip(beta, timing_fit.features(st, True))) for st in mine)
            err = pred / obs - 1
            if abs(err) > 0.10:
                failures.append(f"{s} {name}: predicted {pred:.3f} ms against {obs:.3f} ms, {err:+.1%}")
    lines.append(f"Q3: condition {cond:.1f}, {len(tr)} training settings, {len(ho)} held-out or staggered settings, "
                 f"{len(failures)} phase(s) outside 10%")
    lines += [f"  {f}" for f in failures]
    return not failures, lines, dict(zip(names, beta))


# ---------------------------------------------------------------------------------------------------------------


def evaluate(run, harness):
    lines = gate_archive(run, harness)
    lines += gate_instrument(run)
    cells = {(a, b): instrument_gates.load_cell(run, a, b) for a, b in CELLS}
    ok, more, failures = gate_overhead(cells)
    lines += more
    lines += [f"  outside: {f}" for f in failures]
    lines.append("overhead gate: " + ("PASS -- serial and burst only; staggered is the instrumented engine's"
                                      if ok else "FAIL -- the instrument's overhead is not established"))
    episodes = [e for b in ODD for e in decompose(run, "stagger-step", b)]
    # Every component for every staggered setting, as section 4 registers, not one pooled median.
    for s in sorted({e["setting"] for e in episodes}):
        mine = [e for e in episodes if e["setting"] == s]
        parts = ", ".join(f"{k} {statistics.fmean(e['ms'][k] for e in mine):.3f}"
                          for k in ("S-P", "P-A", "A-F", "F-O", "O-C"))
        lines.append(f"decomposition {s}: mean ms {parts} over {len(mine)} late prefills")
    lines += gaps(run)
    prompt = {s: s[2] for s in Q1_HALF_GAP_MS}
    held, more = q1(episodes, serial_baseline(run), prompt)
    lines += more
    lines.append(f"Q1: {'holds' if held else 'does not hold'} on every short-prefill setting" if held else
                 "Q1: does not hold on every short-prefill setting")
    lines += q3_verdict(run)
    return ok, lines


def q3_verdict(run, fit=None):
    """Q3's lines. A refusal (rank, condition) is Q3's verdict, not the evaluator's: everything before it stands."""
    try:
        passed, more, _ = (fit or q3)(run)
        return more + [f"Q3: {'PASS' if passed else 'FAIL'}"]
    except Refusal as e:
        return [f"Q3: REFUSED -- {e}"]


if __name__ == "__main__":
    try:
        if sys.argv[1:] == ["--self-test"]:
            import step_boundary_selftest
            step_boundary_selftest.run()
        elif len(sys.argv) == 2:
            harness = os.environ.get("BENCHHARNESS")
            if not harness:
                raise Refusal("set BENCHHARNESS to a built cmd/benchharness: the archive is checked before any gate")
            ok, lines = evaluate(sys.argv[1], harness)
            print("\n".join(lines))
            sys.exit(0 if ok else 1)
        else:
            sys.exit(__doc__)
    except Refusal as e:
        sys.exit(f"REFUSED: {e}")
