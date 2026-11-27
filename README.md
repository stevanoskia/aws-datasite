# aws-datasite

A small internal web application on AWS, used to practise cloud infrastructure, deployment automation and PostgreSQL performance work:

- **Infrastructure:** Terraform, built in reusable modules: a private VPC, EC2, and RDS PostgreSQL on the smallest practical instance.
- **CI/CD:** GitHub Actions. AWS access goes through two key-only IAM users that can only assume tightly scoped roles (OIDC is blocked in
  this account, see [ADR-0001](docs/adr/0001-ci-access-without-oidc.md)). Tests gate every deploy, and infrastructure changes are applied only after approval.
- **Workload:** a FastAPI app with parameterized SQL ([ADR-0007](docs/adr/0007-application.md)), plus reproducible simulated traffic (k6) with read-heavy and write-heavy patterns.
- **Database:** query analysis (`pg_stat_statements`, `EXPLAIN (ANALYZE, BUFFERS)`), indexing strategies, storage growth, maintenance.
- **Observability:** Prometheus, Grafana and Loki, with dashboards and alerts.
- **Security:** nothing is publicly reachable; access goes through a private path only.

## Architecture

Target architecture. Parts marked ✅ exist.

```
  Laptop on the company VPN                                 GitHub Actions (GitHub-hosted runners)
    │ SSM Session Manager port forwarding                     │ access key → assume role ci-plan / ci-apply ✅
    │ (IAM-authenticated, no inbound ports)                   │ infra pipeline: validate → plan → approval → apply ✅
    │ app, Grafana and psql on localhost                      │ app pipeline: test → build → (migrate) → deploy ✅
    │                                                         │ deploy = fixed script via SSM Run Command (no SSH) ✅
 ┌──▼───────────────────────── VPC 10.30.0.0/16, eu-north-1 ✅ ─────────▼────────────────────┐
 │ public subnet                                                                              │
 │   NAT instance (outbound only, nothing in from the internet) ✅                            │
 │                                                                                            │
 │ private-app subnets (2 AZs), no public IPs                                                 │
 │   app host:  FastAPI app ✅ · k6 traffic generator · Grafana Alloy (logs + metrics)         │
 │   obs host:  Prometheus · Grafana · Loki · postgres_exporter · YACE (CloudWatch metrics)    │
 │                                                                                            │
 │ private-db subnets (2 AZs), no route out                                                   │
 │   RDS PostgreSQL 18 (db.t4g.micro), encrypted, not public, point-in-time recovery ✅       │
 │                                                                                            │
 │ Security groups chained: app → db, app → obs (metrics), obs → db; nothing open to internet │
 │ VPC flow logs · S3 gateway endpoint · RDS logs → CloudWatch Logs → Loki                    │
 └────────────────────────────────────────────────────────────────────────────────────────────┘

 Outside the VPC
   Terraform state: S3 bucket, versioned, encrypted, locked ✅
   Alerts: SNS topic → email ✅ · monthly budget with alerts ✅
   Scheduler: stops and starts hosts and database outside working hours ✅
```

| Terraform stack | Contents |
|---|---|
| `00-bootstrap` | State bucket, alerts topic, budget, CI access ([ADR-0001](docs/adr/0001-ci-access-without-oidc.md), [ADR-0002](docs/adr/0002-terraform-layout-and-state.md)) |
| `10-network` | VPC, subnets, NAT instance, flow logs, private access ([ADR-0003](docs/adr/0003-network-isolation-and-private-access.md)) |
| `20-data` | RDS PostgreSQL, its settings and automatic stop ([ADR-0005](docs/adr/0005-database.md)) |
| `30-app` | App server with Docker, automatic stop ([ADR-0004](docs/adr/0004-servers-and-automatic-stop.md)), the app's database password ([ADR-0006](docs/adr/0006-application-database-login.md)), image registry and deploy scripts ([ADR-0008](docs/adr/0008-deployment.md)) |
| `40-observability` | Monitoring server with Prometheus and Grafana, and the collector on the app server ([ADR-0009](docs/adr/0009-metrics-prometheus-grafana.md)) |

## Documentation

- [docs/requirements.md](docs/requirements.md): the requirement checklist
- [docs/deployment.md](docs/deployment.md): how changes are deployed, and how to go back
- [docs/schema.md](docs/schema.md): the database schema, its data and its sizes
- [docs/](docs/README.md): decision records, investigations and runbooks, written as each part is built
