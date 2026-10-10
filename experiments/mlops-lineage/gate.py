#!/usr/bin/env python3
"""Decide whether a candidate model version may become the champion, and move the alias only if it may.

Usage: gate.py TRACKING_URL MODEL VERSION [--max-drop 0.02] [--force]

The rule, fixed in the registration before any model existed: a candidate is promoted when there is no champion
yet, or when its held-out accuracy is no more than MAX_DROP below the champion's. --force moves the alias
regardless and says so, which is how the experiment stages an operator bypassing the gate.

It uses only the standard library and the MLflow REST API, so the host needs no MLflow install.
Prints one JSON decision and exits 0 for a decision either way; a non-zero exit means no decision was reached.
"""
import argparse
import json
import sys
import urllib.error
import urllib.parse
import urllib.request


def call(base, method, path, query=None, body=None):
    url = f"{base}/api/2.0/mlflow/{path}"
    if query:
        url += "?" + urllib.parse.urlencode(query)
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=10) as resp:
        return json.loads(resp.read() or b"{}")


def accuracy_of(base, version):
    run = call(base, "GET", "runs/get", {"run_id": version["run_id"]})["run"]
    metrics = {m["key"]: m["value"] for m in run["data"].get("metrics", [])}
    if "eval_accuracy" not in metrics:
        raise SystemExit(f"run {version['run_id']} has no eval_accuracy, so no decision can be made")
    return metrics["eval_accuracy"]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("tracking")
    parser.add_argument("model")
    parser.add_argument("version")
    parser.add_argument("--max-drop", type=float, default=0.02)
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()
    base = args.tracking.rstrip("/")

    candidate = call(base, "GET", "model-versions/get", {"name": args.model, "version": args.version})["model_version"]
    cand_acc = accuracy_of(base, candidate)
    try:
        champion = call(base, "GET", "registered-models/alias", {"name": args.model, "alias": "champion"})["model_version"]
    except urllib.error.HTTPError as err:
        # Only "no such alias" means there is no champion; any other failure must not read as an empty registry.
        # MLflow 2.17 answers a missing alias with 400 INVALID_PARAMETER_VALUE, not 404, and gives the same answer
        # for a model that does not exist, so the message is matched and the model's existence is already settled
        # by the candidate lookup above.
        detail = json.loads(err.read() or b"{}")
        if err.code != 400 or detail.get("message") != "Registered model alias champion not found.":
            raise
        champion = None
    champ_acc = accuracy_of(base, champion) if champion else None

    passes = champion is None or cand_acc >= champ_acc - args.max_drop
    promote = passes or args.force
    if promote:
        call(base, "POST", "registered-models/alias", body={"name": args.model, "alias": "champion", "version": args.version})
    print(json.dumps({
        "candidate": args.version, "candidate_accuracy": cand_acc,
        "champion_before": champion["version"] if champion else None, "champion_accuracy": champ_acc,
        "max_drop": args.max_drop, "passes_rule": passes, "forced": args.force and not passes,
        "alias_moved": promote,
    }, sort_keys=True))


if __name__ == "__main__":
    sys.exit(main())
