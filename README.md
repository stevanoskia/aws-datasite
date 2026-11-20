# aws-datasite

A small internal web application on AWS, used to practise cloud infrastructure, deployment automation and PostgreSQL performance work:

- **Infrastructure:** Terraform, built in reusable modules: a private VPC, EC2, and RDS PostgreSQL on the smallest practical instance.
- **CI/CD:** GitHub Actions with OIDC (no stored AWS keys). Tests gate every deploy, and infrastructure changes are applied only after approval.
- **Workload:** a FastAPI app with parameterized SQL, plus reproducible simulated traffic (k6) with read-heavy and write-heavy patterns.
- **Database:** query analysis (`pg_stat_statements`, `EXPLAIN (ANALYZE, BUFFERS)`), indexing strategies, storage growth, maintenance.
- **Observability:** Prometheus, Grafana and Loki, with dashboards and alerts.
- **Security:** nothing is publicly reachable; access goes through a private path only.

Status: setup. See [docs/requirements.md](docs/requirements.md) for the requirement checklist. More docs follow as each part is built.
