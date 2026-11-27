# ADR-0009: Metrics with Prometheus and Grafana on a monitoring server, fed by Alloy

## Context
Load tests (k6) and the app produce numbers that must be seen over time and compared between runs: request rate, errors and
duration per endpoint, statement duration as the app sees it, and the servers' CPU, memory, disk and network. The goal asks
for central metrics with low overhead, inside the private network, reachable only from the company network.

The app listens on the app server's localhost only (ADR-0008), and nothing in the VPC accepts connections it doesn't need.

## Decision
A second private server, the **monitoring server** (`t4g.small`, 20 GB, same schedule as the app server), runs Prometheus and
Grafana in Docker Compose. On the app server, **Grafana Alloy** collects and **pushes**:

```
app server:  Alloy ── scrapes ──> app /metrics (localhost:8000) and the server itself (node metrics)
             Alloy ── remote write, port 9090 ──> monitoring server: Prometheus <── Grafana (localhost:3000)
             k6 ── OpenTelemetry (OTLP over HTTP), port 9090 ──┘
laptop:      tunnel.ps1 grafana ── SSM port forwarding ──> Grafana
```

- **Network:** the monitoring server's security group accepts port 9090 from the app server's group only; the app server's group
  gets one outbound rule to it. Grafana is published on the monitoring server's localhost, so the only way to it is an SSM
  session (operator role, company address). Alloy's status page also stays on localhost.
- **Push, not scrape:** Prometheus runs with `--web.enable-remote-write-receiver` (Alloy) and `--web.enable-otlp-receiver`
  (k6, [ADR-0010](0010-traffic-generator.md)) and scrapes only itself. OpenTelemetry metrics may arrive up to 30 minutes
  out of order (`out_of_order_time_window`, as the Prometheus guide recommends). The app keeps
  listening on localhost, and the monitoring server needs no route to the app server. When the monitoring server is down,
  Alloy keeps the samples in its write-ahead log and sends them later.
