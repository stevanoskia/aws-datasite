"""What the shop does, shared by the API (main.py) and the pages (pages.py): the same request runs the same statements."""

from fastapi import HTTPException
from psycopg.types.json import Jsonb

from . import sql
from .database import Session
from .models import NewOrder


def found(row: dict | None, what: str) -> dict:
    if row is None:
        raise HTTPException(404, f"unknown {what}")
    return row


def order_history(db: Session, customer_id: int, page: int, page_size: int) -> list[dict]:
    found(db.one(sql.CUSTOMER, customer_id=customer_id), "customer")
    return db.all(sql.ORDER_HISTORY, customer_id=customer_id, limit=page_size, offset=(page - 1) * page_size)


def search_products(db: Session, q: str, category_id: int | None, color: str | None, page: int, page_size: int) -> list[dict]:
    return db.all(
        sql.PRODUCT_SEARCH,
        pattern=sql.like_pattern(q),
        category_id=category_id,
        attributes=Jsonb({"color": color}) if color else None,
        limit=page_size,
        offset=(page - 1) * page_size,
    )


def product(db: Session, product_id: int) -> dict:
    result = found(db.one(sql.PRODUCT, product_id=product_id), "product")
    result["reviews"] = db.all(sql.PRODUCT_REVIEWS, product_id=product_id, limit=10)
    return result


def place_order(db: Session, new: NewOrder) -> dict:
    # Always in the same order: two orders that share products then can't block each other for ever
    lines = sorted(new.lines, key=lambda line: line.product_id)
    product_ids = [line.product_id for line in lines]
    with db.transaction():
        prices = {row["id"]: row["price"] for row in db.all(sql.PRODUCT_PRICES, product_ids=product_ids)}
        if len(prices) != len(lines):
            raise HTTPException(404, "unknown product")
        for line in lines:
            if db.run(sql.TAKE_STOCK, product_id=line.product_id, quantity=line.quantity) == 0:
                raise HTTPException(409, f"not enough stock of product {line.product_id}")
        total = sum(prices[line.product_id] * line.quantity for line in lines)
        placed = db.one(sql.ADD_ORDER, customer_id=new.customer_id, total=total)
        db.run(
            sql.ADD_ORDER_LINES,
            order_id=placed["id"],
            line_nos=list(range(1, len(lines) + 1)),
            product_ids=product_ids,
            quantities=[line.quantity for line in lines],
            prices=[prices[product_id] for product_id in product_ids],
        )
        db.run(sql.ADD_PAYMENT, order_id=placed["id"], method=new.payment_method, amount=total)
    return placed
