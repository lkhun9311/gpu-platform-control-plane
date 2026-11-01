"""Runs train.py's checkpoint protocol through every fault it injects and checks each resume against a reference.

Each case is one or two attempts of two gloo ranks under torchrun in the CPU torch image, on a fresh directory standing
in for the shared volume.
A case passes only if the attempt that finishes ends with exactly the parameters of a run that was never interrupted,
resumed from the step the case says it must, so loading a partial or a skewed checkpoint cannot pass by luck.
Each negative control drops one saved component (optimizer, scheduler, sampler position, global RNG) and must fail that
comparison: a component whose loss leaves the parameters equal is either not part of the result or not seen by the
comparison, and either way the claim that restoring it matters would be unshown.

    python3 experiments/distributed-restart/check_protocol.py [IMAGE]

This is a local check of the trainer alone. A shared filesystem between nodes is not exercised here: every rank runs in
one container on one disk, so NFS visibility and close-to-open behaviour are left to the kind cases with an NFS server.
"""

from __future__ import annotations

import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import uuid

IMAGE = sys.argv[1] if len(sys.argv) > 1 else "cpu-ddp:torch251"
HERE = pathlib.Path(__file__).resolve().parent
STEPS = 12
# An uninterrupted attempt takes seconds; this only has to separate that from a deadlock.
ATTEMPT_TIMEOUT = 120
FAILURES: list[str] = []


def attempt(state: pathlib.Path, number: int, steps: int = STEPS, **env: str) -> tuple[int, list[dict]]:
    settings = {"CKPT_STEPS": str(steps), "CKPT_DIR": "/state", "CKPT_JOB_ID": "uid-test", "TRAINING_ATTEMPT": str(number),
                "CKPT_RUN_ID": state.name, "HOME": "/tmp", **env}
    name = f"ckpt-check-{uuid.uuid4().hex[:12]}"
    cmd = ["docker", "run", "--rm", "--name", name, "--network", "none", "--user", f"{os.getuid()}:{os.getgid()}",
           "-v", f"{state}:/state", "-v", f"{HERE}:/code:ro"]
    for k, v in settings.items():
        cmd += ["-e", f"{k}={v}"]
    cmd += [IMAGE, "torchrun", "--standalone", "--nproc-per-node", "2", "--max-restarts", "0", "/code/train.py"]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=ATTEMPT_TIMEOUT)
    except subprocess.TimeoutExpired:
        # Ranks that disagree on what to load wait on each other's next collective forever, so a hang is a result.
        # Killing the client leaves the container running; it is removed by name.
        subprocess.run(["docker", "rm", "-f", name], capture_output=True, text=True)
        print(f"attempt {number} timed out after {ATTEMPT_TIMEOUT} s", file=sys.stderr)
        return -1, []
    records = []
    for line in proc.stdout.splitlines():
        if line.startswith("{"):
            records.append(json.loads(line))
    if not records:
        # A run that printed nothing is a harness failure, not a result; show why rather than reporting an empty case.
        print(proc.stderr[-3000:], file=sys.stderr)
    return proc.returncode, records


def events(records: list[dict], event: str, rank: int = 0) -> list[dict]:
    return [r for r in records if r["event"] == event and r["rank"] == rank]


def final(records: list[dict]) -> list[float] | None:
    last = [r for r in events(records, "step") if r["step"] == STEPS]
    return last[0]["params"] if last else None


def expect(case: str, ok: bool, detail: str) -> None:
    print(f"{'ok  ' if ok else 'FAIL'} {case}: {detail}")
    if not ok:
        FAILURES.append(case)


def fresh() -> pathlib.Path:
    # CKPT_CHECK_TMP picks the parent; /tmp is RAM on some hosts, and a run killed midway would leave its directories there.
    path = pathlib.Path(tempfile.mkdtemp(prefix="ckpt-", dir=os.environ.get("CKPT_CHECK_TMP")))
    path.chmod(0o777)
    return path


def resumed_case(case: str, fault: str, want_from: int, reference: list[float], load: str = "full") -> None:
    state = fresh()
    try:
        code, first = attempt(state, 1, CKPT_FAULT=fault)
        fired = [r for r in first if r["event"] == "fault"]
        expect(case + " fault fired", code != 0 and len(fired) == 1, f"exit {code}, fault records {len(fired)}")
        code, second = attempt(state, 2, CKPT_LOAD=load)
        resume = events(second, "resume")
        got_from = resume[0]["from_step"] if resume else None
        expect(case + " resume point", code == 0 and got_from == want_from, f"exit {code}, resumed from {got_from}, want {want_from}")
        same = final(second) == reference
        if load == "full":
            expect(case + " same training", same, "final parameters equal the reference" if same else "final parameters differ")
        else:
            expect(case + " negative control", final(second) is not None and not same,
                   "differs from the reference, as dropping state must" if not same else "matched the reference")
    finally:
        shutil.rmtree(state, ignore_errors=True)


