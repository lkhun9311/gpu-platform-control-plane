#!/usr/bin/env python3
"""The #68415 verdict of oss/vllm/68414-gdn/vllm-gdn-68414-session.sh run 3, read from the records oss/vllm/68414-gdn/kda-state.sh leaves.

    kda-verdict.py <sweep dir> <kda-test.diff sha256> <kda-fix.diff sha256>

Prints key=value lines prefixed kda_, the import check first, and exits 0 only when kda_verdict is "confirmed".
It reads only the kda-before and kda-after records and the image identity, so no other item can change it, and it cannot change another item's.
"confirmed" needs every one of these, on the pinned image and pinned trees:
  - BEFORE ran k64-v32, k64-v64, k64-v32-hv2 and v-bf16, and never k32-v64, by its command, its collection and its junit;
  - BEFORE failed k64-v32 and k64-v32-hv2 each on `assert out.shape == v.shape`, with its own E line, and passed k64-v64 and v-bf16;
  - AFTER ran all five cases, and all five passed;
  - each call's command, the GPU, the python and the apply command were recorded as the summary quotes them;
  - the imported kda.py holds the bug line and not the fix BEFORE, and the fix and not the bug line AFTER;
  - kda.py's kernel came from the image's fused_recurrent.py without #68416's term, and the new test from the checkout;
  - the collection loaded no file that differs between the image's commit and the diff base.
Every other combination is reported by name.
"""
import sys
import xml.etree.ElementTree as ET

OPS = "/usr/local/lib/python3.12/dist-packages/vllm/third_party/flash_linear_attention/ops"
KDA = f"{OPS}/kda.py"
KERNEL = f"{OPS}/fused_recurrent.py"
TEST_FILE = "/vllm-workspace/tests/kernels/fla/test_fused_recurrent_kda.py"
IMAGE_DIGEST = "sha256:9071b00dc36251a304e9099ed40b42a8260f8feb23432c8f312689e34c4d3f5f"
VLLM_COMMIT = "428c371b32c18a788def35abea1cb9f579278381"
TEST = "tests/kernels/fla/test_fused_recurrent_kda.py"
CASE = "test_fused_recurrent_kda_output_has_value_shape"
UNSAFE = "k32-v64"
# BEFORE's whole selection as kda-state.sh records it, so a widened command line voids the run even when it crashed before writing junit.
BEFORE_ARGS = " ".join(f"{TEST}::{CASE}[{i}]" for i in ("k64-v32", "k64-v64", "k64-v32-hv2", "v-bf16")) + f" -k not {UNSAFE}"
# The output is allocated from k, so its shape has K=64 and k's single head where v has V=32 and its own heads.
BEFORE_FAILS = {
    "k64-v32": "E   assert torch.Size([1, 4, 1, 64]) == torch.Size([1, 4, 1, 32])",
    "k64-v32-hv2": "E   assert torch.Size([1, 4, 1, 64]) == torch.Size([1, 4, 2, 32])",
}
BEFORE_PASSES = ("k64-v64", "v-bf16")
SHAPE_LINE = "assert out.shape == v.shape"
AFTER_IDS = ("k64-v32", "k64-v64", "k32-v64", "k64-v32-hv2", "v-bf16")


def kv(path):
    try:
        with open(path) as f:
            return dict(line.rstrip("\n").split("=", 1) for line in f if "=" in line)
    except OSError:
        return None


def cases(path):
    """Each testcase as (id, outcome, text), or None when the file is missing or not junit."""
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
        name = tc.get("name", "")
        out.append((name[len(CASE) + 1:-1] if name.startswith(CASE + "[") and name.endswith("]") else name, outcome, text))
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


def import_check(name, st, fix_rc, bug_rc):
    if st is None:
        return f"{name}-missing"
    for key, want in (("kda_file", KDA), ("kernel_file", KERNEL), ("test_file", TEST_FILE)):
        if st.get(key) != want:
            return f"wrong-file-{name}({key}={st.get(key)})"
    if st.get("fix_grep_rc") != fix_rc or st.get("bug_grep_rc") != bug_rc:
        return f"lines-{name}(fix_grep_rc={st.get('fix_grep_rc')},bug_grep_rc={st.get('bug_grep_rc')})"
    # #68416's fix in this item's kernel would be another item's fix leaking in.
    if st.get("kernel_stride_fix_count") != "0":
        return f"other-fix-{name}(kernel_stride_fix_count={st.get('kernel_stride_fix_count')})"
    if st.get("probe_rc") != "0" or not st.get("loaded_count", "0").isdigit() or int(st.get("loaded_count", "0")) == 0:
        return f"probe-{name}(rc={st.get('probe_rc')},loaded={st.get('loaded_count')})"
    if st.get("loaded_differs") != "none":
        return f"loaded-differs-{name}({st.get('loaded_differs')})"
    return "ok"


