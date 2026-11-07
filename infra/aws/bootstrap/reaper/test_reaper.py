"""Tests the session reaper's decisions without AWS.

    python3 -m unittest infra/aws/bootstrap/reaper/test_reaper.py

The clients are fakes holding a small account: they answer the calls the reaper makes and record the mutating ones.
"""

import datetime
import json
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import reaper  # noqa: E402

NOW = datetime.datetime(2026, 11, 7, 12, 0, tzinfo=datetime.timezone.utc)
PAST = "2026-11-07T11:00:00Z"
FUTURE = "2026-11-07T13:00:00Z"
TAGS = {"project": "gpu-platform-control-plane"}


class AWSError(Exception):
    def __init__(self, code):
        super().__init__(code)
        self.response = {"Error": {"Code": code}}


class Account:
    """The state the fakes share, and every mutating call made."""

    def __init__(self):
        self.leases = {}
        self.clusters = {}  # name -> {status, tags, vpc, nodegroups: {name: {...}}}
        self.efs = {}  # id -> {Name, tags, state, mounts: [ids]}
        self.nats = []  # dicts as EC2 returns them
        self.addresses = {}  # allocation -> {tags, associated}
        self.vpcs = []
        self.asg_instances = {}  # asg name -> count
        self.calls = []


class SSM:
    def __init__(self, a):
        self.a = a

    def get_paginator(self, _):
        a = self.a

        class P:
            def paginate(self, **kw):
                assert kw["Path"] == reaper.LEASE_PATH
                return [{"Parameters": [{"Name": n, "Value": v} for n, v in sorted(a.leases.items())]}]
        return P()

    def delete_parameter(self, Name):
        self.a.calls.append(("delete_parameter", Name))
        del self.a.leases[Name]


class EKS:
    def __init__(self, a):
        self.a = a

    def _cluster(self, name):
        if name not in self.a.clusters:
            raise AWSError("ResourceNotFoundException")
        return self.a.clusters[name]

    def describe_cluster(self, name):
        c = self._cluster(name)
        return {"cluster": {"name": name, "status": c["status"], "tags": c["tags"],
                            "resourcesVpcConfig": {"vpcId": c.get("vpc")}}}

    def list_nodegroups(self, clusterName):
        return {"nodegroups": sorted(self._cluster(clusterName)["nodegroups"])}

    def describe_nodegroup(self, clusterName, nodegroupName):
        ngs = self._cluster(clusterName)["nodegroups"]
        if nodegroupName not in ngs:
            raise AWSError("ResourceNotFoundException")
        return {"nodegroup": ngs[nodegroupName]}

    def update_nodegroup_config(self, clusterName, nodegroupName, scalingConfig):
        ng = self._cluster(clusterName)["nodegroups"][nodegroupName]
        if ng.get("update_in_progress"):
            raise AWSError("ResourceInUseException")
        self.a.calls.append(("update_nodegroup_config", nodegroupName, scalingConfig["desiredSize"], scalingConfig["minSize"]))
        ng["scalingConfig"] = dict(scalingConfig)

    def delete_nodegroup(self, clusterName, nodegroupName):
        self.a.calls.append(("delete_nodegroup", nodegroupName))
        self._cluster(clusterName)["nodegroups"][nodegroupName]["status"] = "DELETING"

    def delete_cluster(self, name):
        self.a.calls.append(("delete_cluster", name))
        self._cluster(name)["status"] = "DELETING"


class ASG:
    def __init__(self, a):
        self.a = a

    def describe_auto_scaling_groups(self, AutoScalingGroupNames):
        return {"AutoScalingGroups": [{"AutoScalingGroupName": n, "Instances": [{}] * self.a.asg_instances.get(n, 0)}
                                      for n in AutoScalingGroupNames]}


class EFS:
    def __init__(self, a):
        self.a = a

    def describe_file_systems(self):
        return {"FileSystems": [{"FileSystemId": i, "LifeCycleState": f["state"],
                                 "Tags": [{"Key": k, "Value": v} for k, v in {**f["tags"], "Name": f["Name"]}.items()]}
                                for i, f in self.a.efs.items()]}

    def describe_mount_targets(self, FileSystemId):
        return {"MountTargets": [{"MountTargetId": m, "LifeCycleState": "available"} for m in self.a.efs[FileSystemId]["mounts"]]}

    def delete_mount_target(self, MountTargetId):
        self.a.calls.append(("delete_mount_target", MountTargetId))

    def delete_file_system(self, FileSystemId):
        self.a.calls.append(("delete_file_system", FileSystemId))


