data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

resource "aws_security_group" "app" {
  name        = "${var.project_name}-app-sg"
  description = "Allow app traffic from admin IP only"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "App"
    from_port   = 5000
    to_port     = 5000
    protocol    = "tcp"
    cidr_blocks = [var.my_ip_cidr]
  }

  ingress {
    description = "SSH (only used if key_pair_name is set)"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.my_ip_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-app-sg" }
}

# --- IAM role for the EC2 instance: CloudWatch Agent, X-Ray write, SSM (for Session Manager + Automation targeting) ---
resource "aws_iam_role" "ec2_role" {
  name = "${var.project_name}-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "cloudwatch_agent" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_role_policy_attachment" "xray_write" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess"
}

resource "aws_iam_role_policy_attachment" "ssm_managed" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "${var.project_name}-ec2-profile"
  role = aws_iam_role.ec2_role.name
}

resource "aws_cloudwatch_log_group" "app_logs" {
  name              = "/aws/ec2/${var.project_name}-app-logs"
  retention_in_days = 7
}

locals {
  cw_agent_config = templatefile("${path.module}/files/amazon-cloudwatch-agent.json.tpl", {
    log_group_name = aws_cloudwatch_log_group.app_logs.name
  })

  user_data = <<-EOF
    #!/bin/bash
    set -e
    dnf install -y python3-pip amazon-cloudwatch-agent
    pip3 install flask aws-xray-sdk

    # X-Ray daemon
    curl -o /tmp/xray.rpm https://s3.dualstack.us-east-1.amazonaws.com/aws-xray-assets.us-east-1/xray-daemon/aws-xray-daemon-3.x.rpm
    dnf install -y /tmp/xray.rpm

    mkdir -p /opt/aiops-demo
    cat > /opt/aiops-demo/app.py << 'PYEOF'
    ${file("${path.module}/../app/app.py")}
    PYEOF

    cat > /opt/amazon-cloudwatch-agent.json << 'CWEOF'
    ${local.cw_agent_config}
    CWEOF
    /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
      -a fetch-config -m ec2 -s -c file:/opt/amazon-cloudwatch-agent.json

    cat > /etc/systemd/system/aiops-demo-app.service << 'SVCEOF'
    [Unit]
    Description=AIOps demo Flask app
    After=network.target

    [Service]
    ExecStart=/usr/bin/python3 /opt/aiops-demo/app.py
    StandardOutput=append:/var/log/aiops-demo-app.log
    StandardError=append:/var/log/aiops-demo-app.log
    Restart=always

    [Install]
    WantedBy=multi-user.target
    SVCEOF

    systemctl daemon-reload
    systemctl enable --now aiops-demo-app
    systemctl enable --now xray
  EOF
}

resource "aws_instance" "app" {
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = var.instance_type
  subnet_id              = data.aws_subnets.default.ids[0]
  vpc_security_group_ids = [aws_security_group.app.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2_profile.name
  key_name               = var.key_pair_name != "" ? var.key_pair_name : null
  user_data              = local.user_data

  tags = {
    Name = "${var.project_name}-app"
    Role = "aiops-demo-workload"
  }
}
