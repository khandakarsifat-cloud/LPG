create table if not exists public.employee_types (
  tenant_id uuid not null,
  employee_type_id uuid default extensions.uuid_generate_v4() not null,
  name varchar(120) not null,
  is_active boolean default true not null,
  created_at timestamptz default now() not null,
  primary key (tenant_id, employee_type_id),
  unique (tenant_id, name),
  foreign key (tenant_id) references public.tenants(tenant_id) on delete cascade
);

create table if not exists public.employees (
  tenant_id uuid not null,
  employee_id uuid default extensions.uuid_generate_v4() not null,
  employee_type_id uuid,
  name varchar(255) not null,
  address text,
  current_salary numeric(12,2) default 0 not null check (current_salary >= 0),
  business_unit varchar(40) not null check (business_unit in ('gas_business', 'truck_business')),
  notes text,
  is_active boolean default true not null,
  created_at timestamptz default now() not null,
  updated_at timestamptz default now() not null,
  created_by uuid,
  primary key (tenant_id, employee_id),
  foreign key (tenant_id) references public.tenants(tenant_id) on delete cascade,
  foreign key (tenant_id, employee_type_id) references public.employee_types(tenant_id, employee_type_id),
  foreign key (created_by) references public.user_profiles(user_id)
);

create table if not exists public.employee_phone_numbers (
  tenant_id uuid not null,
  employee_phone_id uuid default extensions.uuid_generate_v4() not null,
  employee_id uuid not null,
  phone varchar(20) not null,
  is_primary boolean default false not null,
  created_at timestamptz default now() not null,
  primary key (tenant_id, employee_phone_id),
  unique (tenant_id, phone),
  foreign key (tenant_id, employee_id) references public.employees(tenant_id, employee_id) on delete cascade,
  foreign key (tenant_id) references public.tenants(tenant_id) on delete cascade,
  check (phone ~ '^(01[3-9][0-9]{8}|08801[3-9][0-9]{8})$')
);

create unique index if not exists employee_phone_numbers_one_primary
  on public.employee_phone_numbers (tenant_id, employee_id)
  where is_primary;

create table if not exists public.employee_payment_categories (
  tenant_id uuid not null,
  category_id uuid default extensions.uuid_generate_v4() not null,
  code varchar(50) not null,
  name varchar(120) not null,
  category_kind varchar(40) not null check (category_kind in ('salary', 'bonus', 'commission', 'trips', 'other')),
  is_active boolean default true not null,
  created_at timestamptz default now() not null,
  primary key (tenant_id, category_id),
  unique (tenant_id, code),
  unique (tenant_id, category_id, code),
  foreign key (tenant_id) references public.tenants(tenant_id) on delete cascade
);

create table if not exists public.employee_payments (
  tenant_id uuid not null,
  payment_id uuid default extensions.uuid_generate_v4() not null,
  employee_id uuid not null,
  category_id uuid not null,
  category_code varchar(50) not null,
  amount numeric(12,2) not null check (amount > 0),
  payment_date date not null,
  description text,
  salary_year integer check (salary_year between 2000 and 2100),
  salary_month integer check (salary_month between 1 and 12),
  trip_count integer check (trip_count is null or trip_count > 0),
  created_at timestamptz default now() not null,
  created_by uuid,
  primary key (tenant_id, payment_id),
  foreign key (tenant_id, employee_id) references public.employees(tenant_id, employee_id),
  foreign key (tenant_id, category_id, category_code) references public.employee_payment_categories(tenant_id, category_id, code),
  foreign key (created_by) references public.user_profiles(user_id),
  check (
    (category_code = 'salary' and salary_year is not null and salary_month is not null)
    or (category_code <> 'salary' and salary_year is null and salary_month is null)
  ),
  check (
    (category_code = 'trips' and trip_count is not null)
    or (category_code <> 'trips' and trip_count is null)
  )
);

create unique index if not exists employee_payments_salary_once_per_month
  on public.employee_payments (tenant_id, employee_id, salary_year, salary_month)
  where category_code = 'salary';

create index if not exists idx_employee_types_tenant_active
  on public.employee_types (tenant_id, is_active, name);

create index if not exists idx_employees_tenant_active
  on public.employees (tenant_id, is_active, name);

create index if not exists idx_employee_phones_employee
  on public.employee_phone_numbers (tenant_id, employee_id);

