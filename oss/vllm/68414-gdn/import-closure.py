#!/usr/bin/env python3
"""Every vllm and tests file reachable at import time from the given files, read from git at one commit.

    import-closure.py <vLLM clone> <commit> <file>...

It follows `import` and `from ... import` statements in module bodies, class bodies and if, try and with blocks, and every package __init__ on the way.
It skips function bodies and `if TYPE_CHECKING:` blocks, since neither runs when pytest imports a test module.
Run on a test file and the conftest files pytest loads for it, it lists what that collection imports, which oss/vllm/68414-gdn/vllm-gdn-68414-session-test.sh intersects with the files that differ between the image's commit and a diff base.
It is static, so an import made by a string at run time is not in it; the probe in lib.sh records what the real collection loaded.
"""
import ast
import subprocess
import sys


def main(repo, commit, starts):
    ls = subprocess.run(["git", "-C", repo, "ls-tree", "-r", "--name-only", commit, "vllm", "tests"], capture_output=True, text=True, check=True)
    files = set(ls.stdout.split())

    def src(p):
        return subprocess.run(["git", "-C", repo, "show", f"{commit}:{p}"], capture_output=True, text=True, check=True).stdout

    def mod_files(mod):
        parts = mod.split(".")
        out = []
        for i in range(1, len(parts) + 1):
            base = "/".join(parts[:i])
            out += [c for c in (base + ".py", base + "/__init__.py") if c in files]
        return out

    def package(path):
        return path[:-3].split("/")[:-1]

    def walk(body):
        for n in body:
            if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef)):
                continue
            if isinstance(n, ast.If) and "TYPE_CHECKING" in ast.unparse(n.test):
                yield from walk(n.orelse)
                continue
            yield n
            for field in ("body", "orelse", "finalbody", "handlers"):
                sub = getattr(n, field, None)
                if isinstance(sub, list):
                    yield from walk(sub)

    seen, todo = set(), list(starts)
    while todo:
        f = todo.pop()
        if f in seen:
            continue
        seen.add(f)
        for n in walk(ast.parse(src(f)).body):
            mods = []
            if isinstance(n, ast.Import):
                mods = [a.name for a in n.names]
            elif isinstance(n, ast.ImportFrom):
                if n.level:
                    pkg = package(f)
                    pkg = pkg[: len(pkg) - (n.level - 1)]
                    m = ".".join(pkg + ([n.module] if n.module else []))
                else:
                    m = n.module or ""
                # A name imported from a package may be a submodule, so both are followed.
                mods = [m] + [f"{m}.{a.name}" for a in n.names]
            for m in mods:
                if m.split(".")[0] in ("vllm", "tests"):
                    todo += mod_files(m)
    print("\n".join(sorted(seen)))


if __name__ == "__main__":
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2], sys.argv[3:])
