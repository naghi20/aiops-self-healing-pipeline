resource "aws_sns_topic" "rca_alerts" {
  name = "${var.project_name}-rca-alerts"
}

# --- CPU anomaly band + alarm ---
resource "aws_cloudwatch_metric_alarm" "cpu_anomaly" {
  alarm_name          = "${var.project_name}-cpu-anomaly"
  comparison_operator = "GreaterThanUpperThreshold"
  evaluation_periods   = 2
  threshold_metric_id  = "ad1"
  alarm_description    = "CPU utilization outside the ML-predicted band"
  treat_missing_data    = "notBreaching"

  metric_query {
    id          = "m1"
    return_data = true
    metric {
      metric_name = "CPUUtilization"
      namespace   = "AWS/EC2"
      period      = 60
      stat        = "Average"
      dimensions = {
        InstanceId = aws_instance.app.id
      }
    }
  }

  metric_query {
    id          = "ad1"
    expression  = "ANOMALY_DETECTION_BAND(m1, 3)"
    label       = "CPUUtilization (expected)"
    return_data = true
  }

  alarm_actions = [aws_sns_topic.rca_alerts.arn]
}

# --- Custom app error count (from the demo app's own logging - via a
#     metric filter over the shipped log group) ---
resource "aws_cloudwatch_log_metric_filter" "app_errors" {
  name           = "${var.project_name}-app-error-count"
  log_group_name = aws_cloudwatch_log_group.app_logs.name
  pattern        = "ERROR"

  metric_transformation {
    name      = "AppErrorCount"
    namespace = "AIOpsDemo"
    value     = "1"
    default_value = 0
  }
}

resource "aws_cloudwatch_metric_alarm" "error_anomaly" {
  alarm_name          = "${var.project_name}-error-anomaly"
  comparison_operator = "GreaterThanUpperThreshold"
  evaluation_periods   = 2
  threshold_metric_id  = "ad1"
  alarm_description    = "App error rate outside the ML-predicted band"
  treat_missing_data    = "notBreaching"

  metric_query {
    id          = "m1"
    return_data = true
    metric {
      metric_name = aws_cloudwatch_log_metric_filter.app_errors.metric_transformation[0].name
      namespace   = aws_cloudwatch_log_metric_filter.app_errors.metric_transformation[0].namespace
      period      = 60
      stat        = "Sum"
    }
  }

  metric_query {
    id          = "ad1"
    expression  = "ANOMALY_DETECTION_BAND(m1, 3)"
    label       = "AppErrorCount (expected)"
    return_data = true
  }

  alarm_actions = [aws_sns_topic.rca_alerts.arn]
}
