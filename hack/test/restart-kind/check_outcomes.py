"""Checks that each run of hack/restart-lifecycle-kind.sh came out as its scenario requires, before the driver may
report success.

    python3 hack/test/restart-kind/check_outcomes.py OUT RUN...

The driver once exited 0 whenever check_lifecycle.py did, so a run whose cases were never started, whose scorer refused
the run, or whose fault was never injected read as a passing rehearsal (codex review against origin/dev).
For each run named this requires:
  - every expected case's directory, and case.json for each case the scenario must start;
  - the shim scorer's verdict.txt, its exit status read and 0 or 1, never 2 (refused) or absent;
  - each case's verdict among those the scenario allows, the expected FAILED, VOID and NOTRUN included;
  - the scenario's injection recorded as done, and no injection-failed.txt.
Prints one line per finding, OK or FAIL, and exits 1 if any FAIL.
"""

from __future__ import annotations

import pathlib
import re
import sys

# Per run: case -> (must it have started, the verdicts allowed, text its reason must hold or None).
# Both terminate-wait-1 cases must recover on a replacement: run a's joins 150 s after the termination, past the 60 s
# collective timeout that failed it in hack/restart-lifecycle-kind-20261101T143009Z, and CKPT_RENDEZVOUS_TIMEOUT is
# what lets attempt 2 wait for it, so a FAILED there is the defect the rendezvous fix exists to remove.
REPLACEMENT = '"class": "replacement"'
EXPECTED = {
    "a": {"reference": (True, {"ACCEPTED"}, None), "no-rng-control": (True, {"ACCEPTED"}, None),
          "dcgm-1": (True, {"ACCEPTED"}, None), "terminate-wait-1": (True, {"ACCEPTED"}, REPLACEMENT)},
    "b": {"reference": (True, {"ACCEPTED"}, None), "rank-kill-1": (True, {"FAILED"}, "censored at its budget"),
          "rank-kill-2": (True, {"ACCEPTED"}, None), "terminate-wait-1": (True, {"ACCEPTED"}, REPLACEMENT)},
    "c": {"reference": (True, {"ACCEPTED"}, None), "rank-kill-1": (True, {"ACCEPTED", "FAILED"}, None),
          "rank-kill-2": (False, {"NOTRUN"}, "could not be retired")},
    "d": {"reference": (True, {"ACCEPTED"}, None), "rank-kill-1": (True, {"VOID"}, "VOID-before-fault"),
          "rank-kill-2": (True, {"VOID"}, "VOID-before-fault"), "dcgm-1": (False, {"NOTRUN"}, "two cases in a row were VOID")},
}


def injected(out: pathlib.Path, run: str) -> tuple[bool, str]:
    """Whether the run's scenario injection is recorded as done."""
    if run == "b":
        text = (out / "quota-hold.txt").read_text() if (out / "quota-hold.txt").exists() else ""
        ok = re.search(r"^lowered ", text, re.M) and re.search(r"^restored ", text, re.M)
        return bool(ok), "the quota was lowered and restored" if ok else f"quota-hold.txt reads {text.strip()!r}"
    if run == "c":
        text = (out / "stuck.txt").read_text().strip() if (out / "stuck.txt").exists() else ""
        return bool(text), f"the finalizer was put on {text}" if text else "no stuck.txt, so no finalizer was put on a Pod"
    if run == "d":
        ok = (out / "clocks-broken.txt").exists()
        return ok, "every exporter's date was broken" if ok else "no clocks-broken.txt"
    return True, "no injection"


def main(argv: list[str]) -> int:
    out, runs = pathlib.Path(argv[1]), argv[2:]
    fails = 0

    def report(ok: bool, msg: str) -> None:
        nonlocal fails
        print(("OK   " if ok else "FAIL ") + msg)
        fails += 0 if ok else 1

    if not runs:
        report(False, "no run was named, so nothing was checked")
    failed = out / "injection-failed.txt"
    report(not failed.exists(), "no injection failed" if not failed.exists() else f"an injection failed: {failed.read_text().strip()[:300]}")
    for run in runs:
        if run not in EXPECTED:
            report(False, f"run {run!r} has no expected outcome")
            continue
        d = out / f"run-{run}"
        verdict = d / "verdict.txt"
        lines = verdict.read_text().splitlines() if verdict.exists() else []
        status = [l for l in lines if l.startswith("exit=")]
        if not status:
            report(False, f"run-{run}: no scorer exit status in verdict.txt, so the scorer is not shown to have scored it")
        else:
            code = status[-1][len("exit="):]
            report(code in ("0", "1"), f"run-{run}: the scorer exited {code}" + ("" if code in ("0", "1") else ", which is not a scored run"))
        verdicts = {}
        for l in lines:
            m = re.match(r"^(ACCEPTED|FAILED|VOID|NOTRUN)\s+(\S+?):?(\s|$)", l)
            if m:
                verdicts[m.group(2)] = (m.group(1), l)
        for case, (started, allowed, reason) in EXPECTED[run].items():
            cdir = d / case
            if not cdir.is_dir():
                report(False, f"run-{run}/{case}: no directory, so the case was neither run nor recorded as not run")
                continue
            if started and not (cdir / "case.json").exists():
                report(False, f"run-{run}/{case}: no case.json, so the case was never submitted")
                continue
            got, line = verdicts.get(case, (None, ""))
            ok = got in allowed and (reason is None or reason in line)
            report(ok, f"run-{run}/{case}: {got or 'no verdict'}, allowed {sorted(allowed)}"
                       + (f" with '{reason}'" if reason else "") + ("" if ok else f"; the line reads {line[:160]!r}"))
        ok, why = injected(out, run)
        report(ok, f"run-{run}: {why}")
    print(f"{fails} FAIL(s)")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
