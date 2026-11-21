"""A fake huggingface_hub: snapshot_download writes a small fake checkpoint, or fails with FAKE_DOWNLOAD_FAIL=1."""

import json
import os


def snapshot_download(repo, revision=None, local_dir=None, allow_patterns=None):
    if os.environ.get("FAKE_DOWNLOAD_FAIL") == "1":
        raise RuntimeError("fake download failure")
    os.makedirs(local_dir, exist_ok=True)
    with open(os.path.join(local_dir, "config.json"), "w") as f:
        json.dump({"architectures": ["NemotronHForCausalLM"], "repo": repo, "revision": revision}, f)
    for name in ("model-00001-of-00002.safetensors", "model-00002-of-00002.safetensors", "tokenizer.json"):
        with open(os.path.join(local_dir, name), "w") as f:
            f.write(f"fake {name}\n")
    return local_dir
