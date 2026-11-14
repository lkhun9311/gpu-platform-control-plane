# W2 and the CPU half of M1: BANKING77 intent classification and a promotion gate that a wrong model cannot pass

Date: 2026-11-14. Status: design, before any training run. Issue #570.

## Why

The MLOps gate in `experiments/mlops-lineage` promotes a synthetic `nn.Linear(8,1)` on one accuracy number (`gate.py:306`, `cand_acc >= champ_acc - 0.02`).
It shows the promotion mechanics, not that a promoted model is any good.
W2 is the real workload the MLOps track measures against, and M1 is the gate in front of promotion.
This page fixes the data, the prompt, the parser, the metrics and the gate rules before any model is trained, so no rule is chosen after its numbers are seen.

## Data

| | |
|---|---|
| Source | `PolyAI/banking77`, revision `1846984189f2bc0ac51c6fc3a600fa9e1714e0c6`, CC-BY-4.0 |
| Files | `data/train-00000-of-00001.parquet` sha256 `8dc89b87…e363a`, `data/test-00000-of-00001.parquet` sha256 `1f40f777…905341`, `README.md` sha256 `f3786a53…364e1` (label names) |
| Measured | train 10,003, test 3,080, 77 labels in each; test is exactly 40 per label; train 35 to 187 per label |
| Text length | median 46 characters, p99 216, max 433 |
| Duplicates (normalised: NFKC, lower case, whitespace collapsed) | 4 texts repeat inside train, none with conflicting labels; 7 test texts also appear in train, all with the same label |

The label names come from the dataset card at the same revision, in label-id order, and the loader refuses if it does not find exactly 77.

**Splits.**
- `test` is used as published, all 3,080 rows, so results stay comparable with other work on BANKING77.
- Train rows whose normalised text appears in test are removed (the 7 above), and repeated train texts are kept once, so nothing scored on test was seen in training.
- `dev` is 10% of what remains, drawn per label with a fixed seed (at least 3 per label); the rest is `train`.
- Every split is written with the sha256 of its rows, and every evaluation record carries those hashes. Two records with different test hashes are not comparable, and the gate refuses to compare them.

## Task, prompt and parser

The model is Qwen2.5-1.5B-Instruct (Apache-2.0), adapted with LoRA; the base model is evaluated zero-shot on the same prompt as a control.

- The prompt gives the 77 label names in id order and the customer message, and asks for one JSON object `{"label": "<name>"}` and nothing else.
- The prompt template and the label list are hashed into every record.
- **Strict parser.** An answer counts only if, after trimming whitespace, it is a single JSON object whose only key is `label` and whose value is exactly one of the 77 names. Anything else is a `format_error`, scored as wrong, never dropped. A generation stopped by the length limit is `truncated`, also scored as wrong. Dropping these would let a model that answers badly in form look better than one that answers everything.

## Metrics

- **Primary:** macro-F1 over the 77 labels on test, with format errors and truncations counted as wrong predictions.
- Also recorded: accuracy, format-error rate, truncation rate, per-label F1.
- **Comparison between two models is paired.** Both are scored on the same test rows, and the difference in macro-F1 gets a 95% interval from a paired bootstrap over test rows (2,000 resamples, fixed seed). For a model trained with several seeds, the interval is over the pooled per-seed differences, and the per-seed values are reported too.

## Controls

- **TF-IDF control.** Word 1–2 gram TF-IDF with a linear classifier (scikit-learn), its regularisation chosen on `dev` only, scored by the same evaluator on the same test rows. If the LoRA model does not beat it, that is the result, recorded as such.
- **Untrained base.** Qwen2.5-1.5B-Instruct zero-shot on the same prompt (GPU).
- **Negative controls the gate must refuse** (fixtures, run in its own tests):
  1. a candidate whose label map is shuffled, so its answers are well-formed and wrong;
  2. a candidate whose template is broken, so most answers are format errors;
  3. a candidate scored on a different test set (different hash);
  4. a candidate record that lacks a required field.

## The M1 gate

The gate reads evaluation records (MLflow run metrics and tags, or the same fields as JSON in tests) and decides `promote` or `refuse` with every reason that applies. It never promotes on a missing field.

| Rule | Refuses when |
|---|---|
| Comparable | the candidate, the champion and the control do not share the data revision, the split hashes, the prompt hash and the parser version |
| Well formed | format errors plus truncations exceed 1% of test rows |
| Beats the control | the lower bound of the paired interval of candidate minus TF-IDF macro-F1 is not above 0 |
| Not worse than the champion | the lower bound of the paired interval of candidate minus champion macro-F1 is below −0.01 (one point) |
| Served as trained | when the candidate is to be served: label agreement between the trained adapter and the served model is below 99.5% on test, or the teacher-forced log-probability gap exceeds its bound (set from a measured run before it is enforced) |
| Performance | when both have it: served p95 latency or throughput is more than 10% worse than the champion's on the same load |

With no champion, the champion rule is skipped and the record says so.
The thresholds are proposals fixed here before any model is trained; changing one later is a new version of this page, not an edit.

## What is CPU and what is GPU

| CPU, this issue | GPU, later and approved separately |
|---|---|
| download pinned files, split, dedupe, hash | LoRA SFT of Qwen2.5-1.5B-Instruct, several seeds |
| label names and prompt rendering | zero-shot base evaluation |
| strict parser and evaluator, bootstrap | adapter vs merged vs vLLM parity, served latency |
| TF-IDF control trained and scored | |
| gate rules over records, with the negative-control fixtures | |

## Layout

`experiments/mlops-w2/`: `data.py` (download, split, hashes), `labels.py`, `prompt.py`, `evaluate.py` (parser, metrics, paired bootstrap), `tfidf.py`, `gate.py`, `tests/`, and `requirements.txt` with exact versions.
It does not change `experiments/mlops-lineage`, which stays the record of the earlier promotion run.

## Not claimed

- That LoRA beats TF-IDF on this task. It may not; BANKING77 is known to be well served by simple classifiers.
- Anything about served behaviour before the GPU runs.
