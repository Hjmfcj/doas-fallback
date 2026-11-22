-- DEMO SCENARIOS (22-Nov-2026). Synthetic orders that put work in front of every demo login.
-- Needs: demo_seed.sql, the demo users (Demo_Logins.md) and the approval-engine migrations.
-- Every order is created through the real functions as the real demo users (Distribution Manager submits, Back-End enters inputs and returns,
-- approvers decide), so statuses, stages, decisions and notifications are exactly what the product produces.
-- WARNING: the real functions write the audit log, which is insert-only. Orders and demo users that have audit rows can never be deleted.
-- Run once. Set dry := true to see the result and roll everything back; dry := false keeps it.
create or replace function pg_temp.uid(p_email text) returns uuid language sql as $$ select id from auth.users where email = p_email $$;
create or replace function pg_temp.act(p_email text) returns void language plpgsql as $$
begin
  reset role;
  perform set_config('request.jwt.claims', json_build_object('sub', pg_temp.uid(p_email), 'email', p_email, 'role', 'authenticated')::text, true);
  set local role authenticated;
end $$;
create or replace function pg_temp.mk(p_name text, p_type text, p_ago int, p_rows jsonb) returns uuid language plpgsql as $$
declare dm uuid := pg_temp.uid('demo.dm@example.invalid'); f uuid; o uuid; x jsonb; i int := 0;
begin
  reset role;
  insert into public.order_file (uploaded_name, stored_name, uploader, upload_type, demo, created_at)
    values (p_name || '.xlsx', 'demo-scn-' || gen_random_uuid(), dm, p_type, true, now() - (p_ago::text || ' days')::interval) returning id into f;
  insert into public.orders (file_id, creator, demo, created_at) values (f, dm, true, now() - (p_ago::text || ' days')::interval) returning id into o;
  for x in select * from jsonb_array_elements(p_rows) loop
    i := i + 1;
    insert into public.order_line (order_id, file_row, distributor, customer_key_entered, product_code_entered, requested_quantity, pharmacy_price, order_date, demo)
      values (o, i, 'Demo Distributor ' || coalesce(x ->> 'd', '1'), x ->> 'c', x ->> 'p', (x ->> 'q')::numeric, coalesce((x ->> 'price')::numeric, 10), current_date, true);
  end loop;
  return o;
end $$;
create or replace function pg_temp.dm_go(p_o uuid, p_submit boolean default true) returns uuid language plpgsql as $$
declare r text;
begin
  perform pg_temp.act('demo.dm@example.invalid');
  r := public.run_file_check(p_o);
  if p_submit then
    if r <> 'Valid' then raise exception 'file check gave %', r; end if;
    perform public.submit_order(p_o);
  end if;
  reset role; return p_o;
end $$;
create or replace function pg_temp.be_inp(p_o uuid, p_hdr jsonb, p_obj jsonb, p_rows int[] default null) returns uuid language plpgsql as $$
declare arr jsonb;
begin
  reset role;
  select jsonb_agg(p_obj || jsonb_build_object('line_id', id)) into arr from public.order_line where order_id = p_o and (p_rows is null or file_row = any (p_rows));
  perform pg_temp.act('demo.backend@example.invalid');
  perform public.be_set_inputs(p_o, coalesce(p_hdr, '{}'::jsonb), coalesce(arr, '[]'::jsonb));
  reset role; return p_o;
end $$;
create or replace function pg_temp.be_ret(p_o uuid, p_rows int[], p_reason text) returns uuid language plpgsql as $$
declare arr jsonb;
begin
  reset role;
  select jsonb_agg(jsonb_build_object('line_id', id, 'reason', p_reason)) into arr from public.order_line where order_id = p_o and file_row = any (p_rows);
  perform pg_temp.act('demo.backend@example.invalid');
  perform public.be_return_lines(p_o, arr);
  reset role; return p_o;
end $$;
create or replace function pg_temp.be_qty(p_o uuid, p_row int, p_qty numeric, p_reason text) returns uuid language plpgsql as $$
declare l uuid;
begin
  reset role; select id into l from public.order_line where order_id = p_o and file_row = p_row;
  perform pg_temp.act('demo.backend@example.invalid');
  perform public.be_change_quantity(l, p_qty, p_reason);
  reset role; return p_o;
