-- Engine fixes found by the rolled-back test (supabase/tests/approval_engine_test.sql)
-- 1. Grouped chains and EgyDrug are not routed by a cap: the cap check no longer blocks them (the cap table only holds independent pharmacies and private hospitals).
-- 2. The final approved quantity is the one given at the last stage in the canonical order, not just the latest timestamp.
-- 3. A returned line that the Distribution Manager corrected and resubmitted loses its old Back-End inputs: they belonged to the old values.

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
        if r.customer_type in ('grouped_chain', 'egydrug') then
          v_above := true;  -- chains and EgyDrug are not routed by a cap: their own rules (Guided Value, Days on Hand) decide
        elsif r.k_present then
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

create or replace function app_private.advance_line(p_line_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare l public.order_line; nxt text; lastq numeric;
begin
  select * into l from public.order_line where id = p_line_id for update;
  if not found or l.status is distinct from 'In approval' then return; end if;
  nxt := app_private.next_stage(l);
  if nxt is null then
    select d.quantity into lastq from public.line_decision d where d.line_id = l.id and d.decision = 'approved' and not d.superseded order by app_private.canon_seq(d.stage) desc, d.decided_at desc limit 1;
    update public.order_line set status = 'Approved', approved_quantity = coalesce(lastq, l.requested_quantity - coalesce(l.postponed_quantity, 0)) where id = l.id;
  else
    perform app_private.notify_stage(l.order_id, nxt);
  end if;
end $$;

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
    update public.order_line set status = null, approved_quantity = null, postponed_quantity = null, required_stages = '{}',
        gv_position_pct = null, over_allowed_growth = null, growth_pct = null, doh_with_order = null, seek_full_quantity = false, capped_quantity = null, calculated_quantity = null
     where id = any (v_lines);
    insert into public.action_log (order_id, file_id, actor, actor_role, action, detail)
      values (p_order_id, v_order.file_id, (select auth.uid()), v_role, 'resubmitted', n || ' returned line(s) sent back after correction. Order checked again: Valid');
    perform app_private.route_order(p_order_id);
  end if;
  return v_result;
end $function$;
