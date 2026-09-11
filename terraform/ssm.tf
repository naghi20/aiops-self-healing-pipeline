resource "aws_iam_role" "automation_assume_role" {
  name = "${var.project_name}-automation-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ssm.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "automation_ssm" {
  role       = aws_iam_role.automation_assume_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMAutomationRole"
}

resource "aws_ssm_document" "restart_service" {
  name            = "${var.project_name}-restart-service"
  document_type   = "Automation"
  document_format = "YAML"
  content         = file("${path.module}/../runbooks/restart-service.yaml")
}
