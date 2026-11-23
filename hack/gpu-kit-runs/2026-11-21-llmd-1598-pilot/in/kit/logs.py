"""Readers for the EPP's JSON log and Envoy's JSON access log, keyed by x-request-id.

Field names are the ones the pinned EPP (llm-d-router 733d0e4e) and Envoy 1.40.2 emit; a line that does not parse is
counted, never guessed at.
"""

import datetime
import json


def epp_time(ts):
    """The EPP's RFC 3339 timestamps carry nanoseconds, which datetime cannot parse, so the fraction is read separately."""
    base, _, frac = ts.rstrip("Z").partition(".")
    t = datetime.datetime.strptime(base, "%Y-%m-%dT%H:%M:%S").replace(tzinfo=datetime.timezone.utc).timestamp()
    return t + (float("0." + frac) if frac else 0.0)


def read_epp(path, names):
    """Per request: the router's matched 64-token blocks per endpoint, its scores, and its pick and PreRequest times.

    `names` maps the EPP's endpoint ids ("default/vllm-0") to the host:port Envoy reports as the upstream.
    """
    match, scores, picked, prereq, bad = {}, {}, {}, {}, 0
    with open(path, errors="replace") as f:
        for ln in f:
            if not ln.startswith("{"):
                continue
            try:
                d = json.loads(ln)
            except ValueError:
                bad += 1
                continue
            rid = d.get("x-request-id")
            if not rid:
                continue
            body = d.get("body")
            if body == "Prefix cache match":
                match[rid] = {names.get(k, k): v for k, v in (d.get("matchedBlocks") or {}).items()}
            elif body == "Calculated score":
                ep = d.get("endpoint") or {}
                key = names.get(f"{ep.get('namespace', 'default')}/{ep.get('name')}", ep.get("name"))
                scores.setdefault(rid, {}).setdefault(d.get("plugin"), {})[key] = d.get("score")
            elif body == "Completed running picker plugin successfully" and rid not in picked:
                picked[rid] = epp_time(d["timestamp"])
            elif body == "Running PreRequest plugin" and rid not in prereq:
                prereq[rid] = epp_time(d["timestamp"])
    return {"match": match, "scores": scores, "picked": picked, "prerequest": prereq, "unparsable": bad}


def read_access(path):
    out, bad = {}, 0
    try:
        f = open(path)
    except FileNotFoundError:
        return out, 0
    with f:
        for ln in f:
            try:
                d = json.loads(ln)
            except ValueError:
                bad += 1
                continue
            if d.get("rid") and d["rid"] != "-":
                out[d["rid"]] = d
    return out, bad
