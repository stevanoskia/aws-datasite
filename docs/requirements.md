# Requirements checklist

What the project has to deliver. Optional items (OPT) start only after every core item is done.

## R1 Infrastructure (Terraform)
- R1.1 All AWS resources (VPC, subnets, security groups, IAM, compute, RDS, ...) are defined in Terraform.
- R1.2 The cheapest workable architecture, using free-tier-eligible options where possible; the service choices are justified against alternatives.
- R1.3 PostgreSQL runs on the smallest practical RDS instance, and its CPU, memory, storage and connection limits are taken into account.
- R1.4 The environment is network-isolated.
- R1.5 Terraform code is split into reusable, maintainable modules.
- R1.6 The infrastructure can be created, changed and destroyed through Terraform, again and again with the same result.
- R1.7 Resource usage and cost are reviewed during the whole project.

## R2 CI/CD
- R2.1 Automated pipelines build, test and deploy the application.
- R2.2 Infrastructure changes go through Terraform in the pipeline.
- R2.3 Validation and tests run before any deployment.
- R2.4 Credentials and sensitive settings are managed securely.
- R2.5 Approval controls exist for deployments and infrastructure changes.
- R2.6 The deploy process is documented, including rollback and recovery.
- R2.7 Few manual steps; deployments can be repeated.

## R3 Application and simulated traffic
- R3.1 A simple web app (or API) whose purpose is to create realistic, observable database activity.
- R3.2 Several endpoints that run database operations.
- R3.3 Several related tables and views, using joins, filters, sorting and aggregation.
- R3.4 Generated test data, big enough to show differences between execution plans and indexes.
- R3.5 Parameterized SQL only (no hard-coded values).
- R3.6 Varied requests and parameter values, including cases where the same query gets different plans or performance.
- R3.7 Automated traffic generation with configurable rate, concurrency and workload pattern.
- R3.8 Read-heavy and write-heavy workloads.
- R3.9 Reproducible workloads, so before/after runs can be compared.

## R4 PostgreSQL analysis and optimization
- R4.1 Find expensive, slow and frequent queries using PG statistics, logs and monitoring.
- R4.2 Use EXPLAIN, EXPLAIN ANALYZE and buffer statistics. Cover seq, index and bitmap scans, sorts, joins and aggregation.
- R4.3 Parameterized queries with different values: selectivity, data distribution, prepared statements and their effect on the plan.
- R4.4 Review activity, connections, locks, CPU, memory pressure and I/O.
- R4.5 Document every investigation SQL: its purpose, its logic and how to read the result.
- R4.6 Index strategies beyond the PK: composite, partial, expression, covering and other relevant types.
- R4.7 Effect of column choice, column order and query conditions on index use.
- R4.8 Measure index, table and total DB sizes, and track index growth as data grows.
- R4.9 Find unused, redundant, oversized and inefficient indexes.
- R4.10 Trade-offs between query speed, index storage and write overhead; ways to reduce index storage.
- R4.11 Maintenance: VACUUM, ANALYZE, REINDEX.
- R4.12 Several detailed investigations, each covering: original SQL + plan + metrics + stats → cause → options → applied fix → the same workload
  repeated → comparison, trade-offs and reasoning.

## R5 Observability
- R5.1 A central observability stack (Prometheus / Grafana / log store, or justified alternatives), in AWS or on approved internal infrastructure,
  kept secure and isolated.
- R5.2 Metrics: infrastructure health and usage; PG CPU, memory indicators, connections, storage and I/O; query frequency, duration and load;
  app request rate, latency and errors; table and index sizes, growth and usage; PG maintenance statistics.
- R5.3 Central collection and analysis of app logs and DB logs, with suitable levels, retention and collection methods.
- R5.4 Dashboards for infrastructure, app and DB, showing slow queries, workload patterns and bottlenecks.
- R5.5 Monitoring adds little load and little cost.
- R5.6 Alerts for infrastructure, app and DB conditions (high utilization, slow queries, error rate, ...), with documented thresholds.
- R5.7 Each alert is fired and seen to recover in a test. For each alert the docs say what it detects, why that threshold, and the investigation steps.
- R5.8 Problems can be detected and correlated across app and infrastructure.

## R6 Security and access
- R6.1 App, DB and monitoring are not publicly accessible.
- R6.2 Access to the app and monitoring only through the company VPN, over an approved private connectivity solution.
- R6.3 PostgreSQL is never reachable from the internet.
- R6.4 Private networking, security groups, least-privilege IAM.
- R6.5 Secure service-to-service communication.
- R6.6 Proper secrets and credential management.
- R6.7 Dashboards and admin interfaces have restricted access.
- R6.8 Isolation is validated; the docs say how authorized and unauthorized access is handled.

## R7 Documentation
- R7.1 Docs are written during the project, not at the end.
- R7.2 Each major item covers: what, why, how/config, alternatives, why chosen, drawbacks/limits/security/cost, how validated, outcome + next steps.
- R7.3 Docs include: architecture diagrams, Terraform explanations, deploy workflows, DB schema, investigation SQL, execution plans, monitoring
  config and troubleshooting procedures.

## R8 Final deliverables
- R8.1 Working infrastructure managed through Terraform.
- R8.2 Automated CI/CD for the app and for infrastructure changes.
- R8.3 A working internal app with simulated traffic and parameterized queries.
- R8.4 A DB with related tables, views and several index types.
- R8.5 Working dashboards, central logging and tested alerts.
- R8.6 Documented investigations with measured before/after results.
- R8.7 Evidence of index usage, storage growth and the effect of optimizations.
- R8.8 Network isolation and access control verified.
- R8.9 Complete technical documentation.
- R8.10 A final demo of the app, the deploy automation, the monitoring and the investigation process.

## OPT Optional (only after core is done)
- OPT.1 Distributed tracing: request/trace IDs; follow a request across components and DB calls; durations; visual request flow; link traces
  with logs and metrics.
- OPT.2 Performance under different concurrency and traffic levels.
- OPT.3 Connection pooling and its effect on RDS.
- OPT.4 Locking, blocking and connection-exhaustion scenarios.
- OPT.5 Maintenance behaviour and index bloat.
- OPT.6 Backup and restore procedures.
- OPT.7 Automated cost monitoring and environment shutdown.
- OPT.8 Controlled failure scenarios that test monitoring, alerts and recovery.
