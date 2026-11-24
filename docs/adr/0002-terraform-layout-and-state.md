# ADR-0002: Terraform layout and state

## Context
All infrastructure is defined in Terraform and must be creatable, changeable and destroyable repeatedly (R1.6), in reusable components (R1.5),
and applied from a pipeline (R2.2). Some parts live for the whole project (state bucket, network, database); others will be changed or
recreated often (hosts, monitoring). The repository is public, so no account-specific values may be committed.

## Decision

**Layout: modules + one root module per layer ("stack")**
```
terraform/
  modules/                 reusable building blocks with inputs and outputs, no provider or backend config
    ci-access/  network/  nat-instance/  operator-access/  rds-postgres/  docker-host/  scheduler/
  live/                    one folder = one stack = one state file
    00-bootstrap/          state bucket, alerts topic, budget, CI access   (applied by hand only)
    10-network/            VPC, subnets, NAT instance, flow logs, SSM access
    20-data/               RDS, its parameter group and automatic stop
    30-app/                app server and automatic stop
```
- Splitting by layer keeps every `plan` small and quick, and a mistake in the app stack can't touch the network or the DB.
- Stacks read each other's outputs from the remote state (`terraform_remote_state`), always in the direction of the numbers (30 reads 10 and 20, never the other way).

**State: S3 backend with native locking**
- One bucket (`aws-datasite-tfstate-<random suffix>`), one key per stack (`<stack>/terraform.tfstate`).
- Locking with `use_lockfile = true`: a `.tflock` object next to the state, so no DynamoDB table is needed (Terraform ≥ 1.10).
- Bucket settings:
  - versioning on;
  - SSE-S3 encryption;
  - every public access setting blocked;
  - ACLs disabled;
  - a policy that denies non-HTTPS requests;
  - old versions expire after 90 days;
  - `prevent_destroy` in Terraform.
- The random suffix keeps the account ID out of the bucket name.

**Partial backend configuration**
- Each stack commits only `backend "s3" {}`. The real values (bucket name, key, region) are in a git-ignored `backend.hcl`, passed with
  `terraform init "-backend-config=backend.hcl"`.
- CI writes the same file from secrets.
- A committed `backend.hcl.example` documents the format.

**Bootstrap order (the chicken-and-egg problem):** the state bucket can't store the state of the stack that creates it until it exists.
`00-bootstrap` was therefore applied with local state, then moved into the bucket with `terraform init -migrate-state`.

**Versions and reproducibility**
- `required_version >= 1.10`, AWS provider `~> 6.73`, random `~> 3.9`.
- `.terraform.lock.hcl` is committed with checksums for `windows_amd64` (laptop), `linux_amd64` and `linux_arm64` (CI runners), so every
  machine uses the identical provider build.
- `default_tags` in every stack: `project`, `layer`, `managed_by`.

**Credentials**
- The provider has no `profile` setting, so profile names never reach the repository. Credentials come from environment variables:
  - on the laptop, `aws configure export-credentials ... | Invoke-Expression`, because Terraform can't read `aws login` sessions directly;
  - in CI, from the keys of [ADR-0001](0001-ci-access-without-oidc.md).

## Alternatives considered

| Option | Pros | Cons | Why not chosen |
|---|---|---|---|
| One root module for everything | Simplest | Every plan touches everything; one state = one blast radius; slow plans | Rejected |
| Terraform workspaces per layer | One folder | Workspaces are meant for copies of the same config, not different layers; easy to apply to the wrong workspace | Rejected |
| Terragrunt | Less repetition across stacks | Another tool to learn and explain; not needed for one environment | Rejected |
| DynamoDB table for locking | The classic pattern | An extra resource; deprecated in favour of S3 native locking | Rejected |
| HCP Terraform (remote state + runs) | Hosted state, UI, run history | External service, state outside the account; its own credentials to AWS would hit the same OIDC block | Rejected |
| Local state | No setup | Can't be shared with CI; lost with the laptop | Used only during bootstrap |
| KMS customer key for the state | Key policy control, audit | $1/month per key; SSE-S3 is enough for this threat model | Rejected |

## Consequences
- Several stacks mean several `init`/`plan` runs. The pipeline plans and applies them one after the other, in number order.
- All stacks are planned before any is applied, so a stack can't read a new output of a lower stack in the same push. Destroying runs in reverse order (40 → 10), and `00-bootstrap` is destroyed last, by hand.
- `prevent_destroy` means a full teardown of the bootstrap needs a deliberate code change. That's intended.
- **Security:** the state contains resource IDs and ARNs, and later possibly sensitive values. It stays in the private, encrypted bucket,
  and only the CI roles and admins can read it.
- **Cost:** the bucket costs cents (a few KB, old versions expire).

## Validation
2026-11-20:
- `terraform fmt -check`, `validate` and `tflint` pass for `00-bootstrap` and `modules/ci-access`.
- `00-bootstrap` applied (23 resources).
- Bucket settings verified read-only: versioning `Enabled`, `AES256`, all 4 public-access blocks `true`, `BucketOwnerEnforced`, the
  `DenyInsecureTransport` policy, the 90-day lifecycle rule.
- State migrated to S3 (`00-bootstrap/terraform.tfstate`). A following `terraform plan` reported **No changes**, so the migrated state is complete.

## Outcome and further improvements
Four stacks use this layout; three of them are applied through the pipeline only. Recommended improvement: a full destroy and recreate test of all stacks.
