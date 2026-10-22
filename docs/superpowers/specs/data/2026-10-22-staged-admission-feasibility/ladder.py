"""A1 part 2: the replay's screen of the staged ladder, on the diagnostic's three traces (seeds 851 to 853).

For each cap in CAPS, the gateway's serial-prefill hold ("hold-one-prefill") with vLLM's long_prefill_token_threshold
at that cap, and cap-only (every contender forwarded) beside it; off (no hold, no cap) is the unshed arm; isolation is
the same trace's premium rows alone, uncapped, admission off, which is what an R1 cell replays.
Step model: simulate.py's, fitted on pilots A and B (282,897 steps), as every published replay figure was.
Guard bars, as the ladder registers them, on the shared window ending at the trace's last scheduled instant:
aggregate throughput (every token any request had processed by then, prompt and output) at least 95% of off's, and
contender work (contender prompt and output tokens processed by then) and contender output (contender output tokens by
then) each at least 75% of off's. Beside them, the owner's earlier contender limits (Finding 9), reported, not judged.

These are screening outputs of a model, not measurements; nothing here is publishable as a result.
"""
import json
import math
import os
import sys

sys.path.insert(0, "/home/lkhun9311/workspace/gpu-cp-t2/hack/prospective-pilot")
import pilot_report as pr  # noqa: E402
import simulate as sim  # noqa: E402

H = "/home/lkhun9311/workspace/gpu-platform-control-plane/hack/"
FIT = [H + "m5c-20261008-235046-pilotA/m5c-run", H + "m5c-20261009-013656-pilotB/m5c-run"]
DIAG = H + "m5c-20261009-122503-diagD/m5c-run"
CAPS = [0, 384, 256, 192, 128, 96, 72]
SCALES = [float(s) for s in (sys.argv[1].split(",") if len(sys.argv) > 1 else ["1.0", "1.03", "1.1"])]
# A lighter contender load for screening only: keep KEEP of every EVERY contenders in arrival order, premium untouched.
KEEP, EVERY = (int(v) for v in (sys.argv[2].split("/") if len(sys.argv) > 2 else ["1", "1"]))
if len(sys.argv) > 3:
    CAPS = [int(c) for c in sys.argv[3].split(",")]
LOG = []


class LoggingEngine(sim.Engine):
    """The replay's engine, recording each step's end and the tokens it gave each tenant, prompt and output apart."""

    def step(self):
        before = {id(r): (r["computed"], r["out"]) for r in self.running}
        waiting = {id(w[2]): w[2] for w in self.waiting}
        out = super().step()
        if out is None:
            return None
        row = {"t": self.now, "prem_pf": 0, "prem_out": 0, "cont_pf": 0, "cont_out": 0}
        seen = list(self.running) + out[1]
        for r in seen:
            c0, o0 = before.get(id(r), (0, 0)) if id(r) in before else ((0, 0) if id(r) in waiting else (None, None))
            if c0 is None:
                continue
            dpf = min(r["computed"], r["prompt"]) - min(c0, r["prompt"])
            dout = r["out"] - o0
            k = "prem" if r["tenant"] == pr.PREMIUM else "cont"
            row[k + "_pf"] += dpf
            row[k + "_out"] += dout
        LOG.append(row)
        return out


sim.Engine = LoggingEngine


def fit():
    k = 5
    xtx = [[0.0] * k for _ in range(k)]
    xty = [0.0] * k
    n = 0
    for d in FIT:
        for arm, rep in pr.cells(d):
            reqs, steps, adds = sim.load_cell(d, arm, rep)
            sched = [s for s in steps if s.get("ev") == "sched"]
            for a, b in zip(sched, sched[1:]):
                period = (b["t0"] - a["t0"]) / 1e6
                if period > 500:
                    continue
                x = sim.step_features(a, adds)
                for i in range(k):
                    xty[i] += x[i] * period
                    for j in range(k):
                        xtx[i][j] += x[i] * x[j]
                n += 1
            del reqs, steps, adds
    return sim.solve(xtx, xty), n


