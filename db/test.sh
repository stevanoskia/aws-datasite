#!/usr/bin/env bash
# Tests the migrations on an empty database: on the server given by PGHOST (the pipeline, PostgreSQL 18), or on a
# temporary server that is started here and removed afterwards (needs a PostgreSQL server installation).
set -euo pipefail
cd "$(dirname "$0")"

work="$(mktemp -d)"
started=""
cleanup() {
  if [ -n "$started" ]; then pg_ctl -D "$work/data" -m immediate stop > /dev/null 2>&1 || true; fi
  if [ -n "$work" ] && [ -d "$work" ]; then rm -rf -- "${work:?}"; fi
}
trap cleanup EXIT

if [ -z "${PGHOST:-}" ]; then
  if ! command -v initdb > /dev/null 2>&1; then
    for bin in "/c/Program Files/PostgreSQL"/*/bin /usr/lib/postgresql/*/bin; do
      if [ -x "$bin/initdb" ] || [ -x "$bin/initdb.exe" ]; then PATH="$bin:$PATH"; fi
    done
  fi
  export PGHOST=127.0.0.1 PGPORT=54329 PGUSER=tester
  initdb -D "$work/data" -U tester -A trust -E UTF8 --locale=C > "$work/initdb.log" 2>&1
  pg_ctl -D "$work/data" -l "$work/server.log" -w -o "-p $PGPORT -c listen_addresses=127.0.0.1 -c fsync=off" start > /dev/null
  started=yes
fi

export PGOPTIONS="-c client_min_messages=warning"
psql -X -q -d postgres -v ON_ERROR_STOP=1 -c "drop database if exists migration_test" -c "create database migration_test"
export PGDATABASE=migration_test
fail() { echo "FAILED: $1" >&2; exit 1; }
count() { psql -X -At -v ON_ERROR_STOP=1 -c "$1" | tr -d '\r'; }

# 1. all migrations run on an empty database, and a second run changes nothing
files="$(ls migrations/*.sql | wc -l | tr -d ' ')"
bash migrate.sh | grep -q "^$files applied" || fail "not every migration was applied to an empty database"
bash migrate.sh | grep -q "^0 applied" || fail "a second run applied something again"

# 2. a migration that was applied must not change
mkdir "$work/changed"
cp migrations/*.sql "$work/changed/"
echo "-- changed later" >> "$work/changed/0001_roles_and_extensions.sql"
if MIGRATIONS_DIR="$work/changed" bash migrate.sh > /dev/null 2>&1; then fail "a changed migration was accepted"; fi

# 3. a failing migration leaves nothing behind
mkdir "$work/broken"
cp migrations/*.sql "$work/broken/"
printf 'create table shop.half_done (id int);\nselect 1 / 0;\n' > "$work/broken/9999_broken.sql"
if MIGRATIONS_DIR="$work/broken" bash migrate.sh > /dev/null 2>&1; then fail "a failing migration reported success"; fi
[ "$(count "select to_regclass('shop.half_done') is null")" = "t" ] || fail "a failing migration left a table behind"
[ "$(count "select count(*) from public.schema_migrations where version like '9999%'")" = "0" ] || fail "a failing migration was recorded as applied"

# 4. what the schema itself promises
for file in tests/*.sql; do
  psql -X -q -v ON_ERROR_STOP=1 -f "$file" > "$work/out.log" 2>&1 || { cat "$work/out.log" >&2; fail "$file"; }
done

version="$(count 'show server_version_num')"
psql -X -q -d postgres -c "drop database migration_test"
echo "database tests passed (PostgreSQL ${version:0:2}, $files migrations)"
