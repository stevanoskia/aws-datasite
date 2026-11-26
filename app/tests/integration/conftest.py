"""A fresh database with the real migrations and the small generated data set.

The server comes from PGHOST, PGPORT, PGUSER, PGPASSWORD (an administrator). The app itself logs in as shop_app,
so a missing right shows up here. Without a server these tests fail; they are never skipped."""

import os
import subprocess
from pathlib import Path

import psycopg
import pytest
from psycopg.rows import dict_row

from shop.settings import Settings

DB = Path(__file__).resolve().parents[3] / "db"
NAME, PASSWORD = "app_test", "only-for-this-test"


@pytest.fixture(scope="session")
def admin():
    """The administrator's view, to check what the app really did."""
    if "PGHOST" not in os.environ:
        pytest.fail("these tests need a PostgreSQL server (PGHOST, PGPORT, PGUSER, PGPASSWORD)")
    with psycopg.connect(dbname="postgres", autocommit=True) as server:
        server.execute(f"drop database if exists {NAME} with (force)")
        server.execute("drop role if exists shop_app, shop_migrate, shop_owner")
        server.execute(f"create database {NAME}")
    for command in (["migrate.sh"], ["seed/seed.sh", "small"]):
        script = str(DB / command[0])
        subprocess.run(["bash", script, *command[1:]], env={**os.environ, "PGDATABASE": NAME}, check=True, capture_output=True)
    with psycopg.connect(dbname=NAME, autocommit=True, row_factory=dict_row) as connection:
        connection.execute(f"alter role shop_app password '{PASSWORD}'")
        yield connection


@pytest.fixture(scope="session")
def make_settings(admin, tmp_path_factory):
    password_file = tmp_path_factory.mktemp("secret") / "password"
    password_file.write_text(PASSWORD + "\n")

    def make(**changes) -> Settings:
        values = {
            "db_host": os.environ["PGHOST"],
            "db_port": int(os.environ.get("PGPORT", "5432")),
            "db_name": NAME,
            "db_password_file": password_file,
            "db_sslmode": "prefer",  # the test server has no certificate
        }
        return Settings(**{**values, **changes})

    return make


@pytest.fixture(scope="session")
def client(run_app, make_settings):
    return run_app(make_settings())


@pytest.fixture
def value(admin):
    """The single value of a query, read by the administrator."""

    def read(sql: str, *parameters):
        return next(iter(admin.execute(sql, parameters).fetchone().values()))

    return read


@pytest.fixture
def new_products(admin):
    """Adds active products with the given stock, so that tests don't share stock."""

    def add(*stocks: int, price: str = "10.50") -> list[int]:
        ids = []
        for stock in stocks:
            product = admin.execute(
                "insert into shop.products (category_id, sku, name, price) values (11, 'T', 'Test', %s) returning id", (price,)
            ).fetchone()
            admin.execute("insert into shop.inventory (product_id, quantity) values (%s, %s)", (product["id"], stock))
            ids.append(product["id"])
        return ids

    return add
