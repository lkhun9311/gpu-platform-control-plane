#!/usr/bin/env python3
"""Unit checks for the SGLang #51628 kit r2: the compile hook, the record parsers, burst attribution and every verdict outcome.

  python3 -I hack/sglang-51628-kit-check.py <kit dir> <fakes dir>

Prints one ok or FAIL line per check and exits 1 when any check failed.
hack/sglang-51628-kit-test.sh runs it on the kit and on mutants of verdict.py, each of which must make it fail.
"""

import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile

# The kit directory is shipped as committed, so nothing here may leave bytecode in it.
sys.dont_write_bytecode = True
KIT, FAKES = sys.argv[1], sys.argv[2]
failures = 0


def check(name, cond):
    global failures
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        failures += 1


def load_verdict():
    spec = importlib.util.spec_from_file_location("verdict", os.path.join(KIT, "verdict.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


V = load_verdict()
WORK = tempfile.mkdtemp(prefix="sgl51628-check-", dir=os.environ.get("SCRATCH"))

# ---------------------------------------------------------------- the compile hook, in a child with the fake Triton
HOOK_SCRIPT = r"""
import json, os, sys
log = os.environ.get("SGL51628_COMPILE_LOG")
import sgl51628_compile_hook as h
import triton, triton.knobs as knobs
seen = []
if os.environ.get("CHAIN") == "1":
    from sglang.srt.utils import triton_load_watch as w
    w.install(); w.mark_serving_started()
    sys.stdout.write("chained=%s\n" % w._installed)
triton.fake_compile("_chunk_scan_fwd_kernel", "sglang.kernels.ops.mamba.triton_ops.ssd_chunk_scan", 1.25)
triton.fake_compile("_small_copy_kernel", "x.y", 0.1, cache_hit=True)
if os.environ.get("BREAK") == "1":
    # A times object whose total raises must not reach the caller.
    class Bad:
        @property
        def total(self):
            raise RuntimeError("boom")
    knobs.compilation.listener(src=None, metadata=None, metadata_group=None, times=Bad(), cache_hit=False)
    sys.stdout.write("survived\n")
sys.stdout.write("second_install=%s\n" % h.install())
"""


def run_hook(extra_env):
    env = {"PATH": os.environ["PATH"], "PYTHONDONTWRITEBYTECODE": "1", "PYTHONPATH": os.path.join(FAKES, "py") + os.pathsep + KIT}
    env.update(extra_env)
    p = subprocess.run([sys.executable, "-c", HOOK_SCRIPT], env=env, capture_output=True, text=True, timeout=60)
    return p


log = os.path.join(WORK, "hook.jsonl")
p = run_hook({"SGL51628_COMPILE_LOG": log, "CHAIN": "1"})
recs = [json.loads(x) for x in open(log)] if os.path.exists(log) else []
inst = [r for r in recs if r["event"] == "install"]
comp = [r for r in recs if r["event"] == "compile"]
check("the hook installs once per process and records it", p.returncode == 0 and len(inst) == 1 and inst[0]["installed"] is True)
check("a second install in the same process is a no-op", "second_install=True" in p.stdout and len(inst) == 1)
check(
    "the hook records name, module, duration in microseconds, cache flag and time",
    len(comp) == 2
    and comp[0]["name"] == "_chunk_scan_fwd_kernel"
    and comp[0]["module"] == "sglang.kernels.ops.mamba.triton_ops.ssd_chunk_scan"
    and comp[0]["total_us"] == 1.25e6
    and comp[0]["cache_hit"] is False
    and comp[1]["cache_hit"] is True
    and isinstance(comp[0]["t"], float),
)
check(
    "SGLang's watch keeps the hook in the chain and still logs the slow compile",
    "chained=True" in p.stdout and "Triton kernel '_chunk_scan_fwd_kernel' took 1.25 s to compile after serving started" in p.stderr,
)
log2 = os.path.join(WORK, "hook2.jsonl")
p = run_hook({"SGL51628_COMPILE_LOG": log2, "BREAK": "1"})
recs2 = [json.loads(x) for x in open(log2)] if os.path.exists(log2) else []
check("an error inside the listener is recorded and does not reach the compiling caller",
      p.returncode == 0 and "survived" in p.stdout and any(r["event"] == "listener_error" for r in recs2))
p = run_hook({})
check("without SGL51628_COMPILE_LOG the hook installs nothing", p.returncode == 0 and "second_install=False" in p.stdout)
log3 = os.path.join(WORK, "hook3.jsonl")
p = run_hook({"SGL51628_COMPILE_LOG": log3, "FAKE_NO_LISTENER": "1"})
recs3 = [json.loads(x) for x in open(log3)] if os.path.exists(log3) else []
check("a Triton without the listener knob is recorded as not installed",
      any(r["event"] == "install" and r["installed"] is False and "listener" in r["error"] for r in recs3))

# ---------------------------------------------------------------- the parsers
check("classify: the chunked scan is a Mamba2 kernel", V.classify("_chunk_scan_fwd_kernel", None) == "mamba2")
check("classify: a state-scatter kernel of the mamba package is mamba_aux, not Mamba2",
      V.classify("_fused_mamba_state_scatter_with_mask_kernel", "sglang.kernels.ops.mamba.mamba_state_scatter_triton") == "mamba_aux")
check("classify: a copy kernel elsewhere is other", V.classify("_small_copy_kernel", "sglang.srt.mem_cache.memory_pool") == "other")
GQA = "[2026-11-21 10:00:00] Disable prefill CUDA graph because some layers do not apply Standard GQA"
check("gate: the GQA line passes", V.gate_from_log("a\n" + GQA + "\nb") == ("pass", GQA))
check("gate: another disabling line on this SHA passes too",
      V.gate_from_log("Disable target prefill CUDA graph because the target model does not have a 'layers' attribute")[0] == "pass")
check("gate: no disabling line fails", V.gate_from_log("Capture target decode CUDA graph begin.")[0] == "fail")
check("gate: a prefill capture fails even beside a disabling line",
      V.gate_from_log(GQA + "\nCapture target prefill CUDA graph begin. backend=breakable")[0] == "fail")
W1 = "[x] Triton kernel '_chunk_scan_fwd_kernel' took 1.45 s to compile after serving started. Serving-time ..."
check("SGLang's warning line is parsed into name and seconds", V.sglang_warnings(W1 + "\n" + W1.replace("1.45", "1.00")) ==
      [("_chunk_scan_fwd_kernel", 1.45), ("_chunk_scan_fwd_kernel", 1.0)])
c1 = {"name": "_chunk_scan_fwd_kernel", "seconds": 1.4512, "cache_hit": False}
check("a warning matches a record of the same name within the printed precision", V.unmatched_warnings([("_chunk_scan_fwd_kernel", 1.45)], [c1]) == [])
check("a warning whose duration no record has is unmatched", V.unmatched_warnings([("_chunk_scan_fwd_kernel", 1.0)], [c1]) == [("_chunk_scan_fwd_kernel", 1.0)])
check("one record cannot match two warnings", len(V.unmatched_warnings([("_chunk_scan_fwd_kernel", 1.45)] * 2, [c1])) == 1)
check("a cache hit cannot match a warning", V.unmatched_warnings([("_chunk_scan_fwd_kernel", 1.45)], [dict(c1, cache_hit=True)]) != [])
bs = [{"label": "warmup", "start": 100.0, "end": 110.0}, {"label": "c1-r1", "start": 112.0, "end": 120.0}]
check("phase: before ready is startup", V.phase_of(99.0, 99.5, bs) == "startup")
check("phase: inside a burst is that burst, its edges included",
      V.phase_of(100.0, 90, bs) == "warmup" and V.phase_of(110.0, 90, bs) == "warmup" and V.phase_of(115, 90, bs) == "c1-r1")
check("phase: between bursts names both", V.phase_of(111.0, 90, bs) == "between warmup and c1-r1")
check("phase: after ready and before the first burst says so", V.phase_of(95.0, 90, bs) == "after ready, before warmup")
check("phase: after the last burst says so", V.phase_of(130.0, 90, bs) == "after c1-r1")


# ---------------------------------------------------------------- synthetic runs for the verdict
def burst_result(n, mean):
    return {"completed": n, "ttfts": [mean / 1000] * n, "errors": [""] * n, "mean_ttft_ms": mean, "median_ttft_ms": mean, "p99_ttft_ms": mean * 1.2}


def make_arm(d, *, gate=True, compiles=(), warn_lines=(), ready=1000.0, first_ttft=3000.0, other_ttft=100.0, cache0="0",
             drop_burst=None, skip_burst=None, short_burst=None, no_install=False, gate_kv=None):
    os.makedirs(os.path.join(d, "bursts"), exist_ok=True)
    log = ["[t] server_args={}"]
    log.append(GQA if gate else "[t] Capture target prefill CUDA graph begin. backend=breakable")
    log.extend(warn_lines)
    log.append("[t] The server is fired up and ready to roll!")
    with open(os.path.join(d, "server.log"), "w") as f:
        f.write("\n".join(log) + "\n")
    with open(os.path.join(d, "arm.txt"), "w") as f:
        f.write(f"triton_cache_entries_at_start={cache0}\nready_epoch={ready}\ngate={gate_kv or ('pass' if gate else 'fail')}\n")
    with open(os.path.join(d, "compiles.jsonl"), "w") as f:
        if not no_install:
            f.write(json.dumps({"event": "install", "installed": True, "pid": 7, "t": 1.0}) + "\n")
        for name, t, secs, hit in compiles:
            f.write(json.dumps({"event": "compile", "name": name, "module": None, "t": t, "total_us": secs * 1e6, "cache_hit": hit, "pid": 7}) + "\n")
    rows = ["label\tconcurrency\tprompts\tseed\tstart\tend\trc"]
    t = (ready if isinstance(ready, float) else 1000.0) + 10
    for e in V.expected_bursts():
        if e["label"] == skip_burst:
            rows.append(f"{e['label']}\t{e['concurrency']}\t{e['prompts']}\t{e['seed']}\t-\t-\tskipped-time")
            continue
        rows.append(f"{e['label']}\t{e['concurrency']}\t{e['prompts']}\t{e['seed']}\t{t}\t{t + 20}\t0")
        t += 30
        if e["label"] == drop_burst:
            continue
        n = e["prompts"] - (1 if e["label"] == short_burst else 0)
        r = burst_result(n, first_ttft if e["label"] == "warmup" else other_ttft)
        with open(os.path.join(d, "bursts", e["label"] + ".jsonl"), "w") as f:
            f.write(json.dumps(r) + "\n")
    with open(os.path.join(d, "bursts.tsv"), "w") as f:
        f.write("\n".join(rows) + "\n")


def make_run(name, *, main=None, control=None, probe_ok=True, measure_extra="", plan=None, measure=True):
    out = os.path.join(WORK, name)
    c = os.path.join(out, "c")
    os.makedirs(c)
    if measure:
        with open(os.path.join(c, "measure.txt"), "w") as f:
            f.write(f"bursts={plan or V.BURSTS}\nprobe_hook={'ok' if probe_ok else 'bad'}\nmodel_repo=nvidia/Nemotron-H-4B-Instruct-128K\n" + measure_extra)
    with open(os.path.join(c, "probe-compiles.jsonl"), "w") as f:
        for k in ("_sgl51628_probe_a", "_sgl51628_probe_b") if probe_ok else ("_sgl51628_probe_a",):
            f.write(json.dumps({"event": "compile", "name": k, "cache_hit": False}) + "\n")
    make_arm(os.path.join(c, "main"), **(main or {}))
    if control is not None:
        make_arm(os.path.join(c, "control"), **control)
    return out


START = [("write_req_to_token_pool_triton", 900.0, 0.09, False), ("_chunk_state_fwd_kernel", 950.0, 0.4, False)]
LATE = [("_chunk_scan_fwd_kernel", 1011.0, 1.45, False), ("_chunk_scan_fwd_kernel", 1012.0, 1.0, False), ("_small_copy_kernel", 1013.0, 0.12, False)]
WARN = ["[t] Triton kernel '_chunk_scan_fwd_kernel' took 1.45 s to compile after serving started.",
        "[t] Triton kernel '_chunk_scan_fwd_kernel' took 1.00 s to compile after serving started."]
CONTROL_OK = {"compiles": START + [("_small_copy_kernel", 1012.0, 0.1, False)], "first_ttft": 150.0}


def verdict_of(out):
    v, rc = V.judge(out)
    return v, rc, V.render(v)


v, rc, text = verdict_of(make_run("repro", main={"compiles": START + LATE, "warn_lines": WARN}, control=CONTROL_OK))
check("REPRODUCED when the chunked scan compiles after ready, with exit 0", v["verdict"] == "REPRODUCED" and rc == 0)
check("the headline counts the chunked scan's compiles, their seconds and their burst",
      v["headline"] == {"kernel": "_chunk_scan_fwd_kernel", "compiles": 2, "seconds": 2.45, "phases": ["warmup"]})
check("the small copy kernel is listed apart and is not a Mamba2 compile",
      len(v["mamba2_after_ready"]) == 2 and "OTHER KERNELS AFTER READY (main, not part of the verdict): 1" in text and "_small_copy_kernel 0.12 s in warmup" in text)
check("the first-burst TTFT hit is MAIN's first burst against CONTROL's",
      v["ttft_hit"]["status"] == "MEASURED" and v["ttft_hit"]["mean_ttft_ms"] == 2850.0 and "FIRST-BURST TTFT HIT: MEASURED: mean +2850.0 ms" in text)
check("the Mamba2 kernels compiled before ready are named", "MAMBA2 KERNELS COMPILED BEFORE READY (main): _chunk_state_fwd_kernel" in text)

v, rc, text = verdict_of(make_run("norepro", main={"compiles": START + [("_small_copy_kernel", 1013.0, 0.12, False)]}, control=CONTROL_OK))
check("NOT REPRODUCED, said plainly, when only other kernels compile after ready",
      v["verdict"] == "NOT REPRODUCED" and rc == 0 and "no Mamba2 kernel compiled after the server reported ready" in text)
v, rc, _ = verdict_of(make_run("cachehit", main={"compiles": START + [("_chunk_scan_fwd_kernel", 1011.0, 0.01, True)]}, control=CONTROL_OK))
check("a cache hit after ready is not a compile", v["verdict"] == "NOT REPRODUCED")
v, rc, text = verdict_of(make_run("gatefail", main={"gate": False, "compiles": START}))
check("GATE FAILED, exit 4, when the server captured a prefill graph", v["verdict"] == "GATE FAILED" and rc == 4 and "stopped before traffic" in text)
v, rc, _ = verdict_of(make_run("gatedisagree", main={"gate": False, "gate_kv": "pass", "compiles": START}))
check("arm.txt and the server log disagreeing on the gate is INCOMPLETE", v["verdict"] == "INCOMPLETE" and rc == 3)


def incomplete(name, why, **kw):
    v, rc, text = verdict_of(make_run(name, **kw))
    check(f"INCOMPLETE, exit 3: {name}", v["verdict"] == "INCOMPLETE" and rc == 3 and why in text)


incomplete("no-compile-log", "no server process recorded the compile hook", main={"compiles": START + LATE, "no_install": True})
incomplete("hook-not-live", "the hook was not shown live", main={"compiles": LATE})
incomplete("warning-unmatched", "SGLang logged compile(s) the hook did not record",
           main={"compiles": START + [("_small_copy_kernel", 1013.0, 0.12, False)], "warn_lines": WARN})
incomplete("cache-not-empty", "entries at the start, not 0", main={"compiles": START + LATE, "cache0": "12"})
incomplete("probe", "positive control", main={"compiles": START + LATE}, probe_ok=False)
incomplete("burst-missing", "c16-r2: the client wrote no result", main={"compiles": START + LATE, "drop_burst": "c16-r2"})
incomplete("burst-skipped", "c128-r3: skipped, the time ran out", main={"compiles": START + LATE, "skip_burst": "c128-r3"})
incomplete("burst-short", "c1-r1: 3 of 4 requests completed", main={"compiles": START + LATE, "short_burst": "c1-r1"})
incomplete("plan", "a different burst plan", main={"compiles": START + LATE}, plan="warmup:32:64:42")
incomplete("no-measure", "measure.txt is missing", main={"compiles": START + LATE}, measure=False)
incomplete("never-ready", "never reported ready", main={"compiles": START + LATE, "ready": "x"})

v, rc, text = verdict_of(make_run("noctl", main={"compiles": START + LATE, "warn_lines": WARN}, measure_extra="control_skipped=CONTROL=off\n"))
check("without CONTROL the compile verdict stands and the TTFT hit is INCOMPLETE with why",
      v["verdict"] == "REPRODUCED" and rc == 0 and "FIRST-BURST TTFT HIT: INCOMPLETE: the CONTROL arm did not run: CONTROL=off" in text)
v, rc, text = verdict_of(make_run("ctl-incomplete", main={"compiles": START + LATE, "warn_lines": WARN},
                                  control=dict(CONTROL_OK, drop_burst="c1-r2")))
check("an incomplete CONTROL makes the TTFT hit INCOMPLETE, not a number", v["ttft_hit"]["status"] == "INCOMPLETE" and "c1-r2" in v["ttft_hit"]["why"])
v, rc, text = verdict_of(make_run("ctl-late", main={"compiles": START + LATE, "warn_lines": WARN},
                                  control={"compiles": START + [("_chunk_scan_fwd_kernel", 1011.0, 0.5, False)], "first_ttft": 900.0}))
check("a CONTROL that also compiled a Mamba2 kernel late makes the hit NOT ISOLATED",
      v["ttft_hit"]["status"] == "NOT ISOLATED" and "CONTROL: 1 Mamba2 kernel compile(s) after ready" in text)
out = make_run("main-cli", main={"compiles": START + LATE, "warn_lines": WARN}, control=CONTROL_OK)
p = subprocess.run([sys.executable, "-I", os.path.join(KIT, "verdict.py"), out], capture_output=True, text=True)
check("verdict.py writes verdict.json and prints the verdict first",
      p.returncode == 0 and p.stdout.startswith("VERDICT: REPRODUCED") and json.load(open(os.path.join(out, "verdict.json")))["verdict"] == "REPRODUCED")
p = subprocess.run([sys.executable, "-I", os.path.join(KIT, "verdict.py")], capture_output=True, text=True)
check("verdict.py without an OUT is a usage error", p.returncode == 2 and "usage" in p.stderr)

shutil.rmtree(WORK, ignore_errors=True)
sys.exit(1 if failures else 0)
