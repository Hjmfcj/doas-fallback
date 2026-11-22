-- Lines the signed-in approver can decide right now (the screen shows decision controls only for these; ap_decide still checks every decision itself).
create or replace function public.ap_actionable_lines(p_order_id uuid default null) returns table(order_id uuid, line_id uuid, stage text)
language sql stable security definer set search_path = '' as $$
  select l.order_id, l.id, app_private.next_stage(l)
    from public.order_line l
   where (p_order_id is null or l.order_id = p_order_id)
     and l.status = 'In approval'
     and app_private.approver_sees(l.order_id)
     and not exists (select 1 from public.line_return r where r.line_id = l.id and r.resolved_at is null)
     and app_private.next_stage(l) is not null
     and app_private.can_act_on_stage(l.order_id, app_private.next_stage(l), l.product_id) $$;
revoke all on function public.ap_actionable_lines(uuid) from public, anon;
grant execute on function public.ap_actionable_lines(uuid) to authenticated;
