"""The session reaper: the cleanup that runs when the laptop that started a paid session cannot.

docs/superpowers/specs/2026-11-07-session-cloud-safety-design.md is the contract.
Every five minutes it reads the session leases under LEASE_PATH, one per cluster, written by
hack/lib/session-lease.sh before the session creates anything that bills.
A lease whose GPU deadline has passed has its GPU node groups held at zero until no instance is left (proposal P2).
A lease whose session deadline has passed has its session's billing resources deleted, a step per run, in dependency
order, and the lease removed once nothing is left (proposal P1).

It deletes only what the lease names and what carries the project tag: the cluster of the lease's name, that cluster's
node groups, the EFS file system named after it, and the NAT gateways and addresses of its VPC.
The VPC, subnets, route tables and security groups are left: they cost nothing, and the next session's terraform owns
them.
"""

import datetime
import json
import os

LEASE_PATH = os.environ.get("LEASE_PATH", "/gpu-platform/session-lease/")
PROJECT_KEY = "project"
PROJECT_VALUE = os.environ.get("PROJECT_TAG", "gpu-platform-control-plane")


class LeaseError(Exception):
    """A lease that cannot be read well enough to act on."""


def parse_time(value):
    """An aware datetime from an ISO 8601 string with a zone, or None for anything else."""
    if not isinstance(value, str):
        return None
    try:
        t = datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
        if t.tzinfo is None:
            return None
        return t.astimezone(datetime.timezone.utc)
    except (ValueError, OverflowError):
        return None


def parse_lease(name, text):
    """The lease as a dict, checked; LeaseError when it names no cluster or no readable session deadline.

    An unreadable session deadline is refused rather than read as passed: the reaper deletes a cluster, and a runner's bug
    must not be enough to do that; the run fails, Lambda's Errors metric counts it, and the watchdog and the nightly
    destroy are still there.
    """
    try:
        lease = json.loads(text)
    except ValueError as e:
        raise LeaseError(f"{name}: not JSON: {e}") from e
    if not isinstance(lease, dict):
        raise LeaseError(f"{name}: not an object")
    cluster = lease.get("cluster")
    if not isinstance(cluster, str) or not cluster or name.rsplit("/", 1)[-1] != cluster:
        raise LeaseError(f"{name}: names cluster {cluster!r}, which is not the parameter's own name")
    if parse_time(lease.get("deadline")) is None:
        raise LeaseError(f"{name}: session deadline {lease.get('deadline')!r} is not a time with a zone")
    if "gpu_deadline" in lease and parse_time(lease["gpu_deadline"]) is None:
        raise LeaseError(f"{name}: GPU deadline {lease['gpu_deadline']!r} is not a time with a zone")
    groups = lease.get("gpu_nodegroups", [])
    if not isinstance(groups, list) or not all(isinstance(g, str) and g for g in groups):
        raise LeaseError(f"{name}: gpu_nodegroups is not a list of names")
    return lease


def phase(lease, now):
    """'reap' once the session deadline has passed, 'gpu' once only the GPU deadline has, otherwise 'wait'."""
    if now >= parse_time(lease["deadline"]):
        return "reap"
    gpu = lease.get("gpu_deadline")
    if gpu is not None and now >= parse_time(gpu) and lease.get("gpu_nodegroups"):
        return "gpu"
    return "wait"


def owned(tags):
    """Whether a resource's tags carry the project tag; tags as a dict or as EC2's list of Key/Value."""
    if isinstance(tags, list):
        tags = {t.get("Key"): t.get("Value") for t in tags}
    return (tags or {}).get(PROJECT_KEY) == PROJECT_VALUE


def _code(err):
    return getattr(err, "response", {}).get("Error", {}).get("Code", "")


