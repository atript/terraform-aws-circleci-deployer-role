# terraform-aws-circleci-deployer-role

Reusable Terraform module that creates an AWS IAM role assumable by a specific CircleCI project via OIDC. Pair it with the `circleci/aws-cli` orb to delete long-lived `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` from CircleCI env vars.

- **Trust policy:** `sts:AssumeRoleWithWebIdentity` against the CircleCI OIDC provider, scoped by org UUID (`:aud`) **and** project UUID (`:sub`). Optionally further scoped to a single git ref.
- **Permissions:** you supply a JSON policy document; the module attaches it inline. Or omit it and attach permissions separately (managed-policy attachment, etc).

## Prerequisites

The CircleCI OIDC provider must already be registered in the target AWS account. Bootstrapping is one-time per account — see the [CircleCI docs on OIDC](https://circleci.com/docs/openid-connect-tokens/), or, for atript engineers, the internal **CircleCI OIDC Setup** wiki page for the per-account provider ARNs and which terraform root manages each. _(Internal link not published here.)_

You will need:
- The CircleCI **organization UUID** (CircleCI → Organization Settings → Overview)
- The CircleCI **project UUID** for the project that will assume the role (Project Settings → Overview)
- The AWS **account ID** where the role lives

## Quick start

```hcl
module "circleci_deployer" {
  source = "git::https://github.com/atript/terraform-aws-circleci-deployer-role.git?ref=<commit-sha>"

  role_name           = "myservice-ci"
  account_id          = "<your-aws-account-id>"
  circleci_org_id     = "<your-circleci-org-uuid>"
  circleci_project_id = "<your-circleci-project-uuid>"
  branch_filter       = "refs/heads/main"     # optional, recommended for prod
  permissions_policy  = data.aws_iam_policy_document.deploy.json
}

output "ci_role_arn" {
  value = module.circleci_deployer.role_arn
}
```

Pin `?ref=` to a commit SHA. Don't track `main`.

---

## Migrating a project from key-based AWS to OIDC

End-to-end path for an existing CircleCI project that today uses static `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` env vars.

### Step 0 — Find your CircleCI project UUID

CircleCI → your project → **Project Settings → Overview**. Copy the **Project ID** (UUID format). Or via API:

```bash
curl -s -H "Circle-Token: $CIRCLE_TOKEN" \
  "https://circleci.com/api/v2/project/gh/<org>/<repo>" | jq -r .id
```

### Step 1 — Add the role to your project's terraform

Pick the right account ID for where this project deploys. Build a least-privilege permissions policy — start from the actions the existing IAM user has, and trim.

```hcl
data "aws_iam_policy_document" "deploy" {
  statement {
    sid     = "DeployArtifacts"
    actions = ["s3:PutObject", "s3:GetObject", "s3:ListBucket"]
    resources = [
      "arn:aws:s3:::myservice-artifacts",
      "arn:aws:s3:::myservice-artifacts/*",
    ]
  }

  statement {
    sid       = "UpdateLambda"
    actions   = ["lambda:UpdateFunctionCode", "lambda:UpdateFunctionConfiguration", "lambda:GetFunction"]
    resources = ["arn:aws:lambda:<region>:<account-id>:function:myservice-*"]
  }
}

module "circleci_deployer" {
  source = "git::https://github.com/atript/terraform-aws-circleci-deployer-role.git?ref=<sha>"

  role_name           = "myservice-ci"
  account_id          = "<your-aws-account-id>"
  circleci_org_id     = "<your-circleci-org-uuid>"
  circleci_project_id = "<your-circleci-project-uuid>"
  branch_filter       = "refs/heads/main"
  permissions_policy  = data.aws_iam_policy_document.deploy.json
}
```

Apply once with **human creds** (`AWS_PROFILE=<your-profile> terraform apply`) — this is the bootstrap. After this, CI assumes the role and runs all subsequent applies itself.

### Step 2 — Update `.circleci/config.yml`

Use the `circleci/aws-cli` orb's `setup` step. It reads `$CIRCLE_OIDC_TOKEN` (CircleCI injects it automatically), calls `sts:AssumeRoleWithWebIdentity` for you, and exports the resulting short-lived creds into the job's environment.

```yaml
version: 2.1

orbs:
  aws-cli: circleci/aws-cli@5.1.1

jobs:
  deploy:
    docker:
      - image: cimg/base:current
    steps:
      - checkout
      - aws-cli/setup:
          role_arn: arn:aws:iam::<account-id>:role/myservice-ci
          region: <region>
          role_session_name: myservice-${CIRCLE_BUILD_NUM}
      - run: aws sts get-caller-identity   # sanity check: should print the role ARN
      - run: ./deploy.sh
```

Or, without the orb, manually:

```yaml
- run:
    name: Assume deploy role via OIDC
    command: |
      CREDS=$(aws sts assume-role-with-web-identity \
        --role-arn arn:aws:iam::<account-id>:role/myservice-ci \
        --role-session-name "myservice-${CIRCLE_BUILD_NUM}" \
        --web-identity-token "$CIRCLE_OIDC_TOKEN" \
        --duration-seconds 3600 \
        --query 'Credentials' --output json)
      {
        echo "export AWS_ACCESS_KEY_ID=$(echo "$CREDS" | jq -r .AccessKeyId)"
        echo "export AWS_SECRET_ACCESS_KEY=$(echo "$CREDS" | jq -r .SecretAccessKey)"
        echo "export AWS_SESSION_TOKEN=$(echo "$CREDS" | jq -r .SessionToken)"
      } >> "$BASH_ENV"
```

### Step 3 — Verify on a non-prod branch first

Push to a feature branch (or whichever ref your `branch_filter` allows — drop the filter temporarily if you want to test from a feature branch). The job should:
1. Print the assumed role ARN from `aws sts get-caller-identity`
2. Successfully run the same deploy steps that previously needed static keys

If `aws-cli/setup` fails with `AccessDenied`, the trust policy isn't matching — see Troubleshooting.

### Step 4 — Remove static credentials

Once the OIDC-based deploy has succeeded **at least once on the same branch your real deploys use** (typically `main`):

1. **CircleCI:** Project Settings → **Environment Variables** → delete `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` (and any context-level versions).
2. **AWS:** find the IAM user that owned those keys. Delete its access keys (or the user entirely if the keys were its only purpose). Treat any leaked key as a real incident — once OIDC is live, every long-lived key is just blast radius waiting to happen.

### Rollback

If something breaks after switching:
1. Re-add the old `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` env vars in CircleCI (you kept the IAM user keys until step 4 — if you've already rotated them, generate new ones).
2. Revert the `.circleci/config.yml` changes.

The role itself is harmless to leave deployed; it can only be assumed by your specific CircleCI project, so it isn't standing-access risk.

---

## Permission policy patterns

### Lambda deploy

```hcl
data "aws_iam_policy_document" "lambda_deploy" {
  statement {
    actions   = ["lambda:UpdateFunctionCode", "lambda:UpdateFunctionConfiguration", "lambda:GetFunction", "lambda:PublishVersion"]
    resources = ["arn:aws:lambda:<region>:${var.account_id}:function:${var.service}-*"]
  }
  statement {
    actions   = ["s3:PutObject", "s3:GetObject"]
    resources = ["arn:aws:s3:::${var.artifact_bucket}/*"]
  }
}
```

### ECS rolling deploy

```hcl
data "aws_iam_policy_document" "ecs_deploy" {
  statement {
    actions   = ["ecs:UpdateService", "ecs:DescribeServices", "ecs:RegisterTaskDefinition"]
    resources = ["*"]
  }
  statement {
    actions   = ["iam:PassRole"]
    resources = [aws_iam_role.ecs_task.arn, aws_iam_role.ecs_execution.arn]
  }
  statement {
    actions   = ["ecr:GetAuthorizationToken", "ecr:BatchCheckLayerAvailability", "ecr:PutImage", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart", "ecr:CompleteLayerUpload"]
    resources = ["*"]
  }
}
```

### Terraform-runs-everything (transitional)

If you're cutting over a project whose CI today runs `terraform apply` with broad access, attach a managed policy outside the module instead of writing a permissions policy from scratch. **Tighten before declaring the migration "done".**

```hcl
module "circleci_deployer" {
  # ... omit permissions_policy
}

resource "aws_iam_role_policy_attachment" "power_user" {
  role       = module.circleci_deployer.role_name
  policy_arn = "arn:aws:iam::aws:policy/PowerUserAccess"
}
```

---

## Variables

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `role_name` | string | _required_ | IAM role name. Must be unique in the account. |
| `account_id` | string | _required_ | AWS account where the role is created. Must match where the OIDC provider is registered. |
| `circleci_org_id` | string | _required_ | CircleCI organization UUID. |
| `circleci_project_id` | string | _required_ | CircleCI project UUID. Scopes which project can assume the role. |
| `branch_filter` | string | `null` | If set (e.g. `refs/heads/main`), only that ref can assume. Leave null to allow any branch — recommend only for non-prod. |
| `permissions_policy` | string | `null` | JSON IAM policy document, attached inline. If null, no inline policy is created — attach permissions separately (e.g. `aws_iam_role_policy_attachment` for a managed policy, or your own `aws_iam_role_policy` resource). |
| `max_session_duration` | number | `3600` | Max session length in seconds. AWS allows up to 43200 (12h). |
| `tags` | map(string) | `{}` | Tags applied to the role. |

## Outputs

| Name | Description |
| --- | --- |
| `role_arn` | ARN of the created role. Pass to `aws-cli/setup`'s `role_arn`. |
| `role_name` | Name of the role. Use to attach extra managed policies outside the module. |
| `oidc_provider_arn` | The OIDC provider ARN this role trusts (computed). |

## Notes & gotchas

- **CircleCI sub-claim format.** CircleCI emits `org/<org>/project/<project>/user/<user>` (no branch) or `org/<org>/project/<project>/user/<user>/vcs-ref/<ref>` (with branch). The module's `branch_filter` toggles between these patterns. If you have an existing role using the catch-all `org/<org>/project/<project>/*`, that works too but is broader — the module is stricter on purpose.
- **Branch filter ≠ branch protection.** A user with push access to your default branch can still trigger a deploy. Branch filtering only prevents *other* branches from deploying — it's a least-privilege boundary, not an approval workflow.
- **Bootstrap requires human creds.** First apply has to be done with someone's `AWS_PROFILE` — chicken/egg. After that the role can run all subsequent applies (including modifying its own trust policy, if it has IAM permissions).
- **One role per project, not per account.** Don't share a single deployer role across multiple CircleCI projects. The trust policy's `:sub` is what gives you blast-radius isolation; sharing the role throws that away.

## Troubleshooting

**`AccessDenied: Not authorized to perform sts:AssumeRoleWithWebIdentity`**
- Trust policy mismatch. Decode the OIDC token from CircleCI (paste `$CIRCLE_OIDC_TOKEN` into jwt.io) and check the `sub` claim matches your `branch_filter` and `circleci_project_id`. Common cause: feature-branch test against a `branch_filter` set to `refs/heads/main`.

**`InvalidIdentityToken: No OpenIDConnect provider found in your account for...`**
- The OIDC provider isn't registered in the target account. Check `aws iam list-open-id-connect-providers`. If empty, bootstrap it first.

**`The security token included in the request is invalid` after `aws-cli/setup`**
- Stale creds from a previous job step. Make sure `aws-cli/setup` runs *before* any AWS-touching step, and that you haven't manually `export`ed conflicting `AWS_*` vars in an earlier step.

**Build succeeds but `aws sts get-caller-identity` shows the wrong account**
- Multiple `aws-cli/setup` calls / multiple roles in the same job. The last `setup` wins.

## License

MIT.
