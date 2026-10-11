#!/usr/bin/env python3
"""Compares a vLLM "non-default args: {...}" line with the engine the admission study measured.

Usage: check-engine-args.py LINE_FILE CAP SERVED_NAME

The reference is hack/lib/prospective-pilot.sh's pp_expected_args CAP itself, run through bash, so this check and the
pilot's validator cannot drift apart. Two of its keys are left out because the controller does not render them: they
only instrumented the measured runs, and the unprotected arm carried them too. served_model_name is added because the
controller renders it for the gateway to route on. port and host may be present with any value, as the pilot allows.

Every other key must match exactly, in both directions: a missing measured key or an extra unmeasured key refuses.
Exit 0 on a match, 1 with the differences listed otherwise.
"""
import ast
import os
import subprocess
import sys

INSTRUMENTATION = {"enable_logging_iteration_details", "scheduler_cls"}
INFRASTRUCTURE = {"port", "host"}


def expected(cap: str, served: str) -> dict:
    lib = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib", "prospective-pilot.sh")
    out = subprocess.run(["bash", "-c", 'source "$1" && pp_expected_args "$2"', "_", lib, cap],
                         check=True, capture_output=True, text=True).stdout
    want = {}
    for line in out.strip().splitlines():
        key, _, value = line.partition("=")
        want[key] = ast.literal_eval(value)
    for key in INSTRUMENTATION:
        if key not in want:
            sys.exit(f"pp_expected_args no longer prints {key}; this check's exemption is stale")
        del want[key]
    want["served_model_name"] = served
    return want


def observed(path: str) -> dict:
    text = open(path, encoding="utf-8").read().strip()
    marker = "non-default args: "
    if marker not in text:
        sys.exit(f"{path} holds no non-default args line")
    return ast.literal_eval(text[text.index(marker) + len(marker):])


def same(a, b) -> bool:
    if isinstance(a, (int, float)) and isinstance(b, (int, float)) and not isinstance(a, bool) and not isinstance(b, bool):
        return float(a) == float(b)
    # vLLM prints served_model_name as a list of one.
    if isinstance(a, list) and len(a) == 1 and not isinstance(b, list):
        return a[0] == b
    return a == b


def main() -> int:
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    path, cap, served = sys.argv[1:]
    want, got = expected(cap, served), observed(path)
    problems = []
    for key, value in want.items():
        if key not in got:
            problems.append(f"missing {key}={value!r}, which was measured")
        elif not same(got[key], value):
            problems.append(f"{key}={got[key]!r}, measured {value!r}")
    for key, value in got.items():
        if key not in want and key not in INFRASTRUCTURE:
            problems.append(f"extra {key}={value!r}, which the rendered profile does not carry")
    if problems:
        print(f"REFUSED {path} against pp_expected_args {cap}:")
        for p in problems:
            print(f"  {p}")
        return 1
    print(f"MATCH {path}: {len(want)} measured keys, cap {cap}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
