# infra/aws/bootstrap

Creates the Terraform state backend (S3 + DynamoDB), the GitHub OIDC provider,
the CI IAM roles, and the ECR repository. This root is the chicken-and-egg base:
it begins on local state, then migrates into the bucket it just created.

Nothing here is provisioned yet. This is the documented procedure for when it is.

## One-time bootstrap

```bash
cd infra/aws/bootstrap

# 1. Create the backend on local state.
terraform init
terraform apply -var 'state_bucket_name=<globally-unique-name>' -var 'github_repo=lkhun9311/gpu-platform-control-plane'

# 2. Migrate the local state into the bucket just created.
cat > backend.tf <<'HCL'
terraform {
  backend "s3" {
    bucket         = "<globally-unique-name>"
    key            = "bootstrap/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "gpu-platform-tf-lock"
    encrypt        = true
    kms_key_id     = "<state_kms_key_arn from the step 1 output>"
  }
}
HCL
terraform init -migrate-state
```

After migration, `bootstrap` is applied only to rotate identity or the registry,
never on routine cluster work.

## Required GitHub Environment protection (one-time, manual)

The apply role's OIDC trust condition pins the sub to
`repo:<owner/name>:environment:infra-apply`. That condition denies applies from
forked PRs and non-main branches only when the GitHub Environment enforces it.
In the repository settings, create an Environment named `infra-apply` with:

- a deployment branch policy restricting deployments to the `main` branch, and
- at least one required reviewer.

Without this Environment protection, the sub condition alone does not prevent a
workflow edited in a fork from assuming the apply role.

## Unattended teardown note

`destroy.yml` runs on a nightly schedule but uses the `infra-apply` environment
so its OIDC token can assume the apply role. If `infra-apply` requires a
reviewer, the scheduled teardown will pause for manual approval. For fully
unattended teardown, provision a separate `infra-destroy` environment and a
dedicated destroy role whose trust pins `sub` to that environment, without a
reviewer gate.

## Required repository secrets and variables (one-time, manual)

After `terraform apply` of this bootstrap root, set these in the GitHub repo so
the workflows can assume the roles and complete the cluster backend:

Secrets:
- `CI_PLAN_ROLE_ARN` from output `ci_plan_role_arn`
- `CI_APPLY_ROLE_ARN` from output `ci_apply_role_arn`
- `CI_IMAGE_PUSH_ROLE_ARN` from output `ci_image_push_role_arn`

Variables:
- `TF_STATE_BUCKET` from output `state_bucket`
- `TF_LOCK_TABLE` from output `lock_table`
- `TF_STATE_KMS_KEY` from output `state_kms_key_arn`
