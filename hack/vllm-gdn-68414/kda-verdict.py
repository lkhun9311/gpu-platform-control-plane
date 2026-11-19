#!/usr/bin/env python3
"""The #68415 verdict of hack/vllm-gdn-68414-session.sh run 2, read from the records hack/vllm-gdn-68414/kda-state.sh leaves.

    kda-verdict.py <sweep dir> <kda-test.diff sha256> <kda-fix.diff sha256>

Prints key=value lines prefixed kda_, the import check first, and exits 0 only when kda_verdict is "confirmed".
It reads only the kda-before and kda-after records and the image identity, so no other item can change it, and it cannot change another item's.
"confirmed" needs every one of these, on the pinned image and pinned trees:
  - BEFORE ran the 64-32 case alone, and it failed on `out.shape == v.shape` with [1, 4, 1, 64] against [1, 4, 1, 32];
  - AFTER ran the three cases 64-32, 64-64 and 32-64, and all three passed;
  - the imported kda.py holds the bug line and not the fix BEFORE, and the fix and not the bug line AFTER.
Every other combination is reported by name.
"""
import sys
import xml.etree.ElementTree as ET

KDA = "/usr/local/lib/python3.12/dist-packages/vllm/third_party/flash_linear_attention/ops/kda.py"
IMAGE_DIGEST = "sha256:45feec27226e1dc9d10e14272a45bcd7344555c85102be9ccbc0fbe9df2d99ed"
VLLM_COMMIT = "8700cc9ba0016bf14d8f2756f3b673e93fbcf2fd"
CASE = "test_fused_recurrent_kda_output_has_value_shape"
BEFORE_CASES = {f"{CASE}[64-32]"}
# BEFORE's whole selection as kda-state.sh records it, so a widened command line voids the run even when it crashed before writing junit.
BEFORE_ARGS = f"tests/kernels/fla/test_fused_recurrent_kda.py::{CASE}[64-32] -k 64-32"
AFTER_CASES = {f"{CASE}[64-32]", f"{CASE}[64-64]", f"{CASE}[32-64]"}
# The 64-32 case's output is allocated from k, so its shape has K=64 where v has V=32.
BUG_TEXT = ("out.shape == v.shape", "[1, 4, 1, 64]", "[1, 4, 1, 32]")


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


def import_check(name, st, fix_rc, bug_rc):
    if st is None:
        return f"{name}-missing"
    if st.get("kda_file") != KDA:
        return f"wrong-file-{name}({st.get('kda_file')})"
    if st.get("fix_grep_rc") != fix_rc or st.get("bug_grep_rc") != bug_rc:
        return f"lines-{name}(fix_grep_rc={st.get('fix_grep_rc')},bug_grep_rc={st.get('bug_grep_rc')})"
    return "ok"


def before_result(st, tc):
    if st is None or "test_rc" not in st:
        return "missing"
    if st.get("pytest_args") != BEFORE_ARGS:
        return f"wrong-args({st.get('pytest_args')})"
    rc = st["test_rc"]
    if tc is None:
        return f"no-junit(rc={rc})"
    names = [n for n, _, _ in tc]
    # Any case but 64-32 is a breach of the rule this state exists to keep, whatever its outcome.
    if set(names) != BEFORE_CASES or len(names) != 1:
        return f"wrong-cases({','.join(names) or 'none'})"
    _, outcome, message = tc[0]
    if rc == "1" and outcome == "failure" and all(t in message for t in BUG_TEXT):
        return "bug-shown"
    if rc == "0" and outcome == "passed":
        return "no-bug"
    return f"other(rc={rc},outcome={outcome})"


def after_result(st, tc):
    if st is None or "test_rc" not in st:
        return "missing"
    rc = st["test_rc"]
    if tc is None:
        return f"no-junit(rc={rc})"
    names = [n for n, _, _ in tc]
    # Three distinct names, so a repeated case cannot stand in for one that never ran.
    if rc == "0" and len(names) == 3 and set(names) == AFTER_CASES and all(o == "passed" for _, o, _ in tc):
        return "passed"
    outcomes = ",".join(f"{n.removeprefix(CASE)}:{o}" for n, o, _ in tc) or "none"
    return f"not-passed(rc={rc},cases={len(tc)},{outcomes})"


def main(sweep, test_sha, fix_sha):
    b, a = kv(f"{sweep}/kda-before/state.txt"), kv(f"{sweep}/kda-after/state.txt")
    lines = []
    imp_b = import_check("before", b, fix_rc="1", bug_rc="0")
    imp_a = import_check("after", a, fix_rc="0", bug_rc="1")
    imp = imp_b if imp_b != "ok" else imp_a
    lines.append(f"kda_import_check={imp}")
    try:
        with open(f"{sweep}/image-identity.txt") as f:
            ident = f.read()
        with open(f"{sweep}/wheel-sha256.txt") as f:
            wheel = f.read().strip()
        image = "ok" if IMAGE_DIGEST in ident and ident.rstrip().endswith(" " + VLLM_COMMIT) and wheel else "mismatch"
    except OSError:
        image = "missing"
    lines.append(f"kda_image={image}")
    bid, aid = identity(b, test_sha), identity(a, fix_sha)
    lines += [f"kda_before_identity={bid}", f"kda_after_identity={aid}"]
    try:
        order = "ok" if int(b["ended"]) <= int(a["started"]) else "after-started-before-before-ended"
    except (TypeError, KeyError, ValueError):
        order = "unread"
    lines.append(f"kda_order={order}")
    lines.append(f"kda_before_args={(b or {}).get('pytest_args', '')}")
    rb = before_result(b, cases(f"{sweep}/kda-before/test.xml"))
    ra = after_result(a, cases(f"{sweep}/kda-after/test.xml"))
    lines += [f"kda_before_test={rb}", f"kda_after_test={ra}"]

    if image != "ok" or bid != "ok" or aid != "ok" or order != "ok":
        verdict = "void-identity"
    elif imp != "ok":
        verdict = "void-import-check"
    elif rb.startswith(("wrong-cases", "wrong-args")):
        verdict = "void-before-selection"
    elif rb != "bug-shown":
        verdict = "before-did-not-reproduce"
    elif ra != "passed":
        verdict = "after-not-passed"
    else:
        verdict = "confirmed"
    lines.append(f"kda_verdict={verdict}")
    print("\n".join(lines))
    return 0 if verdict == "confirmed" else 2


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    sys.exit(main(*sys.argv[1:]))
