"""Unit checks for the vLLM HF3FS preemption kit p7's verdict.py: the fenced head (FIX) against p6's code with the new test (CONTROL).

usage: python3 -I hack/vllm-hf3fs-preemption-p7-kit-check.py KIT_DIR FAKE_DIR
FAKE_DIR holds cpu-logs-p7/e2e-{control,fix}.log, both arms run on CPU at kit p7's pinned trees, where both GPU tests skip.
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


TF = "tests/v1/kv_connector/unit/test_hf3fs_preemption.py"
FIRST = "TestHF3FSPreemptionEndToEnd::test_preempted_request_saves_its_own_kv"
NEW = "TestHF3FSPreemptionEndToEnd::test_failed_gather_still_fences_its_reads"
GPU_ENV = {"cuda_available": True, "device_name": "NVIDIA A10G", "torch": "t", "torch_cuda": "13.0", "triton": "3"}
NEW_E = ["E   assert (None is not None)", "E    +  where None = <_SaveGather object at 0x7f00>.cuda_event"]
DUR = [f"61.20s call     {TF}::{FIRST}", f"9.10s call     {TF}::{NEW}"]


def log(first="passed", new="passed", timed_out=True, errors="[0.0, 0.0, 0.0]", first_e=None, first_at=321, new_e=None):
    """A `pytest -q -s --tb=short --durations=0` log of the two-test file."""
    out = ["/x/plugin.py:306: PytestDeprecationWarning: unset"]
    if first in ("passed", "mismatch"):
        out += ["(EngineCore pid=1) INFO start", f"held=[32, 33, 34] reused=[33, 34] hold_timed_out={timed_out}",
                "end-of-run page errors: [0.0, 0.0, 0.0]", f"held-save page errors: {errors}"]
    out.append(("." if first == "passed" else "F") + ("." if new == "passed" else "F"))
    failed = ([FIRST] if first != "passed" else []) + ([NEW] if new != "passed" else [])
    if failed:
        out.append("=================================== FAILURES ===================================")
        if first != "passed":
            out += ["_____ TestHF3FSPreemptionEndToEnd.test_preempted_request_saves_its_own_kv _____", f"{TF}:{first_at}: in test_preempted_request_saves_its_own_kv"]
            out += first_e or [f"E   AssertionError: {errors}"]
        if new != "passed":
            out += ["_____ TestHF3FSPreemptionEndToEnd.test_failed_gather_still_fences_its_reads _____", f"{TF}:354: in test_failed_gather_still_fences_its_reads"]
            out += new_e or NEW_E
        out.append("=========================== short test summary info ============================")
        out += [f"FAILED {TF}::{t}" for t in failed]
    out.append("============================= slowest durations ==============================")
    out += DUR
    n_pass = 2 - len(failed)
    out.append(", ".join(([f"{len(failed)} failed"] if failed else []) + ([f"{n_pass} passed"] if n_pass else [])) + ", 21 warnings in 72.34s (0:01:12)")
    return "\n".join(out) + "\n", (1 if failed else 0)


CONTROL = log(new="failed")
FIX = log()


def judged(control=CONTROL, fix=FIX, env=GPU_ENV, stopped=None):
    d = tempfile.mkdtemp(prefix="hf3fs-p7-")
    try:
        status = []
        for arm, (text, rc) in (("control", control), ("fix", fix)):
            if text is not None:
                open(os.path.join(d, f"e2e-{arm}.log"), "w", newline="").write(text)
            if rc is not None:
                status.append(f"test-{arm} exit={rc} t=1")
        open(os.path.join(d, "status.txt"), "w").write("\n".join(status) + "\n")
        if env is not None:
            json.dump(env, open(os.path.join(d, "env.json"), "w"))
        if stopped:
            open(os.path.join(d, "STOPPED"), "w").write(stopped)
        r = V.judge(d)
        with contextlib.redirect_stdout(io.StringIO()) as buf:
            r["_rc"] = V.main(["verdict.py", d])
        r["_text"] = buf.getvalue()
        return r
    finally:
        shutil.rmtree(d)


r = judged()
t = r["_text"]
check("CONFIRMED: FIX passes both, the first with every held-save page error 0.0; CONTROL passes the first and fails the new one; exit 0",
      r["verdict"] == "CONFIRMED" and r["_rc"] == 0)
check("the printout has each arm's summary verbatim, CONTROL's new-test E lines verbatim, the held and page-error lines and the durations",
      "  pytest summary (verbatim): 1 failed, 1 passed, 21 warnings in 72.34s (0:01:12)\n" in t
      and "  pytest summary (verbatim): 2 passed, 21 warnings in 72.34s (0:01:12)\n" in t
      and "    E   assert (None is not None)\n" in t and "    E    +  where None = <_SaveGather object at 0x7f00>.cuda_event\n" in t
      and "  held-save page errors: [0.0, 0.0, 0.0]" in t and t.count(f"    61.20s call     {TF}::{FIRST}") == 2
      and t.count(f"    9.10s call     {TF}::{NEW}") == 2 and "test_failed_gather_still_fences_its_reads: FAILED" in t
      and "test_failed_gather_still_fences_its_reads: passed" in t and t.rstrip().endswith("VERDICT: CONFIRMED"))
r = judged(control=log())
check("INCONCLUSIVE: CONTROL passes the new test, so it does not catch the bug; exit 5",
      r["verdict"] == "INCONCLUSIVE" and r["_rc"] == 5 and "CONTROL passed the new test" in r["why"])
r = judged(control=log(first="mismatch", new="failed", errors="[0.0, 1.0049]"))
check("INCONCLUSIVE: CONTROL fails the first test too, where p6's code passes it", r["verdict"] == "INCONCLUSIVE" and "CONTROL's first test mismatch" in r["why"])
r = judged(fix=log(new="failed"))
check("FINDING: FIX fails the new test; exit 2", r["verdict"] == "FINDING" and r["_rc"] == 2 and "the new test failed" in r["why"])
r = judged(fix=log(first="mismatch", errors="[0.0, 1.0049]"))
check("FINDING: FIX fails the first test's page comparison", r["verdict"] == "FINDING")
r = judged(fix=log(errors="[0.0, 0.07]"))
check("FINDING: FIX's first test prints a 0.07 held-save error", r["verdict"] == "FINDING")
r = judged(fix=log(errors="[0.0, 0.0012]"))
check("INCONCLUSIVE: FIX's first test passes with a 0.0012 error, not 0.0", r["verdict"] == "INCONCLUSIVE" and "expected 0.0" in r["why"])
r = judged(fix=log(timed_out=False))
check("INCONCLUSIVE: FIX's first test passes without its hold timing out", r["verdict"] == "INCONCLUSIVE" and "did not time out" in r["why"])
r = judged(control=log(first="raised", new="failed", first_e=["E   AssertionError: the target was not preempted"]))
check("INCONCLUSIVE: a precondition not met in CONTROL", r["verdict"] == "INCONCLUSIVE" and "target preempted" in r["why"])
reset = ["E   Failed: the local prefix cache could not be reset"]
r = judged(control=log(first="raised", new="failed", first_e=reset, first_at=268), fix=log(first="raised", first_e=reset, first_at=268))
check("NOT RUN: both arms' first tests fail at the same line with the same error; exit 4", r["verdict"] == "NOT RUN" and r["_rc"] == 4)
r = judged(control=log(first="raised", new="failed", first_e=reset, first_at=268), fix=log(first="raised", first_e=["E   RuntimeError: x"], first_at=240))
check("FINDING: both arms' first tests fail early, but FIX elsewhere with another error", r["verdict"] == "FINDING")
kv = ["E   ValueError: (0.04 GiB KV cache is needed, which is larger than the available KV cache memory (0.03 GiB)."]
r = judged(control=log(first="raised", new="failed", first_e=kv))
check("NOT RUN: CONTROL without KV cache memory", r["verdict"] == "NOT RUN")
cpu = {a: (open(os.path.join(FAKES, "cpu-logs-p7", f"e2e-{a}.log"), errors="replace", newline="").read(), 0) for a in V.ARMS}
r = judged(control=cpu["control"], fix=cpu["fix"], env={"cuda_available": False, "device_name": None})
check("INCOMPLETE: the real CPU logs at the p7 trees, where both GPU tests skip", r["verdict"] == "INCOMPLETE" and "skipped" in r["why"])
r = judged(fix=(FIX[0].replace("2 passed, 21 warnings", "3 passed, 21 warnings"), 0))
check("INCOMPLETE: a FIX process that counted three tests, not the file's two", r["verdict"] == "INCOMPLETE")
r = judged(fix=(None, None))
check("INCOMPLETE: no FIX log", r["verdict"] == "INCOMPLETE")
r = judged(stopped="the budget ran out before test-fix")
check("INCOMPLETE: a STOPPED run", r["verdict"] == "INCOMPLETE")
r = judged(fix=("(EngineCore pid=1) ERROR CUDA error: an illegal memory access was encountered\n", 134))
check("FINDING: FIX faulting", r["verdict"] == "FINDING")

print()
print("all unit checks passed" if failures == 0 else f"{failures} unit check(s) failed")
sys.exit(1 if failures else 0)
