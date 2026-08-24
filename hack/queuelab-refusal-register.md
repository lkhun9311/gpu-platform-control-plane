# What will refuse the paid queuelab session, and what has been closed

This harness refuses rather than improvises, which is the right design and means the failure mode of a
rented card is a session that produces `refused` instead of a number. Everything that can refuse is
enumerated below. The register exists because **none of the device-evidence path has ever run against a
real device plugin**: every recorded run used the fake one and produced no DCGM observation at all.

Counts: 16 refusals in `internal/queuelab/device.go`, 5 in `cmd/queuelabrun/qualify.go`, 16 in
`cmd/queuelabrun/device_preflight.go`.

## 1. A structural defect, found by this audit and NOT fixed

**The busyness gate is judged over the device hold, and in the honouring arm the victim is exiting.**

`cmd/queuelabrun/record.go` passes `DeviceHoldWindow`'s bounds — owner `Admitted` to victim
`AttemptStopped` — straight into `EstablishesDeviceWork`, and the decode path re-runs the gate bound to the
same two stamps. Inside that window the victim is *being terminated*; that is what the window is. The gate
requires `minBusySamples` (2) distinct instants showing the card working, and refuses with "a card that is
allocated and idle is the state this whole axis exists to distinguish from one that is computing".

In the arm that honours SIGTERM those two requirements contradict each other:

The holds below are read off the committed records, not restated from another page. Re-derive them with:

    queuelabrun -compare 'ex/e17-*-e17[gs]*.json' -mode model

| | recorded hold | victim during the hold | samples inside at 1 s scrape |
|---|---|---|---|
| A-honor | 2.171 – 3.210 s | has stopped computing | 2–3, reading idle |
| A-ignore | 31.192 – 31.233 s | still computing | ~31, reading busy |

So `-require-device` does not fail evenly. It refuses the short arm and keeps the long one, **leaving no
contrast to form** — and the contrast is the result.

`internal/queuelab/device_holdwindow_test.go` characterises it: the honouring shape is refused, the
ignoring shape passes, and the test says what to do if the refusal ever stops happening.

Two candidate fixes, neither taken, because both change what the record's device evidence MEANS and the
decode-time re-check is bound to the hold stamps:

- judge "this Pod did device work" over the victim's own attempt rather than over the hold, which is the
  interval the question is actually about;
- keep the hold-bound check and make it conditional on the hold being long enough to contain the samples it
  demands, turning a silent refusal into a stated limit.

**Session mitigation, whichever is chosen later:** run the study WITHOUT `-require-device` first. The timing
result — the hold, the dose axis, the model check — does not depend on device evidence, and it is the result
the milestone is for. Attempt `-require-device` afterwards, on the same card, as a separate question.

## 2. Closed by evidence, without a GPU

**The DCGM label shape the parser depends on.** Read out of the pinned exporter binary's own template
(`nvcr.io/nvidia/k8s/dcgm-exporter:3.3.9-3.6.1-ubuntu22.04@sha256:3d4e0dfa…`), not from documentation:

    DCGM_FI_DEV_GPU_UTIL{gpu="0",UUID="…",pci_bus_id="…",device="nvidia0",modelName="…"[,GPU_I_PROFILE,GPU_I_ID][,Hostname="…"][,<attributes>]} <value>

- `UUID` is rendered from a variable (`{{ $metric.UUID }}`) whose value is the literal `UUID` off MIG. The
  parser reads `labels["UUID"]` and is correct for T4 and A10G, neither of which supports MIG.
- `namespace`, `pod` and `container` arrive through `{{- range $k, $v := $metric.Attributes -}}`, appended
  last and in sorted key order. They exist only with `DCGM_EXPORTER_KUBERNETES=true` and the pod-resources
  socket mounted; `config/dcgm-exporter/daemonset.yaml` sets both, and a contract test holds it there.
- `modelName` carries spaces (`NVIDIA A10G`) and commas on MIG parts. `splitLabels` splits on commas outside
  quotes and already documents that case.
- `pci_bus_id` carries colons and is absent from the package's fixture. Harmless — labels are split on
  commas and the key on the first `=` — but the fixture does not match the template.
- `N/A` values are skipped and counted rather than ending the scrape, which DCGM emits around driver init,
  a GPU reset, or an XID event.

**Not verified:** `nv-hostengine` in this image exposes no fake-GPU mode, so no exposition could be captured
without a card. Everything above is read from the artifact that will run, which is better than
documentation and weaker than a capture.

## 3. Open, and only a session can close them

| # | Refusal | Why the fake plugin cannot answer it |
|---|---|---|
| 1 | The card is never observed working | The PTX FMA loop has never run on real silicon. If it does not move `DCGM_FI_DEV_GPU_UTIL` above 0, every arm refuses. |
| 2 | Allocatable devices ≠ requirement exactly | The plugin advertises what NVML enumerates; `NVIDIA_VISIBLE_DEVICES` is documented in the manifest as probably NOT restricting it. The surplus occupier is the real mechanism and has never held a real device. |
| 3 | Samples name more than one device for one Pod | Cannot occur with a simulator that has no devices. |
| 4 | Exclusivity: a device carries two Pods' labels | The occupier's devices carry ITS label. Distinct devices, so it should not fire — untested. |
| 5 | Observer coverage gaps | Real scrape latency against a real exporter under load is not the simulator's. |

## 4. Ordering that matters

- Qualification counts the surplus occupier's devices out and requires what remains to equal the
  requirement **exactly**. Too few refuses ("the contrast it never produced"); too many refuses ("collapse
  below the floor"). Both are correct and both stop the session.
- `hack/gpu-session.sh` prepares every worker, not just the first, and verifies its route before running the
  study. Neither has run against real hardware either.

## 5. What this register does not cover

The refusals in `device_preflight.go` are the preflight's own, and the preflight exists precisely to hit
them before the study does. Reaching one of those is the system working. The ones above are the ones that
would be reached *during* a paid run.
