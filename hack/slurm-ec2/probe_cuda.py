"""B1's probe: what a job can do with the GPU, printed as one JSON object.

It unsets CUDA_VISIBLE_DEVICES first when PROBE_UNSET=1, because the question is whether the device cgroup, not the
variable Slurm sets, keeps a job without a GPU allocation away from the card.
Every attempt is recorded with its error rather than allowed to end the probe.
"""
import errno
import json
import os
import socket
import subprocess
import sys

out = {"host": socket.gethostname(), "job": os.environ.get("SLURM_JOB_ID", ""),
       "cvd_before": os.environ.get("CUDA_VISIBLE_DEVICES")}
if os.environ.get("PROBE_UNSET") == "1":
    os.environ.pop("CUDA_VISIBLE_DEVICES", None)
out["cvd_after"] = os.environ.get("CUDA_VISIBLE_DEVICES")

try:
    fd = os.open("/dev/nvidia0", os.O_RDONLY)
    os.close(fd)
    out["open_nvidia0"] = "ok"
except OSError as exc:
    out["open_nvidia0"] = errno.errorcode.get(exc.errno, str(exc.errno))

r = subprocess.run(["nvidia-smi", "-L"], capture_output=True, text=True)
out["nvidia_smi_rc"] = r.returncode
out["nvidia_smi_lines"] = [l for l in r.stdout.splitlines() if l.strip()]
out["nvidia_smi_err"] = r.stderr.strip()[:300]

try:
    import torch
    out["device_count"] = torch.cuda.device_count()
    try:
        x = torch.arange(1024, dtype=torch.float32, device="cuda")
        out["cuda_sum"] = float(x.sum().item())
    except Exception as exc:  # noqa: BLE001 - the error is the observation
        out["cuda_error"] = f"{type(exc).__name__}: {exc}"[:300]
except Exception as exc:  # noqa: BLE001
    out["torch_error"] = f"{type(exc).__name__}: {exc}"[:300]

print(json.dumps(out, sort_keys=True))
sys.exit(0)
