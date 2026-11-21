-- Slice 1 access and audit tests. Run in one transaction that always rolls back:
-- success ends with the exception 'TESTS_PASSED n'; any failure ends with 'FAILED: ...'.
do $$
declare
  dm1 uuid := gen_random_uuid(); dm2 uuid := gen_random_uuid(); be uuid := gen_random_uuid();
  f1 uuid; o1 uuid; n int; passed int := 0; rc int;
begin
  insert into auth.users (id, email) values (dm1,'dm1@test.invalid'),(dm2,'dm2@test.invalid'),(be,'be@test.invalid');
  insert into public.app_user (id, display_name, role, demo) values
    (dm1,'DM1','distribution_manager',true),(dm2,'DM2','distribution_manager',true),(be,'BE','back_end_monitoring',true);
  insert into public.customer (code,name,customer_type,demo) values ('T-1','Test customer','independent_pharmacy',true);
  insert into public.blacklist (customer_name, demo) values ('(BL)T', true);

  -- Distribution Manager 1 creates a draft with errors
  perform set_config('request.jwt.claims', json_build_object('sub',dm1,'role','authenticated')::text, true);
  set local role authenticated;
  insert into public.order_file (uploaded_name, stored_name, uploader, upload_type, check_result, demo)
    values ('a.xlsx','a_20261121.xlsx',dm1,'other','Has Errors',true) returning id into f1;
  insert into public.orders (file_id, creator, demo) values (f1, dm1, true) returning id into o1;
  select count(*) into n from public.order_file; if n <> 1 then raise exception 'FAILED T1 own file visible'; end if; passed := passed + 1;

  begin perform public.submit_order(o1); raise exception 'FAILED T2 submit with errors allowed';
  exception when others then if sqlerrm like 'FAILED%' then raise; end if; passed := passed + 1; end;

  update public.order_file set check_result = 'Valid' where id = f1;
  perform public.submit_order(o1);
  select count(*) into n from public.orders where arrived_at is not null; if n <> 1 then raise exception 'FAILED T3 arrived_at not set'; end if; passed := passed + 1;

  update public.order_file set uploaded_name = 'changed' where id = f1; get diagnostics rc = row_count;
  if rc <> 0 then raise exception 'FAILED T4 submitted file editable'; end if; passed := passed + 1;
  delete from public.order_file where id = f1; get diagnostics rc = row_count;
  if rc <> 0 then raise exception 'FAILED T5 submitted file deletable'; end if; passed := passed + 1;

  -- Distribution Manager 2 sees nothing of DM1, cannot write reference data, cannot read blacklist or caps
  perform set_config('request.jwt.claims', json_build_object('sub',dm2,'role','authenticated')::text, true);
  select count(*) into n from public.order_file; if n <> 0 then raise exception 'FAILED T6a other DM sees files'; end if;
  select count(*) into n from public.orders; if n <> 0 then raise exception 'FAILED T6b other DM sees orders'; end if; passed := passed + 1;
  begin insert into public.cap (product_id, customer_type) values (gen_random_uuid(),'independent_pharmacy'); raise exception 'FAILED T7 DM wrote reference data';
  exception when others then if sqlerrm like 'FAILED%' then raise; end if; passed := passed + 1; end;
  select count(*) into n from public.customer; if n <> 1 then raise exception 'FAILED T8a DM cannot read customer'; end if;
  select count(*) into n from public.blacklist; if n <> 0 then raise exception 'FAILED T8b DM reads blacklist'; end if; passed := passed + 1;
  begin perform public.submit_order(o1); raise exception 'FAILED T8c other DM submitted';
  exception when others then if sqlerrm like 'FAILED%' then raise; end if; passed := passed + 1; end;

  -- Back-End reads orders, maintains reference data, cannot change the audit log
  perform set_config('request.jwt.claims', json_build_object('sub',be,'role','authenticated')::text, true);
  select count(*) into n from public.order_file; if n <> 1 then raise exception 'FAILED T9a backend cannot read files'; end if;
  select count(*) into n from public.action_log; if n <> 1 then raise exception 'FAILED T9b audit row missing'; end if;
  insert into public.customer (code,name,customer_type,demo) values ('T-2','Backend added','ngo',true); passed := passed + 1;
  begin update public.action_log set action = 'x'; raise exception 'FAILED T10 audit log updated';
  exception when others then if sqlerrm like 'FAILED%' then raise; end if; passed := passed + 1; end;

  -- Not signed in
  reset role; set local role anon;
  begin perform 1 from public.customer; raise exception 'FAILED T11 anon read customer';
  exception when others then if sqlerrm like 'FAILED%' then raise; end if; passed := passed + 1; end;

  -- Owner cannot change the audit log either
  reset role;
  begin update public.action_log set action = 'x'; raise exception 'FAILED T12 owner updated audit log';
  exception when others then if sqlerrm like 'FAILED%' then raise; end if; passed := passed + 1; end;
  begin delete from public.action_log; raise exception 'FAILED T13 owner deleted audit log';
  exception when others then if sqlerrm like 'FAILED%' then raise; end if; passed := passed + 1; end;

  raise exception 'TESTS_PASSED %', passed;
end $$;
