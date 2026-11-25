import json
import time
from concurrent.futures import ThreadPoolExecutor
from decimal import Decimal
from uuid import uuid4

import psycopg
import pytest

WHALE = 1  # one of the five customers with very many orders


def money(value) -> Decimal:
    return Decimal(str(value)).quantize(Decimal("0.01"))


def ids(rows) -> list[int]:
    return [row["id"] for row in rows]


def order_of(*lines, customer_id=WHALE) -> dict:
    lines = [{"product_id": product_id, "quantity": quantity} for product_id, quantity in lines]
    return {"customer_id": customer_id, "payment_method": "card", "lines": lines}


# --- Reading -------------------------------------------------------------------------------


def test_health(client):
    assert client.get("/health").json() == {"status": "ok", "version": "dev"}


def test_order_history_is_complete_and_newest_first(client, admin):
    expected = admin.execute(
        "select id from shop.orders where customer_id = 2 order by created_at desc, id desc limit 40"
    ).fetchall()
    assert len(expected) == 40
    pages = [client.get("/customers/2/orders", params={"page": page, "page_size": 20}).json() for page in (1, 2)]
    assert ids(pages[0]) + ids(pages[1]) == ids(expected)


def test_unknown_things_are_not_found(client):
    for address in ("/customers/999999", "/customers/999999/orders", "/orders/999999999", "/products/999999"):
        assert client.get(address).status_code == 404


def test_order_detail(client, admin):
    order = client.get("/orders/4000").json()
    assert sum(money(line["unit_price"]) * line["quantity"] for line in order["lines"]) == money(order["total"])
    assert [money(payment["amount"]) for payment in order["payments"]] == [money(order["total"])]
    expected = admin.execute(
        "select c.full_name from shop.orders o join shop.customers c on c.id = o.customer_id where o.id = 4000"
    ).fetchone()
    assert order["customer_name"] == expected["full_name"]
    assert len(order["lines"]) == admin.execute("select count(*) from shop.order_items where order_id = 4000").fetchone()["count"]


def test_customers_are_found_by_email_in_any_case(client, admin):
    email = admin.execute("select email from shop.customers where email <> lower(email) limit 1").fetchone()["email"]
    for written in (email, email.lower(), email.upper()):
        assert [customer["email"] for customer in client.get("/customers", params={"email": written}).json()] == [email]


def test_orders_by_status_oldest_first(client, admin):
    expected = admin.execute("select id from shop.orders where status = 'returned' order by created_at, id limit 10").fetchall()
    assert ids(client.get("/orders", params={"status": "returned", "limit": 10}).json()) == ids(expected)


def test_inactive_products_are_not_found(client, admin, new_products):
    visible, hidden = new_products(1, 1)
    admin.execute("update shop.products set name = 'Findme' where id = any(%s)", ([visible, hidden],))
    admin.execute("update shop.products set is_active = false where id = %s", (hidden,))
    assert ids(client.get("/products", params={"q": "findme"}).json()) == [visible]


def test_product_search(client, admin):
    def search(**params):
        return client.get("/products", params={"page_size": 100, **params}).json()

    expected = admin.execute("select id from shop.products where name ilike '%%lamp%%' and is_active order by id").fetchall()
    assert expected and ids(search(q="LAMP")) == ids(expected)
    assert search(q="%") == [] and search(q="_") == []
    assert search(q="'; drop table shop.reviews; --") == []

    red = admin.execute("select id from shop.products where attributes->>'color' = 'red' and is_active order by id").fetchall()
    assert red and ids(search(color="red")) == ids(red)

    category = admin.execute("select category_id from shop.products where is_active order by id limit 1").fetchone()[
        "category_id"
    ]
    expected = admin.execute(
        "select id from shop.products where category_id = %s and is_active order by id", (category,)
    ).fetchall()
    assert ids(search(category_id=category)) == ids(expected)
    assert ids(search(page_size=5, page=2)) == ids(search(page_size=10))[5:]


