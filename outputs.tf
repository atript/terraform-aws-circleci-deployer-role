output "role_arn" {
  description = "ARN of the created IAM role. Pass this to CircleCI's aws-cli/setup step as role_arn."
  value       = aws_iam_role.deployer.arn
}

output "role_name" {
  description = "Name of the created IAM role. Useful for attaching extra managed policies outside the module."
  value       = aws_iam_role.deployer.name
}

output "oidc_provider_arn" {
  description = "ARN of the CircleCI OIDC provider this role trusts. Computed from account_id + circleci_org_id."
  value       = local.oidc_provider_arn
}
