-- Approval engine (22-Nov-2026). Sources: BRD v1.3 Section 8.3, 8.4, FR-09 to FR-31, FR-55; AZ Order Approval playbook (Uranium, June 2026) slides 5, 9 to 15;
-- SOP "Demand orders approval cycle" (January 2026) slides 7 to 10, 13.
-- Design:
--  * Back-End records the routing inputs (the playbook says Back-End "provides routing inputs to the system"); the system then proposes the route from the documented rules.
--  * Back-End can edit the route afterwards. Once Back-End has edited it, the system stops proposing for that order (route_locked), so the two never fight.
--  * Progress is kept per line: each line has its own list of stages (required_stages) and its own decisions. A returned line restarts from the first stage when resubmitted; other lines are not disturbed.
--  * One owner at a time per line: Distribution Manager (draft or returned), the approver at the line's current stage, or nobody (approved, rejected, cleared).
--  * Anything the sources do not settle is NOT decided here: the order stays "needs inputs" and Back-End sets the route.

-- ---------------------------------------------------------------- helpers
create or replace function app_private.canon_seq(p_stage text) returns int language sql immutable set search_path = '' as $$
  select case p_stage when 'second_line_manager' then 1 when 'business_unit_director' then 2 when 'cfo' then 3 when 'cp' then 4 end $$;

create or replace function app_private.sort_stages(p_stages text[]) returns text[] language sql immutable set search_path = '' as $$
  select coalesce(array_agg(s order by app_private.canon_seq(s)), '{}') from (select distinct unnest(p_stages) s) x $$;

-- Working time between two instants: Friday and Saturday and the holidays table are left out (Shehab 22-Nov-2026).
-- Day boundaries use Africa/Cairo (TIME ZONE NOT STATED IN THE SOURCES: to confirm).
create or replace function app_private.working_hours(p_from timestamptz, p_to timestamptz) returns numeric
language sql stable security definer set search_path = '' as $$
  select coalesce(sum(greatest(0, extract(epoch from (
      least(p_to, ((d.day + 1)::timestamp at time zone 'Africa/Cairo'))
    - greatest(p_from, (d.day::timestamp at time zone 'Africa/Cairo')))) / 3600.0)), 0)
  from (select g::date as day from generate_series((p_from at time zone 'Africa/Cairo')::date, (p_to at time zone 'Africa/Cairo')::date, interval '1 day') g) d
  where extract(dow from d.day) not in (5, 6)
    and not exists (select 1 from public.holiday h where h.holiday_date = d.day) $$;
grant execute on function app_private.working_hours(timestamptz, timestamptz) to authenticated;

-- ---------------------------------------------------------------- schema
alter table public.order_stage
  add column if not exists seq int,
  add column if not exists source text not null default 'system',
  add column if not exists reassigned boolean not null default false,
  add column if not exists reason text;
update public.order_stage set seq = app_private.canon_seq(stage) where seq is null;
alter table public.order_stage alter column seq set not null;
alter table public.order_stage drop constraint if exists order_stage_source_chk;
alter table public.order_stage add constraint order_stage_source_chk check (source in ('system', 'back_end'));

alter table public.orders
  add column if not exists route_state text not null default 'not_routed',
  add column if not exists route_note text,
  add column if not exists route_locked boolean not null default false,
  add column if not exists concern_type text,
  add column if not exists concern_note text,
  add column if not exists completed_at timestamptz;
alter table public.orders drop constraint if exists orders_route_state_chk;
alter table public.orders add constraint orders_route_state_chk check (route_state in ('not_routed', 'no_approval', 'needs_inputs', 'in_approval', 'completed'));

alter table public.order_line
  add column if not exists gv_position_pct numeric,
  add column if not exists over_allowed_growth boolean,
  add column if not exists growth_pct numeric,
  add column if not exists doh_with_order numeric,
  add column if not exists seek_full_quantity boolean not null default false,
  add column if not exists capped_quantity numeric,
  add column if not exists calculated_quantity numeric,
  add column if not exists required_stages text[] not null default '{}',
  add column if not exists approved_quantity numeric,
  add column if not exists postponed_quantity numeric;
alter table public.order_line drop constraint if exists order_line_status_chk;
alter table public.order_line add constraint order_line_status_chk check (status is null or status in ('Awaiting Back-End inputs', 'Cleared', 'In approval', 'Approved', 'Rejected', 'Returned'));

create table if not exists public.line_decision (
  id uuid primary key default gen_random_uuid(),
  line_id uuid not null references public.order_line(id) on delete cascade,
  stage text not null check (stage in ('second_line_manager', 'business_unit_director', 'cfo', 'cp')),
  decision text not null check (decision in ('approved', 'rejected')),
  quantity numeric,
  rationale text,
  decided_by uuid,
  decided_name text,
  decided_at timestamptz not null default now(),
  superseded boolean not null default false,
  demo boolean not null default false
);
create index if not exists line_decision_line_idx on public.line_decision(line_id);
alter table public.line_decision enable row level security;

create table if not exists public.notification (
  id uuid primary key default gen_random_uuid(),
  order_id uuid references public.orders(id) on delete cascade,
  to_user uuid,
  to_email text,
  to_role text,
  kind text not null,
  message text not null,
  created_at timestamptz not null default now(),
  read_at timestamptz,
  demo boolean not null default false
);
create index if not exists notification_order_idx on public.notification(order_id);
alter table public.notification enable row level security;

-- ---------------------------------------------------------------- read access (default deny; select only)
create or replace function app_private.approver_sees(p_order_id uuid) returns boolean
language plpgsql stable security definer set search_path = '' as $$
declare v_role text := app_private.current_role_name(); v_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
begin
  if v_role is null or v_role not in ('second_line_manager', 'business_unit_director', 'cfo', 'cp') then return false; end if;
  return exists (select 1 from public.orders o where o.id = p_order_id and o.arrived_at is not null) and (
    exists (select 1 from public.order_stage s where s.order_id = p_order_id
            and ((s.assigned_email is not null and lower(s.assigned_email) = v_email) or (s.assigned_email is null and s.stage = v_role)))
    or exists (select 1 from public.order_line l join public.product_map m on m.product_id = l.product_id
               where l.order_id = p_order_id and lower(m.second_line_manager_email) = v_email and 'second_line_manager' = any (l.required_stages)));
