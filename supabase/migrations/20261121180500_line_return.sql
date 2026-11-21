-- Returned lines (BRD FR-19, FR-49): who returned, when, reason, per order line.
-- Only the fields FR-49 names. No write policy: the approval slice that creates returns is not built.
create table public.line_return (
  id uuid primary key default gen_random_uuid(),
  line_id uuid not null references public.order_line(id) on delete cascade,
  returned_by_name text not null,
  returned_by_role text not null check (returned_by_role in ('second_line_manager','business_unit_director','cfo','cp')),
  returned_at timestamptz not null default now(),
  reason text not null check (length(trim(reason)) > 0),
  demo boolean not null default false,
  created_at timestamptz not null default now()
);
alter table public.line_return enable row level security;
revoke all on public.line_return from anon, authenticated;
grant select on public.line_return to authenticated;
create policy backend_read on public.line_return for select to authenticated
  using ((select app_private.current_role_name()) = 'back_end_monitoring');
create policy dm_select on public.line_return for select to authenticated
  using ((select app_private.current_role_name()) = 'distribution_manager'
    and exists (select 1 from public.order_line l join public.orders o on o.id = l.order_id
                where l.id = line_return.line_id and o.creator = (select auth.uid())));
create index line_return_line_idx on public.line_return(line_id);
