locals {
  lambda_zip = var.lambda_zip == null ? "${path.module}/lambdas/runner-binaries-syncer/runner-binaries-syncer.zip" : var.lambda_zip
  role_path  = var.role_path == null ? "/${var.prefix}/" : var.role_path
  gh_binary_os_label = {
    windows = "win",
    linux   = "linux"
  }
}

resource "aws_lambda_function" "syncer" {
  s3_bucket         = var.lambda_s3_bucket != null ? var.lambda_s3_bucket : null
  s3_key            = var.syncer_lambda_s3_key != null ? var.syncer_lambda_s3_key : null
  s3_object_version = var.syncer_lambda_s3_object_version != null ? var.syncer_lambda_s3_object_version : null
  filename          = var.lambda_s3_bucket == null ? local.lambda_zip : null
  source_code_hash  = var.lambda_s3_bucket == null ? filebase64sha256(local.lambda_zip) : null
  function_name     = "${var.prefix}-syncer"
  role              = aws_iam_role.syncer_lambda.arn
  handler           = "index.handler"
  runtime           = "nodejs14.x"
  timeout           = var.lambda_timeout
  memory_size       = 256

  environment {
    variables = {
      GITHUB_RUNNER_ALLOW_PRERELEASE_BINARIES = var.runner_allow_prerelease_binaries
      GITHUB_RUNNER_ARCHITECTURE              = var.runner_architecture
      GITHUB_RUNNER_OS                        = local.gh_binary_os_label[var.runner_os]
      LOG_LEVEL                               = var.log_level
      LOG_TYPE                                = var.log_type
      S3_BUCKET_NAME                          = aws_s3_bucket.action_dist.id
      S3_OBJECT_KEY                           = local.action_runner_distribution_object_key
      S3_SSE_ALGORITHM                        = try(var.server_side_encryption_configuration.rule.apply_server_side_encryption_by_default.sse_algorithm, null)
      S3_SSE_KMS_KEY_ID                       = try(var.server_side_encryption_configuration.rule.apply_server_side_encryption_by_default.kms_master_key_id, null)
    }
  }

  dynamic "vpc_config" {
    for_each = var.lambda_subnet_ids != null && var.lambda_security_group_ids != null ? [true] : []
    content {
      security_group_ids = var.lambda_security_group_ids
      subnet_ids         = var.lambda_subnet_ids
    }
  }

  tags = var.tags
}

resource "aws_iam_role_policy" "lambda_kms" {
  count = try(var.server_side_encryption_configuration.rule.apply_server_side_encryption_by_default.kms_master_key_id, null) != null ? 1 : 0
  name  = "${var.environment}-lambda-kms-policy-syncer"
  role  = aws_iam_role.syncer_lambda.id

  policy = templatefile("${path.module}/policies/lambda-kms.json", {
    kms_key_arn = var.server_side_encryption_configuration.rule.apply_server_side_encryption_by_default.kms_master_key_id
  })
}

resource "aws_cloudwatch_log_group" "syncer" {
  name              = "/aws/lambda/${aws_lambda_function.syncer.function_name}"
  retention_in_days = var.logging_retention_in_days
  kms_key_id        = var.logging_kms_key_id
  tags              = var.tags
}

resource "aws_iam_role" "syncer_lambda" {
  name                 = "${var.prefix}-action-syncer-lambda-role"
  assume_role_policy   = data.aws_iam_policy_document.lambda_assume_role_policy.json
  path                 = local.role_path
  permissions_boundary = var.role_permissions_boundary

  tags = var.tags
}

data "aws_iam_policy_document" "lambda_assume_role_policy" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }

    dynamic "principals" {
      for_each = var.lambda_principals

      content {
        type        = principals.value.type
        identifiers = principals.value.identifiers
      }
    }
  }
}

resource "aws_iam_role_policy" "lambda_logging" {
  name = "${var.prefix}-lambda-logging-policy-syncer"
  role = aws_iam_role.syncer_lambda.id

  policy = templatefile("${path.module}/policies/lambda-cloudwatch.json", {
    log_group_arn = aws_cloudwatch_log_group.syncer.arn
  })
}

resource "aws_iam_role_policy" "syncer" {
  name = "${var.prefix}-lambda-syncer-s3-policy"
  role = aws_iam_role.syncer_lambda.id

  policy = templatefile("${path.module}/policies/lambda-syncer.json", {
    s3_resource_arn = "${aws_s3_bucket.action_dist.arn}/${local.action_runner_distribution_object_key}"
  })
}

resource "aws_cloudwatch_event_rule" "syncer" {
  name                = "${var.prefix}-syncer-rule"
  schedule_expression = var.lambda_schedule_expression
  tags                = var.tags
}

resource "aws_cloudwatch_event_target" "syncer" {
  rule = aws_cloudwatch_event_rule.syncer.name
  arn  = aws_lambda_function.syncer.arn
}

resource "aws_lambda_permission" "syncer" {
  statement_id  = "AllowExecutionFromCloudWatch"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.syncer.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.syncer.arn
}

###################################################################################
### Extra trigger to trigger from S3 to execute the lambda after first deployment
###################################################################################

resource "aws_s3_object" "trigger" {
  bucket = aws_s3_bucket.action_dist.id
  key    = "triggers/${aws_lambda_function.syncer.id}-trigger.json"
  source = "${path.module}/trigger.json"
  etag   = filemd5("${path.module}/trigger.json")

  depends_on = [aws_s3_bucket_notification.on_deploy]
}

resource "aws_s3_bucket_notification" "on_deploy" {
  bucket = aws_s3_bucket.action_dist.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.syncer.arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "triggers/"
    filter_suffix       = ".json"
  }

  depends_on = [aws_lambda_permission.on_deploy]
}

data "aws_caller_identity" "current" {}

resource "aws_lambda_permission" "on_deploy" {
  statement_id   = "AllowExecutionFromS3Bucket"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.syncer.arn
  principal      = "s3.amazonaws.com"
  source_account = data.aws_caller_identity.current.account_id
  source_arn     = aws_s3_bucket.action_dist.arn
}
