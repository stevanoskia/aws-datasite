# ADR-0004: Servers and automatic stop

## Context
The application and the traffic generator need a place to run, the database needs a private stepping stone for administration, and everything
must fit a fixed amount of credits. The account's Free plan allows only a few instance types.

## Decision
**App server:** one private `t4g.small` (ARM, 2 vCPU, 2 GB) with Amazon Linux, Docker and Docker Compose.
- No public IP, no SSH key, no inbound rule; reached through SSM only (ADR-0003).
- Encrypted disk. IMDSv2 only, with a hop limit of 1, so containers can't reach the server's AWS credentials.
- IAM role with the SSM agent policy and the project's permissions boundary.
- Docker Compose is downloaded in a pinned version and checked against a pinned SHA-256.

**Automatic stop:** EventBridge Scheduler calls the AWS API directly. Start on weekdays at 07:00, stop **every** day at 19:00, so a server started
by hand on a weekend isn't forgotten. Each schedule has its own role that may start and stop exactly its instances. One module serves EC2 and RDS.

Code: [`modules/docker-host`](../../terraform/modules/docker-host/main.tf), [`modules/scheduler`](../../terraform/modules/scheduler/main.tf),
[`live/30-app`](../../terraform/live/30-app/main.tf).

## Alternatives considered

| Option | Why not chosen |
|---|---|
| ECS Fargate | About twice the cost and needs a load balancer; hides the host level that should be observed |
| Lambda | No long-running traffic generator; many short connections would exhaust a micro database |
| A larger server | Not available on the Free plan, or about 2.5 times the price |
| Stop by a Lambda function or cron on a server | More code and permissions; a server can't start itself |
| No automatic stop | About 2.8 times the running hours (168 instead of 60 per week) |

## Consequences
- Outside 07:00–19:00 and on weekends, nothing runs unless it is started by hand. Deployments and backups must happen in the running hours.
- A stopped NAT instance has no public IP. Terraform is told to ignore that, otherwise it could plan to replace the instance.
- Monitoring will have gaps at night. Disks are charged even while the servers are stopped.
- A changed startup script replaces the server. It holds no data, so that is acceptable.

## Validation
- Offline module tests: private, hardened, boundary set, checksum checked, schedule roles limited. Checked against purpose-broken code: every mistake was caught.
- 2026-11-24: app server online in SSM, no public IP; Docker installed and the Compose checksum confirmed in the boot log.
- First night, CloudTrail: NAT stopped at 19:00 and started at 07:00 by the schedule's role; it forwarded traffic again after the restart.

## Outcome and further improvements
The server is ready for containers, and the schedule cuts the running hours to about a third. Recommended improvement: a warning when a server runs outside the schedule.
