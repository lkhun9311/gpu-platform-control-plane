"""The termination sweeper: ends every instance whose study-deadline tag has passed.

Run by EventBridge every five minutes (infra/aws/bootstrap/sweeper.tf). The deadline travels with the launch, as a tag
set in RunInstances' own tag specifications, so it exists the moment the instance does, and nothing has to be
created after the launch for the instance to be swept (docs/superpowers/specs/2026-10-08-measuring-prospective-
admission-design.md, "The termination sweeper, which exists before launch").
"""

import datetime
import json

TAG = "study-deadline"
# Every state an instance can bill or come back from. A terminated or shutting-down instance is already going.
LIVE_STATES = ["pending", "running", "stopping", "stopped"]


def parse_deadline(value):
    """The deadline as an aware UTC datetime, or None when the value is not an ISO-8601 time with a zone."""
    try:
        t = datetime.datetime.fromisoformat(value.strip().replace("Z", "+00:00"))
    except (AttributeError, ValueError):
        return None
    if t.tzinfo is None:
        return None
    return t.astimezone(datetime.timezone.utc)


def decide(instances, now):
    """[(instance_id, reason)] for every instance to terminate now.

    An instance whose tag cannot be read as a zoned time is terminated too. The tag is set only by the study's
    runners, so an unreadable one is a runner's bug, and the cost of keeping an instance nobody can say the end of
    is what the sweeper exists to stop.
    """
    out = []
    for inst in instances:
        tags = {t["Key"]: t["Value"] for t in inst.get("Tags", [])}
        if TAG not in tags:
            continue
        deadline = parse_deadline(tags[TAG])
        if deadline is None:
            out.append((inst["InstanceId"], "its %s tag %r is not a zoned ISO-8601 time" % (TAG, tags[TAG])))
        elif now >= deadline:
            out.append((inst["InstanceId"], "its %s %s has passed" % (TAG, deadline.isoformat())))
    return out


def tagged_instances(ec2):
    """Every live instance carrying the tag, across pages."""
    out = []
    pages = ec2.get_paginator("describe_instances").paginate(
        Filters=[{"Name": "tag-key", "Values": [TAG]}, {"Name": "instance-state-name", "Values": LIVE_STATES}])
    for page in pages:
        for r in page["Reservations"]:
            out.extend(r["Instances"])
    return out


def handler(event, context):
    import boto3  # imported here so the tests can run without it

    ec2 = boto3.client("ec2")
    now = datetime.datetime.now(datetime.timezone.utc)
    doomed = decide(tagged_instances(ec2), now)
    for iid, why in doomed:
        # One call per instance, so one refusal does not spare the rest, and each outcome is logged by itself.
        try:
            ec2.terminate_instances(InstanceIds=[iid])
            print(json.dumps({"terminated": iid, "why": why, "at": now.isoformat()}))
        except Exception as e:  # noqa: BLE001 -- logged and the sweep continues
            print(json.dumps({"failed": iid, "why": why, "error": str(e), "at": now.isoformat()}))
    return {"checked_at": now.isoformat(), "terminated": [i for i, _ in doomed]}
