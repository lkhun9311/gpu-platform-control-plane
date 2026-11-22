#!/usr/bin/env python3
"""Unit checks for the SGLang #51628 kit r4: the compile hook, the parsers on r2's real records, and every verdict outcome.

  python3 -I hack/sglang-51628-kit-r4-check.py <kit dir> <fakes dir> <r2 main arm dir>

Prints one ok or FAIL line per check and exits 1 when any check failed.
hack/sglang-51628-kit-r4-test.sh runs it on the kit and on mutants of verdict.py, each of which must make it fail.
The parser checks read r2's committed records, pinned here by sha256, and the expected numbers were read from them once, by hand, with r2's verdict.
"""

import hashlib
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
KIT, FAKES, R2 = sys.argv[1], sys.argv[2], sys.argv[3]
failures = 0


def check(name, cond):
    global failures
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        failures += 1


spec = importlib.util.spec_from_file_location("verdict", os.path.join(KIT, "verdict.py"))
V = importlib.util.module_from_spec(spec)
spec.loader.exec_module(V)
WORK = tempfile.mkdtemp(prefix="sgl51628-r4-check-", dir=os.environ.get("SCRATCH"))

# ---------------------------------------------------------------- the pins agree across the kit
run_sh = open(os.path.join(KIT, "run.sh")).read()
patch_hash = hashlib.sha256(open(os.path.join(KIT, "prewarm.patch"), "rb").read()).hexdigest()
check("the shipped prewarm.patch is the pinned one", patch_hash == V.PATCH_SHA256 == "6aa4b47ca4aa314d0cae6d35e8894df0caa1e7565b403f028eda50a7d94624f9")
for name, value in (("SGLANG_SHA", V.SGLANG_SHA), ("BASE_TREE", V.BASE_TREE), ("FIX_TREE", V.FIX_TREE), ("PATCH_SHA256", V.PATCH_SHA256)):
    check(f"run.sh and verdict.py pin the same {name}", f"\n{name}={value}\n" in run_sh)
check("the pinned commit is SGLang main cb337923", V.SGLANG_SHA == "cb337923d576f48a4accba439af9cfbc9b720a2c")
for line in V.FIX_NUMSTAT.split("\n"):
    check(f"run.sh pins the FIX numstat line {line.split(chr(9))[2]}", "$'" + line.replace("\t", "\\t") + "'" in run_sh)
# The numstat is the patch's own: each file's added and removed lines, counted from the patch text.
counts, cur = {}, None
for ln in open(os.path.join(KIT, "prewarm.patch")).read().split("\n"):
    if ln.startswith("diff --git") or ln == "-- ":
        # "-- " opens format-patch's signature, which is not a removed line.
        cur = None
    elif ln.startswith("+++ "):
        cur = ln[6:]
        counts[cur] = [0, 0]
    elif cur and ln.startswith("+") and not ln.startswith("+++"):
        counts[cur][0] += 1
    elif cur and ln.startswith("-") and not ln.startswith("---"):
        counts[cur][1] += 1
check("the pinned numstat is what prewarm.patch adds and removes", "\n".join(f"{a}\t{r}\t{p}" for p, (a, r) in counts.items()) == V.FIX_NUMSTAT)
check("the burst plan is r2's warmup and three c16 runs with r2's seeds", V.BURSTS == "warmup:32:64:42 c16-r1:16:32:161 c16-r2:16:32:162 c16-r3:16:32:163"
      and f'BURSTS="{V.BURSTS}"' in open(os.path.join(KIT, "measure.sh")).read())

# ---------------------------------------------------------------- the compile hook records the kernel's source file
HOOK = r"""
import sgl51628_compile_hook, triton
triton.fake_compile("_chunk_scan_fwd_kernel", "sglang.kernels.ops.mamba.triton_ops.ssd_chunk_scan", 1.25)
"""
log = os.path.join(WORK, "hook.jsonl")
env = {"PATH": os.environ["PATH"], "PYTHONDONTWRITEBYTECODE": "1", "PYTHONPATH": os.path.join(FAKES, "py") + os.pathsep + KIT, "SGL51628_COMPILE_LOG": log}
p = subprocess.run([sys.executable, "-c", HOOK], env=env, capture_output=True, text=True, timeout=60)
recs = [json.loads(x) for x in open(log)] if os.path.exists(log) else []
comp = [r for r in recs if r["event"] == "compile"]
check("the hook records the file the kernel is defined in",
      p.returncode == 0 and len(comp) == 1 and comp[0]["file"] == os.path.join(os.path.abspath(FAKES), "py", "triton", "__init__.py"))