def run(reqs, coef, rule, cap, scale, fwd, deliver, window_end):
    del LOG[:]
    out = sim.simulate(reqs, coef, sim.RULES[rule], fwd, deliver, long_prefill=cap, step_scale=scale)
    s = sim.summarize(out)
    w = [x for x in LOG if x["t"] <= window_end]
    s["work_total"] = sum(x["prem_pf"] + x["prem_out"] + x["cont_pf"] + x["cont_out"] for x in w)
    s["work_cont"] = sum(x["cont_pf"] + x["cont_out"] for x in w)
    s["out_cont"] = sum(x["cont_out"] for x in w)
    # Aggregate output tokens, the price-of-protection's definition of throughput (2026-09-05, reading 1).
    s["out_total"] = sum(x["prem_out"] + x["cont_out"] for x in w)
    # The registered guard bars (2026-10-22-staged-admission-targets-design.md, "Estimands"), on the window from the
    # trace's first scheduled instant to 420 s after it: output of successful streams whose last content arrived
    # inside it, credited whole, a partial stream at zero; the contender's share of that output; and the contender's
    # prompt tokens in steps that ended inside it. The token-level sums above are the screen's first reading, kept
    # beside these because a review (codex review --uncommitted) showed they are not the registered quantities.
    reg_end = min(r["sched"] for r in reqs) + 420 * 1_000_000_000
    ok_p = sum(1 for r in out if r["tenant"] == pr.PREMIUM and "first_token" in r and not r.get("expired")
               and "finished" in r and r["finished"] - r["sched"] <= sim.TIMEOUT_NS and r["finished"] <= reg_end)
    ok_c = sum(1 for r in out if r["tenant"] == pr.CONTENDER and "finished" in r
               and r["finished"] - r["sched"] <= sim.TIMEOUT_NS and r["finished"] <= reg_end)
    s["reg_out_p"], s["reg_out_c"] = ok_p * sim.CAP[pr.PREMIUM], ok_c * sim.CAP[pr.CONTENDER]
    s["reg_work_c"] = sum(x["cont_pf"] for x in LOG if x["t"] <= reg_end)
    # Contender prefill duration, from reaching the engine to its first token: what decides the hold's stability.
    dur = sorted((r["first_token"] - r["engaged"]) / 1e6 for r in out if r["tenant"] == pr.CONTENDER and "first_token" in r)
    s["cont_prefill_p50_ms"] = pr.nearest_rank(dur, 0.5)
    s["cont_prefill_p95_ms"] = pr.nearest_rank(dur, 0.95)
    return s


