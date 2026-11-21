#!/usr/bin/env python3
"""The verdict of the SGLang #51628 kit r3, from the records run.sh and measure.sh leave in OUT.

  verdict.py <OUT>

r3 is r2's CONTROL arm alone: the same server with --warmups prefill_shapes, the same traffic and seeds.
It asks whether SGLang's own prefill warmup moves the Mamba2 compiles that r2's MAIN arm saw after ready to before ready.
r2's MAIN arm comes from r2-reference.json beside this file, which pins r2's committed verdict.json, arm.txt and compiles.jsonl by sha256.

  WARMUP MOVES ALL   no Mamba2 kernel compiled after ready (exit 0)
  WARMUP MOVES SOME  fewer Mamba2 compiles after ready than r2's MAIN arm, with the counts per kernel (exit 0)
  NO EFFECT          as many Mamba2 compiles after ready as r2's MAIN arm, or more (exit 0)
  GATE FAILED        the server did not start with prefill CUDA graph off (exit 4)
  INCOMPLETE         a record, a field or the reference is missing, or the records disagree (exit 3)

Beside the verdict it reports, per Mamba2 kernel, the compiles before and after ready and the burst of each late one;
the first burst's TTFT against r2's; the startup time from launch to ready against r2's;
and Triton's autotune report (TRITON_PRINT_AUTOTUNING=1): per autotune, the kernel, its key, the configs benchmarked and the config chosen.
Each late compile of an autotuned kernel is classed as an autotune config or a later specialisation only where the records allow it.
"""

import ast
import json
import math
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REFERENCE = os.path.join(HERE, "r2-reference.json")
ARM = "control"
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
BURSTS = (
    "warmup:32:64:42 c1-r1:1:4:101 c1-r2:1:4:102 c1-r3:1:4:103 c16-r1:16:32:161 c16-r2:16:32:162 c16-r3:16:32:163 "
    "c128-r1:128:128:1281 c128-r2:128:128:1282 c128-r3:128:128:1283"
)
FIRST_BURST = "warmup"
GATE_RE = re.compile(r"Disable (?:target |draft )?prefill CUDA graph")
CAPTURE_RE = re.compile(r"Capture .*prefill CUDA graph begin")
WARN_RE = re.compile(r"Triton kernel '([^']+)' took ([0-9.]+) s to compile after serving started")
WARN_TOLERANCE_S = 0.0051
# Triton's autotune report, printed (without a timestamp) when TRITON_PRINT_AUTOTUNING=1.
# r2's buffered stdout spliced a log line into the middle of a config line, so a config is read only as far as it is well formed,
# and every pattern is searched for rather than anchored at the start of a line.
_CFG = r"((?:\w+: (?:-?\d+|None), )*\w+: (?:-?\d+|None))"
AT_CONFIG_RE = re.compile(r"Autotuning kernel (\S+) with config " + _CFG)
AT_HEAD_RE = re.compile(r"Triton autotuning for function (\S+),")
AT_KEY_RE = re.compile(r"with key as (\(.*\)),")
AT_DONE_RE = re.compile(r"finished after ([0-9.]+)s,")
AT_BEST_RE = re.compile(r"best config selected: " + _CFG)
# A report's four lines come from one print, but a splice can push log lines between them, so the parser looks this far.
AT_BLOCK_SPAN = 40
# Keys of a printed config that are compile options, not kernel constants.
CONFIG_OPTIONS = ("num_warps", "num_ctas", "num_stages", "maxnreg")
REF_FIELDS = ("source_verdict_sha256", "source_arm_sha256", "source_compiles_sha256", "first_burst_ttft_ms", "startup_s",
              "mamba2_after_ready", "mamba2_after_ready_total", "mamba2_before_ready", "verdict")


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
    if name in MAMBA2_KERNELS:
        return "mamba2"
    if isinstance(module, str) and module.startswith(MAMBA_MODULE_PREFIX):
        return "mamba_aux"
    return "other"


def gate_from_log(text):
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


# ---------------------------------------------------------------- Triton's autotune report
def parse_config(text):
    """'BLOCK_SIZE_M: 64, num_warps: 8, maxnreg: None' as a dict, or None when a field does not parse."""
    out = {}
    for part in text.split(","):
        if not part.strip():
            continue
        if ":" not in part:
            return None
        k, v = part.split(":", 1)
        k, v = k.strip(), v.strip()
        if v == "None":
            out[k] = None
        else:
            try:
                out[k] = int(v)
            except ValueError:
                return None
    return out or None


