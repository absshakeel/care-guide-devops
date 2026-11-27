# Reusable EC2 module
#
# Provisions one EC2 instance with an IAM role that allows:
# - AWS Systems Manager (SSM) session access — no SSH required
# - Amazon ECR image pull
# - CloudWatch Logs write

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.80"
    }
  }
}

# ---------------------------------------------------------------------------
# Variables
# ---------------------------------------------------------------------------
variable "name" {
  description = "Resource name prefix"
  type        = string
}

variable "environment" {
  description = "Deployment environment (staging | production)"
  type        = string
}

variable "ami_id" {
  description = "Amazon Machine Image ID (Amazon Linux 2023 recommended)"
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.micro"
}

variable "subnet_id" {
  description = "VPC subnet to launch the instance in"
  type        = string
}

variable "vpc_id" {
  description = "VPC containing the subnet"
  type        = string
}

variable "app_port" {
  description = "Port the application listens on"
  type        = number
  default     = 8080
}

variable "allowed_ingress_cidrs" {
  description = "CIDR blocks permitted to reach the application port"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "ecr_repository_arn" {
  description = "ARN of the ECR repository the instance is allowed to pull from"
  type        = string
}

variable "cloudwatch_log_group_name" {
  description = "CloudWatch log group name the instance writes to"
  type        = string
}

variable "user_data" {
  description = "EC2 user data script (bootstrap)"
  type        = string
  default     = ""
}

variable "tags" {
  description = "Additional tags to apply to all resources"
  type        = map(string)
  default     = {}
}

# ---------------------------------------------------------------------------
# Data sources
# ---------------------------------------------------------------------------
data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

# ---------------------------------------------------------------------------
# IAM role for the EC2 instance
# ---------------------------------------------------------------------------
resource "aws_iam_role" "app" {
  name = "${var.name}-${var.environment}-ec2"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = merge(var.tags, {
    Name        = "${var.name}-${var.environment}-ec2"
    Environment = var.environment
  })
}

# SSM access — allows AWS Systems Manager to manage the instance without SSH
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.app.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# ECR image pull — scoped to the specific repository
resource "aws_iam_role_policy" "ecr_pull" {
  name = "${var.name}-${var.environment}-ecr-pull"
  role = aws_iam_role.app.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:BatchCheckLayerAvailability",
        ]
        Resource = var.ecr_repository_arn
      },
      {
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
    ]
  })
}

# CloudWatch Logs — write access scoped to one log group
resource "aws_iam_role_policy" "cloudwatch_logs" {
  name = "${var.name}-${var.environment}-cw-logs"
  role = aws_iam_role.app.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogStreams",
      ]
      Resource = "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:${var.cloudwatch_log_group_name}:*"
    }]
  })
}

resource "aws_iam_instance_profile" "app" {
  name = "${var.name}-${var.environment}-profile"
  role = aws_iam_role.app.name
}

# ---------------------------------------------------------------------------
# Security group — no SSH; application port and HTTPS only
# ---------------------------------------------------------------------------
resource "aws_security_group" "app" {
  name        = "${var.name}-${var.environment}-app"
  description = "Allow inbound to app port; all outbound"
  vpc_id      = var.vpc_id

  ingress {
    description = "Application port"
    from_port   = var.app_port
    to_port     = var.app_port
    protocol    = "tcp"
    cidr_blocks = var.allowed_ingress_cidrs
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, {
    Name        = "${var.name}-${var.environment}-app"
    Environment = var.environment
  })
}

# ---------------------------------------------------------------------------
# CloudWatch log group
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "app" {
  name              = var.cloudwatch_log_group_name
  retention_in_days = 30

  tags = merge(var.tags, {
    Name        = var.cloudwatch_log_group_name
    Environment = var.environment
  })
}

# ---------------------------------------------------------------------------
# EC2 instance
# ---------------------------------------------------------------------------
resource "aws_instance" "app" {
  ami                    = var.ami_id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  iam_instance_profile   = aws_iam_instance_profile.app.name
  vpc_security_group_ids = [aws_security_group.app.id]

  # Prevent accidental replacement on metadata changes
  user_data_replace_on_change = false

  user_data = var.user_data != "" ? base64encode(var.user_data) : null

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 20
    delete_on_termination = true
    encrypted             = true
  }

  metadata_options {
    http_tokens                 = "required" # IMDSv2 — prevents SSRF attacks
    http_put_response_hop_limit = 1
  }

  tags = merge(var.tags, {
    Name        = "${var.name}-${var.environment}"
    Environment = var.environment
  })
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------
output "instance_id" {
  description = "EC2 instance ID — set as EC2_INSTANCE_ID GitHub variable"
  value       = aws_instance.app.id
}

output "instance_public_dns" {
  description = "Public DNS name of the instance"
  value       = aws_instance.app.public_dns
}

output "security_group_id" {
  description = "Security group ID"
  value       = aws_security_group.app.id
}

