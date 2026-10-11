"""Train one small classifier, record where it came from, and register it as a model version.

The model is deliberately trivial: what this experiment tests is the trail around it. Every version must be
traceable from a served answer back to the bytes it was trained on and the code that trained it, so this script
records three hashes beside the usual metrics — the training data, this file, and the saved weights — and the
serving side refuses to start on weights whose hash does not match the one recorded here.

VARIANT=noisy reproduces a labelling bug confined to one region of the input, which shifts the learned boundary
and costs held-out accuracy. A uniformly random flip would not: a linear classifier averages it away.
"""

from __future__ import annotations

import hashlib
import json
import os
import socket
import sys

import mlflow
import torch
import torch.nn as nn

MODEL_NAME = os.environ.get("MODEL_NAME", "clf")
VARIANT = os.environ.get("VARIANT", "clean")
GIT_COMMIT = os.environ.get("GIT_COMMIT", "unset")
FEATURES = 8
TRUE_W = torch.linspace(-1.0, 1.0, FEATURES).unsqueeze(1)


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def tensor_bytes(t: torch.Tensor) -> bytes:
    # A uint8 view of contiguous storage; the CPU torch image ships without numpy.
    return bytes(t.detach().contiguous().flatten().view(torch.uint8).tolist())


def dataset(seed: int, n: int) -> tuple[torch.Tensor, torch.Tensor]:
    g = torch.Generator().manual_seed(seed)
    x = torch.randn(n, FEATURES, generator=g)
    y = (x @ TRUE_W > 0).float()
    return x, y


def main() -> int:
    if VARIANT not in ("clean", "noisy"):
        print(f"VARIANT={VARIANT!r} is not clean or noisy", file=sys.stderr)
        return 2
    torch.manual_seed(0)
    x, y = dataset(seed=7, n=2000)
    if VARIANT == "noisy":
        # The labelling bug: every positive example whose first feature is below -0.3 was labelled negative.
        y = torch.where((x[:, 0:1] < -0.3) & (y == 1), torch.zeros_like(y), y)
    x_eval, y_eval = dataset(seed=8, n=1000)

    model = nn.Linear(FEATURES, 1)
    optimiser = torch.optim.SGD(model.parameters(), lr=0.5)
    loss_fn = nn.BCEWithLogitsLoss()
    for _ in range(300):
        optimiser.zero_grad()
        loss = loss_fn(model(x), y)
        loss.backward()
        optimiser.step()
    with torch.no_grad():
        accuracy = float(((model(x_eval) > 0).float() == y_eval).float().mean())

    weights = "/tmp/model.pt"
    torch.save(model.state_dict(), weights)
    with open(weights, "rb") as handle:
        artifact_sha = sha256_bytes(handle.read())
    with open(__file__, "rb") as handle:
        code_sha = sha256_bytes(handle.read())
    data_sha = sha256_bytes(tensor_bytes(x) + tensor_bytes(y))

    mlflow.set_experiment(MODEL_NAME)
    with mlflow.start_run() as run:
        mlflow.log_params({"variant": VARIANT, "data_seed": 7, "epochs": 300, "lr": 0.5})
        mlflow.log_metric("eval_accuracy", accuracy)
        mlflow.set_tags({
            "git_commit": GIT_COMMIT,
            "code_sha256": code_sha,
            "train_data_sha256": data_sha,
            "artifact_sha256": artifact_sha,
            "trained_in_pod": socket.gethostname(),
        })
        mlflow.log_artifact(weights, artifact_path="model")
        run_id = run.info.run_id
    version = mlflow.register_model(f"runs:/{run_id}/model", MODEL_NAME, tags={"artifact_sha256": artifact_sha})

    record = {"event": "trained", "variant": VARIANT, "run_id": run_id, "model_version": version.version,
              "eval_accuracy": accuracy, "train_data_sha256": data_sha, "code_sha256": code_sha,
              "artifact_sha256": artifact_sha, "git_commit": GIT_COMMIT, "pod": socket.gethostname()}
    print(json.dumps(record, sort_keys=True), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
