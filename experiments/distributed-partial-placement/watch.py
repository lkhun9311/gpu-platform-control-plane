"""Records every change to one namespace's Workloads, MLTrainingJobs and Pods, stamped as it arrives.

    python3 watch.py <context> <namespace> <kind> <until epoch> <out>

A Workload's conditions say only what holds now, so a poll can miss a reservation released and taken again between
two samples; a watch delivers every write. Each line is one event: when it arrived, its type, and the object.
The stream is restarted if kubectl exits early, and each restart is recorded, so a gap in the record is visible.
"""

import datetime
import json
import subprocess
import sys
import time


def now() -> str:
    return datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="milliseconds")


def watch(context, ns, kind, until, f):
    while time.time() < until:
        f.write(json.dumps({"arrived": now(), "kind": kind, "type": "WATCH_STARTED"}) + "\n")
        f.flush()
        proc = subprocess.Popen(
            ["kubectl", "--context", context, "-n", ns, "get", kind, "--watch", "--output-watch-events", "-o", "json"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        decoder, buf = json.JSONDecoder(), ""
        try:
            while time.time() < until:
                chunk = proc.stdout.readline()
                if not chunk:
                    break
                buf += chunk
                # kubectl prints each event as an indented JSON document; decode whole ones as they complete.
                while buf.strip():
                    try:
                        event, end = decoder.raw_decode(buf.lstrip())
                    except json.JSONDecodeError:
                        break
                    buf = buf.lstrip()[end:]
                    f.write(json.dumps({"arrived": now(), "kind": kind, "type": event.get("type"),
                                        "object": event.get("object")}, sort_keys=True) + "\n")
                    f.flush()
        finally:
            proc.kill()
            err = proc.stderr.read().strip()[:500]
        f.write(json.dumps({"arrived": now(), "kind": kind, "type": "WATCH_ENDED", "error": err}) + "\n")
        f.flush()
        time.sleep(0.5)


def main(argv):
    context, ns, kind, until, path = argv
    until = float(until)
    with open(path, "a") as f:
        watch(context, ns, kind, until, f)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
