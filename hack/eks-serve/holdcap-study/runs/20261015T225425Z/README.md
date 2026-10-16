# Hold-cap on the product path, on EKS: run 2, 20261015T225425Z

Study `holdcap-product-transfer-r2-2026-10-15`, registered in the design page's "Run 2" section before it ran
(`docs/superpowers/specs/2026-10-15-holdcap-on-the-product-path-design.md`), at tooling commit `89015bc`.
Run 1 (`../20261015T050622Z/README.md`) stands as it was; the two are reported side by side and not pooled.

## Registered verdict: not met

```
verdict: not met
  first failing: block 852, line 3 contender p50 ratio and p95
```

Every cell was complete and valid, so the scorer read every line in every block (`holdcap-study/verdict.txt`):

| block | premium TTFT p99, HoldCap / Off | contender p50, HoldCap against Off (limit 1.5 ×) | contender p95 (limit 25 s) | refusals | preemptions |
|---|---|---|---|---|---|
| 851 | 428.1 / 9,908.0 ms = 0.043 | 4,057 against 3,037 ms (1.34 ×) | 16,625 ms | 0 | 0 |
| 852 | 436.7 / 9,811.4 ms = 0.045 | 7,034 against 4,673 ms (**1.505 ×, fails line 3**) | 15,698 ms | 0 | 0 |
| 853 | 464.4 / 6,191.6 ms = 0.075 | 3,995 against 3,068 ms (1.30 ×) | 9,425 ms | 0 | 0 |

In every block every contender completed and the premium content-event gap p99 was 0.96 to 0.99 of Off's.

## Beside run 1

| | run 1 | run 2 |
|---|---|---|
| registered verdict | not met: one refusal in block 853 | not met: contender median in block 852 |
| premium TTFT p99, HoldCap / Off, by block | 0.040, 0.046, 0.076 | 0.043, 0.045, 0.075 |
| contender median, HoldCap / Off, block 852 | 1.51 × | 1.505 × |
| refusals | one 502, an engine connection reset | none |
| validity | one unreadable sample in block 851 | every cell valid |

What the two runs say together, and only this:

- On these three traces, switching the product's engine from Off to HoldCap cut the premium tenant's scheduled, client-observed TTFT p99 to 4% to 8% of Off's, in both runs, with every contender completing.
- In block 852 the contender's median cost was at the registered 1.5 × limit and over it in both runs, by 0.01 × and 0.005 ×; on that trace this is a property of the treatment against the product's Off, not of one run. Part of it is Off's: it binds no priority, so contenders fare comparatively well under it (median 4,673 ms here, against the lab off's 5,215 ms on the same trace in `docs/superpowers/specs/data/2026-10-09-diagnostic-results/arms.txt`), which makes the denominator small.
- The refusal of run 1 did not recur after #361, which drops idle gateway connections before the engine's keep-alive. One run without it is consistent with that fix, not proof of it.

## Evidence

As in run 1: per cell the derived manifest, `raw.jsonl.gz` (4,019, 4,143 and 4,102 rows), the sender configuration, 64 to 67 samples, metrics before and after, the engine's `non-default args`, the identity after the cell, `sampler.err` (empty in all six) and `SHA256SUMS` of the uncompressed rows; the study's `study-id.txt`, `identity-start.json`, `run.log` and `verdict.txt`; and the session's own records.
Scoring the gzipped copy gave byte-identical output to the session's `verdict.txt`.

Excluded: the three key files, `terraform.log`, `ttl.pid`, the harness binary (its sha256 and commit are recorded) and the warm-up's scratch prompts. The operator's address is masked as `<operator-ip>`, and `runbook-verify/*.out` are renamed `*.out.txt`. No key value appears in any committed file; each was searched for.

## Session and cost

| | |
|---|---|
| cluster | 22:54:58Z apply to 00:44:20Z teardown verified, 1.82 h |
| card | one g5.xlarge Spot, `i-04ffde05dbdbf0744`, scaled up 23:10:30Z, scaled down 00:24:25Z and reported terminated before the destroy began at 00:32:40Z |
| Spot price at purchase | 0.5718 to 0.5883 $/h across three zones, under the $1.00 gate |
| cells | six, 453 to 467 s each, all on that one card |
| teardown | destroy returned zero and every residue query answered empty |

Estimated cost, not a bill: card at most about $0.81 (scale-up to the destroy's start bounds it at 1.37 h, at the highest zone price), cluster about $0.47, NAT data about $3.3 (seven engine starts at 6.18 GiB and one 9.1 GiB image pull), about **$4.6** in all.
