#!/usr/bin/env python3
"""The #68414 verdict of hack/vllm-gdn-68414-session.sh run 2, read from the records hack/vllm-gdn-68414/state.sh leaves.

    verdict.py <sweep dir> <fix.diff sha256> <kernel_repro.py sha256>

Prints key=value lines prefixed gdn_, the import check first, and exits 0 only when gdn_verdict is "confirmed".
It reads only the gdn-after record and the image identity, so no other item can change it.
"confirmed" needs every one of these, on the pinned image and the pinned AFTER tree:
  - kernel_repro.py, run through the wrapper as run 1 ran it, prints the reporter's fixed line exactly;
  - the imported index.py holds the fix line and output_size, and not the bug line.
Run 1's BEFORE on the same image is printed as a reference and is not required here.
The new test is CPU-only, so its result is printed as gdn_unit and never decides the verdict.
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
FIXED_LINE = "unwritten 0 o_err 0.0 state_err 0.0 empty_keeps_h0 True"
# Run 1's BEFORE, on this image and commit, which run 2 does not repeat.
BEFORE_REFERENCE = ("hack/vllm-gdn-68414/runs/2026-11-19-run1-spot-reclaimed/verdict.txt: "
                    "unwritten 70 o_err 1234.100830078125 state_err nan empty_keeps_h0 True")
UNIT_CASE = re.compile(r"^test_chunk_indices_keep_ids_of_empty_sequences\[.+\]$")
# Six sequence-length lists, each with int32 and int64.
UNIT_CASES = 12


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


def image_identity(sweep):
    try:
        with open(f"{sweep}/image-identity.txt") as f:
            ident = f.read()
        with open(f"{sweep}/wheel-sha256.txt") as f:
            wheel = f.read().strip()
    except OSError:
        return "missing"
    return "ok" if IMAGE_DIGEST in ident and ident.rstrip().endswith(" " + VLLM_COMMIT) and wheel else "mismatch"


def identity(st, want_diff, want_repro):
    if st is None:
        return "missing"
    for key, want in (("base_identity", "ok"), ("apply", "ok"), ("applied_identity", "ok"),
                      ("diff_sha256", want_diff), ("repro_sha256", want_repro)):
        if st.get(key) != want:
            return f"{key}={st.get(key, 'unread')}"
    return "ok"


def import_check(st):
    """ok when Python imported the image's index.py, holding the final fix and not the bug, in both the state and the wrapper."""
    if st is None:
        return "missing"
    if st.get("index_file") != INDEX:
        return f"wrong-file({st.get('index_file')})"
    rcs = {k: st.get(k) for k in ("fix_grep_rc", "outsize_grep_rc", "bug_grep_rc")}
    if rcs != {"fix_grep_rc": "0", "outsize_grep_rc": "0", "bug_grep_rc": "1"}:
        return "lines(" + ",".join(f"{k}={v}" for k, v in rcs.items()) + ")"
    # The wrapper prints the file its own process imported, and the repro's answer speaks for that file only.
    # A run that printed no answer imported nothing to speak for, and after_repro names it instead.
    if st.get("repro_line") and st.get("repro_index_file") != INDEX:
        return f"repro-wrong-file({st.get('repro_index_file')})"
    return "ok"


def after_repro(st):
    if st is None or "repro_line" not in st:
        return "missing"
    line = st["repro_line"]
    m = LINE.match(line)
    if not m:
        return f"no-result(rc={st.get('repro_cuda_rc')})"
    # A run that printed and then crashed or hung is not an answer.
    if st.get("repro_cuda_rc") != "0":
        return f"exited-{st.get('repro_cuda_rc')}"
    if line == FIXED_LINE:
        return "fixed"
    unwritten, o_err, state_err, keeps = int(m.group(1)), float(m.group(2)), float(m.group(3)), m.group(4) == "True"
    if unwritten == 0 and keeps and math.isfinite(o_err) and math.isfinite(state_err):
        return "fixed-inexact"
    return "not-fixed"


def unit_result(st, tc):
    if st is None or "unit_rc" not in st:
        return "missing"
    rc = st["unit_rc"]
    if tc is None:
        return f"no-junit(rc={rc})"
    names = {n for n, _, _ in tc}
    if any(not UNIT_CASE.match(n) for n in names):
        return f"unexpected-cases(rc={rc})"
    # Twelve distinct cases, so a repeated name cannot stand in for a case that never ran.
    if rc == "0" and len(names) == len(tc) == UNIT_CASES and all(o == "passed" for _, o, _ in tc):
        return "passed"
    outcomes = ",".join(o for _, o, _ in tc) or "none"
    return f"not-passed(rc={rc},cases={len(tc)},outcomes={outcomes})"


def main(sweep, fix_sha, repro_sha):
    a = kv(f"{sweep}/gdn-after/state.txt")
    imp = import_check(a)
    image = image_identity(sweep)
    aid = identity(a, fix_sha, repro_sha)
    ra = after_repro(a)
    lines = [f"gdn_import_check={imp}", f"gdn_image={image}", f"gdn_after_identity={aid}",
             # Recorded, not gated: the pinned file hashes already prove the tree, and HEAD only names where it came from.
             f"gdn_checkout_head={(a or {}).get('checkout_head', 'unread')}",
             f"gdn_repro_mode={(a or {}).get('repro_mode', 'unread')}",
             f"gdn_after_repro={ra}", f"gdn_after_line={(a or {}).get('repro_line', '')}",
             f"gdn_before_reference={BEFORE_REFERENCE}",
             f"gdn_unit={unit_result(a, cases(f'{sweep}/gdn-after/unit.xml'))}"]

    # The first failed condition names the verdict, in the order a reader must rule them out.
    if image != "ok" or aid != "ok":
        verdict = "void-identity"
    elif imp != "ok":
        verdict = "void-import-check"
    elif ra == "fixed-inexact":
        verdict = "after-fixed-inexact"
    elif ra != "fixed":
        verdict = "after-not-fixed"
    else:
        verdict = "confirmed"
    lines.append(f"gdn_verdict={verdict}")
    print("\n".join(lines))
    return 0 if verdict == "confirmed" else 2


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    sys.exit(main(*sys.argv[1:]))