# ---------------------------------------------------------------- the parsers, on r2's real records
R2_FILES = {
    "server.log": "61af84836e3081e632cfb28b1d2e6eb9872f77326ca38453573a70af23a40a01",
    "compiles.jsonl": "3903abbb7068c2e34954f91ae3bc5bcee168cdc4a575c0fd4053ca506a6f4a24",
    "arm.txt": "472c630dbaef2d8dcb1deda3574b5abff445c4559f56d1a2886edd032f4c6b56",
    "bursts.tsv": "40ab695a3ff1a893311ec67943ff65a3f886c9758fb7907cb1cbfb52ef660366",
    "bursts/warmup.jsonl": "d8a6a156d5d73b3b28bcf7327d2e7a46e899db1048549c7654fbe860956418dd",
    "bursts/c16-r1.jsonl": "8cc262950f15acff5e349bd61256cb49e7fd9047dd23aa52041558e96a87dbe0",
    "bursts/c16-r2.jsonl": "6c34daaa143fe9dd2624ae6a8f612205f2f2300a7250b4d346fb3e09bbb58909",
    "bursts/c16-r3.jsonl": "6257fc7114928f6b93a075e4adfddd92f93875153b6c13020770e8910a5fee7e",
}
for f, h in R2_FILES.items():
    have = hashlib.sha256(open(os.path.join(R2, f), "rb").read()).hexdigest() if os.path.exists(os.path.join(R2, f)) else None
    check(f"r2's {f} is the committed one", have == h)
r2log = open(os.path.join(R2, "server.log")).read()
r2kv = V.read_kv(os.path.join(R2, "arm.txt"))
r2ready, r2launch = float(r2kv["ready_epoch"]), float(r2kv["launch_epoch"])
r2recs, _ = V.read_jsonl(os.path.join(R2, "compiles.jsonl"))
miss = []
r2c = V.compile_records(r2recs, miss, need_file=False)
r2b = V.read_bursts(R2, miss)
late = V.late_mamba2(r2c, r2ready, r2b)
pk = V.per_kernel_per_burst(late)
check("r2: every record and r4's four bursts parse without a gap", miss == [])
check("r2: the gate line passes, and fails for FIX without a prewarm line",
      V.gate_from_log(r2log, False) == ("pass", "[2026-11-21 02:32:34 PID365] " + V.GATE_LINE) and V.gate_from_log(r2log, True)[0] == "fail")
check("r2: no prewarm line", V.prewarm_of(r2log) is None)
check("r2: launch to ready is 153.8 s", round(r2ready - r2launch, 1) == 153.8)
check("r2: the TreeCore line reads RustUnifiedTreeCore", V.TREECORE_RE.search(r2log).group(1) == "RustUnifiedTreeCore")
check("r2: SGLang's 22 warning lines all match a compile record", len(V.sglang_warnings(r2log)) == 22 and V.unmatched_warnings(V.sglang_warnings(r2log), r2c) == [])
check("r2: 53 Mamba2 compiles after ready, 33.3 s", len(late) == 53 and round(sum(r["seconds"] for r in late), 1) == 33.3)
check("r2: the chunked scan compiled 24 times after ready: 21 in warmup, 2 in c16-r1, 1 in c16-r3",
      {k: v[0] for k, v in pk["_chunk_scan_fwd_kernel"].items()} == {"warmup": 21, "c16-r1": 2, "c16-r3": 1}
      and round(pk["_chunk_scan_fwd_kernel"]["warmup"][1], 2) == 20.95)
check("r2: a compile during r2's c1-r1, a burst r4 drops, lands in the gap between warmup and c16-r1",
      pk["_state_passing_fwd_kernel"].get("between warmup and c16-r1", [0])[0] == 1)
check("r2: 69 Mamba2 compiles before ready, as r2-reference.json counts", sum(1 for c in r2c if c["t"] < r2ready and V.classify(c["name"], c["module"]) == "mamba2") == 69)
w = r2b[0]["result"]
check("r2: warmup TTFT mean 50110.7 ms, p99 82974.7 ms, n 64", (round(w["mean_ttft_ms"], 1), round(w["p99_ttft_ms"], 1), w["n"]) == (50110.7, 82974.7, 64))
check("r2: c16 ITL medians 21.752, 21.752, 21.758 ms and output 262.6, 275.2, 270.1 tok/s",
      [(round(b["result"]["median_itl_ms"], 3), round(b["result"]["output_throughput"], 1)) for b in r2b[1:]]
      == [(21.752, 262.6), (21.752, 275.2), (21.758, 270.1)])

