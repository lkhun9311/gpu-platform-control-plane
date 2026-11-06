#!/usr/bin/python3
"""Slurm HealthCheckProgram for the lab: drains this node when its GPU fault signal shows a fault or cannot be read.

slurmd runs it as root every HealthCheckInterval seconds, in any node state (HealthCheckNodeState=ANY in slurm.conf).
The signal is a per-node file in the shape the Kubernetes platform scrapes from dcgm-exporter: one
DCGM_FI_DEV_XID_ERRORS and one DCGM_FI_DEV_ECC_DBE_VOL_TOTAL sample per card, labelled with its UUID.
The lab has no GPUs and no exporter, so the entrypoint writes that file and the steps rewrite it to inject a fault.

The rules are the platform's (internal/gpufault/classify.go Assess): an Xid is a fault unless it is one of the
application Xids NVIDIA's device plugin ignores; a double-bit count above zero is a fault; a value that is not a whole
non-negative number, or a card without both fields, cannot be judged.

What it does about them is Slurm's own vocabulary, not the platform's:
- A fault, or a signal that cannot be judged, drains the node with a reason naming what was read.
  A check that cannot read its signal must not look healthy, and in sinfo a node this check left alone is healthy.
- It never resumes a node. A signal that reads clean again is not a repair, so returning the node is an operator's
  `scontrol update state=resume`.
- It does not overwrite a drain that is already there, so an operator's maintenance reason, or the first fault's,
  stays the one sinfo shows.
- With the word `requeue` in the policy file, a fault also requeues every running job on the node, which is what
  the platform's --gpu-fault-evict-workloads does with Kueue; a job submitted --no-requeue refuses that and keeps
  running, and the refusal is logged once, because each job is tried only once.

Exit status: 0 healthy, 1 a fault, 2 a signal that could not be judged; slurmd only logs it.
Every environment variable below exists so the host-side test can run this file without Slurm.
"""

from __future__ import annotations

import datetime
import glob
import math
import os
import re
import socket
import subprocess
import sys

SIGNAL = os.environ.get("LABGPU_SIGNAL", "/var/lib/labgpu/metrics.prom")
POLICY = os.environ.get("LABGPU_POLICY", "/var/lib/labgpu/policy")
DEVICES = os.environ.get("LABGPU_DEVICES", "/dev/labgpu*")
LOG = os.environ.get("LABGPU_LOG", "/var/log/slurm/gpuhc.log")
# While this file exists every verdict is logged, healthy ones too, so a step can show the check ran on a clean signal.
TRACE = os.environ.get("LABGPU_TRACE", "/var/lib/labgpu/trace")
# The jobs the requeue policy has already tried on this node, one id per line.
REQUEUED = os.environ.get("LABGPU_REQUEUED", "/var/lib/labgpu/requeued")
NODE = os.environ.get("LABGPU_NODE") or socket.gethostname().split(".")[0]

FIELD_XID = "DCGM_FI_DEV_XID_ERRORS"
FIELD_DBE = "DCGM_FI_DEV_ECC_DBE_VOL_TOTAL"
FIELDS = (FIELD_XID, FIELD_DBE)
# The same set as internal/gpufault/classify.go applicationXids.
APPLICATION_XIDS = {13, 31, 43, 45, 68}
SAMPLE = re.compile(r'^([A-Z_]+)\{([^}]*)\}\s+(\S+)$')
LABEL = re.compile(r'(\w+)="([^"]*)"')


class Unjudged(Exception):
    """The signal could not be read or judged; its message is the drain reason's detail."""


def log(msg: str) -> None:
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"
    try:
        with open(LOG, "a") as fh:
            fh.write(f"{stamp} {NODE} {msg}\n")
    except OSError:
        # The log is for the evidence; a full or missing log directory must not decide health.
        pass


