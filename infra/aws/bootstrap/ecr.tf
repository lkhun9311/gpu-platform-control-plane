# The operator image registry.
#
# The lifecycle policy expires only untagged images, never a tag referenced from the default branch.
resource "aws_ecr_repository" "operator" {
  name                 = var.operator_repo_name
  image_tag_mutability = "IMMUTABLE"
  tags                 = var.tags

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
  }
}

resource "aws_ecr_lifecycle_policy" "operator" {
  repository = aws_ecr_repository.operator.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Expire untagged images after 14 days."
      selection = {
        tagStatus   = "untagged"
        countType   = "sinceImagePushed"
        countUnit   = "days"
        countNumber = 14
      }
      action = {
        type = "expire"
      }
    }]
  })
}
