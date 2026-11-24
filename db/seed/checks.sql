-- Run by db/test.sh after the small data set is loaded. Everything is rolled back at the end.

begin;

create function pg_temp.expect(ok boolean, message text) returns void language plpgsql as $$
begin
  if ok is not true then raise exception 'expected: %', message; end if;
end $$;

-- row counts
select pg_temp.expect((select (select count(*) from shop.customers) = s.customers and (select count(*) from shop.products) = s.products
  and (select count(*) from shop.inventory) = s.products and (select count(*) from shop.categories) = s.categories
  and (select count(*) from shop.orders) = s.orders and (select count(*) from shop.payments) = s.orders
  and (select count(*) from shop.reviews) = s.reviews and (select count(*) from shop.events) = s.events from gen.settings s), 'the row counts of the settings');
select pg_temp.expect((select avg(lines) between 2.8 and 3.2 and min(lines) = 1 and max(lines) = 5
  from (select count(*) as lines from shop.order_items group by order_id) x), '1 to 5 lines per order, 3 on average');

-- money adds up
select pg_temp.expect(not exists (select from shop.orders o
  where o.total is distinct from (select sum(quantity * unit_price) from shop.order_items i where i.order_id = o.id)), 'every total is the sum of its lines');
select pg_temp.expect(not exists (select from shop.orders o left join shop.payments p on p.order_id = o.id where p.amount is distinct from o.total), 'every order has one payment of its total');
select pg_temp.expect(not exists (select from shop.order_items i join shop.products p on p.id = i.product_id where i.unit_price <> p.price), 'lines carry the product price');
select pg_temp.expect((select sum(revenue) from shop.mv_daily_sales) = (select sum(total) from shop.orders where status not in ('cancelled', 'returned')), 'the stored sales view matches the orders');

-- the data is uneven on purpose
select pg_temp.expect((select avg((customer_id <= 5)::integer) between 0.07 and 0.13 from shop.orders), 'five customers hold about 10% of the orders');
select pg_temp.expect((select count(distinct customer_id) > 300 from shop.orders), 'the other orders are spread over many customers');
select pg_temp.expect((select avg((product_id <= 10)::integer) between 0.38 and 0.55 from shop.order_items), 'a tenth of the products sells almost half of the lines');
select pg_temp.expect((select avg((status = 'delivered')::integer) between 0.965 and 0.995 from shop.orders), 'about 98% are delivered');
select pg_temp.expect((select avg((status = 'pending')::integer) between 0.0002 and 0.004 from shop.orders), 'about 0.1% are pending');
select pg_temp.expect(not exists (select from shop.orders where status in ('pending', 'paid', 'shipped') and id <= 4750), 'only the newest orders are open');
select pg_temp.expect((select avg((email <> lower(email))::integer) between 0.05 and 0.16 from shop.customers), 'about 10% of the emails have capitals');
select pg_temp.expect((select avg((customer_id is null)::integer) between 0.22 and 0.38 from shop.events), 'about 30% of the events are anonymous');

-- rows are in time order, inside the period
select pg_temp.expect(not exists (select from (select created_at < lag(created_at) over (order by id) as back from shop.events) x where back), 'events are in time order');
select pg_temp.expect(not exists (select from (select created_at < lag(created_at) over (order by id) as back from shop.orders) x where back), 'orders are in time order');
select pg_temp.expect((select min(created_at) >= '2024-11-01 00:00+00' and max(created_at) <= '2026-11-01 00:00+00' from shop.orders), 'orders are inside the period');
select pg_temp.expect(not exists (select from shop.orders o join shop.customers c on c.id = o.customer_id where c.created_at > o.created_at), 'nobody orders before registering');

-- new rows continue after the generated ones, and the first snapshot exists
insert into shop.orders (customer_id, status, total) values (1, 'pending', 0);
insert into shop.events (event_type, session_id) values ('login', gen_random_uuid());
select pg_temp.expect((select max(id) = 5001 from shop.orders) and (select max(id) = 15001 from shop.events), 'new rows get the next number');
select pg_temp.expect((select count(*) > 0 from ops.size_history where kind = 'table' and relation = 'events' and bytes > 0), 'the first size snapshot is stored');

rollback;
