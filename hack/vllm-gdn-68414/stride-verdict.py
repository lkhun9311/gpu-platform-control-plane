#!/usr/bin/env python3
"""The #68416 verdict of hack/vllm-gdn-68414-session.sh run 2, read from the records hack/vllm-gdn-68414/stride-state.sh leaves.

    stride-verdict.py <sweep dir> <stride-test.diff sha256> <stride-fix.diff sha256>

Prints key=value lines prefixed stride_, the import check first, and exits 0 only when stride_verdict is "confirmed".
It reads only the stride-before and stride-after records and the image identity, so no other item can change it, and it cannot change another item's.
"confirmed" needs every one of these, on the pinned image and pinned trees:
  - BEFORE ran the new test's two cases, recurrent and sigmoid_gating, and both failed on assert_close finding the tensors unequal;
  - AFTER ran the same two cases, and both passed;
  - fused_recurrent.py and fused_sigmoid_gating.py were imported from the image's dist-packages in both states, with `i_t * stride_indices_tok` in neither BEFORE and in both loads of each AFTER.
Every other combination is reported by name.
"""
import sys
import xml.etree.ElementTree as ET

OPS = "/usr/local/lib/python3.12/dist-packages/vllm/third_party/flash_linear_attention/ops"
IMAGE_DIGEST = "sha256:45feec27226e1dc9d10e14272a45bcd7344555c85102be9ccbc0fbe9df2d99ed"
VLLM_COMMIT = "8700cc9ba0016bf14d8f2756f3b673e93fbcf2fd"
TEST = "tests/kernels/fla/test_state_index_stride.py"
CASE = "test_state_index_table_stride_does_not_change_results"
CASES = {f"{CASE}[recurrent]", f"{CASE}[sigmoid_gating]"}
KERNELS = ("fused_recurrent", "fused_sigmoid_gating")
# The diff adds the term to the initial-state and the final-state load in each kernel.
FIX_COUNT_AFTER = "2"
# torch.testing.assert_close with rtol=atol=0 says "equal", not "close", when the tensors differ.
BUG_TEXT = "Tensor-likes are not equal!"


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


def import_check(name, st, want_count):
    if st is None:
        return f"{name}-missing"
    for k in KERNELS:
        if st.get(f"{k}_file") != f"{OPS}/{k}.py":
            return f"wrong-file-{name}({k}={st.get(f'{k}_file')})"
        if st.get(f"{k}_fix_count") != want_count:
            return f"lines-{name}({k}_fix_count={st.get(f'{k}_fix_count')})"
    return "ok"


def ran_both(st, tc):
    """None when the state ran exactly the two cases, else why not."""
    if st is None or "test_rc" not in st:
        return "missing"
    if st.get("pytest_args") != TEST:
        return f"wrong-args({st.get('pytest_args')})"
    if tc is None:
        return f"no-junit(rc={st['test_rc']})"
    names = [n for n, _, _ in tc]
    # Two distinct names, so a repeated case cannot stand in for one that never ran.
    if len(names) != 2 or set(names) != CASES:
        return f"wrong-cases({','.join(names) or 'none'})"
    return None


def before_result(st, tc):
    why = ran_both(st, tc)
    if why:
        return why
    if st["test_rc"] == "1" and all(o == "failure" and BUG_TEXT in m for _, o, m in tc):
        return "bug-shown"
    if st["test_rc"] == "0" and all(o == "passed" for _, o, _ in tc):
        return "no-bug"
    outcomes = ",".join(f"{n.removeprefix(CASE)}:{o}" for n, o, _ in tc)
    return f"other(rc={st['test_rc']},{outcomes})"


def after_result(st, tc):
    why = ran_both(st, tc)
    if why:
        return why
    if st["test_rc"] == "0" and all(o == "passed" for _, o, _ in tc):
        return "passed"
    outcomes = ",".join(f"{n.removeprefix(CASE)}:{o}" for n, o, _ in tc)
    return f"not-passed(rc={st['test_rc']},{outcomes})"


def main(sweep, test_sha, fix_sha):
    b, a = kv(f"{sweep}/stride-before/state.txt"), kv(f"{sweep}/stride-after/state.txt")
    lines = []
    imp_b = import_check("before", b, "0")
    imp_a = import_check("after", a, FIX_COUNT_AFTER)
    imp = imp_b if imp_b != "ok" else imp_a
    lines.append(f"stride_import_check={imp}")
    try:
        with open(f"{sweep}/image-identity.txt") as f:
            ident = f.read()
        with open(f"{sweep}/wheel-sha256.txt") as f:
            wheel = f.read().strip()
        image = "ok" if IMAGE_DIGEST in ident and ident.rstrip().endswith(" " + VLLM_COMMIT) and wheel else "mismatch"
    except OSError:
        image = "missing"
    lines.append(f"stride_image={image}")
    bid, aid = identity(b, test_sha), identity(a, fix_sha)
    lines += [f"stride_before_identity={bid}", f"stride_after_identity={aid}"]
    try:
        order = "ok" if int(b["ended"]) <= int(a["started"]) else "after-started-before-before-ended"
    except (TypeError, KeyError, ValueError):
        order = "unread"
    lines.append(f"stride_order={order}")
    rb = before_result(b, cases(f"{sweep}/stride-before/test.xml"))
    ra = after_result(a, cases(f"{sweep}/stride-after/test.xml"))
    lines += [f"stride_before_test={rb}", f"stride_after_test={ra}"]

    if image != "ok" or bid != "ok" or aid != "ok" or order != "ok":
        verdict = "void-identity"
    elif imp != "ok":
        verdict = "void-import-check"
    elif rb != "bug-shown":
        verdict = "before-did-not-reproduce"
    elif ra != "passed":
        verdict = "after-not-passed"
    else:
        verdict = "confirmed"
    lines.append(f"stride_verdict={verdict}")
    print("\n".join(lines))
    return 0 if verdict == "confirmed" else 2


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    sys.exit(main(*sys.argv[1:]))
