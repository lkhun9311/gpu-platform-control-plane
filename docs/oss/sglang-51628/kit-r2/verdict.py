#!/usr/bin/env python3
"""The verdict of the SGLang #51628 kit r2, from the records run.sh and measure.sh leave in OUT.

  verdict.py <OUT>

It writes OUT/verdict.json and prints the verdict in plain words.
The question is whether a Mamba2 kernel compiles after the NemotronH server reports ready, how long it takes, and what it costs the first burst's TTFT.

  GATE FAILED     the server did not start with prefill CUDA graph off, so the run does not test the reporter's path (exit 4)
  REPRODUCED      at least one Mamba2 kernel compiled after ready in the MAIN arm (exit 0)
  NOT REPRODUCED  every record is present and no Mamba2 kernel compiled after ready in the MAIN arm (exit 0)
  INCOMPLETE      a record or a field is missing, or the records disagree (exit 3)

Kernels that are not Mamba2 kernels are listed apart and never decide the verdict; run 1's verdict counted them, which this one does not.
The first-burst TTFT hit is MAIN's first burst against CONTROL's, the same traffic on a server that ran SGLang's prefill warmup.
It is its own line, and says INCOMPLETE when CONTROL did not run or is missing data, rather than taking a default.
"""

import json
import math
import os
import re
import sys

# The Mamba2 mixer's compute kernels at SGLang 03fde9cc (python/sglang/kernels/ops/mamba): the chunked scan, its state and cumsum,
# the state passing and the chunk bmm, the decode state update, and the causal conv1d.
MAMBA2_KERNELS = frozenset(
    {
        "_chunk_scan_fwd_kernel",
        "_chunk_state_fwd_kernel",
        "_chunk_cumsum_fwd_kernel",
        "_chunk_state_varlen_kernel",
        "_state_passing_fwd_kernel",
        "_bmm_chunk_fwd_kernel",
        "_selective_scan_update_kernel",
        "_causal_conv1d_fwd_kernel",
        "_causal_conv1d_update_kernel",
    }
)
MAMBA_MODULE_PREFIX = "sglang.kernels.ops.mamba"
HEADLINE_KERNEL = "_chunk_scan_fwd_kernel"
# measure.sh's bursts, held equal here, so a record from a different traffic plan is refused.
BURSTS = (
    "warmup:32:64:42 c1-r1:1:4:101 c1-r2:1:4:102 c1-r3:1:4:103 c16-r1:16:32:161 c16-r2:16:32:162 c16-r3:16:32:163 "
    "c128-r1:128:128:1281 c128-r2:128:128:1282 c128-r3:128:128:1283"
)
FIRST_BURST = "warmup"
GATE_RE = re.compile(r"Disable (?:target |draft )?prefill CUDA graph")
CAPTURE_RE = re.compile(r"Capture .*prefill CUDA graph begin")
WARN_RE = re.compile(r"Triton kernel '([^']+)' took ([0-9.]+) s to compile after serving started")
# SGLang prints the duration with two decimals.
WARN_TOLERANCE_S = 0.0051


def expected_bursts():
    out = []
    for spec in BURSTS.split():
        label, conc, n, seed = spec.split(":")
        out.append({"label": label, "concurrency": int(conc), "prompts": int(n), "seed": int(seed)})
    return out


def read_text(path):
    try:
        with open(path, errors="replace") as f:
            return f.read()
    except OSError:
        return None


def read_kv(path):
    text = read_text(path)
    if text is None:
        return None
    kv = {}
    for line in text.splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            kv[k] = v
    return kv


def number(value):
    try:
        x = float(value)
    except (TypeError, ValueError):
        return None
    return x if math.isfinite(x) else None


def read_jsonl(path):
    """The records and the count of lines that are not JSON objects, or None when the file is missing."""
    text = read_text(path)
    if text is None:
        return None, 0
    records, bad = [], 0
    for line in text.splitlines():
        if not line.strip():
            continue
        try:
            r = json.loads(line)
        except ValueError:
            bad += 1
            continue
        if isinstance(r, dict):
            records.append(r)
        else:
            bad += 1
    return records, bad


