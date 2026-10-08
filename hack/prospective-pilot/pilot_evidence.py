"""Checks on one pilot cell's evidence, run by hack/m5c-matrix.sh as soon as the cell is captured.

    python3 pilot_evidence.py terminal STEP_LOG
        exit 0 when the step log ends in a complete terminal record, 1 when the last one is incomplete,
        2 when there is none
    python3 pilot_evidence.py priority STEP_LOG RAW_ROWS
        exit 0 when every request the scheduler received carries its tier's priority, 1 on a violation,
        2 when the step log cannot witness it

docs/superpowers/specs/2026-10-08-measuring-prospective-admission-design.md, "The measurement pilot": a premium
request must reach the scheduler at priority 0 and a standard one at 1, or the apparatus is not the registered one
and the pilot stops; a step log that cannot show it makes the arm ineligible, which is not the same outcome.
"""

import json
import sys

PREMIUM_TENANT = "premium-1"
PRIORITY = {"premium-1": 0, "standard-noisy": 1}
# Requests the capture itself sends, which belong to no arm.
OWN_PREFIXES = ("fence-", "calib-")


def records(path):
    out = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line:
                out.append(json.loads(line))
    return out


def terminal(step_log):
    """(complete, why): whether the log ends in a terminal record that says everything produced was written."""
    recs = records(step_log)
    terms = [r for r in recs if r.get("ev") == "terminal"]
    if not terms:
        return None, "the step log has no terminal record"
    t = terms[-1]
    if t["seq_written"] != t["seq_produced"] or t["buffered"] != 0:
        return False, "the last terminal record says %d of %d records written, %d buffered" % (
            t["seq_written"], t["seq_produced"], t["buffered"])
    data = [r for r in recs if "seq" in r]
    seqs = [r["seq"] for r in data]
    if seqs != list(range(1, len(seqs) + 1)):
        return False, "the step log's sequence numbers are not 1 to %d without a gap" % len(seqs)
    if seqs and seqs[-1] != t["seq_produced"]:
        return False, "the log holds records up to %d and the terminal record says %d were produced" % (
            seqs[-1], t["seq_produced"])
    if any(r.get("ev") == "overflow" for r in recs):
        return False, "the step logger overflowed its buffer"
    return True, ""


def client_tiers(raw_rows):
    """The tenant each client request ID belongs to."""
    out = {}
    for r in records(raw_rows):
        rid = r.get("requestId")
        if rid:
            out[rid] = r["tenant"]
    return out


def match_client(engine_id, ids):
    """The client ID an engine request ID carries, or None.

    vLLM may add its own text around the ID the client sent; how is checked on the real engine by the CPU rehearsal.
    A client ID matches where it appears whole: the character after it is not a digit, so "...-1" does not match
    inside "...-10". An engine ID that still matches two client IDs is refused rather than guessed between.
    """
    hits = []
    for c in ids:
        at = engine_id.find(c)
        while at >= 0:
            end = at + len(c)
            if end == len(engine_id) or not engine_id[end].isdigit():
                hits.append(c)
                break
            at = engine_id.find(c, at + 1)
    if len(hits) > 1:
        raise ValueError("engine request %s carries more than one client ID: %s" % (engine_id, sorted(hits)[:2]))
    return hits[0] if hits else None


def priority(step_log, raw_rows):
    """(ok, why): ok is True when every scheduled client request had its tier's priority, None when unknown."""
    complete, why = terminal(step_log)
    if not complete:
        return None, "the step log cannot witness the priorities: " + why
    tenants = client_tiers(raw_rows)
    bad = []
    for r in records(step_log):
        if r.get("ev") != "add":
            continue
        rid = r["id"]
        if any(p in rid for p in OWN_PREFIXES):
            continue
        client = match_client(rid, tenants)
        if client is None:
            return False, "the scheduler received %s, which no client row sent" % rid
        want = PRIORITY.get(tenants[client])
        if r.get("priority") != want:
            bad.append("%s (%s) at priority %r, registered %r" % (client, tenants[client], r.get("priority"), want))
    if bad:
        return False, "%d request(s) reached the scheduler at the wrong priority, e.g. %s" % (len(bad), bad[0])
    return True, ""


def main(argv):
    if len(argv) >= 3 and argv[1] == "terminal":
        ok, why = terminal(argv[2])
        if ok:
            return 0
        print(why)
        return 2 if ok is None else 1
    if len(argv) >= 4 and argv[1] == "priority":
        ok, why = priority(argv[2], argv[3])
        if ok:
            return 0
        print(why)
        return 2 if ok is None else 1
    print(__doc__)
    return 64


if __name__ == "__main__":
    sys.exit(main(sys.argv))
