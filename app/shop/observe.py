"""What is measured about a request: log line, metrics and response headers."""

import json
import logging
import re
import time
import uuid
from contextvars import ContextVar
from dataclasses import dataclass, field
from datetime import UTC, datetime

from prometheus_client import CollectorRegistry, Counter, Histogram

BUCKETS = (0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30)


@dataclass
class RequestStats:
    request_id: str
    started: float = field(default_factory=time.perf_counter)
    db_queries: int = 0
    db_seconds: float = 0.0
    pool_wait_seconds: float = 0.0


# Endpoints run in worker threads, which get a copy of the context: they share this one object
current_request: ContextVar[RequestStats | None] = ContextVar("current_request", default=None)


class Metrics:
    def __init__(self) -> None:
        self.registry = CollectorRegistry()
        # "route" is the pattern (/orders/{order_id}), never the address: every order would be its own time series
        self.requests = Counter("shop_http_requests", "Requests", ["method", "route", "status"], registry=self.registry)
        self.request_seconds = Histogram(
            "shop_http_request_duration_seconds",
            "Duration of requests",
            ["method", "route"],
            buckets=BUCKETS,
            registry=self.registry,
        )
        self.query_seconds = Histogram(
            "shop_db_query_duration_seconds",
            "Duration of statements, as the app sees it",
            ["query"],
            buckets=BUCKETS,
            registry=self.registry,
        )
        self.query_errors = Counter("shop_db_errors", "Failed statements", ["query", "sqlstate"], registry=self.registry)
        self.pool_wait_seconds = Histogram(
            "shop_db_pool_wait_seconds",
            "Time until a connection was free",
            buckets=BUCKETS,
            registry=self.registry,
        )


class JsonFormatter(logging.Formatter):
    def __init__(self, version: str) -> None:
        super().__init__()
        self.version = version

    def format(self, record: logging.LogRecord) -> str:
        entry = {
            "time": datetime.fromtimestamp(record.created, UTC).isoformat(timespec="milliseconds"),
            "level": record.levelname.lower(),
            "logger": record.name,
            "version": self.version,
            "message": record.getMessage(),
        }
        stats = current_request.get()
        if stats:
            entry["request_id"] = stats.request_id
        entry.update(getattr(record, "fields", {}))
        if record.exc_info:
            entry["exception"] = self.formatException(record.exc_info)
        return json.dumps(entry, default=str)


class StdoutHandler(logging.Handler):
    def emit(self, record: logging.LogRecord) -> None:
        print(self.format(record), flush=True)


def setup_logging(version: str) -> None:
    handler = StdoutHandler()
    handler.setFormatter(JsonFormatter(version))
    root = logging.getLogger()
    root.handlers = [handler]
    root.setLevel(logging.INFO)
    logging.getLogger("uvicorn.access").disabled = True  # would print whole addresses, with emails in them


log = logging.getLogger("shop")


class ObserveMiddleware:
    """One log line and one measurement per request; the request ID is in the log and in the response."""

    def __init__(self, app, metrics: Metrics) -> None:
        self.app = app
        self.metrics = metrics

    async def __call__(self, scope, receive, send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        sent = dict(scope["headers"]).get(b"x-request-id", b"").decode("latin-1")
        request_id = sent if re.fullmatch(r"[A-Za-z0-9-]{1,64}", sent) else uuid.uuid4().hex
        stats = RequestStats(request_id)
        token = current_request.set(stats)
        status = 0

        async def send_with_headers(message) -> None:
            nonlocal status
            if message["type"] == "http.response.start":
                status = message["status"]
                timing = f'db;dur={stats.db_seconds * 1000:.1f};desc="{stats.db_queries} queries"'
                message["headers"] = [
                    *message.get("headers", []),
                    (b"x-request-id", stats.request_id.encode()),
                    (b"server-timing", timing.encode()),
                ]
            await send(message)

        try:
            await self.app(scope, receive, send_with_headers)
        except Exception:
            log.exception("unhandled error")
            if status == 0:
                body = b'{"detail": "internal error"}'
                start = {"type": "http.response.start", "status": 500}
                start["headers"] = [(b"content-type", b"application/json"), (b"content-length", str(len(body)).encode())]
                await send_with_headers(start)
                await send({"type": "http.response.body", "body": body})
            status = 500
        finally:
            seconds = time.perf_counter() - stats.started
            route = getattr(scope.get("route"), "path", "unmatched")
            method = scope["method"] if route != "unmatched" else "ANY"
            self.metrics.requests.labels(method, route, str(status)).inc()
            self.metrics.request_seconds.labels(method, route).observe(seconds)
            # No address and no query string: they can hold personal data, such as an email
            fields = {
                "method": scope["method"],
                "route": route,
                "status": status,
                "duration_ms": round(seconds * 1000, 1),
                "db_queries": stats.db_queries,
                "db_ms": round(stats.db_seconds * 1000, 1),
                "pool_wait_ms": round(stats.pool_wait_seconds * 1000, 1),
            }
            if route not in ("/health", "/metrics"):
                log.info("request", extra={"fields": fields})
            current_request.reset(token)
