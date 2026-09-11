output "app_instance_id" {
  value = aws_instance.app.id
}

output "app_public_ip" {
  value = aws_instance.app.public_ip
}

output "app_url" {
  value = "http://${aws_instance.app.public_ip}:5000/api/work"
}

output "telemetry_bucket" {
  value = aws_s3_bucket.telemetry_archive.bucket
}

output "rca_findings_table" {
  value = aws_dynamodb_table.rca_findings.name
}

output "incidents_table" {
  value = aws_dynamodb_table.incidents.name
}

output "sns_topic_arn" {
  value = aws_sns_topic.rca_alerts.arn
}
