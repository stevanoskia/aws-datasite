-- One line per table: the same data gives the same lines.
set timezone = 'UTC';
select 'categories ' || md5(string_agg(t::text, '' order by id)) from shop.categories t;
select 'customers ' || md5(string_agg(t::text, '' order by id)) from shop.customers t;
select 'products ' || md5(string_agg(t::text, '' order by id)) from shop.products t;
select 'inventory ' || md5(string_agg(t::text, '' order by product_id)) from shop.inventory t;
select 'orders ' || md5(string_agg(t::text, '' order by id)) from shop.orders t;
select 'order_items ' || md5(string_agg(t::text, '' order by order_id, line_no)) from shop.order_items t;
select 'payments ' || md5(string_agg(t::text, '' order by id)) from shop.payments t;
select 'reviews ' || md5(string_agg(t::text, '' order by id)) from shop.reviews t;
select 'events ' || md5(string_agg(t::text, '' order by id)) from shop.events t;
