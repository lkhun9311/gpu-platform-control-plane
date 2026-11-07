"""B4's trainer: a deterministic two-layer MLP on CUDA that checkpoints and resumes from a shared directory.

Each step's batch is generated from the step number, so a run resumed at step k sees exactly the batches an
uninterrupted run sees from k on, and the final parameters can be compared bit for bit with a reference run.
A checkpoint is written to a temporary name, fsynced and renamed, and LATEST is renamed over last, so a reader
that follows LATEST never sees a partial checkpoint.
Records are JSON lines on stdout: start, step, ckpt and done.

Environment: TRAIN_DIR (the run's directory on /shared), TRAIN_STEPS, TRAIN_STEP_SLEEP, TRAIN_CKPT_EVERY, and
TRAIN_DEVICE, which only the local rehearsal sets to cpu.
"""
import hashlib
import io
import json
import os
import socket
import sys
import time

import torch

DIR = os.environ["TRAIN_DIR"]
STEPS = int(os.environ.get("TRAIN_STEPS", "60"))
SLEEP = float(os.environ.get("TRAIN_STEP_SLEEP", "0"))
EVERY = int(os.environ.get("TRAIN_CKPT_EVERY", "5"))
DEVICE = os.environ.get("TRAIN_DEVICE", "cuda")
ATTEMPT = int(os.environ.get("SLURM_RESTART_COUNT", "0") or 0)


def rec(**kw):
    kw.update(t=round(time.time(), 3), attempt=ATTEMPT, host=socket.gethostname())
    print(json.dumps(kw, sort_keys=True), flush=True)


def fsync_write(path, data):
    tmp = path + ".tmp"
    with open(tmp, "wb") as fh:
        fh.write(data)
        fh.flush()
        os.fsync(fh.fileno())
    os.rename(tmp, path)
    dfd = os.open(os.path.dirname(path), os.O_RDONLY)
    os.fsync(dfd)
    os.close(dfd)


def params_sha(model):
    h = hashlib.sha256()
    # Through uint8 rather than .numpy(): the PyTorch wheel does not bring NumPy.
    for p in model.parameters():
        h.update(bytes(p.detach().cpu().contiguous().view(-1).view(torch.uint8).tolist()))
    return h.hexdigest()


def main():
    os.environ.setdefault("CUBLAS_WORKSPACE_CONFIG", ":4096:8")
    torch.use_deterministic_algorithms(True)
    torch.manual_seed(0)
    model = torch.nn.Sequential(torch.nn.Linear(64, 64), torch.nn.ReLU(), torch.nn.Linear(64, 1)).to(DEVICE)
    opt = torch.optim.SGD(model.parameters(), lr=0.01)
    os.makedirs(DIR, exist_ok=True)
    start, resumed_from = 1, None
    latest = os.path.join(DIR, "LATEST")
    if os.path.exists(latest):
        with open(latest) as fh:
            name = fh.read().strip()
        state = torch.load(os.path.join(DIR, name), map_location=DEVICE)
        model.load_state_dict(state["model"])
        opt.load_state_dict(state["opt"])
        resumed_from = state["step"]
        start = resumed_from + 1
    rec(event="start", resumed_from=resumed_from, first_step=start, device=DEVICE)
    for step in range(start, STEPS + 1):
        g = torch.Generator().manual_seed(step)
        x = torch.randn(32, 64, generator=g).to(DEVICE)
        y = torch.randn(32, 1, generator=g).to(DEVICE)
        loss = torch.nn.functional.mse_loss(model(x), y)
        opt.zero_grad()
        loss.backward()
        opt.step()
        rec(event="step", step=step, loss=round(float(loss.item()), 6))
        if step % EVERY == 0:
            name = f"ckpt-{step:05d}.pt"
            buf = io.BytesIO()
            torch.save({"model": model.state_dict(), "opt": opt.state_dict(), "step": step}, buf)
            fsync_write(os.path.join(DIR, name), buf.getvalue())
            fsync_write(latest, name.encode())
            rec(event="ckpt", step=step, name=name)
        if SLEEP:
            time.sleep(SLEEP)
    torch.save({k: v.cpu() for k, v in model.state_dict().items()}, os.path.join(DIR, "final.pt"))
    rec(event="done", params_sha256=params_sha(model))
    return 0


if __name__ == "__main__":
    sys.exit(main())