# ---------------------------------------------------------------- verdict fixtures, built from r2's records
SRC = "/src/sglang"
PKG = SRC + "/python/sglang"
NUMSTAT_BASE = ""


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


def source_txt(commit, tree, numstat, untracked=0, matches="yes"):
    return f"commit={commit}\ntree={tree}\nworktree_matches_index={matches}\nuntracked={untracked}\nnumstat_begin\n" + (numstat + "\n" if numstat else "") + "numstat_end\n"


def make_arm(d, name, *, keep_late, log_edit=None, file_root=PKG, pytest=("0", "3 passed in 10.21s"), drop_itl=False, skip_burst=None,
             gate_kv="pass", cache_hit_late=False, missing_measure=False):
    """An arm dir from r2's MAIN arm: its records with file fields, keeping keep_late of its 53 late Mamba2 compiles."""
    os.makedirs(os.path.join(d, "bursts"))
    if missing_measure:
        return
    measure = (f"mode={name}\nsrc={SRC}\nsglang_dir={PKG}\ninstall=ok\nprobe_hook=ok\nmodel=ok\nbursts={V.BURSTS}\n"
               + (f"pytest_rc={pytest[0]}\npytest_summary={pytest[1]}\n" if name == "fix" else "") + "arm_rc=0\n")
    write(os.path.join(d, "measure.txt"), measure)
    write(os.path.join(d, "probe-compiles.jsonl"), "".join(json.dumps({"event": "compile", "name": n, "cache_hit": False}) + "\n"
                                                         for n in ("_sgl51628_probe_a", "_sgl51628_probe_b")))
    write(os.path.join(d, "arm.txt"), open(os.path.join(R2, "arm.txt")).read().replace("gate=pass", f"gate={gate_kv}"))
    log = r2log
    kept, out = 0, []
    for r in r2recs:
        r = dict(r)
        if r.get("event") == "compile":
            r["file"] = file_root + "/kernels/ops/mamba/triton_ops/x.py"
            if r["t"] >= r2ready and V.classify(r["name"], r.get("module")) == "mamba2":
                if kept >= keep_late:
                    continue
                kept += 1
                if cache_hit_late:
                    r["cache_hit"] = True
        out.append(r)
    write(os.path.join(d, "compiles.jsonl"), "".join(json.dumps(r) + "\n" for r in out))
    if keep_late < 53:
        # The warnings of the dropped compiles would have no record, so the fixture drops every warning line.
        log = "\n".join(ln for ln in log.split("\n") if not V.WARN_RE.search(ln))
    if name == "fix":
        log = log.replace("The server is fired up", "Prewarmed the Mamba2 prefill scan for 1 layer geometries in 41.7 s.\n[x] The server is fired up", 1)
    if log_edit:
        log = log_edit(log)
    write(os.path.join(d, "server.log"), log)
    rows = open(os.path.join(R2, "bursts.tsv")).read()
    if skip_burst:
        rows = "\n".join(ln if not ln.startswith(skip_burst + "\t") else "\t".join(ln.split("\t")[:4] + ["-", "-", "skipped-time"]) for ln in rows.split("\n"))
    write(os.path.join(d, "bursts.tsv"), rows)
    for label in ("warmup", "c16-r1", "c16-r2", "c16-r3"):
        res = [json.loads(x) for x in open(os.path.join(R2, "bursts", f"{label}.jsonl"))][-1]
        if drop_itl and label == "c16-r2":
            del res["median_itl_ms"]
        write(os.path.join(d, "bursts", f"{label}.jsonl"), json.dumps(res) + "\n")


