# W2 and the CPU half of M1: BANKING77 intent classification and a promotion gate that a wrong model cannot pass

Date: 2026-11-14. Status: **design v2**, before any training run. Issue #570.
v1 was attacked cold by codex `gpt-6-astra` (high) before any code beyond the data split existed; the attack and how v2 answers it are at the end. The three numeric counterexamples it gave were re-computed here before v2 relied on them.

## Why

The MLOps gate in `experiments/mlops-lineage` promotes a synthetic `nn.Linear(8,1)` on one accuracy number (`gate.py:306`, `cand_acc >= champ_acc - 0.02`).
It shows the promotion mechanics, not that a promoted model is any good.
W2 is the real workload the MLOps track measures against, and M1 is the gate in front of promotion.
This page fixes the data, the output contract, the metrics and the gate rules before any model is trained, so no rule is chosen after its numbers are seen.

## Data

| | |
|---|---|
| Source | `PolyAI/banking77`, revision `1846984189f2bc0ac51c6fc3a600fa9e1714e0c6`, CC-BY-4.0 |
| Files and sha256 | as pinned in `experiments/mlops-w2/data.py` (`FILES`); a file that differs is refused |
| Measured | train 10,003, test 3,080, 77 labels in each; test is exactly 40 per label; train 35 to 187 per label |
| Text length | median 46 characters, p99 216, max 433 |
| Duplicates (normalised: NFKC, lower case, whitespace collapsed) | 4 texts repeat inside train, none with conflicting labels; 7 test texts also appear in train, all with the same label |

The label names come from the dataset card at the same revision, in label-id order; the loader refuses unless it finds exactly ids 0 to 76 with 77 distinct names.

**Splits** (the algorithm is `build_splits` in `data.py`, seed `20261114`; the code at the commit that adds this page is the definition).
- `test` is used as published, all 3,080 rows.
- Train rows whose normalised text appears in test are removed (7), and a text repeated inside train is kept at its first occurrence (4 removed).
- `dev` is 10% of what remains per label, rounded, at least 3, drawn by `random.Random(20261114)` over each label's rows sorted by text.
- Result: train 8,992, dev 1,000, test 3,080. Each split's sha256 over its rows in order is in the manifest `data.py` writes, and the registered test hash is `9e6d177c6a52281c0d18980012dcd5042711c0114f51ca8e05b02520fb47b5c0`.

**What the de-duplication guarantees, and what it does not.** No normalised-identical text is shared between this downstream train/dev and the published test. It says nothing about near-duplicates or paraphrases, and nothing about what the pretrained model saw before; contamination of Qwen2.5 by BANKING77 is unknown. Because train is de-duplicated and dev is held out, results are not directly comparable with work that trained on all 10,003 rows.

## Output contract

The model is Qwen2.5-1.5B-Instruct, revision `989aa7980e4cf806f80c7fef2b1adb7bc71aa306` (Apache-2.0), adapted with LoRA. The same model with no BANKING77 training, on the same prompt, is the **pretrained control**.

- The prompt template is a committed file (`experiments/mlops-w2/prompt.py`), hashed into every record, and lists the 77 names in id order.
- Generation: greedy, `max_new_tokens` 32, stop at end of turn. These are part of the inference manifest the record carries.
- **Each test row yields exactly one outcome, and the outcomes exclude each other:** `ok` (a label), `truncated` (the engine reports it stopped on the length limit; checked first), `format_error` (anything else, including an empty answer, a timeout or a transport failure, each recorded with its raw text or error).
- `ok` requires the trimmed answer to be one JSON object with exactly the key `label`, appearing once, whose value is exactly one of the 77 names. Duplicate keys are refused; Python's `json.loads` would otherwise keep the last one.

## Metrics

- **Primary: accuracy on test, every row counted, every non-`ok` outcome wrong.** Test has exactly 40 rows per label, so accuracy equals macro-averaged recall and weighs every intent equally.
  v1 used macro-F1. Under macro-F1 a format error costs only the gold label's recall, while a wrong label also costs another label's precision, so 30 rows emitted as format errors scored 99.22% against 98.87% for the same 30 rows given a wrong label (computed here); accuracy scores both 99.03%. Macro-F1 is still recorded.
