"""Unit checks for the vLLM HF3FS preemption kit p5's verdict.py, whose test file holds the GPU test alone.

usage: python3 -I hack/vllm-hf3fs-preemption-p5-kit-check.py KIT_DIR FAKE_DIR
FAKE_DIR holds:
  cpu-logs-p5/e2e-{control,fix}.log, the two arms run on CPU at kit p5's pinned trees, where the one GPU test skips;
  gpu-p4-logs/e2e-{control,fix}.log, run p4's real logs of the earlier test with its CPU tests, which kit p5 must not judge;
  gpu-p2-logs/e2e-{control,fix}.log, run p2's real logs, where LLM() had too little KV cache memory in both arms.
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

# python3 -I ignores PYTHONDONTWRITEBYTECODE, so the import below would leave __pycache__ in the kit, which the session ships.
sys.dont_write_bytecode = True
KIT, FAKES = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("verdict", os.path.join(KIT, "verdict.py"))
V = importlib.util.module_from_spec(spec)
spec.loader.exec_module(V)

failures = 0


def check(name, cond):
    global failures
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        failures += 1


def read(*parts):
    return open(os.path.join(FAKES, *parts), errors="replace", newline="").read()


TF = "tests/v1/kv_connector/unit/test_hf3fs_preemption.py"
GPU_ID = "TestHF3FSPreemptionEndToEnd::test_preempted_request_saves_its_own_kv"
GPU_ENV = {"cuda_available": True, "device_name": "NVIDIA A10G", "torch": "t", "torch_cuda": "13.0", "triton": "3"}
SUMMARY_FAILED = "1 failed, 21 warnings in 164.88s (0:02:44)"
SUMMARY_PASSED = "1 passed, 21 warnings in 60.69s (0:01:00)"


def log(held="held=[32, 33, 34] reused=[33, 34] hold_timed_out=False", errors="[0.0, 1.0049, 1.2084]",
        end="[0.0, 1.0049, 1.2084]", gpu="mismatch", e_lines=None, s=True, extra="", summary=None):
    """A `pytest -q -s --tb=short` log of the one-test file, the shape run p4's logs have without the CPU tests.

    gpu is passed, mismatch (the page assert after the prints), skip, or raised (e_lines raised before the prints).
    """
    out = ["/x/plugin.py:306: PytestDeprecationWarning: unset"]
    prints = []
    if gpu in ("passed", "mismatch"):
        prints = [x for x in (held, f"end-of-run page errors: {end}" if end else None, f"held-save page errors: {errors}" if errors else None) if x]
    if s and prints:
        out.append("(EngineCore pid=1) INFO 11-23 01:00:01 [llm.py:1] Supported tasks: ['generate']")
        out.extend(prints)
        out.append({"passed": ".", "mismatch": "F"}[gpu])
    else:
        out.append({"passed": ".", "mismatch": "F", "skip": "s", "raised": "F"}[gpu])
    if extra:
        out.append(extra)
    failed = gpu in ("mismatch", "raised")
    if failed:
        out.append("=================================== FAILURES ===================================")
        out += ["_____ TestHF3FSPreemptionEndToEnd.test_preempted_request_saves_its_own_kv _____", f"{TF}:313: in test_preempted_request_saves_its_own_kv"]
        out += e_lines or ["    assert max(errors) < 0.05, errors", f"E   AssertionError: {errors}", "E   assert 1.2084 < 0.05"]
        if not s and prints:
            out += ["----------------------------- Captured stdout call -----------------------------"] + prints
        out.append("=========================== short test summary info ============================")
        out.append(f"FAILED {TF}::{GPU_ID}")
    if summary is None:
        summary = {"passed": SUMMARY_PASSED, "skip": "1 skipped, 1 warning in 0.03s"}.get(gpu, SUMMARY_FAILED)
    out.append(summary)
    return "\n".join(out) + "\n", (1 if failed else 0)


CONTROL = log()
FIX = log(held="held=[32, 33, 34] reused=[33, 34] hold_timed_out=True", errors="[0.0, 0.0, 0.0]", end="[0.0, 0.0, 0.0]", gpu="passed")
RESET = "E   Failed: the local prefix cache could not be reset"


def judged(control=CONTROL, fix=FIX, env=GPU_ENV, stopped=None):
    """The verdict on an OUT with the two arms' (log or None, exit) pairs."""
    d = tempfile.mkdtemp(prefix="hf3fs-p5-")
    try:
        status = []
        for arm, (text, rc) in (("control", control), ("fix", fix)):
            if text is not None:
                with open(os.path.join(d, f"e2e-{arm}.log"), "w", newline="") as f:
                    f.write(text)
            if rc is not None:
                status.append(f"test-{arm} exit={rc} t=1")
        with open(os.path.join(d, "status.txt"), "w") as f:
            f.write("\n".join(status) + "\n")
        if env is not None:
            with open(os.path.join(d, "env.json"), "w") as f:
                json.dump(env, f)
        if stopped:
            with open(os.path.join(d, "STOPPED"), "w") as f:
                f.write(stopped)
        r = V.judge(d)
        with contextlib.redirect_stdout(io.StringIO()) as buf:
            rc_main = V.main(["verdict.py", d])
        r["_rc"], r["_text"] = rc_main, buf.getvalue()
        return r
    finally:
        shutil.rmtree(d)


