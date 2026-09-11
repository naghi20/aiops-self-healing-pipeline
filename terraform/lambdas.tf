data "archive_file" "correlation_rca" {
  type        = "zip"
  source_file = "${path.module}/../lambdas/correlation_rca/handler.py"
  output_path = "${path.module}/build/correlation_rca.zip"
}

data "archive_file" "incident_lifecycle" {
  type        = "zip"
  source_file = "${path.module}/../lambdas/incident_lifecycle/handler.py"
  output_path = "${path.module}/build/incident_lifecycle.zip"
}

data "archive_file" "chatops_notifier" {
  type        = "zip"
  source_file = "${path.module}/../lambdas/chatops_notifier/handler.py"
  output_path = "${path.module}/build/chatops_notifier.zip"
}

# --- Shared Lambda execution role ---
resource "aws_iam_role" "lambda_role" {
  name = "${var.project_name}-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic_logs" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "lambda_permissions" {
  name = "${var.project_name}-lambda-permissions"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:Scan", "dynamodb:Query"]
        Resource = [
          aws_dynamodb_table.cmdb_assets.arn,
          aws_dynamodb_table.rca_findings.arn,
          aws_dynamodb_table.incidents.arn
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = aws_sns_topic.rca_alerts.arn
      },
      {
        Effect   = "Allow"
        Action   = ["ssm:StartAutomationExecution"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["iam:PassRole"]
        Resource = aws_iam_role.automation_assume_role.arn
      },
      {
        Effect   = "Allow"
        Action   = ["cloudwatch:DescribeAlarms"]
        Resource = "*"
      }
    ]
  })
}

# --- correlation_rca ---
resource "aws_lambda_function" "correlation_rca" {
  function_name    = "${var.project_name}-correlation-rca"
  role              = aws_iam_role.lambda_role.arn
  handler           = "handler.handler"
  runtime           = "python3.12"
  timeout           = 30
  filename          = data.archive_file.correlation_rca.output_path
  source_code_hash  = data.archive_file.correlation_rca.output_base64sha256

  environment {
    variables = {
      CMDB_TABLE_NAME        = aws_dynamodb_table.cmdb_assets.name
      RCA_TABLE_NAME          = aws_dynamodb_table.rca_findings.name
      SNS_TOPIC_ARN           = aws_sns_topic.rca_alerts.arn
      SSM_RUNBOOK_NAME        = aws_ssm_document.restart_service.name
      HIGH_CONFIDENCE_ALARMS  = join(",", var.high_confidence_alarm_names)
    }
  }
}

resource "aws_cloudwatch_event_rule" "alarm_state_change" {
  name = "${var.project_name}-alarm-state-change"
  event_pattern = jsonencode({
    source      = ["aws.cloudwatch"]
    "detail-type" = ["CloudWatch Alarm State Change"]
    detail = {
      state = { value = ["ALARM"] }
      alarmName = var.high_confidence_alarm_names
    }
  })
}

resource "aws_cloudwatch_event_target" "alarm_to_correlation_lambda" {
  rule = aws_cloudwatch_event_rule.alarm_state_change.name
  arn  = aws_lambda_function.correlation_rca.arn
}

resource "aws_lambda_permission" "allow_eventbridge_alarm" {
  statement_id  = "AllowEventBridgeAlarmInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.correlation_rca.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.alarm_state_change.arn
}

# --- incident_lifecycle ---
resource "aws_lambda_function" "incident_lifecycle" {
  function_name    = "${var.project_name}-incident-lifecycle"
  role              = aws_iam_role.lambda_role.arn
  handler           = "handler.handler"
  runtime           = "python3.12"
  timeout           = 30
  filename          = data.archive_file.incident_lifecycle.output_path
  source_code_hash  = data.archive_file.incident_lifecycle.output_base64sha256

  environment {
    variables = {
      INCIDENTS_TABLE_NAME = aws_dynamodb_table.incidents.name
    }
  }
}

resource "aws_sns_topic_subscription" "incident_lifecycle_sub" {
  topic_arn = aws_sns_topic.rca_alerts.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.incident_lifecycle.arn
}

resource "aws_lambda_permission" "allow_sns_incident_lifecycle" {
  statement_id  = "AllowSNSInvokeIncidentLifecycle"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.incident_lifecycle.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.rca_alerts.arn
}

resource "aws_cloudwatch_event_rule" "health_check_sweep" {
  name                = "${var.project_name}-incident-health-check-sweep"
  schedule_expression = "rate(5 minutes)"
}

resource "aws_cloudwatch_event_target" "sweep_target" {
  rule = aws_cloudwatch_event_rule.health_check_sweep.name
  arn  = aws_lambda_function.incident_lifecycle.arn
}

resource "aws_lambda_permission" "allow_eventbridge_sweep" {
  statement_id  = "AllowEventBridgeSweepInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.incident_lifecycle.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.health_check_sweep.arn
}

# --- chatops_notifier ---
resource "aws_lambda_function" "chatops_notifier" {
  function_name    = "${var.project_name}-chatops-notifier"
  role              = aws_iam_role.lambda_role.arn
  handler           = "handler.handler"
  runtime           = "python3.12"
  timeout           = 15
  filename          = data.archive_file.chatops_notifier.output_path
  source_code_hash  = data.archive_file.chatops_notifier.output_base64sha256

  environment {
    variables = {
      SLACK_WEBHOOK_URL = var.slack_webhook_url
    }
  }
}

resource "aws_sns_topic_subscription" "chatops_notifier_sub" {
  topic_arn = aws_sns_topic.rca_alerts.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.chatops_notifier.arn
}

resource "aws_lambda_permission" "allow_sns_chatops" {
  statement_id  = "AllowSNSInvokeChatops"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.chatops_notifier.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.rca_alerts.arn
}
