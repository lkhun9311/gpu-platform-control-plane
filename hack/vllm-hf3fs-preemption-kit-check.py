"""Unit checks for the vLLM HF3FS preemption kits' verdict.py, on the real CPU logs of both arms and on built GPU logs.

usage: python3 -I hack/vllm-hf3fs-preemption-kit-check.py KIT_DIR FAKE_DIR [--p2 | --p3 | --p4]
FAKE_DIR holds cpu-logs/e2e-{control,fix}.log, the two arms run on CPU at kit p1's pinned trees, where the GPU test skips.
--p2 checks kit p2 instead: it reads cpu-logs-p2/, the same runs at kit p2's trees,
and adds the checks of p2's KV memory lines on run p1's real GPU logs in gpu-p1-logs/.
--p3 checks kit p3 the same way, on cpu-logs-p3/ and run p2's real GPU logs in gpu-p2-logs/.
--p4 checks kit p4, whose test prints "held-save page errors" and "end-of-run page errors" in place of "relative page errors":
the built logs use that format, and run p3's real GPU logs in gpu-p3-logs/, where both arms stop before the comparison, must give NOT RUN.
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
# Each later kit: its CPU logs, the earlier run whose real GPU logs it is checked on, and the KV memory that run had.
LATER = {"--p2": ("cpu-logs-p2", "p1", "6.1 GiB"), "--p3": ("cpu-logs-p3", "p2", "14.92 GiB"), "--p4": ("cpu-logs-p4", "p3", "6.1 GiB")}
P2 = len(sys.argv) == 4 and sys.argv[3] in LATER
if sys.argv[3:] not in ([], ["--p2"], ["--p3"], ["--p4"]):
    sys.exit(f"unexpected arguments {sys.argv[3:]}")
CPU_LOGS, RUN, KV_GIB = LATER[sys.argv[3]] if P2 else ("cpu-logs", None, None)
P4 = sys.argv[3:] == ["--p4"]
# The line the test prints the judged page errors on, and the label verdict.py prints them under.
PAGE_LABEL = "held-save page errors" if P4 else "relative page errors"
RENDER_LABEL = "  held-save page errors: " if P4 else "  page errors: "
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
CPU_IDS = [f"TestHF3FSHandlePreemptions::{t}" for t in (
    "test_scheduler_passes_preempted_requests_to_the_worker", "test_waits_for_the_preempted_request_saves_only", "test_no_preemption_does_not_wait")]
GPU_ID = "TestHF3FSPreemptionEndToEnd::test_preempted_request_saves_its_own_kv"
GPU_ENV = {"cuda_available": True, "device_name": "NVIDIA A10G", "torch": "t", "torch_cuda": "13.0", "triton": "3"}


def log(cpu_fail=(), held="held=[20, 21, 22, 23] reused=[21, 22] hold_timed_out=False", errors="[0.9731, 1.0214]",
        gpu="mismatch", e_lines=None, s=True, extra=""):
    """A pytest -q --tb=short log of the file, with the CPU tests in cpu_fail failing and the GPU test's outcome gpu.

    gpu is passed, mismatch (the page assert after both prints), skip, or raised (e_lines raised before the prints).
    """
    out = ["/x/plugin.py:306: PytestDeprecationWarning: unset"]
    prog = "".join("F" if i in cpu_fail else "." for i in range(3))
    prints = []
    if gpu in ("passed", "mismatch"):
        # Kit p4's test prints the end-of-run pages first, for information, and then the held-save pages it compares.
        end = "end-of-run page errors: [0.0007, 0.0004]" if P4 else None
        prints = [x for x in (held, end, f"{PAGE_LABEL}: {errors}" if errors else None) if x]
    if s and prints:
        out.append(prog + "(EngineCore pid=1) INFO 11-22 21:00:01 [llm.py:1] Supported tasks: ['generate']")
        out.extend(prints)
        out.append({"passed": ".", "mismatch": "F"}[gpu])
    else:
        out.append(prog + {"passed": ".", "mismatch": "F", "skip": "s", "raised": "F"}[gpu])
    out.append(extra) if extra else None
    failed = [CPU_IDS[i] for i in cpu_fail] + ([GPU_ID] if gpu in ("mismatch", "raised") else [])
    if failed:
        out.append("=================================== FAILURES ===================================")
        for i in cpu_fail:
            out += [f"_ {CPU_IDS[i].replace('::', '.')} _", "E   assert False"]
        if gpu in ("mismatch", "raised"):
            out += ["_____ TestHF3FSPreemptionEndToEnd.test_preempted_request_saves_its_own_kv _____", f"{TF}:300: in test_preempted_request_saves_its_own_kv"]
            out += e_lines or ["    assert max(errors) < 0.05, errors", f"E   AssertionError: {errors}", "E   assert 1.0214 < 0.05"]
            if not s and prints:
                out += ["----------------------------- Captured stdout call -----------------------------"] + prints
        out.append("=========================== short test summary info ============================")
        out += [f"FAILED {TF}::{t}" for t in failed]
    n_pass = 3 - len(cpu_fail) + (1 if gpu == "passed" else 0)
    parts = ([f"{len(failed)} failed"] if failed else []) + ([f"{n_pass} passed"] if n_pass else []) + (["1 skipped"] if gpu == "skip" else [])
    out.append(", ".join(parts) + ", 20 warnings in 61.20s (0:01:01)")
    return "\n".join(out) + "\n", (1 if failed else 0)


CONTROL = log(cpu_fail=(0, 1))
FIX = log(held="held=[20, 21, 22, 23] reused=[21, 22] hold_timed_out=True", errors="[0.0012, 0.0009]", gpu="passed")


def judged(control=CONTROL, fix=FIX, env=GPU_ENV, stopped=None):
    """The verdict on an OUT with the two arms' (log or None, exit) pairs."""
    d = tempfile.mkdtemp(prefix="hf3fs-p1-")
    try:
        status = []
        for arm, pair in (("control", control), ("fix", fix)):
            text, rc = pair
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


