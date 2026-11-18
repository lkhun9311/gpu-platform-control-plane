#!/usr/bin/env python3
"""Fake aws, docker, kubectl, helm, make, kind, nvidia-smi and sleep for hack/dra-nvidia-gpu-session-test.sh.

One file, linked under each tool's name, so the model of the cluster and of AWS the tools share lives in one place.
Every call is appended to $FAKE_STATE/calls, which the test reads to check what the scripts ran and in what order.
Nothing here reaches AWS, a cluster, a GPU or the network.
"""
import datetime
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import time

ST = os.environ["FAKE_STATE"]
TOOL = os.path.basename(sys.argv[0])
A = sys.argv[1:]
MODEL = os.path.join(ST, "model.json")


def load():
    if os.path.exists(MODEL):
        with open(MODEL) as f:
            return json.load(f)
    return {"claims": {}, "cp": {}, "down": False, "restarts": 0, "releases": ["dra-driver-nvidia-gpu-batssuite"],
            "terminated": False, "applied": 0}


def save(m):
    with open(MODEL, "w") as f:
        json.dump(m, f)


def record(extra=""):
    with open(os.path.join(ST, "calls"), "a") as f:
        f.write(TOOL + " " + " ".join(A) + extra + "\n")


def arg(flag, default=None):
    return A[A.index(flag) + 1] if flag in A else default


def has(*words):
    return all(w in A for w in words)


def out(s=""):
    if s:
        sys.stdout.write(s if s.endswith("\n") else s + "\n")
    sys.exit(0)


def env(name, default=""):
    return os.environ.get(name, default)


def now_iso(offset=0):
    t = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(seconds=offset)
    return t.strftime("%Y-%m-%dT%H:%M:%S+00:00")


# ---------------------------------------------------------------- the cluster
def kubectl(m):
    if "apply" in A:
        path = arg("-f")
        text = open(path).read()
        m["applied"] += 1
        shutil.copy(path, os.path.join(ST, "applied-%02d.yaml" % m["applied"]))
        for ns in re.findall(r"namespace: (s1-r\d+)\n  name: gpu\n", text):
            uid = "uid-" + ns
            m["claims"][ns + "/gpu"] = uid
            if not env("FAKE_S1_NOT_PREPARED"):
                m["cp"][uid] = "PrepareCompleted"
            m["claims"][ns + "/pod"] = "pod"
        if "gpu-test-mps" in text:
            m["claims"]["gpu-test-mps/claim"] = "uid-mps"
            # The entry appears a second after the apply, as a prepare does, so a kill that does not wait for it is seen.
            if not env("FAKE_MPS_NEVER"):
                m["cp"]["uid-mps"] = "PrepareStarted"
                m["mps_at"] = time.time() + 1.0
        for name in re.findall(r"kind: ResourceClaim\nmetadata:\n  namespace: s3-shares\n  name: (mem-\d)", text):
            m["claims"]["s3-shares/" + name] = "uid-" + name
        save(m)
        out()
    if "wait" in A:
        if env("FAKE_S3_POD1_PENDING") and "pod/pod-1" in A:
            sys.exit(1)
        out()
    if "rollout" in A:
        out()
    if "patch" in A:
        m["down"] = arg("--type") == "merge"
        # The fake plugin finishes every unprepare it missed when it returns, unless the test makes it leak.
        if not m["down"] and not env("FAKE_S1_LEAK"):
            for uid in [u for u in m["cp"] if u.startswith("uid-s1-") and not any(v == u for v in m["claims"].values())]:
                del m["cp"][uid]
        save(m)
        out()
    if "delete" in A:
        ns = arg("-n", "")
        if "pod/pod" in A:
            m["claims"].pop(ns + "/pod", None)
        if "resourceclaim/gpu" in A:
            m["claims"].pop(ns + "/gpu", None)
        if has("ns", "gpu-test-mps"):
            m["claims"].pop("gpu-test-mps/claim", None)
        save(m)
        out()
    if "create" in A or "describe" in A:
        out()
    if "logs" in A:
        out("\n".join(["I1118 driver.go] plugin started"] + ["I1118 driver.go] Unprepare: claim %s" % u for u in m["cp"]]))
    if "get" in A:
        ns = arg("-n", "")
        q = arg("-o", "")
        if "--ignore-not-found" in A:
            if "ns" in A:
                out("namespace/gpu-test-mps" if "gpu-test-mps/claim" in m["claims"] else "")
            obj = [a for a in A if "/" in a][0]
            kind, name = obj.split("/", 1)
            out(obj if ns + "/" + (name if kind == "resourceclaim" else "pod") in m["claims"] else "")
        if "resourceslices" in A and q == "json":
            mem = {"value": "23034Mi"}
            if not env("FAKE_NO_POLICY"):
                mem["requestPolicy"] = {"default": "0", "validRange": {"min": "0", "max": "23034Mi", "step": "1Mi"}}
            out(json.dumps({"items": [{"spec": {"devices": [{"name": "gpu-0", "capacity": {"memory": mem, "multiprocessors": {"value": "58"}}}]}}]}))
        if "ds" in A:
            out("dra-driver-nvidia-gpu-kubelet-plugin")
        if "resourceslices" in A and q == "name":
            out("resourceslice.resource.k8s.io/worker-gpu.nvidia.com-x")
        if "pods" in A and "-l" in A:
            if m["down"]:
                out()
            out("plugin-abc" if "jsonpath" in q else "pod/plugin-abc")
        if "pods" in A and "--no-headers" in A:
            out("dra-driver-nvidia-gpu-kubelet-plugin-abc   1/1   Running   0   1m")
        if "pod" in A and "plugin-abc" in A:
            out(str(m["restarts"]) if "restartCount" in q else "true")
        if "deploy" in A and q == "name":
            out(env("FAKE_MPS_LEFT"))
        if "resourceclaims" in A and ns == "gpu-test-mps":
            out(m["claims"].get("gpu-test-mps/claim", ""))
        for obj in [a for a in A if "/" in a]:
            kind, name = obj.split("/", 1)
            key = ns + "/" + (name if kind == "resourceclaim" else "pod")
            if kind == "resourceclaim" and name.startswith("mem-"):
                if key not in m["claims"]:
                    sys.exit(1)
                out('{"memory":"4Gi","multiprocessors":"58"}' if "consumedCapacity" in q else "")
            if kind in ("pod", "resourceclaim") and ns.startswith("s1-"):
                if key not in m["claims"]:
                    sys.exit(1)
                out(m["claims"][key] if "uid" in q else "%s: %s" % (kind, name))
        if "events" in A and "FailedScheduling" in " ".join(A):
            out("0/2 nodes are available: 1 cannot allocate all claims" if env("FAKE_S3_POD1_PENDING") else "")
        out("stub " + " ".join(A))
    out()


