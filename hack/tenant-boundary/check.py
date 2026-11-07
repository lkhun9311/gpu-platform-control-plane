#!/usr/bin/env python3
"""Score a tenant-boundary run: python3 hack/tenant-boundary/check.py <run-dir>.

Reads <run-dir>/run.json and <run-dir>/results.jsonl written by run.sh, writes <run-dir>/verdict.json, prints one
line per check and exits 0 only on PASS.

What each check must observe lives here, not in run.sh, so a runner that recorded the wrong thing cannot also
decide that it was right.
A refusal counts only in the words of the layer that should refuse: an RBAC denial for a request RBAC must stop, the
named admission policy for a request admission must stop, Pod Security for a Pod it must stop.
Any other failure (a typo, a missing CRD, a webhook down) is not the boundary working and scores as a failure.
A blocked connection counts only as a timeout, and only when the same client and the same target each succeeded in
another check, so a Pod that never started cannot pass for an isolated one.
"""
import json
import os
import sys

TENANT_USER = 'User "user-train-a"'

# id: (expectation, argument, the checks that must have succeeded for this one to mean anything)
CHECKS = {
    "own-namespace-job": ("allowed", None, ()),
    "other-namespace-job": ("rbac-forbidden", 'cannot create resource "mltrainingjobs"', ()),
    "create-pod": ("rbac-forbidden", 'cannot create resource "pods"', ()),
    "create-job": ("rbac-forbidden", 'cannot create resource "jobs"', ()),
    "create-resourcequota": ("rbac-forbidden", 'cannot create resource "resourcequotas"', ()),
    "create-localqueue": ("rbac-forbidden", 'cannot create resource "localqueues"', ()),
    "create-networkpolicy": ("rbac-forbidden", 'cannot create resource "networkpolicies"', ()),
    "tenant-fences": ("policy-denied", "tenant-reserved-metadata", ("own-namespace-job",)),
    "admin-fences": ("allowed", None, ("own-namespace-job",)),
    "tenant-strips-finalizer": ("policy-denied", "tenant-reserved-metadata", ("own-namespace-job",)),
    "tenant-binds-staged-volume": ("policy-denied", "tenant-claim-binding", ()),
    "tenant-raises-tier": ("rbac-forbidden", 'cannot patch resource "gpuquotapolicies"', ()),
    "tenant-labels-namespace": ("rbac-forbidden", 'cannot patch resource "namespaces"', ()),
    "privileged-pod": ("pod-security", 'violates PodSecurity "baseline:v1.31"', ()),
    "rank-to-rank": ("reached", "rank-1", ()),
    "dns": ("resolved", None, ()),
    "gateway-to-own-engine": ("reached", "engine-a", ()),
    "gateway-to-other-engine": ("reached", "engine-b", ()),
    "monitoring-to-gateway": ("reached", "gateway", ()),
    "monitoring-to-rank": ("reached", "rank-0", ()),
    # The client is rank-0, which rank-to-rank shows can connect; each target is shown up by another client.
    "tenant-to-other-engine": ("blocked", None, ("rank-to-rank", "gateway-to-other-engine")),
    "tenant-to-gateway-metrics": ("blocked", None, ("rank-to-rank", "monitoring-to-gateway")),
    "trainer-to-own-engine": ("blocked", None, ("rank-to-rank", "gateway-to-own-engine")),
}


def judge(kind, arg, rec, run):
    rc, out, err = rec["exit"], rec["stdout"], rec["stderr"]
    if kind == "allowed":
        return rc == 0, f"exit {rc}" + ("" if rc == 0 else f": {err.strip()[:200]}")
    if rc == 0:
        return False, "the request succeeded"
    if kind == "rbac-forbidden":
        ok = "(Forbidden)" in err and TENANT_USER in err and arg in err
        return ok, ("RBAC refused it" if ok else f"refused, but not by RBAC as {arg}: {err.strip()[:200]}")
    if kind == "policy-denied":
        ok = f"ValidatingAdmissionPolicy '{arg}'" in err and "denied request" in err
        return ok, (f"{arg} refused it" if ok else f"refused, but not by {arg}: {err.strip()[:200]}")
    if kind == "pod-security":
        ok = arg in err
        return ok, ("Pod Security refused it" if ok else f"refused, but not by Pod Security: {err.strip()[:200]}")
    if kind == "blocked":
        ok = "timed out" in err
        return ok, ("timed out" if ok else f"failed without a timeout: {err.strip()[:200]}")
    raise ValueError(kind)


def judge_success(kind, arg, rec, run):
    rc, out, err = rec["exit"], rec["stdout"], rec["stderr"]
    if rc != 0:
        return False, f"exit {rc}: {err.strip()[:200]}"
    if kind == "reached":
        ok = out.strip() == arg
        return ok, (f"{arg} answered" if ok else f"something other than {arg} answered: {out.strip()[:80]!r}")
    if kind == "resolved":
        ip = run.get("kubernetes_service_ip", "")
        ok = bool(ip) and ip in out
        return ok, (f"resolved to {ip}" if ok else f"did not resolve to the kubernetes Service {ip!r}: {out[:200]!r}")
    raise ValueError(kind)


def main():
    d = sys.argv[1]
    run = json.load(open(os.path.join(d, "run.json")))
    records = {}
    problems = []
    for n, line in enumerate(open(os.path.join(d, "results.jsonl")), 1):
        r = json.loads(line)
        if r["id"] in records:
            problems.append(f"results.jsonl line {n}: {r['id']} recorded twice")
        records[r["id"]] = r
    for unknown in sorted(set(records) - set(CHECKS)):
        problems.append(f"{unknown} is recorded but not registered here")

    # The run must be of a committed tree, on the CNI and images it names, or the checks describe nothing anyone
    # can rebuild.
    if run.get("dirty_paths") != 0:
        problems.append(f"the run was made with {run.get('dirty_paths')} uncommitted change(s) under its paths")
    if not run.get("git_head"):
        problems.append("run.json names no commit")
    if run.get("cni") != "calico" or not run.get("calico_manifest_sha256"):
        problems.append("run.json names no pinned enforcing CNI")

    results = {}
    for cid, (kind, arg, _) in CHECKS.items():
        if cid not in records:
            results[cid] = (False, "absent: the run recorded nothing for it")
            continue
        fn = judge_success if kind in ("reached", "resolved") else judge
        results[cid] = fn(kind, arg, records[cid], run)
    for cid, (_, _, needs) in CHECKS.items():
        failed = [n for n in needs if not results[n][0]]
        if failed and results[cid][0]:
            results[cid] = (False, f"{results[cid][1]}, but it means nothing without {', '.join(failed)}")

    verdict = "PASS" if not problems and all(ok for ok, _ in results.values()) else "FAIL"
    out = {
        "verdict": verdict,
        "git_head": run.get("git_head"),
        "problems": problems,
        "checks": [{"id": c, "expected": CHECKS[c][0], "pass": results[c][0], "observed": results[c][1]} for c in CHECKS],
    }
    with open(os.path.join(d, "verdict.json"), "w") as f:
        json.dump(out, f, indent=2)
        f.write("\n")
    for c in CHECKS:
        print(f"{'ok  ' if results[c][0] else 'FAIL'} {c}: {results[c][1]}")
    for p in problems:
        print(f"FAIL {p}")
    print(f"tenant boundary: {verdict}")
    return 0 if verdict == "PASS" else 1


if __name__ == "__main__":
    sys.exit(main())
