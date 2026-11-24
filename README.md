# aws-datasite

A small internal web application on AWS, used to practise cloud infrastructure, deployment automation and PostgreSQL performance work:

- **Infrastructure:** Terraform, built in reusable modules: a private VPC, EC2, and RDS PostgreSQL on the smallest practical instance.
- **CI/CD:** GitHub Actions. AWS access goes through two key-only IAM users that can only assume tightly scoped roles (OIDC is blocked in
  this account, see [ADR-0001](docs/adr/0001-ci-access-without-oidc.md)). Tests gate every deploy, and infrastructure changes are applied only after approval.
- **Workload:** a FastAPI app with parameterized SQL, plus reproducible simulated traffic (k6) with read-heavy and write-heavy patterns.
- **Database:** query analysis (`pg_stat_statements`, `EXPLAIN (ANALYZE, BUFFERS)`), indexing strategies, storage growth, maintenance.
- **Observability:** Prometheus, Grafana and Loki, with dashboards and alerts.
- **Security:** nothing is publicly reachable; access goes through a private path only.

## Architecture

Target architecture. Parts marked ✅ exist; the rest is built phase by phase, and this diagram is updated as each part is built.

```
  Laptop on the company VPN                                 GitHub Actions (GitHub-hosted runners)
    │ SSM Session Manager port forwarding                     │ access key → assume role ci-plan / ci-apply ✅
    │ (IAM-authenticated, no inbound ports)                   │ infra pipeline: validate → plan → approval → apply ✅
    │ app, Grafana and psql on localhost                      │ deploy = SSM Run Command (no SSH)
 ┌──▼───────────────────────── VPC 10.30.0.0/16, eu-north-1 ✅ ─────────▼────────────────────┐
 │ public subnet                                                                              │
 │   NAT instance (outbound only, no inbound rules)                                           │
 │                                                                                            │
 │ private-app subnets (2 AZs), no public IPs                                                 │
 │   app host:  FastAPI app · k6 traffic generator · Grafana Alloy (logs + metrics)            │
 │   obs host:  Prometheus · Grafana · Loki · postgres_exporter · YACE (CloudWatch metrics)    │
 │                                                                                            │
 │ private-db subnets (2 AZs), no route out                                                   │
 │   RDS PostgreSQL 18 (db.t4g.micro), encrypted, not public, point-in-time recovery          │
 │                                                                                            │
 │ Security groups chained: app → db, obs → db, obs → app; nothing open to the internet       │
 │ VPC flow logs · S3 gateway endpoint · RDS logs → CloudWatch Logs → Loki                    │
 └────────────────────────────────────────────────────────────────────────────────────────────┘

 Outside the VPC
   Terraform state: S3 bucket, versioned, encrypted, locked ✅
   Alerts: SNS topic → email ✅ · monthly budget with alerts ✅
   Scheduler: stops and starts hosts and database outside working hours
```

| Terraform stack | Contents | Status |
|---|---|---|
| `00-bootstrap` | State bucket, alerts topic, budget, CI access | ✅ applied |
| `10-network` | VPC, subnets, NAT instance, flow logs, SSM access | ✅ applied; isolation evidence still to be written up |
| `20-data` | RDS PostgreSQL, parameter group, secrets | in progress: private instance, only the app server may connect, automatic stop |
| `30-app` | App host, container registry | in progress: private app server with Docker ✅, automatic stop ✅ |
| `40-observability` | Monitoring host | planned |

## Documentation

- [docs/requirements.md](docs/requirements.md): the requirement checklist
- [docs/](docs/README.md): decision records, investigations and runbooks, written as each part is built
