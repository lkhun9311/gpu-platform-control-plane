"""Checks that CKPT_RENDEZVOUS_TIMEOUT bounds only the ranks' join, and that the collective timeout still bounds the rest.

The paid session's terminate-wait case restarts with one rank on a surviving node and its peer on a replacement node that
does not exist yet, so the first rank can wait minutes for the second to start.
With the join bounded by the 60 s collective timeout, the kind rehearsal of 2026-11-01 failed that case at 61 s.
Each case here starts the two ranks as separate processes, as the paid session's Pods are, and never under torchrun,
which would start them together and own the store's port.

    python3 experiments/distributed-restart/check_rendezvous.py [IMAGE]

The ranks are gloo processes in one container on loopback, so a frozen process stands in for a lost node: it closes no
connection, as a node that loses power closes none, and its peer has only the timeout to notice it by.
NCCL's own timeouts on a real GPU are not exercised here.
Nor is train.py's store.set_timeout back to the collective timeout: gloo's collectives never wait on the store after the
join, so removing that line leaves every case here passing; it matters for NCCL, whose communicator exchange goes through
the store at the first collective.
"""

from __future__ import annotations

import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import uuid

IMAGE = sys.argv[1] if len(sys.argv) > 1 else "cpu-ddp:torch251"
HERE = pathlib.Path(__file__).resolve().parent
COLLECTIVE = 3
RENDEZVOUS = 40
# Longer than COLLECTIVE by enough that a join bounded by the collective timeout cannot survive it.
LATE = 15
FAILURES: list[str] = []

# Every case runs this inside the container: LATE_RANK starts DELAY seconds after the other; with THIRD three ranks run
# and rank 2 is the late one; with FREEZE set rank 0 is stopped once rank 1 has recorded step 3, and the time until rank
# 1 exits is printed.
SCRIPT = r"""
export WORLD_SIZE=${THIRD:+3} MASTER_ADDR=127.0.0.1 MASTER_PORT=29513 CKPT_DIR=/state CKPT_JOB_ID=uid-test TRAINING_ATTEMPT=1
export CKPT_RUN_ID=rdzv HOME=/tmp WORLD_SIZE=${WORLD_SIZE:-2}
run() { RANK=$1 LOCAL_RANK=0 python /code/train.py >/tmp/r$1.out 2>/tmp/r$1.err; echo "rank $1 exit $?"; }
if [ -n "$FREEZE" ]; then
  RANK=0 LOCAL_RANK=0 python /code/train.py >/tmp/r0.out 2>/tmp/r0.err & p0=$!
  RANK=1 LOCAL_RANK=0 python /code/train.py >/tmp/r1.out 2>/tmp/r1.err & p1=$!
  until grep -q '"step": 3' /tmp/r1.out; do kill -0 $p1 || break; sleep 0.2; done
  kill -STOP $p0
  t0=$(date +%s%N)
  wait $p1; rc=$?
  echo "rank 1 exit $rc"
  echo "after freeze $(( ($(date +%s%N) - t0) / 1000000 )) ms"
  kill -KILL $p0
elif [ -n "$THIRD" ]; then
  run 0 & a=$!
  run 1 & b=$!
  sleep "$DELAY"
  run 2 & c=$!
  wait $a; wait $b; wait $c
else
  run $((1 - LATE_RANK)) & a=$!
  sleep "$DELAY"
  run "$LATE_RANK" & b=$!
  wait $a; wait $b
fi
for r in 0 1 2; do [ -f /tmp/r$r.err ] && { echo "== rank $r stderr"; tail -3 /tmp/r$r.err; }; done
"""


