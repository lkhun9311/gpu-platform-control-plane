"""A fake `python -m pytest <file> -q`: 3 passed when the file exists, as the patch's tests do on a GPU.

FAKE_PYTEST=fail reports one failure; FAKE_PYTEST=skip reports the CUDA test skipped, as on a machine without a GPU.
"""

import os
import sys

args = [a for a in sys.argv[1:] if not a.startswith("-")]
if sys.argv[1:] == ["--version"]:
    print("pytest 8.3.5 (fake)")
    sys.exit(0)
if len(args) != 1 or not os.path.isfile(args[0]):
    print(f"ERROR: file or directory not found: {args}")
    sys.exit(4)
mode = os.environ.get("FAKE_PYTEST", "pass")
if mode == "fail":
    print("F..\n1 failed, 2 passed in 0.12s")
    sys.exit(1)
if mode == "skip":
    print("..s\n2 passed, 1 skipped in 0.10s")
    sys.exit(0)
print("...\n3 passed in 0.11s")
