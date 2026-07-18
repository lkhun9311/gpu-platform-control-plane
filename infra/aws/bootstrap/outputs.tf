output "state_bucket" {
  description = "S3 bucket name for Terraform state."
  value       = aws_s3_bucket.state.id
}

output "lock_table" {
  description = "DynamoDB table name for Terraform locks."
  value       = aws_dynamodb_table.lock.name
}

output "state_kms_key_arn" {
  description = "KMS key ARN encrypting the state bucket."
  value       = aws_kms_key.state.arn
}

output "operator_repo_url" {
  description = "ECR repository URL for the operator image."
  value       = aws_ecr_repository.operator.repository_url
}