def docker(m):
    if A[:1] == ["ps"]:
        out(env("FAKE_WORKERS", "dra-session-worker"))
    if A[:1] == ["exec"]:
        rest = A[2:]
        if rest[:2] == ["cat", "/proc/mounts"]:
            out("overlay / overlay rw 0 0")
        if rest[:1] == ["cat"]:
            live = {u: s for u, s in m["cp"].items() if u != "uid-mps" or time.time() >= m.get("mps_at", 0)}
            out(json.dumps({"checksum": 1, "v2": {"preparedClaims": {u: {"checkpointState": s} for u, s in live.items()}}}))
        if rest[:2] == ["crictl", "ps"]:
            out("cid-gpus")
        if rest[:2] == ["crictl", "inspect"]:
            out("4242")
        if rest[:2] == ["kill", "-KILL"]:
            m["restarts"] += 1
            save(m)
            out()
        if rest[:1] == ["journalctl"]:
            out("\n".join(["kubelet started"] + ["kubelet dra manager: UnprepareResources claim %s" % u for u in m["cp"]]))
        if rest[:1] == ["grep"]:
            out("0")
        out()
    out("stub docker " + " ".join(A))


def helm(m):
    if "list" in A:
        out("\n".join(m["releases"]))
    if "uninstall" in A:
        m["releases"] = [r for r in m["releases"] if r not in A]
        save(m)
    if "upgrade" in A:
        rel = A[A.index("-i") + 1]
        if rel not in m["releases"]:
            m["releases"].append(rel)
        save(m)
    out()


def make(m):
    keep = ["CI", "USER", "KUBECONFIG", "DOCKER_NETWORK", "SKIP_CLEANUP", "TEST_CHART_LOCAL", "TEST_NVIDIA_DRIVER_ROOT",
            "DISABLE_COMPUTE_DOMAINS", "TEST_FILTER_TAGS", "NVMM_PATH"]
    record(" ENV " + " ".join("%s=%s" % (k, os.environ[k]) for k in keep if k in os.environ))
    if "print-IMAGE" in A:
        out("registry.k8s.io/dra-driver-nvidia/dra-driver-nvidia-gpu:v0.6.0-dev")
    if "tests-session-s4" in A:
        print("ok 1 GPUs: 1 pod(s), 1 full GPU in 2100ms")
        sys.exit(int(env("FAKE_S4_RC", "0")))
    out()


def nvidia_smi(m):
    if "--query-gpu=compute_mode" in A:
        out("Default")
    out("GPU 0: NVIDIA L4")


# ---------------------------------------------------------------- AWS
BUCKET = os.path.join(ST, "bucket")


def s3path(url):
    return os.path.join(BUCKET, url[len("s3://"):].split("/", 1)[1])


