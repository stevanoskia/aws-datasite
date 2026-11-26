-- The tables change hands: shop_owner (no login) owns them instead of the administrator, and the migration login
-- shop_migrate works as shop_owner. The pipeline can then migrate without the administrator's password.
-- Run once by the administrator; later migrations run as shop_migrate. Creating roles stays with the administrator.

do $$
begin
  if not exists (select from pg_roles where rolname = 'shop_owner') then
    create role shop_owner nologin;
  end if;
  if not exists (select from pg_roles where rolname = 'shop_migrate') then
    create role shop_migrate login connection limit 3; -- no password yet: db/set_app_password.py sets it
  end if;
end
$$;

grant shop_owner to shop_migrate;
alter role shop_migrate set role shop_owner; -- what it creates belongs to shop_owner
grant shop_owner to current_user;            -- needed to hand the objects over

alter schema shop owner to shop_owner;
alter schema ops owner to shop_owner;
alter table public.schema_migrations owner to shop_owner;

do $$
declare
  item record;
begin
  for item in
    select c.oid::regclass as name, case c.relkind when 'v' then 'view' when 'm' then 'materialized view' else 'table' end as kind
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname in ('shop', 'ops') and c.relkind in ('r', 'p', 'v', 'm')
  loop
    execute format('alter %s %s owner to shop_owner', item.kind, item.name); -- sequences and indexes follow their table
  end loop;

  for item in
    select p.oid::regprocedure as name
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('shop', 'ops')
  loop
    execute format('alter routine %s owner to shop_owner', item.name);
  end loop;

  execute format('grant create on database %I to shop_owner', current_database()); -- for extensions such as pg_trgm
end
$$;

-- The same rights on what shop_owner creates later as on what exists (0001 covered only the administrator's objects)
alter default privileges for role shop_owner in schema shop grant select, insert, update, delete on tables to app_rw;
alter default privileges for role shop_owner in schema shop grant usage, select on sequences to app_rw;
alter default privileges for role shop_owner in schema shop grant select on tables to app_ro;
alter default privileges for role shop_owner in schema ops grant select on tables to obs_monitor, app_ro;

-- Before it starts, a version checks that the database has all the migrations it needs
grant select on public.schema_migrations to app_rw, app_ro;