def raised(line, at=None):
    text, rc = log(gpu="raised", e_lines=[line])
    return (text.replace(":313: in test_preempted", f":{at}: in test_preempted"), rc) if at else (text, rc)


# ---------------------------------------------------------------- CONFIRMED, with no CPU tests to expect
r = judged()
c, f = r["arms"]["control"], r["arms"]["fix"]
check("CONFIRMED: CONTROL fails the held-save comparison near 1 with preconditions met, FIX passes with the hold timed out; exit 0",
      r["verdict"] == "CONFIRMED" and r["_rc"] == 0)
check("a one-test file is not a failure: both arms count their one test, have no CPU failures, and the printout names no CPU tests",
      c["counts"] == {"failed": 1} and f["counts"] == {"passed": 1} and c["cpu_failed"] == [] == f["cpu_failed"] and "CPU" not in r["_text"])
check("the held line and both page lines are parsed, and only the held-save line is judged",
      c["held"] == [32, 33, 34] and c["reused"] == [33, 34] and c["hold_timed_out"] is False and f["hold_timed_out"] is True
      and c["errors"] == [0.0, 1.0049, 1.2084] and c["end_errors"] == [0.0, 1.0049, 1.2084] and c["max_error"] == 1.2084)

# ---------------------------------------------------------------- FINDING
r = judged(fix=log(held="held=[32] reused=[33] hold_timed_out=True"))
check("FINDING: FIX failing the held-save comparison near 1; exit 2", r["verdict"] == "FINDING" and r["_rc"] == 2 and "mismatch" in r["why"])
r = judged(fix=log(held="held=[32] reused=[33] hold_timed_out=True", errors="[0.0, 0.07]", e_lines=["E   AssertionError: [0.0, 0.07]", "E   assert 0.07 < 0.05"]))
check("FINDING: FIX failing with a held-save error of 0.07, at or above 0.05", r["verdict"] == "FINDING" and r["arms"]["fix"]["max_error"] == 0.07)
r = judged(fix=log(held="held=[32] reused=[33] hold_timed_out=True", errors="[0.0, 0.07]", gpu="passed"))
check("FINDING: FIX shown passing yet printing a 0.07 held-save error", r["verdict"] == "FINDING")
r = judged(fix=raised("E   AssertionError: saves did not finish", at=279))
check("FINDING: FIX failing before the comparison while CONTROL reached it", r["verdict"] == "FINDING" and r["arms"]["fix"]["gpu"] == "failed")
r = judged(fix=("(EngineCore pid=1) ERROR Triton Error [CUDA]: an illegal memory access was encountered\nFatal Python error: Aborted\n", 134))
check("FINDING: FIX hitting an illegal access, even with no summary", r["verdict"] == "FINDING" and r["arms"]["fix"]["gpu"] == "faulted")
r = judged(fix=log(held="held=[32] reused=[33] hold_timed_out=True"), env=None)
check("a FINDING outranks a gap", r["verdict"] == "FINDING")
r = judged(fix=log(held="held=[32] reused=[33] hold_timed_out=True", gpu="mismatch", errors=None, e_lines=["E   AssertionError: the held save did not finish"]))
check("FINDING: FIX whose held save never finished, so no held-save line, while CONTROL reached the comparison", r["verdict"] == "FINDING")

# ---------------------------------------------------------------- INCONCLUSIVE
for name, text in (("save held", "no save of the target was held"), ("target preempted", "the target was not preempted"),
                   ("held block reused", "no held block was reused by the other request")):
    r = judged(control=raised(f"E   AssertionError: {text}"))
    check(f"INCONCLUSIVE: CONTROL's precondition '{name}' not met; exit 5", r["verdict"] == "INCONCLUSIVE" and r["_rc"] == 5
          and r["arms"]["control"]["gpu"] == "precondition" and f"precondition not met: {name}" in r["why"])
