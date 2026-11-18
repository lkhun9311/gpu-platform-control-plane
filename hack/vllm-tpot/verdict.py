#!/usr/bin/env python3
"""The verdict of hack/vllm-tpot-session.sh, read from the records hack/vllm-tpot/state.sh leaves.

    verdict.py <sweep dir> <serving-test-only.diff sha256> <fix.diff sha256>

Prints key=value lines, the import check first, and exits 0 only when the verdict is "confirmed".
"confirmed" means exactly one thing: BEFORE failed on the TPOT assertion with a delta of 5, then AFTER passed all three
servers, on pinned trees, with the fix absent from the imported loggers.py before and present after.
Every other combination is reported by name, because a run that cannot say why it is not confirmed is not evidence.
"""
import re
import sys
import xml.etree.ElementTree as ET

LOGGERS = "/usr/local/lib/python3.12/dist-packages/vllm/v1/metrics/loggers.py"
IMAGE_DIGEST = "sha256:9f77cb6501aa29d5bfa70d0819c153ecebd604d41fc77a9e8cc097cb0e4145bb"
VLLM_COMMIT = "3a1c6c43df5eb5344a3f853c34fac93c274a372f"
TPOT_CASE = re.compile(r"^test_tpot_skips_single_token_requests\[.*text.*\]$")
# pytest renders `assert _tpot_count(server) - before == 2` as `assert (5.0 - 0.0) == 2`.
DELTA = re.compile(r"assert \((-?[0-9.]+) - (-?[0-9.]+)\) == 2")
EXPECTED_BEFORE_DELTA = 5.0
# The server fixture has three parameters, so the TPOT test runs once per server.
EXPECTED_AFTER_CASES = 3


def kv(path):
    try:
        with open(path) as f:
            return dict(line.rstrip("\n").split("=", 1) for line in f if "=" in line)
    except OSError:
        return None


def cases(path):
    """Each testcase as (name, outcome, message), or None when the file is missing or not junit."""
    try:
        root = ET.parse(path).getroot()
    except (OSError, ET.ParseError):
        return None
    out = []
    for tc in root.iter("testcase"):
        outcome, message = "passed", ""
        # An error outranks a failure: a teardown error beside the expected assertion is not the clean expected failure.
        for tag in ("error", "failure", "skipped"):
            el = tc.find(tag)
            if el is not None:
                outcome, message = tag, (el.get("message") or "") + "\n" + (el.text or "")
                break
        out.append((tc.get("name", ""), outcome, message))
    return out


def identity(st, want_diff):
    if st is None:
        return "missing"
    for key, want in (("base_identity", "ok"), ("apply", "ok"), ("applied_identity", "ok"), ("diff_sha256", want_diff)):
        if st.get(key) != want:
            return f"{key}={st.get(key, 'unread')}"
    return "ok"


def before_result(st, tc):
    """failed-as-expected, passed, or why it is neither."""
    if st is None or tc is None:
        return "missing", None
    rc = st.get("tpot_rc")
    if not tc:
        return f"no-cases(rc={rc})", None
    if any(not TPOT_CASE.match(n) for n, _, _ in tc):
        return "unexpected-cases", None
    if rc == "0" and all(o == "passed" for _, o, _ in tc):
        return "passed", None
    if rc != "1" or any(o != "failure" for _, o, _ in tc):
        return f"error(rc={rc},outcomes={','.join(o for _, o, _ in tc)})", None
    deltas = []
    for _, _, msg in tc:
        m = DELTA.search(msg)
        if not m:
            return "failed-elsewhere", None
        deltas.append(float(m.group(1)) - float(m.group(2)))
    if any(d != EXPECTED_BEFORE_DELTA for d in deltas):
        return "failed-with-another-delta", deltas[0]
    return "failed-as-expected", deltas[0]


