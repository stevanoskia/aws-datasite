# ADR-0006: The application's database login

## Context
The application needs a login to the database. Its password must not be in the code, in Git, in the Terraform state or on anybody's screen,
and a stolen login must not be able to do more than the application itself.

## Decision
**An own login `shop_app` with a random password in Secrets Manager that only the app server may read.**

| Part | How | Code |
|---|---|---|
| Login | A migration creates `shop_app` without a password, as a member of `app_rw` only, with at most 60 connections | [`0005_app_login.sql`](../../db/migrations/0005_app_login.sql) |
| Secret | Terraform creates it empty; the app server's role may read this one secret | [`modules/app-secret`](../../terraform/modules/app-secret/main.tf) |
| Protection | The secret's own policy denies reading to every other identity, administrators included | [`modules/app-secret`](../../terraform/modules/app-secret/main.tf) |
| Password | A script makes it, sets it, tests a login with it and stores it. Running it again changes the password | [`set_app_password.py`](../../db/set_app_password.py) |

The script never shows the password and never puts it on a command line. The database receives only the SCRAM verifier, from which the password
can't be read back: a readable password in `ALTER ROLE` could end up in the server log or in `pg_stat_statements`. Both sides are checked before
anything changes.

## Alternatives considered

| Option | Why not chosen |
|---|---|
| The application uses the master login | It may do everything; a mistake or a stolen password would reach the whole database |
| Password made by Terraform | It would be in the state |
| Password as a pipeline secret | One more copy outside AWS, and no record of who read it |
| SSM Parameter Store (free) | Parameters have no resource policy in the standard tier, so administrators can't be denied |
| IAM database authentication | A token per connection; adds overhead to exactly what is measured |
| Automatic rotation by Secrets Manager | Needs a Lambda function inside the VPC and a way for the app to reload the password |

## Consequences
- **Changing the password** is one command, but the application must then load the new one: the old one stops working immediately.
- **Who still gets to it:** whoever can open a session on the app server can use that server's role. Administrators can't read the secret, but they
  can change its policy, which CloudTrail records.
- **Short exposure:** the script writes the value to a file in the user's temporary folder for the moment of the upload, then deletes it. On a
  command line it would be visible to monitoring software.
- **No recovery period:** a deleted secret is gone at once. The password can be made again, so its name must not stay blocked.
- **Cost:** about $0.40 per month.

## Validation

| Check | Result |
|---|---|
| Pipeline, PostgreSQL 18: no login without a password, the stored password works, a wrong one is refused | Pass |
| The password is not in the output, not in the arguments, and kept as a SCRAM verifier | Pass |
| A changed password replaces the old one; nothing changes when the secret can't be reached | Pass |
| `shop_app` can write data, can't create tables, has no special rights and no other memberships | Pass |
| Deliberate mistakes in the migration and the script | 11 of 11 caught |
| Deliberate mistakes in the Terraform module | 6 of 6 caught |
| On AWS, 2026-11-25: the script set, tested and stored the password | `PutSecretValue` in CloudTrail |
| On AWS, 2026-11-25: the administrator tries to read the secret | `AccessDenied` in CloudTrail |

## Outcome and further improvements
The application has its own login, and its password exists only in the database (as a verifier) and in Secrets Manager. Recommended improvements:
automatic rotation, and an alarm when the secret's policy is changed.