def classify(name, module):
    """mamba2 for the Mamba2 mixer's kernels, mamba_aux for other kernels of SGLang's mamba package, other for the rest."""
    if name in MAMBA2_KERNELS:
        return "mamba2"
    if isinstance(module, str) and module.startswith(MAMBA_MODULE_PREFIX):
        return "mamba_aux"
    return "other"


def gate_from_log(text):
    """pass with the disabling line, or fail with why; a log that holds a prefill capture fails even beside a disabling line."""
    capture = next((ln for ln in text.splitlines() if CAPTURE_RE.search(ln)), None)
    gate = next((ln for ln in text.splitlines() if GATE_RE.search(ln)), None)
    if capture is not None:
        return "fail", f"the server captured a prefill CUDA graph: {capture.strip()}"
    if gate is None:
        return "fail", "no line says prefill CUDA graph was disabled"
    return "pass", gate.strip()


def sglang_warnings(text):
    return [(m.group(1), float(m.group(2))) for m in WARN_RE.finditer(text)]


def unmatched_warnings(warnings, compiles):
    """SGLang's warning lines that no fresh compile record matches by name and duration, each record used once."""
    pool = [c for c in compiles if not c["cache_hit"]]
    missing = []
    for name, secs in warnings:
        hit = next((c for c in pool if c["name"] == name and abs(c["seconds"] - secs) <= WARN_TOLERANCE_S), None)
        if hit is None:
            missing.append((name, secs))
        else:
            pool.remove(hit)
    return missing


def phase_of(t, ready, bursts):
    """Where a compilation that ended at t falls: startup, a burst's label, or the gap it fell in."""
    if t < ready:
        return "startup"
    timed = [b for b in bursts if b.get("start") is not None]
    for b in timed:
        if b["start"] <= t <= b["end"]:
            return b["label"]
    before = [b for b in timed if b["end"] < t]
    after = [b for b in timed if b["start"] > t]
    if not before:
        return f"after ready, before {after[0]['label']}" if after else "after ready"
    if not after:
        return f"after {before[-1]['label']}"
    return f"between {before[-1]['label']} and {after[0]['label']}"


def read_bursts(arm_dir, missing):
    """The burst rows in plan order, each with its timing and its client result, and a reason in missing for every gap."""
    rows = {}
    text = read_text(os.path.join(arm_dir, "bursts.tsv"))
    if text is None:
        missing.append("bursts.tsv is missing")
        text = ""
    for line in text.splitlines()[1:]:
        f = line.split("\t")
        if len(f) == 7:
            rows[f[0]] = f
    out = []
    for e in expected_bursts():
        b = dict(e, start=None, end=None, rc=None, result=None)
        out.append(b)
        f = rows.get(e["label"])
        if f is None:
            missing.append(f"{e['label']}: no row in bursts.tsv")
            continue
        if f[1:4] != [str(e["concurrency"]), str(e["prompts"]), str(e["seed"])]:
            missing.append(f"{e['label']}: its row is concurrency {f[1]}, {f[2]} prompts, seed {f[3]}, not the plan's")
            continue
        if f[6] == "skipped-time":
            missing.append(f"{e['label']}: skipped, the time ran out")
            continue
        start, end = number(f[4]), number(f[5])
        if start is None or end is None or end < start:
            missing.append(f"{e['label']}: no start and end times")
            continue
        b["start"], b["end"], b["rc"] = start, end, f[6]
        if f[6] != "0":
            missing.append(f"{e['label']}: the client exited {f[6]}")
        results, bad = read_jsonl(os.path.join(arm_dir, "bursts", f"{e['label']}.jsonl"))
        if not results:
            missing.append(f"{e['label']}: the client wrote no result")
            continue
        r = results[-1]
        ttfts = r.get("ttfts")
        errors = r.get("errors") or []
        stats = {k: number(r.get(k)) for k in ("mean_ttft_ms", "median_ttft_ms", "p99_ttft_ms")}
        if r.get("completed") != e["prompts"] or not isinstance(ttfts, list) or len(ttfts) != e["prompts"]:
            missing.append(f"{e['label']}: {r.get('completed')} of {e['prompts']} requests completed")
            continue
        if any(errors):
            missing.append(f"{e['label']}: a request returned an error")
            continue
        if None in stats.values():
            missing.append(f"{e['label']}: the result has no TTFT statistics")
            continue
        b["result"] = stats
    return out


