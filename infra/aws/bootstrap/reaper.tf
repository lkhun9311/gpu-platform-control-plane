# The session reaper (docs/superpowers/specs/2026-11-07-session-cloud-safety-design.md, proposals P1 and P2 of the r5
# review): a Lambda run every five minutes that acts on session leases in Parameter Store.
#
# The kill switch's watchdog runs on the laptop that started the session; if that machine loses power, the EKS control
# plane, the NAT gateway, its address and the EFS file system bill until someone notices, because the GPU schedule in
# ttl.tf only scales the GPU group down, and only once. The reaper is that someone: authenticated by its own role, it
# holds a lease's GPU groups at zero after the GPU deadline, and deletes the session's billing resources after the
# session deadline, a step per run, then removes the lease.
#
# It lives here for the reason the sweeper does: it must exist before any session creates anything, and outlive them all.
# Its own cost is one invocation every five minutes and a log group.

data "archive_file" "reaper" {
  type        = "zip"
  source_file = "${path.module}/reaper/reaper.py"
  output_path = "${path.module}/.build/reaper.zip"
}

locals {
  reaper_lease_path = "/gpu-platform/session-lease/"
  reaper_project    = var.tags["project"]
}

data "aws_iam_policy_document" "reaper_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
    # No aws:SourceAccount condition, as for the sweeper: Lambda does not supply it when assuming an execution role.
  }
}

data "aws_iam_policy_document" "reaper" {
  # The leases: read every one, and remove one once its session is gone. Nothing writes them but the session runner.
  statement {
    effect    = "Allow"
    actions   = ["ssm:GetParametersByPath"]
    resources = ["arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter${trimsuffix(local.reaper_lease_path, "/")}"]
  }
  statement {
    effect    = "Allow"
    actions   = ["ssm:DeleteParameter"]
    resources = ["arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter${local.reaper_lease_path}*"]
  }

  # Reads, which cannot be scoped by tag.
  statement {
    effect = "Allow"
    actions = [
      "eks:DescribeCluster", "eks:ListNodegroups", "eks:DescribeNodegroup",
      "autoscaling:DescribeAutoScalingGroups",
      "ec2:DescribeVpcs", "ec2:DescribeNatGateways", "ec2:DescribeAddresses",
      "elasticfilesystem:DescribeFileSystems", "elasticfilesystem:DescribeMountTargets",
    ]
    resources = ["*"]
  }

  # Every change only on a resource carrying the project tag; the code checks it too, and this is the check the code
  # cannot get wrong.
  statement {
    effect    = "Allow"
    actions   = ["eks:UpdateNodegroupConfig", "eks:DeleteNodegroup"]
    resources = ["arn:aws:eks:${var.region}:${data.aws_caller_identity.current.account_id}:nodegroup/*/*/*"]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/project"
      values   = [local.reaper_project]
    }
  }
  statement {
    effect    = "Allow"
    actions   = ["eks:DeleteCluster"]
    resources = ["arn:aws:eks:${var.region}:${data.aws_caller_identity.current.account_id}:cluster/*"]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/project"
      values   = [local.reaper_project]
    }
  }
  statement {
    effect    = "Allow"
    actions   = ["ec2:DeleteNatGateway"]
    resources = ["arn:aws:ec2:${var.region}:${data.aws_caller_identity.current.account_id}:natgateway/*"]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/project"
      values   = [local.reaper_project]
    }
  }
  statement {
    effect    = "Allow"
    actions   = ["ec2:ReleaseAddress"]
    resources = ["arn:aws:ec2:${var.region}:${data.aws_caller_identity.current.account_id}:elastic-ip/*"]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/project"
      values   = [local.reaper_project]
    }
  }
  statement {
    effect    = "Allow"
    actions   = ["elasticfilesystem:DeleteMountTarget", "elasticfilesystem:DeleteFileSystem"]
    resources = ["arn:aws:elasticfilesystem:${var.region}:${data.aws_caller_identity.current.account_id}:file-system/*"]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/project"
      values   = [local.reaper_project]
    }
  }

  statement {
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.reaper.arn}:*"]
  }
}

resource "aws_iam_role" "reaper" {
  name               = "gpu-platform-session-reaper"
  description        = "Assumed by the session reaper Lambda to scale down and delete a paid session's resources after its lease's deadlines."
  assume_role_policy = data.aws_iam_policy_document.reaper_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy" "reaper" {
  name   = "session-reaper"
  role   = aws_iam_role.reaper.id
  policy = data.aws_iam_policy_document.reaper.json
}

resource "aws_cloudwatch_log_group" "reaper" {
  name              = "/aws/lambda/gpu-platform-session-reaper"
  retention_in_days = 30
  tags              = var.tags
}

resource "aws_lambda_function" "reaper" {
  function_name    = "gpu-platform-session-reaper"
  description      = "Holds a session lease's GPU groups at zero after its GPU deadline and deletes the session's billing resources after its session deadline."
  role             = aws_iam_role.reaper.arn
  runtime          = "python3.12"
  handler          = "reaper.handler"
  filename         = data.archive_file.reaper.output_path
  source_code_hash = data.archive_file.reaper.output_base64sha256
  # A run asks and returns; it never waits for a deletion. 120 s covers the reads of every lease with their retries.
  timeout = 120
  # One run at a time, so two runs never ask for the same deletion at once.
  reserved_concurrent_executions = 1
  environment {
    variables = {
      LEASE_PATH  = local.reaper_lease_path
      PROJECT_TAG = local.reaper_project
    }
  }
  tags = var.tags

  depends_on = [aws_iam_role_policy.reaper, aws_cloudwatch_log_group.reaper]
}

resource "aws_cloudwatch_event_rule" "reaper" {
  name                = "gpu-platform-session-reaper"
  description         = "Runs the session reaper every five minutes."
  schedule_expression = "rate(5 minutes)"
  tags                = var.tags
}

resource "aws_cloudwatch_event_target" "reaper" {
  rule = aws_cloudwatch_event_rule.reaper.name
  arn  = aws_lambda_function.reaper.arn
}

resource "aws_lambda_permission" "reaper" {
  statement_id  = "AllowEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.reaper.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.reaper.arn
}
