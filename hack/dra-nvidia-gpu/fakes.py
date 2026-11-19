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
            "terminated": False, "applied": 0, "s5": {}, "unprepared": [], "kubelet_unprep": []}


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
def selector_matches(labels, sel):
    """True when every equality term of a -l selector holds in labels, as the API server reads it."""
    return all(labels.get(k) == v for k, v in (t.split("=", 1) for t in sel.split(",") if t))


def daemonsets(m):
    """The kubelet-plugin DaemonSet of every installed release, shaped as the pinned chart renders it.

    The component label is on the selector and the pod template only, not on the DaemonSet's own metadata
    (deployments/helm/dra-driver-nvidia-gpu/templates/kubeletplugin.yaml at the pinned commit), so a fake that matched it
    on metadata would hide the defect attempt 4 hit.
    FAKE_DS_JSON replaces the model with a list rendered from the real chart.
    """
    if env("FAKE_DS_JSON"):
        return json.load(open(env("FAKE_DS_JSON")))["items"]
    if env("FAKE_NO_DS"):
        return []
    return [{"metadata": {"name": "dra-driver-nvidia-gpu-kubelet-plugin", "namespace": "dra-driver-nvidia-gpu",
                          "labels": {"app.kubernetes.io/name": "dra-driver-nvidia-gpu", "app.kubernetes.io/instance": r,
                                     "app.kubernetes.io/managed-by": "Helm"}},
             "spec": {"selector": {"matchLabels": {"dra-driver-nvidia-gpu-component": "kubelet-plugin"}}}}
            for r in m["releases"]]


def s5_leaked(m):
    """The S5 claim UIDs the checkpoint still holds although the API no longer has their claim."""
    return [u for u in m["cp"] if u.startswith("uid-s5-") and u not in m["claims"].values()]


def kubectl_s5(m, ns):
    """S5's namespaces: a template-generated claim, force deletion, and a delete-protection finalizer.

    A normal delete leaves both objects in the API, as attempt 5's S1 saw them while the plugin was down.
    A forced pod delete removes the pod at once, unless FAKE_S5_STAYS keeps it.
    A forced claim delete leaves the claim held by its finalizer until the finalizers are patched away.
    FAKE_S5_CLAIM_GC has the garbage collector remove the claim with its pod, before the claim's own delete is sent.
    FAKE_S5_CLAIM_STAYS keeps the claim whatever is done to it, as a finalizer something else re-adds would.
    A delete of an object the API does not have fails unless it carries --ignore-not-found, as kubectl's does.
    """
    st = m["s5"].get(ns)
    forced = "--force" in A and "--grace-period=0" in A
    if "wait" in A:
        if "pod/pod-b" in A and s5_leaked(m):
            sys.exit(1)
        out()
    if env("FAKE_GET_FAIL") and "get" in A and arg("-o") == "name":
        sys.stderr.write("Unable to connect to the server\n")
        sys.exit(1)
    if "delete" in A and st:
        ckey = ns + "/" + st["claim"]
        if "pod/pod" in A:
            if forced and not env("FAKE_S5_STAYS"):
                m["claims"].pop(ns + "/pod", None)
                m["kubelet_unprep"].append(st["pod_uid"])
                if env("FAKE_S5_CLAIM_GC"):
                    m["claims"].pop(ckey, None)
        if "resourceclaim/" + st["claim"] in A:
            if ckey not in m["claims"] and "--ignore-not-found" not in A:
                sys.stderr.write('Error from server (NotFound): resourceclaims "%s" not found\n' % st["claim"])
                sys.exit(1)
            st["deleting"] = True
        save(m)
        out()
    if "patch" in A and st and "resourceclaim/" + st["claim"] in A:
        if st["deleting"] and '{"metadata":{"finalizers":null}}' in A and not env("FAKE_S5_CLAIM_STAYS"):
            m["claims"].pop(ns + "/" + st["claim"], None)
        save(m)
        out()
    if "get" in A and "events" in A:
        if not (st and st.get("pod_b")):
            out()
        out("\n".join("Warning FailedPrepareDynamicResources pod/pod-b requested device gpu-0 is already allocated to "
                      "different claim %s" % u for u in s5_leaked(m)))
    if "get" in A and st:
        q = arg("-o", "")
        if "--ignore-not-found" in A:
            obj = [a for a in A if "/" in a][0]
            kind, name = obj.split("/", 1)
            key = ns + "/" + ("pod" if kind == "pod" else name)
            out(obj if key in m["claims"] else "")
        if "pod/pod" in A and "resourceClaimStatuses[" in q:
            out("" if env("FAKE_S5_NO_STATUS") else st["claim"])
        if "pod/pod" in A and q == "jsonpath={.metadata.uid}":
            if ns + "/pod" not in m["claims"]:
                sys.exit(1)
            out(st["pod_uid"])
        if "resourceclaim/" + st["claim"] in A and q == "jsonpath={.metadata.uid}":
            key = ns + "/" + st["claim"]
            if key not in m["claims"]:
                sys.exit(1)
            out(m["claims"][key])
        out("stub " + " ".join(A))
    out()


