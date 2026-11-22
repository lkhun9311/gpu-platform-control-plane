"""A fake TreeCore extension loader: importing it builds into SGLANG_CACHE_DIR when the build mode is auto, as SGLang's does.

FAKE_TREECORE_FAIL=1 makes the build fail, as a cargo or crate download failure would.
"""

import os

if os.environ.get("FAKE_TREECORE_FAIL") == "1":
    raise RuntimeError("fake cargo build failed")
if os.environ.get("SGLANG_RUST_BUILD_MODE") != "auto":
    raise ModuleNotFoundError("sglang.srt.mem_cache.rust_tree_core.mem_cache is not bundled or cached, and Rust extension build mode is 'never'")
_cache = os.path.expanduser(os.environ.get("SGLANG_CACHE_DIR", "~/.cache/sglang"))
_art = os.path.join(_cache, "rust_extensions", "artifacts", "sglang-radix-tree", "fakefingerprint")
os.makedirs(_art, exist_ok=True)
with open(os.path.join(_art, "mem_cache.cpython-fake.so"), "w") as f:
    f.write("fake extension\n")
os.makedirs(os.path.join(_cache, "rust_extensions", "targets", "big"), exist_ok=True)
bindings = "fake-bindings"
