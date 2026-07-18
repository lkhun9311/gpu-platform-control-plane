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

variable "tags" {
  description = "Owner and TTL tags applied to every resource."
  type        = map(string)
  default = {
    project = "gpu-platform-control-plane"
    owner   = "lkhun9311"
    ttl     = "ephemeral"
  }
}
