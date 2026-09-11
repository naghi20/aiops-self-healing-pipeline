variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Short name used as a prefix for resource naming"
  type        = string
  default     = "aiops-demo"
}

variable "instance_type" {
  description = "EC2 instance type for the demo workload"
  type        = string
  default     = "t3.micro"
}

variable "key_pair_name" {
  description = "Existing EC2 key pair name for SSH access (leave blank to disable SSH key access and use SSM Session Manager instead)"
  type        = string
  default     = ""
}

variable "my_ip_cidr" {
  description = "Your IP in CIDR form, e.g. 203.0.113.4/32, allowed to reach the app on port 5000 and SSH on 22. Do not leave as 0.0.0.0/0."
  type        = string
}

variable "slack_webhook_url" {
  description = "Slack incoming webhook URL used by the chatops_notifier Lambda"
  type        = string
  sensitive   = true
  default     = ""
}

variable "high_confidence_alarm_names" {
  description = "CloudWatch alarm names that are allowed to trigger automated self-healing (SSM Automation) rather than notify-only"
  type        = list(string)
  default     = ["aiops-demo-cpu-anomaly", "aiops-demo-error-anomaly"]
}
