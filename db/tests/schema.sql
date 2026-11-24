-- Run by db/test.sh on a freshly migrated database. Everything is rolled back at the end.

begin;

create function pg_temp.expect(ok boolean, message text) returns void language plpgsql as $$
begin
  if ok is not true then raise exception 'expected: %', message; end if;
end $$;

-- The statement must fail with the given error class
create function pg_temp.expect_error(statement text, state text, message text) returns void language plpgsql as $$
begin
  begin
    execute statement;
  exception when others then
    if sqlstate = state then return; end if;
    raise exception 'expected: %, got error % (%)', message, sqlstate, sqlerrm;
  end;
  raise exception 'expected: %, but the statement worked', message;
end $$;

insert into shop.categories (name) values ('Books'), ('Games');
insert into shop.customers (email, full_name, country) values ('a@example.com', 'Ann', 'DE');
insert into shop.products (category_id, sku, name, price) values (1, 'B-1', 'Book', 10.00), (2, 'G-1', 'Game', 25.50);
insert into shop.inventory (product_id, quantity) values (1, 5), (2, 0);
insert into shop.orders (customer_id, status, total, created_at) values
  (1, 'delivered', 45.50, '2026-01-01 12:00+00'), (1, 'cancelled', 10.00, '2026-01-01 13:00+00'), (1, 'pending', 0, '2026-01-02 12:00+00');
insert into shop.order_items values (1, 1, 1, 2, 10.00), (1, 2, 2, 1, 25.50), (2, 1, 1, 1, 10.00);
insert into shop.payments (order_id, method, status, amount) values (1, 'card', 'captured', 20.00), (1, 'gift_card', 'captured', 25.50), (1, 'card', 'failed', 45.50);
insert into shop.reviews (product_id, customer_id, rating, title) values (1, 1, 5, 'Good'), (1, 1, 2, 'Hm');

-- wrong data is refused
select pg_temp.expect_error($$insert into shop.orders (customer_id, status, total) values (999, 'paid', 1)$$, '23503', 'no order for an unknown customer');
select pg_temp.expect_error($$insert into shop.orders (customer_id, status, total) values (1, 'lost', 1)$$, '23514', 'no unknown order status');
select pg_temp.expect_error($$insert into shop.order_items values (1, 9, 1, 0, 1)$$, '23514', 'no order line with quantity 0');
select pg_temp.expect_error($$update shop.inventory set quantity = quantity - 1 where product_id = 2$$, '23514', 'stock never below zero');
select pg_temp.expect_error($$insert into shop.reviews (product_id, customer_id, rating, title) values (1, 1, 6, 'x')$$, '23514', 'no rating above 5');

-- the views: two items and two captured payments must not multiply each other
select pg_temp.expect((select (line_count, item_count, paid) = (2, 3, 45.50) from shop.v_order_summary where order_id = 1), 'order 1: 2 lines, 3 items, 45.50 paid');
select pg_temp.expect((select (line_count, item_count, paid) = (0, 0, 0) from shop.v_order_summary where order_id = 3), 'an order without lines is listed with zeros');

refresh materialized view shop.mv_daily_sales;
refresh materialized view shop.mv_product_rating;
select pg_temp.expect((select sum(revenue) = 45.50 and sum(units) = 3 from shop.mv_daily_sales), 'daily sales ignore cancelled orders');
select pg_temp.expect((select (review_count, average_rating) = (2, 3.50) from shop.mv_product_rating where product_id = 1), 'average rating 3.50 from 2 reviews');

-- only keys are indexed at first; every further index comes with a measurement
select pg_temp.expect((
  select count(*) = 0
  from pg_index i
  join pg_class t on t.oid = i.indrelid
  join pg_namespace n on n.oid = t.relnamespace
  where n.nspname = 'shop' and t.relkind = 'r' and not i.indisprimary
), 'no index on the tables except primary keys');

-- size history: one database row, every table and every index of the shop
select pg_temp.expect(ops.take_size_snapshot() = (
  select 1 + (select count(*) from pg_stat_user_tables where schemaname = 'shop') + (select count(*) from pg_stat_user_indexes where schemaname = 'shop')
), 'a snapshot holds the database, all tables and all indexes');
select pg_temp.expect((select count(*) = 1 and min(bytes) > 0 from ops.size_history where kind = 'table' and relation = 'orders'), 'the orders table is in the snapshot');
select pg_temp.expect((select count(*) = 1 from ops.size_history where kind = 'index' and relation = 'orders_pkey' and table_name = 'orders'), 'the index is linked to its table');

-- rights: app_ro only reads, app_rw changes data but not tables, obs_monitor sees no shop data
set local role app_ro;
select pg_temp.expect((select count(*) = 1 from shop.customers), 'app_ro can read');
select pg_temp.expect_error('delete from shop.reviews', '42501', 'app_ro cannot change data');
reset role;
set local role app_rw;
insert into shop.events (event_type, session_id) values ('view', gen_random_uuid());
select pg_temp.expect_error('drop table shop.events', '42501', 'app_rw cannot drop tables');
select pg_temp.expect_error('create table shop.x (id int)', '42501', 'app_rw cannot create tables');
select pg_temp.expect_error('select ops.take_size_snapshot()', '42501', 'app_rw cannot take snapshots');
reset role;
set local role obs_monitor;
select pg_temp.expect((select count(*) > 0 from ops.size_history), 'obs_monitor can read the size history');
select pg_temp.expect_error('select * from shop.customers', '42501', 'obs_monitor cannot read customers');
reset role;

rollback;
