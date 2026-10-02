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

## The analysis version these figures reproduce under

The reference analysis version for reproducing the published figures and readings of the
`evidence-m5c-2026-10-01` release is:

```
cc920d34a574576eae320043dae90bdfcfff1fdd
```

That is **the source version the release points at** — the tag and the GitHub release both resolve to it.
It is **not** a claim that every figure was first computed by that commit, and it does not retroactively
certify the process that produced any individual number. Three versions are different things and this page
keeps them apart:

| | Value | What it is |
|---|---|---|
| Collection | `85ae2fa` (ninth pilot), `471b86b` (the morning run that stopped at cell 1), `7b69214` (the ten-cell run) | The tree each run's evidence was gathered from, recorded in that archive's own `commit.txt` |
| Published analysis | `cc920d34a574576eae320043dae90bdfcfff1fdd` | The source version the release points at, and the one these figures reproduce under |
| Later re-analysis | any later commit | Legitimate and expected — reading `4d` postdates both paid runs — but it is a re-analysis and is labelled as one |

A collection commit cannot stand in for the analysis version. The ten-cell run's own `readings.txt`, written
at `7b69214`, still says `none of the readings fired` — a sentence this project has since withdrawn, because
reading `4d` now distinguishes "could not fire" from "fired negative". Naming `7b69214` as the published
analysis would adopt that withdrawn reading as part of the published claim. (Both files are in the digest
list above: `readings.txt` at `5d65bec0ec7f1076…` and `commit.txt` at `f8a8c70b12419c81…`, so this is a
statement about the published bytes rather than about a working copy.)

⚠️ **"The archive" means the published set, which is larger than the run's own `evidence.tgz`.** The digest
list names **49** files; the `evidence.tgz` inside a paid run's output directory holds **42** and carries an
`m5c-run/` prefix. Eight of the published files — `commit.txt`, `readings.txt`, `instance-id`,
`instance-log.txt`, `nodes.txt`, `preflight-node-cards.txt`, `preflight-nvidia-smi.csv`, `termination.txt` —
sit beside that tarball rather than inside it, and one file (`README.txt`) is inside it and not published.
A reader looking for `commit.txt` inside the tarball will not find it; it is in the published set.

⚠️ **What `hack/verify-published-evidence.sh` does and does not pin.** `ANALYSIS_COMMIT` makes the script
*check* that the current `HEAD` is the version you named; it does not fetch or build that commit. Omitted,
the script accepts whatever `HEAD` you run it from and says so. So reproducing the published figures means
checking out the version above in a clean tree and passing it explicitly:

```bash
git -C <clone> checkout cc920d34a574576eae320043dae90bdfcfff1fdd
ANALYSIS_COMMIT=cc920d3 ./hack/verify-published-evidence.sh <archive-dir>
```

Running it from a later tree is a re-analysis. That is normal and the script says which case it is in, but
the two must not be reported as the same thing.

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

## The 2026-10-02 run, and why its answer differs

It was registered as a "reproduction run" of the ninth pilot and **was not one**: it offered a 256-token
premium prompt against the pilot's 68 — the engine's own count in both archives — and a 60-second timeout
against its 30. The pre-registration carries a
dated correction saying so. The paragraph below describes it as what it is — a measurement at this load.

A five-repetition run of the frozen matrix — `R1`, `shared`, `timeSlicing`, fifteen cells,
collected at `b97d88ebfb97bf1b8cced34ceae5c4b5c4388270` on an A10G in ap-northeast-2d for about $2.16.
It is published here because the 2026-10-02 amendment to the pre-registration requires every outcome to
be published, and this one **disagrees with the release**.

**Fifteen of fifteen cells completed**, with **0 shed requests and 0 timeouts** in every arm and 23,275
premium completions per arm, so there is no missing cell and no interruption to account for. The session ended
at 04:54:42Z on 2026-10-02 and the amendment's deadline for publishing the outcome, whatever it was, is 48
hours after that. Nothing was bought a second time to obtain a different answer.

```
ANSWER: 3        splitting the card changes nothing that matters -- INCONCLUSIVE
```

