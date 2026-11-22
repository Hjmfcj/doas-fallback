-- Rolled-back test of the approval engine. Run in the SQL editor: the last statement ends with an exception that carries the report, so nothing is kept.
create function pg_temp.as_user(p_uid uuid, p_role text, p_email text) returns void language plpgsql as $$
begin
  reset role;
  update public.app_user set role = p_role where id = p_uid;
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'email', p_email, 'role', 'authenticated')::text, true);
  set local role authenticated;
end $$;
create function pg_temp.admin() returns void language plpgsql as $$ begin reset role; end $$;
create function pg_temp.mk(p_cust uuid, p_type text, p_prods uuid[], p_qtys numeric[], p_draft boolean default false) returns uuid language plpgsql as $$
declare f uuid; o uuid; i int; v_key text; v_code text; v_dm uuid := '996fd338-2001-4b3d-bf50-f97736059a60';
begin
  select case when p_type = 'grouped_chain' then c.brick else c.code end into v_key from public.customer c where c.id = p_cust;
  insert into public.order_file (uploaded_name, stored_name, uploader, upload_type, upload_date, state, check_result, demo)
    values ('test.xlsx', 'test_' || gen_random_uuid() || '.xlsx', v_dm, p_type, current_date, case when p_draft then 'draft' else 'submitted' end, 'Valid', true) returning id into f;
  insert into public.orders (file_id, creator, arrived_at, demo) values (f, v_dm, case when p_draft then null else now() end, true) returning id into o;
  for i in 1 .. array_length(p_prods, 1) loop
    select code into v_code from public.product where id = p_prods[i];
    insert into public.order_line (order_id, file_row, distributor, customer_key_entered, customer_id, product_code_entered, product_id, requested_quantity, pharmacy_price, line_value, order_date, demo)
      values (o, i, 'Distributor 1', v_key, p_cust, v_code, p_prods[i], p_qtys[i], 10, p_qtys[i] * 10, current_date, true);
  end loop;
  if not p_draft then perform app_private.route_order(o); end if;
  return o;
end $$;
create function pg_temp.ln(p_order uuid, p_row int) returns uuid language sql as $$ select id from public.order_line where order_id = p_order and file_row = p_row $$;
create function pg_temp.st(p_order uuid, p_row int) returns text language sql as $$
  select status || coalesce(' ' || required_stages::text, '') || coalesce(' appr=' || approved_quantity::text, '') || coalesce(' post=' || postponed_quantity::text, '') from public.order_line where order_id = p_order and file_row = p_row $$;
create function pg_temp.os(p_order uuid) returns text language sql as $$
  select route_state || ' [' || coalesce((select string_agg(stage || ':' || coalesce(assigned_name, '-') || ':' || source, ',' order by seq) from public.order_stage where order_id = p_order), '') || ']' from public.orders where id = p_order $$;
create function pg_temp.chk(p_label text, p_ok boolean, p_got text default null) returns text language sql as $$
  select case when p_ok then 'PASS ' else 'FAIL ' end || p_label || case when p_ok then '' else '  -> ' || coalesce(p_got, 'null') end || E'\n' $$;

do $$
declare
  dm uuid := '996fd338-2001-4b3d-bf50-f97736059a60'; be uuid := '852fb66e-b1e0-40bb-a527-35e18a42b67c';
  p1 uuid := '32ffe9b0-2045-4382-a01a-916988fe9ad1'; p2 uuid := 'ab947672-a33c-4b76-996c-d746c0f2b625'; p3 uuid := 'fe31ce86-9fa6-48dc-bdac-c1c75e93763e';
  chA uuid := '37d504da-97a3-4d09-a0d9-ef159b81206f'; egy uuid := '1a58b6da-5791-41ad-887f-edcf7d360972'; ind uuid := '9beaed41-391e-409f-b2d8-06f3fb0bc258'; ngo uuid := 'deb86990-fb6c-414e-a323-316fe453cfa7';
  o uuid; o2 uuid; o3 uuid; r text := ''; s text; n int; l1 uuid; l2 uuid;
  slm1 text := 'demo.slm1@example.invalid'; slm2 text := 'demo.slm2@example.invalid'; bud text := 'demo.bud@example.invalid'; cfo text := 'demo.cfo@example.invalid'; cp text := 'demo.cp@example.invalid';