# ---------------------------------------------------------------- CONFIRMED and its parts
r = judged()
check("CONFIRMED: CONTROL fails the comparison near 1 with preconditions met, FIX passes with the hold timed out; exit 0", r["verdict"] == "CONFIRMED" and r["_rc"] == 0)
c, f = r["arms"]["control"], r["arms"]["fix"]
check("the held line is parsed into held, reused and hold_timed_out", c["held"] == [20, 21, 22, 23] and c["reused"] == [21, 22] and c["hold_timed_out"] is False and f["hold_timed_out"] is True)
check("the page errors are parsed, and CONTROL's mismatch is recorded with its maximum", c["errors"] == [0.9731, 1.0214] and c["gpu"] == "mismatch" and c["max_error"] == 1.0214)
check("CONTROL's failing hook CPU tests are recorded and decide nothing", c["cpu_failed"] == CPU_IDS[:2])

# ---------------------------------------------------------------- FINDING
r = judged(fix=log(held="held=[20] reused=[21] hold_timed_out=True"))
check("FINDING: FIX failing the page comparison near 1; exit 2", r["verdict"] == "FINDING" and r["_rc"] == 2 and "mismatch" in r["why"])
r = judged(fix=log(held="held=[20] reused=[21] hold_timed_out=True", errors="[0.0012, 0.07]",
                   e_lines=["E   AssertionError: [0.0012, 0.07]", "E   assert 0.07 < 0.05"]))
check("FINDING: FIX failing with a 0.07 error, at or above 0.05", r["verdict"] == "FINDING" and r["arms"]["fix"]["max_error"] == 0.07)
r = judged(fix=log(cpu_fail=(1,), held="held=[20] reused=[21] hold_timed_out=True", errors="[0.001]", gpu="passed"))
check("FINDING: a FIX CPU test failing, though its GPU test passed", r["verdict"] == "FINDING" and "CPU tests failed" in r["why"])
r = judged(fix=log(gpu="raised", e_lines=["E   AssertionError: saves did not finish"]))
check("FINDING: FIX's GPU test failing before the comparison, not on a precondition", r["verdict"] == "FINDING" and r["arms"]["fix"]["gpu"] == "failed")
r = judged(fix=("...(EngineCore pid=1) ERROR Triton Error [CUDA]: an illegal memory access was encountered\nFatal Python error: Aborted\n", 134))
check("FINDING: FIX hitting an illegal access, even with no summary", r["verdict"] == "FINDING" and r["arms"]["fix"]["gpu"] == "faulted")
r = judged(fix=log(held="held=[20] reused=[21] hold_timed_out=True", errors="[0.0012, 0.07]", gpu="passed"))
check("FINDING: FIX shown passing yet printing a 0.07 error", r["verdict"] == "FINDING")
r = judged(fix=log(held="held=[20] reused=[21] hold_timed_out=True"), env=None)
check("a FINDING outranks a gap", r["verdict"] == "FINDING")

