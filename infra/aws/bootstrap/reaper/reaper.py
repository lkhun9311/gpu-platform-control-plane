"""The session reaper: the cleanup that runs when the laptop that started a paid session cannot.

docs/superpowers/specs/2026-11-07-session-cloud-safety-design.md is the contract.
Every five minutes it reads the session leases under LEASE_PATH, one per cluster, written by
hack/lib/session-lease.sh before the session creates anything that bills.
A lease whose GPU deadline has passed has its GPU node groups held at zero until no instance is left (proposal P2).
A lease whose session deadline has passed has its session's billing resources deleted, a step per run, in dependency
order, and the lease removed once nothing is left (proposal P1).

It deletes only what the lease names and what carries the project tag: the cluster of the lease's name, that cluster's
node groups, the session's EFS file system, the NAT gateways of its VPC, the addresses the VPC module named after it, the
cluster's log group, and the encryption key aliased to the cluster.
The VPC, subnets, route tables, security groups and IAM roles are left: they cost nothing, and the next session's
terraform owns them.
"""

import datetime
import hashlib
import json
import os

LEASE_PATH = os.environ.get("LEASE_PATH", "/gpu-platform/session-lease/")
PROJECT_KEY = "project"
PROJECT_VALUE = os.environ.get("PROJECT_TAG", "gpu-platform-control-plane")
HEARTBEAT = os.environ.get("HEARTBEAT", "/gpu-platform/session-reaper/last-ok")
# A lease is not started with less than this left in the invocation; each client call is bounded well below it.
MIN_SECONDS_PER_LEASE = 30


class LeaseError(Exception):
    """A lease that cannot be read well enough to act on."""


class Handover(Exception):
    """The lease changed since this run read it; the run stops acting on it, which is not a failure."""


class Partial(Exception):
    """Some steps of a lease failed after the others were asked for; carries the failures."""

# How long instances may stay in a GPU group held at zero before the reaper terminates them itself: a group whose
# instances are protected from scale-in keeps them billing at desiredSize 0 (round 3 of the adversarial review).
GPU_STRAGGLER_GRACE = datetime.timedelta(minutes=int(os.environ.get("GPU_STRAGGLER_GRACE_MINUTES", "15")))


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
    if not isinstance(cluster, str) or not cluster:
        raise LeaseError(f"{name}: names no cluster")
    # A lease is named for its session (hack/lib/session-lease.sh), so a removal of one can never remove another's.
    if lease.get("session") != name.rsplit("/", 1)[-1]:
        raise LeaseError(f"{name}: names session {lease.get('session')!r}, which is not the parameter's own name")
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


def still_gpu_phase(ssm, lease_name, group, now):
    """Whether the lease, read again now, still puts GROUP past its GPU deadline.

    The run read every lease at its start; a session that renewed the GPU deadline since, to buy the group again, must
    not have it scaled down on the run's old copy (r1 of the adversarial review). The session waits out a run's timeout
    after renewing an expired deadline, which closes the window this read narrows.
    """
    try:
        cur = parse_lease(lease_name, ssm.get_parameter(Name=lease_name)["Parameter"]["Value"])
    except Exception as e:  # noqa: BLE001
        if _code(e) == "ParameterNotFound":
            return False
        raise
    return phase(cur, now) == "gpu" and group in cur.get("gpu_nodegroups", [])


def same_lease(ssm, lease_name, lease):
    """Whether the lease stored now is the one this run read: same session, same session deadline.

    A session's verified teardown removes its lease, and a new session may then take the account's lock while a run that
    read the old lease is still going; that run must not go on deleting (round 2 and 3 of the adversarial review). Leases
    are named per session, so the removal itself can only ever remove the lease the run read (round 4).
    """
    try:
        cur = parse_lease(lease_name, ssm.get_parameter(Name=lease_name)["Parameter"]["Value"])
    except Exception as e:  # noqa: BLE001
        if _code(e) == "ParameterNotFound":
            return False
        raise
    return cur.get("session") == lease.get("session") and cur["deadline"] == lease["deadline"]