end $$;
create or replace function pg_temp.be_stg(p_o uuid, p_stage text, p_present boolean, p_nm text default null, p_em text default null) returns uuid language plpgsql as $$
begin
  perform pg_temp.act('demo.backend@example.invalid');
  perform public.be_set_stage(p_o, p_stage, p_present, p_nm, p_em);
  reset role; return p_o;
end $$;
create or replace function pg_temp.be_reas(p_o uuid, p_stage text, p_nm text, p_em text) returns uuid language plpgsql as $$
begin
  perform pg_temp.act('demo.backend@example.invalid');
  perform public.be_reassign_stage(p_o, p_stage, p_nm, p_em);
  reset role; return p_o;
end $$;
create or replace function pg_temp.ap(p_email text, p_o uuid, p_decs jsonb, p_rat text default null) returns uuid language plpgsql as $$
declare arr jsonb;
begin
  reset role;
  select jsonb_agg((d - 'row') || jsonb_build_object('line_id', l.id)) into arr
    from jsonb_array_elements(p_decs) d join public.order_line l on l.order_id = p_o and l.file_row = (d ->> 'row')::int;
  perform pg_temp.act(p_email);
  perform public.ap_decide(p_o, arr, p_rat);
  reset role; return p_o;
end $$;
create or replace function pg_temp.dm_fix(p_o uuid, p_row int, p_changes jsonb) returns uuid language plpgsql as $$
declare l uuid;
begin
  reset role; select id into l from public.order_line where order_id = p_o and file_row = p_row;
  perform pg_temp.act('demo.dm@example.invalid');
  perform public.dm_edit_line(l, p_changes);
  perform public.dm_resubmit_returned(p_o);
  reset role; return p_o;
end $$;
create or replace function pg_temp.back(p_o uuid, p_hours numeric) returns uuid language plpgsql as $$
declare v timestamptz := now(); n int := 0;
begin
  reset role;
  while app_private.working_hours(v, now()) < p_hours and n < 1000 loop v := v - interval '1 hour'; n := n + 1; end loop;
  update public.orders set arrived_at = v where id = p_o;
  return p_o;
end $$;
drop table if exists pg_temp.scn_log;
create temp table scn_log (code text, order_id uuid, note text);
create or replace function pg_temp.scn(p_code text, p_body text) returns void language plpgsql as $$
declare o uuid; s text;
begin
  begin
    execute p_body into o;
    reset role;
    select 'state=' || x.route_state || ' | ' || coalesce((select string_agg('r' || l.file_row || ':' || coalesce(l.status, '-') || coalesce(' ' || l.required_stages::text, '') || coalesce(' appr=' || l.approved_quantity::text, ''), '; ' order by l.file_row)
      from public.order_line l where l.order_id = x.id), '') || ' | file=' || f.state || '/' || coalesce(f.check_result, '-') into s
      from public.orders x join public.order_file f on f.id = x.file_id where x.id = o;
    insert into scn_log values (p_code, o, s);
  exception when others then
    reset role;
    insert into scn_log values (p_code, null, 'ERROR: ' || sqlerrm);
  end;
end $$;

