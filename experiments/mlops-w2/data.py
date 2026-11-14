"""BANKING77 for workload W2: pinned files, the 77 label names, and the train / dev / test splits.

Design: docs/superpowers/specs/2026-11-14-w2-banking77-and-m1-gate-design.md.

Everything but reading the parquet files is standard-library Python, so the split rules are tested by scorer-tests
without third-party packages. pyarrow is imported only by read_parquet.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import random
import re
import sys
import unicodedata
import urllib.request
from pathlib import Path

REPO = "PolyAI/banking77"
# The revision every number in the design page was measured at; a later upload is a different dataset.
REVISION = "1846984189f2bc0ac51c6fc3a600fa9e1714e0c6"
# A file that does not match is refused, never used, so a silently replaced upload cannot change what is scored.
FILES = {
    "data/train-00000-of-00001.parquet": "8dc89b87a188509c42cce5a086e8f7c1ff4a225bdd9ae3f23e6cdfa5806e363a",
    "data/test-00000-of-00001.parquet": "1f40f777c33f0edfa6c530ff84fe2878db6490838c12d22d036f626948905341",
    "README.md": "f3786a5327fd6533c7c0ff3ff654e20ee3d1261d2fa41667381f59a2e42364e1",
}
LABELS = 77
DEV_FRACTION = 0.1
MIN_DEV_PER_LABEL = 3
SPLIT_SEED = 20261114


class DataError(Exception):
    """Input that does not match what the design page fixed; the run must stop rather than score something else."""


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def download(dest: Path, base: str = f"https://huggingface.co/datasets/{REPO}/resolve/{REVISION}") -> dict[str, Path]:
    """Fetch the pinned files into dest, or reuse ones already there, and refuse any whose sha256 differs."""
    out = {}
    for name, want in FILES.items():
        path = dest / Path(name).name
        if not path.exists():
            dest.mkdir(parents=True, exist_ok=True)
            with urllib.request.urlopen(f"{base}/{name}", timeout=60) as resp:  # noqa: S310 - fixed https or test file URL
                path.write_bytes(resp.read())
        got = sha256_file(path)
        if got != want:
            raise DataError(f"{name}: sha256 {got}, pinned {want}; refusing a file that is not the one measured")
        out[name] = path
    return out


def label_names(readme: str) -> list[str]:
    """The class names from the dataset card's `names:` block, in label-id order; exactly 77 contiguous ids or refused."""
    names: dict[int, str] = {}
    inside = False
    for line in readme.splitlines():
        if line.strip() == "names:":
            inside = True
            continue
        if inside:
            m = re.fullmatch(r"\s+'?(\d+)'?:\s*(\S+)\s*", line)
            if not m:
                break
            names[int(m.group(1))] = m.group(2)
    if sorted(names) != list(range(LABELS)):
        raise DataError(f"the card names {len(names)} labels with ids {sorted(names)[:3]}..., not ids 0..{LABELS - 1}")
    ordered = [names[i] for i in range(LABELS)]
    if len(set(ordered)) != LABELS:
        raise DataError("two labels share a name, so a name cannot identify a label")
    return ordered


def read_parquet(path: Path) -> list[tuple[str, int]]:
    """Rows as (text, label id); the only function here that needs a third-party package."""
    import pyarrow.parquet as pq  # noqa: PLC0415 - kept out of the standard-library tests

    table = pq.read_table(path).to_pydict()
    return list(zip(table["text"], table["label"], strict=True))


def normalise(text: str) -> str:
    """The form duplicates are judged in: NFKC, lower case, runs of whitespace collapsed."""
    return re.sub(r"\s+", " ", unicodedata.normalize("NFKC", text).strip().lower())


def build_splits(train: list[tuple[str, int]], test: list[tuple[str, int]], seed: int = SPLIT_SEED):
    """Train, dev and test as the design page fixes them, and a report of what was removed and why.

    Test is kept whole. A train row whose text is also in test is removed, so nothing scored was trained on; a text
    repeated inside train is kept once. Dev is a per-label fraction of what remains, at least MIN_DEV_PER_LABEL each.
    """
    if any(not 0 <= label < LABELS for _, label in train + test):
        raise DataError("a label id outside 0..76")
    in_test = {normalise(t) for t, _ in test}
    seen: dict[str, int] = {}
    leaked = repeated = 0
    kept: list[tuple[str, int]] = []
    for text, label in train:
        key = normalise(text)
        if key in in_test:
            leaked += 1
            continue
        if key in seen:
            if seen[key] != label:
                raise DataError(f"train text {text!r} carries labels {seen[key]} and {label}")
            repeated += 1
            continue
        seen[key] = label
        kept.append((text, label))

    by_label: dict[int, list[tuple[str, int]]] = {}
    for row in kept:
        by_label.setdefault(row[1], []).append(row)
    if sorted(by_label) != list(range(LABELS)):
        raise DataError(f"train covers {len(by_label)} labels after removal, not {LABELS}")
    rng = random.Random(seed)
    new_train, dev = [], []
    for label in range(LABELS):
        rows = sorted(by_label[label])
        rng.shuffle(rows)
        n_dev = max(MIN_DEV_PER_LABEL, round(len(rows) * DEV_FRACTION))
        if n_dev >= len(rows):
            raise DataError(f"label {label} has {len(rows)} train rows, too few to hold {n_dev} out for dev")
        dev.extend(rows[:n_dev])
        new_train.extend(rows[n_dev:])
    report = {"removed_in_test": leaked, "removed_repeated": repeated, "seed": seed}
    return {"train": new_train, "dev": dev, "test": list(test)}, report


def split_hash(rows: list[tuple[str, int]]) -> str:
    """sha256 over the rows in order, so two records that disagree on any row or its order are not comparable."""
    h = hashlib.sha256()
    for text, label in rows:
        h.update(json.dumps([label, text], ensure_ascii=False).encode())
        h.update(b"\n")
    return h.hexdigest()


def write_splits(splits: dict, report: dict, names: list[str], out: Path) -> dict:
    """Each split as JSONL beside a manifest holding the counts, the hashes, the revision and the label names."""
    out.mkdir(parents=True, exist_ok=True)
    manifest = {"repo": REPO, "revision": REVISION, "files": FILES, "labels": names, "removed": report, "splits": {}}
    for name, rows in splits.items():
        with (out / f"{name}.jsonl").open("w", encoding="utf-8") as f:
            for text, label in rows:
                f.write(json.dumps({"text": text, "label": label}, ensure_ascii=False) + "\n")
        manifest["splits"][name] = {"rows": len(rows), "sha256": split_hash(rows)}
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    return manifest


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--cache", type=Path, required=True, help="where the pinned files are downloaded and reused")
    p.add_argument("--out", type=Path, required=True, help="where the splits and manifest are written")
    args = p.parse_args(argv)
    files = download(args.cache)
    names = label_names(files["README.md"].read_text(encoding="utf-8"))
    splits, report = build_splits(read_parquet(files["data/train-00000-of-00001.parquet"]),
                                  read_parquet(files["data/test-00000-of-00001.parquet"]))
    manifest = write_splits(splits, report, names, args.out)
    print(json.dumps({"removed": report, "splits": manifest["splits"]}, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