def make_run(name, *, base=None, fix=None, fix_tree=None, base_tree=None, patch=None, numstat_after=None, treecore="rust", stopped=None):
    out = os.path.join(WORK, name)
    os.makedirs(os.path.join(out, "c", "prep"))
    write(os.path.join(out, "settings.txt"), f"sglang_sha={V.SGLANG_SHA}\n")
    write(os.path.join(out, "patch.txt"), f"patch_sha256={patch or V.PATCH_SHA256}\n")
    for when in ("before", "after"):
        write(os.path.join(out, f"source-base-{when}.txt"), source_txt(V.SGLANG_SHA, base_tree or V.BASE_TREE, NUMSTAT_BASE))
        num = numstat_after if (when == "after" and numstat_after is not None) else V.FIX_NUMSTAT
        write(os.path.join(out, f"source-fix-{when}.txt"), source_txt(V.SGLANG_SHA, fix_tree or V.FIX_TREE, num))
    write(os.path.join(out, "c", "prep", "measure.txt"), f"prep=ok\ntreecore={treecore}\n" + ("treecore_fallback=the build exited 1\n" if treecore == "python" else ""))
    if stopped:
        write(os.path.join(out, "STOPPED"), stopped)
    make_arm(os.path.join(out, "c", "base"), "base", **(base or {"keep_late": 53}))
    make_arm(os.path.join(out, "c", "fix"), "fix", **(fix or {"keep_late": 3}))
    return out


def verdict_of(out):
    v, rc = V.judge(out)
    return v, rc, V.render(v)


v, rc, text = verdict_of(make_run("improved"))
check("IMPROVED, exit 0, when FIX keeps 3 of BASE's 53 late compiles and the tests passed", v["verdict"] == "IMPROVED" and rc == 0)
check("IMPROVED prints both arms' counts, startup, prewarm seconds, warmup TTFT with n, and the c16 decode data",
      "Mamba2 compiles after ready: 53 3" in text and "launch to ready s: 153.8 153.8" in text and "1 layer geometries in 41.7 s" in text
      and "WARMUP TTFT BASE: mean 50110.7 ms, p99 82974.7 ms, n 64" in text and "  c16-r1 21.752 21.752 262.6 262.6" in text
      and "data, not a verdict condition" in text)
check("IMPROVED names each late kernel per burst", "  _chunk_scan_fwd_kernel warmup 21 20.95" in text)
v, rc, _ = verdict_of(make_run("edge-half", fix={"keep_late": 26}))
check("26 against 53 is at most half and 27 fewer: IMPROVED", v["verdict"] == "IMPROVED")
v, rc, text = verdict_of(make_run("edge-over-half", fix={"keep_late": 27}))
check("27 against 53 is more than half: NO CHANGE, exit 0, with why", v["verdict"] == "NO CHANGE" and rc == 0 and "not clearly fewer" in text)
v, rc, _ = verdict_of(make_run("edge-drop", base={"keep_late": 8}, fix={"keep_late": 4}))
check("4 against 8 is half but only 4 fewer: NO CHANGE", v["verdict"] == "NO CHANGE")
v, rc, _ = verdict_of(make_run("edge-drop5", base={"keep_late": 10}, fix={"keep_late": 5}))
check("5 against 10 is half and 5 fewer: IMPROVED", v["verdict"] == "IMPROVED")
v, rc, _ = verdict_of(make_run("same", fix={"keep_late": 53}))
check("as many late compiles in FIX as in BASE: NO CHANGE", v["verdict"] == "NO CHANGE" and rc == 0)
v, rc, text = verdict_of(make_run("tests-fail", fix={"keep_late": 3, "pytest": ("1", "1 failed, 2 passed in 3.0s")}))
check("failed unit tests: NO CHANGE even with fewer compiles, and the tests named", v["verdict"] == "NO CHANGE" and "unit tests did not pass" in text)
v, rc, _ = verdict_of(make_run("tests-skip", fix={"keep_late": 3, "pytest": ("0", "2 passed, 1 skipped in 3.0s")}))
check("a skipped CUDA test is not 3 passed: NO CHANGE", v["verdict"] == "NO CHANGE")
v, rc, _ = verdict_of(make_run("tests-4", fix={"keep_late": 3, "pytest": ("0", "4 passed in 3.0s")}))
check("4 passed is not the patch's 3 tests: NO CHANGE", v["verdict"] == "NO CHANGE")
no_warn = lambda log: "\n".join(ln for ln in log.split("\n") if not V.WARN_RE.search(ln))  # noqa: E731
v, rc, _ = verdict_of(make_run("cachehit", fix={"keep_late": 53, "cache_hit_late": True, "log_edit": no_warn}))
check("a cache hit after ready is not a compile", v["verdict"] == "IMPROVED" and v["fix"]["mamba2_after_ready_count"] == 0)
v, rc, _ = verdict_of(make_run("decode", fix={"keep_late": 3}))
check("the decode numbers do not decide: equal output still IMPROVED", v["verdict"] == "IMPROVED")


