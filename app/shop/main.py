"""The shop's API."""

from contextlib import asynccontextmanager
from typing import Annotated

import psycopg
from fastapi import Depends, FastAPI, HTTPException, Query, Request, Response
from fastapi.responses import JSONResponse
from prometheus_client import CONTENT_TYPE_LATEST, generate_latest
from psycopg.types.json import Jsonb
from psycopg_pool import PoolTimeout

from . import pages, service, sql
from .database import Database
from .models import (
    NO_ZERO_CHARACTER,
    CategoryId,
    Id,
    Limit,
    NewEvent,
    NewOrder,
    NewReview,
    OrderStatus,
    Page,
    PageSize,
    Period,
    StatusChange,
)
from .observe import Metrics, ObserveMiddleware, log, setup_logging
from .settings import Settings

# status now -> status it may change to -> what happens to its payment
STATUS_CHANGES = {
    "pending": {"paid": "captured", "cancelled": "failed"},
    "paid": {"shipped": "captured", "cancelled": "refunded"},
    "shipped": {"delivered": "captured"},
    "delivered": {"returned": "refunded"},
}


def create_app(settings: Settings | None = None) -> FastAPI:
    settings = settings or Settings.from_env()
    setup_logging(settings.version)
    metrics = Metrics()
    database = Database(settings, metrics)

    @asynccontextmanager
    async def lifespan(_: FastAPI):
        database.open()
        yield
        database.close()

    app = FastAPI(title="Shop", version=settings.version, lifespan=lifespan)
    app.state.database = database
    app.add_middleware(ObserveMiddleware, metrics=metrics)
    add_error_handlers(app)
    add_routes(app, database, metrics, settings)
    pages.add_pages(app, database)
    return app


def add_error_handlers(app: FastAPI) -> None:
    def answer(error_class: type[Exception], status: int, detail: str) -> None:
        def handle(_: Request, error: Exception) -> JSONResponse:
            # Only the class: the message of a database error can hold values
            log.warning("database error", extra={"fields": {"error": type(error).__name__}})
            headers = {"Retry-After": "1"} if status == 503 else None
            return JSONResponse({"detail": detail}, status, headers)

        app.add_exception_handler(error_class, handle)

    answer(psycopg.errors.ForeignKeyViolation, 404, "unknown customer or product")
    answer(psycopg.IntegrityError, 409, "the change conflicts with existing data")
    answer(psycopg.DataError, 422, "the database refused a value")
    answer(psycopg.errors.QueryCanceled, 504, "the database took too long")
    answer(psycopg.OperationalError, 503, "the database is not available")  # no connection, deadlock, too many connections
    answer(PoolTimeout, 503, "no free database connection")


