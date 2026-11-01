"""Records one resource's watch events in a namespace, each with the moment it was received, until killed.

    python3 hack/test/restart-kind/watch_events.py CONTEXT NAMESPACE RESOURCE OUT.jsonl

hack/restart-lifecycle-kind.sh runs one per resource so that check_lifecycle.py can replay what existed when each case
was submitted; a sampler polling every few seconds could miss an object that lived between two samples.
A watch the API server ends is restarted, and each start is written as WATCH-START, after which kubectl lists every
existing object again as ADDED; the replay clears that resource's objects at each start, so an object deleted while no
watch ran is not carried as alive.
After each start a separate list is taken and written as LISTED with every name in it, so the replay knows the
resource's whole state again from that moment; between a WATCH-START and its LISTED the state is unknown, which is a
failure of the check, never an absence (codex review of the checker's first form).
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
    ctx, ns, res, path = argv[1:5]
    with open(path, "a", buffering=1) as out:
        while True:
            out.write(json.dumps({"received": now(), "res": res, "type": "WATCH-START"}) + "\n")
            proc = subprocess.Popen(["kubectl", "--context", ctx, "-n", ns, "get", res, "--watch", "--output-watch-events",
                                     "-o", "json"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            listed = subprocess.run(["kubectl", "--context", ctx, "-n", ns, "get", res, "-o", "json"],
                                    capture_output=True, text=True, timeout=60)
            if listed.returncode == 0:
                names = [i["metadata"]["name"] for i in json.loads(listed.stdout).get("items", [])]
                out.write(json.dumps({"received": now(), "res": res, "type": "LISTED", "names": names}) + "\n")
            else:
                out.write(json.dumps({"received": now(), "res": res, "type": "LIST-FAILED",
                                      "stderr": listed.stderr[:300]}) + "\n")
            buf, dec = "", json.JSONDecoder()
            for chunk in iter(lambda: proc.stdout.readline(), ""):
                buf += chunk
                while True:
                    stripped = buf.lstrip()
                    if not stripped:
                        buf = ""
                        break
                    try:
                        event, end = dec.raw_decode(stripped)
                    except ValueError:
                        break
                    buf = stripped[end:]
                    obj = event.get("object") or {}
                    meta = obj.get("metadata") or {}
                    out.write(json.dumps({
                        "received": now(), "res": res, "type": event.get("type"), "name": meta.get("name"),
                        "uid": meta.get("uid"), "deleting": "deletionTimestamp" in meta,
                        "finalizers": meta.get("finalizers"), "labels": meta.get("labels"),
                        "phase": (obj.get("status") or {}).get("phase"),
                    }) + "\n")
            proc.wait()
            out.write(json.dumps({"received": now(), "res": res, "type": "WATCH-END", "exit": proc.returncode,
                                  "stderr": (proc.stderr.read() or "")[:300]}) + "\n")
            time.sleep(1)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
