#!/usr/bin/env python3
"""Every pytest call of hack/vllm-gdn-68414-session.sh run 2 in one human-readable page, for the PRs to quote.

    pytest-summary.py <sweep dir> <fix.diff sha256> <kda-test.diff sha256> <kda-fix.diff sha256> <stride-test.diff sha256> <stride-fix.diff sha256>

For each call it prints the exact command, the diff the state applied with its sha256 and whether that is the pinned one, the exit status, pytest's own summary line, and each case's outcome from the junit file.
A call that left no record says so, so the page never reads as complete when the run was not.
It judges nothing: the three verdict scripts do.
"""
import sys
import xml.etree.ElementTree as ET

# (record directory, pytest key, title, diff file, index of its pinned sha256 among the arguments)
CALLS = (
    ("gdn-after", "unit", "#68414 AFTER, new CPU-only test", "fix.diff", 0),
    ("stride-before", "test", "#68416 BEFORE, test file only", "stride-test.diff", 3),
    ("stride-after", "test", "#68416 AFTER, full diff", "stride-fix.diff", 4),
    ("kda-before", "test", "#68415 BEFORE, test file only, 64-32 case only", "kda-test.diff", 1),
    ("kda-after", "test", "#68415 AFTER, full diff", "kda-fix.diff", 2),
)


def kv(path):
    try:
        with open(path) as f:
            return dict(line.rstrip("\n").split("=", 1) for line in f if "=" in line)
    except OSError:
        return None


def cases(path):
    try:
        root = ET.parse(path).getroot()
    except (OSError, ET.ParseError):
        return None
    out = []
    for tc in root.iter("testcase"):
        outcome = "passed"
        for tag in ("error", "failure", "skipped"):
            if tc.find(tag) is not None:
                outcome = {"failure": "failed"}.get(tag, tag)
                break
        out.append((tc.get("name", ""), outcome))
    return out


def main(sweep, *shas):
    out = []
    for d, key, title, diff, i in CALLS:
        out.append(f"== {title} ({d})")
        st = kv(f"{sweep}/{d}/state.txt")
        if st is None or f"{key}_cmd" not in st:
            out.append("   not run: no pytest record in this state")
            out.append("")
            continue
        have = st.get("diff_sha256", "unread")
        out.append(f"   command: {st[f'{key}_cmd']}")
        out.append(f"   diff:    {diff} sha256 {have} ({'the pinned one' if have == shas[i] else 'NOT the pinned ' + shas[i]})")
        out.append(f"   exit:    {st.get(f'{key}_rc', 'not recorded; the call did not finish')}")
        out.append(f"   summary: {st.get(f'{key}_summary') or 'no pytest summary line'}")
        tc = cases(f"{sweep}/{d}/{key}.xml")
        if tc is None:
            out.append("   cases:   no junit file")
        else:
            out.append(f"   cases:   {len(tc)} in junit")
            out += [f"     {o:8} {n}" for n, o in tc]
        out.append("")
    print("\n".join(out).rstrip("\n"))
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 7:
        sys.exit(__doc__)
    sys.exit(main(*sys.argv[1:]))
