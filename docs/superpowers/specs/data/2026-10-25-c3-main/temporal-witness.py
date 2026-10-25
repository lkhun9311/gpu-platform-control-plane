"""Temporal witnesses on archived cells: hold-cap admissions against the previous admission's release, and fixed
spacing between every consecutive pair of contender admissions, whatever the reason label.
Run from the repository root: python3 docs/superpowers/specs/data/2026-10-25-c3-main/temporal-witness.py <m5c-run directory>...
"""
import sys, os
sys.path.insert(0, "hack/prospective-pilot")
import pilot_report as pr


def admitted(d, tag):
    rows = {r.get("requestId"): r.get("tenant") for r in pr.jsonl(os.path.join(d, "raw-%s.jsonl" % tag))}
    out = []
    for rid, e in pr.gateway_records(os.path.join(d, "gateway-record-%s.jsonl" % tag)).items():
        x = e.get("done") or {}
        if rows.get(rid) == pr.CONTENDER and x.get("decision") == "admit":
            out.append(x)
    return sorted(out, key=lambda x: x["decidedUnixNanos"])


for d in sys.argv[1:]:
    for arm, rep in pr.cells(d):
        tag = "%s-%d" % (arm, rep)
        if arm.startswith("hold-cap"):
            adm = admitted(d, tag)
            gaps, no_release, lead = [], 0, []
            for a, b in zip(adm, adm[1:]):
                rel = a.get("releasedUnixNanos")
                if not rel:
                    no_release += 1
                    continue
                gaps.append((b["decidedUnixNanos"] - rel) / 1e6)
                if a.get("firstContentUnixNanos"):
                    lead.append((a["firstContentUnixNanos"] - rel) / 1e6)
            early = sum(1 for g in gaps if g < 0)
            print("%s %s hold-cap: %d admissions, min gap after release %.3f ms, %d before it, %d without a release; first content less release %.3f to %.3f ms" % (
                d.split("/")[1], tag, len(adm), min(gaps), early, no_release, min(lead), max(lead)))
        if arm.startswith("fixed"):
            sp = float(arm.split("-")[1]) * 1000
            adm = admitted(d, tag)
            dev = [(b["decidedUnixNanos"] - a["decidedUnixNanos"]) / 1e6 - sp for a, b in zip(adm, adm[1:])]
            print("%s %s fixed %.0f ms: %d admissions, least gap less spacing %.3f ms, %d under -1 ms" % (
                d.split("/")[1], tag, sp, len(adm), min(dev), sum(1 for x in dev if x < -1)))