def read_signal() -> dict[str, dict[str, int]]:
    """Every card's fault fields, by UUID; raises Unjudged for anything that would not be honest to call healthy."""
    try:
        with open(SIGNAL) as fh:
            text = fh.read()
    except OSError as exc:
        raise Unjudged(f"signal {SIGNAL} unreadable: {exc.strerror}") from exc
    cards: dict[str, dict[str, int]] = {}
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        m = SAMPLE.match(line)
        if not m:
            raise Unjudged(f"malformed line {line[:60]!r}")
        name, labels, raw = m.groups()
        if name not in FIELDS:
            continue
        uuid = dict(LABEL.findall(labels)).get("UUID", "")
        if not uuid:
            raise Unjudged(f"{name} sample names no UUID")
        try:
            value = float(raw)
        except ValueError:
            raise Unjudged(f"{uuid} {name}={raw} is not a number") from None
        # NaN and the infinities pass float() and make int() raise, which would end the check with no drain.
        if not math.isfinite(value) or value < 0 or value != int(value):
            raise Unjudged(f"{uuid} {name}={raw} is not a whole non-negative number")
        prev = cards.setdefault(uuid, {}).get(name)
        if prev is not None and prev != int(value):
            raise Unjudged(f"{uuid} carries two {name} values")
        cards[uuid][name] = int(value)
    # A card the node declares but the signal does not carry is unread, not healthy.
    declared = len(glob.glob(DEVICES))
    if len(cards) < declared:
        raise Unjudged(f"{len(cards)} card(s) in the signal, {declared} declared")
    for uuid, fields in sorted(cards.items()):
        for f in FIELDS:
            if f not in fields:
                raise Unjudged(f"{uuid} has no {f}")
    return cards


def faults(cards: dict[str, dict[str, int]]) -> list[str]:
    out = []
    for uuid, fields in sorted(cards.items()):
        xid = fields[FIELD_XID]
        if xid != 0 and xid not in APPLICATION_XIDS:
            out.append(f"{uuid} {FIELD_XID}={xid}")
        if fields[FIELD_DBE] > 0:
            out.append(f"{uuid} {FIELD_DBE}={fields[FIELD_DBE]}")
    return out


def slurm(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(list(args), capture_output=True, text=True, timeout=20)


def node_state() -> str:
    r = slurm("scontrol", "show", "node", NODE)
    m = re.search(r"\bState=(\S+)", r.stdout)
    return m.group(1) if m else ""


def drain(reason: str) -> None:
    state = node_state()
    if "DRAIN" in state:
        log(f"already {state}; reason left as it is: {reason}")
        return
    r = slurm("scontrol", "update", f"nodename={NODE}", "state=drain", f"reason={reason}")
    log(f"drain ({state}) rc={r.returncode} reason={reason} {r.stderr.strip()}")


def requeue_running() -> None:
    try:
        with open(POLICY) as fh:
            policy = fh.read().split()
    except OSError:
        policy = []
    if "requeue" not in policy:
        return
    try:
        with open(REQUEUED) as fh:
            tried = set(fh.read().split())
    except OSError:
        tried = set()
    r = slurm("squeue", "-h", "-w", NODE, "-t", "R", "-o", "%i")
    for job in r.stdout.split():
        # One attempt per job: the check runs every few seconds while the fault lasts, and a --no-requeue job refuses
        # every time, so retrying it each run only filled the log (evidence/2026-11-04/06b-gpu-health-requeue.txt).
        if job in tried:
            continue
        q = slurm("scontrol", "requeue", job)
        log(f"requeue {job} rc={q.returncode} {q.stderr.strip()}")
        with open(REQUEUED, "a") as fh:
            fh.write(job + "\n")


def main() -> int:
    try:
        found = faults(read_signal())
    except Unjudged as exc:
        drain(f"gpuhc: signal not judged: {exc}"[:200])
        return 2
    if not found:
        if os.path.exists(TRACE):
            log("healthy: every card read, no fault field set")
        return 0
    drain(("gpuhc: " + "; ".join(found))[:200])
    requeue_running()
    return 1


if __name__ == "__main__":
    sys.exit(main())