# ---------------------------------------------------------------- INCONCLUSIVE: preconditions and the control
# The test's own assert messages, written out here so a verdict.py that misquotes one is caught.
for name, text in (("save held", "no save of the target was held"), ("target preempted", "the target was not preempted"),
                   ("held block reused", "no held block was reused by the other request")):
    r = judged(control=log(cpu_fail=(0, 1), gpu="raised", e_lines=[f"E   AssertionError: {text}"]))
    check(f"INCONCLUSIVE: CONTROL's precondition '{name}' not met; exit 5", r["verdict"] == "INCONCLUSIVE" and r["_rc"] == 5
          and r["arms"]["control"]["gpu"] == "precondition" and f"precondition not met: {name}" in r["why"])
r = judged(fix=log(gpu="raised", e_lines=["E   AssertionError: the target was not preempted"]))
check("INCONCLUSIVE, not FINDING: FIX's target was not preempted", r["verdict"] == "INCONCLUSIVE" and "target preempted" in r["why"])
r = judged(control=log(cpu_fail=(0, 1), held="held=[20, 21] reused=[] hold_timed_out=False"))
check("INCONCLUSIVE: a held line with no reused block is a precondition not met", r["verdict"] == "INCONCLUSIVE" and r["arms"]["control"]["gpu"] == "precondition")
r = judged(control=log(cpu_fail=(0, 1), errors="[0.0011, 0.0009]", gpu="passed"))
check("INCONCLUSIVE: CONTROL's GPU test passing", r["verdict"] == "INCONCLUSIVE" and "passed instead of failing" in r["why"])
r = judged(control=log(cpu_fail=(0, 1), errors="[0.2, 0.1]"))
check("INCONCLUSIVE: CONTROL failing with a 0.2 error, not another request's KV", r["verdict"] == "INCONCLUSIVE" and "under 0.5" in r["why"])
r = judged(control=log(cpu_fail=(0, 1), held="held=[20] reused=[20] hold_timed_out=True"))
check("INCONCLUSIVE: CONTROL failing the comparison with its hold timed out", r["verdict"] == "INCONCLUSIVE" and "CONTROL's hold timed out" in r["why"])
r = judged(fix=log(held="held=[20] reused=[21] hold_timed_out=False", errors="[0.001]", gpu="passed"))
check("INCONCLUSIVE: FIX passing without its hold timing out", r["verdict"] == "INCONCLUSIVE" and "FIX passed but its hold did not time out" in r["why"])
r = judged(control=log(cpu_fail=(0, 1), gpu="raised", e_lines=["E   AssertionError: a target block was not stored"]))
check("INCONCLUSIVE: CONTROL's GPU test failing before its comparison", r["verdict"] == "INCONCLUSIVE" and r["arms"]["control"]["gpu"] == "failed")
r = judged(control=("..(EngineCore pid=1) ERROR CUDA error: an illegal memory access was encountered\n", 134))
check("INCONCLUSIVE: CONTROL faulting rather than failing the comparison", r["verdict"] == "INCONCLUSIVE" and r["arms"]["control"]["gpu"] == "faulted")

# ---------------------------------------------------------------- NOT RUN and INCOMPLETE
kv = "E   ValueError: To serve at least one request with the model's max seq len (1024), (0.04 GiB KV cache is needed, which is larger than the available KV cache memory (0.01 GiB)."
r = judged(control=log(cpu_fail=(0, 1), gpu="raised", e_lines=[kv]))
check("NOT RUN: CONTROL without KV cache memory; exit 4", r["verdict"] == "NOT RUN" and r["_rc"] == 4 and "KV cache memory" in r["why"])
r = judged(fix=log(gpu="raised", e_lines=["E   huggingface_hub.errors.LocalEntryNotFoundError: no snapshot"]))
check("NOT RUN: FIX unable to load the model offline", r["verdict"] == "NOT RUN" and "model download" in r["why"])
r = judged(fix=log(gpu="raised", e_lines=["E   torch.OutOfMemoryError: CUDA out of memory."]))
check("NOT RUN: FIX out of GPU memory", r["verdict"] == "NOT RUN")
cap = log(gpu="raised", e_lines=["E   AssertionError: saves did not finish"], extra="WARNING huggingface_hub Cannot find the requested files in the disk cache")
r = judged(fix=cap)
check("a captured line that looks like a harness cause does not turn a FIX failure into NOT RUN", r["verdict"] == "FINDING")
cpu = {a: (read(CPU_LOGS, f"e2e-{a}.log"), 1 if a == "control" else 0) for a in V.ARMS}
r = judged(control=cpu["control"], fix=cpu["fix"], env={"cuda_available": False, "device_name": None})
check("INCOMPLETE: the real CPU logs, where the GPU test skips; CONTROL's two hook tests fail there and FIX's pass",
      r["verdict"] == "INCOMPLETE" and r["arms"]["control"]["cpu_failed"] == CPU_IDS[:2] and r["arms"]["fix"]["cpu_failed"] == []
      and r["arms"]["fix"]["gpu"] == "incomplete" and r["arms"]["control"]["gpu"] == "incomplete")
