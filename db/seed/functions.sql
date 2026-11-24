-- The data generator. It runs inside the database, so nothing is uploaded.
--
-- Repeatable: every value comes from a hash of the row's number and the seed, never from random(),
-- so the same seed gives the same data, in whatever order the batches run.
-- Resumable:  every batch is one transaction together with its entry in gen.progress.

create schema if not exists gen;

create table if not exists gen.settings (
  only_row   boolean primary key default true check (only_row),
  size       text not null,
  seed       bigint not null,
  starts_at  timestamptz not null,
  ends_at    timestamptz not null,
  categories integer not null,
  customers  bigint not null,
  products   bigint not null,
  orders     bigint not null,
  reviews    bigint not null,
  events     bigint not null,
  batch_rows integer not null
);

create table if not exists gen.progress (
  step        text not null,
  batch       integer not null,
  loaded      bigint not null,
  seconds     numeric(10, 1) not null,
  finished_at timestamptz not null default clock_timestamp(),
  primary key (step, batch)
);

-- A repeatable "random" number, 0 <= r < 1. The salt keeps different columns independent.
create or replace function gen.r(seed bigint, salt integer, id bigint) returns double precision
language sql immutable parallel safe as $$
  select ((hashint8extended(id, seed * 1000003 + salt) >> 11) & 9007199254740991)::double precision / 9007199254740992.0
$$;

-- Five customers ("whales") get 10% of everything; the others share the rest unevenly
create or replace function gen.pick_customer(seed bigint, salt integer, id bigint, customers bigint) returns bigint
language sql immutable parallel safe as $$
  select case
    when gen.r(seed, salt, id) < 0.10 then 1 + floor(5 * gen.r(seed, salt + 1, id))::bigint
    else 6 + floor((customers - 5) * power(gen.r(seed, salt + 2, id), 1.5))::bigint
  end
$$;

-- A few products are very popular, most are not
create or replace function gen.pick_product(seed bigint, salt integer, id bigint, products bigint) returns bigint
language sql immutable parallel safe as $$
  select 1 + floor(products * power(gen.r(seed, salt, id), 3))::bigint
$$;

create or replace function gen.price(seed bigint, product_id bigint) returns numeric
language sql immutable parallel safe as $$
  select round((5 + 495 * power(gen.r(seed, 11, product_id), 2))::numeric, 2)
$$;

-- Row numbers spread over the whole period, denser towards the end (a growing shop)
create or replace function gen.moment(starts_at timestamptz, ends_at timestamptz, id bigint, total bigint) returns timestamptz
language sql immutable parallel safe as $$
  select starts_at + (ends_at - starts_at) * power(id::double precision / total, 0.8)
$$;

create or replace function gen.init(wanted text) returns text
language plpgsql as $$
declare
  existing text;
begin
  select size into existing from gen.settings;
  if existing = wanted then
    return 'continuing with size ' || wanted;
  elsif existing is not null then
    raise exception 'the database already holds size %; run db/seed/reset.sql first', existing;
  elsif exists (select from shop.categories) or exists (select from shop.customers) or exists (select from shop.events) then
    raise exception 'the shop already holds data that the generator did not create';
  end if;

  if wanted = 'small' then
    insert into gen.settings values (true, 'small', 20261124, '2024-11-01 00:00+00', '2026-11-01 00:00+00', 200, 500, 100, 5000, 1000, 15000, 500);
  elsif wanted = 'full' then
    insert into gen.settings values (true, 'full', 20261124, '2024-11-01 00:00+00', '2026-11-01 00:00+00', 200, 500000, 100000, 5000000, 1000000, 15000000, 50000);
  else
    raise exception 'unknown size %, use small or full', wanted;
  end if;
  return 'starting with size ' || wanted;
end
$$;

-- -----------------------------------------------------------------------------
-- Categories, customers, products, inventory
-- -----------------------------------------------------------------------------

