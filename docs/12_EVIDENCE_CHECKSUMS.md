# 12. Evidence checksums

The raw rows behind every published figure are **not in this repository**, and they are not public. This
page is what makes that defensible: it publishes the hash of every evidence file *before* anyone asks for
one, so an archive handed over later can be checked against a commitment that predates the conversation.

## What a hash here does and does not do

| | |
| --- | --- |
| **Does** | Let someone holding a file confirm it is the file this page names |
| **Does** | Fix *when* the claim was made — these lines are in git history, with a commit date |
| **Does NOT** | Reveal anything about the contents. A sha256 is one-way; there is no lookup from hash to data |
| **Does NOT** | Let anyone recover the rows, the timings, the row count or the prompt lengths |

So this page is a **commitment, not a disclosure**. It turns "trust the number" into "check the hash of
what I send you" without publishing the rows at all — and the point is not that they are too large to
publish. They are 44 MB uncompressed and 2.7 MB compressed, which is nothing. The point is in the next
section: they live beside working notes that are not portfolio material, and disclosure stays a decision
rather than a default.

The archives are reproducible: `tar -czf` over the same directory gives the same digest on every run, so a
recipient can verify either the archive or the individual files.

## How to verify a copy you were given

```
# per-file, which also says WHICH file differs if one does
sha256sum -c m5c-20261001-023515-ten-cell-complete.SHA256SUMS

# or the archive as a whole
sha256sum m5c-20261001-023515-ten-cell-complete.tar.gz

# then recompute every published figure from the rows themselves
go run ./cmd/benchharness report $(for f in raw-*.jsonl; do echo --raw $f; done)
```

The report prints the load it replayed, the per-repetition p99s behind each tail, and the pre-registered
readings — so the recomputation is checkable line by line against what this repository claims.

## Archives

| run | arms × reps | archive sha256 |
| --- | --- | --- |
| `m5c-20260913-011031-ninth-pilot` | 3 × 2 | `54fcdf6813e6fb63230934586b051f3098be202a1f468ad47313b64817551952` |
| `m5c-20261001-023515-ten-cell-complete` | 2 × 5 | `92d54eb363064e069a45b8adac88f32eae341c48d60ce00c67cc9f062a58be7a` |

Uncompressed the two are 15 MB and 29 MB; compressed, 900 KB and 1.8 MB. Size was never the reason they
are unpublished — the reason is that the sibling `storage` repository they live in also holds the
engineering journal, the defect records and the cost ledger, which are working notes rather than
portfolio material.

⚠️ The figure "about 114 MB" that appeared in `README.md` was the **whole paid-run directory** — it
includes the shipped `gateway` and `benchharness` binaries and the source archive. The *evidence* carried
into `storage` is the 15 MB above.

## Per-file digests

Each run's full digest list is committed beside this page, one line per file:

- [`docs/evidence/m5c-20260913-011031-ninth-pilot.SHA256SUMS`](evidence/m5c-20260913-011031-ninth-pilot.SHA256SUMS) — 13 files
- [`docs/evidence/m5c-20261001-023515-ten-cell-complete.SHA256SUMS`](evidence/m5c-20261001-023515-ten-cell-complete.SHA256SUMS) — 49 files

## The chain that was already there

These digests are the outermost layer of a chain the harness builds on its own, and the inner layers are
already published — they are inside the evidence, not added by this page:

```
manifest-R1-1.yaml :  promptCorpusSHA dec10207…   traceChecksum 1e91e051…   tokenizerRev aa8e7253…
raw-R1-1.jsonl     :  every one of 4,655 rows carries  "traceChecksum":"1e91e051…"
```

A single raw row therefore identifies the trace it was replayed from and the prompt corpus that trace was
cut from. `LoadManifest` refuses a manifest whose corpus digest is not the one compiled into the binary, so
a run frozen against different prompt bytes cannot be replayed or reported as if it were the same traffic.

That is why a *sample* of rows is enough to check provenance: the chain does not depend on holding all of
them.

## What this page does not fix

A reader who never asks for the archive still has to take the numbers on trust. This page narrows that to
one request, and it does not remove it. The stronger guarantee is the one the pre-registration provides —
the load, the rounding, the percentile convention and the readings were all frozen before the run, in
dated amendments, and `hack/m5c-gpu-session.sh` buys the whole thing again from a commit. A measurement is
believable because the protocol is specified well enough to redo, not because its logs are auditable.