The `evidence-m5c-2026-10-01` release's answer, from the ninth pilot, is `ANSWER: 5 (timeSlicing)`.
Both archives were re-scored with the SAME binary for this comparison, so the difference is not an
analysis-version difference:

| | ninth pilot (2 reps) | this run (5 reps) |
|---|---|---|
| `R1` median of per-repetition p99 | 69.540 ms | 174.268 ms |
| `shared` | 1892.852 ms | 4000.579 ms |
| `timeSlicing` | 1008.079 ms | 14868.019 ms |
| registered B / C / ratio | 70 / 1893 / 22.994 → see note | 174 / 4001 / 22.994 |
| shed, timeouts | 0, 0 | 0, 0 |
| premium completions per arm | 9,310 | 23,275 |

⚠️ The ninth pilot's registered ratio is **27.043**; the 22.994 in the right-hand column is this run's.
They are different runs and the two must not be quoted as one.

**This run is a later analysis version**, not a reproduction of the release. Per the table above in
"The analysis version these figures reproduce under", a run scored by a later tree is labelled as such.

**The loads are NOT the same, and an earlier draft of this section said they were.** The arrival schedule is
identical — `RATE=9.4045`, weights `1 / 0.0260 / 0`, `DURATION_MS=505000`, seed 11 — which is why both runs
offer 4,655 premium and 139 contender requests per cell. What each request *carries* differs:

| | ninth pilot | this run |
|---|---|---|
| premium prompt | 200 chars, engine-reported **68 tok** | 1,174 chars, engine-reported **256 tok** |
| contender prompt | 40,000 chars, engine-reported 7,695 tok | 42,579 chars, engine-reported 8,192 tok |
| the gateway's `estInputTokens` score, `ceil(chars/4)` | 50 / 10,000 | 294 / 10,645 |
| `timeoutMs` | 30,000 | 60,000 |
| `traceChecksum` (R1 rep 1) | `98efa634…` | `499a5e4d…` |

**The token counts above are the engine's own, and an earlier draft of this table quoted the gateway's
estimate instead.** Every row of both archives carries both numbers: `engineInputTokens`, which
`internal/bench/replay.go:100` defines as what the engine itself reported, and `estInputTokens`, the
`ceil(chars/4)` score the admission decision is made on, which `internal/gateway/proxy.go:76` calls "never an
exact count". They disagree about how much the load moved: by the gateway's score the premium prefill grew
5.9x (estimate 294 against estimate 50), and by the engine's own count **3.8x** (256 against 68). The
engine's number is the one that describes prefill work, so it is the one the prose uses. The estimate stays in the table because it is what
the gateway actually gated on. Uniform across every row: 256 on all **69,825** premium rows of this run and
68 on all 27,930 of the pilot's, with 0 exceptions in either.

That is the same difference `docs/11_WHAT_THIS_MEASURED.md` already names for the isolated baseline: `R1` is
69.5 ms at 68 tokens and 174 ms at 256. It is the leading candidate for the `timeSlicing` change too — a 3.8x
heavier prefill against a split engine whose KV cache is 4x smaller (93,200 against 369,680 tokens) — but the
prompt length and the timeout moved together, so this run does not separate them. The first draft of this
section called the load identical after checking only the rate, the weights and the duration.

Ruled out by measurement: the engine configuration is identical in both runs (split engines at
`gpu_memory_utilization 0.475`, `max_num_seqs 32`, KV 93,200 tokens; whole-card engines at `0.9`, `64`,
KV 369,680 tokens), the card model is identical (A10G, 23,028 MiB), and the prompt corpus is the same
(`promptCorpusSHA dec102070158…` in both). What else differs: the kernel (`6.8.0-1063-aws` against
`6.8.0-1064-aws`).

What **cannot** be compared, and why — both are recording gaps rather than losses:

- **The engine image.** This run records `vllm/vllm-openai@sha256:0a51ea5b4ae2dc5d81890e5173f54203d2a3ae0cfffe51b8fd2afd4391bfd967`.
  The ninth pilot's manifests carry no `imageDigests` at all: the code that fills them landed on
  2026-09-16 and the ninth pilot ran on 2026-09-13.