r = judged(fix=raised("E   AssertionError: the target was not preempted"))
check("INCONCLUSIVE, not FINDING: FIX's target was not preempted", r["verdict"] == "INCONCLUSIVE" and "target preempted" in r["why"])
r = judged(control=log(held="held=[32, 33] reused=[] hold_timed_out=False"))
check("INCONCLUSIVE: a held line with no reused block", r["verdict"] == "INCONCLUSIVE" and r["arms"]["control"]["gpu"] == "precondition")
r = judged(control=log(errors="[0.0, 0.0011]", gpu="passed", summary=SUMMARY_PASSED))
check("INCONCLUSIVE: CONTROL's test passing", r["verdict"] == "INCONCLUSIVE" and "passed instead of failing" in r["why"])
r = judged(control=log(errors="[0.2, 0.1]"))
check("INCONCLUSIVE: CONTROL failing with a 0.2 held-save error, not another request's KV", r["verdict"] == "INCONCLUSIVE" and "under 0.5" in r["why"])
r = judged(control=log(held="held=[32] reused=[32] hold_timed_out=True"))
check("INCONCLUSIVE: CONTROL failing the comparison with its hold timed out", r["verdict"] == "INCONCLUSIVE" and "CONTROL's hold timed out" in r["why"])
r = judged(fix=log(held="held=[32] reused=[33] hold_timed_out=False", errors="[0.0]", gpu="passed"))
check("INCONCLUSIVE: FIX passing without its hold timing out", r["verdict"] == "INCONCLUSIVE" and "did not time out" in r["why"])
r = judged(control=raised(RESET, at=239))
check("INCONCLUSIVE: CONTROL failing before the comparison while FIX passes", r["verdict"] == "INCONCLUSIVE")
r = judged(control=("(EngineCore pid=1) ERROR CUDA error: an illegal memory access was encountered\n", 134))
check("INCONCLUSIVE: CONTROL faulting rather than failing the comparison", r["verdict"] == "INCONCLUSIVE")
r = judged(control=log(errors="[0.0, 0.0]", end="[0.9, 1.0]", gpu="passed", summary=SUMMARY_PASSED))
check("INCONCLUSIVE: CONTROL's end-of-run pages near 1 decide nothing when its held-save pages match", r["verdict"] == "INCONCLUSIVE")

# ---------------------------------------------------------------- NOT RUN, and the same-step rule
kv = "E   ValueError: To serve at least one request with the model's max seq len (1024), (0.04 GiB KV cache is needed, which is larger than the available KV cache memory (0.03 GiB)."
r = judged(control=raised(kv))
check("NOT RUN: CONTROL without KV cache memory; exit 4", r["verdict"] == "NOT RUN" and r["_rc"] == 4 and "KV cache memory" in r["why"])
r = judged(fix=raised("E   huggingface_hub.errors.LocalEntryNotFoundError: no snapshot"))
check("NOT RUN: FIX unable to load the model offline", r["verdict"] == "NOT RUN" and "model download" in r["why"])
r = judged(fix=raised("E   torch.OutOfMemoryError: CUDA out of memory."))
check("NOT RUN: FIX out of GPU memory", r["verdict"] == "NOT RUN")
r = judged(fix=log(gpu="raised", e_lines=["E   AssertionError: saves did not finish"], extra="WARNING huggingface_hub Cannot find the requested files in the disk cache"))
check("a captured line that looks like a harness cause does not turn a FIX failure into NOT RUN", r["verdict"] == "FINDING")
r = judged(control=raised(RESET, at=239), fix=raised(RESET, at=239))
check("NOT RUN: both arms failing at the same line with the same error, before the comparison",
      r["verdict"] == "NOT RUN" and "both arms' GPU tests failed before the page comparison" in r["why"])
r = judged(control=raised(RESET, at=239), fix=raised("E   AttributeError: no attribute 'preempted_req_ids'", at=231))
check("FINDING: both arms failing early, but FIX at another line with another error", r["verdict"] == "FINDING")
r = judged(control=raised(RESET, at=239), fix=raised("E   RuntimeError: saves did not finish", at=239))
check("FINDING: both arms failing at the same line but with different errors", r["verdict"] == "FINDING")
p2 = {a: (read("gpu-p2-logs", f"e2e-{a}.log"), 1) for a in V.ARMS}
r = judged(control=p2["control"], fix=p2["fix"])
check("run p2's real logs: NOT RUN on KV cache memory, printing each arm's 'Available KV cache memory' and 'available KV cache memory' lines",
      r["verdict"] == "NOT RUN" and r["_text"].count("kv memory: ") >= 4
      and r["_text"].count("Available KV cache memory: 14.92 GiB") == 2 and r["_text"].count("kv memory: ") - 2 >= 2)

