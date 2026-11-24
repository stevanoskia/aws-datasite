"""Breaks one thing at a time in a copy of db/ and checks that db/test.sh notices it.
Run by hand (the db workflow's "Run workflow" button); needs the same PostgreSQL as db/test.sh."""
import os, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
T, V, R, H = "migrations/0002_tables.sql", "migrations/0003_views.sql", "migrations/0001_roles_and_extensions.sql", "migrations/0004_size_history.sql"
F = "seed/functions.sql"
MISTAKES = [
    (T, "orders without foreign key", "bigint not null references shop.customers (id),\n  status", "bigint not null,\n  status"),
    (T, "any order status", "'cancelled', 'returned'))", "'cancelled', 'returned', 'lost'))"),
    (T, "quantity 0 allowed", "check (quantity > 0)", "check (quantity >= 0)"),
    (T, "negative stock allowed", "quantity   integer not null check (quantity >= 0)", "quantity   integer not null"),
    (T, "rating 6 allowed", "between 1 and 5", "between 1 and 6"),
    (T, "an extra index", "create table shop.payments", "create index on shop.order_items (product_id);\ncreate table shop.payments"),
    (V, "failed payments counted as paid", "and status = 'captured'", ""),
    (V, "cancelled orders counted as sales", "where o.status not in ('cancelled', 'returned')\n", ""),
    (V, "items counted as lines", "select count(*) as line_count", "select sum(quantity) as line_count"),
    (R, "readers may change data", "grant select on tables to app_ro", "grant select, delete on tables to app_ro"),
    (R, "monitoring sees shop data", "grant usage on schema shop to app_rw, app_ro;", "grant usage on schema shop to app_rw, app_ro, obs_monitor;\nalter default privileges in schema shop grant select on tables to obs_monitor;"),
    (H, "everyone may take snapshots", "revoke all on function ops.take_size_snapshot() from public;", "alter function ops.take_size_snapshot() security definer;\ngrant usage on schema ops to public;\ngrant execute on function ops.take_size_snapshot() to public;"),
    (H, "indexes missing in the history", "where i.schemaname = 'shop'", "where false"),
    ("migrate.sh", "changed files accepted", '"$applied" != "$checksum"', '"$applied" = "never"'),
    ("migrate.sh", "no transaction per file", "    run_sql -1 \\", "    run_sql \\"),
    (F, "real randomness", "select ((hashint8extended(id, seed * 1000003 + salt) >> 11) & 9007199254740991)::double precision / 9007199254740992.0", "select random() + 0 * id * seed * salt"),
    (F, "no whales", "gen.r(seed, salt, id) < 0.10 then", "gen.r(seed, salt, id) < 0 then"),
    (F, "products evenly popular", "power(gen.r(seed, salt, id), 3)", "gen.r(seed, salt, id)"),
    (F, "open orders everywhere", "t.order_id > s.orders * 0.95 and gen.r(s.seed, 26, t.order_id) < 0.02", "gen.r(s.seed, 26, t.order_id) < 0.02"),
    (F, "wrong totals", "sum(quantity * unit_price) as total", "sum(unit_price) as total"),
    (F, "finished batches loaded again", "continue when exists (select from gen.progress p where p.step = 'orders' and p.batch = b);", ""),
    (F, "sequences not moved", "perform setval(pg_get_serial_sequence('shop.orders', 'id'), (select max(id) from shop.orders));", ""),
    (F, "events out of order", "gen.moment(s.starts_at, s.ends_at, e.id, s.events)", "gen.moment(s.starts_at, s.ends_at, s.events - e.id, s.events)"),
]
missed = 0
for file, name, old, new in MISTAKES:
    with tempfile.TemporaryDirectory() as tmp:
        copy = os.path.join(tmp, "db")
        shutil.copytree(HERE, copy)
        path = os.path.join(copy, file)
        text = open(path, encoding="utf-8").read()
        if old not in text:
            print("NOT APPLIED", file, "|", name); missed += 1; continue
        open(path, "w", encoding="utf-8").write(text.replace(old, new))
        try:
            run = subprocess.run(["bash", os.path.join(copy, "test.sh")], capture_output=True, text=True, timeout=300)
            caught = run.returncode != 0 and "FAILED:" in run.stderr
            reason = (run.stderr.strip().splitlines() or ["-"])[-1]
        except subprocess.TimeoutExpired:
            caught, reason = False, "timeout"
    print("caught     " if caught else "MISSED     ", file, "|", name, "|", reason[:110])
    missed += not caught
print(len(MISTAKES) - missed, "of", len(MISTAKES), "caught")
sys.exit(1 if missed else 0)