- **Configuration from Git:** the compose files, `prometheus.yml`, Grafana's data source and the dashboards are in
  [`modules/observability/files`](../../terraform/modules/observability/files). Terraform writes them into two SSM documents
  (`datasite-obs-stack`, `datasite-app-stack`); an SSM association runs each document on its server, and again on a new
  server. The script ([`install.sh`](../../terraform/modules/observability/scripts/install.sh)) replaces the files as a whole,
  recreates the containers and fails unless all of them run after 60 seconds. Terraform waits for an association's success
  (up to 15 minutes) only when it creates the association, so a changed document replaces its association: every change
  waits for the server, and a broken configuration fails the apply. Each file's folder is computed with `/` as separator,
  not with `dirname()`, which returns `\` on Windows.
- **Limits:** memory per container (Prometheus 700 MB, Grafana 350 MB, Alloy 200 MB), Prometheus keeps 30 days and at most
  12 GB. Images are pinned by digest.
- **Grafana without its own login:** anonymous access with the Admin role, login form off. The tunnel is the authentication.
  Dashboards are provisioned from Git and can't be changed in the browser.
- **Dashboards:** *Service* (requests per route and status, 5xx share, duration p50/p95/p99, statement duration per query,
  pool wait, failed statements), *Servers* (CPU, memory, disk, network; Prometheus' own memory and intake) and *Load test*
  (k6: requests, unexpected answers, duration and time to first byte per endpoint, virtual users; selectable by profile,
  [ADR-0010](0010-traffic-generator.md)). The `loadgen` workflow checks that every k6 metric and label a dashboard uses
  arrives in Prometheus.

Code: [`modules/observability`](../../terraform/modules/observability/main.tf), [`live/40-observability`](../../terraform/live/40-observability/main.tf),
[`scripts/tunnel.ps1`](../../scripts/tunnel.ps1).

## Alternatives considered
| Option | Pros | Cons | Why not chosen |
|---|---|---|---|
| Prometheus on the app server | No second server | 2 GB shared by the app, k6 and Prometheus: a load test would disturb its own measurement; monitoring fails with the app | Measurements must not compete with what they measure |
| Prometheus scrapes the app across the network | The common pattern | The app would have to listen beyond localhost, and the app server would accept connections | Push keeps the app server without any inbound rule |
| Amazon Managed Prometheus + Managed Grafana | No server to run | Managed Grafana needs IAM Identity Center or SAML (not available here); per-sample and per-user prices; endpoints outside the VPC need interface endpoints (≈ $8/month each) | Cost, and the access model |
| CloudWatch metrics and dashboards | Already there | Custom metrics cost per metric; no PromQL; k6 and the app speak Prometheus | Less suited, and more expensive per metric |
| Configuration copied by hand or in user data | Simple | By hand: not reproducible. User data: runs once at the first boot, and a change replaces the server and its data | SSM association applies every change, through the approved pipeline |
| Grafana with its own admin password | A second factor | The password would live in Secrets Manager or the Terraform state, for a page only the tunnel reaches | The tunnel already limits who and from where |

## Consequences
- **Cost:** about $8 a month on the working-hours schedule (server and its 20 GB disk); the disk is charged while it is stopped.
- **Security:** a new listening port (9090) inside the VPC, reachable from the app server only. Anyone who can open an SSM session
  on the monitoring server is Grafana admin. Remote write and the OpenTelemetry receiver accept any series from the app server.
- **Availability:** while the monitoring server is stopped or being recreated, nothing is shown; Alloy sends what it kept
  (its write-ahead log holds about two hours). An apply that changes a file restarts the containers (a few seconds without data).
- **Alloy reads the app server's `/proc`, `/sys` and file system** (read-only) for the node metrics, and runs in the host's network.
- **Apply depends on the servers:** an apply that changes a document waits for the server; outside the schedule it times out.

## Validation
- Module tests ([`observability.tftest.hcl`](../../terraform/modules/observability/tests/observability.tftest.hcl), mocked AWS):
  only the app server's group reaches port 9090; the app server may send there; Alloy sends to the monitoring server's address;
  each association targets its server, follows the newest document version and is waited for; no document contains `{{`
  (SSM would read it as a parameter; the test found such a comment in the first draft); reserved prefixes and images without
  digest are refused.
- File tests ([`test_observability_files.py`](../../scripts/tests/test_observability_files.py)): every container has a memory limit
  and restarts; every image comes from the pinned list; only Prometheus publishes a port beyond localhost; Grafana listens on
  localhost; Alloy opens no port; dashboards use the provisioned data source and only metrics the app defines.
- Read-only plan against the real account: 17 to add, 0 to change, 0 to destroy; the monitoring document is 7.5 KB of SSM's 64 KB.
- First apply: 16 of 17 created. The monitoring server's association succeeded after 2.5 minutes. The app server's association
  failed within a second with AccessDenied, before anything reached the server (the agent log has no trace of it, and the
  command was sent by the SSM service like the successful one). Started once more by hand with `start-associations-once`,
  it succeeded; the cause was not found. Terraform then replaced the association in the next apply.
- In Grafana through the tunnel: the *Service* dashboard showed the app's requests. *Servers* showed nothing: the unix exporter
  labels its series `job="integrations/unix"`, and `job_name` does not replace it. A relabel rule now sets `job="node"`, and a
  file test checks that every job a dashboard filters on is one that arrives (it failed on the old configuration). After that
  apply, *Servers* shows CPU, memory, disk and network.
- An apply that changed both documents ended at 14:44:09 UTC, while both servers finished their install at 14:45:09 (SSM
  association history): an updated association does not make Terraform wait. Hence the replacement on every change; a file
  test checks that rule. The next change (the *Load test* dashboard) replaced the monitoring server's association: the apply
  step took 97 seconds and ended at 15:23:29 UTC, after the server's install had finished at 15:23:16.
- A read-only plan from Windows showed both documents changing, although nothing had changed: `dirname()` had written
  `grafana\dashboards`, and three files had Windows line endings in the working copy (stored with LF in Git). After the fix,
  the plan from Windows shows no changes; a module test fails with `dirname()` on Windows.

## Outcome and further improvements
Prometheus and Grafana run on their own server and receive the app's and the app server's metrics; k6 sends its results to the
same Prometheus. Recommended next: Loki and the database exporters on the same server, alert rules, and a node exporter on the
monitoring server itself.
