"""Records one resource's history in a namespace, as a list and then a watch from that list's resourceVersion, each
event with the moment it was received, until killed.

    python3 hack/test/restart-kind/watch_events.py CONTEXT NAME API_PATH OUT.jsonl

NAME labels the records; API_PATH is the namespaced collection, such as /api/v1/namespaces/train-a/pods.
hack/restart-lifecycle-kind.sh runs one per resource so that check_lifecycle.py can replay what existed when each case
was submitted; a sampler polling every few seconds could miss an object that lived between two samples.

The watch starts from the list's resourceVersion and, when the API server ends it, resumes from the last resourceVersion
it delivered, so no change between the list and the watch, or between two watches, goes unseen (codex review of
b6051665: two independently timed requests did not establish one history).
Only when a resume is refused as too old is the resource listed again; that is written as a GAP, which the checker reads
as not knowing what existed from the end of the previous watch to the new LISTED, never as an absence.
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
                write({"type": "LISTED", "resourceVersion": rv, "names": [i["metadata"]["name"] for i in body.get("items", [])]})
            write({"type": "WATCH-START", "resourceVersion": rv})
            proc = subprocess.Popen(kubectl + ["get", "--raw", f"{path}?watch=1&allowWatchBookmarks=true&resourceVersion={rv}"],
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            gone = False
            for line in iter(proc.stdout.readline, ""):
                if not line.strip():
                    continue
                event = json.loads(line)
                obj = event.get("object") or {}
                meta = obj.get("metadata") or {}
                if event.get("type") == "ERROR":
                    # 410 Gone: the resume point has been compacted away, so only a new list can say what exists.
                    gone = obj.get("code") == 410
                    write({"type": "WATCH-ERROR", "code": obj.get("code"), "message": str(obj.get("message"))[:200]})
                    break
                rv = meta.get("resourceVersion") or rv
                if event.get("type") == "BOOKMARK":
                    continue
                write({"type": event.get("type"), "name": meta.get("name"), "uid": meta.get("uid"),
                       "deleting": "deletionTimestamp" in meta, "finalizers": meta.get("finalizers"),
                       "labels": meta.get("labels"), "phase": (obj.get("status") or {}).get("phase")})
            proc.kill()
            proc.wait()
            write({"type": "WATCH-END", "exit": proc.returncode, "stderr": (proc.stderr.read() or "")[:300]})
            if gone:
                write({"type": "GAP"})
                rv = None


if __name__ == "__main__":
    sys.exit(main(sys.argv))
