-- 0003 Row-level security (default deny) and submit function. Access only as evidenced in the BRD (G1 section 3).

create function app_private.current_role_name() returns text
language sql stable security definer set search_path = '' as $$
  select role from public.app_user where id = (select auth.uid())
$$;
revoke all on function app_private.current_role_name() from public, anon;
grant usage on schema app_private to authenticated;
grant execute on function app_private.current_role_name() to authenticated;

revoke all on all tables in schema public from anon;

alter table public.customer enable row level security;
alter table public.product enable row level security;
alter table public.cap enable row level security;
alter table public.product_growth enable row level security;
alter table public.guided_value enable row level security;
alter table public.product_map enable row level security;
alter table public.approver enable row level security;
alter table public.special_case enable row level security;
alter table public.blacklist enable row level security;
alter table public.bulk_purchase enable row level security;
alter table public.concern_type enable row level security;
alter table public.holiday enable row level security;
alter table public.stock_sales_out enable row level security;
alter table public.status_value enable row level security;
alter table public.app_user enable row level security;
alter table public.order_file enable row level security;
alter table public.orders enable row level security;
alter table public.order_line enable row level security;
alter table public.line_issue enable row level security;
alter table public.action_log enable row level security;

-- Back-End Monitoring maintains reference data (FR-42).
do $$
declare t text;
begin
  foreach t in array array['customer','product','cap','product_growth','guided_value','product_map','approver','special_case','blacklist','bulk_purchase','concern_type','holiday','stock_sales_out'] loop
    execute format($f$create policy backend_all on public.%I for all to authenticated
      using ((select app_private.current_role_name()) = 'back_end_monitoring')
      with check ((select app_private.current_role_name()) = 'back_end_monitoring')$f$, t);
  end loop;
end $$;

-- Distribution Manager reads customer and product only (FR-02, FR-03). Caps and blacklist are checked inside database functions later, not read by the user.
create policy dm_read on public.customer for select to authenticated using ((select app_private.current_role_name()) = 'distribution_manager');
create policy dm_read on public.product  for select to authenticated using ((select app_private.current_role_name()) = 'distribution_manager');

-- Status list is readable by any signed-in user who has a role.
create policy any_role_read on public.status_value for select to authenticated using ((select app_private.current_role_name()) is not null);

-- Users: see own row; Back-End sees all. Nobody edits users through the API.
create policy own_row on public.app_user for select to authenticated using (id = (select auth.uid()));
create policy backend_read on public.app_user for select to authenticated using ((select app_private.current_role_name()) = 'back_end_monitoring');

-- Order files (FR-45, FR-47): a Distribution Manager works on his or her own files; drafts only are editable or deletable.
create policy dm_select on public.order_file for select to authenticated
  using (uploader = (select auth.uid()) and (select app_private.current_role_name()) = 'distribution_manager');
create policy dm_insert on public.order_file for insert to authenticated
  with check (uploader = (select auth.uid()) and state = 'draft' and (select app_private.current_role_name()) = 'distribution_manager');
create policy dm_update_draft on public.order_file for update to authenticated
  using (uploader = (select auth.uid()) and state = 'draft' and (select app_private.current_role_name()) = 'distribution_manager')
  with check (uploader = (select auth.uid()) and state = 'draft');
create policy dm_delete_draft on public.order_file for delete to authenticated
  using (uploader = (select auth.uid()) and state = 'draft' and (select app_private.current_role_name()) = 'distribution_manager');
create policy backend_read on public.order_file for select to authenticated using ((select app_private.current_role_name()) = 'back_end_monitoring');

-- Orders
create policy dm_select on public.orders for select to authenticated
  using (creator = (select auth.uid()) and (select app_private.current_role_name()) = 'distribution_manager');
create policy dm_insert on public.orders for insert to authenticated
  with check (creator = (select auth.uid()) and arrived_at is null and (select app_private.current_role_name()) = 'distribution_manager');
create policy backend_read on public.orders for select to authenticated using ((select app_private.current_role_name()) = 'back_end_monitoring');

