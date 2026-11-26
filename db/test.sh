#!/usr/bin/env bash
# Tests the migrations and the data generator on an empty database: on the server given by PGHOST (the pipeline, PostgreSQL 18), or on a
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
  export PGHOST=127.0.0.1 PGPORT=54329 PGUSER=tester PGPASSWORD=tester
  echo tester > "$work/password"
  initdb -D "$work/data" -U tester -A scram-sha-256 --pwfile="$work/password" -E UTF8 --locale=C > "$work/initdb.log" 2>&1
  pg_ctl -D "$work/data" -l "$work/server.log" -w -o "-p $PGPORT -c listen_addresses=127.0.0.1 -c fsync=off" start > /dev/null
  started=yes
fi

export PGOPTIONS="-c client_min_messages=warning"
psql -X -q -d postgres -v ON_ERROR_STOP=1 -c "drop database if exists migration_test" -c "drop role if exists shop_app, shop_migrate, shop_owner" -c "create database migration_test"
export PGDATABASE=migration_test
fail() { echo "FAILED: $1" >&2; exit 1; }
refused() { if "$@" > /dev/null 2>&1; then fail "this should have been refused: $1 ${2:-}"; fi; }
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

# 5. the application's login: useless without a password, then only the stored password works
as_app() { PGUSER=shop_app PGPASSWORD="$1" psql -X -q -At -w -v ON_ERROR_STOP=1 -c "$2" 2>&1 | tr -d '\r'; }
stored() { python3 -c "import json, sys; print(json.load(open(sys.argv[1]))['password'])" "$work/stored.json"; }

mkdir "$work/bin"
cat > "$work/bin/aws" << 'EOF' # stands in for the AWS CLI: keeps its arguments and the stored value
#!/usr/bin/env bash
echo "$*" >> "$FAKE_AWS/arguments.log"
if [ -e "$FAKE_AWS/secret_missing" ]; then exit 1; fi
for argument in "$@"; do
  case "$argument" in file://*) cp "${argument#file://}" "$FAKE_AWS/stored.json" ;; esac
done
EOF
chmod +x "$work/bin/aws"
export FAKE_AWS="$work"
set_password() { PATH="$work/bin:$PATH" python3 set_app_password.py "$@"; }

refused as_app anything "select 1"
set_password > "$work/out.log" 2>&1 || { cat "$work/out.log" >&2; fail "the password could not be set"; }
[ -e "$work/stored.json" ] || fail "the password was not stored"
first_password="$(stored)"
[ "$(as_app "$first_password" "select current_user")" = "shop_app" ] || fail "the stored password does not work"
refused as_app wrong "select 1"
if grep -qF -e "$first_password" "$work/out.log" "$work/arguments.log"; then fail "the password was shown or on a command line"; fi
if [ "$(count "select left(rolpassword, 14) from pg_authid where rolname = 'shop_app'")" != 'SCRAM-SHA-256$' ]; then fail "the password is not kept as a SCRAM verifier"; fi

as_app "$first_password" "insert into shop.events (event_type, session_id) values ('login', gen_random_uuid())" > /dev/null || fail "the app cannot write data"
refused as_app "$first_password" "create table shop.x (id int)"
psql -X -q -c "truncate shop.events restart identity"

touch "$work/secret_missing"
refused set_password
rm "$work/secret_missing"
as_app "$first_password" "select 1" > /dev/null || fail "the password was changed although the secret could not be reached"

set_password > /dev/null 2>&1 || fail "the password could not be changed"
second_password="$(stored)"
[ "$second_password" != "$first_password" ] || fail "the new password is the old one"
refused as_app "$first_password" "select 1"
as_app "$second_password" "select 1" > /dev/null || fail "the changed password does not work"

# 6. the migration login: later migrations run as shop_migrate, and what it creates the app can use, but not change
refused set_password --role postgres # the script never sets an administrator's password
set_password --role shop_migrate > "$work/out.log" 2>&1 || { cat "$work/out.log" >&2; fail "the migration login's password could not be set"; }
grep -q '"username": "shop_migrate"' "$work/stored.json" || fail "the migration login's password was stored under another name"
migrate_password="$(stored)"
as_migrate() { PGUSER=shop_migrate PGPASSWORD="$migrate_password" "$@"; }

mkdir "$work/later"
cp migrations/*.sql "$work/later/"
printf 'create table shop.added_later (id bigint generated always as identity primary key, note text);\n' > "$work/later/9998_added_later.sql"
as_migrate env MIGRATIONS_DIR="$work/later" bash migrate.sh | grep -q "^1 applied" || fail "the migration login cannot migrate"
[ "$(count "select tableowner from pg_tables where tablename = 'added_later'")" = "shop_owner" ] || fail "a table made by the migration login does not belong to shop_owner"
[ "$(as_app "$second_password" "insert into shop.added_later (note) values ('x') returning id")" = "1" ] || fail "the app cannot use a table that was added later"
refused as_app "$second_password" "drop table shop.added_later"
[ "$(as_app "$second_password" "select count(*) from public.schema_migrations")" = "$((files + 1))" ] || fail "the app cannot see which migrations exist"
refused as_app "$second_password" "delete from public.schema_migrations"
refused as_migrate psql -X -w -c "create role intruder login"
psql -X -q -c "drop table shop.added_later" -c "delete from public.schema_migrations where version = '9998_added_later'"

# 7. the generator: correct data, the same data again, also when interrupted
fingerprint() { psql -X -q -At -v ON_ERROR_STOP=1 -f seed/fingerprint.sql | tr -d '\r'; }
quiet() { "$@" > "$work/out.log" 2>&1 || { cat "$work/out.log" >&2; fail "$*"; }; }
refused timeout 60 bash seed/seed.sh huge
quiet bash seed/seed.sh small
quiet psql -X -q -v ON_ERROR_STOP=1 -f seed/checks.sql
first="$(fingerprint)"
[ -n "$first" ] || fail "no fingerprint"
refused timeout 60 bash seed/seed.sh full # another size on top of existing data

quiet bash seed/seed.sh small
[ "$(fingerprint)" = "$first" ] || fail "running a finished load again changed the data"

quiet psql -X -q -v ON_ERROR_STOP=1 -f seed/reset.sql
quiet bash seed/seed.sh small 3
[ "$(count 'select gen.is_complete()')" = "f" ] || fail "an interrupted load counts as complete"
[ "$(count 'select count(*) from shop.orders')" = "1500" ] || fail "3 batches should be 1500 orders"
quiet bash seed/seed.sh small
[ "$(fingerprint)" = "$first" ] || fail "a continued load gives different data"

quiet psql -X -q -v ON_ERROR_STOP=1 -f seed/reset.sql
psql -X -q -c "insert into shop.categories (name) values ('mine')"
refused timeout 60 bash seed/seed.sh small # data that the generator did not create

version="$(count 'show server_version_num')"
psql -X -q -d postgres -c "drop database migration_test" -c "drop role shop_app, shop_migrate, shop_owner"
echo "database tests passed (PostgreSQL ${version:0:2}, $files migrations)"