def arm_report(arm_dir, name):
    """One arm's records, checked; status is GATE FAILED, INCOMPLETE or COMPLETE, with the reasons for anything missing."""
    rep = {"arm": name, "missing": []}
    missing = rep["missing"]
    kv = read_kv(os.path.join(arm_dir, "arm.txt"))
    log = read_text(os.path.join(arm_dir, "server.log"))
    if kv is None or log is None:
        missing.append("arm.txt or server.log is missing")
        rep["status"] = "INCOMPLETE"
        return rep
    ready = number(kv.get("ready_epoch"))
    if ready is None:
        missing.append("the server never reported ready")
        rep["status"] = "INCOMPLETE"
        return rep
    rep["ready_epoch"] = ready
    gate, why = gate_from_log(log)
    rep["gate"], rep["gate_line"] = gate, why
    if kv.get("gate") != gate:
        missing.append(f"arm.txt says the gate was {kv.get('gate')}, the server log says {gate}")
    if gate == "fail" and not missing:
        rep["status"] = "GATE FAILED"
        return rep
    if kv.get("triton_cache_entries_at_start") != "0":
        missing.append(f"the Triton cache held {kv.get('triton_cache_entries_at_start')} entries at the start, not 0")

    records, bad = read_jsonl(os.path.join(arm_dir, "compiles.jsonl"))
    if records is None:
        missing.append("compiles.jsonl is missing")
        records = []
    if bad:
        missing.append(f"compiles.jsonl has {bad} line(s) that are not JSON objects")
    if not any(r.get("event") == "install" and r.get("installed") is True for r in records):
        missing.append("no server process recorded the compile hook as installed")
    errs = [r for r in records if r.get("event") == "listener_error"]
    if errs:
        missing.append(f"the compile hook failed {len(errs)} time(s) inside the listener")
    compiles = []
    for r in records:
        if r.get("event") != "compile":
            continue
        t, us = number(r.get("t")), number(r.get("total_us"))
        if t is None or us is None or not isinstance(r.get("name"), str) or not isinstance(r.get("cache_hit"), bool):
            missing.append("a compile record lacks its time, duration, name or cache flag")
            continue
        compiles.append(
            {"name": r["name"], "module": r.get("module"), "t": t, "seconds": us / 1e6, "cache_hit": r["cache_hit"], "pid": r.get("pid")}
        )
    # The hook is shown live in the server only by compilations it saw there before ready.
    if not any(c["t"] < ready for c in compiles):
        missing.append("no compilation was recorded before ready, so the hook was not shown live in the server")
    lost = unmatched_warnings(sglang_warnings(log), compiles)
    if lost:
        missing.append("SGLang logged compile(s) the hook did not record: " + ", ".join(f"{n} {s:.2f} s" for n, s in lost))

    bursts = read_bursts(arm_dir, missing)
    rep["bursts"] = [{k: b[k] for k in ("label", "concurrency", "prompts", "seed", "start", "end", "rc", "result")} for b in bursts]
    after = []
    for c in sorted(compiles, key=lambda c: c["t"]):
        if c["cache_hit"] or c["t"] < ready:
            continue
        after.append(dict(c, family=classify(c["name"], c["module"]), phase=phase_of(c["t"], ready, bursts), after_ready_s=c["t"] - ready))
    rep["compiles_after_ready"] = after
    rep["compiles_before_ready"] = sum(1 for c in compiles if c["t"] < ready and not c["cache_hit"])
    rep["mamba2_before_ready"] = sorted({c["name"] for c in compiles if c["t"] < ready and classify(c["name"], c["module"]) == "mamba2"})
    rep["status"] = "INCOMPLETE" if missing else "COMPLETE"
    return rep


