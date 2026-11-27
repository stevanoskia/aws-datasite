# ADR-0010: Reproducible traffic with k6, and light background traffic on the app server

## Context
The query investigations compare a workload before and after a change, so the traffic must be repeatable: the same requests,
in the same order, at the same rate, against the same amount of data. The goal asks for read-heavy and write-heavy patterns
with configurable rate, mix and duration. Between tests, a little steady use makes the dashboards and, later, the alerts show
something real.

The database has only primary and foreign keys so far ([schema](../schema.md)): many lookups read a whole table. Order history
reads all of `orders` (403 MB), order detail all of `payments` (372 MB), product detail all of `reviews` (142 MB), and the
reports up to 1.5 GB. The instance (`db.t4g.micro`, 1 GB memory) bursts on CPU credits and on disk throughput.

## Decision
**One k6 script for every profile:** [`loadgen/shop.js`](../../loadgen/shop.js) sends the requests, and
[`loadgen/profiles.json`](../../loadgen/profiles.json) defines the endpoints and the profiles:

| Profile | Shape | Reads / writes | Default rate, duration |
|---|---|---|---|
| `background` | constant | 90 / 10, only endpoints without a full scan | 1.5 per second, 13 hours |
| `read-heavy` | constant | 90 / 10 | 5 per second, 10 minutes |
| `write-heavy` | constant | 30 / 70 | 5 per second, 10 minutes |
| `mixed` | constant | 60 / 40 | 5 per second, 10 minutes |
| `spike` | the `mixed` load, with a burst of `PEAK` times the rate in the middle | 60 / 40 | 2 per second, peak 5×, 10 minutes |
| `soak` | the `mixed` load for a long time | 60 / 40 | 2 per second, 2 hours |

- **Settings:** `PROFILE`, `RATE`, `PEAK`, `DURATION`, `SEED`, `BASE_URL`, `MAX_VUS` and the data set's size come from
  environment variables. Arrival-rate executors keep the rate fixed however slow the answers are; requests that can't start
  in time are counted as dropped, not delayed.
- **Reproducible:** request number *n* of a run is drawn from a random generator started from `SEED` and *n*, so the same
  seed gives the same requests in the same order, whichever virtual user sends them. Customers and products are picked as
  unevenly as the generator made them: five customers get 10% of the requests, and a few products most of them. Report
  periods are fixed days inside the generated data, so a run next month asks for the same rows.
- **Expected answers:** each request lists the statuses that are correct for it. For example, placing an order may answer 404
  (a product not for sale) or 409 (out of stock). `STRICT=1` fails the run when any other answer comes back.
- **Results in Prometheus:** k6's OpenTelemetry output sends to Prometheus' OTLP receiver on the monitoring server
  (`/api/v1/otlp/v1/metrics`, port 9090, which the app server may already reach; [ADR-0009](0009-metrics-prometheus-grafana.md)).
  Metric names start with `k6_`, and `job` is `k6`. The endpoint is the label `name`. The `url` label is dropped, or every
  product and order number would become a series of its own. Each run carries `profile` and `seed` labels.
- **Background traffic:** a `traffic` container on the app server runs the `background` profile at 1.5 requests per second
  (stack variable `background_rate`; 0 removes the container). It uses only the endpoints marked `cheap`: customer by key,
  product search (25 MB, stays in memory), delivered orders, daily sales from the materialized view, and the inserts of events,
  orders and reviews. It runs in the host network like Alloy, because the app listens on the server's localhost only, and
  it publishes no port. It sends no usage report to Grafana Labs (`K6_NO_USAGE_REPORT`). It runs while the server runs
  (weekdays 07:00–19:00) and starts again after 13 hours or after a restart.
- **Delivery:** the stack `40-observability` reads `loadgen/*.js` and `*.json` and writes them to the app server with the
  collector's files ([`modules/observability`](../../terraform/modules/observability/main.tf)). A change in `loadgen/`
  therefore goes through an approved infrastructure apply, and the infra workflow plans for it.

