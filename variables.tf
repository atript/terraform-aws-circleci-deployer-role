variable "role_name" {
  description = "Name of the IAM role to create. Must be unique within the AWS account."
  type        = string
}

variable "account_id" {
  description = "AWS account ID where the role lives. Must be the account where the CircleCI OIDC provider is registered."
  type        = string
}

variable "circleci_org_id" {
  description = "CircleCI organization UUID. Used both to construct the OIDC provider ARN and to scope the trust policy via :aud / :sub claims."
  type        = string
}

variable "circleci_project_id" {
  description = "CircleCI project UUID. Restricts which CircleCI project can assume this role."
  type        = string
}

variable "branch_filter" {
  description = "Optional. Restricts assumption to a specific git ref (e.g. \"refs/heads/main\"). Omit to allow any branch — recommended only for non-prod roles."
  type        = string
  default     = null
}

variable "permissions_policy" {
  description = "Optional. JSON IAM policy document attached inline as the role's permissions. If null, no inline policy is created — useful when permissions are attached separately (managed-policy attachment, or multiple inline policies managed outside the module)."
  type        = string
  default     = null
}

variable "max_session_duration" {
  description = "Maximum session length in seconds. Defaults to 3600 (1h). Raise up to 43200 (12h) for very long deploys."
  type        = number
  default     = 3600
}

variable "tags" {
  description = "Tags applied to the IAM role."
  type        = map(string)
  default     = {}
}
