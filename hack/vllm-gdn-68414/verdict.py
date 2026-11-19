#!/usr/bin/env python3
"""The verdict of hack/vllm-gdn-68414-session.sh, read from the records hack/vllm-gdn-68414/state.sh leaves.

    verdict.py <sweep dir> <fix.diff sha256> <kernel_repro.py sha256>

Prints key=value lines, the import check first, and exits 0 only when the verdict is "confirmed".
"confirmed" needs every one of these, on the pinned image and pinned trees:
  - BEFORE's kernel_repro.py shows the bug, 70 unwritten rows and a NaN final state;
  - AFTER's kernel_repro.py prints the reporter's fixed line exactly;
  - AFTER's new test passes its five cases;
  - each existing GDN test passes, or skips for the reason an sm_86 GPU is expected to give;
  - the imported index.py holds the bug line and not the fix BEFORE, and the fix and not the bug line AFTER.
Every other combination is reported by name, because a run that cannot say why it is not confirmed is not evidence.
"""
import math
import re
import sys
import xml.etree.ElementTree as ET

INDEX = "/usr/local/lib/python3.12/dist-packages/vllm/third_party/flash_linear_attention/ops/index.py"
IMAGE_DIGEST = "sha256:45feec27226e1dc9d10e14272a45bcd7344555c85102be9ccbc0fbe9df2d99ed"
VLLM_COMMIT = "8700cc9ba0016bf14d8f2756f3b673e93fbcf2fd"
LINE = re.compile(r"^unwritten (\d+) o_err (\S+) state_err (\S+) empty_keeps_h0 (True|False)$")
# The reporter's numbers: sequence 3 holds 70 tokens, all unwritten when it reads the empty sequence's bounds.
BUG_UNWRITTEN = 70
FIXED_LINE = "unwritten 0 o_err 0.0 state_err 0.0 empty_keeps_h0 True"
UNIT_CASE = re.compile(r"^test_chunk_indices_keep_ids_of_empty_sequences\[.+\]$")
UNIT_CASES = 5
# Neither existing GDN test can run on an A10G (sm_86): one needs SM10x for CuteDSL, the other needs ROCm.
# A skip for any other reason, such as an import that failed, is not the expected one and is named.
EXISTING = {
    "core_split": "requires CUDA SM10x",
    "rocm_layout": "ROCm-specific tests",
}


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
        # An error outranks a failure, and both outrank a skip, so a test is never counted better than its worst record.
        for tag in ("error", "failure", "skipped"):
            el = tc.find(tag)
            if el is not None:
                outcome, message = tag, (el.get("message") or "") + "\n" + (el.text or "")
                break
        out.append((tc.get("name", ""), outcome, message))
    return out


def identity(st, want_diff, want_repro):
    if st is None:
        return "missing"
    want_apply = "none" if want_diff == "none" else "ok"
    for key, want in (("base_identity", "ok"), ("apply", want_apply), ("applied_identity", "ok"),
                      ("diff_sha256", want_diff), ("repro_sha256", want_repro)):
        if st.get(key) != want:
            return f"{key}={st.get(key, 'unread')}"
    return "ok"


def import_check(name, st, fix_rc, bug_rc):
    """ok when Python imported the image's index.py, which held the fix and bug lines this state expects."""
    if st is None:
        return f"{name}-missing"
    if st.get("index_file") != INDEX:
        return f"wrong-file-{name}({st.get('index_file')})"
    if st.get("fix_grep_rc") != fix_rc or st.get("bug_grep_rc") != bug_rc:
        return f"lines-{name}(fix_grep_rc={st.get('fix_grep_rc')},bug_grep_rc={st.get('bug_grep_rc')})"
    # The wrapper prints the file its own process imported, and the repro's answer speaks for that file only.
    if st.get("repro_mode") == "cuda-default" and st.get("repro_index_file") != INDEX:
        return f"repro-wrong-file-{name}({st.get('repro_index_file')})"
    return "ok"


def parse(line):
    m = LINE.match(line or "")
    if not m:
        return None
    return int(m.group(1)), float(m.group(2)), float(m.group(3)), m.group(4) == "True"


def before_repro(st):
    if st is None or "repro_line" not in st:
        return "missing"
    p = parse(st["repro_line"])
    if p is None:
        return f"no-result(mode={st.get('repro_mode')})"
    unwritten, _, state_err, _ = p
    if unwritten == BUG_UNWRITTEN and math.isnan(state_err):
        return "bug-shown"
    if unwritten == 0 and state_err == 0.0:
        return "no-bug"
    return "other"


def after_repro(st):
    if st is None or "repro_line" not in st:
        return "missing"
    line = st["repro_line"]
    p = parse(line)
    if p is None:
        return f"no-result(mode={st.get('repro_mode')})"
    if line == FIXED_LINE:
        return "fixed"
    unwritten, o_err, state_err, keeps = p
    if unwritten == 0 and keeps and math.isfinite(o_err) and math.isfinite(state_err):
        return "fixed-inexact"
    return "not-fixed"


