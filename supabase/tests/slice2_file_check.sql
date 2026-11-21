-- Slice 1 file check tests (V-01, V-04, V-05, V-06, V-08, V-12). Run in one transaction that always rolls back:
-- success ends with the exception 'TESTS_PASSED n'; any failure ends with 'FAILED: ...'. Uses its own T2- codes, so it can run beside the demo seed.
do $$
declare
  dm1 uuid := gen_random_uuid(); dm2 uuid := gen_random_uuid();
  p1 uuid; p2 uuid; c_ph uuid; c_ngo uuid; c_bl uuid; c_ch uuid;
  f1 uuid; o1 uuid; f2 uuid; o2 uuid; f3 uuid; o3 uuid;
  res text; n int; m text; d date; passed int := 0;
begin
  insert into auth.users (id, email) values (dm1,'t2dm1@test.invalid'),(dm2,'t2dm2@test.invalid');
  insert into public.app_user (id, display_name, role, demo) values
    (dm1,'T2 DM1','distribution_manager',true),(dm2,'T2 DM2','distribution_manager',true);
  insert into public.product (code,name,demo) values ('T2-P1','T2 product 1',true) returning id into p1;
  insert into public.product (code,name,demo) values ('T2-P2','T2 product 2',true) returning id into p2;
  insert into public.customer (code,name,customer_type,demo) values ('T2-PH','T2 pharmacy','independent_pharmacy',true) returning id into c_ph;
  insert into public.customer (code,name,customer_type,demo) values ('T2-NGO','T2 ngo','ngo',true) returning id into c_ngo;
  insert into public.customer (code,name,customer_type,demo) values ('T2-BL','T2 stopped pharmacy','independent_pharmacy',true) returning id into c_bl;
  insert into public.customer (brick,name,customer_type,demo) values ('T2-BRICK','T2 chain','grouped_chain',true) returning id into c_ch;
  insert into public.cap (product_id, customer_type, cap_quantity, no_capping, demo) values
    (p1,'independent_pharmacy',50,false,true),(p2,'independent_pharmacy',null,true,true);
  insert into public.blacklist (customer_id, customer_name, demo) values (c_bl,'T2 stopped pharmacy',true);

  perform set_config('request.jwt.claims', json_build_object('sub',dm1,'role','authenticated')::text, true);
  set local role authenticated;

  -- File 1 (other): one line per rule
  insert into public.order_file (uploaded_name, stored_name, uploader, upload_type, demo) values ('t2a.xlsx','t2a_20261121.xlsx',dm1,'other',true) returning id into f1;
  insert into public.orders (file_id, creator, demo) values (f1, dm1, true) returning id into o1;
  insert into public.order_line (order_id, file_row, distributor, customer_key_entered, product_code_entered, requested_quantity, earlier_orders_quantity, order_date, demo) values
    (o1,1,'D1','NOPE'  ,'T2-P1',10,   null,current_date,true),
    (o1,2,'D1','T2-PH' ,'T2-P1',0,    null,current_date,true),
    (o1,3,'D1','T2-PH' ,'T2-P1',60,   null,current_date,true),
    (o1,4,'D2','T2-PH' ,'T2-P1',40,   15,  current_date,true),
    (o1,5,'D3','T2-PH' ,'T2-P1',50,   null,current_date,true),
    (o1,6,'D1','T2-PH' ,'T2-P2',9999, null,current_date,true),
    (o1,7,'D1','T2-NGO','T2-P1',9999, null,current_date,true),
    (o1,8,'D1','T2-BL' ,'T2-P1',5,    null,null,        true),
    (o1,9,'D1','T2-BL' ,'T2-P2',5,    null,current_date,true);
  res := public.run_file_check(o1);
  if res <> 'Has Errors' then raise exception 'FAILED T1 result %', res; end if; passed := passed + 1;

  select count(*) into n from public.line_issue i join public.order_line l on l.id = i.line_id where l.order_id = o1 and i.rule_id = 'V-01';
  if n <> 1 then raise exception 'FAILED T2 V-01 count %', n; end if;
  select count(*) into n from public.line_issue i join public.order_line l on l.id = i.line_id where l.order_id = o1 and i.rule_id = 'V-01' and l.file_row = 1;
  if n <> 1 then raise exception 'FAILED T2b V-01 not on row 1'; end if; passed := passed + 1;

  select count(*) into n from public.line_issue i join public.order_line l on l.id = i.line_id where l.order_id = o1 and i.rule_id = 'V-04' and l.file_row = 2;
  if n <> 1 then raise exception 'FAILED T3 V-04 on zero quantity'; end if;
  select count(*) into n from public.line_issue where rule_id = 'V-04' and (file_id = f1 or line_id in (select id from public.order_line where order_id = o1));
  if n <> 1 then raise exception 'FAILED T3b V-04 count %', n; end if; passed := passed + 1;

  -- V-05: row 3 (60 > 50) and row 4 (40 + 15 > 50) warn; row 5 (exactly 50), row 6 (no capping), row 7 (NGO) do not
  select string_agg(l.file_row::text, ',' order by l.file_row) into m from public.line_issue i join public.order_line l on l.id = i.line_id where l.order_id = o1 and i.rule_id = 'V-05';
  if m is distinct from '3,4' then raise exception 'FAILED T4 V-05 rows %', m; end if; passed := passed + 1;

  -- V-06: one message for the stopped customer naming rows 8 and 9, severity error
  select count(*) into n from public.line_issue where file_id = f1 and rule_id = 'V-06' and severity = 'error' and message like '%Delete rows 8, 9 and upload the file again.';
  if n <> 1 then raise exception 'FAILED T5 V-06 message'; end if; passed := passed + 1;

  -- V-08: row 8 had no date
  select order_date, order_date_defaulted::int into d, n from public.order_line where order_id = o1 and file_row = 8;
  if d <> current_date or n <> 1 then raise exception 'FAILED T6 V-08 date not defaulted'; end if;
  select count(*) into n from public.line_issue i join public.order_line l on l.id = i.line_id where l.order_id = o1 and i.rule_id = 'V-08' and i.severity = 'information';
  if n <> 1 then raise exception 'FAILED T6b V-08 count %', n; end if; passed := passed + 1;

  -- V-12: rows 2 and 3 (same customer, product and distributor); row 4 is another distributor, so it is not in the message
  select count(*) into n from public.line_issue where file_id = f1 and rule_id = 'V-12' and severity = 'warning' and message like '%in rows 2, 3. Check if this is intended.';
  if n <> 1 then raise exception 'FAILED T7 V-12 message'; end if;
  select count(*) into n from public.line_issue where file_id = f1 and rule_id = 'V-12';
  if n <> 1 then raise exception 'FAILED T7b V-12 count %', n; end if; passed := passed + 1;

  -- Running the check again replaces the result, it does not add to it
  select count(*) into n from public.line_issue where file_id = f1 or line_id in (select id from public.order_line where order_id = o1);
  res := public.run_file_check(o1);
  select count(*) into m from public.line_issue where file_id = f1 or line_id in (select id from public.order_line where order_id = o1);
  if m::int <> n then raise exception 'FAILED T8 re-run changed issue count % to %', n, m; end if; passed := passed + 1;

  -- File 2 (grouped chain): a Brick is recognised, a customer code is not
  insert into public.order_file (uploaded_name, stored_name, uploader, upload_type, demo) values ('t2b.xlsx','t2b_20261121.xlsx',dm1,'grouped_chain',true) returning id into f2;
  insert into public.orders (file_id, creator, demo) values (f2, dm1, true) returning id into o2;
  insert into public.order_line (order_id, file_row, distributor, customer_key_entered, product_code_entered, requested_quantity, order_date, demo) values
    (o2,1,'D1','T2-BRICK','T2-P1',5,current_date,true),
    (o2,2,'D1','T2-PH'   ,'T2-P1',5,current_date,true);
  res := public.run_file_check(o2);
  select string_agg(l.file_row::text, ',') into m from public.line_issue i join public.order_line l on l.id = i.line_id where l.order_id = o2 and i.rule_id = 'V-01';
  if res <> 'Has Errors' or m is distinct from '2' then raise exception 'FAILED T9 grouped chain key: % %', res, m; end if; passed := passed + 1;

  -- File 3: only a warning, so the file is Valid and can be submitted
  insert into public.order_file (uploaded_name, stored_name, uploader, upload_type, demo) values ('t2c.xlsx','t2c_20261121.xlsx',dm1,'other',true) returning id into f3;
  insert into public.orders (file_id, creator, demo) values (f3, dm1, true) returning id into o3;
  insert into public.order_line (order_id, file_row, distributor, customer_key_entered, product_code_entered, requested_quantity, order_date, demo) values
    (o3,1,'D1','T2-PH','T2-P1',60,current_date,true);
  res := public.run_file_check(o3);
  if res <> 'Valid' then raise exception 'FAILED T10 warning-only file result %', res; end if;
  perform public.submit_order(o3);
  select count(*) into n from public.orders where id = o3 and arrived_at is not null;
  if n <> 1 then raise exception 'FAILED T10b valid file not submitted'; end if; passed := passed + 1;

  -- A submitted file cannot be checked again
  begin perform public.run_file_check(o3); raise exception 'FAILED T11 submitted file re-checked';
  exception when others then if sqlerrm like 'FAILED%' then raise; end if; passed := passed + 1; end;

  -- Another Distribution Manager cannot run the check on someone else's order
  perform set_config('request.jwt.claims', json_build_object('sub',dm2,'role','authenticated')::text, true);
  begin perform public.run_file_check(o1); raise exception 'FAILED T12 other DM ran the check';
  exception when others then if sqlerrm like 'FAILED%' then raise; end if; passed := passed + 1; end;

  -- Not signed in
  reset role; set local role anon;
  begin perform public.run_file_check(o1); raise exception 'FAILED T13 anon ran the check';
  exception when others then if sqlerrm like 'FAILED%' then raise; end if; passed := passed + 1; end;

  raise exception 'TESTS_PASSED %', passed;
end $$;
