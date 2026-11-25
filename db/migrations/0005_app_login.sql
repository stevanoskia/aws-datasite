-- The application's own login. It has no password here, so nobody can use it until
-- db/set_app_password.py sets one. The connection limit keeps some connections free for people.

do $$
begin
  if not exists (select from pg_roles where rolname = 'shop_app') then
    create role shop_app login connection limit 60;
  end if;
end
$$;

grant app_rw to shop_app;