def parse_autotune(text):
    """Every autotune the log reports, in log order.

    Each block has the kernel, the configs benchmarked (the 'Autotuning kernel' lines since its previous block), the key, the seconds and the config chosen.
    A block whose key, time or choice is not on the lines after its header is kept with complete False.
    """
    lines = text.splitlines()
    pending = {}
    blocks = []
    for i, line in enumerate(lines):
        m = AT_CONFIG_RE.search(line)
        if m:
            pending.setdefault(m.group(1), []).append(parse_config(m.group(2)))
            continue
        m = AT_HEAD_RE.search(line)
        if not m:
            continue
        kernel = m.group(1)
        block = {"kernel": kernel, "configs": pending.pop(kernel, []), "key": None, "seconds": None, "best": None}
        for nxt in lines[i + 1 : i + 1 + AT_BLOCK_SPAN]:
            if AT_HEAD_RE.search(nxt):
                break
            if block["key"] is None and (k := AT_KEY_RE.search(nxt)):
                block["key"] = k.group(1)
            elif block["seconds"] is None and (d := AT_DONE_RE.search(nxt)):
                block["seconds"] = float(d.group(1))
            elif block["best"] is None and (b := AT_BEST_RE.search(nxt)):
                block["best"] = parse_config(b.group(1))
                break
        block["complete"] = (block["key"] is not None and block["seconds"] is not None and block["best"] is not None
                             and len(block["configs"]) > 0 and None not in block["configs"])
        blocks.append(block)
    return blocks


def _literal(text):
    try:
        return ast.literal_eval(text)
    except (ValueError, SyntaxError, TypeError, MemoryError, RecursionError):
        return None


def compile_identity(rec, params):
    """(config, specialisation) of one compile, or None when its constants or signature do not parse.

    The config is the kernel's tile constants named in its autotune report plus num_warps and num_stages.
    The specialisation is every other constant, the signature's types and the divisibility attrs.
    """
    # r2's records lack attrs, num_warps and num_stages, and without them two specialisations or two configs can look alike.
    if rec.get("attrs") is None or rec.get("num_warps") is None or rec.get("num_stages") is None:
        return None
    sig = _literal(rec.get("signature") or "")
    consts = _literal(rec.get("constants") or "")
    if not isinstance(sig, dict) or not isinstance(consts, dict):
        return None
    names = list(sig.keys())
    named = {}
    for key, value in consts.items():
        if isinstance(key, tuple) and len(key) == 1 and isinstance(key[0], int) and 0 <= key[0] < len(names):
            named[names[key[0]]] = value
        else:
            return None
    if any(p not in named for p in params):
        return None
    cfg = tuple((p, named[p]) for p in params) + (("num_warps", rec.get("num_warps")), ("num_stages", rec.get("num_stages")))
    rest = tuple(sorted((k, repr(v)) for k, v in named.items() if k not in params))
    types = tuple((k, repr(v)) for k, v in sig.items() if k not in params)
    return cfg, (rest, types, rec.get("attrs"))


def best_identity(best, params):
    return tuple((p, best.get(p)) for p in params) + (("num_warps", best.get("num_warps")), ("num_stages", best.get("num_stages")))