# ---------------------------------------------------------------- INCOMPLETE
cpu = {a: (read("cpu-logs-p5", f"e2e-{a}.log"), 0) for a in V.ARMS}
r = judged(control=cpu["control"], fix=cpu["fix"], env={"cuda_available": False, "device_name": None})
check("INCOMPLETE: the real CPU logs at the p5 trees, where the one GPU test skips in both arms",
      r["verdict"] == "INCOMPLETE" and all(r["arms"][a]["gpu"] == "incomplete" and "skipped" in r["arms"][a]["why"] for a in V.ARMS))
p4 = {a: (read("gpu-p4-logs", f"e2e-{a}.log"), 1 if a == "control" else 0) for a in V.ARMS}
r = judged(control=p4["control"], fix=p4["fix"])
check("INCOMPLETE: run p4's real CONFIRMED logs come from a four-test file, so kit p5 does not take them as its own",
      r["verdict"] == "INCOMPLETE" and all("does not count the file's 1 tests" in r["arms"][a]["why"] for a in V.ARMS))
old_c = CONTROL[0].replace("held-save page errors: ", "relative page errors: ").replace("end-of-run page errors: [0.0, 1.0049, 1.2084]\n", "")
old_f = FIX[0].replace("held-save page errors: ", "relative page errors: ").replace("end-of-run page errors: [0.0, 0.0, 0.0]\n", "")
r = judged(control=(old_c, 1), fix=(old_f, 0))
check("INCOMPLETE: logs with only the older 'relative page errors' line decide nothing, though they would have CONFIRMED",
      r["verdict"] == "INCOMPLETE" and all("older test's page errors line" in r["arms"][a]["why"] for a in V.ARMS))
r = judged(fix=log(held="held=[32] reused=[33] hold_timed_out=True", errors="[0.0]", gpu="passed", s=False))
check("INCOMPLETE: FIX passing without -s prints no held line, so it shows nothing", r["verdict"] == "INCOMPLETE" and "not printed" in r["why"])
r = judged(control=log(s=False))
check("without -s CONTROL's prints are read from its captured stdout", r["arms"]["control"]["gpu"] == "mismatch")
for arm in V.ARMS:
    r = judged(**{arm: (None, None)})
    check(f"INCOMPLETE: no {arm.upper()} log; exit 3", r["verdict"] == "INCOMPLETE" and r["_rc"] == 3)
r = judged(fix=("Fatal Python error: Aborted\n", 134))
check("INCOMPLETE: FIX dying before its summary without a fault", r["verdict"] == "INCOMPLETE")
r = judged(fix=(FIX[0], 124))
check("INCOMPLETE: FIX cut by its cap", r["verdict"] == "INCOMPLETE")
r = judged(fix=(FIX[0].replace(SUMMARY_PASSED, "2 passed in 9.0s"), 0))
check("INCOMPLETE: a FIX process that ran two tests, not the file's one", r["verdict"] == "INCOMPLETE" and "does not count" in r["why"])
r = judged(env={"cuda_available": False, "device_name": None})
check("INCOMPLETE: no CUDA", r["verdict"] == "INCOMPLETE")
r = judged(stopped="the budget ran out before test-fix")
check("INCOMPLETE: a STOPPED run", r["verdict"] == "INCOMPLETE")

# ---------------------------------------------------------------- the printout, which goes into the PR
r = judged()
t = r["_text"]
check("verdict.txt prints each arm's pytest summary line verbatim, the held line, both page lines and the traceback, then the verdict",
      f"  pytest summary (verbatim): {SUMMARY_FAILED}\n" in t and f"  pytest summary (verbatim): {SUMMARY_PASSED}\n" in t
      and "  held line: held=[32, 33, 34] reused=[33, 34] hold_timed_out=False" in t and "  held-save page errors: [0.0, 1.0049, 1.2084]" in t
      and "  end-of-run page errors (information only): [0.0, 0.0, 0.0]" in t and "    E   AssertionError: [0.0, 1.0049, 1.2084]" in t
      and t.rstrip().endswith("VERDICT: CONFIRMED"))
padded = "========================= 1 passed, 21 warnings in 60.69s (0:01:00) =========================="
r = judged(fix=(FIX[0].replace(SUMMARY_PASSED, padded), 0))
check("a summary line in pytest's padded form is printed exactly as pytest wrote it", r["verdict"] == "CONFIRMED" and f"  pytest summary (verbatim): {padded}\n" in r["_text"])

print()
print("all unit checks passed" if failures == 0 else f"{failures} unit check(s) failed")
sys.exit(1 if failures else 0)
