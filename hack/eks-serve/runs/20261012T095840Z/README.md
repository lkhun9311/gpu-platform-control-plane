# Serving one request on EKS, 2026-10-12T09:58Z

The paid session `docs/superpowers/specs/2026-10-12-serve-one-request-on-eks-design.md` describes, run by `hack/eks-gitops-session.sh` with `SERVE=yes TTL_MINUTES=180` in gpu-lab, approved by the owner.
Argo CD deployed `main` at `54e29d7`, the commit recorded in `runbook-serve/application-revisions-ready.txt`.
It was preceded the same morning by a kind rehearsal of `main` that passed `apply`, `seed-key`, `verify`, `serve-sync` and `serve-rehearse`.

## What it showed

| bar | evidence | result |
|---|---|---|
| GitOps baseline | `runbook-apply/`, `runbook-seed-key/`, `runbook-verify/` | all 12 declared Applications created, the automated ones Synced/Healthy, `/readyz` 200, a bad key 401, seed-key's `tenant-a` key 403 `no_policy` (that tenant has no policy here) |
| before the card: what a GPU-less cluster can show | `runbook-serve/run.log` | the engine Pod **created** and charged against `gpuquota-serve-a-quota` (used=1), Pending for node affinity, status `Off`, serve-a's key answered 502 `bad_gateway` |
| S1 | `gpu-node.json`, `gpu-plugin-pods.txt` | `nvidia-device-plugin-vltcb` Ready on the GPU node, which advertised `nvidia.com/gpu: 1`; no simulator ran |
| S2 | `runbook-serve/engine-node.json` | the engine ran on a `g5.xlarge` of node group `gpu_single` (`SPOT`, `ap-northeast-2c`, instance `i-0ae491dfa6ee120da`) |
| S3 | `runbook-serve/holdcap-infd.json`, `args-check.txt` | `status.admission.mode` `HoldCap` for generation 1, 459 s after the step began; the engine's arguments matched the 14 measured keys with cap 384 |
| S4 | `runbook-serve/request-first.*`, `gateway-args.txt` | 200, a stream of 20 well-formed frames ending in `[DONE]`, `X-Engine-Priority: 1`; the live gateway ran with no `-bind-priority` (`["/gateway"]`). The answer: "Sure! Here are three colors: 1. Red 2. Blue 3. Yellow" |
| S5 | `runbook-serve/recover-timeline.txt`, `request-recovered.*` | the engine Pod deleted; status left HoldCap 1 s later and returned 173 s after the deletion, on a Pod with a new UID, generation still 1, with 0 unreadable status reads; a second request then passed as in S4 |
| S6 | `gpu-down.txt`, `billing-after-destroy.txt`, `billing-unasked.txt` | `gpu_single` back to desiredSize 0 and its one instance terminated; after destroy no EKS cluster, instance, NAT gateway, EIP, volume, ASG, load balancer, cluster log group or GPU deadline schedule, every query answered |

What this licenses, in the design's words: the GitOps path deploys the serving chain on EKS, and one tenant's streaming request was routed by the gateway under HoldCap admission to a controller-rendered vLLM engine on an A10G and answered.

## What it did not show

- That the gateway held anything. One request on an idle backend enters at once.
- Any latency, protection, capacity or availability figure.
- Quota metering of the serving Pod on EKS beyond the one charge above.
- A second tenant, or a second replica.

## Timeline and cost

| | UTC |
|---|---|
| `terraform apply` began (billing starts) | 09:58:43 |
| cluster up | 10:10:23 |
| GPU scale-up requested | 10:12:45 |
| GPU scale-down requested | 10:24:27 |
| instance verified terminated, destroy began | by 10:32:26 |
| destroy and residue checks done | 10:46:14 |

Spot price read at purchase (`spot-price.txt`): $0.5792–0.5961/h across the three zones.
An estimate, not a bill:
- GPU: about 20 minutes, roughly $0.20.
- Cluster: about 48 minutes at about $0.26/h, roughly $0.21.
- NAT data: one image pull plus two model downloads, about 21.5 GiB at $0.059/GB, roughly $1.4.
The amount billed is what Cost Explorer reports, once it has the day.

## What went wrong, and what was changed in the copy

- An attempt four minutes earlier (`ex/eks-serve-20261012T095432Z`, not kept) stopped at `terraform init` with "No valid credential sources found". The AWS SSO token had expired at 06:50Z while the cached role credentials were valid until 17:50Z. Terraform tried to refresh the token and failed. Nothing was created; its watchdog was killed by hand. This run exported the role credentials into the environment.
- The run reports one failed check: "the TTL watchdog survived disarming". When checked, PID 2672886 no longer existed and no `sleep 10800` remained. The disarm asked `kill -0` immediately after the kill, and `kill -0` succeeds on a process that has exited and not yet been reaped. Run locally against the same `setsid nohup bash -c` shape, the old check reported survival in 10 of 10 tries. The check is fixed in the same change as this record: it treats a zombie as gone and waits up to five seconds.
- Left out of this copy:
  - `runbook-serve/serve-key.txt` and `runbook-seed-key/seeded-key.txt`, which hold the API keys.
  - `terraform.log`, which holds this machine's address.
  - `ttl.pid`.
- This machine's address is replaced by `<egress-ip>` in `session.log` and `session.out.txt`.
- Files ending `.out` are renamed `.out.txt`, because the repository ignores `*.out`.