class EC2:
    def __init__(self, a):
        self.a = a

    def describe_vpcs(self, Filters):
        name = [f["Values"][0] for f in Filters if f["Name"] == "tag:Name"][0]
        return {"Vpcs": [v for v in self.a.vpcs if v["Name"] == name and v["project"]]}

    def describe_nat_gateways(self, Filters):
        vpc = [f["Values"][0] for f in Filters if f["Name"] == "vpc-id"][0]
        assert any(f["Name"] == "tag:project" for f in Filters), "NAT gateways listed without the project filter"
        return {"NatGateways": [n for n in self.a.nats if n["VpcId"] == vpc]}

    def delete_nat_gateway(self, NatGatewayId):
        self.a.calls.append(("delete_nat_gateway", NatGatewayId))

    def describe_addresses(self, AllocationIds):
        (alloc,) = AllocationIds
        if alloc not in self.a.addresses:
            raise AWSError("InvalidAllocationID.NotFound")
        a = self.a.addresses[alloc]
        out = {"AllocationId": alloc, "Tags": [{"Key": k, "Value": v} for k, v in a["tags"].items()]}
        if a.get("associated"):
            out["AssociationId"] = "eipassoc-1"
        return {"Addresses": [out]}

    def release_address(self, AllocationId):
        self.a.calls.append(("release_address", AllocationId))


def lease(a, cluster="gpu-platform", **fields):
    body = {"cluster": cluster, "deadline": FUTURE, **fields}
    a.leases[reaper.LEASE_PATH + cluster] = json.dumps(body)


def run(a):
    logs = []
    failures = reaper.run(SSM(a), EKS(a), EC2(a), EFS(a), ASG(a), NOW, logs.append)
    return failures, logs


def nodegroup(desired, minimum=0, status="ACTIVE", tags=TAGS, asg="asg-gpu"):
    return {"status": status, "tags": dict(tags), "scalingConfig": {"minSize": minimum, "maxSize": 3, "desiredSize": desired},
            "resources": {"autoScalingGroups": [{"name": asg}]}}


def mutations(a):
    return [c for c in a.calls]


class LeaseTest(unittest.TestCase):
    # Mutation that turns it red: read an unreadable session deadline as passed.
    def test_an_unreadable_session_deadline_is_a_failure_not_a_deletion(self):
        a = Account()
        a.clusters["gpu-platform"] = {"status": "ACTIVE", "tags": TAGS, "nodegroups": {}}
        lease(a, deadline="tomorrow")
        failures, _ = run(a)
        self.assertEqual(len(failures), 1)
        self.assertEqual(a.calls, [])

    # A lease stored under another cluster's name could make the reaper delete a cluster nobody leased.
    def test_a_lease_naming_another_cluster_than_its_own_is_refused(self):
        a = Account()
        a.clusters["other"] = {"status": "ACTIVE", "tags": TAGS, "nodegroups": {}}
        a.leases[reaper.LEASE_PATH + "gpu-platform"] = json.dumps({"cluster": "other", "deadline": PAST})
        failures, _ = run(a)
        self.assertEqual(len(failures), 1)
        self.assertEqual(a.calls, [])

    def test_a_zoneless_time_is_not_a_time(self):
        self.assertIsNone(reaper.parse_time("2026-11-07T11:00:00"))
        self.assertIsNotNone(reaper.parse_time("2026-11-07T20:00:00+09:00"))

    # Mutation that turns it red: compare with > instead of >=, or act on a future deadline.
    def test_nothing_happens_before_either_deadline(self):
        a = Account()
        a.clusters["gpu-platform"] = {"status": "ACTIVE", "tags": TAGS, "nodegroups": {"gpu": nodegroup(3)}}
        lease(a, gpu_deadline=FUTURE, gpu_nodegroups=["gpu"])
        failures, _ = run(a)
        self.assertEqual((failures, a.calls), ([], []))


