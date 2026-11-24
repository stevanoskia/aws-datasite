-- Schemas, extension and group roles. The roles can't log in: people and services get their
-- own login and become a member of one of them.

create schema shop;  -- the application's tables
create schema ops;   -- housekeeping: size history

create extension if not exists pg_stat_statements;

do $$
declare
  role_name text;
begin
  foreach role_name in array array['app_rw', 'app_ro', 'obs_monitor'] loop
    if not exists (select from pg_roles where rolname = role_name) then
      execute format('create role %I nologin', role_name);
    end if;
  end loop;
end
$$;

-- app_rw: the application (read and write data, no changes to tables)
-- app_ro: people and tools that only read
grant usage on schema shop to app_rw, app_ro;
alter default privileges in schema shop grant select, insert, update, delete on tables to app_rw;
alter default privileges in schema shop grant usage, select on sequences to app_rw;
alter default privileges in schema shop grant select on tables to app_ro;

-- obs_monitor: the monitoring exporter (statistics, no table data)
grant pg_monitor to obs_monitor;
grant usage on schema ops to obs_monitor, app_ro;
alter default privileges in schema ops grant select on tables to obs_monitor, app_ro;