- **The driver version.** Neither run has one, because the preflight asks
  `nvidia-smi --query-gpu=index,name,memory.total` and never requests `driver_version`.

### Per-file digests, 2026-10-02 run

```
0ce34e0d7c4546d4f09ce10fc60c6cc0196970c39f14c61801054a424cb488b9  readings.txt
f1bbf2f98726910d022df4e6e154291712156f0380a071b12b6fdedc2aba0942  commit.txt
d3252e764072afa0080f82f94b23fc1d85799ea579422faef5d32a655a06f6b3  termination.txt
86d1147a7cd26362797cac5a3b531e242ac3f10685927ce1301c329ae61d109c  instance-id
efe782528ad5881a020ada587e07146f9e05aea9543146618c8dc25112df5675  log.txt
f323d5723db925f938a90bc21a26dbef67a72a83847c64d1a1959e1f588bccae  evidence.tgz
89029053bdd20658b1732492d663294960ca8dc3372f78cab7cf468ac1a62cbf  nodes.txt
c14f2a0e73a445e046c99d0197feba2d02af81e008d77feb1b4a57265c1f5e6d  preflight-nvidia-smi.csv
0d1f875deec9a84a1d1e91a608343d3b1c63db90effdc0a7962dcda2fd511d39  preflight-node-cards.txt
6ea37a340b7e184c2ace1ec0e647f3eabcfcdc12a95acf4ae4eaa661607bdf60  m5c-run/raw-R1-1.jsonl
395c7c49d216f5dfdd9aa00637d23621d0e79fb28e0aed7eb93dc940adcfe124  m5c-run/raw-R1-2.jsonl
4c2bc215d8f98be0d4a28283607899e61c377907d7f45f780f27d9adcb58817d  m5c-run/raw-R1-3.jsonl
478a688347dc89ef19cca2c8a00779941400493bb2aff319b488de5a0142b7c4  m5c-run/raw-R1-4.jsonl
07be2f357647144ac708788240cfc90c17b7f5d5baa5c1706f3cd63c0719f21b  m5c-run/raw-R1-5.jsonl
f60bf375493ade53d360e50df714820b1f9b6fdf17883df3053f5598a49d7a16  m5c-run/raw-shared-1.jsonl
a5b8ca34a5f7009a2100dfa9f209cff6b49cdbb2b8d77bbf44d7ccc97d2d58de  m5c-run/raw-shared-2.jsonl
d5102a8fd1eebd8fcd62e2d39a616be8bb2b2b9c59303fab004986cd57c18acf  m5c-run/raw-shared-3.jsonl
815550d6d4561029053f92d0e7e03b7091cb1620e419e76de41e5f80a5ec0fa6  m5c-run/raw-shared-4.jsonl
597252f4cc1bdcd6eb2624b9bbe218f35bcbca805ec99395346435f36df48098  m5c-run/raw-shared-5.jsonl
2c6fd762bc32d977f159aa7233c2c7822b78f2db187de850308bee512d81150c  m5c-run/raw-timeSlicing-1.jsonl
25755dcc413c4e654a6fd0f913793958acd9267586830ca32d535f0fb5cb541e  m5c-run/raw-timeSlicing-2.jsonl
2ad23c0d02a646c45eb42fb143f4816aa43a9a76c2070c6da43dd5ac3371ecd8  m5c-run/raw-timeSlicing-3.jsonl
f74b8b6cde71c519475cc6875a37bdfb060a57b8db9cfedbd52be6e50c7bf830  m5c-run/raw-timeSlicing-4.jsonl
16ba209a4feadfa181121fa8a42c7802817ab7b19c1000eaa427834f6e73933f  m5c-run/raw-timeSlicing-5.jsonl
```

`readings.txt` is not written by the run. The session wrapper deliberately does not evaluate the
readings on the instance — it prints the command instead — so that file is the output of
`benchharness report --raw …` over the fifteen raw files, pinned into the archive after the run.