def main() -> int:
    state = fresh()
    try:
        code, ref_records = attempt(state, 1)
        reference = final(ref_records)
        expect("reference", code == 0 and reference is not None, f"exit {code}")
        if reference is None:
            return 1
        repeat = fresh()
        code, again = attempt(repeat, 1)
        shutil.rmtree(repeat, ignore_errors=True)
        expect("reference repeats", code == 0 and final(again) == reference,
               f"exit {code}; a second uninterrupted run ends identically")
    finally:
        shutil.rmtree(state, ignore_errors=True)

    # Rank 1 dies with its shard of step 6 unsynced and unrenamed: step 6 has no manifest.
    resumed_case("kill-before-fsync", "kill-before-fsync:6:1", 5, reference)
    # Every shard of step 6 is in place and rank 0 dies before the manifest.
    resumed_case("kill-before-manifest", "kill-before-manifest:6", 5, reference)
    # The manifest of step 6 is complete but LATEST still names step 5, and LATEST is what is offered first.
    resumed_case("kill-before-latest", "kill-before-latest:6", 5, reference)
    # LATEST names step 6 and rank 0 dies right after publishing it.
    resumed_case("kill-after-latest", "kill-after-latest:6", 6, reference)
    # Step 6 is one batch into the second epoch and between the learning rate's first and second decays, so no component
    # sits at a boundary where a fresh one would happen to coincide with the saved one.
    for control in ("no-optimizer", "no-scheduler", "no-sampler", "no-rng"):
        resumed_case(control, "kill-after-latest:6", 6, reference, load=control)

    # Rank 1 labels its shard of step 6 as step 7: the checkpoint is refused by every rank and LATEST stays at 5.
    state = fresh()
    try:
        code, first = attempt(state, 1, steps=6, CKPT_FAULT="skew:6:1")
        refused = events(first, "checkpoint_refused", 0) + events(first, "checkpoint_refused", 1)
        expect("skew refused", code == 0 and len(refused) == 2, f"exit {code}, refusals {len(refused)} of 2 ranks")
        code, second = attempt(state, 2)
        resume = events(second, "resume")
        got_from = resume[0]["from_step"] if resume else None
        # The exit code as well: the last step record is written before the last save, so an attempt can report the
        # right parameters and still fail.
        expect("skew resume point", code == 0 and got_from == 5, f"exit {code}, resumed from {got_from}, want 5")
        expect("skew same training", final(second) == reference, "final parameters compared with the reference")
    finally:
        shutil.rmtree(state, ignore_errors=True)

    # A shard truncated after publication: its hash no longer matches, so every rank falls back to step 5 together.
    state = fresh()
    try:
        code, _ = attempt(state, 1, steps=6)
        expect("torn shard setup", code == 0, f"exit {code} of the attempt that publishes step 6")
        latest = (state / "uid-test" / "LATEST").read_text().strip()
        shard = state / "uid-test" / latest / "rank-1.pt"
        shard.write_bytes(shard.read_bytes()[:100])
        code, second = attempt(state, 2)
        rejected = events(second, "checkpoint_rejected", 0) + events(second, "checkpoint_rejected", 1)
        resume = events(second, "resume")
        got_from = resume[0]["from_step"] if resume else None
        own = sorted((r["rank"], r["own_shard_ok"]) for r in rejected)
        expect("torn shard rejected together", own == [(0, True), (1, False)], f"rejections {own}")
        expect("torn shard resume point", code == 0 and got_from == 5, f"exit {code}, resumed from {got_from}, want 5")
        expect("torn shard same training", final(second) == reference, "final parameters compared with the reference")
    finally:
        shutil.rmtree(state, ignore_errors=True)

    # Nothing on the volume: a restart from step zero, recorded as one and not as a resume.
    state = fresh()
    try:
        code, records = attempt(state, 2)
        zero = events(records, "restart_from_zero")
        expect("empty volume", code == 0 and len(zero) == 1 and not events(records, "resume"),
               f"restart_from_zero records {len(zero)}, resume records {len(events(records, 'resume'))}")
    finally:
        shutil.rmtree(state, ignore_errors=True)

    print(f"{len(FAILURES)} failed" if FAILURES else "all cases passed")
    return 1 if FAILURES else 0


if __name__ == "__main__":
    sys.exit(main())
