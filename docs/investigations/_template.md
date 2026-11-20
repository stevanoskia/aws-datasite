# INV-NN: <short description of the query>

- **Date:** YYYY-MM-DD
- **Endpoint / workload:** which app endpoint and which traffic profile (`loadgen/...`, seed, duration)
- **Data volume:** row counts of the tables involved at the time of the test
- **Requirements:** R4.x

## 1. The query
```sql
-- original statement, exactly as the application sends it (parameters as $1, $2, ...)
```
Purpose and logic: what it returns and why the application needs it.

## 2. Baseline
- `pg_stat_statements`: calls, mean / p95 time, rows, shared blks hit / read
- Execution plan (`EXPLAIN (ANALYZE, BUFFERS, SETTINGS)`) for representative parameter values:
```text
-- plan
```
- Relevant statistics (`pg_stats` for the filtered columns, table/index sizes, `n_dead_tup`, last analyze)
- Load-test result: throughput, latency p50/p95/p99, errors

## 3. Diagnosis
What in the plan or the statistics explains the cost (e.g. a sequential scan on a selective filter, a sort spilling to disk,
a generic plan chosen for a skewed parameter). How each conclusion was reached.

## 4. Options
| Option | Expected effect | Cost (storage, write overhead, complexity) |
|---|---|---|
| | | |

## 5. Change applied
The DDL / query change / statistics change, and why this option was chosen.

## 6. After
The same measurements as in section 2, with the **same workload, seed and data volume**.

| Metric | Before | After | Change |
|---|---|---|---|
| mean time | | | |
| p95 latency | | | |
| shared blks read | | | |
| index size | | | |
| write throughput | | | |

## 7. Trade-offs and conclusion
What was gained, what it costs (e.g. index size, slower writes), and when this choice would no longer be the right one.
