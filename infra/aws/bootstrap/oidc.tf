data "tls_certificate" "github" {
  url = "https://token.actions.githubusercontent.com/.well-known/openid-configuration"
}

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github.certificates[0].sha1_fingerprint]
  tags            = var.tags
}

# The plan role is assumed from pull_request contexts and is read-only.
data "aws_iam_policy_document" "ci_plan_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repo}:pull_request"]
    }
  }
}

resource "aws_iam_role" "ci_plan" {
  name               = "gpu-platform-ci-plan"
  assume_role_policy = data.aws_iam_policy_document.ci_plan_trust.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "ci_plan_readonly" {
  role       = aws_iam_role.ci_plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# ReadOnlyAccess covers reading state from S3 but not the lock write or the state decrypt that plan needs.
#
# The lock used to be a DynamoDB row, so this policy used to grant GetItem/PutItem/DeleteItem on the table.
# With the backend's use_lockfile the lock is an object next to the state, so the grant follows it there:
# write and delete on *.tflock, and nothing else in the bucket. ReadOnlyAccess still supplies the reads.
#
# Scoped to the suffix rather than the whole bucket on purpose -- plan must be able to take a lock and must
# not be able to overwrite a state file.
data "aws_iam_policy_document" "ci_plan_state" {
  statement {
    effect = "Allow"

    actions = [
      "s3:PutObject",
      "s3:DeleteObject",
    ]

    resources = ["${aws_s3_bucket.state.arn}/*.tflock"]
  }

  statement {
    effect = "Allow"

    actions = [
      "kms:Decrypt",
      "kms:GenerateDataKey",
    ]

    resources = [aws_kms_key.state.arn]
  }
}

resource "aws_iam_role_policy" "ci_plan_state" {
  name   = "tf-state-access"
  role   = aws_iam_role.ci_plan.id
  policy = data.aws_iam_policy_document.ci_plan_state.json
}

# The apply role is assumed only from the protected GitHub Environment named infra-apply.
#
# This sub condition denies forked-PR and non-main assumption only when the infra-apply Environment has a deployment branch policy restricting it to main.
#
# That GitHub-side protection rule is a one-time manual setup documented in README.md.
data "aws_iam_policy_document" "ci_apply_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repo}:environment:infra-apply"]
    }
  }
}

resource "aws_iam_role" "ci_apply" {
  name               = "gpu-platform-ci-apply"
  assume_role_policy = data.aws_iam_policy_document.ci_apply_trust.json
  tags               = var.tags
}

# PowerUserAccess excludes IAM role and policy creation.
#
# The cluster module creates IAM roles at apply time, so this role needs IAM-creation permission too.
#
# The companion aws_iam_role_policy_attachment.ci_apply_iam attachment below supplies that permission.
#
# The apply role's permissions are broad by necessity (VPC, EKS, IAM, node groups).
#
# This is scoped to the demo account, not a production least-privilege set, and is labeled as such.
resource "aws_iam_role_policy_attachment" "ci_apply_admin" {
  role       = aws_iam_role.ci_apply.name
  policy_arn = "arn:aws:iam::aws:policy/PowerUserAccess"
}

# PowerUserAccess excludes IAM management, but the EKS module creates IAM roles at apply time.
#
# This companion attachment supplies the IAM permissions the cluster provisioning needs.
resource "aws_iam_role_policy_attachment" "ci_apply_iam" {
  role       = aws_iam_role.ci_apply.name
  policy_arn = "arn:aws:iam::aws:policy/IAMFullAccess"
}

# The image-push role is assumed from the default branch to push the operator image.
data "aws_iam_policy_document" "ci_image_push_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repo}:ref:refs/heads/main"]
    }
  }
}

resource "aws_iam_role" "ci_image_push" {
  name               = "gpu-platform-ci-image-push"
  assume_role_policy = data.aws_iam_policy_document.ci_image_push_trust.json
  tags               = var.tags
}

data "aws_iam_policy_document" "ci_image_push" {
  statement {
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
    ]
    # Both repositories, because the gateway is now published by CI too. Scoped to these two rather than
    # ecr:* so the push role cannot write to a repository nobody reviewed.
    resources = [
      aws_ecr_repository.operator.arn,
      aws_ecr_repository.gateway.arn,
    ]
  }
}

resource "aws_iam_role_policy" "ci_image_push" {
  name   = "ecr-push"
  role   = aws_iam_role.ci_image_push.id
  policy = data.aws_iam_policy_document.ci_image_push.json
}
