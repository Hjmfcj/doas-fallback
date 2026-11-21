-- Removes the demo orders and their check results (rows with demo = true). Does not touch the reference-data demo seed or the audit log.
-- Run this before demo_remove.sql, which refuses to run while demo customers or products are still used by orders.
do $$
begin
  delete from public.line_issue where file_id in (select id from public.order_file where demo)
     or line_id in (select id from public.order_line where demo);
  delete from public.orders where demo;
  delete from public.order_file where demo;
end $$;
