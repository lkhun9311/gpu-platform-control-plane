# Hold-cap on the product path, on EKS: run 3, 20261021T021149Z

Study `holdcap-product-transfer-bound-off-2026-10-21`, registered in the design page's "Run 3, the bound Off" section before it ran (`docs/superpowers/specs/2026-10-15-holdcap-on-the-product-path-design.md`), at tooling commit `53ce5f1`.
Runs 1 and 2 (`../20261015T050622Z/README.md`, `../20261015T225425Z/README.md`) stand as they were; the three are reported side by side and not pooled.

## Registered verdict: observed on these traces

```
verdict: observed on these traces
```

Every cell was complete and valid, so the scorer read every line in every block (`holdcap-study/verdict.txt`):

| block | premium TTFT p99, HoldCap / Off (limit 0.85) | contender p50, HoldCap against Off (limit 1.5 ×) | contender p95 (limit 25 s) | refusals | preemptions |
|---|---|---|---|---|---|
| 851 | 410.8 / 1,468.8 ms = 0.280 | 4,006 against 3,127 ms (1.28 ×) | 16,724 ms | 0 | 0 |
| 852 | 429.3 / 1,515.3 ms = 0.283 | 7,025 against 5,107 ms (1.38 ×) | 15,770 ms | 0 | 0 |
| 853 | 456.8 / 1,497.9 ms = 0.305 | 3,944 against 3,142 ms (1.26 ×) | 9,276 ms | 0 | 0 |

In every block every contender completed and the premium content-event gap p99 was 0.965 to 0.974 of Off's.

## The Off this run measured against

The registration's one changed validity line held in every Off row: all 11,661 premium rows reached the engine at priority 0 and all 603 contender rows at priority 1, each with `X-Admission-Reason: admission_off`.
In the HoldCap cells the same rows carried the same priorities, with `premium_unreserved` for premium and `serial_prefill_free` or `serial_prefill_waited` for the contender.
Off's premium p99 was 1,469 to 1,515 ms, where the unbound Off of runs 1 and 2 gave 6,192 to 10,006 ms and the lab's off on block 3 gave 1,486 ms.

## Beside runs 1 and 2

| | run 1 | run 2 | run 3 |
|---|---|---|---|
| Off | binds no priority | binds no priority | binds by tier (#365) |
| registered verdict | not met: one refusal in block 853 | not met: contender median in block 852 | observed on these traces |
| premium TTFT p99, HoldCap / Off, by block | 0.040, 0.046, 0.076 | 0.043, 0.045, 0.075 | 0.280, 0.283, 0.305 |
| contender median, HoldCap / Off, block 852 | 1.51 × | 1.505 × | 1.38 × |
| refusals | one 502, an engine connection reset | none | none |
| validity | one unreadable sample in block 851 | every cell valid | every cell valid |

What the three runs say together, and only this:

- Against an Off that binds by tier, as the lab's off did, switching the product's engine to HoldCap cut the premium tenant's scheduled, client-observed TTFT p99 to 0.28 to 0.31 of Off's on these three traces, with every contender completing at a median 1.26 to 1.38 times Off's.
  The lab's diagnostic gave about 0.30 and 1.25 to 1.38 on the same traces; the card, the path and the client differ, so this is agreement in kind, not a replication.
- The contender's cost on trace 852, which runs 1 and 2 put at the 1.5 × limit, fell to 1.38 × once Off also deprioritised the contender: much of that near-miss was the unbound Off's small denominator, as run 2's write-up proposed.
- One run of one card, with three traces, is one observation, not a rate.

## A property of trace 853, the same in all three runs

In block 853 the first 14 premium requests (indexes 0 to 13, scheduled 265 to 861 ms into the replay) streamed 63 content events against a limit of 64, with HTTP 200, `[DONE]` and `finish_reason: length`, in both arms.
The registration counts a premium request whose output is not exactly at its limit as unsuccessful, at +∞, so these 14 enter each arm's premium p99 as failures.
Runs 1 and 2 show the same 14 indexes in both arms (run 1's HoldCap adds its one 502), so this is the trace, not this run.
Counted as successes instead, block 853's ratio would be 434.5 / 1,473.3 ms = 0.295; the registered figure is 0.305.

## Evidence

As in runs 1 and 2: per cell the derived manifest, `raw.jsonl.gz` (4,019, 4,143 and 4,102 rows), the sender configuration, 65 to 67 samples, metrics before and after, the engine's `non-default args`, the identity after the cell, `sampler.err` (empty in all six) and `SHA256SUMS` of the uncompressed rows, which all six gzipped copies match; the study's `study-id.txt`, `identity-start.json`, `run.log` and `verdict.txt`; and the session's own records.
Scoring the gzipped copy gave byte-identical output to the session's `verdict.txt`.

Excluded: the three key files, `terraform.log`, `ttl.pid`, the harness binary (its sha256 and commit are recorded) and the warm-up's scratch prompts.
The operator's address is masked as `<operator-ip>`, and `runbook-verify/*.out` are renamed `*.out.txt`.
No key value appears in any committed file or row; each was searched for, and the same search found each one in the session's own key files.

## What the product under test was

Argo CD deployed `main` at `329cba2`, which holds #365 and also #367: the image-push job pinned to ubuntu-24.04, after `ubuntu-latest` moved to 26.04 and its Docker push needed an ECR permission the push role does not have, and the build moved from Go 1.27.2 to 1.27.3 for GO-2026-6809 in `crypto/x509`.
Neither changes the gateway's or the controller's logic; the registration named `main` with #365, and this is that plus a toolchain patch.

## Session and cost

| | |
|---|---|
| cluster | 02:12:27Z apply to 04:01:13Z teardown verified, 1.81 h |
| card | one g5.xlarge Spot, `i-06cc5e1f74dee957b`, scaled up 02:27:49Z, scaled down 03:42:16Z and reported terminated before the destroy began at 03:50:15Z |
| Spot price at purchase | 0.5655 to 0.5850 $/h across three zones, under the $1.00 gate |
| cells | six, all on that one card; each replay spanned 421 to 434 s, and each cell 628 to 657 s from its start line to its completion line |
| teardown | destroy returned zero and every residue query answered empty |

Estimated cost, not a bill: card at most about $0.80 (scale-up to the destroy's start bounds it at 1.37 h, at the highest zone price), cluster about $0.47, NAT data about $3.3 (seven engine starts at 6.18 GiB and one 9.1 GiB image pull, as in run 2), about **$4.6** in all.
