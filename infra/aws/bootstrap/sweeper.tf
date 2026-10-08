# The termination sweeper (docs/superpowers/specs/2026-10-08-measuring-prospective-admission-design.md, build
# item 16): a Lambda run every five minutes that terminates any instance whose study-deadline tag has passed.
#
# ttl.tf's schedule is created per session, after the launch, which leaves the window this closes: AWS accepts a
# RunInstances whose answer is lost, the operator's shell dies, and nothing was ever told the instance exists. The
# deadline here travels on the instance itself, set in RunInstances' own tag specifications, and the sweeper exists
# before any launch.
#
# It must be applied in the account the paid sessions launch in (gpu-lab), because it sweeps only its own account and
# region. The apply is the owner's step, and the exercise in hack/sweeper-exercise.sh must pass after it.

data "archive_file" "sweeper" {
  type        = "zip"
  source_file = "${path.module}/sweeper/sweeper.py"
  output_path = "${path.module}/.build/sweeper.zip"
}

data "aws_iam_policy_document" "sweeper_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }

    # The confused-deputy guard ttl.tf uses for the same reason.
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

data "aws_iam_policy_document" "sweeper" {
  # DescribeInstances cannot be scoped by resource, and without it the sweeper cannot find what to terminate
  # (round 6, finding 7: "TerminateInstances and nothing else" could not).
  statement {
    effect    = "Allow"
    actions   = ["ec2:DescribeInstances"]
    resources = ["*"]
  }

  # Only instances that carry the tag: an instance launched without a deadline is not the sweeper's to end.
  statement {
    effect    = "Allow"
    actions   = ["ec2:TerminateInstances"]
    resources = ["arn:aws:ec2:${var.region}:${data.aws_caller_identity.current.account_id}:instance/*"]

    condition {
      test     = "Null"
      variable = "aws:ResourceTag/study-deadline"
      values   = ["false"]
    }
  }

  statement {
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.sweeper.arn}:*"]
  }
}

resource "aws_iam_role" "sweeper" {
  name               = "gpu-platform-study-sweeper"
  description        = "Assumed by the study sweeper Lambda to terminate instances whose study-deadline tag has passed."
  assume_role_policy = data.aws_iam_policy_document.sweeper_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy" "sweeper" {
  name   = "study-sweeper"
  role   = aws_iam_role.sweeper.id
  policy = data.aws_iam_policy_document.sweeper.json
}

# Created here rather than by the Lambda on first run, so the role needs no logs:CreateLogGroup and the logs expire.
resource "aws_cloudwatch_log_group" "sweeper" {
  name              = "/aws/lambda/gpu-platform-study-sweeper"
  retention_in_days = 30
  tags              = var.tags
}

resource "aws_lambda_function" "sweeper" {
  function_name    = "gpu-platform-study-sweeper"
  description      = "Terminates instances whose study-deadline tag has passed."
  role             = aws_iam_role.sweeper.arn
  runtime          = "python3.12"
  handler          = "sweeper.handler"
  filename         = data.archive_file.sweeper.output_path
  source_code_hash = data.archive_file.sweeper.output_base64sha256
  timeout          = 60
  tags             = var.tags

  depends_on = [aws_iam_role_policy.sweeper, aws_cloudwatch_log_group.sweeper]
}

resource "aws_cloudwatch_event_rule" "sweeper" {
  name                = "gpu-platform-study-sweeper"
  description         = "Runs the study sweeper every five minutes."
  schedule_expression = "rate(5 minutes)"
  tags                = var.tags
}

resource "aws_cloudwatch_event_target" "sweeper" {
  rule = aws_cloudwatch_event_rule.sweeper.name
  arn  = aws_lambda_function.sweeper.arn
}

resource "aws_lambda_permission" "sweeper" {
  statement_id  = "AllowEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.sweeper.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.sweeper.arn
}
