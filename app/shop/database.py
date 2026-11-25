"""Connections and statements, with their time measured."""

import time
from collections.abc import Iterator
from contextlib import contextmanager

import psycopg
from prometheus_client.core import GaugeMetricFamily
from psycopg.rows import dict_row
from psycopg_pool import ConnectionPool

from .observe import Metrics, current_request
from .settings import Settings
from .sql import PING, Query


class Session:
    """One connection, borrowed from the pool for one request."""

    def __init__(self, connection: psycopg.Connection, metrics: Metrics) -> None:
        self.connection = connection
        self.metrics = metrics

    def all(self, query: Query, **values) -> list[dict]:
        return self._execute(query, values, rows=True)[0]

    def one(self, query: Query, **values) -> dict | None:
        rows = self.all(query, **values)
        return rows[0] if rows else None

    def run(self, query: Query, **values) -> int:
        """Returns the number of changed rows."""
        return self._execute(query, values, rows=False)[1]

    def transaction(self):
        return self.connection.transaction()

    def _execute(self, query: Query, values: dict, rows: bool) -> tuple[list[dict], int]:
        started = time.perf_counter()
        try:
            with self.connection.cursor(row_factory=dict_row) as cursor:
                cursor.execute(query.text, values)
                return (cursor.fetchall() if rows else []), cursor.rowcount
        except psycopg.Error as error:
            self.metrics.query_errors.labels(query.name, error.sqlstate or "none").inc()
            raise
        finally:
            seconds = time.perf_counter() - started
            self.metrics.query_seconds.labels(query.name).observe(seconds)
            stats = current_request.get()
            if stats:
                stats.db_queries += 1
                stats.db_seconds += seconds


class Database:
    def __init__(self, settings: Settings, metrics: Metrics) -> None:
        self.metrics = metrics
        self.pool = ConnectionPool(
            kwargs=settings.connection_kwargs,
            min_size=settings.pool_min,
            max_size=settings.pool_max,
            timeout=settings.pool_timeout,
            open=False,
            name="shop",
        )
        metrics.registry.register(PoolCollector(self.pool))

    def open(self) -> None:
        self.pool.open(wait=False)  # the app starts without the database and reports it in /health

    def close(self) -> None:
        self.pool.close()

    @contextmanager
    def session(self, timeout: float | None = None) -> Iterator[Session]:
        started = time.perf_counter()
        with self.pool.connection(timeout=timeout) as connection:
            waited = time.perf_counter() - started
            self.metrics.pool_wait_seconds.observe(waited)
            stats = current_request.get()
            if stats:
                stats.pool_wait_seconds += waited
            yield Session(connection, self.metrics)

    def is_healthy(self) -> bool:
        try:
            with self.session(timeout=2) as session:
                return session.one(PING) is not None
        except psycopg.Error:
            return False


class PoolCollector:
    def __init__(self, pool: ConnectionPool) -> None:
        self.pool = pool

    def collect(self):
        stats = self.pool.get_stats()
        gauge = GaugeMetricFamily("shop_db_pool_connections", "Connections of the pool", labels=["state"])
        size, available = stats.get("pool_size", 0), stats.get("pool_available", 0)
        gauge.add_metric(["in_use"], size - available)
        gauge.add_metric(["free"], available)
        yield gauge
        yield GaugeMetricFamily(
            "shop_db_pool_requests_waiting", "Requests waiting for a connection", value=stats.get("requests_waiting", 0)
        )
