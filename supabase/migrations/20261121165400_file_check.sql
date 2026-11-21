-- 0004 File check for the Distribution Manager (slice 1). BRD v1.3 section 11.3 (V-01, V-04, V-05, V-06, V-08, V-12), FR-02, FR-03, FR-05 to FR-08, FR-43, FR-44, FR-52, FR-53.
-- Runs inside the database because the Distribution Manager may not read caps or the blacklist (G1 section 3).
-- NOT coded, because the BRD does not give what is needed (see G0 gaps G0-11 to G0-14):
--   V-02 required fields (the list of required cells is not defined), V-03 file structure (a parsing step, not a database rule),
--   unknown product code (FR-02 names it, but there is no V-number or message text), how a blacklist name is matched to a customer.
-- V-07 is not part of the upload check (FR-44). V-09 to V-11 belong to the approval slices.
-- FR-05 "earlier orders this month" uses only the column on the file (FR-01); orders held in the system are not added (G0-1 is open).

create function public.run_file_check(p_order_id uuid) returns text
language plpgsql security definer set search_path = '' as $$
declare v_order public.orders; v_file public.order_file; v_role text; v_result text; v_lines int;
begin
  select * into v_order from public.orders where id = p_order_id;
  if not found or v_order.creator <> (select auth.uid()) then raise exception 'order not found'; end if;
  select app_private.current_role_name() into v_role;
  if v_role <> 'distribution_manager' then raise exception 'not allowed'; end if;
  select * into v_file from public.order_file where id = v_order.file_id for update;
  if v_file.state <> 'draft' then raise exception 'order already submitted'; end if;
  select count(*) into v_lines from public.order_line where order_id = p_order_id;
  if v_lines = 0 then raise exception 'there are no lines to check'; end if;

  -- A new check replaces the previous result.
  delete from public.line_issue
   where file_id = v_file.id or line_id in (select id from public.order_line where order_id = p_order_id);

  -- Recognise customer and product by exact match (FR-03, FR-52). Grouped chains use the Brick; other segments use the customer code.
  -- A Brick shared by more than one master row is recognised but not linked to one customer (Brick master is GA-3).
  update public.order_line l set
    customer_id = case when v_file.upload_type = 'grouped_chain'
      then (select case when count(*) = 1 then (array_agg(c.id))[1] end from public.customer c where c.brick = l.customer_key_entered)
      else (select c.id from public.customer c where c.code = l.customer_key_entered) end,
    product_id = (select p.id from public.product p where p.code = l.product_code_entered)
  where l.order_id = p_order_id;

  -- V-01 Customer code must exist in the customer master. Blocks upload.
  insert into public.line_issue (line_id, rule_id, severity, message)
  select l.id, 'V-01', 'error', 'This customer code is not recognised. Check the code against the customer list.'
  from public.order_line l
  where l.order_id = p_order_id and l.customer_key_entered is not null
    and not exists (select 1 from public.customer c
                    where (case when v_file.upload_type = 'grouped_chain' then c.brick else c.code end) = l.customer_key_entered);

  -- V-04 Requested quantity must be greater than zero. Blocks upload.
  insert into public.line_issue (line_id, rule_id, severity, message)
  select l.id, 'V-04', 'error', 'Enter a quantity greater than zero.'
  from public.order_line l
  where l.order_id = p_order_id and l.requested_quantity <= 0;

  -- V-05 Requested quantity checked against the cap (FR-05, FR-07, R-02). Warning.
  -- Only independent pharmacies and private hospitals have caps; a product marked "No capping" or without a cap value has no check.
  insert into public.line_issue (line_id, rule_id, severity, message)
  select l.id, 'V-05', 'warning', 'Requested quantity is above the cap for this product. The line will enter the approval cycle.'
  from public.order_line l
  join public.customer c on c.id = l.customer_id
  join public.cap k on k.product_id = l.product_id and k.customer_type = c.customer_type
  where l.order_id = p_order_id and not k.no_capping and k.cap_quantity is not null
    and l.requested_quantity is not null
    and l.requested_quantity + coalesce(l.earlier_orders_quantity, 0) > k.cap_quantity;

  -- V-06 Customer must not be on the blacklist (FR-08, R-03). Blocks submission. One message per customer, naming the rows to delete.
  insert into public.line_issue (file_id, rule_id, severity, message)
  select v_file.id, 'V-06', 'error',
         'This customer is currently stopped and cannot be ordered for. Delete rows ' || string_agg(l.file_row::text, ', ' order by l.file_row) || ' and upload the file again.'
  from public.order_line l
  where l.order_id = p_order_id and l.customer_id is not null
    and exists (select 1 from public.blacklist b where b.customer_id = l.customer_id)
  group by l.customer_id;

  -- V-08 Blank order date takes the upload date, and the user is told (FR-06). Information.
  with d as (
    update public.order_line set order_date = v_file.upload_date, order_date_defaulted = true
    where order_id = p_order_id and (order_date is null or order_date_defaulted)
    returning id)
  insert into public.line_issue (line_id, rule_id, severity, message)
  select id, 'V-08', 'information', 'Order date set to today''s upload date.' from d;

  -- V-12 Same product more than once for the same customer and distributor in the file (FR-44). Warning naming the rows. Works inside one file only.
  insert into public.line_issue (file_id, rule_id, severity, message)
  select v_file.id, 'V-12', 'warning',
         'The same product is ordered more than once for the same customer and distributor in rows ' || string_agg(l.file_row::text, ', ' order by l.file_row) || '. Check if this is intended.'
  from public.order_line l
  where l.order_id = p_order_id
    and coalesce(l.customer_id::text, l.customer_key_entered) is not null
    and coalesce(l.product_id::text, l.product_code_entered) is not null
  group by coalesce(l.customer_id::text, l.customer_key_entered), coalesce(l.product_id::text, l.product_code_entered), coalesce(l.distributor, '')
  having count(*) > 1;

  -- Result as in the live app: errors block submission, warnings do not (FR-43).
  v_result := case when exists (select 1 from public.line_issue i where i.severity = 'error'
                                and (i.file_id = v_file.id or i.line_id in (select id from public.order_line where order_id = p_order_id)))
                   then 'Has Errors' else 'Valid' end;
  update public.order_file set check_result = v_result where id = v_file.id;
  return v_result;
end $$;
revoke all on function public.run_file_check(uuid) from public, anon;
grant execute on function public.run_file_check(uuid) to authenticated;
