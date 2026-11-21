"""Unit checks for the vLLM #69058 kit's verdict.py, on real CPU pytest logs and on built ones.

usage: python3 -I hack/vllm-69058-kit-check.py KIT_DIR CPU_LOG_DIR
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

KIT, LOGS = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location("verdict", os.path.join(KIT, "verdict.py"))
V = importlib.util.module_from_spec(spec)
spec.loader.exec_module(V)

failures = 0


def check(name, cond):
    global failures
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        failures += 1


F = V.FILE
OLD = [
    F + "::TestHf3fsMockClient::test_init_creates_file",
    F + "::TestHf3fsMockClient::test_multiple_tensors_rw",
    F + "::TestHF3FSKVConnectorStats::test_clone_and_reset",
]
NEW = sorted(V.EXPECTED_A)
CUDA = V.CUDA_TEST
LATER = V.SCHED + "test_failed_later_batch_keeps_prefix_and_saves_the_rest"
EF, ER = V.E2E_FAIL, V.E2E_RECOMPUTE
GPU_ENV = {"cuda_available": True, "device_name": "NVIDIA A10G", "torch": "t", "torch_cuda": "12.9", "triton": "3"}
# The traceback lines of an end-to-end failure, by how it failed.
HOW = {
    "finish_error": ['>           assert retry.finish_reason == "error"', "E           AssertionError: assert 'length' == 'error'"],
    "finish_length": ['>       assert retry.finish_reason == "length"', "E       AssertionError: assert 'error' == 'length'"],
    "token_ids": [">       assert retry.token_ids == cold.token_ids", "E       assert [2, 50118, 133] == [2, 50118, 4148]"],
    "logprobs": [">       check_logprobs_close(", "", "    def check_logprobs_close(", ">           assert output_id_0 in logprobs_1", "E           AssertionError: Test0:"],
    "timeout": [">           _wait_until(lambda: metadata.num_stored_keys() >= num_target_blocks)",
                '>           assert time.monotonic() < deadline, "condition not met before the timeout"',
                "E           AssertionError: condition not met before the timeout"],
    "oom": [">       with vllm_runner(E2E_MODEL, **common_kwargs) as runner:", "E       torch.OutOfMemoryError: CUDA out of memory. Tried to allocate 20.00 MiB."],
    "layout": [">           with (", "E       RuntimeError: HF3FS register_kv_caches: unsupported KV cache layout"],
    "noread": [">           assert faults.num_failed_reads > 0", "E           assert 0 > 0"],
    "download": [">       with vllm_runner(E2E_MODEL, **common_kwargs) as runner:",
                 "E       huggingface_hub.errors.LocalEntryNotFoundError: Cannot find the requested files in the disk cache"],
    "other": [">           retry = _greedy_output(llm, target)", "E           ValueError: something else broke"],
    # A deciding assertion's text in an inner frame, not on the test's own ">" line, must not count as deciding.
    "inner_text": [">           retry = _greedy_output(llm, target)", '    assert retry.finish_reason == "error"', "E           KeyError: 'outputs'"],
}


def make_log(outcomes, deselected=0, summary=True, extra_counts="", how=None, prefix=None):
    """A `pytest -rA` log in the shape of the real ones, for the given {test id: outcome} and end-to-end failure kinds."""
    how = how or {}
    lines = ["============================= test session starts ==============================", f"collected {len(outcomes) + deselected} items"]
    shown = (lambda t: t.replace(F, prefix, 1)) if prefix else (lambda t: t)
    errored = [t for t, o in outcomes.items() if o == "ERROR"]
    if errored:
        lines.append("==================================== ERRORS ====================================")
        for t in errored:
            lines.append(f"_ ERROR at setup of {t.split('::', 1)[1].replace('::', '.')} _")
            lines.append("E       RuntimeError: fixture setup failed")
    failed = [t for t, o in outcomes.items() if o == "FAILED"]
    if failed:
        lines.append("=================================== FAILURES ===================================")
        for t in failed:
            lines.append(f"_____ {t.split('::', 1)[1].replace('::', '.')} _____")
            if t in V.EXPECTED_C:
                lines.extend(HOW[how.get(t, "finish_error" if t == EF else "token_ids")])
            else:
                lines.append("E       assert set() == {3, 5}")
    lines.append("=========================== short test summary info ============================")
    for t, o in outcomes.items():
        if o == "SKIPPED":
            lines.append(f"SKIPPED [1] {F}:384: a successful load scatters with a Triton kernel")
        else:
            lines.append(f"{o} {shown(t)}")
    if summary:
        parts = []
        for word, o in (("failed", "FAILED"), ("passed", "PASSED"), ("skipped", "SKIPPED"), ("errors", "ERROR")):
            n = sum(1 for x in outcomes.values() if x == o)
            if n:
                parts.append(f"{n} {word}")
        if deselected:
            parts.append(f"{deselected} deselected")
        body = ", ".join(parts) + extra_counts
        lines.append(f"============ {body}, 1 warning in 2.50s ============")
    return "\n".join(lines) + "\n"


def expected_runs():
    """The six runs as the fix claims they come out on a GPU."""
    return {
        "base-a": {t: "FAILED" for t in NEW},
        "fix-a": {t: "PASSED" for t in NEW},
        "base-c": {EF: "FAILED", ER: "FAILED"},
        "fix-c": {EF: "PASSED", ER: "PASSED"},
        "base-b": {**{t: "PASSED" for t in OLD}, **{t: "FAILED" for t in NEW}, EF: "FAILED", ER: "FAILED"},
        "fix-b": {**{t: "PASSED" for t in OLD + NEW}, EF: "PASSED", ER: "PASSED"},
    }


def build(runs=None, env=GPU_ENV, rcs=None, texts=None, stopped=None, how=None, not_run=None):
    """An OUT directory holding the given runs, env.json and status.txt."""
    d = tempfile.mkdtemp(prefix="v69058-")
    runs = expected_runs() if runs is None else runs
    texts = texts or {}
    how = how or {}
    status = []
    for name in ("base-a", "fix-a", "base-c", "fix-c", "base-b", "fix-b"):
        if name in texts:
            text = texts[name]
        elif name in runs:
            desel = {"a": 18, "c": 24, "b": 0}[name[-1]]
            prefix = "v1/kv_connector/unit/test_hf3fs_connector.py" if name.endswith("-c") else None
            text = make_log(runs[name], deselected=desel, how=how.get(name), prefix=prefix)
        else:
            text = None
        if text is not None:
            with open(os.path.join(d, name + ".log"), "w") as f:
                f.write(text)
        if rcs and name in rcs:
            rc = rcs[name]
        elif name in runs:
            rc = 1 if any(o in ("FAILED", "ERROR") for o in runs[name].values()) else 0
        else:
            rc = None
        if rc is not None:
            status.append(f"test-{name} exit={rc} t=1")
    with open(os.path.join(d, "status.txt"), "w") as f:
        f.write("\n".join(status) + "\n")
    if env is not None:
        with open(os.path.join(d, "env.json"), "w") as f:
            json.dump(env, f)
    if stopped:
        with open(os.path.join(d, "STOPPED"), "w") as f:
            f.write(stopped)
    if not_run:
        with open(os.path.join(d, "c-not-run.txt"), "w") as f:
            f.write(not_run)
    return d


def incomplete_for(rec, text):
    """Whether rec is INCOMPLETE with a gap that names text, so the rule under test is the one that fired."""
    return rec["verdict"] == "INCOMPLETE" and any(text in g for g in rec["gaps"])


def verdict_of(d):
    rec = V.judge(d)
    shutil.rmtree(d)
    return rec


def c_of(**kw):
    return verdict_of(build(**kw))["c"]


def short(t):
    return t.rsplit("::", 1)[1]


# ---------------------------------------------------------------- parsing the real CPU logs of the round-4 diff
base_a = V.parse_log(open(os.path.join(LOGS, "base-a.log")).read())
check("real base-a: the summary line and its time are read", base_a["summary"] and base_a["summary"]["seconds"] == 12.37)
check("real base-a: counts 7 failed, 1 skipped, 18 deselected, 1 warning", base_a["counts"] == {"failed": 7, "skipped": 1, "deselected": 18, "warnings": 1})
check("real base-a: the seven failed tests are the eight less the CUDA-only one", {t for t, o in base_a["outcomes"].items() if o == "FAILED"} == set(NEW) - {CUDA})
check("real base-a: the CUDA-only test appears only as a SKIPPED line", CUDA not in base_a["outcomes"] and len(base_a["skipped_lines"]) == 1)
heads = base_a["assertions"]
check("real base-a: each failure keeps its assertion line, the later-batch test's 'assert 10 == 8' included",
      len(heads) == 7 and sum(a[0] == "E       assert set() == {3, 5}" for a in heads.values()) == 3
      and any("WAITING_FOR_REMOTE_KVS" in a[0] for a in heads.values()) and any("{'id-2': 1} == {'id-2': 65}" in a[0] for a in heads.values())
      and any(a[0].endswith("assert 10 == 8") for a in heads.values()) and any("(64, True) == (0, False)" in a[0] for a in heads.values()))
check("real base-a: the failure sections are keyed by test id", LATER in base_a["sections"] and any("assert 10 == 8" in x for x in base_a["sections"][LATER]))
sep = V.parse_log("__ TestX.test_long[p] __\n_ _ _ _ _ _ _ _\nE   assert 1 == 2\n")
check("a '_ _ _' frame separator is not read as a failure header", list(sep["assertions"]) == ["TestX.test_long[p]"])
base_b = V.parse_log(open(os.path.join(LOGS, "base-b.log")).read())
check("real base-b: counts 11 failed, 12 passed, 3 skipped", (base_b["counts"].get("failed"), base_b["counts"].get("passed"), base_b["counts"].get("skipped")) == (11, 12, 3))
fix_b = V.parse_log(open(os.path.join(LOGS, "fix-b.log")).read())
check("real fix-b: counts 4 failed, 19 passed, 3 skipped", (fix_b["counts"].get("failed"), fix_b["counts"].get("passed"), fix_b["counts"].get("skipped")) == (4, 19, 3))
base_c = V.parse_log(open(os.path.join(LOGS, "base-c.log")).read())
check("real base-c: on CPU both end-to-end tests are skipped, 24 deselected",
      base_c["counts"] == {"skipped": 2, "deselected": 24, "warnings": 1} and base_c["outcomes"] == {} and "needs a CUDA GPU" in base_c["skipped_lines"][0])
check("an id printed from tests/ is read as the id from the repository root",
      V.normalize("v1/kv_connector/unit/test_hf3fs_connector.py::TestHF3FSLoadFailureEndToEnd::test_failed_read_honors_policy[fail]") == EF)
cpu = {n: open(os.path.join(LOGS, n + ".log")).read() for n in ("base-a", "fix-a", "base-c", "fix-c", "base-b", "fix-b")}
rec = verdict_of(build(runs={}, texts=cpu, rcs={"base-a": 1, "fix-a": 0, "base-c": 0, "fix-c": 0, "base-b": 1, "fix-b": 1},
                       env={"cuda_available": False, "device_name": None}))
check("the real CPU logs are INCOMPLETE for (a,b), for the skip and for no CUDA", rec["verdict"] == "INCOMPLETE"
      and any("skipped" in g for g in rec["gaps"]) and any("did not see CUDA" in g for g in rec["gaps"]))
check("the real CPU logs are INCOMPLETE for (c), whose two tests were skipped", rec["c"]["verdict"] == "INCOMPLETE" and any("base-c: 2 skipped" in g for g in rec["c"]["gaps"]))
check("the real CPU logs show no test outside the ten that the fix changes", rec["findings"] == [])

# ---------------------------------------------------------------- the unit verdict, (a) and (b)
rec = verdict_of(build())
check("pass: the expected outcomes are AS EXPECTED for both verdicts", rec["verdict"] == "AS EXPECTED" and rec["c"]["verdict"] == "AS EXPECTED"
      and rec["cuda_only_test"] == {"base": "FAILED", "fix": "PASSED"} and rec["findings"] == [])
check("the eight expected tests are the round-4 set", len(NEW) == 8 and LATER in NEW and sum("TestHF3FSSchedulerLoadFailure" in t for t in NEW) == 4)
r = expected_runs(); r["base-a"][LATER] = "PASSED"; r["base-b"][LATER] = "PASSED"
rec = verdict_of(build(runs=r))
check("the by-design pass is gone: the later-batch test passing on base is NOT AS EXPECTED",
      rec["verdict"] == "NOT AS EXPECTED" and any("passed but expected to fail" in d and short(LATER) in d for d in rec["deviations"]))
r = expected_runs(); r["base-b"][LATER] = "PASSED"
rec = verdict_of(build(runs=r))
check("the later-batch test passing on base in the whole file alone is NOT AS EXPECTED", rec["verdict"] == "NOT AS EXPECTED" and any(d.startswith("base-b:") for d in rec["deviations"]))
r = expected_runs(); r["base-b"][OLD[1]] = "FAILED"
rec = verdict_of(build(runs=r))
check("finding: an older test that fails on base and passes with the fix is named, and the verdict is not AS EXPECTED",
      rec["verdict"] == "NOT AS EXPECTED" and rec["findings"] == [f"{OLD[1]}: base FAILED, fix PASSED"])
with contextlib.redirect_stdout(io.StringIO()) as buf:
    print("\n".join(V.render(rec)))
check("finding: verdict.txt prints it on its own FINDING line", f"FINDING outside the ten: {OLD[1]}: base FAILED, fix PASSED" in buf.getvalue())
r = expected_runs(); r["base-b"][OLD[1]] = "FAILED"
rec = verdict_of(build(runs=r, env=None))
check("finding: it is named even when a gap leaves the verdict INCOMPLETE", rec["verdict"] == "INCOMPLETE" and len(rec["findings"]) == 1)
r = expected_runs(); r["base-b"][OLD[1]] = "FAILED"; r["fix-b"][OLD[1]] = "FAILED"
rec = verdict_of(build(runs=r))
check("finding: an older test failing on both sides is a deviation, not a finding", rec["verdict"] == "NOT AS EXPECTED" and rec["findings"] == [])
r = expected_runs(); r["base-b"][ER] = "PASSED"
rec = verdict_of(build(runs=r))
check("an end-to-end test that differs in the whole file is neither a finding nor a unit deviation", rec["verdict"] == "AS EXPECTED" and rec["findings"] == [])
r = expected_runs(); r["base-b"][EF] = "ERROR"
rec = verdict_of(build(runs=r))
check("an end-to-end test that errors in the whole file is left to (c), not a unit gap", rec["verdict"] == "AS EXPECTED")
r = expected_runs(); r["fix-a"][CUDA] = "FAILED"; r["fix-b"][CUDA] = "FAILED"
rec = verdict_of(build(runs=r))
check("fail: the CUDA-only test failing with the fix is NOT AS EXPECTED", rec["verdict"] == "NOT AS EXPECTED" and rec["cuda_only_test"]["fix"] == "FAILED")
r = expected_runs(); r["base-a"][CUDA] = "PASSED"; r["base-b"][CUDA] = "PASSED"
rec = verdict_of(build(runs=r))
check("fail: the CUDA-only test passing on base is NOT AS EXPECTED", rec["verdict"] == "NOT AS EXPECTED")
r = expected_runs(); r["fix-b"][OLD[1]] = "FAILED"
rec = verdict_of(build(runs=r))
check("fail: an older test failing with the fix is NOT AS EXPECTED", rec["verdict"] == "NOT AS EXPECTED" and any(OLD[1] in d for d in rec["deviations"]))
r = expected_runs(); r["fix-a"][CUDA] = "SKIPPED"
rec = verdict_of(build(runs=r))
check("skip: a skipped CUDA-only test is INCOMPLETE, not a pass", incomplete_for(rec, "fix-a: 1 skipped"))
r = expected_runs(); r["fix-b"][OLD[0]] = "SKIPPED"
rec = verdict_of(build(runs=r))
check("skip: a skip anywhere in the whole file is INCOMPLETE", incomplete_for(rec, "fix-b: 1 skipped"))
r = expected_runs(); del r["fix-a"]
rec = verdict_of(build(runs=r))
check("missing: a missing log is INCOMPLETE", incomplete_for(rec, "fix-a: no log"))
r = expected_runs()
rec = verdict_of(build(runs=r, texts={"fix-a": make_log(r["fix-a"], 18, summary=False)}))
check("missing: a log with no summary is INCOMPLETE", incomplete_for(rec, "no pytest summary"))
r = expected_runs(); r["fix-a"] = {t: "PASSED" for t in NEW if t != CUDA}; r["fix-b"] = {**{t: "PASSED" for t in OLD + NEW if t != CUDA}, EF: "PASSED", ER: "PASSED"}
rec = verdict_of(build(runs=r))
check("missing: a CUDA-only test that never ran, with no skip line, is INCOMPLETE", incomplete_for(rec, "fix-a: ran ") and rec["cuda_only_test"]["fix"] == "missing")
rec = verdict_of(build(rcs={"base-a": 1, "fix-a": 2, "base-c": 1, "fix-c": 0, "base-b": 1, "fix-b": 0}))
check("missing: pytest exiting 2 (interrupted) is INCOMPLETE even with a summary", incomplete_for(rec, "fix-a: pytest exited 2, so"))
rec = verdict_of(build(rcs={"base-a": 1, "fix-a": 1, "base-c": 1, "fix-c": 0, "base-b": 1, "fix-b": 0}))
check("missing: an exit code that disagrees with the outcomes is INCOMPLETE", incomplete_for(rec, "fix-a: pytest exited 1 with 0 failed"))
d = build(); open(os.path.join(d, "status.txt"), "w").close()
rec = verdict_of(d)
check("missing: no exit codes in status.txt is INCOMPLETE", incomplete_for(rec, "no exit code in status.txt"))
r = expected_runs(); r["fix-a"][CUDA] = "ERROR"; r["fix-b"][CUDA] = "ERROR"
rec = verdict_of(build(runs=r))
check("error: a unit test that errors in setup is INCOMPLETE", incomplete_for(rec, "fix-a: 1 error(s)"))
check("error: an ERROR outcome line is a gap of its own", incomplete_for(rec, "outcomes other than PASSED or FAILED"))
rec = verdict_of(build(env={"cuda_available": False, "device_name": None}))
check("no CUDA: a run torch saw no GPU in is INCOMPLETE for both", incomplete_for(rec, "did not see CUDA") and rec["c"]["verdict"] == "INCOMPLETE")
rec = verdict_of(build(env={"cuda_available": True, "device_name": ""}))
check("no CUDA: a run whose probe names no device is INCOMPLETE", incomplete_for(rec, "names no CUDA device"))
rec = verdict_of(build(env=None))
check("no env.json is INCOMPLETE", incomplete_for(rec, "env.json unreadable"))
r = expected_runs(); r["fix-b"] = {t: "PASSED" for t in OLD}; r["base-b"] = {t: "PASSED" for t in OLD}
rec = verdict_of(build(runs=r))
check("a whole-file run without the new tests is INCOMPLETE", incomplete_for(rec, "the whole file lacks"))
r = expected_runs()
rec = verdict_of(build(runs=r, texts={"fix-a": make_log(r["fix-a"], 18).replace("8 passed", "9 passed")}))
check("a summary that disagrees with the -rA lines is INCOMPLETE", incomplete_for(rec, "the summary counts"))
r = expected_runs()
rec = verdict_of(build(runs=r, texts={"fix-a": make_log(r["fix-a"], 18).replace(f"PASSED {CUDA}\n", f"PASSED {CUDA}\nPASSED {CUDA}\n")}))
check("a test reported twice is INCOMPLETE", incomplete_for(rec, "reported twice"))
r = expected_runs(); r["fix-b"] = {**{t: "PASSED" for t in OLD[:2] + NEW}, EF: "PASSED", ER: "PASSED"}
rec = verdict_of(build(runs=r))
check("base and fix running different whole-file tests is INCOMPLETE", incomplete_for(rec, "b: base and fix ran different tests"))
rec = verdict_of(build(stopped="the budget ran out before test-fix-b"))
check("a STOPPED run is INCOMPLETE for both", incomplete_for(rec, "the run stopped early") and rec["c"]["verdict"] == "INCOMPLETE")
r = expected_runs(); r["fix-a"][CUDA] = "XPASS"
rec = verdict_of(build(runs=r, texts={"fix-a": make_log(r["fix-a"], 18, extra_counts=", 1 xpassed")}))
check("an xpassed test is INCOMPLETE", incomplete_for(rec, "1 xpassed"))
rec = verdict_of(build(runs={k: {} for k in expected_runs()}, rcs={k: 5 for k in expected_runs()}))
check("runs where no test ran are INCOMPLETE", incomplete_for(rec, "no test ran"))

# ---------------------------------------------------------------- the (c) verdict
c = c_of()
check("(c) pass: base [fail] fails at its finish_reason check, the fix passes both, base [recompute] is recorded",
      c["verdict"] == "AS EXPECTED" and c["base_recompute"] == {"state": "FAILED", "at": "assert retry.token_ids == cold.token_ids"})
r = expected_runs(); r["base-c"][ER] = "PASSED"
c = c_of(runs=r)
check("(c) base [recompute] passing is recorded and does not decide the verdict", c["verdict"] == "AS EXPECTED" and c["base_recompute"] == {"state": "PASSED"})
r = expected_runs(); r["base-c"][EF] = "PASSED"
c = c_of(runs=r)
check("(c) fail: base [fail] passing is NOT AS EXPECTED", c["verdict"] == "NOT AS EXPECTED" and any(d.startswith("base test_failed_read_honors_policy[fail]") for d in c["deviations"]))
r = expected_runs(); r["fix-c"][ER] = "FAILED"
c = c_of(runs=r, how={"fix-c": {ER: "token_ids"}})
check("(c) fail: fix [recompute] failing at its token comparison is NOT AS EXPECTED", c["verdict"] == "NOT AS EXPECTED")
c = c_of(runs=r, how={"fix-c": {ER: "logprobs"}})
check("(c) fail: fix [recompute] failing in check_logprobs_close is NOT AS EXPECTED", c["verdict"] == "NOT AS EXPECTED" and any("check_logprobs_close" in d for d in c["deviations"]))
c = c_of(runs=r, how={"fix-c": {ER: "finish_length"}})
check("(c) fail: fix [recompute] failing at finish_reason == length is NOT AS EXPECTED", c["verdict"] == "NOT AS EXPECTED")
r = expected_runs(); r["fix-c"][EF] = "FAILED"
c = c_of(runs=r, how={"fix-c": {EF: "finish_error"}})
check("(c) fail: fix [fail] failing at its finish_reason check is NOT AS EXPECTED", c["verdict"] == "NOT AS EXPECTED")
for kind, cause in (("timeout", "timeout in the 60 s wait for stored keys"), ("oom", "OOM with two LLM instances"),
                    ("layout", "KV layout registration error"), ("noread", "the failing read never reached HF3FS"),
                    ("download", "model download or offline load failure"), ("other", "other harness failure (FAILED)"),
                    ("inner_text", "other harness failure (FAILED)")):
    r = expected_runs(); r["fix-c"][EF] = "FAILED"
    c = c_of(runs=r, how={"fix-c": {EF: kind}})
    check(f"(c) NOT RUN: a {kind} failure is a harness failure with its cause, never a verdict",
          c["verdict"] == "NOT RUN" and any(n.startswith(f"fix test_failed_read_honors_policy[fail]: {cause}") for n in c["not_run"]))
r = expected_runs(); r["base-c"][EF] = "FAILED"; r["base-c"][ER] = "FAILED"
c = c_of(runs=r, how={"base-c": {ER: "oom"}})
check("(c) NOT RUN on one test outweighs a decided other test", c["verdict"] == "NOT RUN" and len(c["not_run"]) == 1)
r = expected_runs(); r["base-c"][EF] = "ERROR"
c = c_of(runs=r)
check("(c) NOT RUN: a setup error is a harness failure, not a gap", c["verdict"] == "NOT RUN" and any("(ERROR)" in n for n in c["not_run"]) and not c["gaps"])
c = c_of(not_run="model download failure: hf download facebook/opt-125m exited non-zero")
check("(c) NOT RUN: the kit's c-not-run.txt names the cause", c["verdict"] == "NOT RUN" and c["not_run"] == ["model download failure: hf download facebook/opt-125m exited non-zero"])
r = expected_runs(); r["fix-c"][ER] = "SKIPPED"
c = c_of(runs=r)
check("(c) skip: a skipped end-to-end test is INCOMPLETE", c["verdict"] == "INCOMPLETE" and any("fix-c: 1 skipped" in g for g in c["gaps"]))
r = expected_runs(); del r["fix-c"]
c = c_of(runs=r)
check("(c) missing: a missing log is INCOMPLETE", c["verdict"] == "INCOMPLETE" and any("fix-c: no log" in g for g in c["gaps"]))
r = expected_runs()
c = c_of(runs=r, texts={"base-c": make_log(r["base-c"], 24, summary=False)})
check("(c) missing: no summary is INCOMPLETE", c["verdict"] == "INCOMPLETE" and any("base-c: no pytest summary" in g for g in c["gaps"]))
c = c_of(rcs={"base-a": 1, "fix-a": 0, "base-c": 1, "fix-c": 124, "base-b": 1, "fix-b": 0})
check("(c) missing: a run cut by its cap (exit 124) is INCOMPLETE", c["verdict"] == "INCOMPLETE" and any("fix-c: pytest exited 124" in g for g in c["gaps"]))
r = expected_runs(); r["fix-c"] = {EF: "PASSED"}
c = c_of(runs=r)
check("(c) a run of other than the two tests is INCOMPLETE", c["verdict"] == "INCOMPLETE" and any("not the two end-to-end tests" in g for g in c["gaps"]))

# ---------------------------------------------------------------- the two verdicts together, and main
for name, kw, want_overall, want_rc in (
        ("both AS EXPECTED", {}, "AS EXPECTED", 0),
        ("a unit deviation", {"runs": {**expected_runs(), "fix-a": {t: "FAILED" for t in NEW}}}, "NOT AS EXPECTED", 2),
        ("a (c) deviation", {"runs": {**expected_runs(), "base-c": {EF: "PASSED", ER: "FAILED"}}}, "NOT AS EXPECTED", 2),
        ("a gap", {"env": None}, "INCOMPLETE", 3),
        ("(c) NOT RUN", {"not_run": "model download failure: x"}, "NOT RUN", 4)):
    d = build(**kw)
    with contextlib.redirect_stdout(io.StringIO()) as buf:
        rc = V.main(["verdict.py", d])
    saved = json.load(open(os.path.join(d, "verdict.json")))
    check(f"main exits {want_rc} for {name}, prints VERDICT: {want_overall} and writes it to verdict.json",
          rc == want_rc and f"VERDICT: {want_overall}\n" in buf.getvalue() and saved["overall"] == want_overall)
    shutil.rmtree(d)
d = build(not_run="x", runs={**expected_runs(), "fix-a": {t: "FAILED" for t in NEW}})
with contextlib.redirect_stdout(io.StringIO()):
    rc = V.main(["verdict.py", d])
shutil.rmtree(d)
check("a unit deviation outranks (c) NOT RUN in the exit status", rc == 2)

print()
print("all unit checks passed" if failures == 0 else f"{failures} unit check(s) failed")
sys.exit(1 if failures else 0)
