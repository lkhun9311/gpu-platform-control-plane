"""Fixture runs for check_lifecycle.py's consecutive-case replay: a clean one passes, and each defect is a FAIL."""
import json
import pathlib
import subprocess
import sys
import tempfile

CHECK = str(pathlib.Path(__file__).resolve().parent / "check_lifecycle.py")
P, C = "rst-reference-100000", "rst-rank-kill-1-100100"
STREAMS = ("mltrainingjobs", "jobs", "pods", "workloads")


def ev(res, kind, rv, at, **kw):
    return {"received": f"2026-11-01T10:00:{at:02d}+00:00", "res": res, "type": kind, "rv": str(rv), **kw}


def run(extra=(), drop=()):
    d = pathlib.Path(tempfile.mkdtemp())
    r = d / "run-x"
    for case, n in (("reference", P), ("rank-kill-1", C)):
        (r / case).mkdir(parents=True)
        (r / case / "case.json").write_text(json.dumps({"name": n}))
    (r / "provenance.txt").write_text("cases=reference rank-kill-1\n")
    base = {res: [ev(res, "LISTED", 1, 0, names=[]), ev(res, "WATCH-START", 1, 1)] for res in STREAMS}
    base["mltrainingjobs"] += [ev("mltrainingjobs", "ADDED", 5, 5, name=P)]
    base["pods"] += [ev("pods", "ADDED", 10, 10, name=P + "-0-abc")]
    if "pod-deleted" not in drop:
        base["pods"] += [ev("pods", "DELETED", 50, 50, name=P + "-0-abc")]
    base["mltrainingjobs"] += [ev("mltrainingjobs", "DELETED", 51, 51, name=P), ev("mltrainingjobs", "ADDED", 60, 52, name=C)]
    for res, e in extra:
        base[res].append(e)
    for res in STREAMS:
        if (res, "bookmark") not in drop:
            base[res].append(ev(res, "BOOKMARK", 61, 59))
        (d / f"events-{res}.jsonl").write_text("".join(json.dumps(e) + "\n" for e in sorted(base[res], key=lambda e: e["received"])))
    out = subprocess.run([sys.executable, CHECK, str(d)], capture_output=True, text=True).stdout
    return " | ".join(l for l in out.splitlines() if ("submitted" in l or "submission" in l) and "last sampled" not in l)


cases = {
    "clean": (run(), "OK"),
    "a leftover Pod": (run(drop=("pod-deleted",)), "FAIL"),
    "a recorder that never caught up": (run(drop=(("pods", "bookmark"),)), "FAIL"),
    "a watch resumed from its resourceVersion": (run(extra=[("pods", ev("pods", "WATCH-END", 50, 53)), ("pods", ev("pods", "WATCH-START", 50, 54))]), "OK"),
    "a gap across the submission": (run(extra=[("pods", ev("pods", "GAP", 50, 53)), ("pods", ev("pods", "LISTED", 70, 55, names=[]))],
                                        drop=(("pods", "bookmark"),)), "FAIL"),
    "a gap before the submission, listed again": (run(extra=[("pods", ev("pods", "GAP", 50, 51)), ("pods", ev("pods", "LISTED", 55, 52, names=[]))]), "OK"),
    "a change after the submission": (run(extra=[("pods", ev("pods", "MODIFIED", 70, 58, name=P + "-0-zzz"))]), "changed"),
}
bad = 0
for k, (got, want) in cases.items():
    ok = got.startswith(want) if want in ("OK", "FAIL") else want in got
    print(f"{'ok  ' if ok else 'BAD '} {k}: {got[:160]}")
    bad += not ok
sys.exit(1 if bad else 0)