def run(env: dict[str, str], timeout: int = 180) -> str:
    state = pathlib.Path(tempfile.mkdtemp(prefix="rdzv-", dir=os.environ.get("CKPT_CHECK_TMP")))
    state.chmod(0o777)
    name = f"rdzv-check-{uuid.uuid4().hex[:12]}"
    cmd = ["docker", "run", "--rm", "--name", name, "--network", "none", "--user", f"{os.getuid()}:{os.getgid()}",
           "-v", f"{state}:/state", "-v", f"{HERE}:/code:ro"]
    for k, v in env.items():
        cmd += ["-e", f"{k}={v}"]
    cmd += [IMAGE, "sh", "-c", SCRIPT]
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout).stdout
    except subprocess.TimeoutExpired:
        subprocess.run(["docker", "rm", "-f", name], capture_output=True, text=True)
        return f"timed out after {timeout} s"
    finally:
        shutil.rmtree(state, ignore_errors=True)


def exits(out: str) -> dict[int, int]:
    return {int(r): int(c) for r, c in re.findall(r"^rank (\d) exit (\d+)$", out, re.M)}


def expect(case: str, ok: bool, out: str) -> None:
    print(f"{'ok  ' if ok else 'FAIL'} {case}")
    if not ok:
        print("    " + out.strip().replace("\n", "\n    "))
        FAILURES.append(case)


def main() -> int:
    base = {"CKPT_STEPS": "12", "CKPT_COLLECTIVE_TIMEOUT": str(COLLECTIVE)}
    for late in (1, 0):
        out = run({**base, "CKPT_RENDEZVOUS_TIMEOUT": str(RENDEZVOUS), "LATE_RANK": str(late), "DELAY": str(LATE)})
        expect(f"rank {late} {LATE} s late joins within the rendezvous timeout", exits(out) == {0: 0, 1: 0}, out)
        # Without the setting the join is the collective timeout's, which is what failed the rehearsal's case.
        out = run({**base, "LATE_RANK": str(late), "DELAY": str(LATE)})
        failed = exits(out).get(1 - late, 0) != 0 and re.search(r"clients joined|timed out after", out) is not None
        expect(f"rank {late} {LATE} s late without it fails the join, as the rehearsal did", failed, out)

    # Only the store's server waits for every rank, so a third rank late would fail the second without a join of all.
    out = run({**base, "CKPT_RENDEZVOUS_TIMEOUT": str(RENDEZVOUS), "THIRD": "1", "DELAY": str(LATE)})
    expect(f"with three ranks, rank 2 {LATE} s late joins within the rendezvous timeout", exits(out) == {0: 0, 1: 0, 2: 0}, out)

    # A peer lost after the join is noticed at the collective timeout, not at the longer rendezvous one.
    out = run({**base, "CKPT_STEPS": "40", "CKPT_STEP_SLEEP": "1", "CKPT_RENDEZVOUS_TIMEOUT": str(RENDEZVOUS),
               "FREEZE": "1"})
    waited = re.search(r"^after freeze (\d+) ms$", out, re.M)
    ms = int(waited.group(1)) if waited else None
    expect(f"a frozen peer fails the survivor near the {COLLECTIVE} s collective timeout, not {RENDEZVOUS} s",
           exits(out).get(1, 0) != 0 and ms is not None and ms < (COLLECTIVE + 7) * 1000
           and "Timed out waiting" in out, out)

    for value in ("0", "-5"):
        out = run({**base, "CKPT_RENDEZVOUS_TIMEOUT": value, "LATE_RANK": "1", "DELAY": "0"})
        expect(f"CKPT_RENDEZVOUS_TIMEOUT={value} is refused", exits(out) == {0: 2, 1: 2} and "not positive" in out, out)
    out = run({**base, "CKPT_RENDEZVOUS_TIMEOUT": str(RENDEZVOUS), "TORCHELASTIC_USE_AGENT_STORE": "True",
               "LATE_RANK": "1", "DELAY": "0"})
    expect("CKPT_RENDEZVOUS_TIMEOUT under torchrun is refused", exits(out) == {0: 2, 1: 2} and "torchrun" in out, out)

    print(f"{len(FAILURES)} failed" if FAILURES else "all cases passed")
    return 1 if FAILURES else 0


if __name__ == "__main__":
    sys.exit(main())
