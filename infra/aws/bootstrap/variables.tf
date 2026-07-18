variable "region" {
  description = "AWS region for the state backend and registry."
  type        = string
  default     = "us-east-1"
}

variable "state_bucket_name" {
  description = "Globally unique S3 bucket name for Terraform state."
  type        = string
}

variable "lock_table_name" {
  description = "DynamoDB table name for Terraform state locks."
  type        = string
  default     = "gpu-platform-tf-lock"
}

variable "operator_repo_name" {
  description = "ECR repository name for the operator image."
  type        = string
  default     = "gpu-platform-operator"
}

variable "state_key_user_arns" {
  description = "IAM role ARNs allowed to use the state KMS key for encrypt and decrypt."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Owner and TTL tags applied to every resource."
  type        = map(string)
  default = {
    project = "gpu-platform-control-plane"
    owner   = "lkhun9311"
    ttl     = "ephemeral"
  }
}

variable "github_repo" {
  description = "owner/name of the GitHub repository allowed to assume the CI roles."
  type        = string
}

# job_workflow_ref is not an AWS IAM trust condition key.
#
# Workflow identity, if it must be pinned, is encoded through GitHub's customized sub template, not here.
#
# Immutable owner/repo-ID sub claims require opt-in for repos created before 2026-07-15 (this one).
#
# This toggle stays off until that opt-in is enabled.
variable "use_immutable_sub" {
  description = "Whether the OIDC sub uses immutable owner/repo IDs (requires GitHub opt-in)."
  type        = bool
  default     = false
}
