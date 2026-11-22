"""Verdict for the vLLM #69058 kit r4: PR #69095's head (arm A) against our additions (arm B).

usage: python verdict.py OUT
Reads OUT/env.json, OUT/status.txt, OUT/STOPPED if present, and the pytest logs OUT/{a,b}-{1,2}.log.
Writes OUT/verdict.json, OUT/{a,b}-2-illegal.txt for each arm whose step 2 hit an illegal memory access, and prints the verdict.
Step 1 is judged against the spec's counts; step 2 is a result, reported with its first illegal memory access if there is one.
Exit status: 2 if step 1 has a FINDING, else 3 if anything is INCOMPLETE, else 4 if a step 2 is NOT RUN for a harness cause, else 0.
"""

import json
import os
import re
import sys

ARMS = ("a", "b")
# Step 1's expected counts per arm, without deselected tests and warnings.
EXPECTED_1 = {"a": {"failed": 3, "passed": 1}, "b": {"passed": 4}}
STEP3 = "not run: the #69058 issue body names ./run.sh fault and ./run.sh nofault but does not contain run.sh, and kit r3 had none"
# pytest -q prints its summary without the "=" padding that -rA runs have, so both shapes are read.
SUMMARY_RE = re.compile(r"^=*\s*(\d+ [a-z]+(?:, \d+ [a-z]+)*) in ([0-9.]+)s(?: \([^)]*\))?\s*=*$")
COUNT_RE = re.compile(r"(\d+) (passed|failed|skipped|deselected|errors?|xfailed|xpassed|warnings?)")
FAILED_RE = re.compile(r"^(FAILED|ERROR) (\S+)")
ILLEGAL_RE = re.compile(r"illegal memory access|CUDA_ERROR_ILLEGAL_ADDRESS|cudaErrorIllegalAddress")
# vLLM's logger prefixes a record with its source as "[file.py:line]".
LOG_SITE_RE = re.compile(r"\[([\w./-]+\.py):(\d+)\]")
PY_FRAME_RE = re.compile(r'^\s*File "([^"]+)", line (\d+), in (\S+)')
# pytest --tb=long closes each frame with "path:line: " and, for the raising frame, the exception's type.
PYTEST_SITE_RE = re.compile(r"^(\S+\.py):(\d+): (\w+)\s*$")
# Harness causes, matched on the traceback's ">" and E lines only, since captured logs name things like HF_HUB_OFFLINE on every run.
# An illegal memory access is not among them: it is a result and is checked first.
HARNESS_CAUSES = (
    ("KV cache memory", re.compile(r"KV cache is needed, which is larger than the available KV cache memory")),
    ("timeout in the 60 s wait for stored keys", re.compile(r"condition not met before the timeout")),
    ("GPU out of memory", re.compile(r"OutOfMemoryError|CUDA out of memory|out of memory", re.I)),
    ("model download or offline load failure", re.compile(r"LocalEntryNotFoundError|Cannot find the requested files|couldn't connect to|RepositoryNotFound|GatedRepo")),
)


def parse_log(text):
    """One pytest log's summary, counts and the tests its short summary names as failed or errored."""
    # splitlines would also split on form feeds and other separators a log can carry, and the line numbers would drift from the file's.
    lines = text.split("\n")
    summary = None
    for line in lines:
        m = SUMMARY_RE.match(line.strip())
        if m:
            summary = {"line": line.strip(), "body": m.group(1), "seconds": float(m.group(2))}
    counts = {}
    if summary:
        for n, word in COUNT_RE.findall(summary["body"]):
            key = {"error": "errors", "warning": "warnings"}.get(word, word)
            counts[key] = counts.get(key, 0) + int(n)
    failed = [m.group(2) for m in (FAILED_RE.match(x) for x in lines) if m]
    return {"lines": lines, "summary": summary, "counts": counts, "failed": failed}


