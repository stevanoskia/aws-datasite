-- The shop's tables. On purpose there are only primary keys and foreign keys: PostgreSQL does not
-- index foreign keys by itself, and every further index is added with a measurement before and after.

create table shop.categories (
  id        integer generated always as identity primary key,
  parent_id integer references shop.categories (id),
  name      text not null
);

create table shop.customers (
  id            bigint generated always as identity primary key,
  email         text not null,
  full_name     text not null,
  country       char(2) not null,
  is_business   boolean not null default false,
  created_at    timestamptz not null default now(),
  last_login_at timestamptz
);

create table shop.products (
  id          bigint generated always as identity primary key,
  category_id integer not null references shop.categories (id),
  sku         text not null,
  name        text not null,
  description text not null default '',
  price       numeric(10, 2) not null check (price >= 0),
  attributes  jsonb not null default '{}',
  is_active   boolean not null default true,
  created_at  timestamptz not null default now()
);

create table shop.inventory (
  product_id bigint primary key references shop.products (id),
  quantity   integer not null check (quantity >= 0),
  updated_at timestamptz not null default now()
);

create table shop.orders (
  id          bigint generated always as identity primary key,
  customer_id bigint not null references shop.customers (id),
  status      text not null check (status in ('pending', 'paid', 'shipped', 'delivered', 'cancelled', 'returned')),
  total       numeric(12, 2) not null check (total >= 0),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create table shop.order_items (
  order_id   bigint not null references shop.orders (id),
  line_no    smallint not null,
  product_id bigint not null references shop.products (id),
  quantity   integer not null check (quantity > 0),
  unit_price numeric(10, 2) not null check (unit_price >= 0),
  primary key (order_id, line_no)
);

create table shop.payments (
  id         bigint generated always as identity primary key,
  order_id   bigint not null references shop.orders (id),
  method     text not null check (method in ('card', 'paypal', 'bank_transfer', 'gift_card')),
  status     text not null check (status in ('authorized', 'captured', 'failed', 'refunded')),
  amount     numeric(12, 2) not null check (amount >= 0),
  created_at timestamptz not null default now()
);

create table shop.reviews (
  id          bigint generated always as identity primary key,
  product_id  bigint not null references shop.products (id),
  customer_id bigint not null references shop.customers (id),
  rating      smallint not null check (rating between 1 and 5),
  title       text not null,
  body        text not null default '',
  created_at  timestamptz not null default now()
);

-- Clickstream: only ever added to, in time order. No foreign keys, so that an insert stays cheap.
create table shop.events (
  id          bigint generated always as identity primary key,
  customer_id bigint,
  product_id  bigint,
  event_type  text not null check (event_type in ('view', 'search', 'add_to_cart', 'checkout', 'login')),
  session_id  uuid not null,
  payload     jsonb not null default '{}',
  created_at  timestamptz not null default now()
);
