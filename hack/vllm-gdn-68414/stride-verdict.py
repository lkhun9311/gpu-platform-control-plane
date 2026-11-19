#!/usr/bin/env python3
"""The #68416 verdict of hack/vllm-gdn-68414-session.sh run 4, read from the records hack/vllm-gdn-68414/stride-state.sh leaves.

    stride-verdict.py <sweep dir> <stride-test.diff sha256> <stride-fix.diff sha256>

Prints key=value lines prefixed stride_, the import check first, and exits 0 only when stride_verdict is "confirmed".
It reads only the stride-before and stride-after records and the image identity, so no other item can change it, and it cannot change another item's.
"confirmed" needs every one of these, on the pinned image and pinned trees:
  - BEFORE ran `-k stride`, which selected the three cases recurrent, sigmoid_gating and kda, and all three failed on assert_close finding the tensors unequal;
  - AFTER ran `-k stride`, and the same three passed;
  - AFTER ran the whole test file, and all 21 of its cases passed: 6 non_spec, 12 spec and the three new ones;
  - each call's command, the GPU, the python and the apply command were recorded as the summary quotes them;
  - fused_recurrent.py, fused_sigmoid_gating.py and kda.py came from the image's dist-packages and the test file from the checkout, in both states;
  - `i_t * stride_indices_tok` was in neither kernel BEFORE and in both loads of each AFTER, and kda.py launched fused_recurrent.py's kernel;
  - kda.py held #68415's bug line and not its fix in both states, so that item's fix did not reach this one;
  - the collection loaded no file that differs between the image's commit and the diff base 545ef08189.
Every other combination is reported by name.
"""
import sys
import xml.etree.ElementTree as ET

OPS = "/usr/local/lib/python3.12/dist-packages/vllm/third_party/flash_linear_attention/ops"
TEST_FILE = "/vllm-workspace/tests/kernels/fla/test_fused_sigmoid_gating_delta_rule.py"
IMAGE_DIGEST = "sha256:639209c4b3c1f16f309837668608ac889e92db0d4dd4facf5a6987c6d54ef8ac"
VLLM_COMMIT = "3e469e9ffbef4c54595327df14d209ba9c2481f7"
TEST = "tests/kernels/fla/test_fused_sigmoid_gating_delta_rule.py"
CASE = "test_state_index_table_stride_does_not_change_results"
CASES = {f"{CASE}[recurrent]", f"{CASE}[sigmoid_gating]", f"{CASE}[kda]"}
ARGS = f"{TEST} -k stride"
# 3 x 2 non_spec cases, 3 x 2 x 2 spec cases and the three new ones, counted from the file at 541d8b9771.
# Each function's count is held on its own, so 21 unrelated names cannot stand in for the file.
FILE_SHAPE = {
    "test_fused_sigmoid_gating_delta_rule_update_non_spec[": 6,
    "test_fused_sigmoid_gating_delta_rule_update_spec[": 12,
    f"{CASE}[": 3,
}
FILE_CASES = 21
KERNELS = ("fused_recurrent", "fused_sigmoid_gating")
# The diff adds the term to the initial-state and the final-state load in each kernel.
FIX_COUNT_AFTER = "2"
# torch.testing.assert_close with rtol=atol=0 says "equal", not "close", when the tensors differ, and then counts the mismatches.
BUG_LINE = "E   AssertionError: Tensor-likes are not equal!"
MISMATCH = "E   Mismatched elements: "


def kv(path):
    try:
        with open(path) as f:
            return dict(line.rstrip("\n").split("=", 1) for line in f if "=" in line)
    except OSError:
        return None


def cases(path):
    """Each testcase as (name, outcome, text), or None when the file is missing or not junit."""
    try:
        root = ET.parse(path).getroot()
    except (OSError, ET.ParseError):
        return None
    out = []
    for tc in root.iter("testcase"):
        outcome, text = "passed", ""
        for tag in ("error", "failure", "skipped"):
            el = tc.find(tag)
            if el is not None:
                outcome, text = tag, (el.get("message") or "") + "\n" + (el.text or "")
                break
        out.append((tc.get("name", ""), outcome, text))
    return out


