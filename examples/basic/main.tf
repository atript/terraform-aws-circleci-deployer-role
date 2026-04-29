terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 4.0"
    }
  }
}

provider "aws" {
  region = var.region
}

variable "region" {
  type    = string
  default = "eu-central-1"
}

variable "account_id" {
  description = "AWS account ID where the role lives"
  type        = string
}

variable "circleci_org_id" {
  description = "CircleCI organization UUID"
  type        = string
}

variable "circleci_project_id" {
  description = "CircleCI project UUID (Project Settings -> Overview)"
  type        = string
}

data "aws_iam_policy_document" "deploy" {
  statement {
    sid     = "S3Artifacts"
    actions = ["s3:PutObject", "s3:GetObject", "s3:ListBucket"]
    resources = [
      "arn:aws:s3:::example-artifacts",
      "arn:aws:s3:::example-artifacts/*",
    ]
  }
}

module "circleci_deployer" {
  source = "../.."

  role_name           = "example-ci"
  account_id          = var.account_id
  circleci_org_id     = var.circleci_org_id
  circleci_project_id = var.circleci_project_id
  branch_filter       = "refs/heads/main"
  permissions_policy  = data.aws_iam_policy_document.deploy.json

  tags = {
    Service = "example"
    Managed = "terraform"
  }
}

output "role_arn" {
  value = module.circleci_deployer.role_arn
}
