"""Serve one registered model version and say, in every answer, exactly which one it is.

InferenceDeployment runs every serving container as `<entrypoint> --model <name> --model-path <storageUri>`, so
the storage URI is the only thing that selects a version. Two forms are accepted:
`models:/<name>/<version>` pins a version, and `models:/<name>@<alias>` follows an alias — resolved once, here, at
start-up. Nothing re-resolves it later, and that is part of what the experiment measures.

The weights are refused, and the process exits, if their hash differs from the one the training run recorded:
an answer is only traceable if the bytes serving it are the bytes that were registered.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import mlflow
import torch
import torch.nn as nn
from mlflow.tracking import MlflowClient

FEATURES = 8
# A fixed probe, so a change of answer between versions is visible in the response as well as in the metadata.
PROBE = torch.linspace(1.0, -1.0, FEATURES).unsqueeze(0)


def resolve(client: MlflowClient, uri: str):
    pinned = re.fullmatch(r"models:/([^/@]+)/(\d+)", uri)
    if pinned:
        return client.get_model_version(pinned.group(1), pinned.group(2))
    aliased = re.fullmatch(r"models:/([^/@]+)@([A-Za-z0-9_-]+)", uri)
    if aliased:
        return client.get_model_version_by_alias(aliased.group(1), aliased.group(2))
    raise SystemExit(f"--model-path {uri!r} is neither models:/<name>/<version> nor models:/<name>@<alias>")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True)
    parser.add_argument("--model-path", required=True)
    parser.add_argument("--port", type=int, default=8090)
    args = parser.parse_args()

    # InferenceDeployment has no env field, so MLFLOW_TRACKING_URI cannot be set on a serving container; the
    # tracking server is therefore expected beside it, as the Service `mlflow` in the same namespace.
    mlflow.set_tracking_uri(os.environ.get("MLFLOW_TRACKING_URI", "http://mlflow:5000"))
    client = MlflowClient()
    version = resolve(client, args.model_path)
    local = mlflow.artifacts.download_artifacts(f"runs:/{version.run_id}/model/model.pt")
    with open(local, "rb") as handle:
        raw = handle.read()
    sha = hashlib.sha256(raw).hexdigest()
    recorded = version.tags.get("artifact_sha256")
    if sha != recorded:
        print(f"refusing: weights hash {sha} but version {version.version} recorded {recorded}", file=sys.stderr)
        return 1

    model = nn.Linear(FEATURES, 1)
    model.load_state_dict(torch.load(local, weights_only=True))
    model.eval()
    with torch.no_grad():
        probe_logit = float(model(PROBE))
    identity = {"model_name": version.name, "model_version": version.version, "run_id": version.run_id,
                "artifact_sha256": sha, "resolved_from": args.model_path, "probe_logit": probe_logit}
    body = json.dumps(identity, sort_keys=True).encode()
    print(json.dumps({"event": "serving", **identity}, sort_keys=True), flush=True)

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            # /health answers only once this process exists, which is after the weights loaded and checked out,
            # so the readiness probe cannot route traffic to a replica that has not loaded a model.
            if self.path == "/health":
                payload = b"ok"
            elif self.path == "/predict":
                payload = body
            else:
                self.send_error(404)
                return
            self.send_response(200)
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        def log_message(self, *_):
            pass

    ThreadingHTTPServer(("0.0.0.0", args.port), Handler).serve_forever()
    return 0


if __name__ == "__main__":
    sys.exit(main())
