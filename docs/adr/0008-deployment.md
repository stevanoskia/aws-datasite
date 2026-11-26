# ADR-0008: Deployment of the app

## Context
Every change to the app should reach the private app server without a manual step, but only after its tests have passed. Changes to the
tables need a human look first. GitHub's runners can't reach the private network, and the pipeline log of this public repository is public.

## Decision
**GitHub Actions builds the images and runs fixed scripts on the server through SSM Run Command.** A third CI user, which needs no approval,
may do only that. Migrations need an approval and run with the apply role.

```
push to main ─► test ─► build (ARM) ─► new migrations? ──no──────────────────────────────► deploy
                         │                       └─yes─► approval ─► snapshot ─► migrate ─┘
                         └─► registry (ECR), tag = commit                                    │
                                                         app server ◄── SSM "datasite-deploy" ┘
```

| Part | How | Code |
|---|---|---|
| Images | One Dockerfile, two targets: the app (Python, 58 MB) and the migrations (`psql`, 155 MB). Base images pinned by digest, the database's certificate authorities by checksum | [`app/Dockerfile`](../../app/Dockerfile) |
| Registry | ECR, tags can't be replaced, scanned on push, newest 20 images kept | [`modules/app-deploy`](../../terraform/modules/app-deploy/main.tf) |
| Server scripts | Two SSM documents: `datasite-deploy` and `datasite-migrate`. Their only input is a commit, accepted only as 40 hexadecimal characters | [`deploy.sh`](../../terraform/modules/app-deploy/scripts/deploy.sh), [`migrate.sh`](../../terraform/modules/app-deploy/scripts/migrate.sh) |
| Deploy | Pull, check that the database has every migration of the version, start, check health and a real query, else start the previous version again | `deploy.sh` |
| Migrations | Only when a push changes `db/migrations` (or by hand): approval, database snapshot, then `migrate.sh` as `shop_migrate` | [`app.yml`](../../.github/workflows/app.yml) |
| Deploy user | May push to this registry and run `datasite-deploy` on the app server. Nothing else: no migrate script, no shell, no secrets | [`ci-access/deploy.tf`](../../terraform/modules/ci-access/deploy.tf) |
| Container | Read-only file system, no capabilities, no new privileges, 512 MB, a user without rights, port on 127.0.0.1 only, no host network | `deploy.sh` |
| Logs | The pipeline prints fixed fields only: step, command ID, status, exit code, duration. The server's output stays in SSM | [`ci_send_command.sh`](../../scripts/ci_send_command.sh) |

The server gets the app's password from Secrets Manager and the database address from an SSM parameter, with its own role. The
container can't reach that role: the metadata service answers only one network hop, and the container is one hop further.

## Alternatives considered

| Option | Why not chosen |
|---|---|
| Deploy with the apply role | Every deploy would wait for an approval |
| `AWS-RunShellScript` with the script in the pipeline | Whoever holds the deploy key could run any command as root on the server |
| SSH from the pipeline | Needs an open port and a key on the runner |
| A self-hosted runner in the network | Untrusted code from forks of a public repository could run on it |
| CodeDeploy | A second deployment system for one server; its agent needs extra rights |
| ECS or Fargate | About twice the cost, and a load balancer (ADR-0004) |
| Migrations at every app start | Every start would need the owner's rights; a failing migration would block the app |
| Migrations without an approval | Table changes would reach the database without a human look |

## Consequences
- **Short downtime:** the old container is stopped before the new one starts, so a deploy takes the app away for a few seconds.
- **Migrations are forward only.** A version is refused only when the database lacks one of its migrations. An older version must also work
  with newer tables. A change that can't be undone by a new migration needs the snapshot.
- **Migration detection compares the push with the previous one;** a run started by hand migrates only when asked to. Before the snapshot
  the pipeline waits until the database is available: during its daily backup it refuses snapshots.
- **The comparison doesn't notice a migration that failed earlier:** the deploy then refuses (exit 10), and the migration is started by hand.
- **The server must be running:** a deploy outside the server's hours is refused at once.
- **Any built version can be deployed** by the deploy user, older ones included. That is how a rollback works.
- **The registry login** is stored on the server for 12 hours in root's home folder, unencrypted (Docker's default).
- **Known vulnerabilities in the base image:** the registry's scan reports high findings in Debian's `openssl`, for which no fixed package
  existed when this was built. The database driver brings its own TLS library.
- **The deploy key is long-lived,** like the other CI keys (ADR-0001), and is rotated the same way.
- **Cost:** ECR storage for about 20 images, a few cents per month; SSM Run Command is free.

## Validation

| Check | Result |
|---|---|
| Deploy and migrate scripts with stand-ins for `docker`, `aws` and `curl` | 13 tests pass |
| Deliberate mistakes in the scripts and the module (no rollback, port open to the network, wrong login, password left behind, any input, ...) | 30 of 30 caught |
| Deliberate mistakes in the deploy user's rights | 12 of 12 caught |
| The pipeline's steps, run in GitHub's shell, with every exit code | Pass |
| Names that stacks and pipelines must agree on, and that AWS must accept | Pass |
| IAM policy simulator, deploy role (region given as context) | 11 of 11 cases as expected: deploy script on the app server allowed; migrate script, shell, NAT server, sessions, secrets, parameter, access keys denied |
| First deployment from a push | Test, build, deploy in about 3 minutes, no manual step |
| A version that can't start (start command broken on purpose) | Unhealthy after 74 s; the previous version runs again (exit 20) |
| Deploy of an older version by hand | Healthy after 15 s |
| A commit that was never built; shell code as input | Both refused before anything reached the server |
| All public pipeline logs (43 runs) | No account ID, address, key or password |

Found while building: SSM parameter and document names that start with `aws` are reserved, and a test with plain `bash` missed that GitHub
stops a step at the first failing command. Both are covered by tests now.

## Outcome and further improvements
A push to `main` reaches the server tested and with a way back, and table changes need an approval. Recommended improvements: start the
new container before stopping the old one (no downtime), a credential helper for the registry login, a base image with fewer packages,
and an alarm when the deploy key is used outside a pipeline run.
