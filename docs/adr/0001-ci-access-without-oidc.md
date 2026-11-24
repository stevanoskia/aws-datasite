# ADR-0001: CI access to AWS without OIDC

## Context
GitHub Actions has to run `terraform plan` / `apply` and deploy the application, so it needs AWS credentials. The recommended way is
**OIDC**: GitHub issues a short-lived token per workflow run, and AWS exchanges it for temporary role credentials, so no secret is stored anywhere.

In this account an organization policy (SCP) **explicitly denies** `iam:CreateOpenIDConnectProvider` and `iam:CreateSAMLProvider`, checked
with the IAM policy simulator on 2026-11-20. OIDC (and SAML federation) can't be used.

The repository is **public**, so whatever is chosen must stay safe even though anyone can read the workflow files and logs.

## Decision
Two **key-only IAM users** whose only permission is to assume one role each. All real permissions are on the roles.

```
GitHub secret (access key) ─▶ IAM user ─(sts:AssumeRole only)─▶ IAM role (1 h session) ─▶ permissions
```

| | Plan | Apply |
|---|---|---|
| User | `aws-datasite-ci-plan-user` | `aws-datasite-ci-apply-user` |
| Role | `aws-datasite-ci-plan` | `aws-datasite-ci-apply` |
| Permissions | AWS `ReadOnlyAccess` + write **only** `*.tflock` files in the state bucket | AWS `PowerUserAccess` (no IAM/Organizations/account) + scoped IAM + explicit denies (below) |
| Key stored as | repository secret | secret of the GitHub environment `production`, released to a job only **after a required reviewer approves** it |

**Apply role: scoped IAM rights**
- It may create and change roles named `aws-datasite-*`, **only if** the role carries the permissions boundary `aws-datasite-boundary`
  (condition `iam:PermissionsBoundary`).
- It may also manage instance profiles and customer policies named `aws-datasite-*`, and create service-linked roles.

**Apply role: explicit denies** (an explicit deny always wins over an allow)
- No IAM users, access keys, login profiles, or user policies.
- No changes to the CI users, the CI roles or the boundary policy.
- No removing a permissions boundary.
- No changes to the Terraform state bucket's configuration (delete, policy, versioning, lifecycle, encryption, public access block).

**Permissions boundary:** a ceiling for every role the project creates. Such roles may use AWS services, but can never change IAM
(except read and `PassRole`), Organizations or account settings, whatever policies are attached to them.

**Handling of the keys**
- Access keys are **not** created by Terraform, because Terraform would store them in the state. They are created with the AWS CLI and
  piped directly into `gh secret set`, so they never appear on screen, in chat or in a file.
- **Rotation every 30 days**, and immediately on any suspicion (runbook `rotate-ci-keys`).
- The stack that creates this access (`00-bootstrap`) is applied **only by hand**, never by CI. The guardrails would block CI from changing it anyway.

**Workflow hardening**
- Actions are pinned to a commit SHA, and only GitHub-owned and verified-creator actions are allowed (repository setting).
- No AWS jobs run on `pull_request`. Fork pull requests never receive secrets, and their workflows need approval before they run at all.
- `GITHUB_TOKEN` is read-only by default, and the account ID is masked in logs.

Code: [`terraform/modules/ci-access`](../../terraform/modules/ci-access/main.tf), used by [`terraform/live/00-bootstrap`](../../terraform/live/00-bootstrap/main.tf).

## Alternatives considered

| Option | Pros | Cons | Why not chosen |
|---|---|---|---|
| GitHub OIDC | No stored secrets; per-run credentials | — | **Blocked** by the SCP |
| AWS CodePipeline + CodeBuild (GitHub keeps CI only) | No keys anywhere; CodeBuild can run inside the VPC | Two CI systems; the approval happens in the AWS console, not in GitHub; more moving parts to explain and maintain | Rejected in favour of one CI system |
| One IAM user with admin keys | Simplest | One leaked key = full account access, no ceiling | Rejected: violates least privilege |
| Self-hosted runner in the VPC with an instance role | No keys; private network access | Self-hosted runners on a **public** repository can run untrusted code from forks | Rejected (GitHub advises against it) |
| Apply from the laptop by hand | No credentials in CI | Infrastructure changes are no longer automated (R2.2) | Rejected |

