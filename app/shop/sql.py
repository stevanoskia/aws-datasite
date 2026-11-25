"""Every SQL statement of the application.

Values are always parameters, never part of the text. The name is sent as a comment, so that a statement
can be recognised in pg_stat_statements and in the server log.
"""

from dataclasses import dataclass, field


@dataclass(frozen=True)
class Query:
    name: str
    body: str
    text: bytes = field(init=False)

    def __post_init__(self) -> None:
        lines = " ".join(line.strip() for line in self.body.strip().splitlines())
        object.__setattr__(self, "text", f"/* {self.name} */ {lines}".encode())


def like_pattern(search: str) -> str:
    """The text anywhere in the value; % and _ are ordinary characters."""
    escaped = search.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
    return f"%{escaped}%"


PING = Query("ping", "select 1 as ok")

# --- Customers -----------------------------------------------------------------------------

CUSTOMER = Query(
    "customer",
    """
    select id, email, full_name, country, is_business, created_at, last_login_at
    from shop.customers
    where id = %(customer_id)s
    """,
)

CUSTOMERS_BY_EMAIL = Query(
    "customers_by_email",
    """
    select id, email, full_name, country, is_business, created_at, last_login_at
    from shop.customers
    where lower(email) = lower(%(email)s)
    order by id
    """,
)

ORDER_HISTORY = Query(
    "order_history",
    """
    select id, status, total, created_at
    from shop.orders
    where customer_id = %(customer_id)s
    order by created_at desc, id desc
    limit %(limit)s offset %(offset)s
    """,
)

# --- Orders --------------------------------------------------------------------------------

ORDER = Query(
    "order",
    """
    select o.id, o.status, o.total, o.created_at, o.updated_at, c.id as customer_id, c.full_name as customer_name
    from shop.orders o
    join shop.customers c on c.id = o.customer_id
    where o.id = %(order_id)s
    """,
)

ORDER_LINES = Query(
    "order_lines",
    """
    select i.line_no, i.product_id, p.name as product_name, i.quantity, i.unit_price
    from shop.order_items i
    join shop.products p on p.id = i.product_id
    where i.order_id = %(order_id)s
    order by i.line_no
    """,
)

ORDER_PAYMENTS = Query(
    "order_payments",
    """
    select id, method, status, amount, created_at
    from shop.payments
    where order_id = %(order_id)s
    order by id
    """,
)

ORDERS_BY_STATUS = Query(
    "orders_by_status",
    """
    select id, customer_id, status, total, created_at
    from shop.orders
    where status = %(status)s
    order by created_at, id
    limit %(limit)s
    """,
)

# --- Products ------------------------------------------------------------------------------

PRODUCT_SEARCH = Query(
    "product_search",
    """
    select p.id, p.sku, p.name, p.price, p.category_id, p.attributes,
      r.average_rating, coalesce(r.review_count, 0) as review_count
    from shop.products p
    left join shop.mv_product_rating r on r.product_id = p.id
    where p.is_active
      and p.name ilike %(pattern)s
      and (%(category_id)s::integer is null or p.category_id = %(category_id)s::integer)
      and (%(attributes)s::jsonb is null or p.attributes @> %(attributes)s::jsonb)
    order by p.id
    limit %(limit)s offset %(offset)s
    """,
)

PRODUCT = Query(
    "product",
    """
    select p.id, p.sku, p.name, p.description, p.price, p.attributes, p.is_active, c.name as category,
      coalesce(i.quantity, 0) as stock, r.average_rating, coalesce(r.review_count, 0) as review_count
    from shop.products p
    join shop.categories c on c.id = p.category_id
    left join shop.inventory i on i.product_id = p.id
    left join shop.mv_product_rating r on r.product_id = p.id
    where p.id = %(product_id)s
    """,
)

PRODUCT_REVIEWS = Query(
    "product_reviews",
    """
    select id, customer_id, rating, title, body, created_at
    from shop.reviews
    where product_id = %(product_id)s
    order by created_at desc, id desc
    limit %(limit)s
    """,
)