def add_routes(app: FastAPI, database: Database, metrics: Metrics, settings: Settings) -> None:
    # Each endpoint borrows a connection inside its function, not as a FastAPI dependency: dependencies run
    # even when the request is invalid, and such a request must not use up the pool.

    # --- Operations ------------------------------------------------------------------------

    @app.get("/health")
    def health(response: Response):
        healthy = database.is_healthy()
        response.status_code = 200 if healthy else 503
        return {"status": "ok" if healthy else "database not available", "version": settings.version}

    @app.get("/metrics")
    def get_metrics():
        return Response(generate_latest(metrics.registry), media_type=CONTENT_TYPE_LATEST)

    # --- Customers -------------------------------------------------------------------------

    @app.get("/customers")
    def customers_by_email(email: Annotated[str, Query(min_length=3, max_length=320, pattern=NO_ZERO_CHARACTER)]):
        with database.session() as db:
            return db.all(sql.CUSTOMERS_BY_EMAIL, email=email)

    @app.get("/customers/{customer_id}")
    def customer(customer_id: Id):
        with database.session() as db:
            return service.found(db.one(sql.CUSTOMER, customer_id=customer_id), "customer")

    @app.get("/customers/{customer_id}/orders")
    def order_history(customer_id: Id, page: Page = 1, page_size: PageSize = 20):
        with database.session() as db:
            return service.order_history(db, customer_id, page, page_size)

    # --- Orders ----------------------------------------------------------------------------

    @app.get("/orders")
    def orders_by_status(status: OrderStatus, limit: Limit = 50):
        with database.session() as db:
            return db.all(sql.ORDERS_BY_STATUS, status=status, limit=limit)

    @app.get("/orders/{order_id}")
    def order(order_id: Id):
        with database.session() as db:
            result = service.found(db.one(sql.ORDER, order_id=order_id), "order")
            result["lines"] = db.all(sql.ORDER_LINES, order_id=order_id)
            result["payments"] = db.all(sql.ORDER_PAYMENTS, order_id=order_id)
            return result

    @app.post("/orders", status_code=201)
    def place_order(new: NewOrder):
        with database.session() as db:
            return service.place_order(db, new)

    @app.put("/orders/{order_id}/status")
    def change_status(order_id: Id, change: StatusChange):
        with database.session() as db:
            with db.transaction():
                # Locked until the end, so two changes of the same order can't both succeed
                current = service.found(db.one(sql.LOCK_ORDER, order_id=order_id), "order")["status"]
                payment_status = STATUS_CHANGES.get(current, {}).get(change.status)
                if payment_status is None:
                    raise HTTPException(409, f"an order that is {current} can't become {change.status}")
                changed = db.one(sql.SET_ORDER_STATUS, order_id=order_id, status=change.status)
                db.run(sql.SET_PAYMENT_STATUS, order_id=order_id, status=payment_status)
                if change.status in ("cancelled", "returned"):
                    lines = db.all(sql.ORDER_LINES, order_id=order_id)
                    for line in sorted(lines, key=lambda line: line["product_id"]):
                        db.run(sql.RETURN_STOCK, product_id=line["product_id"], quantity=line["quantity"])
            return changed

    # --- Products --------------------------------------------------------------------------

    @app.get("/products")
    def search_products(
        q: Annotated[str, Query(max_length=100, pattern=NO_ZERO_CHARACTER)] = "",
        category_id: CategoryId = None,
        color: Annotated[str | None, Query(max_length=20, pattern=r"^[a-z]+$")] = None,
        page: Page = 1,
        page_size: PageSize = 20,
    ):
        with database.session() as db:
            return service.search_products(db, q, category_id, color, page, page_size)

    @app.get("/products/{product_id}")
    def product(product_id: Id):
        with database.session() as db:
            return service.product(db, product_id)

    @app.post("/products/{product_id}/reviews", status_code=201)
    def add_review(product_id: Id, new: NewReview):
        with database.session() as db:
            return db.one(sql.ADD_REVIEW, product_id=product_id, **new.model_dump())

    # --- Reports ---------------------------------------------------------------------------

    @app.get("/reports/top-products")
    def top_products(period: Annotated[Period, Depends()], limit: Limit = 10):
        with database.session() as db:
            return db.all(sql.TOP_PRODUCTS, start=period.start, end=period.end, limit=limit)

    @app.get("/reports/daily-sales")
    def daily_sales(period: Annotated[Period, Depends()], category_id: CategoryId = None):
        with database.session() as db:
            return db.all(sql.DAILY_SALES, start=period.start_day, end=period.end_day, category_id=category_id)

    @app.get("/reports/events")
    def event_counts(period: Annotated[Period, Depends()]):
        with database.session() as db:
            return db.all(sql.EVENT_COUNTS, start=period.start, end=period.end)

    # --- Events ----------------------------------------------------------------------------

    @app.post("/events", status_code=201)
    def add_event(new: NewEvent):
        with database.session() as db:
            values = new.model_dump()
            values["payload"] = Jsonb(values["payload"])
            return db.one(sql.ADD_EVENT, **values)