def kubectl(m):
    ns0 = arg("-n", "") or ""
    if ns0.startswith("s5-"):
        kubectl_s5(m, ns0)
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
        for ns in re.findall(r"kind: Pod\nmetadata:\n  namespace: (s5-r\d+)\n  name: pod-b\n", text):
            m["s5"][ns]["pod_b"] = True
        for ns in re.findall(r"kind: Pod\nmetadata:\n  namespace: (s5-r\d+)\n  name: pod\n", text):
            uid = "uid-" + ns
            claim = "pod-gpu-x7k2q"
            m["s5"][ns] = {"claim": claim, "pod_uid": "poduid-" + ns, "deleting": False}
            m["claims"][ns + "/" + claim] = uid
            m["claims"][ns + "/pod"] = "pod"
            if not env("FAKE_S5_NOT_PREPARED"):
                m["cp"][uid] = "PrepareCompleted"
        for name in re.findall(r"kind: ResourceClaim\nmetadata:\n  namespace: s3-shares\n  name: (mem-\d)", text):
            m["claims"]["s3-shares/" + name] = "uid-" + name
        save(m)
        out()
    if "wait" in A:
        if env("FAKE_S3_POD1_PENDING") and "pod/pod-1" in A:
            sys.exit(1)
        if env("FAKE_S3_POD0_PENDING") and "pod/pod-0" in A:
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
        # S5's entries leak only when the test asks, which is #1278's finding.
        if not m["down"] and not env("FAKE_S5_LEAK"):
            for uid in s5_leaked(m):
                del m["cp"][uid]
                m["unprepared"].append(uid)
        save(m)
        out()
    if "delete" in A:
        ns = arg("-n", "")
        # A namespace whose deletion does not finish inside its timeout, as one held by a finalizer would.
        if env("FAKE_NS_DELETE_FAIL") and has("ns", "gpu-test-mps") and "--ignore-not-found" not in A:
            sys.exit(1)
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
        reg = [] if env("FAKE_S5_UNREGISTERED") else [
            'I1118 nonblockinggrpcserver.go:150] "handling request" logger="registrar" requestID=2 '
            'method="/pluginregistration.Registration/NotifyRegistrationStatus" request="plugin_registered:true"']
        out("\n".join(["I1118 driver.go] plugin started"] + reg + ["I1118 driver.go] Unprepare: claim %s" % u for u in m["cp"]] +
                       ["I1118 driver.go:392] Unprepare called for: [ns/claim:%s]" % u for u in m["unprepared"]]))
    if "get" in A:
        ns = arg("-n", "")
        q = arg("-o", "")
        # An API server that cannot answer a presence query, which must not read as the object being gone.
        if env("FAKE_GET_FAIL") and ns.startswith("s1-") and "-o" in A and arg("-o") == "name":
            sys.stderr.write("Unable to connect to the server\n")
            sys.exit(1)
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
        if "ds" in A and ns == "dra-driver-nvidia-gpu":
            items = [d for d in daemonsets(m) if selector_matches(d["metadata"].get("labels", {}), arg("-l", ""))]
            if q.startswith("jsonpath"):
                if not items:
                    sys.stderr.write("error: array index out of bounds: index 0, length 0\n")
                    sys.exit(1)
                out(items[0]["metadata"]["name"])
            out(json.dumps({"apiVersion": "v1", "kind": "List", "items": items}))
        if "ds,pods" in A:
            out("NAMESPACE NAME LABELS\n" + "\n".join("dra-driver-nvidia-gpu daemonset.apps/%s %s" % (
                d["metadata"]["name"], d["metadata"].get("labels")) for d in daemonsets(m)))
        if "pods" in A and "app.kubernetes.io/instance!=" in (arg("-l", "") or ""):
            # A pod of an uninstalled release that does not terminate, as one stuck on a finalizer would not.
            out("pod/plugin-old" if env("FAKE_OLD_PODS_LINGER") else "")
        inst = re.search(r"app\.kubernetes\.io/instance=([^,]+)", arg("-l", "") or "")
        if "pods" in A and inst and inst.group(1) not in m["releases"]:
            out()
        if "resourceslices" in A and q == "name":
            out("resourceslice.resource.k8s.io/worker-gpu.nvidia.com-x")
        # A listing of the plugin pods that fails, which must not read as no plugin pod.
        if env("FAKE_PLUGIN_LIST_FAIL") and "pods" in A and arg("-l") == "dra-driver-nvidia-gpu-component=kubelet-plugin" \
                and arg("-o") == "name":
            sys.stderr.write("Unable to connect to the server\n")
            sys.exit(1)
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
            out("\n".join(["kubelet started"] + ["kubelet dra manager: UnprepareResources claim %s" % u for u in m["cp"]] +
                           ['E1118 pod_workers.go] "Error syncing pod" err="unprepare dynamic resources: DRA driver gpu.nvidia.com '
                            'is not registered" podUID="%s"' % u for u in m["kubelet_unprep"]]))
        if rest[:1] == ["grep"]:
            out("0")
        out()
    out("stub docker " + " ".join(A))


def helm(m):
    if "list" in A:
        if env("FAKE_HELM_LIST_FAIL"):
            sys.stderr.write("Error: Kubernetes cluster unreachable\n")
            sys.exit(1)
        out("\n".join(m["releases"]))
    if "status" in A:
        # A line on stderr, so a capture that drops stderr is caught.
        sys.stderr.write("WARNING: fake helm status note on stderr\n")
        out("NAME: %s\nSTATUS: deployed" % A[-1])
    if "get" in A and "manifest" in A:
        out("\n---\n".join("kind: DaemonSet\nmetadata:\n  name: %s" % d["metadata"]["name"] for d in daemonsets(m)))
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
    rcs = dict(kv.split("=") for kv in env("FAKE_PHASE_RCS", "cluster=0 build=0 s1=0 s5=0").split())
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
        out(env("FAKE_SWEEPER_STATE", "Active"))
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