- **Per-label recall** for each of the 77 labels, used by the floor rule below.
- **Paired comparison of two models** is on the same test row ids. The interval for a difference in accuracy is a stratified paired bootstrap: each resample draws 40 rows with replacement within each label, keeping the design's per-label balance; 10,000 resamples; seed `20261114`; percentile interval at 2.5% and 97.5% using the nearest-rank rule. The gate recomputes it from the rows; it never reads an interval someone else computed.

## Controls

- **TF-IDF control.** `TfidfVectorizer(analyzer="word", ngram_range=(1, 2), sublinear_tf=True, lowercase=True)` and `LogisticRegression(solver="lbfgs", max_iter=5000)`; `C` from {0.1, 0.3, 1, 3, 10, 30, 100} by dev accuracy, ties to the smaller `C`; the vectorizer and classifier are fit on train only, for selection and for the final model alike. It is scored on test by the same evaluator. A weak control would make beating it meaningless, so this one is tuned; if the LoRA model does not beat it, that is the result.
  **Measured 2026-11-14** (`experiments/mlops-w2/results/tfidf-control/`, the test evaluation logged in `test-ledger.jsonl`): dev accuracy by `C` was 0.701, 0.808, 0.870, 0.884, 0.890, 0.892, 0.899, so `C` = 100, the top of the registered grid. Because the choice sat on the grid's edge, `C` = 300 and 1,000 were then scored on dev only, as a diagnostic that changes nothing registered: 0.889 and 0.886, so 100 is the peak and the control is not under-tuned by the grid. On test: **accuracy 0.8886**, macro-F1 0.8890, no non-`ok` rows, lowest per-label recall 0.70 (`wrong_exchange_rate_for_cash_withdrawal`). This is the bar a LoRA candidate's paired interval must clear.
- **Pretrained control.** As above (GPU).
- **Fixed reference.** The first model this gate promotes becomes the fixed reference; later candidates are also compared with it, so small allowed losses cannot accumulate.

## Selection happens on dev; test is spent deliberately

Every choice — LoRA hyperparameters within a budget registered before the GPU run, seed, checkpoint, prompt variant — is made on dev. Test is evaluated only for a frozen candidate, and each test evaluation is appended to a ledger (`test-ledger.jsonl`: candidate digest, time, purpose). A plan registers how many candidates it will take to test; a candidate beyond that number is refused as `test_budget_spent` until a fresh holdout exists. Re-registering a page does not make a seen test unseen.
A result about the training procedure across seeds is a research claim reported separately; promotion judges **one artifact**, the one that would be served.

## The M1 gate

The gate's input is an **evaluation artifact**: a manifest and a per-row predictions file.
- The manifest binds the model (base revision, adapter sha256, tokenizer revision, inference manifest), the evaluation code version, the test manifest hash, the label map hash, and the sha256 of the predictions file.
- The predictions file has one row per test row id: gold label, raw output, finish state, outcome, parsed label.

The gate recomputes every number from the rows and decides one of: `offline_qualified`, `refuse` with every reason that applies, or `insufficient_evidence`. It never qualifies on a missing or malformed field.

| Rule | Refuses (or `insufficient_evidence`) when |
|---|---|
| Integrity | the predictions file's sha256 differs from its manifest; row ids are not exactly the registered 3,080, or repeat; any number is not finite |
| Comparable | an artifact's test manifest hash or label map hash differs from the registered ones. Prompts and tokenizers are provenance, not a comparability condition: a different pipeline is compared on the same rows, labels and scoring |
| Bound to the promoted model | the artifact to be promoted is not the one the evaluation names (adapter sha256, base and tokenizer revisions, inference manifest) |
| Label map | the label map the candidate was trained and served with differs from the registered one. Fixture: two labels swapped, otherwise perfect |
| Well formed | non-`ok` rows exceed 1% of test (the count of rows, not a sum of rates) |
| No collapsed label | any label's recall is below 0.50. A model that misses an intent most of the time is refused however good its average is |
| Beats each control | the lower bound of the paired interval of candidate minus control accuracy is not above 0, for the TF-IDF control and for the pretrained control |
| Not worse than the champion, nor the fixed reference | the lower bound of the paired interval of candidate minus champion accuracy is below −0.01; the same against the fixed reference. If the interval straddles the margin, the outcome is `insufficient_evidence`, not "worse" |
| Test budget | the candidate's test evaluation is beyond its plan's registered number |