-- Lines and issues: own orders; changes only while the file is a draft
create policy dm_select on public.order_line for select to authenticated
  using (exists (select 1 from public.orders o where o.id = order_id and o.creator = (select auth.uid())) and (select app_private.current_role_name()) = 'distribution_manager');
create policy dm_write_draft on public.order_line for all to authenticated
  using (exists (select 1 from public.orders o join public.order_file f on f.id = o.file_id
                 where o.id = order_id and o.creator = (select auth.uid()) and f.state = 'draft') and (select app_private.current_role_name()) = 'distribution_manager')
  with check (exists (select 1 from public.orders o join public.order_file f on f.id = o.file_id
                 where o.id = order_id and o.creator = (select auth.uid()) and f.state = 'draft') and (select app_private.current_role_name()) = 'distribution_manager');
create policy backend_read on public.order_line for select to authenticated using ((select app_private.current_role_name()) = 'back_end_monitoring');

create policy dm_select on public.line_issue for select to authenticated
  using ((select app_private.current_role_name()) = 'distribution_manager' and (
     exists (select 1 from public.order_file f where f.id = file_id and f.uploader = (select auth.uid()))
     or exists (select 1 from public.order_line l join public.orders o on o.id = l.order_id where l.id = line_id and o.creator = (select auth.uid()))));
create policy dm_write_draft on public.line_issue for all to authenticated
  using ((select app_private.current_role_name()) = 'distribution_manager' and (
     exists (select 1 from public.order_file f where f.id = file_id and f.uploader = (select auth.uid()) and f.state = 'draft')
     or exists (select 1 from public.order_line l join public.orders o on o.id = l.order_id join public.order_file f on f.id = o.file_id
               where l.id = line_id and o.creator = (select auth.uid()) and f.state = 'draft')))
  with check ((select app_private.current_role_name()) = 'distribution_manager' and (
     exists (select 1 from public.order_file f where f.id = file_id and f.uploader = (select auth.uid()) and f.state = 'draft')
     or exists (select 1 from public.order_line l join public.orders o on o.id = l.order_id join public.order_file f on f.id = o.file_id
               where l.id = line_id and o.creator = (select auth.uid()) and f.state = 'draft')));
create policy backend_read on public.line_issue for select to authenticated using ((select app_private.current_role_name()) = 'back_end_monitoring');

-- Audit log: Back-End reads (order history users per BRD section 14: Back-End, approvers; approvers added with their slice). No insert policy: rows are written by functions.
create policy backend_read on public.action_log for select to authenticated using ((select app_private.current_role_name()) = 'back_end_monitoring');
revoke update, delete, truncate on public.action_log from anon, authenticated;

-- Submit (FR-43, FR-46): only the owner, only a draft, only a file with no blocking issue. Starts the 48-hour clock.
create function public.submit_order(p_order_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare v_order public.orders; v_file public.order_file; v_role text;
begin
  select * into v_order from public.orders where id = p_order_id;
  if not found or v_order.creator <> (select auth.uid()) then raise exception 'order not found'; end if;
  select app_private.current_role_name() into v_role;
  if v_role <> 'distribution_manager' then raise exception 'not allowed'; end if;
  select * into v_file from public.order_file where id = v_order.file_id for update;
  if v_file.state <> 'draft' then raise exception 'order already submitted'; end if;
  if v_file.check_result is distinct from 'Valid'
     or exists (select 1 from public.line_issue i where i.severity = 'error'
                and (i.file_id = v_file.id or i.line_id in (select id from public.order_line where order_id = p_order_id))) then
    raise exception 'This file can''t be submitted';
  end if;
  update public.order_file set state = 'submitted' where id = v_file.id;
  update public.orders set arrived_at = now() where id = p_order_id;
  insert into public.action_log (order_id, file_id, actor, actor_role, action, detail)
    values (p_order_id, v_file.id, (select auth.uid()), v_role, 'submitted', v_file.uploaded_name);
end $$;
revoke all on function public.submit_order(uuid) from public, anon;
grant execute on function public.submit_order(uuid) to authenticated;