do $$
declare dry boolean := true; rep text;
begin
  insert into public.customer (code, name, customer_type, demo) select 'DEMO-I003', 'Demo Special-Case Pharmacy 3', 'independent_pharmacy', true where not exists (select 1 from public.customer where code = 'DEMO-I003');
  insert into public.special_case (customer_id, note, demo) select id, 'Demo special case 2', true from public.customer where code = 'DEMO-I003' and not exists (select 1 from public.special_case sc where sc.customer_id = customer.id);
  -- ===== Distribution Manager: drafts =====
  perform pg_temp.scn('S01 Draft valid', $q$ select pg_temp.dm_go(pg_temp.mk('S01 Draft valid', 'other', 6, '[{"c":"DEMO-I001","p":"DEMO-P1","q":40},{"c":"DEMO-I001","p":"DEMO-P2","q":20}]'), false) $q$);
  perform pg_temp.scn('S02 Draft valid, cap warning', $q$ select pg_temp.dm_go(pg_temp.mk('S02 Draft above cap warning', 'other', 3, '[{"c":"DEMO-I001","p":"DEMO-P1","q":60},{"c":"DEMO-I001","p":"DEMO-P2","q":40,"d":2}]'), false) $q$);
  perform pg_temp.scn('S03 Draft with errors', $q$ select pg_temp.dm_go(pg_temp.mk('S03 Draft with errors', 'other', 1, '[{"c":"NOPE-1","p":"DEMO-P1","q":10},{"c":"DEMO-I002","p":"DEMO-P2","q":5},{"c":"DEMO-I001","p":"DEMO-P1","q":0,"d":2}]'), false) $q$);
  perform pg_temp.scn('S04 Draft not checked', $q$ select pg_temp.mk('S04 Draft not checked yet', 'other', 0, '[{"c":"DEMO-I002","p":"DEMO-P1","q":25}]') $q$);
  -- ===== Submitted, no approval needed =====
  perform pg_temp.scn('S05 Independent within cap', $q$ select pg_temp.dm_go(pg_temp.mk('S05 Independent within cap', 'other', 0, '[{"c":"DEMO-I001","p":"DEMO-P1","q":30}]')) $q$);
  perform pg_temp.scn('S06 Above cap, growth 30', $q$ select pg_temp.be_inp(pg_temp.dm_go(pg_temp.mk('S06 Above cap growth 30', 'other', 0, '[{"c":"DEMO-I001","p":"DEMO-P1","q":60}]')), null, '{"growth_pct":30}') $q$);
  perform pg_temp.scn('S07 Chain GV within', $q$ select pg_temp.be_inp(pg_temp.dm_go(pg_temp.mk('S07 Chain GV within limits', 'grouped_chain', 0, '[{"c":"DEMO-B01","p":"DEMO-P1","q":20},{"c":"DEMO-B01","p":"DEMO-P2","q":20}]')), null, '{"gv_position_pct":90,"over_allowed_growth":false}') $q$);
  perform pg_temp.scn('S08 EgyDrug DOH 25', $q$ select pg_temp.be_inp(pg_temp.dm_go(pg_temp.mk('S08 EgyDrug DOH 25', 'egydrug', 0, '[{"c":"DEMO-E001","p":"DEMO-P1","q":50}]')), null, '{"doh_with_order":25}') $q$);
  perform pg_temp.scn('S09 EgyDrug cut to 30', $q$ select pg_temp.be_inp(pg_temp.dm_go(pg_temp.mk('S09 EgyDrug DOH 41 cut to 30', 'egydrug', 0, '[{"c":"DEMO-E001","p":"DEMO-P1","q":50}]')), null, '{"doh_with_order":41,"capped_quantity":30}') $q$);
  perform pg_temp.scn('S10 Hospital within cap', $q$ select pg_temp.dm_go(pg_temp.mk('S10 Private hospital within cap', 'other', 0, '[{"c":"DEMO-H001","p":"DEMO-P1","q":150}]')) $q$);
  -- ===== Waiting for Back-End inputs =====
  perform pg_temp.scn('S11 Independent above cap, nothing entered', $q$ select pg_temp.dm_go(pg_temp.mk('S11 Above cap waiting for growth', 'other', 0, '[{"c":"DEMO-I001","p":"DEMO-P1","q":60},{"c":"DEMO-I001","p":"DEMO-P2","q":40}]')) $q$);
  perform pg_temp.scn('S12 Chain, nothing entered', $q$ select pg_temp.dm_go(pg_temp.mk('S12 Chain waiting for GV', 'grouped_chain', 0, '[{"c":"DEMO-B01","p":"DEMO-P1","q":20},{"c":"DEMO-B01","p":"DEMO-P2","q":20},{"c":"DEMO-B02","p":"DEMO-P1","q":50,"d":2}]')) $q$);
  perform pg_temp.scn('S13 EgyDrug, nothing entered', $q$ select pg_temp.dm_go(pg_temp.mk('S13 EgyDrug waiting for DOH', 'egydrug', 0, '[{"c":"DEMO-E001","p":"DEMO-P1","q":50}]')) $q$);
  perform pg_temp.scn('S14 NGO special case, nothing entered', $q$ select pg_temp.dm_go(pg_temp.mk('S14 NGO special case waiting', 'other', 0, '[{"c":"DEMO-N001","p":"DEMO-P1","q":60}]')) $q$);
  perform pg_temp.scn('S15 Hospital above cap', $q$ select pg_temp.dm_go(pg_temp.mk('S15 Hospital above cap', 'other', 0, '[{"c":"DEMO-H001","p":"DEMO-P3","q":150}]')) $q$);
  perform pg_temp.scn('S16 Growth exactly 50', $q$ select pg_temp.be_inp(pg_temp.dm_go(pg_temp.mk('S16 Growth exactly 50', 'other', 0, '[{"c":"DEMO-I001","p":"DEMO-P1","q":60}]')), null, '{"growth_pct":50}') $q$);
  perform pg_temp.scn('S17 GV exactly 120', $q$ select pg_temp.be_inp(pg_temp.dm_go(pg_temp.mk('S17 Chain GV exactly 120', 'grouped_chain', 0, '[{"c":"DEMO-B01","p":"DEMO-P1","q":20}]')), null, '{"gv_position_pct":120}') $q$);
  perform pg_temp.scn('S18 Mixed: one line cleared, one waiting', $q$ select pg_temp.dm_go(pg_temp.mk('S18 Mixed lines', 'other', 0, '[{"c":"DEMO-I001","p":"DEMO-P1","q":30},{"c":"DEMO-I001","p":"DEMO-P2","q":40}]')) $q$);
  -- ===== Route proposed by the system; Back-End can edit =====
  perform pg_temp.scn('S19 Growth 80, at SLM', $q$ select pg_temp.be_inp(pg_temp.dm_go(pg_temp.mk('S19 Growth 80 at second line', 'other', 0, '[{"c":"DEMO-I001","p":"DEMO-P1","q":60},{"c":"DEMO-I001","p":"DEMO-P2","q":40}]')), null, '{"growth_pct":80}') $q$);
  perform pg_temp.scn('S20 CP added by Back-End', $q$ select pg_temp.be_stg(pg_temp.be_inp(pg_temp.dm_go(pg_temp.mk('S20 Route edited, CP added', 'other', 0, '[{"c":"DEMO-I001","p":"DEMO-P1","q":60}]')), null, '{"growth_pct":80}'), 'cp', true) $q$);
  perform pg_temp.scn('S21 BUD reassigned to deputy', $q$ select pg_temp.be_reas(pg_temp.ap('demo.slm1@example.invalid', pg_temp.be_inp(pg_temp.dm_go(pg_temp.mk('S21 BUD stage given to the deputy', 'other', 0, '[{"c":"DEMO-I001","p":"DEMO-P1","q":60}]')), null, '{"growth_pct":80}'), '[{"row":1,"decision":"approve"}]', 'Demand confirmed with the field team'), 'business_unit_director', 'Demo BUD Deputy', 'demo.bud.deputy@example.invalid') $q$);
  perform pg_temp.scn('S22 Concern, BUD and CFO', $q$ select pg_temp.be_inp(pg_temp.dm_go(pg_temp.mk('S22 Concern attached', 'other', 0, '[{"c":"DEMO-I001","p":"DEMO-P1","q":60}]')), '{"concern_type":"Demo concern type 1","concern_note":"Unusual demand spike"}', '{"growth_pct":30}') $q$);
  perform pg_temp.scn('S23 Chain GV 110', $q$ select pg_temp.be_inp(pg_temp.dm_go(pg_temp.mk('S23 Chain GV 110', 'grouped_chain', 0, '[{"c":"DEMO-B01","p":"DEMO-P1","q":20},{"c":"DEMO-B01","p":"DEMO-P2","q":20}]')), null, '{"gv_position_pct":110,"over_allowed_growth":false}') $q$);
  perform pg_temp.scn('S24 Chain GV 130', $q$ select pg_temp.be_inp(pg_temp.dm_go(pg_temp.mk('S24 Chain GV 130', 'grouped_chain', 0, '[{"c":"DEMO-B01","p":"DEMO-P1","q":20},{"c":"DEMO-B01","p":"DEMO-P2","q":20}]')), null, '{"gv_position_pct":130,"over_allowed_growth":false}') $q$);
  perform pg_temp.scn('S25 Chain over allowed growth', $q$ select pg_temp.be_inp(pg_temp.be_inp(pg_temp.dm_go(pg_temp.mk('S25 Chain over allowed growth', 'grouped_chain', 0, '[{"c":"DEMO-B01","p":"DEMO-P1","q":20},{"c":"DEMO-B01","p":"DEMO-P2","q":20}]')), null, '{"gv_position_pct":90,"over_allowed_growth":true}', array[1]), null, '{"gv_position_pct":90,"over_allowed_growth":false}', array[2]) $q$);
  perform pg_temp.scn('S26 EgyDrug full quantity wanted', $q$ select pg_temp.be_inp(pg_temp.dm_go(pg_temp.mk('S26 EgyDrug full quantity wanted', 'egydrug', 0, '[{"c":"DEMO-E001","p":"DEMO-P1","q":50}]')), null, '{"doh_with_order":41,"seek_full_quantity":true}') $q$);
  perform pg_temp.scn('S27 Special case at SLM', $q$ select pg_temp.be_inp(pg_temp.dm_go(pg_temp.mk('S27 Special case calculated 30', 'other', 0, '[{"c":"DEMO-I003","p":"DEMO-P1","q":60}]')), null, '{"calculated_quantity":30}') $q$);
  perform pg_temp.scn('S28 Product C, SLM 2 only', $q$ select pg_temp.be_inp(pg_temp.dm_go(pg_temp.mk('S28 Product C second line manager 2', 'other', 0, '[{"c":"DEMO-H001","p":"DEMO-P3","q":150}]')), null, '{"growth_pct":80}') $q$);
  -- ===== Later stages =====
  perform pg_temp.scn('S29 At BUD after SLM', $q$ select pg_temp.ap('demo.slm1@example.invalid', pg_temp.be_inp(pg_temp.dm_go(pg_temp.mk('S29 At BUD after second line', 'other', 0, '[{"c":"DEMO-I001","p":"DEMO-P1","q":60},{"c":"DEMO-I001","p":"DEMO-P2","q":40}]')), null, '{"growth_pct":80}'), '[{"row":1,"decision":"approve","quantity":50},{"row":2,"decision":"approve"}]', 'Demand confirmed with the field team') $q$);
  perform pg_temp.scn('S30 At CFO and CP', $q$ select pg_temp.ap('demo.bud@example.invalid', pg_temp.ap('demo.slm1@example.invalid', pg_temp.be_inp(pg_temp.dm_go(pg_temp.mk('S30 At CFO and CP', 'other', 0, '[{"c":"DEMO-I001","p":"DEMO-P1","q":60},{"c":"DEMO-I001","p":"DEMO-P2","q":40}]')), null, '{"growth_pct":80}'), '[{"row":1,"decision":"approve"},{"row":2,"decision":"approve"}]', 'Demand confirmed with the field team'), '[{"row":1,"decision":"approve"},{"row":2,"decision":"approve"}]') $q$);
  perform pg_temp.scn('S31 Special case at BUD', $q$ select pg_temp.ap('demo.slm1@example.invalid', pg_temp.be_inp(pg_temp.dm_go(pg_temp.mk('S31 Special case above calculation', 'other', 0, '[{"c":"DEMO-I003","p":"DEMO-P1","q":60}]')), null, '{"calculated_quantity":30}'), '[{"row":1,"decision":"approve","quantity":35}]', 'Customer needs it') $q$);
  perform pg_temp.scn('S32 Special case at CFO', $q$ select pg_temp.ap('demo.bud@example.invalid', pg_temp.ap('demo.slm1@example.invalid', pg_temp.be_inp(pg_temp.dm_go(pg_temp.mk('S32 Special case at CFO', 'other', 0, '[{"c":"DEMO-I003","p":"DEMO-P1","q":60}]')), null, '{"calculated_quantity":30}'), '[{"row":1,"decision":"approve","quantity":35}]', 'Customer needs it'), '[{"row":1,"decision":"approve","quantity":35}]') $q$);
  -- ===== Returned lines =====
  perform pg_temp.scn('S33 Returned by Back-End', $q$ select pg_temp.be_ret(pg_temp.dm_go(pg_temp.mk('S33 Back-End returned one line', 'other', 0, '[{"c":"DEMO-I001","p":"DEMO-P1","q":60},{"c":"DEMO-I001","p":"DEMO-P2","q":40}]')), array[1], 'Quantity looks like a typing error, please confirm') $q$);
  perform pg_temp.scn('S34 Returned by SLM', $q$ select pg_temp.ap('demo.slm1@example.invalid', pg_temp.be_inp(pg_temp.dm_go(pg_temp.mk('S34 Second line returned one line', 'other', 0, '[{"c":"DEMO-I001","p":"DEMO-P1","q":60},{"c":"DEMO-I001","p":"DEMO-P2","q":40}]')), null, '{"growth_pct":80}'), '[{"row":1,"decision":"return","reason":"Looks like a typing error"},{"row":2,"decision":"approve"}]', 'Demand confirmed with the field team') $q$);
  perform pg_temp.scn('S35 Returned by BUD', $q$ select pg_temp.ap('demo.bud@example.invalid', pg_temp.ap('demo.slm1@example.invalid', pg_temp.be_inp(pg_temp.dm_go(pg_temp.mk('S35 BUD returned one line', 'other', 0, '[{"c":"DEMO-I001","p":"DEMO-P1","q":60},{"c":"DEMO-I001","p":"DEMO-P2","q":40}]')), null, '{"growth_pct":80}'), '[{"row":1,"decision":"approve"},{"row":2,"decision":"approve"}]', 'Demand confirmed with the field team'), '[{"row":1,"decision":"return","reason":"Please confirm the quantity with the pharmacy"},{"row":2,"decision":"approve"}]') $q$);
  perform pg_temp.scn('S36 Corrected and resubmitted', $q$ select pg_temp.dm_fix(pg_temp.ap('demo.slm1@example.invalid', pg_temp.be_inp(pg_temp.dm_go(pg_temp.mk('S36 Returned line corrected and resubmitted', 'other', 0, '[{"c":"DEMO-I001","p":"DEMO-P1","q":60},{"c":"DEMO-I001","p":"DEMO-P2","q":40}]')), null, '{"growth_pct":80}'), '[{"row":1,"decision":"return","reason":"Looks like a typing error"},{"row":2,"decision":"approve"}]', 'Demand confirmed with the field team'), 1, '{"requested_quantity":55}') $q$);
  perform pg_temp.scn('S37 All lines returned', $q$ select pg_temp.be_ret(pg_temp.dm_go(pg_temp.mk('S37 Whole order returned', 'other', 0, '[{"c":"DEMO-I001","p":"DEMO-P1","q":60},{"c":"DEMO-I001","p":"DEMO-P2","q":40}]')), array[1,2], 'Wrong customer code on the file') $q$);
  perform pg_temp.scn('S38 Back-End changed a quantity', $q$ select pg_temp.be_qty(pg_temp.be_inp(pg_temp.dm_go(pg_temp.mk('S38 Back-End changed a quantity', 'other', 0, '[{"c":"DEMO-I001","p":"DEMO-P1","q":60}]')), null, '{"growth_pct":80}'), 1, 52, 'Stock cover') $q$);
  -- ===== Completed =====
  perform pg_temp.scn('S39 Fully approved', $q$ select pg_temp.ap('demo.cp@example.invalid', pg_temp.ap('demo.cfo@example.invalid', pg_temp.ap('demo.bud@example.invalid', pg_temp.ap('demo.slm1@example.invalid', pg_temp.be_inp(pg_temp.dm_go(pg_temp.mk('S39 Fully approved', 'other', 0, '[{"c":"DEMO-I001","p":"DEMO-P1","q":60},{"c":"DEMO-I001","p":"DEMO-P2","q":40}]')), null, '{"growth_pct":80}'), '[{"row":1,"decision":"approve"},{"row":2,"decision":"approve"}]', 'Demand confirmed with the field team'), '[{"row":1,"decision":"approve"},{"row":2,"decision":"approve"}]'), '[{"row":1,"decision":"approve"}]'), '[{"row":2,"decision":"approve"}]') $q$);
  perform pg_temp.scn('S40 Reduced quantity and one rejected', $q$ select pg_temp.ap('demo.cfo@example.invalid', pg_temp.ap('demo.bud@example.invalid', pg_temp.ap('demo.slm1@example.invalid', pg_temp.be_inp(pg_temp.dm_go(pg_temp.mk('S40 Reduced quantity and one line rejected', 'other', 0, '[{"c":"DEMO-I001","p":"DEMO-P1","q":60},{"c":"DEMO-I001","p":"DEMO-P2","q":40}]')), null, '{"growth_pct":80}'), '[{"row":1,"decision":"approve","quantity":50},{"row":2,"decision":"approve"}]', 'Demand is real'), '[{"row":1,"decision":"approve","quantity":50},{"row":2,"decision":"reject","reason":"Stock is enough"}]'), '[{"row":1,"decision":"approve","quantity":40}]') $q$);
  perform pg_temp.scn('S41 All lines rejected', $q$ select pg_temp.ap('demo.slm1@example.invalid', pg_temp.be_inp(pg_temp.dm_go(pg_temp.mk('S41 All lines rejected', 'other', 0, '[{"c":"DEMO-I001","p":"DEMO-P1","q":60},{"c":"DEMO-I001","p":"DEMO-P2","q":40}]')), null, '{"growth_pct":80}'), '[{"row":1,"decision":"reject","reason":"Demand not supported"},{"row":2,"decision":"reject","reason":"Demand not supported"}]', 'Demand not supported') $q$);
  perform pg_temp.scn('S42 Product C approved by SLM 2', $q$ select pg_temp.ap('demo.slm2@example.invalid', pg_temp.be_inp(pg_temp.dm_go(pg_temp.mk('S42 Product C approved by second line manager 2', 'other', 0, '[{"c":"DEMO-H001","p":"DEMO-P3","q":150}]')), null, '{"growth_pct":80}'), '[{"row":1,"decision":"approve","quantity":120}]', 'Demand confirmed with the field team') $q$);
  perform pg_temp.scn('S43 BUD rejects one line', $q$ select pg_temp.ap('demo.cp@example.invalid', pg_temp.ap('demo.bud@example.invalid', pg_temp.ap('demo.slm1@example.invalid', pg_temp.be_inp(pg_temp.dm_go(pg_temp.mk('S43 BUD rejected one line', 'other', 0, '[{"c":"DEMO-I001","p":"DEMO-P1","q":60},{"c":"DEMO-I001","p":"DEMO-P2","q":40}]')), null, '{"growth_pct":80}'), '[{"row":1,"decision":"approve"},{"row":2,"decision":"approve"}]', 'Demand confirmed with the field team'), '[{"row":1,"decision":"reject","reason":"Above the allowed demand"},{"row":2,"decision":"approve"}]'), '[{"row":2,"decision":"approve"}]') $q$);
  perform pg_temp.scn('S44 Special case closed at 32', $q$ select pg_temp.ap('demo.cfo@example.invalid', pg_temp.ap('demo.bud@example.invalid', pg_temp.ap('demo.slm1@example.invalid', pg_temp.be_inp(pg_temp.dm_go(pg_temp.mk('S44 Special case closed at 32', 'other', 0, '[{"c":"DEMO-I003","p":"DEMO-P1","q":60}]')), null, '{"calculated_quantity":30}'), '[{"row":1,"decision":"approve","quantity":35}]', 'Customer needs it'), '[{"row":1,"decision":"approve","quantity":35}]'), '[{"row":1,"decision":"approve","quantity":32}]') $q$);
  -- ===== Ageing =====
  perform pg_temp.scn('S45 Ageing orange (24 h+)', $q$ select pg_temp.back(pg_temp.be_inp(pg_temp.dm_go(pg_temp.mk('S45 Ageing orange at second line', 'other', 0, '[{"c":"DEMO-I001","p":"DEMO-P1","q":60}]')), null, '{"growth_pct":80}'), 26) $q$);
  perform pg_temp.scn('S46 Ageing overdue (48 h+)', $q$ select pg_temp.back(pg_temp.ap('demo.slm1@example.invalid', pg_temp.be_inp(pg_temp.dm_go(pg_temp.mk('S46 Ageing overdue at BUD', 'other', 0, '[{"c":"DEMO-I001","p":"DEMO-P1","q":60},{"c":"DEMO-I001","p":"DEMO-P2","q":40}]')), null, '{"growth_pct":80}'), '[{"row":1,"decision":"approve"},{"row":2,"decision":"approve"}]', 'Demand confirmed with the field team'), 50) $q$);
  perform pg_temp.scn('S47 Ageing red (72 h+)', $q$ select pg_temp.back(pg_temp.dm_go(pg_temp.mk('S47 Ageing red waiting for Back-End', 'other', 0, '[{"c":"DEMO-I001","p":"DEMO-P1","q":60}]')), 75) $q$);
  -- ===== Two second line managers on one order =====
  perform pg_temp.scn('S48 Two SLMs on one order', $q$ select pg_temp.be_inp(pg_temp.dm_go(pg_temp.mk('S48 Two second line managers', 'other', 0, '[{"c":"DEMO-H001","p":"DEMO-P1","q":250},{"c":"DEMO-H001","p":"DEMO-P3","q":150}]')), null, '{"growth_pct":80}') $q$);

  select string_agg(l.code || ' | #' || coalesce(o.order_no::text, '-') || ' | ' || l.note, E'\n' order by l.code) into rep from scn_log l left join public.orders o on o.id = l.order_id;
  if dry then raise exception E'\n===== DRY RUN (rolled back) =====\n%', rep; end if;
end $$;
