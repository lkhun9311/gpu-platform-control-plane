"""Unit checks for the vLLM HF3FS preemption kit p6's verdict.py (FIX alone) and b2_verdict.py (the bench arm on FIX).

usage: python3 -I hack/vllm-hf3fs-preemption-p6-kit-check.py KIT_DIR FAKE_DIR
FAKE_DIR holds cpu-logs-p6/e2e-fix.log, the FIX arm run on CPU at kit p6's pinned tree, where the one GPU test skips.
Prints one ok or FAIL line per check and exits 1 if any failed.
"""

import contextlib
import importlib.util
import io
import json
import os
import shutil
import sys
import tempfile

# python3 -I ignores PYTHONDONTWRITEBYTECODE, so the imports below would leave __pycache__ in the kit, which the session ships.
sys.dont_write_bytecode = True
KIT, FAKES = sys.argv[1], sys.argv[2]


def load(name):
    spec = importlib.util.spec_from_file_location(name, os.path.join(KIT, f"{name}.py"))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


V = load("verdict")
B = load("b2_verdict")
failures = 0


def check(name, cond):
    global failures
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        failures += 1


TF = "tests/v1/kv_connector/unit/test_hf3fs_preemption.py"
GPU_ID = "TestHF3FSPreemptionEndToEnd::test_preempted_request_saves_its_own_kv"
GPU_ENV = {"cuda_available": True, "device_name": "NVIDIA A10G", "torch": "t", "torch_cuda": "13.0", "triton": "3"}
PASSED = "1 passed, 21 warnings in 60.69s (0:01:00)"
FAILED = "1 failed, 21 warnings in 60.69s (0:01:00)"


def log(held="held=[32, 33, 34] reused=[33, 34] hold_timed_out=True", errors="[0.0, 0.0, 0.0]", gpu="passed", e_lines=None, summary=None):
    """A `pytest -q -s --tb=short` log of the one-test file; gpu is passed, mismatch or raised (before the prints)."""
    out = ["/x/plugin.py:306: PytestDeprecationWarning: unset"]
    if gpu in ("passed", "mismatch"):
        out += ["(EngineCore pid=1) INFO 11-23 01:00:01 [llm.py:1] Supported tasks: ['generate']", held,
                "end-of-run page errors: [0.0, 0.0, 0.0]", f"held-save page errors: {errors}"]
    out.append("." if gpu == "passed" else "F")
    if gpu != "passed":
        out += ["=================================== FAILURES ===================================",
                "_____ TestHF3FSPreemptionEndToEnd.test_preempted_request_saves_its_own_kv _____", f"{TF}:313: in test_preempted_request_saves_its_own_kv"]
        out += e_lines or [f"E   AssertionError: {errors}", "E   assert 1.0 < 0.05"]
        out += ["=========================== short test summary info ============================", f"FAILED {TF}::{GPU_ID}"]
    out.append(summary or (PASSED if gpu == "passed" else FAILED))
    return "\n".join(out) + "\n", (0 if gpu == "passed" else 1)


def judged(fix=None, env=GPU_ENV, stopped=None, control=None, status_extra=""):
    text, rc = fix or log()
    d = tempfile.mkdtemp(prefix="hf3fs-p6-")
    try:
        if text is not None:
            open(os.path.join(d, "e2e-fix.log"), "w", newline="").write(text)
        open(os.path.join(d, "status.txt"), "w").write((f"test-fix exit={rc} t=1\n" if rc is not None else "") + status_extra)
        if env is not None:
            json.dump(env, open(os.path.join(d, "env.json"), "w"))
        if stopped:
            open(os.path.join(d, "STOPPED"), "w").write(stopped)
        if control:
            open(os.path.join(d, "e2e-control.log"), "w").write(control)
        r = V.judge(d)
        with contextlib.redirect_stdout(io.StringIO()) as buf:
            r["_rc"] = V.main(["verdict.py", d])
        r["_text"] = buf.getvalue()
        return r
    finally:
        shutil.rmtree(d)


# ---------------------------------------------------------------- the test arm, FIX alone
r = judged()
check("CONFIRMED: FIX passes its one test, every held-save page error 0.0, preconditions met, hold timed out; exit 0",
      r["verdict"] == "CONFIRMED" and r["_rc"] == 0 and list(r["arms"]) == ["fix"])
