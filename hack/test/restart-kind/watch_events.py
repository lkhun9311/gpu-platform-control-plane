"""Records one resource's history in a namespace, as a list and then a watch from that list's resourceVersion, every
record carrying the resourceVersion it was observed at, until killed.

    python3 hack/test/restart-kind/watch_events.py CONTEXT NAME API_PATH OUT.jsonl

NAME labels the records; API_PATH is the namespaced collection, such as /api/v1/namespaces/train-a/pods.
hack/restart-lifecycle-kind.sh runs one per resource so that check_lifecycle.py can replay what existed when each case
was submitted; a sampler polling every few seconds could miss an object that lived between two samples.

The watch starts from the list's resourceVersion and, when it ends or a line arrives cut short, resumes from the last
resourceVersion it delivered, so no change between the list and the watch, or between two watches, goes unseen (codex
reviews of b6051665 and 6ea63fee).
Bookmarks are kept, because a bookmark at or past a submission's resourceVersion is what shows the stream had caught
up to that submission.
Only when a resume is refused as too old is the resource listed again, written as a GAP; the checker never reads
anything across a GAP as continuous.
"""

from __future__ import annotations

import datetime
import json
import subprocess
import sys
import time


def now() -> str:
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def main(argv: list[str]) -> int:
    ctx, name, path, out_path = argv[1:5]
    kubectl = ["kubectl", "--context", ctx, "--request-timeout=0"]
    with open(out_path, "a", buffering=1) as out:
        def write(record: dict) -> None:
            out.write(json.dumps({"received": now(), "res": name, **record}) + "\n")

        rv = None
        while True:
            if rv is None:
                listed = subprocess.run(kubectl + ["get", "--raw", path], capture_output=True, text=True, timeout=60)
                if listed.returncode != 0:
                    write({"type": "LIST-FAILED", "stderr": listed.stderr[:300]})
                    time.sleep(1)
                    continue
                body = json.loads(listed.stdout)
                rv = body["metadata"]["resourceVersion"]
                write({"type": "LISTED", "rv": rv, "names": [i["metadata"]["name"] for i in body.get("items", [])]})
            write({"type": "WATCH-START", "rv": rv})
            proc = subprocess.Popen(kubectl + ["get", "--raw", f"{path}?watch=1&allowWatchBookmarks=true&resourceVersion={rv}"],
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            gone = False
            for line in iter(proc.stdout.readline, ""):
                if not line.strip():
                    continue
                try:
                    event = json.loads(line)
                except ValueError:
                    # A line cut short by a closed connection: resumed from the last whole event's resourceVersion.
                    write({"type": "WATCH-INTERRUPTED", "rv": rv, "partial": line[:120]})
                    break
                obj = event.get("object") or {}
                meta = obj.get("metadata") or {}
                if event.get("type") == "ERROR":
                    # 410 Gone: the resume point has been compacted away, so only a new list can say what exists.
                    gone = obj.get("code") == 410
                    write({"type": "WATCH-ERROR", "rv": rv, "code": obj.get("code"), "message": str(obj.get("message"))[:200]})
                    break
                rv = meta.get("resourceVersion") or rv
                if event.get("type") == "BOOKMARK":
                    write({"type": "BOOKMARK", "rv": rv})
                    continue
                write({"type": event.get("type"), "rv": rv, "name": meta.get("name"), "uid": meta.get("uid"),
                       "deleting": "deletionTimestamp" in meta, "finalizers": meta.get("finalizers"),
                       "labels": meta.get("labels"), "phase": (obj.get("status") or {}).get("phase")})
            proc.kill()
            proc.wait()
            write({"type": "WATCH-END", "rv": rv, "exit": proc.returncode, "stderr": (proc.stderr.read() or "")[:300]})
            if gone:
                write({"type": "GAP", "rv": rv})
                rv = None


if __name__ == "__main__":
    sys.exit(main(sys.argv))
