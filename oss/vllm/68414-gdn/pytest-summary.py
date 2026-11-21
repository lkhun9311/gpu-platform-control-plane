#!/usr/bin/env python3
"""Every pytest call of oss/vllm/68414-gdn/vllm-gdn-68414-session.sh run 4 in one human-readable page, for the PRs to quote.

    pytest-summary.py <sweep dir> <stride-test.diff sha256> <stride-fix.diff sha256>

It opens with the image: its digest and revision as docker reported them, and the wheel hash it carries.
For each call it prints the exact command, the GPU, the python executable and version, the diff with its sha256 and whether that is the pinned one, each git apply command with the paths it changed, the exit status, pytest's own summary line, and each case's outcome from the junit file.
Under each failed case it prints that case's failing source line and E lines, as --tb=short wrote them into the junit.
A call that left no record says so, and so does a failed case whose junit holds no E line, so the page never reads as complete when the run was not.
It judges nothing: stride-verdict.py does.
#68415's calls ran in run 3, whose summary is in its run directory, so this page lists #68416's alone.
"""
import sys
import xml.etree.ElementTree as ET

# (record directory, pytest key, title, diff file, index of its pinned sha256 among the arguments)
CALLS = (
    ("stride-before", "test", "#68416 BEFORE, test only, -k stride", "stride-test.diff", 0),
    ("stride-after", "test", "#68416 AFTER, full diff, -k stride", "stride-fix.diff", 1),
    ("stride-after", "file", "#68416 AFTER, full diff, the whole test file", "stride-fix.diff", 1),
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
        outcome, text = "passed", ""
        for tag in ("error", "failure", "skipped"):
            el = tc.find(tag)
            if el is not None:
                outcome, text = {"failure": "failed"}.get(tag, tag), el.text or ""
                break
        out.append((tc.get("name", ""), outcome, text))
    return out


def assertion_lines(text):
    """The failing source line and the E lines of one case, from --tb=short's text in the junit."""
    lines = [x.rstrip() for x in text.splitlines()]
    e = [i for i, x in enumerate(lines) if x.startswith("E ")]
    if not e:
        return []
    # The source line pytest prints just above the first E line is the statement that raised.
    src = [lines[e[0] - 1].strip()] if e[0] > 0 and not lines[e[0] - 1].startswith("E") else []
    return [f"> {s}" for s in src] + [lines[i] for i in e if lines[i].strip() != "E"]


def image(sweep):
    out = []
    for name, label in (("image-identity.txt", "image:  "), ("wheel-sha256.txt", "wheel:  ")):
        try:
            with open(f"{sweep}/{name}") as f:
                out.append(f"{label}{f.read().strip() or 'empty'}")
        except OSError:
            out.append(f"{label}not recorded")
    return out


def main(sweep, *shas):
    out = ["== the image every call ran in (digest and org.opencontainers.image.revision, as docker image inspect reported them)"]
    out += [f"   {x}" for x in image(sweep)]
    out.append("")
    for d, key, title, diff, i in CALLS:
        out.append(f"== {title} ({d}, {key})")
        st = kv(f"{sweep}/{d}/state.txt")
        if st is None or f"{key}_cmd" not in st:
            out.append("   not run: no pytest record in this state")
            out.append("")
            continue
        have = st.get("diff_sha256", "unread")
        out.append(f"   command: {st[f'{key}_cmd']}")
        out.append(f"   gpu:     {st.get('gpu_name', 'not recorded')}")
        out.append(f"   python:  {st.get('python_executable', 'not recorded')} {st.get('python_version', '')} ({st.get('pytest_version', 'pytest not recorded')})")
        out.append(f"   diff:    {diff} sha256 {have} ({'the pinned one' if have == shas[i] else 'NOT the pinned ' + shas[i]})")
        out.append(f"   applied: {st.get('apply_checkout_cmd', 'not recorded')}")
        out.append(f"            changed {st.get('apply_checkout_files') or 'nothing'}")
        out.append(f"   applied: {st.get('apply_site_cmd', 'not recorded')}")
        if "apply_site_files" in st:
            out.append(f"            changed {st.get('apply_site_files') or 'nothing'}")
        out.append(f"   exit:    {st.get(f'{key}_rc', 'not recorded; the call did not finish')}")
        out.append(f"   summary: {st.get(f'{key}_summary') or 'no pytest summary line'}")
        tc = cases(f"{sweep}/{d}/{key}.xml")
        if tc is None:
            out.append("   cases:   no junit file")
        else:
            out.append(f"   cases:   {len(tc)} in junit")
            for n, o, text in tc:
                out.append(f"     {o:8} {n}")
                if o in ("failed", "error"):
                    al = assertion_lines(text)
                    out += [f"              {x}" for x in al] or ["              no E line in the junit for this case"]
        out.append("")
    print("\n".join(out).rstrip("\n"))
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    sys.exit(main(*sys.argv[1:]))