def test_product_detail(client, admin):
    product = client.get("/products/1").json()
    expected = admin.execute("""
        select i.quantity, r.review_count, r.average_rating
        from shop.inventory i join shop.mv_product_rating r using (product_id) where product_id = 1
    """).fetchone()
    assert (product["stock"], product["review_count"]) == (expected["quantity"], expected["review_count"])
    assert money(product["average_rating"]) == expected["average_rating"]
    newest = admin.execute(
        "select id from shop.reviews where product_id = 1 order by created_at desc, id desc limit 10"
    ).fetchall()
    assert ids(product["reviews"]) == ids(newest)


def test_top_products(client, admin):
    expected = admin.execute("""
        with sold as (
          select i.product_id, i.quantity * i.unit_price as revenue from shop.order_items i
          where i.order_id in (
            select id from shop.orders
            where created_at >= '2026-01-01 00:00+00' and created_at < '2026-03-01 00:00+00'
              and status in ('pending', 'paid', 'shipped', 'delivered'))
        )
        select product_id, sum(revenue) as revenue from sold group by 1 order by 2 desc, 1 limit 5
    """).fetchall()
    period = {"start": "2026-01-01", "end": "2026-03-01", "limit": 5}
    rows = client.get("/reports/top-products", params=period).json()
    assert len(rows) == 5
    assert [(row["product_id"], money(row["revenue"])) for row in rows] == [
        (row["product_id"], row["revenue"]) for row in expected
    ]


def test_daily_sales(client, admin):
    period = {"start": "2026-01-01", "end": "2026-01-08"}
    rows = client.get("/reports/daily-sales", params=period).json()
    assert [row["day"] for row in rows] == [f"2026-01-0{day}" for day in range(1, 8)]
    revenue = admin.execute(
        "select sum(revenue) as revenue from shop.mv_daily_sales where day between '2026-01-01' and '2026-01-07'"
    ).fetchone()["revenue"]
    assert sum(money(row["revenue"]) for row in rows) == revenue


def test_event_counts(client, admin):
    expected = admin.execute("""
        select event_type, count(*) as events, count(distinct session_id) as sessions from shop.events
        where created_at between '2026-01-01 00:00+00' and '2026-01-31 23:59:59.999999+00' group by 1 order by 1
    """).fetchall()
    assert expected and client.get("/reports/events", params={"start": "2026-01-01", "end": "2026-02-01"}).json() == expected


# --- Placing orders ------------------------------------------------------------------------


def test_place_order(client, admin, new_products, value):
    first, second = new_products(10, 10, price="10.50")
    answer = client.post("/orders", json=order_of((second, 1), (first, 3)))
    assert answer.status_code == 201
    order = client.get(f"/orders/{answer.json()['id']}").json()
    assert (order["status"], money(order["total"]), order["customer_id"]) == ("pending", Decimal("42.00"), WHALE)
    assert [(line["product_id"], line["quantity"], money(line["unit_price"])) for line in order["lines"]] == [
        (first, 3, Decimal("10.50")),
        (second, 1, Decimal("10.50")),
    ]
    assert [(p["method"], p["status"], money(p["amount"])) for p in order["payments"]] == [
        ("card", "authorized", Decimal("42.00"))
    ]
    assert value("select quantity from shop.inventory where product_id = %s", first) == 7
    assert value("select quantity from shop.inventory where product_id = %s", second) == 9


@pytest.mark.parametrize("problem", ["no stock", "unknown product", "inactive product", "unknown customer"])
def test_a_refused_order_changes_nothing(client, admin, new_products, value, problem):
    product, other = new_products(10, 1)
    order, status = {
        "no stock": (order_of((product, 1), (other, 2)), 409),
        "unknown product": (order_of((product, 1), (999_999, 1)), 404),
        "inactive product": (order_of((product, 1), (other, 1)), 404),
        "unknown customer": (order_of((product, 1), customer_id=999_999), 404),
    }[problem]
    if problem == "inactive product":
        admin.execute("update shop.products set is_active = false where id = %s", (other,))
    before = value("select (select count(*) from shop.orders) + (select count(*) from shop.payments)")
    answer = client.post("/orders", json=order)
    assert answer.status_code == status
    if problem == "no stock":  # the app's own message: the database's rule is only the second line of defence
        assert answer.json()["detail"] == f"not enough stock of product {other}"
    assert value("select quantity from shop.inventory where product_id = %s", product) == 10
    assert value("select (select count(*) from shop.orders) + (select count(*) from shop.payments)") == before


