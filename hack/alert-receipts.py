#!/usr/bin/env python3
"""Count the alerts an Alertmanager webhook sink received with a given name, status and labels.

    alert-receipts.py SINK_JSONL ALERTNAME STATUS [LABEL=VALUE ...]

The sink writes one JSON object per webhook body, {"received_at", "path", "payload"}; other lines are skipped.
Labels are matched exactly, so GPUFaultSignalPresent with field=ecc_dbe never counts an Xid notification: the two
share an alert name, and counting by name alone let a late or repeated Xid notification stand in for an ECC one.
"""

import json
import sys


def count(lines, name, status, want):
    n = 0
    for line in lines:
        line = line.strip()
        if not line.startswith("{"):
            continue
        body = json.loads(line)["payload"]
        for a in body.get("alerts", []):
            labels = a["labels"]
            if labels.get("alertname") != name or a["status"] != status:
                continue
            if all(labels.get(k) == v for k, v in want.items()):
                n += 1
    return n


def main(argv):
    if len(argv) < 4:
        sys.exit("usage: alert-receipts.py SINK_JSONL ALERTNAME STATUS [LABEL=VALUE ...]")
    want = {}
    for pair in argv[4:]:
        k, sep, v = pair.partition("=")
        if not sep or not k:
            sys.exit(f"not LABEL=VALUE: {pair!r}")
        want[k] = v
    with open(argv[1]) as f:
        print(count(f, argv[2], argv[3], want))


if __name__ == "__main__":
    main(sys.argv)
