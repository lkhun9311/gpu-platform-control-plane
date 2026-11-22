"""A fake pip: `install --no-deps --no-build-isolation -e python` writes the editable .pth a real install writes.

The .pth puts <cwd>/python first on sys.path, so the fake container imports the tree's sglang, as the real one would.
FAKE_INSTALL_FAIL=1 makes the editable install fail; any other install succeeds without doing anything.
"""

import os
import sys
import sysconfig

args = sys.argv[1:]
if args[:1] == ["--version"]:
    print("pip 25.0 (fake)")
    sys.exit(0)
if args[:1] != ["install"]:
    sys.exit(f"fake pip: unsupported {args}")
if "-e" in args:
    if os.environ.get("FAKE_INSTALL_FAIL") == "1":
        sys.exit("fake pip: the editable build failed")
    target = os.path.abspath(args[args.index("-e") + 1])
    if not os.path.isdir(os.path.join(target, "sglang")):
        sys.exit(f"fake pip: {target} holds no sglang package")
    site = sysconfig.get_paths()["purelib"]
    # Sorts before _sgl51628_fakes.pth, so the tree's sglang wins over the shared fake one, as a real editable install wins over nothing.
    with open(os.path.join(site, "__editable__.sglang-0.pth"), "w") as f:
        f.write(target + "\n")
print("fake pip: done")
