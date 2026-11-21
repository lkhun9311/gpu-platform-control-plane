"""A pytest plugin for lib.sh's probe: every vllm and tests file the collection loaded, with its sha256.

    FLA_LOADED_OUT=<file> FLA_LOADED_ROOTS=<site>:<checkout> python3 -m pytest --collect-only -p fla_loaded_modules ...

Each line is `<sha256>  <path relative to its root>  <absolute path>`.
It runs after the collection, so the conftest files and the selected test modules have been imported as the run imports them.
"""
import hashlib
import os
import sys


def pytest_collection_finish(session):
    roots = [r.rstrip("/") + "/" for r in os.environ["FLA_LOADED_ROOTS"].split(":")]
    rows = set()
    for m in list(sys.modules.values()):
        f = getattr(m, "__file__", None)
        if not f:
            continue
        f = os.path.abspath(f)
        for r in roots:
            rel = f[len(r):]
            if f.startswith(r) and rel.split("/", 1)[0] in ("vllm", "tests"):
                rows.add((rel, f))
    with open(os.environ["FLA_LOADED_OUT"], "w") as out:
        for rel, f in sorted(rows):
            with open(f, "rb") as fh:
                out.write(f"{hashlib.sha256(fh.read()).hexdigest()}  {rel}  {f}\n")
