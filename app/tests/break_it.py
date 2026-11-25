"""Breaks one thing at a time in a copy of the app and checks that its tests notice it.
Run by hand (the app workflow's "Run workflow" button); needs the same PostgreSQL as the tests."""

import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
M, S, D, OBS, SET, MOD = (f"shop/{name}.py" for name in ("main", "sql", "database", "observe", "settings", "models"))
MISTAKES = [
    (M, "products locked in any order", "sorted(new.lines, key=lambda line: line.product_id)", "new.lines"),
    (M, "order without transaction", "            with db.transaction():\n                prices", "            if True:\n                prices"),
    (M, "missing stock ignored", "quantity=line.quantity) == 0:", "quantity=line.quantity) == -1:"),
    (M, "unknown products ignored", "if len(prices) != len(lines):", "if False:"),
    (M, "wrong total", "sum(prices[line.product_id] * line.quantity for", "sum(prices[line.product_id] for"),
    (M, "stock not given back", 'if change.status in ("cancelled", "returned"):', 'if change.status == "returned":'),
    (M, "any status change allowed", "if payment_status is None:", "if False:"),
    (M, "page 1 skipped", "offset=(page - 1) * page_size)\n\n    # --- Orders", "offset=page * page_size)\n\n    # --- Orders"),
    (M, "color ignored", 'Jsonb({"color": color}) if color else None', "None"),
    (M, "lost connections not handled", 'answer(psycopg.OperationalError, 503, "the', 'answer(psycopg.errors.DeadlockDetected, 503, "the'),
    (M, "a full pool not handled", 'answer(PoolTimeout, 503,', 'answer(PoolTimeout, 500,'),
    (M, "timeouts not handled", '    answer(psycopg.errors.QueryCanceled, 504, "the database took too long")\n', ""),
    (M, "unknown customers not handled", '    answer(psycopg.errors.ForeignKeyViolation, 404, "unknown customer or product")\n', ""),
    (S, "stock below zero tried", "and quantity >= %(quantity)s", ""),
    (S, "order not locked", "where id = %(order_id)s for update", "where id = %(order_id)s"),
    (S, "other customers' orders shown", "where customer_id = %(customer_id)s\n", "where customer_id >= %(customer_id)s\n"),
    (S, "oldest orders first", "order by created_at desc, id desc\n    limit %(limit)s offset", "order by created_at, id\n    limit %(limit)s offset"),
    (S, "email in exact case only", "lower(email) = lower(%(email)s)", "email = %(email)s"),
    (S, "search in exact case only", "p.name ilike", "p.name like"),
    (S, "inactive products found", "where p.is_active\n      and", "where"),
    (S, "inactive products sold", "and is_active\n", "\n"),
    (S, "wildcards in the search text", "replace(\"%\", \"\\\\%\")", "replace(\"%\", \"%\")"),
    (S, "cancelled orders are sales", "and o.status not in ('cancelled', 'returned')", ""),
    (S, "last day included", "where created_at >= %(start)s and created_at < %(end)s\n    group by event_type", "where created_at >= %(start)s and created_at <= %(end)s + interval '1 day'\n    group by event_type"),
    (S, "statements without name", 'f"/* {self.name} */ {lines}"', "lines"),
    (D, "password read only once", "kwargs=settings.connection_kwargs,", "kwargs=settings.connection_kwargs(),"),
    (D, "app waits for the database", "self.pool.open(wait=False)", "self.pool.open(wait=True, timeout=5)"),
    (D, "errors not counted", "self.metrics.query_errors.labels(query.name, error.sqlstate or \"none\").inc()", "pass"),
    (OBS, "address as label", 'route = getattr(scope.get("route"), "path", "unmatched")', 'route = scope["path"]'),
    (OBS, "request ID not checked", 'sent if re.fullmatch(r"[A-Za-z0-9-]{1,64}", sent) else uuid.uuid4().hex', "sent or uuid.uuid4().hex"),
    (OBS, "address in the log", '"status": status,\n                "duration_ms"', '"status": status, "query": str(scope["query_string"]),\n                "duration_ms"'),
    (SET, "server not checked", 'env.get("DB_SSLMODE", "verify-full")', 'env.get("DB_SSLMODE", "require")'),
    (SET, "no statement timeout", " -c statement_timeout={self.statement_timeout_ms}", ""),
    (SET, "prepare setting ignored", '"prepare_threshold": self.prepare_threshold,', '"prepare_threshold": 5,'),
    (SET, "password kept", 'self.db_password_file.read_text(encoding="utf-8").strip()', '_once(self.db_password_file)'),
    (MOD, "a product twice", "if len({line.product_id for line in self.lines}) != len(self.lines):", "if False:"),
    (MOD, "negative quantities", "quantity: int = Field(ge=1, le=100)", "quantity: int = Field(le=100)"),
    (MOD, "unknown fields accepted", 'extra="forbid"', 'extra="ignore"'),
    (MOD, "endless periods", "<= timedelta(days=366)", "<= timedelta(days=36600)"),
]  # fmt: skip
ONCE = "\n\n_kept = {}\n\n\ndef _once(path):\n    return _kept.setdefault(path, path.read_text().strip())\n"

missed = 0
for file, name, old, new in MISTAKES:
    with tempfile.TemporaryDirectory() as tmp:
        for folder in ("app", "db"):
            shutil.copytree(ROOT / folder, Path(tmp, folder), ignore=shutil.ignore_patterns(".venv", "__pycache__"))
        path = Path(tmp, "app", file)
        text = path.read_text(encoding="utf-8")
        if text.count(old) != 1:
            print("NOT APPLIED", file, "|", name, "|", text.count(old), "places")
            missed += 1
            continue
        path.write_text(text.replace(old, new) + (ONCE if "_once(" in new else ""), encoding="utf-8")
        command = [sys.executable, "-m", "pytest", "-x", "-q", "-p", "no:cacheprovider", "tests"]
        try:
            run = subprocess.run(command, cwd=Path(tmp, "app"), capture_output=True, text=True, timeout=300, env=os.environ)
            failed = [line for line in run.stdout.splitlines() if line.startswith(("FAILED", "ERROR"))]
            caught, reason = run.returncode == 1 and bool(failed), (failed or run.stdout.splitlines() or ["-"])[-1]
        except subprocess.TimeoutExpired:
            caught, reason = False, "timeout"
    print("caught     " if caught else "MISSED     ", file, "|", name, "|", reason[:140], flush=True)
    missed += not caught
print(len(MISTAKES) - missed, "of", len(MISTAKES), "caught")
sys.exit(1 if missed else 0)
