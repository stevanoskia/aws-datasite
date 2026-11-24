#!/usr/bin/env bash
# Fills the shop with generated data. Run it again to continue where it stopped.
# The connection comes from the usual variables: PGHOST, PGPORT, PGUSER, PGDATABASE, PGPASSWORD, PGSSLMODE.
#
#   db/seed/seed.sh small        a few thousand rows, for tests
#   db/seed/seed.sh full 5       the first 5 batches of each big table, to measure
#   db/seed/seed.sh full         everything that is still missing
set -euo pipefail

size="${1:-}"
max="${2:-}"
case "$size" in small | full) ;; *) echo "usage: seed.sh small|full [batches]" >&2; exit 1 ;; esac
case "$max" in *[!0-9]*) echo "batches must be a number" >&2; exit 1 ;; esac

dir="$(cd "$(dirname "$0")" && pwd)"
# A crash could lose the last moments, data and progress alike: the next run repeats that batch
export PGOPTIONS="${PGOPTIONS:-} -c synchronous_commit=off -c work_mem=32MB"
run_sql() { psql -X -q -v ON_ERROR_STOP=1 "$@"; }

run_sql -f "$dir/functions.sql"
run_sql -At -c "select gen.init('$size')"
run_sql -c "call gen.load_dimensions()"
run_sql -c "call gen.load_orders($max)"
run_sql -c "call gen.load_reviews($max)"
run_sql -c "call gen.load_events($max)"

if [ "$(run_sql -At -c 'select gen.is_complete()' | tr -d '\r')" = "t" ]; then
  echo "statistics, stored views and size snapshot ..."
  run_sql -c "vacuum (analyze)"
  run_sql -At -c "select gen.finish()"
  run_sql -At -c "select 'size snapshot: ' || ops.take_size_snapshot() || ' rows'"
else
  echo "stopped after $max batches; run again to continue"
fi
run_sql -c "select * from gen.report()" -c "select pg_size_pretty(pg_database_size(current_database())) as database_size"