def test_the_last_items_are_sold_only_once(client, new_products, value):
    (product,) = new_products(5)
    with ThreadPoolExecutor(12) as pool:
        answers = list(pool.map(lambda _: client.post("/orders", json=order_of((product, 1))).status_code, range(12)))
    assert sorted(answers) == [201] * 5 + [409] * 7
    assert value("select quantity from shop.inventory where product_id = %s", product) == 0


def test_orders_that_share_products_do_not_block_each_other(client, new_products):
    first, second, third = new_products(1000, 1000, 1000)
    orders = [order_of((first, 1), (second, 1), (third, 1)), order_of((third, 1), (second, 1), (first, 1))] * 40
    with ThreadPoolExecutor(8) as pool:
        answers = list(pool.map(lambda order: client.post("/orders", json=order).status_code, orders))
    assert set(answers) == {201}


# --- Status changes ------------------------------------------------------------------------


def payment_status(client, order_id) -> str:
    return client.get(f"/orders/{order_id}").json()["payments"][0]["status"]


def test_an_order_goes_through_its_life(client, new_products, value):
    (product,) = new_products(10)
    order_id = client.post("/orders", json=order_of((product, 4))).json()["id"]
    steps = [("paid", "captured"), ("shipped", "captured"), ("delivered", "captured"), ("returned", "refunded")]
    for status, payment in steps:
        assert client.put(f"/orders/{order_id}/status", json={"status": status}).json()["status"] == status
        assert payment_status(client, order_id) == payment
        assert value("select quantity from shop.inventory where product_id = %s", product) == (10 if status == "returned" else 6)


def test_a_cancelled_order_gives_its_stock_back_once(client, new_products, value):
    (product,) = new_products(10)
    order_id = client.post("/orders", json=order_of((product, 4))).json()["id"]
    with ThreadPoolExecutor(6) as pool:
        change = {"status": "cancelled"}
        answers = list(pool.map(lambda _: client.put(f"/orders/{order_id}/status", json=change).status_code, range(6)))
    assert sorted(answers) == [200] + [409] * 5
    assert payment_status(client, order_id) == "failed"
    assert value("select quantity from shop.inventory where product_id = %s", product) == 10


def test_impossible_status_changes_are_refused(client, new_products):
    (product,) = new_products(10)
    order_id = client.post("/orders", json=order_of((product, 1))).json()["id"]
    for status in ("pending", "shipped", "delivered", "returned"):
        answer = client.put(f"/orders/{order_id}/status", json={"status": status})
        assert (answer.status_code, answer.json()["detail"]) == (409, f"an order that is pending can't become {status}")
    assert client.put("/orders/999999999/status", json={"status": "paid"}).status_code == 404


# --- Reviews and events --------------------------------------------------------------------


def test_add_review(client, new_products):
    (product,) = new_products(1)
    review = {"customer_id": WHALE, "rating": 4, "title": "It's 100% good; -- really", "body": ""}
    assert client.post(f"/products/{product}/reviews", json=review).status_code == 201
    (stored,) = client.get(f"/products/{product}").json()["reviews"]
    assert (stored["rating"], stored["title"], stored["customer_id"]) == (4, review["title"], WHALE)
    assert client.post("/products/999999/reviews", json=review).status_code == 404


def test_add_event(client, admin):
    session = str(uuid4())
    event = {"event_type": "search", "session_id": session, "payload": {"q": "lamp"}}
    event_id = client.post("/events", json=event).json()["id"]
    stored = admin.execute("select * from shop.events where id = %s", (event_id,)).fetchone()
    assert (stored["event_type"], str(stored["session_id"]), stored["payload"]) == ("search", session, {"q": "lamp"})
    assert stored["customer_id"] is None


# --- Operations ----------------------------------------------------------------------------


