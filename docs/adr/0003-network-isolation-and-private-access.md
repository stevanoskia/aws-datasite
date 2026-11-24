# ADR-0003: Network isolation and private access

## Context
The application, the database and the dashboards must not be reachable from the internet, and people may reach them only from the company
network or VPN. The servers still need outbound access for updates, container images and the AWS management agent. The budget is small.

## Decision

**One VPC, three tiers in two availability zones.** What a tier can reach is decided by its route table:

| Tier | Route out | Used by |
|---|---|---|
| public | internet gateway | the NAT instance only |
| app | NAT instance (outbound only), S3 gateway endpoint | app and monitoring servers |
| db | none (only the VPC's own local route) | RDS |

- **Security groups** name each other instead of IP ranges. The VPC's default group has no rules, and no group accepts anything from the internet.
- **Outbound:** a NAT instance (Amazon Linux with iptables) that forwards only traffic from the two app subnets.
- **Evidence:** VPC flow logs of all accepted and rejected traffic, in a private S3 bucket, kept 30 days.
- **Private access:** AWS Systems Manager (SSM) Session Manager. The agent on the server dials out, so no inbound port, public IP, SSH key or
  bastion host is needed. A dedicated **operator role** may open sessions only
  - on servers tagged with the project,
  - from the company's public address (`aws:SourceIp`), which is kept out of the repository,
  - and may resume or end only its own sessions.

Code: [`modules/network`](../../terraform/modules/network/main.tf), [`modules/nat-instance`](../../terraform/modules/nat-instance/main.tf),
[`modules/operator-access`](../../terraform/modules/operator-access/main.tf), [`live/10-network`](../../terraform/live/10-network/main.tf).

**Who gets in:** a person needs an identity in this AWS account, the operator role, and the company network. **Who does not:** anyone on the
internet (no route, no rule), and an identity in the account that uses the operator role from another network.

## Alternatives considered

| Option | Why not chosen |
|---|---|
| NAT gateway | About $34/month; the NAT instance costs a tenth of that. Trade-off below |
| Interface VPC endpoints instead of NAT | About $8/month each, and SSM alone needs three |
| S3 route for the database tier | Nothing needs it, and it reached any bucket. It existed at first and was removed |
| Site-to-Site VPN + internal load balancer | About $55/month; needs the company's network team |
| AWS Client VPN | At least $73/month per subnet |
| Public load balancer limited to company addresses | Still publicly addressable |
| Bastion host with SSH | An open port and keys to manage |

Prices are estimates for eu-north-1.

## Consequences
- **Single point of failure:** one NAT instance in one zone. If it stops, servers lose outbound access and SSM; the database keeps running.
- **Capacity:** AWS had no `t4g.micro` in one zone on the first attempt, and the apply failed after 52 minutes of retries. The zone is now a variable.
- **Address changes:** if the company's public address changes, the operator role stops working until the list is updated.
- **The account's admin role is not bound by the address rule.** It stays as the emergency path.
- **Only people with an AWS identity get in.** A colleague can't simply open the dashboards in a browser.

## Validation
Offline module tests run before every push. Checked against AWS on 2026-11-23 and 2026-11-24:

| Check | Result |
|---|---|
| Db route table | only the local route |
| Inbound security group rules | NAT: only the two app subnets; app, test and default groups: none |
| Connection attempts from a company laptop to the NAT on 22, 80, 443 | 3 REJECT in the flow logs |
| Attempts from other internet addresses on the NAT | 252 REJECT from 172 addresses; none accepted on a port below 1024 |
| Private server without a public IP online in SSM | yes, so outbound through the NAT works |
| Session through the operator role | opened; HTTPS out accepted, SSH out rejected (flow logs) |
| Operator role, IAM policy simulator | 5 of 5: allowed only for project servers from the company address |

## Outcome and further improvements
The isolation works as designed in all checks above. Recommended improvement: a second NAT instance in the other zone, if outbound access must survive a failure.
