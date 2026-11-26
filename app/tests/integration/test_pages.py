"""The four pages, on the real database: they show the same data as the API, escape what people wrote, and say what they cost."""

import re

import pytest

ORDER_FORM = {"customer_id": "1", "product_id": "", "quantity": "1", "payment_method": "card"}


def footer(html: str) -> tuple[int, float, str]:
    """The cost shown at the bottom of a page: queries, milliseconds in the database, request ID."""
    queries = re.search(r"<b>(\d+)</b> quer", html)
    milliseconds = re.search(r"<b>([\d.]+) ms</b> in the database", html)
    request_id = re.search(r"request <code>([^<]+)</code>", html)
    assert queries and milliseconds and request_id, "the page has no cost footer"
    return int(queries.group(1)), float(milliseconds.group(1)), request_id.group(1)


def test_search_shows_the_same_products_as_the_api(client):
    page = client.get("/shop", params={"q": "lamp"})
    api = client.get("/products", params={"q": "lamp", "page_size": 20}).json()
    assert page.status_code == 200 and api
    assert [int(found) for found in re.findall(r'href="/shop/products/(\d+)"', page.text)] == [p["id"] for p in api]


def test_every_page_shows_what_it_cost(client):
    page = client.get("/shop/products/1", headers={"X-Request-ID": "page-cost-test"})
    queries, milliseconds, request_id = footer(page.text)
    assert (queries, request_id) == (2, "page-cost-test")  # the product, and its reviews
    assert milliseconds > 0


def test_what_people_wrote_is_shown_as_text(client, admin, new_products):
    (product,) = new_products(1)
    admin.execute("update shop.products set name = '<script>alert(1)</script>' where id = %s", (product,))
    review = {"customer_id": 1, "rating": 5, "title": "<img src=x onerror=alert(2)>", "body": ""}
    assert client.post(f"/products/{product}/reviews", json=review).status_code == 201
    page = client.get(f"/shop/products/{product}").text
    assert "<script>alert(1)</script>" not in page and "&lt;script&gt;alert(1)&lt;/script&gt;" in page
    assert "<img src=x" not in page and "&lt;img src=x" in page


def test_an_order_from_the_form_is_placed_once(client, new_products, value):
    (product,) = new_products(5)
    sent = client.post("/shop/order", data={**ORDER_FORM, "product_id": str(product), "quantity": "2"})
    assert sent.status_code == 303
    placed = int(re.search(r"placed=(\d+)", sent.headers["location"]).group(1))
    history = client.get(sent.headers["location"]).text
    assert f"Order {placed} is placed" in history and f"<td>{placed}</td>" in history
    assert value("select quantity from shop.inventory where product_id = %s", product) == 3
    assert value("select count(*) from shop.order_items where order_id = %s and product_id = %s", placed, product) == 1


@pytest.mark.parametrize(
    "change, status, message",
    [
        ({"quantity": "0"}, 422, "please check: product number and quantity"),
        ({"customer_id": "abc"}, 422, "please check: customer number"),
        ({"quantity": "99"}, 409, "not enough stock"),
        ({"customer_id": "999999"}, 404, "unknown customer"),
        ({"product_id": "999999"}, 404, "unknown product"),
    ],
)
def test_a_refused_order_says_why_and_changes_nothing(client, new_products, value, change, status, message):
    (product,) = new_products(5)
    before = value("select count(*) from shop.orders")
    answer = client.post("/shop/order", data={**ORDER_FORM, "product_id": str(product), **change})
    assert answer.status_code == status and message in answer.text
    assert value("select count(*) from shop.orders") == before
    assert value("select quantity from shop.inventory where product_id = %s", product) == 5


@pytest.mark.parametrize(
    "headers",
    [
        {"Origin": "http://evil.example"},
        {"Sec-Fetch-Site": "cross-site"},
        {"Origin": "http://evil.example", "Sec-Fetch-Site": "same-site"},
    ],
)
def test_another_web_site_cannot_place_orders(client, new_products, value, headers):
    (product,) = new_products(5)
    answer = client.post("/shop/order", data={**ORDER_FORM, "product_id": str(product)}, headers=headers)
    assert answer.status_code == 403
    assert value("select quantity from shop.inventory where product_id = %s", product) == 5


def test_the_history_page_matches_the_api_page_by_page(client):
    for page in (1, 2):
        html = client.get("/shop/history", params={"customer_id": 2, "page": page}).text
        api = client.get("/customers/2/orders", params={"page": page, "page_size": 20}).json()
        assert [int(order) for order in re.findall(r"<td>(\d+)</td>", html)] == [o["id"] for o in api]


def test_unknown_things_get_a_page_not_a_crash(client):
    for address in ("/shop/products/999999", "/shop/history?customer_id=999999"):
        answer = client.get(address)
        assert answer.status_code == 404 and "unknown" in answer.text and "<footer>" in answer.text
