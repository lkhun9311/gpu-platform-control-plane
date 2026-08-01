# M5-a ephemeral apply → smoke → destroy

The "one thing to do first" from the strategy review: prove the operator runs on **real EKS**, capture sanitized evidence, then destroy everything — closing the "designed but never actually applied" credibility hole. CPU-only (t3.large), no GPU.

Script: [`m5a-ephemeral-runbook.sh`](m5a-ephemeral-runbook.sh). **You run it; it is not run for you** (it creates billable AWS resources).

## Run

```bash
# 1. Dry preflight (no AWS calls) — checks offline tools and prints the quota reminder:
./hack/m5a-ephemeral-runbook.sh

# 2. Real run (creates + destroys real resources):
AWS_PROFILE=<profile> AWS_REGION=us-east-1 M5A_CONFIRM=yes ./hack/m5a-ephemeral-runbook.sh
```

Nothing touches AWS unless `M5A_CONFIRM=yes`.

## What it does

1. **Preflight** — offline tools, `terraform fmt`, then (only with confirm) AWS identity.
2. **Arm an independent TTL kill switch** — a detached watchdog force-destroys after `M5A_TTL_MINUTES` (default 90) **regardless of what happens to the script**. This exists because **AWS Budgets is not an hourly kill switch** (its billing data updates only a few times a day), so a hung script or a closed terminal cannot leave a cluster billing indefinitely.
3. **Apply** — `bootstrap` (state/OIDC/ECR) then `cluster` (VPC, EKS, CPU node group), timed.
4. **Smoke** — kubeconfig, nodes Ready, deploy the operator (CRDs + manager), roll it out, apply a sample CR and let it reconcile.
5. **Capture evidence** — provisioning time, node list, operator pods, sample-CR status, and the tagged-resource inventory, into `storage/.../evidence/m5a-<timestamp>/`.
6. **Destroy** — `cluster` then `bootstrap`, then re-list tagged resources so you can confirm nothing was left behind.

## Before the paid clock

- Check the region's **EKS cluster** and **NAT gateway** limits. This run needs no GPU, so it does not need a G-instance vCPU quota — but that G quota **defaults to 0** on many accounts and will matter for the later M5-b GPU run, so request an increase early.
- Cost is dominated by the EKS control plane ($0.10/cluster-hour) plus NAT/EBS/transfer; keep the run short and confirm the destroy completed.

## Tunables (env)

`AWS_REGION` (us-east-1) · `M5A_CLUSTER` (gpu-platform) · `M5A_TTL_MINUTES` (90) · `M5A_EVIDENCE_DIR` · `M5A_CONFIRM` (must be `yes` to touch AWS).
