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
  }
}
HCL
terraform init -migrate-state
```

After migration, `bootstrap` is applied only to rotate identity or the registry,
never on routine cluster work.
