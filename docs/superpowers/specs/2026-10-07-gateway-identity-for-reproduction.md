# The gateway's identity in a reproduction claim

*Registered 2026-10-07, before the code that implements it. Closes issue 323.*

## The problem

`bench.ReproductionRefusal` compares a plan's `imageDigests` with the target run's.
The gateway entry is the image ID that `docker build -q` prints on the paid instance (`hack/m5c-matrix.sh`).

Measured on 2026-10-07:

| Built twice from | Binary sha256 | Image ID | Top layer |
|---|---|---|---|
| the same commit, warm and cold Go cache | identical (`79d4784e…`) | — | — |
| an identical binary on a base pinned by digest, `--no-cache` | identical | **different** | **different** |

The image ID and the layer holding the binary change with every build, because the copied file's timestamp goes into the layer.
The base layers are identical.
So an image ID names one build, not one gateway, and a plan cannot carry it at all: the plan check runs before the image is built.

The comparison cannot simply drop the gateway either.
The Dockerfile's base was `gcr.io/distroless/static:nonroot`, a tag, so two builds at one source commit could sit on different bases.
Source commit alone would also miss a gateway binary supplied from elsewhere (`GATEWAY_BIN`).

## The rule

A run identifies its gateway by two content facts, recorded in its manifest beside the image ID:
- `gatewayBinarySHA256`: the sha256 of the gateway binary copied into the image, 64 lowercase hex;
- `gatewayBase`: the base image, pinned by digest (`name@sha256:<64 hex>`).

A reproduction claim compares them as it compares `tokenizerRev`, in three classes:
- **The target recorded neither.** That is every run before this page. The gateway image ID is compared exactly as before, so those runs stay reproducible only by the very image they ran, and stay uncertifiable otherwise.
- **The target recorded both and the plan records either one missing.** Refused: this run is failing to record what the comparison needs.
- **Both recorded both.** The two facts must be equal, and the gateway image ID is then not compared. The engine and any other image are still compared by digest.

Partial records are refused, not read as "neither":
- a manifest recording one of the two without the other;
- a value that is not well formed.

Rules this page does not change:
- **`gatewaySHA` is still compared exactly.** An identical binary built from a later commit (say, one that only changed docs) is therefore still refused. That is stricter than necessary, and loosening it would be a separate registration.
- **Role coverage.** The target must record an image for every role in `bench.ProvenanceRoles`, `gateway` and `engine`. Before this page, any non-empty `imageDigests` counted as recorded, so a target naming only its engine was not reported as UNKNOWN for its gateway (found in review).

## What produces the facts

- `hack/m5c-matrix.sh` builds the gateway image on a base pinned by digest. It hashes the binary it copies in and passes both facts to every `gen-trace` that records provenance.
- When `REPRODUCES` is set, the pre-purchase plan's `gen-trace` also receives `--gateway-sha`, `--engine-image`, `--tokenizer-rev` and the two gateway facts. A plan without them could never be compared with a target that has them.
  - The plan does not receive the gateway image ID, which does not exist yet.
  - Without `REPRODUCES` the plan commands are unchanged, byte for byte, so earlier sessions' recorded plan calls still reproduce.
- `prepare-traces`, the M5-b path, is not changed. Its runs keep the legacy comparison.

## What would show it wrong

The tests must turn red in each of these cases:
- the gateway binary or the base is substituted while the source commit stays the same;
- the gateway image ID is compared when both sides recorded both facts (that is, two builds of one binary are refused);
- a legacy target is compared without its image ID;
- a manifest records one of the two facts without the other;
- a target lacking an engine image is not reported as UNKNOWN.

## What this does not claim

- It does not certify any existing archive. None recorded the two facts, and none can now.
- It does not make the image reproducible, only its content comparable.
- It says nothing about the driver version, `matchTolerance` or `primaryEndpoint`, which the comparison has never covered (2026-09-10 registration, its correction).

## Amendment, 2026-10-07 — the judging contract is compared too

The 2026-09-10 registration's correction records that `ReproductionFacts` had no `matchTolerance` or `primaryEndpoint`. So a plan judging the same traffic by another tolerance or another primary metric was accepted as a reproduction; codex `gpt-6-astra` raised it again while reviewing this page's issue.

Both fields are now compared, and so are their recordings across one archive's repetitions.
- Every manifest records them: `validateFields` in `internal/bench/manifest.go` requires both.
- So they are compared as plain values, like `timeoutMs`, with no UNKNOWN class.

The driver version stays outside the comparison, for a reason the plan check cannot get around:
- The plan check runs before purchase, and the driver is known only once the instance has booted (`preflight-nvidia-smi.csv`).
- Comparing it would have to happen after the money is spent. That is a different check and is not registered here.
- A reproduction's write-up must still say that the driver was not compared.
