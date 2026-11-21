#!/usr/bin/env python3
"""Unit checks for the SGLang #51628 kit r3: the hook's new fields, the autotune report parser, the compile classes, the r2 reference and every verdict.

  python3 -I hack/sglang-51628-kit-r3-check.py <kit dir> <fakes dir> <repository root>

Prints one ok or FAIL line per check and exits 1 when any check failed.
r2's committed server log and compile records are a fixture: the parser must read r2's real autotune report, splice included,
and the classifier must refuse to class r2's compiles, whose records lack attrs, num_warps and num_stages.
hack/sglang-51628-kit-r3-test.sh runs it on the kit and on mutants of verdict.py, each of which must make it fail.
"""

import collections
import hashlib
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile

# The kit directory is shipped as committed, so nothing here may leave bytecode in it.
sys.dont_write_bytecode = True
KIT, FAKES, ROOT = sys.argv[1], sys.argv[2], sys.argv[3]
R2 = os.path.join(ROOT, "hack/gpu-kit-runs/2026-11-21-sglang-51628-r2/run/results")
failures = 0


def check(name, cond):
    global failures
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        failures += 1


spec = importlib.util.spec_from_file_location("verdict_r3", os.path.join(KIT, "verdict.py"))
V = importlib.util.module_from_spec(spec)
spec.loader.exec_module(V)
WORK = tempfile.mkdtemp(prefix="sgl51628-r3-check-", dir=os.environ.get("SCRATCH"))

# ---------------------------------------------------------------- the hook's new fields
HOOK = r"""
import triton, sgl51628_compile_hook
big = {(i,): i for i in range(200)}
triton.fake_compile("_chunk_scan_fwd_kernel", "m", 1.0, constants=big, signature={"a": "i32"}, attrs={(0,): [["tt.divisibility", 16]]}, num_warps=8, num_stages=2)
"""
log = os.path.join(WORK, "hook.jsonl")
env = {"PATH": os.environ["PATH"], "PYTHONDONTWRITEBYTECODE": "1", "PYTHONPATH": os.path.join(FAKES, "py") + os.pathsep + KIT, "SGL51628_COMPILE_LOG": log}
p = subprocess.run([sys.executable, "-c", HOOK], env=env, capture_output=True, text=True, timeout=60)
recs = [json.loads(x) for x in open(log)] if os.path.exists(log) else []
comp = [r for r in recs if r.get("event") == "compile"]
check("the hook records attrs, num_warps and num_stages", p.returncode == 0 and len(comp) == 1
      and comp[0]["attrs"] == "{(0,): [['tt.divisibility', 16]]}" and comp[0]["num_warps"] == 8 and comp[0]["num_stages"] == 2)
check("the hook keeps constants longer than r2's 400-character cut whole",
      bool(comp) and len(comp[0]["constants"]) > 400 and V._literal(comp[0]["constants"]) == {(i,): i for i in range(200)})

# ---------------------------------------------------------------- the report parser
CFG = "BLOCK_SIZE_M: 64, BLOCK_SIZE_N: 32, num_warps: 8, num_ctas: 1, num_stages: 2, maxnreg: None"
check("a config parses into ints and None", V.parse_config(CFG) == {"BLOCK_SIZE_M": 64, "BLOCK_SIZE_N": 32, "num_warps": 8, "num_ctas": 1, "num_stages": 2, "maxnreg": None})
check("a config field that is not name: value does not parse", V.parse_config("BLOCK_SIZE_M: x") is None and V.parse_config("garbage") is None)


def report(kernel, cfgs, key="(256, 64)", secs="1.50", best=None, splice_at=None):
    out = []
    for i, c in enumerate(cfgs):
        out.append(f"Autotuning kernel {kernel} with config {c}" + ("[2026-11-21 02:33:36] INFO: GET /health 503" if i == splice_at else ""))
    out += [f"Triton autotuning for function {kernel},", f"with key as {key},", f"finished after {secs}s,", f"best config selected: {best or cfgs[-1]};"]
    return out


C1, C2 = CFG, CFG.replace("BLOCK_SIZE_M: 64", "BLOCK_SIZE_M: 32")
b = V.parse_autotune("\n".join(report("k", [C1, C2])))
check("a report gives the kernel, the configs benchmarked, the key, the seconds and the choice",
      len(b) == 1 and b[0]["complete"] and len(b[0]["configs"]) == 2 and b[0]["key"] == "(256, 64)" and b[0]["seconds"] == 1.5
      and b[0]["best"]["BLOCK_SIZE_M"] == 32)
