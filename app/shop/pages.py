"""Four pages for people, from the same statements as the API. Each page shows what it cost the database.

/shop                      search products
/shop/products/{id}        a product and its newest reviews
/shop/order                place an order
/shop/history              a customer's orders
"""

from pathlib import Path
from typing import Annotated

import psycopg
from fastapi import FastAPI, Form, HTTPException, Query, Request
from fastapi.responses import HTMLResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from pydantic import ValidationError

from . import service
from .database import Database
from .models import NO_ZERO_CHARACTER, CategoryId, Id, NewOrder, Page
from .observe import current_request

HERE = Path(__file__).parent
PAGE_SIZE = 20
PAYMENT_METHODS = ["card", "paypal", "bank_transfer", "gift_card"]
FIELD_NAMES = {"customer_id": "customer number", "payment_method": "payment", "lines": "product number and quantity (1 to 100)"}

templates = Jinja2Templates(directory=HERE / "templates")  # escapes every value: names and reviews are not trusted
templates.env.globals["cost"] = current_request.get  # read while the page is drawn, after its statements ran


def from_this_site(request: Request) -> bool:
    """A form sent by another web page in the same browser must not place orders (cross-site request forgery)."""
    if request.headers.get("sec-fetch-site", "same-origin") not in ("same-origin", "none"):
        return False
    origin = request.headers.get("origin")
    return origin is None or origin == f"{request.url.scheme}://{request.headers.get('host')}"


def add_pages(app: FastAPI, database: Database) -> None:
    app.mount("/static", StaticFiles(directory=HERE / "static"), name="static")

    def page(request: Request, name: str, status: int = 200, **values) -> HTMLResponse:
        return templates.TemplateResponse(request, name, values, status_code=status)

    def problem(request: Request, error: HTTPException) -> HTMLResponse:
        return page(request, "problem.html", error.status_code, message=error.detail)

    @app.get("/", include_in_schema=False)
    def home():
        return RedirectResponse("/shop", status_code=303)

    @app.get("/shop", response_class=HTMLResponse, include_in_schema=False)
    def search(
        request: Request,
        q: Annotated[str, Query(max_length=100, pattern=NO_ZERO_CHARACTER)] = "",
        category_id: CategoryId = None,
        color: Annotated[str | None, Query(max_length=20, pattern=r"^[a-z]*$")] = None,
        page_number: Annotated[Page, Query(alias="page")] = 1,
    ):
        with database.session() as db:
            products = service.search_products(db, q, category_id, color or None, page_number, PAGE_SIZE)
        return page(request, "search.html", products=products, q=q, color=color or "", category_id=category_id, page=page_number)

    @app.get("/shop/products/{product_id}", response_class=HTMLResponse, include_in_schema=False)
    def product(request: Request, product_id: Id):
        try:
            with database.session() as db:
                found = service.product(db, product_id)
        except HTTPException as error:
            return problem(request, error)
        return page(request, "product.html", product=found)

    @app.get("/shop/order", response_class=HTMLResponse, include_in_schema=False)
    def order_form(request: Request, product_id: Annotated[int | None, Query(ge=1)] = None):
        return page(request, "order.html", form={"product_id": product_id or "", "quantity": 1}, methods=PAYMENT_METHODS)

    @app.post("/shop/order", response_class=HTMLResponse, include_in_schema=False)
    def place_order(
        request: Request,
        customer_id: Annotated[str, Form()] = "",
        product_id: Annotated[str, Form()] = "",
        quantity: Annotated[str, Form()] = "",
        payment_method: Annotated[str, Form()] = "",
    ):
        form = {"customer_id": customer_id, "product_id": product_id, "quantity": quantity, "payment_method": payment_method}

        def again(status: int, message: str) -> HTMLResponse:
            return page(request, "order.html", status, form=form, methods=PAYMENT_METHODS, message=message)

        if not from_this_site(request):
            return again(403, "refused: this form was sent by another web site")
        try:
            new = NewOrder(
                customer_id=customer_id, payment_method=payment_method, lines=[{"product_id": product_id, "quantity": quantity}]
            )
        except ValidationError as error:
            fields = sorted({FIELD_NAMES.get(str(problem["loc"][0]), "the form") for problem in error.errors()})
            return again(422, "please check: " + ", ".join(fields))
        try:
            with database.session() as db:
                placed = service.place_order(db, new)
        except HTTPException as error:
            return again(error.status_code, error.detail)
        except psycopg.errors.ForeignKeyViolation:
            return again(404, "unknown customer")
        # A new page, so that reloading it can't place the order twice
        return RedirectResponse(f"/shop/history?customer_id={new.customer_id}&placed={placed['id']}", status_code=303)

    @app.get("/shop/history", response_class=HTMLResponse, include_in_schema=False)
    def history(
        request: Request,
        customer_id: Annotated[int | None, Query(ge=1, le=2**63 - 1)] = None,
        page_number: Annotated[Page, Query(alias="page")] = 1,
        placed: Annotated[int | None, Query(ge=1)] = None,
    ):
        if customer_id is None:
            return page(request, "history.html", orders=None, customer_id="", page=1, placed=None)
        try:
            with database.session() as db:
                orders = service.order_history(db, customer_id, page_number, PAGE_SIZE)
        except HTTPException as error:
            return problem(request, error)
        return page(request, "history.html", orders=orders, customer_id=customer_id, page=page_number, placed=placed)
