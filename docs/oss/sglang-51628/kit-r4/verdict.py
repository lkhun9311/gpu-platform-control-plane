#!/usr/bin/env python3
"""The verdict of the SGLang #51628 kit r4, from the records run.sh and measure.sh leave in OUT.

  verdict.py <OUT>

It writes OUT/verdict.json and prints the verdict in plain words.
The question: with prewarm.patch on SGLang cb337923 (FIX), do fewer Mamba2 kernels compile after the NemotronH server is ready than without it (BASE)?

These rules were written before any r4 run.

  IMPROVED   both arms ran, both gates passed, FIX's unit tests passed (3 passed),
             and FIX's Mamba2 compiles after ready are clearly fewer than BASE's (exit 0).
             "Clearly fewer" is fixed here: FIX's count is at most half of BASE's, and at least CLEAR_MIN_DROP fewer.
  NO CHANGE  both arms ran and both gates passed, and the rule above does not hold:
             the compiles are not clearly fewer, or the tests did not pass (exit 0). The reason is printed.
  NOT RUN    an arm's gate failed (exit 4): BASE or FIX did not log
               "Disable prefill CUDA graph because some layers do not apply Standard GQA", or captured a prefill graph,
             or FIX did not log "Prewarmed the Mamba2 prefill scan for N layer geometries in X s.".
             Also NOT RUN (exit 3) when the comparison is not the one specified, which is never read as NO CHANGE:
             a source tree that is not cb337923 (BASE) or cb337923 plus prewarm.patch (FIX) by commit, tree hash and numstat,
             before or after its arm; a patch whose sha256 is not the pinned one; an arm that ran another tree's kernels;
             BASE logging the prewarm line; the two arms on different TreeCores; or a record that is missing or disagrees.

The decode numbers (c16 ITL median and output tokens/s per run) and the startup times are data beside the verdict, not conditions of it.
Mamba2 compiles are counted as r2 counted them: compile records that are not cache hits, ending after ready, of the Mamba2 kernels below.
"""

import json
import math
import os
import re
import sys

SGLANG_SHA = "cb337923d576f48a4accba439af9cfbc9b720a2c"
BASE_TREE = "55785ea97d04f50423b5297f78d2292fff321a53"
FIX_TREE = "dfdd29ffd25da3b19d3d4cfb6a366418d1ae9b0b"
PATCH_SHA256 = "6aa4b47ca4aa314d0cae6d35e8894df0caa1e7565b403f028eda50a7d94624f9"
FIX_NUMSTAT = (
    "43\t0\tpython/sglang/srt/layers/attention/hybrid_linear_attn_backend.py\n"
    "79\t0\tpython/sglang/srt/layers/attention/mamba/mamba.py\n"
    "8\t1\tpython/sglang/srt/model_executor/runner/base_runner.py\n"
    "158\t0\ttest/registered/unit/layers/test_mamba2_prefill_prewarm.py"
)
# The rule's thresholds: at most half, and at least this many fewer.
CLEAR_RATIO = 0.5
CLEAR_MIN_DROP = 5
EXPECTED_TESTS = 3
# r2's Mamba2 kernel set, unchanged at cb337923 (python/sglang/kernels/ops/mamba).
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
BURSTS = "warmup:32:64:42 c16-r1:16:32:161 c16-r2:16:32:162 c16-r3:16:32:163"
FIRST_BURST = "warmup"
STEADY_BURSTS = ("c16-r1", "c16-r2", "c16-r3")
GATE_LINE = "Disable prefill CUDA graph because some layers do not apply Standard GQA"
CAPTURE_RE = re.compile(r"Capture .*prefill CUDA graph begin")
PREWARM_RE = re.compile(r"Prewarmed the Mamba2 prefill scan for (\d+) layer geometries in ([0-9.]+) s\.")
WARN_RE = re.compile(r"Triton kernel '([^']+)' took ([0-9.]+) s to compile after serving started")
TREECORE_RE = re.compile(r"Tree Core: (\w+)")
TREECORE_CLASS = {"rust": "RustUnifiedTreeCore", "python": "UnifiedTreeCore"}
# SGLang prints the duration with two decimals.
WARN_TOLERANCE_S = 0.0051
ARMS = ("base", "fix")


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