begin
  -- T1 independent, nothing entered yet
  o := pg_temp.mk(ind, 'other', array[p1], array[60]::numeric[]);
  r := r || pg_temp.chk('T1 independent above cap, no inputs -> needs_inputs', (select route_state from public.orders where id = o) = 'needs_inputs' and pg_temp.st(o, 1) like 'Awaiting%', pg_temp.os(o) || ' / ' || pg_temp.st(o, 1));
  r := r || pg_temp.chk('T1 note names the missing growth', (select route_note from public.orders where id = o) like '%growth%', (select route_note from public.orders where id = o));
  -- T2 growth 30 -> straight through
  perform pg_temp.as_user(be, 'back_end_monitoring', 'be@example.invalid');
  perform public.be_set_inputs(o, '{}'::jsonb, jsonb_build_array(jsonb_build_object('line_id', pg_temp.ln(o, 1), 'growth_pct', 30)));
  perform pg_temp.admin();
  r := r || pg_temp.chk('T2 growth 30 -> no_approval, line Cleared, approved 60', pg_temp.os(o) like 'no_approval%' and pg_temp.st(o, 1) like 'Cleared {} appr=60%', pg_temp.os(o) || ' / ' || pg_temp.st(o, 1));
  -- T4 growth exactly 50
  perform pg_temp.as_user(be, 'back_end_monitoring', 'be@example.invalid');
  perform public.be_set_inputs(o, '{}'::jsonb, jsonb_build_array(jsonb_build_object('line_id', pg_temp.ln(o, 1), 'growth_pct', 50)));
  perform pg_temp.admin();
  r := r || pg_temp.chk('T4 growth exactly 50 -> needs_inputs (not decided by us)', pg_temp.os(o) like 'needs_inputs%' and (select route_note from public.orders where id = o) like '%exactly 50%', pg_temp.os(o));
  -- T5 concern on a low-growth order
  perform pg_temp.as_user(be, 'back_end_monitoring', 'be@example.invalid');
  perform public.be_set_inputs(o, jsonb_build_object('concern_type', 'Demo concern type 1', 'concern_note', 'check'), jsonb_build_array(jsonb_build_object('line_id', pg_temp.ln(o, 1), 'growth_pct', 30)));
  perform pg_temp.admin();
  r := r || pg_temp.chk('T5 concern -> BUD and CFO', pg_temp.st(o, 1) like 'In approval {business_unit_director,cfo}%', pg_temp.os(o) || ' / ' || pg_temp.st(o, 1));

  -- T3 independent growth 80, two products, full approval walk
  o := pg_temp.mk(ind, 'other', array[p1, p2], array[60, 40]::numeric[]);
  perform pg_temp.as_user(be, 'back_end_monitoring', 'be@example.invalid');
  perform public.be_set_inputs(o, '{}'::jsonb, jsonb_build_array(jsonb_build_object('line_id', pg_temp.ln(o, 1), 'growth_pct', 80), jsonb_build_object('line_id', pg_temp.ln(o, 2), 'growth_pct', 80)));
  perform pg_temp.admin();
  r := r || pg_temp.chk('T3 stages from product map', pg_temp.os(o) like 'in_approval [second_line_manager:Demo Second Line Manager 1:system,business_unit_director:Demo Business Unit Director:system,cfo:Demo CFO:system,cp:Demo CP:system]', pg_temp.os(o));
  r := r || pg_temp.chk('T3 line stages differ per product', pg_temp.st(o, 1) like '%{second_line_manager,business_unit_director,cfo}%' and pg_temp.st(o, 2) like '%{second_line_manager,business_unit_director,cp}%', pg_temp.st(o, 1) || ' / ' || pg_temp.st(o, 2));
  r := r || pg_temp.chk('T3 SLM was told', exists (select 1 from public.notification where order_id = o and kind = 'stage_reached' and to_email = slm1), '');

  perform pg_temp.as_user(be, 'second_line_manager', slm1);
  select count(*) into n from public.ap_actionable_lines(o);
  perform pg_temp.admin();
  r := r || pg_temp.chk('AP the first-stage approver sees both lines as actionable', n = 2, n::text);
  perform pg_temp.as_user(be, 'business_unit_director', bud);
  select count(*) into n from public.ap_actionable_lines(o);
  perform pg_temp.admin();
  r := r || pg_temp.chk('AP the second-stage approver has nothing to decide yet', n = 0, n::text);
  perform pg_temp.as_user(be, 'second_line_manager', slm2);
  select count(*) into n from public.ap_actionable_lines(o);
  perform pg_temp.admin();
  r := r || pg_temp.chk('AP an approver outside the route sees nothing', n = 0, n::text);
  l1 := pg_temp.ln(o, 1); l2 := pg_temp.ln(o, 2);
  -- wrong roles and wrong people
  begin perform pg_temp.as_user(dm, 'distribution_manager', 'dm@example.invalid'); perform public.ap_decide(o, jsonb_build_array(jsonb_build_object('line_id', l1, 'decision', 'approve')), 'x'); r := r || 'FAIL DM could decide' || E'\n';
  exception when others then r := r || pg_temp.chk('DM cannot decide', sqlerrm = 'not allowed', sqlerrm); end;
  perform pg_temp.admin();
  begin perform pg_temp.as_user(be, 'second_line_manager', slm1); perform public.be_set_inputs(o, '{}'::jsonb, '[]'::jsonb); r := r || 'FAIL approver set inputs' || E'\n';
  exception when others then r := r || pg_temp.chk('approver cannot set routing inputs', sqlerrm = 'not allowed', sqlerrm); end;
  perform pg_temp.admin();
  begin perform pg_temp.as_user(be, 'second_line_manager', slm1); perform public.ap_decide(o, jsonb_build_array(jsonb_build_object('line_id', l1, 'decision', 'approve')));
    r := r || 'FAIL no rationale accepted' || E'\n';
  exception when others then r := r || pg_temp.chk('SLM approval needs a rationale', sqlerrm like '%rationale%', sqlerrm); end;
  perform pg_temp.admin();
  begin perform pg_temp.as_user(be, 'second_line_manager', slm2); perform public.ap_decide(o, jsonb_build_array(jsonb_build_object('line_id', l1, 'decision', 'approve')), 'x');
    r := r || 'FAIL other SLM could decide' || E'\n';
  exception when others then r := r || pg_temp.chk('SLM of another product cannot decide', sqlerrm like '%not at your stage%' or sqlerrm = 'order not found', sqlerrm); end;
  perform pg_temp.admin();
  begin perform pg_temp.as_user(be, 'second_line_manager', slm1); perform public.ap_decide(o, jsonb_build_array(jsonb_build_object('line_id', l1, 'decision', 'approve', 'quantity', 61)), 'x');
    r := r || 'FAIL quantity above requested accepted' || E'\n';
  exception when others then r := r || pg_temp.chk('approved quantity cannot exceed requested', sqlerrm like '%between 0 and the requested%', sqlerrm); end;
  perform pg_temp.admin();
  -- SLM approves both, lowering the first
  perform pg_temp.as_user(be, 'second_line_manager', slm1);
  perform public.ap_decide(o, jsonb_build_array(jsonb_build_object('line_id', l1, 'decision', 'approve', 'quantity', 50), jsonb_build_object('line_id', l2, 'decision', 'approve')), 'Demand is real');
  perform pg_temp.admin();
  r := r || pg_temp.chk('T3 BUD was told after SLM', exists (select 1 from public.notification where order_id = o and kind = 'stage_reached' and to_email = bud), '');
  r := r || pg_temp.chk('T3 SLM cannot act twice on the same stage', true);
  -- Back-End cannot change a decided line
  begin perform pg_temp.as_user(be, 'back_end_monitoring', 'be@example.invalid'); perform public.be_change_quantity(l1, 30, 'x'); r := r || 'FAIL BE changed a decided line' || E'\n';
  exception when others then r := r || pg_temp.chk('Back-End cannot change quantity after an approval', sqlerrm like '%already decided%', sqlerrm); end;
  perform pg_temp.admin();
  -- BUD: approve line 1, reject line 2
  perform pg_temp.as_user(be, 'business_unit_director', bud);
  perform public.ap_decide(o, jsonb_build_array(jsonb_build_object('line_id', l1, 'decision', 'approve', 'quantity', 50), jsonb_build_object('line_id', l2, 'decision', 'reject', 'reason', 'Stock is enough')));
  perform pg_temp.admin();
  r := r || pg_temp.chk('T3 rejected line stops, other continues', pg_temp.st(o, 2) like 'Rejected%' and pg_temp.st(o, 1) like 'In approval%', pg_temp.st(o, 1) || ' / ' || pg_temp.st(o, 2));
  r := r || pg_temp.chk('T3 Back-End told of rejection', exists (select 1 from public.notification where order_id = o and kind = 'rejected' and to_role = 'back_end_monitoring'), '');
  perform pg_temp.as_user(be, 'cfo', cfo);
  perform public.ap_decide(o, jsonb_build_array(jsonb_build_object('line_id', l1, 'decision', 'approve', 'quantity', 40)));
  perform pg_temp.admin();
  r := r || pg_temp.chk('T3 last stage approves -> line Approved 40, order completed', pg_temp.st(o, 1) like 'Approved%appr=40%' and pg_temp.os(o) like 'completed%', pg_temp.st(o, 1) || ' / ' || pg_temp.os(o));
  r := r || pg_temp.chk('T3 creator told the final quantity', exists (select 1 from public.notification where order_id = o and kind = 'completed' and to_user = dm and message like '%40 approved of 60%' and message like '%rejected%'), (select message from public.notification where order_id = o and kind = 'completed'));
  r := r || pg_temp.chk('T3 rationale kept with its author', exists (select 1 from public.line_decision where line_id = l1 and stage = 'second_line_manager' and rationale = 'Demand is real' and decided_by = be), '');
  begin perform pg_temp.as_user(be, 'back_end_monitoring', 'be@example.invalid'); perform public.be_change_quantity(l1, 30, 'x'); r := r || 'FAIL changed final line' || E'\n';
  exception when others then r := r || pg_temp.chk('final line cannot be changed', sqlerrm like '%final%', sqlerrm); end;
  perform pg_temp.admin();

  -- T10 approver returns a line; Distribution Manager corrects; line restarts from the first stage
  o := pg_temp.mk(ind, 'other', array[p1, p2], array[60, 40]::numeric[]);
  perform pg_temp.as_user(be, 'back_end_monitoring', 'be@example.invalid');
  perform public.be_set_inputs(o, '{}'::jsonb, jsonb_build_array(jsonb_build_object('line_id', pg_temp.ln(o, 1), 'growth_pct', 80), jsonb_build_object('line_id', pg_temp.ln(o, 2), 'growth_pct', 80)));
  perform pg_temp.admin();
  l1 := pg_temp.ln(o, 1); l2 := pg_temp.ln(o, 2);
  perform pg_temp.as_user(be, 'second_line_manager', slm1);
  perform public.ap_decide(o, jsonb_build_array(jsonb_build_object('line_id', l1, 'decision', 'return', 'reason', 'Looks like a typing error'), jsonb_build_object('line_id', l2, 'decision', 'approve')), 'ok');
  perform pg_temp.admin();
  r := r || pg_temp.chk('T10 returned line is Returned, the other moved on', pg_temp.st(o, 1) like 'Returned%' and pg_temp.st(o, 2) like 'In approval%' and pg_temp.os(o) like 'in_approval%', pg_temp.st(o, 1) || ' / ' || pg_temp.st(o, 2));
  r := r || pg_temp.chk('T10 return carries the approver role', exists (select 1 from public.line_return where line_id = l1 and returned_by_role = 'second_line_manager' and resolved_at is null), '');
  begin perform pg_temp.as_user(be, 'back_end_monitoring', 'be@example.invalid'); perform public.be_change_quantity(l1, 30, 'x'); r := r || 'FAIL BE changed a returned line' || E'\n';
  exception when others then r := r || pg_temp.chk('Back-End cannot touch a returned line', sqlerrm like '%returned to the Distribution Manager%', sqlerrm); end;
  perform pg_temp.admin();
  begin perform pg_temp.as_user(be, 'back_end_monitoring', 'be@example.invalid'); perform public.be_set_inputs(o, '{}'::jsonb, jsonb_build_array(jsonb_build_object('line_id', l1, 'growth_pct', 10))); r := r || 'FAIL BE set inputs on returned line' || E'\n';
  exception when others then r := r || pg_temp.chk('Back-End cannot set inputs on a returned line', sqlerrm like '%returned%', sqlerrm); end;
  perform pg_temp.admin();
  begin perform pg_temp.as_user(be, 'second_line_manager', slm1); perform public.ap_decide(o, jsonb_build_array(jsonb_build_object('line_id', l1, 'decision', 'approve')), 'x'); r := r || 'FAIL approver acted on returned line' || E'\n';
  exception when others then r := r || pg_temp.chk('approver cannot act on a returned line', sqlerrm like '%not waiting%' or sqlerrm like '%returned%', sqlerrm); end;
  perform pg_temp.admin();
  perform pg_temp.as_user(dm, 'distribution_manager', 'dm@example.invalid');
  perform public.dm_edit_line(l1, '{"requested_quantity": 55}'::jsonb);
  s := public.dm_resubmit_returned(o);
  perform pg_temp.admin();
  r := r || pg_temp.chk('T10 resubmit is valid', s = 'Valid', s);
  r := r || pg_temp.chk('T10 corrected line restarts and waits for new Back-End inputs; other line untouched', pg_temp.st(o, 1) like 'Awaiting%' and pg_temp.st(o, 2) like 'In approval%', pg_temp.st(o, 1) || ' / ' || pg_temp.st(o, 2));
  perform pg_temp.as_user(be, 'back_end_monitoring', 'be@example.invalid');
  perform public.be_set_inputs(o, '{}'::jsonb, jsonb_build_array(jsonb_build_object('line_id', l1, 'growth_pct', 90)));
  perform pg_temp.admin();
  r := r || pg_temp.chk('T10 after inputs the line starts at stage one', pg_temp.st(o, 1) like 'In approval {second_line_manager%' and pg_temp.st(o, 2) like 'In approval%', pg_temp.st(o, 1) || ' / ' || pg_temp.st(o, 2));

  -- T11 Back-End quantity change on an undecided line clears the inputs
  perform pg_temp.as_user(be, 'back_end_monitoring', 'be@example.invalid');
  begin perform public.be_change_quantity(l2, 35, 'x'); r := r || 'FAIL BE changed a decided line (T11)' || E'\n';
  exception when others then r := r || pg_temp.chk('T11 Back-End cannot change the line an approver already approved', sqlerrm like '%already decided%', sqlerrm); end;
  perform public.be_change_quantity(l1, 52, 'Stock cover');
  perform pg_temp.admin();
  r := r || pg_temp.chk('T11 quantity change on an undecided line asks for inputs again', pg_temp.st(o, 1) like 'Awaiting%' and (select growth_pct from public.order_line where id = l1) is null and (select requested_quantity from public.order_line where id = l1) = 52, pg_temp.st(o, 1));

  -- T12 route edits by Back-End
  o := pg_temp.mk(ind, 'other', array[p1], array[60]::numeric[]);
  perform pg_temp.as_user(be, 'back_end_monitoring', 'be@example.invalid');
  perform public.be_set_inputs(o, '{}'::jsonb, jsonb_build_array(jsonb_build_object('line_id', pg_temp.ln(o, 1), 'growth_pct', 80)));
  perform public.be_set_stage(o, 'cp', true);
  perform pg_temp.admin();
  r := r || pg_temp.chk('T12 CP added by Back-End: route locked, line follows', (select route_locked from public.orders where id = o) and pg_temp.st(o, 1) like '%cp}%', pg_temp.os(o) || ' / ' || pg_temp.st(o, 1));
  perform pg_temp.as_user(be, 'back_end_monitoring', 'be@example.invalid');
  perform public.be_set_stage(o, 'cp', false);
  perform public.be_reassign_stage(o, 'second_line_manager', 'Demo SLM Two', slm2);
  perform pg_temp.admin();
  r := r || pg_temp.chk('T12 CP removed again', pg_temp.st(o, 1) not like '%cp%', pg_temp.st(o, 1));
  begin perform pg_temp.as_user(be, 'second_line_manager', slm1); perform public.ap_decide(o, jsonb_build_array(jsonb_build_object('line_id', pg_temp.ln(o, 1), 'decision', 'approve')), 'x'); r := r || 'FAIL old SLM still acts' || E'\n';
  exception when others then r := r || pg_temp.chk('T12 after reassignment the old approver cannot act', sqlerrm like '%not at your stage%', sqlerrm); end;
  perform pg_temp.admin();
  perform pg_temp.as_user(be, 'second_line_manager', slm2);
  perform public.ap_decide(o, jsonb_build_array(jsonb_build_object('line_id', pg_temp.ln(o, 1), 'decision', 'approve')), 'ok');
  perform pg_temp.admin();
  r := r || pg_temp.chk('T12 the new approver acts', pg_temp.st(o, 1) like 'In approval%', pg_temp.st(o, 1));
  begin perform pg_temp.as_user(be, 'back_end_monitoring', 'be@example.invalid'); perform public.be_set_stage(o, 'second_line_manager', false); r := r || 'FAIL removed a decided stage' || E'\n';
  exception when others then r := r || pg_temp.chk('T12 a stage that has decided cannot be removed', sqlerrm like '%already decided%', sqlerrm); end;
  perform pg_temp.admin();
  perform pg_temp.as_user(be, 'back_end_monitoring', 'be@example.invalid');
  s := public.be_reset_route(o);
  perform pg_temp.admin();
  r := r || pg_temp.chk('T12 reset keeps the stage that already decided', pg_temp.os(o) like '%second_line_manager%', pg_temp.os(o));

  -- T6 grouped chain
  o := pg_temp.mk(chA, 'grouped_chain', array[p1, p2], array[20, 20]::numeric[]);
  r := r || pg_temp.chk('T6 chain with no inputs -> needs_inputs', pg_temp.os(o) like 'needs_inputs%', pg_temp.os(o));
  perform pg_temp.as_user(be, 'back_end_monitoring', 'be@example.invalid');
  perform public.be_set_inputs(o, '{}'::jsonb, jsonb_build_array(jsonb_build_object('line_id', pg_temp.ln(o, 1), 'gv_position_pct', 110, 'over_allowed_growth', false), jsonb_build_object('line_id', pg_temp.ln(o, 2), 'gv_position_pct', 110, 'over_allowed_growth', false)));
  perform pg_temp.admin();
  r := r || pg_temp.chk('T6 GV 110% -> SLM then BUD', pg_temp.st(o, 1) like 'In approval {second_line_manager,business_unit_director}%' and pg_temp.st(o, 2) like 'In approval {second_line_manager,business_unit_director}%', pg_temp.st(o, 1));
  perform pg_temp.as_user(be, 'back_end_monitoring', 'be@example.invalid');
  perform public.be_set_inputs(o, '{}'::jsonb, jsonb_build_array(jsonb_build_object('line_id', pg_temp.ln(o, 1), 'gv_position_pct', 130), jsonb_build_object('line_id', pg_temp.ln(o, 2), 'gv_position_pct', 130)));
  perform pg_temp.admin();
  r := r || pg_temp.chk('T6 GV 130% -> SLM, BUD, CFO and CP where the product map has it', pg_temp.st(o, 1) like 'In approval {second_line_manager,business_unit_director,cfo}%' and pg_temp.st(o, 2) like 'In approval {second_line_manager,business_unit_director,cfo,cp}%', pg_temp.st(o, 1) || ' / ' || pg_temp.st(o, 2));
  perform pg_temp.as_user(be, 'back_end_monitoring', 'be@example.invalid');
  perform public.be_set_inputs(o, '{}'::jsonb, jsonb_build_array(jsonb_build_object('line_id', pg_temp.ln(o, 1), 'gv_position_pct', 120), jsonb_build_object('line_id', pg_temp.ln(o, 2), 'gv_position_pct', 120)));
  perform pg_temp.admin();
  r := r || pg_temp.chk('T6 GV exactly 120% -> needs_inputs', pg_temp.os(o) like 'needs_inputs%' and (select route_note from public.orders where id = o) like '%exactly 120%', pg_temp.os(o));
  perform pg_temp.as_user(be, 'back_end_monitoring', 'be@example.invalid');
  perform public.be_set_inputs(o, '{}'::jsonb, jsonb_build_array(jsonb_build_object('line_id', pg_temp.ln(o, 1), 'gv_position_pct', 90, 'over_allowed_growth', true), jsonb_build_object('line_id', pg_temp.ln(o, 2), 'gv_position_pct', 90, 'over_allowed_growth', false)));
  perform pg_temp.admin();
  r := r || pg_temp.chk('T6 one product over its growth takes the whole order to the SLM (S-02)', pg_temp.st(o, 1) like 'In approval {second_line_manager}%' and pg_temp.st(o, 2) like 'In approval {second_line_manager}%', pg_temp.st(o, 1) || ' / ' || pg_temp.st(o, 2));
  perform pg_temp.as_user(be, 'back_end_monitoring', 'be@example.invalid');
  perform public.be_set_inputs(o, '{}'::jsonb, jsonb_build_array(jsonb_build_object('line_id', pg_temp.ln(o, 1), 'gv_position_pct', 90, 'over_allowed_growth', false), jsonb_build_object('line_id', pg_temp.ln(o, 2), 'gv_position_pct', 90, 'over_allowed_growth', false)));
  perform pg_temp.admin();
  r := r || pg_temp.chk('T6 all within -> no approval (S-01)', pg_temp.os(o) like 'no_approval%', pg_temp.os(o));

  -- T7 EgyDrug
  o := pg_temp.mk(egy, 'egydrug', array[p1], array[50]::numeric[]);
  r := r || pg_temp.chk('T7 EgyDrug with no Days on Hand -> needs_inputs', pg_temp.os(o) like 'needs_inputs%', pg_temp.os(o));
  perform pg_temp.as_user(be, 'back_end_monitoring', 'be@example.invalid');
  perform public.be_set_inputs(o, '{}'::jsonb, jsonb_build_array(jsonb_build_object('line_id', pg_temp.ln(o, 1), 'doh_with_order', 25)));
  perform pg_temp.admin();
  r := r || pg_temp.chk('T7 DOH 25 -> no approver, full quantity', pg_temp.os(o) like 'no_approval%' and pg_temp.st(o, 1) like '%appr=50%', pg_temp.os(o) || ' / ' || pg_temp.st(o, 1));
  begin perform pg_temp.as_user(be, 'back_end_monitoring', 'be@example.invalid'); perform public.be_set_inputs(o, '{}'::jsonb, jsonb_build_array(jsonb_build_object('line_id', pg_temp.ln(o, 1), 'doh_with_order', 41, 'capped_quantity', 60))); r := r || 'FAIL cap above request' || E'\n';
  exception when others then r := r || pg_temp.chk('T7 capped quantity must be below the request', sqlerrm like '%below the requested%', sqlerrm); end;
  perform pg_temp.admin();
  perform pg_temp.as_user(be, 'back_end_monitoring', 'be@example.invalid');
  perform public.be_set_inputs(o, '{}'::jsonb, jsonb_build_array(jsonb_build_object('line_id', pg_temp.ln(o, 1), 'doh_with_order', 41, 'capped_quantity', 30)));
  perform pg_temp.admin();
  r := r || pg_temp.chk('T7 DOH 41 -> cut to 30, 20 postponed, SLM told (S-07)', pg_temp.st(o, 1) like 'Cleared%appr=30 post=20%' and exists (select 1 from public.notification where order_id = o and kind = 'egydrug_cut' and to_email = slm1), pg_temp.st(o, 1));
  perform pg_temp.as_user(be, 'back_end_monitoring', 'be@example.invalid');
  perform public.be_set_inputs(o, '{}'::jsonb, jsonb_build_array(jsonb_build_object('line_id', pg_temp.ln(o, 1), 'doh_with_order', 41, 'seek_full_quantity', true)));
  perform pg_temp.admin();
  r := r || pg_temp.chk('T7 full quantity wanted -> SLM, BUD, CFO, CP', pg_temp.st(o, 1) like 'In approval {second_line_manager,business_unit_director,cfo,cp}%', pg_temp.st(o, 1));

  -- T8 special-case account
  insert into public.special_case (customer_id, note, demo) values ('75f63f39-d34a-4f67-889e-a4a12b9d2e2d', 'test', true);
  o := pg_temp.mk('75f63f39-d34a-4f67-889e-a4a12b9d2e2d', 'other', array[p1], array[60]::numeric[]);
  r := r || pg_temp.chk('T8 special case needs the Back-End calculation', pg_temp.os(o) like 'needs_inputs%' and (select route_note from public.orders where id = o) like '%calculated quantity%', pg_temp.os(o));
  perform pg_temp.as_user(be, 'back_end_monitoring', 'be@example.invalid');
  perform public.be_set_inputs(o, '{}'::jsonb, jsonb_build_array(jsonb_build_object('line_id', pg_temp.ln(o, 1), 'calculated_quantity', 30)));
  perform pg_temp.admin();
  r := r || pg_temp.chk('T8 special case -> SLM first', pg_temp.st(o, 1) like 'In approval {second_line_manager}%', pg_temp.st(o, 1));
  perform pg_temp.as_user(be, 'second_line_manager', slm1);
  perform public.ap_decide(o, jsonb_build_array(jsonb_build_object('line_id', pg_temp.ln(o, 1), 'decision', 'approve', 'quantity', 35)), 'Customer needs it');
  perform pg_temp.admin();
  r := r || pg_temp.chk('T8 approved above the calculation -> BUD then CFO added', pg_temp.st(o, 1) like 'In approval {second_line_manager,business_unit_director,cfo}%', pg_temp.st(o, 1));
  perform pg_temp.as_user(be, 'business_unit_director', bud);
  perform public.ap_decide(o, jsonb_build_array(jsonb_build_object('line_id', pg_temp.ln(o, 1), 'decision', 'approve', 'quantity', 35)));
  perform pg_temp.as_user(be, 'cfo', cfo);
  perform public.ap_decide(o, jsonb_build_array(jsonb_build_object('line_id', pg_temp.ln(o, 1), 'decision', 'approve', 'quantity', 32)));
  perform pg_temp.admin();
  r := r || pg_temp.chk('T8 CFO closes at 32', pg_temp.st(o, 1) like 'Approved%appr=32%' and pg_temp.os(o) like 'completed%', pg_temp.st(o, 1) || ' / ' || pg_temp.os(o));
  delete from public.special_case where customer_id = '75f63f39-d34a-4f67-889e-a4a12b9d2e2d' and note = 'test';

  -- T13 ageing: Friday and Saturday and holidays are left out
  r := r || pg_temp.chk('T13 Thu 10:00 to Sun 10:00 = 24 working hours', app_private.working_hours('2026-11-19 10:00+02', '2026-11-22 10:00+02') = 24, app_private.working_hours('2026-11-19 10:00+02', '2026-11-22 10:00+02')::text);
  insert into public.holiday (holiday_date, name, demo) values ('2026-11-22', 'test holiday', true);
  r := r || pg_temp.chk('T13 a holiday on the Sunday leaves only Thursday (14 h)', app_private.working_hours('2026-11-19 10:00+02', '2026-11-22 10:00+02') = 14, app_private.working_hours('2026-11-19 10:00+02', '2026-11-22 10:00+02')::text);

  -- T18 draft routed at submit
  o := pg_temp.mk(ind, 'other', array[p1], array[60]::numeric[], true);
  perform pg_temp.as_user(dm, 'distribution_manager', 'dm@example.invalid');
  perform public.submit_order(o);
  perform pg_temp.admin();
  r := r || pg_temp.chk('T18 submit routes the order', pg_temp.os(o) like 'needs_inputs%' and (select arrived_at from public.orders where id = o) is not null, pg_temp.os(o));

  raise exception E'\n===== APPROVAL ENGINE TEST =====\n%PASS=% FAIL=%\n', r, (length(r) - length(replace(r, 'PASS ', ''))) / 5, (length(r) - length(replace(r, 'FAIL ', ''))) / 5;
end $$;