b = V.parse_autotune("\n".join(report("k", [C1, C2], splice_at=0)))
check("a log line spliced into a config line leaves the config readable", len(b) == 1 and b[0]["complete"] and b[0]["configs"][0] == V.parse_config(C1))
lines = report("k", [C1, C2])
lines[3:3] = ["[t] INFO: a log line between the report's lines"] * 3
b = V.parse_autotune("\n".join(lines))
check("log lines between a report's lines do not break it", len(b) == 1 and b[0]["complete"])
b = V.parse_autotune("\n".join(report("k", [C1, C2])[:-1]))
check("a report without its chosen config is incomplete", len(b) == 1 and not b[0]["complete"])
b = V.parse_autotune("\n".join(report("k", [C1]) + report("k", [C1, C2, C1]) + report("j", [C2])))
check("two reports of one kernel each keep their own configs", [len(x["configs"]) for x in b] == [1, 3, 1] and [x["kernel"] for x in b] == ["k", "k", "j"])
# The first report has its configs and header but lost its three field lines; the next report's fields must not complete it.
b = V.parse_autotune("\n".join(report("k", [C1])[:2] + report("k", [C2])))
check("a header that is cut short does not take the next report's fields",
      [x["complete"] for x in b] == [False, True] and b[0]["key"] is None and len(b[1]["configs"]) == 1)

R2LOG = open(os.path.join(R2, "c/main/server.log"), errors="replace").read()
rb = V.parse_autotune(R2LOG)
check("r2's real log: eight complete reports, 6 9 6 9 18 9 6 18 configs",
      [len(x["configs"]) for x in rb] == [6, 9, 6, 9, 18, 9, 6, 18] and all(x["complete"] for x in rb))
cs = [x for x in rb if x["kernel"] == "_chunk_scan_fwd_kernel"]
check("r2's real log: two _chunk_scan_fwd_kernel autotunes, keys starting (256, 64, 128, True, the second with three more dtypes",
      len(cs) == 2 and all(x["key"].startswith("(256, 64, 128, True,") for x in cs) and cs[1]["key"].count("'torch.") - cs[0]["key"].count("'torch.") == 3
      and [x["seconds"] for x in cs] == [17.15, 20.22])

# ---------------------------------------------------------------- the classes
SIG = repr({"x_ptr": "*bf16", "seqlen": "i32", "BLOCK_SIZE_M": "constexpr", "BLOCK_SIZE_N": "constexpr"})


def rec(m, n, w, st, attrs="{}", t=1.0, sig=SIG, name="k"):
    return {"name": name, "t": t, "constants": repr({(2,): m, (3,): n}), "signature": sig, "attrs": attrs, "num_warps": w, "num_stages": st}


cfgs = ["BLOCK_SIZE_M: 32, BLOCK_SIZE_N: 32, num_warps: 8, num_ctas: 1, num_stages: 2, maxnreg: None",
        "BLOCK_SIZE_M: 64, BLOCK_SIZE_N: 64, num_warps: 4, num_ctas: 1, num_stages: 1, maxnreg: None"]
blocks = V.parse_autotune("\n".join(report("k", cfgs)))
check("identity: tile constants are named from the signature, specialisation from the rest",
      V.compile_identity(rec(64, 64, 4, 1), ["BLOCK_SIZE_M", "BLOCK_SIZE_N"])[0] == (("BLOCK_SIZE_M", 64), ("BLOCK_SIZE_N", 64), ("num_warps", 4), ("num_stages", 1)))
check("identity: a record without attrs, num_warps or num_stages has none",
      V.compile_identity(dict(rec(64, 64, 4, 1), attrs=None), ["BLOCK_SIZE_M"]) is None
      and V.compile_identity(dict(rec(64, 64, 4, 1), num_warps=None), ["BLOCK_SIZE_M"]) is None)
check("identity: constants that do not parse give none", V.compile_identity(dict(rec(64, 64, 4, 1), constants="{(2,): 6"), ["BLOCK_SIZE_M"]) is None)
comps = [rec(32, 32, 8, 2, t=1), rec(64, 64, 4, 1, t=2), rec(64, 64, 4, 1, attrs="{(0,): 16}", t=3), rec(32, 32, 8, 2, attrs="{(1,): 16}", t=4)]
cl, links = V.classify_autotune(comps, blocks)
check("several configs for one specialisation are autotune-config", cl[0] == cl[1] == "autotune-config")
check("the chosen config alone for a new specialisation is a post-autotune specialisation", cl[2] == "post-autotune specialisation")
check("a lone config that no autotune chose is unclassified", cl[3] == "unclassified")
check("the autotune is linked to its compiles when the count and the choice agree",
      len(links) == 1 and links[0]["linked"] and links[0]["sweep_compiles"] == 2 and links[0]["start"] == 1)