def gate_from_log(text, need_prewarm):
    """pass with the lines found, or fail with why; a prefill capture fails even beside the disabling line."""
    lines = text.splitlines()
    capture = next((ln for ln in lines if CAPTURE_RE.search(ln)), None)
    gate = next((ln for ln in lines if GATE_LINE in ln), None)
    prewarm = next((ln for ln in lines if PREWARM_RE.search(ln)), None)
    if capture is not None:
        return "fail", f"the server captured a prefill CUDA graph: {capture.strip()}"
    if gate is None:
        return "fail", f"no line says '{GATE_LINE}'"
    if need_prewarm and prewarm is None:
        return "fail", "no line says 'Prewarmed the Mamba2 prefill scan for N layer geometries in X s.'"
    return "pass", gate.strip()


def prewarm_of(text):
    """(layer geometries, seconds) from the prewarm line, or None."""
    m = PREWARM_RE.search(text)
    return (int(m.group(1)), float(m.group(2))) if m else None


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


def compile_records(records, missing, need_file):
    """The compile records with their fields checked; a record without its fields is named in missing."""
    out = []
    for r in records:
        if r.get("event") != "compile":
            continue
        t, us = number(r.get("t")), number(r.get("total_us"))
        if t is None or us is None or not isinstance(r.get("name"), str) or not isinstance(r.get("cache_hit"), bool):
            missing.append("a compile record lacks its time, duration, name or cache flag")
            continue
        if need_file and not isinstance(r.get("file"), str):
            missing.append(f"the compile record of {r['name']} lacks its source file")
            continue
        out.append({"name": r["name"], "module": r.get("module"), "file": r.get("file"), "t": t, "seconds": us / 1e6,
                    "cache_hit": r["cache_hit"], "pid": r.get("pid")})
    return out


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
        results, _ = read_jsonl(os.path.join(arm_dir, "bursts", f"{e['label']}.jsonl"))
        if not results:
            missing.append(f"{e['label']}: the client wrote no result")
            continue
        r = results[-1]
        ttfts = r.get("ttfts")
        errors = r.get("errors") or []
        keys = ("mean_ttft_ms", "median_ttft_ms", "p99_ttft_ms", "median_itl_ms", "output_throughput")
        stats = {k: number(r.get(k)) for k in keys}
        if r.get("completed") != e["prompts"] or not isinstance(ttfts, list) or len(ttfts) != e["prompts"]:
            missing.append(f"{e['label']}: {r.get('completed')} of {e['prompts']} requests completed")
            continue
        if any(errors):
            missing.append(f"{e['label']}: a request returned an error")
            continue
        if None in stats.values():
            missing.append(f"{e['label']}: the result lacks " + ", ".join(k for k, v in stats.items() if v is None))
            continue
        stats["n"] = r["completed"]
        b["result"] = stats
    return out


def late_mamba2(compiles, ready, bursts):
    """The Mamba2 compiles that ended after ready, in time order, each with its burst or gap."""
    out = []
    for c in sorted(compiles, key=lambda c: c["t"]):
        if c["cache_hit"] or c["t"] < ready or classify(c["name"], c["module"]) != "mamba2":
            continue
        out.append(dict(c, phase=phase_of(c["t"], ready, bursts), after_ready_s=c["t"] - ready))
    return out


def per_kernel_per_burst(rows):
    """{kernel: {phase: [count, seconds]}} for the late compiles."""
    out = {}
    for r in rows:
        cell = out.setdefault(r["name"], {}).setdefault(r["phase"], [0, 0.0])
        cell[0] += 1
        cell[1] += r["seconds"]
    return out


def tests_of(mkv):
    """pass when pytest exited 0 and its summary is exactly EXPECTED_TESTS passed with nothing failed, errored or skipped."""
    summary = mkv.get("pytest_summary") or ""
    m = re.search(r"\b(\d+) passed\b", summary)
    bad = re.search(r"\b(failed|error|errors|skipped|xfailed|xpassed|deselected)\b", summary)
    ok = mkv.get("pytest_rc") == "0" and m is not None and int(m.group(1)) == EXPECTED_TESTS and bad is None
    return {"status": "pass" if ok else "fail", "rc": mkv.get("pytest_rc"), "summary": summary or "none"}


def pins(settings):
    """The commit and trees the records must show: the real ones, or the offline test's, which the records then say."""
    if settings.get("offline_test", "").startswith("1"):
        return {"sha": settings.get("offline_sglang_sha"), "base": settings.get("offline_base_tree"),
                "fix": settings.get("offline_fix_tree"), "offline": True}
    return {"sha": SGLANG_SHA, "base": BASE_TREE, "fix": FIX_TREE, "offline": False}