def extract_illegal(lines):
    """The first illegal memory access in a log: its line, the frame that raised it, how that frame was read, and the block around it."""
    first = next((i for i, x in enumerate(lines) if ILLEGAL_RE.search(x)), None)
    if first is None:
        return None
    line = lines[first]
    rec = {"line_no": first + 1, "line": line.strip()}
    m = LOG_SITE_RE.search(line)
    if m and not line.startswith("E "):
        # A logged error names the site that caught it; under CUDA_LAUNCH_BLOCKING that is the call that faulted.
        site = m.group(0)
        end = first
        while end + 1 < len(lines) and site in lines[end + 1] and end - first < 20:
            end += 1
        rec.update(frame=f"{m.group(1)}:{m.group(2)}", method="logged record", block=lines[first:end + 1])
        return rec
    if line.startswith("E "):
        # pytest prints the raising frame's location after its E lines.
        for j in range(first + 1, min(first + 40, len(lines))):
            s = PYTEST_SITE_RE.match(lines[j])
            if s:
                rec.update(frame=f"{s.group(1)}:{s.group(2)} ({s.group(3)})", method="pytest traceback", block=lines[max(0, first - 25):j + 1])
                return rec
    for k in range(first - 1, max(-1, first - 300), -1):
        if lines[k].startswith("Traceback (most recent call last):"):
            frames = [PY_FRAME_RE.match(x) for x in lines[k:first]]
            frames = [f for f in frames if f]
            if frames:
                inner = frames[-1]
                rec.update(frame=f"{inner.group(1)}:{inner.group(2)} in {inner.group(3)}", method="python traceback", block=lines[k:first + 1])
                return rec
            break
    rec.update(frame=None, method="line only", block=[line])
    return rec


def read_status(out):
    """Map each step name in status.txt to its last recorded exit code."""
    rcs = {}
    path = os.path.join(out, "status.txt")
    if os.path.exists(path):
        for line in open(path):
            m = re.match(r"^(\S+) exit=(-?\d+)", line)
            if m:
                rcs[m.group(1)] = int(m.group(2))
    return rcs


def judge_step1(arm, run, rc):
    """Step 1 on one arm: AS EXPECTED, FINDING, or INCOMPLETE with the reason."""
    if run is None:
        return {"state": "INCOMPLETE", "why": "no log"}
    if run["summary"] is None:
        return {"state": "INCOMPLETE", "why": f"no pytest summary line (exit {rc})"}
    if rc not in (0, 1):
        return {"state": "INCOMPLETE", "why": f"pytest exited {rc}", "summary": run["summary"]["line"]}
    c = {k: v for k, v in run["counts"].items() if k not in ("deselected", "warnings")}
    if rc != (1 if c.get("failed") or c.get("errors") else 0):
        return {"state": "INCOMPLETE", "why": f"pytest exited {rc} with counts {c}", "summary": run["summary"]["line"]}
    rec = {"summary": run["summary"]["line"], "seconds": run["summary"]["seconds"], "counts": c, "failed": run["failed"]}
    rec["state"] = "AS EXPECTED" if c == EXPECTED_1[arm] else "FINDING"
    if rec["state"] == "FINDING":
        rec["why"] = f"counts {c}, expected {EXPECTED_1[arm]}"
    return rec


def judge_step2(run, rc):
    """Step 2 on one arm: a RESULT with its cause and any illegal memory access, NOT RUN for a harness cause, or INCOMPLETE."""
    if run is None:
        return {"state": "INCOMPLETE", "why": "no log", "illegal_access": None}
    illegal = extract_illegal(run["lines"])
    rec = {"summary": run["summary"]["line"] if run["summary"] else None, "exit": rc,
           "failed": run["failed"], "illegal_access": illegal}
    if illegal:
        # A fault on the GPU is what this step looks for, so it is a result even when pytest died before its summary.
        rec.update(state="RESULT", cause="CUDA illegal memory access")
        return rec
    c = run["counts"]
    if run["summary"] is None or rc not in (0, 1):
        rec.update(state="INCOMPLETE", why=f"no summary or an abnormal exit ({rc}) and no illegal memory access")
        return rec
    if c.get("skipped"):
        rec.update(state="INCOMPLETE", why=f"{c['skipped']} skipped, and a skip on the GPU is not a result")
        return rec
    if not c.get("failed") and not c.get("errors"):
        rec.update(state="RESULT", cause="passed")
        return rec
    tb = [x for x in run["lines"] if x.startswith(("E ", ">"))]
    text = "\n".join(tb)
    first_e = next((x.strip() for x in tb if x.startswith("E ")), "no E line")
    for label, pattern in HARNESS_CAUSES:
        if pattern.search(text):
            rec.update(state="NOT RUN", cause=f"{label}: {first_e}")
            return rec
    rec.update(state="RESULT", cause=f"failed: {first_e}")
    return rec


