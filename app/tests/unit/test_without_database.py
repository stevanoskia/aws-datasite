"""Tests that need no database: they also run on the laptop before every push."""

import socket

import pytest

from shop.settings import Settings
from shop.sql import like_pattern


@pytest.fixture(scope="module")
def client(run_app, tmp_path_factory):
    """An app whose database can't be reached."""
    with socket.socket() as free:
        free.bind(("127.0.0.1", 0))
        port = free.getsockname()[1]
    password_file = tmp_path_factory.mktemp("secret") / "password"
    password_file.write_text("unused")
    return run_app(Settings(db_host="127.0.0.1", db_port=port, db_password_file=password_file, pool_timeout=0.5))


def test_the_connection_is_encrypted_and_the_server_checked_by_default(tmp_path):
    password_file = tmp_path / "password"
    password_file.write_text("first\n")
    settings = Settings.from_env({"DB_HOST": "db", "DB_PASSWORD_FILE": str(password_file)})
    assert settings.connection_kwargs()["sslmode"] == "verify-full"


def test_a_changed_password_is_used_for_new_connections(tmp_path):
    password_file = tmp_path / "password"
    password_file.write_text("first\n")
    settings = Settings.from_env({"DB_HOST": "db", "DB_PASSWORD_FILE": str(password_file)})
    assert settings.connection_kwargs()["password"] == "first"
    password_file.write_text("second\n")
    assert settings.connection_kwargs()["password"] == "second"


def test_the_password_is_not_in_the_settings_text(tmp_path):
    password_file = tmp_path / "password"
    password_file.write_text("do-not-show")
    assert "do-not-show" not in repr(Settings(db_host="db", db_password_file=password_file))


def test_prepared_statements_can_be_switched_off():
    env = {"DB_HOST": "db", "DB_PASSWORD_FILE": "x"}
    assert Settings.from_env({**env, "PREPARE_THRESHOLD": "off"}).prepare_threshold is None
    assert Settings.from_env({**env, "PREPARE_THRESHOLD": "0"}).prepare_threshold == 0


def test_search_text_is_taken_literally():
    assert like_pattern("50%_a\\b") == "%50\\%\\_a\\\\b%"


def test_without_a_database_the_app_says_so(client):
    health = client.get("/health")
    assert (health.status_code, health.json()["status"]) == (503, "database not available")
    answer = client.get("/orders/1")
    assert answer.status_code == 503
    assert answer.headers["retry-after"] == "1"
    assert client.get("/metrics").status_code == 200


ORDER = {"customer_id": 1, "payment_method": "card", "lines": [{"product_id": 1, "quantity": 1}]}


@pytest.mark.parametrize(
    "change",
    [
        {"lines": []},
        {"lines": [{"product_id": 1, "quantity": 0}]},
        {"lines": [{"product_id": 1, "quantity": -5}]},
        {"lines": [{"product_id": 1, "quantity": 1}, {"product_id": 1, "quantity": 1}]},
        {"lines": [{"product_id": 1, "quantity": 1, "unit_price": 0.01}]},
        {"customer_id": 2**63},
        {"payment_method": "cash"},
        {"total": 1},
    ],
)
def test_a_wrong_order_is_refused(client, change):
    assert client.post("/orders", json={**ORDER, **change}).status_code == 422


@pytest.mark.parametrize(
    "address",
    [
        "/orders/0",
        "/orders/99999999999999999999",
        "/orders?status=lost",
        "/customers/1/orders?page=0",
        "/customers/1/orders?page_size=101",
        "/customers?email=a%00b",
        "/products?q=a%00b",
        "/reports/top-products?start=2026-02-01&end=2026-01-01",
        "/reports/top-products?start=2024-01-01&end=2026-01-01",
        "/reports/events?end=0001-01-01",
    ],
)
def test_a_wrong_address_is_refused(client, address):
    assert client.get(address).status_code == 422


def test_unknown_addresses_are_one_time_series(client):
    client.get("/no/such/page/1")
    client.get("/no/such/page/2")
    metrics = client.get("/metrics").text
    assert 'route="unmatched"' in metrics
    assert "/no/such/page" not in metrics
