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
  description = "GitHub repository name (e.g. care-guide-devops)"
  type        = string
}

variable "role_name" {
  description = "Name of the IAM role"
  type        = string
  default     = "github-actions-oidc"
}

variable "create_oidc_provider" {
  description = <<-EOT
    Whether this module creates the GitHub OIDC provider. An account may hold
    only one provider for a given URL, so exactly one environment must set this
    to true; every other environment reuses the existing provider via a data
    source. Ignored when provider_arn is set.
  EOT
  type        = bool
  default     = true
}

variable "provider_arn" {
  description = "ARN of an existing GitHub OIDC provider. When set, the provider is neither created nor looked up."
  type        = string
  default     = ""
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

locals {
  # A provider ARN passed in always wins; otherwise either create the provider
  # or look up the one another environment already created. `one(splat)` yields
  # null for the branch that has count = 0, so no invalid index is evaluated.
  created_provider_arn  = var.provider_arn == "" && var.create_oidc_provider ? one(aws_iam_openid_connect_provider.github[*].arn) : null
  existing_provider_arn = var.provider_arn == "" && !var.create_oidc_provider ? one(data.aws_iam_openid_connect_provider.github[*].arn) : null
  provider_arn          = var.provider_arn != "" ? var.provider_arn : coalesce(local.created_provider_arn, local.existing_provider_arn)
}

# OIDC provider for GitHub Actions (one per AWS account, shared across repos)
resource "aws_iam_openid_connect_provider" "github" {
  count = var.provider_arn == "" && var.create_oidc_provider ? 1 : 0

  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

data "aws_iam_openid_connect_provider" "github" {
  count = var.provider_arn == "" && !var.create_oidc_provider ? 1 : 0

  url = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_role" "github_actions" {
  name = var.role_name

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = local.provider_arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          # Restrict to this repository, any branch or tag.
          #
          # GitHub embeds the immutable numeric owner/repo IDs in the OIDC
          # `sub` claim (repo:owner@123/repo@456:environment:production), so a
          # name-only pattern silently stops matching and every workflow fails
          # with "Not authorized to perform sts:AssumeRoleWithWebIdentity".
          # Accept both the ID-qualified and the plain name form; the owner and
          # repository names are matched literally in either case.
          "token.actions.githubusercontent.com:sub" = [
            "repo:${var.github_org}/${var.github_repo}:*",
            "repo:${var.github_org}@*/${var.github_repo}@*:*",
          ]
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

output "oidc_provider_arn" {
  description = "ARN of the GitHub OIDC provider used by this role. Pass this as provider_arn to other environments in the same account."
  value       = local.provider_arn
}
