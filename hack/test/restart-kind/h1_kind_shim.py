"""h1_retarget.py, unmodified, reading its verdicts from score_kind_shim.py's scorer so a kind rehearsal can be evaluated.

    python3 hack/test/restart-kind/h1_kind_shim.py <run directory>

The unmodified scorer voids every gloo rank, which would leave H1 NOT ASSESSED on kind by construction.
"""

from __future__ import annotations

import importlib.util
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[3]
_spec = importlib.util.spec_from_file_location("score_kind_shim", ROOT / "hack/test/restart-kind/score_kind_shim.py")
_shim = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_shim)
# h1_retarget imports score_eks by name, so the patched module must be the one registered under that name.
sys.modules["score_eks"] = _shim.score_eks
sys.path.insert(0, str(ROOT / "experiments/distributed-restart"))
import h1_retarget  # noqa: E402

if __name__ == "__main__":
    sys.exit(h1_retarget.main(sys.argv))
