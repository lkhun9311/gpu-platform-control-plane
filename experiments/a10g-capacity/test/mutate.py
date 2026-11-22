"""Mutation check of the A10G capacity analysis: each mutant breaks one contract rule, and test_kit must fail on every one.

    python3 mutate.py

A mutant whose text is no longer in analysis.py is reported STALE, and one the tests pass on is SURVIVED; either fails the run.
"""

import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
KIT = os.path.join(HERE, "..", "kit")

MUTANTS = [
    ("S1 completion bound ignored", 'if frac < st["min_completed_fraction"]:', "if frac < 0:"),
    ("S2 p99 bound ignored", 'elif q["p99"] > st["max_p99_ttft_ms"]:', "elif q[\"p99\"] > 1e12:"),
    ("S3 trend ignored", 'if m3 > st["trend_ratio"] * m1 + st["trend_slack_ms"]:', "if m3 > 1e12 * m1:"),
    ("p99 minimum ignored", '"p99": quantile(values, 0.99) if n >= min_p99 else None,', '"p99": quantile(values, 0.99) if n >= 0 else None,'),
    ("nearest rank off by one", "return v[max(math.ceil(q * len(v)) - 1, 0)]", "return v[min(int(q * len(v)), len(v) - 1)]"),
    ("recovery needs one window", 'need = rc["consecutive_windows"]', "need = 1"),
    ("recovery window minimum ignored", 'if led["sent"] < rc["min_window_sent"]:', "if led[\"sent\"] < 0:"),
    ("recovery ignores failures", 'elif led["completed"] == led["sent"] and p90 is not None and p90 <= limit:', "elif p90 is not None and p90 <= limit:"),
    ("recovery counts windows past the stage", "for k in range(len(windows) - need + 1):", "for k in range(len(windows)):"),
    ("recovery baseline minimum ignored", 'if base["ttft"]["p99"] is None:', "if False:"),
    ("ledger row count unchecked", 'if planned != meta["rows"] or indices != list(range(planned)):', "if False:"),
    ("replay reconciliation unchecked", 'if meta.get("reconciled") is not True:', "if False:"),
    ("finish reason unchecked", '        and row.get("finishReason") == "length"\n', ""),
    ("rejections counted as failures", '        return "rejected", http, stream', '        return "failed", http, stream'),
    ("saturation takes the unstable rung", '"r_sat": verdicts[-2]["rate_rps"]', '"r_sat": verdicts[-1]["rate_rps"]'),
    ("overload factor moved", 'r_over = c["overload_factor"] * r_sat', "r_over = 2 * r_sat"),
    ("R_low ceiling ignored", 'if r_low > c["low_max_fraction_of_sat"] * r_sat:', "if False:"),
    ("pilot past an unstable rung accepted", '            raise Refused("the pilot continued past an unstable rung")', "            pass"),
    ("token contract exclusion dropped", "        if bad:\n", "        if False:\n"),
    ("dispatch lag exclusion dropped", 'if not lag["ok"]:', "if False:"),
    ("dispatch lag bound loosened", 'return {"sent": len(sent), "lagged": len(lagged), "fraction": frac, "ok": frac <= m["max_lagged_fraction"]}', 'return {"sent": len(sent), "lagged": len(lagged), "fraction": frac, "ok": frac <= 0.5}'),
]


def main():
    src = os.path.join(KIT, "analysis.py")
    with open(src) as f:
        original = f.read()
    bad = 0
    for name, old, new in MUTANTS:
        if original.count(old) != 1:
            print(f"STALE    {name}: the text occurs {original.count(old)} times")
            bad += 1
            continue
        tmp = tempfile.mkdtemp(prefix="a10g-mutant-")
        kit = os.path.join(tmp, "kit")
        shutil.copytree(KIT, kit)
        with open(os.path.join(kit, "analysis.py"), "w") as f:
            f.write(original.replace(old, new))
        env = dict(os.environ, A10G_KIT=kit, PYTHONDONTWRITEBYTECODE="1")
        p = subprocess.run([sys.executable, "-m", "unittest", "-q", "test_kit"], cwd=HERE, env=env, capture_output=True, text=True)
        shutil.rmtree(tmp)
        if p.returncode == 0:
            print(f"SURVIVED {name}")
            bad += 1
        else:
            print(f"killed   {name}")
    print(f"{len(MUTANTS) - bad} of {len(MUTANTS)} mutants killed")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
