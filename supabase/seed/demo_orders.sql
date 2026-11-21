-- DEMO ORDERS. Synthetic orders owned by one Distribution Manager login, so the Drafts and My Orders screens have content.
-- Needs demo_seed.sql loaded first (uses its DEMO- customers and products). Every row has demo = true. Nothing here is AstraZeneca data.
-- Edit v_email below to the login that should own the orders. Not a migration: run on demand. Remove with demo_orders_remove.sql.
-- Each file goes through the real file check as that user. Files that come out Valid and are marked "submit" are then moved to submitted
-- directly (no action_log row, so the audit log stays free of demo entries and the orders can be removed again).
do $$
declare
  v_email text := 'syehhea@gmail.com';
  v_uid uuid; v_file uuid; v_order uuid; f jsonb; l jsonb; res text; i int := 0;
  v_files jsonb := '[
    {"name":"Pharmacies_Oct_A.xlsx","type":"other","ago":9,"submit":true,"lines":[
      {"d":"Demo Distributor 1","c":"DEMO-I001","p":"DEMO-P1","q":20,"price":10},
      {"d":"Demo Distributor 1","c":"DEMO-I001","p":"DEMO-P2","q":10,"price":10},
      {"d":"Demo Distributor 2","c":"DEMO-H001","p":"DEMO-P3","q":60,"price":10}]},
    {"name":"Chains_Oct.xlsx","type":"grouped_chain","ago":6,"submit":true,"lines":[
      {"d":"Demo Distributor 1","c":"DEMO-B01","p":"DEMO-P1","q":100,"price":12.5},
      {"d":"Demo Distributor 1","c":"DEMO-B01","p":"DEMO-P2","q":40,"price":8},
      {"d":"Demo Distributor 2","c":"DEMO-B02","p":"DEMO-P1","q":50,"price":12.5}]},
    {"name":"EgyDrug_Oct.xlsx","type":"egydrug","ago":3,"submit":true,"lines":[
      {"d":"Demo Distributor 1","c":"DEMO-E001","p":"DEMO-P1","q":30,"price":10},
      {"d":"Demo Distributor 1","c":"DEMO-E001","p":"DEMO-P3","q":15,"price":10}]},
    {"name":"Pharmacies_Nov_draft.xlsx","type":"other","ago":1,"submit":false,"lines":[
      {"d":"Demo Distributor 1","c":"DEMO-I001","p":"DEMO-P1","q":60,"price":10},
      {"d":"Demo Distributor 2","c":"DEMO-H001","p":"DEMO-P3","q":40,"price":10}]},
    {"name":"Mixed_with_errors.xlsx","type":"other","ago":0,"submit":false,"lines":[
      {"d":"Demo Distributor 1","c":"NOPE-1","p":"DEMO-P1","q":10,"price":10},
      {"d":"Demo Distributor 1","c":"DEMO-I002","p":"DEMO-P2","q":5,"price":10},
      {"d":"Demo Distributor 2","c":"DEMO-I001","p":"DEMO-P1","q":0,"price":10}]}
  ]'::jsonb;
begin
  select id into v_uid from auth.users where email = v_email;
  if v_uid is null or not exists (select 1 from public.app_user where id = v_uid and role = 'distribution_manager') then
    raise exception 'No Distribution Manager login for %', v_email;
  end if;
  if not exists (select 1 from public.customer where demo) then raise exception 'Load demo_seed.sql first.'; end if;
  if exists (select 1 from public.order_file where demo and stored_name like 'demo-orders-%') then raise exception 'Demo orders are already loaded.'; end if;

  perform set_config('request.jwt.claims', json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);

  for f in select * from jsonb_array_elements(v_files) loop
    i := i + 1;
    insert into public.order_file (uploaded_name, stored_name, uploader, upload_type, demo, created_at)
      values (f->>'name', 'demo-orders-' || i || '-' || to_char(now(), 'YYYYMMDD'), v_uid, f->>'type', true, now() - ((f->>'ago')::int || ' days')::interval)
      returning id into v_file;
    insert into public.orders (file_id, creator, demo, created_at)
      values (v_file, v_uid, true, now() - ((f->>'ago')::int || ' days')::interval) returning id into v_order;
    insert into public.order_line (order_id, file_row, distributor, customer_key_entered, product_code_entered, requested_quantity, pharmacy_price, order_date, demo)
      select v_order, n, x->>'d', x->>'c', x->>'p', (x->>'q')::numeric, (x->>'price')::numeric, current_date, true
      from jsonb_array_elements(f->'lines') with ordinality as t(x, n);
    res := public.run_file_check(v_order);
    if (f->>'submit')::boolean then
      if res <> 'Valid' then raise exception 'Demo file % did not pass the check (%)', f->>'name', res; end if;
      update public.order_file set state = 'submitted' where id = v_file;
      update public.orders set arrived_at = created_at where id = v_order;
    end if;
  end loop;
end $$;