def test_metrics_and_headers(client):
    answer = client.get("/orders/4000", headers={"X-Request-ID": "my-request-1"})
    assert answer.headers["x-request-id"] == "my-request-1"
    assert 'desc="3 queries"' in answer.headers["server-timing"]
    assert len(client.get("/orders/4000", headers={"X-Request-ID": "bad id\t{}"}).headers["x-request-id"]) == 32
    metrics = client.get("/metrics").text
    assert 'shop_http_requests_total{method="GET",route="/orders/{order_id}",status="200"}' in metrics
    assert 'shop_db_query_duration_seconds_count{query="order_lines"}' in metrics
    assert 'shop_db_pool_connections{state="free"}' in metrics
    assert "/orders/4000" not in metrics


def test_the_log_line_has_the_request_but_no_personal_data(run_app, make_settings, capfd):
    client = run_app(make_settings(version="v-test"))
    client.get("/customers", params={"email": "somebody@example.com"}, headers={"X-Request-ID": "log-test"})
    client.get("/health")
    output = capfd.readouterr().out
    (line,) = [json.loads(line) for line in output.splitlines() if "log-test" in line]
    expected = {"route": "/customers", "status": 200, "db_queries": 1, "version": "v-test", "request_id": "log-test"}
    assert {key: line[key] for key in expected} == expected
    assert line["db_ms"] > 0
    assert "somebody" not in output


def test_a_statement_that_takes_too_long_is_stopped(run_app, make_settings, new_products):
    client = run_app(make_settings(statement_timeout_ms=300))
    (product,) = new_products(10)
    with psycopg.connect(dbname="app_test") as blocker:
        blocker.execute("select from shop.inventory where product_id = %s for update", (product,))
        assert client.post("/orders", json=order_of((product, 1))).status_code == 504
    assert client.post("/orders", json=order_of((product, 1))).status_code == 201
    assert 'shop_db_errors_total{query="take_stock",sqlstate="57014"} 1.0' in client.get("/metrics").text


def test_a_full_pool_is_reported_and_recovers(run_app, make_settings, new_products, value):
    client = run_app(make_settings(pool_min=1, pool_max=1, pool_timeout=0.3))
    (product,) = new_products(10)
    with ThreadPoolExecutor(1) as pool, psycopg.connect(dbname="app_test") as blocker:
        blocker.execute("select from shop.inventory where product_id = %s for update", (product,))
        waiting = pool.submit(client.post, "/orders", json=order_of((product, 1)))
        # asked by another connection: inside one transaction the list of sessions never changes
        while not value("select exists (select from pg_stat_activity where usename = 'shop_app' and wait_event_type = 'Lock')"):
            assert not waiting.done()
            time.sleep(0.05)
        assert client.get("/orders/4000").status_code == 503
        blocker.rollback()
        assert waiting.result(20).status_code == 201
    assert client.get("/orders/4000").status_code == 200


def test_a_changed_password_is_picked_up_after_a_lost_connection(run_app, make_settings, admin):
    settings = make_settings(pool_min=1, pool_max=1)
    client = run_app(settings)
    assert client.get("/orders/4000").status_code == 200
    old = settings.db_password_file.read_text()

    def change_password(password: str) -> None:
        admin.execute(f"alter role shop_app password '{password.strip()}'")
        settings.db_password_file.write_text(password)

    change_password("another-one")
    try:
        newest = "select pid from pg_stat_activity where usename = 'shop_app' order by backend_start desc limit 1"
        admin.execute(f"select pg_terminate_backend(({newest}))")
        assert client.get("/orders/4000").status_code == 503
        deadline = time.monotonic() + 20
        while client.get("/orders/4000").status_code != 200:
            assert time.monotonic() < deadline
            time.sleep(0.2)
    finally:
        change_password(old)


@pytest.mark.parametrize("threshold, prepared", [(0, True), (None, False)])
def test_prepared_statements_follow_the_setting(make_settings, threshold, prepared):
    from shop.database import Database
    from shop.observe import Metrics
    from shop.sql import ORDER, Query

    database = Database(make_settings(pool_min=1, pool_max=1, prepare_threshold=threshold), Metrics())
    database.open()
    with database.session() as session:
        session.one(ORDER, order_id=4000)
        found = session.one(
            Query("check", "select count(*) as n from pg_prepared_statements where statement like '/* order */%%'")
        )
    database.close()
    assert (found["n"] == 1) is prepared