create index if not exists idx_employee_payments_employee_date
  on public.employee_payments (tenant_id, employee_id, payment_date desc);

create index if not exists idx_employee_payments_year
  on public.employee_payments (tenant_id, employee_id, salary_year);

alter table public.employee_types enable row level security;
alter table public.employees enable row level security;
alter table public.employee_phone_numbers enable row level security;
alter table public.employee_payment_categories enable row level security;
alter table public.employee_payments enable row level security;

create policy employee_types_tenant_select on public.employee_types
  for select using (tenant_id = public.my_tenant_id());
create policy employee_types_tenant_insert on public.employee_types
  for insert with check (tenant_id = public.my_tenant_id());
create policy employee_types_tenant_update on public.employee_types
  for update using (tenant_id = public.my_tenant_id())
  with check (tenant_id = public.my_tenant_id());

create policy employees_tenant_select on public.employees
  for select using (tenant_id = public.my_tenant_id());
create policy employees_tenant_insert on public.employees
  for insert with check (tenant_id = public.my_tenant_id());
create policy employees_tenant_update on public.employees
  for update using (tenant_id = public.my_tenant_id())
  with check (tenant_id = public.my_tenant_id());

create policy employee_phone_numbers_tenant_select on public.employee_phone_numbers
  for select using (tenant_id = public.my_tenant_id());
create policy employee_phone_numbers_tenant_insert on public.employee_phone_numbers
  for insert with check (tenant_id = public.my_tenant_id());
create policy employee_phone_numbers_tenant_update on public.employee_phone_numbers
  for update using (tenant_id = public.my_tenant_id())
  with check (tenant_id = public.my_tenant_id());

create policy employee_payment_categories_tenant_select on public.employee_payment_categories
  for select using (tenant_id = public.my_tenant_id());
create policy employee_payment_categories_tenant_insert on public.employee_payment_categories
  for insert with check (tenant_id = public.my_tenant_id());
create policy employee_payment_categories_tenant_update on public.employee_payment_categories
  for update using (tenant_id = public.my_tenant_id())
  with check (tenant_id = public.my_tenant_id());

create policy employee_payments_tenant_select on public.employee_payments
  for select using (tenant_id = public.my_tenant_id());
create policy employee_payments_tenant_insert on public.employee_payments
  for insert with check (tenant_id = public.my_tenant_id());