check("the printout has FIX's pytest summary verbatim and its held-save page errors, and names no CONTROL arm",
      f"  pytest summary (verbatim): {PASSED}\n" in r["_text"] and "  held-save page errors: [0.0, 0.0, 0.0]" in r["_text"]
      and "CONTROL" not in r["_text"] and r["_text"].rstrip().endswith("VERDICT: CONFIRMED"))
r = judged(fix=log(errors="[0.0, 0.0012, 0.0]"))
check("INCONCLUSIVE: FIX passing with a held-save page error of 0.0012, not 0.0; exit 5",
      r["verdict"] == "INCONCLUSIVE" and r["_rc"] == 5 and "expects every one 0.0" in r["why"])
r = judged(fix=log(held="held=[32] reused=[33] hold_timed_out=False"))
check("INCONCLUSIVE: FIX passing without its hold timing out", r["verdict"] == "INCONCLUSIVE" and "did not time out" in r["why"])
r = judged(fix=log(gpu="raised", e_lines=["E   AssertionError: the target was not preempted"]))
check("INCONCLUSIVE, not FINDING: FIX's precondition not met", r["verdict"] == "INCONCLUSIVE" and "target preempted" in r["why"])
r = judged(fix=log(errors="[0.0, 1.0049, 1.2084]", gpu="mismatch"))
check("FINDING: FIX failing the held-save comparison; exit 2", r["verdict"] == "FINDING" and r["_rc"] == 2)
r = judged(fix=log(errors="[0.0, 0.07]", gpu="passed"))
check("FINDING: FIX printing a held-save page error of 0.07", r["verdict"] == "FINDING")
r = judged(fix=log(gpu="raised", e_lines=["E   AssertionError: saves did not finish"]))
check("FINDING: FIX failing before the comparison, with no CONTROL to share the failure", r["verdict"] == "FINDING" and r["arms"]["fix"]["gpu"] == "failed")
r = judged(fix=("(EngineCore pid=1) ERROR CUDA error: an illegal memory access was encountered\n", 134))
check("FINDING: FIX faulting", r["verdict"] == "FINDING")
r = judged(fix=log(gpu="raised", e_lines=["E   ValueError: (0.04 GiB KV cache is needed, which is larger than the available KV cache memory (0.03 GiB)."]))
check("NOT RUN: FIX without KV cache memory; exit 4", r["verdict"] == "NOT RUN" and r["_rc"] == 4)
r = judged(control=log(errors="[1.0]", gpu="mismatch")[0])
check("INCOMPLETE: a CONTROL log present, since kit p6 runs FIX alone; exit 3", r["verdict"] == "INCOMPLETE" and r["_rc"] == 3 and "CONTROL arm ran" in r["why"])
r = judged(status_extra="test-control exit=1 t=1\n")
check("INCOMPLETE: a CONTROL step in status.txt, even without its log", r["verdict"] == "INCOMPLETE")
r = judged(fix=(open(os.path.join(FAKES, "cpu-logs-p6", "e2e-fix.log"), errors="replace", newline="").read(), 0), env={"cuda_available": False, "device_name": None})
check("INCOMPLETE: the real CPU log at the p6 tree, where the GPU test skips", r["verdict"] == "INCOMPLETE" and "skipped" in r["arms"]["fix"]["why"])
r = judged(fix=(None, None))
check("INCOMPLETE: no FIX log", r["verdict"] == "INCOMPLETE")
r = judged(stopped="the budget ran out before test-fix")
check("INCOMPLETE: a STOPPED run", r["verdict"] == "INCOMPLETE")
r = judged(fix=(log()[0].replace("held-save page errors: ", "relative page errors: ").replace("end-of-run page errors: [0.0, 0.0, 0.0]\n", ""), 0))
check("INCOMPLETE: a log with only the older 'relative page errors' line", r["verdict"] == "INCOMPLETE")
r = judged(fix=(log()[0].replace(PASSED, "2 passed in 9.0s"), 0))
check("INCOMPLETE: a process that ran two tests", r["verdict"] == "INCOMPLETE")