# --- Reports -------------------------------------------------------------------------------

TOP_PRODUCTS = Query(
    "top_products",
    """
    select i.product_id, p.name, sum(i.quantity) as units, sum(i.quantity * i.unit_price) as revenue
    from shop.orders o
    join shop.order_items i on i.order_id = o.id
    join shop.products p on p.id = i.product_id
    where o.created_at >= %(start)s and o.created_at < %(end)s
      and o.status not in ('cancelled', 'returned')
    group by i.product_id, p.name
    order by revenue desc, i.product_id
    limit %(limit)s
    """,
)

DAILY_SALES = Query(
    "daily_sales",
    """
    select day, sum(units) as units, sum(revenue) as revenue
    from shop.mv_daily_sales
    where day >= %(start)s and day < %(end)s
      and (%(category_id)s::integer is null or category_id = %(category_id)s::integer)
    group by day
    order by day
    """,
)

EVENT_COUNTS = Query(
    "event_counts",
    """
    select event_type, count(*) as events, count(distinct session_id) as sessions
    from shop.events
    where created_at >= %(start)s and created_at < %(end)s
    group by event_type
    order by event_type
    """,
)

# --- Placing an order ----------------------------------------------------------------------

PRODUCT_PRICES = Query(
    "product_prices",
    """
    select id, price
    from shop.products
    where id = any(%(product_ids)s::bigint[]) and is_active
    """,
)

TAKE_STOCK = Query(
    "take_stock",
    """
    update shop.inventory
    set quantity = quantity - %(quantity)s, updated_at = now()
    where product_id = %(product_id)s and quantity >= %(quantity)s
    """,
)

ADD_ORDER = Query(
    "add_order",
    """
    insert into shop.orders (customer_id, status, total)
    values (%(customer_id)s, 'pending', %(total)s)
    returning id, status, total, created_at
    """,
)

ADD_ORDER_LINES = Query(
    "add_order_lines",
    """
    insert into shop.order_items (order_id, line_no, product_id, quantity, unit_price)
    select %(order_id)s, line.no, line.product_id, line.quantity, line.unit_price
    from unnest(%(line_nos)s::smallint[], %(product_ids)s::bigint[], %(quantities)s::integer[], %(prices)s::numeric[])
      as line (no, product_id, quantity, unit_price)
    """,
)

ADD_PAYMENT = Query(
    "add_payment",
    """
    insert into shop.payments (order_id, method, status, amount)
    values (%(order_id)s, %(method)s, 'authorized', %(amount)s)
    """,
)

# --- Changing the status of an order -------------------------------------------------------

LOCK_ORDER = Query("lock_order", "select status from shop.orders where id = %(order_id)s for update")

SET_ORDER_STATUS = Query(
    "set_order_status",
    """
    update shop.orders
    set status = %(status)s, updated_at = now()
    where id = %(order_id)s
    returning id, status, total, created_at, updated_at
    """,
)

SET_PAYMENT_STATUS = Query(
    "set_payment_status",
    "update shop.payments set status = %(status)s where order_id = %(order_id)s",
)

RETURN_STOCK = Query(
    "return_stock",
    """
    update shop.inventory
    set quantity = quantity + %(quantity)s, updated_at = now()
    where product_id = %(product_id)s
    """,
)

# --- Reviews and events --------------------------------------------------------------------

ADD_REVIEW = Query(
    "add_review",
    """
    insert into shop.reviews (product_id, customer_id, rating, title, body)
    values (%(product_id)s, %(customer_id)s, %(rating)s, %(title)s, %(body)s)
    returning id, created_at
    """,
)

ADD_EVENT = Query(
    "add_event",
    """
    insert into shop.events (customer_id, product_id, event_type, session_id, payload)
    values (%(customer_id)s, %(product_id)s, %(event_type)s, %(session_id)s, %(payload)s)
    returning id
    """,
)