cl, links = V.classify_autotune(comps[:1] + [rec(64, 32, 4, 1, t=2)], blocks)
check("a set of compiles whose configs do not include the choice is not linked", not links[0]["linked"])
cl, _ = V.classify_autotune([rec(32, 32, 8, 2, name="j")], blocks)
check("a kernel no report names is 'no autotune report', not inferred", cl[0] == "no autotune report")
cl, _ = V.classify_autotune(comps, V.parse_autotune("\n".join(report("k", cfgs)[:-1])))
check("an incomplete report leaves its kernel unclassified", set(cl.values()) == {"unclassified"})
cl, _ = V.classify_autotune([dict(c, attrs=None) for c in comps], blocks)
check("records without attrs stay unclassified", set(cl.values()) == {"unclassified"})

r2recs = [json.loads(x) for x in open(os.path.join(R2, "c/main/compiles.jsonl"))]
r2c = sorted((dict(r, seconds=r["total_us"] / 1e6) for r in r2recs if r.get("event") == "compile" and not r["cache_hit"]), key=lambda r: r["t"])
cl, links = V.classify_autotune(r2c, rb)
cls = collections.Counter(cl[i] for i, c in enumerate(r2c) if c["name"] == "_chunk_scan_fwd_kernel")
check("r2's real records: no _chunk_scan_fwd_kernel compile is classed, since they lack attrs, num_warps and num_stages",
      cls == collections.Counter({"unclassified": 43}))

# ---------------------------------------------------------------- the reference, re-derived from r2's committed evidence
ref = json.load(open(os.path.join(KIT, "r2-reference.json")))


def sha(p):
    return hashlib.sha256(open(p, "rb").read()).hexdigest()


r2v = json.load(open(os.path.join(R2, "verdict.json")))
r2arm = dict(x.split("=", 1) for x in open(os.path.join(R2, "c/main/arm.txt")).read().splitlines() if "=" in x)
after = collections.Counter(r["name"] for r in r2v["main"]["compiles_after_ready"] if r["family"] == "mamba2")
ready = float(r2arm["ready_epoch"])
before = collections.Counter(r["name"] for r in r2c if r["t"] < ready and r["name"] in V.MAMBA2_KERNELS)
w = next(b for b in r2v["main"]["bursts"] if b["label"] == "warmup")["result"]
check("the reference pins r2's verdict.json, arm.txt and compiles.jsonl by sha256",
      ref["source_verdict_sha256"] == sha(os.path.join(R2, "verdict.json")) and ref["source_arm_sha256"] == sha(os.path.join(R2, "c/main/arm.txt"))
      and ref["source_compiles_sha256"] == sha(os.path.join(R2, "c/main/compiles.jsonl")))
check("the reference's numbers are r2's: 53 after ready, the per-kernel counts, the warmup TTFT and 153.8 s to ready",
      ref["mamba2_after_ready"] == dict(after) and ref["mamba2_after_ready_total"] == 53 == sum(after.values())
      and ref["mamba2_before_ready"] == dict(before) and ref["first_burst_ttft_ms"] == w
      and abs(ref["startup_s"] - (ready - float(r2arm["launch_epoch"]))) < 1e-6 and round(ref["startup_s"], 1) == 153.8)
r2plan = " ".join(f"{b['label']}:{b['concurrency']}:{b['prompts']}:{b['seed']}" for b in r2v["main"]["bursts"])
check("r3's burst plan is r2's, label, concurrency, prompts and seed", r2plan == V.BURSTS)


# ---------------------------------------------------------------- synthetic runs for the verdict
GQA = "[t] Disable prefill CUDA graph because some layers do not apply Standard GQA"


def burst_result(n, mean):
    return {"completed": n, "ttfts": [mean / 1000] * n, "errors": [""] * n, "mean_ttft_ms": mean, "median_ttft_ms": mean, "p99_ttft_ms": mean * 1.2}


