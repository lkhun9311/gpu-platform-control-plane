"""Feeds score_requeue.py the archived step-5 logs and doctored copies of them, and exits 1 if any verdict is wrong.

    python3 experiments/slurm-lab/check_score_requeue.py

The archived runs (evidence/2026-11-04) are the fixtures, so the scorer is checked against records train.py wrote,
not against records imagined for the test.
Each doctored copy changes one thing a real mix-up would change, and the scorer must refuse it.
"""

from __future__ import annotations

import json
import pathlib
import shutil
import subprocess
import sys
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
SCORER = HERE / "score_requeue.py"
EVID = HERE / "evidence" / "2026-11-04"
STEPS = "40"


def score(case: pathlib.Path, scontrol: pathlib.Path, control: bool = False) -> tuple[int, str]:
    args = [sys.executable, str(SCORER)] + (["--load-none-control"] if control else [])
    args += [str(EVID / "05-tr-ref-logs"), str(case), str(scontrol), STEPS]
    r = subprocess.run(args, capture_output=True, text=True, timeout=60)
    return r.returncode, r.stdout + r.stderr


def rewrite(path: pathlib.Path, change) -> None:
    """Applies change to every record of one log, in place."""
    out = []
    for line in path.read_text().splitlines():
        if line.strip():
            rec = json.loads(line)
            change(rec)
            line = json.dumps(rec)
        out.append(line)
    path.write_text("\n".join(out) + "\n")


def copy(tmp: pathlib.Path, name: str, src: str) -> pathlib.Path:
    dst = tmp / name
    shutil.copytree(EVID / src, dst)
    return dst


def main() -> int:
    bad = 0

    def expect(name: str, ok: bool, out: str) -> None:
        nonlocal bad
        if ok:
            print(f"ok   {name}")
        else:
            bad += 1
            tail = "\n".join(line for line in out.splitlines() if line.startswith(("FAIL", "load-none", "Traceback")))
            print(f"FAIL {name}\n{tail[:800]}")

    full_sc = EVID / "05-tr-full-scontrol.txt"
    none_sc = EVID / "05-tr-none-scontrol.txt"
    with tempfile.TemporaryDirectory() as d:
        tmp = pathlib.Path(d)

        rc, out = score(EVID / "05-tr-full-logs", full_sc)
        expect("the archived full case passes", rc == 0 and "0 failed" in out, out)

        rc, out = score(EVID / "05-tr-none-logs", none_sc, control=True)
        expect("the archived load-none control is caught for its reason alone",
               rc == 1 and "caught for the expected reason only: yes" in out, out)

        # The control's restarted attempt crashing after it chose to start from zero is still five of the same
        # failures plus more; it must not count as caught.
        logs = copy(tmp, "none-crash", "05-tr-none-logs")
        for rank in (0, 1):
            p = logs / f"attempt-1-rank-{rank}.jsonl"
            keep = [line for line in p.read_text().splitlines() if '"event": "step"' not in line or
                    json.loads(line)["step"] <= 5]
            p.write_text("\n".join(keep) + "\n")
        rc, out = score(logs, none_sc, control=True)
        expect("a load-none control whose restarted attempt stopped at step 5 is not caught",
               rc == 1 and "caught for the expected reason only: no" in out, out)

        # Rank 0's records copied under rank 1's name: the file name says two ranks, the records say one.
        logs = copy(tmp, "dup-rank", "05-tr-full-logs")
        shutil.copy(logs / "attempt-1-rank-0.jsonl", logs / "attempt-1-rank-1.jsonl")
        rc, out = score(logs, full_sc)
        expect("rank 0's records filed as rank 1 are refused",
               rc == 1 and "attempt 1 rank 1: every record carries rank 1" in out, out)

        # Attempt 0 from another job: the scorer once checked the attempt number and never the job.
        logs = copy(tmp, "other-job", "05-tr-full-logs")
        for rank in (0, 1):
            rewrite(logs / f"attempt-0-rank-{rank}.jsonl", lambda r: r.__setitem__("run_id", "3"))
        rc, out = score(logs, full_sc)
        expect("attempt 0 records from another job are refused",
               rc == 1 and "attempt 0 rank 0: every record carries the case's JobId 36" in out, out)

        # One rank's log of an attempt missing.
        logs = copy(tmp, "missing", "05-tr-full-logs")
        (logs / "attempt-0-rank-1.jsonl").unlink()
        rc, out = score(logs, full_sc)
        expect("a missing rank log is refused",
               rc == 1 and "FAIL: the case has a log for every rank of every attempt" in out, out)

        # A resume from a directory attempt 0 did not publish, at the right step number.
        logs = copy(tmp, "other-dir", "05-tr-full-logs")
        for rank in (0, 1):
            def other(r):
                if r.get("event") == "resume":
                    r["from_dir"] = r["from_dir"].split("-")[0] + "-00000000000000000000000000000000"
            rewrite(logs / f"attempt-1-rank-{rank}.jsonl", other)
        rc, out = score(logs, full_sc)
        expect("a resume from a directory attempt 0 did not publish is refused",
               rc == 1 and "FAIL: the resume directory" in out, out)

    total = 7
    print(f"{total - bad} passed, {bad} failed")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