def read_source(path):
    """The source record: its key values, and the numstat between its markers."""
    text = read_text(path)
    if text is None:
        return None
    kv, num, inside = {}, [], False
    for line in text.splitlines():
        if line == "numstat_begin":
            inside = True
        elif line == "numstat_end":
            inside = False
        elif inside:
            num.append(line)
        elif "=" in line:
            k, v = line.split("=", 1)
            kv[k] = v
    kv["numstat"] = "\n".join(num)
    return kv


def source_problems(out_dir, arm, pin):
    """Why ARM's tree is not the pinned one, before or after its arm; empty when it is."""
    want_tree = pin[arm]
    want_num = "" if arm == "base" else FIX_NUMSTAT
    problems = []
    for when in ("before", "after"):
        s = read_source(os.path.join(out_dir, f"source-{arm}-{when}.txt"))
        if s is None:
            problems.append(f"{arm}: source-{arm}-{when}.txt is missing")
            continue
        if s.get("commit") != pin["sha"]:
            problems.append(f"{arm} {when}: commit {s.get('commit')}, not {pin['sha']}")
        if s.get("tree") != want_tree:
            problems.append(f"{arm} {when}: tree {s.get('tree')}, not {want_tree}")
        if s.get("worktree_matches_index") != "yes":
            problems.append(f"{arm} {when}: the working tree differs from its index")
        if when == "before" and s.get("untracked") != "0":
            problems.append(f"{arm} before: {s.get('untracked')} untracked file(s)")
        if s["numstat"] != want_num:
            problems.append(f"{arm} {when}: its diff against the commit is not the pinned one")
    return problems


def arm_report(arm_dir, name, treecore):
    """One arm's records, checked: status COMPLETE, GATE FAILED or NOT RUN, with every reason, and the measurements."""
    rep = {"arm": name, "missing": []}
    missing = rep["missing"]
    mkv = read_kv(os.path.join(arm_dir, "measure.txt"))
    if mkv is None:
        missing.append("measure.txt is missing (the arm did not run)")
        rep["status"] = "NOT RUN"
        return rep
    rep["measure"] = {k: mkv.get(k) for k in ("sglang_dir", "src", "sglang_version", "pytest_rc", "pytest_summary")}
    if mkv.get("stopped"):
        missing.append(f"measure.sh stopped at the {mkv['stopped']} step")
    src_pkg = os.path.normpath(os.path.join(mkv.get("src") or "/nonexistent", "python", "sglang"))
    if mkv.get("install") != "ok" or os.path.normpath(mkv.get("sglang_dir") or "") != src_pkg:
        missing.append(f"python did not import sglang from {src_pkg} (it read {mkv.get('sglang_dir')})")
    probe, _ = read_jsonl(os.path.join(arm_dir, "probe-compiles.jsonl"))
    fresh = {r.get("name") for r in (probe or []) if r.get("event") == "compile" and r.get("cache_hit") is False}
    if mkv.get("probe_hook") != "ok" or not {"_sgl51628_probe_a", "_sgl51628_probe_b"} <= fresh:
        missing.append("the compile hook's positive control did not record both probe kernels")
    if mkv.get("model") != "ok":
        missing.append("the model check did not pass")
    if mkv.get("bursts") != BURSTS:
        missing.append("measure.sh ran a different burst plan from the one this verdict reads")
    if name == "fix":
        rep["tests"] = tests_of(mkv)
    akv = read_kv(os.path.join(arm_dir, "arm.txt"))
    log = read_text(os.path.join(arm_dir, "server.log"))
    if missing or akv is None or log is None:
        if akv is None or log is None:
            missing.append("arm.txt or server.log is missing")
        rep["status"] = "NOT RUN"
        return rep
    gate, why = gate_from_log(log, need_prewarm=(name == "fix"))
    rep["gate"], rep["gate_line"] = gate, why
    if akv.get("gate") != gate:
        missing.append(f"arm.txt says the gate was {akv.get('gate')}, the server log says {gate}")
    if gate == "fail" and not missing:
        rep["status"] = "GATE FAILED"
        return rep
    rep["prewarm"] = prewarm_of(log)
    if name == "base" and rep["prewarm"] is not None:
        missing.append("BASE logged the prewarm line, so it did not run the unpatched tree")
    ready, launch = number(akv.get("ready_epoch")), number(akv.get("launch_epoch"))
    if ready is None or launch is None:
        missing.append("the server never reported ready, or its launch time is missing")
        rep["status"] = "NOT RUN"
        return rep
    rep["launch_to_ready_s"] = ready - launch
    tc = TREECORE_RE.search(log)
    rep["treecore"] = tc.group(1) if tc else None
    if rep["treecore"] != TREECORE_CLASS.get(treecore):
        missing.append(f"the server ran TreeCore {rep['treecore']}, not the prep's {TREECORE_CLASS.get(treecore)}")
    if akv.get("triton_cache_entries_at_start") != "0":
        missing.append(f"the Triton cache held {akv.get('triton_cache_entries_at_start')} entries at the start, not 0")

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
    compiles = compile_records(records, missing, need_file=True)
    # Every Mamba2 kernel must come from this arm's tree: the image's own 03fde9cc copy would compile from /sgl-workspace.
    foreign = sorted({c["file"] for c in compiles if classify(c["name"], c["module"]) == "mamba2"
                      and not os.path.normpath(c["file"]).startswith(src_pkg + os.sep)})
    if foreign:
        missing.append("Mamba2 kernels compiled from outside the arm's tree: " + ", ".join(foreign))
    if not any(c["t"] < ready for c in compiles):
        missing.append("no compilation was recorded before ready, so the hook was not shown live in the server")
    lost = unmatched_warnings(sglang_warnings(log), compiles)
    if lost:
        missing.append("SGLang logged compile(s) the hook did not record: " + ", ".join(f"{n} {s:.2f} s" for n, s in lost))

    bursts = read_bursts(arm_dir, missing)
    rep["bursts"] = [{k: b[k] for k in ("label", "concurrency", "prompts", "seed", "start", "end", "rc", "result")} for b in bursts]
    late = late_mamba2(compiles, ready, bursts)
    rep["mamba2_after_ready"] = late
    rep["mamba2_after_ready_count"] = len(late)
    rep["mamba2_after_ready_s"] = sum(r["seconds"] for r in late)
    rep["mamba2_per_kernel_per_burst"] = per_kernel_per_burst(late)
    rep["mamba2_before_ready_count"] = sum(1 for c in compiles if c["t"] < ready and not c["cache_hit"]
                                           and classify(c["name"], c["module"]) == "mamba2")
    rep["status"] = "NOT RUN" if missing else "COMPLETE"
    return rep


