-- 0002 Users, order files, orders, lines, issues, audit log (slice 1: Distribution Manager flow + audit). BRD v1.3.

create table public.app_user (                 -- Section 6 roles; matrix beyond slice 1 is MISSING INFORMATION
  id uuid primary key references auth.users(id) on delete restrict,
  display_name text not null,
  role text not null check (role in ('distribution_manager','back_end_monitoring','second_line_manager','business_unit_director','cfo','cp','management')),
  demo boolean not null default false,
  created_at timestamptz not null default now()
);

create table public.order_file (               -- FR-45, FR-50, FR-53
  id uuid primary key default gen_random_uuid(),
  uploaded_name text not null,                 -- FR-50: name as uploaded
  stored_name text not null unique,            -- FR-50: stored name carries upload date and time
  uploader uuid not null references public.app_user(id),
  upload_type text not null check (upload_type in ('grouped_chain','egydrug','other')), -- FR-53
  upload_date date not null default current_date,
  state text not null default 'draft' check (state in ('draft','submitted')),
  check_result text check (check_result in ('Valid','Has Errors')), -- live app pills; warnings do not block (FR-43)
  demo boolean not null default false,
  created_at timestamptz not null default now()
);

create table public.orders (                   -- one order per submitted or draft file; id shown in lists
  id uuid primary key default gen_random_uuid(),
  order_no bigint generated always as identity unique,  -- display format of the order id is not documented: not modelled
  file_id uuid not null unique references public.order_file(id),
  creator uuid not null references public.app_user(id),
  arrived_at timestamptz,                      -- set on submit; starts the 48-hour clock (FR-30)
  demo boolean not null default false,
  created_at timestamptz not null default now()
);

create table public.order_line (               -- FR-01
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id) on delete cascade,
  file_row int not null,
  distributor text,                            -- FR-01: distributor named on the line
  customer_key_entered text,                   -- as entered: customer code, or Brick for grouped chains (FR-52)
  customer_id uuid references public.customer(id),   -- null when the code is not recognised (V-01)
  product_code_entered text,
  product_id uuid references public.product(id),
  requested_quantity numeric,
  pharmacy_price numeric,
  line_value numeric,                          -- FR-04: grouped chains only
  earlier_orders_quantity numeric,             -- FR-01/FR-05: blank counts as zero; source rule is OPEN (G0-1)
  order_date date,
  order_date_defaulted boolean not null default false, -- FR-06 / V-08
  status text,                                 -- per-product status (FR-48); value list MISSING (Point 21)
  demo boolean not null default false,
  created_at timestamptz not null default now(),
  unique (order_id, file_row)
);

create table public.line_issue (               -- result of the file check: V-01 to V-12
  id uuid primary key default gen_random_uuid(),
  file_id uuid references public.order_file(id) on delete cascade,
  line_id uuid references public.order_line(id) on delete cascade,
  rule_id text not null check (rule_id ~ '^V-[0-9]{2}$'),
  severity text not null check (severity in ('error','warning','information')), -- Blocks upload/submission = error; Warning; Information
  message text not null,                       -- wording as in BRD section 11.3
  created_at timestamptz not null default now(),
  constraint issue_has_target check (file_id is not null or line_id is not null)
);

create table public.action_log (               -- FR-33, NFR Audit: insert-only
  id bigint generated always as identity primary key,
  order_id uuid references public.orders(id),
  file_id uuid references public.order_file(id),
  actor uuid references public.app_user(id),
  actor_role text,
  stage text,
  action text not null,
  detail text,
  quantity numeric,
  at timestamptz not null default now()
);

create function app_private.block_mutation() returns trigger
language plpgsql set search_path = '' as $$
begin
  raise exception 'action_log is insert-only (BRD NFR Audit)';
end $$;

create trigger action_log_no_update_delete before update or delete on public.action_log
  for each row execute function app_private.block_mutation();
create trigger action_log_no_truncate before truncate on public.action_log
  for each statement execute function app_private.block_mutation();