def hold_gpu_at_zero(eks, asg, cluster, groups, log):
    """P2: each named group at minSize 0, desiredSize 0, and with no instance left; returns the groups not yet there."""
    pending = []
    for name in groups:
        try:
            ng = eks.describe_nodegroup(clusterName=cluster, nodegroupName=name)["nodegroup"]
        except Exception as e:  # noqa: BLE001 -- the code decides, and anything else is a failure to report
            if _code(e) == "ResourceNotFoundException":
                continue
            raise
        if not owned(ng.get("tags")):
            log(f"{cluster}/{name}: no project tag, left alone")
            continue
        sc = ng.get("scalingConfig", {})
        if sc.get("desiredSize", 0) > 0 or sc.get("minSize", 0) > 0:
            try:
                eks.update_nodegroup_config(clusterName=cluster, nodegroupName=name, scalingConfig={
                    "minSize": 0, "maxSize": max(sc.get("maxSize", 1), 1), "desiredSize": 0})
                log(f"{cluster}/{name}: asked for desiredSize 0 (was {sc.get('desiredSize')})")
            except Exception as e:  # noqa: BLE001
                # An update already in progress is retried on the next run; anything else is a failure.
                if _code(e) != "ResourceInUseException":
                    raise
                log(f"{cluster}/{name}: an update is in progress, retried next run")
            pending.append(name)
            continue
        names = [g["name"] for g in ng.get("resources", {}).get("autoScalingGroups", [])]
        left = 0
        if names:
            for g in asg.describe_auto_scaling_groups(AutoScalingGroupNames=names).get("AutoScalingGroups", []):
                left += len(g.get("Instances", []))
        if left:
            log(f"{cluster}/{name}: desiredSize 0, {left} instance(s) still in its groups")
            pending.append(name)
    return pending


def vpc_of(lease, cluster_desc, ec2, log):
    """The session's VPC: the lease's record, the cluster's own, or the one project VPC named <cluster>-vpc.

    The last is the name infra/aws/cluster/vpc.tf gives it, a name the lease owns, never "the only project VPC left".
    More than one match is refused.
    """
    if lease.get("vpc_id"):
        return lease["vpc_id"]
    if cluster_desc:
        v = cluster_desc.get("resourcesVpcConfig", {}).get("vpcId")
        if v:
            return v
    vpcs = ec2.describe_vpcs(Filters=[{"Name": f"tag:{PROJECT_KEY}", "Values": [PROJECT_VALUE]},
                                      {"Name": "tag:Name", "Values": [lease["cluster"] + "-vpc"]}]).get("Vpcs", [])
    if len(vpcs) > 1:
        raise LeaseError(f"{lease['cluster']}: {len(vpcs)} project VPCs are named {lease['cluster']}-vpc; refusing to choose")
    if not vpcs:
        log(f"{lease['cluster']}: no VPC recorded or found; NAT gateways and addresses are not looked for")
        return None
    return vpcs[0]["VpcId"]