class GPUPhaseTest(unittest.TestCase):
    def account(self, desired, instances, minimum=0):
        a = Account()
        a.clusters["gpu-platform"] = {"status": "ACTIVE", "tags": TAGS,
                                      "nodegroups": {"gpu": nodegroup(desired, minimum), "cpu": nodegroup(2, 2, asg="asg-cpu")}}
        a.asg_instances = {"asg-gpu": instances, "asg-cpu": 2}
        lease(a, gpu_deadline=PAST, gpu_nodegroups=["gpu"])
        return a

    # Mutation that turns it red: skip the update, or touch the CPU group the lease does not name.
    def test_a_passed_gpu_deadline_scales_only_the_named_group_to_zero(self):
        a = self.account(desired=3, instances=3)
        failures, _ = run(a)
        self.assertEqual(failures, [])
        self.assertEqual(a.calls, [("update_nodegroup_config", "gpu", 0, 0)])

    # A minSize above zero would let the group come back; it is scaled even with desired already 0.
    def test_a_min_size_above_zero_is_also_scaled(self):
        a = self.account(desired=0, instances=0, minimum=1)
        run(a)
        self.assertEqual(a.calls, [("update_nodegroup_config", "gpu", 0, 0)])

    # Accepted is not done: desired 0 with an instance still in the group is still pending, and asked again next run.
    # Mutation that turns it red: treat desiredSize 0 as done without reading the instances.
    def test_desired_zero_with_instances_left_is_pending(self):
        a = self.account(desired=0, instances=1)
        failures, logs = run(a)
        self.assertEqual((failures, a.calls), ([], []))
        self.assertTrue(any("not yet: gpu" in line for line in logs), logs)

    # An update already running is retried next run, not a failure.
    def test_an_update_in_progress_is_retried_not_failed(self):
        a = self.account(desired=2, instances=2)
        a.clusters["gpu-platform"]["nodegroups"]["gpu"]["update_in_progress"] = True
        failures, logs = run(a)
        self.assertEqual((failures, a.calls), ([], []))

    # Mutation that turns it red: drop the project-tag check.
    def test_a_group_without_the_project_tag_is_left_alone(self):
        a = self.account(desired=2, instances=2)
        a.clusters["gpu-platform"]["nodegroups"]["gpu"]["tags"] = {}
        run(a)
        self.assertEqual(a.calls, [])