create or replace function public.ensure_default_employee_payment_categories(p_tenant_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_tenant_id is null then
    raise exception 'Tenant is required';
  end if;

  insert into public.employee_payment_categories (tenant_id, code, name, category_kind)
  values
    (p_tenant_id, 'salary', 'Monthly Salary', 'salary'),
    (p_tenant_id, 'bonus', 'Bonus', 'bonus'),
    (p_tenant_id, 'commission', 'Commission', 'commission'),
    (p_tenant_id, 'trips', 'Trips', 'trips'),
    (p_tenant_id, 'other', 'Other Payment', 'other')
  on conflict (tenant_id, code) do update
  set name = excluded.name,
      category_kind = excluded.category_kind,
      is_active = true;
end;
$$;

create or replace function public.employee_payment_immutable()
returns trigger
language plpgsql
as $$
begin
  raise exception 'Employee payment records are immutable';
end;
$$;

create trigger employee_payments_no_update
before update on public.employee_payments
for each row execute function public.employee_payment_immutable();

create trigger employee_payments_no_delete
before delete on public.employee_payments
for each row execute function public.employee_payment_immutable();

create or replace function public.resolve_employee_type(p_tenant_id uuid, p_employee_type_name text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_employee_type_id uuid;
  v_name text := nullif(trim(p_employee_type_name), '');
begin
  if v_name is null then
    return null;
  end if;

  insert into public.employee_types (tenant_id, name)
  values (p_tenant_id, v_name)
  on conflict (tenant_id, name) do update
  set is_active = true
  returning employee_type_id into v_employee_type_id;

  return v_employee_type_id;
end;
$$;

create or replace function public.create_employee(
  p_name text,
  p_phones jsonb,
  p_address text,
  p_current_salary numeric,
  p_employee_type_name text,
  p_business_unit text,
  p_notes text
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_tenant_id uuid;
  v_employee_id uuid;
  v_employee_type_id uuid;
  v_phone jsonb;
  v_phone_count integer := 0;
  v_primary_count integer := 0;
begin
  if v_user_id is null then raise exception 'Not authenticated'; end if;
  select tenant_id into v_tenant_id from public.user_profiles where user_id = v_user_id;
  if v_tenant_id is null then raise exception 'No tenant found for user'; end if;
  if nullif(trim(p_name), '') is null then raise exception 'Employee name is required'; end if;
  if p_business_unit not in ('gas_business', 'truck_business') then raise exception 'Invalid business unit'; end if;
  if jsonb_typeof(p_phones) <> 'array' or jsonb_array_length(p_phones) = 0 then
    raise exception 'At least one phone number is required';
  end if;

  v_employee_type_id := public.resolve_employee_type(v_tenant_id, p_employee_type_name);

  insert into public.employees (
    tenant_id, name, address, current_salary, employee_type_id, business_unit, notes, created_by
  ) values (
    v_tenant_id,
    trim(p_name),
    nullif(trim(p_address), ''),
    coalesce(p_current_salary, 0),
    v_employee_type_id,
    p_business_unit,
    nullif(trim(p_notes), ''),
    v_user_id
  ) returning employee_id into v_employee_id;

  for v_phone in select * from jsonb_array_elements(p_phones)
  loop
    v_phone_count := v_phone_count + 1;
    if coalesce((v_phone->>'is_primary')::boolean, false) then
      v_primary_count := v_primary_count + 1;
    end if;

    insert into public.employee_phone_numbers (tenant_id, employee_id, phone, is_primary)
    values (
      v_tenant_id,
      v_employee_id,
      trim(v_phone->>'phone'),
      coalesce((v_phone->>'is_primary')::boolean, false)
    );
  end loop;

  if v_phone_count = 0 or v_primary_count <> 1 then
    raise exception 'Exactly one primary phone number is required';
  end if;

  perform public.ensure_default_employee_payment_categories(v_tenant_id);

  return jsonb_build_object('employee_id', v_employee_id);
end;
$$;

create or replace function public.update_employee(
  p_employee_id uuid,
  p_name text,
  p_phones jsonb,
  p_address text,
  p_current_salary numeric,
  p_employee_type_name text,
  p_business_unit text,
  p_notes text,
  p_is_active boolean
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_tenant_id uuid;
  v_employee_type_id uuid;
  v_phone jsonb;
  v_phone_count integer := 0;
  v_primary_count integer := 0;
begin
  if v_user_id is null then raise exception 'Not authenticated'; end if;
  select tenant_id into v_tenant_id from public.user_profiles where user_id = v_user_id;
  if v_tenant_id is null then raise exception 'No tenant found for user'; end if;
  if nullif(trim(p_name), '') is null then raise exception 'Employee name is required'; end if;
  if p_business_unit not in ('gas_business', 'truck_business') then raise exception 'Invalid business unit'; end if;
  if jsonb_typeof(p_phones) <> 'array' or jsonb_array_length(p_phones) = 0 then
    raise exception 'At least one phone number is required';
  end if;

  if not exists (
    select 1 from public.employees
    where tenant_id = v_tenant_id and employee_id = p_employee_id
  ) then
    raise exception 'Employee not found';
  end if;

  v_employee_type_id := public.resolve_employee_type(v_tenant_id, p_employee_type_name);

  update public.employees
  set name = trim(p_name),
      address = nullif(trim(p_address), ''),
      current_salary = coalesce(p_current_salary, 0),
      employee_type_id = v_employee_type_id,
      business_unit = p_business_unit,
      notes = nullif(trim(p_notes), ''),
      is_active = coalesce(p_is_active, true),
      updated_at = now()
  where tenant_id = v_tenant_id and employee_id = p_employee_id;

  delete from public.employee_phone_numbers
  where tenant_id = v_tenant_id and employee_id = p_employee_id;

  for v_phone in select * from jsonb_array_elements(p_phones)
  loop
    v_phone_count := v_phone_count + 1;
    if coalesce((v_phone->>'is_primary')::boolean, false) then
      v_primary_count := v_primary_count + 1;
    end if;

    insert into public.employee_phone_numbers (tenant_id, employee_id, phone, is_primary)
    values (
      v_tenant_id,
      p_employee_id,
      trim(v_phone->>'phone'),
      coalesce((v_phone->>'is_primary')::boolean, false)
    );
  end loop;

  if v_phone_count = 0 or v_primary_count <> 1 then
    raise exception 'Exactly one primary phone number is required';
  end if;

  return jsonb_build_object('employee_id', p_employee_id);
end;
$$;

create or replace function public.deactivate_employee(p_employee_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_tenant_id uuid;
begin
  if v_user_id is null then raise exception 'Not authenticated'; end if;
  select tenant_id into v_tenant_id from public.user_profiles where user_id = v_user_id;
  if v_tenant_id is null then raise exception 'No tenant found for user'; end if;

  if exists (
    select 1 from public.employee_payments
    where tenant_id = v_tenant_id and employee_id = p_employee_id
  ) then
    update public.employees
    set is_active = false,
        updated_at = now()
    where tenant_id = v_tenant_id and employee_id = p_employee_id;
  else
    delete from public.employees
    where tenant_id = v_tenant_id and employee_id = p_employee_id;
  end if;

  return jsonb_build_object('employee_id', p_employee_id);
end;
$$;

create or replace function public.create_employee_payment(
  p_employee_id uuid,
  p_category_id uuid,
  p_amount numeric,
  p_payment_date date,
  p_description text,
  p_salary_year integer,
  p_salary_month integer,
  p_trip_count integer
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_tenant_id uuid;
  v_category record;
  v_employee record;
  v_payment_id uuid;
begin
  if v_user_id is null then raise exception 'Not authenticated'; end if;
  select tenant_id into v_tenant_id from public.user_profiles where user_id = v_user_id;
  if v_tenant_id is null then raise exception 'No tenant found for user'; end if;

  perform public.ensure_default_employee_payment_categories(v_tenant_id);

  select * into v_employee
  from public.employees
  where tenant_id = v_tenant_id and employee_id = p_employee_id and is_active = true;
  if v_employee.employee_id is null then raise exception 'Active employee not found'; end if;

  select * into v_category
  from public.employee_payment_categories
  where tenant_id = v_tenant_id and category_id = p_category_id and is_active = true;
  if v_category.category_id is null then raise exception 'Payment category not found'; end if;

  if coalesce(p_amount, 0) <= 0 then raise exception 'Payment amount must be greater than zero'; end if;
  if v_category.code = 'salary' and (p_salary_year is null or p_salary_month is null) then
    raise exception 'Salary month and year are required for salary payments';
  end if;
  if v_category.code <> 'salary' and (p_salary_year is not null or p_salary_month is not null) then
    raise exception 'Salary month and year can only be used for salary payments';
  end if;
  if v_category.code = 'trips' and coalesce(p_trip_count, 0) <= 0 then
    raise exception 'Trip count is required for trips payments';
  end if;
  if v_category.code <> 'trips' and p_trip_count is not null then
    raise exception 'Trip count can only be used for trips payments';
  end if;

  insert into public.employee_payments (
    tenant_id,
    employee_id,
    category_id,
    category_code,
    amount,
    payment_date,
    description,
    salary_year,
    salary_month,
    trip_count,
    created_by
  ) values (
    v_tenant_id,
    p_employee_id,
    p_category_id,
    v_category.code,
    p_amount,
    p_payment_date,
    nullif(trim(p_description), ''),
    p_salary_year,
    p_salary_month,
    p_trip_count,
    v_user_id
  ) returning payment_id into v_payment_id;

  return jsonb_build_object('payment_id', v_payment_id);
exception
  when unique_violation then
    raise exception 'Salary payment already exists for this employee and month';
end;
$$;

create or replace function public.list_employees()
returns table (
  employee_id uuid,
  name varchar,
  address text,
  current_salary numeric,
  business_unit varchar,
  notes text,
  is_active boolean,
  created_at timestamptz,
  updated_at timestamptz,
  employee_type_id uuid,
  employee_type_name varchar,
  phones jsonb,
  primary_phone varchar,
  payment_count bigint
)
language sql
security definer
set search_path = public
as $$
  select
    e.employee_id,
    e.name,
    e.address,
    e.current_salary,
    e.business_unit,
    e.notes,
    e.is_active,
    e.created_at,
    e.updated_at,
    e.employee_type_id,
    et.name as employee_type_name,
    coalesce(
      jsonb_agg(
        jsonb_build_object(
          'employee_phone_id', ep.employee_phone_id,
          'phone', ep.phone,
          'is_primary', ep.is_primary
        )
        order by ep.is_primary desc, ep.created_at asc
      ) filter (where ep.employee_phone_id is not null),
      '[]'::jsonb
    ) as phones,
    max(ep.phone) filter (where ep.is_primary) as primary_phone,
    count(distinct pay.payment_id) as payment_count
  from public.employees e
  left join public.employee_types et
    on et.tenant_id = e.tenant_id and et.employee_type_id = e.employee_type_id
  left join public.employee_phone_numbers ep
    on ep.tenant_id = e.tenant_id and ep.employee_id = e.employee_id
  left join public.employee_payments pay
    on pay.tenant_id = e.tenant_id and pay.employee_id = e.employee_id
  where e.tenant_id = public.my_tenant_id()
  group by e.employee_id, e.name, e.address, e.current_salary, e.business_unit,
    e.notes, e.is_active, e.created_at, e.updated_at, e.employee_type_id, et.name
  order by e.is_active desc, e.name asc;
$$;

create or replace function public.list_employee_payments(p_employee_id uuid)
returns table (
  payment_id uuid,
  employee_id uuid,
  employee_name varchar,
  category_id uuid,
  category_code varchar,
  category_name varchar,
  category_kind varchar,
  amount numeric,
  payment_date date,
  description text,
  salary_year integer,
  salary_month integer,
  trip_count integer,
  created_at timestamptz
)
language sql
security definer
set search_path = public
as $$
  select
    p.payment_id,
    p.employee_id,
    e.name as employee_name,
    p.category_id,
    p.category_code,
    c.name as category_name,
    c.category_kind,
    p.amount,
    p.payment_date,
    p.description,
    p.salary_year,
    p.salary_month,
    p.trip_count,
    p.created_at
  from public.employee_payments p
  join public.employees e
    on e.tenant_id = p.tenant_id and e.employee_id = p.employee_id
  join public.employee_payment_categories c
    on c.tenant_id = p.tenant_id and c.category_id = p.category_id
  where p.tenant_id = public.my_tenant_id()
    and p.employee_id = p_employee_id
  order by p.payment_date desc, p.created_at desc;
$$;

create or replace function public.list_employee_payment_categories()
returns table (
  category_id uuid,
  code varchar,
  name varchar,
  category_kind varchar,
  is_active boolean
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tenant_id uuid;
begin
  v_tenant_id := public.my_tenant_id();
  if v_tenant_id is null then
    raise exception 'No tenant found for user';
  end if;

  perform public.ensure_default_employee_payment_categories(v_tenant_id);

  return query
    select c.category_id, c.code, c.name, c.category_kind, c.is_active
    from public.employee_payment_categories c
    where c.tenant_id = v_tenant_id
    order by
      case c.code
        when 'salary' then 1
        when 'bonus' then 2
        when 'commission' then 3
        when 'trips' then 4
        else 5
      end,
      c.name;
end;
$$;

grant all on table public.employee_types to anon, authenticated, service_role;
grant all on table public.employees to anon, authenticated, service_role;
grant all on table public.employee_phone_numbers to anon, authenticated, service_role;
grant all on table public.employee_payment_categories to anon, authenticated, service_role;
grant all on table public.employee_payments to anon, authenticated, service_role;

grant all on function public.ensure_default_employee_payment_categories(uuid) to anon, authenticated, service_role;
grant all on function public.resolve_employee_type(uuid, text) to anon, authenticated, service_role;
grant all on function public.create_employee(text, jsonb, text, numeric, text, text, text) to anon, authenticated, service_role;
grant all on function public.update_employee(uuid, text, jsonb, text, numeric, text, text, text, boolean) to anon, authenticated, service_role;
grant all on function public.deactivate_employee(uuid) to anon, authenticated, service_role;
grant all on function public.create_employee_payment(uuid, uuid, numeric, date, text, integer, integer, integer) to anon, authenticated, service_role;
grant all on function public.list_employees() to anon, authenticated, service_role;
grant all on function public.list_employee_payments(uuid) to anon, authenticated, service_role;
grant all on function public.list_employee_payment_categories() to anon, authenticated, service_role;
