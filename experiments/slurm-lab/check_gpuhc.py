"""Runs etc/gpuhc.py on the host against stub scontrol and squeue, and exits 1 if any case is decided wrongly.

    python3 experiments/slurm-lab/check_gpuhc.py

No Slurm and no containers: each case writes a signal file, runs the health check with LABGPU_* pointing at it, and
reads back which Slurm commands the stubs were asked to run.
The cases that must drain are most of the list on purpose, because a check that always passes is the failure this
guards against, and it passes every case that expects silence.
"""

from __future__ import annotations

import os
import pathlib
import stat
import subprocess
import sys
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
CHECK = HERE / "etc" / "gpuhc.py"

STUB = """#!/bin/sh
# Records its own name and arguments, and answers the two queries gpuhc.py makes.
echo "$(basename "$0") $*" >>"$STUB_CALLS"
case "$(basename "$0") $1" in
"scontrol show") echo "NodeName=c9 Arch=x86_64 State=${STUB_STATE:-IDLE} ThreadsPerCore=1" ;;
"squeue -h") printf '%s\\n' $STUB_RUNNING ;;
"scontrol requeue") [ "$2" = 77 ] && { echo "scontrol: error: Requested operation is presently disabled for job 77" >&2; exit 1; } ;;
esac
exit 0
"""


def sample(uuid: str, xid="0", dbe="0") -> str:
    return (f'DCGM_FI_DEV_XID_ERRORS{{gpu="0",UUID="{uuid}"}} {xid}\n'
            f'DCGM_FI_DEV_ECC_DBE_VOL_TOTAL{{gpu="0",UUID="{uuid}"}} {dbe}\n')


def two(xid0="0", dbe0="0", xid1="0", dbe1="0") -> str:
    return "# HELP lab signal\n" + sample("GPU-c9-0", xid0, dbe0) + sample("GPU-c9-1", xid1, dbe1)


# name, signal text (None: no file), state the stub reports, running jobs, policy, expected exit, expected calls
CASES = [
    ("healthy", two(), "IDLE", "", "", 0, []),
    ("healthy while running a job", two(), "ALLOCATED", "41", "requeue", 0, []),
    ("an application Xid is not a fault", two(xid1="13"), "IDLE", "", "", 0, []),
    ("single-bit ECC is not a fault", two() + 'DCGM_FI_DEV_ECC_SBE_VOL_TOTAL{gpu="0",UUID="GPU-c9-0"} 9\n',
     "IDLE", "", "", 0, []),
    ("Xid 79 drains, naming card and field", two(xid1="79"), "ALLOCATED", "41", "", 1,
     ["scontrol show node c9",
      "scontrol update nodename=c9 state=drain reason=gpuhc: GPU-c9-1 DCGM_FI_DEV_XID_ERRORS=79"]),
    ("a double-bit count drains", two(dbe0="2"), "IDLE", "", "", 1,
     ["scontrol show node c9",
      "scontrol update nodename=c9 state=drain reason=gpuhc: GPU-c9-0 DCGM_FI_DEV_ECC_DBE_VOL_TOTAL=2"]),
    ("an existing drain is not overwritten", two(xid0="48"), "IDLE+DRAIN", "", "", 1,
     ["scontrol show node c9"]),
    ("the requeue policy requeues every running job, and a refusal does not stop the rest", two(xid0="79"),
     "MIXED", "41 77 42", "requeue", 1,
     ["scontrol show node c9",
      "scontrol update nodename=c9 state=drain reason=gpuhc: GPU-c9-0 DCGM_FI_DEV_XID_ERRORS=79",
      "squeue -h -w c9 -t R -o %i", "scontrol requeue 41", "scontrol requeue 77", "scontrol requeue 42"]),
    ("no signal file drains as not judged", None, "IDLE", "", "", 2, ["scontrol show node c9", "DRAIN:not judged"]),
    ("an empty signal drains: no card read", "", "IDLE", "", "", 2, ["scontrol show node c9", "DRAIN:0 card(s)"]),
    ("a card missing from the signal drains", sample("GPU-c9-0"), "IDLE", "", "", 2,
     ["scontrol show node c9", "DRAIN:1 card(s) in the signal, 2 declared"]),
    ("a card without its double-bit field drains", sample("GPU-c9-0") +
     'DCGM_FI_DEV_XID_ERRORS{gpu="1",UUID="GPU-c9-1"} 0\n', "IDLE", "", "", 2,
     ["scontrol show node c9", "DRAIN:GPU-c9-1 has no DCGM_FI_DEV_ECC_DBE_VOL_TOTAL"]),
    ("a fractional value drains", two(dbe1="0.5"), "IDLE", "", "", 2,
     ["scontrol show node c9", "DRAIN:not a whole non-negative number"]),
    ("a malformed line drains", two() + "garbage line\n", "IDLE", "", "", 2, ["scontrol show node c9", "DRAIN:malformed"]),
    ("two values for one card drain", two() + sample("GPU-c9-0", xid="5"), "IDLE", "", "", 2,
     ["scontrol show node c9", "DRAIN:carries two"]),
]