def make_arm(d, *, gate=True, compiles=(), log_extra=(), ready=1000.0, launch=700.0, first_ttft=3000.0, cache0="0", warm_end=True,
             drop_burst=None, no_install=False):
    os.makedirs(os.path.join(d, "bursts"), exist_ok=True)
    log = ["[t] server_args={}", GQA if gate else "[t] Capture target prefill CUDA graph begin.", "[t] Running warmup prefill_shapes"]
    log += list(log_extra)
    if warm_end:
        log.append("[t] Warmup ended")
    log.append("[t] The server is fired up and ready to roll!")
    open(os.path.join(d, "server.log"), "w").write("\n".join(log) + "\n")
    kv = f"triton_cache_entries_at_start={cache0}\nready_epoch={ready}\ngate={'pass' if gate else 'fail'}\n"
    if launch is not None:
        kv += f"launch_epoch={launch}\n"
    open(os.path.join(d, "arm.txt"), "w").write(kv)
    with open(os.path.join(d, "compiles.jsonl"), "w") as f:
        if not no_install:
            f.write(json.dumps({"event": "install", "installed": True, "pid": 7, "t": 1.0}) + "\n")
        for c in compiles:
            f.write(json.dumps(dict({"event": "compile", "module": None, "cache_hit": False, "pid": 7}, **c)) + "\n")
    rows = ["label\tconcurrency\tprompts\tseed\tstart\tend\trc"]
    t = ready + 10
    for e in V.expected_bursts():
        rows.append(f"{e['label']}\t{e['concurrency']}\t{e['prompts']}\t{e['seed']}\t{t}\t{t + 20}\t0")
        t += 30
        if e["label"] == drop_burst:
            continue
        open(os.path.join(d, "bursts", e["label"] + ".jsonl"), "w").write(json.dumps(burst_result(e["prompts"], first_ttft if e["label"] == "warmup" else 100.0)) + "\n")
    open(os.path.join(d, "bursts.tsv"), "w").write("\n".join(rows) + "\n")


def make_run(name, *, arm=None, probe_ok=True, reference="keep"):
    out = os.path.join(WORK, name)
    c = os.path.join(out, "c")
    os.makedirs(c)
    open(os.path.join(c, "measure.txt"), "w").write(f"bursts={V.BURSTS}\nprobe_hook={'ok' if probe_ok else 'bad'}\n")
    with open(os.path.join(c, "probe-compiles.jsonl"), "w") as f:
        for k in ("_sgl51628_probe_a", "_sgl51628_probe_b"):
            f.write(json.dumps({"event": "compile", "name": k, "cache_hit": False}) + "\n")
    make_arm(os.path.join(c, "control"), **(arm or {}))
    return out


def comp(name, t, secs=0.5, **kw):
    return dict({"name": name, "t": t, "total_us": secs * 1e6}, **kw)


START = [comp("_chunk_scan_fwd_kernel", 900.0), comp("_chunk_state_fwd_kernel", 901.0)]


def verdict_of(out, ref_path=None):
    if ref_path is not None:
        old = V.REFERENCE
        V.REFERENCE = ref_path
    try:
        v, rc = V.judge(out)
    finally:
        if ref_path is not None:
            V.REFERENCE = old
    return v, rc, V.render(v) if v.get("verdict") else ""


v, rc, text = verdict_of(make_run("all", arm={"compiles": START, "first_ttft": 150.0, "ready": 1000.0, "launch": 700.0}))
check("WARMUP MOVES ALL with no Mamba2 compile after ready, exit 0", v["verdict"] == "WARMUP MOVES ALL" and rc == 0)
check("the first burst's TTFT is shown beside r2's", "FIRST-BURST TTFT ms (warmup burst): r3 mean 150.0" in text and "r2 MAIN mean 50110.7" in text)
check("the startup time is launch to ready, beside r2's 153.8 s", "STARTUP launch to ready: r3 300.0 s with --warmups prefill_shapes, r2 MAIN 153.8 s without, +146.2 s" in text)
check("each kernel's counts sit beside r2's", "  _chunk_scan_fwd_kernel | 1, 0 | 19, 24 | - | -" in text)
LATE = [comp("_chunk_scan_fwd_kernel", 1011.0), comp("_chunk_scan_fwd_kernel", 1071.0), comp("_state_passing_fwd_kernel", 1012.0),
        comp("_small_copy_kernel", 1013.0)]
