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
# The cluster module creates IAM roles at apply time, so before real provisioning this role needs IAM-creation permission added (for example an IAMFullAccess attachment).
#
# That expansion is deferred to the provisioning step and is intentionally not applied here.
#
# The apply role's permissions are broad by necessity (VPC, EKS, IAM, node groups).
#
# This is scoped to the demo account, not a production least-privilege set, and is labeled as such.
resource "aws_iam_role_policy_attachment" "ci_apply_admin" {
  role       = aws_iam_role.ci_apply.name
  policy_arn = "arn:aws:iam::aws:policy/PowerUserAccess"
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
    resources = [aws_ecr_repository.operator.arn]
  }
}

resource "aws_iam_role_policy" "ci_image_push" {
  name   = "ecr-push"
  role   = aws_iam_role.ci_image_push.id
  policy = data.aws_iam_policy_document.ci_image_push.json
}