def classify_autotune(compiles, blocks):
    """Each compile's class, keyed by its index in compiles, and each block's link to the compiles that ran it.

    autotune-config: one of several configs compiled for one specialisation, which only an autotune does.
    post-autotune specialisation: the only config compiled for its specialisation, and one an autotune chose.
    unclassified: the records do not say, and nothing is inferred.
    no autotune report: no autotune report names the kernel, which is not read as "not autotuned".
    """
    classes = {}
    links = []
    for kernel in sorted({c["name"] for c in compiles}):
        idx = [i for i, c in enumerate(compiles) if c["name"] == kernel]
        kb = [b for b in blocks if b["kernel"] == kernel]
        if not kb:
            for i in idx:
                classes[i] = "no autotune report"
            continue
        if not all(b["complete"] for b in kb):
            for i in idx:
                classes[i] = "unclassified"
            continue
        params = sorted({k for b in kb for cfg in b["configs"] + [b["best"]] for k in cfg if k not in CONFIG_OPTIONS})
        bests = {best_identity(b["best"], params) for b in kb}
        groups = {}
        for i in idx:
            ident = compile_identity(compiles[i], params)
            if ident is None:
                classes[i] = "unclassified"
                continue
            groups.setdefault(ident[1], []).append((i, ident[0]))
        sweeps = []
        for members in groups.values():
            cfgs = {cfg for _, cfg in members}
            if len(cfgs) >= 2:
                for i, _ in members:
                    classes[i] = "autotune-config"
                sweeps.append(members)
            else:
                cls = "post-autotune specialisation" if next(iter(cfgs)) in bests else "unclassified"
                for i, _ in members:
                    classes[i] = cls
        # The n-th sweep in time is the n-th report in the log, since one process prints them in order.
        sweeps.sort(key=lambda m: min(compiles[i]["t"] for i, _ in m))
        for n, b in enumerate(kb):
            link = {"kernel": kernel, "n": n, "configs": len(b["configs"]), "key": b["key"], "seconds": b["seconds"], "best": b["best"],
                    "sweep_compiles": None, "start": None, "end": None, "linked": False}
            if n < len(sweeps):
                m = sweeps[n]
                cfgs = {cfg for _, cfg in m}
                link["sweep_compiles"] = len(m)
                link["start"] = min(compiles[i]["t"] for i, _ in m)
                link["end"] = max(compiles[i]["t"] for i, _ in m)
                link["linked"] = len(cfgs) == len(b["configs"]) and best_identity(b["best"], params) in cfgs
            links.append(link)
    return classes, links


# ---------------------------------------------------------------- the reference
def load_reference(missing):
    text = read_text(REFERENCE)
    if text is None:
        missing.append("r2-reference.json is missing beside verdict.py")
        return None
    try:
        ref = json.loads(text)
    except ValueError:
        missing.append("r2-reference.json is not JSON")
        return None
    absent = [f for f in REF_FIELDS if f not in ref]
    if absent:
        missing.append("r2-reference.json lacks " + ", ".join(absent))
        return None
    t = ref["first_burst_ttft_ms"]
    if not isinstance(t, dict) or any(number(t.get(k)) is None for k in ("mean_ttft_ms", "median_ttft_ms", "p99_ttft_ms")) or number(ref["startup_s"]) is None:
        missing.append("r2-reference.json has no first-burst TTFT or startup time")
        return None
    return ref




# ---------------------------------------------------------------- the arm
def arm_report(arm_dir):
    rep = {"arm": ARM, "missing": []}
    missing = rep["missing"]
    kv = read_kv(os.path.join(arm_dir, "arm.txt"))
    log = read_text(os.path.join(arm_dir, "server.log"))
    if kv is None or log is None:
        missing.append("arm.txt or server.log is missing")
        rep["status"] = "INCOMPLETE"
        return rep
    ready, launch = number(kv.get("ready_epoch")), number(kv.get("launch_epoch"))
    if ready is None:
        missing.append("the server never reported ready")
        rep["status"] = "INCOMPLETE"
        return rep
    if launch is None or launch > ready:
        missing.append("no launch time before ready, so the startup time is unknown")
    rep["ready_epoch"], rep["launch_epoch"] = ready, launch
    rep["startup_s"] = ready - launch if launch is not None and launch <= ready else None
    gate, why = gate_from_log(log)
    rep["gate"], rep["gate_line"] = gate, why
    if kv.get("gate") != gate:
        missing.append(f"arm.txt says the gate was {kv.get('gate')}, the server log says {gate}")
    if gate == "fail" and not missing:
        rep["status"] = "GATE FAILED"
        return rep
    if kv.get("triton_cache_entries_at_start") != "0":
        missing.append(f"the Triton cache held {kv.get('triton_cache_entries_at_start')} entries at the start, not 0")
    if "Warmup ended" not in log:
        missing.append("the server log does not say the prefill_shapes warmup ended")

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
        compiles.append(dict(r, t=t, seconds=us / 1e6))
    if not any(c["t"] < ready for c in compiles):
        missing.append("no compilation was recorded before ready, so the hook was not shown live in the server")
    lost = unmatched_warnings(sglang_warnings(log), compiles)
    if lost:
        missing.append("SGLang logged compile(s) the hook did not record: " + ", ".join(f"{n} {s:.2f} s" for n, s in lost))

    bursts = read_bursts(arm_dir, missing)
    rep["bursts"] = [{k: b[k] for k in ("label", "concurrency", "prompts", "seed", "start", "end", "rc", "result")} for b in bursts]
    fresh = sorted((c for c in compiles if not c["cache_hit"]), key=lambda c: c["t"])
    blocks = parse_autotune(log)
    classes, links = classify_autotune(fresh, blocks)
    for link in links:
        link["phase"] = phase_of(link["start"], ready, bursts) if link["start"] is not None else None
    rep["autotune"] = links
    rep["autotune_reported"] = len(blocks) > 0
    per = {}
    after = []
    for i, c in enumerate(fresh):
        fam = classify(c["name"], c.get("module"))
        if fam != "mamba2":
            continue
        k = per.setdefault(c["name"], {"before_ready": 0, "after_ready": 0, "after_by_phase": {}, "after_by_class": {}})
        if c["t"] < ready:
            k["before_ready"] += 1
            continue
        ph = phase_of(c["t"], ready, bursts)
        k["after_ready"] += 1
        k["after_by_phase"][ph] = k["after_by_phase"].get(ph, 0) + 1
        k["after_by_class"][classes[i]] = k["after_by_class"].get(classes[i], 0) + 1
        after.append({"name": c["name"], "seconds": c["seconds"], "phase": ph, "after_ready_s": c["t"] - ready, "class": classes[i]})
    rep["per_kernel"] = per
    rep["mamba2_after_ready"] = after
    rep["status"] = "INCOMPLETE" if missing else "COMPLETE"
    return rep