def main():
    coef, n = fit()
    print(json.dumps({"coef_ms": [round(c, 4) for c in coef], "steps": n}))
    cells = []
    fwd_all = []
    for rep in (1, 2, 3):
        reqs, steps, adds = sim.load_cell(DIAG, "off", rep)
        conts = sorted((r for r in reqs if r["tenant"] == pr.CONTENDER), key=lambda r: r["sched"])
        drop = {id(r) for i, r in enumerate(conts) if i % EVERY >= KEEP}
        cells.append((rep, [r for r in reqs if id(r) not in drop]))
        fwd_all.append((reqs, steps, adds))
    # The forward delay and delivery the published replays use: the median gateway-arrival-to-engine-add of the cells
    # replayed, and 8 ms.
    fwd = sim.offsets(fwd_all)
    del fwd_all
    deliver = 8_000_000
    print(json.dumps({"forward_ms": fwd / 1e6, "deliver_ms": deliver / 1e6}))
    print("scale block arm cap | premium p99 ms | iso p99 ms | p99/iso | p99/off | thru/off | cont work/off | "
          "cont out/off | cont done/offered | p50/off | p95 s | hold-timeouts | cont prefill p50/p95 ms")
    pooled = {}
    for scale in SCALES:
        for rep, reqs in cells:
            window_end = max(r["sched"] for r in reqs)
            iso = run([r for r in reqs if r["tenant"] == pr.PREMIUM], coef, "off", 0, scale, fwd, deliver, window_end)
            off = run(reqs, coef, "off", 0, scale, fwd, deliver, window_end)
            arms = [("off", "off", 0)] + [("hold", "hold-one-prefill", c) for c in CAPS] + [
                ("cap-only", "off", c) for c in CAPS if c]
            for name, rule, cap in arms:
                x = off if (name == "off") else run(reqs, coef, rule, cap, scale, fwd, deliver, window_end)
                key = (scale, name, cap)
                pooled.setdefault(key, []).append((x, off, iso))
                f = lambda v: "inf" if v is None or (isinstance(v, float) and math.isinf(v)) else "%.0f" % v
                print("%.4f %d %s %d | %s | %s | %.2f | %.3f | %.4f | %.4f | %.4f | %d/%d | %.2f | %s | %d | %s/%s" % (
                    scale, 850 + rep, name, cap, f(x["premium_p99_ms"]), f(iso["premium_p99_ms"]),
                    x["premium_p99_ms"] / iso["premium_p99_ms"], x["premium_p99_ms"] / off["premium_p99_ms"],
                    x["work_total"] / off["work_total"], x["work_cont"] / off["work_cont"], x["out_cont"] / off["out_cont"],
                    x["contender_completed"], x["contender_offered"],
                    x["contender_completion_p50_ms"] / off["contender_completion_p50_ms"],
                    "inf" if math.isinf(x["contender_completion_p95_ms"]) else "%.1f" % (x["contender_completion_p95_ms"] / 1000),
                    x["contender_hold_timeouts"], f(x["cont_prefill_p50_ms"]), f(x["cont_prefill_p95_ms"])))
                sys.stdout.flush()
    print("\nworst block per arm: scale arm cap | max p99/iso | min thru/off | min cont work/off | min cont out/off | "
          "ladder stage reached on every block (guard bars as registered) | min output thru/off | stage with output throughput")
    for (scale, name, cap), rows in sorted(pooled.items()):
        ratio = max(x["premium_p99_ms"] / iso["premium_p99_ms"] for x, off, iso in rows)
        thru = min(x["work_total"] / off["work_total"] for x, off, iso in rows)
        cw = min(x["work_cont"] / off["work_cont"] for x, off, iso in rows)
        co = min(x["out_cont"] / off["out_cont"] for x, off, iso in rows)
        guard = thru >= 0.95 and cw >= 0.75 and co >= 0.75
        stage = "guard fails" if not guard else (
            "T3" if ratio <= 1.25 else "T2" if ratio <= 2 else "T1" if ratio <= 3 else "below T1")
        othru = min(x["out_total"] / off["out_total"] for x, off, iso in rows)
        oguard = othru >= 0.95 and cw >= 0.75 and co >= 0.75
        ostage = "guard fails" if not oguard else (
            "T3" if ratio <= 1.25 else "T2" if ratio <= 2 else "T1" if ratio <= 3 else "below T1")
        print("%.4f %s %d | %.2f | %.4f | %.4f | %.4f | %s | %.4f | %s" % (scale, name, cap, ratio, thru, cw, co, stage, othru, ostage))
    print("\nregistered guard bars, worst block per arm: scale arm cap | max p99/iso | min aggregate output/off | "
          "min contender output share/off's share | min contender prompt work/off | stage on every block")
    for (scale, name, cap), rows in sorted(pooled.items()):
        ratio = max(x["premium_p99_ms"] / iso["premium_p99_ms"] for x, off, iso in rows)
        share = lambda z: z["reg_out_c"] / (z["reg_out_p"] + z["reg_out_c"])
        g1 = min((x["reg_out_p"] + x["reg_out_c"]) / (off["reg_out_p"] + off["reg_out_c"]) for x, off, iso in rows)
        g2 = min(share(x) / share(off) for x, off, iso in rows)
        g3 = min(x["reg_work_c"] / off["reg_work_c"] for x, off, iso in rows)
        rstage = "guard fails" if not (g1 >= 0.95 and g2 >= 0.75 and g3 >= 0.75) else (
            "T3" if ratio <= 1.25 else "T2" if ratio <= 2 else "T1" if ratio <= 3 else "below T1")
        print("%.4f %s %d | %.2f | %.4f | %.4f | %.4f | %s" % (scale, name, cap, ratio, g1, g2, g3, rstage))


if __name__ == "__main__":
    main()