def run(tmp: pathlib.Path, signal, state, running, policy):
    bindir = tmp / "bin"
    bindir.mkdir(exist_ok=True)
    for name in ("scontrol", "squeue"):
        p = bindir / name
        p.write_text(STUB)
        p.chmod(p.stat().st_mode | stat.S_IXUSR)
    devdir = tmp / "dev"
    devdir.mkdir(exist_ok=True)
    for i in (0, 1):
        (devdir / f"labgpu{i}").touch()
    sig = tmp / "metrics.prom"
    if sig.exists():
        sig.unlink()
    if signal is not None:
        sig.write_text(signal)
    (tmp / "policy").write_text(policy)
    calls = tmp / "calls"
    calls.write_text("")
    env = dict(os.environ, PATH=f"{bindir}:{os.environ['PATH']}", STUB_CALLS=str(calls), STUB_STATE=state,
               STUB_RUNNING=running, LABGPU_SIGNAL=str(sig), LABGPU_POLICY=str(tmp / "policy"),
               LABGPU_DEVICES=str(devdir / "labgpu*"), LABGPU_LOG=str(tmp / "gpuhc.log"), LABGPU_NODE="c9",
               LABGPU_TRACE=str(tmp / "trace"), LABGPU_REQUEUED=str(tmp / "requeued"))
    r = subprocess.run([sys.executable, str(CHECK)], env=env, capture_output=True, text=True, timeout=30)
    return r.returncode, [c for c in calls.read_text().splitlines() if c], r.stderr


def matches(want: list[str], got: list[str]) -> bool:
    # "DRAIN:<text>" stands for one drain call whose reason contains <text>, after which nothing else is called.
    if want and want[-1].startswith("DRAIN:"):
        head, needle = want[:-1], want[-1][len("DRAIN:"):]
        return (got[:-1] == head and len(got) == len(head) + 1
                and got[-1].startswith("scontrol update nodename=c9 state=drain reason=gpuhc: signal not judged: ")
                and needle in got[-1])
    return got == want


def main() -> int:
    bad = 0
    with tempfile.TemporaryDirectory() as d:
        for i, (name, signal, state, running, policy, rc_want, calls_want) in enumerate(CASES):
            tmp = pathlib.Path(d) / str(i)
            tmp.mkdir()
            rc, calls, err = run(tmp, signal, state, running, policy)
            if rc == rc_want and matches(calls_want, calls) and not err:
                print(f"ok   {name}")
            else:
                bad += 1
                print(f"FAIL {name}: exit {rc} (want {rc_want}); calls {calls}; stderr {err.strip()[:200]}")
        # The check runs every few seconds while the fault lasts, so a job it has tried once is not tried again:
        # a --no-requeue job refuses every time, and retrying it each run filled the lab's log (evidence 06b).
        tmp = pathlib.Path(d) / "repeat"
        tmp.mkdir()
        run(tmp, two(xid0="79"), "MIXED", "41 77", "requeue")
        rc, calls, err = run(tmp, two(xid0="79"), "MIXED+DRAIN", "41 77 50", "requeue")
        want = ["scontrol show node c9", "squeue -h -w c9 -t R -o %i", "scontrol requeue 50"]
        if rc == 1 and calls == want and not err:
            print("ok   a second run requeues only the job it has not tried")
        else:
            bad += 1
            print(f"FAIL a second run requeues only the job it has not tried: exit {rc}; calls {calls}; stderr {err.strip()[:200]}")
    # Every case compares the whole list of calls, so a check that ever asked for state=resume would fail one.
    print(f"{len(CASES) + 1 - bad} passed, {bad} failed")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