def before_result(st, tc):
    if st is None:
        return "missing"
    # Any trace of k32-v64 is a breach of the rule this state exists to keep, whatever its outcome.
    # The guard refuses before pytest runs, so its "no" is read before the missing exit status would hide it.
    if st.get("before_selection_guard") == "no":
        return "wrong-args(refused by kda-state.sh's selection guard)"
    if "test_rc" not in st:
        return "missing"
    if st.get("pytest_args") != BEFORE_ARGS or st.get("before_selection_guard") != "yes":
        return f"wrong-args({st.get('pytest_args')})"
    rc = st["test_rc"]
    if tc is None:
        return f"no-junit(rc={rc})"
    ids = [i for i, _, _ in tc]
    if any(UNSAFE in i for i in ids) or len(ids) != 4 or set(ids) != set(BEFORE_FAILS) | set(BEFORE_PASSES):
        return f"wrong-cases({','.join(ids) or 'none'})"
    got = {i: (o, t) for i, o, t in tc}
    wrong = []
    for i, eline in BEFORE_FAILS.items():
        o, t = got[i]
        lines = [x.rstrip() for x in t.splitlines()]
        if o != "failure":
            wrong.append(f"{i}:{o}")
        elif eline not in lines or SHAPE_LINE not in (x.strip() for x in lines):
            wrong.append(f"{i}:failure-not-the-shape-assert")
    for i in BEFORE_PASSES:
        if got[i][0] != "passed":
            wrong.append(f"{i}:{got[i][0]}")
    if rc == "1" and not wrong:
        return "bug-shown"
    if all(w.endswith("failure-not-the-shape-assert") for w in wrong) and wrong:
        return f"other-failure({','.join(wrong)})"
    return f"other(rc={rc},{','.join(wrong) or 'outcomes as expected'})"


def after_result(st, tc):
    if st is None or "test_rc" not in st:
        return "missing"
    rc = st["test_rc"]
    if tc is None:
        return f"no-junit(rc={rc})"
    ids = [i for i, _, _ in tc]
    # Five distinct names, so a repeated case cannot stand in for one that never ran.
    if rc == "0" and len(ids) == 5 and set(ids) == set(AFTER_IDS) and all(o == "passed" for _, o, _ in tc):
        return "passed"
    outcomes = ",".join(f"{i}:{o}" for i, o, _ in tc) or "none"
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
    ev = evidence("kda-before", b, ("test",)) or evidence("kda-after", a, ("test",)) or "ok"
    lines.append(f"kda_evidence={ev}")
    lines.append(f"kda_before_args={(b or {}).get('pytest_args', '')}")
    tb = cases(f"{sweep}/kda-before/test.xml")
    # Stated on its own line, since the PR quotes that the unsafe case never ran before the fix.
    lines.append(f"kda_before_junit_{UNSAFE}={'unread' if tb is None else ('present' if any(UNSAFE in i for i, _, _ in tb) else 'absent')}")
    rb = before_result(b, tb)
    ra = after_result(a, cases(f"{sweep}/kda-after/test.xml"))
    lines += [f"kda_before_test={rb}", f"kda_after_test={ra}"]

    # A selection that could reach k32-v64 is named before anything else, since it is the one breach that can corrupt the GPU's memory.
    if rb.startswith(("wrong-cases", "wrong-args")):
        verdict = "void-before-selection"
    elif image != "ok" or bid != "ok" or aid != "ok" or order != "ok":
        verdict = "void-identity"
    elif imp != "ok":
        verdict = "void-import-check"
    elif ev != "ok":
        verdict = "void-evidence"
    elif rb.startswith("other-failure"):
        verdict = "before-failed-otherwise"
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
