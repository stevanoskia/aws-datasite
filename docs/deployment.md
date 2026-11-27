# Deployment and recovery

How changes reach AWS, and how to go back. The reasons are in [ADR-0002](adr/0002-terraform-layout-and-state.md) (infrastructure) and
[ADR-0008](adr/0008-deployment.md) (app).

## What deploys what

| Change in | Pipeline | Approval | Result |
|---|---|---|---|
| `terraform/**` | [infra](../.github/workflows/infra.yml) | Every apply | The reviewed plan is applied |
| `app/**`, `db/**` | [app](../.github/workflows/app.yml) | Only if `db/migrations` changed | Test, build, (snapshot and migrate), deploy |
| `terraform/live/00-bootstrap` | None: applied by hand from the laptop | – | CI access itself |
| Any older version of the app | [deploy](../.github/workflows/deploy.yml), by hand | None | That version runs |

Nothing is deployed when a test fails: each job runs only if the one before it passed.

**Before a push:** the hook [`.githooks/pre-push`](../.githooks/pre-push) runs `scripts/check.ps1 -Quick`: the private-data scan
and the formatting checks, in seconds. The scan must run before the push, because the repository is public and only the
laptop has the real private values to look for. The pipeline runs all checks (`scripts/check.ps1`) after the push; a commit
that fails them is on `main` but is never applied or deployed, and the next commit fixes it. Running `scripts/check.ps1` by
hand gives the full result before a push (about 3 minutes on Windows).

**Following a push:** `python scripts/watch_runs.py` shows every run of the last commit with a progress bar, the time so far, the job
and step that runs, and when a job waits for an approval. The percentage compares each job with its median time in the last
5 successful runs of its workflow; the wait for an approval is not counted. It ends when the runs end (exit code 1 if one failed).

## The app

**Normal case:** push to `main`. About 3 minutes later the version runs, if the server is running (weekdays 07:00–19:00 Berlin time).

**What the deploy does on the server:** pull the image → check that the database has all migrations of this version → start it → check
`/health` (this version, database reachable) and a real query → on failure, start the previous version again.

**Results in the run's summary:**

| Exit code | Meaning | What to do |
|---|---|---|
| 0 | Deployed and healthy | – |
| 3 | The server is not running | Wait for its hours, or start it, then run the workflow again |
| 10 | The database lacks migrations of this version; nothing changed | Run the app workflow by hand with **migrate** |
| 11 | The database could not be checked; nothing changed | Check that the database is running |
| 20 | The new version was unhealthy; the previous one runs again | Read the server's output (below), fix, push |
| 21 | Unhealthy, and no earlier version could be started: **the app is down** | Deploy a known good version by hand (below) |

### Going back to an older version
1. Find the commit of a version that worked (the app workflow's history, or `git log`).
2. GitHub → Actions → **deploy** → Run workflow → enter the full commit (40 characters).

Or from the command line:
```
gh workflow run deploy.yml -f tag=<commit>
```
Only commits that the app workflow has built can be deployed. The newest 20 images are kept.

### Seeing what the server printed
The pipeline log shows only the SSM command ID. The full output is in AWS Systems Manager → Run Command → Command history, or:
```
aws ssm list-command-invocations --command-id <command ID> --details --query "CommandInvocations[0].CommandPlugins[0].Output" --output text
```

## The database

**Migrations** are numbered files in [`db/migrations`](../db/migrations). A file that was applied must never change: a fix is a new file.
When a push adds one, the app workflow waits for an approval in `production`, takes a snapshot (`aws-datasite-db-before-<commit>-<run>`, the
newest two are kept), then migrates as `shop_migrate`. Each file runs in one transaction, so a failed file leaves nothing behind.

**Changes that create roles** (like `0005` and `0006`) need the administrator: run them through the tunnel with
`bash db/migrate.sh` as `dbadmin` before the push that needs them.

**Going back after a migration:**

| Situation | Way back |
|---|---|
| The migration failed | Nothing to undo (one transaction). Fix it in a new file and push |
| It worked, but the change is wrong | A new migration that reverses it |
| Data was lost (a dropped column or table) | Restore the snapshot taken before it as a new database instance, then switch the app to it |
| Anything else | Point-in-time restore within the backup retention (1 day) |

**Changing a database password:**
```
python db/set_app_password.py                      # the app's login
python db/set_app_password.py --role shop_migrate  # the migration login
```
Then deploy again, so that the server writes the new password for the app. The migration login reads its password at every migration.

## The infrastructure

**Normal case:** push to `main`, read the plan in the run's summary, approve the `apply` job in the `production` environment.
The `infra` workflow runs all checks on every push that changes Terraform code, a script or a workflow. It plans only when the push
changes something that Terraform reads: `terraform/` (except module tests), the infra workflow, `safe_log.py` or `ci_private_values.sh`.
Other pushes, such as laptop scripts, tests or the other workflows, end after the checks. **Run workflow** on `infra` always plans.

**Going back:** `git revert` the commit and push: the plan shows the way back, which is approved like any change. Resources that can't
come back, such as a deleted database, need their snapshot (the database has deletion protection and a final snapshot).

**State:** the state files are versioned in the S3 bucket. An older version can be restored there if a state file is damaged.

**A stuck lock** (a run was cancelled during an apply): delete `<stack>/terraform.tfstate.tflock` in the state bucket, only after checking
that no run is active.

## Keys and secrets

| What | Where | Change it |
|---|---|---|
| CI keys (plan, apply, deploy) | GitHub secrets | Every 30 days, see [ADR-0001](adr/0001-ci-access-without-oidc.md): create a new key, set the secret, delete the old key |
| Database administrator | Secrets Manager, managed by RDS | Rotated by RDS |
| App and migration logins | Secrets Manager | `db/set_app_password.py` (above) |
