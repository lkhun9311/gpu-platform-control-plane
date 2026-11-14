"""W2's evaluator: the strict answer parser and the metrics every model, control and gate reads.

Design: docs/superpowers/specs/2026-11-14-w2-banking77-and-m1-gate-design.md. Standard library only.
"""

from __future__ import annotations

import json
import random

# The two ways an answer can fail before its label is even compared. Both are scored as wrong, never dropped: dropping
# them would let a model that answers badly in form score better than one that answers every row.
FORMAT_ERROR = "format_error"
TRUNCATED = "truncated"


def parse_answer(text: str, names: list[str], *, truncated: bool = False) -> str:
    """The label an answer names, or FORMAT_ERROR / TRUNCATED.

    An answer counts only if, trimmed, it is one JSON object whose only key is "label" and whose value is exactly one
    of the label names. A generation stopped by the length limit is TRUNCATED whatever it holds, because its JSON
    may happen to close on a label the model had not finished choosing.
    """
    if truncated:
        return TRUNCATED
    try:
        obj = json.loads(text.strip(), object_pairs_hook=_refuse_repeated_keys)
    except (json.JSONDecodeError, ValueError):
        return FORMAT_ERROR
    if not isinstance(obj, dict) or set(obj) != {"label"}:
        return FORMAT_ERROR
    label = obj["label"]
    if not isinstance(label, str) or label not in names:
        return FORMAT_ERROR
    return label


def _refuse_repeated_keys(pairs: list[tuple[str, object]]) -> dict:
    """json.loads keeps the last of two equal keys, so {"label": "a", "label": "b"} would parse as b; refuse it instead."""
    keys = [k for k, _ in pairs]
    if len(keys) != len(set(keys)):
        raise ValueError(f"repeated keys {keys}")
    return dict(pairs)


def per_label_recall(gold: list[str], predicted: list[str], names: list[str]) -> dict[str, float]:
    """The share of each label's rows answered with that label; the gate's per-label floor reads this."""
    hits = dict.fromkeys(names, 0)
    total = dict.fromkeys(names, 0)
    for g, p in zip(gold, predicted, strict=True):
        if g not in total:
            raise ValueError(f"gold label {g!r} is not one of the label names")
        total[g] += 1
        hits[g] += p == g
    return {n: hits[n] / total[n] if total[n] else 0.0 for n in names}


def per_label_f1(gold: list[str], predicted: list[str], names: list[str]) -> dict[str, float]:
    """F1 of each label; a parse failure is a prediction of no label, so it costs the gold label its recall."""
    if len(gold) != len(predicted):
        raise ValueError(f"{len(gold)} gold labels and {len(predicted)} predictions")
    tp = dict.fromkeys(names, 0)
    fp = dict.fromkeys(names, 0)
    fn = dict.fromkeys(names, 0)
    for g, p in zip(gold, predicted, strict=True):
        if g not in tp:
            raise ValueError(f"gold label {g!r} is not one of the label names")
        if p == g:
            tp[g] += 1
            continue
        fn[g] += 1
        if p in fp:
            fp[p] += 1
    out = {}
    for n in names:
        denom = 2 * tp[n] + fp[n] + fn[n]
        # A label with no gold rows and no predictions has no F1 to speak of; on BANKING77 test every label has 40 rows.
        out[n] = 2 * tp[n] / denom if denom else 0.0
    return out


def macro_f1(gold: list[str], predicted: list[str], names: list[str]) -> float:
    """The unweighted mean of per-label F1 over all label names, the design page's primary metric."""
    f1 = per_label_f1(gold, predicted, names)
    return sum(f1.values()) / len(names)


def summarise(gold: list[str], predicted: list[str], names: list[str]) -> dict:
    """Every metric a record carries for one model on one split.

    Accuracy is the primary metric (design v2): on a test with the same number of rows per label it equals
    macro-averaged recall, and it charges a format error exactly what it charges a wrong label. Macro-F1 does not, so a
    model could raise its macro-F1 by answering badly in form instead of wrongly in content.
    """
    n = len(gold)
    return {
        "rows": n,
        "accuracy": sum(g == p for g, p in zip(gold, predicted, strict=True)) / n,
        "macro_f1": macro_f1(gold, predicted, names),
        "not_ok_rows": sum(p in (FORMAT_ERROR, TRUNCATED) for p in predicted),
        "format_error_rows": predicted.count(FORMAT_ERROR),
        "truncated_rows": predicted.count(TRUNCATED),
        "per_label_recall": per_label_recall(gold, predicted, names),
    }


BOOTSTRAP_RESAMPLES = 10_000
BOOTSTRAP_SEED = 20261114


def paired_accuracy_interval(gold: dict[str, str], a: dict[str, str], b: dict[str, str],
                             resamples: int = BOOTSTRAP_RESAMPLES, seed: int = BOOTSTRAP_SEED) -> tuple[float, float]:
    """95% interval of accuracy(a) - accuracy(b), from a stratified paired bootstrap over row ids.

    Rows are paired by id, never by position, so two files in different orders give the same answer. Each resample
    draws, within every label, as many rows as that label has, with replacement, so every resample keeps the test's
    per-label balance. The interval is the nearest-rank 2.5th and 97.5th percentiles.
    """
    if set(gold) != set(a) or set(gold) != set(b):
        raise ValueError("the two models were not scored on the same row ids")
    diffs: dict[str, list[int]] = {}
    for rid in sorted(gold):
        g = gold[rid]
        diffs.setdefault(g, []).append((a[rid] == g) - (b[rid] == g))
    n = len(gold)
    # A label where the two models never disagree adds zero to every resample and is skipped for speed.
    varying = [d for d in diffs.values() if any(d)]
    rng = random.Random(seed)
    stats = []
    for _ in range(resamples):
        total = 0
        for d in varying:
            total += sum(rng.choices(d, k=len(d)))
        stats.append(total / n)
    stats.sort()
    lo = stats[max(0, -(-25 * resamples // 1000) - 1)]
    hi = stats[min(resamples - 1, -(-975 * resamples // 1000) - 1)]
    return lo, hi