`offline_qualified` is all this CPU half can grant. **`serve_approved` is a later state** and requires, with no field optional:
- the quality rules above re-applied to the served model's own outputs on test, since the adapter agreeing with the served model is not the served model being good;
- parity between the trained adapter and the served model as an implementation check, with its log-probability bound (answer tokens only, maximum absolute difference) fixed on dev before test;
- latency and throughput under a load profile registered with the GPU run, measured over repeated runs, against an absolute SLO for the first deployment and against the champion afterwards.

Until those are registered, `serve_approved` cannot be granted.
The thresholds here are fixed before any model is trained; changing one is a new version of this page, not an edit.

## Gate tests

Every refusal fixture breaks only the rule it targets and asserts the reason, and positive fixtures make sure the gate is not one that refuses everything:
- a good candidate is `offline_qualified`;
- identical predictions give a difference interval of exactly [0, 0];
- non-`ok` rows at 30 and 31 of 3,080 (just under and over 1%);
- two labels swapped, otherwise perfect, is refused for the label map and for collapsed labels;
- the 30-row format-error case from Metrics, run from evaluator to gate;
- NaN or infinite numbers, missing or repeated row ids, rows in shuffled order (same result by id), a predictions file whose sha256 does not match;
- an artifact bound to a different adapter than the one to be promoted;
- a straddling interval gives `insufficient_evidence`.

## What is CPU and what is GPU

| CPU, this issue | GPU, later, registered and approved separately |
|---|---|
| pinned data, splits, hashes | LoRA SFT within a registered budget, selection on dev |
| prompt template, strict parser, evaluator, stratified bootstrap | pretrained-control evaluation |
| TF-IDF control, tuned on dev, scored on test once | served-model evaluation, parity, latency and throughput |
| gate rules over evaluation artifacts, with every fixture above | `serve_approved` |

## Layout

`experiments/mlops-w2/`: `data.py`, `prompt.py`, `evaluate.py` (parser, metrics, stratified paired bootstrap), `tfidf.py`, `gate.py`, their `test_*.py`, and `requirements.txt` with exact versions.
It does not change `experiments/mlops-lineage`, which stays the record of the earlier promotion run.

## Not claimed

- That LoRA beats TF-IDF on this task. It may not; BANKING77 is well served by simple classifiers.
- Anything about served behaviour before the GPU runs.
- Freedom from pretraining contamination.

## The v1 attack and where v2 answers it

Source: codex `gpt-6-astra` (high), 2026-11-14, kept in the storage repository at `gpu-platform-control-plane/engineering/2026-11-14-w2-m1-gate/codex-astra-attack.md`. Numbers marked "computed here" were recomputed before use; codex is not the source of any number on this page.

| # | Finding | v2 |
|---|---|---|
| 1 | Two swapped labels pass on overall macro-F1 (candidate 0.974 vs champion 0.900 with both labels at F1 0, computed here) | label map rule, per-label recall floor, swap fixture |
| 2 | A passing record is not bound to the promoted model; aggregates cannot reproduce a paired interval | evaluation artifact with per-row predictions and model digests; gate recomputes |
| 3 | Reusing test across candidates inflates false promotion | selection on dev, test ledger and budget |
| 4 | A pooled-seed interval can approve one seed's model | promotion judges one artifact; seed results are a separate claim |
| 5 | Missing serving fields skip their checks | `offline_qualified` vs `serve_approved` with nothing optional |
| 6 | 99.5% parity does not make the served model pass | quality re-applied to served outputs; bound fixed on dev |
| 7 | Format errors score better than wrong labels under macro-F1 (computed here) | primary metric is accuracy |
| 8 | Relative rules allow a bad first model and cumulative regression | pretrained control and fixed reference |
| 9 | No power or stratification; "not shown" read as "worse" | stratified paired bootstrap, `insufficient_evidence` |
| 10 | Prompt hash as a comparability condition blocks valid improvements | comparability is rows, labels and scoring; prompt is provenance |
| 11 | Many "fixed" settings were not | split, generation, TF-IDF and model revisions fixed here; LoRA budget registered before the GPU run |
| 12 | The no-leak guarantee and "untrained base" overstated | scope limited; "pretrained control" |
| 13 | Duplicate JSON keys pass; error rate can double-count | duplicate keys refused (reproduced here); outcomes exclusive, counted once |
| 14 | Refusal-only fixtures pass a gate that refuses everything | positive, boundary and order fixtures |
