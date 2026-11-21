-- 0005 Read views for the Distribution Manager screens (FR-45 Drafts, FR-47 My Orders, FR-48 order detail, FR-04 line value).
-- security_invoker: the existing row-level security applies, and every view also filters to the signed-in user's own files and orders.
-- Facts only. How long an order has waited is shown as arrived_at (the display rule is not defined); the status list is MISSING (Point 21),
-- so per-product status is passed through as entered. "Date saved" is the date the draft was first stored: the BRD does not say what counts as a re-save.
-- Returned lines (FR-49) need the approval slice and are not built here.

create view public.my_drafts with (security_invoker = true) as
select f.id as file_id, o.id as order_id, f.uploaded_name as file_name, f.created_at as date_saved, f.check_result as status
from public.order_file f
join public.orders o on o.file_id = f.id
where f.state = 'draft' and f.uploader = (select auth.uid());

-- One row per customer on an order, with the distributor and the number of products (FR-47). Submitted files only: a draft is not shown in My Orders (FR-45).
create view public.my_orders with (security_invoker = true) as
select o.id as order_id, o.order_no, f.uploaded_name as file_name,
       coalesce(c.name, l.customer_key_entered) as customer,
       l.distributor,
       count(*) as products,
       o.arrived_at
from public.order_file f
join public.orders o on o.file_id = f.id
join public.order_line l on l.order_id = o.id
left join public.customer c on c.id = l.customer_id
where f.state = 'submitted' and o.creator = (select auth.uid())
group by o.id, o.order_no, f.uploaded_name, l.customer_id, l.customer_key_entered, c.name, l.distributor, o.arrived_at;

-- Order detail: each product on its own line with quantity, value and its own status (FR-48).
-- Value is quantity x pharmacy price for grouped chain lines only; no price or amount for any other segment (FR-04).
create view public.my_order_lines with (security_invoker = true) as
select o.id as order_id, l.id as line_id, l.file_row,
       coalesce(c.name, l.customer_key_entered) as customer,
       l.distributor,
       coalesce(p.name, l.product_code_entered) as product,
       l.requested_quantity as quantity,
       case when c.customer_type = 'grouped_chain' then l.requested_quantity * l.pharmacy_price end as value,
       l.status
from public.orders o
join public.order_file f on f.id = o.file_id
join public.order_line l on l.order_id = o.id
left join public.customer c on c.id = l.customer_id
left join public.product p on p.id = l.product_id
where f.state = 'submitted' and o.creator = (select auth.uid());

revoke all on public.my_drafts, public.my_orders, public.my_order_lines from public, anon;
grant select on public.my_drafts, public.my_orders, public.my_order_lines to authenticated;
