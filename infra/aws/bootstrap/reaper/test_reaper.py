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
        self.log_groups = {}  # name -> tags
        self.keys = {}  # alias -> {id, state, tags}
        self.heartbeat = None
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
                assert kw["Path"] == reaper.LEASE_PATH.rstrip("/"), kw["Path"]
                return [{"Parameters": [{"Name": n, "Value": v} for n, v in sorted(a.leases.items())]}]
        return P()

    def get_parameter(self, Name):
        if Name not in self.a.leases:
            raise AWSError("ParameterNotFound")
        return {"Parameter": {"Name": Name, "Value": self.a.leases[Name]}}

    def put_parameter(self, Name, Value, Type, Overwrite):
        assert Name == reaper.HEARTBEAT
        self.a.heartbeat = Value

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

    def _fs(self, i, f):
        return {"FileSystemId": i, "LifeCycleState": f["state"],
                "Tags": [{"Key": k, "Value": v} for k, v in {**f["tags"], "Name": f["Name"]}.items()]}

    def describe_file_systems(self, FileSystemId):
        if FileSystemId not in self.a.efs:
            raise AWSError("FileSystemNotFound")
        return {"FileSystems": [self._fs(FileSystemId, self.a.efs[FileSystemId])]}

    # Two pages, so a reader of the first page alone misses the second's file systems.
    def get_paginator(self, _):
        items = [self._fs(i, f) for i, f in sorted(self.a.efs.items())]

        class P:
            def paginate(self, **_):
                return [{"FileSystems": items[:1]}, {"FileSystems": items[1:]}]
        return P()

    def describe_mount_targets(self, FileSystemId):
        if self.a.efs[FileSystemId].get("denied"):
            raise AWSError("AccessDeniedException")
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

    def describe_availability_zones(self, AllAvailabilityZones):
        return {"AvailabilityZones": [{"ZoneName": z} for z in ("ap-northeast-2a", "ap-northeast-2b", "ap-northeast-2c", "ap-northeast-2d")]}

    def describe_nat_gateways(self, Filters):
        vpc = [f["Values"][0] for f in Filters if f["Name"] == "vpc-id"][0]
        assert any(f["Name"] == "tag:project" for f in Filters), "NAT gateways listed without the project filter"
        return {"NatGateways": [n for n in self.a.nats if n["VpcId"] == vpc]}

    def delete_nat_gateway(self, NatGatewayId):
        self.a.calls.append(("delete_nat_gateway", NatGatewayId))

    def describe_addresses(self, Filters):
        assert any(f["Name"] == "tag:project" for f in Filters), "addresses listed without the project filter"
        out = []
        for alloc, a in sorted(self.a.addresses.items()):
            if a["tags"].get("project") != "gpu-platform-control-plane":
                continue
            names = [f["Values"] for f in Filters if f["Name"] == "tag:Name"][0]
            assert not any("*" in n or "?" in n for n in names), "addresses matched by a pattern, not exact names"
            if a["tags"].get("Name", "") not in names:
                continue
            d = {"AllocationId": alloc, "Tags": [{"Key": k, "Value": v} for k, v in a["tags"].items()]}
            if a.get("associated"):
                d["AssociationId"] = "eipassoc-1"
            out.append(d)
        return {"Addresses": out}

    def release_address(self, AllocationId):
        self.a.calls.append(("release_address", AllocationId))
        del self.a.addresses[AllocationId]


class Logs:
    def __init__(self, a):
        self.a = a

    def describe_log_groups(self, logGroupNamePrefix):
        return {"logGroups": [{"logGroupName": n, "arn": f"arn:aws:logs:r:1:log-group:{n}:*"}
                              for n in sorted(self.a.log_groups) if n.startswith(logGroupNamePrefix)]}

    def list_tags_for_resource(self, resourceArn):
        assert not resourceArn.endswith(":*"), resourceArn
        return {"tags": self.a.log_groups[resourceArn.split("log-group:", 1)[1]]}

    def delete_log_group(self, logGroupName):
        self.a.calls.append(("delete_log_group", logGroupName))
        del self.a.log_groups[logGroupName]