create or replace procedure gen.load_dimensions()
language plpgsql as $$
declare
  s       gen.settings;
  started timestamptz := clock_timestamp();
begin
  if exists (select from gen.progress where step = 'dimensions') then
    return;
  end if;
  select * into strict s from gen.settings;

  -- 10 main categories, the others below them
  insert into shop.categories (id, parent_id, name) overriding system value
  select id, case when id > 10 then 1 + (id % 10) end, case when id > 10 then 'Category ' || id else 'Department ' || id end
  from generate_series(1, s.categories) id;

  insert into shop.customers (id, email, full_name, country, is_business, created_at, last_login_at) overriding system value
  select
    id,
    -- one in ten is written with capitals: the case-insensitive lookup must still find it
    case when gen.r(s.seed, 1, id) < 0.10 then initcap('user' || id) else 'user' || id end
      || (array['@example.com', '@example.com', '@example.com', '@example.org', '@example.net'])[1 + floor(5 * gen.r(s.seed, 2, id))::integer],
    (array['Ann', 'Ben', 'Cleo', 'Dan', 'Eva', 'Finn', 'Gia', 'Hugo', 'Ida', 'Jon', 'Kim', 'Leo', 'Mia', 'Nils', 'Ole', 'Pia'])[1 + floor(16 * gen.r(s.seed, 3, id))::integer]
      || ' ' || (array['Adams', 'Berg', 'Costa', 'Dahl', 'Evans', 'Fischer', 'Garcia', 'Horn', 'Ivanov', 'Jensen', 'Kovac', 'Lund', 'Moreau', 'Novak', 'Olsen', 'Petrov'])[1 + floor(16 * gen.r(s.seed, 4, id))::integer],
    (array['DE', 'DE', 'DE', 'DE', 'FR', 'FR', 'SE', 'SE', 'PL', 'NL', 'IT', 'ES', 'DK', 'NO', 'FI', 'AT'])[1 + floor(16 * gen.r(s.seed, 5, id))::integer],
    id <= 5 or gen.r(s.seed, 6, id) < 0.03,
    s.starts_at - interval '1 day' * (1000 * gen.r(s.seed, 7, id)), -- everyone registered before the first order
    case when gen.r(s.seed, 8, id) >= 0.20 then s.ends_at - interval '1 day' * (400 * power(gen.r(s.seed, 9, id), 2)) end
  from generate_series(1, s.customers) id;

  insert into shop.products (id, category_id, sku, name, description, price, attributes, is_active, created_at) overriding system value
  select
    id,
    11 + floor((s.categories - 10) * gen.r(s.seed, 10, id))::integer,
    'SKU-' || lpad(id::text, 7, '0'),
    (array['Classic', 'Modern', 'Compact', 'Deluxe', 'Eco', 'Fine', 'Grand', 'Handy', 'Light', 'Mini', 'Nordic', 'Prime', 'Quiet', 'Rapid', 'Smart', 'Urban'])[1 + floor(16 * gen.r(s.seed, 12, id))::integer]
      || ' ' || (array['Backpack', 'Blender', 'Bottle', 'Chair', 'Clock', 'Desk', 'Drill', 'Headphones', 'Jacket', 'Kettle', 'Keyboard', 'Lamp', 'Mirror', 'Monitor', 'Mug', 'Notebook', 'Pan', 'Pillow', 'Printer', 'Rug', 'Scale', 'Shelf', 'Speaker', 'Tent'])[1 + floor(24 * gen.r(s.seed, 13, id))::integer]
      || ' ' || id,
    'Product number ' || id || '. ' || repeat(md5(id::text) || ' ', 1 + floor(4 * gen.r(s.seed, 14, id))::integer),
    gen.price(s.seed, id),
    jsonb_build_object(
      'color', (array['black', 'black', 'black', 'black', 'white', 'white', 'grey', 'blue', 'red', 'teal'])[1 + floor(10 * gen.r(s.seed, 15, id))::integer],
      'size', (array['S', 'M', 'L', 'XL'])[1 + floor(4 * gen.r(s.seed, 16, id))::integer],
      'weight_g', 50 + floor(5000 * gen.r(s.seed, 17, id))::integer),
    gen.r(s.seed, 18, id) < 0.95,
    s.starts_at - interval '1 day' * (500 * gen.r(s.seed, 19, id))
  from generate_series(1, s.products) id;

  insert into shop.inventory (product_id, quantity, updated_at)
  select id, case when gen.r(s.seed, 41, id) < 0.02 then 0 else 1 + floor(1000 * gen.r(s.seed, 42, id))::integer end, s.ends_at
  from generate_series(1, s.products) id;

  insert into gen.progress (step, batch, loaded, seconds)
  values ('dimensions', 1, s.categories + s.customers + 2 * s.products, extract(epoch from clock_timestamp() - started));
  commit;
  raise notice 'dimensions done';
