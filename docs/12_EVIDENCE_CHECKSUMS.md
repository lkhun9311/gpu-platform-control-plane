# 12. Evidence checksums

The raw rows behind every published figure are **not in this repository**, and this page publishes the hash
of every evidence file so that a copy handed over later can be checked against a commitment that predates
the conversation.

**Since 2026-10-01 the rows are also downloadable.** Two archives are attached to [the evidence release](https://github.com/lkhun9311/gpu-platform-control-plane/releases/tag/evidence-m5c-2026-10-01), and
`hack/verify-published-evidence.sh` recomputes every published figure from them without a GPU. The ninth
pilot is published complete and byte-identical to its commitment; the ten-cell run is published as a
**derivative** with two files masked and two withheld, and the section below says exactly which, because the
derivative's digest is not the committed one and must not be read as if it were.

## What a hash here does and does not do

| | |
| --- | --- |
| **Does** | Let someone holding a file confirm it is the file this page names |
| **Does** | Fix *when* the claim was made — these lines are in git history, with a commit date |
| **Does NOT** | Reveal anything about the contents. A sha256 is one-way; there is no lookup from hash to data |
| **Does NOT** | Let anyone recover the rows, the timings, the row count or the prompt lengths |

So this page is the **commitment**, and the release is the **disclosure**. They are different things and the
distinction is the point: a commitment fixes *when* a claim was made, which a download cannot do, and a
download lets a reader recompute, which a hash cannot do. This page used to say the rows were not public and
that disclosure stayed a decision rather than a default; the decision was taken on 2026-10-01, and what it
cost is one masked account identifier rather than the whole archive.

The archives are reproducible: `tar -czf` over the same directory gives the same digest on every run, so a
recipient can verify either the archive or the individual files.

## How to verify a copy you were given

```
# per-file, which also says WHICH file differs if one does
sha256sum -c m5c-20261001-023515-ten-cell-complete.SHA256SUMS

# or the archive as a whole
sha256sum m5c-20261001-023515-ten-cell-complete.tar.gz

# then recompute every published figure from the rows themselves, from a clone of this repository
go run ./cmd/benchharness report $(for f in /path/to/unpacked/raw-*.jsonl; do echo --raw $f; done)
```

⚠️ **Run it from a clone, with absolute paths to the rows.** The first version of this page said to run
`go run ./cmd/benchharness` in the unpacked directory, and that fails with `cannot find main module` because
the archive carries evidence and no `go.mod`. The command above was executed before being written here; so
was the alternative, `go build -o benchharness ./cmd/benchharness` and then running that binary beside the
rows, which works with no module at all.

**It exits 1, and that is the expected result.** Reading `4d` is a gate: this evidence declares one
`sharingMode`, so it has no sharing candidate, and the harness refuses to print a verdict rather than
reporting an empty outcome space as a finding. A recomputation that exited 0 here would mean the gate had
stopped working. The lines to check are these:

```
Per-repetition premium TTFT p99 (ms) -- the sample behind each tail above
R1                 174.078  173.832  174.297  174.387  174.034   median 174.078
shared             3996.117  4000.349  4000.510  3998.338  3997.887   median 3998.338

Registered estimand (design spec, third 2026-09-30 amendment)
  baselineP99Ms  174   colocatedP99Ms 3998   interferenceRatio 22.977
  ... No interval is published; see the seventh amendment.

ANSWER: none of the readings COULD fire.
```

The report also prints the load it replayed and every pre-registered reading, so the recomputation is
checkable line by line against what this repository claims.

## Archives

| run | arms × reps | archive sha256 |
| --- | --- | --- |
| `m5c-20260913-011031-ninth-pilot` | 3 × 2 | `54fcdf6813e6fb63230934586b051f3098be202a1f468ad47313b64817551952` |
| `m5c-20261001-023515-ten-cell-complete` | 2 × 5 | `92d54eb363064e069a45b8adac88f32eae341c48d60ce00c67cc9f062a58be7a` |

Uncompressed the two are 15 MB and 29 MB; compressed, 900 KB and 1.8 MB. Size was never the reason they sat
unpublished — the reason was that the sibling `storage` repository they live in also holds the engineering
journal, the defect records and the cost ledger, which are working notes rather than portfolio material. That
is a reason not to publish the *repository*, and it was never a reason not to publish the *rows*; separating
them is what the release does.

## The public download, and what it is not

| | archive | digest | files |
| --- | --- | --- | ---: |
| ninth pilot | `m5c-20260913-011031-ninth-pilot.tar.gz` | `54fcdf6813e6fb63…` — **the committed value**, byte-identical | 13 |
| ten-cell | `m5c-20261001-023515-ten-cell-complete-public-v1.tar.gz` | `601197dcf19a27ee…` — a **new** digest for a derivative | 47 |

`92d54eb363064e069a45b8adac88f32eae341c48d60ce00c67cc9f062a58be7a` and the 49-line list above are
**unchanged**. They name the complete, private archive. Of those 49 files the download carries 45 byte for
byte, 2 with identifiers masked, and omits 2:

| file | treatment | why |
| --- | --- | --- |
| `instance-log.txt` → `instance-log.redacted.txt` | AWS account id and bucket name replaced by `<ACCOUNT_ID>` in 21 places; line order, commands, settings and every hash preserved | it is the instance's own account of the run, including the line that shows a CR compiled the load. Masking keeps that; deleting it would not |
| `preflight-node-cards.txt` → `preflight-node-cards.redacted.txt` | GPU UUID replaced by `GPU-<UUID>`; model and card count preserved | a device identifier the analysis does not use |
| `instance-id`, `termination.txt` | withheld | each is a bare EC2 instance id and nothing else |

**The download cannot verify `92d54eb3…`, and it cannot prove the two masked files match their originals.**
The new digest identifies the derivative; it does not replace the commitment.

## Reproducing the figures from the download

```bash
tar -xzf m5c-20261001-023515-ten-cell-complete-public-v1.tar.gz
./hack/verify-published-evidence.sh m5c-20261001-023515-ten-cell-complete-public-v1
```

It checks the inputs against their digest list, builds the scorer from your clone, recomputes the report,
and asserts every published figure, the expected exit status and the expected refusal. It exits 0 only if all
of them hold — and it was shown to fail three ways (a broken checksum line, a missing list, a deleted row
file) before being written down here.

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
