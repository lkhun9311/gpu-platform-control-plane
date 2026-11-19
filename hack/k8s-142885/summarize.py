#!/usr/bin/env python3
# Prints one table row per sample of every case under the evidence directory.
# Values are copied from samples.jsonl as recorded; nothing is rounded except the MiB column next to the bytes.
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])


def mib(v):
    return f"{int(v) / 2**20:.1f}Mi" if v.isdigit() else v


print("| case | t | spec limits.swap / requests.memory | containerStatuses limits.swap | memory.swap.max | memory.swap.current | memory.max | oom_kill | PodResizeInProgress |")
print("|---|---|---|---|---|---|---|---|---|")
for case in sorted(p for p in root.iterdir() if (p / "samples.jsonl").is_file()):
    for line in (case / "samples.jsonl").read_text().splitlines():
        r = json.loads(line)
        cond = r["resize_conditions"].get("PodResizeInProgress")
        cond_s = "absent" if cond is None else f'{cond["status"]} {cond["reason"] or ""}'.strip()
        cs_swap = ((r["containerStatuses.resources"] or {}).get("limits") or {}).get("swap", "-")
        spec = f'{(r["spec_limits"] or {}).get("swap", "-")} / {r["spec_requests"].get("memory")}'
        print(
            f'| {case.name} | {r["t"]} | {spec} | {cs_swap} | {mib(r["ctr.memory.swap.max"])} | '
            f'{mib(r["ctr.memory.swap.current"])} ({r["ctr.memory.swap.current"]}) | {mib(r["ctr.memory.max"])} | '
            f'{r["ctr.oom_kill"][0].split()[-1] if r["ctr.oom_kill"] else "?"} | {cond_s} |'
        )