end
$$;

-- -----------------------------------------------------------------------------
-- Orders with their lines and payments, oldest first
-- -----------------------------------------------------------------------------

create or replace procedure gen.load_orders(max_batches integer default null)
language plpgsql as $$
declare
  s       gen.settings;
  batches integer;
  lo      bigint;
  hi      bigint;
  n       bigint;
  started timestamptz;
begin
  select * into strict s from gen.settings;
  batches := ceil(s.orders::numeric / s.batch_rows);

  for b in 1 .. least(batches, coalesce(max_batches, batches)) loop
    continue when exists (select from gen.progress p where p.step = 'orders' and p.batch = b);
    started := clock_timestamp();
    lo := (b - 1)::bigint * s.batch_rows + 1;
    hi := least(b::bigint * s.batch_rows, s.orders);

    with lines as materialized (
      select
        o.id as order_id,
        l.line_no,
        gen.pick_product(s.seed, 21, o.id * 8 + l.line_no, s.products) as product_id,
        1 + floor(3 * power(gen.r(s.seed, 22, o.id * 8 + l.line_no), 2))::integer as quantity
      from generate_series(lo, hi) as o (id)
      cross join lateral generate_series(1, 1 + floor(5 * gen.r(s.seed, 20, o.id))::integer) as l (line_no)
    ),
    priced as materialized (
      select order_id, line_no, product_id, quantity, gen.price(s.seed, product_id) as unit_price
      from lines
    ),
    new_orders as (
      insert into shop.orders (id, customer_id, status, total, created_at, updated_at) overriding system value
      select
        t.order_id,
        gen.pick_customer(s.seed, 23, t.order_id, s.customers),
        case
          -- only the newest orders are still open: 0.1% of all are pending
          when t.order_id > s.orders * 0.95 and gen.r(s.seed, 26, t.order_id) < 0.02 then 'pending'
          when t.order_id > s.orders * 0.95 and gen.r(s.seed, 26, t.order_id) < 0.06 then 'paid'
          when t.order_id > s.orders * 0.95 and gen.r(s.seed, 26, t.order_id) < 0.12 then 'shipped'
          when gen.r(s.seed, 27, t.order_id) < 0.010 then 'cancelled'
          when gen.r(s.seed, 27, t.order_id) < 0.014 then 'returned'
          else 'delivered'
        end,
        t.total,
        gen.moment(s.starts_at, s.ends_at, t.order_id, s.orders),
        gen.moment(s.starts_at, s.ends_at, t.order_id, s.orders) + interval '1 hour' * (72 * gen.r(s.seed, 28, t.order_id))
      from (select order_id, sum(quantity * unit_price) as total from priced group by order_id) t
      order by t.order_id
      returning id, status, total, created_at
    ),
    new_items as (
      insert into shop.order_items (order_id, line_no, product_id, quantity, unit_price)
      select order_id, line_no, product_id, quantity, unit_price
      from priced
      order by order_id, line_no
    )
    insert into shop.payments (id, order_id, method, status, amount, created_at) overriding system value
    select
      o.id,
      o.id,
      (array['card', 'card', 'card', 'card', 'card', 'card', 'card', 'paypal', 'paypal', 'bank_transfer', 'gift_card'])[1 + floor(11 * gen.r(s.seed, 29, o.id))::integer],
      case o.status when 'pending' then 'authorized' when 'cancelled' then 'failed' when 'returned' then 'refunded' else 'captured' end,
      o.total,
      o.created_at + interval '1 minute' * (30 * gen.r(s.seed, 30, o.id))
    from new_orders o
    order by o.id;

    get diagnostics n = row_count;
    insert into gen.progress (step, batch, loaded, seconds) values ('orders', b, n, extract(epoch from clock_timestamp() - started));
    commit;
    raise notice 'orders %/%  % s', b, batches, round(extract(epoch from clock_timestamp() - started), 1);
  end loop;