def hold_gpu_at_zero(eks, asg, ssm, lease_name, cluster, groups, gpu_deadline, now, log):
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
            if not still_gpu_phase(ssm, lease_name, name, now):
                log(f"{cluster}/{name}: the lease was renewed since this run read it; left alone")
                continue
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
        stragglers = []
        if names:
            for g in asg.describe_auto_scaling_groups(AutoScalingGroupNames=names).get("AutoScalingGroups", []):
                stragglers += [i["InstanceId"] for i in g.get("Instances", [])]
        if not stragglers:
            continue
        pending.append(name)
        if now < gpu_deadline + GPU_STRAGGLER_GRACE:
            log(f"{cluster}/{name}: desiredSize 0, {len(stragglers)} instance(s) still in its groups")
            continue
        if not still_gpu_phase(ssm, lease_name, name, now):
            log(f"{cluster}/{name}: the lease was renewed since this run read it; left alone")
            continue
        # Still there a grace after the deadline with desiredSize 0: scale-in protection, or a stuck termination. Ended
        # here, without decrementing the group, which is already at zero.
        for iid in stragglers:
            asg.terminate_instance_in_auto_scaling_group(InstanceId=iid, ShouldDecrementDesiredCapacity=False)
            log(f"{cluster}/{name}: instance {iid} still running {GPU_STRAGGLER_GRACE} after the GPU deadline; terminated")
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
        log(f"{lease['cluster']}: no VPC recorded or found; NAT gateways are not looked for")
        return None
    return vpcs[0]["VpcId"]


def session_file_systems(lease, efs):
    """The session's EFS: exactly the recorded id when there is one, else the one project file system named
    <cluster>-restart, which infra/aws/cluster/efs.tf gives it; two of that name is a refusal."""
    cluster = lease["cluster"]
    if lease.get("efs_id"):
        try:
            found = efs.describe_file_systems(FileSystemId=lease["efs_id"]).get("FileSystems", [])
        except Exception as e:  # noqa: BLE001
            if _code(e) == "FileSystemNotFound":
                return []
            raise
        for fs in found:
            if not owned(fs.get("Tags")):
                raise LeaseError(f"{cluster}: the recorded file system {lease['efs_id']} carries no project tag")
        return found
    matches = []
    for page in efs.get_paginator("describe_file_systems").paginate():
        for fs in page.get("FileSystems", []):
            tags = {t["Key"]: t["Value"] for t in fs.get("Tags", [])}
            if owned(tags) and tags.get("Name") == f"{cluster}-restart":
                matches.append(fs)
    if len(matches) > 1:
        raise LeaseError(f"{cluster}: {len(matches)} project file systems are named {cluster}-restart and none is recorded")
    return matches