## Consequences
- **Long-lived keys exist.** If a key leaks (for example through a compromised third-party action), it stays valid until rotated.
  These limit the damage:
  - The user can do nothing but assume one role.
  - The apply key is released only after an approval.
  - The apply role can't create users or keys, and can't create a role stronger than the boundary.
  - **Limitation:** the explicit denies apply to the apply role itself. Roles it creates are limited by the boundary only, which is wider.
    The tests below cover direct actions of the CI roles.
  - Rotation every 30 days.
- **`PowerUserAccess` is broad** for the services it covers: within eu-north-1 it could delete resources that don't belong to the project.
  The account is used for this project only.
- **An approval is needed for every `apply`.** That is deliberate (R2.5): a human checks every infrastructure change. Application deploys
  don't use the apply key's infrastructure path and run automatically.
- **Cost:** IAM is free.

## Validation
Applied on 2026-11-20 (`00-bootstrap`, 23 resources). Read-only checks afterwards: both roles exist with 1-hour sessions, the boundary policy
exists, and the users have 0 access keys.

IAM policy simulator against the deployed roles (organization policies included, region eu-north-1), 2026-11-20:

| Case | Expected | Result |
|---|---|---|
| apply: create an IAM user | deny | explicitDeny ✅ |
| apply: create an access key | deny | explicitDeny ✅ |
| apply: create a project role **without** the boundary | deny | implicitDeny ✅ |
| apply: create a project role **with** the boundary | allow | allowed ✅ |
| apply: create a non-project role (even with the boundary) | deny | implicitDeny ✅ |
| apply: add a policy to its own role | deny | explicitDeny ✅ |
| apply: edit the boundary policy | deny | explicitDeny ✅ |
| apply: remove a role's boundary | deny | explicitDeny ✅ |
| apply: delete the state bucket | deny | explicitDeny ✅ |
| apply: launch an EC2 instance | allow | allowed ✅ |
| apply: create an RDS instance | allow | allowed ✅ |
| plan: write a state lock file | allow | allowed ✅ |
| plan: overwrite a state file | deny | implicitDeny ✅ |
| plan: read a state file | allow | allowed ✅ |
| plan: launch an EC2 instance | deny | implicitDeny ✅ |

First real pipeline run, 2026-11-20 (`infra` workflow, stack `10-network`, 2 resources):
- `validate` and `plan` ran with no human involved, and `apply` waited until the required reviewer approved it in the `production` environment.
- The apply keys were released only to the approved job.
- In the public job log: 0 occurrences of the account ID, the state bucket name not visible, all 16 secret values masked as `***`.
- The saved plan was uploaded encrypted (expires after 1 day).
- CloudTrail records the change under the role session `gha-apply-<run id>`, so every AWS change can be traced to the exact workflow run.

Found during that run: GitHub refuses changes to `.github/workflows/*` pushed with a **deploy key** (it has no `workflow` permission).
Workflow changes are therefore pushed over HTTPS with the owner's `gh` login (scope `workflow`); everything else uses the repository-scoped deploy key.
This adds a stronger credential for the most sensitive files, the ones that decide what runs with the secrets.

## Outcome and further improvements
The pipeline plans and applies infrastructure, and the keys themselves can only assume their role. Recommended improvements:
- a narrower boundary for the roles CI creates;
- a CloudTrail alarm for CI key use outside workflow runs;
- automated key rotation;
- replace `PowerUserAccess` with a policy built from the actions actually used (IAM Access Analyzer policy generation isn't available here, so CloudTrail is analysed manually);
- switch to OIDC if the SCP ever allows it.