end
$$;

-- -----------------------------------------------------------------------------
-- Reviews and events, oldest first
-- -----------------------------------------------------------------------------

create or replace procedure gen.load_reviews(max_batches integer default null)
language plpgsql as $$
declare
  s       gen.settings;
  batches integer;
  n       bigint;
  started timestamptz;
begin
  select * into strict s from gen.settings;
  batches := ceil(s.reviews::numeric / s.batch_rows);

  for b in 1 .. least(batches, coalesce(max_batches, batches)) loop
    continue when exists (select from gen.progress p where p.step = 'reviews' and p.batch = b);
    started := clock_timestamp();

    insert into shop.reviews (id, product_id, customer_id, rating, title, body, created_at) overriding system value
    select
      id,
      gen.pick_product(s.seed, 50, id, s.products),
      gen.pick_customer(s.seed, 51, id, s.customers),
      case -- most people are happy, some are angry, few are in between
        when gen.r(s.seed, 54, id) < 0.55 then 5
        when gen.r(s.seed, 54, id) < 0.75 then 4
        when gen.r(s.seed, 54, id) < 0.83 then 3
        when gen.r(s.seed, 54, id) < 0.88 then 2
        else 1
      end,
      (array['Great', 'Good value', 'As described', 'Not for me', 'Would buy again', 'Arrived late'])[1 + floor(6 * gen.r(s.seed, 55, id))::integer],
      repeat('Some words about this product. ', floor(8 * power(gen.r(s.seed, 56, id), 2))::integer),
      gen.moment(s.starts_at, s.ends_at, id, s.reviews)
    from generate_series((b - 1)::bigint * s.batch_rows + 1, least(b::bigint * s.batch_rows, s.reviews)) id;

    get diagnostics n = row_count;
    insert into gen.progress (step, batch, loaded, seconds) values ('reviews', b, n, extract(epoch from clock_timestamp() - started));
    commit;
    raise notice 'reviews %/%  % s', b, batches, round(extract(epoch from clock_timestamp() - started), 1);
  end loop;
end
$$;

create or replace procedure gen.load_events(max_batches integer default null)
language plpgsql as $$
declare
  s       gen.settings;
  batches integer;
  n       bigint;
  started timestamptz;
