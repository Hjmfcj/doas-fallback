-- Removes the demo seed and nothing else (rows with demo = true, reference tables only, children before parents).
-- Stops with an error, and removes nothing, if demo rows are still referenced by orders, so a half-removed state cannot happen.
-- The audit log is insert-only and is never touched.
do $$
declare n int;
begin
  delete from public.stock_sales_out where demo;
  delete from public.bulk_purchase  where demo;
  delete from public.special_case   where demo;
  delete from public.blacklist      where demo;
  delete from public.product_map    where demo;
  delete from public.cap            where demo;
  delete from public.product_growth where demo;
  delete from public.approver       where demo;
  delete from public.guided_value   where demo;
  delete from public.concern_type   where demo;
  delete from public.holiday        where demo;
  delete from public.customer       where demo;
  delete from public.product        where demo;
  select (select count(*) from public.customer where demo) + (select count(*) from public.product where demo)
       + (select count(*) from public.cap where demo) + (select count(*) from public.blacklist where demo) into n;
  if n <> 0 then raise exception 'Demo rows remain: %', n; end if;
end $$;
