"""M1, the CPU half: decide whether one evaluated W2 model artifact is offline_qualified.

Design: docs/superpowers/specs/2026-11-14-w2-banking77-and-m1-gate-design.md (v2). Standard library only.

The gate takes evaluation artifacts, not scores. Each artifact is a manifest and one prediction row per test row id,
and every number the decision rests on is recomputed here from those rows: an interval somebody else computed, or an
aggregate copied into a run, cannot reproduce a paired comparison and cannot be checked against the rows.
serve_approved is a later state with its own required evidence; nothing here can grant it.
"""

from __future__ import annotations

import hashlib
import json
import math
from dataclasses import dataclass, field

import evaluate as ev

OFFLINE_QUALIFIED = "offline_qualified"
REFUSE = "refuse"
INSUFFICIENT = "insufficient_evidence"

OUTCOMES = ("ok", ev.FORMAT_ERROR, ev.TRUNCATED)
MAX_NOT_OK_SHARE = 0.01
MIN_LABEL_RECALL = 0.50
NONINFERIORITY_MARGIN = -0.01

# Reasons, spelled once so the tests and the record agree.
INTEGRITY = "integrity"
NOT_COMPARABLE = "not_comparable"
NOT_BOUND = "not_bound_to_promoted_model"
LABEL_MAP = "label_map_differs"
MALFORMED = "too_many_not_ok_rows"
COLLAPSED = "collapsed_label"
TEST_BUDGET = "test_budget_spent"


@dataclass(frozen=True)
class Registered:
    """What the design page fixed before any model was trained: the test rows and their gold labels, and the hashes."""

    test_manifest_sha256: str
    label_map_sha256: str
    gold: dict[str, str]  # row id -> gold label name
    names: list[str]


@dataclass
class Artifact:
    """One model's evaluation: its manifest and its prediction rows."""

    manifest: dict
    rows: list[dict]


@dataclass
class Decision:
    decision: str
    reasons: list[str] = field(default_factory=list)
    notes: list[str] = field(default_factory=list)
    numbers: dict = field(default_factory=dict)


def predictions_digest(rows: list[dict]) -> str:
    """sha256 over the rows sorted by id, each as canonical JSON, so a reordered file has the same digest."""
    h = hashlib.sha256()
    for row in sorted(rows, key=lambda r: str(r.get("id"))):
        h.update(json.dumps(row, sort_keys=True, ensure_ascii=False).encode())
        h.update(b"\n")
    return h.hexdigest()


def label_map_digest(names: list[str]) -> str:
    """sha256 of the id -> name map, the ontology every prediction is read against."""
    return hashlib.sha256(json.dumps(list(enumerate(names))).encode()).hexdigest()


def _predictions(art: Artifact, reg: Registered, who: str) -> tuple[dict[str, str] | None, list[str]]:
    """The predicted label per row id, or None and the reasons the artifact cannot be read."""
    reasons = []
    m = art.manifest
    if predictions_digest(art.rows) != m.get("predictions_sha256"):
        reasons.append(f"{INTEGRITY}: {who} predictions do not match their manifest's sha256")
    ids = [r.get("id") for r in art.rows]
    if len(ids) != len(set(ids)):
        reasons.append(f"{INTEGRITY}: {who} repeats a row id")
    if set(ids) != set(reg.gold):
        reasons.append(f"{INTEGRITY}: {who} rows are not exactly the {len(reg.gold)} registered test row ids")
    if m.get("test_manifest_sha256") != reg.test_manifest_sha256 or m.get("label_map_sha256") != reg.label_map_sha256:
        reasons.append(f"{NOT_COMPARABLE}: {who} was not scored on the registered test rows and label map")
    pred: dict[str, str] = {}
    for r in art.rows:
        rid, outcome, label = r.get("id"), r.get("outcome"), r.get("label")
        if rid in reg.gold and r.get("gold") != reg.gold[rid]:
            reasons.append(f"{INTEGRITY}: {who} row {rid} carries gold {r.get('gold')!r}, registered {reg.gold[rid]!r}")
            break
        if outcome not in OUTCOMES or (outcome == "ok") != (label is not None) or (label is not None and label not in reg.names):
            reasons.append(f"{INTEGRITY}: {who} row {rid} has an inconsistent outcome {outcome!r} / label {label!r}")
            break
        pred[rid] = label if outcome == "ok" else outcome
    return (None if reasons else pred), reasons


