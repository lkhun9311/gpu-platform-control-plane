"""Lets the chart's Envoy sidecar carry gRPC to the model server.

The v1.0.0 chart's original_destination_cluster has no upstream protocol options, so Envoy speaks HTTP/1.1 upstream and a gRPC backend cannot answer.
This adds use_downstream_protocol_config, so HTTP/2 requests stay HTTP/2 and HTTP/1.1 requests stay HTTP/1.1.
Nothing else in the rendered chart changes.
Usage: python3 envoy-h2-upstream.py rendered-envoy.yaml > rendered-envoy-h2.yaml
"""
import sys

import yaml

# Helm output contains empty documents, which safe_dump_all would write as "--- null" and kubectl rejects.
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d is not None]
patched = 0
for d in docs:
    if d and d.get("kind") == "ConfigMap" and "envoy.yaml" in d.get("data", {}):
        cfg = yaml.safe_load(d["data"]["envoy.yaml"])
        for cluster in cfg["static_resources"]["clusters"]:
            if cluster["name"] == "original_destination_cluster":
                cluster["typed_extension_protocol_options"] = {
                    "envoy.extensions.upstreams.http.v3.HttpProtocolOptions": {
                        "@type": "type.googleapis.com/envoy.extensions.upstreams.http.v3.HttpProtocolOptions",
                        "use_downstream_protocol_config": {"http2_protocol_options": {}},
                    }
                }
                patched += 1
        d["data"]["envoy.yaml"] = yaml.safe_dump(cfg, sort_keys=False)
if patched != 1:
    sys.exit(f"patched {patched} clusters, want 1")
yaml.safe_dump_all(docs, sys.stdout, sort_keys=False)
