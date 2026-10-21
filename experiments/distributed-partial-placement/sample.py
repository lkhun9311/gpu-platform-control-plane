"""Samples one partial-placement run once a second, for experiments/distributed-partial-placement/README.md.

    python3 sample.py <context> <namespace> <job name> <clusterqueue> <squatter namespace> <squatter pod> <until epoch> <out>

Each line is one sample: when it was taken, whether every read succeeded, and what each read returned.
A failed read is written as failed with its error, never as an empty object, because the scorer treats a sample with
a failed read as missing and an empty object would read as "nothing there".
"""

import datetime
import json
import subprocess
import sys
import time


def kubectl(context, *args):
    """Returns (object, error): the parsed JSON, or None and the reason it could not be read."""
    proc = subprocess.run(["kubectl", "--context", context, *args, "-o", "json"],
                          capture_output=True, text=True, timeout=10)
    if proc.returncode != 0:
        return None, proc.stderr.strip()[:500] or f"exit {proc.returncode}"
    try:
        return json.loads(proc.stdout), None
    except json.JSONDecodeError as exc:
        return None, f"unparsable: {exc}"


def conditions(obj):
    return [{k: c.get(k) for k in ("type", "status", "reason", "message", "lastTransitionTime")}
            for c in (obj.get("status") or {}).get("conditions") or []]


def pod_view(p):
    cs = ((p.get("status") or {}).get("containerStatuses") or [{}])[0]
    return {
        "uid": p["metadata"]["uid"], "name": p["metadata"]["name"],
        "index": (p["metadata"].get("annotations") or {}).get("batch.kubernetes.io/job-completion-index"),
        "created": p["metadata"].get("creationTimestamp"),
        "deletionTimestamp": p["metadata"].get("deletionTimestamp"),
        "node": p["spec"].get("nodeName"), "phase": (p.get("status") or {}).get("phase"),
        "conditions": conditions(p), "ready": cs.get("ready"), "state": cs.get("state"),
    }


def sample(context, ns, job_name, cq, squat_ns, squat_pod):
    out, errors = {}, {}
    # One list call for the namespaced kinds keeps them as close to one instant as kubectl allows.
    items, err = kubectl(context, "-n", ns, "get", "mltrainingjobs,jobs,workloads.kueue.x-k8s.io,pods")
    if err:
        errors["namespace"] = err
    else:
        by_kind = {}
        for o in items["items"]:
            by_kind.setdefault(o["kind"], []).append(o)
        mltj = [o for o in by_kind.get("MLTrainingJob", []) if o["metadata"]["name"] == job_name]
        job = [o for o in by_kind.get("Job", []) if o["metadata"]["name"] == job_name]
        out["mltj"] = mltj[0].get("status") if mltj else None
        out["mltjExists"] = bool(mltj)
        out["job"] = {"suspend": job[0]["spec"].get("suspend"), "status": job[0].get("status")} if job else None
        job_uid = job[0]["metadata"]["uid"] if job else None
        out["workloads"] = [{
            "uid": w["metadata"]["uid"], "name": w["metadata"]["name"],
            "owners": [o.get("uid") for o in w["metadata"].get("ownerReferences") or []],
            "active": w["spec"].get("active"), "conditions": conditions(w),
            "requeueState": (w.get("status") or {}).get("requeueState"),
        } for w in by_kind.get("Workload", [])]
        out["jobUID"] = job_uid
        out["pods"] = [pod_view(p) for p in by_kind.get("Pod", [])
                       if (p["metadata"].get("labels") or {}).get("platform.lkhun9311.github.io/mltrainingjob") == job_name]
    q, err = kubectl(context, "get", "clusterqueue", cq)
    if err:
        errors["clusterqueue"] = err
    else:
        out["cqReservation"] = (q.get("status") or {}).get("flavorsReservation")
    s, err = kubectl(context, "-n", squat_ns, "get", "pods", "--field-selector", f"metadata.name={squat_pod}")
    if err:
        errors["squatter"] = err
    else:
        out["squatter"] = [{"phase": (p.get("status") or {}).get("phase"), "node": p["spec"].get("nodeName"),
                            "deletionTimestamp": p["metadata"].get("deletionTimestamp")} for p in s["items"]]
    return out, errors


def main(argv):
    context, ns, job_name, cq, squat_ns, squat_pod, until, path = argv
    until = float(until)
    with open(path, "a") as f:
        while time.time() < until:
            began = time.time()
            observed = datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="milliseconds")
            try:
                out, errors = sample(context, ns, job_name, cq, squat_ns, squat_pod)
            except Exception as exc:  # noqa: BLE001 -- a sampler that dies silently is worse than a failed sample
                out, errors = {}, {"sampler": f"{type(exc).__name__}: {exc}"[:500]}
            f.write(json.dumps({"observed": observed, "ok": not errors, "errors": errors, **out}, sort_keys=True) + "\n")
            f.flush()
            time.sleep(max(0.0, 1.0 - (time.time() - began)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