def reap(lease, eks, ec2, efs, log):
    """P1: one step of deleting the session's billing resources; returns what is still left, empty when done."""
    cluster = lease["cluster"]
    left = []
    desc = None
    try:
        desc = eks.describe_cluster(name=cluster)["cluster"]
    except Exception as e:  # noqa: BLE001
        if _code(e) != "ResourceNotFoundException":
            raise
    if desc is not None and not owned(desc.get("tags")):
        raise LeaseError(f"{cluster}: the cluster carries no project tag; refusing to delete anything of it")
    groups_gone = True
    if desc is not None:
        for name in eks.list_nodegroups(clusterName=cluster).get("nodegroups", []):
            groups_gone = False
            ng = eks.describe_nodegroup(clusterName=cluster, nodegroupName=name)["nodegroup"]
            if ng.get("status") != "DELETING":
                eks.delete_nodegroup(clusterName=cluster, nodegroupName=name)
                log(f"{cluster}/{name}: node group deletion asked")
            left.append(f"nodegroup/{name}")
        if groups_gone:
            if desc.get("status") != "DELETING":
                eks.delete_cluster(name=cluster)
                log(f"{cluster}: cluster deletion asked")
            left.append(f"cluster/{cluster}")
    # Nothing else goes while a node can still be using it: the NAT carries their traffic and the EFS their checkpoints.
    if not groups_gone:
        return left

    for fs in efs.describe_file_systems().get("FileSystems", []):
        tags = {t["Key"]: t["Value"] for t in fs.get("Tags", [])}
        if not owned(tags):
            continue
        if fs["FileSystemId"] != lease.get("efs_id") and tags.get("Name") != f"{cluster}-restart":
            continue
        mts = efs.describe_mount_targets(FileSystemId=fs["FileSystemId"]).get("MountTargets", [])
        for mt in mts:
            if mt.get("LifeCycleState") not in ("deleting", "deleted"):
                efs.delete_mount_target(MountTargetId=mt["MountTargetId"])
                log(f"{cluster}: EFS mount target {mt['MountTargetId']} deletion asked")
        if not mts and fs.get("LifeCycleState") not in ("deleting", "deleted"):
            efs.delete_file_system(FileSystemId=fs["FileSystemId"])
            log(f"{cluster}: EFS {fs['FileSystemId']} deletion asked")
        if fs.get("LifeCycleState") != "deleted":
            left.append(f"efs/{fs['FileSystemId']}")

    vpc = vpc_of(lease, desc, ec2, log)
    if vpc is None:
        return left
    allocations = set()
    nats = ec2.describe_nat_gateways(Filters=[{"Name": "vpc-id", "Values": [vpc]},
                                              {"Name": f"tag:{PROJECT_KEY}", "Values": [PROJECT_VALUE]}]).get("NatGateways", [])
    for nat in nats:
        state = nat.get("State")
        # Only a deleted gateway's addresses: an address is never released from under a gateway still using it, whatever
        # its association reads at that moment.
        if state == "deleted":
            for a in nat.get("NatGatewayAddresses", []):
                if a.get("AllocationId"):
                    allocations.add(a["AllocationId"])
        if state in ("pending", "available", "failed"):
            ec2.delete_nat_gateway(NatGatewayId=nat["NatGatewayId"])
            log(f"{cluster}: NAT gateway {nat['NatGatewayId']} deletion asked")
        if state != "deleted":
            left.append(f"nat/{nat['NatGatewayId']}")
    # One at a time: a deleted NAT gateway goes on listing its address for about an hour after the address is released,
    # and asking for a released allocation fails the whole call.
    for alloc in sorted(allocations):
        try:
            addrs = ec2.describe_addresses(AllocationIds=[alloc]).get("Addresses", [])
        except Exception as e:  # noqa: BLE001
            if _code(e) != "InvalidAllocationID.NotFound":
                raise
            continue
        for addr in addrs:
            if not owned(addr.get("Tags")):
                continue
            if addr.get("AssociationId"):
                left.append(f"eip/{addr['AllocationId']} (still associated)")
                continue
            ec2.release_address(AllocationId=addr["AllocationId"])
            log(f"{cluster}: address {addr['AllocationId']} released")
    return left


def run(ssm, eks, ec2, efs, asg, now, log):
    """One pass over every lease; returns a list of failures, each a string, after trying every lease."""
    failures = []
    params = []
    for page in ssm.get_paginator("get_parameters_by_path").paginate(Path=LEASE_PATH, Recursive=False):
        params.extend(page.get("Parameters", []))
    for p in params:
        name = p["Name"]
        try:
            lease = parse_lease(name, p["Value"])
            ph = phase(lease, now)
            if ph == "gpu":
                pending = hold_gpu_at_zero(eks, asg, lease["cluster"], lease["gpu_nodegroups"], log)
                log(f"{name}: GPU deadline passed; {'held at zero' if not pending else 'not yet: ' + ', '.join(pending)}")
            elif ph == "reap":
                left = reap(lease, eks, ec2, efs, log)
                if left:
                    log(f"{name}: session deadline passed; still left: {', '.join(left)}")
                else:
                    ssm.delete_parameter(Name=name)
                    log(f"{name}: REAPED, nothing billing is left; lease removed")
        except Exception as e:  # noqa: BLE001 -- one lease's failure must not stop the others
            failures.append(f"{name}: {type(e).__name__}: {e}")
            log(f"FAILED {name}: {type(e).__name__}: {e}")
    return failures


def handler(event, context):  # pragma: no cover -- the AWS wiring; run() is what the tests drive
    import boto3

    region = os.environ.get("AWS_REGION", "ap-northeast-2")
    clients = {s: boto3.client(s, region_name=region) for s in ("ssm", "eks", "ec2", "efs", "autoscaling")}
    failures = run(clients["ssm"], clients["eks"], clients["ec2"], clients["efs"], clients["autoscaling"],
                   datetime.datetime.now(datetime.timezone.utc), print)
    if failures:
        # Raised, so Lambda's Errors metric counts the run and the next session's gate can see it.
        raise RuntimeError("; ".join(failures))
    return {"ok": True}