def unit_result(st, tc):
    if st is None or tc is None or "unit_rc" not in st:
        return "missing"
    rc = st["unit_rc"]
    names = {n for n, _, _ in tc}
    if any(not UNIT_CASE.match(n) for n in names):
        return f"unexpected-cases(rc={rc})"
    # Five distinct cases, so a repeated name cannot stand in for a case that never ran.
    if rc == "0" and len(names) == len(tc) == UNIT_CASES and all(o == "passed" for _, o, _ in tc):
        return "passed"
    outcomes = ",".join(o for _, o, _ in tc) or "none"
    return f"not-passed(rc={rc},cases={len(tc)},outcomes={outcomes})"


def existing_result(name, st, tc):
    if st is None or f"{name}_rc" not in st:
        return "missing"
    rc = st[f"{name}_rc"]
    if rc == "absent":
        return "absent"
    if tc is None:
        return f"no-junit(rc={rc})"
    n = {o: sum(1 for _, x, _ in tc if x == o) for o in ("passed", "failure", "error", "skipped")}
    if rc != "0" or n["failure"] or n["error"] or not tc:
        return f"not-passed(rc={rc},{n['passed']}p,{n['failure']}f,{n['error']}e,{n['skipped']}s)"
    if n["skipped"] == len(tc):
        reasons = {m.strip().splitlines()[0] if m.strip() else "" for _, _, m in tc}
        why = "|".join(sorted(reasons))
        if all(EXISTING[name] in r for r in reasons):
            return f"skipped({why})"
        return f"skipped-unexpectedly({why})"
    return f"passed({n['passed']}p,{n['skipped']}s)"


def main(sweep, fix_sha, repro_sha):
    b, a = kv(f"{sweep}/before/state.txt"), kv(f"{sweep}/after/state.txt")
    lines = []

    # The import check comes first: a BEFORE without the bug is most likely one that imported a fixed index.py.
    imp_b = import_check("before", b, fix_rc="1", bug_rc="0")
    imp_a = import_check("after", a, fix_rc="0", bug_rc="1")
    imp = imp_b if imp_b != "ok" else imp_a
    lines.append(f"import_check={imp}")

    # The image is the pinned one only if the runner's own record says so, and the wheel's hash came out of it.
    try:
        with open(f"{sweep}/image-identity.txt") as f:
            ident = f.read()
        with open(f"{sweep}/wheel-sha256.txt") as f:
            wheel = f.read().strip()
        image = "ok" if IMAGE_DIGEST in ident and ident.rstrip().endswith(" " + VLLM_COMMIT) and wheel else "mismatch"
    except OSError:
        image = "missing"
    lines.append(f"image={image}")

    bid, aid = identity(b, "none", repro_sha), identity(a, fix_sha, repro_sha)
    lines += [f"before_identity={bid}", f"after_identity={aid}"]
    # Recorded, not gated: the pinned file hashes already prove the tree, and HEAD only names where it came from.
    lines.append(f"checkout_head={(a or b or {}).get('checkout_head', 'unread')}")
    try:
        order = "ok" if int(b["ended"]) <= int(a["started"]) else "after-started-before-before-ended"
    except (TypeError, KeyError, ValueError):
        order = "unread"
    lines.append(f"order={order}")

    mode_b, mode_a = (b or {}).get("repro_mode", "unread"), (a or {}).get("repro_mode", "unread")
    lines.append(f"repro_mode={mode_b},{mode_a}")
    rb, ra = before_repro(b), after_repro(a)
    lines += [f"before_repro={rb}", f"before_line={(b or {}).get('repro_line', '')}",
              f"after_repro={ra}", f"after_line={(a or {}).get('repro_line', '')}"]
    unit = unit_result(a, cases(f"{sweep}/after/unit.xml"))
    lines.append(f"after_unit={unit}")
    existing = {n: existing_result(n, a, cases(f"{sweep}/after/{n}.xml")) for n in EXISTING}
    lines += [f"after_{n}={r}" for n, r in existing.items()]

    # The first failed condition names the verdict, in the order a reader must rule them out.
    if image != "ok" or bid != "ok" or aid != "ok" or order != "ok":
        verdict = "void-identity"
    elif imp != "ok":
        verdict = "void-import-check"
    elif mode_b != mode_a:
        verdict = "repro-mode-differs"
    elif rb != "bug-shown":
        verdict = "before-did-not-reproduce"
    elif ra == "fixed-inexact":
        verdict = "after-fixed-inexact"
    elif ra != "fixed":
        verdict = "after-not-fixed"
    elif unit != "passed":
        verdict = "after-unit-test-not-passed"
    elif not all(r.startswith(("skipped(", "passed(")) for r in existing.values()):
        verdict = "after-existing-tests-not-passed"
    else:
        verdict = "confirmed"
    lines.append(f"verdict={verdict}")
    print("\n".join(lines))
    return 0 if verdict == "confirmed" else 2


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    sys.exit(main(*sys.argv[1:]))