def judge(out_dir):
    v = {"missing": []}
    c = os.path.join(out_dir, "c")
    if os.path.exists(os.path.join(out_dir, "STOPPED")):
        v["missing"].append("run.sh stopped: " + (read_text(os.path.join(out_dir, "STOPPED")) or "").strip())
    mkv = read_kv(os.path.join(c, "measure.txt"))
    if mkv is None:
        v["missing"].append("measure.txt is missing")
        mkv = {}
    v["sglang_build_commit"] = mkv.get("sglang_build_commit")
    v["model"] = f"{mkv.get('model_repo')}@{mkv.get('model_revision')}"
    if mkv and mkv.get("bursts") != BURSTS:
        v["missing"].append("measure.sh ran a different burst plan from r2's")
    probe, _ = read_jsonl(os.path.join(c, "probe-compiles.jsonl"))
    fresh = {r.get("name") for r in (probe or []) if r.get("event") == "compile" and r.get("cache_hit") is False}
    if mkv.get("probe_hook") != "ok" or not {"_sgl51628_probe_a", "_sgl51628_probe_b"} <= fresh:
        v["missing"].append("the compile hook's positive control did not record both probe kernels")
    if mkv.get("stopped"):
        v["missing"].append(f"measure.sh stopped at the {mkv['stopped']} step")
    ref = load_reference(v["missing"])
    v["reference"] = ref

    arm = arm_report(os.path.join(c, ARM)) if not v["missing"] else None
    v["arm"] = arm
    if arm is not None and arm["status"] == "GATE FAILED":
        v["verdict"] = "GATE FAILED"
        v["say"] = f"GATE FAILED: {arm['gate_line']}. The run stopped before traffic."
        return v, 4
    if arm is None or arm["status"] != "COMPLETE":
        if arm is not None:
            v["missing"].extend(f"{ARM}: {m}" for m in arm["missing"])
        v["verdict"] = "INCOMPLETE"
        v["say"] = "INCOMPLETE: " + "; ".join(v["missing"])
        return v, 3

    n_after = len(arm["mamba2_after_ready"])
    r2_total = ref["mamba2_after_ready_total"]
    w = next(b for b in arm["bursts"] if b["label"] == FIRST_BURST)["result"]
    rw = ref["first_burst_ttft_ms"]
    v["first_burst_ttft"] = {"r3": w, "r2_main": rw, "delta_ms": {k: w[k] - rw[k] for k in w}}
    v["startup"] = {"r3_s": arm["startup_s"], "r2_main_s": ref["startup_s"], "delta_s": arm["startup_s"] - ref["startup_s"]}
    if n_after == 0:
        v["verdict"] = "WARMUP MOVES ALL"
        v["say"] = f"WARMUP MOVES ALL: no Mamba2 kernel compiled after ready, against {r2_total} in r2's MAIN arm."
    elif n_after < r2_total:
        v["verdict"] = "WARMUP MOVES SOME"
        v["say"] = f"WARMUP MOVES SOME: {n_after} Mamba2 compile(s) after ready, against {r2_total} in r2's MAIN arm."
    else:
        v["verdict"] = "NO EFFECT"
        v["say"] = f"NO EFFECT: {n_after} Mamba2 compile(s) after ready, against {r2_total} in r2's MAIN arm."
    return v, 0


