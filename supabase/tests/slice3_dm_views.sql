-- Distribution Manager views tests (drafts, My Orders, order detail, line value). Run in one transaction that always rolls back:
-- success ends with the exception 'TESTS_PASSED n'; any failure ends with 'FAILED: ...'. Uses its own T3- codes, so it can run beside the demo seed.
do $$
declare
  dm1 uuid := gen_random_uuid(); dm2 uuid := gen_random_uuid(); be uuid := gen_random_uuid();
  p1 uuid; p2 uuid; c_ph uuid; c_ch uuid;
  f1 uuid; o1 uuid; f2 uuid; o2 uuid; n int; v numeric; passed int := 0;
begin
  insert into auth.users (id, email) values (dm1,'t3dm1@test.invalid'),(dm2,'t3dm2@test.invalid'),(be,'t3be@test.invalid');
  insert into public.app_user (id, display_name, role, demo) values
    (dm1,'T3 DM1','distribution_manager',true),(dm2,'T3 DM2','distribution_manager',true),(be,'T3 BE','back_end_monitoring',true);
  insert into public.product (code,name,demo) values ('T3-P1','T3 product 1',true) returning id into p1;
  insert into public.product (code,name,demo) values ('T3-P2','T3 product 2',true) returning id into p2;
  insert into public.customer (code,name,customer_type,demo) values ('T3-PH','T3 pharmacy','independent_pharmacy',true) returning id into c_ph;
  insert into public.customer (brick,name,customer_type,demo) values ('T3-BRICK','T3 chain','grouped_chain',true) returning id into c_ch;

  perform set_config('request.jwt.claims', json_build_object('sub',dm1,'role','authenticated')::text, true);
  set local role authenticated;

  -- File 1: a draft with a pharmacy line (no value shown) and a second pharmacy line to another distributor
  insert into public.order_file (uploaded_name, stored_name, uploader, upload_type, check_result, demo) values ('t3a.xlsx','t3a_20261121.xlsx',dm1,'other','Valid',true) returning id into f1;
  insert into public.orders (file_id, creator, demo) values (f1, dm1, true) returning id into o1;
  insert into public.order_line (order_id, file_row, distributor, customer_key_entered, customer_id, product_code_entered, product_id, requested_quantity, pharmacy_price, order_date, demo) values
    (o1,1,'D1','T3-PH',c_ph,'T3-P1',p1,10,5,current_date,true),
    (o1,2,'D1','T3-PH',c_ph,'T3-P2',p2,20,5,current_date,true),
    (o1,3,'D2','T3-PH',c_ph,'T3-P1',p1,30,5,current_date,true);

  select count(*) into n from public.my_drafts where file_name = 't3a.xlsx' and status = 'Valid';
  if n <> 1 then raise exception 'FAILED T1 draft not listed'; end if;
  select count(*) into n from public.my_orders;
  if n <> 0 then raise exception 'FAILED T2 draft shown in My Orders'; end if; passed := passed + 1;

  -- Submit: it leaves Drafts and appears in My Orders, one row per customer and distributor
  perform public.submit_order(o1);
  select count(*) into n from public.my_drafts;
  if n <> 0 then raise exception 'FAILED T3 submitted file still a draft'; end if;
  select count(*) into n from public.my_orders where order_id = o1;
  if n <> 2 then raise exception 'FAILED T4 My Orders rows %', n; end if;
  select products into n from public.my_orders where order_id = o1 and distributor = 'D1';
  if n <> 2 then raise exception 'FAILED T4b products for D1 %', n; end if;
  select count(*) into n from public.my_orders where order_id = o1 and arrived_at is not null and file_name = 't3a.xlsx' and customer = 'T3 pharmacy';
  if n <> 2 then raise exception 'FAILED T4c arrived_at, file name or customer missing'; end if; passed := passed + 1;

  -- Order detail: pharmacy lines show no value (FR-04)
  select count(*) into n from public.my_order_lines where order_id = o1;
  if n <> 3 then raise exception 'FAILED T5 detail lines %', n; end if;
  select count(*) into n from public.my_order_lines where order_id = o1 and value is not null;
  if n <> 0 then raise exception 'FAILED T5b value shown for a pharmacy'; end if;
  select count(*) into n from public.my_order_lines where order_id = o1 and product = 'T3 product 1' and quantity = 10;
  if n <> 1 then raise exception 'FAILED T5c product name or quantity'; end if; passed := passed + 1;

  -- File 2: a grouped chain line shows quantity x pharmacy price
  insert into public.order_file (uploaded_name, stored_name, uploader, upload_type, check_result, demo) values ('t3b.xlsx','t3b_20261121.xlsx',dm1,'grouped_chain','Valid',true) returning id into f2;
  insert into public.orders (file_id, creator, demo) values (f2, dm1, true) returning id into o2;
  insert into public.order_line (order_id, file_row, distributor, customer_key_entered, customer_id, product_code_entered, product_id, requested_quantity, pharmacy_price, order_date, demo) values
    (o2,1,'D1','T3-BRICK',c_ch,'T3-P1',p1,4,2.5,current_date,true);
  perform public.submit_order(o2);
  select value into v from public.my_order_lines where order_id = o2;
  if v is distinct from 10.0 then raise exception 'FAILED T6 chain value %', v; end if; passed := passed + 1;

  -- Another Distribution Manager sees nothing of DM1
  perform set_config('request.jwt.claims', json_build_object('sub',dm2,'role','authenticated')::text, true);
  select count(*) into n from public.my_orders; if n <> 0 then raise exception 'FAILED T7a other DM sees orders'; end if;
  select count(*) into n from public.my_order_lines; if n <> 0 then raise exception 'FAILED T7b other DM sees lines'; end if;
  select count(*) into n from public.my_drafts; if n <> 0 then raise exception 'FAILED T7c other DM sees drafts'; end if; passed := passed + 1;

  -- Back-End has its own screens later; these views are "my" views and stay empty for it
  perform set_config('request.jwt.claims', json_build_object('sub',be,'role','authenticated')::text, true);
  select count(*) into n from public.my_orders; if n <> 0 then raise exception 'FAILED T8 backend sees my_orders'; end if; passed := passed + 1;

  -- Not signed in
  reset role; set local role anon;
  begin perform 1 from public.my_orders; raise exception 'FAILED T9 anon read my_orders';
  exception when others then if sqlerrm like 'FAILED%' then raise; end if; passed := passed + 1; end;

  raise exception 'TESTS_PASSED %', passed;
end $$;