end $$;

create or replace function app_private.is_approver() returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce(app_private.current_role_name() in ('second_line_manager', 'business_unit_director', 'cfo', 'cp'), false) $$;

drop policy if exists approver_read on public.orders;
create policy approver_read on public.orders for select to authenticated using (app_private.approver_sees(id));
drop policy if exists approver_read on public.order_line;
create policy approver_read on public.order_line for select to authenticated using (app_private.approver_sees(order_id));
drop policy if exists approver_read on public.order_stage;
create policy approver_read on public.order_stage for select to authenticated using (app_private.approver_sees(order_id));
drop policy if exists approver_read on public.order_comment;
create policy approver_read on public.order_comment for select to authenticated using (app_private.approver_sees(order_id));
drop policy if exists approver_read on public.order_file;
create policy approver_read on public.order_file for select to authenticated using (exists (select 1 from public.orders o where o.file_id = order_file.id and app_private.approver_sees(o.id)));
drop policy if exists approver_read on public.line_return;
create policy approver_read on public.line_return for select to authenticated using (exists (select 1 from public.order_line l where l.id = line_return.line_id and app_private.approver_sees(l.order_id)));
drop policy if exists approver_read on public.customer;
create policy approver_read on public.customer for select to authenticated using (app_private.is_approver());
drop policy if exists approver_read on public.product;
create policy approver_read on public.product for select to authenticated using (app_private.is_approver());

drop policy if exists backend_read on public.line_decision;
create policy backend_read on public.line_decision for select to authenticated using ((select app_private.current_role_name()) = 'back_end_monitoring');
drop policy if exists approver_read on public.line_decision;
create policy approver_read on public.line_decision for select to authenticated using (exists (select 1 from public.order_line l where l.id = line_decision.line_id and app_private.approver_sees(l.order_id)));
drop policy if exists dm_read on public.line_decision;
create policy dm_read on public.line_decision for select to authenticated using (
  (select app_private.current_role_name()) = 'distribution_manager'
  and exists (select 1 from public.order_line l join public.orders o on o.id = l.order_id where l.id = line_decision.line_id and o.creator = (select auth.uid())));

drop policy if exists own_read on public.notification;
create policy own_read on public.notification for select to authenticated using (
  to_user = (select auth.uid())
  or (to_email is not null and lower(to_email) = lower(coalesce((select auth.jwt() ->> 'email'), '')))
  or (to_user is null and to_email is null and to_role = (select app_private.current_role_name())));

create or replace function public.mark_notifications_read() returns void
language plpgsql security definer set search_path = '' as $$
begin
  update public.notification set read_at = now()
   where read_at is null and (
     to_user = (select auth.uid())
     or (to_email is not null and lower(to_email) = lower(coalesce((select auth.jwt() ->> 'email'), '')))
     or (to_user is null and to_email is null and to_role = app_private.current_role_name()));
end $$;
revoke all on function public.mark_notifications_read() from public, anon;
grant execute on function public.mark_notifications_read() to authenticated;

create or replace view public.order_ageing with (security_invoker = true) as
select o.id as order_id,
  case when o.arrived_at is null then null else round(app_private.working_hours(o.arrived_at, coalesce(o.completed_at, now())), 1) end as working_hours,
  case when o.arrived_at is null or o.completed_at is not null or o.route_state in ('no_approval', 'not_routed') then null
       when app_private.working_hours(o.arrived_at, now()) >= 72 then 'red'
       when app_private.working_hours(o.arrived_at, now()) >= 24 then 'orange' end as level,
  (o.arrived_at is not null and o.completed_at is null and o.route_state not in ('no_approval', 'not_routed')
   and app_private.working_hours(o.arrived_at, now()) >= 48) as overdue
from public.orders o;
grant select on public.order_ageing to authenticated;

-- ---------------------------------------------------------------- internal building blocks
create or replace function app_private.log_action(p_order uuid, p_action text, p_detail text, p_stage text default null, p_qty numeric default null, p_system boolean default false) returns void
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.action_log (order_id, file_id, actor, actor_role, stage, action, detail, quantity)
  select o.id, o.file_id, case when p_system then null else auth.uid() end, case when p_system then null else app_private.current_role_name() end, p_stage, p_action, p_detail, p_qty
  from public.orders o where o.id = p_order;
end $$;