def judge(out_dir):
    """The verdict dictionary and the exit code."""
    v = {"missing": [], "rule": {"clear_ratio": CLEAR_RATIO, "clear_min_drop": CLEAR_MIN_DROP, "tests": EXPECTED_TESTS}}
    c = os.path.join(out_dir, "c")
    settings = read_kv(os.path.join(out_dir, "settings.txt")) or {}
    pin = pins(settings)
    v["pins"] = pin
    if os.path.exists(os.path.join(out_dir, "STOPPED")):
        v["missing"].append("run.sh stopped: " + (read_text(os.path.join(out_dir, "STOPPED")) or "").strip())
    patch = read_kv(os.path.join(out_dir, "patch.txt")) or {}
    if patch.get("patch_sha256") != PATCH_SHA256:
        v["missing"].append(f"prewarm.patch was {patch.get('patch_sha256')}, not {PATCH_SHA256}")
    for arm in ARMS:
        v["missing"].extend(source_problems(out_dir, arm, pin))
    prep = read_kv(os.path.join(c, "prep", "measure.txt")) or {}
    treecore = prep.get("treecore")
    v["treecore"] = {"chosen": treecore, "fallback": prep.get("treecore_fallback")}
    if prep.get("prep") != "ok" or treecore not in TREECORE_CLASS:
        v["missing"].append("the prep container did not finish or chose no TreeCore")
    reports = {arm: arm_report(os.path.join(c, arm), arm, treecore) for arm in ARMS}
    v.update(reports)

    gate_failed = [a for a in ARMS if reports[a]["status"] == "GATE FAILED"]
    not_run = [a for a in ARMS if reports[a]["status"] == "NOT RUN"]
    for a in not_run:
        v["missing"].extend(f"{a}: {m}" for m in reports[a]["missing"])
    if gate_failed:
        v["verdict"] = "NOT RUN"
        v["say"] = "NOT RUN: the gate failed in " + ", ".join(f"{a.upper()} ({reports[a]['gate_line']})" for a in gate_failed) + "."
        # A gate failure is reported first, but a tree off its pins beside it is the likelier cause, so it is named too.
        if v["missing"]:
            v["say"] += " Also: " + "; ".join(v["missing"])
        return v, 4
    if v["missing"]:
        v["verdict"] = "NOT RUN"
        v["say"] = "NOT RUN: " + "; ".join(v["missing"])
        return v, 3

    b, f = reports["base"]["mamba2_after_ready_count"], reports["fix"]["mamba2_after_ready_count"]
    clearly = f <= CLEAR_RATIO * b and b - f >= CLEAR_MIN_DROP
    tests = reports["fix"]["tests"]
    v["clearly_fewer"] = clearly
    if clearly and tests["status"] == "pass":
        v["verdict"] = "IMPROVED"
        v["say"] = f"IMPROVED: Mamba2 compiles after ready fell from {b} (BASE) to {f} (FIX); the {EXPECTED_TESTS} unit tests passed."
        return v, 0
    why = []
    if not clearly:
        why.append(f"FIX's {f} Mamba2 compiles after ready against BASE's {b} are not clearly fewer "
                   f"(at most {CLEAR_RATIO:g} of BASE and at least {CLEAR_MIN_DROP} fewer)")
    if tests["status"] != "pass":
        why.append(f"the unit tests did not pass ({tests['summary']}, exit {tests['rc']})")
    v["verdict"] = "NO CHANGE"
    v["say"] = "NO CHANGE: " + "; ".join(why) + "."
    return v, 0