r = judged(control=cpu["control"], fix=cpu["fix"])
check("INCOMPLETE: the real CPU logs with a CUDA env.json still say the GPU test was skipped", r["verdict"] == "INCOMPLETE" and "skipped" in r["why"])
r = judged(fix=log(held="held=[20] reused=[21] hold_timed_out=True", errors="[0.001]", gpu="passed", s=False))
check("INCOMPLETE: FIX passing without -s prints no held line, so it shows nothing", r["verdict"] == "INCOMPLETE" and "not printed" in r["why"])
r = judged(control=log(cpu_fail=(0, 1), s=False))
check("without -s CONTROL's prints are read from its captured stdout", r["arms"]["control"]["gpu"] == "mismatch")
for arm in V.ARMS:
    r = judged(**{arm: (None, None)})
    check(f"INCOMPLETE: no {arm.upper()} log; exit 3", r["verdict"] == "INCOMPLETE" and r["_rc"] == 3)
r = judged(fix=("...Fatal Python error: Aborted\n", 134))
check("INCOMPLETE: FIX dying before its summary without a fault", r["verdict"] == "INCOMPLETE")
r = judged(fix=(FIX[0], 124))
check("INCOMPLETE: FIX cut by its cap", r["verdict"] == "INCOMPLETE")
r = judged(fix=(f"1 passed in 9.0s\nheld=[20] reused=[21] hold_timed_out=True\n{PAGE_LABEL}: [0.001]\n", 0))
check("INCOMPLETE: a FIX process that ran one test, not the file's four", r["verdict"] == "INCOMPLETE" and "does not count" in r["why"])
r = judged(env={"cuda_available": False, "device_name": None})
check("INCOMPLETE: no CUDA", r["verdict"] == "INCOMPLETE")
r = judged(stopped="the budget ran out before test-fix")
check("INCOMPLETE: a STOPPED run", r["verdict"] == "INCOMPLETE")

# ---------------------------------------------------------------- the printout
r = judged()
t = r["_text"]
check("verdict.txt prints each arm's summary, held line, page errors and traceback, then the verdict",
      "CONTROL: GPU test mismatch (exit 1): 3 failed, 1 passed, 20 warnings in 61.20s (0:01:01)" in t
      and "FIX: GPU test passed (exit 0): 4 passed, 20 warnings in 61.20s (0:01:01)" in t
      and "  held line: held=[20, 21, 22, 23] reused=[21, 22] hold_timed_out=False" in t and RENDER_LABEL + "[0.9731, 1.0214]" in t
      and "    E   AssertionError: [0.9731, 1.0214]" in t and t.rstrip().endswith("VERDICT: CONFIRMED"))

# ---------------------------------------------------------------- kits p2 and p3: the KV memory lines, on the earlier run's real GPU logs
if P2 and not P4:
    gpu = {a: (read(f"gpu-{RUN}-logs", f"e2e-{a}.log"), 1) for a in V.ARMS}
    r = judged(control=gpu["control"], fix=gpu["fix"])
    t = r["_text"]
    check(f"run {RUN}'s real logs: NOT RUN in both arms on KV cache memory; exit 4",
          r["verdict"] == "NOT RUN" and r["_rc"] == 4 and all(r["arms"][a]["gpu"] == "not run" and "KV cache memory" in r["arms"][a]["why"] for a in V.ARMS))
    check(f"run {RUN}'s real logs: each arm prints vLLM's 'Available KV cache memory' line and the startup check's 'available KV cache memory' line",
          t.count("kv memory: ") >= 4 and t.count(f"Available KV cache memory: {KV_GIB}") == 2
          and t.count("larger than the available KV cache memory (0.03 GiB)") >= 2)
    one = "(MainProcess pid=1) INFO 11-22 13:08:49 [gpu_worker.py:846] Available KV cache memory: 6.1 GiB\n"
    r = judged(control=(one + CONTROL[0], CONTROL[1]))
    check("a run that passes its memory check still prints the KV memory line, and decides as before",
          r["verdict"] == "CONFIRMED" and "  kv memory: 1:(MainProcess pid=1) INFO 11-22 13:08:49 [gpu_worker.py:846] Available KV cache memory: 6.1 GiB" in r["_text"])

