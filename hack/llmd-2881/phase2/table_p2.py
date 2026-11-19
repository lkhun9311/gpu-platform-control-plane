#!/usr/bin/env python3
"""Print the Phase 2 comparison tables from results.json, which the harness writes when LAB2881_OUT is set.

Usage: table_p2.py results.json
"""
import json
import sys


def fmt_counts(d):
    return " ".join(f"{k}:{v}" for k, v in sorted(d.items(), key=lambda kv: int(kv[0]))) or "-"


def main():
    rows = json.load(open(sys.argv[1]))
    print("| scenario | arm | final 200 / 429 / 503 / 499 | attempts: requests | queue age p50 / max ms | "
          "overshoot max tokens / ms over | gate / filter evaluations | reserve conflicts | reservations taken / released |")
    print("|---|---|---|---|---|---|---|---|---|")
    for r in rows:
        if r["scenario"].startswith(("race", "duplicate")):
            continue
        o = r["outcomes"]
        b = r["reservation_balance"]
        age = r["queue_age_ms"]
        print(f"| {r['scenario']} | {r['arm']} | {o.get('200', 0)} / {o.get('429', 0)} / {o.get('503', 0)} / {o.get('499', 0)} | "
              f"{fmt_counts(r['attempts_per_request'])} | {age['p50']:.0f} / {age['max']:.0f} | "
              f"{r['overshoot_max']} / {r['overshoot_duration_ms']:.0f} | {r['gate_evals']} / {r['filter_evals']} | "
              f"{r['reserve_conflicts']} | {b['dispatch_reserved']} / {b['dispatch_released']} |")
    print()
    print("| scenario | arm | large: outcomes, queue age max ms | small: outcomes, queue age max ms |")
    print("|---|---|---|---|")
    for r in rows:
        if not r.get("by_size") or "large" not in r["by_size"] or "small" not in r["by_size"]:
            continue
        cells = []
        for size in ("large", "small"):
            v = r["by_size"][size]
            cells.append(f"{fmt_counts(v['outcomes'])}, {v['queue_age_ms_max']:.0f}")
        print(f"| {r['scenario']} | {r['arm']} | {cells[0]} | {cells[1]} |")
    print()
    print("| race: release-to-filter window | arm | outcome of the second request over 121 arrival offsets | worst overshoot tokens |")
    print("|---|---|---|---|")
    for r in rows:
        if r["scenario"].startswith("race"):
            print(f"| {r['scenario'].removeprefix('race-window-')} | {r['arm']} | {r['notes']} | {r['overshoot_max']} |")


if __name__ == "__main__":
    main()
