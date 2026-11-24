#!/usr/bin/env bash
# Applies the numbered SQL files in db/migrations that the database doesn't have yet, in order.
# Each file runs in one transaction together with its entry in public.schema_migrations, so a
# failed file leaves nothing behind. A file that was applied must not change any more.
#
# The connection comes from the usual variables: PGHOST, PGPORT, PGUSER, PGDATABASE, PGPASSWORD, PGSSLMODE.
#
#   db/migrate.sh            apply what is missing
#   db/migrate.sh --status   only list, change nothing
set -euo pipefail

dir="${MIGRATIONS_DIR:-$(cd "$(dirname "$0")" && pwd)/migrations}"
run_sql() { psql -X -q -v ON_ERROR_STOP=1 "$@"; }

has_table="$(run_sql -At -c "select to_regclass('public.schema_migrations') is not null" | tr -d '\r')"
if [ "$has_table" = "f" ] && [ "${1:-}" != "--status" ]; then
  run_sql -c "create table public.schema_migrations (version text primary key, checksum text not null, applied_at timestamptz not null default now())"
fi

pending=0
for file in "$dir"/[0-9][0-9][0-9][0-9]_*.sql; do
  version="$(basename "$file" .sql)"
  checksum="$(tr -d '\r' < "$file" | sha256sum | cut -d' ' -f1)" # the same on Windows and Linux
  applied=""
  if [ "$has_table" = "t" ]; then
    applied="$(run_sql -At -c "select checksum from public.schema_migrations where version = '$version'" | tr -d '\r')"
  fi

  if [ -n "$applied" ]; then
    if [ "$applied" != "$checksum" ]; then
      echo "ERROR: $version was changed after it was applied. Write a new migration instead." >&2
      exit 1
    fi
    echo "  have  $version"
  elif [ "${1:-}" = "--status" ]; then
    echo "  todo  $version"
    pending=$((pending + 1))
  else
    echo "  run   $version"
    # The lock keeps two runs apart; it ends with the transaction
    run_sql -1 \
      -c "select pg_advisory_xact_lock(20261124)" \
      -f "$file" \
      -c "insert into public.schema_migrations (version, checksum) values ('$version', '$checksum')" > /dev/null
    pending=$((pending + 1))
  fi
done

if [ "${1:-}" = "--status" ]; then echo "$pending to apply."; else echo "$pending applied."; fi