def render(v):
    lines = [f"VERDICT: {v['verdict']}", v["say"]]
    if v["pins"].get("offline"):
        lines.append("OFFLINE TEST: the source pins are the offline test's fake tree, not cb337923")
    tc = v["treecore"]
    lines.append(f"TREECORE: {tc['chosen']}" + (f" (fallback: {tc['fallback']}; r2 ran the Rust TreeCore)" if tc.get("fallback") else ""))
    for arm in ARMS:
        r = v.get(arm) or {}
        if r.get("gate_line"):
            lines.append(f"GATE {arm.upper()}: {r['gate']}: {r['gate_line']}")
    if "tests" in (v.get("fix") or {}):
        t = v["fix"]["tests"]
        lines.append(f"TESTS FIX: {t['status']}: {t['summary']} (exit {t['rc']})")
    if v["verdict"] not in ("IMPROVED", "NO CHANGE"):
        return "\n".join(lines)
    base, fix = v["base"], v["fix"]
    lines.append("MEASURE: base fix")
    lines.append(f"  launch to ready s: {base['launch_to_ready_s']:.1f} {fix['launch_to_ready_s']:.1f}")
    lines.append(f"  prewarm (FIX): {fix['prewarm'][0]} layer geometries in {fix['prewarm'][1]:.1f} s")
    lines.append(f"  Mamba2 compiles before ready: {base['mamba2_before_ready_count']} {fix['mamba2_before_ready_count']}")
    lines.append(f"  Mamba2 compiles after ready: {base['mamba2_after_ready_count']} {fix['mamba2_after_ready_count']}")
    lines.append(f"  Mamba2 compile s after ready: {base['mamba2_after_ready_s']:.2f} {fix['mamba2_after_ready_s']:.2f}")
    for arm in ARMS:
        lines.append(f"MAMBA2 AFTER READY {arm.upper()}: kernel burst count seconds")
        for k, phases in sorted(v[arm]["mamba2_per_kernel_per_burst"].items()):
            for ph, (n, s) in phases.items():
                lines.append(f"  {k} {ph} {n} {s:.2f}")
    for arm in ARMS:
        w = next(b for b in v[arm]["bursts"] if b["label"] == FIRST_BURST)["result"]
        lines.append(f"WARMUP TTFT {arm.upper()}: mean {w['mean_ttft_ms']:.1f} ms, p99 {w['p99_ttft_ms']:.1f} ms, n {w['n']}")
    lines.append("STEADY c16 (data, not a verdict condition): run base_itl_median_ms fix_itl_median_ms base_out_tok_s fix_out_tok_s")
    for label in STEADY_BURSTS:
        rb = next(b for b in base["bursts"] if b["label"] == label)["result"]
        rf = next(b for b in fix["bursts"] if b["label"] == label)["result"]
        lines.append(f"  {label} {rb['median_itl_ms']:.3f} {rf['median_itl_ms']:.3f} {rb['output_throughput']:.1f} {rf['output_throughput']:.1f}")
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
