resource "random_id" "bucket_suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "telemetry_archive" {
  bucket = "${var.project_name}-telemetry-archive-${random_id.bucket_suffix.hex}"
}

resource "aws_s3_bucket_lifecycle_configuration" "telemetry_archive" {
  bucket = aws_s3_bucket.telemetry_archive.id

  rule {
    id     = "expire-raw-logs"
    status = "Enabled"
    expiration {
      days = 14
    }
  }
}

resource "aws_kinesis_stream" "telemetry" {
  name             = "${var.project_name}-telemetry-stream"
  shard_count      = 1
  retention_period = 24
}

# --- Firehose: Kinesis Stream -> S3 ---
resource "aws_iam_role" "firehose" {
  name = "${var.project_name}-firehose-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "firehose.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "firehose" {
  name = "${var.project_name}-firehose-policy"
  role = aws_iam_role.firehose.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["s3:AbortMultipartUpload", "s3:GetBucketLocation", "s3:GetObject", "s3:ListBucket", "s3:ListBucketMultipartUploads", "s3:PutObject"]
        Resource = [
          aws_s3_bucket.telemetry_archive.arn,
          "${aws_s3_bucket.telemetry_archive.arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = ["kinesis:DescribeStream", "kinesis:GetShardIterator", "kinesis:GetRecords", "kinesis:ListShards"]
        Resource = aws_kinesis_stream.telemetry.arn
      }
    ]
  })
}

resource "aws_kinesis_firehose_delivery_stream" "telemetry_to_s3" {
  name        = "${var.project_name}-telemetry-to-s3"
  destination = "extended_s3"

  kinesis_source_configuration {
    kinesis_stream_arn = aws_kinesis_stream.telemetry.arn
    role_arn            = aws_iam_role.firehose.arn
  }

  extended_s3_configuration {
    role_arn           = aws_iam_role.firehose.arn
    bucket_arn          = aws_s3_bucket.telemetry_archive.arn
    prefix              = "raw/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/"
    error_output_prefix = "errors/"
    buffering_size       = 5
    buffering_interval    = 60
    compression_format   = "GZIP"
  }
}

# --- CloudWatch Logs -> Kinesis subscription filter ---
resource "aws_iam_role" "cwl_to_kinesis" {
  name = "${var.project_name}-cwl-to-kinesis-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "logs.${var.aws_region}.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "cwl_to_kinesis" {
  name = "${var.project_name}-cwl-to-kinesis-policy"
  role = aws_iam_role.cwl_to_kinesis.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["kinesis:PutRecord"]
      Resource = aws_kinesis_stream.telemetry.arn
    }]
  })
}

resource "aws_cloudwatch_log_subscription_filter" "app_logs_to_kinesis" {
  name            = "${var.project_name}-app-logs-to-kinesis"
  log_group_name  = aws_cloudwatch_log_group.app_logs.name
  filter_pattern  = ""
  destination_arn = aws_kinesis_stream.telemetry.arn
  role_arn        = aws_iam_role.cwl_to_kinesis.arn
}