def reap(lease, eks, ec2, efs, logs, kms, log, guard=lambda: None):
    """P1: one step of deleting the session's billing resources; returns what is still left, empty when done.

    GUARD runs before every deletion and raises Handover when the lease is no longer the one this run read, so a run that
    outlived its session's teardown cannot delete what a new session of the same name has begun to build.
    A deletion that fails does not stop the others; the failures are raised together as Partial once all were asked.
    """
    cluster = lease["cluster"]
    left = []
    failed = []
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
            left.append(f"nodegroup/{name}")
            try:
                ng = eks.describe_nodegroup(clusterName=cluster, nodegroupName=name)["nodegroup"]
                if ng.get("status") != "DELETING":
                    guard()
                    eks.delete_nodegroup(clusterName=cluster, nodegroupName=name)
                    log(f"{cluster}/{name}: node group deletion asked")
            except Handover:
                raise
            except Exception as e:  # noqa: BLE001 -- one refused group must not keep the others billing
                failed.append(f"nodegroup/{name}: {type(e).__name__}: {e}")
        if groups_gone:
            if desc.get("status") != "DELETING":
                guard()
                eks.delete_cluster(name=cluster)
                log(f"{cluster}: cluster deletion asked")
            left.append(f"cluster/{cluster}")
    # Nothing else goes while a node can still be using it: the NAT carries their traffic and the EFS their checkpoints.
    if not groups_gone:
        if failed:
            raise Partial(failed)
        return left

    # A failed EFS step (its mount targets need an ENI deletion the reaper may be refused) must not keep the NAT and the
    # addresses billing: it is raised after the rest has been asked for.
    try:
        left.extend(reap_efs(lease, efs, log, guard))
    except Handover:
        raise
    except Exception as e:  # noqa: BLE001
        left.append("efs (failed)")
        failed.append(f"efs: {type(e).__name__}: {e}")
    try:
        reap_network(lease, desc, ec2, left, log, guard)
    except Handover:
        raise
    except Exception as e:  # noqa: BLE001
        left.append("network (failed)")
        failed.append(f"network: {type(e).__name__}: {e}")
    if desc is None:
        try:
            reap_cluster_leftovers(cluster, logs, kms, log, guard)
        except Handover:
            raise
        except Exception as e:  # noqa: BLE001
            failed.append(f"log group or key: {type(e).__name__}: {e}")
    if failed:
        raise Partial(failed)
    return left


def reap_efs(lease, efs, log, guard):
    """The session's EFS: mount targets, then the file system; returns what is left."""
    cluster = lease["cluster"]
    left = []
    for fs in session_file_systems(lease, efs):
        mts = efs.describe_mount_targets(FileSystemId=fs["FileSystemId"]).get("MountTargets", [])
        for mt in mts:
            if mt.get("LifeCycleState") not in ("deleting", "deleted"):
                guard()
                efs.delete_mount_target(MountTargetId=mt["MountTargetId"])
                log(f"{cluster}: EFS mount target {mt['MountTargetId']} deletion asked")
        if not mts and fs.get("LifeCycleState") not in ("deleting", "deleted"):
            guard()
            efs.delete_file_system(FileSystemId=fs["FileSystemId"])
            log(f"{cluster}: EFS {fs['FileSystemId']} deletion asked")
        if fs.get("LifeCycleState") != "deleted":
            left.append(f"efs/{fs['FileSystemId']}")
    return left


def reap_network(lease, desc, ec2, left, log, guard):
    """The NAT gateways of the session's VPC, then its addresses; appends what is left to LEFT and returns whether a
    gateway is still being deleted."""
    cluster = lease["cluster"]
    nats_busy = False
    vpc = vpc_of(lease, desc, ec2, log)
    if vpc is not None:
        nats = ec2.describe_nat_gateways(Filters=[{"Name": "vpc-id", "Values": [vpc]},
                                                  {"Name": f"tag:{PROJECT_KEY}", "Values": [PROJECT_VALUE]}]).get("NatGateways", [])
        for nat in nats:
            state = nat.get("State")
            if state in ("pending", "available", "failed"):
                guard()
                ec2.delete_nat_gateway(NatGatewayId=nat["NatGatewayId"])
                log(f"{cluster}: NAT gateway {nat['NatGatewayId']} deletion asked")
            if state != "deleted":
                nats_busy = True
                left.append(f"nat/{nat['NatGatewayId']}")

    # The addresses by their own tags, named <cluster>-vpc-<zone> by the VPC module, not through the gateways: an address
    # allocated by an apply that died before its gateway, or one whose deleted gateway has aged out of the API, is found
    # the same way. None is released while a gateway of the session is still being deleted.
    # Exact names, one per zone of the Region, never a prefix: `gpu-platform-vpc-*` would also match the addresses of a
    # cluster named `gpu-platform-vpc-test` (round 2 of the adversarial review).
    zones = [z["ZoneName"] for z in ec2.describe_availability_zones(AllAvailabilityZones=False).get("AvailabilityZones", [])]
    if not zones:
        raise LeaseError(f"{cluster}: the Region listed no availability zones; addresses cannot be named")
    addrs = ec2.describe_addresses(Filters=[{"Name": f"tag:{PROJECT_KEY}", "Values": [PROJECT_VALUE]},
                                            {"Name": "tag:Name", "Values": [f"{cluster}-vpc-{z}" for z in zones]}]).get("Addresses", [])
    for addr in addrs:
        if addr.get("AssociationId") or nats_busy:
            left.append(f"eip/{addr['AllocationId']} (waiting for its gateway)")
            continue
        guard()
        ec2.release_address(AllocationId=addr["AllocationId"])
        log(f"{cluster}: address {addr['AllocationId']} released")
        left.append(f"eip/{addr['AllocationId']} (released, confirmed next run)")
    return nats_busy


