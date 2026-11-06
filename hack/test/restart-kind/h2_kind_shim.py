"""h2_corelimit.py, unmodified, reading its verdicts from score_kind_shim.py's scorer so a kind rehearsal can be evaluated.

    python3 hack/test/restart-kind/h2_kind_shim.py <run directory>

The unmodified scorer voids every gloo rank, which would leave H2 NOT ASSESSED on kind by construction.
Kind cannot show a core dump's cost, since its ranks run on CPU and its host writes no cores; what this shows is that the
arms were applied, logged and read.
"""

from __future__ import annotations

import importlib.util
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[3]
_spec = importlib.util.spec_from_file_location("score_kind_shim", ROOT / "hack/test/restart-kind/score_kind_shim.py")
_shim = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_shim)
# h2_corelimit and h1_retarget import score_eks by name, so the patched module must be the one registered under it.
sys.modules["score_eks"] = _shim.score_eks
sys.path.insert(0, str(ROOT / "experiments/distributed-restart"))
import h2_corelimit  # noqa: E402

if __name__ == "__main__":
    sys.exit(h2_corelimit.main(sys.argv))
