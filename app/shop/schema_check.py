"""Does the database have every migration this version knows? Run by the deploy script before a version starts.

Exit 0: yes. Exit 10: some are missing (they must be applied first). Exit 11: the database could not be checked."""

import os
import sys
from pathlib import Path

import psycopg

from .settings import Settings


def main() -> int:
    folder = Path(os.environ.get("MIGRATIONS_DIR", "/app/migrations"))
    expected = sorted(path.stem for path in folder.glob("[0-9][0-9][0-9][0-9]_*.sql"))
    if not expected:
        print(f"no migrations found in {folder}")
        return 11
    try:
        with psycopg.connect(**Settings.from_env().connection_kwargs()) as connection:
            applied = {row[0] for row in connection.execute("select version from public.schema_migrations")}
    except (psycopg.Error, OSError) as error:
        print(f"database not checkable: {type(error).__name__}")  # only the class: the message can hold the address
        return 11
    missing = [version for version in expected if version not in applied]
    print(f"missing migrations: {', '.join(missing)}" if missing else f"all {len(expected)} migrations applied")
    return 10 if missing else 0


if __name__ == "__main__":
    sys.exit(main())