def evidence(name, st, keys):
    """None when a state recorded what the PRs quote about it, else what is missing: each call's command, the GPU, the python and the apply command."""
    if st is None:
        return f"{name}-missing"
    for key in keys:
        # A call that left neither a command nor an exit status never ran, which the test results name more exactly.
        if f"{key}_cmd" not in st and f"{key}_rc" not in st:
            continue
        cmd = st.get(f"{key}_cmd", "")
        args = st.get({"test": "pytest_args", "file": "file_args"}[key], "")
        # The command must be the one whose selection the verdict judged, with the flags that put the E lines in the junit.
        if " python3 -m pytest " not in cmd or " -rA --tb=short " not in cmd or not cmd.endswith(f"/{name}/{key}.xml") or not args or args not in cmd.replace("'", ""):
            return f"{name}-{key}-command({cmd or 'unrecorded'})"
    if "A10G" not in st.get("gpu_name", ""):
        return f"{name}-gpu({st.get('gpu_name', 'unrecorded')})"
    for key in ("python_executable", "python_version", "apply_checkout_cmd"):
        if st.get(key, "unread") in ("", "unread"):
            return f"{name}-{key}(unrecorded)"
    return None


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
    want_files = {f"{k}_file": f"{OPS}/{k}.py" for k in KERNELS}
    want_files.update(kda_file=f"{OPS}/kda.py", kda_kernel_file=f"{OPS}/fused_recurrent.py", test_file=TEST_FILE)
    for key, want in want_files.items():
        if st.get(key) != want:
            return f"wrong-file-{name}({key}={st.get(key)})"
    for k in KERNELS:
        if st.get(f"{k}_fix_count") != want_count:
            return f"lines-{name}({k}_fix_count={st.get(f'{k}_fix_count')})"
    # #68415's fix in kda.py would be another item's fix leaking in.
    if st.get("kda_fix_grep_rc") != "1" or st.get("kda_bug_grep_rc") != "0":
        return f"other-fix-{name}(kda_fix_grep_rc={st.get('kda_fix_grep_rc')},kda_bug_grep_rc={st.get('kda_bug_grep_rc')})"
    if st.get("probe_rc") != "0" or not st.get("loaded_count", "0").isdigit() or int(st.get("loaded_count", "0")) == 0:
        return f"probe-{name}(rc={st.get('probe_rc')},loaded={st.get('loaded_count')})"
    if st.get("loaded_differs") != "none":
        return f"loaded-differs-{name}({st.get('loaded_differs')})"
    return "ok"


def ran_three(st, tc):
    """None when the state ran exactly the three cases, else why not."""
    if st is None or "test_rc" not in st:
        return "missing"
    if st.get("pytest_args") != ARGS:
        return f"wrong-args({st.get('pytest_args')})"
    if tc is None:
        return f"no-junit(rc={st['test_rc']})"
    names = [n for n, _, _ in tc]
    # Three distinct names, so a repeated case cannot stand in for one that never ran.
    if len(names) != 3 or set(names) != CASES:
        return f"wrong-cases({','.join(names) or 'none'})"
    return None


def short(tc):
    return ",".join(f"{n.removeprefix(CASE)}:{o}" for n, o, _ in tc)


def before_result(st, tc):
    why = ran_three(st, tc)
    if why:
        return why
    if all(o == "failure" for _, o, _ in tc):
        if all(BUG_LINE in t.splitlines() and any(x.startswith(MISMATCH) for x in t.splitlines()) for _, _, t in tc):
            return "bug-shown" if st["test_rc"] == "1" else f"other(rc={st['test_rc']},{short(tc)})"
        return f"other-failure({short(tc)})"
    if st["test_rc"] == "0" and all(o == "passed" for _, o, _ in tc):
        return "no-bug"
    return f"other(rc={st['test_rc']},{short(tc)})"


def after_result(st, tc):
    why = ran_three(st, tc)
    if why:
        return why
    if st["test_rc"] == "0" and all(o == "passed" for _, o, _ in tc):
        return "passed"
    return f"not-passed(rc={st['test_rc']},{short(tc)})"


def file_result(st, tc):
    if st is None or "file_rc" not in st:
        return "missing"
    if st.get("file_args") != TEST:
        return f"wrong-args({st.get('file_args')})"
    rc = st["file_rc"]
    if tc is None:
        return f"no-junit(rc={rc})"
    names = [n for n, _, _ in tc]
    bad = [n for n, o, _ in tc if o != "passed"]
    shape = {p: sum(n.startswith(p) for n in set(names)) for p in FILE_SHAPE}
    if rc == "0" and len(names) == FILE_CASES and len(set(names)) == FILE_CASES and CASES <= set(names) and shape == FILE_SHAPE and not bad:
        return "passed"
    counts = ",".join(f"{p.rstrip('[')}:{c}" for p, c in shape.items())
    return f"not-passed(rc={rc},cases={len(names)},{counts},not-passed={','.join(bad) or 'none'})"


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
    ev = evidence("stride-before", b, ("test",)) or evidence("stride-after", a, ("test", "file")) or "ok"
    lines.append(f"stride_evidence={ev}")
    rb = before_result(b, cases(f"{sweep}/stride-before/test.xml"))
    ra = after_result(a, cases(f"{sweep}/stride-after/test.xml"))
    rf = file_result(a, cases(f"{sweep}/stride-after/file.xml"))
    lines += [f"stride_before_test={rb}", f"stride_after_test={ra}", f"stride_after_file={rf}"]

    if image != "ok" or bid != "ok" or aid != "ok" or order != "ok":
        verdict = "void-identity"
    elif imp != "ok":
        verdict = "void-import-check"
    elif ev != "ok":
        verdict = "void-evidence"
    elif rb.startswith(("wrong-cases", "wrong-args")):
        verdict = "void-before-selection"
    elif rb.startswith("other-failure"):
        verdict = "before-failed-otherwise"
    elif rb != "bug-shown":
        verdict = "before-did-not-reproduce"
    elif ra != "passed":
        verdict = "after-not-passed"
    elif rf != "passed":
        verdict = "after-file-not-passed"
    else:
        verdict = "confirmed"
    lines.append(f"stride_verdict={verdict}")
    print("\n".join(lines))
    return 0 if verdict == "confirmed" else 2


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    sys.exit(main(*sys.argv[1:]))