def not_run(name, why, code, **kw):
    v, rc, text = verdict_of(make_run(name, **kw))
    check(f"NOT RUN, exit {code}: {name}", v["verdict"] == "NOT RUN" and rc == code and why in text)


drop_gate = lambda log: log.replace(V.GATE_LINE, "Prefill CUDA graph stays")  # noqa: E731
not_run("base-gate-missing", "the gate failed in BASE", 4, base={"keep_late": 53, "log_edit": drop_gate, "gate_kv": "fail"})
not_run("fix-gate-missing", "the gate failed in FIX", 4, fix={"keep_late": 3, "log_edit": drop_gate, "gate_kv": "fail"})
not_run("fix-no-prewarm", "Prewarmed the Mamba2 prefill scan", 4,
        fix={"keep_late": 3, "log_edit": lambda log: log.replace("Prewarmed the Mamba2", "Skipped the Mamba2"), "gate_kv": "fail"})
not_run("prefill-capture", "captured a prefill CUDA graph", 4,
        base={"keep_late": 53, "log_edit": lambda log: log + "\nCapture target prefill CUDA graph begin. backend=breakable\n", "gate_kv": "fail"})
not_run("gate-disagrees", "arm.txt says the gate was fail", 3, base={"keep_late": 53, "gate_kv": "fail"})
not_run("base-prewarmed", "BASE logged the prewarm line", 3,
        base={"keep_late": 53, "log_edit": lambda log: log + "\nPrewarmed the Mamba2 prefill scan for 1 layer geometries in 1.0 s.\n"})
not_run("fix-tree-is-base", "fix before: tree", 3, fix_tree=V.BASE_TREE)
not_run("base-tree-other", "base before: tree", 3, base_tree=V.FIX_TREE)
not_run("patch-hash", "prewarm.patch was", 3, patch="0" * 64)
not_run("fix-changed-during-arm", "fix after: its diff", 3, numstat_after="1\t0\tpython/sglang/srt/x.py")
not_run("foreign-kernels", "compiled from outside the arm's tree", 3, fix={"keep_late": 3, "file_root": "/sgl-workspace/sglang/python/sglang"})
not_run("treecore-differs", "not the prep's RustUnifiedTreeCore", 3,
        fix={"keep_late": 3, "log_edit": lambda log: log.replace("Tree Core: RustUnifiedTreeCore", "Tree Core: UnifiedTreeCore")})
not_run("burst-skipped", "c16-r2: skipped, the time ran out", 3, fix={"keep_late": 3, "skip_burst": "c16-r2"})
not_run("no-itl", "c16-r2: the result lacks median_itl_ms", 3, fix={"keep_late": 3, "drop_itl": True})
not_run("fix-absent", "fix: measure.txt is missing", 3, fix={"keep_late": 3, "missing_measure": True})
not_run("stopped", "run.sh stopped: budget", 3, stopped="budget")
v, rc, text = verdict_of(make_run("python-core", treecore="python",
                                  base={"keep_late": 53, "log_edit": lambda log: log.replace("RustUnifiedTreeCore", "UnifiedTreeCore")},
                                  fix={"keep_late": 3, "log_edit": lambda log: log.replace("RustUnifiedTreeCore", "UnifiedTreeCore")}))
check("both arms on the Python TreeCore after a failed build still decide, and the fallback is printed",
      v["verdict"] == "IMPROVED" and "fallback: the build exited 1; r2 ran the Rust TreeCore" in text)

p = subprocess.run([sys.executable, "-I", os.path.join(KIT, "verdict.py"), make_run("cli")], capture_output=True, text=True, timeout=60)
check("verdict.py writes verdict.json and prints the verdict first", p.returncode == 0 and p.stdout.startswith("VERDICT: IMPROVED"))
p = subprocess.run([sys.executable, "-I", os.path.join(KIT, "verdict.py")], capture_output=True, text=True, timeout=60)
check("verdict.py without an OUT is a usage error", p.returncode == 2 and "usage" in p.stderr)

shutil.rmtree(WORK, ignore_errors=True)
print(f"{failures} failed" if failures else "all unit checks passed")
sys.exit(1 if failures else 0)