## Alternatives considered
| Option | Pros | Cons | Why not chosen |
|---|---|---|---|
| Locust (Python) | Same language as the app | Its rate depends on the answers (closed model); needs more memory per user | k6 holds a fixed arrival rate and sends to Prometheus without extra code |
| JMeter | Many protocols, a GUI | JVM memory on a 2 GB server; test plans are XML | Too heavy for the app server |
| k6 remote-write output | No receiver to enable | Deprecated in k6 2.4, to be removed in k6 3 | The OpenTelemetry output is k6's recommended way, and Prometheus receives it directly |
| Background traffic with the full mix | More realistic | Full scans all day: CPU credits and disk burst used up (in unlimited mode, extra CPU is charged), and every measurement during working hours disturbed | Only cheap endpoints until indexes exist |
| Load from GitHub's runners | No load on the app server | The app and the database are not reachable from outside the VPC (ADR-0003) | Not possible without opening the network |

## Consequences
- **Cost:** no new resources. The background traffic writes about 0.15 rows per second (events, orders, reviews), so the
  tables keep growing during working hours. That growth is measured with the size snapshots.
- **Measurements:** the background traffic is part of what the database sees. A measured run stops it first and starts it
  again afterwards.
- **Security:** like Alloy, k6 runs in the app server's host network and can reach the instance metadata and the server's role.
  The image is pinned by digest, and the scripts come from Git through an approved apply.
- **Hot rows:** the hottest products lose stock over time; their orders then answer 409, which counts as a correct answer.
  The profiles that return orders give stock back.
- **Data size:** the script assumes the full data set unless `DATA_CUSTOMERS`, `DATA_PRODUCTS` and `DATA_ORDERS` say otherwise.
  A test compares these numbers with the generator's.

## Validation
- File tests ([`test_loadgen.py`](../../scripts/tests/test_loadgen.py)):
  - The background profile uses only cheap endpoints.
  - Each profile has the read/write share it claims, and its weights add up to 100.
  - The script has a request for every endpoint and no other; every request is a route of the app, with the method that
    fits its kind.
  - The data size equals the generator's full set.
  - The CI workflow uses the same images and Prometheus flags as the servers.
- File and module tests of the app server's stack:
  - The traffic container opens no port, sends no usage report and sends to the OTLP receiver (host and port, no scheme).
  - The files reach the server unchanged.
  - Rate 0 removes the container; a rate above 5, or no files, is refused.
- Infra workflow test: every folder outside `terraform/` that a stack reads starts the workflow and a plan.
- 16 deliberate mistakes in the profiles, the script, the compose files, the module, the workflow and the infra trigger: all
  caught.
- Read-only plan against the real account: 0 to add, 4 to change (the two documents and their associations), 0 to destroy.
  The app server's document is 11.1 KB of SSM's 64 KB.
- The [`loadgen`](../../.github/workflows/loadgen.yml) workflow checks three things for real, and passed on its first run:
  - Every profile ran against the app on PostgreSQL 18 with the small data set, with `STRICT=1`: every answer was expected.
  - Seed 7 twice gave the same 300 requests, and seed 8 gave others.
  - The results arrived in a Prometheus configured as on the monitoring server, with `job="k6"` and the labels
    `name` (all 15 endpoints), `method`, `status`, `expected_response`, `scenario`, `profile` and `seed`, and no `url`.
- Metric names as Prometheus stores them (OpenTelemetry translation, unit as suffix):
  - Durations are histograms with fixed buckets: `k6_http_req_duration_milliseconds_bucket`, `_sum` and `_count`. Likewise
    `k6_http_req_waiting_…`, `k6_http_req_blocked_…`, `k6_iteration_duration_…` and the other request phases.
  - Counters: `k6_http_reqs_total`, `k6_http_req_failed_total`, `k6_checks_total`, `k6_iterations_total`,
    `k6_data_sent_bytes_total`, `k6_data_received_bytes_total`.
  - Gauges: `k6_vus`, `k6_vus_max`.
- After the apply, both servers' installs reported their containers running: `alloy traffic` on the app server,
  `grafana prometheus` on the monitoring server.

## Outcome and further improvements
Every profile can be run with one command, and the same seed repeats it. The background traffic keeps the dashboards
supplied without full scans. The *Load test* dashboard shows k6's view per endpoint, with a profile selector. Its duration
percentiles come from fixed histogram buckets, so values between two bucket limits are estimates. Recommended next: a
`loadtest` workflow that runs a profile on the app server through SSM and stops the background traffic during the run; a
measuring procedure (statistics reset, warm-up, CPU credits, row counts); finer duration buckets (native histograms) if the
fixed ones prove too coarse.
