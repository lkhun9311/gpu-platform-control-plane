#!/usr/bin/env python3
"""Print the results table from each run's summary.json, one row per run, in the order given.

The "fit" and "max-num-seqs" columns come from the per-pod load analyze.py rebuilds from EPP log timestamps.
They describe that rebuild, not the producer's counters or the engine's observed running sequences.
Percentiles are nearest-rank over successful (200) requests only.
"""
import json
import sys
from pathlib import Path


def fmt(v, nd=0):
    return "-" if v is None else f"{v:.{nd}f}"


print("| run | arm | requests | 200 | 429 | 503 | other | released then rejected | of which a pod fit at release (rebuilt) | of which no pod fit at release (rebuilt) | of which a pod had EPP-counted requests < max-num-seqs | goodput req/s | TTFT p50/p99 ms | FC queue p50/p99 ms | routed over detector limit | routed over max-num-seqs | peak pod requests / tokens |")
print("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
for run in sys.argv[1:]:
    s = json.loads((Path(run) / "summary.json").read_text())
    st = s["status"]
    other = sum(v for k, v in st.items() if k not in ("200", "429", "503"))
    arm, seed = s["run"][17:].rsplit("-s", 1)
    print(f"| {s['run'][:16]} s{seed} | {arm} | {s['requests']} | {st.get('200', 0)} | {st.get('429', 0)} | "
          f"{st.get('503', 0)} | {other} | {s['release_then_reject']} | {s['rtr_fit_at_release_gone_at_reject']} | "
          f"{s['rtr_no_fit_even_at_release']} | {s['rtr_with_slot_free']} | {fmt(s['goodput_rps'], 1)} | "
          f"{fmt(s['ttft_ms_p50'])}/{fmt(s['ttft_ms_p99'])} | {fmt(s['fc_queue_ms_p50'])}/{fmt(s['fc_queue_ms_p99'])} | "
          f"{s['routed_over_detector_limit']} | {s['routed_over_engine_slots']} | {s['peak_pod_requests']} / {s['peak_pod_tokens']} |")
