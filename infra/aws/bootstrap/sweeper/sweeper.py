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
        if t.tzinfo is None:
            return None
        # Converting a time at the edge of the calendar can overflow; that raised past this handler and ended the
        # whole sweep before any termination (v26 review, C31).
        return t.astimezone(datetime.timezone.utc)
    except (AttributeError, ValueError, OverflowError):
        return None


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


def sweep(ec2, now):
    """Terminates every doomed instance, one call each, and returns which calls were accepted and which failed.

    The result named every candidate as terminated, a refused call included (v26 review, C32). An accepted call is
    named "termination requested": the instance's state is not observed here, and the next sweep finds it again if it
    is still live.
    """
    requested, failed = [], []
    for iid, why in decide(tagged_instances(ec2), now):
        # One call per instance, so one refusal does not spare the rest, and each outcome is logged by itself.
        try:
            ec2.terminate_instances(InstanceIds=[iid])
            requested.append(iid)
            print(json.dumps({"termination_requested": iid, "why": why, "at": now.isoformat()}))
        except Exception as e:  # noqa: BLE001 -- logged and the sweep continues
            failed.append(iid)
            print(json.dumps({"failed": iid, "why": why, "error": str(e), "at": now.isoformat()}))
    return {"checked_at": now.isoformat(), "termination_requested": requested, "failed": failed}


def handler(event, context):
    import boto3  # imported here so the tests can run without it
    from botocore.config import Config

    # Every call is bounded, so one slow request cannot spend the invocation and spare the instances after it
    # (v26 review, C33); the function's own limit in sweeper.tf leaves room for enumeration and every call.
    ec2 = boto3.client("ec2", config=Config(connect_timeout=5, read_timeout=15, retries={"max_attempts": 2}))
    return sweep(ec2, datetime.datetime.now(datetime.timezone.utc))