class KMS:
    def __init__(self, a):
        self.a = a

    def _by(self, KeyId):
        if KeyId in self.a.keys:
            return self.a.keys[KeyId]
        for k in self.a.keys.values():
            if k["id"] == KeyId:
                return k
        raise AWSError("NotFoundException")

    def describe_key(self, KeyId):
        k = self._by(KeyId)
        if KeyId.startswith("alias/") and k.get("unaliased"):
            raise AWSError("NotFoundException")
        return {"KeyMetadata": {"KeyId": k["id"], "KeyState": k["state"], "KeyManager": k.get("manager", "CUSTOMER"),
                                "Description": k.get("description", "")}}

    def get_paginator(self, _):
        ids = [{"KeyId": k["id"]} for k in self.a.keys.values()]

        class P:
            def paginate(self, **_):
                return [{"Keys": ids}]
        return P()

    def list_resource_tags(self, KeyId):
        k = [k for k in self.a.keys.values() if k["id"] == KeyId][0]
        return {"Tags": [{"TagKey": t, "TagValue": v} for t, v in k["tags"].items()]}

    def schedule_key_deletion(self, KeyId, PendingWindowInDays):
        self.a.calls.append(("schedule_key_deletion", KeyId))
        for k in self.a.keys.values():
            if k["id"] == KeyId:
                k["state"] = "PendingDeletion"


def lease(a, cluster="gpu-platform", **fields):
    body = {"cluster": cluster, "deadline": FUTURE, **fields}
    a.leases[reaper.LEASE_PATH + cluster] = json.dumps(body)