def render(v):
    lines = [f"VERDICT: {v['verdict']}", v["say"]]
    arm = v.get("arm")
    if arm and arm.get("gate_line"):
        lines.append(f"GATE: {arm['gate']}: {arm['gate_line']}")
    if v["verdict"] in ("WARMUP MOVES ALL", "WARMUP MOVES SOME", "NO EFFECT"):
        ref = v["reference"]
        lines.append("PER MAMBA2 KERNEL: name | r3 before ready, after ready | r2 MAIN before, after | r3 late compiles by burst | by class")
        names = sorted(set(arm["per_kernel"]) | set(ref["mamba2_after_ready"]) | set(ref["mamba2_before_ready"]))
        for n in names:
            k = arm["per_kernel"].get(n, {"before_ready": 0, "after_ready": 0, "after_by_phase": {}, "after_by_class": {}})
            ph = ", ".join(f"{p} {c}" for p, c in k["after_by_phase"].items()) or "-"
            cl = ", ".join(f"{p} {c}" for p, c in sorted(k["after_by_class"].items())) or "-"
            lines.append(f"  {n} | {k['before_ready']}, {k['after_ready']} | {ref['mamba2_before_ready'].get(n, 0)}, "
                         f"{ref['mamba2_after_ready'].get(n, 0)} | {ph} | {cl}")
        lines.append("MAMBA2 COMPILES AFTER READY (r3):")
        for r in arm["mamba2_after_ready"]:
            lines.append(f"  {r['name']} {r['seconds']:.2f} s in {r['phase']} ({r['after_ready_s']:.1f} s after ready), {r['class']}")
        t = v["first_burst_ttft"]
        lines.append(f"FIRST-BURST TTFT ms (warmup burst): r3 mean {t['r3']['mean_ttft_ms']:.1f}, median {t['r3']['median_ttft_ms']:.1f}, "
                     f"p99 {t['r3']['p99_ttft_ms']:.1f}; r2 MAIN mean {t['r2_main']['mean_ttft_ms']:.1f}, median {t['r2_main']['median_ttft_ms']:.1f}, "
                     f"p99 {t['r2_main']['p99_ttft_ms']:.1f}; r3 minus r2 mean {t['delta_ms']['mean_ttft_ms']:+.1f}")
        s = v["startup"]
        lines.append(f"STARTUP launch to ready: r3 {s['r3_s']:.1f} s with --warmups prefill_shapes, r2 MAIN {s['r2_main_s']:.1f} s without, "
                     f"{s['delta_s']:+.1f} s")
        if not arm["autotune_reported"]:
            lines.append("AUTOTUNE: the log holds no Triton autotune report, so configs and classes are not shown")
        else:
            lines.append("AUTOTUNE (Triton's report, one line per autotune): kernel #n | configs benchmarked | key | seconds | chosen | compiles linked, where")
            for a in arm["autotune"]:
                where = f"{a['sweep_compiles']} compiles, {a['phase']}" if a["linked"] else "not linked to a set of compiles"
                lines.append(f"  {a['kernel']} #{a['n'] + 1} | {a['configs']} | {a['key']} | {a['seconds']} | {a['best']} | {where}")
    return "\n".join(lines)


def main(argv):
    if len(argv) != 2 or not os.path.isdir(argv[1]):
        print("usage: verdict.py <OUT>", file=sys.stderr)
        return 2
    v, rc = judge(argv[1])
    with open(os.path.join(argv[1], "verdict.json"), "w") as f:
        json.dump(v, f, indent=1, sort_keys=True, default=str)
    print(render(v))
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv))