def instance_writes(prefix):
    """What the instance would leave in S3: the DONE marker and an evidence archive whose summary has the test's statuses."""
    root = os.path.join(ST, "instance", "dra-run")
    os.makedirs(os.path.join(root, "run"), exist_ok=True)
    rcs = dict(kv.split("=") for kv in env("FAKE_PHASE_RCS", "cluster=0 build=0 s4=0 s1=0 s2=0 s3=0").split())
    with open(os.path.join(root, "run", "summary.tsv"), "w") as f:
        f.write("phase\texit\tseconds\tbound\n")
        for p, rc in rcs.items():
            f.write("%s\t%s\t1\t1\n" % (p, rc))
    with open(os.path.join(root, "summary.txt"), "w") as f:
        f.write("all scenarios done\n")
    d = os.path.join(BUCKET, prefix)
    os.makedirs(d, exist_ok=True)
    with tarfile.open(os.path.join(d, "evidence.tgz"), "w:gz") as t:
        t.add(root, arcname="dra-run")
    open(os.path.join(d, "DONE"), "w").write("nonce\n")


def aws(m):
    sub = " ".join(A[:2])
    if os.environ.get("FAKE_AWS_FAIL"):
        sys.stderr.write("fake aws: no call is allowed in this case\n")
        sys.exit(1)
    if sub == "sts get-caller-identity":
        out("007635145730")
    if sub == "ec2 describe-images":
        out("Deep Learning Base OSS Nvidia Driver GPU AMI (Ubuntu 22.04) 20261113\tavailable")
    if sub == "ec2 describe-spot-price-history":
        t = arg("--instance-types")
        p = {"g6.xlarge": "0.4717", "g5.xlarge": "0.6115"}[t]
        out("ap-northeast-2a\t%s\nap-northeast-2c\t%s" % (p, p))
    if sub == "service-quotas get-service-quota":
        out("64.0")
    if sub == "lambda get-function":
        out("Active")
    if sub == "events describe-rule":
        out("ENABLED\trate(5 minutes)")
    if sub == "events list-targets-by-rule":
        out("arn:aws:lambda:ap-northeast-2:007635145730:function:gpu-platform-study-sweeper")
    if sub == "cloudwatch get-metric-statistics":
        out("[6.0]" if arg("--metric-name") == "Invocations" else "[0.0]")
    if sub == "configure export-credentials":
        out(json.dumps({"Version": 1, "Expiration": now_iso(36000)}))
    if sub == "ec2 describe-subnets":
        out("subnet-" + [f for f in A if f.startswith("Name=availability-zone")][0].split("=")[-1])
    if sub == "ec2 describe-instances":
        q = arg("--query", "")
        if "--filters" in A and "tag:purpose" in " ".join(A):
            out()
        if "LaunchTime" in q:
            out("%s\t%s" % (m["launch_time"], m["ami"]))
        if "State.Name" in q:
            out("terminated" if m["terminated"] and not env("FAKE_STUCK") else "running")
        out()
    if sub == "ec2 run-instances":
        t = arg("--instance-type")
        if env("FAKE_NO_CAPACITY") == t:
            sys.stderr.write("An error occurred (InsufficientInstanceCapacity) when calling the RunInstances operation\n")
            sys.exit(254)
        ud = arg("--user-data")[len("file://"):]
        shutil.copy(ud, os.path.join(ST, "user-data.sh"))
        prefix = re.search(r'^PREFIX="([^"]+)"', open(ud).read(), re.M).group(1)
        m["launch_time"] = now_iso(-int(env("FAKE_LAUNCH_AGO", "30")))
        m["ami"] = arg("--image-id")
        save(m)
        instance_writes(prefix)
        out("i-0fake")
    if sub == "ec2 create-tags" or sub == "iam put-role-policy":
        out()
    if sub == "ec2 terminate-instances":
        m["terminated"] = True
        save(m)
        out()
    if sub in ("s3api head-bucket", "iam get-instance-profile"):
        out()
    if sub == "s3api head-object":
        sys.exit(0 if os.path.exists(os.path.join(BUCKET, arg("--key"))) else 1)
    if A[:2] == ["s3", "cp"]:
        src, dst = [a for a in A[2:] if not a.startswith("--")][:2]
        if dst.startswith("s3://"):
            p = s3path(dst)
            os.makedirs(os.path.dirname(p), exist_ok=True)
            shutil.copy(src, p)
            out()
        p = s3path(src)
        if not os.path.exists(p):
            sys.exit(1)
        shutil.copy(p, dst)
        out()
    sys.stderr.write("fake aws: unmodelled call %s\n" % " ".join(A))
    sys.exit(1)


def main():
    m = load()
    if TOOL == "sleep":
        # Every wait in the scripts is bounded by the wall clock as well, so a short real sleep keeps those bounds honest.
        time.sleep(0.02)
        return
    if TOOL != "make":
        record()
    {"kubectl": kubectl, "docker": docker, "helm": helm, "make": make, "nvidia-smi": nvidia_smi, "aws": aws,
     "kind": lambda m: out("apiVersion: v1\nkind: Config" if "kubeconfig" in A else ""),
     "crictl": lambda m: out()}[TOOL](m)


if __name__ == "__main__":
    main()
