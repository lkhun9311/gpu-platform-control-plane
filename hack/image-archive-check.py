#!/usr/bin/env python3
"""Refuse a `docker save` archive that a kind node's import will fail on, before anything is bought.

Usage: image-archive-check.py ARCHIVE[.tar|.tar.gz]...

kind imports with `ctr images import --all-platforms`, which tries to unpack every manifest in the archive's
index.json as an image. A Dockerfile of only `FROM busybox:1.36` produces no new manifest: the image is the
official image's amd64 manifest itself, so `docker save` also writes the attestation manifest that names it as
its subject (an in-toto layer). The node then fails with "mismatched image rootfs and manifest layers"; that
voided the first paid fault-reaction session on 2026-10-26, three minutes after launch.

An archive passes when its index holds exactly one manifest, no entry names a subject, and no layer is in-toto.
"""
import gzip
import io
import json
import sys
import tarfile


def problems(path):
    raw = open(path, "rb").read()
    if raw[:2] == b"\x1f\x8b":
        raw = gzip.decompress(raw)
    with tarfile.open(fileobj=io.BytesIO(raw)) as tar:
        names = set(tar.getnames())

        def blob(digest):
            return json.load(tar.extractfile("blobs/" + digest.replace(":", "/")))

        if "index.json" not in names:
            return ["no index.json, so the archive is not an OCI layout kind can import"]
        entries = json.load(tar.extractfile("index.json")).get("manifests", [])
        found = []
        if len(entries) != 1:
            found.append(f"{len(entries)} manifests in index.json, not 1")
        for e in entries:
            subject = (e.get("annotations") or {}).get("io.containerd.manifest.subject")
            if subject:
                found.append(f"{e['digest'][:19]} is an attestation of {subject[:19]}")
                continue
            m = blob(e["digest"])
            for layer in m.get("layers", []):
                if "in-toto" in layer.get("mediaType", ""):
                    found.append(f"{e['digest'][:19]} carries an in-toto layer")
        return found


def main(paths):
    if not paths:
        print("usage: image-archive-check.py ARCHIVE...", file=sys.stderr)
        return 2
    bad = 0
    for p in paths:
        try:
            found = problems(p)
        except Exception as exc:  # an unreadable archive is a refusal, not a pass
            found = [f"unreadable: {exc}"]
        if found:
            bad += 1
            print(f"{p}: refused: " + "; ".join(found))
        else:
            print(f"{p}: one manifest, no attestation")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
