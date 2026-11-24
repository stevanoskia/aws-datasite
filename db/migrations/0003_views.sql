-- One plain view (always current, computed on every read) and two materialized views
-- (stored, as old as their last refresh).

create view shop.v_order_summary as
select
  o.id          as order_id,
  o.created_at,
  o.status,
  c.id          as customer_id,
  c.full_name   as customer_name,
  c.country,
  i.line_count,
  i.item_count,
  o.total,
  p.paid
from shop.orders o
join shop.customers c on c.id = o.customer_id
-- each side is aggregated on its own: joining items and payments directly would multiply the rows
left join lateral (
  select count(*) as line_count, coalesce(sum(quantity), 0) as item_count
  from shop.order_items
  where order_id = o.id
) i on true
left join lateral (
  select coalesce(sum(amount), 0) as paid
  from shop.payments
  where order_id = o.id and status = 'captured'
) p on true;

create materialized view shop.mv_daily_sales as
select
  (o.created_at at time zone 'UTC')::date as day,
  p.category_id,
  count(distinct o.id)                    as orders,
  sum(i.quantity)                         as units,
  sum(i.quantity * i.unit_price)          as revenue
from shop.orders o
join shop.order_items i on i.order_id = o.id
join shop.products p on p.id = i.product_id
where o.status not in ('cancelled', 'returned')
group by 1, 2;

create materialized view shop.mv_product_rating as
select
  product_id,
  count(*)                        as review_count,
  round(avg(rating)::numeric, 2)  as average_rating
from shop.reviews
group by product_id;

-- The keys of the materialized views; a refresh without blocking readers needs them
create unique index mv_daily_sales_key on shop.mv_daily_sales (day, category_id);
create unique index mv_product_rating_key on shop.mv_product_rating (product_id);
