# Production environment Terraform configuration
# Mirrors staging with larger instance and tighter ingress.

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.80"
    }
  }

  backend "s3" {
    bucket       = "careguide-devops-tfstate-ACCOUNT_ID"
    key          = "production/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
  }
}

provider "aws" {
  region = var.aws_region
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "environment" {
  type    = string
  default = "production"
}

variable "ami_id" {
  type = string
}

variable "instance_type" {
  type    = string
  default = "t3.small"
}

variable "allowed_ingress_cidrs" {
  description = "CIDRs that may reach the application port (restrict to known IPs in production)"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "github_org" {
  type = string
}

variable "github_repo" {
  type = string
}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

module "ecr" {
  source          = "../../modules/ecr"
  repository_name = "careguide-devops-app"
  tags = {
    Environment = var.environment
    Project     = "careguide-devops"
  }
}

locals {
  user_data = <<-EOT
    #!/bin/bash
    set -euo pipefail
    dnf install -y docker
    systemctl enable --now docker
    usermod -aG docker ec2-user
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

  allowed_ingress_cidrs     = var.allowed_ingress_cidrs
  ecr_repository_arn        = module.ecr.repository_arn
  cloudwatch_log_group_name = "/careguide/${var.environment}/app"

  user_data = local.user_data

  tags = {
    Environment = var.environment
    Project     = "careguide-devops"
  }
}

module "oidc" {
  source      = "../../modules/oidc"
  github_org  = var.github_org
  github_repo = var.github_repo
  role_name   = "careguide-github-actions-${var.environment}"

  ecr_repository_arns = [module.ecr.repository_arn]
  ec2_instance_arns   = ["arn:aws:ec2:${var.aws_region}:*:instance/${module.app_ec2.instance_id}"]

  tags = {
    Environment = var.environment
    Project     = "careguide-devops"
  }
}

output "ecr_repository_url" {
  value = module.ecr.repository_url
}

output "ec2_instance_id" {
  value = module.app_ec2.instance_id
}

output "github_oidc_role_arn" {
  value = module.oidc.role_arn
}

