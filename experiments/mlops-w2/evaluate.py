"""W2's evaluator: the strict answer parser and the metrics every model, control and gate reads.

Design: docs/superpowers/specs/2026-11-14-w2-banking77-and-m1-gate-design.md. Standard library only.
"""

from __future__ import annotations

import json

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
        obj = json.loads(text.strip())
    except (json.JSONDecodeError, ValueError):
        return FORMAT_ERROR
    if not isinstance(obj, dict) or set(obj) != {"label"}:
        return FORMAT_ERROR
    label = obj["label"]
    if not isinstance(label, str) or label not in names:
        return FORMAT_ERROR
    return label


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
    """Every metric a record carries for one model on one split."""
    n = len(gold)
    return {
        "rows": n,
        "macro_f1": macro_f1(gold, predicted, names),
        "accuracy": sum(g == p for g, p in zip(gold, predicted, strict=True)) / n,
        "format_error_rate": predicted.count(FORMAT_ERROR) / n,
        "truncation_rate": predicted.count(TRUNCATED) / n,
    }