def judge(out):
    rec = {"gaps": [], "arms": {}, "step3": STEP3}
    try:
        env = json.load(open(os.path.join(out, "env.json")))
        rec["env"] = env
        if env.get("cuda_available") is not True or not env.get("device_name"):
            rec["gaps"].append(f"torch did not see a named CUDA device (cuda_available={env.get('cuda_available')!r})")
    except (OSError, ValueError) as e:
        rec["gaps"].append(f"env.json unreadable: {e}")
    if os.path.exists(os.path.join(out, "STOPPED")):
        rec["gaps"].append("the run stopped early: " + open(os.path.join(out, "STOPPED")).read().strip())
    rcs = read_status(out)
    for arm in ARMS:
        runs = {}
        for step in ("1", "2"):
            path = os.path.join(out, f"{arm}-{step}.log")
            # newline="" keeps the carriage returns of progress bars, which text mode would turn into extra lines.
            runs[step] = parse_log(open(path, errors="replace", newline="").read()) if os.path.exists(path) else None
        s1 = judge_step1(arm, runs["1"], rcs.get(f"test-{arm}-1"))
        s2 = judge_step2(runs["2"], rcs.get(f"test-{arm}-2"))
        rec["arms"][arm] = {"step1": s1, "step2": s2}
    states = [rec["arms"][a]["step1"]["state"] for a in ARMS] + [rec["arms"][a]["step2"]["state"] for a in ARMS]
    if "FINDING" in states:
        rec["verdict"] = "FINDING"
    elif rec["gaps"] or "INCOMPLETE" in states:
        rec["verdict"] = "INCOMPLETE"
    elif "NOT RUN" in states:
        rec["verdict"] = "NOT RUN"
    else:
        rec["verdict"] = "AS EXPECTED"
    return rec


def render(rec):
    lines = []
    env = rec.get("env") or {}
    lines.append(f"gpu: {env.get('device_name')} torch: {env.get('torch')} cuda: {env.get('torch_cuda')} triton: {env.get('triton')}")
    for arm in ARMS:
        s1, s2 = rec["arms"][arm]["step1"], rec["arms"][arm]["step2"]
        lines.append(f"arm {arm.upper()} step 1: {s1['state']}: {s1.get('summary')}" + (f" ({s1['why']})" if s1.get("why") else ""))
        for t in s1.get("failed", []):
            lines.append(f"  failed: {t}")
        lines.append(f"arm {arm.upper()} step 2: {s2['state']}: {s2.get('summary')} (exit {s2.get('exit')}); cause: {s2.get('cause', s2.get('why'))}")
        ia = s2.get("illegal_access")
        if ia:
            lines.append(f"arm {arm.upper()} illegal memory access: yes, first at log line {ia['line_no']}, frame {ia['frame']} ({ia['method']})")
            lines.append(f"  {ia['line']}")
        else:
            lines.append(f"arm {arm.upper()} illegal memory access: no")
        lines.append(f"arm {arm.upper()} step 3 (run.sh fault, nofault): {rec['step3']}")
    for g in rec["gaps"]:
        lines.append(f"GAP: {g}")
    # The verdict judges step 1 and whether the run is complete; step 2 is a result, so it gets its own line next to it.
    lines.append("STEP 2 RESULT: " + "; ".join(
        f"arm {a.upper()} {rec['arms'][a]['step2']['state']} {rec['arms'][a]['step2'].get('cause', rec['arms'][a]['step2'].get('why'))}"
        f", illegal memory access {'yes' if rec['arms'][a]['step2'].get('illegal_access') else 'no'}" for a in ARMS))
    lines.append(f"VERDICT: {rec['verdict']}")
    return lines


def main(argv):
    if len(argv) != 2 or not os.path.isdir(argv[1]):
        print("usage: verdict.py OUT", file=sys.stderr)
        return 3
    out = argv[1]
    rec = judge(out)
    for arm in ARMS:
        ia = rec["arms"][arm]["step2"].get("illegal_access")
        if ia:
            with open(os.path.join(out, f"{arm}-2-illegal.txt"), "w") as f:
                f.write("\n".join(ia["block"]) + "\n")
    with open(os.path.join(out, "verdict.json"), "w") as f:
        json.dump(rec, f, indent=1, sort_keys=True)
    print("\n".join(render(rec)))
    return {"AS EXPECTED": 0, "FINDING": 2, "NOT RUN": 4}.get(rec["verdict"], 3)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