def ttft_hit(main, control, control_skipped):
    """MAIN's first-burst TTFT against CONTROL's, or INCOMPLETE with why."""
    if control is None:
        return {"status": "INCOMPLETE", "why": f"the CONTROL arm did not run: {control_skipped or 'no reason was recorded'}"}
    if control["status"] != "COMPLETE":
        return {"status": "INCOMPLETE", "why": f"the CONTROL arm is {control['status']}: " + "; ".join(control["missing"])}
    m = next(b for b in main["bursts"] if b["label"] == FIRST_BURST)["result"]
    c = next(b for b in control["bursts"] if b["label"] == FIRST_BURST)["result"]
    out = {k: m[k] - c[k] for k in ("mean_ttft_ms", "median_ttft_ms", "p99_ttft_ms")}
    out["main"], out["control"] = m, c
    late = [x["name"] for x in control["compiles_after_ready"] if x["family"] == "mamba2"]
    if late:
        out["status"] = "NOT ISOLATED"
        out["why"] = "CONTROL also compiled Mamba2 kernels after ready (" + ", ".join(sorted(set(late))) + "), so the difference is not the compile alone"
    else:
        out["status"] = "MEASURED"
    return out


def describe_compiles(rows):
    return [f"  {r['name']} {r['seconds']:.2f} s in {r['phase']} ({r['after_ready_s']:.1f} s after ready)" for r in rows]


def judge(out_dir):
    """The verdict dictionary and the exit code."""
    v = {"missing": []}
    c = os.path.join(out_dir, "c")
    if os.path.exists(os.path.join(out_dir, "STOPPED")):
        v["missing"].append("run.sh stopped: " + (read_text(os.path.join(out_dir, "STOPPED")) or "").strip())
    mkv = read_kv(os.path.join(c, "measure.txt"))
    if mkv is None:
        v["missing"].append("measure.txt is missing")
        mkv = {}
    v["sglang_build_commit"] = mkv.get("sglang_build_commit")
    v["gpu"] = mkv.get("gpu_name")
    v["model"] = f"{mkv.get('model_repo')}@{mkv.get('model_revision')}"
    if mkv and mkv.get("bursts") != BURSTS:
        v["missing"].append("measure.sh ran a different burst plan from the one this verdict reads")
    # The positive control, re-read from its own record rather than from measure's summary.
    probe, _ = read_jsonl(os.path.join(c, "probe-compiles.jsonl"))
    fresh = {r.get("name") for r in (probe or []) if r.get("event") == "compile" and r.get("cache_hit") is False}
    if mkv.get("probe_hook") != "ok" or not {"_sgl51628_probe_a", "_sgl51628_probe_b"} <= fresh:
        v["missing"].append("the compile hook's positive control did not record both probe kernels")
    if mkv.get("stopped"):
        v["missing"].append(f"measure.sh stopped at the {mkv['stopped']} step")

    main = arm_report(os.path.join(c, "main"), "main") if not v["missing"] else None
    v["main"] = main
    if main is not None and main["status"] == "GATE FAILED":
        v["verdict"] = "GATE FAILED"
        v["say"] = f"GATE FAILED: {main['gate_line']}. The run stopped before traffic, as the spec asks."
        return v, 4
    if main is None or main["status"] != "COMPLETE":
        v["verdict"] = "INCOMPLETE"
        if main is not None:
            v["missing"].extend(f"main: {m}" for m in main["missing"])
        v["say"] = "INCOMPLETE: " + "; ".join(v["missing"])
        return v, 3

    control = None
    if os.path.isdir(os.path.join(c, "control")):
        control = arm_report(os.path.join(c, "control"), "control")
    v["control"] = control
    v["control_skipped"] = mkv.get("control_skipped")
    v["ttft_hit"] = ttft_hit(main, control, mkv.get("control_skipped"))

    mamba = [r for r in main["compiles_after_ready"] if r["family"] == "mamba2"]
    head = [r for r in mamba if r["name"] == HEADLINE_KERNEL]
    v["mamba2_after_ready"] = mamba
    v["headline"] = {"kernel": HEADLINE_KERNEL, "compiles": len(head), "seconds": sum(r["seconds"] for r in head),
                     "phases": sorted({r["phase"] for r in head})}
    if mamba:
        v["verdict"] = "REPRODUCED"
        v["say"] = (f"REPRODUCED: {len(mamba)} Mamba2 kernel compile(s) after ready, {sum(r['seconds'] for r in mamba):.2f} s in all; "
                    f"{HEADLINE_KERNEL} compiled {len(head)} time(s), {v['headline']['seconds']:.2f} s.")
    else:
        v["verdict"] = "NOT REPRODUCED"
        v["say"] = "NOT REPRODUCED: no Mamba2 kernel compiled after the server reported ready."
    return v, 0