# ---------------------------------------------------------------- b2_verdict.py
B2_ORDER = [("fix", 128, 1), ("fix", 128, 2), ("fix", 128, 3), ("fix", 2304, 1)]


def b2_json(pool, **over):
    d = {"has_fix": True, "fix_wait": "wait_for_gathers", "pool_blocks": pool, "num_requests": 64, "prompt_tokens": 256, "output_tokens": 256,
         "wall_s": 31.347290756999996, "output_tok_per_s": 522.7612345, "steps": 2900, "step_ms_p50": 9.254321, "step_ms_p90": 11.5,
         "step_ms_p99": 19.75, "step_ms_max": 61.125, "preemptions": 51 if pool == 128 else 0, "wait_calls": 50 if pool == 128 else 0,
         "wait_total_s": 0.012345678 if pool == 128 else 0, "wait_ms_p50": 0.2 if pool == 128 else None, "wait_ms_max": 1.5 if pool == 128 else None,
         "mean_step_ms": 10.0, "stored_keys": 1883 if pool == 128 else 2003, "storage_pages": 14563}
    d.update(over)
    return json.dumps(d, indent=2)


def b2_judged(runs=None, drop=(), rcs=None, stopped=None, logs=None, raw=None, nolog=()):
    d = tempfile.mkdtemp(prefix="hf3fs-b2-")
    try:
        os.makedirs(os.path.join(d, "b2"))
        status = []
        for arm, pool, i in B2_ORDER:
            name = f"{arm}-{pool}-{i}"
            status.append(f"b2-{name} exit={(rcs or {}).get(name, 0)} t=1")
            if name in drop:
                continue
            open(os.path.join(d, "b2", f"{name}.json"), "w").write((raw or {}).get(name) or (runs or {}).get(name) or b2_json(pool))
            if name not in nolog:
                open(os.path.join(d, "b2", f"{name}.log"), "w").write((logs or {}).get(name, "INFO start\n"))
        open(os.path.join(d, "status.txt"), "w").write("\n".join(status) + "\n")
        if stopped:
            open(os.path.join(d, "b2", "STOPPED"), "w").write(stopped)
        r = B.judge(d)
        with contextlib.redirect_stdout(io.StringIO()) as buf:
            r["_rc"] = B.main(["b2_verdict.py", d])
        r["_text"] = buf.getvalue()
        return r
    finally:
        shutil.rmtree(d)


r = b2_judged()
t = r["_text"]
check("b2 VALID: three pool-128 runs that preempt with 1,883 keys and a pool-2304 run with 2,003 and none; exit 0", r["state"] == "VALID" and r["_rc"] == 0)
check("b2 prints every JSON verbatim, its fields unrounded with fix_wait, and b1's stored_keys beside each run",
      t.startswith("B2, the bench arm on FIX: a separate section that does not change the verdict above.") and t.count("  verbatim:") == 4
      and '    "wall_s": 31.347290756999996,' in t and 'fix_wait="wait_for_gathers"' in t and "wait_total_s=0.012345678" in t
      and t.count("stored_keys 1883 beside b1 at pool 128: CONTROL 1882/1883/1883, FIX 1883/1883/1883") == 3
      and "stored_keys 2003 beside b1 at pool 2304: CONTROL 2003, FIX 2003" in t and t.rstrip().endswith("B2: VALID"))
r = b2_judged(runs={"fix-128-1": b2_json(128, stored_keys=1866)})
check("b2 (b): 1,866 keys at pool 128 are within 1% of b1's 1,882 to 1,883, and stay VALID; the 2,003 rule is not applied at pool 128",
      r["state"] == "VALID")
r = b2_judged(runs={"fix-128-3": b2_json(128, stored_keys=1800)})
check("b2 INVALID (b): 1,800 keys at pool 128, more than 1% under b1's; exit 6",
      r["state"] == "INVALID" and r["_rc"] == 6 and "fix-128-3: (b) stored_keys=1800 is not within 1% of b1 at pool 128" in r["_text"])
