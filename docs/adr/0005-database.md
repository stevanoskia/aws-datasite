# ADR-0005: Database

## Context
The project needs PostgreSQL on the smallest practical RDS instance, private, and set up so that slow queries, plans and I/O can be investigated.

## Decision
**RDS PostgreSQL 18.6 on `db.t4g.micro`** (2 burstable vCPU, 1 GB memory), one zone, 20 GB gp3, in the db tier without any route out.

| Area | Choice | Reason |
|---|---|---|
| Access | Port 5432 from the app server's security group only; no outbound rule | Least privilege |
| Encryption | Disk encrypted; `rds.force_ssl = 1` | Connections without TLS are refused |
| Master password | Created and rotated by RDS in Secrets Manager | Never in code or in the Terraform state |
| Zone | Same as the app server | No cross-zone latency or cost in the measurements |
| Minor version upgrades | Off | Measurements must not change with the version |
| Backups | 1 day, window inside the running hours | Free plan limit; a stopped instance makes no backups |
| Protection | Deletion protection and a final snapshot | No accidental loss |
| Disk | 20 GB | Can grow later, can never shrink |

**Settings for the investigations:** `pg_stat_statements` and `auto_explain` are loaded; statements slower than 500 ms are logged with their plan;
lock waits, temporary files over 1 MB and autovacuum runs over 1 s are logged; I/O timing is on. `auto_explain.log_analyze` is **off**, because it
instruments every statement; it is switched on only during an investigation. Performance Insights keeps 7 days (free).

Code: [`modules/rds-postgres`](../../terraform/modules/rds-postgres/main.tf), [`live/20-data`](../../terraform/live/20-data/main.tf).

## Alternatives considered

| Option | Why not chosen |
|---|---|
| Aurora Serverless | Costs more at its minimum; its storage behaves differently from standard PostgreSQL |
| PostgreSQL on an own EC2 server | Cheaper, but no managed backups, patching or metrics; the goal asks for RDS |
| Larger instance | Not available on the Free plan, and the limits of a small instance are the point |
| Multi-AZ | Twice the cost; can be tested once as an experiment |
| Password in a Terraform variable | It would end up in the state |
| IAM database authentication | A token per connection; adds overhead to exactly what is measured |
| 30 GB disk | Not needed for about 8 GB of data |

## Consequences
- **Memory:** the data will be several times larger than memory, so plans and I/O matter.
- **Burstable CPU:** results depend on CPU credits, so they must be checked before each measurement.
- **Connections:** only about 100 are possible; pooling becomes a topic.
- **Recovery:** point-in-time restore reaches back one day only.
- **Deletion protection** must be switched off on purpose before the database can be destroyed.
- **Cost (estimate):** about $0.20 per working day, plus about $3 per month for disk and the secret.

## Validation
Offline module tests run in the pipeline before every plan; they caught all 20 mistakes made on purpose. Checked against AWS on 2026-11-24:

| Check | Result |
|---|---|
| Version, class, encryption, not public, backups, deletion protection | as designed |
| Security group | inbound 5432 from the app group only, no outbound |
| `psql` through the app server | ACCEPT on the database's network interface |
| Connection attempt from another server in the VPC (the NAT instance) | REJECT on the database's network interface, no reply |
| Name of the database | resolves to a private address only |

## Outcome and further improvements
The database is private, encrypted and ready for the investigations. Recommended improvements: clients verify the server's certificate
(`sslmode=verify-full`), and longer backup retention on a paid plan.
