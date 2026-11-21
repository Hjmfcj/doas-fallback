-- Demo only. Adds (1) returned lines for the Distribution Manager's Returned Orders page and
-- (2) audit-log entries for the demo submitted orders, so the Back-End Order History page has rows.
-- Names and reasons are placeholders; no real approver or reason is implied. Run once, after demo_orders.sql.
do $$
begin
  if exists (select 1 from public.line_return where demo) then raise exception 'demo returns already loaded'; end if;

  -- Returned lines: order lines of the three demo submitted orders (first line of each customer group below)
  insert into public.line_return (line_id, returned_by_name, returned_by_role, returned_at, reason, demo)
  select l.id, v.by_name, v.by_role, now() - v.ago, v.reason, true
  from (values
    (8, 1, 'Demo Second Line Manager', 'second_line_manager', interval '2 days', 'Demo reason: quantity to be checked again'),
    (8, 2, 'Demo Second Line Manager', 'second_line_manager', interval '2 days', 'Demo reason: quantity to be checked again'),
    (7, 3, 'Demo CFO',                 'cfo',                 interval '1 day',  'Demo reason: customer data to be confirmed')
  ) as v(order_no, file_row, by_name, by_role, ago, reason)
  join public.orders o on o.order_no = v.order_no and o.demo
  join public.order_line l on l.order_id = o.id and l.file_row = v.file_row;

  -- History for demo submitted orders (same shape submit_order writes)
  insert into public.action_log (order_id, file_id, actor, actor_role, action, detail, at)
  select o.id, o.file_id, o.creator, 'distribution_manager', 'submitted', f.uploaded_name, o.arrived_at
  from public.orders o join public.order_file f on f.id = o.file_id
  where o.demo and f.state = 'submitted'
    and not exists (select 1 from public.action_log a where a.order_id = o.id);

  -- History for the returns
  insert into public.action_log (order_id, file_id, actor, actor_role, action, detail, at)
  select o.id, o.file_id, null, r.returned_by_role, 'returned', r.returned_by_name || ': ' || r.reason, r.returned_at
  from public.line_return r join public.order_line l on l.id = r.line_id join public.orders o on o.id = l.order_id
  where r.demo;
end $$;
