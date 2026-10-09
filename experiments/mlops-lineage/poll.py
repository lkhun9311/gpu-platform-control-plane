#!/usr/bin/env python3
"""Ask a serving endpoint which model it is, at a fixed rate, until a stop file appears.

Usage: poll.py URL OUT_TSV STOP_FILE [RATE]

One row per request: seconds since start when it was sent and when its answer completed, HTTP status (0 for no
answer), and the model version answered. Readings about when a version stopped answering use the completion time:
a request sent before a rollback can still come back with the old version after it.
Open loop, one thread per request, so a slow answer cannot lower the rate and hide an outage.
"""
import json
import os
import sys
import threading
import time
import urllib.error
import urllib.request


def main():
    url, out, stop = sys.argv[1], sys.argv[2], sys.argv[3]
    rate = float(sys.argv[4]) if len(sys.argv) > 4 else 20.0
    rows, lock, threads = [], threading.Lock(), []
    start = time.monotonic()

    def one(sent):
        status, version = 0, ""
        try:
            with urllib.request.urlopen(url, timeout=5) as resp:
                status = resp.status
                version = json.loads(resp.read()).get("model_version", "")
        except urllib.error.HTTPError as err:
            status = err.code
        except Exception:
            pass
        done = time.monotonic() - start
        with lock:
            rows.append((sent, done, status, version))

    i = 0
    while not os.path.exists(stop):
        time.sleep(max(0.0, start + i / rate - time.monotonic()))
        t = threading.Thread(target=one, args=(time.monotonic() - start,))
        t.start()
        threads.append(t)
        i += 1
    for t in threads:
        t.join()
    with open(out, "w") as f:
        f.write("t_s\tdone_s\tstatus\tversion\n")
        for sent, done, status, version in sorted(rows):
            f.write(f"{sent:.3f}\t{done:.3f}\t{status}\t{version}\n")
    # The start time on the wall clock, so the runner's own event times can be placed on this file's axis.
    # Wall-clock start and end, so the runner's event times can be placed on this file's axis and the scorer can
    # check coverage against a window the rows themselves cannot shrink.
    wall_now, mono_now = time.time(), time.monotonic()
    print(json.dumps({"sent": i, "recorded": len(rows), "rate": rate,
                      "wall_start": wall_now - (mono_now - start), "wall_end": wall_now}))


if __name__ == "__main__":
    main()