create or replace function app_private.notify(p_order uuid, p_kind text, p_msg text, p_user uuid, p_email text, p_role text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if exists (select 1 from public.notification n where n.order_id = p_order and n.kind = p_kind and n.message = p_msg and n.read_at is null
             and n.to_user is not distinct from p_user and n.to_email is not distinct from p_email and n.to_role is not distinct from p_role) then return; end if;
  insert into public.notification (order_id, kind, message, to_user, to_email, to_role) values (p_order, p_kind, p_msg, p_user, nullif(trim(p_email), ''), p_role);
end $$;

create or replace function app_private.notify_stage(p_order uuid, p_stage text) returns void
language plpgsql security definer set search_path = '' as $$
declare s public.order_stage; v_no bigint;
begin
  select * into s from public.order_stage where order_id = p_order and stage = p_stage;
  if not found then return; end if;
  select order_no into v_no from public.orders where id = p_order;
  perform app_private.notify(p_order, 'stage_reached', 'Order ' || v_no || ' is waiting for your decision.', null, s.assigned_email, p_stage);
end $$;

create or replace function app_private.next_stage(p_line public.order_line) returns text
language sql stable security definer set search_path = '' as $$
  select t.s from unnest(p_line.required_stages) with ordinality as t(s, n)
  where not exists (select 1 from public.line_decision d where d.line_id = p_line.id and d.stage = t.s and d.decision = 'approved' and not d.superseded)
  order by t.n limit 1 $$;

create or replace function app_private.can_act_on_stage(p_order_id uuid, p_stage text, p_product_id uuid) returns boolean
language plpgsql stable security definer set search_path = '' as $$
declare v_role text := app_private.current_role_name(); v_email text := lower(coalesce(auth.jwt() ->> 'email', '')); s public.order_stage; v_owner text;
begin
  if v_role is null or v_role not in ('second_line_manager', 'business_unit_director', 'cfo', 'cp') then return false; end if;
  select * into s from public.order_stage where order_id = p_order_id and stage = p_stage;
  if not found then return false; end if;
  if s.assigned_email is not null and lower(s.assigned_email) = v_email then return true; end if;
  if s.reassigned then return false; end if;
  if p_stage = 'second_line_manager' and v_role = 'second_line_manager' then
    select lower(m.second_line_manager_email) into v_owner from public.product_map m where m.product_id = p_product_id;
    if v_owner is not null and v_owner = v_email then return true; end if;
  end if;
  if s.assigned_email is null and v_role = p_stage then return true; end if;
  return false;
end $$;

-- A line that has no stage left is approved at the last quantity decided (or the requested quantity less any postponed part).
create or replace function app_private.advance_line(p_line_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare l public.order_line; nxt text; lastq numeric;
begin
  select * into l from public.order_line where id = p_line_id for update;
  if not found or l.status is distinct from 'In approval' then return; end if;
  nxt := app_private.next_stage(l);
  if nxt is null then
    select d.quantity into lastq from public.line_decision d where d.line_id = l.id and d.decision = 'approved' and not d.superseded order by d.decided_at desc limit 1;
    update public.order_line set status = 'Approved', approved_quantity = coalesce(lastq, l.requested_quantity - coalesce(l.postponed_quantity, 0)) where id = l.id;
  else
    perform app_private.notify_stage(l.order_id, nxt);
  end if;
end $$;

-- When every line is final the order is complete: the creator is told the final approved quantity per product (FR-31).
create or replace function app_private.complete_check(p_order_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare o public.orders; v_msg text;
begin
  select * into o from public.orders where id = p_order_id for update;
  if not found or o.route_state <> 'in_approval' then return; end if;
  if exists (select 1 from public.order_line where order_id = p_order_id and (status is null or status in ('In approval', 'Awaiting Back-End inputs', 'Returned'))) then return; end if;
  update public.orders set route_state = 'completed', completed_at = now() where id = p_order_id;
  select string_agg(coalesce(p.name, l.product_code_entered, 'Product') || ': ' ||
         case when l.status = 'Rejected' then 'rejected' else coalesce(l.approved_quantity, l.requested_quantity)::text || ' approved of ' || l.requested_quantity::text end, '; ' order by l.file_row)
    into v_msg from public.order_line l left join public.product p on p.id = l.product_id where l.order_id = p_order_id;
  perform app_private.notify(p_order_id, 'completed', 'Order ' || o.order_no || ' is complete. ' || coalesce(v_msg, ''), o.creator, null, null);
  perform app_private.log_action(p_order_id, 'completed', coalesce(v_msg, ''), null, null, true);
end $$;

-- ---------------------------------------------------------------- the routing rules
create or replace function app_private.route_order(p_order_id uuid, p_reset boolean default false) returns text
language plpgsql security definer set search_path = '' as $function$
declare
  o public.orders; r record; need text[]; miss text; missing text[] := '{}'; v_above boolean; v_cut boolean; v_cuts jsonb := '[]'::jsonb;
  v_union text[]; v_stages text[]; stg text; v_name text; v_email text; v_state text; v_note text; v_c jsonb; v_x record; v_ids uuid[] := '{}';
begin
  select * into o from public.orders where id = p_order_id for update;
  if not found then raise exception 'order not found'; end if;
  if o.arrived_at is null then raise exception 'order not submitted'; end if;

  if p_reset then
    delete from public.order_stage s where s.order_id = p_order_id
      and not exists (select 1 from public.line_decision d join public.order_line l on l.id = d.line_id where l.order_id = p_order_id and d.stage = s.stage and not d.superseded);
    update public.orders set route_locked = false where id = p_order_id;
    o.route_locked := false;
    update public.order_line set status = null, required_stages = '{}', approved_quantity = null, postponed_quantity = null
     where order_id = p_order_id and status in ('In approval', 'Cleared', 'Awaiting Back-End inputs')
       and not exists (select 1 from public.line_decision d where d.line_id = order_line.id and not d.superseded);
  end if;

  if o.route_locked then
    select coalesce(array_agg(stage order by seq), '{}') into v_stages from public.order_stage where order_id = p_order_id;
    update public.order_line set required_stages = v_stages,
        status = case when cardinality(v_stages) = 0 then 'Cleared' else 'In approval' end,
        approved_quantity = case when cardinality(v_stages) = 0 then requested_quantity else null end,
        postponed_quantity = null
     where order_id = p_order_id and (status is null or status = 'Awaiting Back-End inputs');
  else
    for r in
      select l.*, c.customer_type, p.name as pname, k.present as k_present, k.cap_q, k.no_cap,
             exists (select 1 from public.special_case sc where sc.customer_id = l.customer_id) as is_special,
             (pm.id is not null) as has_pm, pm.second_line_manager_name as slm_name, pm.second_line_manager_email as slm_email,
             pm.includes_business_unit_director as inc_bud, pm.includes_cfo as inc_cfo, pm.includes_cp as inc_cp,
             exists (select 1 from public.order_line x where x.order_id = l.order_id and x.customer_id = l.customer_id and x.over_allowed_growth) as any_over
      from public.order_line l
      left join public.customer c on c.id = l.customer_id
      left join public.product p on p.id = l.product_id
      left join public.product_map pm on pm.product_id = l.product_id
      left join lateral (select true as present, kk.cap_quantity as cap_q, kk.no_capping as no_cap from public.cap kk
                         where kk.product_id = l.product_id and kk.customer_type = c.customer_type limit 1) k on true
      where l.order_id = p_order_id and (l.status is null or l.status = 'Awaiting Back-End inputs')
      order by l.file_row
    loop
      need := '{}'; miss := null; v_cut := false; v_ids := v_ids || r.id;
      if r.customer_id is null or r.product_id is null then
        miss := 'row ' || r.file_row || ': customer or product not recognised';
      else
        v_above := null;
        if r.k_present then
          if r.no_cap then v_above := false;
          elsif r.cap_q is not null then v_above := (r.requested_quantity + coalesce(r.earlier_orders_quantity, 0)) > r.cap_q; end if;
        end if;
        if r.customer_type in ('independent_pharmacy', 'private_hospital', 'ngo') and o.concern_type is not null then
          need := need || '{business_unit_director,cfo}'::text[];
        end if;
        if v_above is null then
          miss := 'row ' || r.file_row || ': no cap set for ' || coalesce(r.pname, 'the product') || ' (' || r.customer_type || ')';
        elsif v_above then
          if r.is_special then
            if r.calculated_quantity is null then miss := 'row ' || r.file_row || ': calculated quantity (special-case account)';
            else need := need || '{second_line_manager}'::text[]; end if;
          elsif r.customer_type = 'grouped_chain' then
            if r.gv_position_pct is null then miss := 'row ' || r.file_row || ': Guided Value position of the chain';
            elsif r.over_allowed_growth is null then miss := 'row ' || r.file_row || ': allowed-growth check of the product';
            elsif r.gv_position_pct = 120 then miss := 'row ' || r.file_row || ': Guided Value position is exactly 120% and the sources do not say which path applies';
            else
              if r.any_over then need := need || '{second_line_manager}'::text[]; end if;
              if r.gv_position_pct > 100 then need := need || '{second_line_manager,business_unit_director}'::text[]; end if;
              if r.gv_position_pct > 120 then
                need := need || '{cfo}'::text[];
                if r.inc_cp then need := need || '{cp}'::text[]; end if;
              end if;
            end if;
          elsif r.customer_type = 'egydrug' then
            if r.doh_with_order is null then miss := 'row ' || r.file_row || ': Days on Hand with the order';
            elsif r.doh_with_order <= 30 then null;
            elsif r.seek_full_quantity then need := need || '{second_line_manager,business_unit_director,cfo,cp}'::text[];
            elsif r.capped_quantity is null then miss := 'row ' || r.file_row || ': quantity that brings the pharmacy to 30 days of cover';
            else v_cut := true; end if;
          elsif r.customer_type in ('independent_pharmacy', 'private_hospital', 'ngo') then
            if r.growth_pct is null then miss := 'row ' || r.file_row || ': growth against last year''s average';
            elsif r.growth_pct = 50 then miss := 'row ' || r.file_row || ': growth is exactly 50% and the sources do not say which path applies';
            elsif r.growth_pct > 50 then
              if not r.has_pm then miss := 'row ' || r.file_row || ': product map missing for ' || coalesce(r.pname, 'the product');
              else
                need := need || '{second_line_manager}'::text[];
                if r.inc_bud then need := need || '{business_unit_director}'::text[]; end if;
                if r.inc_cfo then need := need || '{cfo}'::text[]; end if;
                if r.inc_cp then need := need || '{cp}'::text[]; end if;
              end if;
            end if;
          else
            miss := 'row ' || r.file_row || ': no routing rule for customer type ' || coalesce(r.customer_type, 'unknown');
          end if;
        end if;
        if miss is null and 'second_line_manager' = any (need) and (not r.has_pm or r.slm_email is null) then
          miss := 'row ' || r.file_row || ': no Second Line Manager in the product map for ' || coalesce(r.pname, 'the product');
        end if;
      end if;

      if miss is not null then
        missing := missing || miss;
        update public.order_line set status = 'Awaiting Back-End inputs', required_stages = '{}', approved_quantity = null, postponed_quantity = null where id = r.id;
      else
        need := app_private.sort_stages(need);
        if cardinality(need) = 0 then
          update public.order_line set status = 'Cleared', required_stages = '{}',
              approved_quantity = case when v_cut then r.capped_quantity else r.requested_quantity end,
              postponed_quantity = case when v_cut then r.requested_quantity - r.capped_quantity end
           where id = r.id;
          if v_cut then
            v_cuts := v_cuts || jsonb_build_object('email', r.slm_email, 'msg', 'Order ' || o.order_no || ', row ' || r.file_row || ' (' || coalesce(r.pname, 'product') || '): quantity cut to 30 days of cover, '
                      || (r.requested_quantity - r.capped_quantity)::text || ' postponed to next month.');
          end if;
        else
          update public.order_line set status = 'In approval', required_stages = need, approved_quantity = null, postponed_quantity = null where id = r.id;
        end if;
      end if;
    end loop;

    if cardinality(missing) > 0 then
      update public.order_line set status = 'Awaiting Back-End inputs', required_stages = '{}', approved_quantity = null, postponed_quantity = null
       where id = any (v_ids);
    else
      select coalesce(app_private.sort_stages(array_agg(distinct st)), '{}') into v_union
        from public.order_line l, unnest(l.required_stages) st where l.order_id = p_order_id and l.status = 'In approval';
      delete from public.order_stage s where s.order_id = p_order_id and s.source = 'system' and not (s.stage = any (v_union))
        and not exists (select 1 from public.line_decision d join public.order_line l on l.id = d.line_id where l.order_id = p_order_id and d.stage = s.stage and not d.superseded);
      foreach stg in array v_union loop
        if stg = 'second_line_manager' then
          select m.second_line_manager_name, m.second_line_manager_email into v_name, v_email
            from public.order_line l join public.product_map m on m.product_id = l.product_id
           where l.order_id = p_order_id and l.status = 'In approval' and 'second_line_manager' = any (l.required_stages)
           order by coalesce(l.over_allowed_growth, false) desc, l.file_row limit 1;
        else
          select a.holder_name, a.holder_email into v_name, v_email from public.approver a where a.stage = stg limit 1;
        end if;
        insert into public.order_stage (order_id, stage, seq, assigned_name, assigned_email, source, reason)
          values (p_order_id, stg, app_private.canon_seq(stg), v_name, v_email, 'system', 'Set by the system from the Back-End inputs')
          on conflict (order_id, stage) do nothing;
      end loop;
    end if;
  end if;

  -- state of the order
  if exists (select 1 from public.order_line where order_id = p_order_id and status = 'In approval') then v_state := 'in_approval';
  elsif exists (select 1 from public.order_line where order_id = p_order_id and status = 'Awaiting Back-End inputs') then v_state := 'needs_inputs';
  elsif o.completed_at is not null then v_state := 'completed';
  elsif not exists (select 1 from public.order_line where order_id = p_order_id and status in ('Approved', 'Rejected', 'Returned')) then v_state := 'no_approval';
  else v_state := 'in_approval'; end if;
  v_note := case when cardinality(missing) > 0 then 'Back-End inputs needed: ' || array_to_string(missing, '; ')
                 when v_state = 'needs_inputs' then o.route_note
                 when o.route_locked then 'Route set by Back-End'
                 else 'Route set by the system from the Back-End inputs' end;
  update public.orders set route_state = v_state, route_note = v_note where id = p_order_id;

  if cardinality(missing) = 0 then
    for v_c in select * from jsonb_array_elements(v_cuts) loop
      perform app_private.notify(p_order_id, 'egydrug_cut', v_c ->> 'msg', null, v_c ->> 'email', 'second_line_manager');
    end loop;
    for v_x in select id from public.order_line where order_id = p_order_id and status = 'In approval' loop
      perform app_private.advance_line(v_x.id);
    end loop;
  end if;
  if v_state is distinct from o.route_state or v_note is distinct from o.route_note then
    perform app_private.log_action(p_order_id, 'routed', v_note, null, null, true);
  end if;
  perform app_private.complete_check(p_order_id);
  return v_state;
end $function$;

-- ---------------------------------------------------------------- Back-End: inputs, route, recalculation
create or replace function public.be_set_inputs(p_order_id uuid, p_order jsonb, p_lines jsonb) returns text
language plpgsql security definer set search_path = '' as $function$
declare v_role text; o public.orders; e jsonb; l public.order_line; k text; v_state text; n int := 0; v_num numeric;
begin
  select app_private.current_role_name() into v_role;
  if v_role is distinct from 'back_end_monitoring' then raise exception 'not allowed'; end if;
  select * into o from public.orders where id = p_order_id for update;
  if not found or o.arrived_at is null then raise exception 'order not found'; end if;
  if o.route_state = 'completed' then raise exception 'the order is complete'; end if;

  if p_order is not null and jsonb_typeof(p_order) = 'object' then
    for k in select jsonb_object_keys(p_order) loop
      if k not in ('concern_type', 'concern_note') then raise exception 'field % cannot be set on the order', k; end if;
    end loop;
    if p_order ? 'concern_type' then
      if coalesce(trim(p_order ->> 'concern_type'), '') = '' then
        update public.orders set concern_type = null, concern_note = null where id = p_order_id;
      else
        if not exists (select 1 from public.concern_type t where t.name = trim(p_order ->> 'concern_type')) then raise exception 'choose a concern type from the list'; end if;
        update public.orders set concern_type = trim(p_order ->> 'concern_type'), concern_note = nullif(trim(coalesce(p_order ->> 'concern_note', '')), '') where id = p_order_id;
      end if;
    end if;
  end if;

  if p_lines is not null and jsonb_typeof(p_lines) = 'array' then
    for e in select * from jsonb_array_elements(p_lines) loop
      select * into l from public.order_line where id = (e ->> 'line_id')::uuid and order_id = p_order_id for update;
      if not found then raise exception 'line not on this order'; end if;
      if exists (select 1 from public.line_return r where r.line_id = l.id and r.resolved_at is null) then raise exception 'row % is returned and waiting for the Distribution Manager', l.file_row; end if;
      if l.status in ('Approved', 'Rejected') then raise exception 'row % is already final', l.file_row; end if;
      if exists (select 1 from public.line_decision d where d.line_id = l.id and not d.superseded) then raise exception 'row % is already decided by an approver', l.file_row; end if;
      for k in select jsonb_object_keys(e) loop
        if k not in ('line_id', 'gv_position_pct', 'over_allowed_growth', 'growth_pct', 'doh_with_order', 'seek_full_quantity', 'capped_quantity', 'calculated_quantity') then
          raise exception 'field % cannot be set on a line', k; end if;
      end loop;
      foreach k in array array['gv_position_pct', 'growth_pct', 'doh_with_order', 'capped_quantity', 'calculated_quantity'] loop
        if e ? k and coalesce(e ->> k, '') <> '' then
          v_num := (e ->> k)::numeric;
          if v_num < 0 then raise exception '% on row % cannot be negative', k, l.file_row; end if;
        end if;
      end loop;
      if e ? 'capped_quantity' and coalesce(e ->> 'capped_quantity', '') <> '' and (e ->> 'capped_quantity')::numeric >= l.requested_quantity then
        raise exception 'the capped quantity on row % must be below the requested quantity', l.file_row; end if;
      if e ? 'gv_position_pct' then update public.order_line set gv_position_pct = nullif(e ->> 'gv_position_pct', '')::numeric where id = l.id; end if;
      if e ? 'over_allowed_growth' then update public.order_line set over_allowed_growth = nullif(e ->> 'over_allowed_growth', '')::boolean where id = l.id; end if;
      if e ? 'growth_pct' then update public.order_line set growth_pct = nullif(e ->> 'growth_pct', '')::numeric where id = l.id; end if;
      if e ? 'doh_with_order' then update public.order_line set doh_with_order = nullif(e ->> 'doh_with_order', '')::numeric where id = l.id; end if;
      if e ? 'seek_full_quantity' then update public.order_line set seek_full_quantity = coalesce(nullif(e ->> 'seek_full_quantity', '')::boolean, false) where id = l.id; end if;
      if e ? 'capped_quantity' then update public.order_line set capped_quantity = nullif(e ->> 'capped_quantity', '')::numeric where id = l.id; end if;
      if e ? 'calculated_quantity' then update public.order_line set calculated_quantity = nullif(e ->> 'calculated_quantity', '')::numeric where id = l.id; end if;
      n := n + 1;
    end loop;
  end if;

  update public.order_line set status = null, required_stages = '{}', approved_quantity = null, postponed_quantity = null
   where order_id = p_order_id and status in ('In approval', 'Cleared', 'Awaiting Back-End inputs')
     and not exists (select 1 from public.line_decision d where d.line_id = order_line.id and not d.superseded)
     and not exists (select 1 from public.line_return r where r.line_id = order_line.id and r.resolved_at is null);
  v_state := app_private.route_order(p_order_id);
  perform app_private.log_action(p_order_id, 'inputs_saved', n || ' line(s) updated. Order state: ' || v_state);
  return v_state;
end $function$;
revoke all on function public.be_set_inputs(uuid, jsonb, jsonb) from public, anon;
grant execute on function public.be_set_inputs(uuid, jsonb, jsonb) to authenticated;

create or replace function public.be_reset_route(p_order_id uuid) returns text
language plpgsql security definer set search_path = '' as $function$
declare v_role text; o public.orders; v_state text;
begin
  select app_private.current_role_name() into v_role;
  if v_role is distinct from 'back_end_monitoring' then raise exception 'not allowed'; end if;
  select * into o from public.orders where id = p_order_id for update;
  if not found or o.arrived_at is null then raise exception 'order not found'; end if;
  if o.route_state = 'completed' then raise exception 'the order is complete'; end if;
  v_state := app_private.route_order(p_order_id, true);
  perform app_private.log_action(p_order_id, 'route_reset', 'Route proposed again by the system for lines with no decision yet. Order state: ' || v_state);
  return v_state;
end $function$;
revoke all on function public.be_reset_route(uuid) from public, anon;
grant execute on function public.be_reset_route(uuid) to authenticated;

create or replace function public.be_set_stage(p_order_id uuid, p_stage text, p_present boolean, p_name text default null, p_email text default null) returns void
language plpgsql security definer set search_path = '' as $function$
declare v_role text; o public.orders; v_seq int; v_name text := nullif(trim(p_name), ''); v_email text := nullif(trim(p_email), '');
begin
  select app_private.current_role_name() into v_role;
  if v_role is distinct from 'back_end_monitoring' then raise exception 'not allowed'; end if;
  if p_stage is null or app_private.canon_seq(p_stage) is null then raise exception 'unknown stage'; end if;
  select * into o from public.orders where id = p_order_id for update;
  if not found or o.arrived_at is null then raise exception 'order not found'; end if;
  if o.route_state = 'completed' then raise exception 'the order is complete'; end if;
  v_seq := app_private.canon_seq(p_stage);
  perform 1 from public.order_line where order_id = p_order_id for update;

  if p_present then
    if exists (select 1 from public.order_stage where order_id = p_order_id and stage = p_stage) then return; end if;
    if exists (select 1 from public.line_decision d join public.order_line l on l.id = d.line_id
               where l.order_id = p_order_id and not d.superseded and app_private.canon_seq(d.stage) > v_seq) then
      raise exception 'a later stage has already decided a product, so this stage can no longer be added'; end if;
    if p_stage = 'second_line_manager' and v_name is null then
      select m.second_line_manager_name, m.second_line_manager_email into v_name, v_email
        from public.order_line l join public.product_map m on m.product_id = l.product_id where l.order_id = p_order_id order by l.file_row limit 1;
      if v_name is null then raise exception 'choose the Second Line Manager'; end if;
    elsif p_stage <> 'second_line_manager' and v_name is null then
      select a.holder_name, a.holder_email into v_name, v_email from public.approver a where a.stage = p_stage limit 1;
    end if;
    insert into public.order_stage (order_id, stage, seq, assigned_name, assigned_email, source, reason)
      values (p_order_id, p_stage, v_seq, v_name, v_email, 'back_end', 'Added by Back-End');
    update public.orders set route_locked = true where id = p_order_id;
    update public.order_line set required_stages = app_private.sort_stages(required_stages || p_stage) where order_id = p_order_id and status = 'In approval';
    perform app_private.log_action(p_order_id, 'stage_added', coalesce(v_name, 'no one assigned'), p_stage);
  else
    if not exists (select 1 from public.order_stage where order_id = p_order_id and stage = p_stage) then return; end if;
    if exists (select 1 from public.line_decision d join public.order_line l on l.id = d.line_id where l.order_id = p_order_id and d.stage = p_stage and not d.superseded) then
      raise exception 'this stage has already decided a product and cannot be removed'; end if;
    delete from public.order_stage where order_id = p_order_id and stage = p_stage;
    update public.orders set route_locked = true where id = p_order_id;
    update public.order_line set required_stages = array_remove(required_stages, p_stage) where order_id = p_order_id and status = 'In approval';
    perform app_private.log_action(p_order_id, 'stage_removed', null, p_stage);
  end if;
  perform app_private.route_order(p_order_id);
end $function$;
revoke all on function public.be_set_stage(uuid, text, boolean, text, text) from public, anon;
grant execute on function public.be_set_stage(uuid, text, boolean, text, text) to authenticated;

create or replace function public.be_reassign_stage(p_order_id uuid, p_stage text, p_name text, p_email text) returns void
language plpgsql security definer set search_path = '' as $function$
declare v_role text; o public.orders; v_old text;
begin
  select app_private.current_role_name() into v_role;
  if v_role is distinct from 'back_end_monitoring' then raise exception 'not allowed'; end if;
  if p_name is null or length(trim(p_name)) = 0 then raise exception 'choose the user the stage moves to'; end if;
  select * into o from public.orders where id = p_order_id for update;
  if not found or o.arrived_at is null then raise exception 'order not found'; end if;
  if o.route_state = 'completed' then raise exception 'the order is complete'; end if;
  select coalesce(assigned_name, 'no one') into v_old from public.order_stage where order_id = p_order_id and stage = p_stage;
  if not found then raise exception 'this stage is not on the order'; end if;
  update public.order_stage set assigned_name = trim(p_name), assigned_email = nullif(trim(p_email), ''), reassigned = true, source = 'back_end'
    where order_id = p_order_id and stage = p_stage;
  update public.orders set route_locked = true where id = p_order_id;
  perform app_private.log_action(p_order_id, 'stage_reassigned', 'from ' || v_old || ' to ' || trim(p_name), p_stage);
  if exists (select 1 from public.order_line l where l.order_id = p_order_id and l.status = 'In approval' and app_private.next_stage(l) = p_stage) then
    perform app_private.notify_stage(p_order_id, p_stage);
  end if;
end $function$;
revoke all on function public.be_reassign_stage(uuid, text, text, text) from public, anon;
grant execute on function public.be_reassign_stage(uuid, text, text, text) to authenticated;

-- Quantity change by Back-End: never on a returned or final line, never on a line an approver has already decided.
-- The inputs of the line were worked out on the old quantity, so they are cleared and Back-End enters them again.
create or replace function public.be_change_quantity(p_line_id uuid, p_quantity numeric, p_reason text) returns text
language plpgsql security definer set search_path = '' as $function$
declare v_role text; v_line public.order_line; v_file public.order_file; v_order public.orders; v_result text;
begin
  select app_private.current_role_name() into v_role;
  if v_role is distinct from 'back_end_monitoring' then raise exception 'not allowed'; end if;
  if p_quantity is null or p_quantity < 0 or p_quantity <> trunc(p_quantity) then raise exception 'enter a whole number, zero or more'; end if;
  if p_reason is null or length(trim(p_reason)) = 0 then raise exception 'a reason is required'; end if;
  select * into v_line from public.order_line where id = p_line_id;
  if not found then raise exception 'line not found'; end if;
  select * into v_order from public.orders where id = v_line.order_id for update;
  select * into v_file from public.order_file where id = v_order.file_id for update;
  select * into v_line from public.order_line where id = p_line_id for update;
  if v_file.state <> 'submitted' then raise exception 'the order is not submitted'; end if;
  if exists (select 1 from public.line_return r where r.line_id = p_line_id and r.resolved_at is null) then
    raise exception 'this line is returned to the Distribution Manager; only the Distribution Manager can change it now'; end if;
  if v_line.status in ('Approved', 'Rejected') then raise exception 'this line is already final'; end if;
  if exists (select 1 from public.line_decision d where d.line_id = p_line_id and not d.superseded) then
    raise exception 'an approver has already decided this line; return it instead of changing the quantity'; end if;
  update public.order_line set requested_quantity = p_quantity,
      line_value = case when line_value is not null and pharmacy_price is not null then p_quantity * pharmacy_price else line_value end,
      gv_position_pct = null, over_allowed_growth = null, growth_pct = null, doh_with_order = null, seek_full_quantity = false, capped_quantity = null, calculated_quantity = null,
      status = null, required_stages = '{}', approved_quantity = null, postponed_quantity = null
    where id = p_line_id;
  v_result := app_private.check_order(v_line.order_id);
  insert into public.action_log (order_id, file_id, actor, actor_role, action, detail, quantity)
    values (v_line.order_id, v_file.id, (select auth.uid()), v_role, 'quantity_changed',
            'Row ' || v_line.file_row || ': from ' || coalesce(v_line.requested_quantity::text, 'empty') || ' to ' || p_quantity::text || '. Reason: ' || trim(p_reason) || '. Order checked again: ' || v_result
            || '. Routing inputs of this line cleared.', p_quantity);
  perform app_private.route_order(v_line.order_id);
  return v_result;
end $function$;

create or replace function public.be_return_lines(p_order_id uuid, p_lines jsonb) returns integer
language plpgsql security definer set search_path = '' as $function$
declare v_role text; v_file public.order_file; v_name text; e jsonb; v_line public.order_line; v_prod text; n int := 0;
begin
  select app_private.current_role_name() into v_role;
  if v_role is distinct from 'back_end_monitoring' then raise exception 'not allowed'; end if;
  perform 1 from public.orders where id = p_order_id for update;
  select f.* into v_file from public.orders o join public.order_file f on f.id = o.file_id where o.id = p_order_id;
  if not found then raise exception 'order not found'; end if;
  if v_file.state <> 'submitted' then raise exception 'the order is not submitted'; end if;
  if p_lines is null or jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then raise exception 'choose the lines to return'; end if;
  select display_name into v_name from public.app_user where id = (select auth.uid());
  for e in select * from jsonb_array_elements(p_lines) loop
    if coalesce(trim(e ->> 'reason'), '') = '' then raise exception 'a comment is required on every returned line'; end if;
    select * into v_line from public.order_line where id = (e ->> 'line_id')::uuid and order_id = p_order_id for update;
    if not found then raise exception 'line not on this order'; end if;
    if v_line.status in ('Approved', 'Rejected') then raise exception 'row % is already final', v_line.file_row; end if;
    if exists (select 1 from public.line_return r where r.line_id = v_line.id and r.resolved_at is null) then
      raise exception 'row % is already returned and waiting for the Distribution Manager', v_line.file_row; end if;
    select name into v_prod from public.product where id = v_line.product_id;
    insert into public.line_return (line_id, returned_by_name, returned_by_role, returned_by, reason)
      values (v_line.id, coalesce(v_name, 'Back-End'), 'back_end_monitoring', (select auth.uid()), trim(e ->> 'reason'));
    update public.order_line set status = 'Returned' where id = v_line.id;
    insert into public.action_log (order_id, file_id, actor, actor_role, action, detail)
      values (p_order_id, v_file.id, (select auth.uid()), v_role, 'returned',
              'Row ' || v_line.file_row || ', ' || coalesce(v_prod, v_line.product_code_entered, 'product') || ': ' || trim(e ->> 'reason'));
    n := n + 1;
  end loop;
  perform app_private.route_order(p_order_id);
  return n;
end $function$;

create or replace function public.dm_resubmit_returned(p_order_id uuid) returns text
language plpgsql security definer set search_path = '' as $function$
declare v_role text; v_order public.orders; v_result text; n int; v_lines uuid[];
begin
  select app_private.current_role_name() into v_role;
  if v_role is distinct from 'distribution_manager' then raise exception 'not allowed'; end if;
  select * into v_order from public.orders where id = p_order_id for update;
  if not found or v_order.creator <> (select auth.uid()) then raise exception 'order not found'; end if;
  perform 1 from public.order_line where order_id = p_order_id for update;
  if not exists (select 1 from public.line_return r join public.order_line l on l.id = r.line_id
                 where l.order_id = p_order_id and r.resolved_at is null) then raise exception 'no returned lines are waiting'; end if;
  v_result := app_private.check_order(p_order_id);
  if v_result = 'Valid' then
    with res as (
      update public.line_return r set resolved_at = now() from public.order_line l
       where l.id = r.line_id and l.order_id = p_order_id and r.resolved_at is null returning r.line_id)
    select array_agg(line_id) into v_lines from res;
    n := coalesce(cardinality(v_lines), 0);
    update public.line_decision set superseded = true where line_id = any (v_lines) and not superseded;
    update public.order_line set status = null, approved_quantity = null, postponed_quantity = null, required_stages = '{}' where id = any (v_lines);
    insert into public.action_log (order_id, file_id, actor, actor_role, action, detail)
      values (p_order_id, v_order.file_id, (select auth.uid()), v_role, 'resubmitted', n || ' returned line(s) sent back after correction. Order checked again: Valid');
    perform app_private.route_order(p_order_id);
  end if;
  return v_result;
end $function$;

create or replace function public.submit_order(p_order_id uuid) returns void
language plpgsql security definer set search_path = '' as $function$
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
  perform app_private.route_order(p_order_id);
end $function$;

-- ---------------------------------------------------------------- approver actions
create or replace function public.ap_decide(p_order_id uuid, p_decisions jsonb, p_rationale text default null) returns integer
language plpgsql security definer set search_path = '' as $function$
declare
  v_role text; v_uid uuid := (select auth.uid()); v_name text; e jsonb; l public.order_line; o public.orders;
  v_stage text; v_dec text; v_qty numeric; v_reason text; v_rat text := nullif(trim(coalesce(p_rationale, '')), ''); n int := 0; v_prod text;
begin
  select app_private.current_role_name() into v_role;
  if v_role is null or v_role not in ('second_line_manager', 'business_unit_director', 'cfo', 'cp') then raise exception 'not allowed'; end if;
  select * into o from public.orders where id = p_order_id for update;
  if not found or o.arrived_at is null or not app_private.approver_sees(p_order_id) then raise exception 'order not found'; end if;
  if p_decisions is null or jsonb_typeof(p_decisions) <> 'array' or jsonb_array_length(p_decisions) = 0 then raise exception 'choose a decision for at least one product'; end if;
  select display_name into v_name from public.app_user where id = v_uid;
  for e in select * from jsonb_array_elements(p_decisions) loop
    select * into l from public.order_line where id = (e ->> 'line_id')::uuid and order_id = p_order_id for update;
    if not found then raise exception 'line not on this order'; end if;
    if l.status is distinct from 'In approval' then raise exception 'row % is not waiting for an approval decision', l.file_row; end if;
    if exists (select 1 from public.line_return r where r.line_id = l.id and r.resolved_at is null) then
      raise exception 'row % is returned and waiting for the Distribution Manager', l.file_row; end if;
    v_stage := app_private.next_stage(l);
    if v_stage is null then raise exception 'row % has no open stage', l.file_row; end if;
    if not app_private.can_act_on_stage(p_order_id, v_stage, l.product_id) then raise exception 'row % is not at your stage', l.file_row; end if;
    v_dec := e ->> 'decision';
    select name into v_prod from public.product where id = l.product_id;

    if v_dec = 'approve' then
      v_qty := coalesce(nullif(e ->> 'quantity', '')::numeric, l.requested_quantity);
      if v_qty < 0 or v_qty > l.requested_quantity then raise exception 'the approved quantity of row % must be between 0 and the requested quantity', l.file_row; end if;
      if v_stage = 'second_line_manager' and v_rat is null then raise exception 'a rationale is required when the Second Line Manager approves'; end if;
      insert into public.line_decision (line_id, stage, decision, quantity, rationale, decided_by, decided_name)
        values (l.id, v_stage, 'approved', v_qty, v_rat, v_uid, coalesce(v_name, 'Approver'));
      if v_stage = 'second_line_manager' and l.calculated_quantity is not null and v_qty > l.calculated_quantity
         and exists (select 1 from public.special_case sc where sc.customer_id = l.customer_id) and not ('business_unit_director' = any (l.required_stages)) then
        insert into public.order_stage (order_id, stage, seq, assigned_name, assigned_email, source, reason)
          select p_order_id, a.stage, app_private.canon_seq(a.stage), a.holder_name, a.holder_email, 'system', 'Approved quantity is above the Back-End calculation (special-case account)'
            from public.approver a where a.stage in ('business_unit_director', 'cfo')
          on conflict (order_id, stage) do nothing;
        update public.order_line set required_stages = app_private.sort_stages(required_stages || '{business_unit_director,cfo}'::text[]) where id = l.id;
      end if;
      perform app_private.log_action(p_order_id, 'approved', 'Row ' || l.file_row || ', ' || coalesce(v_prod, 'product') || ': ' || v_qty::text || ' of ' || l.requested_quantity::text
        || case when v_rat is not null then '. Rationale: ' || v_rat else '' end, v_stage, v_qty);
      perform app_private.advance_line(l.id);

    elsif v_dec = 'reject' then
      v_reason := trim(coalesce(e ->> 'reason', ''));
      if v_reason = '' then raise exception 'a reason is required when rejecting a product'; end if;
      insert into public.line_decision (line_id, stage, decision, quantity, rationale, decided_by, decided_name)
        values (l.id, v_stage, 'rejected', 0, v_reason, v_uid, coalesce(v_name, 'Approver'));
      update public.order_line set status = 'Rejected', approved_quantity = 0 where id = l.id;
      perform app_private.notify(p_order_id, 'rejected', 'Order ' || o.order_no || ', row ' || l.file_row || ' (' || coalesce(v_prod, 'product') || ') was rejected: ' || v_reason, null, null, 'back_end_monitoring');
      perform app_private.log_action(p_order_id, 'rejected', 'Row ' || l.file_row || ', ' || coalesce(v_prod, 'product') || ': ' || v_reason, v_stage);

    elsif v_dec = 'return' then
      v_reason := trim(coalesce(e ->> 'reason', ''));
      if v_reason = '' then raise exception 'a reason is required when returning a product'; end if;
      insert into public.line_return (line_id, returned_by_name, returned_by_role, returned_by, reason)
        values (l.id, coalesce(v_name, 'Approver'), v_role, v_uid, v_reason);
      update public.order_line set status = 'Returned' where id = l.id;
      perform app_private.log_action(p_order_id, 'returned', 'Row ' || l.file_row || ', ' || coalesce(v_prod, 'product') || ': ' || v_reason, v_stage);
    else
      raise exception 'unknown decision';
    end if;
    n := n + 1;
  end loop;
  perform app_private.complete_check(p_order_id);
  return n;
end $function$;
revoke all on function public.ap_decide(uuid, jsonb, text) from public, anon;
grant execute on function public.ap_decide(uuid, jsonb, text) to authenticated;

-- ---------------------------------------------------------------- existing demo data
update public.order_stage set seq = app_private.canon_seq(stage);
update public.order_stage set assigned_name = 'Demo Second Line Manager 1', assigned_email = 'demo.slm1@example.invalid'
 where demo and stage = 'second_line_manager' and assigned_name = 'Demo Second Line Manager';
update public.order_line l set status = 'Returned' where exists (select 1 from public.line_return r where r.line_id = l.id and r.resolved_at is null);
update public.orders set route_locked = true where demo and arrived_at is not null;
select app_private.route_order(o.id) from public.orders o where o.demo and o.arrived_at is not null;