def render(v):
    lines = [f"VERDICT: {v['verdict']}", v["say"]]
    main = v.get("main")
    if main and main.get("gate_line"):
        lines.append(f"GATE: {main['gate']}: {main['gate_line']}")
    if v["verdict"] in ("REPRODUCED", "NOT REPRODUCED"):
        lines.append(f"MAMBA2 KERNELS AFTER READY (main): {len(v['mamba2_after_ready'])}")
        lines += describe_compiles(v["mamba2_after_ready"])
        others = [r for r in main["compiles_after_ready"] if r["family"] != "mamba2"]
        lines.append(f"OTHER KERNELS AFTER READY (main, not part of the verdict): {len(others)}")
        lines += describe_compiles(others)
        lines.append("MAMBA2 KERNELS COMPILED BEFORE READY (main): " + (", ".join(main["mamba2_before_ready"]) or "none"))
        lines.append("TTFT ms per burst (main): label mean median p99")
        for b in main["bursts"]:
            r = b["result"]
            lines.append(f"  {b['label']} {r['mean_ttft_ms']:.1f} {r['median_ttft_ms']:.1f} {r['p99_ttft_ms']:.1f}")
        h = v["ttft_hit"]
        if h["status"] == "INCOMPLETE":
            lines.append(f"FIRST-BURST TTFT HIT: INCOMPLETE: {h['why']}")
        else:
            lines.append(f"FIRST-BURST TTFT HIT: {h['status']}: mean {h['mean_ttft_ms']:+.1f} ms, median {h['median_ttft_ms']:+.1f} ms, "
                         f"p99 {h['p99_ttft_ms']:+.1f} ms (main {h['main']['mean_ttft_ms']:.1f} against control {h['control']['mean_ttft_ms']:.1f} mean)")
            if h.get("why"):
                lines.append(f"  {h['why']}")
        ctl = v.get("control")
        if ctl is None:
            lines.append(f"CONTROL: not run: {v.get('control_skipped') or 'no reason was recorded'}")
        elif ctl["status"] != "COMPLETE":
            lines.append(f"CONTROL: {ctl['status']}: " + "; ".join(ctl["missing"]))
        else:
            cm = [r for r in ctl["compiles_after_ready"] if r["family"] == "mamba2"]
            lines.append(f"CONTROL: {len(cm)} Mamba2 kernel compile(s) after ready with --warmups prefill_shapes")
            lines += describe_compiles(cm)
    return "\n".join(lines)


def main(argv):
    if len(argv) != 2 or not os.path.isdir(argv[1]):
        print("usage: verdict.py <OUT>", file=sys.stderr)
        return 2
    v, rc = judge(argv[1])
    with open(os.path.join(argv[1], "verdict.json"), "w") as f:
        json.dump(v, f, indent=1, sort_keys=True)
    print(render(v))
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv))
