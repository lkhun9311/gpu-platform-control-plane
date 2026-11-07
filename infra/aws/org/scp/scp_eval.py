"""What the SCPs in this directory would do to one recorded CloudTrail event.

simulate.sh reads every event CloudTrail recorded and asks these functions whether a policy here would have refused
it. They evaluate the policy's own action patterns and conditions rather than a copy of them: the version inlined in
simulate.sh turned the region policy's exemption of kms:DescribeKey into an exemption of every kms call, and decided
the instance-family policy by searching the request for a fixed list of type prefixes, so a recorded m7i.large launch
matched none of them and passed (gpt-6-astra's review of 116092ef, r5 finding 11).

An event's action is its eventSource's first label and its eventName, which is the IAM action for the services this
account calls; a service whose CloudTrail source differs from its IAM prefix would be evaluated under the wrong name.
"""

import fnmatch
import json
import sys


def _list(x):
    return x if isinstance(x, list) else [x]


def event_action(event):
    """The IAM action an event records, such as ec2:RunInstances."""
    return "%s:%s" % (event.get("eventSource", "").split(".")[0], event.get("eventName", ""))


def action_matches(action, patterns):
    """Whether an action matches any IAM action pattern; IAM compares action names without regard to case."""
    a = action.lower()
    return any(fnmatch.fnmatchcase(a, p.lower()) for p in patterns)


def _applies(statement, action):
    if "NotAction" in statement:
        return not action_matches(action, _list(statement["NotAction"]))
    return action_matches(action, _list(statement.get("Action", [])))


def region_denied(event, policy):
    """Why the region policy would deny the event, or None."""
    action = event_action(event)
    for s in policy["Statement"]:
        regions = s.get("Condition", {}).get("StringNotEquals", {}).get("aws:RequestedRegion")
        if s.get("Effect") != "Deny" or regions is None or not _applies(s, action):
            continue
        if event.get("awsRegion") not in _list(regions):
            return "%s: %s in %s" % (s.get("Sid"), action, event.get("awsRegion"))
    return None


def instance_types(event):
    """The instance types an event's request names, as CloudTrail records RunInstances' parameters."""
    rp = event.get("requestParameters") or {}
    out = []
    if isinstance(rp.get("instanceType"), str):
        out.append(rp["instanceType"])
    ltd = rp.get("launchTemplateData") or {}
    if isinstance(ltd.get("instanceType"), str):
        out.append(ltd["instanceType"])
    return out


def family_verdict(event, policy):
    """("deny", why), ("unevaluated", why) when the request names no instance type to test, or (None, None)."""
    action = event_action(event)
    for s in policy["Statement"]:
        if s.get("Effect") != "Deny" or not _applies(s, action):
            continue
        for key, patterns in s.get("Condition", {}).get("StringNotLike", {}).items():
            if key.lower() != "ec2:instancetype":
                return "unevaluated", "%s: condition key %s is not one this checker evaluates" % (s.get("Sid"), key)
            types = instance_types(event)
            if not types:
                return "unevaluated", "%s: %s records no instance type" % (s.get("Sid"), action)
            bad = [t for t in types if not any(fnmatch.fnmatchcase(t, p) for p in _list(patterns))]
            if bad:
                return "deny", "%s: %s of %s" % (s.get("Sid"), action, ", ".join(bad))
    return None, None


def main(argv):
    """scp_eval.py region|family POLICY EVENTS_JSONL: prints each denial and exits 1 when there is any."""
    mode, policy_path, events_path = argv[1:4]
    policy = json.load(open(policy_path))
    seen = denied = unevaluated = unreadable = 0
    for line in open(events_path):
        try:
            event = json.loads(line)
        except ValueError:
            unreadable += 1
            continue
        seen += 1
        if mode == "region":
            why = region_denied(event, policy)
            if why:
                denied += 1
                print("   WOULD HAVE DENIED %s" % why)
        else:
            verdict, why = family_verdict(event, policy)
            if verdict == "deny":
                denied += 1
                print("   WOULD HAVE DENIED %s" % why)
            elif verdict == "unevaluated":
                unevaluated += 1
                print("   NOT EVALUATED %s" % why)
    print("   %d event(s) read, %d unreadable, %d would have been denied, %d not evaluated" % (seen, unreadable, denied, unevaluated))
    # An unreadable line is an event this check did not judge, so it fails the run as a denial would.
    return 1 if denied or unreadable else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
