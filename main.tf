locals {
  oidc_provider_arn = "arn:aws:iam::${var.account_id}:oidc-provider/oidc.circleci.com/org/${var.circleci_org_id}"

  sub_pattern = var.branch_filter == null ? "org/${var.circleci_org_id}/project/${var.circleci_project_id}/user/*" : "org/${var.circleci_org_id}/project/${var.circleci_project_id}/user/*/vcs-ref/${var.branch_filter}"
}

data "aws_iam_policy_document" "trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "oidc.circleci.com/org/${var.circleci_org_id}:aud"
      values   = [var.circleci_org_id]
    }

    condition {
      test     = "StringLike"
      variable = "oidc.circleci.com/org/${var.circleci_org_id}:sub"
      values   = [local.sub_pattern]
    }
  }
}

resource "aws_iam_role" "deployer" {
  name                 = var.role_name
  assume_role_policy   = data.aws_iam_policy_document.trust.json
  max_session_duration = var.max_session_duration
  tags                 = var.tags
}

resource "aws_iam_role_policy" "deployer" {
  name   = "${var.role_name}-permissions"
  role   = aws_iam_role.deployer.id
  policy = var.permissions_policy
}
