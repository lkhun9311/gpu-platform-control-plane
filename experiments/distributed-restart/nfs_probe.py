"""Helpers the STORAGE=nfs kind cases run in Pods of their own, beside the ranks, on the same NFS claims.

    python nfs_probe.py watch <job>     looks up every shard name of attempt 1's checkpoints as soon as each checkpoint
                                        directory appears, and records every change in what it sees
    python nfs_probe.py keep <job>      records its mounts and then only holds them
    python nfs_probe.py warm <job>      reads both shards of the checkpoint LATEST names, so this node caches them
    python nfs_probe.py corrupt <job>   changes 64 bytes in the middle of rank 1's shard of that checkpoint, size kept
    python nfs_probe.py spoil <job> <how>
                                        makes that checkpoint's manifest malformed, or name another directory, or puts a
                                        directory where rank 1's shard was: how is malformed, otherdir or unreadable

Each prints one JSON record per line on stdout; the harness collects them with kubectl logs or kubectl exec.

watch and keep run as a Pod per worker from before attempt 1 starts, and that matters as much as what they do.
The kubelet mounts a claim for each Pod, but on one node every mount of one server with the same options shares one
client cache, which the kernel drops with the last of them; a helper holding the claim keeps that cache alive from
attempt 1 into attempt 2, whose ranks then mount into it.

watch is the visibility provocation.
A Linux NFS client that looks a name up and finds it absent caches that answer, and keeps giving it for as long as it
trusts its cached attributes of the directory, even after another client has renamed a file to that name.
A rank never looks a shard's name up before the shard exists, so the trainer alone does not create that state; this does.
It finds the checkpoint directories through a second claim mounted with no cache at all, which the kernel keeps apart
from the watched claim's: listing through the watched claim could refresh the very attributes being tested, and listing
through a caching claim could keep missing the job's directories for as long as that claim caches their absence.
"""

from __future__ import annotations

import datetime
import hashlib
import json
import os
import re
import sys
import time

CKPT_DIR_RE = re.compile(r"^(\d{8})-([0-9a-f]{32})$")
NODE = os.environ.get("NODE_NAME", "")
# Where the job's claim and the uncached discovery claim are mounted.
WATCH = "/watch"
LIST = "/list"


def emit(event: str, **fields: object) -> None:
    record = {"ts": datetime.datetime.now(datetime.timezone.utc).isoformat(), "node": NODE, "event": event}
    record.update(fields)
    sys.stdout.write(json.dumps(record) + "\n")
    sys.stdout.flush()


def mount_of(path: str) -> dict:
    """The mount at path from /proc/self/mountinfo, with the device number that identifies its client cache."""
    with open("/proc/self/mountinfo") as handle:
        for line in handle:
            fields = line.split()
            if fields[4] == path:
                sep = fields.index("-")
                return {"point": path, "fstype": fields[sep + 1], "source": fields[sep + 2],
                        "super_options": fields[sep + 3], "dev": os.stat(path).st_dev}
    return {}


def watch(job: str) -> None:
    emit("probe_start", watch=mount_of(WATCH), list=mount_of(LIST))
    seen: dict[tuple[str, int], bool] = {}
    while True:
        try:
            names = os.listdir(os.path.join(LIST, job, "a1"))
        except FileNotFoundError:
            names = []
        for name in sorted(names):
            if not CKPT_DIR_RE.match(name):
                continue
            for rank in (0, 1):
                exists = os.path.exists(os.path.join(WATCH, job, "a1", name, f"rank-{rank}.pt"))
                if seen.get((name, rank)) != exists:
                    seen[(name, rank)] = exists
                    emit("probe", dir=f"a1/{name}", rank=rank, exists=exists)
        time.sleep(0.1)


def keep(job: str) -> None:
    emit("keep_start", job=job, watch=mount_of(WATCH))
    while True:
        time.sleep(3600)


def latest(job: str) -> str:
    with open(os.path.join(WATCH, job, "LATEST")) as handle:
        return handle.read().strip()


def digest(path: str) -> tuple[int, str]:
    with open(path, "rb") as handle:
        data = handle.read()
    return len(data), hashlib.sha256(data).hexdigest()


def warm(job: str) -> None:
    rel = latest(job)
    for rank in (0, 1):
        size, sha = digest(os.path.join(WATCH, job, rel, f"rank-{rank}.pt"))
        emit("warm", file=f"{rel}/rank-{rank}.pt", size=size, sha256=sha, watch=mount_of(WATCH))


def corrupt(job: str) -> None:
    rel = latest(job)
    path = os.path.join(WATCH, job, rel, "rank-1.pt")
    size, sha = digest(path)
    emit("corrupt", when="before", file=f"{rel}/rank-1.pt", size=size, sha256=sha)
    # Same size, other bytes: a check of the size alone would pass this shard, and only the hash can refuse it.
    with open(path, "r+b") as handle:
        handle.seek(size // 2)
        chunk = handle.read(64)
        handle.seek(size // 2)
        handle.write(bytes(b ^ 0xFF for b in chunk))
        handle.flush()
        os.fsync(handle.fileno())
    size, sha = digest(path)
    emit("corrupt", when="after", file=f"{rel}/rank-1.pt", size=size, sha256=sha, watch=mount_of(WATCH))


def spoil(job: str, how: str) -> None:
    """Spoils the checkpoint LATEST names as check_protocol.py's fixture of that name does, through this NFS client.

    Through a client and not below the server: a rename made in the export directory behind NFS-Ganesha's back left its
    cache naming the shard as before, and a rank read the published bytes under a name the export no longer gave them
    (the first kind run of these cases, 2026-11-04).
    """
    rel = latest(job)
    ckpt = os.path.join(WATCH, job, rel)
    size, sha = digest(os.path.join(ckpt, "MANIFEST"))
    emit("spoil", when="before", how=how, dir=rel, manifest_sha256=sha, rank1_dir=os.path.isdir(os.path.join(ckpt, "rank-1.pt")))
    if how in ("malformed", "otherdir"):
        with open(os.path.join(ckpt, "MANIFEST")) as handle:
            manifest = json.load(handle)
        # A manifest that parses but is not one; and one naming a directory other than the one holding it.
        if how == "malformed":
            manifest["shards"] = [{}, {}]
        else:
            manifest["uuid"] = "0" * 32
        tmp = os.path.join(ckpt, f"MANIFEST.spoil-{os.getpid()}")
        with open(tmp, "w") as handle:
            handle.write(json.dumps(manifest, sort_keys=True))
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp, os.path.join(ckpt, "MANIFEST"))
    elif how == "unreadable":
        # Kept beside it rather than removed, so the shard as published stays on the storage for the record.
        os.rename(os.path.join(ckpt, "rank-1.pt"), os.path.join(ckpt, "rank-1.pt.published"))
        os.mkdir(os.path.join(ckpt, "rank-1.pt"))
    else:
        raise SystemExit(f"spoil how={how!r} is not malformed, otherdir or unreadable")
    size, sha = digest(os.path.join(ckpt, "MANIFEST"))
    emit("spoil", when="after", how=how, dir=rel, manifest_sha256=sha, rank1_dir=os.path.isdir(os.path.join(ckpt, "rank-1.pt")),
         watch=mount_of(WATCH))


if __name__ == "__main__":
    if sys.argv[1] == "spoil":
        spoil(sys.argv[2], sys.argv[3])
    else:
        {"watch": watch, "keep": keep, "warm": warm, "corrupt": corrupt}[sys.argv[1]](sys.argv[2])
