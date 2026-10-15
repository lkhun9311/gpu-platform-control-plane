"""Derives one cell's replay manifest from the diagnostic's archived one.

    python3 derive_manifest.py <archived manifest> <out> --arm Off|HoldCap --gateway-url URL \
        --gateway-sha SHA --gateway-image REF@sha256:... --engine-image REF@sha256:...

Everything the load is made of is kept as archived: seed, trace checksum, prompt lengths, output limits, timeout,
model, tokenizer revision and prompt corpus.
Replaced: the study and arm, so every raw row is stamped with this study's; the trace path, made relative so the
manifest travels with its trace; the gateway URL; and the provenance, which must name the builds that answered.
Dropped: gatewayBase and gatewayBinarySHA256, which describe the lab's hand-built gateway binary; the product's is
named by its image digest instead.
The output is JSON, which the harness reads as YAML.
"""

import argparse
import json
import os
import re
import sys

import yaml

STUDY = "holdcap-product-transfer-2026-10-15"
DIGEST = re.compile(r"^\S+@sha256:[0-9a-f]{64}$")
COMMIT = re.compile(r"^[0-9a-f]{40}$")


def derive(archived: dict, arm: str, gateway_url: str, gateway_sha: str, gateway_image: str, engine_image: str) -> dict:
    if archived.get("study") != "admission-diagnostic-2026-10-10" or archived.get("arm") not in ("off", "hold-cap"):
        raise ValueError(f"not one of the diagnostic's off or hold-cap manifests: {archived.get('study')} {archived.get('arm')}")
    if arm not in ("Off", "HoldCap"):
        raise ValueError(f"arm {arm!r} is not Off or HoldCap")
    if not COMMIT.match(gateway_sha):
        raise ValueError(f"gateway sha {gateway_sha!r} is not a commit")
    for name, ref in (("gateway", gateway_image), ("engine", engine_image)):
        if not DIGEST.match(ref):
            raise ValueError(f"{name} image {ref!r} is not pinned by digest")
    out = {k: v for k, v in archived.items() if k not in ("gatewayBase", "gatewayBinarySHA256")}
    out.update({
        "study": STUDY,
        "arm": arm,
        "tracePath": os.path.basename(archived["tracePath"]).replace("hold-cap", "off"),
        "gatewayURL": gateway_url,
        "gatewaySHA": gateway_sha,
        "imageDigests": {"gateway": gateway_image, "engine": engine_image},
    })
    return out


def main(argv):
    p = argparse.ArgumentParser()
    p.add_argument("archived")
    p.add_argument("out")
    p.add_argument("--arm", required=True)
    p.add_argument("--gateway-url", required=True)
    p.add_argument("--gateway-sha", required=True)
    p.add_argument("--gateway-image", required=True)
    p.add_argument("--engine-image", required=True)
    a = p.parse_args(argv)
    with open(a.archived) as f:
        archived = yaml.safe_load(f)
    try:
        out = derive(archived, a.arm, a.gateway_url, a.gateway_sha, a.gateway_image, a.engine_image)
    except ValueError as exc:
        print(f"derive_manifest: {exc}", file=sys.stderr)
        return 1
    with open(a.out, "w") as f:
        json.dump(out, f, indent=1, sort_keys=True)
        f.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
