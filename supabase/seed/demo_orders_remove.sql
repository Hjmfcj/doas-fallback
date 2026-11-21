-- Removes the demo orders and their check results (rows with demo = true). Also removes demo returned lines and the audit-log entries of demo orders. Does not touch the reference-data demo seed.
-- Run this before demo_remove.sql, which refuses to run while demo customers or products are still used by orders.
do $$
begin
  delete from public.line_issue where file_id in (select id from public.order_file where demo)
     or line_id in (select id from public.order_line where demo);
  delete from public.action_log where order_id in (select id from public.orders where demo);
  delete from public.line_return where demo;
  delete from public.orders where demo;
  delete from public.order_file where demo;
end $$;