class ReapTest(unittest.TestCase):
    def account(self):
        a = Account()
        a.clusters["gpu-platform"] = {"status": "ACTIVE", "tags": TAGS, "vpc": "vpc-1",
                                      "nodegroups": {"cpu": nodegroup(2, 2), "gpu": nodegroup(1)}}
        a.efs = {"fs-1": {"Name": "gpu-platform-restart", "tags": TAGS, "state": "available", "mounts": ["fsmt-1"]},
                 "fs-other": {"Name": "someone-else", "tags": TAGS, "state": "available", "mounts": []}}
        a.nats = [{"NatGatewayId": "nat-1", "VpcId": "vpc-1", "State": "available",
                   "NatGatewayAddresses": [{"AllocationId": "eipalloc-1"}]},
                  {"NatGatewayId": "nat-other", "VpcId": "vpc-2", "State": "available",
                   "NatGatewayAddresses": [{"AllocationId": "eipalloc-2"}]}]
        a.addresses = {"eipalloc-1": {"tags": TAGS}, "eipalloc-2": {"tags": TAGS}}
        lease(a, deadline=PAST)
        return a

    # First step: node groups only; nothing a node could still be using goes while one exists.
    # Mutation that turns it red: go on to EFS and the NAT before the groups are gone.
    def test_the_first_step_deletes_only_the_node_groups(self):
        a = self.account()
        failures, _ = run(a)
        self.assertEqual(failures, [])
        self.assertEqual(sorted(a.calls), [("delete_nodegroup", "cpu"), ("delete_nodegroup", "gpu")])
        self.assertIn(reaper.LEASE_PATH + "gpu-platform", a.leases)

    # A group already deleting is not asked again.
    def test_a_deleting_group_is_not_asked_again(self):
        a = self.account()
        for ng in a.clusters["gpu-platform"]["nodegroups"].values():
            ng["status"] = "DELETING"
        run(a)
        self.assertEqual(a.calls, [])

    # With the groups gone: the cluster, this session's EFS (not another's), its VPC's NAT (not another VPC's).
    # Mutation that turns it red: match EFS by the project tag alone, or NAT gateways outside the session's VPC.
    def test_with_the_groups_gone_the_rest_goes_and_only_the_sessions(self):
        a = self.account()
        a.clusters["gpu-platform"]["nodegroups"] = {}
        failures, _ = run(a)
        self.assertEqual(failures, [])
        self.assertEqual(sorted(a.calls), sorted([("delete_cluster", "gpu-platform"), ("delete_mount_target", "fsmt-1"),
                                                  ("delete_nat_gateway", "nat-1")]))

    # The address goes only once its gateway is deleted and nothing holds it; before that, whatever its association
    # reads, it waits.
    # Mutations that turn it red: harvest addresses from a gateway not yet deleted, or release an associated one.
    def test_an_address_is_released_only_after_its_gateway_is_deleted(self):
        a = self.account()
        a.clusters.pop("gpu-platform")
        a.efs.pop("fs-1")
        lease(a, deadline=PAST, vpc_id="vpc-1")
        a.nats[0]["State"] = "deleting"
        run(a)
        self.assertNotIn(("release_address", "eipalloc-1"), a.calls)
        a.calls.clear()
        a.nats[0]["State"] = "deleted"
        a.addresses["eipalloc-1"]["associated"] = True
        run(a)
        self.assertNotIn(("release_address", "eipalloc-1"), a.calls)
        a.calls.clear()
        a.addresses["eipalloc-1"]["associated"] = False
        run(a)
        self.assertIn(("release_address", "eipalloc-1"), a.calls)
        self.assertNotIn(("release_address", "eipalloc-2"), a.calls)

    # An address already released is skipped, not a failure on every later run.
    def test_a_released_address_is_not_a_failure(self):
        a = self.account()
        a.clusters.pop("gpu-platform")
        a.efs.pop("fs-1")
        a.nats[0]["State"] = "deleted"
        a.addresses.pop("eipalloc-1")
        lease(a, deadline=PAST, vpc_id="vpc-1")
        failures, _ = run(a)
        self.assertEqual(failures, [])
        self.assertNotIn(reaper.LEASE_PATH + "gpu-platform", a.leases)

    # Done means nothing left, and only then is the lease removed.
    # Mutation that turns it red: remove the lease while something is left.
    def test_the_lease_is_removed_only_when_nothing_is_left(self):
        a = self.account()
        run(a)
        self.assertIn(reaper.LEASE_PATH + "gpu-platform", a.leases)
        a = Account()
        lease(a, deadline=PAST, vpc_id="vpc-1")
        failures, logs = run(a)
        self.assertEqual(failures, [])
        self.assertEqual(a.calls, [("delete_parameter", reaper.LEASE_PATH + "gpu-platform")])

    # A cluster of the lease's name without the project tag is someone else's.
    # Mutation that turns it red: drop the cluster's project-tag check.
    def test_a_cluster_without_the_project_tag_is_refused(self):
        a = self.account()
        a.clusters["gpu-platform"]["tags"] = {}
        failures, _ = run(a)
        self.assertEqual(len(failures), 1)
        self.assertEqual(a.calls, [])

    # With no cluster and no record, the VPC is the project VPC named after the cluster, and two of them is a refusal.
    # Mutation that turns it red: take the first of several matches.
    def test_the_vpc_fallback_refuses_to_choose(self):
        a = self.account()
        a.clusters.pop("gpu-platform")
        a.efs.pop("fs-1")
        a.vpcs = [{"VpcId": "vpc-1", "Name": "gpu-platform-vpc", "project": True},
                  {"VpcId": "vpc-9", "Name": "gpu-platform-vpc", "project": True}]
        failures, _ = run(a)
        self.assertEqual(len(failures), 1)
        self.assertNotIn(("delete_nat_gateway", "nat-1"), a.calls)
        a.vpcs = a.vpcs[:1]
        failures, _ = run(a)
        self.assertEqual(failures, [])
        self.assertIn(("delete_nat_gateway", "nat-1"), a.calls)

    # One lease's failure does not stop the next lease's reaping.
    def test_one_failing_lease_does_not_stop_another(self):
        a = self.account()
        a.leases[reaper.LEASE_PATH + "aaa-broken"] = "not json"
        failures, _ = run(a)
        self.assertEqual(len(failures), 1)
        self.assertIn(("delete_nodegroup", "gpu"), a.calls)


if __name__ == "__main__":
    unittest.main()
