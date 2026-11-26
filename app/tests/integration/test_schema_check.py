"""The check that the deploy script runs before a version starts: are all its migrations in the database?"""

import os
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

APP = Path(__file__).resolve().parents[2]
DB = APP.parent / "db"


@pytest.fixture
def check(make_settings, tmp_path):
    settings = make_settings()

    def run(migrations: Path = DB / "migrations", password_file: Path = settings.db_password_file) -> tuple[int, str]:
        env = {
            **os.environ,
            "DB_HOST": settings.db_host,
            "DB_PORT": str(settings.db_port),
            "DB_NAME": settings.db_name,
            "DB_SSLMODE": "prefer",
            "DB_PASSWORD_FILE": str(password_file),
            "MIGRATIONS_DIR": str(migrations),
        }
        command = [sys.executable, "-m", "shop.schema_check"]
        done = subprocess.run(command, cwd=APP, env=env, capture_output=True, text=True, check=False)
        return done.returncode, done.stdout + done.stderr

    return run


def test_a_database_with_every_migration_passes(check):
    assert check()[0] == 0


def test_a_missing_migration_stops_the_deploy(check, tmp_path):
    shutil.copytree(DB / "migrations", tmp_path / "migrations")
    (tmp_path / "migrations/9999_not_yet_applied.sql").write_text("select 1;\n")
    code, output = check(tmp_path / "migrations")
    assert code == 10 and "9999_not_yet_applied" in output


@pytest.mark.parametrize("problem", ["wrong password", "no migrations in the image"])
def test_a_check_that_cannot_be_done_stops_the_deploy(check, tmp_path, problem):
    if problem == "wrong password":
        (tmp_path / "password").write_text("wrong")
        code, output = check(password_file=tmp_path / "password")
        assert "wrong" not in output and "OperationalError" in output
    else:
        code, _ = check(tmp_path)
    assert code == 11