def _finite_count(value) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) or (
        isinstance(value, float) and math.isfinite(value) and value.is_integer())


def decide(candidate: Artifact, controls: dict[str, Artifact], reg: Registered, *, promote: dict,
           champion: Artifact | None = None, reference: Artifact | None = None,
           resamples: int = ev.BOOTSTRAP_RESAMPLES) -> Decision:
    """offline_qualified, refuse with every reason that applies, or insufficient_evidence."""
    refuse: list[str] = []
    unsure: list[str] = []
    notes: list[str] = []
    numbers: dict = {}

    cand, why = _predictions(candidate, reg, "candidate")
    refuse += why
    m = candidate.manifest

    # Bound to the model that would be promoted: the passing evaluation must name exactly that artifact.
    model = m.get("model") or {}
    for key in ("base_revision", "adapter_sha256", "tokenizer_revision", "inference_manifest_sha256"):
        if not model.get(key) or model.get(key) != promote.get(key):
            refuse.append(f"{NOT_BOUND}: {key} of the evaluation and of the artifact to promote differ or are missing")
    if model.get("label_map_sha256") != reg.label_map_sha256:
        refuse.append(f"{LABEL_MAP}: the candidate was trained or served with a different label map")

    index, budget = m.get("test_evaluation_index"), m.get("plan_test_budget")
    if not (_finite_count(index) and _finite_count(budget)) or index < 1 or budget < 1:
        refuse.append(f"{INTEGRITY}: test_evaluation_index and plan_test_budget must be positive whole numbers")
    elif index > budget:
        refuse.append(f"{TEST_BUDGET}: test evaluation {int(index)} of a plan that registered {int(budget)}")

    if cand is not None:
        gold_list = [reg.gold[r] for r in sorted(reg.gold)]
        pred_list = [cand[r] for r in sorted(reg.gold)]
        summary = ev.summarise(gold_list, pred_list, reg.names)
        numbers["candidate"] = {k: v for k, v in summary.items() if k != "per_label_recall"}
        if summary["not_ok_rows"] > MAX_NOT_OK_SHARE * len(reg.gold):
            refuse.append(f"{MALFORMED}: {summary['not_ok_rows']} of {len(reg.gold)} rows are not a label")
        worst = min(summary["per_label_recall"].items(), key=lambda kv: kv[1])
        numbers["candidate"]["worst_label"] = list(worst)
        if worst[1] < MIN_LABEL_RECALL:
            low = sorted(n for n, r in summary["per_label_recall"].items() if r < MIN_LABEL_RECALL)
            refuse.append(f"{COLLAPSED}: recall below {MIN_LABEL_RECALL} for {low}")

        for name in ("tfidf", "pretrained"):
            ctl = controls.get(name)
            if ctl is None:
                refuse.append(f"does_not_beat_{name}: the {name} control is missing")
                continue
            other, why = _predictions(ctl, reg, f"{name} control")
            if other is None:
                refuse += why
                continue
            lo, hi = ev.paired_accuracy_interval(reg.gold, cand, other, resamples=resamples)
            numbers[f"minus_{name}"] = [lo, hi]
            if lo <= 0:
                refuse.append(f"does_not_beat_{name}: interval of the accuracy difference is [{lo:.4f}, {hi:.4f}]")

        for name, base in (("champion", champion), ("reference", reference)):
            if base is None:
                notes.append(f"no {name}: the rule against it was not applied")
                continue
            other, why = _predictions(base, reg, name)
            if other is None:
                refuse += why
                continue
            lo, hi = ev.paired_accuracy_interval(reg.gold, cand, other, resamples=resamples)
            numbers[f"minus_{name}"] = [lo, hi]
            if hi < NONINFERIORITY_MARGIN:
                refuse.append(f"worse_than_{name}: interval [{lo:.4f}, {hi:.4f}] lies below {NONINFERIORITY_MARGIN}")
            elif lo < NONINFERIORITY_MARGIN:
                # Not shown to be no worse is not shown to be worse; the record must keep the two apart.
                unsure.append(f"not_shown_noninferior_to_{name}: interval [{lo:.4f}, {hi:.4f}] straddles {NONINFERIORITY_MARGIN}")

    if refuse:
        return Decision(REFUSE, refuse + unsure, notes, numbers)
    if unsure:
        return Decision(INSUFFICIENT, unsure, notes, numbers)
    return Decision(OFFLINE_QUALIFIED, [], notes, numbers)
