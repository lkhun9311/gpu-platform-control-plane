"""Print, as JSON, the GPU and library versions that the kit's pytest runs see."""

import json
import platform

import torch
import triton

rec = {
    "python": platform.python_version(),
    "torch": torch.__version__,
    "torch_cuda": torch.version.cuda,
    "triton": triton.__version__,
    "cuda_available": torch.cuda.is_available(),
    "device_name": torch.cuda.get_device_name(0) if torch.cuda.is_available() else None,
    "device_count": torch.cuda.device_count(),
}
print(json.dumps(rec, sort_keys=True))
