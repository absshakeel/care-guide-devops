# Staging environment Terraform configuration
#
# This root module wires together all shared modules for the staging environment.
# Backend state is stored in S3 with native locking (Terraform ≥ 1.10).

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.80"
    }
  }

  backend "s3" {
    bucket = "careguide-devops-tfstate-ACCOUNT_ID" # set in backend.tfvars
    key    = "staging/terraform.tfstate"
    region = "us-east-1"
    # Native S3 locking — no DynamoDB table required (Terraform ≥ 1.10)
    use_lockfile = true
    encrypt      = true
  }
}

provider "aws" {
  region = var.aws_region
}

# ---------------------------------------------------------------------------
# Variables
# ---------------------------------------------------------------------------
variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "environment" {
  type    = string
  default = "staging"
}

variable "ami_id" {
  description = "Amazon Linux 2023 AMI for the target region"
  type        = string
}

variable "instance_type" {
  type    = string
  default = "t3.micro"
}

variable "github_org" {
  type = string
}

variable "github_repo" {
  type = string
}

# ---------------------------------------------------------------------------
# Data sources
# ---------------------------------------------------------------------------
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# ---------------------------------------------------------------------------
# ECR repository
# ---------------------------------------------------------------------------
module "ecr" {
  source          = "../../modules/ecr"
  repository_name = "careguide-devops-app"
  tags = {
    Environment = var.environment
    Project     = "careguide-devops"
  }
}

# ---------------------------------------------------------------------------
# EC2 instance
# ---------------------------------------------------------------------------
locals {
  user_data = <<-EOT
    #!/bin/bash
    set -euo pipefail

    # Install Docker
    dnf install -y docker
    systemctl enable --now docker

    # Allow ec2-user to run docker
    usermod -aG docker ec2-user

    # Pull and start the application (initial placeholder — real deploy via SSM)
    echo "Bootstrap complete. Application will be deployed via GitHub Actions SSM."
  EOT
}

module "app_ec2" {
  source      = "../../modules/ec2"
  name        = "careguide"
  environment = var.environment

  ami_id        = var.ami_id
  instance_type = var.instance_type
  subnet_id     = data.aws_subnets.default.ids[0]
  vpc_id        = data.aws_vpc.default.id

  ecr_repository_arn        = module.ecr.repository_arn
  cloudwatch_log_group_name = "/careguide/${var.environment}/app"

  user_data = local.user_data

  tags = {
    Environment = var.environment
    Project     = "careguide-devops"
  }
}

# ---------------------------------------------------------------------------
# GitHub OIDC role (shared between staging and production via different repos)
# ---------------------------------------------------------------------------
module "oidc" {
  source      = "../../modules/oidc"
  github_org  = var.github_org
  github_repo = var.github_repo
  role_name   = "careguide-github-actions-${var.environment}"

  # Staging owns the account's GitHub OIDC provider; production reuses it.
  create_oidc_provider = true

  ecr_repository_arns = [module.ecr.repository_arn]
  ec2_instance_arns   = ["arn:aws:ec2:${var.aws_region}:*:instance/${module.app_ec2.instance_id}"]

  tags = {
    Environment = var.environment
    Project     = "careguide-devops"
  }
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------
output "ecr_repository_url" {
  value = module.ecr.repository_url
}

output "ec2_instance_id" {
  description = "Set as EC2_INSTANCE_ID GitHub Actions variable"
  value       = module.app_ec2.instance_id
}

output "github_oidc_role_arn" {
  description = "Set as AWS_OIDC_ROLE_ARN GitHub Actions secret"
  value       = module.oidc.role_arn
}