r = b2_judged(runs={"fix-128-2": b2_json(128, stored_keys=1902)})
check("b2 INVALID (b): 1,902 keys at pool 128, more than 1% over b1's", r["state"] == "INVALID" and "(b) stored_keys=1902" in r["_text"])
for keys, ok in ((1864, False), (1865, True), (1900, True), (1901, False)):
    r = b2_judged(runs={"fix-128-1": b2_json(128, stored_keys=keys)})
    check(f"b2 (b): {keys} keys at pool 128 is {'within' if ok else 'outside'} 1% of every b1 value, 1,864.17 to 1,900.82",
          (r["state"] == "VALID") == ok)
r = b2_judged(nolog=("fix-128-2",))
check("b2 INCOMPLETE: a run without its log cannot be shown free of save failures (a)", r["state"] == "INCOMPLETE" and "fix-128-2: no readable log" in r["_text"])
r = b2_judged(runs={"fix-2304-1": b2_json(2304, stored_keys=2002)})
check("b2 INVALID (c): 2,002 keys at pool 2304, within 1% of b1's 2,003 but not exactly it",
      r["state"] == "INVALID" and "fix-2304-1: (c) stored_keys=2002, not exactly 2003" in r["_text"] and "(b)" not in r["_text"].split("B2 INVALID")[1])
r = b2_judged(logs={"fix-128-2": "INFO start\n(EngineCore pid=7) ERROR [hf3fs_connector.py:390] Write operation failed for Saved request 9-aa\n"})
check("b2 INVALID (a): a 'Write operation failed' line in a run's log", r["state"] == "INVALID" and "fix-128-2: (a) 1 save failure lines" in r["_text"])
for line in ("Page allocation failed for 3 keys", "Buffer allocation failed", "Task execution error: boom", "Rank 0 only allocated 12 pages for 31 keys"):
    r = b2_judged(logs={"fix-128-1": f"INFO start\n(EngineCore pid=7) WARNING {line}\n"})
    check(f"b2 INVALID (a): '{line.split(':')[0]}' in a run's log", r["state"] == "INVALID" and "(a)" in r["_text"])
r = b2_judged(runs={"fix-128-2": b2_json(128, preemptions=0)})
check("b2 INVALID: a pool-128 run that did not preempt", r["state"] == "INVALID" and "fix-128-2: preemptions=0" in r["_text"])
r = b2_judged(runs={"fix-2304-1": b2_json(2304, preemptions=3)})
check("b2 INVALID: a pool-2304 run that preempted", r["state"] == "INVALID" and "fix-2304-1: preemptions=3, so the pool-2304 control preempted" in r["_text"])
old = json.loads(b2_json(128))
del old["fix_wait"]
r = b2_judged(runs={"fix-128-1": json.dumps(old, indent=2)})
check("b2 INCOMPLETE: a JSON without fix_wait is not bench_preempt_v2.py's; exit 3", r["state"] == "INCOMPLETE" and r["_rc"] == 3 and "no fix_wait" in r["_text"])
r = b2_judged(runs={"fix-128-1": b2_json(128, fix_wait="wait_for_saves")})
check("b2 NOT RUN: fix_wait=wait_for_saves means the tree is kit p5's head, not the gather-only one; exit 4",
      r["state"] == "NOT RUN" and r["_rc"] == 4 and "fix_wait='wait_for_saves'" in r["_text"])
r = b2_judged(runs={"fix-2304-1": b2_json(2304, has_fix=False, fix_wait=None)})
check("b2 NOT RUN: has_fix false", r["state"] == "NOT RUN")
r = b2_judged(drop=("fix-2304-1",), stopped="the budget ran out before b2-fix-2304-1")
check("b2 INCOMPLETE: b2 ran out of budget", r["state"] == "INCOMPLETE" and "b2/STOPPED" in r["_text"])
r = b2_judged(rcs={"fix-128-1": 124})
check("b2 INCOMPLETE: a run cut by its cap", r["state"] == "INCOMPLETE")
r = b2_judged(raw={"fix-128-1": "{not json"})
check("b2 INCOMPLETE: an unreadable JSON", r["state"] == "INCOMPLETE")

print()
print("all unit checks passed" if failures == 0 else f"{failures} unit check(s) failed")
sys.exit(1 if failures else 0)