v, rc, text = verdict_of(make_run("some", arm={"compiles": START + LATE}))
check("WARMUP MOVES SOME with the count against r2's 53", v["verdict"] == "WARMUP MOVES SOME" and rc == 0 and "3 Mamba2 compile(s) after ready, against 53" in text)
check("each late compile is placed in its burst", "  _chunk_scan_fwd_kernel | 1, 2 | 19, 24 | warmup 1, c1-r2 1 |" in text)
check("a kernel that is not Mamba2 does not count", v["arm"]["per_kernel"].get("_small_copy_kernel") is None)
many = [comp("_chunk_scan_fwd_kernel", 1011.0 + i * 0.1) for i in range(53)]
v, rc, _ = verdict_of(make_run("none", arm={"compiles": START + many}))
check("NO EFFECT at r2's own count of 53", v["verdict"] == "NO EFFECT" and rc == 0)
v, rc, _ = verdict_of(make_run("none52", arm={"compiles": START + many[:52]}))
check("52 is WARMUP MOVES SOME, not NO EFFECT", v["verdict"] == "WARMUP MOVES SOME")
v, rc, _ = verdict_of(make_run("hit", arm={"compiles": START + [comp("_chunk_scan_fwd_kernel", 1011.0, cache_hit=True)]}))
check("a cache hit after ready is not a compile", v["verdict"] == "WARMUP MOVES ALL")
v, rc, text = verdict_of(make_run("gate", arm={"gate": False, "compiles": START}))
check("GATE FAILED, exit 4", v["verdict"] == "GATE FAILED" and rc == 4)
v, rc, text = verdict_of(make_run("noreport", arm={"compiles": START + LATE}))
check("a log without an autotune report says so", "AUTOTUNE: the log holds no Triton autotune report" in text)
at = report("_chunk_scan_fwd_kernel", cfgs)
v, rc, text = verdict_of(make_run("report", arm={"compiles": START, "log_extra": at}))
check("a log with a report lists it", "  _chunk_scan_fwd_kernel #1 | 2 | (256, 64) | 1.5 |" in text)


def incomplete(name, why, ref_path=None, **kw):
    v, rc, text = verdict_of(make_run(name, **kw), ref_path)
    check(f"INCOMPLETE, exit 3: {name}", v["verdict"] == "INCOMPLETE" and rc == 3 and why in v["say"])


incomplete("no-warmup-end", "does not say the prefill_shapes warmup ended", arm={"compiles": START, "warm_end": False})
incomplete("no-launch", "the startup time is unknown", arm={"compiles": START, "launch": None})
incomplete("hook-not-live", "the hook was not shown live", arm={"compiles": LATE})
incomplete("no-install", "compile hook as installed", arm={"compiles": START, "no_install": True})
incomplete("cache", "entries at the start, not 0", arm={"compiles": START, "cache0": "3"})
incomplete("burst", "c16-r2: the client wrote no result", arm={"compiles": START, "drop_burst": "c16-r2"})
incomplete("probe", "positive control", arm={"compiles": START}, probe_ok=False)
incomplete("warning", "SGLang logged compile(s) the hook did not record",
           arm={"compiles": START, "log_extra": ["[t] Triton kernel '_chunk_scan_fwd_kernel' took 1.45 s to compile after serving started."]})
incomplete("ref-missing", "r2-reference.json is missing", ref_path=os.path.join(WORK, "nope.json"), arm={"compiles": START})
bad = os.path.join(WORK, "ref-bad.json")
json.dump({k: v for k, v in ref.items() if k != "mamba2_after_ready_total"}, open(bad, "w"))
incomplete("ref-field", "lacks mamba2_after_ready_total", ref_path=bad, arm={"compiles": START})
bad2 = os.path.join(WORK, "ref-bad2.json")
json.dump(dict(ref, first_burst_ttft_ms={"mean_ttft_ms": None}), open(bad2, "w"))
incomplete("ref-ttft", "no first-burst TTFT", ref_path=bad2, arm={"compiles": START})

out = make_run("cli", arm={"compiles": START})
p = subprocess.run([sys.executable, "-I", os.path.join(KIT, "verdict.py"), out], capture_output=True, text=True)
check("verdict.py finds r2-reference.json beside itself, writes verdict.json and prints the verdict first",
      p.returncode == 0 and p.stdout.startswith("VERDICT: WARMUP MOVES ALL") and json.load(open(os.path.join(out, "verdict.json")))["verdict"] == "WARMUP MOVES ALL")

shutil.rmtree(WORK, ignore_errors=True)
sys.exit(1 if failures else 0)
