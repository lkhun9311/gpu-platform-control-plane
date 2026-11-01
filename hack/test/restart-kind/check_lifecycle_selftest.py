"""Fixture runs for check_lifecycle.py's consecutive-case replay: a clean one passes, and each defect is a FAIL."""
import json
import pathlib
import subprocess
import sys
import tempfile

CHECK = str(pathlib.Path(__file__).resolve().parent / "check_lifecycle.py")
P, C = "rst-reference-100000", "rst-rank-kill-1-100100"


def t(s):
    return f"2026-11-01T10:{s // 60:02d}:{s % 60:02d}+00:00"


def run(name, extra, drop=()):
    d = pathlib.Path(tempfile.mkdtemp())
    r = d / "run-x"
    for case, n in (("reference", P), ("rank-kill-1", C)):
        (r / case).mkdir(parents=True)
        (r / case / "case.json").write_text(json.dumps({"name": n}))
    (r / "provenance.txt").write_text("cases=reference rank-kill-1\n")
    base = {res: [{"received": t(0), "res": res, "type": "LISTED", "names": []},
                  {"received": t(1), "res": res, "type": "WATCH-START"}] for res in ("mltrainingjobs", "jobs", "pods", "workloads")}
    base["pods"] += [{"received": t(10), "res": "pods", "type": "ADDED", "name": P + "-0-abc"}]
    base["mltrainingjobs"] += [{"received": t(5), "res": "mltrainingjobs", "type": "ADDED", "name": P}]
    if "pod-deleted" not in drop:
        base["pods"] += [{"received": t(50), "res": "pods", "type": "DELETED", "name": P + "-0-abc"}]
    base["mltrainingjobs"] += [{"received": t(51), "res": "mltrainingjobs", "type": "DELETED", "name": P},
                               {"received": t(60), "res": "mltrainingjobs", "type": "ADDED", "name": C}]
    for res, e in extra:
        base[res].append(e)
    for res, evs in base.items():
        (d / f"events-{res}.jsonl").write_text("".join(json.dumps(e) + "\n" for e in evs))
    out = subprocess.run([sys.executable, CHECK, str(d)], capture_output=True, text=True).stdout
    line = [l for l in out.splitlines() if ("submitted" in l or "continuous" in l) and "last sampled" not in l]
    return " | ".join(line) if line else out


cases = {
    "clean": run("clean", []),
    "leftover": run("leftover", [], drop=("pod-deleted",)),
    "watch down at submission": run("down", [("pods", {"received": t(55), "res": "pods", "type": "WATCH-END"})]),
    "watch resumed 1 s before": run("resumed", [("pods", {"received": t(55), "res": "pods", "type": "WATCH-END"}),
                                                 ("pods", {"received": t(59), "res": "pods", "type": "WATCH-START"})]),
    "watch resumed 5 s before": run("resumed5", [("pods", {"received": t(54), "res": "pods", "type": "WATCH-END"}),
                                                  ("pods", {"received": t(55), "res": "pods", "type": "WATCH-START"})]),
    "gap then listed": run("gap", [("pods", {"received": t(52), "res": "pods", "type": "GAP"}),
                                   ("pods", {"received": t(53), "res": "pods", "type": "LISTED", "names": []}),
                                   ("pods", {"received": t(54), "res": "pods", "type": "WATCH-START"})]),
    "late sighting": run("late", [("pods", {"received": t(70), "res": "pods", "type": "MODIFIED", "name": P + "-0-zzz"})]),
}
want = {"clean": "OK", "leftover": "FAIL", "watch down at submission": "FAIL", "watch resumed 1 s before": "FAIL",
        "watch resumed 5 s before": "OK", "gap then listed": "OK"}
bad = 0
for k, v in cases.items():
    w = want.get(k)
    print(f"{k}: {v[:150]}")
    if k == "late sighting":
        w = None
        if "seen 1 time(s) after" not in v:
            print("   UNEXPECTED, want the late sighting reported")
            bad += 1
    if w and not v.startswith(w):
        print(f"   UNEXPECTED, want {w}")
        bad += 1
sys.exit(1 if bad else 0)