def after_result(st, tc):
    if st is None or tc is None:
        return "missing"
    rc = st.get("tpot_rc")
    if any(not TPOT_CASE.match(n) for n, _, _ in tc):
        return "unexpected-cases"
    # Three distinct cases, one per server, so a repeated name cannot stand in for a server that never ran.
    if rc == "0" and len({n for n, _, _ in tc}) == len(tc) == EXPECTED_AFTER_CASES and all(o == "passed" for _, o, _ in tc):
        return "passed"
    if rc == "1" and any(o == "failure" for _, o, _ in tc) and not any(o == "error" for _, o, _ in tc):
        return "failed"
    return f"error(rc={rc},cases={len(tc)})"


def file_result(st, tc):
    if st is None or tc is None or "file_rc" not in st:
        return "missing"
    n = {o: sum(1 for _, x, _ in tc if x == o) for o in ("passed", "failure", "error", "skipped")}
    counts = f"{n['passed']} passed, {n['failure']} failed, {n['error']} errors, {n['skipped']} skipped"
    if st["file_rc"] == "0" and n["failure"] == n["error"] == 0 and n["passed"] > 0:
        return f"passed ({counts})"
    return f"not-passed rc={st['file_rc']} ({counts})"


def main(sweep, serving_sha, fix_sha):
    b, a = kv(f"{sweep}/before/state.txt"), kv(f"{sweep}/after/state.txt")
    lines = []

    # The import check comes first: a BEFORE that passes is most likely one that imported a fixed loggers.py.
    # BEFORE is judged first and on its own, because the runner does not start AFTER when BEFORE did not fail.
    if b is None:
        imp = "before-missing"
    elif b.get("loggers_file") != LOGGERS:
        imp = f"wrong-file-before({b.get('loggers_file')})"
    elif b.get("grep_rc") != "1":
        imp = f"fix-present-or-unread-before(grep_rc={b.get('grep_rc')})"
    elif a is None:
        imp = "after-missing"
    elif a.get("loggers_file") != LOGGERS:
        imp = f"wrong-file-after({a.get('loggers_file')})"
    elif a.get("grep_rc") != "0":
        imp = f"fix-absent-or-unread-after(grep_rc={a.get('grep_rc')})"
    else:
        imp = "ok"
    lines.append(f"import_check={imp}")

    # The image is the pinned one only if the runner's own record says so, and the wheel's hash came out of it.
    try:
        ident = open(f"{sweep}/image-identity.txt").read()
        wheel = open(f"{sweep}/wheel-sha256.txt").read().strip()
        image = "ok" if IMAGE_DIGEST in ident and ident.rstrip().endswith(" " + VLLM_COMMIT) and wheel else "mismatch"
    except OSError:
        image = "missing"
    lines.append(f"image={image}")

    bid, aid = identity(b, serving_sha), identity(a, fix_sha)
    lines += [f"before_identity={bid}", f"after_identity={aid}"]
    # Recorded, not gated: the pinned file hashes already prove the tree, and HEAD only names where it came from.
    lines.append(f"checkout_head={(a or b or {}).get('checkout_head', 'unread')}")
    try:
        order = "ok" if int(b["ended"]) <= int(a["started"]) else "after-started-before-before-ended"
    except (TypeError, KeyError, ValueError):
        order = "unread"
    lines.append(f"order={order}")

    before, delta = before_result(b, cases(f"{sweep}/before/tpot.xml"))
    after = after_result(a, cases(f"{sweep}/after/tpot.xml"))
    lines += [f"before={before}", f"before_delta={'n/a' if delta is None else f'{delta:g}'}", f"after={after}"]
    lines.append(f"after_file={file_result(a, cases(f'{sweep}/after/file.xml'))}")

    if imp == image == bid == aid == order == "ok" and before == "failed-as-expected" and after == "passed":
        verdict = "confirmed"
    elif before == "passed":
        verdict = "before-passed"
    else:
        verdict = "not-confirmed"
    lines.append(f"verdict={verdict}")
    print("\n".join(lines))
    return 0 if verdict == "confirmed" else 2


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    sys.exit(main(*sys.argv[1:]))
