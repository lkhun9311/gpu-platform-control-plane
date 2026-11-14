"""W2's TF-IDF control: tuned on dev, fit on train only, scored on test into an evaluation artifact the M1 gate reads.

Design: docs/superpowers/specs/2026-11-14-w2-banking77-and-m1-gate-design.md (v2), "Controls".
Needs scikit-learn (requirements.txt); the gate and evaluator it feeds do not.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path

import evaluate as ev
import gate

C_GRID = (0.1, 0.3, 1.0, 3.0, 10.0, 30.0, 100.0)
VECTORIZER = {"analyzer": "word", "ngram_range": (1, 2), "sublinear_tf": True, "lowercase": True}
CLASSIFIER = {"solver": "lbfgs", "max_iter": 5000}


def read_split(path: Path) -> list[tuple[str, int]]:
    with path.open(encoding="utf-8") as f:
        return [(r["text"], r["label"]) for r in map(json.loads, f)]


def fit(train: list[tuple[str, int]], c: float):
    from sklearn.feature_extraction.text import TfidfVectorizer  # noqa: PLC0415
    from sklearn.linear_model import LogisticRegression  # noqa: PLC0415
    from sklearn.pipeline import make_pipeline  # noqa: PLC0415

    model = make_pipeline(TfidfVectorizer(**VECTORIZER), LogisticRegression(C=c, **CLASSIFIER))
    model.fit([t for t, _ in train], [label for _, label in train])
    return model


def choose_c(train: list[tuple[str, int]], dev: list[tuple[str, int]]) -> tuple[float, dict[float, float]]:
    """The C with the best dev accuracy, ties to the smaller C; the vectorizer is fit on train only every time."""
    scores = {}
    for c in C_GRID:
        predicted = fit(train, c).predict([t for t, _ in dev])
        scores[c] = sum(int(p) == label for p, (_, label) in zip(predicted, dev, strict=True)) / len(dev)
    best = max(scores.values())
    return min(c for c, s in scores.items() if s == best), scores


def artifact(test: list[tuple[str, int]], predicted: list[int], names: list[str], manifest_sha: str, params: dict) -> gate.Artifact:
    """The test predictions as an evaluation artifact. Row ids are the test file's line numbers."""
    rows = [{"id": f"test-{i:04d}", "gold": names[label], "raw": names[int(p)], "finish": "stop", "outcome": "ok",
             "label": names[int(p)]} for i, ((_, label), p) in enumerate(zip(test, predicted, strict=True))]
    digest = hashlib.sha256(json.dumps(params, sort_keys=True).encode()).hexdigest()
    manifest = {
        "model": {"kind": "tfidf", "params_sha256": digest, "label_map_sha256": gate.label_map_digest(names)},
        "params": params,
        "test_manifest_sha256": manifest_sha,
        "label_map_sha256": gate.label_map_digest(names),
        "predictions_sha256": gate.predictions_digest(rows),
    }
    return gate.Artifact(manifest, rows)


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--splits", type=Path, required=True, help="the directory data.py wrote")
    p.add_argument("--out", type=Path, required=True)
    args = p.parse_args(argv)
    manifest = json.loads((args.splits / "manifest.json").read_text(encoding="utf-8"))
    names = manifest["labels"]
    train, dev, test = (read_split(args.splits / f"{s}.jsonl") for s in ("train", "dev", "test"))
    c, dev_scores = choose_c(train, dev)
    predicted = fit(train, c).predict([t for t, _ in test])
    params = {"vectorizer": {**VECTORIZER, "ngram_range": list(VECTORIZER["ngram_range"])}, "classifier": CLASSIFIER,
              "c": c, "fit_on": "train", "train_sha256": manifest["splits"]["train"]["sha256"]}
    art = artifact(test, list(predicted), names, manifest["splits"]["test"]["sha256"], params)
    args.out.mkdir(parents=True, exist_ok=True)
    (args.out / "manifest.json").write_text(json.dumps(art.manifest, indent=2) + "\n", encoding="utf-8")
    with (args.out / "predictions.jsonl").open("w", encoding="utf-8") as f:
        for row in art.rows:
            f.write(json.dumps(row, sort_keys=True) + "\n")
    gold = [r["gold"] for r in art.rows]
    summary = ev.summarise(gold, [r["label"] for r in art.rows], names)
    print(json.dumps({"c": c, "dev_accuracy": dev_scores, "test": {k: v for k, v in summary.items()
                                                                   if k != "per_label_recall"},
                      "worst_label": min(summary["per_label_recall"].items(), key=lambda kv: kv[1])}, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
