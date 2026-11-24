-- Deletes ALL shop data and the generator's memory. The tables themselves and the size history stay.

begin;
truncate shop.events, shop.reviews, shop.payments, shop.order_items, shop.orders,
  shop.inventory, shop.products, shop.customers, shop.categories restart identity;
drop schema if exists gen cascade;
commit;
refresh materialized view shop.mv_daily_sales;
refresh materialized view shop.mv_product_rating;
