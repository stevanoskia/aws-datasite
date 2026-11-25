# ADR-0007: Application

## Context
The application exists to create realistic database activity that can be observed and investigated. It has to show clearly what it asks the
database, behave correctly under parallel requests, and run on a small server.

## Decision
**A Python API with FastAPI and psycopg 3: plain parameterized SQL, no object-relational mapper, one connection pool.**

| Area | Choice | Reason |
|---|---|---|
| SQL | All statements in [one file](../../app/shop/sql.py), values only as parameters | Each statement can be read, copied into `EXPLAIN` and improved on its own |
| Names | Every statement starts with a comment such as `/* order_history */` | It can be recognised in `pg_stat_statements` and in the server log |
| Connections | Pool of 2 to 10, borrowed only after the input is known to be valid | Connections are scarce on this instance; a bad request must not use one |
| Prepared statements | After 5 executions, adjustable or off | Needed to compare generic and custom plans |
| Transactions | Reads run without one; writes use one explicitly | Fewer round trips; a failed order leaves nothing behind |
| Locks | Stock is changed in product order; an order's status is changed under a row lock | No deadlocks between orders, nothing sold or given back twice |
| Limits | Statement timeout 30 s, wait for a connection 5 s, page size at most 100 | One slow statement can't block everything |
| Encryption | `sslmode=verify-full` by default | The server's identity is checked, not only the encryption |
| Password | Read from a file for every new connection | A changed password needs no restart |

## Endpoints

| Endpoint | Database work |
|---|---|
| `GET /customers?email=`, `GET /customers/{id}` | Case-insensitive lookup; key lookup |
| `GET /customers/{id}/orders` | Filter, sort, pages by offset |
| `GET /orders?status=` | Filter on a very uneven column |
| `GET /orders/{id}` | Joins, three statements |
| `GET /products`, `GET /products/{id}` | `ILIKE`, JSONB filter, joins, materialized view |
| `GET /reports/top-products` | Join and aggregation over a period |
| `GET /reports/daily-sales` | Materialized view |
| `GET /reports/events` | Aggregation over a time range of the largest table |
| `POST /orders`, `PUT /orders/{id}/status` | Transactions over four tables |
| `POST /products/{id}/reviews`, `POST /events` | Single inserts |
| `GET /health`, `GET /metrics` | State of the database connection; Prometheus metrics |

## What can be observed

| Where | What |
|---|---|
| Metrics | Requests and durations per route and status, duration and errors per statement, waiting time for a connection, state of the pool |
| Log | One JSON line per request: request ID, route, status, duration, number of statements, time in the database |
| Response | `X-Request-ID` and `Server-Timing` (time and number of statements) |

Routes are recorded as patterns (`/orders/{order_id}`), never as addresses: each order would otherwise be its own time series. Addresses, query
strings and messages of database errors are not logged, because they can contain personal data.

## Alternatives considered

| Option | Why not chosen |
|---|---|
| An object-relational mapper (SQLAlchemy, Django) | Hides and generates the SQL that is to be investigated |
| Asynchronous code | More parallel requests than a database with about 100 connections can use; harder to debug |
| Node.js, Go or Java | Also suitable; Python has the most direct control over prepared statements with psycopg 3 |
| A connection per request | Connecting takes longer than most statements |
| Connection as a FastAPI dependency | Dependencies run even for invalid requests, which then use up the pool |

## Consequences
- **No login:** the application has no users of its own. It is reachable only through the private access path (ADR-0003).
- **One process:** it uses about one CPU core, which is enough while the database is the bottleneck.
- **Slow at first:** with primary keys only, several endpoints read whole tables. That is the starting point of the investigations.
- **Deep pages are slow:** pages by offset read and throw away all rows before them.
- **Parameter types:** psycopg sends small and large numbers as different types, so one statement can have up to three prepared versions.
- **Retries** are up to the caller: after a lost connection or a deadlock the answer is 503.

## Validation

| Check | Result |
|---|---|
| 25 tests without a database: settings, refused input, behaviour without a database | Pass |
| 31 tests on PostgreSQL 18 with the real migrations and generated data, logged in as `shop_app` | Pass |
| 12 parallel orders for the last 5 items | 5 sold, 7 refused, stock 0 |
| 80 parallel orders with the same products in opposite order | All succeed, no deadlock |
| 6 parallel cancellations of one order | One succeeds, stock given back once |
| Statement timeout, full pool, lost connection with a changed password | 504, 503, 503; works again afterwards |
| Deliberate mistakes in the code ([list](../../app/tests/break_it.py)) | 39 of 39 caught |

The first run of the deliberate mistakes caught 36. Two of the others were also stopped by the database's own rules, and one showed a missing
test (inactive products in the search); the tests were extended.

## Outcome and further improvements
The API covers all planned kinds of database work, and every request shows its cost in the database. Recommended improvements: pages by key
instead of offset, several processes if the CPU becomes the limit, and a retry for deadlocks.
