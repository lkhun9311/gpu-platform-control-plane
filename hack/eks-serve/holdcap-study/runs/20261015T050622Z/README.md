# Hold-cap on the product path, on EKS: run 20261015T050622Z

The registration is `docs/superpowers/specs/2026-10-15-holdcap-on-the-product-path-design.md` (draft v2, at tooling commit `8fb836a`).
Scored by `hack/eks-serve/holdcap-study/score.py`, unchanged in its rules since the registration.

## Registered verdict: not met

```
verdict: not met
  block 853: 1 refusal(s), 0 preemption(s) under HoldCap
```

The registration puts a refusal or preemption in a HoldCap cell first, whatever any comparison's validity, so the scorer stopped there.
That refusal was one premium request (index 657, 65.9 s into trace 853) answered with HTTP 502.
The gateway's log (`holdcap-study/gateway-log-after-study.txt`, captured before the teardown) records it as
`upstream request failed ... read tcp 10.0.75.35:49360->172.20.103.212:8000: read: connection reset by peer`:
the engine reset one connection the gateway sent it on.
It was not a hold-timeout refusal; the request had been admitted as premium and never held.
Why the engine reset it is not established by this evidence.

## Every line, read by the same scorer: also not met

`holdcap-study/secondary-reading.txt` prints every block's validity and comparative lines with `score.py`'s own functions, unchanged.
It is descriptive and does not replace the verdict above. It shows the run would not have met the registration on any reading:

| block | premium TTFT p99, HoldCap / Off | contender p50, HoldCap against Off (limit 1.5 ×) | contender p95 (limit 25 s) | other |
|---|---|---|---|---|
| 851 | 405.1 / 10,006.4 ms = 0.040 | 4,031 against 3,103 ms (1.30 ×) | 16,831 ms | HoldCap cell invalid: one of 59 samples could not read the gateway's gauge |
| 852 | 461.6 / 9,970.6 ms = 0.046 | 7,190 against 4,761 ms (**1.51 ×, fails line 3**) | 15,925 ms | — |
| 853 | 474.1 / 6,232.7 ms = 0.076 | 3,975 against 3,069 ms (1.30 ×) | 9,614 ms | **one refusal, line 4** |

In all three blocks every contender completed, no preemption was counted, and the premium content-event gap p99 was 0.97 to 0.98 of Off's.

What these say, and only this:

- Switching the InferenceDeployment from Off to HoldCap cut the premium tenant's scheduled, client-observed TTFT p99 to 4% to 8% of the product's Off on these three traces.
- The cost to the contender was over the registered median limit in one block, by 0.01 ×.
- The product's Off is not the lab's off: it binds no priority, so premium requests wait first-come behind 40,000-character contender prefills, and its premium p99 was 6.2 to 10.0 s against the lab off's 1.47 to 1.52 s (`docs/superpowers/specs/data/2026-10-09-diagnostic-results/arms.txt`). The ratios above are therefore not comparable with the lab's 0.30, as the registration says.

The unreadable sample in block 851 is a failed read by the collector, not a sample showing another mode; the registration counts it as a validity failure, and so does this record.

## Evidence

- `holdcap-study/cells/<seed>-<arm>/`: per cell, the derived manifest, `raw.jsonl.gz` (4,019, 4,143 and 4,102 rows, one per trace request), the sender configuration, 59 to 66 status samples, engine and gateway metrics before and after, the engine's `non-default args`, the identity after the cell, and `SHA256SUMS` (of the uncompressed rows).
  The rows are gzipped to keep the repository small; `score.py` reads the `.gz` when the plain file is absent, and scoring the gzipped copy gave byte-identical output to the plain one.
- `holdcap-study/identity-start.json`: Argo revisions (`main` at `ef925c4`), operator and gateway images and Pods, and the GPU node; every cell's `identity-after.json` matched it on the Argo revisions and node.
- `holdcap-study/run.log`, `verdict.txt`, `secondary-reading.txt`, `gateway-log-after-study.txt`, `tenants-applied.yaml`, `resourcequotas.yaml`, `collector-pod.json`, `benchharness.sha256`, `tooling-commit.txt`.
- The session's own records: `session.log`, `spot-price.txt`, `gpu-*.txt`, `runbook-*/`, and the teardown checks.

Excluded: the three key files, `terraform.log`, `ttl.pid`, the harness binary (its sha256 and commit are recorded), and the warm-up's scratch prompt files. The operator's address is masked as `<operator-ip>`. The three `runbook-verify/*.out` files are renamed `*.out.txt`, which the repository's ignore rules admit.

## Session and cost

| | |
|---|---|
| cluster | 05:07:18Z apply to 06:56:58Z teardown verified, 1.83 h |
| card | one g5.xlarge Spot, `i-05ac98ff8ed63f069` in `gpu_single`, scaled up 05:23:05Z, scaled down 06:37:45Z and reported terminated by about 06:41Z, about 1.3 h |
| Spot price at purchase | 0.5728 to 0.5895 $/h across three zones, under the $1.00 gate |
| cells | six, 451 to 469 s each from start to end, all on that one card |
| teardown | destroy returned zero and every residue query answered empty |

Estimated cost, not a bill: card about $0.77 (1.3 h at the highest zone price), cluster about $0.48 (1.83 h at $0.26), NAT data about $3.3 (seven engine starts at 6.18 GiB of model and one 9.1 GiB image pull, at $0.059 per GB), about **$4.6** in all.