# ---------------------------------------------------------------- kit p4: the held-save line, and a setup step failing in both arms
if P4:
    gpu = {a: (read("gpu-p3-logs", f"e2e-{a}.log"), 1) for a in V.ARMS}
    r = judged(control=gpu["control"], fix=gpu["fix"])
    check("run p3's real logs: both arms stopped at the prefix cache reset, line 255, before the comparison, which is NOT RUN and not a FINDING; exit 4",
          r["verdict"] == "NOT RUN" and r["_rc"] == 4 and all(r["arms"][a]["gpu"] == "failed" and r["arms"][a]["fail_at"] == 255 for a in V.ARMS)
          and "both arms' GPU tests failed before the page comparison" in r["why"])
    check("run p3's real logs: each arm still prints vLLM's 'Available KV cache memory' line",
          r["_text"].count(f"Available KV cache memory: {KV_GIB}") == 2)
    # A NOT RUN on memory must still print the startup check's lowercase line, here on run p2's real logs.
    mem = {a: (read("gpu-p2-logs", f"e2e-{a}.log"), 1) for a in V.ARMS}
    r = judged(control=mem["control"], fix=mem["fix"])
    check("run p2's real logs: NOT RUN on KV cache memory, printing each arm's 'Available KV cache memory' and 'available KV cache memory' lines",
          r["verdict"] == "NOT RUN" and r["_text"].count("kv memory: ") >= 4 and r["_text"].count("kv memory: ") - r["_text"].count("Available KV cache memory: 14.92 GiB") >= 2)
    early = log(gpu="raised", e_lines=["E   Failed: the local prefix cache could not be reset"])
    r = judged(fix=early)
    check("FINDING: FIX failing before the comparison while CONTROL reached it and failed it", r["verdict"] == "FINDING" and r["arms"]["fix"]["gpu"] == "failed")
    r = judged(control=log(cpu_fail=(0, 1), gpu="raised", e_lines=["E   Failed: the local prefix cache could not be reset"]), fix=early)
    check("NOT RUN: both arms failing before the comparison, built", r["verdict"] == "NOT RUN")
    r = judged(control=log(cpu_fail=(0, 1), gpu="raised", e_lines=["E   Failed: the local prefix cache could not be reset"]))
    check("INCONCLUSIVE: CONTROL failing before the comparison while FIX passes", r["verdict"] == "INCONCLUSIVE")
    old_c = CONTROL[0].replace("held-save page errors: ", "relative page errors: ").replace("end-of-run page errors: [0.0007, 0.0004]\n", "")
    old_f = FIX[0].replace("held-save page errors: ", "relative page errors: ").replace("end-of-run page errors: [0.0007, 0.0004]\n", "")
    r = judged(control=(old_c, 1), fix=(old_f, 0))
    check("INCOMPLETE: logs with only the older 'relative page errors' line decide nothing, though they would have CONFIRMED",
          r["verdict"] == "INCOMPLETE" and all("older test's page errors line" in r["arms"][a]["why"] for a in V.ARMS))
    # A FIX log failing its comparison at 1.0214, with no CPU failure, whose page line is the older one.
    old_fail = log(held="held=[20] reused=[21] hold_timed_out=True")[0]
    old_fail = old_fail.replace("held-save page errors: ", "relative page errors: ").replace("end-of-run page errors: [0.0007, 0.0004]\n", "")
    r = judged(fix=(old_fail, 1))
    check("INCOMPLETE, not FINDING: a FIX log whose only page line is the older one, at 1.0214", r["verdict"] == "INCOMPLETE")
    r = judged(fix=(FIX[0].replace("end-of-run page errors: [0.0007, 0.0004]", "end-of-run page errors: [0.9, 1.0]"), 0))
    check("the end-of-run pages are information only: FIX's end-of-run 1.0 with held-save 0.0012 still CONFIRMS, and both lines are printed",
          r["verdict"] == "CONFIRMED" and "  end-of-run page errors (information only): [0.9, 1.0]" in r["_text"] and "  held-save page errors: [0.0012, 0.0009]" in r["_text"])
    r = judged(fix=log(held="held=[20] reused=[21] hold_timed_out=True", errors=None, gpu="mismatch",
                       e_lines=["E   AssertionError: the held save did not finish"]))
    check("FINDING: FIX whose held save never finished, so no held-save line, while CONTROL reached the comparison",
          r["verdict"] == "FINDING" and r["arms"]["fix"]["errors"] is None)

print()
print("all unit checks passed" if failures == 0 else f"{failures} unit check(s) failed")
sys.exit(1 if failures else 0)
