-- DEMO SEED. Synthetic rows only, so the screens have content. INTERNAL private fallback build.
-- Every row has demo = true. Nothing here is AstraZeneca data, none of it defines a rule,
-- and every value is a placeholder that is removed or overwritten when AstraZeneca supplies its workbook.
-- Names say "Demo", e-mail addresses use the reserved .invalid domain, codes start with DEMO-.
-- Not a migration: it is data, run by the owner on demand. Remove it with demo_remove.sql.

do $$
begin
  if exists (select 1 from public.product where demo) or exists (select 1 from public.customer where demo) then
    raise exception 'Demo seed is already loaded. Run demo_remove.sql first.';
  end if;
end $$;

insert into public.customer (code, brick, name, customer_type, demo) values
  (null,        'DEMO-B01', 'Demo Chain A (Brick DEMO-B01)',  'grouped_chain',        true),
  (null,        'DEMO-B02', 'Demo Chain B (Brick DEMO-B02)',  'grouped_chain',        true),
  ('DEMO-E001', null,       'Demo EgyDrug Branch 1',          'egydrug',              true),
  ('DEMO-I001', null,       'Demo Independent Pharmacy 1',    'independent_pharmacy', true),
  ('DEMO-I002', null,       'Demo Independent Pharmacy 2',    'independent_pharmacy', true),
  ('DEMO-H001', null,       'Demo Private Hospital 1',        'private_hospital',     true),
  ('DEMO-N001', null,       'Demo NGO 1',                     'ngo',                  true);

insert into public.product (code, name, division, demo) values
  ('DEMO-P1', 'Demo Product A', 'Demo Division 1', true),
  ('DEMO-P2', 'Demo Product B', 'Demo Division 1', true),
  ('DEMO-P3', 'Demo Product C', 'Demo Division 2', true);

-- Caps: a value, a "No capping" marker, and a blank (no value = no check, R-02) are all shown.
insert into public.cap (product_id, customer_type, cap_quantity, no_capping, demo)
select p.id, v.customer_type, v.cap_quantity, v.no_capping, true
from (values
  ('DEMO-P1','independent_pharmacy', 50::numeric,  false),
  ('DEMO-P1','private_hospital',     200::numeric, false),
  ('DEMO-P2','independent_pharmacy', 30::numeric,  false),
  ('DEMO-P2','private_hospital',     null::numeric, true),
  ('DEMO-P3','independent_pharmacy', null::numeric, false),
  ('DEMO-P3','private_hospital',     100::numeric, false)
) as v(product_code, customer_type, cap_quantity, no_capping)
join public.product p on p.code = v.product_code;

insert into public.product_growth (product_id, year, yearly_target, allowed_growth_pct, reference_quantity, demo)
select p.id, 2026, v.target, v.growth, v.ref, true
from (values
  ('DEMO-P1', 10000::numeric, 10::numeric, 8000::numeric),
  ('DEMO-P2',  5000::numeric, 15::numeric, 4000::numeric),
  ('DEMO-P3',  2000::numeric, 20::numeric, 1500::numeric)
) as v(product_code, target, growth, ref)
join public.product p on p.code = v.product_code;

insert into public.guided_value (chain_name, year, guided_value_per_branch, number_of_branches, demo) values
  ('Demo Chain A', 2026, 100000, 10, true),
  ('Demo Chain B', 2026,  80000,  5, true);

insert into public.product_map (product_id, second_line_manager_name, second_line_manager_email,
                                includes_business_unit_director, includes_cfo, includes_cp, demo)
select p.id, v.slm_name, v.slm_email, v.bud, v.cfo, v.cp, true
from (values
  ('DEMO-P1', 'Demo Second Line Manager 1', 'demo.slm1@example.invalid', true,  true,  false),
  ('DEMO-P2', 'Demo Second Line Manager 1', 'demo.slm1@example.invalid', true,  false, true),
  ('DEMO-P3', 'Demo Second Line Manager 2', 'demo.slm2@example.invalid', false, false, false)
) as v(product_code, slm_name, slm_email, bud, cfo, cp)
join public.product p on p.code = v.product_code;

insert into public.approver (stage, holder_name, holder_email, deputy_name, deputy_email, demo) values
  ('business_unit_director', 'Demo Business Unit Director', 'demo.bud@example.invalid', 'Demo BUD Deputy', 'demo.bud.deputy@example.invalid', true),
  ('cfo',                    'Demo CFO',                    'demo.cfo@example.invalid', 'Demo CFO Deputy', 'demo.cfo.deputy@example.invalid', true),
  ('cp',                     'Demo CP',                     'demo.cp@example.invalid',  'Demo CP Deputy',  'demo.cp.deputy@example.invalid',  true);

insert into public.special_case (customer_id, note, demo)
select id, 'Demo special case', true from public.customer where code = 'DEMO-N001';

insert into public.blacklist (customer_id, customer_name, demo)
select id, 'Demo Blacklisted Pharmacy 1', true from public.customer where code = 'DEMO-I002';
insert into public.blacklist (customer_id, customer_name, demo) values
  (null, 'Demo Blacklisted Pharmacy 2', true);

insert into public.bulk_purchase (customer_id, product_id, flag_type, demo)
select c.id, p.id, v.flag_type, true
from (values
  ('DEMO-I001', 'DEMO-P1', 'bulk_purchase'),
  ('DEMO-H001', 'DEMO-P3', 'product_interest')
) as v(customer_code, product_code, flag_type)
join public.customer c on c.code = v.customer_code
join public.product p on p.code = v.product_code;

insert into public.concern_type (name, when_used, sent_to, demo) values
  ('Demo concern type 1', 'Demo text', 'Demo recipient 1', true),
  ('Demo concern type 2', 'Demo text', 'Demo recipient 2', true);

insert into public.holiday (holiday_date, name, demo) values
  ('2026-12-03', 'Demo holiday 1', true),
  ('2026-12-17', 'Demo holiday 2', true);

insert into public.stock_sales_out (customer_id, product_id, month, stock_quantity, sales_out_quantity, refreshed_on, demo)
select c.id, p.id, v.month::date, v.stock, v.sales, date '2026-11-01', true
from (values
  ('DEMO-I001', 'DEMO-P1', '2026-09-01', 120::numeric, 60::numeric),
  ('DEMO-I001', 'DEMO-P1', '2026-10-01',  90::numeric, 70::numeric),
  ('DEMO-I002', 'DEMO-P1', '2026-10-01',  40::numeric, 20::numeric),
  ('DEMO-H001', 'DEMO-P3', '2026-10-01', 300::numeric, 150::numeric)
) as v(customer_code, product_code, month, stock, sales)
join public.customer c on c.code = v.customer_code
join public.product p on p.code = v.product_code;