def reap_cluster_leftovers(cluster, logs, kms, log, guard):
    """The cluster's log group and encryption key, only once the cluster is gone: it writes to the one and decrypts with
    the other while it is deleted."""
    group = f"/aws/eks/{cluster}/cluster"
    for lg in logs.describe_log_groups(logGroupNamePrefix=group).get("logGroups", []):
        if lg.get("logGroupName") != group:
            continue
        arn = lg["arn"][:-2] if lg["arn"].endswith(":*") else lg["arn"]
        if not owned(logs.list_tags_for_resource(resourceArn=arn).get("tags", {})):
            continue
        guard()
        logs.delete_log_group(logGroupName=group)
        log(f"{cluster}: log group {group} deleted")
    # The key the EKS module makes for this cluster: by its alias, or, when the alias is gone (an apply that died before
    # it, or a destroy that removed it first), by the module's exact description among the account's customer keys.
    # Only with the project tag; the state bucket's key has another description, and the role denies it by ARN as well.
    for key_id in cluster_keys(kms, cluster, log):
        meta = kms.describe_key(KeyId=key_id)["KeyMetadata"]
        if meta.get("KeyState") in ("PendingDeletion", "PendingReplicaDeletion"):
            continue
        tags = {t["TagKey"]: t["TagValue"] for t in kms.list_resource_tags(KeyId=key_id).get("Tags", [])}
        if not owned(tags):
            log(f"{cluster}: key {key_id} carries no project tag; left alone")
            continue
        guard()
        kms.schedule_key_deletion(KeyId=key_id, PendingWindowInDays=7)
        log(f"{cluster}: key {key_id} scheduled for deletion in 7 days")


def cluster_keys(kms, cluster, log):
    """The ids of the customer keys made for this cluster: the one aliased alias/eks/<cluster>, or, only when the alias
    is gone, any whose description is exactly the EKS module's "<cluster> cluster encryption key".

    A key whose description cannot be read (another application's key policy can refuse it) is skipped with a line, not
    allowed to stop the search (round 3 of the adversarial review).
    """
    try:
        return [kms.describe_key(KeyId=f"alias/eks/{cluster}")["KeyMetadata"]["KeyId"]]
    except Exception as e:  # noqa: BLE001
        if _code(e) != "NotFoundException":
            raise
    want = f"{cluster} cluster encryption key"
    found = []
    for page in kms.get_paginator("list_keys").paginate():
        for k in page.get("Keys", []):
            try:
                meta = kms.describe_key(KeyId=k["KeyId"])["KeyMetadata"]
            except Exception as e:  # noqa: BLE001
                # Refused by the key's own policy: the EKS module's key gives the account its default policy, so a key
                # this account cannot describe is not one of its. Anything else may be the session's key and fails the
                # step, so the lease stays and the next run looks again (round 4 of the adversarial review).
                if _code(e) not in ("AccessDeniedException", "KMSInvalidStateException"):
                    raise
                log(f"{cluster}: key {k['KeyId']} could not be described ({_code(e)}); not this session's")
                continue
            if meta.get("KeyManager") == "CUSTOMER" and meta.get("Description") == want:
                found.append(k["KeyId"])
    return found


