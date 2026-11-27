# GitHub Actions OIDC IAM role module
#
# Allows GitHub Actions workflows to assume an AWS role using OIDC federation.
# No long-lived access keys are required.

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.80"
    }
  }
}

variable "github_org" {
  description = "GitHub organisation or user (e.g. my-org)"
  type        = string
}

variable "github_repo" {
  description = "GitHub repository name (e.g. devops-task)"
  type        = string
}

variable "role_name" {
  description = "Name of the IAM role"
  type        = string
  default     = "github-actions-oidc"
}

variable "ecr_repository_arns" {
  description = "ECR repositories the role may push to"
  type        = list(string)
}

variable "ec2_instance_arns" {
  description = "EC2 instance ARNs the role may send SSM commands to"
  type        = list(string)
}

variable "tags" {
  type    = map(string)
  default = {}
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# OIDC provider for GitHub Actions (one per AWS account, shared across repos)
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

resource "aws_iam_role" "github_actions" {
  name = var.role_name

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.github.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          # Restrict to specific repository and any branch/tag
          "token.actions.githubusercontent.com:sub" = "repo:${var.github_org}/${var.github_repo}:*"
        }
      }
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "github_actions" {
  name = "${var.role_name}-policy"
  role = aws_iam_role.github_actions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # ECR authentication
      {
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      # ECR push
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:CompleteLayerUpload",
          "ecr:GetDownloadUrlForLayer",
          "ecr:InitiateLayerUpload",
          "ecr:PutImage",
          "ecr:UploadLayerPart",
          "ecr:BatchGetImage",
        ]
        Resource = var.ecr_repository_arns
      },
      # SSM — send commands to specific instances
      {
        Effect = "Allow"
        Action = [
          "ssm:SendCommand",
          "ssm:GetCommandInvocation",
        ]
        Resource = concat(
          var.ec2_instance_arns,
          ["arn:aws:ssm:${data.aws_region.current.name}::document/AWS-RunShellScript"]
        )
      },
      # EC2 — describe instances to get public DNS for smoke tests
      {
        Effect   = "Allow"
        Action   = "ec2:DescribeInstances"
        Resource = "*"
      },
    ]
  })
}

output "role_arn" {
  description = "ARN to set as AWS_OIDC_ROLE_ARN GitHub secret"
  value       = aws_iam_role.github_actions.arn
}

