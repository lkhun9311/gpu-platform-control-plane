#!/usr/bin/env python3
"""Keep only the kernel OOM reports of a journal capture, with the host's name and hardware line removed.

The capture is the host's whole kernel log for the case's window, which carries the workstation's name, its board and
unrelated drivers' lines; none of that is evidence, and the repository is public.
Usage: trim-journal.py IN OUT; prints how many lines were read and kept.
"""

import re
import sys

START = re.compile(r"\binvoked oom-killer:")
# The last lines a report prints: the victims, and the group-kill notice between them.
TAIL = re.compile(r"\bMemory cgroup out of memory: Killed process |\bare going to be killed due to memory\.oom\.group set")
HOST = re.compile(r"^(\[\s*[0-9.]+\]) \S+ kernel: ")


def trim(lines):
    out = []
    in_report = False
    # Whether the current report has printed a victim line; lines after one are held until another claims them.
    closed = False
    pending = []
    for line in lines:
        line = HOST.sub(r"\1 host kernel: ", line)
        if START.search(line):
            # After a report's victims, unclaimed lines are noise; a report that never named a victim is kept whole,
            # because dropping it would read as "no report" for a case that expects none.
            if not closed:
                out.extend(pending)
            pending = []
            in_report, closed = True, False
        if not in_report:
            continue
        if "Hardware name:" in line:
            continue
        pending.append(line)
        if TAIL.search(line):
            out.extend(pending)
            pending = []
            closed = True
    if in_report and not closed:
        out.extend(pending)
    return out


def main(src, dst):
    with open(src) as f:
        lines = f.readlines()
    kept = trim(lines)
    with open(dst, "w") as f:
        f.writelines(kept)
    print(f"{src}: read {len(lines)} lines, kept {len(kept)}")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("usage: trim-journal.py IN OUT", file=sys.stderr)
        sys.exit(2)
    main(sys.argv[1], sys.argv[2])