def run(ssm, eks, ec2, efs, asg, logs, kms, now, log, time_left=lambda: 1e9):
    """One pass over every lease; returns a list of failures, each a string, after trying every lease.

    A pass with no failure writes HEARTBEAT, which a session reads before it arms a lease: a reaper that is Active and
    has never completed a pass (a role that cannot read the leases, say) must not be trusted to clean up.
    """
    failures = []
    params = []
    for page in ssm.get_paginator("get_parameters_by_path").paginate(Path=LEASE_PATH.rstrip("/"), Recursive=False):
        params.extend(page.get("Parameters", []))
    # The leases in a different order each run, so one that always runs out the budget cannot starve the ones after it.
    params.sort(key=lambda p: hashlib.sha256((p["Name"] + now.strftime("%Y%m%d%H%M")).encode()).hexdigest())
    for p in params:
        name = p["Name"]
        if time_left() < MIN_SECONDS_PER_LEASE:
            failures.append(f"{name}: not reached, {time_left():.0f} s left in the invocation")
            continue
        try:
            lease = parse_lease(name, p["Value"])
            ph = phase(lease, now)
            if ph == "gpu":
                pending = hold_gpu_at_zero(eks, asg, ssm, name, lease["cluster"], lease["gpu_nodegroups"],
                                           parse_time(lease["gpu_deadline"]), now, log)
                log(f"{name}: GPU deadline passed; {'held at zero' if not pending else 'not yet: ' + ', '.join(pending)}")
            elif ph == "reap":
                if not same_lease(ssm, name, lease):
                    log(f"{name}: replaced or removed since this run read it; left to the next run")
                    continue

                def guard(name=name, lease=lease):
                    if not same_lease(ssm, name, lease):
                        raise Handover(name)
                try:
                    left = reap(lease, eks, ec2, efs, logs, kms, log, guard)
                except Handover:
                    log(f"{name}: replaced or removed during this run; stopped acting on it")
                    continue
                except Partial as e:
                    raise LeaseError("; ".join(e.args[0])) from e
                if left:
                    log(f"{name}: session deadline passed; still left: {', '.join(left)}")
                elif same_lease(ssm, name, lease):
                    ssm.delete_parameter(Name=name)
                    log(f"{name}: REAPED, nothing billing is left; lease removed")
                else:
                    log(f"{name}: nothing left, but the lease was replaced meanwhile; the new one is kept")
        except Exception as e:  # noqa: BLE001 -- one lease's failure must not stop the others
            failures.append(f"{name}: {type(e).__name__}: {e}")
            log(f"FAILED {name}: {type(e).__name__}: {e}")
    if not failures:
        ssm.put_parameter(Name=HEARTBEAT, Value=now.strftime("%Y-%m-%dT%H:%M:%SZ"), Type="String", Overwrite=True)
    return failures


def handler(event, context):  # pragma: no cover -- the AWS wiring; run() is what the tests drive
    import boto3

    from botocore.config import Config

    region = os.environ.get("AWS_REGION", "ap-northeast-2")
    # Bounded calls, so one stalled endpoint costs seconds of the invocation rather than its whole timeout.
    cfg = Config(connect_timeout=5, read_timeout=15, retries={"max_attempts": 2, "mode": "standard"})
    c = {s: boto3.client(s, region_name=region, config=cfg) for s in ("ssm", "eks", "ec2", "efs", "autoscaling", "logs", "kms")}
    failures = run(c["ssm"], c["eks"], c["ec2"], c["efs"], c["autoscaling"], c["logs"], c["kms"],
                   datetime.datetime.now(datetime.timezone.utc), print,
                   lambda: context.get_remaining_time_in_millis() / 1000.0)
    if failures:
        # Raised, so Lambda's Errors metric counts the run and the next session's gate can see it.
        raise RuntimeError("; ".join(failures))
    return {"ok": True}
