-- Size and usage of every table and index, one set of rows per snapshot, so that growth can be
-- followed over the whole project (monitoring data is kept for a shorter time).

create table ops.size_history (
  taken_at      timestamptz not null default now(),
  kind          text not null check (kind in ('database', 'table', 'index')),
  relation      text not null,
  table_name    text not null,
  bytes         bigint not null,
  row_estimate  bigint,
  dead_rows     bigint,
  seq_scans     bigint,
  index_scans   bigint,
  primary key (taken_at, kind, relation)
);

-- bytes of a table are the table itself with its TOAST data, without its indexes (they have own rows)
create function ops.take_size_snapshot() returns integer
language plpgsql
set search_path = pg_catalog
as $$
declare
  inserted integer;
begin
  insert into ops.size_history (taken_at, kind, relation, table_name, bytes, row_estimate, dead_rows, seq_scans, index_scans)
  select now(), 'database', current_database(), '', pg_database_size(current_database()), null, null, null, null
  union all
  select now(), 'table', t.relname, t.relname, pg_table_size(t.relid), t.n_live_tup, t.n_dead_tup, t.seq_scan, t.idx_scan
  from pg_stat_user_tables t
  where t.schemaname = 'shop'
  union all
  select now(), 'index', i.indexrelname, i.relname, pg_relation_size(i.indexrelid), null, null, null, i.idx_scan
  from pg_stat_user_indexes i
  where i.schemaname = 'shop';

  get diagnostics inserted = row_count;
  return inserted;
end
$$;

revoke all on function ops.take_size_snapshot() from public;