def run(a):
    logs = []
    failures = reaper.run(SSM(a), EKS(a), EC2(a), EFS(a), ASG(a), Logs(a), KMS(a), NOW, logs.append)
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
        a.addresses = {"eipalloc-1": {"tags": {**TAGS, "Name": "gpu-platform-vpc-ap-northeast-2a"}},
                       "eipalloc-2": {"tags": {**TAGS, "Name": "other-vpc-ap-northeast-2a"}},
                       "eipalloc-3": {"tags": {**TAGS, "Name": "gpu-platform-vpc-test-vpc-ap-northeast-2a"}}}
        a.log_groups = {"/aws/eks/gpu-platform/cluster": dict(TAGS), "/aws/eks/gpu-platform/cluster-old": dict(TAGS)}
        a.keys = {"alias/eks/gpu-platform": {"id": "k-eks", "state": "Enabled", "tags": dict(TAGS),
                                             "description": "gpu-platform cluster encryption key"},
                  "alias/gpu-platform-state": {"id": "k-state", "state": "Enabled", "tags": dict(TAGS),
                                               "description": "terraform state"}}
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

    # The address goes only once no gateway of the session is still being deleted and nothing holds it.
    # Mutations that turn it red: release while a gateway is deleting, or release an associated one.
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
        self.assertIn(reaper.LEASE_PATH + "gpu-platform", a.leases, "the lease went in the run that released the address")
        run(a)
        self.assertNotIn(reaper.LEASE_PATH + "gpu-platform", a.leases)

    # An address allocated by an apply that died before its gateway existed is found by its own tags.
    # Mutation that turns it red: find addresses only through the NAT gateways.
    def test_an_address_without_a_gateway_is_still_released(self):
        a = self.account()
        a.clusters.pop("gpu-platform")
        a.efs.pop("fs-1")
        a.nats = []
        lease(a, deadline=PAST)
        run(a)
        self.assertIn(("release_address", "eipalloc-1"), a.calls)
        self.assertNotIn(("release_address", "eipalloc-2"), a.calls)
        self.assertNotIn(("release_address", "eipalloc-3"), a.calls, "another cluster's address matched by prefix")

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

    # A recorded EFS id is used alone: a preserved copy with the same Name and tag is not the session's.
    # Mutation that turns it red: match the recorded id or the Name.
    def test_a_recorded_file_system_is_the_only_one_deleted(self):
        a = self.account()
        a.clusters["gpu-platform"]["nodegroups"] = {}
        a.efs["fs-copy"] = {"Name": "gpu-platform-restart", "tags": TAGS, "state": "available", "mounts": ["fsmt-copy"]}
        lease(a, deadline=PAST, efs_id="fs-1")
        run(a)
        self.assertIn(("delete_mount_target", "fsmt-1"), a.calls)
        self.assertNotIn(("delete_mount_target", "fsmt-copy"), a.calls)

    # Without a record, the file system is found on any page, and two of the name is a refusal.
    # Mutations that turn it red: read the first page only, or take the first of several.
    def test_an_unrecorded_file_system_is_found_on_any_page_and_never_chosen(self):
        a = self.account()
        a.clusters["gpu-platform"]["nodegroups"] = {}
        a.efs = {"fs-0": {"Name": "someone-else", "tags": TAGS, "state": "available", "mounts": []},
                 "fs-1": {"Name": "gpu-platform-restart", "tags": TAGS, "state": "available", "mounts": ["fsmt-1"]}}
        run(a)
        self.assertIn(("delete_mount_target", "fsmt-1"), a.calls)
        a = self.account()
        a.clusters["gpu-platform"]["nodegroups"] = {}
        a.efs["fs-2"] = {"Name": "gpu-platform-restart", "tags": TAGS, "state": "available", "mounts": ["fsmt-2"]}
        failures, _ = run(a)
        self.assertEqual(len(failures), 1)
        self.assertFalse([c for c in a.calls if c[0] == "delete_mount_target"])

    # The cluster's log group and its own key go once the cluster is gone, and nothing else of the kind.
    # Mutations that turn it red: delete them while the cluster exists, match the log group by prefix, schedule any key.
    def test_the_log_group_and_key_go_after_the_cluster_and_only_the_clusters(self):
        a = self.account()
        a.clusters["gpu-platform"]["nodegroups"] = {}
        run(a)
        self.assertFalse([c for c in a.calls if c[0] in ("delete_log_group", "schedule_key_deletion")])
        a.clusters.pop("gpu-platform")
        a.calls.clear()
        run(a)
        self.assertIn(("delete_log_group", "/aws/eks/gpu-platform/cluster"), a.calls)
        self.assertNotIn(("delete_log_group", "/aws/eks/gpu-platform/cluster-old"), a.calls)
        self.assertIn(("schedule_key_deletion", "k-eks"), a.calls)
        self.assertNotIn(("schedule_key_deletion", "k-state"), a.calls)
        a.calls.clear()
        run(a)
        self.assertNotIn(("schedule_key_deletion", "k-eks"), a.calls, "a key pending deletion was scheduled again")

    # Mutation that turns it red: drop the key's tag check.
    def test_a_key_without_the_project_tag_is_left(self):
        a = self.account()
        a.clusters.pop("gpu-platform")
        a.keys["alias/eks/gpu-platform"]["tags"] = {}
        run(a)
        self.assertNotIn(("schedule_key_deletion", "k-eks"), a.calls)

    # A renewal written after the run read the lease stops the scale-down.
    # Mutation that turns it red: scale on the run's first copy without reading the lease again.
    def test_a_lease_renewed_during_the_run_is_not_scaled_down(self):
        a = Account()
        a.clusters["gpu-platform"] = {"status": "ACTIVE", "tags": TAGS, "nodegroups": {"gpu": nodegroup(2)}}
        lease(a, gpu_deadline=PAST, gpu_nodegroups=["gpu"])
        stale = [{"Name": n, "Value": v} for n, v in a.leases.items()]
        lease(a, gpu_deadline=FUTURE, gpu_nodegroups=["gpu"])

        class Stale(SSM):
            # The run's listing is the copy read before the renewal; get_parameter reads the store as it is now.
            def get_paginator(self, _):
                class P:
                    def paginate(self, **_):
                        return [{"Parameters": stale}]
                return P()
        failures = reaper.run(Stale(a), EKS(a), EC2(a), EFS(a), ASG(a), Logs(a), KMS(a), NOW, lambda _: None)
        self.assertEqual(failures, [])
        self.assertEqual(a.calls, [])

    # A clean pass writes the heartbeat a session reads before arming; a failing one does not.
    # Mutation that turns it red: write it whatever the pass found.
    def test_the_heartbeat_is_written_only_by_a_clean_pass(self):
        a = Account()
        run(a)
        self.assertEqual(a.heartbeat, "2026-11-07T12:00:00Z")
        a = Account()
        a.leases[reaper.LEASE_PATH + "broken"] = "not json"
        run(a)
        self.assertIsNone(a.heartbeat)

    # A key whose alias is gone is found by the module's exact description; one with another description is not.
    # Mutation that turns it red: look only by alias.
    def test_a_key_without_its_alias_is_still_found(self):
        a = self.account()
        a.clusters.pop("gpu-platform")
        a.keys["alias/eks/gpu-platform"]["unaliased"] = True
        a.keys["k-other"] = {"id": "k-other", "state": "Enabled", "tags": dict(TAGS), "description": "gpu-platform-old cluster encryption key"}
        run(a)
        self.assertIn(("schedule_key_deletion", "k-eks"), a.calls)
        self.assertNotIn(("schedule_key_deletion", "k-other"), a.calls)
        self.assertNotIn(("schedule_key_deletion", "k-state"), a.calls)

    # A run that read session A must neither reap for, nor remove, the lease session B wrote meanwhile.
    # Mutation that turns it red: skip the lease's identity check before reaping or before removing it.
    def test_a_lease_replaced_during_the_run_is_left_alone(self):
        a = Account()
        lease(a, deadline=PAST, session="A", vpc_id="vpc-1")
        stale = [{"Name": n, "Value": v} for n, v in a.leases.items()]
        lease(a, deadline=PAST, session="B", vpc_id="vpc-1")

        class Stale(SSM):
            def get_paginator(self, _):
                class P:
                    def paginate(self, **_):
                        return [{"Parameters": stale}]
                return P()
        failures = reaper.run(Stale(a), EKS(a), EC2(a), EFS(a), ASG(a), Logs(a), KMS(a), NOW, lambda _: None)
        self.assertEqual(failures, [])
        self.assertIn(reaper.LEASE_PATH + "gpu-platform", a.leases)
        self.assertEqual(a.calls, [])

    # Before reaping: a lease replaced since the run's listing stops the reaping of the old session's copy.
    # Mutation that turns it red: skip the identity check before reaping.
    def test_a_lease_replaced_before_reaping_reaps_nothing(self):
        a = Account()
        a.clusters["gpu-platform"] = {"status": "ACTIVE", "tags": TAGS, "nodegroups": {"gpu": nodegroup(1)}}
        lease(a, deadline=PAST, session="A")
        stale = [{"Name": n, "Value": v} for n, v in a.leases.items()]
        lease(a, deadline=FUTURE, session="B")

        class Stale(SSM):
            def get_paginator(self, _):
                class P:
                    def paginate(self, **_):
                        return [{"Parameters": stale}]
                return P()
        failures = reaper.run(Stale(a), EKS(a), EC2(a), EFS(a), ASG(a), Logs(a), KMS(a), NOW, lambda _: None)
        self.assertEqual(failures, [])
        self.assertEqual(a.calls, [], "the old copy's deadline deleted the new session's node group")

    # Before removing: a lease replaced while the run reaped is kept.
    # Mutation that turns it red: skip the identity check before removing the lease.
    def test_a_lease_replaced_while_reaping_is_kept(self):
        a = Account()
        lease(a, deadline=PAST, session="A", vpc_id="vpc-1")
        eks = EKS(a)

        def gone_and_replaced(name):
            lease(a, deadline=FUTURE, session="B", vpc_id="vpc-1")
            raise AWSError("ResourceNotFoundException")
        eks.describe_cluster = gone_and_replaced
        failures = reaper.run(SSM(a), eks, EC2(a), EFS(a), ASG(a), Logs(a), KMS(a), NOW, lambda _: None)
        self.assertEqual(failures, [])
        self.assertIn(reaper.LEASE_PATH + "gpu-platform", a.leases)
        self.assertNotIn(("delete_parameter", reaper.LEASE_PATH + "gpu-platform"), a.calls)

    # An EFS step that is refused does not keep the NAT gateway billing; the run still fails so it is seen.
    # Mutation that turns it red: let the EFS failure end the step before the network.
    def test_a_refused_efs_step_does_not_stop_the_network_step(self):
        a = self.account()
        a.clusters["gpu-platform"]["nodegroups"] = {}
        a.efs["fs-1"]["denied"] = True
        lease(a, deadline=PAST, vpc_id="vpc-1", efs_id="fs-1")
        failures, _ = run(a)
        self.assertEqual(len(failures), 1)
        self.assertIn(("delete_nat_gateway", "nat-1"), a.calls)

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

    # An AWS error on one lease does not stop the next lease either, not only a lease that cannot be read.
    # Mutation that turns it red: catch only LeaseError.
    def test_an_aws_error_on_one_lease_does_not_stop_another(self):
        a = self.account()
        a.clusters["aaa-denied"] = {"status": "ACTIVE", "tags": TAGS, "nodegroups": {}}
        lease(a, cluster="aaa-denied", deadline=PAST)
        eks = EKS(a)
        real = eks.describe_cluster

        def denied(name):
            if name == "aaa-denied":
                raise AWSError("AccessDeniedException")
            return real(name)
        eks.describe_cluster = denied
        failures = reaper.run(SSM(a), eks, EC2(a), EFS(a), ASG(a), Logs(a), KMS(a), NOW, lambda _: None)
        self.assertEqual(len(failures), 1)
        self.assertIn(("delete_nodegroup", "gpu"), a.calls)

    # One lease's failure does not stop the next lease's reaping.
    def test_one_failing_lease_does_not_stop_another(self):
        a = self.account()
        a.leases[reaper.LEASE_PATH + "aaa-broken"] = "not json"
        failures, _ = run(a)
        self.assertEqual(len(failures), 1)
        self.assertIn(("delete_nodegroup", "gpu"), a.calls)


if __name__ == "__main__":
    unittest.main()
