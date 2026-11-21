-- 0001 Reference data tables (BRD v1.3 FR-42, Appendix B). INTERNAL private fallback build.
-- Every table can mark synthetic rows with demo = true (never shown as AstraZeneca data, never used to define a rule).
-- Portable by design: plain types only (text, numeric, int, date, boolean, uuid, timestamptz), choices as text + check.
create schema if not exists app_private;

create table public.customer (
  id uuid primary key default gen_random_uuid(),
  code text,                                   -- FR-02, FR-03, FR-52: customer code (segments other than grouped chain)
  brick text,                                  -- FR-52: grouped chains are identified by Brick (no customer ID)
  name text not null,
  customer_type text not null check (customer_type in ('grouped_chain','egydrug','independent_pharmacy','private_hospital','ngo')), -- BRD 8.1
  demo boolean not null default false,
  created_at timestamptz not null default now(),
  constraint customer_has_key check (code is not null or brick is not null)
);
create unique index customer_code_uq on public.customer (code) where code is not null;
create index customer_brick_ix on public.customer (brick) where brick is not null;

create table public.product (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,                   -- FR-01, FR-02
  name text not null,
  division text,                               -- FR-01 product division
  demo boolean not null default false,
  created_at timestamptz not null default now()
);

create table public.cap (                      -- FR-07, R-02, R-25 (Appendix B sheet 2)
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.product(id),
  customer_type text not null check (customer_type in ('independent_pharmacy','private_hospital')), -- R-02
  cap_quantity numeric,                        -- null = no cap value = no cap check (R-02)
  no_capping boolean not null default false,   -- R-02 "No capping" marker
  demo boolean not null default false,
  created_at timestamptz not null default now(),
  unique (product_id, customer_type)
);

create table public.product_growth (           -- FR-10, R-04 (sheet 3). How the allowed quantity is worked out is OPEN (Point 2): not modelled.
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.product(id),
  year int not null,
  yearly_target numeric,
  allowed_growth_pct numeric,
  reference_quantity numeric,
  demo boolean not null default false,
  created_at timestamptz not null default now(),
  unique (product_id, year)
);

create table public.guided_value (             -- FR-11, R-06 (sheet 4). Per branch vs per chain is OPEN (GA-4): stored as the sheet asks.
  id uuid primary key default gen_random_uuid(),
  chain_name text not null,
  year int not null,
  guided_value_per_branch numeric,
  number_of_branches int,
  demo boolean not null default false,
  created_at timestamptz not null default now(),
  unique (chain_name, year)
);

create table public.product_map (              -- FR-17, FR-22, FR-24 (sheet 5)
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null unique references public.product(id),
  second_line_manager_name text,
  second_line_manager_email text,
  includes_business_unit_director boolean not null default false,
  includes_cfo boolean not null default false,  -- BRD v1.3 says CFO (the request workbook v1.0 still says Finance)
  includes_cp boolean not null default false,
  demo boolean not null default false,
  created_at timestamptz not null default now()
);

create table public.approver (                 -- FR-23, FR-24 (sheet 6): one person per stage (R-28)
  id uuid primary key default gen_random_uuid(),
  stage text not null unique check (stage in ('business_unit_director','cfo','cp')),
  holder_name text,
  holder_email text,
  deputy_name text,
  deputy_email text,
  demo boolean not null default false,
  created_at timestamptz not null default now()
);

create table public.special_case (             -- FR-25, R-16 (sheet 7)
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null unique references public.customer(id),
  note text,
  demo boolean not null default false,
  created_at timestamptz not null default now()
);

create table public.blacklist (                -- FR-08, R-03
  id uuid primary key default gen_random_uuid(),
  customer_id uuid references public.customer(id),
  customer_name text not null,                 -- the supplied list holds names
  demo boolean not null default false,
  created_at timestamptz not null default now()
);

create table public.bulk_purchase (            -- FR-27, R-19
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references public.customer(id),
  product_id uuid references public.product(id),
  flag_type text not null check (flag_type in ('bulk_purchase','product_interest')),
  demo boolean not null default false,
  created_at timestamptz not null default now()
);

create table public.concern_type (             -- FR-26 (sheet 8)
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  when_used text,
  sent_to text,
  demo boolean not null default false,
  created_at timestamptz not null default now()
);

create table public.holiday (                  -- FR-30 (sheet 12)
  id uuid primary key default gen_random_uuid(),
  holiday_date date not null unique,
  name text,
  demo boolean not null default false,
  created_at timestamptz not null default now()
);

create table public.stock_sales_out (          -- FR-12, FR-14 (sheet 9)
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references public.customer(id),
  product_id uuid not null references public.product(id),
  month date not null,
  stock_quantity numeric,
  sales_out_quantity numeric,
  refreshed_on date,                           -- FR-14 shows the date of the last refresh
  demo boolean not null default false,
  created_at timestamptz not null default now(),
  unique (customer_id, product_id, month)
);

create table public.status_value (             -- Point 21: full status lists are MISSING; only values seen in the live app are seeded
  id uuid primary key default gen_random_uuid(),
  entity text not null check (entity in ('file','order','product')),
  value text not null,
  source text not null,
  unique (entity, value)
);
insert into public.status_value (entity, value, source) values
  ('file','Draft','live app, 17-Nov-2026 TFS screenshots'),
  ('file','Valid','live app, 17-Nov-2026 TFS screenshots'),
  ('file','Has Errors','live app, 17-Nov-2026 TFS screenshots');