begin
  select * into strict s from gen.settings;
  batches := ceil(s.events::numeric / s.batch_rows);

  for b in 1 .. least(batches, coalesce(max_batches, batches)) loop
    continue when exists (select from gen.progress p where p.step = 'events' and p.batch = b);
    started := clock_timestamp();

    insert into shop.events (id, customer_id, product_id, event_type, session_id, payload, created_at) overriding system value
    select
      e.id,
      case when gen.r(s.seed, 61, e.id / 8) >= 0.30 then gen.pick_customer(s.seed, 62, e.id / 8, s.customers) end, -- 30% of the sessions are anonymous
      case when e.event_type in ('view', 'add_to_cart') then gen.pick_product(s.seed, 65, e.id, s.products) end,
      e.event_type,
      md5(s.seed || ':' || e.id / 8)::uuid, -- a session is 8 events long
      case e.event_type
        when 'view' then jsonb_build_object('ref', (array['home', 'search', 'ad', 'mail'])[1 + floor(4 * gen.r(s.seed, 66, e.id))::integer])
        when 'search' then jsonb_build_object('q', (array['lamp', 'desk', 'mug', 'tent', 'chair', 'kettle'])[1 + floor(6 * gen.r(s.seed, 67, e.id))::integer])
        else '{}'
      end,
      gen.moment(s.starts_at, s.ends_at, e.id, s.events)
    from (
      select
        id,
        case
          when gen.r(s.seed, 60, id) < 0.80 then 'view'
          when gen.r(s.seed, 60, id) < 0.88 then 'search'
          when gen.r(s.seed, 60, id) < 0.95 then 'add_to_cart'
          when gen.r(s.seed, 60, id) < 0.97 then 'checkout'
          else 'login'
        end as event_type
      from generate_series((b - 1)::bigint * s.batch_rows + 1, least(b::bigint * s.batch_rows, s.events)) id
    ) e
    order by e.id;

    get diagnostics n = row_count;
    insert into gen.progress (step, batch, loaded, seconds) values ('events', b, n, extract(epoch from clock_timestamp() - started));
    commit;
    raise notice 'events %/%  % s', b, batches, round(extract(epoch from clock_timestamp() - started), 1);
  end loop;
end
$$;

-- -----------------------------------------------------------------------------
-- Report and finish
-- -----------------------------------------------------------------------------

-- What is loaded, how long a batch takes, and what that means for the rest
create or replace function gen.report()
returns table (step text, batches_done bigint, batches_total bigint, seconds_per_batch numeric, minutes_left numeric)
language sql stable as $$
  select t.step, count(p.batch), t.total, round(avg(p.seconds), 1), round((t.total - count(p.batch)) * avg(p.seconds) / 60, 1)
  from gen.settings s
  cross join lateral (values
    ('dimensions', 1::bigint),
    ('orders', ceil(s.orders::numeric / s.batch_rows)::bigint),
    ('reviews', ceil(s.reviews::numeric / s.batch_rows)::bigint),
    ('events', ceil(s.events::numeric / s.batch_rows)::bigint)
  ) as t (step, total)
  left join gen.progress p on p.step = t.step
  group by t.step, t.total
  order by min(array_position(array['dimensions', 'orders', 'reviews', 'events'], t.step))
$$;

create or replace function gen.is_complete() returns boolean
language sql stable as $$
  select coalesce(bool_and(batches_done = batches_total), false) from gen.report()
$$;

-- After the last batch: new rows continue after the generated ones, stored views, first size snapshot
create or replace function gen.finish() returns text
language plpgsql as $$
begin
  if not gen.is_complete() then
    raise exception 'not everything is loaded yet';
  end if;
  perform setval(pg_get_serial_sequence('shop.categories', 'id'), (select max(id) from shop.categories));
  perform setval(pg_get_serial_sequence('shop.customers', 'id'), (select max(id) from shop.customers));
  perform setval(pg_get_serial_sequence('shop.products', 'id'), (select max(id) from shop.products));
  perform setval(pg_get_serial_sequence('shop.orders', 'id'), (select max(id) from shop.orders));
  perform setval(pg_get_serial_sequence('shop.payments', 'id'), (select max(id) from shop.payments));
  perform setval(pg_get_serial_sequence('shop.reviews', 'id'), (select max(id) from shop.reviews));
  perform setval(pg_get_serial_sequence('shop.events', 'id'), (select max(id) from shop.events));
  refresh materialized view shop.mv_daily_sales;
  refresh materialized view shop.mv_product_rating;
  return 'finished';
end
$$;
